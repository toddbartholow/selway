import Foundation

/// Path-based identity for file URLs.
///
/// Two URLs naming the same item often differ as values: `contentsOfDirectory`
/// returns folders with a trailing slash ("dir/") but symlinks without one, and
/// `URL(fileURLWithPath:)` / `appendingPathComponent` add or omit the slash
/// depending on what is on disk. Comparing URLs with `==` therefore misses
/// matches (a newly created folder never gets selected, the column trail
/// collapses). Compare `ShellPath.key` values instead.
///
/// Keys are logical: symlinks are NOT resolved, so a folder browsed through a
/// symlink keeps the path the user opened.
enum ShellPath {

    /// Canonical comparison key: standardized absolute path, no trailing slash.
    ///
    /// Purely lexical (no disk access): `standardizedFileURL` also strips a
    /// leading "/private" but only while the path exists, so a folder under
    /// /private/var got one key while it existed and another once deleted, and
    /// anything keyed on it (directory watches) could never be released.
    static func key(_ url: URL) -> String {
        let p = url.absoluteURL.standardized.path
        if p.isEmpty { return "/" }
        if p.count > 1, p.hasSuffix("/") { return String(p.dropLast()) }
        return p
    }

    static func same(_ a: URL?, _ b: URL?) -> Bool {
        switch (a, b) {
        case (nil, nil):              return true
        case let (a?, b?):            return key(a) == key(b)
        default:                      return false
        }
    }

    /// True when `child` sits directly inside `parent`.
    static func isParent(_ parent: URL, of child: URL) -> Bool {
        let c = key(child)
        guard c != "/" else { return false }
        return parentKey(ofKey: c) == key(parent)
    }

    /// True when `url` is `folder` or anywhere below it (lexical, like `key`).
    static func isSameOrInside(_ url: URL, _ folder: URL) -> Bool {
        let u = key(url), f = key(folder)
        return u == f || u.hasPrefix(f == "/" ? "/" : f + "/")
    }

    static func contains(_ urls: [URL], _ url: URL) -> Bool {
        firstIndex(of: url, in: urls) != nil
    }

    static func firstIndex(of url: URL, in urls: [URL]) -> Int? {
        let k = key(url)
        return urls.firstIndex { key($0) == k }
    }

    /// Root-to-`url` chain ("/", "/a", "/a/b") built from path components only —
    /// no disk access and no symlink resolution.
    static func ancestorChain(_ url: URL) -> [URL] {
        let k = key(url)
        var chain = [URL(fileURLWithPath: "/", isDirectory: true)]
        guard k != "/" else { return chain }
        var path = ""
        for component in k.split(separator: "/") {
            path += "/" + component
            chain.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        return chain
    }

    /// Closest ancestor of `url` (or `url` itself) for which `exists` is true;
    /// used when the folder being shown is deleted or renamed underneath us.
    static func nearestExistingAncestor(of url: URL, exists: (String) -> Bool) -> URL? {
        for candidate in ancestorChain(url).reversed() where exists(key(candidate)) {
            return candidate
        }
        return nil
    }

    /// The folder a path typed into the path bar names. Absolute paths stand on
    /// their own; relative ones ("sub", "../other") are relative to `folder`,
    /// the folder being shown. `folder` is treated as a directory even without a
    /// trailing slash: a folder reached through a symlink is listed without one,
    /// and plain `URL(fileURLWithPath:relativeTo:)` then resolves against its
    /// parent ("sub" opened a sibling). Tilde expansion is the caller's job.
    static func resolveTyped(_ typed: String, relativeTo folder: URL) -> URL {
        let resolved: URL
        if typed.hasPrefix("/") {
            resolved = URL(fileURLWithPath: typed)
        } else {
            resolved = URL(fileURLWithPath: key(folder), isDirectory: true)
                .appendingPathComponent(typed)
        }
        return URL(fileURLWithPath: key(resolved))
    }

    /// `url` with every link in its path followed, read one component at a
    /// time with `readLink` (a link's target, nil for anything else). Unlike
    /// `resolvingSymlinksInPath`, what a link points to needn't exist, so a
    /// link to an ejected drive still leads there. Paths `skip` says no to
    /// aren't read: they're kept as they are, with the rest of the path.
    static func followingLinks(_ url: URL, readLink: (String) -> String?,
                               skip: (URL) -> Bool = { _ in false }) -> URL {
        var pending = key(url).split(separator: "/").map(String.init)
        var resolved = ""
        // A loop of links (a -> b -> a) stops following after this many.
        var hops = 0
        while !pending.isEmpty {
            let candidate = resolved + "/" + pending.removeFirst()
            // `isDirectory:` given, so building the URL doesn't look at the disk
            // (it would to decide on a trailing slash), skipped paths included.
            if hops < 40, !skip(URL(fileURLWithPath: candidate, isDirectory: false)),
               let target = readLink(candidate) {
                hops += 1
                // A relative target is relative to the link's folder.
                let base = target.hasPrefix("/") ? "" : resolved + "/"
                pending = key(URL(fileURLWithPath: base + target, isDirectory: false))
                    .split(separator: "/").map(String.init) + pending
                resolved = ""
            } else {
                resolved = candidate
            }
        }
        return URL(fileURLWithPath: resolved.isEmpty ? "/" : resolved, isDirectory: false)
    }

    private static func parentKey(ofKey k: String) -> String {
        guard let slash = k.lastIndex(of: "/") else { return "/" }
        let parent = String(k[..<slash])
        return parent.isEmpty ? "/" : parent
    }
}
