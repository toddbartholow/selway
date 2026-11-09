import Foundation

/// What a directory watcher has seen since it last reported, by folder key
/// (ShellPath.key). A folder whose listing changed (an entry added, removed or
/// renamed, or the folder itself moved) is reloaded whole; one whose files only
/// changed in place (written to, retagged) has just those entries read again.
///
/// A whole-folder change takes in the entry changes for that folder, before or
/// after it, until the batch is taken: the reload reads them anyway.
struct ShellWatchChanges: Equatable {
    /// Above this many changed entries in one folder, the folder is reloaded
    /// whole: reading each one again would cost more than listing it.
    static let maxEntries = 100

    /// Folders whose listing changed.
    private(set) var folders: Set<String> = []
    /// Entries (names) whose contents changed, by folder; never a folder in `folders`.
    private(set) var entries: [String: Set<String>] = [:]

    var isEmpty: Bool { folders.isEmpty && entries.isEmpty }

    mutating func folderChanged(_ key: String) {
        folders.insert(key)
        entries[key] = nil
    }

    mutating func entryChanged(_ name: String, in key: String) {
        guard !folders.contains(key) else { return }
        var names = entries[key] ?? []
        names.insert(name)
        if names.count > Self.maxEntries {
            folderChanged(key)
        } else {
            entries[key] = names
        }
    }

    /// Forgets a folder no longer watched.
    mutating func remove(_ key: String) {
        folders.remove(key)
        entries[key] = nil
    }

    /// Everything seen so far, leaving the batch empty.
    mutating func take() -> ShellWatchChanges {
        defer { self = ShellWatchChanges() }
        return self
    }
}

/// File-system event paths (FSEvents reports them absolute, symlinks resolved)
/// taken apart lexically: no disk access.
enum ShellEventPath {
    /// The folder holding `path` and its name in it, or nil for "/" and
    /// anything that isn't an absolute path.
    static func split(_ path: String) -> (folder: String, name: String)? {
        let utf8 = path.utf8
        guard utf8.first == slash else { return nil }
        var end = utf8.endIndex
        while end > utf8.index(after: utf8.startIndex), utf8[utf8.index(before: end)] == slash {
            end = utf8.index(before: end)
        }
        let trimmed = utf8[..<end]
        guard let last = trimmed.lastIndex(of: slash), trimmed.index(after: last) < end else { return nil }
        let name = String(Substring(trimmed[trimmed.index(after: last)...]))
        let folder = last == utf8.startIndex ? "/" : String(Substring(trimmed[..<last]))
        return (folder, name)
    }

    private static let slash = UInt8(ascii: "/")

    /// True when `path` is `folder` or anywhere below it.
    static func isSameOrInside(_ path: String, _ folder: String) -> Bool {
        if folder == "/" { return path.hasPrefix("/") }
        return path == folder || path.hasPrefix(folder + "/")
    }
}

/// The folders a file-event stream covers, to tell from an event's bytes
/// whether it's about an entry directly inside one of them. A stream over a
/// broad folder ("/" with the column tree shown) reports every change on the
/// disk, almost all of them deeper down: those are turned away by the length
/// of their parent and a byte comparison, without making a String.
struct ShellEventFolders {
    /// The folders' UTF-8 bytes, by length.
    private let byLength: [Int: [[UInt8]]]

    /// `folders` as ShellEventPath.split gives them: absolute, no trailing "/" ("/" itself aside).
    init(_ folders: [String]) {
        var byLength: [Int: [[UInt8]]] = [:]
        for folder in folders {
            let bytes = Array(folder.utf8)
            byLength[bytes.count, default: []].append(bytes)
        }
        self.byLength = byLength
    }

    /// True when the absolute path in `bytes` (UTF-8) names an entry directly
    /// inside one of the folders, or may: a parent with non-ASCII characters is
    /// let through for the watcher's String comparison to decide, since the
    /// same name can be spelled with other bytes (composed or decomposed).
    func holdsEntry(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let slash = UInt8(ascii: "/")
        var end = bytes.count
        while end > 1, bytes[end - 1] == slash { end -= 1 }
        guard end > 1, bytes[0] == slash else { return false }
        var last = end - 1
        while bytes[last] != slash { last -= 1 }        // stops at 0 at the latest
        guard last < end - 1 else { return false }
        let parent = UnsafeBufferPointer(rebasing: bytes[0..<(last == 0 ? 1 : last)])
        if let candidates = byLength[parent.count], candidates.contains(where: { $0.elementsEqual(parent) }) {
            return true
        }
        return parent.contains { $0 >= 0x80 }
    }

    func holdsEntry(_ path: String) -> Bool {
        var path = path
        return path.withUTF8 { holdsEntry($0) }
    }
}
