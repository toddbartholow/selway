import Foundation
import Observation

// MARK: - A browser window's changing state

/// What a browser window shows that changes from click to click: the folder,
/// the selection, the listing and the search and tag results behind it.
///
/// Observed property by property. When it lived in ContentView's `@State`,
/// every change re-rendered the whole window (sidebar, path bar, toolbar, file
/// list, preview, status bar), about 50 ms for a click that only selected a
/// row. Now ContentView's body reads none of it: each part of the window reads
/// what it shows, and only those parts update. Properties nothing shows are
/// `@ObservationIgnored`, so setting them updates nothing.
///
/// The rules for when these change (navigation, reloads, searches) are in
/// PaneState with the services they use; this holds the state and builds the
/// display list from it.
@Observable
@MainActor
final class BrowserModel {
    /// The location this pane shows. A new pane starts at Home until its folder is known.
    var location: BrowserLocation = .folder(FileManager.default.homeDirectoryForCurrentUser)
    var folder: URL? { location.folder }
    /// Set by the background listing load. Avoids re-reading snapshot metadata
    /// from menu validation and per-row write checks.
    var isReadOnlyLocation = false
    /// The Time Machine disk's root the pane shows or is inside, read-only,
    /// for the column browser, whose columns show folders above the pane's.
    var timeMachineRoot: URL?
    var backupUnavailable = false
    /// A Time Machine disk or backup that only an app with Full Disk Access may read.
    var needsFullDiskAccess = false
    /// The folder whose listing set the two above. They hold until the pane
    /// reacts to a new location, so a note is shown only for this folder.
    var backupNoteFolder: URL?

    /// Setting an equal selection notifies no one: every navigation clears it,
    /// usually when it is already empty. Observed by hand because the
    /// `@Observable` macro skips equal values only from Swift 6.2 on, and
    /// Package.swift lets older compilers build Core, where each set would notify.
    var selectedIDs: Set<String> {
        get {
            access(keyPath: \.selectedIDs)
            return selection
        }
        set {
            guard newValue != selection else { return }
            // From the stored set, not the observed hasSelection getter, so a
            // write inside a tracking scope doesn't start tracking hasSelection.
            let had = !selection.isEmpty
            withMutation(keyPath: \.selectedIDs) { selection = newValue }
            let any = !newValue.isEmpty
            if had != any { hasSelection = any }
        }
    }
    @ObservationIgnored private var selection: Set<String> = []
    /// The selected disk overview tile. It is separate from file selection:
    /// mounted volume IDs must never be treated as files in a folder listing.
    var overviewSelection: String?
    /// The tile opened from the overview, for restoring when Back returns there.
    var rememberedOverviewSelection: String?
    /// Not the count: selecting more items needn't update what only cares
    /// whether there's a selection (the toolbar's delete buttons). Set only
    /// when it changes (see `selectedIDs`).
    private(set) var hasSelection = false

    // MARK: Listing

    /// The folder's items, sorted, as last loaded.
    private(set) var rawFiles: [FileItem] = []
    /// Search results turned into items (PaneState.convertSearchResults).
    var searchDisplayFiles: [FileItem] = []
    /// Spotlight's matches for `activeTagFilter`, turned into items.
    var tagDisplayFiles: [FileItem] = []
    var activeTagFilter: SidebarTag?

    // What the browser shows, derived from rawFiles / search / tag results. Cached
    // and rebuilt by `refreshDisplay` when an input changes: computing it in a
    // view's body re-filtered and re-sorted 10k-item folders several times per render.
    private(set) var displayFiles: [FileItem] = []
    private(set) var displayIndex: [String: Int] = [:]
    /// Bumps on every rebuild; child views key caches on it.
    private(set) var displayVersion: UInt = 0
    /// Tags used by items in the current folder, with their colours, for the
    /// sidebar's Tags section (which adds the colour tags and the Mac's others).
    private(set) var usedTags: [FileTag] = []

    // MARK: Search status

    /// Search results are being turned into list items; until then the list
    /// still holds the previous ones.
    var convertingResults = false
    /// The search (query and scope) whose results the list last showed. A
    /// conversion for the same search (a live Spotlight update, a pruned result,
    /// a re-sort) keeps showing its count rather than "Searching…".
    var listedSearch: String?

    // MARK: Requests to the views

    /// An item to start renaming in the list once it shows up.
    var pendingRenameURL: URL?
    /// True while an inline rename is open; watcher reloads wait meanwhile.
    var inlineRenameActive = false
    /// Bumped by Go → Go to Folder… to open the path bar's editor.
    var pathEditRequest = 0
    /// Go to Folder… with the path bar hidden: the bar opens its editor once it appears.
    var pathEditPending = false
    /// The path bar shown for one Go to Folder… edit while the setting hides it.
    var pathBarPresence = ShellPathBarPresence()
    /// Bumped to give the icon grid keyboard focus (PaneState.focusResults).
    var listFocusRequest = 0
    /// Bumped by Edit → Select All in Columns view: the focused column selects everything.
    var columnSelectAllRequest = 0
    /// Bumped by File → Open in Columns view: the focused column opens its selection.
    var columnOpenRequest = 0
    /// The column File → Open acts on has something selected (Columns view,
    /// where selecting a folder leaves the window's selection empty).
    var columnHasSelection = false

    // MARK: Opening

    /// The name of the link being followed to open it (ShellOpenResolver),
    /// for the status bar; nil when nothing is waiting.
    private(set) var openingLinkName: String?
    /// Decides which items being opened are folders, following links the
    /// listing didn't follow off the main thread. One per window: a newer open
    /// replaces one still waiting.
    @ObservationIgnored let openResolver: ShellOpenResolver

    init(openResolver: ShellOpenResolver = ShellOpenResolver()) {
        self.openResolver = openResolver
        openResolver.onPendingChange = { [weak self] pending in self?.openingLinkName = pending?.name }
    }

    // MARK: Bookkeeping nothing shows

    /// Items to select once a reload lists them (a folder just created, a paste,
    /// files selected in another column of the column browser).
    @ObservationIgnored var pendingSelectURLs: [URL] = []
    /// A folder selected in the column browser, shown without a Back step.
    @ObservationIgnored var quietNavigation: URL?
    /// A search finished; VoiceOver hears the count once its results are listed.
    @ObservationIgnored var announceResults = false

    // "Latest request wins" tokens for background work, so an older load or
    // search conversion finishing late can't overwrite newer results.
    /// Loads of the folder's listing, full or patched (ShellListingPatch).
    @ObservationIgnored var listingLoads = ShellListingLoads()
    /// Conversions of the search results into items, and patches of results
    /// changed in place, with the changes waiting for them or for a rename.
    @ObservationIgnored var searchLoads = SearchResultLoads()
    @ObservationIgnored var tagGeneration    = ShellGeneration()

    /// Watcher-driven reloads wait while an inline rename is being typed.
    @ObservationIgnored var reloadGate = ShellReloadGate()
    /// Watcher-driven re-runs of a folder search (debounced, held during an inline rename).
    @ObservationIgnored var searchRefresh = SearchRefreshThrottle()
    /// The folder the directory watcher is holding for this window.
    @ObservationIgnored var watchedPath: URL?

    // MARK: Derived

    /// The first selected item, for the preview panel.
    var selectedItem: FileItem? {
        guard let id = selectedIDs.first, let i = displayIndex[id], displayFiles.indices.contains(i) else { return nil }
        return displayFiles[i]
    }

    var selectedURLs: [URL] {
        displayFiles.filter { selectedIDs.contains($0.id) }.map(\.url)
    }

    /// Identifies a search (its scope and query) for `listedSearch`.
    nonisolated static func searchKey(scope: SearchScope, query: String) -> String {
        scope.rawValue + "\u{0}" + query
    }

    /// The listed item at `url`, compared by path.
    func displayedItem(at url: URL) -> FileItem? {
        let key = ShellPath.key(url)
        return displayFiles.first { ShellPath.key($0.url) == key }
    }

    // MARK: Building the display list

    /// Replaces the folder's items. Call `refreshDisplay` afterwards.
    func setRawFiles(_ items: [FileItem]) {
        rawFiles = items
        // The sidebar lists these even before its Mac-wide scan finds them. When
        // a tag is tapped, TagService searches Mac-wide via Spotlight.
        let tags = FileTag.distinct(items.flatMap(\.tags))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if tags != usedTags { usedTags = tags }
    }

    /// Rebuilds `displayFiles` from the current inputs. Call after changing
    /// rawFiles, search / tag results, the query or the tag filter.
    /// `hasSearchResults` is whether the engine has results for `query` yet;
    /// until it does, the folder's own items are filtered by name.
    func refreshDisplay(query: String, hasSearchResults: Bool,
                        sortField: SortField, ascending: Bool, folderOrder: FolderOrder) {
        let files: [FileItem]
        if let tag = activeTagFilter {
            // Tag filter: Mac-wide Spotlight matches UNION current-folder items carrying
            // the color. The local pass is what guarantees correctness — Spotlight only
            // finds files with a real kMDItemUserTags value, while the local match also
            // catches files that only have the legacy color label (kMDItemFSLabel), which
            // Spotlight cannot search. So tagged items in the folder you're viewing always
            // appear, regardless of how they were tagged.
            let tagged = mergedTagResults(for: tag, sortField: sortField, ascending: ascending,
                                          folderOrder: folderOrder)
            files = query.isEmpty ? tagged
                : tagged.filter { SearchMatcher.matches(name: $0.name, query: query) }
        } else if !query.isEmpty {
            // Search results are pre-computed into searchDisplayFiles to avoid
            // calling FileItem.load(from:) on every render.
            files = hasSearchResults
                ? searchDisplayFiles
                : rawFiles.filter { SearchMatcher.matches(name: $0.name, query: query) }
        } else {
            files = rawFiles
        }

        var index: [String: Int] = [:]
        index.reserveCapacity(files.count)
        for (i, f) in files.enumerated() where index[f.id] == nil { index[f.id] = i }

        displayFiles = files
        displayIndex = index
        displayVersion &+= 1
        if let kept = ShellDisplayList.pruned(selection: selectedIDs, visible: Set(index.keys)) {
            selectedIDs = kept
        }
    }

    // Spotlight (Mac-wide) results unioned with current-folder color matches, deduped
    // and sorted. The local match covers items that only carry the legacy color
    // label, which Spotlight can't find.
    private func mergedTagResults(for tag: SidebarTag, sortField: SortField, ascending: Bool,
                                  folderOrder: FolderOrder) -> [FileItem] {
        let local = rawFiles.filter(tag.matches)
        let merged = BrowserModel.mergedTagItems(local: local, spotlight: tagDisplayFiles)
        return sortedItems(merged, by: sortField, ascending: ascending, folderOrder: folderOrder)
    }

    /// The folder's own matches, then Spotlight's that aren't among them.
    ///
    /// Spotlight reports real paths, while the folder lists the path the user
    /// opened, so in a folder reached through a symlink (a ~/Downloads that
    /// links to another volume) the same item has two paths and showed twice.
    /// A local item counts under both its path and its resolved one, so it
    /// matches Spotlight's either way, and it's the one kept, so the list stays
    /// in the user's terms. Resolving costs one realpath per local match.
    ///
    /// A link the listing didn't follow (`isLinkNotFollowed`) isn't followed
    /// here either: only its folder is resolved, the one just listed, which
    /// gives the link's own real path (Spotlight would report the link there).
    nonisolated static func mergedTagItems(local: [FileItem], spotlight: [FileItem],
                               realPath: (URL) -> URL? = ModelPaths.realPath) -> [FileItem] {
        var seen = Set<String>()
        for item in local {
            seen.insert(ShellPath.key(item.url))
            let real = item.isLinkNotFollowed
                ? realPath(item.url.deletingLastPathComponent()).map { $0.appendingPathComponent(item.url.lastPathComponent) }
                : realPath(item.url)
            if let real { seen.insert(ShellPath.key(real)) }
        }
        return local + spotlight.filter { seen.insert(ShellPath.key($0.url)).inserted }
    }

    /// Spotlight's matches for a tag as items, those inside `folder` shown
    /// under its path rather than its real one (see `mergedTagItems`). Reads
    /// each file, so call it off the main thread.
    nonisolated static func tagResultItems(_ urls: [URL], shownUnder folder: URL) -> [FileItem] {
        let real = ModelPaths.realPath(folder)
        return urls.compactMap { url in
            guard let real, ShellPath.key(real) != ShellPath.key(folder) else { return FileItem.load(from: url) }
            let shown = ModelPaths.rebase(url, from: real, to: folder)
            return FileItem.load(from: url, shownAs: ShellPath.same(shown, url) ? nil : shown)
        }
    }
}

// MARK: - Toast payload

struct ToastPayload: Equatable {
    let id      = UUID()
    let icon:    String
    let message: String
    static func == (l: ToastPayload, r: ToastPayload) -> Bool { l.id == r.id }
}
