import SwiftUI
import AppKit
import Observation
import SystemConfiguration

extension BrowserLocation {
    /// What the window title, the pane's label and the path bar call it: the
    /// folder's display name, or the Mac's computer name (System Settings >
    /// General > Sharing) for the overview.
    var displayName: String {
        folder.map { FileManager.default.displayName(atPath: $0.path) } ?? Self.computerName
    }

    /// From SystemConfiguration, which asks nothing of the network
    /// (Host.current() can wait on DNS). Read once: a rename shows after relaunch.
    static let computerName = (SCDynamicStoreCopyComputerName(nil, nil) as String?)
        ?? String(localized: "Computer", comment: "Name of the computer browser location when the Mac's name can't be read")
}

/// One pane of a browser window, and what it does: the folder it shows and
/// what it lists (`model`), its Back / Forward history (`navigation`), its
/// searches by name (`searchEngine`) and by tag (`tagService`), and the
/// loading, watching, searching and opening that keep them up to date. A
/// window has one, or two side by side (BrowserPanes).
///
/// Held, not observed: the window's body doesn't read what these publish.
/// The views that show a pane's state observe what they read themselves:
/// BrowserModel is @Observable, and the services are ObservableObjects that
/// PaneSearchChanges, BrowserSearch, FileBrowser and the status bar observe.
/// So a search or tag update re-renders only those, not the whole window.
/// BrowserPane shows it, and its reactions (BrowserModelChanges,
/// PaneSearchChanges, the disk and the settings) call the methods here.
///
/// The methods read the browse settings (sort, hidden files, view mode) from
/// `BrowseSettings.current` when they run, not from a view's `@AppStorage`:
/// the window's menu commands call them through closures made once, which
/// would keep the values from that time.
///
/// `init` must stay free of side effects (no watching, searching or loading):
/// it runs each time ContentView is created, as an @State initialiser, and
/// every instance but the first is thrown away. The window starts the work.
@MainActor
final class PaneState {
    let model: BrowserModel
    let navigation: BrowserNavigation
    let searchEngine: SearchEngine
    let tagService: TagService
    /// The volumes and space this pane's overview shows (the reader is the app's).
    let diskOverview = DiskOverviewState()
    /// The window the pane is in (BrowserPanes.attach): VoiceOver's
    /// announcements go to it, folders opened in new tabs open beside it, and
    /// the pane's lists are found in it.
    weak var window: NSWindow?
    /// The pane's file browser (list, icons or columns), for finding the
    /// pane's own lists among the window's (focusResults).
    let browserArea = WeakView()
    /// The whole pane, path bar to status bar: where a click or keyboard
    /// focus makes it the active pane (ActivePaneTracker).
    let paneArea = WeakView()

    init() {
        model        = BrowserModel(openResolver: .forWindow())
        navigation   = BrowserNavigation()
        searchEngine = SearchEngine()
        tagService   = TagService()
    }

    /// The search field has text, or a tag is chosen in the sidebar.
    var isSearchActive: Bool { !searchEngine.query.isEmpty || model.activeTagFilter != nil }

    // MARK: - Starting and stopping

    /// Whether the pane is started (`start`, `stop`). Not observed.
    private(set) var isStarted = false

    /// What a shown pane needs: its folder watched and listed again, and its
    /// searches (the field's and the tag filter's) running. The window calls
    /// it for each pane shown when it appears (again, too: a tab moved), and
    /// for a pane it shows later. Does nothing while started, nor for the
    /// folder's watch and listing while the folder is watched.
    ///
    /// A pane that hasn't shown a folder yet is only marked started: the
    /// window gives it its first (a pending request, else the New windows
    /// folder), which starts the history, the watch and the listing. Its
    /// folder isn't reset here.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        guard navigation.history.current != nil, model.watchedPath == nil, let folder = model.folder else { return }
        watch(folder)
        reload()
        rerunActiveSearch()
        // Listed and searched afresh: what a rename held back is done.
        model.reloadGate.dropDeferred()
        model.searchRefresh.dropDeferred()
        if let tag = model.activeTagFilter { tagService.searchFiles(for: tag) }
        leaveFolderIfGone()
    }

    /// A stopped pane didn't see its folder go (hidden while its disk was
    /// ejected, or the folder deleted or renamed from the other pane), and a
    /// watch can't tell it now: checked once it starts, off the main thread as
    /// a server's folder can be slow to answer. A gone folder is left for the
    /// nearest that still exists, as `currentFolderChanged` does.
    private func leaveFolderIfGone() {
        guard let path = model.folder else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let fallback = Self.fallback(for: path) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, isStarted, ShellPath.same(path, model.folder) else { return }
                let hadTag = model.activeTagFilter != nil
                model.location = .folder(fallback)
                // A pane being shown again has no view yet to react to that
                // (BrowserModelChanges), nor to folderChanged clearing the tag
                // filter, so the tag search start began is stopped here; one
                // that has a view finds both done.
                locationChanged(to: .folder(fallback))
                if hadTag { tagFilterChanged(to: nil) }
            }
        }
    }

    /// Where the pane goes when `path` no longer exists, or nil while it does
    /// (SidebarVolumes.folder(replacingGone:)).
    nonisolated private static func fallback(for path: URL) -> URL? {
        // A backup stays in place to say how to make it available while its
        // disk is mounted (UnavailableBackupView).
        let fm = FileManager.default
        let backups = TimeMachineBackups.live
        if backups.isSnapshotPath(path) {
            if backups.disk(forSnapshotPath: path) != nil || fm.fileExists(atPath: path.path) { return nil }
            // Its disk gone: home, as after an eject, not the hidden snapshot folder.
            let home = fm.homeDirectoryForCurrentUser
            return fm.fileExists(atPath: home.path) ? home : URL(fileURLWithPath: "/", isDirectory: true)
        }
        return SidebarVolumes.folder(replacingGone: path, home: fm.homeDirectoryForCurrentUser,
                                     exists: { fm.fileExists(atPath: $0) })
    }

    /// Lets go of what `start` took, for a pane no longer shown (its window
    /// closed, its view left the window, or the pane was hidden): the folder's
    /// watch, a listing on its way, an open still following a link, and the
    /// searches, which would otherwise keep updating results nobody can see.
    /// The pane keeps its folder, history and query, so `start` picks up
    /// where it left off. Safe to call more than once.
    func stop() {
        isStarted = false
        model.openResolver.cancel()
        model.listingLoads.cancel()
        if let watched = model.watchedPath { DirectoryWatcher.shared.release(watched) }
        model.watchedPath = nil
        searchEngine.clear()
        tagService.stopSearch()
    }

    /// Shows `url` as the pane's first folder, its view already in the
    /// window: changing the folder has BrowserModelChanges call folderChanged,
    /// which starts the history, the watch and the listing.
    func showFirst(_ url: URL) {
        if model.location != .folder(url) {
            model.location = .folder(url)
        } else {
            startShowing(url)
        }
    }

    /// Shows a location requested when this tab was created. The computer
    /// overview has no folder URL, but still must not become the default folder.
    func showFirst(_ location: BrowserLocation) {
        switch location {
        case .folder(let url): showFirst(url)
        case .computer:
            if model.location == .computer {
                navigation.visit(.computer)
            } else {
                model.location = .computer
            }
        }
    }

    /// Starts the history, the directory watch and the listing at `url`.
    func startShowing(_ url: URL) {
        navigation.visit(url)
        watch(url)
        reload()
    }

    /// Settings → General → New windows open. Checked off the main thread: a
    /// chosen folder on a network share can be slow to answer. The user going
    /// somewhere first wins.
    func showNewWindowFolder() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let url = NewWindowFolder.initialURL()
            DispatchQueue.main.async { [self] in
                // A pane stopped meanwhile (its window closed) watches nothing.
                guard isStarted, navigation.history.current == nil else { return }
                if model.location == .folder(url) {
                    startShowing(url)
                } else {
                    model.location = .folder(url)    // locationChanged watches + reloads, and starts the history
                }
            }
        }
    }

    // MARK: - Reacting to the model (BrowserModelChanges)

    // Don't clear the icon cache on every navigation: NSCache evicts under
    // memory pressure automatically; keeping icons warm makes navigation fast.
    func locationChanged(to location: BrowserLocation) {
        guard let newPath = location.folder else {
            model.isReadOnlyLocation = false
            model.backupUnavailable = false
            model.needsFullDiskAccess = false
            model.backupNoteFolder = nil
            model.openResolver.cancel()
            model.listingLoads.cancel()
            if let watched = model.watchedPath { DirectoryWatcher.shared.release(watched) }
            model.watchedPath = nil
            navigation.arrive(at: .computer, columnSelection: nil)
            // Back to the tile last opened, as Finder does; the overview drops
            // it if that volume has gone.
            model.overviewSelection = model.rememberedOverviewSelection
            model.quietNavigation = nil
            model.pendingSelectURLs = []
            model.tagGeneration.next()
            model.tagDisplayFiles = []
            tagService.stopSearch()
            setRawFiles([])
            model.selectedIDs = []
            // The column browser that set it is gone; File > Open mustn't stay enabled.
            model.columnHasSelection = false
            model.activeTagFilter = nil
            model.searchDisplayFiles = []
            model.convertingResults = false
            model.listedSearch = nil
            clearSearch()
            return
        }
        model.overviewSelection = nil
        // Already shown there: `leaveFolderIfGone` moved the pane before its
        // view reacted to the change.
        if let watched = model.watchedPath, let current = navigation.history.current,
           ShellPath.same(watched, newPath), current == .folder(newPath) { return }
        // Until the listing lands: no note from the folder left, and read-only
        // wherever it might be (lexically), so a quick paste can't land on a
        // Time Machine disk's root.
        model.backupUnavailable = false
        model.needsFullDiskAccess = false
        model.backupNoteFolder = nil
        model.isReadOnlyLocation = TimeMachineBackups.live.isSnapshotPath(newPath)
            || TimeMachineBackups.isVolumeRoot(newPath, under: TimeMachineBackups.live.volumesRoot)
        // An open still following a link was for the folder left.
        model.openResolver.cancel()
        // A folder selected in the column browser isn't a Back step (as in Finder).
        navigation.arrive(at: .folder(newPath), columnSelection: model.quietNavigation.map(BrowserLocation.folder))
        model.quietNavigation = nil
        // Instant feedback: clear stale listing so navigation doesn't look frozen
        // while the background reload runs.
        setRawFiles([])
        model.selectedIDs = []
        model.activeTagFilter = nil
        // Keep a pending selection only if it lives in the folder we're entering
        // (e.g. a file selected in another column of the column browser).
        model.pendingSelectURLs.removeAll { !ShellPath.isParent(newPath, of: $0) }
        watch(newPath)
        reload()
        // A folder-scoped search follows the pane to the new folder. BrowserSearch
        // did this when it was handed the folder; it no longer is, so the folder
        // can change without re-rendering the window.
        if searchEngine.selectedScope.isLocal { rerunActiveSearch() }
    }

    // When a tag is selected, search Mac-wide; when cleared, reset tagged results
    func tagFilterChanged(to tag: SidebarTag?) {
        // Drop the previous tag's results right away (and any conversion still
        // running for them) so tag A's files never show under tag B.
        model.tagGeneration.next()
        model.tagDisplayFiles = []
        // The computer's overview has nowhere to list a tag's files.
        if tag != nil, model.folder == nil {
            NSSound.beep()
            model.activeTagFilter = nil
            return
        }
        if let tag {
            tagService.searchFiles(for: tag)
        } else {
            tagService.stopSearch()
        }
        refreshDisplay()
    }

    // An inline rename holds reloads back: one that rebuilt the row being
    // edited took its focus and committed the half-typed name.
    func renamingChanged(to active: Bool) {
        if active {
            model.reloadGate.suspend()
        } else {
            if model.reloadGate.resume() { currentFolderChanged() }
            if model.searchRefresh.resume(), searchEngine.selectedScope.isLocal { refreshActiveSearch() }
            if let held = model.searchLoads.takeHeld() { patchSearchResults(held) }
        }
    }

    // MARK: - Reacting to the searches (PaneSearchChanges)

    /// Searches as the user types; an emptied field stops the search.
    func queryChanged(to query: String) {
        if query.isEmpty { searchEngine.clear() } else { runSearch() }
        model.announceResults = false
        // A cleared field lists no search, so typing the same query again
        // shows "Searching…" even when the results were already empty.
        if query.isEmpty { model.listedSearch = nil }
        refreshDisplay()
    }

    // VoiceOver hears how a search came out, once its results are in the list.
    func searchingChanged(from wasSearching: Bool, to searching: Bool) {
        guard wasSearching, !searching, !searchEngine.query.isEmpty else { return }
        model.announceResults = true
        // After the results' own onChange has started converting them.
        DispatchQueue.main.async { [self] in announceResultsIfListed() }
    }

    // Convert Spotlight tag results to FileItems in background, those in the
    // folder shown under the path the user browsed (it may be a symlink).
    func taggedFilesChanged(to urls: [URL]) {
        let token = model.tagGeneration.next()
        let settings = BrowseSettings.current
        guard let folder = model.folder else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let files = sortedItems(BrowserModel.tagResultItems(urls, shownUnder: folder),
                                    by: settings.sortField, ascending: settings.sortAscending,
                                    folderOrder: settings.folderOrder)
            DispatchQueue.main.async { [self] in
                guard model.tagGeneration.isCurrent(token) else { return }
                model.tagDisplayFiles = files
                refreshDisplay()
            }
        }
    }

    // A search starting or ending in column view drops the selection (ShellSelection).
    func searchToggled() {
        let next = ShellSelection.afterSearchToggle(model.selectedIDs,
                                                    inColumns: BrowseSettings.current.viewMode == .columns)
        if next != model.selectedIDs { model.selectedIDs = next }
    }

    // MARK: - Reacting to the settings

    /// Show Hidden Files changed: the folder is listed again, and a folder
    /// search runs again (Spotlight leaves hidden files out either way).
    func showHiddenChanged() {
        reload()
        if searchEngine.selectedScope.isLocal { rerunActiveSearch() }
    }

    /// Entering or leaving column view: the list selection isn't visible there,
    /// so it's dropped rather than let ⌘C / Delete act on items the user can't see.
    func viewModeChanged(from old: ViewMode, to new: ViewMode) {
        // An open waiting on a link was for the view left (a column's).
        model.openResolver.cancel()
        if old == .columns || new == .columns { model.selectedIDs = [] }
    }

    // MARK: - Reacting to the disk

    /// A watched folder changed on disk (DirectoryWatcher), or a file operation
    /// asked for a refresh (`.refreshDirectory`).
    func directoryChanged(_ url: URL) {
        searchFolderChanged(url)
        guard ShellPath.same(url, model.folder) else { return }
        if model.reloadGate.request() { currentFolderChanged() }
    }

    /// Files in a watched folder changed in place (a download or a log
    /// growing): just those are read again, in the folder shown and among the
    /// search results. Searches aren't re-run for these.
    func entriesChanged(_ names: Set<String>, in folder: URL, realPath: String?) {
        searchEntriesChanged(names, in: folder, realPath: realPath)
        guard ShellPath.same(folder, model.folder) else { return }
        if model.reloadGate.request() { reload(changed: names) }
    }

    // MARK: - Navigation

    /// Going somewhere from the path bar or sidebar ends a Spotlight search,
    /// which would otherwise stay on screen (and selectable for Trash) over the
    /// folder just opened.
    func go(to url: URL) { go(to: .folder(url)) }

    func go(to location: BrowserLocation) {
        endGlobalSearch()
        model.location = location
    }

    /// Clears a Spotlight-scoped search (Desktop … Entire Mac). Folder-scoped
    /// searches stay: folderChanged re-runs them in the new folder.
    func endGlobalSearch() {
        guard !searchEngine.query.isEmpty, !searchEngine.selectedScope.isLocal else { return }
        clearSearch()
    }

    /// Empties the search field and stops its search (Escape in the field).
    func clearSearch() {
        searchEngine.query = ""
        searchEngine.clear()
    }

    func goBack() {
        guard let location = navigation.back() else { NSSound.beep(); return }
        endGlobalSearch()
        model.location = location
    }

    func goForward() {
        guard let location = navigation.forward() else { NSSound.beep(); return }
        endGlobalSearch()
        model.location = location
    }

    func goUp() {
        guard navigation.history.canGoUp else { NSSound.beep(); return }
        endGlobalSearch()
        guard let folder = model.folder else { NSSound.beep(); return }
        model.location = .folder(TimeMachineBackups.live.parentURL(for: folder))
    }

    // MARK: - Selecting and opening

    /// Edit → Select All. Column view: everything in the focused column, which
    /// becomes the last one shown, so nothing selected is out of sight (ColumnsView).
    func selectAll() {
        guard model.folder != nil else { NSSound.beep(); return }
        if BrowseSettings.current.viewMode == .columns && !isSearchActive {
            model.columnSelectAllRequest += 1
            return
        }
        model.selectedIDs = Set(model.displayFiles.map(\.id))
    }

    /// File → Open, as ⌘O in the view shown: Columns view's focused column
    /// opens its selection (a folder as the next column); otherwise the
    /// selection opens, unless a rename is being typed.
    func openSelection() {
        guard model.folder != nil else {
            guard let url = diskOverview.volumeURL(for: model.overviewSelection) else { NSSound.beep(); return }
            model.rememberedOverviewSelection = model.overviewSelection
            go(to: .folder(url))
            return
        }
        if BrowseSettings.current.viewMode == .columns && !isSearchActive {
            model.columnOpenRequest += 1
            return
        }
        let selected = model.displayFiles.filter { model.selectedIDs.contains($0.id) }
        guard case .open(let items) = ShellItemKey.open.action(selected: selected, textHasFocus: false,
                                                               renaming: model.inlineRenameActive)
        else { NSSound.beep(); return }
        // After the menu is done with, as ⌘O: opening a folder replaces the rows.
        DispatchQueue.main.async { [self] in openItems(items) }
    }

    /// Open on the items a double-click, Return or the context menu gave: every
    /// one, as in Finder (see ShellOpenPlan). One folder is shown here (or in a
    /// new window or tab, per Settings), several get a window (or tab) each,
    /// files open each in their app; more than ShellOpenPlanLimit.confirmAbove
    /// at once asks first. `folders` overrides Settings: a ⌘-double-click
    /// opens folders in new tabs, as in Finder.
    func openItems(_ items: [FileItem], folders: ShellFolderDestination? = nil) {
        guard !items.isEmpty else { return }
        let destination = folders ?? FolderOpenTarget.fromStorage(
            UserDefaults.standard.string(forKey: FolderOpenTarget.key)).destination
        // Asks before following anything: a link the listing didn't follow is
        // followed only once the user says Open (so Cancel mounts nothing), and
        // until then counts as the most it could open.
        let most = ShellOpenPlan.mostOpened(items, isFolder: \.isBrowsableFolder, isUnknown: \.isLinkNotFollowed,
                                            folders: destination)
        if most > ShellOpenPlanLimit.confirmAbove {
            let alert = NSAlert()
            alert.messageText     = ShellOpenPlanLimit.question(count: most)
            alert.informativeText = ShellOpenPlanLimit.detail
            alert.addButton(withTitle: String(localized: "Open", comment: "Alert button to open selected items"))
            alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button to cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // Each item's folder-or-not, decided once: the only time a link the
        // listing didn't follow is followed for it (ShellOpenTarget.following).
        // That runs off the main thread (an NFS mount, or an unreachable
        // host's timeout, froze the window), with the status bar saying so,
        // and is dropped if the pane has gone to another folder meanwhile.
        // The link's follow also decides how a file there opens, so nothing
        // reads it on the main thread; one that couldn't be reached isn't
        // opened at all. Holds the pane weakly: a closed window's is let go.
        guard let folder = model.folder else { return }
        model.openResolver.resolve(items, isRelevant: { [weak self] in
            self.map { ShellPath.same(folder, $0.model.folder) } ?? false
        }) { [weak self] resolution in
            guard let self else { return }
            let plan = ShellOpenPlan(items, isFolder: { resolution.folders.contains($0.id) },
                                     folders: destination)
            var unreachable: [String] = []
            for file in plan.files {
                switch resolution.followed[file.id] {
                case .unreachable?: unreachable.append(file.name)
                case let target?:   FileOpener.open(file.url, as: target)
                case nil:           FileOpener.open(file.url, as: ShellOpenTarget.forFile(file.url))
                }
            }
            plan.newWindows.forEach { BrowserWindowRouter.shared.openNewWindow(at: $0.url) }
            plan.newTabs.forEach { BrowserWindowRouter.shared.openNewTab(at: $0.url, in: self.window) }
            if !unreachable.isEmpty { FileOpener.showUnreachable(unreachable) }
            // Last: going there replaces the listing the items came from.
            if let folder = plan.navigate { self.model.location = .folder(folder.url) }
        }
    }

    /// Opens a file the column view has already found not to be a folder.
    func openFile(at url: URL) {
        FileOpener.open(url, as: ShellOpenTarget.forFile(url))
    }

    /// Column view selected `files` (none, one or several) in `directory`. Make
    /// that folder the current one (so New Folder / Paste / ⌘C act where the user
    /// is looking) and make the files the pane's selection, replacing it.
    func columnSelectedFiles(_ files: [URL], in directory: URL) {
        if ShellPath.same(directory, model.folder) {
            let listed = files.compactMap { model.displayedItem(at: $0)?.id }
            model.selectedIDs = Set(listed)
            // Listing still loading: the rest once it's in.
            model.pendingSelectURLs = listed.count == files.count ? [] : files
        } else {
            model.pendingSelectURLs = files
            model.quietNavigation = directory
            model.location = .folder(directory)
        }
    }

    // MARK: - Focus and scrolling

    /// Nothing in particular has keyboard focus: the window, or a view holding
    /// the whole pane, where SwiftUI leaves it after a click on the overview.
    var keyboardFocusIsUnclaimed: Bool {
        guard let window else { return false }
        let responder = window.firstResponder
        if responder == nil || responder === window { return true }
        guard let container = responder as? NSView, let area = paneArea.view else { return false }
        return area.isDescendant(of: container)
    }

    /// Gives the file list keyboard focus (Return / ↓ / Escape in the search
    /// field). The lists are AppKit tables; ShellResultsFocus picks the one in the
    /// pane's file browser area (never the sidebar's) at the trailing edge, the
    /// last column in Columns view. Focusing them through SwiftUI changed how the
    /// list table draws, so it's done here; the icon grid is SwiftUI's.
    func focusResults(rightToLeft: Bool) {
        if model.location.folder == nil {
            model.listFocusRequest += 1
            return
        }
        if BrowseSettings.current.viewMode == .icons {
            model.listFocusRequest += 1
            return
        }
        guard let window, let root = window.contentView, let area = browserArea.view else { return }
        var tables: [NSTableView] = []
        func collect(_ v: NSView) {
            if let t = v as? NSTableView, !t.isHiddenOrHasHiddenAncestor { tables.append(t) }
            v.subviews.forEach(collect)
        }
        collect(root)
        let frames = tables.map { $0.convert($0.visibleRect, to: nil) }
        if let i = ShellResultsFocus.target(listFrames: frames,
                                            browserArea: area.convert(area.bounds, to: nil),
                                            rightToLeft: rightToLeft) {
            window.makeFirstResponder(tables[i])
        }
    }

    /// Scrolls the list Table to `row`. Only the ungrouped list is an
    /// NSTableView whose rows match `displayFiles`; the grouped list scrolls
    /// itself on selection, and in icon / column view a table found in the
    /// window would be the sidebar or a column pane. The table must be in
    /// this pane's area, as for focusResults: another pane's list can have as
    /// many rows. (The area's view is a sibling of the list, not an ancestor,
    /// so the window is searched and the frames compared.)
    func scrollTableView(toRow row: Int) {
        let settings = BrowseSettings.current
        guard row >= 0, settings.viewMode == .list, settings.groupBy == .none,
              let root = window?.contentView else { return }
        let rows = model.displayFiles.count
        let area = browserArea.view.map { $0.convert($0.bounds, to: nil) }
        func find(_ v: NSView) -> NSTableView? {
            if let tv = v as? NSTableView, !(tv is NSOutlineView), tv.numberOfRows == rows,
               area.map({ ShellResultsFocus.isInArea(tv.convert(tv.visibleRect, to: nil), browserArea: $0) }) ?? true {
                return tv
            }
            return v.subviews.lazy.compactMap { find($0) }.first
        }
        find(root)?.scrollRowToVisible(row)
    }

    /// Items a Move to Trash couldn't take and the user kept: those listed
    /// here are selected again, but only into an empty selection: one the
    /// user made meanwhile stays.
    func selectKept(_ urls: [URL]) {
        let keys = Set(urls.map(ShellPath.key))
        let ids = Set(model.displayFiles.filter { keys.contains(ShellPath.key($0.url)) }.map(\.id))
        if !ids.isEmpty, model.selectedIDs.isEmpty { selectByApp(ids) }
    }

    /// A selection the app made (a new folder, a paste, a drop, items kept
    /// from the Trash), until selectionAppeared sees it: it doesn't make the
    /// pane the active one, as the user selecting something there does.
    private var appSelection: Set<String>?

    /// Selects `ids` on the app's behalf, not as the user choosing this pane.
    private func selectByApp(_ ids: Set<String>) {
        appSelection = model.selectedIDs.isEmpty ? ids : nil
        model.selectedIDs = ids
    }

    /// Something is selected where nothing was. If the user selected it in
    /// the pane that isn't active (VoiceOver's VO-Space, or another way that
    /// neither clicks nor moves keyboard focus into it), that pane becomes
    /// the active one, as a click there would make it.
    func selectionAppeared(in panes: BrowserPanes) {
        let madeByApp = appSelection
        appSelection = nil
        guard madeByApp != model.selectedIDs else { return }
        panes.activate(self)
    }

    /// Selects `pendingSelectURLs` once they show up in the listing.
    func resolvePendingSelection() {
        guard !model.pendingSelectURLs.isEmpty else { return }
        let urls = model.pendingSelectURLs
        model.pendingSelectURLs = []
        let items = urls.compactMap { model.displayedItem(at: $0) }
        guard let first = items.first else { return }
        selectByApp(Set(items.map(\.id)))
        DispatchQueue.main.async { [self] in
            scrollTableView(toRow: model.displayIndex[first.id] ?? 0)
        }
    }

    // MARK: - Display list

    func setRawFiles(_ items: [FileItem]) {
        model.setRawFiles(items)
        refreshDisplay()
    }

    /// Rebuilds the model's display list from the current inputs. Call after
    /// changing rawFiles, search / tag results, the query or the tag filter.
    func refreshDisplay() {
        let settings = BrowseSettings.current
        model.refreshDisplay(query: searchEngine.query, hasSearchResults: !searchEngine.results.isEmpty,
                             sortField: settings.sortField, ascending: settings.sortAscending,
                             folderOrder: settings.folderOrder)
    }

    // MARK: - Loading

    /// Re-sorts the listing and search results off the main thread. Both are
    /// rebuilt from their sources rather than from the arrays on screen: a
    /// snapshot taken while a load is still in flight is empty or stale, and its
    /// newer token would discard that load.
    func resortAll() {
        reload()
        convertSearchResults(searchEngine.results)
    }

    /// Turns search result URLs into sorted FileItems in the background.
    func convertSearchResults(_ results: [URL]) {
        let token = model.searchLoads.startConversion()
        // Only a finished search's results are its own: while the engine is still
        // searching, `results` is the list it cleared for that search (or the last
        // one, re-sorted), so stamping the new key would hide "Searching…" until
        // the real results had been converted.
        let search = searchEngine.isSearching ? model.listedSearch : searchKey
        if results.isEmpty {
            _ = model.searchLoads.finishConversion(token)
            model.searchDisplayFiles = []
            model.convertingResults = false
            model.listedSearch = search
            refreshDisplay()
            announceResultsIfListed()
            return
        }
        model.convertingResults = true
        let settings = BrowseSettings.current
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let files = SearchResultLoads.items(results, sortedBy: settings.sortField,
                                                ascending: settings.sortAscending,
                                                folderOrder: settings.folderOrder)
            DispatchQueue.main.async { [self] in
                guard model.searchLoads.finishConversion(token) else { return }
                model.searchDisplayFiles = files
                model.convertingResults = false
                model.listedSearch = search
                refreshDisplay()
                announceResultsIfListed()
                // Results that changed while these were read.
                if let more = model.searchLoads.takeDeferred() { patchSearchResults(more) }
            }
        }
    }

    /// Entries of the watched `folder` (at `realPath`) changed in place: any of
    /// them among the search results are read again (`patchSearchResults`),
    /// under either path.
    func searchEntriesChanged(_ names: Set<String>, in folder: URL, realPath: String?) {
        guard !searchEngine.query.isEmpty else { return }
        patchSearchResults(ShellListingPatch.resultPaths(names, in: folder, realPath: realPath))
    }

    /// Search results at `paths` (ShellPath.key) changed in place: just those are
    /// read again and patched into the results shown, which keep their ids, so
    /// the selection and the scroll position stay. While results are being read
    /// (a new search's first ones too, before any are listed) the paths wait for
    /// them to land, and while an inline rename is open, for it to end
    /// (SearchResultLoads).
    func patchSearchResults(_ paths: Set<String>) {
        guard !searchEngine.query.isEmpty,
              model.searchLoads.changed(paths, renaming: model.inlineRenameActive),
              !model.searchDisplayFiles.isEmpty else { return }
        let results = model.searchDisplayFiles
        let token = model.searchLoads.startPatch()
        let settings = BrowseSettings.current
        // Spotlight leaves hidden files out whatever the setting.
        let hidden = searchEngine.selectedScope.isLocal ? settings.showHidden : true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Kept in order by moving only the results read again.
            let result = ShellListingPatch.apply(paths: paths, toResults: results, showHidden: hidden,
                                                 sortedBy: settings.sortField, ascending: settings.sortAscending,
                                                 folderOrder: settings.folderOrder)
            DispatchQueue.main.async { [self] in
                switch model.searchLoads.finishPatch(token, paths: paths, result: result,
                                                     renaming: model.inlineRenameActive) {
                case .show(let files):
                    model.searchDisplayFiles = files
                    refreshDisplay()
                case .rerun:
                    // A result gone or hidden meanwhile: a folder search runs
                    // again (Spotlight updates its own).
                    scheduleSearchRefresh()
                case .nothing:
                    break
                }
                if let more = model.searchLoads.takeDeferred() { patchSearchResults(more) }
            }
        }
    }

    /// Identifies the search shown for `listedSearch`.
    private var searchKey: String {
        BrowserModel.searchKey(scope: searchEngine.selectedScope, query: searchEngine.query)
    }

    /// Tells VoiceOver how the search finished ("12 found", "No results"), once
    /// the engine is done and its results are what the list shows, not the
    /// previous query's.
    func announceResultsIfListed() {
        guard model.announceResults, !searchEngine.isSearching, !model.convertingResults,
              !searchEngine.query.isEmpty else { return }
        model.announceResults = false
        let count = model.displayFiles.count
        NSAccessibility.post(element: window ?? NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: count == 0 ? String(localized: "No results", comment: "VoiceOver announcement when a search has no results")
                                : String(localized: "\(count) found", comment: "Number of search results announced to VoiceOver."),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Keeps the directory watcher on the folder this pane shows.
    func watch(_ url: URL) {
        if let old = model.watchedPath { DirectoryWatcher.shared.release(old) }
        DirectoryWatcher.shared.retain(url)
        model.watchedPath = url
    }

    /// The current folder changed on disk. If it was deleted or renamed away,
    /// fall back to the nearest folder that still exists.
    func currentFolderChanged() {
        guard let folder = model.folder else { return }
        if let fallback = Self.fallback(for: folder) {
            model.location = .folder(fallback)
            return
        }
        reload()
    }

    /// Reload after a file operation: the listing, plus the active search (its
    /// results are a snapshot and would otherwise keep showing trashed items).
    /// While an inline rename is open both wait, like changes seen on disk: a
    /// long paste or undo finishing then would rebuild the row being edited.
    func refreshAfterFileOp() {
        if model.reloadGate.request() { reload() }
        if model.inlineRenameActive {
            scheduleSearchRefresh()
        } else {
            rerunActiveSearch()
        }
    }

    /// Runs the field's search, in its scope from the folder shown. With an
    /// empty field it stops the one running (a scope change does this, so the
    /// old scope's Spotlight query doesn't keep going).
    func runSearch() {
        guard let folder = model.folder else { return }
        searchEngine.search(in: searchEngine.selectedScope.baseURL(currentPath: folder),
                            showHidden: BrowseSettings.current.showHidden)
    }

    func rerunActiveSearch() {
        guard !searchEngine.query.isEmpty else { return }
        runSearch()
    }

    /// Like `rerunActiveSearch`, for changes seen on disk: a folder walk still
    /// running isn't cancelled, it runs once more when done (SearchRerunState).
    func refreshActiveSearch() {
        guard !searchEngine.query.isEmpty else { return }
        guard let folder = model.folder else { return }
        searchEngine.refresh(in: searchEngine.selectedScope.baseURL(currentPath: folder),
                             showHidden: BrowseSettings.current.showHidden)
    }

    /// A watched folder changed on disk while a search may be showing: results
    /// in it that are gone leave at once, and a folder search covering it
    /// re-runs (debounced) so created and renamed files show up too. Spotlight
    /// scopes update themselves (SearchRefresh). While an inline rename is open
    /// the list isn't touched; the re-run waits until it ends.
    func searchFolderChanged(_ changed: URL) {
        guard !searchEngine.query.isEmpty else { return }
        if !model.inlineRenameActive { searchEngine.dropMissingResults(inside: changed) }
        let scope = searchEngine.selectedScope
        guard let folder = model.folder else { return }
        guard SearchRefresh.shouldRerun(query: searchEngine.query, scope: scope,
                                        base: scope.baseURL(currentPath: folder), changed: changed)
        else { return }
        scheduleSearchRefresh()
    }

    /// Re-runs a folder search `SearchRefreshThrottle.delay` from now, with any
    /// other requests until then riding along; while an inline rename is open
    /// the run waits until it ends (`searchRefresh.resume`).
    func scheduleSearchRefresh() {
        guard model.searchRefresh.request() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + SearchRefreshThrottle.delay) { [self] in
            guard model.searchRefresh.fire(holding: model.inlineRenameActive) else { return }
            // Still shown (hidden, or its window closed, it searches nothing), and
            // still a folder search (the query or scope may have changed meanwhile;
            // a new one has just run on its own).
            guard isStarted, searchEngine.selectedScope.isLocal else { return }
            refreshActiveSearch()
        }
    }

    /// Lists the folder again. With `changed` (entries the watcher saw change in
    /// place), only those are read again and patched into the listing shown
    /// (ShellListingPatch), unless the change turns out to add or remove items.
    /// While a load is in flight, the names wait for it to land and are patched
    /// in then (ShellListingLoads), rather than starting it over.
    func reload(changed names: Set<String>? = nil) {
        guard let path = model.folder else { return }
        if let names, !model.listingLoads.changed(names) { return }
        let patch    = names.map { (names: $0, listing: model.rawFiles) }
        let token    = model.listingLoads.start()
        let settings = BrowseSettings.current
        let backups = TimeMachineBackups.live
        // Weak: a pane hidden or closed meanwhile isn't kept for the result.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // A Time Machine disk's root lists its backups, read once here. The
            // watcher's changes there are to the hidden files, so it's listed
            // in full rather than patched. With hidden files shown it lists its
            // raw contents, still read-only.
            let destination = backups.destination(at: path)
            let listsBackups = destination.map { !$0.backups.isEmpty && !settings.showHidden } ?? false
            let items = ShellListingPatch.reload(path, changed: destination == nil ? patch : nil,
                                                 showHidden: settings.showHidden,
                                                 sortedBy: settings.sortField, ascending: settings.sortAscending,
                                                 folderOrder: settings.folderOrder,
                                                 list: { url, showHidden in
                if listsBackups, let destination, ShellPath.same(url, path) {
                    return destination.backups.map(FileItem.timeMachineBackup)
                }
                return loadItems(at: url, showHidden: showHidden)
            })?.items
            let readOnly = destination != nil || backups.isSnapshotPath(path)
            let unavailable = backups.backup(at: path).map { !$0.isMounted } ?? false
            let needsAccess = destination?.isReadable == false || backups.isUnreadableBackup(path)
            DispatchQueue.main.async { [weak self] in
                guard let self, model.listingLoads.finish(token), ShellPath.same(path, model.folder)
                else { return }
                model.isReadOnlyLocation = readOnly
                if destination != nil {
                    model.timeMachineRoot = path
                } else if let root = model.timeMachineRoot,
                          ShellPath.same(root, path) || !ShellPath.isSameOrInside(path, root) {
                    model.timeMachineRoot = nil
                }
                model.backupUnavailable = unavailable
                model.needsFullDiskAccess = needsAccess
                model.backupNoteFolder = path
                // Busy folders (~/Downloads, /tmp) reload on every watcher tick;
                // an unchanged listing mustn't rebuild the display and every
                // cache keyed on displayVersion.
                if let items, items != model.rawFiles { setRawFiles(items) }
                resolvePendingSelection()
                // Files that changed while this load was on its way.
                if let more = model.listingLoads.takeDeferred() { reload(changed: more) }
            }
        }
    }
}

// MARK: - The pane, as shown

/// A pane of a browser window as shown: its path bar, its files (list, icons or
/// columns) with the preview beside them, and its status bar; and the pane's
/// reactions to its model and searches, to the disk and to the settings, each
/// calling PaneState.
///
/// Its inputs are the pane's state, the window's services and the settings,
/// as references and values that compare equal from one render to the next.
/// No closures: they never compare equal, so the pane would re-render
/// whenever the window does, which is at progress-publish rate during a copy.
/// Like ContentView, its body reads nothing from the model or the services;
/// the views inside read what they show.
///
/// What the window's services publish (a paste landing, a new folder, a
/// toast) is received by the window, which hands it to the panes: see
/// ContentView.
struct BrowserPane: View {
    let pane: PaneState
    /// The window's panes: the header and the pane's accessibility group look
    /// up whether this one is active, in views of their own.
    let panes: BrowserPanes
    /// Which of two panes this is; nil when the window shows one.
    let position: PanePosition?
    let fileOps: FileOperationsService
    /// The window's (see BrowserReloadRelay): operations started here refresh
    /// every pane through it.
    let reloadRelay: BrowserReloadRelay
    let favorites: FavoritesService
    let viewMode: ViewMode
    let groupBy: GroupBy
    let sortField: SortField
    let sortAscending: Bool
    let folderOrder: FolderOrder
    let showHidden: Bool
    let showColumnTree: Bool
    let showPreview: Bool
    let showPathBar: Bool
    let showStatusBar: Bool

    var body: some View {
        VStack(spacing: 0) {
            // The one row of chrome under the toolbar (View → Show / Hide Path Bar).
            BrowserPathBar(pane: pane, panes: panes, isDual: position != nil, showPathBar: showPathBar)

            PaneLocationArea(pane: pane, fileOps: fileOps, reloadRelay: reloadRelay, favorites: favorites,
                             viewMode: viewMode, isActivePane: { [panes, pane] in panes.active === pane },
                             groupBy: groupBy, folderOrder: folderOrder,
                             showHidden: showHidden, showColumnTree: showColumnTree, showPreview: showPreview)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Shows nothing at the computer.
            if showStatusBar {
                BrowserStatusBar(model: pane.model, searchEngine: pane.searchEngine, sortField: sortField,
                                 sortAscending: sortAscending, groupBy: groupBy)
            }
        }
        // Reacts to the model's changes (navigation, tag filter, inline rename)
        // from a view of its own, so this body doesn't read them.
        .background(BrowserModelChanges(pane: pane, panes: panes))
        // And to the searches (query, scope, results, tag results, search on or
        // off), which this body doesn't observe.
        .background(PaneSearchChanges(pane: pane, searchEngine: pane.searchEngine, tagService: pane.tagService))
        // A watched folder changed on disk (DirectoryWatcher), or a file operation
        // asked for a refresh.
        .onReceive(NotificationCenter.default.publisher(for: .refreshDirectory)) { n in
            guard pane.model.folder != nil, let url = n.object as? URL else { return }
            pane.directoryChanged(url)
        }
        // Files in a watched folder changed in place (a download or a log
        // growing): read just those again, in the folder shown and among the
        // search results. Searches aren't re-run for these.
        .onReceive(NotificationCenter.default.publisher(for: .directoryEntriesChanged)) { n in
            guard pane.model.folder != nil, let url = n.object as? URL,
                  let names = DirectoryWatcher.changedNames(n) else { return }
            pane.entriesChanged(names, in: url, realPath: DirectoryWatcher.realPath(n))
        }
        // Date groups ("Today", "Yesterday") are relative to the current day.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                    .receive(on: DispatchQueue.main)) { _ in
            pane.refreshDisplay()
        }
        .onChange(of: sortField)     { _, _ in pane.resortAll() }
        .onChange(of: sortAscending) { _, _ in pane.resortAll() }
        .onChange(of: folderOrder)   { _, _ in pane.resortAll() }
        .onChange(of: showHidden)    { _, _ in pane.showHiddenChanged() }
        .onChange(of: viewMode)      { old, new in pane.viewModeChanged(from: old, to: new) }
        .background(ViewReader { [pane] in pane.paneArea.view = $0 })
        .modifier(PaneGroup(pane: pane, panes: panes, position: position))
    }
}

/// The pane as one group for VoiceOver, named for its side and folder
/// ("Left pane, Documents") in a window with two, and "Active" (with the
/// selected trait, which VoiceOver reads as "selected") while it's the active
/// one; named for its folder in a window with one. Tests find a pane
/// by its identifier, "pane0" for the first and "pane1" for the second: the
/// views inside keep their own (fileList, pathBar, statusBar…), the same in
/// both panes. A modifier of its own, so a navigation or a pane switch
/// re-runs only this, not the pane's body.
/// What a pane shows under its path bar: a folder's listing (with the preview
/// beside it), or the computer's overview. A view of its own so that only it
/// reads the location: BrowserPane's body reads nothing from the model, and a
/// navigation (every click in Columns view) doesn't run it again.
private struct PaneLocationArea: View {
    let pane: PaneState
    let fileOps: FileOperationsService
    let reloadRelay: BrowserReloadRelay
    let favorites: FavoritesService
    let viewMode: ViewMode
    /// Asked, not passed as a value: reading `panes.active` here would redraw
    /// every pane's files whenever the active pane changes.
    let isActivePane: @MainActor () -> Bool
    let groupBy: GroupBy
    let folderOrder: FolderOrder
    let showHidden: Bool
    let showColumnTree: Bool
    let showPreview: Bool
    @Environment(\.textScale) private var textScale
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        // Right preview panel: list and icon views only (column view has inline preview)
        HStack(spacing: 0) {
            if pane.model.location.folder != nil {
                FileBrowser(pane: pane, model: pane.model, searchEngine: pane.searchEngine,
                            viewMode: viewMode, groupBy: groupBy, showHidden: showHidden,
                            showColumnTree: showColumnTree, folderOrder: folderOrder,
                            fileOps: fileOps, favorites: favorites, reloadRelay: reloadRelay)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ViewReader { [pane] in pane.browserArea.view = $0 })

                if showPreview && viewMode != .columns {
                    Divider()
                    // Grows less than the text, so the file list keeps room.
                    SelectionPreview(model: pane.model)
                        .frame(width: 260 * min(textScale, 1.5))
                }
            } else {
                DiskOverviewView(pane: pane, isActivePane: isActivePane, favorites: favorites,
                                 fileOps: fileOps, isList: viewMode == .list)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Going to or from the computer replaces the view that had keyboard
        // focus (the file list, or the overview), which leaves it with the window
        // (keyboardFocusIsUnclaimed). Again a moment later, as keepKeyboardFocus,
        // in case the new list wasn't there yet.
        .onChange(of: pane.model.location) { old, new in
            guard old == .computer || new == .computer else { return }
            for delay in [0.0, 0.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard isActivePane(), pane.keyboardFocusIsUnclaimed else { return }
                    pane.focusResults(rightToLeft: layoutDirection == .rightToLeft)
                }
            }
        }
    }
}

private struct PaneGroup: ViewModifier {
    let pane: PaneState
    let panes: BrowserPanes
    let position: PanePosition?
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        let name = pane.model.location.displayName
        let isActive = position != nil && panes.active === pane
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label(folder: name))
            .accessibilityValue(isActive ? Text("Active") : Text(verbatim: ""))
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityIdentifier(position == .second ? "pane1" : "pane0")
    }

    private func label(folder: String) -> Text {
        guard let position else { return Text(verbatim: folder) }
        return position.isLeft(layoutDirection) ? Text("Left pane, \(folder)") : Text("Right pane, \(folder)")
    }
}

/// The path bar, while it's shown: by the setting, or for one Go to Folder…
/// edit while the setting hides it (ShellPathBarPresence). In a window with
/// two panes it's always shown, and highlighted on the active pane: this view
/// reads which pane is active, so a pane switch re-renders the headers alone.
private struct BrowserPathBar: View {
    let pane: PaneState
    let panes: BrowserPanes
    let isDual: Bool
    let showPathBar: Bool

    var body: some View {
        let model = pane.model
        if model.pathBarPresence.isVisible(setting: showPathBar) {
            PathBarView(location: Binding(get: { model.location }, set: { [pane] in pane.go(to: $0) }),
                        editRequest: model.pathEditRequest,
                        editPending: Bindable(model).pathEditPending,
                        onEditingEnded: { model.pathBarPresence.editingEnded() },
                        isActivePane: isDual ? panes.active === pane : nil)
                .resetsCursorOnEnter()   // clear a stuck resize cursor when moving up from the file list
        }
    }
}

/// List, icons or columns. Making a binding to a model property reads it, so
/// this re-renders with the selection as well as the listing and folder; the
/// list it shows re-renders for those anyway, and the rest of the window doesn't.
/// It observes the search engine for whether the field has text, so it also
/// re-renders as a search runs (as it did when the window re-rendered for it).
private struct FileBrowser: View {
    let pane: PaneState
    @Bindable var model: BrowserModel
    @ObservedObject var searchEngine: SearchEngine
    let viewMode:          ViewMode
    let groupBy:           GroupBy
    let showHidden:        Bool
    let showColumnTree:    Bool
    let folderOrder:       FolderOrder
    let fileOps:           FileOperationsService
    let favorites:         FavoritesService
    let reloadRelay:       BrowserReloadRelay
    // The list's column headers change the sort.
    @AppStorage(UserPreferences.sortFieldKey)     private var sortFieldRaw  = UserPreferences.defaultSortField.rawValue
    @AppStorage(UserPreferences.sortAscendingKey) private var sortAscending = UserPreferences.defaultSortAscending

    /// The search field has text (the model has the tag filter).
    private var searchQueryActive: Bool { !searchEngine.query.isEmpty }
    private var isSearchActive: Bool { searchQueryActive || model.activeTagFilter != nil }

    private var sortField: Binding<SortField> {
        Binding(get: { SortField.fromStorage(sortFieldRaw) }, set: { sortFieldRaw = $0.rawValue })
    }

    // What the views do, through the pane (PaneState.openItems and the rest).
    private var openItems: ([FileItem]) -> Void { { [pane] in pane.openItems($0) } }
    /// Opens them with folders in new tabs (a ⌘-double-click).
    private var openInNewTabs: ([FileItem]) -> Void { { [pane] in pane.openItems($0, folders: .newTabs) } }
    private var reload: () -> Void { { [reloadRelay] in reloadRelay() } }

    // File ▸ Open's enabled state is the active pane's (ActivePaneFocus), not
    // published here: with two panes, both would publish it.
    @ViewBuilder
    var body: some View {
        if viewMode != .columns, let note = backupNote {
            BackupNoteView(note: note)
        } else if let folder = model.folder {
        switch viewMode {
        case .list:
            ListView(
                files:            model.displayFiles,
                filesVersion:     model.displayVersion,
                selectedIDs:      $model.selectedIDs,
                pendingRenameURL: $model.pendingRenameURL,
                isRenaming:       $model.inlineRenameActive,
                currentPath:      folder,
                isReadOnlyLocation: model.isReadOnlyLocation,
                sortField:        sortField,
                sortAscending:    $sortAscending,
                groupBy:          groupBy,
                onOpen:           openItems,
                onOpenInNewTabs:  openInNewTabs,
                onBrowseInto:     { model.location = .folder($0) },
                onReload:         reload,
                fileOps:          fileOps,
                favorites:        favorites,
                showsSearchResults: searchQueryActive || model.activeTagFilter != nil
            )
        case .icons:
            IconsView(
                files:        model.displayFiles,
                filesVersion: model.displayVersion,
                selectedIDs:  $model.selectedIDs,
                currentPath:  folder,
                isReadOnlyLocation: model.isReadOnlyLocation,
                groupBy:      groupBy,
                onOpen:       openItems,
                onOpenInNewTabs: openInNewTabs,
                onBrowseInto: { model.location = .folder($0) },
                onReload:     reload,
                fileOps:      fileOps,
                favorites:    favorites,
                focusRequest: model.listFocusRequest,
                showsSearchResults: searchQueryActive || model.activeTagFilter != nil
            )
        case .columns:
            ColumnsView(
                currentPath: Binding(get: { model.folder ?? folder }, set: { model.location = .folder($0) }),
                timeMachineRoot: model.timeMachineRoot,
                showHidden:     showHidden,
                showColumnTree: showColumnTree,
                groupBy:        groupBy,
                sortField:      SortField.fromStorage(sortFieldRaw),
                sortAscending:  sortAscending,
                folderOrder:    folderOrder,
                fileOps:        fileOps,
                favorites:      favorites,
                // Only shown while searching: outside a search, a reload needn't
                // re-render the columns, which list folders themselves.
                searchResults:  isSearchActive ? model.displayFiles : [],
                isSearchActive: isSearchActive,
                backupNote: backupNote,
                selectedIDs:    $model.selectedIDs,
                // Opens one file by URL (the column panes, which show folders themselves).
                onOpen:         { [pane] in pane.openFile(at: $0) },
                onOpenResults:  openItems,
                onOpenInNewTabs: openInNewTabs,
                onSelectFiles:  { [pane] in pane.columnSelectedFiles($0, in: $1) },
                onClearSelection: { model.selectedIDs = [] },
                onSearchReload: reload,
                onSelectFolder: { url in
                    // Nothing selected inside it, also when it's already the
                    // current folder (a file in it was selected before).
                    model.selectedIDs = []
                    model.pendingSelectURLs = []
                    model.quietNavigation = url
                    model.location = .folder(url)
                },
                selectAllRequest: model.columnSelectAllRequest,
                openRequest:      model.columnOpenRequest,
                onCommandPaneSelection: { model.columnHasSelection = $0 },
                windowSelection: model.selectedIDs.isEmpty ? []
                    : model.displayFiles.filter { model.selectedIDs.contains($0.id) },
                // Not observed: read whenever the selection changes, which is when it matters.
                hasPendingSelection: !model.pendingSelectURLs.isEmpty,
                openResolver:   model.openResolver
            )
        }
        }
    }

    /// The note for the pane's folder, which Columns shows in that folder's
    /// column (the other views show it in place of the listing, above).
    private var backupNote: BackupNote? {
        guard let folder = model.folder, ShellPath.same(model.backupNoteFolder, folder) else { return nil }
        if model.needsFullDiskAccess { return .fullDiskAccess(folder) }
        if model.backupUnavailable { return .unavailable(folder) }
        return nil
    }
}

/// What a Time Machine folder shows in place of its listing.
enum BackupNote: Equatable {
    case fullDiskAccess(URL)
    case unavailable(URL)

    var folder: URL {
        switch self {
        case .fullDiskAccess(let folder), .unavailable(let folder): folder
        }
    }
}

/// A BackupNote, in place of the listing or of its folder's column.
struct BackupNoteView: View {
    let note: BackupNote

    var body: some View {
        switch note {
        case .fullDiskAccess:          FullDiskAccessView()
        case .unavailable(let folder): UnavailableBackupView(folder: folder)
        }
    }
}

/// In place of a Time Machine disk's or backup's listing (or its column) when
/// Selway may not read it: macOS keeps those for apps with Full Disk Access.
private struct FullDiskAccessView: View {
    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "Selway needs Full Disk Access to show this disk's backups.", comment: "Empty state title for a Time Machine disk Selway may not read"),
                  systemImage: "lock")
        } description: {
            Text(String(localized: "macOS lets only apps with Full Disk Access read Time Machine disks. Add Selway in Privacy & Security, then reopen it.", comment: "Explanation for a Time Machine disk Selway may not read"))
        } actions: {
            Button(String(localized: "Open Privacy & Security", comment: "Button to open the Full Disk Access settings")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .accessibilityIdentifier("fullDiskAccess")
    }
}

/// In place of a backup's listing (or its column) when macOS hasn't mounted
/// it. Selway can't mount it (that needs root); Finder or Time Machine
/// opening it does.
private struct UnavailableBackupView: View {
    let folder: URL

    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "This backup isn't available.", comment: "Empty state title for an unmounted Time Machine backup"),
                  systemImage: "clock.arrow.circlepath")
        } description: {
            Text(String(localized: "Open it once in Finder or Time Machine to make it available.", comment: "Explanation for an unmounted Time Machine backup"))
        } actions: {
            if let disk = TimeMachineBackups.live.disk(forSnapshotPath: folder) {
                Button(String(localized: "Open Disk in Finder", comment: "Button to open a Time Machine disk in Finder")) {
                    let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
                    NSWorkspace.shared.open([disk], withApplicationAt: finder,
                                            configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                }
            }
        }
        .accessibilityIdentifier("backupUnavailable")
    }
}

/// What the menus are told about the window's active pane: Go ▸ Back /
/// Forward's history (`.focusedSceneObject`), and whether File ▸ Open has a
/// selection to open or overview tile to eject. Looked up here, in a modifier
/// of its own, so a pane switch re-runs only this, not the window's body or
/// the panes'.
struct ActivePaneFocus: ViewModifier {
    let panes: BrowserPanes
    let viewMode: ViewMode

    func body(content: Content) -> some View {
        let pane = panes.active
        content.modifier(PaneFocusValues(model: pane.model, navigation: pane.navigation,
                                         diskOverview: pane.diskOverview,
                                         searchEngine: pane.searchEngine, viewMode: viewMode))
    }
}

/// ActivePaneFocus's values for one pane. It observes the pane's search
/// engine for whether a search is on; the model and overview are @Observable.
private struct PaneFocusValues: ViewModifier {
    let model: BrowserModel
    let navigation: BrowserNavigation
    let diskOverview: DiskOverviewState
    @ObservedObject var searchEngine: SearchEngine
    let viewMode: ViewMode

    func body(content: Content) -> some View {
        let searching = !searchEngine.query.isEmpty || model.activeTagFilter != nil
        content
            .focusedSceneObject(navigation)
            // Columns view's focused column has a selection (selecting a folder
            // there empties the pane's). At the computer, the selected tile.
            .focusedSceneValue(\.browserHasOpenableSelection,
                               model.folder == nil ? model.overviewSelection != nil
                               : viewMode == .columns && !searching ? model.columnHasSelection : model.hasSelection)
            // Selway ▸ Eject's tile: the other pane's selection mustn't be ejected.
            .focusedSceneValue(\.overviewEjectVolume,
                               model.folder == nil
                               ? diskOverview.volume(for: model.overviewSelection).flatMap { $0.canEject ? $0 : nil }
                               : nil)
    }
}

/// The preview panel, showing the first selected item: one group VoiceOver
/// calls "Preview", which tests find as "previewPanel".
private struct SelectionPreview: View {
    let model: BrowserModel

    var body: some View {
        FilePreviewPanel(item: model.selectedItem)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Preview")
            .accessibilityIdentifier("previewPanel")
    }
}

/// The status bar. It observes the search engine itself for the query, scope
/// and whether a search is running: the pane and window don't re-render for them.
private struct BrowserStatusBar: View {
    let model: BrowserModel
    @ObservedObject var searchEngine: SearchEngine
    let sortField:       SortField
    let sortAscending:   Bool
    let groupBy:         GroupBy

    @ViewBuilder var body: some View {
        let searchQuery = searchEngine.query
        let searchScope = searchEngine.selectedScope
        let engineSearching = searchEngine.isSearching
        if let folder = model.folder {
            StatusBarView(files: model.displayFiles, selectedIDs: model.selectedIDs, currentPath: folder,
                          sortField: sortField, sortAscending: sortAscending, groupBy: groupBy,
                          searchQuery: searchQuery, searchScope: searchScope,
                          // Not a count until the results are in the list.
                          isSearching: engineSearching
                              || (model.convertingResults
                                  && model.listedSearch != BrowserModel.searchKey(scope: searchScope, query: searchQuery)),
                          openingLinkName: model.openingLinkName)
        }
    }
}

/// The pane's `.onChange` reactions to its model, in a view of their own:
/// `.onChange(of:)` reads its value, and on the pane (or the window) that
/// re-rendered it on every change. Only this empty view re-renders now.
private struct BrowserModelChanges: View {
    let pane: PaneState
    let panes: BrowserPanes

    var body: some View {
        let model = pane.model
        Color.clear
            .onChange(of: model.location) { _, location in pane.locationChanged(to: location) }
            .onChange(of: model.activeTagFilter) { _, tag in pane.tagFilterChanged(to: tag) }
            // Initially too: a pane's view made again (hiding the active right
            // pane rebuilds it in the first's place) can arrive after its list
            // ended a rename the old view was gone too soon to see, leaving
            // its reloads held back.
            .onChange(of: model.inlineRenameActive, initial: true) { _, active in pane.renamingChanged(to: active) }
            .onChange(of: model.hasSelection) { had, has in
                if !had, has { pane.selectionAppeared(in: panes) }
            }
    }
}

/// The pane's `.onChange` reactions to its searches, in a view of their own,
/// as BrowserModelChanges is for the model. The window holds the search
/// engine and tag service (PaneState) without observing them, so these must
/// be on a view that does: on ContentView they would never fire. (When they
/// were ContentView's @StateObjects, they did, by re-rendering the whole
/// window on every keystroke and Spotlight update.)
///
/// They're the pane's, not the search field's: the field (BrowserSearch)
/// edits the active pane's engine, and reacting there would run a search in
/// a pane each time the field moved to it.
private struct PaneSearchChanges: View {
    let pane: PaneState
    @ObservedObject var searchEngine: SearchEngine
    @ObservedObject var tagService: TagService

    var body: some View {
        Color.clear
            .onChange(of: searchEngine.query) { _, query in pane.queryChanged(to: query) }
            // Runs again at once when the scope changes (stopping the old scope's
            // Spotlight query even when the field is empty).
            .onChange(of: searchEngine.selectedScope) { _, _ in pane.runSearch() }
            // SearchEngine.isSearching, from and to.
            .onChange(of: searchEngine.isSearching) { was, now in pane.searchingChanged(from: was, to: now) }
            // Converted to the list's items in the background, never while rendering.
            .onChange(of: searchEngine.results) { _, results in pane.convertSearchResults(results) }
            // A folder walk finished while files changed: run once more, like a change on disk.
            .onChange(of: searchEngine.staleWalks) { _, _ in pane.scheduleSearchRefresh() }
            .onChange(of: tagService.taggedFileURLs) { _, urls in pane.taggedFilesChanged(to: urls) }
            // A search started or ended (the field or the tag filter).
            .onChange(of: !searchEngine.query.isEmpty || pane.model.activeTagFilter != nil) { _, _ in
                pane.searchToggled()
            }
    }
}

// MARK: - The window's panes

/// A browser window's panes, and which of them its menus, toolbar and search
/// act on. ContentView keeps it in @State.
///
/// A window shows one pane, or two side by side (View → Show / Hide Dual
/// Pane). The second is made the first time it's shown, on the folder the
/// first shows, and kept while hidden, stopped (PaneState.stop), so showing
/// it again brings back its folder, history and search.
///
/// @Observable, as BrowserModel is, rather than an ObservableObject: a view
/// that reads `active` re-renders when the active pane changes and for
/// nothing else, so a pane switch updates the sidebar, title, search field,
/// toolbar and menus without re-rendering the window. ContentView reads
/// `first`, `second` and `isDual`, which change only when the second pane is
/// shown or hidden.
@MainActor
@Observable
final class BrowserPanes {
    /// The pane on the leading side, always shown. Its view keeps its place,
    /// and its state, when the second is shown beside it. It's another pane
    /// only after the second was hidden while active: that one takes its place.
    private(set) var first: PaneState
    /// The pane beside it, once it has been shown; kept, stopped, while hidden.
    private(set) var second: PaneState?
    /// Whether the window shows both panes.
    private(set) var isDual: Bool
    /// The pane commands act on: the first, or in a dual window the one last
    /// clicked or given keyboard focus.
    private(set) var active: PaneState
    /// The window they're in, for panes added later.
    @ObservationIgnored private weak var window: NSWindow?
    /// How the panes share the window's width (PaneSplit), for the View
    /// menu's commands too.
    @ObservationIgnored let split = PaneSplitState()
    /// The window's layout direction, as SwiftUI lays the panes out (the
    /// window keeps it up to date): what says which pane is on the left, for
    /// VoiceOver's announcements as for the panes' group labels, and which
    /// list focus goes to.
    @ObservationIgnored var layoutDirection: LayoutDirection = .leftToRight
    /// Makes the pane clicked or focused the active one, while the window is
    /// shown (between `start` and `stop`).
    @ObservationIgnored private let tracker = ActivePaneTracker()
    @ObservationIgnored private var isStarted = false

    /// New windows and tabs show two panes if the last window to change it
    /// did (UserPreferences.dualPaneKey). Free of side effects, like
    /// PaneState.init: ContentView's @State initialisers run again with every
    /// ContentView made, and all but the first instance are thrown away.
    init() {
        let pane = PaneState()
        let dual = UserDefaults.standard.bool(forKey: UserPreferences.dualPaneKey)
        first  = pane
        active = pane
        isDual = dual
        second = dual ? PaneState() : nil
    }

    /// Every pane shown, leading side first.
    var shown: [PaneState] {
        guard isDual, let second else { return [first] }
        return [first, second]
    }

    /// Every pane shown, the active one first: for what wants the window's
    /// folder, which is the active pane's (BrowserWindowRouter's targets).
    /// Reads `active`, so call it in closures that run later, not in a body.
    var activeFirst: [PaneState] {
        let active = active
        return [active] + shown.filter { $0 !== active }
    }

    /// The pane shown beside `pane`, in a dual window.
    func other(than pane: PaneState) -> PaneState? {
        shown.first { $0 !== pane }
    }

    /// The window the panes are in (or none, once it has closed).
    func attach(_ window: NSWindow?) {
        self.window = window
        first.window = window
        second?.window = window
        if isStarted { tracker.follow(window, for: self) }
    }

    /// The window appeared (again, too): every pane shown starts
    /// (PaneState.start). Showing a pane later starts it the same way.
    func start() {
        isStarted = true
        tracker.follow(window, for: self)
        shown.forEach { $0.start() }
    }

    /// The window disappeared or closed: every pane shown stops
    /// (PaneState.stop). Hiding a pane stops it the same way, and keeps its
    /// PaneState: its view and reactions are gone, so a pane still watching
    /// would quietly go stale. Not tied to the pane view's own onAppear and
    /// onDisappear, which SwiftUI may run when it rebuilds the view.
    func stop() {
        isStarted = false
        tracker.stop()
        shown.forEach { $0.stop() }
    }

    // MARK: The active pane

    /// The pane shown at `point` (window coordinates), if any.
    func pane(at point: NSPoint) -> PaneState? {
        shown.first { pane in
            guard let view = pane.paneArea.view, view.window != nil else { return false }
            return view.convert(view.bounds, to: nil).contains(point)
        }
    }

    /// Makes `pane`, one of two shown, the one the menus, toolbar, sidebar
    /// and search act on, and tells VoiceOver which it is now. Only when it
    /// changes: an @Observable property notifies its readers even when it's
    /// set to the same value.
    func activate(_ pane: PaneState) {
        guard isDual, active !== pane, shown.contains(where: { $0 === pane }) else { return }
        active = pane
        let folder = pane.model.location.displayName
        announce(isLeft(pane) ? String(localized: "Left pane, \(folder)") : String(localized: "Right pane, \(folder)"))
    }

    /// Go → Switch to Other Pane: the other pane becomes the active one, and
    /// its list takes keyboard focus. Beeps in a window with one pane.
    func switchToOther() {
        guard isDual, let other = other(than: active) else { NSSound.beep(); return }
        activate(other)
        other.focusResults(rightToLeft: layoutDirection == .rightToLeft)
    }

    /// Whether `pane` shows on the left (the first does, but in a
    /// right-to-left layout).
    private func isLeft(_ pane: PaneState) -> Bool {
        (pane === first ? PanePosition.first : .second).isLeft(layoutDirection)
    }

    /// Has VoiceOver say `text`.
    private func announce(_ text: String) {
        NSAccessibility.post(element: window ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    /// The window's first appearance: each pane shown gets its first folder,
    /// `initial` (one requested for the window) or else the New windows folder.
    func showFirstFolders(initial: BrowserLocation?) {
        for pane in shown where pane.navigation.history.current == nil {
            if let initial { pane.showFirst(initial) } else { pane.showNewWindowFolder() }
        }
    }

    /// Replaces the retained hidden pane with a fresh pane on `location`.
    /// The current first pane and its active state remain untouched.
    /// False, changing nothing, in a window that already shows two panes.
    @discardableResult
    func mergeTab(location: BrowserLocation) -> Bool {
        guard !isDual else { return false }
        second?.stop()
        let pane = PaneState()
        second = pane
        pane.window = window
        isDual = true
        pane.start()
        // Its view doesn't exist yet, so nothing reacts to the location
        // changing (BrowserModelChanges): it's shown here, as in showSecond.
        pane.model.location = location
        if let folder = location.folder { pane.startShowing(folder) } else { pane.navigation.visit(.computer) }
        let name = location.displayName
        announce(isLeft(pane)
            ? String(localized: "Merged “\(name)” into the left pane",
                     comment: "VoiceOver announcement after merging the next tab into the left pane (right-to-left layouts); the placeholder is its folder")
            : String(localized: "Merged “\(name)” into the right pane",
                     comment: "VoiceOver announcement after merging the next tab into the right pane; the placeholder is its folder"))
        keepKeyboardFocus()
        return true
    }

    /// Removes the inactive pane from this window and returns its displayed
    /// location for a new tab. The active pane stays in place and remains active.
    func moveOtherPaneToNewTab() -> BrowserLocation? {
        guard isDual, let pane = other(than: active) else { return nil }
        let location = pane.model.location
        hideSecond()
        // It lives on in the new tab: Show Dual Pane here starts afresh.
        second = nil
        announce(String(localized: "Moved “\(location.displayName)” to a new tab",
                        comment: "VoiceOver announcement after moving a pane to a new tab; the placeholder is its folder"))
        keepKeyboardFocus()
        return location
    }

    // MARK: Showing and hiding the second pane

    /// View → Show / Hide Dual Pane: the second pane shown or hidden, and
    /// VoiceOver told which ("Dual pane shown, left pane active").
    func toggleDual() {
        if isDual {
            hideSecond()
            announce(String(localized: "Dual pane hidden"))
        } else {
            showSecond()
            announce(isLeft(active) ? String(localized: "Dual pane shown, left pane active")
                                    : String(localized: "Dual pane shown, right pane active"))
        }
        keepKeyboardFocus()
    }

    /// After the panes change: if keyboard focus went nowhere (hiding the
    /// active right pane rebuilds it in the first pane's place, and the list
    /// that had focus is gone), the active pane's list takes it. Once the
    /// panes are on screen, and again a little later for a list still being
    /// made.
    private func keepKeyboardFocus() {
        for delay in [0.0, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let window = self.window, window.isVisible else { return }
                let responder = window.firstResponder
                guard responder == nil || responder === window else { return }
                self.active.focusResults(rightToLeft: self.layoutDirection == .rightToLeft)
            }
        }
    }

    /// Shows the second pane beside the first. The first time, it opens on
    /// the first pane's folder; after that, on its own again.
    func showSecond() {
        guard !isDual else { return }
        let pane = second ?? PaneState()
        second = pane
        pane.window = window
        isDual = true
        pane.start()
        guard pane.navigation.history.current == nil else { return }
        if first.navigation.history.current != nil {
            // Its view doesn't exist yet, so nothing reacts to the folder
            // changing (BrowserModelChanges): it's shown here.
            pane.model.location = first.model.location
            if let folder = first.model.folder { pane.startShowing(folder) }
            else { pane.navigation.visit(.computer) }
        } else {
            // The first pane's folder is still being looked up: the same one.
            pane.showNewWindowFolder()
        }
    }

    /// Hides the second pane. The active pane stays: if that was the second,
    /// it takes the first's place, and the first is the one kept hidden.
    func hideSecond() {
        guard isDual, let second else { return }
        if active === second {
            self.second = first
            first = second
        }
        isDual = false
        if active !== first { active = first }
        self.second?.stop()
    }
}
