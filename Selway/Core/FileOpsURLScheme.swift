import Foundation

// Shared by the app and the Finder Sync extension: the extension builds these
// URLs, the app parses them. Keep this file self-contained (Foundation only, no
// other Selway types) so the extension target can compile it on its own.

/// What a `selway://` link may ask for. Anything else is ignored.
enum FileOpsURLAction: String, CaseIterable, Sendable {
    /// Show a location: navigate to a plain folder, reveal anything else.
    case open
    /// Create "New Folder" inside a folder (forwarded by the Finder extension).
    case newFolder = "new-folder"
    /// Open a Terminal window at a folder (forwarded by the Finder extension).
    case terminal

    /// Actions that change something or start another app, as opposed to only
    /// showing a location. A web page can fire any `selway://` link, so the
    /// app confirms these unless the request came from its own extension.
    var hasSideEffects: Bool { self != .open }
}

struct FileOpsURLRequest: Equatable, Sendable {
    let action: FileOpsURLAction
    /// Absolute, standardized POSIX path.
    let path: String
}

/// Builds and parses `selway://<action>?path=<percent-encoded path>`.
enum FileOpsURLScheme {
    static let scheme = "selway"

    /// Only RFC 3986 unreserved characters and "/" stay literal; everything
    /// else, including "&", "=", "+", "%", "#", "?", ";" and non-ASCII, is
    /// percent-encoded as UTF-8. (`.urlQueryAllowed` leaves "&", "=" and "+"
    /// alone, which cut "/Users/x/R&D" down to "/Users/x/R".)
    static let pathAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")

    static func url(for action: FileOpsURLAction, path: String) -> URL? {
        guard path.hasPrefix("/"),
              let encoded = path.addingPercentEncoding(withAllowedCharacters: pathAllowed)
        else { return nil }
        return URL(string: "\(scheme)://\(action.rawValue)?path=\(encoded)")
    }

    /// Strict parse: known action as the host, exactly one `path` query item
    /// holding an absolute path, and nothing else (no user, port, fragment or
    /// URL path). Returns nil for anything that doesn't fit, and for a path
    /// in an automount folder (`AutomountPaths`). Nothing here reads the disk:
    /// "." and ".." are resolved from the text, so a path that a lookup would
    /// mount is refused before anything looks it up.
    static func parse(_ url: URL) -> FileOpsURLRequest? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == scheme,
              let host = c.host?.lowercased(), let action = FileOpsURLAction(rawValue: host),
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/",
              let items = c.queryItems, items.count == 1, items[0].name == "path",
              let path = items[0].value, path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value == 0 })
        else { return nil }
        let standardized = AutomountPaths.standardized(path)
        guard !AutomountPaths.contains(standardized) else { return nil }
        return FileOpsURLRequest(action: action, path: standardized)
    }
}

/// Folders whose contents the automounter mounts when they're looked at:
/// autofs's `/net` map (each `/net/<host>` an NFS server; off unless turned on
/// in /etc/auto_master), `/Network/Servers`, and `/home` (auto_home, where a
/// network home folder can be). Shared by `selway://` links and Markdown's
/// local images. A lexical first check; `AutomountGuard` (the app's) also
/// walks the path on disk, for links and other maps.
enum AutomountPaths {
    /// Each as lowercased path components.
    static let roots: [[String]] = {
        var roots = [["net"], ["network"]]
        #if os(macOS)
        roots.append(["home"])
        #endif
        return roots
    }()

    /// The same folders seen through the Data volume's own path.
    static let dataVolumePrefix = ["system", "volumes", "data"]

    /// The deepest a path's own components can decide `contains`: a root
    /// under the Data volume's prefix. A longer path matches exactly when its
    /// first `maxDepth` components do.
    static let maxDepth = dataVolumePrefix.count + (roots.map(\.count).max() ?? 0)

    /// The lengths an ASCII first component can have to match (a root's
    /// first, or the Data volume's): a cheap first test.
    private static let firstComponents = Set((roots.compactMap(\.first) + [dataVolumePrefix[0]]).map(\.utf8.count))

    /// `path`'s components between "/" scalars (not Characters: a "/" followed
    /// by a combining mark is still a separator to the file system), with
    /// empty ones and "." left out and ".." taking the one before away.
    static func components(_ path: String) -> [String] {
        var parts: [String] = []
        for part in Array(path.unicodeScalars).split(separator: "/") {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: part)
            let name = String(view)
            switch name {
            case ".":  continue
            case "..": _ = parts.popLast()
            default:   parts.append(name)
            }
        }
        return parts
    }

    /// `path` with "." and ".." resolved and no empty parts, from the text alone.
    static func standardized(_ path: String) -> String {
        "/" + components(path).joined(separator: "/")
    }

    /// True for `path` in or below an automount folder (case ignored, as on
    /// the startup disk; through /System/Volumes/Data too).
    static func contains(_ path: String) -> Bool {
        contains(parts: components(path))
    }

    /// `contains` for a path already split into components, with no "." or
    /// ".." in them. Only its first `maxDepth` components are looked at.
    static func contains(parts: [String]) -> Bool {
        // Most paths start elsewhere: rule them out before lowercasing anything.
        // Only an ASCII name is sure to keep its length lowercased ("K", the
        // Kelvin sign, lowercases to "k").
        guard let first = parts.first else { return false }
        if first.utf8.allSatisfy({ $0 < 0x80 }), !firstComponents.contains(first.utf8.count) { return false }
        var parts = parts.prefix(maxDepth).map { $0.lowercased() }
        if parts.starts(with: dataVolumePrefix) { parts.removeFirst(dataVolumePrefix.count) }
        return roots.contains { parts.starts(with: $0) }
    }
}
