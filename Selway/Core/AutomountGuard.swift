import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Whether a path can be looked at without the automounter mounting
/// something. Looking a name up inside an autofs folder mounts what its map
/// has there (`/net/<host>` mounts that host's NFS exports), and a link can
/// lead into one from anywhere, so `AutomountPaths`' lexical check isn't
/// enough for a path from outside (a `selway://` link): this walks the path
/// one component at a time, with `lstat` and `readlink` only, following
/// links itself, and checks each folder's file system (`statfs`) before
/// anything inside it is looked up. Nothing is ever looked up inside an
/// autofs folder.
///
/// Two short cuts keep a walk cheap, since a listing walks every link in it:
/// - `statfs` runs only where the folder's device (`st_dev`, from the `lstat`
///   the walk makes anyway) differs from its parent's. An autofs folder is a
///   mount of its own, so it always has a device of its own: a child on its
///   parent's device is on its parent's file system, already checked. Where
///   the parent's device isn't known (the first folder below "/"), it runs.
/// - The lexical check runs only `AutomountPaths.maxDepth` components deep:
///   below that its answer is its prefix's, checked on the way down.
///
/// Residual: a direct-map trigger (an `/-` entry in auto_master) is itself
/// the mount point, so the `lstat` of it mounts it; its contents are never
/// looked at, but the mount happens. What the guard can't see: a mount laid
/// over an autofs folder (nullfs, a FUSE bindfs, a union mount) has a device
/// of its own and a type other than "autofs", so a look-up through it isn't
/// caught; and a folder can be swapped between its `lstat` and its `statfs`
/// (by someone already able to change this Mac's files).
enum AutomountGuard {
    enum Kind: Equatable, Sendable { case directory, link, other }

    /// What `lstat` says about a path: its kind and the device it's on.
    struct Entry: Equatable, Sendable {
        var kind: Kind
        var device: UInt64
    }

    /// The look-ups the walk makes, injectable for tests.
    struct FileSystem {
        /// `lstat`: what's at the path itself; nil when nothing is (or it can't be read).
        var entry: (String) -> Entry?
        /// `readlink`: a link's target.
        var readLink: (String) -> String?
        /// `statfs`'s file system type for a folder ("apfs", "autofs"…); nil if unreadable.
        var fileSystemType: (String) -> String?
        /// `realpath`: a folder's path with no links in it; nil if it can't be resolved.
        var realPath: (String) -> String?

        static let live = FileSystem(entry: liveEntry, readLink: liveReadLink,
                                     fileSystemType: liveType, realPath: liveRealPath)
    }

    /// Links followed before giving up, as the kernel's MAXSYMLINKS.
    static let maxLinks = 32

    /// What a walk found.
    enum Verdict: Equatable, Sendable {
        /// The path leads to something that exists, reached safely.
        case safe
        /// Nothing is there (or it can't be read, or a link on the way is
        /// broken), found without looking anything up in an automount folder.
        case missing
        /// The walk stopped before an automount folder (or a folder whose
        /// file system it couldn't read): whether anything is there is unknown.
        case refused
    }

    /// True when `path` (absolute) leads to something that exists, reached
    /// without looking anything up in an autofs folder or in one of the
    /// `AutomountPaths` folders. False for anything else, including a path
    /// that doesn't exist or can't be read: whatever asked is refused.
    ///
    /// Walks from "/", trusting nothing on the way: for a path from outside
    /// (a `selway://` link). A link found in a folder Selway lists goes
    /// through `Seed` instead.
    static func isSafe(_ path: String, fileSystem fs: FileSystem = .live) -> Bool {
        check(path, fileSystem: fs) == .safe
    }

    /// `isSafe`'s walk, saying why a path isn't safe: nothing is there, or
    /// the walk stopped before looking (a path under /net, a link into one).
    /// A path that isn't absolute is refused.
    static func check(_ path: String, fileSystem fs: FileSystem = .live) -> Verdict {
        guard path.hasPrefix("/"), !AutomountPaths.contains(path) else { return .refused }
        guard isNotAutofs("/", fs) else { return .refused }
        var walk = Walk(fs: fs, seed: nil)
        return walk.run(rawComponents(path))
    }

    /// Whether the link at `path` may be followed, walked from the folder
    /// holding it (a `Seed` of `path`'s parent; see there for why that's sound
    /// for any item just read from disk). For a single item; a listing makes
    /// one `Seed` for all its links.
    static func isSafeLink(atPath path: String, fileSystem fs: FileSystem = .live) -> Bool {
        let parts = rawComponents(path)
        guard path.hasPrefix("/"), !parts.isEmpty else { return false }
        return Seed(folder: "/" + parts.dropLast().joined(separator: "/"), fileSystem: fs).allowsLink(atPath: path)
    }

    /// A folder whose links are walked from the folder itself rather than
    /// from "/": a link's own path isn't looked at again, only where its
    /// target leads. The folder is one whose path has already been resolved
    /// by the system (Selway listed it, or just read an item in it), so
    /// whatever that path would mount is mounted already, and resolving it
    /// again (`realpath`, here, once) mounts nothing new. What the walk then
    /// looks up is new: names inside the folder, checked as below.
    ///
    /// - The folder itself must not be autofs (`statfs`, once). A link never
    ///   lives in an autofs folder, so this only fails for odd input; the
    ///   link then gets the walk from "/".
    /// - Going down from it, each folder gets the usual checks (statfs on a
    ///   device change). The lexical check is skipped when the folder is
    ///   itself under an `AutomountPaths` folder (/home/me, already
    ///   mounted): every path below matches it, so it would refuse every
    ///   link there, and the statfs check still finds a nested autofs folder.
    /// - A target's `..` that climbs above the folder reaches an ancestor
    ///   nothing has looked inside yet (`/net/host` above
    ///   `/net/host/export`). Before anything is looked up in it, it must
    ///   not be autofs (statfs), or the link is refused. That's the check
    ///   that matters: looking a name up mounts something only inside an
    ///   autofs folder, and statfs says for certain whether a folder is one,
    ///   where the lexical list only guesses. So an ancestor under /home or
    ///   /net that is a mounted share, not the autofs folder above it, is
    ///   fine: `../lib/x` in a network home's node_modules/.bin is followed.
    ///   Below such an ancestor the lexical check is skipped, as below the
    ///   seed. Each ancestor is checked once per seed.
    ///
    ///   Refusing at any autofs ancestor reached is all a climb needs. The
    ///   walk only ever looks names up in the folder it has reached, so an
    ///   autofs ancestor is refused before anything is looked up in it (a
    ///   climb that would only pass through one is refused too, which is
    ///   stricter than needed). From an ancestor that isn't autofs, going
    ///   down again is the ordinary walk: a child on its device is on its
    ///   file system, and one on another device gets statfs.
    /// - An absolute target starts again from "/", checked once per seed,
    ///   with every check of the walk from "/", the lexical one included.
    ///
    /// Not thread-safe (it remembers those checks): one per listing.
    final class Seed {
        private let folder: String
        private let fs: FileSystem
        private var prepared: Start??
        private var checkedRoot: Bool?
        /// Ancestors checked after a climb, by depth: nil when refused.
        private var ancestors: [Int: Ancestor?] = [:]

        /// An ancestor a climb reached that isn't autofs.
        fileprivate struct Ancestor {
            let device: UInt64
            /// Under an `AutomountPaths` folder: the lexical check is skipped below it.
            let isLexicallyAutomount: Bool
        }

        /// The seed folder, resolved: its parts, the full path at each depth,
        /// its device, and whether it's under an `AutomountPaths` folder.
        fileprivate struct Start {
            let parts: [String]
            let paths: [String]
            let device: UInt64
            let isLexicallyAutomount: Bool
        }

        init(folder: String, fileSystem: FileSystem = .live) {
            self.folder = folder
            self.fs = fileSystem
        }

        /// Whether the link at `path`, an item in this folder (its last
        /// component is the link's name), may be followed.
        func allowsLink(atPath path: String) -> Bool {
            guard let name = AutomountGuard.lastComponent(path) else { return false }
            guard let start = start() else { return AutomountGuard.isSafe(path, fileSystem: fs) }
            var walk = Walk(fs: fs, seed: (self, start))
            return walk.run([name]) == .safe
        }

        private func start() -> Start? {
            if let prepared { return prepared }
            var result: Start?
            if let real = fs.realPath(folder), real.hasPrefix("/"),
               let entry = fs.entry(real), entry.kind == .directory,
               AutomountGuard.isNotAutofs(real, fs) {
                let parts = AutomountGuard.rawComponents(real)
                var paths: [String] = []
                paths.reserveCapacity(parts.count)
                for part in parts { paths.append((paths.last ?? "") + "/" + part) }
                result = Start(parts: parts, paths: paths, device: entry.device,
                               isLexicallyAutomount: AutomountPaths.contains(real))
            }
            prepared = .some(result)
            return result
        }

        /// "/" isn't autofs (for an absolute target, or a climb to it).
        fileprivate func rootIsSafe() -> Bool {
            if let checkedRoot { return checkedRoot }
            let safe = AutomountGuard.isNotAutofs("/", fs)
            checkedRoot = safe
            return safe
        }

        /// The ancestor at `path` (`depth` components) if it's a folder and not
        /// autofs (statfs); nil when it's refused.
        fileprivate func checkAncestor(_ path: String, depth: Int) -> Ancestor? {
            if let known = ancestors[depth] { return known }
            var result: Ancestor?
            if let entry = fs.entry(path), entry.kind == .directory, AutomountGuard.isNotAutofs(path, fs) {
                result = Ancestor(device: entry.device, isLexicallyAutomount: AutomountPaths.contains(path))
            }
            ancestors[depth] = .some(result)
            return result
        }
    }

    /// One walk: the folder reached so far (link-free, each part checked or
    /// part of the seed) and what's left to look up.
    private struct Walk {
        let fs: FileSystem
        let seed: (Seed, Seed.Start)?
        /// The folder reached: its parts, its full path at each depth, and
        /// the device at each depth (nil for a seed ancestor not yet checked).
        var parts: [String] = []
        var paths: [String] = []
        var devices: [UInt64?] = []
        /// The folder the walk last went down from (the seed, or the ancestor
        /// a climb last reached) is under an `AutomountPaths` folder, so is
        /// everything below it: the lexical check would refuse it all, and
        /// is skipped. Never for the walk from "/".
        var skipsLexical = false
        var links = 0

        init(fs: FileSystem, seed: (Seed, Seed.Start)?) {
            self.fs = fs
            self.seed = seed
            if let (_, start) = seed {
                parts = start.parts
                paths = start.paths
                devices = Array(repeating: nil, count: start.parts.count)
                if !devices.isEmpty { devices[devices.count - 1] = start.device }
                skipsLexical = start.isLexicallyAutomount
            }
        }

        /// The device of the folder reached; nil for "/" (never compared:
        /// the first folder below it always gets its statfs).
        private var device: UInt64? { devices.last ?? nil }

        mutating func run(_ components: [String]) -> Verdict {
            var pending = Array(components.reversed())
            while let part = pending.popLast() {
                if part == "." { continue }
                if part == ".." {
                    guard climb() else { return .refused }
                    continue
                }
                let depth = parts.count + 1
                let candidate = (paths.last ?? "") + "/" + part
                if !skipsLexical && depth <= AutomountPaths.maxDepth && AutomountPaths.contains(parts: parts + [part]) {
                    return .refused
                }
                switch fs.entry(candidate) {
                case nil:
                    return .missing
                case let entry? where entry.kind == .link:
                    links += 1
                    guard links <= AutomountGuard.maxLinks, let target = fs.readLink(candidate), !target.isEmpty
                    else { return .missing }
                    if target.hasPrefix("/") {
                        guard toRoot() else { return .refused }
                    }
                    pending += AutomountGuard.rawComponents(target).reversed()
                case let entry? where entry.kind == .directory:
                    if device != entry.device {
                        guard AutomountGuard.isNotAutofs(candidate, fs) else { return .refused }
                    }
                    parts.append(part)
                    paths.append(candidate)
                    devices.append(entry.device)
                default:
                    // A file: nothing below it can be looked up.
                    return pending.isEmpty ? .safe : .missing
                }
            }
            return .safe
        }

        /// `..`: the folder reached holds no links, so its parent is the real
        /// one. Above the seed, each ancestor reached is checked (statfs)
        /// before anything in it is looked up (see Seed).
        private mutating func climb() -> Bool {
            guard !parts.isEmpty else { return true }      // "/.." is "/"
            parts.removeLast()
            paths.removeLast()
            devices.removeLast()
            guard let (seed, _) = seed else { return true }
            if parts.isEmpty {
                skipsLexical = false
                return seed.rootIsSafe()
            }
            // Known: a folder the walk entered, the seed, or an ancestor
            // checked, each below the folder the walk last went down from.
            guard devices[devices.count - 1] == nil else { return true }
            guard let ancestor = seed.checkAncestor(paths[paths.count - 1], depth: parts.count) else { return false }
            devices[devices.count - 1] = ancestor.device
            skipsLexical = ancestor.isLexicallyAutomount
            return true
        }

        /// An absolute link target: back to "/", which a seed checks once.
        private mutating func toRoot() -> Bool {
            parts = []
            paths = []
            devices = []
            guard let (seed, _) = seed else { return true }   // the walk from "/" checked it first
            skipsLexical = false
            return seed.rootIsSafe()
        }
    }

    fileprivate static func isNotAutofs(_ folder: String, _ fs: FileSystem) -> Bool {
        guard let type = fs.fileSystemType(folder) else { return false }
        return type.lowercased() != "autofs"
    }

    /// `path`'s parts between "/" scalars, empty ones left out; "." and ".."
    /// kept, for the walk to apply in order.
    static func rawComponents(_ path: String) -> [String] {
        // Split as UTF-8: a "/" byte is only ever the "/" scalar there.
        path.utf8.split(separator: slash).map { String(Substring($0)) }
    }

    private static let slash = UInt8(ascii: "/")

    /// The last of `path`'s `rawComponents`, without splitting the rest.
    static func lastComponent(_ path: String) -> String? {
        let bytes = path.utf8
        var end = bytes.endIndex
        while end > bytes.startIndex, bytes[bytes.index(before: end)] == slash { end = bytes.index(before: end) }
        guard end > bytes.startIndex else { return nil }
        let start = bytes[..<end].lastIndex(of: slash).map { bytes.index(after: $0) } ?? bytes.startIndex
        return String(Substring(bytes[start..<end]))
    }

    // MARK: The real look-ups

    #if SELWAY_UI_TESTING
    /// UI tests only (UITestHooks, `-SelwayUITestAutofsFolder`): a folder the
    /// real look-ups report as an autofs mount, with a device of its own, so a
    /// test can list a link the guard refuses without going near /net.
    static var uiTestAutofsFolder: String?
    #endif

    private static func liveEntry(_ path: String) -> Entry? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        var device = UInt64(truncatingIfNeeded: st.st_dev)
        #if SELWAY_UI_TESTING
        if path == uiTestAutofsFolder { device = ~device }
        #endif
        switch st.st_mode & S_IFMT {
        case S_IFDIR: return Entry(kind: .directory, device: device)
        case S_IFLNK: return Entry(kind: .link, device: device)
        default:      return Entry(kind: .other, device: device)
        }
    }

    /// nil too for a target that isn't valid UTF-8: decoding would replace
    /// the bad bytes (with U+FFFD), and the walk would look up a name other
    /// than the one the kernel follows.
    static func liveReadLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count >= 0 else { return nil }
        let bytes = buffer.prefix(count).map { UInt8(bitPattern: $0) }
        let target = String(decoding: bytes, as: UTF8.self)
        guard target.utf8.elementsEqual(bytes) else { return nil }
        return target
    }

    private static func liveRealPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func liveType(_ folder: String) -> String? {
        #if SELWAY_UI_TESTING
        if folder == uiTestAutofsFolder { return "autofs" }
        #endif
        #if canImport(Darwin)
        var fs = statfs()
        guard statfs(folder, &fs) == 0 else { return nil }
        return withUnsafeBytes(of: &fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #else
        // Linux (where the tests run in CI): no autofs to look for, so any
        // folder that's there will do; the tests inject their own types.
        return access(folder, F_OK) == 0 ? "linux" : nil
        #endif
    }
}
