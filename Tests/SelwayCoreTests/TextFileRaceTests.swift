import Foundation
import Testing
@testable import SelwayCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Saves and loads racing someone who can rename a folder on the path (another
// account in /Users/Shared, a group-writable project, an SMB share): the path is
// checked, then the folder is swapped for a link to the user's own files. Nothing
// may be read from, written to or re-permissioned through that link.

// MARK: - Helpers

/// A canonical (symlink-free) scratch folder, so paths compare as the code sees them.
private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TextFileRaceTests-\(UUID().uuidString)", isDirectory: true)
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
private func inode(_ url: URL) -> UInt64? { TextFileIO.fileInfo(url)?.inode }

/// Calls `action` the first time `checkpoint` is reached.
private final class Trigger {
    var fired = false
    func hooks(at checkpoint: TextFileIOHooks.Checkpoint, _ action: @escaping () throws -> Void) -> TextFileIOHooks {
        var hooks = TextFileIOHooks()
        hooks.checkpoint = { [self] reached in
            guard reached == checkpoint, !fired else { return }
            fired = true
            do { try action() } catch { Issue.record("swap failed: \(error)") }
        }
        return hooks
    }
}

/// `shared/` is the folder the user edits in; `outside/` stands for their home
/// folder, holding a same-named file the attacker wants overwritten.
private struct Scene {
    let base: URL
    var shared: URL { base.appendingPathComponent("shared", isDirectory: true) }
    var moved: URL { base.appendingPathComponent("shared-real", isDirectory: true) }
    var outside: URL { base.appendingPathComponent("outside", isDirectory: true) }
    var file: URL { shared.appendingPathComponent("notes.txt") }
    var outsideFile: URL { outside.appendingPathComponent("notes.txt") }

    init() throws {
        base = try makeDir()
        let fm = FileManager.default
        try fm.createDirectory(at: shared, withIntermediateDirectories: false)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try write("mine\n", file)
        try write("sentinel\n", outsideFile)
    }

    /// Moves the real folder aside and puts a link to `outside` in its place.
    func swapFolderForLink() throws {
        let fm = FileManager.default
        try fm.moveItem(at: shared, to: moved)
        try fm.createSymbolicLink(at: shared, withDestinationURL: outside)
    }
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

// MARK: - Save racing a folder swap

private let saveModes: [(inPlace: Bool, force: Bool)] = [(false, false), (false, true), (true, false), (true, true)]

@Test(arguments: TextFileIOHooks.Checkpoint.allCases, saveModes)
func saveNeverWritesThroughAFolderSwappedMidSave(checkpoint: TextFileIOHooks.Checkpoint,
                                                 mode: (inPlace: Bool, force: Bool)) throws {
    try raceSave(at: checkpoint, mode: mode) { scene in try scene.swapFolderForLink() }
}

/// Same, with the file itself swapped for a link (by someone who can write to the folder).
@Test(arguments: TextFileIOHooks.Checkpoint.allCases, saveModes)
func saveNeverWritesThroughAFileSwappedMidSave(checkpoint: TextFileIOHooks.Checkpoint,
                                               mode: (inPlace: Bool, force: Bool)) throws {
    try raceSave(at: checkpoint, mode: mode) { scene in
        try FileManager.default.moveItem(at: scene.file, to: scene.shared.appendingPathComponent("moved.txt"))
        try FileManager.default.createSymbolicLink(at: scene.file, withDestinationURL: scene.outsideFile)
    }
}

private func raceSave(at checkpoint: TextFileIOHooks.Checkpoint, mode: (inPlace: Bool, force: Bool),
                      swap: @escaping (Scene) throws -> Void,
                      sourceLocation: SourceLocation = #_sourceLocation) throws {
    let scene = try Scene()
    defer { removeDir(scene.base) }
    if mode.inPlace {
        // A second hard link makes the save overwrite the file in place.
        try FileManager.default.linkItem(at: scene.file, to: scene.shared.appendingPathComponent("link.txt"))
    }
    #if canImport(Darwin)
    // A shared file typically lets everyone write; that must never reach the user's file.
    try run("/bin/chmod", ["+a", "everyone allow write,append", scene.file.path])
    TextFileIO.setXattr(scene.file.path, "com.example.shared", Data("shared".utf8))
    TextFileIO.setXattr(scene.outsideFile.path, "com.example.outside", Data("keep".utf8))
    #endif
    let outsideInode = inode(scene.outsideFile)
    let outsideMode = TextFileIO.fileInfo(scene.outsideFile)?.permissions

    let loaded = try TextFileIO.load(scene.file)
    let trigger = Trigger()
    let hooks = trigger.hooks(at: checkpoint) { try swap(scene) }
    let result = Result {
        try TextFileIO.saveDocument("edited\n", format: loaded.format, to: loaded.resolvedURL,
                                    expected: loaded.snapshot, force: mode.force, hooks: hooks)
    }

    // In-place saves make no temporary copy.
    #expect(trigger.fired || (mode.inPlace && [.scratchFolderCreated, .temporaryCreated].contains(checkpoint)),
            "the swap happened",
            sourceLocation: sourceLocation)
    #expect(try read(scene.outsideFile) == "sentinel\n", "the outside file was overwritten",
            sourceLocation: sourceLocation)
    #expect(inode(scene.outsideFile) == outsideInode, "the outside file was replaced",
            sourceLocation: sourceLocation)
    #expect(TextFileIO.fileInfo(scene.outsideFile)?.permissions == outsideMode, sourceLocation: sourceLocation)
    #expect(try FileManager.default.contentsOfDirectory(atPath: scene.outside.path) == ["notes.txt"],
            "nothing was created next to the outside file", sourceLocation: sourceLocation)
    #if canImport(Darwin)
    #expect(TextFileIO.aclText(scene.outsideFile.path) == nil, "the shared file's ACL reached the outside file",
            sourceLocation: sourceLocation)
    #expect(TextFileIO.xattr(scene.outsideFile.path, "com.example.outside") == Data("keep".utf8),
            sourceLocation: sourceLocation)
    #expect(TextFileIO.xattr(scene.outsideFile.path, "com.example.shared") == nil, sourceLocation: sourceLocation)
    #endif
    if case .failure(let error) = result {
        #expect(error is TextFileIOError, "\(error)", sourceLocation: sourceLocation)
    }
}

/// "Save" after the file was deleted creates it again, but only in its own folder,
/// never in one a swapped-in link leads to.
@Test(arguments: [TextFileIOHooks.Checkpoint.afterPathCheck, .beforeWrite, .temporaryCreated])
func recreatingSaveNeverCreatesThroughAFolderSwappedMidSave(checkpoint: TextFileIOHooks.Checkpoint) throws {
    let scene = try Scene()
    defer { removeDir(scene.base) }
    let loaded = try TextFileIO.load(scene.file)
    try FileManager.default.removeItem(at: scene.file)
    try FileManager.default.removeItem(at: scene.outsideFile)
    let trigger = Trigger()
    let hooks = trigger.hooks(at: checkpoint) { try scene.swapFolderForLink() }
    _ = try? TextFileIO.saveDocument("edited\n", format: loaded.format, to: loaded.resolvedURL,
                                     expected: loaded.snapshot, force: true, hooks: hooks)
    #expect(trigger.fired)
    #expect(try FileManager.default.contentsOfDirectory(atPath: scene.outside.path).isEmpty,
            "a file was created through the link")
}

/// The folder is replaced by a different real folder (not a link) holding a
/// same-named file: the save is for the folder the file was opened in, so it is
/// refused even when the user chose to overwrite.
@Test(arguments: [false, true])
func saveRefusesAFolderReplacedByAnotherFolder(force: Bool) throws {
    let scene = try Scene()
    defer { removeDir(scene.base) }
    let loaded = try TextFileIO.load(scene.file)
    let fm = FileManager.default
    try fm.moveItem(at: scene.shared, to: scene.moved)
    try fm.createDirectory(at: scene.shared, withIntermediateDirectories: false)
    try write("planted\n", scene.file)

    #expect(throws: TextFileIOError.self) {
        try TextFileIO.save("edited\n", format: loaded.format, to: loaded.resolvedURL,
                            expected: loaded.snapshot, force: force)
    }
    #expect(try read(scene.file) == "planted\n")
    #expect(try read(scene.moved.appendingPathComponent("notes.txt")) == "mine\n")
}

// MARK: - Load racing a swap

@Test(arguments: [false, true])
func loadNeverReadsThroughALinkSwappedInAfterTheCheck(swapFolder: Bool) throws {
    let scene = try Scene()
    defer { removeDir(scene.base) }
    let trigger = Trigger()
    let hooks = trigger.hooks(at: .afterPathCheck) {
        if swapFolder {
            try scene.swapFolderForLink()
        } else {
            try FileManager.default.removeItem(at: scene.file)
            try FileManager.default.createSymbolicLink(at: scene.file, withDestinationURL: scene.outsideFile)
        }
    }
    let result = Result { try TextFileIO.load(scene.file, hooks: hooks) }
    #expect(trigger.fired)
    switch result {
    case .success(let loaded):
        Issue.record("loaded “\(loaded.text)” through a swapped-in link")
    case .failure(let error):
        guard case .redirected? = error as? TextFileIOError else {
            Issue.record("expected .redirected, got \(error)")
            return
        }
    }
}

// MARK: - Case-only renames (case-insensitive volumes)

private func isCaseInsensitive(_ dir: URL) -> Bool {
    let probe = dir.appendingPathComponent("case-probe")
    guard FileManager.default.createFile(atPath: probe.path, contents: nil) else { return false }
    defer { try? FileManager.default.removeItem(at: probe) }
    return access(dir.appendingPathComponent("CASE-PROBE").path, F_OK) == 0
}

@Test(arguments: [false, true], [false, true])
func caseOnlyRenameKeepsSavingAndReloading(renameFolder: Bool, viaReload: Bool) throws {
    let base = try makeDir()
    defer { removeDir(base) }
    guard isCaseInsensitive(base) else { return }   // e.g. Linux: a case rename is a different file
    let folder = base.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let original = folder.appendingPathComponent("notes.md")
    try write("v1\n", original)
    let loaded = try TextFileIO.load(original)

    // Renamed in Finder (or Selway) while open: only the case changes.
    let renamed: URL
    if renameFolder {
        let to = base.appendingPathComponent("project", isDirectory: true)
        #expect(rename(folder.path, to.path) == 0)
        renamed = to.appendingPathComponent("notes.md")
    } else {
        renamed = folder.appendingPathComponent("Notes.md")
        #expect(rename(original.path, renamed.path) == 0)
    }

    let newURL: URL
    if viaReload {
        let again = try TextFileIO.reload(loaded.resolvedURL, openedAs: loaded.url, expectedFolder: loaded.snapshot.folder)
        #expect(again.text == "v1\n")
        newURL = again.resolvedURL
    } else {
        let saved = try TextFileIO.saveDocument("v2\n", format: loaded.format, to: loaded.resolvedURL,
                                                expected: loaded.snapshot)
        newURL = saved.resolvedURL
        // Saving again at the adopted path works and keeps the new spelling.
        try TextFileIO.save("v3\n", format: loaded.format, to: saved.resolvedURL, expected: saved.snapshot)
        #expect(try read(renamed) == "v3\n")
    }
    #expect(newURL.path == renamed.path, "the new spelling is adopted")
    let listing = try FileManager.default.contentsOfDirectory(atPath: renamed.deletingLastPathComponent().path)
    #expect(listing == [renamed.lastPathComponent], "the save didn't undo the rename")
}

/// A folder swapped for a link whose name differs only in case is still a swap.
@Test func caseOnlyDifferentLinkIsStillRefused() throws {
    let scene = try Scene()
    defer { removeDir(scene.base) }
    guard isCaseInsensitive(scene.base) else { return }
    let loaded = try TextFileIO.load(scene.file)
    try FileManager.default.moveItem(at: scene.shared, to: scene.moved)
    try FileManager.default.createSymbolicLink(at: scene.base.appendingPathComponent("Shared"),
                                               withDestinationURL: scene.outside)
    for force in [false, true] {
        #expect(throws: TextFileIOError.self) {
            try TextFileIO.save("edited\n", format: loaded.format, to: loaded.resolvedURL,
                                expected: loaded.snapshot, force: force)
        }
        #expect(throws: TextFileIOError.self) { try TextFileIO.reload(loaded.resolvedURL, openedAs: loaded.url, expectedFolder: loaded.snapshot.folder) }
    }
    #expect(try read(scene.outsideFile) == "sentinel\n")
}

// MARK: - A failed write never loses the file

@Test(arguments: [false, true], [0, 65_536])
func failedWriteKeepsTheOriginalBytes(inPlace: Bool, failAfter: Int) throws {
    let base = try makeDir()
    defer { removeDir(base) }
    let url = base.appendingPathComponent("big.txt")
    let original = String(repeating: "original line\n", count: 1_000)
    try write(original, url)
    if inPlace { try FileManager.default.linkItem(at: url, to: base.appendingPathComponent("link.txt")) }
    let before = inode(url)
    let loaded = try TextFileIO.load(url)

    var hooks = TextFileIOHooks()
    hooks.failWrite = { written in written >= failAfter ? ENOSPC : nil }
    let longer = String(repeating: "new text that is longer than the original\n", count: 5_000)
    #expect(throws: TextFileIOError.self) {
        try TextFileIO.saveDocument(longer, format: loaded.format, to: loaded.resolvedURL,
                                    expected: loaded.snapshot, hooks: hooks)
    }
    #expect(try read(url) == original, "the file lost its content")
    #expect(inode(url) == before)
    let expected = inPlace ? ["big.txt", "link.txt"] : ["big.txt"]
    #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).sorted() == expected,
            "no temporary copy is left behind")
    // Saving again (over the restored file, so forced) goes through.
    try TextFileIO.save("ok\n", format: loaded.format, to: loaded.resolvedURL, expected: loaded.snapshot, force: true)
    #expect(try read(url) == "ok\n")
}
