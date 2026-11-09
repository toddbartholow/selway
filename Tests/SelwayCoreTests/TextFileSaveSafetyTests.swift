import Foundation
import Testing
@testable import SelwayCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// What "Overwrite", temporary copies, recreation, reload and in-place writes must
// never do: write into a file planted at the name, expose the text through an
// inherited ACL, clobber a file that appeared meanwhile, trust a replaced folder,
// or start an in-place write the disk can't finish or undo.

// MARK: - Helpers

private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TextFileSaveSafetyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return TextFileIO.resolved(dir)
}

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
private func info(_ url: URL) -> TextFileIO.FileInfo? { TextFileIO.fileInfo(url) }

/// Reads what an open descriptor's file holds (it may no longer have a name).
private func read(fd: Int32) -> String {
    var buffer = [UInt8](repeating: 0, count: 4096)
    let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
    return String(decoding: buffer.prefix(max(0, n)), as: UTF8.self)
}

#if canImport(Darwin)
private func run(_ tool: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0, "\(tool) \(args)")
}
#endif

/// Makes everything created in `folder` inherit an allow-read entry (macOS), so a
/// new file or folder that isn't made private on creation is readable by everyone.
private func shareNewItems(in folder: URL) throws {
    #if canImport(Darwin)
    try run("/bin/chmod", ["+a", "everyone allow read,execute,file_inherit,directory_inherit", folder.path])
    #endif
}

/// Writes a private file: mode 600 and no ACL, whatever the folder hands down.
private func writePrivate(_ text: String, _ url: URL) throws {
    try write(text, url)
    #if canImport(Darwin)
    TextFileIO.removeACL(url.path)
    #endif
    #expect(chmod(url.path, 0o600) == 0)
}

/// The file at `url` is no more open than the private file that was loaded.
private func expectPrivate(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) {
    let mode = info(url)?.permissions ?? 0o777
    #expect(mode & 0o077 == 0, "mode \(String(mode, radix: 8))", sourceLocation: sourceLocation)
    #if canImport(Darwin)
    #expect(TextFileIO.aclText(url.path) == nil, "ACL \(TextFileIO.aclText(url.path) ?? "")",
            sourceLocation: sourceLocation)
    #endif
}

// MARK: - Overwrite never writes into a planted file

/// Someone who can write the folder replaces the file with a hard link to a file
/// of the user's they can reach (~/.zshrc). The save sees a change; the user
/// chooses Overwrite. The linked file must not receive the buffer.
@Test func overwriteNeverWritesThroughAPlantedHardLink() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let shared = dir.appendingPathComponent("shared", isDirectory: true)
    let home = dir.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    try shareNewItems(in: shared)
    let file = shared.appendingPathComponent("build.sh")
    let victim = home.appendingPathComponent(".zshrc")
    try writePrivate("mine\n", file)
    try write("precious\n", victim)
    #if canImport(Darwin)
    TextFileIO.setXattr(victim.path, "com.example.victim", Data("theirs".utf8))
    #expect(chflags(victim.path, UInt32(UF_HIDDEN)) == 0)
    #endif
    let victimInode = info(victim)?.inode
    let loaded = try TextFileIO.load(file)

    try FileManager.default.removeItem(at: file)
    try FileManager.default.linkItem(at: victim, to: file)

    #expect(throws: TextFileIOError.changedOnDisk) {
        try TextFileIO.save("edited\n", format: loaded.format, to: loaded.resolvedURL, expected: loaded.snapshot)
    }
    // Overwrite: the name gets a new file with the text; the linked file keeps its own.
    _ = try? TextFileIO.save("edited\n", format: loaded.format, to: loaded.resolvedURL,
                             expected: loaded.snapshot, force: true)
    #expect(try read(victim) == "precious\n", "the buffer went into the hard-linked file")
    #expect(info(victim)?.inode == victimInode)
    #expect(info(victim)?.linkCount == 1, "the planted link was replaced")
    #expect(info(file)?.inode != victimInode)
    #expect(try read(file) == "edited\n")
    expectPrivate(file)
    expectNoMetadataFromPlantedFile(file, attribute: "com.example.victim")
}

/// A file someone else owns, swapped in at the name: Overwrite must not write the
/// user's text into it (it would then be theirs to read). Without root to chown,
/// the save is told the user is someone else, so a file the test owns is foreign.
@Test func overwriteNeverWritesIntoAPlantedForeignFile() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    try shareNewItems(in: dir)
    let file = dir.appendingPathComponent("notes.txt")
    try writePrivate("mine\n", file)
    let loaded = try TextFileIO.load(file)

    try FileManager.default.removeItem(at: file)
    try write("planted\n", file)
    #if canImport(Darwin)
    TextFileIO.setXattr(file.path, "com.example.planted", Data("theirs".utf8))
    #expect(chflags(file.path, UInt32(UF_HIDDEN)) == 0)
    #endif
    #expect(chmod(file.path, 0o666) == 0)
    if geteuid() == 0 { #expect(chown(file.path, 4321, 4321) == 0) }
    let planted = open(file.path, O_RDONLY)
    #expect(planted >= 0)
    defer { close(planted) }

    var hooks = TextFileIOHooks()
    if geteuid() != 0 { hooks.effectiveUser = geteuid() &+ 1 }
    _ = try? TextFileIO.save("secret\n", format: loaded.format, to: loaded.resolvedURL,
                             expected: loaded.snapshot, force: true, hooks: hooks)
    #expect(read(fd: planted) == "planted\n", "the user's text went into the planted file")
    #expect(try read(file) == "secret\n", "the name got a new file with the text")
    expectPrivate(file)
    expectNoMetadataFromPlantedFile(file, attribute: "com.example.planted")
}

/// A file that isn't the user's alone (someone else's, or linked to another of the
/// user's files) gives the new file none of its attributes or flags.
private func expectNoMetadataFromPlantedFile(_ url: URL, attribute: String,
                                             sourceLocation: SourceLocation = #_sourceLocation) {
    #if canImport(Darwin)
    #expect(TextFileIO.xattr(url.path, attribute) == nil, "copied \(attribute)", sourceLocation: sourceLocation)
    var st = stat()
    #expect(lstat(url.path, &st) == 0, sourceLocation: sourceLocation)
    #expect(st.st_flags & UInt32(UF_HIDDEN) == 0, "copied the hidden flag", sourceLocation: sourceLocation)
    #endif
}

/// Another app saving atomically (a new inode, the user's own, one link) is the
/// ordinary conflict: Overwrite replaces it with the loaded file's permissions and
/// keeps what the file carries besides: tags, quarantine (a downloaded script
/// stays quarantined), other extended attributes, the hidden flag and the
/// creation date.
@Test func overwriteOfAnAtomicSaveByAnotherAppStillWorks() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let file = dir.appendingPathComponent("install.command")
    try writePrivate("mine\n", file)
    let loaded = try TextFileIO.load(file)
    try Data("theirs\n".utf8).write(to: file, options: .atomic)
    #expect(chmod(file.path, 0o600) == 0)   // an atomic save keeps the file's mode
    #if canImport(Darwin)
    TextFileIO.removeACL(file.path)
    let created = Date(timeIntervalSince1970: 1_000_000_000)
    let quarantine = Data("0081;5f000000;Safari;".utf8)
    try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: file.path)
    try (file as NSURL).setResourceValue(["Red"], forKey: .tagNamesKey)
    #expect(TextFileIO.setXattr(file.path, TextFileIO.quarantineAttribute, quarantine))
    #expect(TextFileIO.setXattr(file.path, "com.example.custom", Data("kept".utf8)))
    #expect(chflags(file.path, UInt32(UF_HIDDEN)) == 0)
    #endif

    let snap = try TextFileIO.save("edited\n", format: loaded.format, to: loaded.resolvedURL,
                                   expected: loaded.snapshot, force: true)
    #expect(try read(file) == "edited\n")
    #expect(info(file)?.permissions == 0o600, "the loaded file's permissions")
    expectPrivate(file)
    #expect(!TextFileIO.hasChanged(file, since: snap))
    #if canImport(Darwin)
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect(attrs[.creationDate] as? Date == created)
    let fresh = URL(fileURLWithPath: file.path)
    #expect(try fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames == ["Red"])
    #expect(TextFileIO.xattr(file.path, TextFileIO.quarantineAttribute) == quarantine)
    #expect(TextFileIO.xattr(file.path, "com.example.custom") == Data("kept".utf8))
    var st = stat()
    #expect(lstat(file.path, &st) == 0)
    #expect(st.st_flags & UInt32(UF_HIDDEN) != 0)
    #endif
}

/// Another file of the user's put at the name (another app's atomic save, or one
/// moved there by someone who can write the folder): Overwrite replaces it, with
/// the permissions of the file that was loaded, not that file's.
@Test func overwriteOfAReplacedFileKeepsTheLoadedPermissions() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    try shareNewItems(in: dir)
    let file = dir.appendingPathComponent("notes.txt")
    try writePrivate("mine\n", file)
    let loaded = try TextFileIO.load(file)
    try Data("theirs\n".utf8).write(to: file, options: .atomic)
    #expect(chmod(file.path, 0o644) == 0)
    #if canImport(Darwin)
    try run("/bin/chmod", ["+a", "everyone allow read", file.path])
    #endif
    let snap = try TextFileIO.save("edited\n", format: loaded.format, to: loaded.resolvedURL,
                                   expected: loaded.snapshot, force: true)
    #expect(try read(file) == "edited\n")
    #expect(info(file)?.permissions == 0o600)
    expectPrivate(file)
    #expect(!TextFileIO.hasChanged(file, since: snap))
}

/// Someone who can write a shared, non-sticky folder renames another of the
/// user's files onto the name: one more open than the file that was loaded (wider
/// mode, or an ACL granting more). Overwrite gives the new file the loaded
/// permissions and none of that file's metadata (where it was downloaded from,
/// tags, …), so nothing about it reaches whoever the loaded file is shared with.
/// Quarantine is still kept: it only ever restricts.
@Test(arguments: [false, true])
func overwriteTakesNoMetadataFromAMoreOpenFileOfTheUsers(widerByACL: Bool) throws {
    #if !canImport(Darwin)
    if widerByACL { return }
    #endif
    let dir = try makeDir()
    defer { removeDir(dir) }
    let file = dir.appendingPathComponent("notes.txt")
    try writePrivate("mine\n", file)
    let loaded = try TextFileIO.load(file)

    let other = dir.appendingPathComponent("elsewhere.txt")
    try writePrivate("other\n", other)
    if widerByACL {
        #if canImport(Darwin)
        try run("/bin/chmod", ["+a", "everyone allow read", other.path])
        #endif
    } else {
        #expect(chmod(other.path, 0o644) == 0)
    }
    #if canImport(Darwin)
    let quarantine = Data("0081;5f000000;Safari;".utf8)
    try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000_000_000)],
                                          ofItemAtPath: other.path)
    try (other as NSURL).setResourceValue(["Secret Project"], forKey: .tagNamesKey)
    #expect(TextFileIO.setXattr(other.path, "com.apple.metadata:kMDItemWhereFroms", Data("https://intranet/".utf8)))
    #expect(TextFileIO.setXattr(other.path, TextFileIO.quarantineAttribute, quarantine))
    #expect(chflags(other.path, UInt32(UF_HIDDEN)) == 0)
    #endif
    #expect(rename(other.path, file.path) == 0)

    try TextFileIO.save("edited\n", format: loaded.format, to: loaded.resolvedURL,
                        expected: loaded.snapshot, force: true)
    #expect(try read(file) == "edited\n")
    #expect(info(file)?.permissions == 0o600)
    expectPrivate(file)
    #if canImport(Darwin)
    #expect(TextFileIO.xattr(file.path, TextFileIO.quarantineAttribute) == quarantine, "quarantine is kept")
    #expect(TextFileIO.xattr(file.path, "com.apple.metadata:kMDItemWhereFroms") == nil)
    let fresh = URL(fileURLWithPath: file.path)
    #expect(try fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [] == [])
    var st = stat()
    #expect(lstat(file.path, &st) == 0)
    #expect(st.st_flags & UInt32(UF_HIDDEN) == 0)
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect(attrs[.creationDate] as? Date != Date(timeIntervalSince1970: 1_000_000_000))
    #endif
}

// MARK: - The temporary copy is private until it is complete

/// The text is only ever written into a private folder made for the save (mode
/// 700, no ACL, so nothing in it inherits anything and nobody else can look it
/// up), never into a file created directly in the shared folder, where anyone
/// the folder's ACL lets in could open it before its ACL was cleared.
@Test(arguments: [false, true])
func temporaryCopyIsMadeInAPrivateFolder(recreate: Bool) throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let folder = dir.appendingPathComponent("team", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try shareNewItems(in: folder)
    let file = folder.appendingPathComponent("private.txt")
    try writePrivate("v1\n", file)
    let loaded = try TextFileIO.load(file)
    if recreate { try FileManager.default.removeItem(at: file) }

    var sawText = false
    var hooks = TextFileIOHooks()
    hooks.checkpoint = { checkpoint in
        // Just made and still empty: its inherited ACL is cleared once it is opened
        // and checked, before anything is created in it.
        guard checkpoint != .scratchFolderCreated else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name != "private.txt" {
            let item = folder.appendingPathComponent(name)
            guard let scratch = info(item) else { continue }
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
            guard isDir.boolValue else {
                Issue.record("temporary copy \(name) created directly in the folder at \(checkpoint)")
                continue
            }
            #expect(scratch.permissions == 0o700, "scratch folder mode \(String(scratch.permissions, radix: 8))")
            #expect(scratch.owner == geteuid())
            #if canImport(Darwin)
            #expect(TextFileIO.aclText(item.path) == nil, "scratch folder ACL at \(checkpoint)")
            #endif
            for inner in (try? FileManager.default.contentsOfDirectory(atPath: item.path)) ?? [] {
                expectPrivate(item.appendingPathComponent(inner))
                if checkpoint == .beforeMetadata { sawText = true }
            }
        }
    }
    try TextFileIO.save("secret\n", format: loaded.format, to: loaded.resolvedURL,
                        expected: loaded.snapshot, force: recreate, hooks: hooks)
    #expect(sawText, "the text was written inside the private folder")
    #expect(try read(file) == "secret\n")
    expectPrivate(file)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["private.txt"])
}

// MARK: - Long names

@Test(arguments: [false, true])
func saveWorksForTheLongestNames(recreate: Bool) throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let name = String(repeating: "n", count: 246) + ".txt"   // 250 bytes
    let file = dir.appendingPathComponent(name)
    try write("v1\n", file)
    let loaded = try TextFileIO.load(file)
    if recreate { try FileManager.default.removeItem(at: file) }
    try TextFileIO.save("v2\n", format: loaded.format, to: loaded.resolvedURL,
                        expected: loaded.snapshot, force: recreate)
    #expect(try read(file) == "v2\n")
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [name])
}

@Test func temporaryNamesStayShortAndWhole() {
    for name in [String(repeating: "é", count: 125), String(repeating: "n", count: 250), "a.txt", "😀🎉" + String(repeating: "x", count: 240)] {
        let temp = TextFileIO.temporaryName(for: name)
        #expect(temp.utf8.count <= 81, "\(temp.utf8.count) bytes")
        #expect(temp.hasPrefix("."))
        #expect(String(decoding: Array(temp.utf8), as: UTF8.self) == temp, "split a character")
    }
}

// MARK: - Recreating never replaces a file that appeared meanwhile

@Test(arguments: [0, 1, 2])
func recreatingNeverReplacesAFileThatAppeared(fallback: Int) throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    try shareNewItems(in: dir)
    let file = dir.appendingPathComponent("gone.txt")
    try writePrivate("v1\n", file)
    let loaded = try TextFileIO.load(file)
    try FileManager.default.removeItem(at: file)

    var hooks = TextFileIOHooks()
    hooks.exclusiveRenameUnsupported = fallback >= 1
    hooks.hardLinksUnsupported = fallback >= 2
    var appeared = false
    hooks.checkpoint = { checkpoint in
        guard checkpoint == .beforeWrite, !appeared else { return }
        appeared = true
        try? write("appeared\n", file)
    }
    #expect(throws: TextFileIOError.changedOnDisk) {
        try TextFileIO.save("v2\n", format: loaded.format, to: loaded.resolvedURL,
                            expected: loaded.snapshot, force: true, hooks: hooks)
    }
    #expect(appeared)
    #expect(try read(file) == "appeared\n")
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["gone.txt"])

    // With nothing in the way, each fallback recreates the file.
    try FileManager.default.removeItem(at: file)
    hooks.checkpoint = nil
    try TextFileIO.save("v2\n", format: loaded.format, to: loaded.resolvedURL,
                        expected: loaded.snapshot, force: true, hooks: hooks)
    #expect(try read(file) == "v2\n")
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["gone.txt"])
    expectPrivate(file)
}

// MARK: - Reload checks the folder too

@Test func reloadRefusesAFolderReplacedByAnotherFolder() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let folder = dir.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let file = folder.appendingPathComponent("notes.txt")
    try write("mine\n", file)
    let loaded = try TextFileIO.load(file)

    try FileManager.default.moveItem(at: folder, to: dir.appendingPathComponent("project-old"))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try write("planted\n", file)

    #expect(throws: TextFileIOError.folderReplaced(folder.path)) {
        try TextFileIO.reload(loaded.resolvedURL, openedAs: loaded.url, expectedFolder: loaded.snapshot.folder)
    }
    // Opening it again explicitly trusts the new folder.
    #expect(try TextFileIO.load(file).text == "planted\n")
}

// MARK: - In-place writes need room to finish or undo

@Test func inPlaceSaveNeedsRoomForTheNewAndTheOriginalBytes() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let file = dir.appendingPathComponent("linked.txt")
    let original = String(repeating: "original\n", count: 100)
    try write(original, file)
    try FileManager.default.linkItem(at: file, to: dir.appendingPathComponent("other.txt"))
    let loaded = try TextFileIO.load(file)
    let text = String(repeating: "x", count: 500)   // shorter than the original

    var hooks = TextFileIOHooks()
    hooks.freeSpace = UInt64(text.utf8.count + original.utf8.count - 1)
    do {
        try TextFileIO.save(text, format: loaded.format, to: loaded.resolvedURL,
                            expected: loaded.snapshot, hooks: hooks)
        Issue.record("saved without room to put the original back")
    } catch TextFileIOError.io(let message) {
        #expect(message.contains("free space"), "\(message)")
    }
    #expect(try read(file) == original)

    hooks.freeSpace = UInt64(text.utf8.count + original.utf8.count)
    try TextFileIO.save(text, format: loaded.format, to: loaded.resolvedURL,
                        expected: loaded.snapshot, hooks: hooks)
    #expect(try read(file) == text)
}

// MARK: - The scratch folder is the one this save made

/// The scratch folder's name in the file's folder, while a save of `file` runs.
private func scratchFolder(for file: URL) -> URL? {
    let prefix = "." + String(file.lastPathComponent.prefix(32)) + ".selwaysave-"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)) ?? []
    return names.first { $0.hasPrefix(prefix) }.map { file.deletingLastPathComponent().appendingPathComponent($0) }
}

/// Someone who can write a shared (non-sticky) folder renames one of the user's
/// own folders to the scratch folder's name right after it was made. The save
/// must not take it over: clearing its ACL and making it mode 700 would lock the
/// user's collaborators out of it.
@Test(arguments: [false, true])
func saveNeverTakesOverAUserFolderSwappedInForTheScratchFolder(withACL: Bool) throws {
    #if !canImport(Darwin)
    if withACL { return }
    #endif
    let dir = try makeDir()
    defer { removeDir(dir) }
    let file = dir.appendingPathComponent("notes.txt")
    try write("mine\n", file)
    let projects = dir.appendingPathComponent("Projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: false)
    #expect(chmod(projects.path, withACL ? 0o700 : 0o755) == 0)
    #if canImport(Darwin)
    if withACL { try run("/bin/chmod", ["+a", "everyone allow list,search", projects.path]) }
    let projectsACL = TextFileIO.aclText(projects.path)
    #endif
    let projectsMode = info(projects)?.permissions
    let loaded = try TextFileIO.load(file)

    var swapped: URL?
    var hooks = TextFileIOHooks()
    hooks.checkpoint = { checkpoint in
        guard checkpoint == .scratchFolderCreated, swapped == nil, let scratch = scratchFolder(for: file) else { return }
        do {
            try FileManager.default.moveItem(at: scratch, to: dir.appendingPathComponent("scratch-real"))
            try FileManager.default.moveItem(at: projects, to: scratch)
            swapped = scratch
        } catch { Issue.record("swap failed: \(error)") }
    }
    #expect(throws: TextFileIOError.self) {
        try TextFileIO.save("edited\n", format: loaded.format, to: loaded.resolvedURL,
                            expected: loaded.snapshot, hooks: hooks)
    }
    let victim = try #require(swapped)
    #expect(info(victim)?.permissions == projectsMode, "the user's folder was re-permissioned")
    #if canImport(Darwin)
    #expect(TextFileIO.aclText(victim.path) == projectsACL, "the user's folder lost its ACL")
    #endif
    #expect(try FileManager.default.contentsOfDirectory(atPath: victim.path).isEmpty)
    #expect(try read(file) == "mine\n")
}

/// The scratch folder is renamed away mid-save and an empty folder of the user's
/// put at its name: cleaning up removes the scratch folder only, never by name
/// alone.
@Test func cleanupNeverRemovesAFolderPutAtTheScratchName() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let file = dir.appendingPathComponent("notes.txt")
    try write("mine\n", file)
    let loaded = try TextFileIO.load(file)

    var planted: URL?
    var hooks = TextFileIOHooks()
    hooks.checkpoint = { checkpoint in
        guard checkpoint == .beforeMetadata, planted == nil, let scratch = scratchFolder(for: file) else { return }
        do {
            try FileManager.default.moveItem(at: scratch, to: dir.appendingPathComponent("scratch-real"))
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            planted = scratch
        } catch { Issue.record("swap failed: \(error)") }
    }
    try TextFileIO.save("edited\n", format: loaded.format, to: loaded.resolvedURL,
                        expected: loaded.snapshot, hooks: hooks)
    #expect(try read(file) == "edited\n")
    let folder = try #require(planted)
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue,
            "the folder put at the scratch name was removed")
}

#if canImport(Darwin)
/// Recreating through a hard link, with a loaded ACL that denies deleting the
/// file: the scratch link must go before that ACL is applied, or it stays behind
/// (a second link to the text in a leftover folder, and every later save of the
/// now two-link file is written in place).
@Test func recreatingThroughAHardLinkLeavesOneLinkWithADenyDeleteACL() throws {
    let dir = try makeDir()
    defer { removeDir(dir) }
    let file = dir.appendingPathComponent("gone.txt")
    try writePrivate("v1\n", file)
    try run("/bin/chmod", ["+a", "everyone deny delete", file.path])
    let loaded = try TextFileIO.load(file)
    TextFileIO.removeACL(file.path)
    try FileManager.default.removeItem(at: file)

    var hooks = TextFileIOHooks()
    hooks.exclusiveRenameUnsupported = true   // the hard-link fallback
    try TextFileIO.save("v2\n", format: loaded.format, to: loaded.resolvedURL,
                        expected: loaded.snapshot, force: true, hooks: hooks)
    #expect(try read(file) == "v2\n")
    #expect(info(file)?.linkCount == 1, "a second link to the text was left behind")
    #expect(TextFileIO.aclText(file.path)?.contains("deny") == true, "the loaded ACL")
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["gone.txt"])
}
#endif

#if os(macOS)
/// Saving on FAT and exFAT (volumes without ownership or ACLs) must work. "MS-DOS 777"
/// is FAT mounted the way removable disks often are, with every item reported as
/// rwxrwxrwx: the private scratch folder can't be made 0700 there, so the save falls
/// back to rewriting the file in place instead of failing. Mounts a small image in a
/// temporary folder (hidden, nothing opened, always detached), so it only runs when
/// asked: `SELWAY_RUN_HDIUTIL_TESTS=1 ./scripts/test.sh --filter savesOnAFATVolume`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SELWAY_RUN_HDIUTIL_TESTS"] == "1"),
      arguments: ["MS-DOS", "ExFAT", "MS-DOS 777"])
func savesOnAFATVolume(volume: String) throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let image = dir.url.appendingPathComponent("fat.dmg")
    let mount = try dir.dir("mnt")
    let fileSystem = volume == "ExFAT" ? "ExFAT" : "MS-DOS"
    let create = TestTool.run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "16m", "-fs", fileSystem,
                                                   "-volname", "SELWAYFAT", "-layout", "NONE", image.path])
    try #require(create.status == 0, "\(create.text)")
    defer { TestTool.detachImages(of: image) }
    if volume == "MS-DOS 777" {
        let attach = TestTool.run("/usr/bin/hdiutil", ["attach", "-nomount", "-noautoopen", image.path])
        try #require(attach.status == 0, "\(attach.text)")
        let device = try #require(attach.output.split(whereSeparator: \.isWhitespace).first.map(String.init))
        let mounted = TestTool.run("/sbin/mount_msdos", ["-m", "777", "-o", "nobrowse", device, mount.path])
        try #require(mounted.status == 0, "\(mounted.text)")
    } else {
        let attach = TestTool.run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noautoopen",
                                                       "-mountpoint", mount.path, image.path])
        try #require(attach.status == 0, "\(attach.text)")
    }

    let file = mount.appendingPathComponent("notes.txt")
    try Data("v1\n".utf8).write(to: file)
    let loaded = try TextFileIO.load(file)
    _ = try TextFileIO.save("v2\n", format: loaded.format, to: loaded.resolvedURL, expected: loaded.snapshot)
    #expect(try String(contentsOf: file, encoding: .utf8) == "v2\n")
    // Saving again after the file was deleted creates it.
    try FileManager.default.removeItem(at: file)
    _ = try TextFileIO.save("v3\n", format: loaded.format, to: loaded.resolvedURL, expected: nil, force: true)
    #expect(try String(contentsOf: file, encoding: .utf8) == "v3\n")
    // No scratch folder or temporary copy is left behind.
    let names = try FileManager.default.contentsOfDirectory(atPath: mount.path)
        .filter { ![".fseventsd", ".Trashes", ".Spotlight-V100"].contains($0) && !$0.hasPrefix("._") }
    #expect(names == ["notes.txt"])
}
#endif
