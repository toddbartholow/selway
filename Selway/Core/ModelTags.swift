import Foundation
#if canImport(Glibc)
import Glibc
#endif

// MARK: - A tag on a file

/// One of a file's tags: its name and the colour stored with it.
///
/// Finder keeps a file's tags in the `com.apple.metadata:_kMDItemUserTags`
/// extended attribute, a binary property list holding one string per tag:
/// "Name\nColour", sometimes with more fields after ("Project\n2\n0"). A bare
/// "Name" has no colour. The colour belongs to the file's copy of the tag, so a
/// custom tag ("Project") or a renamed colour tag ("Urgent") keeps its colour
/// only if that number is kept. `URLResourceKey.tagNamesKey` strips it, which is
/// why Selway reads and writes the attribute itself (FinderTagStore).
struct FileTag: Hashable, Sendable {
    let name: String
    /// 1...7 is one of Finder's colours (FileItem.labelToColorName); 0 is none.
    let color: Int

    init(name: String, color: Int) {
        self.name = name
        self.color = FileTag.validColors.contains(color) ? color : 0
    }

    /// Parses one stored entry. A colour field that isn't 1...7 counts as none.
    init(entry: String) {
        let fields = entry.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        let color = fields.count > 1 ? Int(fields[1].trimmingCharacters(in: .whitespaces)) ?? 0 : 0
        self.init(name: fields.first.map(String.init) ?? "", color: color)
    }

    static let validColors = 1...7

    /// The colour its dot is drawn in: the stored one, or for a colourless tag
    /// named after a standard colour ("Red", as older apps and scripts wrote it),
    /// that colour. 0 draws no dot.
    var displayColor: Int {
        color != 0 ? color : FileItem.colorNameToLabel[name.lowercased()] ?? 0
    }

    /// The entry Selway writes for a new tag ("Red\n6"; "Work" for no colour).
    var entry: String { color == 0 ? name : "\(name)\n\(color)" }

    /// `tags` once per name (compared without regard to case, as Finder does),
    /// in first-seen order. A name seen first without a colour takes the first
    /// colour it's seen with.
    static func distinct(_ tags: [FileTag]) -> [FileTag] {
        var out: [FileTag] = []
        var index: [String: Int] = [:]
        for tag in tags where !tag.name.isEmpty {
            let key = tag.name.lowercased()
            if let i = index[key] {
                if out[i].color == 0 && tag.color != 0 { out[i] = FileTag(name: out[i].name, color: tag.color) }
            } else {
                index[key] = out.count
                out.append(tag)
            }
        }
        return out
    }
}

// MARK: - The user's names for the colour tags

/// What the user calls Finder's seven colour tags, by colour number. Finder →
/// Settings → Tags lets them be renamed ("Red" → "Urgent"), and on other
/// languages they have local names. The app fills this from
/// `NSWorkspace.fileLabels`; Core code and tests use `english`.
struct TagColorNames: Hashable, Sendable {
    private let names: [Int: String]

    static let english = TagColorNames(names: FileItem.labelToColorName)

    private init(names: [Int: String]) { self.names = names }

    /// From `NSWorkspace.fileLabels`: indexed by colour number, index 0 being
    /// "None". A blank or missing name falls back to the English one.
    init(fileLabels: [String]) {
        var names = FileItem.labelToColorName
        for color in FileTag.validColors where fileLabels.indices.contains(color) {
            let name = fileLabels[color].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !name.contains("\n") { names[color] = name }
        }
        self.init(names: names)
    }

    func name(for color: Int) -> String { names[color] ?? FileItem.labelToColorName[color] ?? "" }

    /// The colour whose standard tag is called `name`, by the user's name for
    /// it or its English one, or nil for a custom tag.
    func color(named name: String) -> Int? {
        let key = name.lowercased()
        if let hit = names.first(where: { $0.value.lowercased() == key }) { return hit.key }
        return FileItem.colorNameToLabel[key]
    }

    /// True when `tag` is the standard tag for `color`: named as the user names
    /// that colour (or with its English name, as files tagged before a rename,
    /// or by older Selway builds, still are), and carrying that colour or none.
    ///
    /// A custom tag that merely has the colour ("Project" in red) is a different
    /// tag, so it doesn't count: the Tags menu's Red toggles Red, as Finder's
    /// does, and never removes "Project".
    func isStandard(_ tag: FileTag, color: Int) -> Bool {
        guard FileTag.validColors.contains(color), tag.color == 0 || tag.color == color else { return false }
        let key = tag.name.lowercased()
        return key == name(for: color).lowercased()
            || key == FileItem.labelToColorName[color]?.lowercased()
    }

    /// The standard tags in the order Finder's Tags menu and sidebar show them.
    var standardTags: [FileTag] {
        FileItem.colorMenuNumbers.map { FileTag(name: name(for: $0), color: $0) }
    }
}

// MARK: - Reading and writing the stored tags

/// The tags attribute itself. Entries are kept as the strings Finder stored,
/// so whatever Selway doesn't change is written back byte for byte.
enum FinderTagStore {
    static let attributeName = "com.apple.metadata:_kMDItemUserTags"

    /// The stored entries, or nil when the file has no tags attribute. Follows a
    /// symlink to its target, as the system's tag APIs do, unless
    /// `followingLinks` is false (a link into an automount folder, which
    /// following would mount). Throws when the attribute can't be read or isn't
    /// a list of strings, so a caller never overwrites tags it couldn't see.
    static func readEntries(atPath path: String, followingLinks: Bool = true) throws -> [String]? {
        #if os(macOS)
        let options: Int32 = followingLinks ? 0 : XATTR_NOFOLLOW
        for _ in 0..<3 {
            let size = getxattr(path, attributeName, nil, 0, 0, options)
            if size < 0 {
                if errno == ENOATTR { return nil }
                throw posixError(path)
            }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, attributeName, $0.baseAddress, size, 0, options) }
            if read < 0 {
                if errno == ERANGE { continue }   // grew between the two calls
                if errno == ENOATTR { return nil }
                throw posixError(path)
            }
            data.count = read
            return try decode(data)
        }
        throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path])
        #else
        return nil
        #endif
    }

    /// Writes `entries` as Finder does (a binary property list), or removes the
    /// attribute when there are none. Spotlight re-indexes the file's tags from
    /// the attribute on its own.
    static func writeEntries(_ entries: [String], atPath path: String) throws {
        #if os(macOS)
        if entries.isEmpty {
            if removexattr(path, attributeName, 0) != 0 && errno != ENOATTR { throw posixError(path) }
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        let status = data.withUnsafeBytes { setxattr(path, attributeName, $0.baseAddress, data.count, 0, 0) }
        if status != 0 { throw posixError(path) }
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    static func decode(_ data: Data) throws -> [String] {
        if data.isEmpty { return [] }
        guard let list = try PropertyListSerialization.propertyList(from: data, format: nil) as? [Any],
              let entries = list as? [String] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return entries
    }

    #if os(macOS)
    private static func posixError(_ path: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }
    #endif
}

// MARK: - The tags in use on this Mac

/// Turns a Spotlight scan of tagged files into the custom tags the sidebar
/// lists. Spotlight indexes tag names only (kMDItemUserTags), so each name's
/// colour is read from the tags stored on one of its files.
enum TagScan {
    /// One tagged file Spotlight found.
    struct Hit: Sendable {
        let names: [String]
        let path: String
    }

    /// Files tried per name for its colour; a file may have lost the tag since
    /// it was indexed, or carry it without a colour.
    static let samplesPerName = 3

    /// Each name once (without regard to case, first spelling kept), in the
    /// order found, with the first colour its sampled files store for it.
    static func tags(from hits: [Hit],
                     readEntries: (String) -> [String]? = { try? FinderTagStore.readEntries(atPath: $0) }) -> [FileTag] {
        var order: [String] = []
        var found: [String: (name: String, paths: [String])] = [:]
        for hit in hits {
            for name in hit.names where !name.isEmpty {
                let key = name.lowercased()
                if found[key] == nil { order.append(key); found[key] = (name, []) }
                if found[key]!.paths.count < samplesPerName { found[key]!.paths.append(hit.path) }
            }
        }
        var cache: [String: [FileTag]] = [:]
        return order.compactMap { key in
            guard let (name, paths) = found[key] else { return nil }
            for path in paths {
                if cache[path] == nil { cache[path] = (readEntries(path) ?? []).map(FileTag.init(entry:)) }
                if let tag = cache[path]?.first(where: { $0.name.lowercased() == key && $0.color != 0 }) {
                    return FileTag(name: name, color: tag.color)
                }
            }
            return FileTag(name: name, color: 0)
        }
    }
}
