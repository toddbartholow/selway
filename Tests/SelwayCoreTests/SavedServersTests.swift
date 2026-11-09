import Foundation
import Testing
@testable import SelwayCore

private func address(_ text: String) throws -> ServerAddress {
    try ServerAddress.parse(text).get().address
}

@Suite struct RecentServersTests {
    @Test func newestFirstDeduplicatedAndCapped() throws {
        var list: [ServerAddress] = []
        for i in 0..<15 { list = RecentServers.adding(try address("smb://nas\(i)/share"), to: list) }
        #expect(list.count == RecentServers.limit && RecentServers.limit == 10)
        #expect(list.first?.host == "nas14" && list.last?.host == "nas5")
        // The same server and share again (another spelling, another user) moves to the top.
        list = RecentServers.adding(try address("SMB://alex@NAS9:445/SHARE"), to: list)
        #expect(list.count == 10 && list.first?.user == "alex")
        #expect(list.filter { $0.matchKey == (try? address("smb://nas9/share"))?.matchKey }.count == 1)
    }

    @Test func storedWithoutPasswordsAndReadBack() throws {
        let d = TestDefaults(); defer { d.cleanup() }
        let typed = try ServerAddress.parse("smb://alex:hunter2@nas/My Share").get().address
        RecentServers.save([typed], to: d.defaults)
        let stored = d.defaults.stringArray(forKey: RecentServers.defaultsKey) ?? []
        #expect(stored == ["smb://alex@nas/My%20Share"])
        #expect(!stored.joined().contains("hunter2"))
        #expect(RecentServers.load(from: d.defaults) == [typed])
    }

    /// Edited or corrupt preferences: anything that isn't an allowed address
    /// goes, so the list can't offer a `file:` or `vnc:` link.
    @Test func corruptOrDisallowedEntriesAreDropped() throws {
        let d = TestDefaults(); defer { d.cleanup() }
        d.defaults.set(["smb://nas/a", "file:///etc", "", "vnc://mac", "javascript:alert(1)", "smb://nas/A",
                        "smb://user:pw@nas/b", "nfs://n/e"] as [Any], forKey: RecentServers.defaultsKey)
        let loaded = RecentServers.load(from: d.defaults)
        #expect(loaded.map(\.url.absoluteString) == ["smb://nas/a", "smb://user@nas/b", "nfs://n/e"])
        d.defaults.set("not a list", forKey: RecentServers.defaultsKey)
        #expect(RecentServers.load(from: d.defaults).isEmpty)
        d.defaults.set([1, 2, ["x"]], forKey: RecentServers.defaultsKey)
        #expect(RecentServers.load(from: d.defaults).isEmpty)
    }

    @Test func removing() throws {
        let a = try address("smb://a/x"), b = try address("smb://b/x")
        #expect(RecentServers.removing(try address("SMB://A/X"), from: [a, b]) == [b])
    }
}

@Suite struct SavedServersTests {
    @Test func savingWhatWasTypedSplitsShareAndFolder() throws {
        let server = SavedServer.make(id: "1", typed: try address("smb://alex:pw@nas/Media/Movies/2026"))
        #expect(server.address.url.absoluteString == "smb://alex@nas/Media")
        #expect(server.folder == "Movies/2026")
        #expect(server.name == "2026")
        #expect(!server.reconnectAtLaunch)
        #expect(server.fullAddress.url.absoluteString == "smb://alex@nas/Media/Movies/2026")
    }

    @Test func defaultNames() throws {
        #expect(SavedServer.make(typed: try address("smb://nas/Media")).name == "Media")
        #expect(SavedServer.make(typed: try address("smb://nas")).name == "nas")
        #expect(SavedServer.make(typed: try address("nfs://n/srv/nfs/Backups")).name == "Backups")
        #expect(SavedServer.make(typed: try address("smb://nas/Media"), name: "  Films ").name == "Films")
        #expect(SavedServer.make(typed: try address("smb://nas/Media"), name: "  ").name == "Media")
    }

    @Test func reconnectAtLaunchIsOffByDefaultAndPersists() throws {
        let d = TestDefaults(); defer { d.cleanup() }
        let store = SavedServersStore(defaults: d.defaults)
        var list = [SavedServer.make(id: "a", typed: try address("smb://nas/Media"))]
        #expect(!list[0].reconnectAtLaunch)
        list = SavedServers.setting(reconnectAtLaunch: true, id: "a", in: list)
        store.save(list)
        let loaded = store.load()
        #expect(loaded == list && loaded[0].reconnectAtLaunch)
    }

    @Test func persistedWithoutPasswords() throws {
        let d = TestDefaults(); defer { d.cleanup() }
        let store = SavedServersStore(defaults: d.defaults)
        store.save([SavedServer.make(id: "a", typed: try address("smb://alex:hunter2@nas/Media/Sub"))])
        let raw = try #require(d.defaults.array(forKey: SavedServersStore.defaultsKey) as? [[String: Any]])
        #expect(raw.count == 1)
        #expect(raw[0]["address"] as? String == "smb://alex@nas/Media")
        #expect(raw[0]["folder"] as? String == "Sub")
        #expect(!"\(raw)".contains("hunter2"))
    }

    @Test func corruptStorageIsTolerated() throws {
        let d = TestDefaults(); defer { d.cleanup() }
        let store = SavedServersStore(defaults: d.defaults)
        d.defaults.set("garbage", forKey: SavedServersStore.defaultsKey)
        #expect(store.load().isEmpty)
        d.defaults.set(Data([0, 1, 2]), forKey: SavedServersStore.defaultsKey)
        #expect(store.load().isEmpty)
        d.defaults.set([
            "not a dictionary",
            ["address": 42],
            ["name": "no address"],
            ["address": "file:///etc", "name": "a file"],
            ["address": "vnc://mac.local"],
            ["address": "smb://nas/a", "folder": "../../etc"],
            ["address": "smb://nas/a", "folder": 7, "name": ["x"], "reconnectAtLaunch": "yes"],
            ["address": "smb://user:pw@nas/b", "id": "b", "name": "B", "reconnectAtLaunch": true],
            ["address": "smb://NAS/B", "id": "b2"],   // the same place as "b"
            ["address": "nfs://n/e", "id": "b"],      // a repeated id gets a new one
        ] as [Any], forKey: SavedServersStore.defaultsKey)
        let loaded = store.load()
        #expect(loaded.map(\.address.url.absoluteString) == ["smb://nas/a", "smb://user@nas/b", "nfs://n/e"])
        #expect(loaded[0].name == "a" && loaded[0].folder == "" && !loaded[0].reconnectAtLaunch)
        #expect(loaded[1].id == "b" && loaded[1].name == "B" && loaded[1].reconnectAtLaunch)
        #expect(loaded[2].id != "b" && !loaded[2].id.isEmpty)
        #expect(Set(loaded.map(\.id)).count == 3)
    }

    @Test func atMostAHundredAreRead() throws {
        let d = TestDefaults(); defer { d.cleanup() }
        let entries: [[String: Any]] = (0..<150).map { ["address": "smb://nas/share\($0)", "id": "\($0)"] }
        d.defaults.set(entries, forKey: SavedServersStore.defaultsKey)
        let loaded = SavedServersStore(defaults: d.defaults).load()
        #expect(loaded.count == SavedServersStore.limit && SavedServersStore.limit == 100)
        #expect(loaded.last?.id == "99")
    }

    @Test func addingTheSamePlaceTwiceIsRefused() throws {
        let one = SavedServer.make(typed: try address("smb://nas/Media/Sub"))
        let list = try #require(SavedServers.adding(one, to: []))
        #expect(SavedServers.adding(SavedServer.make(typed: try address("smb://GUEST@NAS/media/sub")), to: list) == nil)
        #expect(SavedServers.adding(SavedServer.make(typed: try address("smb://nas/Media")), to: list)?.count == 2)
        #expect(SavedServers.removing(id: one.id, from: list).isEmpty)
    }

    @Test func aServerWithoutAShareNeverReconnectsQuietly() throws {
        let list = [SavedServer.make(id: "s", typed: try address("smb://nas"))]
        #expect(list[0].isServerOnly)
        #expect(!SavedServers.setting(reconnectAtLaunch: true, id: "s", in: list)[0].reconnectAtLaunch)
    }

    @Test func whatReconnectsAtLaunch() throws {
        var media = SavedServer.make(id: "1", typed: try address("smb://nas/Media"))
        media.reconnectAtLaunch = true
        var mediaSub = SavedServer.make(id: "2", typed: try address("smb://nas/Media/Sub"))
        mediaSub.reconnectAtLaunch = true
        var docs = SavedServer.make(id: "3", typed: try address("smb://nas/Docs"))
        docs.reconnectAtLaunch = true
        let off = SavedServer.make(id: "4", typed: try address("smb://nas/Off"))
        var serverOnly = SavedServer.make(id: "5", typed: try address("smb://nas"))
        serverOnly.reconnectAtLaunch = true
        let mounted = [try address("smb://GUEST@nas/docs")]
        // One mount per share; mounted ones, ones turned off and bare servers left alone.
        #expect(SavedServers.toReconnect([media, mediaSub, docs, off, serverOnly], mounted: mounted)
                == [media.address])
    }

    @Test func theFolderToSaveOnAMountedVolume() {
        let volume = URL(fileURLWithPath: "/Volumes/Media")
        #expect(SavedServers.folder(URL(fileURLWithPath: "/Volumes/Media/Movies/2026"), onVolume: volume) == "Movies/2026")
        #expect(SavedServers.folder(URL(fileURLWithPath: "/Volumes/Media/"), onVolume: volume) == "")
        #expect(SavedServers.folder(URL(fileURLWithPath: "/Volumes/Media-1/x"), onVolume: volume) == nil)
        #expect(SavedServers.folder(URL(fileURLWithPath: "/Users/me"), onVolume: volume) == nil)
    }

    @Test func folderNormalization() {
        #expect(SavedServers.normalizedFolder("/a//b/") == "a/b")
        #expect(SavedServers.normalizedFolder("") == "")
        #expect(SavedServers.normalizedFolder("a/../b") == nil)
        #expect(SavedServers.normalizedFolder("./a") == nil)
        #expect(SavedServers.normalizedFolder("a\nb") == nil)
    }
}

@Suite struct SidebarServersTests {
    private func volume(_ path: String, remount: String?) throws -> SidebarVolume {
        SidebarVolume(url: URL(fileURLWithPath: path, isDirectory: true),
                      name: URL(fileURLWithPath: path).lastPathComponent, isEjectable: true, isLocal: false,
                      server: try remount.map(address))
    }

    @Test func aMountedShareIsTheVolumesRowNotASecondOne() throws {
        let media = SavedServer.make(id: "m", typed: try address("smb://nas/Media"))
        let docs = SavedServer.make(id: "d", typed: try address("smb://nas/Docs"))
        // The remount URL has the guest login and other spelling.
        let mounted = [try volume("/Volumes/Media", remount: "smb://GUEST:@NAS/media")]
        let rows = SidebarServers.rows([media, docs], mounted: mounted, listed: mounted)
        #expect(rows.map(\.server.id) == ["d"])
        #expect(rows[0].folder == nil && !rows[0].isConnected)
    }

    @Test func aSavedFolderOnAMountedShareKeepsItsRowAndGoesThere() throws {
        let sub = SavedServer.make(id: "s", typed: try address("smb://nas/Media/Movies/2026"))
        let mounted = [try volume("/Volumes/Media", remount: "smb://nas/Media")]
        let rows = SidebarServers.rows([sub], mounted: mounted, listed: mounted)
        #expect(rows.count == 1)
        #expect(rows[0].folder == URL(fileURLWithPath: "/Volumes/Media/Movies/2026", isDirectory: true))
        #expect(rows[0].isConnected)
    }

    @Test func aShareMountedButNotListedKeepsItsRow() throws {
        // Settings → Sidebar → Network volumes off: no volume row to stand in.
        let media = SavedServer.make(id: "m", typed: try address("smb://nas/Media"))
        let mounted = [try volume("/Volumes/Media", remount: "smb://nas/Media")]
        let rows = SidebarServers.rows([media], mounted: mounted, listed: [])
        #expect(rows.map(\.folder) == [URL(fileURLWithPath: "/Volumes/Media", isDirectory: true)])
    }

    @Test func nfsAndOtherPortsMatchOnlyTheSameExport() throws {
        let nfs = SavedServer.make(id: "n", typed: try address("nfs://192.0.2.35/srv/nfs/Backups"))
        let otherPort = SavedServer.make(id: "p", typed: try address("smb://nas:1445/Media"))
        let mounted = [try volume("/Volumes/Backups", remount: "nfs://192.0.2.35/srv/nfs/Backups"),
                       try volume("/Volumes/Media", remount: "smb://nas/Media")]
        let rows = SidebarServers.rows([nfs, otherPort], mounted: mounted, listed: mounted)
        #expect(rows.map(\.server.id) == ["p"])
        #expect(SidebarServers.mountPoint(for: try address("nfs://192.0.2.35/srv/nfs/backups"), in: mounted) == nil)
    }

    @Test func aBareServerIsNeverConnectedItself() throws {
        let bare = SavedServer.make(id: "b", typed: try address("smb://nas"))
        let mounted = [try volume("/Volumes/Media", remount: "smb://nas/Media")]
        #expect(SidebarServers.rows([bare], mounted: mounted, listed: mounted).map(\.isConnected) == [false])
    }

    /// An FTP, WebDAV or NFS root is mounted whole: it matches its volume
    /// (no second row), shows connected when mounted, and can reconnect.
    @Test func rootAddressesThatArentSMBMountWhole() throws {
        var ftp = SavedServer.make(id: "f", typed: try address("ftp://ftp.example.com"))
        var dav = SavedServer.make(id: "d", typed: try address("https://dav.example.com"))
        #expect(!ftp.isServerOnly && !dav.isServerOnly)
        let mounted = [try volume("/Volumes/ftp.example.com", remount: "ftp://ftp.example.com/")]
        #expect(SidebarServers.rows([ftp], mounted: mounted, listed: mounted).isEmpty)
        let unlisted = SidebarServers.rows([ftp, dav], mounted: mounted, listed: [])
        #expect(unlisted.map(\.server.id) == ["d", "f"])
        #expect(unlisted.map(\.isConnected) == [false, true])
        ftp = SavedServers.setting(reconnectAtLaunch: true, id: "f", in: [ftp])[0]
        dav = SavedServers.setting(reconnectAtLaunch: true, id: "d", in: [dav])[0]
        #expect(ftp.reconnectAtLaunch && dav.reconnectAtLaunch)
        #expect(SavedServers.toReconnect([ftp, dav], mounted: []) == [ftp.address, dav.address])
        #expect(SavedServers.toReconnect([ftp, dav], mounted: [try address("ftp://ftp.example.com")])
                == [dav.address])
    }

    @Test func rowsAreByName() throws {
        let b = SavedServer.make(id: "1", typed: try address("smb://nas/b"))
        let a = SavedServer.make(id: "2", typed: try address("smb://nas/A"))
        let c = SavedServer.make(id: "3", typed: try address("smb://nas/c10"))
        let c2 = SavedServer.make(id: "4", typed: try address("smb://nas/c9"))
        #expect(SidebarServers.rows([b, a, c, c2], mounted: [], listed: []).map(\.server.name) == ["A", "b", "c9", "c10"])
    }

    @Test func theFolderURLIsBuiltFromThePathAlone() {
        let url = SidebarServers.folderURL("a b/c", on: URL(fileURLWithPath: "/Volumes/Share/"))
        #expect(url.path == "/Volumes/Share/a b/c")
        #expect(SidebarServers.folderURL("", on: URL(fileURLWithPath: "/Volumes/Share")).path == "/Volumes/Share")
    }
}

/// `selway://` links (any web page can fire one) and the Finder extension's
/// messages must never start a mount: there's no action for it, and a path
/// in one is only ever a local path.
@Suite struct ServerLinkSafetyTests {
    @Test func noURLActionMounts() {
        #expect(FileOpsURLAction.allCases == [.open, .newFolder, .terminal])
        for action in FileOpsURLAction.allCases {
            for word in ["mount", "connect", "server", "smb", "afp", "nfs"] {
                #expect(!action.rawValue.lowercased().contains(word))
            }
        }
    }

    /// With autofs's /net map on, looking at /net/<host> mounts that host's
    /// NFS exports: such a path is refused before anything reads the disk,
    /// however it's spelled.
    @Test(arguments: ["selway://open?path=/net/evil.example/export", "selway://open?path=/NET/evil/x",
                      "selway://terminal?path=/net", "selway://open?path=/tmp/../net/evil/x",
                      "selway://open?path=/./net/./evil", "selway://new-folder?path=/Network/Servers/evil/x",
                      "selway://open?path=/network/servers",
                      // A "/" followed by a combining mark or a joiner is one Character,
                      // but still a separator to the file system.
                      "selway://open?path=/net/%CC%81evil.example/x", "selway://open?path=/net/%E2%80%8Devil/x",
                      "selway://open?path=/Network/Servers/%CC%81x", "selway://open?path=//net//%CC%81evil",
                      // The Data volume's own path to the same folders.
                      "selway://open?path=/System/Volumes/Data/net/evil/x",
                      "selway://open?path=/system/volumes/data/Network/Servers/evil",
                      "selway://open?path=/System/Volumes/Data/../Data/net/evil"])
    func automountPathsAreRefused(link: String) throws {
        #expect(FileOpsURLScheme.parse(try #require(URL(string: link))) == nil)
    }

    #if os(macOS)
    /// auto_home: a network home folder is mounted there.
    @Test(arguments: ["selway://open?path=/home/someone", "selway://open?path=/System/Volumes/Data/home/x",
                      "selway://open?path=/HOME"])
    func homeAutomountIsRefused(link: String) throws {
        #expect(FileOpsURLScheme.parse(try #require(URL(string: link))) == nil)
    }
    #endif

    @Test func pathsNearAutomountFoldersAreFine() throws {
        #expect(!AutomountPaths.contains("/Users/me/net/x"))
        #expect(!AutomountPaths.contains("/netflix"))
        #expect(!AutomountPaths.contains("/net/../tmp"))
        #expect(!AutomountPaths.contains("/System/Volumes/Data/Users/me"))
        #expect(!AutomountPaths.contains("/System/Volumes/Preboot/net"))
        #expect(AutomountPaths.contains("/net/host"))
        #expect(AutomountPaths.contains("/Network/Library"))
        #expect(FileOpsURLScheme.parse(try #require(URL(string: "selway://open?path=/tmp")))?.path == "/tmp")
    }

    /// Parsing reads nothing from the disk: "." and ".." are resolved from the text.
    @Test func parsingStandardizesFromTheTextAlone() throws {
        #expect(AutomountPaths.standardized("/a//b/./c/../d/") == "/a/b/d")
        #expect(AutomountPaths.standardized("/../..") == "/")
        #expect(AutomountPaths.standardized("/a/\u{301}b") == "/a/\u{301}b")
        let link = try #require(URL(string: "selway://open?path=/private/tmp/x/../y"))
        #expect(FileOpsURLScheme.parse(link)?.path == "/private/tmp/y")
    }

    @Test(arguments: ["selway://open?path=smb://nas/share", "selway://open?path=smb%3A%2F%2Fnas%2Fshare",
                      "selway://open?path=//nas/share", "selway://open?path=nas/share",
                      "selway://terminal?path=afp://mac/x", "selway://new-folder?path=nfs://n/e",
                      "selway://mount?path=/Volumes/x", "selway://connect?path=smb://nas/x",
                      "smb://nas/share", "selway://open?path=%5C%5Cnas%5Cshare"])
    func aServerAddressInALinkIsNeverAServer(link: String) throws {
        let url = try #require(URL(string: link))
        guard let request = FileOpsURLScheme.parse(url) else { return }   // refused outright: fine
        // Whatever is accepted is an absolute local path, never a server address…
        #expect(request.path.hasPrefix("/"))
        if case .success = ServerAddress.parse(request.path) {
            Issue.record("\(link) gave a server address")
        }
        // …and the policy only ever shows or acts on a local folder.
        switch FileOpsURLPolicy.decide(request, fromOwnExtension: true) {
        case .ignore: break
        case .show(let folder): #expect(folder.isFileURL)
        case .perform(_, let folder, _): #expect(folder.isFileURL)
        }
    }
}
