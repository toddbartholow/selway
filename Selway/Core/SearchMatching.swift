import Foundation

// MARK: - Scope

enum SearchScope: String, CaseIterable {
    case thisFolder          = "This Folder"
    case thisFolderRecursive = "This Folder & Subfolders"
    case desktop             = "Desktop"
    case documents           = "Documents"
    case downloads           = "Downloads"
    case home                = "Home Folder"
    case entireMac           = "Entire Mac"

    var displayName: String {
        switch self {
        case .thisFolder:          NSLocalizedString("This Folder", comment: "Search location option")
        case .thisFolderRecursive: NSLocalizedString("This Folder & Subfolders", comment: "Search location option")
        case .desktop:             NSLocalizedString("Desktop", comment: "Search location option")
        case .documents:           NSLocalizedString("Documents", comment: "Search location option")
        case .downloads:           NSLocalizedString("Downloads", comment: "Search location option")
        case .home:                NSLocalizedString("Home Folder", comment: "Search location option")
        case .entireMac:           NSLocalizedString("Entire Mac", comment: "Search location option")
        }
    }

    /// Local scopes walk the folder themselves; the rest go through Spotlight.
    var isLocal: Bool { self == .thisFolder || self == .thisFolderRecursive }

    func baseURL(currentPath: URL) -> URL {
        let fm = FileManager.default
        switch self {
        case .thisFolder, .thisFolderRecursive:
            return currentPath
        case .desktop:
            return fm.urls(for: .desktopDirectory,  in: .userDomainMask).first ?? currentPath
        case .documents:
            return fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? currentPath
        case .downloads:
            return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? currentPath
        case .home:
            return fm.homeDirectoryForCurrentUser
        case .entireMac:
            return fm.homeDirectoryForCurrentUser   // unused; Spotlight uses its own scope constant
        }
    }
}

// MARK: - Query matching

/// What the search field means: ".pdf" → files with that extension (case-
/// insensitive); anything else → name contains the text (case- and
/// diacritic-insensitive, like Finder). "." alone and "" match nothing.
enum SearchMatcher {
    static func extensionQuery(_ query: String) -> String? {
        guard query.hasPrefix(".") else { return nil }
        return String(query.dropFirst())
    }

    static func matches(name: String, query: String) -> Bool {
        if let ext = extensionQuery(query) {
            guard !ext.isEmpty else { return false }
            return (name as NSString).pathExtension.caseInsensitiveCompare(ext) == .orderedSame
        }
        guard !query.isEmpty else { return false }
        return name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    static func matches(url: URL, query: String) -> Bool {
        matches(name: url.lastPathComponent, query: query)
    }

    #if canImport(Darwin)
    /// Spotlight predicate mirroring `matches` ([cd] = case/diacritic-insensitive).
    static func spotlightPredicate(for query: String) -> NSPredicate {
        if let ext = extensionQuery(query) {
            guard !ext.isEmpty else { return NSPredicate(value: false) }
            return NSPredicate(format: "%K ==[cd] %@", "kMDItemFSExtension", ext)
        }
        guard !query.isEmpty else { return NSPredicate(value: false) }
        return NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemFSName", query)
    }
    #endif
}

// MARK: - Local folder search

enum LocalSearch {
    static let resultLimit = 5_000

    /// Search `directory` (and, when `recursive`, its subfolders) for `query`.
    /// Walks the folder's real path — FileManager won't enumerate through a
    /// symlinked root — and reports results under `directory` as given, so
    /// ~/Downloads results don't come back as /Volumes/… paths. Symlinked
    /// subfolders aren't descended into, so link cycles can't loop. Package
    /// contents are skipped. Stops at `limit` results or when `isCancelled()`.
    static func search(in directory: URL, query: String, recursive: Bool, showHidden: Bool,
                       limit: Int = resultLimit,
                       isCancelled: () -> Bool = { false }) -> [URL] {
        guard !query.isEmpty, let root = ModelPaths.realPath(directory) else { return [] }
        let fm = FileManager.default
        var found: [URL] = []
        let hidden: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let rebase = { (url: URL) in ModelPaths.rebase(url, from: root, to: directory) }

        if !recursive {
            let urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                     options: hidden)) ?? []
            for url in urls {
                if isCancelled() { return [] }
                if matches(url, query) { found.append(rebase(url)) }
                if found.count >= limit { break }
            }
            return found
        }

        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                             options: hidden.union(.skipsPackageDescendants),
                                             errorHandler: { _, _ in true })
        else { return [] }
        while let url = enumerator.nextObject() as? URL {
            if isCancelled() { return [] }
            if matches(url, query) { found.append(rebase(url)) }
            if found.count >= limit { break }
        }
        return found
    }

    private static func matches(_ url: URL, _ query: String) -> Bool {
        SearchMatcher.matches(url: url, query: query)
    }
}

// MARK: - Search runs

/// Which search's results may still be shown. Every search or clear starts a
/// new generation; results are applied only by work started under the
/// current one, so a slow, superseded search (or a Spotlight notification
/// already queued for a stopped query) can't overwrite newer results, and a
/// cleared Mac-wide query can't keep feeding hits that Trash / Delete would
/// then act on.
struct SearchRunState {
    private var generation = ShellGeneration()
    /// Scope + folder the results on screen came from.
    private(set) var resultsOrigin: String?

    /// Starts a search of `directory` under `scope`. `clearResults` is true when
    /// the results on screen came from another scope or folder (e.g. Entire Mac
    /// hits) and must go now rather than stay selectable while the new search
    /// runs; refining the query in the same place keeps them until the new set
    /// arrives.
    mutating func start(scope: SearchScope, directory: URL) -> (token: UInt, clearResults: Bool) {
        let token = generation.next()
        let origin = "\(scope.rawValue)|\(ShellPath.key(directory))"
        let clear = origin != resultsOrigin
        resultsOrigin = origin
        return (token, clear)
    }

    /// Supersedes whatever is running; its results will be dropped.
    mutating func cancel() { generation.next() }

    /// Cancels and forgets where the (now cleared) results came from.
    mutating func reset() {
        cancel()
        resultsOrigin = nil
    }

    /// True when results produced under `token` may be shown.
    func accepts(_ token: UInt) -> Bool { generation.isCurrent(token) }
}

// MARK: - Keeping results current

/// What a folder change reported by the directory watcher means for the
/// search on screen.
///
/// Local scopes ("This Folder", "This Folder & Subfolders") are one-off walks,
/// so their results go stale when files are created, deleted or renamed; they
/// are re-run when a watched folder they cover changes. Only folders on screen
/// are watched (the current folder, and the open columns in column view), so a
/// change deeper in a recursive search's tree is picked up when one of those
/// changes. Spotlight scopes are live NSMetadataQuery searches that update
/// themselves (after Spotlight has indexed the change).
enum SearchRefresh {
    /// True when a change in `changed` should re-run the search for `query`
    /// under `scope`, whose base folder is `base`.
    static func shouldRerun(query: String, scope: SearchScope, base: URL, changed: URL) -> Bool {
        guard !query.isEmpty else { return false }
        switch scope {
        case .thisFolder:          return ShellPath.same(changed, base)
        case .thisFolderRecursive: return ShellPath.isSameOrInside(changed, base)
        default:                   return false
        }
    }

    /// `items` without the ones inside `changed` that no longer exist, or nil
    /// when nothing was removed. Only items inside the changed folder are
    /// checked: nothing else can have gone in that change, and a Mac-wide
    /// result list can be thousands long.
    static func pruned<T>(_ items: [T], afterChangeIn changed: URL,
                          url: (T) -> URL, exists: (URL) -> Bool) -> [T]? {
        var removed = false
        let kept = items.filter { item in
            let u = url(item)
            guard ShellPath.isSameOrInside(u, changed), !ShellPath.same(u, changed), !exists(u) else { return true }
            removed = true
            return false
        }
        return removed ? kept : nil
    }
}

/// Coalesces watcher-driven search re-runs. The first change schedules one
/// run `delay` later and the changes after it ride along, so a folder that
/// keeps changing (a download in progress) re-runs the search at most once
/// per `delay` instead of once per event. While something on screen must not
/// be rebuilt (an inline rename) the run waits and happens when that ends.
struct SearchRefreshThrottle: Equatable {
    static let delay: TimeInterval = 0.5

    private(set) var isScheduled = false
    private(set) var isDeferred = false

    /// A relevant change arrived. True when the caller should schedule `fire`
    /// after `delay`; false when a run is already scheduled or waiting.
    mutating func request() -> Bool {
        guard !isScheduled, !isDeferred else { return false }
        isScheduled = true
        return true
    }

    /// The scheduled time came. True when the search should re-run now; false
    /// while `holding`, and then `resume` says when.
    mutating func fire(holding: Bool) -> Bool {
        isScheduled = false
        if holding { isDeferred = true; return false }
        return true
    }

    /// The hold ended. True when a re-run waited for it.
    mutating func resume() -> Bool {
        defer { isDeferred = false }
        return isDeferred
    }

    /// The search has just run again from the start: a re-run waiting for the
    /// hold to end is owed no longer.
    mutating func dropDeferred() {
        isDeferred = false
    }
}

/// Watcher-driven re-runs of a folder search must not cancel one that is
/// still walking: in a folder that changes more often than a walk takes, each
/// re-run would cancel the last and the search would never finish. A refresh
/// that arrives mid-walk only marks the results dirty; when the walk finishes
/// (its results shown), it runs once more. A search the user starts (new
/// query, scope, folder, hidden files) still cancels at once (`reset`).
struct SearchRerunState: Equatable {
    private(set) var isWalking = false
    private(set) var isDirty = false

    /// A refresh was asked for. True when it should start now; false when a
    /// walk is running (it will run once more when that one finishes).
    mutating func requestRefresh() -> Bool {
        if isWalking { isDirty = true; return false }
        return true
    }

    /// A local walk started; it sees every change made before now.
    mutating func walkStarted() {
        isWalking = true
        isDirty = false
    }

    /// The current walk finished and its results are shown. True when changes
    /// arrived while it ran and it should run once more.
    mutating func walkFinished() -> Bool {
        isWalking = false
        defer { isDirty = false }
        return isDirty
    }

    /// The user started a different search, or cleared it: nothing pending.
    mutating func reset() {
        isWalking = false
        isDirty = false
    }
}
