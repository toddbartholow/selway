import Foundation

/// Pinned sidebar folders, persisted as paths. Entries whose folder is missing
/// right now (unmounted external / network volume) are kept, so the next save
/// can't silently drop them for good; the sidebar shows them as unavailable.
/// URLs are compared by normalized path (`ShellPath.key`), so "/a/b" and
/// "/a/b/" are the same pin.
struct FavoritesStore {
    static let defaultsKey = "pinnedFolders"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Duplicates are dropped by normalized path ("/a/b", "/a/b/" and
    /// "/a/./b" are one pin), keeping the first.
    func load() -> [URL] {
        let urls = (defaults.stringArray(forKey: Self.defaultsKey) ?? [])
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: ShellPath.key(URL(fileURLWithPath: $0)), isDirectory: true) }
        return ShellDisplayList.mergeUnique([urls], key: ShellPath.key)
    }

    func save(_ urls: [URL]) {
        defaults.set(urls.map(\.path), forKey: Self.defaultsKey)
    }

    /// True when the folder exists right now (follows symlinks).
    static func isAvailable(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func contains(_ urls: [URL], _ url: URL) -> Bool {
        ShellPath.contains(urls, url)
    }

    /// `urls` with `url` pinned at the top, or nil when it's already pinned.
    static func pinning(_ url: URL, in urls: [URL]) -> [URL]? {
        guard !contains(urls, url) else { return nil }
        return [URL(fileURLWithPath: url.path, isDirectory: true)] + urls
    }

    static func unpinning(_ url: URL, in urls: [URL]) -> [URL] {
        let key = ShellPath.key(url)
        return urls.filter { ShellPath.key($0) != key }
    }

    /// Removes every index in `offsets` at once (List `onDelete`); out-of-range
    /// offsets are ignored.
    static func removing(atOffsets offsets: IndexSet, from urls: [URL]) -> [URL] {
        urls.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    }
}
