import Foundation
import Testing
#if canImport(Glibc)
import Glibc
#endif
@testable import SelwayCore

@Suite struct ModelLoadTests {
    private func byName(_ items: [FileItem]) -> [String: FileItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
    }

    @Test func realFolder() throws {
        let t = try TempDir(); defer { t.cleanup() }
        try t.file("a.txt", bytes: 3)
        try t.dir("Sub")
        let items = byName(loadItems(at: t.url, showHidden: false))
        #expect(Set(items.keys) == ["a.txt", "Sub"])
        let a = try #require(items["a.txt"])
        #expect(!a.isDirectory && a.size == 3 && a.fileExtension == "txt")
        #if canImport(Darwin)
        #expect(!a.kind.isEmpty && a.kind != "TXT File")   // Finder's, e.g. "Plain Text Document"
        #else
        #expect(a.kind == "TXT File")
        #endif
        #expect(a.id == t.url.appendingPathComponent("a.txt").path && a.url.path == a.id)
        let sub = try #require(items["Sub"])
        #expect(sub.isBrowsableFolder && sub.kind == "Folder")
    }

    @Test(arguments: [true, false])
    func folderSymlinkListsTargetUnderTheLinkPath(relative: Bool) throws {
        let t = try TempDir(); defer { t.cleanup() }
        try t.file("real/inner.txt")
        try t.dir("real/Nested")
        let link = try t.link("link", to: relative ? "real" : t.url.appendingPathComponent("real").path)

        let entry = try #require(byName(loadItems(at: t.url, showHidden: false))["link"])
        #expect(entry.isBrowsableFolder && entry.kind == "Folder")
        #expect(FileItem.isBrowsableFolder(link))

        let children = loadItems(at: link, showHidden: false)
        #expect(Set(children.map(\.name)) == ["inner.txt", "Nested"])
        for child in children {
            #expect(child.url.deletingLastPathComponent().path == link.path)
            #expect(child.id == link.appendingPathComponent(child.name).path)
        }
        #expect(byName(children)["Nested"]?.isBrowsableFolder == true)
    }

    @Test func folderUnderASymlinkedAncestorKeepsTheLogicalPath() throws {
        let t = try TempDir(); defer { t.cleanup() }
        try t.file("real/sub/deep.txt")
        let link = try t.link("link", to: "real")
        let sub = link.appendingPathComponent("sub")
        let items = loadItems(at: sub, showHidden: false)
        #expect(items.map(\.id) == [sub.appendingPathComponent("deep.txt").path])
    }

    @Test func fileSymlinkIsAFile() throws {
        let t = try TempDir(); defer { t.cleanup() }
        try t.file("target.md", bytes: 10)
        let link = try t.link("alias.md", to: "target.md")
        let item = try #require(byName(loadItems(at: t.url, showHidden: false))["alias.md"])
        #expect(!item.isDirectory && !item.isBrowsableFolder && item.fileExtension == "md")
        #expect(!FileItem.isBrowsableFolder(link))
        #expect(loadItems(at: link, showHidden: false).isEmpty)
    }

    @Test(arguments: ["missing-target", "loop"])
    func brokenAndLoopingLinksAreFilesWithNoChildren(target: String) throws {
        let t = try TempDir(); defer { t.cleanup() }
        let link = try t.link("loop", to: target)   // "loop" → itself
        let item = try #require(loadItems(at: t.url, showHidden: false).first)
        #expect(item.name == "loop" && !item.isDirectory && !item.isPackage)
        #expect(!FileItem.isBrowsableFolder(link))
        #expect(loadItems(at: link, showHidden: false).isEmpty)
    }

    /// Listing a folder must not look up where a link into an automount folder
    /// leads: /net/<host> mounts that host's exports when anything in it is
    /// looked up. Such a link stays a file, unfollowed.
    @Test func aLinkIntoAnAutomountFolderIsNotFollowed() throws {
        let t = try TempDir(); defer { t.cleanup() }
        try t.link("share", to: "/net/evil.example/export")
        try t.link("Tool.app", to: "/net/evil.example/Tool.app")
        let items = byName(loadItems(at: t.url, showHidden: false))
        for name in ["share", "Tool.app"] {
            let item = try #require(items[name])
            #expect(item.isLinkNotFollowed && !item.isDirectory && !item.isPackage && !item.isBrowsableFolder)
        }
    }

    /// A listing walks each link from the folder: a relative link to a
    /// sibling folder is a folder, found without looking at anything outside
    /// the folder (a walk from "/" would look at each of its ancestors), and
    /// one whose `..` climbs out of the folder to /net is refused when the
    /// climb reaches "/", before /net is looked at.
    @Test func aListingWalksLinksFromTheFolder() throws {
        let t = try TempDir(); defer { t.cleanup() }
        let folder = try t.dir("folder")
        try t.dir("folder/sib")
        try t.link("folder/toSib", to: "sib")
        var lookedUp: [String] = []
        let live = AutomountGuard.FileSystem.live
        let recording = AutomountGuard.FileSystem(entry: { lookedUp.append($0); return live.entry($0) },
                                                  readLink: live.readLink, fileSystemType: live.fileSystemType,
                                                  realPath: live.realPath)
        let toSib = try #require(byName(loadItems(at: folder, showHidden: false, fileSystem: recording))["toSib"])
        #expect(!toSib.isLinkNotFollowed && toSib.isBrowsableFolder)
        #expect(!lookedUp.isEmpty && lookedUp.allSatisfy { $0.hasPrefix(folder.path) })

        try t.link("upToNet", to: String(repeating: "../", count: 40) + "net/evil.example/x")
        let upToNet = try #require(byName(loadItems(at: t.url, showHidden: false))["upToNet"])
        #expect(upToNet.isLinkNotFollowed && !upToNet.isDirectory)
    }

    /// A tag change leaves out links the listing didn't follow, and its
    /// message says how many.
    @Test func aTagChangeSkipsLinksTheListingDidntFollow() {
        var refused = FileItem.fixture("share")
        refused.isLinkNotFollowed = true
        let plain = FileItem.fixture("a.txt")
        let mixed = FileItem.tagTargets([refused, plain, refused])
        #expect(mixed.items == [plain] && mixed.skippedLinks == 2)
        #expect(FileItem.tagTargets([refused]).items.isEmpty)
        #expect(FileItem.tagTargets([plain]).skippedLinks == 0)
        #expect(FileOpsTags.skippedNote(links: 0) == "")
        #expect(FileOpsTags.skippedNote(links: 1) == " (1 link skipped)")
        #expect(FileOpsTags.skippedNote(links: 2) == " (2 links skipped)")
    }

    /// Opening a link the listing refused follows it then, as Finder does on
    /// a user's action; anything else opens as the listing says, unasked.
    @Test func openingARefusedLinkFollowsIt() throws {
        let t = try TempDir(); defer { t.cleanup() }
        try t.dir("real")
        try t.file("Tool.app/Contents/Info.plist")
        try t.file("note.txt")
        for (name, target, isFolder) in [("folder", "real", true), ("app", "Tool.app", false), ("file", "note.txt", false)] {
            let link = try t.link(name, to: target)
            let refused = try #require(FileItem.load(from: link, isSafeLink: { _ in false }))
            #expect(!refused.isBrowsableFolder)
            #expect(refused.opensAsFolder() == isFolder)
        }
        let plain = try #require(FileItem.load(from: t.url.appendingPathComponent("real")))
        #expect(plain.opensAsFolder(isFolder: { _ in Issue.record("looked"); return false }))
    }

    @Test func aLinkTheGuardRefusesIsntFollowedEvenToAFolder() throws {
        let t = try TempDir(); defer { t.cleanup() }
        try t.dir("real")
        let link = try t.link("link", to: "real")
        var asked: [String] = []
        let refused = try #require(FileItem.load(from: link, isSafeLink: { asked.append($0); return false }))
        #expect(asked == [link.path])
        #expect(refused.isLinkNotFollowed && !refused.isDirectory)
        let followed = try #require(FileItem.load(from: link))
        #expect(!followed.isLinkNotFollowed && followed.isBrowsableFolder)
    }

    @Test func onlyLinksAskTheGuard() throws {
        let t = try TempDir(); defer { t.cleanup() }
        let file = try t.file("a.txt")
        let folder = try t.dir("Sub")
        for url in [file, folder] {
            let item = try #require(FileItem.load(from: url, isSafeLink: { _ in Issue.record("asked"); return false }))
            #expect(!item.isLinkNotFollowed)
        }
    }

    #if os(macOS)
    /// The tags are read from the link itself, not through it.
    @Test func anUnfollowedLinksTagsAreItsOwn() throws {
        let t = try TempDir(); defer { t.cleanup() }
        let target = try t.file("target.txt")
        try (target as NSURL).setResourceValue(["Red"], forKey: .tagNamesKey)
        let link = try t.link("link.txt", to: "target.txt")
        #expect(FileItem.load(from: link)?.tagNames == ["Red"])
        #expect(FileItem.load(from: link, isSafeLink: { _ in false })?.tagNames == [])
    }
    #endif

    @Test func linkToPackageIsNotBrowsable() throws {
        let t = try TempDir(); defer { t.cleanup() }
        try t.file("Tool.app/Contents/Info.plist")
        let link = try t.link("ToolLink", to: "Tool.app")
        let items = byName(loadItems(at: t.url, showHidden: false))
        let app = try #require(items["Tool.app"])
        #expect(app.isDirectory && app.isPackage && !app.isBrowsableFolder)
        let linked = try #require(items["ToolLink"])
        #expect(linked.isDirectory && linked.isPackage && !linked.isBrowsableFolder)
        #expect(!FileItem.isBrowsableFolder(link))
        #expect(!FileItem.isBrowsableFolder(t.url.appendingPathComponent("Tool.app")))
    }

    #if os(macOS)
    /// resolvingSymlinksInPath strips /private, which lands on /tmp (itself a link);
    /// these must still be folders.
    @Test(arguments: ["/private/tmp", "/tmp", "/private/var", "/private/etc"])
    func linksIntoPrivateAreFolders(target: String) throws {
        let t = try TempDir(); defer { t.cleanup() }
        let link = try t.link("sys", to: target)
        let item = try #require(loadItems(at: t.url, showHidden: false).first)
        #expect(item.isBrowsableFolder, "\(target)")
        #expect(FileItem.isBrowsableFolder(link))
        #expect(FileItem.isBrowsableFolder(URL(fileURLWithPath: target)))
        let children = loadItems(at: link, showHidden: true)
        #expect(!children.isEmpty)
        #expect(children.allSatisfy { $0.url.deletingLastPathComponent().path == link.path })
    }
    #endif

    @Test func hiddenFilesFollowShowHidden() throws {
        let t = try TempDir(); defer { t.cleanup() }
        try t.file(".secret")
        try t.file("visible")
        #expect(loadItems(at: t.url, showHidden: false).map(\.name) == ["visible"])
        let all = byName(loadItems(at: t.url, showHidden: true))
        #expect(Set(all.keys) == [".secret", "visible"])
        #expect(all[".secret"]?.isHidden == true && all["visible"]?.isHidden == false)
    }

    @Test(.enabled(if: getuid() != 0, "root can read mode-000 folders"))
    func unreadableFolderIsEmpty() throws {
        let t = try TempDir(); defer { t.cleanup() }
        let locked = try t.dir("locked")
        try t.file("locked/x.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        #expect(loadItems(at: locked, showHidden: true).isEmpty)
        #expect(loadItems(at: t.url.appendingPathComponent("nope"), showHidden: true).isEmpty)
    }

    #if os(macOS)
    /// v1.5.2 dropped .tagNamesKey from the listing keys, so tagNames was always
    /// empty: no sidebar Tags, Clear Tags disabled, tag filters empty.
    @Test func tagsAreLoaded() throws {
        let t = try TempDir(); defer { t.cleanup() }
        let red = try t.file("red.txt")
        try t.file("plain.txt")
        try (red as NSURL).setResourceValue(["Red", "Project X"], forKey: .tagNamesKey)
        let items = byName(loadItems(at: t.url, showHidden: false))
        #expect(items["red.txt"]?.tagNames == ["Red", "Project X"])
        #expect(items["red.txt"]?.hasColorTag("red") == true)
        #expect(items["plain.txt"]?.tagNames == [])
        #expect(FileItem.load(from: red)?.tagNames == ["Red", "Project X"])
    }
    #endif

    @Test func rebaseSwapsOnlyTheRootPrefix() {
        let real = URL(fileURLWithPath: "/Volumes/T7/Users/me/Downloads")
        let logical = URL(fileURLWithPath: "/Users/me/Downloads")
        func r(_ p: String) -> String {
            ModelPaths.rebase(URL(fileURLWithPath: p), from: real, to: logical).path
        }
        #expect(r("/Volumes/T7/Users/me/Downloads/a.pdf") == "/Users/me/Downloads/a.pdf")
        #expect(r("/Volumes/T7/Users/me/Downloads/x/y.txt") == "/Users/me/Downloads/x/y.txt")
        #expect(r("/Volumes/T7/Users/me/Downloads") == "/Users/me/Downloads")
        #expect(r("/Volumes/T7/Users/me/DownloadsOld/a") == "/Volumes/T7/Users/me/DownloadsOld/a")
        #expect(r("/elsewhere/a") == "/elsewhere/a")
        #expect(ModelPaths.rebase(URL(fileURLWithPath: "/a/b"), from: URL(fileURLWithPath: "/a"),
                                  to: URL(fileURLWithPath: "/a")).path == "/a/b")
    }

    @Test func notDirectoryErrorDetection() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 256,
                              userInfo: [NSUnderlyingErrorKey: posix])
        #expect(ModelPaths.isNotDirectoryError(posix))
        #expect(ModelPaths.isNotDirectoryError(wrapped))
        #expect(!ModelPaths.isNotDirectoryError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    /// A followed link's thumbnail is keyed by its target's date and size, so
    /// editing the file it leads to gives it a new thumbnail; the columns keep
    /// the link's own, as Finder lists a link.
    @Test func aFollowedLinkKeysItsThumbnailByItsTarget() throws {
        let t = try TempDir(); defer { t.cleanup() }
        let target = try t.file("photo.png", bytes: 3)
        let fm = FileManager.default
        let first = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try fm.setAttributes([.modificationDate: first], ofItemAtPath: target.path)
        let link = try t.link("link.png", to: "photo.png")

        let before = try #require(FileItem.load(from: link))
        #expect(!before.isLinkNotFollowed)
        #expect(before.targetSize == 3 && before.contentSize == 3)
        #expect(before.contentModified == first)
        let ownSize = before.size
        let ownDate = before.dateModified

        try Data(repeating: 0x62, count: 10).write(to: target)
        try fm.setAttributes([.modificationDate: first.addingTimeInterval(60)], ofItemAtPath: target.path)
        let after = try #require(FileItem.load(from: link))
        #expect(after.contentSize == 10)
        #expect(after.contentModified == first.addingTimeInterval(60))
        #expect(after.size == ownSize && after.dateModified == ownDate)
        #expect(ThumbnailPolicy.key(for: after, pixelSide: 128) != ThumbnailPolicy.key(for: before, pixelSide: 128))
    }

    @Test func onlyAFollowedLinkHasATargetStamp() throws {
        let t = try TempDir(); defer { t.cleanup() }
        let file = try t.file("photo.png", bytes: 3)
        let link = try t.link("link.png", to: "photo.png")
        let plain = try #require(FileItem.load(from: file))
        #expect(plain.targetModified == nil && plain.targetSize == nil)
        #expect(plain.contentModified == plain.dateModified && plain.contentSize == 3)
        let refused = try #require(FileItem.load(from: link, isSafeLink: { _ in false }))
        #expect(refused.targetModified == nil && refused.targetSize == nil)
        let broken = try t.link("broken.png", to: "missing.png")
        let dangling = try #require(FileItem.load(from: broken))
        #expect(dangling.targetModified == nil && dangling.targetSize == nil)
        // A link to a folder: a folder gets no thumbnail, so nothing is read.
        try t.dir("Photos")
        let folderLink = try #require(FileItem.load(from: try t.link("PhotosLink", to: "Photos")))
        #expect(folderLink.isBrowsableFolder)
        #expect(folderLink.targetModified == nil && folderLink.targetSize == nil)
    }
}
