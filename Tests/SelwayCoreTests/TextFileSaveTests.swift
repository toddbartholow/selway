import Foundation
import Testing
@testable import SelwayCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// What a save must keep: the file's identity (owner, group, mode, hard links,
// metadata) and the path it was opened at, and what it must never leave behind.

// MARK: - Helpers

private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TextFileSaveTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Removes a test folder even when a test left it (or something in it) read-only
/// or with a deny-delete ACL.
private func removeDir(_ dir: URL) {
    let fm = FileManager.default
    var paths = [dir.path]
    if let e = fm.enumerator(atPath: dir.path) {
        while let rel = e.nextObject() as? String { paths.append(dir.appendingPathComponent(rel).path) }
    }
    for path in paths {
        #if canImport(Darwin)
        TextFileIO.removeACL(path)
        #endif
        _ = chmod(path, 0o755)
    }
    try? fm.removeItem(at: dir)
}

private func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }
private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

private func stat(_ url: URL) -> TextFileIO.FileInfo {
    TextFileIO.fileInfo(url)!
}

/// A group the current user belongs to other than their primary one, or nil.
private func secondaryGroup() -> gid_t? {
    let n = getgroups(0, nil)
    guard n > 0 else { return nil }
    var groups = [gid_t](repeating: 0, count: Int(n))
    let got = getgroups(n, &groups)
    guard got > 0 else { return nil }
    return groups.prefix(Int(got)).first { $0 != getegid() }
}

/// Load, then save `text` back the way the editors do.
@discardableResult
private func loadAndSave(_ url: URL, _ text: String) throws -> TextFileSnapshot {
    let loaded = try TextFileIO.load(url)
    return try TextFileIO.save(text, format: loaded.format, to: loaded.resolvedURL, expected: loaded.snapshot)
}

/// Nothing holding the user's text may stay behind: no temporary copy next to the
/// file, and none in the system's temporary-items folders.
private func expectNoLeftovers(in dir: URL, only names: [String], fileName: String,
                               sourceLocation: SourceLocation = #_sourceLocation) {
    let listing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    #expect(listing.sorted() == names.sorted(), "left in the folder: \(listing)", sourceLocation: sourceLocation)
    let temporaryItems = FileManager.default.temporaryDirectory.appendingPathComponent("TemporaryItems")
    let folders = (try? FileManager.default.contentsOfDirectory(atPath: temporaryItems.path)) ?? []
    for folder in folders {
        let items = (try? FileManager.default.contentsOfDirectory(
            atPath: temporaryItems.appendingPathComponent(folder).path)) ?? []
        #expect(!items.contains { $0.contains(fileName) }, "temp copy left in \(folder)",
                sourceLocation: sourceLocation)
    }
}

// MARK: - Owner, group, mode

@Test(arguments: [0o640, 0o664, 0o750] as [mode_t])
func savePreservesGroupAndPermissions(mode: mode_t) throws {
    guard let group = secondaryGroup() else { return }   // no secondary group: nothing to cover
    let dir = try makeDir()
    defer { removeDir(dir) }
    let url = dir.appendingPathComponent("shared.txt")
    try write("v1\n", url)
    #expect(chown(url.path, geteuid(), group) == 0)
    #expect(chmod(url.path, mode) == 0)

    try loadAndSave(url, "v2\n")

    let after = stat(url)
    #expect(after.group == group, "group must survive the save")
    #expect(after.owner == geteuid())
    #expect(after.permissions == mode, "mode \(String(after.permissions, radix: 8))")
    #expect(try read(url) == "v2\n")
}

private func isMember(of group: gid_t) -> Bool {
    if group == getegid() { return true }
    let n = getgroups(0, nil)
    var groups = [gid_t](repeating: 0, count: Int(max(n, 0)))
    let got = getgroups(n, &groups)
    return groups.prefix(Int(max(got, 0))).contains(group)
}

/// A file whose group the user isn't in (on macOS, files made in /private/tmp get
/// its group, wheel) can't be given that group by a swapped-in copy: replaceItemAt
/// used to leave it alex:staff with the group bits stripped (640 → 600, 664 → 644).
/// It is now written in place, keeping group and mode.
@Test(arguments: [0o640, 0o664] as [mode_t])
func saveKeepsAGroupTheUserIsNotIn(mode: mode_t) throws {
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: "/private/tmp")
        .appendingPathComponent("SelwayCoreTests-\(UUID().uuidString)", isDirectory: true)
    guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: false)) != nil else { return }
    defer { removeDir(dir) }
    let url = dir.appendingPathComponent("wheel.txt")
    try write("v1\n", url)
    let group = stat(url).group
    guard !isMember(of: group) else { return }   // e.g. Linux: files get the creator's group
    #expect(chmod(url.path, mode) == 0)

    try loadAndSave(url, "v2\n")

    let after = stat(url)
    #expect(after.group == group)
    #expect(after.permissions == mode, "mode \(String(after.permissions, radix: 8))")
    #expect(try read(url) == "v2\n")
}

/// Root can hand a file to another user; a save must then keep that owner (it is
/// written in place rather than replaced by a file root owns). Runs on Linux CI.
@Test(.enabled(if: geteuid() == 0, "needs root to chown to another user"))
func saveKeepsAnotherUsersOwnership() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let url = dir.appendingPathComponent("theirs.txt")
    try write("v1\n", url)
    #expect(chown(url.path, 4321, 4321) == 0)
    #expect(chmod(url.path, 0o664) == 0)
    let inode = stat(url).inode

    try loadAndSave(url, "v2\n")

    let after = stat(url)
    #expect(after.owner == 4321)
    #expect(after.group == 4321)
    #expect(after.inode == inode)
    #expect(try read(url) == "v2\n")
}

// MARK: - Hard links

@Test func saveKeepsHardLinksTogether() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let a = dir.appendingPathComponent("a.txt")
    let b = dir.appendingPathComponent("b.txt")
    try write("old\n", a)
    try FileManager.default.linkItem(at: a, to: b)
    #expect(TextFileIO.isSameFile(a, b))

    let snap = try loadAndSave(a, "new\n")

    #expect(try read(b) == "new\n", "the other link sees the edit")
    #expect(stat(a).inode == stat(b).inode)
    #expect(stat(a).linkCount == 2)
    #expect(!TextFileIO.hasChanged(a, since: snap))
}

// MARK: - Path checks: dangling links, swapped-in links

@Test func savingThroughDanglingLinkRecreatesItsTarget() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let target = dir.appendingPathComponent("real.txt")
    let link = dir.appendingPathComponent("link.txt")
    try write("v1\n", target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let loaded = try TextFileIO.load(link)
    try FileManager.default.removeItem(at: target)

    // The link now dangles: that is "moved or deleted", not "changed by another app".
    #expect(TextFileIO.snapshot(of: link) == nil)
    #expect(TextFileIO.snapshot(of: loaded.resolvedURL) == nil)
    #expect(TextFileIO.resolved(link).path == loaded.resolvedURL.path)
    #expect(throws: TextFileIOError.changedOnDisk) {
        try TextFileIO.save("v2\n", format: loaded.format, to: loaded.resolvedURL, expected: loaded.snapshot)
    }
    // "Save" in the moved-or-deleted prompt recreates the target; the link stays a link.
    try TextFileIO.save("v2\n", format: loaded.format, to: loaded.resolvedURL,
                        expected: loaded.snapshot, force: true)
    #expect(try read(target) == "v2\n")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
}

@Test func saveRefusesFileSwappedForSymlink() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let opened = dir.appendingPathComponent("notes.txt")
    let victim = dir.appendingPathComponent("victim-rc")
    try write("mine\n", opened)
    try write("precious\n", victim)
    let loaded = try TextFileIO.load(opened)

    // Someone with write access to the folder swaps the file for a link.
    try FileManager.default.removeItem(at: opened)
    try FileManager.default.createSymbolicLink(at: opened, withDestinationURL: victim)

    for force in [false, true] {
        #expect(throws: TextFileIOError.redirected(to: TextFileIO.resolved(victim).path)) {
            try TextFileIO.save("evil\n", format: loaded.format, to: loaded.resolvedURL,
                                expected: loaded.snapshot, force: force)
        }
    }
    #expect(try read(victim) == "precious\n")
    #expect(throws: TextFileIOError.redirected(to: TextFileIO.resolved(victim).path)) {
        try TextFileIO.reload(loaded.resolvedURL, openedAs: opened, expectedFolder: loaded.snapshot.folder)
    }
}

@Test func reloadKeepsTheOpenedURLAndRereadsTheFile() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let target = dir.appendingPathComponent("real.txt")
    let link = dir.appendingPathComponent("link.txt")
    try write("v1\n", target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let loaded = try TextFileIO.load(link)
    try Data("v2\n".utf8).write(to: target, options: .atomic)
    let again = try TextFileIO.reload(loaded.resolvedURL, openedAs: loaded.url, expectedFolder: loaded.snapshot.folder)
    #expect(again.url == link)
    #expect(again.resolvedURL == loaded.resolvedURL)
    #expect(again.text == "v2\n")
}

@Test func saveRefusesFolderSwappedForSymlink() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let fm = FileManager.default
    let sub = dir.appendingPathComponent("sub", isDirectory: true)
    let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
    try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try write("mine\n", sub.appendingPathComponent("f.txt"))
    try write("theirs\n", elsewhere.appendingPathComponent("f.txt"))
    let loaded = try TextFileIO.load(sub.appendingPathComponent("f.txt"))

    try fm.moveItem(at: sub, to: dir.appendingPathComponent("moved"))
    try fm.createSymbolicLink(at: sub, withDestinationURL: elsewhere)

    #expect(throws: TextFileIOError.self) {
        try TextFileIO.save("x\n", format: loaded.format, to: loaded.resolvedURL,
                            expected: loaded.snapshot, force: true)
    }
    #expect(try read(elsewhere.appendingPathComponent("f.txt")) == "theirs\n")
}

// MARK: - Size limit

@Test func loadRefusesFilesOverTheSizeLimit() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let url = dir.appendingPathComponent("huge.log")
    #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: TextFileIO.maxEditableSize + 1)   // sparse: instant
    try handle.close()
    #expect(throws: TextFileIOError.tooLarge(TextFileIO.maxEditableSize + 1)) {
        try TextFileIO.load(url)
    }
}

#if canImport(Darwin)
// MARK: - macOS metadata

private func run(_ tool: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0, "\(tool) \(args)")
}

@Test func saveKeepsCreationDateTagsAndCustomAttributes() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    var url = dir.appendingPathComponent("tagged.txt")
    try write("v1\n", url)
    let created = Date(timeIntervalSince1970: 1_000_000_000)
    try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
    try (url as NSURL).setResourceValue(["Red"], forKey: .tagNamesKey)
    TextFileIO.setXattr(url.path, "com.example.custom", Data("kept".utf8))
    #expect(chflags(url.path, UInt32(UF_HIDDEN)) == 0)
    let inode = stat(url).inode

    try loadAndSave(url, "v2\n")
    #expect(stat(url).inode != inode, "this covers the replacing save")

    url.removeAllCachedResourceValues()
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attrs[.creationDate] as? Date) == created)
    #expect(try url.resourceValues(forKeys: [.tagNamesKey]).tagNames == ["Red"])
    #expect(TextFileIO.xattr(url.path, "com.example.custom") == Data("kept".utf8))
    var st = Darwin.stat()
    #expect(lstat(url.path, &st) == 0 && st.st_flags & UInt32(UF_HIDDEN) != 0, "hidden flag kept")
    #expect(try read(url) == "v2\n")
}

@Test func replacingSaveKeepsTheACL() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let url = dir.appendingPathComponent("acl.txt")
    try write("v1\n", url)
    try run("/bin/chmod", ["+a", "everyone allow read,write", url.path])
    let acl = TextFileIO.aclText(url.path)
    #expect(acl != nil)
    let inode = stat(url).inode

    try loadAndSave(url, "v2\n")

    #expect(stat(url).inode != inode, "this covers the replacing save")
    #expect(TextFileIO.aclText(url.path) == acl)
    #expect(try read(url) == "v2\n")
    expectNoLeftovers(in: dir, only: ["acl.txt"], fileName: "acl.txt")
}

/// A save that creates the file again (moved or deleted, user chose Save) uses the
/// usual permissions and leaves nothing else behind.
@Test func recreatingSaveLeavesNoTemporaryFiles() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let url = dir.appendingPathComponent("gone.txt")
    try write("v1\n", url)
    let loaded = try TextFileIO.load(url)
    try FileManager.default.removeItem(at: url)
    let snap = try TextFileIO.save("v2\n", format: loaded.format, to: loaded.resolvedURL,
                                   expected: loaded.snapshot, force: true)
    #expect(try read(url) == "v2\n")
    #expect(!TextFileIO.hasChanged(url, since: snap))
    expectNoLeftovers(in: dir, only: ["gone.txt"], fileName: "gone.txt")
}

@Test func saveKeepsQuarantineAndTextEncoding() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let url = dir.appendingPathComponent("downloaded.txt")
    try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: url)   // "café" in Latin-1
    let quarantine = Data("0081;65000000;Safari;".utf8)
    let latin1Tag = Data("iso-8859-1;513".utf8)
    TextFileIO.setXattr(url.path, TextFileIO.quarantineAttribute, quarantine)
    TextFileIO.setXattr(url.path, TextFileIO.textEncodingAttribute, latin1Tag)

    var loaded = try TextFileIO.load(url)
    #expect(loaded.format.encoding == .isoLatin1)
    var snap = try TextFileIO.save("café!\n", format: loaded.format, to: loaded.resolvedURL, expected: loaded.snapshot)
    #expect(TextFileIO.xattr(url.path, TextFileIO.quarantineAttribute) == quarantine)
    #expect(TextFileIO.xattr(url.path, TextFileIO.textEncodingAttribute) == latin1Tag)

    // "Save as UTF-8" updates the recorded encoding to match the bytes.
    loaded.format.encoding = .utf8
    snap = try TextFileIO.save("café € \n", format: loaded.format, to: loaded.resolvedURL, expected: snap)
    #expect(TextFileIO.xattr(url.path, TextFileIO.textEncodingAttribute) == Data("utf-8;134217984".utf8))
    #expect(TextFileIO.xattr(url.path, TextFileIO.quarantineAttribute) == quarantine)
    #expect(!TextFileIO.hasChanged(url, since: snap))
}

@Test(arguments: [
    ("iso-8859-1;513", String.Encoding.isoLatin1, "iso-8859-1;513"),
    ("iso-8859-1;513", .utf8, "utf-8;134217984"),
    ("utf-8;134217984", .utf8, "utf-8;134217984"),
    // A legacy guess never overwrites what the creating app recorded.
    ("macintosh;0", .isoLatin1, "macintosh;0"),
    ("garbage", .windowsCP1252, "garbage"),
])
func textEncodingAttributeAfterSave(original: String, saved: String.Encoding, expected: String) {
    #expect(TextFileIO.textEncodingValue(original: original, saved: saved) == expected)
}

@Test(.enabled(if: getuid() != 0, "root ignores folder permissions"))
func saveInReadOnlyFolderWritesInPlace() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let name = "locked-\(UUID().uuidString).txt"
    let url = dir.appendingPathComponent(name)
    try write("v1\n", url)
    let inode = stat(url).inode
    #expect(chmod(dir.path, 0o555) == 0)

    let snap = try loadAndSave(url, "v2\n")

    #expect(try read(url) == "v2\n")
    #expect(stat(url).inode == inode)
    #expect(!TextFileIO.hasChanged(url, since: snap))
    expectNoLeftovers(in: dir, only: [name], fileName: name)
}

@Test(.enabled(if: getuid() != 0, "root ignores ACLs"))
func saveWithDenyDeleteACLWritesInPlaceAndCleansUp() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let name = "guarded-\(UUID().uuidString).txt"
    let url = dir.appendingPathComponent(name)
    try write("v1\n", url)
    try run("/bin/chmod", ["+a", "everyone deny delete", url.path])
    let acl = TextFileIO.aclText(url.path)
    #expect(acl != nil)

    try loadAndSave(url, "v2\n")

    #expect(try read(url) == "v2\n")
    #expect(TextFileIO.aclText(url.path) == acl, "the ACL stays on the file")
    expectNoLeftovers(in: dir, only: [name], fileName: name)
}

@Test func ordinarySaveLeavesNoTemporaryFiles() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let name = "plain-\(UUID().uuidString).txt"
    let url = dir.appendingPathComponent(name)
    try write("v1\n", url)
    let inode = stat(url).inode
    try loadAndSave(url, "v2\n")
    #expect(try read(url) == "v2\n")
    #expect(stat(url).inode != inode, "the save replaced the file atomically")
    expectNoLeftovers(in: dir, only: [name], fileName: name)
}
#endif
