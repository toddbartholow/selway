import Foundation

/// A folder's listing with a few of its entries read again, in place of a
/// full reload, when the watcher saw only those files change (a download or
/// a log file growing, a file retagged). Selection and scroll position key off
/// item ids, which stay the same.
enum ShellListingPatch {
    enum Result: Equatable {
        /// Nothing shown changed (only skipped entries did, or the files read
        /// the same): nothing to sort or show.
        case unchanged
        /// The listing with the changed items replaced, unsorted.
        case patched([FileItem])
        /// More than an edit in place: list the folder again.
        case needsFullListing
    }

    /// A folder's items after `reload`.
    struct Reload: Equatable {
        let items: [FileItem]
        /// Listed whole, not patched: entries may have come or gone.
        let isFullListing: Bool
        /// Patched with every item where it was: none had to move to stay in
        /// order, so anything kept per position (a column's path keys) holds.
        let keepsOrder: Bool
    }

    /// `listing` (the items of `folder`, as listed) with each of `names` read
    /// again by `load`. The folder must be listed again (`needsFullListing`) when:
    /// - a listed entry is gone or can't be read, or is now hidden while hidden
    ///   items aren't shown;
    /// - an entry that isn't listed would be shown (it's new).
    ///
    /// An entry that isn't listed and wouldn't be shown (`.DS_Store` with hidden
    /// items off) is skipped. Listed entries are read at a fresh copy of the URL
    /// they were listed under (ModelPaths.fresh: the listed one would give back
    /// the values cached when it was listed); others under `folder`, as files, so
    /// building the URL looks nothing up (a link into an automount folder isn't
    /// followed to find out whether it's a folder; `load` decides whether to
    /// follow it).
    static func apply(_ names: Set<String>, to listing: [FileItem], in folder: URL, showHidden: Bool,
                      load: (URL) -> FileItem? = { FileItem.load(from: $0) }) -> Result {
        patch(names, to: listing, in: folder, showHidden: showHidden, load: load).result
    }

    /// `apply`, with the indices of the items it replaced.
    private static func patch(_ names: Set<String>, to listing: [FileItem], in folder: URL, showHidden: Bool,
                              load: (URL) -> FileItem?) -> (result: Result, changed: [Int]) {
        var index: [String: Int] = [:]
        index.reserveCapacity(listing.count)
        for (i, item) in listing.enumerated() { index[item.name] = i }

        var patched = listing
        var changed: [Int] = []
        for name in names {
            if let i = index[name] {
                guard let item = reread(listing[i], showHidden: showHidden, load: load) else {
                    return (.needsFullListing, [])
                }
                if item != listing[i] {
                    patched[i] = item
                    changed.append(i)
                }
            } else {
                if !showHidden, name.hasPrefix(".") { continue }
                let url = folder.appendingPathComponent(name, isDirectory: false)
                guard let item = load(url) else { continue }   // came and went
                guard !showHidden, item.isHidden else { return (.needsFullListing, []) }
            }
        }
        return changed.isEmpty ? (.unchanged, []) : (.patched(patched), changed)
    }

    /// Search results (from any folders) with those at `paths` (ShellPath.key)
    /// read again, as listed entries are in `apply`. The search must run again
    /// (`needsFullListing`) when one of them is gone, can't be read, or is now
    /// hidden while hidden items aren't shown. Paths that aren't results are
    /// skipped: a new file changes its folder too, which runs a folder search
    /// again (SearchRefresh).
    ///
    /// With `field`, the results (sorted that way) stay sorted: only the ones
    /// read again are moved, when they must (`reordered`), so a Mac-wide
    /// search's tens of thousands of results aren't sorted again on every
    /// change to one of them.
    static func apply(paths: Set<String>, toResults results: [FileItem], showHidden: Bool,
                      sortedBy field: SortField? = nil, ascending: Bool = true,
                      folderOrder: FolderOrder = .foldersFirst,
                      load: (URL) -> FileItem? = { FileItem.load(from: $0) }) -> Result {
        guard !paths.isEmpty else { return .unchanged }
        // Names first: a Mac-wide search can list tens of thousands of results,
        // and only those with a changed file's name need their path made.
        let names = Set(paths.map { URL(fileURLWithPath: $0, isDirectory: false).lastPathComponent })
        var patched = results
        var changed: [Int] = []
        for (i, result) in results.enumerated()
        where names.contains(result.name) && paths.contains(ShellPath.key(result.url)) {
            guard let item = reread(result, showHidden: showHidden, load: load) else { return .needsFullListing }
            if item != result {
                patched[i] = item
                changed.append(i)
            }
        }
        guard !changed.isEmpty else { return .unchanged }
        guard let field else { return .patched(patched) }
        return .patched(reordered(patched, changed: changed) {
            itemPrecedes($0, $1, by: field, ascending: ascending, folderOrder: folderOrder)
        }.items)
    }

    /// `items`, in order but for those at `changed` (just patched), put back in
    /// order by moving only those, and whether any moved. Most changes move
    /// nothing (a file growing while sorted by name): each changed item is
    /// checked against its neighbours, and the list is kept as it is.
    static func reordered(_ items: [FileItem], changed: [Int],
                          precedes: (FileItem, FileItem) -> Bool) -> (items: [FileItem], moved: Bool) {
        let inOrder = changed.allSatisfy { i in
            (i == 0 || !precedes(items[i], items[i - 1]))
                && (i == items.count - 1 || !precedes(items[i + 1], items[i]))
        }
        guard !inOrder else { return (items, false) }
        var rest = items
        var moving: [FileItem] = []
        for i in changed.sorted(by: >) { moving.append(rest.remove(at: i)) }
        for item in moving {
            // After every item that comes before it: a binary search of the
            // rest, which is still in order.
            var low = 0, high = rest.count
            while low < high {
                let mid = (low + high) / 2
                if precedes(item, rest[mid]) { high = mid } else { low = mid + 1 }
            }
            rest.insert(item, at: low)
        }
        return (rest, true)
    }

    /// The paths (ShellPath.key) search results have for `names` changed in
    /// `folder`: under the folder as it was opened, and under its real path
    /// (`realPath`, the watcher's), where Spotlight reports them when the folder
    /// is reached through a link (a ~/Downloads that links to another volume).
    /// Built as files, so making them looks nothing up.
    static func resultPaths(_ names: Set<String>, in folder: URL, realPath: String?) -> Set<String> {
        var folders = [folder]
        if let realPath, realPath != ShellPath.key(folder) {
            folders.append(URL(fileURLWithPath: realPath, isDirectory: true))
        }
        var paths = Set<String>()
        for dir in folders {
            for name in names { paths.insert(ShellPath.key(dir.appendingPathComponent(name, isDirectory: false))) }
        }
        return paths
    }

    /// The items of `folder` to show after a change, sorted: with `changed`
    /// (entries the watcher saw change in place, and the listing they're
    /// patched into, sorted the same way), only those read again (`apply`) and
    /// moved if they must (`reordered`), unless the change adds or removes
    /// items; otherwise the folder listed whole (`list`). nil when nothing
    /// shown changed.
    static func reload(_ folder: URL, changed: (names: Set<String>, listing: [FileItem])?, showHidden: Bool,
                       sortedBy field: SortField, ascending: Bool, folderOrder: FolderOrder,
                       list: (URL, Bool) -> [FileItem] = { loadItems(at: $0, showHidden: $1) },
                       load: (URL) -> FileItem? = { FileItem.load(from: $0) }) -> Reload? {
        if let changed {
            let patch = patch(changed.names, to: changed.listing, in: folder, showHidden: showHidden, load: load)
            switch patch.result {
            case .unchanged:
                return nil
            case .patched(let items):
                let sorted = reordered(items, changed: patch.changed) {
                    itemPrecedes($0, $1, by: field, ascending: ascending, folderOrder: folderOrder)
                }
                return Reload(items: sorted.items, isFullListing: false, keepsOrder: !sorted.moved)
            case .needsFullListing:
                break
            }
        }
        let items = sortedItems(list(folder, showHidden), by: field, ascending: ascending, folderOrder: folderOrder)
        return Reload(items: items, isFullListing: true, keepsOrder: false)
    }

    /// `item` read again at a fresh copy of its URL (ModelPaths.fresh: the one
    /// it was listed under gives back the values cached then); nil when it's
    /// gone, can't be read, or is now hidden while hidden items aren't shown.
    private static func reread(_ item: FileItem, showHidden: Bool, load: (URL) -> FileItem?) -> FileItem? {
        guard let fresh = load(ModelPaths.fresh(item.url)), showHidden || !fresh.isHidden else { return nil }
        return fresh
    }
}

/// Loads of a folder's listing, full or patched (ShellListingPatch), latest
/// request wins. A patch starts from the listing on screen, so it doesn't start
/// while a load is on its way to replace that listing: the names wait
/// (`changed`) and are patched in once it lands (`takeDeferred`). Restarting
/// the load instead would never let a folder that takes longer to list than
/// the watcher's interval land while a file in it is being written. Search
/// results load the same way (SearchResultLoads), with their paths
/// (ShellPath.key) for names.
struct ShellListingLoads: Equatable {
    private(set) var generation = ShellGeneration()
    /// The last load whose result was taken.
    private var landed: UInt = 0
    /// Entries that changed while a load was in flight.
    private(set) var deferred: Set<String> = []

    /// A load has started and its result hasn't landed yet.
    var isLoading: Bool { landed != generation.current }

    /// Starts a load; pass its token to `finish`. A full load reads every entry
    /// from now on, so the names waiting are dropped; a patch is started with them.
    mutating func start() -> UInt {
        deferred = []
        return generation.next()
    }

    /// Entries the watcher saw change. True when a patch for them may start now;
    /// false when a load is in flight, and they wait for it.
    mutating func changed(_ names: Set<String>) -> Bool {
        guard isLoading else { return true }
        deferred.formUnion(names)
        return false
    }

    /// True when the load with `token` is the latest one, whose result should
    /// be shown; it has then landed.
    mutating func finish(_ token: UInt) -> Bool {
        guard generation.isCurrent(token) else { return false }
        landed = token
        return true
    }

    /// Drops the load in flight, if any (its pane has stopped): its result
    /// isn't taken, and the entries waiting for it are dropped with it. The
    /// next load starts afresh.
    mutating func cancel() {
        deferred = []
        landed = generation.next()
    }

    /// The entries that changed while the load that just landed was in flight,
    /// to patch in now; nil when there are none.
    mutating func takeDeferred() -> Set<String>? {
        guard !isLoading, !deferred.isEmpty else { return nil }
        defer { deferred = [] }
        return deferred
    }
}

/// Reads of the search results, latest wins: conversions of the engine's
/// results into items, which read every result, and patches of results changed
/// in place (ShellListingPatch.apply(paths:)). Changes wait, by path, while a
/// read is in flight (a new search's first results included, while the list
/// is still empty) and while an inline rename is open, as the listing's
/// reloads do: rebuilding the row being edited committed the half-typed name.
struct SearchResultLoads: Equatable {
    private var loads = ShellListingLoads()
    /// Results changed while an inline rename was open: patched once it ends.
    private(set) var held: Set<String> = []

    /// What a patch landing asks of the window.
    enum Landing: Equatable {
        /// Nothing: a newer read replaced it, nothing shown changed, or a
        /// rename is open (its paths are held).
        case nothing
        /// Show these results.
        case show([FileItem])
        /// A result is gone or now hidden: run the search again.
        case rerun
    }

    /// A conversion starts. It reads every result, so the changes waiting or
    /// held are in it.
    mutating func startConversion() -> UInt {
        held = []
        return loads.start()
    }

    /// The conversion with `token` landed: true when it's the latest, to be shown.
    mutating func finishConversion(_ token: UInt) -> Bool {
        loads.finish(token)
    }

    /// Results at `paths` (ShellPath.key) changed in place. True when a patch
    /// may start now (`startPatch`); false when they wait for the read in
    /// flight, or for the inline rename (`renaming`) to end.
    mutating func changed(_ paths: Set<String>, renaming: Bool) -> Bool {
        if renaming {
            held.formUnion(paths)
            return false
        }
        return loads.changed(paths)
    }

    mutating func startPatch() -> UInt {
        loads.start()
    }

    /// The patch of `paths` with `token` landed with `result`. One that lands
    /// while a rename is open (it started before) is held, like the changes
    /// that come then.
    mutating func finishPatch(_ token: UInt, paths: Set<String>, result: ShellListingPatch.Result,
                              renaming: Bool) -> Landing {
        guard loads.finish(token) else { return .nothing }
        if renaming {
            held.formUnion(paths)
            return .nothing
        }
        switch result {
        case .unchanged:            return .nothing
        case .patched(let items):   return .show(items)
        case .needsFullListing:     return .rerun
        }
    }

    /// The changes that waited for the read that just landed, to patch now;
    /// nil when there are none.
    mutating func takeDeferred() -> Set<String>? {
        loads.takeDeferred()
    }

    /// The rename ended: the changes held for it, to patch now; nil when there
    /// are none.
    mutating func takeHeld() -> Set<String>? {
        guard !held.isEmpty else { return nil }
        defer { held = [] }
        return held
    }

    /// The search results' items, sorted, each read at a fresh copy of its URL
    /// (ModelPaths.fresh): the engine's URLs keep the values first read
    /// through them, so a re-sort would bring back the sizes and dates of then.
    static func items(_ urls: [URL], sortedBy field: SortField, ascending: Bool, folderOrder: FolderOrder,
                      load: (URL) -> FileItem? = { FileItem.load(from: $0) }) -> [FileItem] {
        sortedItems(urls.compactMap { load(ModelPaths.fresh($0)) }, by: field, ascending: ascending,
                    folderOrder: folderOrder)
    }
}
