import Foundation

/// A sidebar row: a Favorites location, a volume under Locations, a saved
/// server under Locations, the Network row or a server under it, a pinned
/// folder or a Recent folder. The same folder can be in more than one
/// section, so the row says which.
enum SidebarItem: Hashable, Sendable {
    case location(URL)
    case computer
    case volume(URL)
    /// A saved server, by its id (SavedServer.id): it has no folder while it
    /// isn't connected.
    case server(String)
    /// The Network row under Locations, whose rows are the servers found.
    case network
    /// A server found on the network, by its id (NetworkServer.id).
    case networkServer(String)
    case pinned(URL)
    case recent(URL)

    /// The folder the row goes to; nil for a saved server (where it goes
    /// depends on whether it's connected) and the Network rows (no folder).
    var url: URL? {
        switch self {
        case .location(let url), .volume(let url), .pinned(let url), .recent(let url): return url
        case .server, .network, .networkServer, .computer: return nil
        }
    }
}

/// The sidebar's decisions, kept out of the view so they can be tested: which
/// row follows the folder shown, and what a selection made by the user does.
enum SidebarSelection {
    /// The row to highlight for `path`, as Finder does. The row already selected
    /// stays if it's that folder and still listed (a Recent row that's also in
    /// Favorites mustn't jump up, or arrowing down the list loops; an ejected
    /// drive's row is gone); otherwise the first row for it in the sidebar's
    /// order: Favorites, then Locations (`volumes`, then the connected saved
    /// servers in `servers`), then Pinned; otherwise none.
    ///
    /// `networkShown`: the Network rows on screen (Network, and the servers
    /// under it while it's open). One of them that's selected stays selected:
    /// pass them when the rows change (a drive mounted, a server saved), not
    /// when the folder shown does, which the highlight follows.
    static func matchingItem(for location: BrowserLocation, selected: SidebarItem?, locations: [URL], volumes: [URL] = [],
                             servers: [SidebarServerRow] = [], pinned: [URL],
                             networkShown: Set<SidebarItem> = []) -> SidebarItem? {
        if let selected, networkShown.contains(selected) { return selected }
        if location == .computer { return .computer }
        guard let path = location.folder else { return nil }
        if let selected, let url = selected.url ?? serverFolder(selected, servers), ShellPath.same(url, path),
           isListed(selected, locations, volumes, servers, pinned) {
            return selected
        }
        if let url = locations.first(where: { ShellPath.same($0, path) }) { return .location(url) }
        if let url = volumes.first(where: { ShellPath.same($0, path) }) { return .volume(url) }
        if let row = servers.first(where: { $0.folder.map { ShellPath.same($0, path) } ?? false }) {
            return .server(row.server.id)
        }
        if let url = pinned.first(where: { ShellPath.same($0, path) }) { return .pinned(url) }
        return nil
    }

    static func matchingItem(for path: URL, selected: SidebarItem?, locations: [URL], volumes: [URL] = [],
                             servers: [SidebarServerRow] = [], pinned: [URL],
                             networkShown: Set<SidebarItem> = []) -> SidebarItem? {
        matchingItem(for: .folder(path), selected: selected, locations: locations, volumes: volumes,
                     servers: servers, pinned: pinned, networkShown: networkShown)
    }

    private static func serverFolder(_ item: SidebarItem, _ servers: [SidebarServerRow]) -> URL? {
        guard case .server(let id) = item else { return nil }
        return servers.first { $0.server.id == id }?.folder
    }

    /// Recent rows aren't checked: the list changes only when a folder is shown.
    static func isListed(_ item: SidebarItem, _ locations: [URL], _ volumes: [URL],
                         _ servers: [SidebarServerRow], _ pinned: [URL]) -> Bool {
        switch item {
        case .location(let url): return ShellPath.contains(locations, url)
        case .volume(let url):   return ShellPath.contains(volumes, url)
        case .server(let id):    return servers.contains { $0.server.id == id }
        case .pinned(let url):   return ShellPath.contains(pinned, url)
        case .recent:            return true
        case .network, .networkServer: return false
        case .computer: return true
        }
    }

    enum Outcome: Equatable, Sendable {
        /// Nothing to do: no row, or the folder already shown.
        case stay
        /// Show this folder.
        case navigate(BrowserLocation)
        /// A pinned folder whose volume isn't connected: the highlight rests on
        /// it (so the arrow keys can move on past it), with a beep, and nothing opens.
        case unavailable
        /// A saved server that isn't connected: connect to it (by id), then
        /// show it. Only ever from `activated`: a click, Return, or the row's
        /// Connect action, never from the selection moving onto it.
        case connect(String)
        /// A server found on the network: connect to it (by its
        /// NetworkServer.id). Like `connect`, only from `activated`.
        case connectNetworkServer(String)
    }

    /// What the user selecting `item` does. Only the user's selections go through
    /// here: the app moving the highlight to follow the folder never navigates.
    /// The Network row and the servers under it only take the highlight.
    /// `serverFolder` is where a saved server's row goes while it's connected
    /// (SidebarServerRow.folder), nil while it isn't. A saved server that isn't
    /// connected only takes the highlight (`.stay`): the arrow keys pass over
    /// it, and connecting, which can bring up the system's login prompt, waits
    /// for the row to be activated (`activated`).
    static func userSelected(_ item: SidebarItem?, location: BrowserLocation, isAvailable: (URL) -> Bool,
                             serverFolder: (String) -> URL? = { _ in nil }) -> Outcome {
        guard let item else { return .stay }
        if case .computer = item { return location == .computer ? .stay : .navigate(.computer) }
        if case .server(let id) = item {
            guard let folder = serverFolder(id) else { return .stay }
            return location == .folder(folder) ? .stay : .navigate(.folder(folder))
        }
        guard let url = item.url, location != .folder(url) else { return .stay }
        if case .pinned = item, !isAvailable(url) { return .unavailable }
        return .navigate(.folder(url))
    }

    static func userSelected(_ item: SidebarItem?, currentPath: URL, isAvailable: (URL) -> Bool,
                             serverFolder: (String) -> URL? = { _ in nil }) -> Outcome {
        userSelected(item, location: .folder(currentPath), isAvailable: isAvailable, serverFolder: serverFolder)
    }

    /// What activating `item` does (clicking it, Return on it, or its Connect
    /// action): a saved server that isn't connected connects, and so does a
    /// server under Network; anything else does what selecting it does.
    static func activated(_ item: SidebarItem?, location: BrowserLocation, isAvailable: (URL) -> Bool,
                          serverFolder: (String) -> URL? = { _ in nil }) -> Outcome {
        if case .server(let id)? = item, serverFolder(id) == nil { return .connect(id) }
        if case .networkServer(let id)? = item { return .connectNetworkServer(id) }
        return userSelected(item, location: location, isAvailable: isAvailable, serverFolder: serverFolder)
    }

    static func activated(_ item: SidebarItem?, currentPath: URL, isAvailable: (URL) -> Bool,
                          serverFolder: (String) -> URL? = { _ in nil }) -> Outcome {
        activated(item, location: .folder(currentPath), isAvailable: isAvailable, serverFolder: serverFolder)
    }
}

/// The sidebar's Recent folders: a stored list of paths (newest first) and the
/// rows on screen.
enum RecentFolders {
    static let defaultsKey  = "recentFolders"
    /// How many the sidebar shows unless Settings → Sidebar says otherwise
    /// (`SidebarPrefs.recentCountKey`).
    static let defaultVisibleLimit = 8
    /// How many are remembered: the most the sidebar can be set to show.
    static let storedLimit  = 20

    /// URLs for stored rows, without looking at the file system. A reader
    /// checks them off the main thread before deciding which to keep.
    static func urls(_ paths: [String]) -> [URL] {
        paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The rows once the reader has answered. Those `isGone` (found missing,
    /// and not being read again) leave; stored folders not shown (`waiting`:
    /// say on a drive that was away) join at the end, in their order, once
    /// they're found there or refused and not gone since. Refused folders are
    /// never looked at. At most `storedLimit` rows.
    static func merged<Info>(_ rows: [URL], waiting: [URL], answers: [String: PinnedFolderAnswer<Info>],
                             isGone: (String) -> Bool) -> (rows: [URL], waiting: [URL]) {
        let kept = rows.filter { !isGone(ShellPath.key($0)) }
        var arrived: [URL] = []
        var still: [URL] = []
        for url in waiting where !ShellPath.contains(kept, url) {
            let key = ShellPath.key(url)
            switch answers[key] {
            case .present?, .refused?: if isGone(key) { still.append(url) } else { arrived.append(url) }
            case .missing?, nil:       still.append(url)
            }
        }
        return (Array((kept + arrived).prefix(storedLimit)), still)
    }

    /// Whether `AutomountGuard` refuses to let `path` be looked at: under an
    /// automount folder (`/net/<host>`, `/Network/Servers`, `/home`) or
    /// reached through a link into one. Looking would mount it, or wait on a
    /// host that has gone.
    static func isUnchecked(_ path: String,
                            check: (String) -> AutomountGuard.Verdict = { AutomountGuard.check($0) }) -> Bool {
        check(path) == .refused
    }

    /// The stored list after visiting `path`: moved (or added) to the top.
    static func stored(_ paths: [String], visiting path: String) -> [String] {
        Array(([path] + paths.filter { $0 != path }).prefix(storedLimit))
    }

    /// The rows after visiting `url`, of which the sidebar shows the first
    /// `limit`. A folder already shown keeps its row: moving it to the top
    /// under the pointer, or while arrowing down the list, made the rows jump
    /// around. Any other goes on top. Up to `storedLimit` rows are kept, so
    /// raising the limit in Settings shows more at once.
    static func visible(_ rows: [URL], visiting url: URL, limit: Int = defaultVisibleLimit) -> [URL] {
        guard !rows.prefix(limit).contains(where: { ShellPath.same($0, url) }) else { return rows }
        let rest = rows.filter { !ShellPath.same($0, url) }
        return Array(([url] + rest).prefix(storedLimit))
    }
}
