import Foundation

/// A folder of known files for one test, created by the test runner and removed
/// afterwards.
///
/// Where: `/private/tmp/studio.irq.selway.uitests/SelwayUITests-<UUID>/`. Not the
/// runner's own temporary folder: Xcode signs UI test runners into the App
/// Sandbox, so that folder is inside the runner's container, and the app under
/// test opening another app's container makes macOS ask for permission ("would
/// like to access data from other apps"). The runner may write only here (the
/// one exception in SelwayUITests.entitlements); the app, which isn't sandboxed,
/// reads and writes it freely. /private/tmp is on the internal disk, away from
/// the symlinked home folders (~/Downloads and others point at another volume on
/// this Mac), and paths are canonical (`realpath`), so what the app is told to
/// open is exactly the folder made here.
struct Fixture {
    /// Holds `root` and any sibling folders a test needs; `remove()` deletes it.
    let container: URL
    /// The folder the app opens.
    let root: URL

    /// The root's name, and so the browser window's title.
    static let rootName = "SelwayFixture"
    /// Every container goes in here (the path SelwayUITests.entitlements allows).
    static let base = URL(fileURLWithPath: "/private/tmp/studio.irq.selway.uitests", isDirectory: true)
    /// The prefix that marks a container as ours; `remove()` deletes nothing else.
    private static let containerPrefix = "SelwayUITests-"

    /// The standard files, sorted by name, with sizes that differ so the status
    /// bar's selection total says which files are selected: any one, two or all
    /// three of them add up to a different number of bytes.
    static let files: [(name: String, size: Int)] = [("alpha.txt", 100), ("beta.txt", 200), ("gamma.txt", 400)]
    /// The standard folder, listed first (folders on top). It holds `innerFile`.
    static let folder = "subfolder"
    static let innerFile = "inner.txt"
    /// What the root lists with the standard contents, in order.
    static let standardListing = [folder] + files.map(\.name)

    /// An empty root in a new container.
    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.base, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let base = URL(fileURLWithPath: Self.canonicalPath(Self.base.path), isDirectory: true)
        container = base.appendingPathComponent(Self.containerPrefix + UUID().uuidString, isDirectory: true)
        root = container.appendingPathComponent(Self.rootName, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// `subfolder/inner.txt`, `alpha.txt`, `beta.txt` and `gamma.txt` in the root.
    func makeStandardContents() throws {
        let folder = try makeFolder(Self.folder)
        try makeFile(Self.innerFile, size: 10, in: folder)
        for file in Self.files { try makeFile(file.name, size: file.size) }
    }

    @discardableResult
    func makeFolder(_ name: String, in parent: URL? = nil) throws -> URL {
        let url = (parent ?? root).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A folder next to the root, inside the container (not listed in the root).
    func makeSibling(_ name: String) throws -> URL {
        try makeFolder(name, in: container)
    }

    @discardableResult
    func makeFile(_ name: String, size: Int, in parent: URL? = nil) throws -> URL {
        let url = (parent ?? root).appendingPathComponent(name, isDirectory: false)
        try Data(repeating: UInt8(ascii: "x"), count: size).write(to: url)
        return url
    }

    /// Every folder inside the container, at any depth, by canonical path.
    func allFolders() -> Set<String> {
        var found = Set<String>()
        let enumerator = FileManager.default.enumerator(at: container, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                found.insert(Self.canonicalPath(url.path))
            }
        }
        return found
    }

    func exists(_ relativePath: String, in parent: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (parent ?? root).appendingPathComponent(relativePath).path)
    }

    /// Deletes the container, and only ever a container this type made in `base`.
    func remove() {
        guard container.lastPathComponent.hasPrefix(Self.containerPrefix),
              container.deletingLastPathComponent().path == Self.canonicalPath(Self.base.path) else { return }
        try? FileManager.default.removeItem(at: container)
    }

    /// `path` with every symlink resolved (/var → /private/var).
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
