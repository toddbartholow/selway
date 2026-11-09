import Foundation

// Recent Servers (Connect to Server's list) and saved servers (Finder's
// Favorite Servers, listed in the sidebar under Locations). Both are stored
// in UserDefaults as addresses without a password (ServerAddress), and read
// back through the same parser, so a stored entry that isn't an address
// Selway would connect to (tampered with, or from an older build) is dropped.

/// The servers connected to lately, newest first, as Finder lists them.
enum RecentServers {
    static let defaultsKey = "selwayRecentServers"
    /// As many as Finder keeps.
    static let limit = 10

    static func load(from defaults: UserDefaults) -> [ServerAddress] {
        let stored = defaults.array(forKey: defaultsKey)?.compactMap { $0 as? String } ?? []
        return addresses(fromStorage: stored)
    }

    static func save(_ addresses: [ServerAddress], to defaults: UserDefaults) {
        defaults.set(storage(addresses), forKey: defaultsKey)
    }

    /// The stored strings as addresses: unparseable ones dropped, then
    /// duplicates (by `matchKey`), keeping the first; at most `limit`.
    static func addresses(fromStorage stored: [String]) -> [ServerAddress] {
        var seen = Set<String>()
        var list: [ServerAddress] = []
        for text in stored {
            guard case .success(let parsed) = ServerAddress.parse(text),
                  seen.insert(parsed.address.matchKey).inserted else { continue }
            list.append(parsed.address)
            if list.count == limit { break }
        }
        return list
    }

    static func storage(_ addresses: [ServerAddress]) -> [String] {
        addresses.prefix(limit).map(\.url.absoluteString)
    }

    /// `list` after connecting to `address`: on top, any earlier entry for the
    /// same server and share (whatever user) gone, at most `limit`.
    static func adding(_ address: ServerAddress, to list: [ServerAddress]) -> [ServerAddress] {
        Array(([address] + list.filter { $0.matchKey != address.matchKey }).prefix(limit))
    }

    static func removing(_ address: ServerAddress, from list: [ServerAddress]) -> [ServerAddress] {
        list.filter { $0.matchKey != address.matchKey }
    }
}

/// A server, or a folder on one, saved to the sidebar.
struct SavedServer: Hashable, Sendable, Identifiable {
    /// Stable across launches; the sidebar row's identity.
    let id: String
    /// What's mounted: an SMB or AFP share (or just the server), an NFS
    /// export, a WebDAV or FTP address.
    let address: ServerAddress
    /// A folder on it to open, relative ("Projects/2026"), or "".
    let folder: String
    /// The row's name.
    var name: String
    /// Mount it when Selway starts, quietly. Off unless turned on.
    var reconnectAtLaunch = false

    /// The address with the folder: what the row's tooltip shows.
    var fullAddress: ServerAddress { address.appending(folder: folder) }

    /// The row's name. One that is a non-ASCII host has the host's ASCII
    /// form after it (`ServerAddress.displayHost`), so a lookalike stands
    /// out; the tooltip (`displayAddress`) always has it.
    var sidebarDisplayName: String {
        name.caseInsensitiveCompare(address.host) == .orderedSame ? ServerAddress.displayHost(address.host) : name
    }

    /// An SMB or AFP server with no share: macOS asks which shares to mount,
    /// so it's never "connected" itself and can't reconnect quietly.
    var isServerOnly: Bool { address.isServerOnly }

    /// Saving what was typed in Connect to Server: an SMB or AFP address's
    /// share is mounted and the rest of its path opened.
    static func make(id: String = UUID().uuidString, typed address: ServerAddress, name: String? = nil) -> SavedServer {
        make(id: id, mounting: address.mountTarget, folder: address.folderInShare, name: name)
    }

    /// Saving `folder` on a mounted share whose address (its remount URL) is `address`.
    static func make(id: String = UUID().uuidString, mounting address: ServerAddress, folder: String,
                     name: String? = nil) -> SavedServer {
        let folder = SavedServers.normalizedFolder(folder) ?? ""
        let fallback = ServerAddress.components(folder).last ?? address.shareName ?? address.host
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SavedServer(id: id, address: address, folder: folder,
                           name: trimmed.isEmpty ? fallback : trimmed)
    }

    /// Whether two entries save the same place (same share and folder,
    /// whatever user or name).
    func isSamePlace(as other: SavedServer) -> Bool {
        placeKey == other.placeKey
    }

    var placeKey: String {
        let folder = address.scheme.pathIsCaseInsensitive ? self.folder.lowercased() : self.folder
        return address.matchKey + "|" + folder
    }
}

/// The saved servers, persisted as a list of dictionaries (plain property-list
/// values, so tests and the UI tests can set them as preferences). Entries
/// that can't be read, or whose address Selway wouldn't connect to, are
/// skipped rather than losing the rest.
struct SavedServersStore {
    static let defaultsKey = "selwaySavedServers"
    /// The most read back; any more (a preferences file filled by hand) are ignored.
    static let limit = 100

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [SavedServer] {
        SavedServers.servers(fromStorage: defaults.object(forKey: Self.defaultsKey))
    }

    func save(_ servers: [SavedServer]) {
        defaults.set(SavedServers.storage(servers), forKey: Self.defaultsKey)
    }
}

/// The saved servers' list edits and storage format.
enum SavedServers {
    private enum Key {
        static let id = "id", address = "address", folder = "folder", name = "name", reconnect = "reconnectAtLaunch"
    }

    static func servers(fromStorage raw: Any?) -> [SavedServer] {
        guard let entries = raw as? [Any] else { return [] }
        var list: [SavedServer] = []
        var ids = Set<String>()
        for case let entry as [String: Any] in entries.prefix(SavedServersStore.limit) {
            guard let text = entry[Key.address] as? String,
                  case .success(let parsed) = ServerAddress.parse(text),
                  let folder = normalizedFolder(entry[Key.folder] as? String ?? "") else { continue }
            var id = (entry[Key.id] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            if ids.contains(id) { id = UUID().uuidString }
            var server = SavedServer.make(id: id, mounting: parsed.address, folder: folder,
                                          name: entry[Key.name] as? String)
            server.reconnectAtLaunch = entry[Key.reconnect] as? Bool ?? false
            guard !list.contains(where: { $0.isSamePlace(as: server) }) else { continue }
            ids.insert(id)
            list.append(server)
        }
        return list
    }

    static func storage(_ servers: [SavedServer]) -> [[String: Any]] {
        servers.map { server in
            [Key.id: server.id, Key.address: server.address.url.absoluteString, Key.folder: server.folder,
             Key.name: server.name, Key.reconnect: server.reconnectAtLaunch]
        }
    }

    /// A relative folder path ("a/b"), or nil for one that isn't safe to
    /// append to a mount point (".." in it, control characters).
    static func normalizedFolder(_ folder: String) -> String? {
        var parts: [String] = []
        for part in ServerAddress.components(folder) {
            if part == "." || part == ".." { return nil }
            if part.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return nil }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    /// `list` with `server` added at the end, or nil when that place is saved already.
    static func adding(_ server: SavedServer, to list: [SavedServer]) -> [SavedServer]? {
        guard !list.contains(where: { $0.isSamePlace(as: server) }) else { return nil }
        return list + [server]
    }

    static func removing(id: String, from list: [SavedServer]) -> [SavedServer] {
        list.filter { $0.id != id }
    }

    static func setting(reconnectAtLaunch: Bool, id: String, in list: [SavedServer]) -> [SavedServer] {
        list.map { server in
            guard server.id == id else { return server }
            var changed = server
            changed.reconnectAtLaunch = reconnectAtLaunch && !server.isServerOnly
            return changed
        }
    }

    /// The saved servers to mount at launch: those with the setting on that
    /// aren't mounted already, one per share.
    static func toReconnect(_ servers: [SavedServer], mounted: [ServerAddress]) -> [ServerAddress] {
        let mountedKeys = Set(mounted.map(\.matchKey))
        var seen = Set<String>()
        return servers.filter { $0.reconnectAtLaunch && !$0.isServerOnly }.map(\.address).filter {
            !mountedKeys.contains($0.matchKey) && seen.insert($0.matchKey).inserted
        }
    }

    /// The folder to save for `folder` on a mounted network volume: its path
    /// below the mount point, or nil when it isn't on it.
    static func folder(_ folder: URL, onVolume mountPoint: URL) -> String? {
        let volume = ShellPath.key(mountPoint), path = ShellPath.key(folder)
        if path == volume { return "" }
        guard path.hasPrefix(volume == "/" ? "/" : volume + "/") else { return nil }
        return normalizedFolder(String(path.dropFirst(volume.count)))
    }
}

/// A saved server's row under Locations.
struct SidebarServerRow: Hashable, Sendable {
    let server: SavedServer
    /// Where the row goes while its share is mounted: the mount point, or the
    /// saved folder on it. nil while it isn't connected (the row is dimmed and
    /// a click connects).
    let folder: URL?

    var isConnected: Bool { folder != nil }
}

/// How saved servers sit among the volumes under Locations.
enum SidebarServers {
    /// The saved servers' rows, by name, after the volumes. One whose share is
    /// mounted and listed as a volume row has no row of its own: the volume's
    /// row stands in for it. A saved folder on a share keeps its row while
    /// connected (it goes to the folder, not the share), as does a saved
    /// share whose volume row is hidden (Settings → Sidebar → Network volumes off).
    static func rows(_ servers: [SavedServer], mounted: [SidebarVolume],
                     listed: [SidebarVolume]) -> [SidebarServerRow] {
        let listedKeys = Set(listed.compactMap { $0.server?.matchKey })
        return servers.compactMap { server -> SidebarServerRow? in
            guard let mountPoint = mountPoint(for: server.address, in: mounted) else {
                return SidebarServerRow(server: server, folder: nil)
            }
            if server.folder.isEmpty && listedKeys.contains(server.address.matchKey) { return nil }
            return SidebarServerRow(server: server, folder: folderURL(server.folder, on: mountPoint))
        }
        .sorted { a, b in
            switch a.server.name.localizedStandardCompare(b.server.name) {
            case .orderedAscending:  return true
            case .orderedDescending: return false
            case .orderedSame:       return a.server.id < b.server.id
            }
        }
    }

    /// Where the share `address` is mounted, if it is: the volume whose
    /// remount address is the same server and share. An SMB or AFP server
    /// with no share is never mounted itself.
    static func mountPoint(for address: ServerAddress, in volumes: [SidebarVolume]) -> URL? {
        guard !address.isServerOnly else { return nil }
        let key = address.matchKey
        return volumes.first { $0.server?.matchKey == key }?.url
    }

    /// `folder` (relative) on the volume at `mountPoint`. Built from the path
    /// alone: nothing on the volume is read.
    static func folderURL(_ folder: String, on mountPoint: URL) -> URL {
        let base = URL(fileURLWithPath: ShellPath.key(mountPoint), isDirectory: true)
        return ServerAddress.components(folder).reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
    }
}
