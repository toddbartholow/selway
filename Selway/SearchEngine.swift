import Foundation
import Combine

// Extract file URLs from a finished NSMetadataQuery.
//
// IMPORTANT: NSMetadataItemURLKey ("kMDItemURL") frequently comes back nil for
// Spotlight results (verified on this system), which silently dropped every match
// when used with compactMap. kMDItemPath is reliably populated, so prefer it and
// fall back to the URL key only if the path is somehow missing.
func metadataQueryURLs(_ q: NSMetadataQuery) -> [URL] {
    (0..<q.resultCount).compactMap { i -> URL? in
        guard let item = q.result(at: i) as? NSMetadataItem else { return nil }
        if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
            return URL(fileURLWithPath: path)
        }
        return item.value(forAttribute: NSMetadataItemURLKey) as? URL
    }
}

/// Drives the search bar. Every `search` / `clear` bumps `generation` and tears
/// down whatever was running (local task or Spotlight query), and results are
/// only published by work started under the current generation — so a slow,
/// superseded search can't overwrite newer results, and a cleared Mac-wide
/// query can't keep feeding hits that Trash / Delete would then act on.
class SearchEngine: ObservableObject {
    @Published var query          = ""
    @Published var results:   [URL] = []
    /// Starts at Settings → Advanced → Search in (This Folder unless changed).
    @Published var selectedScope: SearchScope = SearchScope.defaultScope()
    @Published var isSearching    = false
    /// Bumped when a folder walk finished but files changed while it ran. The
    /// view re-runs the search for it through its refresh throttle, which holds
    /// the run while an inline rename is open; the engine doesn't start it.
    @Published private(set) var staleWalks = 0

    private var metadataQuery:      NSMetadataQuery?
    private var spotlightObservers: [NSObjectProtocol] = []
    private var searchTask:         Task<Void, Never>?
    /// Generation / origin bookkeeping (Core, tested).
    private var run = SearchRunState()
    /// Watcher refreshes of a folder search that is still walking (Core, tested).
    private var rerun = SearchRerunState()

    /// Search `directory` (the selected scope's base folder) for `query`.
    /// `showHidden` follows the toolbar's Show Hidden Files toggle (local scopes only;
    /// Spotlight doesn't index hidden files). Call on the main thread.
    func search(in directory: URL, showHidden: Bool) {
        rerun.reset()
        start(in: directory, showHidden: showHidden)
    }

    /// Re-runs the search because files changed on disk. Unlike `search`, it
    /// never cancels a folder walk that is still running (in a busy folder the
    /// search would otherwise never finish); once it is done, `staleWalks`
    /// asks for one more run.
    func refresh(in directory: URL, showHidden: Bool) {
        guard rerun.requestRefresh() else { return }
        start(in: directory, showHidden: showHidden)
    }

    private func start(in directory: URL, showHidden: Bool) {
        cancelRunningSearch()
        guard !query.isEmpty else {
            results = []; isSearching = false; return
        }
        // Results from another scope or folder (e.g. Entire Mac hits) must not stay
        // on screen — and selectable for Trash — while the new search runs.
        let (gen, clearResults) = run.start(scope: selectedScope, directory: directory)
        if clearResults { results = [] }
        isSearching = true

        switch selectedScope {
        case .thisFolder:
            searchLocal(in: directory, recursive: false, showHidden: showHidden, gen: gen)
        case .thisFolderRecursive:
            searchLocal(in: directory, recursive: true, showHidden: showHidden, gen: gen)
        default:
            searchWithSpotlight(scope: selectedScope, base: directory, gen: gen)
        }
    }

    /// Stop any running search and drop its results (query cleared / search bar reset).
    func clear() {
        rerun.reset()
        cancelRunningSearch()
        run.reset()
        results       = []
        isSearching   = false
    }

    /// The directory watcher saw `changed` change: drop results inside it whose
    /// item is gone, so deleted or renamed-away files leave the list at once
    /// (the re-run of a folder search, or Spotlight's own update, follows).
    /// Checked off the main thread; applied only if no newer search replaced
    /// the results meanwhile.
    func dropMissingResults(inside changed: URL) {
        let snapshot = results
        guard !snapshot.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let kept = SearchRefresh.pruned(snapshot, afterChangeIn: changed, url: { $0 },
                                                  exists: { FileOpsTransfer.exists($0, .default) })
            else { return }
            DispatchQueue.main.async {
                guard let self, self.results == snapshot else { return }
                self.results = kept
            }
        }
    }

    private func cancelRunningSearch() {
        run.cancel()
        searchTask?.cancel()
        searchTask = nil
        stopSpotlight()
    }

    // MARK: - Local search (current folder, optionally recursive; no Spotlight)

    private func searchLocal(in directory: URL, recursive: Bool, showHidden: Bool, gen: UInt) {
        let q   = query
        rerun.walkStarted()
        // Strong capture: the walk returns promptly once cancelled, and a weak `self`
        // (a captured var) can't be read from the concurrent closure.
        searchTask = Task.detached(priority: .userInitiated) { [self] in
            let found = LocalSearch.search(in: directory, query: q, recursive: recursive,
                                           showHidden: showHidden, isCancelled: { Task.isCancelled })
            await MainActor.run {
                guard self.run.accepts(gen) else { return }
                self.results     = found
                self.isSearching = false
                // Files changed while it walked: once more, now that these are shown
                // (through the view's throttle, so an inline rename holds it).
                if self.rerun.walkFinished() { self.staleWalks += 1 }
            }
        }
    }

    // MARK: - Spotlight search (Desktop / Documents / Downloads / Home / Entire Mac)

    private func searchWithSpotlight(scope: SearchScope, base: URL, gen: UInt) {
        let q   = NSMetadataQuery()

        // Map scope → NSMetadataQuery scope. Spotlight reports real paths, so search
        // the folder's real path and present hits under the path the user knows
        // (~/Downloads/x, not /Volumes/…/Downloads/x).
        var rebase: (URL) -> URL = { $0 }
        switch scope {
        case .entireMac:
            q.searchScopes = [NSMetadataQueryLocalComputerScope]
        default:
            let real = ModelPaths.realPath(base) ?? base
            q.searchScopes = [real as NSURL]
            rebase = { ModelPaths.rebase($0, from: real, to: base) }
        }

        q.predicate = SearchMatcher.spotlightPredicate(for: query)
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]

        // Collect results on finish AND on each incremental update — but only from
        // the current query (a notification already queued for a stopped one is dropped).
        let collect: (Notification) -> Void = { [weak self, weak q] _ in
            guard let self, let q, q === self.metadataQuery, self.run.accepts(gen) else { return }
            q.disableUpdates()
            let urls = metadataQueryURLs(q).map(rebase)
            q.enableUpdates()
            self.results     = urls
            self.isSearching = false
        }
        spotlightObservers = [
            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main, using: collect),
            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidUpdate, object: q, queue: .main, using: collect),
        ]

        metadataQuery = q
        q.start()
    }

    private func stopSpotlight() {
        metadataQuery?.stop()
        spotlightObservers.forEach { NotificationCenter.default.removeObserver($0) }
        spotlightObservers = []
        metadataQuery      = nil
    }

    deinit {
        stopSpotlight()
        searchTask?.cancel()
    }
}

// MARK: - Mac-wide tag-based Spotlight search

class TagService: NSObject, ObservableObject {
    @Published var taggedFileURLs:  [URL] = []
    @Published var isSearchingTags: Bool  = false

    private var searchQuery:     NSMetadataQuery?
    private var searchObservers: [NSObjectProtocol] = []

    // Search Mac-wide for all files tagged with `tag`.
    // Uses ==[cd] so "Red" matches "red", "RED", etc.
    func searchFiles(for tag: SidebarTag) {
        stopSearch()
        isSearchingTags = true
        let q = NSMetadataQuery()
        q.searchScopes    = [NSMetadataQueryLocalComputerScope]
        // Match the user tag by name (for a colour tag, the user's name for it
        // and the English one) AND, for the 7 standard colors, the legacy color
        // label (kMDItemFSLabel). Finder's color sidebar matches the label too,
        // so this also surfaces files tagged by Finder or older builds that carry
        // the color label but no kMDItemUserTags value.
        var predicates = tag.searchNames.map { NSPredicate(format: "kMDItemUserTags ==[cd] %@", $0) }
        if tag.isStandard {
            predicates.append(NSPredicate(format: "kMDItemFSLabel == %ld", tag.color))
        }
        q.predicate = predicates.count == 1 ? predicates[0]
            : NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]

        let handle: (Notification) -> Void = { [weak self, weak q] _ in
            // Ignore a notification queued by a query that has since been replaced.
            guard let self, let q, q === self.searchQuery else { return }
            self.collectTaggedFiles(from: q)
        }
        searchObservers = [
            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main, using: handle),
            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidUpdate, object: q, queue: .main, using: handle),
        ]
        searchQuery = q
        q.start()
    }

    private func collectTaggedFiles(from q: NSMetadataQuery?) {
        guard let q else { return }
        q.disableUpdates()
        let urls = metadataQueryURLs(q)
        q.enableUpdates()
        taggedFileURLs  = urls
        isSearchingTags = false
    }

    func stopSearch() {
        searchQuery?.stop()
        searchObservers.forEach { NotificationCenter.default.removeObserver($0) }
        searchObservers = []
        searchQuery     = nil
        taggedFileURLs  = []
        isSearchingTags = false
    }

    deinit { stopSearch() }
}
