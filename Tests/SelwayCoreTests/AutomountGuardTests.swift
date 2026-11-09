import Foundation
import Testing
#if canImport(Glibc)
import Glibc
#endif
@testable import SelwayCore

/// A made-up file system that records every path looked up, so the tests can
/// check nothing is ever looked up inside an autofs folder. Every path is on
/// device 1 except each autofs folder, a mount with a device of its own (as a
/// real one is), unless a test sets `devices`.
private final class FakeFileSystem {
    var kinds: [String: AutomountGuard.Kind] = [:]
    var links: [String: String] = [:]
    var types: [String: String] = [:]
    var devices: [String: UInt64] = [:]
    var unreadableTypes: Set<String> = []
    private(set) var lookedUp: [String] = []
    private(set) var statfsed: [String] = []

    init(folders: [String], files: [String] = [], links: [String: String] = [:], autofs: [String] = []) {
        for folder in folders { kinds[folder] = .directory }
        for file in files { kinds[file] = .other }
        for (path, target) in links { kinds[path] = .link; self.links[path] = target }
        for (i, folder) in autofs.enumerated() { types[folder] = "autofs"; devices[folder] = 100 + UInt64(i) }
    }

    var fileSystem: AutomountGuard.FileSystem {
        AutomountGuard.FileSystem(
            entry: { [unowned self] path in
                self.lookedUp.append(path)
                guard let kind = self.kinds[path] ?? (path == "/" ? .directory : nil) else { return nil }
                return AutomountGuard.Entry(kind: kind, device: self.devices[path] ?? 1)
            },
            readLink: { [unowned self] in self.links[$0] },
            fileSystemType: { [unowned self] in
                self.statfsed.append($0)
                return self.unreadableTypes.contains($0) ? nil : (self.types[$0] ?? "apfs")
            },
            // The tests' seed folders hold no links.
            realPath: { [unowned self] in self.kinds[$0] == .directory || $0 == "/" ? $0 : nil })
    }

    func lookedInside(_ folder: String) -> Bool { lookedUp.contains { $0.hasPrefix(folder + "/") } }
}

/// A FileManager that records the paths the policy looks up through it, for
/// one test on one thread. (`fileExists(atPath:isDirectory:)` can't be
/// overridden on Linux.)
private final class RecordingFileManager: FileManager, @unchecked Sendable {
    private(set) var lookedUp: [String] = []
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        lookedUp.append(path)
        return try super.attributesOfItem(atPath: path)
    }
    override func fileExists(atPath path: String) -> Bool {
        lookedUp.append(path)
        return super.fileExists(atPath: path)
    }
}

@Suite struct AutomountGuardTests {
    @Test func anOrdinaryPathIsSafe() {
        let fs = FakeFileSystem(folders: ["/Users", "/Users/me", "/Users/me/Docs"], files: ["/Users/me/Docs/a.txt"])
        #expect(AutomountGuard.isSafe("/Users/me/Docs", fileSystem: fs.fileSystem))
        #expect(AutomountGuard.isSafe("/Users/me/Docs/a.txt", fileSystem: fs.fileSystem))
        #expect(AutomountGuard.isSafe("/", fileSystem: fs.fileSystem))
    }

    /// A custom map (auto_master) Selway's list doesn't know: its folder is
    /// autofs, so nothing in it is looked up.
    @Test func nothingInsideAnAutofsFolderIsLookedUp() {
        let fs = FakeFileSystem(folders: ["/mnt", "/mnt/auto"], autofs: ["/mnt/auto"])
        #expect(!AutomountGuard.isSafe("/mnt/auto/evil.example/x", fileSystem: fs.fileSystem))
        #expect(!AutomountGuard.isSafe("/mnt/auto", fileSystem: fs.fileSystem))
        #expect(!fs.lookedInside("/mnt/auto"))
    }

    @Test func aLinkIntoAnAutofsFolderIsRefused() {
        let fs = FakeFileSystem(folders: ["/Users", "/Users/me", "/mnt", "/mnt/auto"],
                                links: ["/Users/me/innocent": "/mnt/auto/evil.example/export"],
                                autofs: ["/mnt/auto"])
        #expect(!AutomountGuard.isSafe("/Users/me/innocent/sub", fileSystem: fs.fileSystem))
        #expect(!fs.lookedInside("/mnt/auto"))
    }

    @Test func linksIntoTheKnownAutomountFoldersAreRefusedWithoutLookingThere() {
        let fs = FakeFileSystem(folders: ["/Users", "/Users/me", "/Users/me/a"],
                                links: ["/Users/me/a/abs": "/net/evil/x", "/Users/me/a/rel": "../../../net/evil",
                                        "/Users/me/a/data": "/System/Volumes/Data/Network/Servers/x",
                                        "/Users/me/a/mark": "/net/\u{301}evil"])
        for link in ["abs", "rel", "data", "mark"] {
            #expect(!AutomountGuard.isSafe("/Users/me/a/\(link)", fileSystem: fs.fileSystem))
        }
        #expect(!fs.lookedUp.contains { $0.lowercased().contains("/net") || $0.contains("/Network") })
    }

    @Test func aLinkWithDotDotResolvesFromWhereItReallyIs() {
        // /a/l -> /b/c, so /a/l/../d is /b/d (not /a/d).
        let fs = FakeFileSystem(folders: ["/a", "/b", "/b/c", "/b/d", "/b/auto"],
                                links: ["/a/l": "/b/c", "/a/m": "/b/c/../auto/x"], autofs: ["/b/auto"])
        #expect(AutomountGuard.isSafe("/a/l/../d", fileSystem: fs.fileSystem))
        #expect(!AutomountGuard.isSafe("/a/m", fileSystem: fs.fileSystem))
        #expect(!fs.lookedInside("/b/auto"))
    }

    @Test func whatCantBeWalkedIsRefused() {
        let fs = FakeFileSystem(folders: ["/a", "/a/unreadable"], files: ["/a/file"],
                                links: ["/a/loop1": "/a/loop2", "/a/loop2": "/a/loop1", "/a/empty": ""])
        // A mount (its own device) whose file system can't be read.
        fs.unreadableTypes = ["/a/unreadable"]
        fs.devices["/a/unreadable"] = 7
        #expect(!AutomountGuard.isSafe("/a/missing", fileSystem: fs.fileSystem))
        #expect(!AutomountGuard.isSafe("/a/file/below", fileSystem: fs.fileSystem))
        #expect(!AutomountGuard.isSafe("/a/loop1", fileSystem: fs.fileSystem))
        #expect(!AutomountGuard.isSafe("/a/empty", fileSystem: fs.fileSystem))
        #expect(!AutomountGuard.isSafe("/a/unreadable", fileSystem: fs.fileSystem))
        #expect(!AutomountGuard.isSafe("relative", fileSystem: fs.fileSystem))
        let autofsRoot = FakeFileSystem(folders: ["/a"], autofs: ["/"])
        #expect(!AutomountGuard.isSafe("/a", fileSystem: autofsRoot.fileSystem))
        #expect(autofsRoot.lookedUp.isEmpty)
    }

    /// The real file system: a link to /net in a temporary folder. The walk
    /// refuses it from the link's text, without looking at /net.
    @Test func aRealLinkToNetIsRefusedAndTheLinkPolicyIgnoresIt() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let link = try dir.link("to-net", to: "/net/selway-test.invalid/export")
        let plain = try dir.dir("plain")
        #expect(!AutomountGuard.isSafe(link.path))
        #expect(AutomountGuard.isSafe(plain.path))
        let request = FileOpsURLRequest(action: .open, path: link.path)
        #expect(FileOpsURLPolicy.decide(request, fromOwnExtension: true) == .ignore)
        let terminal = FileOpsURLRequest(action: .terminal, path: link.path + "/sub")
        #expect(FileOpsURLPolicy.decide(terminal, fromOwnExtension: false) == .ignore)
    }

    /// A real folder, so the rest of the policy would act on it: only the
    /// walk, told its parent is autofs, stops it, and before the policy
    /// looks the path up itself.
    @Test func thePolicyAsksTheWalkBeforeAnythingElse() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let auto = try dir.dir("auto")
        let target = try dir.dir("auto/evil")
        var ancestors: [String] = []
        for part in AutomountGuard.rawComponents(dir.url.path) { ancestors.append((ancestors.last ?? "") + "/" + part) }
        let folders = ancestors + [auto.path, target.path]
        let request = FileOpsURLRequest(action: .newFolder, path: target.path)
        let plain = FakeFileSystem(folders: folders)
        let plainManager = RecordingFileManager()
        let performed = FileOpsURLPolicy.decide(request, fromOwnExtension: true, fileManager: plainManager,
                                                fileSystem: plain.fileSystem)
        guard case .perform(.newFolder, let folder, confirm: false) = performed else {
            Issue.record("expected the action to run, got \(performed)")
            return
        }
        #expect(folder.path == target.path)
        #expect(!plainManager.lookedUp.isEmpty)
        let fs = FakeFileSystem(folders: folders, autofs: [auto.path])
        let manager = RecordingFileManager()
        #expect(FileOpsURLPolicy.decide(request, fromOwnExtension: true, fileManager: manager,
                                        fileSystem: fs.fileSystem) == .ignore)
        #expect(!fs.lookedInside(auto.path))
        #expect(manager.lookedUp.isEmpty)
    }

    // MARK: Seeded walks (links in a listed folder)

    /// A relative link to a sibling is checked from the folder holding it:
    /// the folder's ancestors are never looked at, and a folder on the same
    /// device as its parent isn't statfs'd.
    @Test func aSeededLinkToASiblingLooksOnlyInsideTheFolder() {
        let fs = FakeFileSystem(folders: ["/Users", "/Users/me", "/Users/me/proj", "/Users/me/proj/sib"],
                                links: ["/Users/me/proj/l": "sib", "/Users/me/proj/m": "./sib/../sib"])
        let seed = AutomountGuard.Seed(folder: "/Users/me/proj", fileSystem: fs.fileSystem)
        #expect(seed.allowsLink(atPath: "/Users/me/proj/l"))
        #expect(seed.allowsLink(atPath: "/Users/me/proj/m"))
        #expect(Set(fs.lookedUp) == ["/Users/me/proj", "/Users/me/proj/l", "/Users/me/proj/m", "/Users/me/proj/sib"])
        #expect(fs.statfsed == ["/Users/me/proj"])
    }

    /// A `..` that climbs above the folder reaches a folder nothing looked
    /// inside: it's statfs'd before anything in it is looked up, and the
    /// link is refused at the first autofs folder it reaches.
    @Test func aClimbAboveTheSeedIntoAnAutomountFolderIsRefused() {
        let fs = FakeFileSystem(folders: ["/mnt", "/mnt/auto", "/mnt/auto/host", "/mnt/auto/host/dir",
                                          "/net", "/net/host", "/net/host/export", "/net/host/export/dir"],
                                links: ["/mnt/auto/host/dir/up": "../../other/x",
                                        "/net/host/export/dir/up": "../../other/x"],
                                autofs: ["/mnt/auto", "/net", "/net/host"])
        fs.devices["/mnt/auto/host"] = 5          // the share mounted there
        fs.devices["/mnt/auto/host/dir"] = 5
        fs.devices["/net/host/export"] = 6
        fs.devices["/net/host/export/dir"] = 6
        // A map Selway's list doesn't know, and /net: the mounted share is
        // passed, the autofs folder above it isn't.
        for folder in ["/mnt/auto/host/dir", "/net/host/export/dir"] {
            let seed = AutomountGuard.Seed(folder: folder, fileSystem: fs.fileSystem)
            #expect(!seed.allowsLink(atPath: folder + "/up"))
        }
        #expect(Set(fs.statfsed).isSuperset(of: ["/mnt/auto/host", "/mnt/auto", "/net/host/export", "/net/host"]))
        #expect(!fs.lookedUp.contains { $0.hasSuffix("/other") || $0.hasSuffix("/other/x") })
    }

    /// A climb to an ordinary folder is fine, and each ancestor is checked
    /// once for the whole listing.
    @Test func aClimbToAnOrdinaryFolderIsCheckedOnce() {
        let fs = FakeFileSystem(folders: ["/Users", "/Users/me", "/Users/me/proj", "/Users/me/lib"],
                                files: ["/Users/me/lib/a", "/Users/me/lib/b"],
                                links: ["/Users/me/proj/a": "../lib/a", "/Users/me/proj/b": "../lib/b"])
        let seed = AutomountGuard.Seed(folder: "/Users/me/proj", fileSystem: fs.fileSystem)
        #expect(seed.allowsLink(atPath: "/Users/me/proj/a"))
        #expect(seed.allowsLink(atPath: "/Users/me/proj/b"))
        #expect(fs.statfsed.filter { $0 == "/Users/me" }.count == 1)
        #expect(!fs.lookedUp.contains("/Users"))
    }

    /// Folders under an automount folder (a network home, an NFS export
    /// under /net): a link there to somewhere local is followed, where the
    /// walk from "/" refuses it for its own path.
    @Test(arguments: automountedFolders)
    func aLinkInAnAutomountedFolderToALocalPlaceIsFollowed(folder: String) {
        let parts = AutomountGuard.rawComponents(folder)
        let ancestors = parts.indices.map { "/" + parts[...$0].joined(separator: "/") }
        let fs = FakeFileSystem(folders: ancestors + [folder + "/sub", "/Users", "/Users/me"],
                                files: [folder + "/sub/f", "/Users/me/x"],
                                links: [folder + "/abs": "/Users/me/x", folder + "/rel": "sub/f"])
        let seed = AutomountGuard.Seed(folder: folder, fileSystem: fs.fileSystem)
        #expect(seed.allowsLink(atPath: folder + "/abs"))
        #expect(seed.allowsLink(atPath: folder + "/rel"))
        #expect(!AutomountGuard.isSafe(folder + "/abs", fileSystem: fs.fileSystem))
        #expect(AutomountGuard.isSafeLink(atPath: folder + "/rel", fileSystem: fs.fileSystem))
    }

    /// A climb to an ancestor under /home or /net that statfs says is a
    /// mounted share, not autofs, is followed, and so is the way back down
    /// (`../lib/x` in a network home's node_modules/.bin): only statfs
    /// decides on a climb, and below an ancestor under an automount folder
    /// the lexical check is skipped, as below the seed.
    @Test(arguments: automountedFolders)
    func aClimbToAMountedShareUnderAnAutomountFolderIsFollowed(folder: String) {
        let parts = AutomountGuard.rawComponents(folder)
        let ancestors = parts.indices.map { "/" + parts[...$0].joined(separator: "/") }
        let fs = FakeFileSystem(folders: ancestors + [folder + "/.bin", folder + "/lib"],
                                files: [folder + "/lib/x"],
                                links: [folder + "/.bin/x": "../lib/x"])
        let seed = AutomountGuard.Seed(folder: folder + "/.bin", fileSystem: fs.fileSystem)
        #expect(seed.allowsLink(atPath: folder + "/.bin/x"))
        #expect(fs.statfsed.contains(folder))
        // Once per seed.
        #expect(seed.allowsLink(atPath: folder + "/.bin/x"))
        #expect(fs.statfsed.filter { $0 == folder }.count == 1)
    }

    /// Below an ancestor a climb reached, the lexical check is on or off as
    /// that ancestor says, not as the seed did: from a seed under /net, a
    /// climb to the Data volume's root, or to "/", then into net/… is
    /// refused by the lexical check (statfs alone would pass these folders,
    /// all ordinary here).
    @Test func aClimbOutOfAnAutomountFolderTurnsTheLexicalCheckBackOn() {
        let seed = "/System/Volumes/Data/net/host/export/dir"
        let parts = AutomountGuard.rawComponents(seed)
        let ancestors = parts.indices.map { "/" + parts[...$0].joined(separator: "/") }
        let fs = FakeFileSystem(folders: ancestors + ["/System/Volumes/Data/net/other", "/net", "/net/other"],
                                links: [seed + "/toData": "../../../../net/other",
                                        seed + "/toRoot": String(repeating: "../", count: 8) + "net/other"])
        let listing = AutomountGuard.Seed(folder: seed, fileSystem: fs.fileSystem)
        #expect(!listing.allowsLink(atPath: seed + "/toData"))
        #expect(!listing.allowsLink(atPath: seed + "/toRoot"))
        // Every ancestor under /net, up to "/" itself.
        for folder in ["/net/host", "/net/host/export", "/net/host/export/dir"] { fs.kinds[folder] = .directory }
        fs.kinds["/net/host/export/dir/up"] = .link
        fs.links["/net/host/export/dir/up"] = "../../../../net/other"
        #expect(!AutomountGuard.Seed(folder: "/net/host/export/dir", fileSystem: fs.fileSystem)
            .allowsLink(atPath: "/net/host/export/dir/up"))
        #expect(!fs.lookedUp.contains { $0.hasSuffix("/net/other") })
    }

    /// A link whose target isn't valid UTF-8 is refused: decoded, the bad
    /// bytes would become U+FFFD, and the walk would look up another name
    /// (here a folder that is there) than the one the kernel follows.
    @Test func aLinkTargetThatIsntUTF8IsRefused() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        try dir.dir("\u{FFFD}bad")
        let link = dir.url.appendingPathComponent("link").path
        let target: [CChar] = [CChar(bitPattern: 0xFF), 0x62, 0x61, 0x64, 0]
        try #require(symlink(target, link) == 0)
        #expect(AutomountGuard.FileSystem.live.readLink(link) == nil)
        #expect(!AutomountGuard.Seed(folder: dir.url.path).allowsLink(atPath: link))
        try FileManager.default.createSymbolicLink(atPath: dir.url.appendingPathComponent("good").path,
                                                   withDestinationPath: "\u{FFFD}bad")
        #expect(AutomountGuard.Seed(folder: dir.url.path).allowsLink(atPath: dir.url.appendingPathComponent("good").path))
    }

    static var automountedFolders: [String] {
        var folders = ["/net/host/export", "/Network/Servers/host/Users/me",
                       "/System/Volumes/Data/net/host/export"]
        #if os(macOS)
        folders.append("/home/me")
        #endif
        return folders
    }

    /// A folder that can't be resolved or is autofs isn't a seed: its links
    /// get the walk from "/".
    @Test func aFolderThatCantSeedFallsBackToTheWalkFromRoot() {
        let fs = FakeFileSystem(folders: ["/a", "/a/sub"], links: ["/a/l": "sub", "/mnt/auto/l": "/a/sub"],
                                autofs: ["/a"])
        #expect(!AutomountGuard.Seed(folder: "/a", fileSystem: fs.fileSystem).allowsLink(atPath: "/a/l"))
        #expect(!AutomountGuard.Seed(folder: "/missing", fileSystem: fs.fileSystem).allowsLink(atPath: "/missing/l"))
        #expect(!fs.lookedUp.contains("/a/l"))
    }

    // MARK: The device short cut

    /// statfs runs where the device changes, and only there: a mount with a
    /// device of its own is checked, and found autofs.
    @Test func aDeviceChangeIsAlwaysStatfsed() {
        let fs = FakeFileSystem(folders: ["/a", "/a/b", "/a/b/m", "/a/b/c"], autofs: ["/a/b/m"])
        #expect(!AutomountGuard.isSafe("/a/b/m/x", fileSystem: fs.fileSystem))
        #expect(!fs.lookedInside("/a/b/m"))
        #expect(AutomountGuard.isSafe("/a/b/c", fileSystem: fs.fileSystem))
        // "/" first, then "/a" (the first folder: no parent device to compare),
        // then only the mount.
        #expect(fs.statfsed == ["/", "/a", "/a/b/m", "/", "/a"])
    }

    /// Where the short cut's assumption would fail, an autofs folder on its
    /// parent's device, the first folder below "/" is still statfs'd: there's
    /// no parent device it could be compared with.
    @Test func theFirstFolderIsStatfsedWhateverItsDevice() {
        let fs = FakeFileSystem(folders: ["/auto"], autofs: ["/auto"])
        fs.devices["/auto"] = 1                    // as "/"'s
        #expect(!AutomountGuard.isSafe("/auto/host", fileSystem: fs.fileSystem))
        let seed = AutomountGuard.Seed(folder: "/", fileSystem: fs.fileSystem)
        fs.kinds["/l"] = .link
        fs.links["/l"] = "auto/host"
        #expect(!seed.allowsLink(atPath: "/l"))
        #expect(!fs.lookedInside("/auto"))
    }

    // MARK: The lexical check

    @Test func theLexicalCheckLooksOnlyAsDeepAsItCanMatch() {
        #expect(AutomountPaths.maxDepth == 4)
        #expect(AutomountPaths.contains(parts: ["System", "Volumes", "Data", "Network", "x", "y"]))
        #expect(AutomountPaths.contains(parts: ["NET"]))
        #expect(AutomountPaths.contains(parts: ["Networ\u{212A}"]))       // Kelvin sign: lowercases to "k"
        #expect(!AutomountPaths.contains(parts: ["System", "Volumes", "Data", "Users", "net"]))
        #expect(!AutomountPaths.contains(parts: ["Users", "net"]))
        #expect(!AutomountPaths.contains(parts: []))
        #expect(AutomountGuard.lastComponent("/a/b//") == "b")
        #expect(AutomountGuard.lastComponent("/a/\u{301}b") == "\u{301}b")
        #expect(AutomountGuard.lastComponent("/") == nil)
    }

    // MARK: Why a path isn't safe (check)

    /// Nothing there, found without going near an automount folder.
    @Test func aPathThatIsntThereIsMissing() {
        let fs = FakeFileSystem(folders: ["/Users", "/Users/me"], files: ["/Users/me/a.txt"],
                                links: ["/Users/me/broken": "/Users/me/gone"])
        #expect(AutomountGuard.check("/Users/me", fileSystem: fs.fileSystem) == .safe)
        #expect(AutomountGuard.check("/Users/me/gone", fileSystem: fs.fileSystem) == .missing)
        #expect(AutomountGuard.check("/Users/me/broken", fileSystem: fs.fileSystem) == .missing)
        #expect(AutomountGuard.check("/Users/me/a.txt/x", fileSystem: fs.fileSystem) == .missing)
    }

    /// Whether anything is there is unknown: the walk stopped before looking.
    /// /home is an automount folder on macOS only (auto_home); on Linux it
    /// holds the local users' folders, walked like any other.
    @Test func aPathTheWalkWontLookAtIsRefused() {
        let fs = FakeFileSystem(folders: ["/Users", "/Users/me", "/mnt", "/mnt/auto"],
                                links: ["/Users/me/nfs": "/net/host/export", "/Users/me/map": "/mnt/auto/x"],
                                autofs: ["/mnt/auto"])
        for path in Self.automountedFolders + ["/mnt/auto/x", "/Users/me/nfs/sub", "/Users/me/map", "relative/path"] {
            #expect(AutomountGuard.check(path, fileSystem: fs.fileSystem) == .refused, "\(path)")
        }
        #expect(!fs.lookedInside("/mnt/auto"))
        #expect(!fs.lookedUp.contains { AutomountPaths.contains($0) })
        #if !os(macOS)
        #expect(AutomountGuard.check("/home/me", fileSystem: fs.fileSystem) == .missing)
        #endif
    }

    /// A folder whose file system can't be read is refused, not missing: it
    /// may be there.
    @Test func aFolderWhoseFileSystemCantBeReadIsRefused() {
        let fs = FakeFileSystem(folders: ["/Volumes", "/Volumes/X", "/Volumes/X/a"])
        fs.devices["/Volumes/X"] = 7
        fs.unreadableTypes = ["/Volumes/X"]
        #expect(AutomountGuard.check("/Volumes/X/a", fileSystem: fs.fileSystem) == .refused)
    }
}
