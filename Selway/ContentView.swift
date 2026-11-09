import SwiftUI
import Quartz
import UniformTypeIdentifiers

/// A browser window: the sidebar, the toolbar and search field, and its pane
/// or two (BrowserPane, each showing a PaneState; PaneSplit lays them out),
/// with what acts for the whole window:
/// the menu commands, file operations and new items, sheets and errors, the
/// toast, and the window's place in BrowserWindowRouter.
///
/// A pane's changing state (folder, selection, listing) is in its `model`,
/// which this body never reads: the views that show it read what they show,
/// so a click re-renders only them, not the whole window (see BrowserModel).
/// Keep it that way: a `model.` read added here, in a computed property used
/// here, or in `.onChange(of:)` / `.navigationTitle`, re-renders everything on
/// each change again. Reads in closures that run later (actions, `onReceive`,
/// async work) are fine.
///
/// The same holds for a pane's searches (`searchEngine`, `tagService`): this
/// body doesn't observe them. PaneSearchChanges reacts to them, and the views
/// that show what they publish (BrowserSearch, FileBrowser, the status bar)
/// observe them, so typing a query or a Spotlight update doesn't re-render
/// the window. Don't pass their published values down from here as plain
/// values: they would never update.
///
/// Nor does it read which pane is active (`panes.active`): the sidebar,
/// title, search field, toolbar buttons and what the menus are told
/// (ActivePaneFocus) follow the active pane by looking it up in their own
/// bodies.
struct ContentView: View {
    @StateObject private var folderService = FolderCreationService()
    @StateObject private var fileOps       = FileOperationsService()
    /// The window's panes (PaneState): their models, histories and searches.
    /// The body reads only which panes are shown (`first`, `second`,
    /// `isDual`), which changes when the second is shown or hidden, never
    /// which is active (see above).
    @State private var panes               = BrowserPanes()
    @ObservedObject private var installed  = InstalledAppsService.shared
    @EnvironmentObject  var  favorites:      FavoritesService
    @Environment(\.openWindow) private var openWindow
    @Environment(\.textScale) private var textScale

    // Persisted browse prefs — Finder-like defaults on first launch
    @AppStorage(UserPreferences.viewModeKey)       private var viewModeRaw       = UserPreferences.defaultViewMode.rawValue
    @AppStorage(UserPreferences.sortFieldKey)      private var sortFieldRaw      = UserPreferences.defaultSortField.rawValue
    @AppStorage(UserPreferences.sortAscendingKey)  private var sortAscending     = UserPreferences.defaultSortAscending
    @AppStorage(UserPreferences.groupByKey)        private var groupByRaw        = UserPreferences.defaultGroupBy.rawValue
    @AppStorage(UserPreferences.folderOrderKey)    private var folderOrderRaw    = UserPreferences.defaultFolderOrder.rawValue
    @AppStorage(UserPreferences.showHiddenKey)     private var showHidden        = false
    @AppStorage(UserPreferences.showPreviewKey)    private var showPreview       = false
    @AppStorage(UserPreferences.showColumnTreeKey) private var showColumnTree    = false
    @AppStorage(UserPreferences.didShowFirstRunKey) private var didShowFirstRun  = false
    @AppStorage(UserPreferences.showPathBarKey)    private var showPathBar       = true
    @AppStorage(SettingsKeys.showStatusBar)        private var showStatusBar     = true
    @State private var searchKeyMonitor: Any?
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var showFirstRun = false
    @State private var errorMsg:     String?
    /// Go → Connect to Server…, or a saved server's row: the sheet.
    @State private var connectSheet: ConnectSheetRequest?
    /// File → Copy / Move to Other Pane (F5 / F6): the confirmation's sheet.
    @State private var paneTransfer: PaneTransferRequest?
    /// F5 / F6 reading the selection before they ask.
    @State private var paneTransferCheck = PaneTransferCheck()

    private var viewMode: ViewMode       { ViewMode.fromStorage(viewModeRaw) }
    private var sortField: SortField     { SortField.fromStorage(sortFieldRaw) }
    private var groupBy: GroupBy         { GroupBy.fromStorage(groupByRaw) }
    private var folderOrder: FolderOrder { FolderOrder.fromStorage(folderOrderRaw) }

    /// The id of the request this window was opened for (BrowserWindowRouter):
    /// nil when it wasn't asked for (File ▸ New Window), last session's when
    /// it was restored.
    let requestID: UUID?

    init(requestID: UUID? = nil) {
        self.requestID = requestID
    }

    // Window identity for BrowserWindowRouter and the directory watcher.
    @State private var windowID    = UUID()
    @State private var hostWindow  = WeakWindow()
    /// Whether this window has a tab to its right, for the Window menu.
    @State private var tabNeighbors = TabNeighborWatch()
    /// Whether onAppear has run: it can run again for the same window.
    @State private var lifecycle   = BrowserLifecycle()

    /// This window's menu-command actions: one stable object (see BrowserActions).
    @State private var browserActions = BrowserActions()
    /// What file operations call back when done (see BrowserReloadRelay).
    @State private var reloadRelay = BrowserReloadRelay()
    /// The window's toast, read only by ToastOverlay.
    @State private var toast = WindowToast()

    /// The terminal and IDE buttons open the folder selected in `pane`, else
    /// the folder it shows.
    private func toolFolder(in pane: PaneState) -> URL? {
        guard let item = pane.model.selectedItem, item.isBrowsableFolder else { return pane.model.folder }
        return item.url
    }

    /// New Folder and New Text File go into the folder the active pane shows,
    /// beside the selection, as in Finder (see ShellNewItemTarget).
    private var newItemDestination: URL? {
        panes.active.model.folder.map { ShellNewItemTarget.destination(showing: $0) }
    }

    /// ⌘V pastes into the folder `pane` shows, like Finder (see ShellPasteTarget).
    private func pasteDestination(in pane: PaneState) -> URL? {
        pane.model.folder.map { ShellPasteTarget.destination(showing: $0, clipboard: fileOps.pasteboardURLs) }
    }

    // Split out of `body` so each chained expression stays within the Swift
    // type-checker's complexity budget (adding more modifiers to one giant
    // expression triggers "unable to type-check in reasonable time").
    private var splitView: some View {
        NavigationSplitView {
            BrowserSidebar(panes: panes, go: { panes.active.go(to: $0) }, fileOps: fileOps, onReload: fileOpReload,
                           connect: { server in
                               // A click can reach the row twice (its tap and the list's
                               // selection): one sheet, on a window with none.
                               guard connectSheet == nil, hostWindow.window?.attachedSheet == nil else { return }
                               connectSheet = ConnectSheetRequest(saved: server)
                           },
                           connectNetwork: { server, purpose in
                               guard connectSheet == nil, hostWindow.window?.attachedSheet == nil else { return }
                               connectSheet = ConnectSheetRequest(network: server, networkPurpose: purpose)
                           })
                // Column limits rather than a frame: the split view then widens a
                // saved sidebar that's narrower than the minimum, instead of the
                // rows overflowing it.
                .navigationSplitViewColumnWidth(min: 180 * textScale, ideal: 220 * textScale)
                .background(ArrowCursorArea())   // resets cursor when leaving the sidebar divider
                .resetsCursorOnEnter()           // clears the divider's stuck resize cursor on entry
        } detail: {
            // The panes side by side. The first keeps its place, and its view's
            // state, when the second is shown beside it or hidden; it's rebuilt
            // only when another pane takes its place (BrowserPanes.hideSecond).
            PaneSplit(isDual: panes.isDual, split: panes.split) {
                paneView(panes.first, position: panes.isDual ? .first : nil)
                    .id(ObjectIdentifier(panes.first))
            } second: {
                if panes.isDual, let second = panes.second {
                    paneView(second, position: .second)
                }
            }
            .background(ArrowCursorArea())   // resets IBeam / resize cursor leaving search bar or column handles
            .resetsCursorOnEnter()           // clears the divider's stuck resize cursor on entry
            .overlay(alignment: .bottom) { FileOperationProgressStrip(fileOps: fileOps) }
            .animation(.easeOut(duration: 0.2), value: fileOps.activeOperation?.id)
            .overlay(alignment: .bottom) { ToastOverlay(toast: toast) }
            .toolbar(id: "browser") {
                BrowserToolbar(
                    actions:      browserActions,
                    panes:        panes,
                    apps:         installed.apps,
                    shownTools:   Set(OpenTool.allCases.filter(installed.apps.shows)),
                    fileOps:      fileOps
                )
            }
            .modifier(BrowserSearch(panes: panes,
                                    // After the field has finished with the Return.
                                    onSubmit: { DispatchQueue.main.async { focusResults() } }))
            // The active pane's folder, its name and icon in the title bar, as in Finder.
            .background(WindowTitle(panes: panes))
        }
        .frame(minWidth: 860, minHeight: 520)
        .background(QLResponderSetup())
        .background(WindowReader(immediately: { window in
            BrowserWindowRouter.shared.windowWillAttach(windowID, window: window)
        }) { window in
            hostWindow.window = window
            panes.attach(window)
            tabNeighbors.watch(window)
            BrowserWindowRouter.shared.attach(windowID, window: window)
            #if SELWAY_UI_TESTING
            UITestHooks.place(window)
            #endif
        })
        // Keyboard shortcuts (undo/redo, cut/copy/paste, select all, new folder,
        // hidden files, Quick Look) are menu commands that act on the key window
        // through these focused actions — see BrowserCommands.swift.
        .focusedSceneValue(\.browserActions, browserActions)
        // Edit ▸ Undo / Redo observe it for their titles and enabled state.
        .focusedSceneObject(fileOps)
        // View ▸ Show / Hide Dual Pane's title, and the items it disables.
        .focusedSceneValue(\.browserIsDual, panes.isDual)
        // Window ▸ Merge Tab into Dual Pane's enabled state.
        .focusedSceneValue(\.browserHasTabToRight, tabNeighbors.hasTabToRight)
        // Go ▸ Back / Forward and File ▸ Open, likewise: the active pane's
        // history and selection, published by a modifier that looks up the
        // active pane itself, so a pane switch doesn't re-render the window.
        .modifier(ActivePaneFocus(panes: panes, viewMode: viewMode))
        // What a drag of an icon or column row out to another app leaves to do.
        .environment(\.fileOperations, fileOps)
    }

    private var splitWithChanges: some View {
        splitView
        // ── Lifecycle ───────────────────────────────────────────────────
        .onAppear {
            UserPreferences.migrateBrowseDefaultsIfNeeded()
            let router = BrowserWindowRouter.shared
            router.openWindow = openWindow
            let panes = self.panes
            // Each pane shown, the active one first: external opens go to it,
            // and every pane on a volume that has gone leaves it.
            router.register(windowID, window: hostWindow.window) {
                panes.activeFirst.map { pane in
                    BrowserWindowRouter.Target(location: pane.model.location) { url in pane.go(to: url) }
                }
            }
            bindBrowserActions()
            // Every pane shown: the undo history keeps this relay with each step,
            // so an Undo refreshes whichever pane shows the folder it changed,
            // whichever was active when the operation began.
            reloadRelay.action = { panes.shown.forEach { $0.refreshAfterFileOp() } }
            InstalledAppsService.shared.detectInstalledApps()
            // onAppear can run again for the same window (a tab moved, say;
            // see `lifecycle`): one monitor per window, removed in onDisappear.
            if searchKeyMonitor == nil {
                searchKeyMonitor = ToolbarSearchField.installKeys(
                    window: { hostWindow.window },
                    toResults: { focusResults() },
                    clear: { panes.active.clearSearch() })
            }
            // Resolve the first tab request before starting panes so a moved
            // pane's new tab never starts with the remembered dual-pane layout.
            if !lifecycle.hasAppeared {
                lifecycle.hasAppeared = true
                let request = router.takeInitialRequest(for: windowID, requestID: requestID)
                if request.forcesSinglePane, panes.isDual { panes.hideSecond() }
                // The panes get their first location only after they have started.
                panes.start()
                panes.showFirstFolders(initial: request.location)
            } else {
                // A tab moved back into view gets its existing panes started
                // again with their folders and histories intact.
                panes.start()
            }
            if !didShowFirstRun {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    showFirstRun = true
                }
            }
        }
        // Which pane is on the left, for what isn't a view (BrowserPanes).
        // A backup opened in Finder meanwhile may have been mounted.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            panes.shown.filter { $0.model.backupUnavailable || $0.model.needsFullDiskAccess }.forEach { $0.reload() }
        }
        .onChange(of: layoutDirection, initial: true) { _, direction in panes.layoutDirection = direction }
        .onDisappear {
            BrowserWindowRouter.shared.unregister(windowID)
            // The panes' watches and live queries: an Entire Mac or tag search
            // would otherwise keep updating results for a window nobody can see.
            panes.stop()
            // Break the references that keep a closed window alive (menu actions,
            // undo steps' reload).
            browserActions.reset()
            reloadRelay.action = nil
            if let searchKeyMonitor { NSEvent.removeMonitor(searchKeyMonitor) }
            searchKeyMonitor = nil
        }
    }

    var body: some View {
        splitWithChanges
        // What the window's services did, for the panes. Subscribed here, once
        // per window, and handed to every pane showing the folder concerned: a
        // @Published value is sent again to each new subscriber, so a pane
        // subscribing itself (shown later, or rebuilt) would select the last
        // pasted item again.
        //
        // Folder/file created → select & scroll to it. Never navigates: going into
        // the folder it was made in took the user somewhere they hadn't asked to go.
        .onReceive(folderService.$lastCreatedURL.compactMap { $0 }) { url in
            for pane in panes.shown where pane.model.folder.map({ ShellNewItemTarget.selectsCreated(url, showing: $0) }) == true {
                pane.model.pendingSelectURLs = [url]   // resolved by the next reload
            }
            // Reloads the panes showing the parent, and any column pane showing
            // it, without waiting for the watcher.
            NotificationCenter.default.post(name: .refreshDirectory, object: url.deletingLastPathComponent())
        }
        .onReceive(fileOps.$lastOpURL.compactMap { $0 }) { url in
            let parent = url.deletingLastPathComponent()
            // Select a pasted / duplicated / renamed item when it lands here.
            for pane in panes.shown where ShellPath.same(parent, pane.model.folder) {
                pane.model.pendingSelectURLs = [url]
            }
            NotificationCenter.default.post(name: .refreshDirectory, object: parent)
        }
        // New items in one folder (dropped file promises): all selected when they land here.
        .onReceive(fileOps.$lastLandedURLs.compactMap { $0 }.filter { !$0.isEmpty }) { urls in
            let parent = urls[0].deletingLastPathComponent()
            for pane in panes.shown where ShellPath.same(parent, pane.model.folder) {
                pane.model.pendingSelectURLs = urls
            }
            NotificationCenter.default.post(name: .refreshDirectory, object: parent)
        }
        .onReceive(folderService.$errorMessage.compactMap      { $0 }) { msg in errorMsg = msg }
        .onReceive(fileOps.$errorMessage.compactMap            { $0 }) { msg in errorMsg = msg }
        .onReceive(fileOps.$lastActionFeedback.compactMap      { $0 }) { f in showToast(f) }
        // Items a Move to Trash couldn't take and the user kept: selected again.
        .onReceive(fileOps.$keptItems.compactMap { $0 }) { urls in
            panes.shown.forEach { $0.selectKept(urls) }
            fileOps.keptItems = nil
        }
        .onReceive(folderService.$lastActionFeedback.compactMap { $0 }) { f in showToast(f) }
        .sheet(isPresented: Binding(
            get: { errorMsg != nil },
            set: { if !$0 {
                errorMsg = nil
                folderService.errorMessage = nil
                fileOps.errorMessage = nil
            }}
        )) {
            ErrorReportSheet(message: errorMsg ?? "") {
                errorMsg = nil
                folderService.errorMessage = nil
                fileOps.errorMessage = nil
            }
        }
        .sheet(isPresented: $showFirstRun, onDismiss: {
            didShowFirstRun = true
        }) {
            FirstRunSheet(isPresented: $showFirstRun)
        }
        .sheet(item: $connectSheet) { request in
            ConnectToServerSheet(request: request, navigate: goFromChrome)
                .environmentObject(favorites)
        }
        .sheet(item: $paneTransfer) { request in
            PaneTransferSheet(plan: request.plan) {
                fileOps.drop(request.plan.sources, into: request.plan.destination, mode: request.plan.mode,
                             reload: fileOpReload)
            }
        }
    }

    // MARK: - Menu command actions (per window)

    /// Fills in this window's stable `BrowserActions` object. The closures
    /// look up the active pane, and read the settings, when they run, so
    /// they're set once rather than rebuilt (and republished to the menus) on
    /// every render. They don't read this view's @AppStorage: a closure made
    /// once would keep the value from that time (see BrowseSettings).
    private func bindBrowserActions() {
        let a = browserActions
        let panes = self.panes
        a.newFolder    = {
            guard panes.active.model.location.allows(.newFolder, readOnly: panes.active.model.isReadOnlyLocation) else { NSSound.beep(); return }
            promptAndCreateFolder()
        }
        a.toggleHidden = {
            UserDefaults.standard.set(!BrowseSettings.current.showHidden, forKey: UserPreferences.showHiddenKey)
        }
        a.undo         = { fileOps.undo() }
        a.redo         = { fileOps.redo() }
        a.cut = {
            let model = panes.active.model
            guard !model.isReadOnlyLocation,
                  !model.selectedURLs.contains(where: { TimeMachineBackups.isSnapshotPath($0) }) else { NSSound.beep(); return }
            let urls = model.selectedURLs
            if urls.isEmpty { NSSound.beep() } else { fileOps.cut(urls) }
        }
        a.copy = {
            let urls = panes.active.model.selectedURLs
            if urls.isEmpty { NSSound.beep() } else { fileOps.copy(urls) }
        }
        a.paste = {
            guard panes.active.model.location.allows(.paste, readOnly: panes.active.model.isReadOnlyLocation), let destination = pasteDestination(in: panes.active)
            else { NSSound.beep(); return }
            if fileOps.pasteboardURLs.isEmpty { NSSound.beep(); return }
            fileOps.paste(to: destination, reload: fileOpReload)
        }
        a.pasteHere = {
            guard panes.active.model.location.allows(.pasteHere, readOnly: panes.active.model.isReadOnlyLocation), let folder = panes.active.model.folder
            else { NSSound.beep(); return }
            if fileOps.pasteboardURLs.isEmpty { NSSound.beep(); return }
            fileOps.paste(to: folder, reload: fileOpReload)
        }
        a.selectAll = {
            NotificationCenter.default.post(name: .selectAllRequested, object: nil)
            panes.active.selectAll()
        }
        a.open = { panes.active.openSelection() }
        a.quickLook = {
            let urls = panes.active.model.selectedURLs
            if urls.isEmpty { NSSound.beep() } else { QuickLookController.shared.show(urls) }
        }
        a.canUndo = { fileOps.canUndo }
        a.canRedo = { fileOps.canRedo }
        a.goBack    = { panes.active.goBack() }
        a.goForward = { panes.active.goForward() }
        a.goUp      = { panes.active.goUp() }
        a.find = {
            guard panes.active.model.location.allows(.find, readOnly: panes.active.model.isReadOnlyLocation) else { NSSound.beep(); return }
            if !ToolbarSearchField.focus(in: hostWindow.window) { NSSound.beep() }
        }
        // With the path bar hidden, it's shown for this edit only and hides again
        // when the edit ends; the View / Settings choice stays off (ShellPathBarPresence).
        a.goToFolder = {
            let model = panes.active.model
            // Two panes always show their path bars.
            switch model.pathBarPresence.goToFolder(setting: BrowseSettings.current.showPathBar || panes.isDual) {
            case .openEditor:
                model.pathEditRequest += 1
            case .showBarThenEdit:
                // Not a bumped request: the bar would first appear with it already
                // bumped, and onChange doesn't fire for a view's initial value.
                model.pathEditPending = true
            }
        }
        // This window only; new windows and tabs follow the last choice.
        a.toggleDualPane = {
            panes.toggleDual()
            UserDefaults.standard.set(panes.isDual, forKey: UserPreferences.dualPaneKey)
        }
        a.mergeTabIntoDualPane = {
            // Not while the tab to merge has a sheet open (an error report, a
            // confirmation): closing it would throw that away unseen.
            guard let window = hostWindow.window, let right = BrowserWindowRouter.shared.tabToRight(of: window),
                  right.attachedSheet == nil,
                  let location = BrowserWindowRouter.shared.activeLocation(in: right),
                  panes.mergeTab(location: location) else { NSSound.beep(); return }
            BrowserWindowRouter.shared.closeTab(right)
        }
        a.moveOtherPaneToNewTab = {
            // The pane leaves only once a tab can be opened for it.
            guard let window = hostWindow.window, BrowserWindowRouter.shared.openWindow != nil,
                  let location = panes.moveOtherPaneToNewTab() else { NSSound.beep(); return }
            BrowserWindowRouter.shared.openNewTab(at: location, after: window)
        }
        a.connectToServer = {
            // One sheet at a time on a window.
            if hostWindow.window?.attachedSheet == nil { connectSheet = ConnectSheetRequest() } else { NSSound.beep() }
        }
        a.switchPane        = { panes.switchToOther() }
        a.widenPane         = { side in panes.split.widen(side) }
        a.equalizePanes     = { panes.split.equalize() }
        a.copyToOtherPane   = { transferToOtherPane(.copy) }
        a.moveToOtherPane   = { transferToOtherPane(.move) }
        a.newTextFile       = {
            guard panes.active.model.location.allows(.newTextFile, readOnly: panes.active.model.isReadOnlyLocation) else { NSSound.beep(); return }
            promptAndCreateFile()
        }
        a.moveToTrash       = { deleteSelected(.moveToTrash) }
        a.deletePermanently = { deleteSelected(.deletePermanently) }
        // The selection's paths, as the context menu's Copy Path and Finder's ⌥⌘C
        // copy them; the folder's only when nothing is selected.
        a.copyPath = {
            let model = panes.active.model
            guard model.location.allows(.copyPath, readOnly: model.isReadOnlyLocation) else { NSSound.beep(); return }
            if model.folder == nil {
                guard let url = panes.active.diskOverview.volumeURL(for: model.overviewSelection),
                      let text = ShellCopyPath.text(selected: [url], folder: nil) else { NSSound.beep(); return }
                fileOps.copyPath(text)
                return
            }
            guard let folder = model.folder else { NSSound.beep(); return }
            if let text = ShellCopyPath.text(selected: model.selectedURLs, folder: folder) {
                fileOps.copyPath(text)
            }
        }
        a.refresh  = {
            guard panes.active.model.location.allows(.refresh, readOnly: panes.active.model.isReadOnlyLocation) else { NSSound.beep(); return }
            fileOpReload()
        }
        a.openTool = { tool in
            guard panes.active.model.location.allows(.openInTool, readOnly: panes.active.model.isReadOnlyLocation), let folder = toolFolder(in: panes.active)
            else { NSSound.beep(); return }
            InstalledAppsService.shared.open(tool, at: folder) { message in
                fileOps.errorMessage = message
            }
        }
    }

    // MARK: - Navigation from outside the listing

    /// The path bar, sidebar or Connect to Server going somewhere (PaneState.go).
    private func goFromChrome(_ url: URL) {
        panes.active.go(to: url)
    }

    // MARK: - Pre-named creation dialogs

    // Show a name dialog BEFORE creating, so the item appears with the correct name immediately.
    // Created in the folder shown, never inside a selected folder (newItemDestination).

    func promptAndCreateFolder() {
        guard panes.active.model.location.allows(.newFolder, readOnly: panes.active.model.isReadOnlyLocation), let dest = newItemDestination else { NSSound.beep(); return }
        guard let name = NamePrompt.ask(title: String(localized: "New Folder in \"\(dest.lastPathComponent)\"", comment: "New folder prompt title with parent folder name"),
                                        message: String(localized: "Enter a name for the new folder:", comment: "New folder prompt instructions"),
                                        button: String(localized: "Create", comment: "Alert button to create a folder"), initial: DefaultNames.newFolder) else { return }
        folderService.createFolder(at: dest, name: name)
    }

    func promptAndCreateFile() {
        guard panes.active.model.location.allows(.newTextFile, readOnly: panes.active.model.isReadOnlyLocation), let dest = newItemDestination else { NSSound.beep(); return }
        guard let name = NamePrompt.ask(title: String(localized: "New File in \"\(dest.lastPathComponent)\"", comment: "New file prompt title with parent folder name"),
                                        message: String(localized: "Enter a name for the new file (include extension, e.g. notes.txt):", comment: "New file prompt instructions"),
                                        button: String(localized: "Create", comment: "Alert button to create a file"), initial: DefaultNames.untitledTextFile) else { return }
        folderService.createFile(at: dest, name: name)
    }

    // MARK: - Move to Trash / Delete Permanently

    /// The active pane's selection, trashed or deleted as Settings → Advanced
    /// says (DeleteFlow).
    func deleteSelected(_ command: FileOpsDeleteCommand) {
        let model = panes.active.model
        guard !model.isReadOnlyLocation else { NSSound.beep(); return }
        let urls = model.selectedURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        if DeleteFlow.run(command, urls: urls, fileOps: fileOps, reload: fileOpReload) {
            model.selectedIDs = []
        }
    }

    // MARK: - Copy / Move to Other Pane

    /// F5 / F6: asks to copy or move the active pane's selection into the
    /// folder the other pane shows, then does it as a drop does (progress,
    /// free names for clashes, Undo), refreshing every pane through the
    /// window's relay. When there's nothing to do it beeps and says why in
    /// the toast, which VoiceOver reads (ShellPaneTransfer); when the window
    /// already shows a sheet it only beeps: a key held down would ask again.
    ///
    /// The selection is the pane's, as ⌘C copies it: in Columns view a folder
    /// selected in a column is shown as the next column and leaves the pane's
    /// selection empty, so neither ⌘C nor F5 / F6 take it.
    ///
    /// Deciding reads the disk (each item, and the folders above them), so it
    /// runs off the main thread: a big selection, or a server slow to answer,
    /// would freeze the window. If the panes change meanwhile (another folder,
    /// selection or active pane, or one hidden), another sheet comes up, or the
    /// window closes or its tab is left (its panes stopped), it beeps instead
    /// of asking about what's no longer shown.
    private func transferToOtherPane(_ mode: FileOpsTransfer.Mode) {
        let check = paneTransferCheck
        guard paneTransfer == nil, !check.isRunning, hostWindow.window?.attachedSheet == nil
        else { NSSound.beep(); return }
        let source = panes.active
        let model = source.model
        let otherPane = panes.other(than: source)
        let destination = otherPane?.model.folder
        let destinationAllowsTransfer = otherPane?.model.location.allows(.transferInto, readOnly: otherPane?.model.isReadOnlyLocation ?? false) == true
        let selected = model.selectedURLs
        // Nothing moves out of a Time Machine backup (read-only); copying does.
        if mode == .move, model.isReadOnlyLocation || selected.contains(where: { TimeMachineBackups.isSnapshotPath($0) }) {
            NSSound.beep(); return
        }
        // A pane at the computer has nothing selected: refused with its toast.
        if let refusal = ShellPaneTransfer.refusalBeforeReading(isDual: panes.isDual, selected: selected,
                                                                hasFolderDestination: destinationAllowsTransfer) {
            refuse(refusal, mode: mode, destination: destination)
            return
        }
        guard let folder = model.folder else { NSSound.beep(); return }
        guard let destination else { return }
        let searching = source.isSearchActive
        check.isRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let decision = ShellPaneTransfer.decide(mode, isDual: true, selected: selected, from: folder,
                                                    into: destination, searching: searching)
            DispatchQueue.main.async {
                check.isRunning = false
                guard source.isStarted, hostWindow.window?.attachedSheet == nil, panes.active === source,
                      model.selectedURLs == selected,
                      ShellPath.same(folder, model.folder),
                      panes.other(than: source).map({ ShellPath.same($0.model.folder, destination) }) == true
                else { NSSound.beep(); return }
                switch decision {
                case .confirm(let plan):
                    paneTransfer = PaneTransferRequest(plan: plan)
                case .refuse(let refusal):
                    refuse(refusal, mode: mode, destination: destination)
                }
            }
        }
    }

    /// F5 / F6 can't run: a beep, and the toast says why.
    private func refuse(_ refusal: ShellPaneTransfer.Refusal, mode: FileOpsTransfer.Mode, destination: URL?) {
        NSSound.beep()
        showToast(ActionFeedback(icon: "exclamationmark.circle",
                                 message: ShellPaneTransfer.refusalMessage(refusal, mode: mode,
                                                                           destination: destination)))
    }

    // MARK: - Panes

    /// `pane` as shown, with the window's services and the settings as values.
    /// No closures: they never compare equal, so the pane would re-render
    /// whenever the window does. Beside another pane (a `position`), each
    /// shows its own path bar and status bar, whatever the settings, so its
    /// folder and counts are always in sight; the preview panel is left out.
    private func paneView(_ pane: PaneState, position: PanePosition?) -> some View {
        let dual = position != nil
        return BrowserPane(pane: pane, panes: panes, position: position, fileOps: fileOps,
                           reloadRelay: reloadRelay, favorites: favorites,
                           viewMode: viewMode, groupBy: groupBy, sortField: sortField, sortAscending: sortAscending,
                           folderOrder: folderOrder, showHidden: showHidden, showColumnTree: showColumnTree,
                           showPreview: showPreview && !dual, showPathBar: showPathBar || dual,
                           showStatusBar: showStatusBar || dual)
    }

    // MARK: - Helpers

    /// Gives the active pane's file list keyboard focus (Return / ↓ / Escape in
    /// the search field; PaneState.focusResults).
    private func focusResults() {
        panes.active.focusResults(rightToLeft: layoutDirection == .rightToLeft)
    }

    // MARK: - Toast

    /// The toast, which VoiceOver also announces ("Moved 2 items to the Trash"):
    /// it is the only sign some actions give. Once per window, whichever pane
    /// the action was in.
    private func showToast(_ feedback: ActionFeedback) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            toast.item = ToastPayload(icon: feedback.icon, message: feedback.message)
        }
        NSAccessibility.post(element: hostWindow.window ?? NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: feedback.message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// `refreshAfterFileOp` on every pane, through this window's relay, for
    /// operations that keep their callback (see BrowserReloadRelay).
    private var fileOpReload: () -> Void {
        let relay = reloadRelay
        return { relay() }
    }
}

// MARK: - Window chrome
//
// Each follows the active pane, looked up in its own body, and reads from its
// model only what it shows, so it updates on its own when that changes and
// ContentView's body doesn't run (see BrowserModel).

/// The sidebar, following the active pane's folder. Its highlight is its own state.
private struct BrowserSidebar: View {
    let panes: BrowserPanes
    /// Goes to a folder, or the computer, picked here (PaneState.go).
    let go: (BrowserLocation) -> Void
    /// For files dropped on a sidebar folder.
    let fileOps: FileOperationsService
    let onReload: () -> Void
    /// Connects to a saved server that isn't connected (its row was chosen).
    let connect: (SavedServer) -> Void
    /// Looks up a server under Network to connect to it or save it (its row
    /// or its menu was chosen).
    let connectNetwork: (NetworkServer, ConnectSheetRequest.NetworkPurpose) -> Void
    @State private var selection: SidebarItem?

    var body: some View {
        let model = panes.active.model
        SidebarView(location: Binding(get: { model.location }, set: go),
                    selection: $selection,
                    activeTagFilter: Bindable(model).activeTagFilter,
                    usedTags: model.usedTags,
                    fileOps: fileOps, onReload: onReload, onConnect: connect, onConnectNetwork: connectNetwork)
    }
}

/// The folder's name and icon in the title bar, as in Finder. A view of its
/// own: `.navigationTitle` reads the folder, and on ContentView that re-rendered
/// the window on every navigation.
private struct WindowTitle: View {
    let panes: BrowserPanes

    var body: some View {
        let location = panes.active.model.location
        let name = location.displayName
        Group {
            if let path = location.folder {
                Color.clear.navigationTitle(name).navigationDocument(path)
            } else {
                Color.clear.navigationTitle(name)
            }
        }
    }
}

/// A browser window's toast ("Moved 2 items to the Trash"). The window's, not
/// a pane's: what shows one (file operations, new items, Copy Path) acts for
/// the window, and VoiceOver should hear it once. @Observable, so that only
/// ToastOverlay, which reads it, re-renders when it comes and goes.
@Observable
final class WindowToast {
    var item: ToastPayload?
}

private struct ToastOverlay: View {
    let toast: WindowToast
    @Environment(\.textScale) private var textScale

    var body: some View {
        ZStack {
            if let item = toast.item {
                InAppToast(icon: item.icon, message: item.message)
                    .padding(.bottom, 42 * textScale)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal:   .opacity
                    ))
                    .allowsHitTesting(false)
                    .id(item.id)
                    .onAppear {
                        let captured = item.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation(.easeOut(duration: 0.25)) {
                                if toast.item?.id == captured { toast.item = nil }
                            }
                        }
                    }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toast.item?.id)
    }
}

/// Opens files where `ShellOpenTarget` says, and says when a link's
/// target couldn't be reached.
enum FileOpener {
    /// In Selway's Markdown reader or editor, or its app. Known types are
    /// decided by name; anything else was sniffed already (`target`).
    @MainActor
    static func open(_ url: URL, as target: ShellOpenTarget) {
        switch target {
        case .markdown:      MarkdownWindowManager.shared.open(url)
        case .editor:        EditorWindowManager.shared.open(url)
        case .app, .folder:  NSWorkspace.shared.open(url)
        case .unreachable:   showUnreachable([url.lastPathComponent])
        }
    }

    /// On the key browser window, as a sheet; otherwise app-modal (as an
    /// eject that fails is reported).
    @MainActor
    static func showUnreachable(_ names: [String]) {
        let text = ShellOpenTarget.unreachableAlert(names: names)
        let alert = NSAlert()
        alert.alertStyle      = .warning
        alert.messageText     = text.title
        alert.informativeText = text.detail
        let window = [NSApp.keyWindow, NSApp.mainWindow].lazy.compactMap { $0 }
            .first { BrowserWindowRouter.shared.isBrowserWindow($0) && $0.attachedSheet == nil }
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension ShellOpenResolver {
    /// A browser window's. Under the UI tests each follow can be made to
    /// wait, as for an unreachable host, until the test lets it answer
    /// (UITestHooks.linkFollowGate; at most a minute).
    static func forWindow() -> ShellOpenResolver {
        #if SELWAY_UI_TESTING
        if let gate = UITestHooks.linkFollowGate {
            return ShellOpenResolver(follow: { item in
                let deadline = Date(timeIntervalSinceNow: 60)
                while !FileManager.default.fileExists(atPath: gate), Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                return ShellOpenTarget.following(item.url)
            })
        }
        #endif
        return ShellOpenResolver()
    }
}

// MARK: - In-app toast view

struct InAppToast: View {
    let icon:    String
    let message: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.primary)
            Text(message)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

// MARK: - File preview panel (right sidebar)
// Uses native QLPreviewView (same engine as macOS Finder's preview column)

struct FilePreviewPanel: View {
    let item: FileItem?
    @Environment(\.textScale) private var textScale

    var body: some View {
        VStack(spacing: 0) {
            if let item {
                Group {
                    if item.isLinkNotFollowed {
                        UnfollowedLinkPreview()
                    } else {
                        QLSidebarPreview(url: item.url)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        FileIconView(item: item, size: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .scaledFont(size: 12, weight: .semibold).lineLimit(2)
                            TagDotsView(colors: item.tagColors, names: item.spokenTagNames, size: 10)
                        }
                    }
                    Divider()
                    detailRow("Kind:",     item.kind)
                    if !item.isDirectory { detailRow("Size:", item.formattedSize) }
                    detailRow("Modified:", item.formattedDateModified)
                    detailRow("Created:",  item.formattedDateCreated)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.magnifyingglass")
                        .scaledFont(size: 36).foregroundStyle(.secondary)
                    Text("Select a file\nto preview")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    private func detailRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label).scaledFont(.caption).foregroundStyle(.secondary)
                .frame(width: 52 * textScale, alignment: .leading)
            Text(value).scaledFont(.caption).lineLimit(2)
        }
    }
}

/// What the preview shows for a link the listing didn't follow (FileItem.load):
/// a preview reads the file it leads to, which would mount it.
struct UnfollowedLinkPreview: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(for: .symbolicLink))
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("Link not previewed:\nQuick Look or Open follows it")
                .scaledFont(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("unfollowedLinkPreview")
    }
}

// MARK: - Native QL preview (mirrors Finder's preview panel)
// QLPreviewView must be created after the view enters the window hierarchy —
// creating it with a zero frame or before a window exists silently produces nothing.

struct QLSidebarPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> _QLSidebarHost { _QLSidebarHost() }
    func updateNSView(_ host: _QLSidebarHost, context: Context) { host.show(url) }
}

final class _QLSidebarHost: NSView {
    private var qlView: QLPreviewView?
    private var pendingURL: URL?
    private var releaseObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        observeEjects()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeEjects()
    }

    deinit {
        if let releaseObserver { NotificationCenter.default.removeObserver(releaseObserver) }
    }

    /// A preview of a PDF or a sound keeps its file open, which stops its
    /// volume ejecting: it's dropped when an eject finds the volume busy. The
    /// URL is forgotten too, so the next update shows it again if the volume
    /// stayed (another app was using it).
    private func observeEjects() {
        releaseObserver = NotificationCenter.default.addObserver(
            forName: .releaseVolume, object: nil, queue: .main) { [weak self] note in
                guard let self, let volume = note.object as? URL, let url = self.pendingURL,
                      ShellPath.isSameOrInside(url, volume) else { return }
                self.qlView?.previewItem = nil
                self.pendingURL = nil
            }
    }

    /// Called from every `updateNSView`. Only hand QLPreviewView a new item when
    /// the URL actually changes — resetting `previewItem` on unrelated re-renders
    /// (selection, toasts, hover) restarted the preview and flickered.
    func show(_ url: URL) {
        if let ql = qlView {
            guard url != pendingURL else { return }
            pendingURL = url
            ql.previewItem = url as NSURL
        } else {
            pendingURL = url
            setupQL()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { setupQL() }
    }

    override func layout() {
        super.layout()
        qlView?.frame = bounds
    }

    private func setupQL() {
        guard window != nil, qlView == nil else { return }
        // Use a concrete initial frame; zero frame produces a blank view.
        let frame = bounds.isEmpty ? NSRect(x: 0, y: 0, width: 260, height: 300) : bounds
        guard let ql = QLPreviewView(frame: frame, style: .normal) else { return }
        ql.autoresizingMask = [.width, .height]
        ql.autostarts = true
        ql.shouldCloseWithWindow = false
        addSubview(ql)
        qlView = ql
        if let url = pendingURL {
            ql.previewItem = url as NSURL
        }
    }
}

// MARK: - Arrow cursor catch-all
//
// Place this as .background() on any region that should show the default arrow cursor
// when nothing else has claimed it (file list, sidebar list, toolbar, etc.).
//
// Uses NSTrackingArea with .cursorUpdate. AppKit's rule: if a cursor rect is active
// at the mouse position (text field → IBeam, resize handle → resizeLeftRight, the
// NavigationSplitView divider → resizeLeftRight), that cursor rect takes priority and
// cursorUpdate(with:) is NOT called. In every other area the tracking area fires
// cursorUpdate(with:) and we reset to arrow — which clears any IBeam or resize cursor
// that the previous area set via NSCursor.set() rather than via a cursor rect.
//
// hitTest returns nil so this transparent layer never intercepts clicks or drags.

struct ArrowCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> _ArrowCursorAreaView { _ArrowCursorAreaView() }
    func updateNSView(_ v: _ArrowCursorAreaView, context: Context) {}
}

final class _ArrowCursorAreaView: NSView {
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        guard !bounds.isEmpty else { return }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

// MARK: - Cursor reset on exit
//
// A zero-cost transparent layer that forces the cursor back to the default arrow
// the instant the pointer LEAVES its bounds. Apply to any view that hands the
// cursor to a child which sets a non-default cursor (text fields → I-beam) so the
// cursor never "sticks" after the pointer moves on.
//
// Why this exists alongside ArrowCursorArea: the catch-all above resets via a
// .cursorUpdate tracking area placed as a .background(), which the front-most
// AppKit table/list views occlude — so leaving a text field onto the file list
// would not fire it and the I-beam would persist. This uses geometry-based
// .mouseEnteredAndExited on the field itself, which fires the moment the pointer
// crosses the field boundary regardless of what is in front of it.
//
// hitTest returns nil so it never intercepts clicks, drags, or text selection.

struct CursorResetOnExit: NSViewRepresentable {
    func makeNSView(context: Context) -> _CursorResetView { _CursorResetView() }
    func updateNSView(_ v: _CursorResetView, context: Context) {}
}

final class _CursorResetView: NSView {
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        guard !bounds.isEmpty else { return }
        // No .enabledDuringMouseDrag — we must not reset to arrow mid text-selection
        // drag; we only care about a plain pointer move leaving the field.
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

extension View {
    /// Forces the cursor back to the default arrow the moment the pointer leaves
    /// this view. Use on text fields so the I-beam never sticks after moving away.
    func resetsCursorOnExit() -> some View { background(CursorResetOnExit()) }
}

// MARK: - Cursor reset on enter
//
// Sibling of CursorResetOnExit, but fires on ENTER. This exists specifically for
// the NavigationSplitView divider: the divider sets a resize cursor while hovered,
// and when the pointer moves off it onto a pane the divider's cursor would stick.
// The existing .cursorUpdate catch-all (ArrowCursorArea) can't clear it because the
// pane's List/Table is painted in front and steals the cursorUpdate. A geometry
// based .mouseEntered fires the instant the pointer crosses into the pane regardless
// of what is in front, so the stale resize cursor is released immediately.
//
// We only reset on ENTER (not exit) so internal cursors — text-field I-beams, the
// column resize handles — are left untouched; those views manage their own cursor
// once the pointer is already inside the pane.

struct CursorResetOnEnter: NSViewRepresentable {
    func makeNSView(context: Context) -> _CursorResetOnEnterView { _CursorResetOnEnterView() }
    func updateNSView(_ v: _CursorResetOnEnterView, context: Context) {}
}

final class _CursorResetOnEnterView: NSView {
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        guard !bounds.isEmpty else { return }
        // No .enabledDuringMouseDrag — while the user is actively dragging the
        // divider we must keep the resize cursor; we only reset once the drag is
        // over and the pointer moves into the pane.
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

extension View {
    /// Forces the cursor back to the default arrow the moment the pointer enters
    /// this view. Use on split-view panes so the divider's resize cursor never
    /// sticks after the pointer moves off the divider onto the pane.
    func resetsCursorOnEnter() -> some View { background(CursorResetOnEnter()) }
}
