import Foundation
import Testing
@testable import SelwayCore

/// A temp folder per test, plus a fake Trash inside it so nothing touches the real one.
private struct Sandbox {
    let root: URL
    let trash: URL
    let fm = FileManager.default

    init() throws {
        root  = FileManager.default.temporaryDirectory.appendingPathComponent("selway-\(UUID())")
        trash = root.appendingPathComponent(".FakeTrash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    func remove() { try? fm.removeItem(at: root) }

    @discardableResult
    func file(_ path: String, _ text: String = "data") throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    func names(_ dir: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    /// Moves into the fake Trash (unique names), like the system Trash would.
    var trasher: FileOpsTransfer.Trasher {
        let trash = self.trash
        return { url in
            let dest = FileOpsNaming.uniqueURL(in: trash, name: url.lastPathComponent,
                                               isDirectory: FileOpsNaming.isDirectory(url))
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
    }
}

@Test func fileOpsCopyIntoOtherFolderUsesFreeNames() throws {
    let s = try Sandbox(); defer { s.remove() }
    let a = try s.file("src/a.txt", "new")
    let dest = try s.folder("dest")
    try s.file("dest/a.txt", "old")

    let r = FileOpsTransfer.transfer([a], into: dest, mode: .copy)
    #expect(r.failures.isEmpty)
    #expect(r.done.map(\.result.lastPathComponent) == ["a 2.txt"])
    #expect(s.text(dest.appendingPathComponent("a.txt")) == "old")
    #expect(s.text(dest.appendingPathComponent("a 2.txt")) == "new")
    #expect(s.text(a) == "new")
}

@Test func fileOpsCopyIntoSameFolderDuplicates() throws {
    let s = try Sandbox(); defer { s.remove() }
    let a = try s.file("src/a.txt")
    let r = FileOpsTransfer.transfer([a], into: a.deletingLastPathComponent(), mode: .copy)
    #expect(r.done.map(\.result.lastPathComponent) == ["a copy.txt"])
}

@Test func fileOpsMoveKeepsGoingAfterFailuresAndCollectsThem() throws {
    let s = try Sandbox(); defer { s.remove() }
    let a = try s.file("src/a.txt")
    let missing = s.root.appendingPathComponent("src/missing.txt")
    let folder = try s.folder("src/folder")
    let b = try s.file("src/b.txt")

    let r = FileOpsTransfer.transfer([a, missing, folder, b], into: folder, mode: .move)
    #expect(r.done.map(\.result.lastPathComponent) == ["a.txt", "b.txt"])
    #expect(r.failures.map(\.name) == ["missing.txt", "folder"])
    #expect(s.names(folder) == ["a.txt", "b.txt"])
    #expect(!r.cancelled)
}

@Test func fileOpsRefusesPastingFolderIntoItsOwnSubfolder() throws {
    let s = try Sandbox(); defer { s.remove() }
    let parent = try s.folder("p")
    let child  = try s.folder("p/child")
    for mode in [FileOpsTransfer.Mode.copy, .move] {
        let r = FileOpsTransfer.transfer([parent], into: child, mode: mode)
        #expect(r.done.isEmpty)
        #expect(r.failures.count == 1)
    }
    #expect(s.names(child).isEmpty)
}

@Test func fileOpsMoveWithinSameFolderIsNoOp() throws {
    let s = try Sandbox(); defer { s.remove() }
    let a = try s.file("src/a.txt")
    let r = FileOpsTransfer.transfer([a], into: a.deletingLastPathComponent(), mode: .move)
    #expect(r.done.isEmpty && r.failures.isEmpty)
    #expect(s.names(a.deletingLastPathComponent()) == ["a.txt"])
}

@Test func fileOpsCancelledBeforeStartDoesNothing() throws {
    let s = try Sandbox(); defer { s.remove() }
    let a = try s.file("src/a.txt")
    let dest = try s.folder("dest")
    let token = FileOpsCancellationToken()
    token.cancel()
    var reported: [FileOpsProgress] = []
    let r = FileOpsTransfer.transfer([a], into: dest, mode: .copy, token: token) { reported.append($0) }
    #expect(r.cancelled)
    #expect(r.done.isEmpty)
    #expect(s.names(dest).isEmpty)
    #expect(reported.last?.completed == reported.last?.total)
}

@Test func fileOpsProgressCountsEveryItem() throws {
    let s = try Sandbox(); defer { s.remove() }
    let urls = try (1...3).map { try s.file("src/\($0).txt") }
    var reported: [FileOpsProgress] = []
    _ = FileOpsTransfer.duplicate(urls) { reported.append($0) }
    #expect(reported.map(\.completed) == [0, 1, 2, 3])
    #expect(reported.allSatisfy { $0.total == 3 })
}

@Test func fileOpsUndoCopyTrashesInsteadOfDeleting() throws {
    let s = try Sandbox(); defer { s.remove() }
    let a = try s.file("src/a.txt", "content")
    let dup = FileOpsTransfer.duplicate([a])
    let copy = try #require(dup.done.first?.result)

    #expect(dup.created.map(\.url) == [copy])
    let undo = FileOpsTransfer.trashCopies(dup.created, trasher: s.trasher)
    #expect(undo.failures.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: copy.path))
    #expect(s.text(s.trash.appendingPathComponent("a copy.txt")) == "content")
    #expect(s.text(a) == "content")
}

@Test func fileOpsUndoMoveReportsClashInsteadOfOverwriting() throws {
    let s = try Sandbox(); defer { s.remove() }
    let a = try s.file("src/a.txt", "moved")
    let b = try s.file("src/b.txt", "moved too")
    let dest = try s.folder("dest")
    let moved = FileOpsTransfer.transfer([a, b], into: dest, mode: .move)
    #expect(moved.done.count == 2)

    try s.file("src/a.txt", "newcomer")   // something new took a.txt's old place
    let undo = FileOpsTransfer.moveBack(moved.done)
    #expect(undo.failures.map(\.name) == ["a.txt"])
    #expect(s.text(a) == "newcomer")
    #expect(s.text(dest.appendingPathComponent("a.txt")) == "moved")
    #expect(s.text(b) == "moved too")
}

/// Undo of a Paste or Duplicate trashes the copy it made, not whatever has
/// taken the copy's name since (checked by volume + inode).
@Test func fileOpsUndoCopyLeavesReplacementAlone() throws {
    let s = try Sandbox(); defer { s.remove() }
    let a = try s.file("src/a.txt", "original")
    let dest = try s.folder("dest")
    let pasted = FileOpsTransfer.transfer([a], into: dest, mode: .copy)
    let copy = try #require(pasted.created.first?.url)
    #expect(copy.lastPathComponent == "a.txt")

    // The user moves the copy away and saves something else under its name.
    try FileManager.default.moveItem(at: copy, to: s.root.appendingPathComponent("kept.txt"))
    try s.file("dest/a.txt", "new work")

    let undo = FileOpsTransfer.trashCopies(pasted.created, trasher: s.trasher)
    #expect(undo.done.isEmpty)
    #expect(undo.failures.map(\.name) == ["a.txt"])
    #expect(undo.failures.first?.message.contains("changed since it was copied") == true)
    #expect(s.text(copy) == "new work")
    #expect(s.names(s.trash).isEmpty)
}

/// FileManager that hides one path from lstat-style checks and whose
/// moveItem is a plain rename(2), which replaces an existing destination.
/// A check-then-move undo would therefore overwrite; only the exclusive
/// rename (renamex_np RENAME_EXCL) refuses.
private final class BlindFileManager: FileManager {
    var hidden: String = ""
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if path == hidden { throw CocoaError(.fileReadNoSuchFile) }
        return try super.attributesOfItem(atPath: path)
    }
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        guard rename(srcURL.path, dstURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

#if canImport(Darwin)
@Test func fileOpsUndoMoveUsesExclusiveRename() throws {
    let s = try Sandbox(); defer { s.remove() }
    let a = try s.file("src/a.txt", "moved")
    let dest = try s.folder("dest")
    let moved = FileOpsTransfer.transfer([a], into: dest, mode: .move)
    try s.file("src/a.txt", "newcomer")

    let fm = BlindFileManager()
    fm.hidden = a.path
    let undo = FileOpsTransfer.moveBack(moved.done, fileManager: fm)
    #expect(undo.failures.map(\.name) == ["a.txt"])
    #expect(s.text(a) == "newcomer")
    #expect(s.text(dest.appendingPathComponent("a.txt")) == "moved")
}
#endif

/// copyItem that writes part of the copy, then fails like a nested clash
/// ("a" and "A" from a case-sensitive volume) or a clash at `dest` itself.
private final class ClashingCopyFileManager: FileManager {
    var clashAtTop = false
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if clashAtTop {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: srcURL.path,
                                                              "NSDestinationFilePath": dstURL.path])
        }
        try createDirectory(at: dstURL, withIntermediateDirectories: false)
        try Data("1".utf8).write(to: dstURL.appendingPathComponent("a"))
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: srcURL.appendingPathComponent("A").path,
                                                          "NSDestinationFilePath": dstURL.appendingPathComponent("A").path])
    }
}

@Test func fileOpsPartialCopyRemovedAfterNestedClash() throws {
    let s = try Sandbox(); defer { s.remove() }
    let src = try s.folder("src/d")
    let dest = s.root.appendingPathComponent("dest-d")
    let fm = ClashingCopyFileManager()
    #expect(throws: CocoaError.self) { try FileOpsTransfer.copyRemovingPartial(src, to: dest, fileManager: fm) }
    #expect(!FileManager.default.fileExists(atPath: dest.path))
}

@Test func fileOpsCopyClashAtDestinationLeavesItAlone() throws {
    let s = try Sandbox(); defer { s.remove() }
    let src = try s.file("src/a.txt", "new")
    let theirs = try s.file("dest/a.txt", "theirs")
    // Real FileManager: whatever it reports for an existing destination must
    // be recognised as "dest itself" so the other item isn't deleted.
    #expect(throws: (any Error).self) {
        try FileOpsTransfer.copyRemovingPartial(src, to: theirs, fileManager: FileManager.default)
    }
    #expect(s.text(theirs) == "theirs")
    let fm = ClashingCopyFileManager()
    fm.clashAtTop = true
    #expect(throws: CocoaError.self) { try FileOpsTransfer.copyRemovingPartial(src, to: theirs, fileManager: fm) }
    #expect(s.text(theirs) == "theirs")
}

/// FileManager whose removeItem fails for one path (an original that can't
/// be deleted after a cross-volume copy).
private final class UndeletableFileManager: FileManager {
    var protected: String = ""
    override func removeItem(at url: URL) throws {
        if url.path == protected { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}

@Test func fileOpsCrossVolumeMoveReportsItemInBothPlaces() throws {
    let s = try Sandbox(); defer { s.remove() }
    let a = try s.file("src/a.txt", "data")
    let dest = try s.folder("Backup")
    let fm = UndeletableFileManager()
    fm.protected = a.path
    do {
        try FileOpsTransfer.moveAcrossVolumes(a, to: dest.appendingPathComponent("a.txt"), fileManager: fm)
        Issue.record("expected movedButOriginalRemains")
    } catch let error as FileOpsError {
        guard case let .movedButOriginalRemains(name, folder, _) = error else {
            Issue.record("unexpected \(error)"); return
        }
        #expect(name == "a.txt" && folder == "Backup")
        #expect(error.localizedDescription.contains("exists in both places"))
    }
    #expect(s.text(a) == "data")
    #expect(s.text(dest.appendingPathComponent("a.txt")) == "data")
}

@Test func fileOpsCrossVolumeMoveRemovesOriginal() throws {
    let s = try Sandbox(); defer { s.remove() }
    let a = try s.file("src/a.txt", "data")
    let dest = try s.folder("dest")
    try FileOpsTransfer.moveAcrossVolumes(a, to: dest.appendingPathComponent("a.txt"), fileManager: .default)
    #expect(!FileManager.default.fileExists(atPath: a.path))
    #expect(s.text(dest.appendingPathComponent("a.txt")) == "data")
}

@Test func fileOpsTrashAndDeleteCollectEveryError() throws {
    let s = try Sandbox(); defer { s.remove() }
    let a = try s.file("a.txt"), b = try s.file("b.txt")
    let ghost1 = s.root.appendingPathComponent("ghost1"), ghost2 = s.root.appendingPathComponent("ghost2")

    let trashed = FileOpsTransfer.trash([ghost1, a, ghost2], trasher: s.trasher)
    #expect(trashed.done.map(\.source) == [a])
    #expect(trashed.failures.map(\.name) == ["ghost1", "ghost2"])

    let deleted = FileOpsTransfer.delete([ghost1, b, ghost2])
    #expect(deleted.done.map(\.source) == [b])
    #expect(deleted.failures.count == 2)

    let message = FileOpsErrorSummary.message(action: .delete, failures: deleted.failures, total: 3)
    #expect(message?.contains("2 of 3") == true)
    #expect(message?.contains("ghost1") == true && message?.contains("ghost2") == true)
}

@Test func fileOpsErrorSummaryFormats() {
    #expect(FileOpsErrorSummary.message(action: .copy, failures: [], total: 3) == nil)
    let one = FileOpsErrorSummary.message(action: .copy, failures: [.init(name: "a", message: "nope")], total: 1)
    #expect(one == "Couldn’t copy “a”: nope")
    let many = (1...7).map { FileOpsFailure(name: "f\($0)", message: "bad") }
    let text = FileOpsErrorSummary.message(action: .copy, failures: many, total: 10) ?? ""
    #expect(text.hasPrefix("Couldn’t copy 7 of 10 items:"))
    #expect(text.contains("• and 2 more"))
    #expect(!text.contains("f6"))
}

// MARK: - Clipboard

private final class FakePasteboard: FileOpsPasteboard {
    var changeCount = 0
    var urls: [URL] = []
    func readFileURLs() -> [URL] { urls }
    func writeFileURLs(_ urls: [URL]) -> Int { changeCount += 1; self.urls = urls; return changeCount }
    func clearContents() { changeCount += 1; urls = [] }
    func writeString(_ string: String) { changeCount += 1; urls = [] }
    /// Another app copying something.
    func externalCopy(_ urls: [URL]) { changeCount += 1; self.urls = urls }
}

@Test func fileOpsCutThenPasteMoves() {
    let pb = FakePasteboard(), clip = FileOpsClipboard(pasteboard: pb)
    let a = URL(fileURLWithPath: "/tmp/a")
    clip.cut([a])
    #expect(clip.pendingPaste()?.isMove == true)
    let token = clip.beginMove()
    #expect(token == FileOpsCutMark(changeCount: pb.changeCount, urls: [a]))
    // A second Paste while the move runs must not move again.
    #expect(clip.pendingPaste()?.isMove == false)
    clip.finishMove(token)
    #expect(clip.pendingPaste() == nil)
}

@Test func fileOpsCopyPathAfterCutCancelsTheMove() {
    let pb = FakePasteboard(), clip = FileOpsClipboard(pasteboard: pb)
    clip.cut([URL(fileURLWithPath: "/tmp/a")])
    pb.writeString("/tmp/a")
    #expect(!clip.isCutPending)
    #expect(clip.pendingPaste() == nil)
}

@Test func fileOpsCutThenExternalCopyPastesAsCopy() {
    let pb = FakePasteboard(), clip = FileOpsClipboard(pasteboard: pb)
    clip.cut([URL(fileURLWithPath: "/tmp/a")])
    let other = URL(fileURLWithPath: "/tmp/other")
    pb.externalCopy([other])
    let pending = clip.pendingPaste()
    #expect(pending?.urls == [other])
    #expect(pending?.isMove == false)
    // Nothing to finish, and the other app's clipboard is left alone.
    let token = clip.beginMove()
    #expect(token == nil)
    clip.finishMove(token)
    #expect(pb.urls == [other])
}

@Test func fileOpsCopyAfterCutCancelsTheMove() {
    let pb = FakePasteboard(), clip = FileOpsClipboard(pasteboard: pb)
    clip.cut([URL(fileURLWithPath: "/tmp/a")])
    clip.copy([URL(fileURLWithPath: "/tmp/b")])
    #expect(clip.pendingPaste()?.isMove == false)
    #expect(clip.cutURLs.isEmpty)
}

// MARK: - Paste sequencing (what FileOperationsService.paste does)

/// Collects FileOpsClipboard.didChange for one clipboard.
private final class ChangeCounter {
    private(set) var count = 0
    private var token: NSObjectProtocol?
    init(_ clipboard: FileOpsClipboard) {
        token = NotificationCenter.default.addObserver(forName: FileOpsClipboard.didChange, object: clipboard,
                                                       queue: nil) { [weak self] _ in self?.count += 1 }
    }
    deinit { token.map(NotificationCenter.default.removeObserver) }
}

@Test func fileOpsPasteAfterCutMovesAndUsesUpTheCut() throws {
    let s = try Sandbox(); defer { s.remove() }
    let a = try s.file("src/a.txt", "A")
    let dest = try s.folder("dest")
    let pb = FakePasteboard(), clip = FileOpsClipboard(pasteboard: pb)
    clip.cut([a])

    let plan = try #require(FileOpsPaste.begin(clip))
    #expect(plan.isMove && plan.sources == [a])
    #expect(!clip.isCutPending)                       // a second Paste would copy
    let result = FileOpsPaste.run(plan, into: dest)
    let undo = FileOpsPaste.finish(plan, result: result, clipboard: clip)
    #expect(s.text(dest.appendingPathComponent("a.txt")) == "A")
    #expect(!FileManager.default.fileExists(atPath: a.path))
    #expect(pb.urls.isEmpty)                          // pasteboard no longer points at the old place
    #expect(undo == .move([FileOpsUndoMove(reversing: try #require(result.done.first))]))

    // The registered undo puts it back.
    let back = try #require(undo).perform(trasher: s.trasher)
    #expect(back.result.failures.isEmpty)
    #expect(s.text(a) == "A")
}

@Test func fileOpsPasteAfterCopyCopiesAndUndoTrashesTheCopy() throws {
    let s = try Sandbox(); defer { s.remove() }
    let a = try s.file("src/a.txt", "A")
    let dest = try s.folder("dest")
    let pb = FakePasteboard(), clip = FileOpsClipboard(pasteboard: pb)
    clip.copy([a])

    let plan = try #require(FileOpsPaste.begin(clip))
    #expect(!plan.isMove && plan.cutMark == nil)
    let result = FileOpsPaste.run(plan, into: dest)
    let undo = try #require(FileOpsPaste.finish(plan, result: result, clipboard: clip))
    #expect(s.text(a) == "A")
    #expect(pb.urls == [a])                           // a copy leaves the pasteboard alone
    guard case .trash(let items) = undo else { Issue.record("expected trash"); return }
    #expect(items.map(\.url) == [dest.appendingPathComponent("a.txt")])

    #expect(undo.perform(trasher: s.trasher).result.failures.isEmpty)
    #expect(s.names(dest).isEmpty)
    #expect(s.names(s.trash) == ["a.txt"])
}

/// A cut-and-paste that moved nothing (every item failed, or it was
/// cancelled before the first) keeps the Cut, so the next Paste moves.
@Test func fileOpsFailedMoveKeepsTheCut() throws {
    let s = try Sandbox(); defer { s.remove() }
    let gone = s.root.appendingPathComponent("src/gone.txt")
    let dest = try s.folder("dest")
    let pb = FakePasteboard(), clip = FileOpsClipboard(pasteboard: pb)
    clip.cut([gone])

    let plan = try #require(FileOpsPaste.begin(clip))
    let result = FileOpsPaste.run(plan, into: dest)
    #expect(result.done.isEmpty && result.failures.count == 1)
    #expect(FileOpsPaste.finish(plan, result: result, clipboard: clip) == nil)
    #expect(clip.isCutPending)
    #expect(clip.cutURLs == [gone])
    #expect(clip.pendingPaste()?.isMove == true)

    // Cancelled before the first item: same.
    let plan2 = try #require(FileOpsPaste.begin(clip))
    let token = FileOpsCancellationToken(); token.cancel()
    let cancelled = FileOpsPaste.run(plan2, into: dest, token: token)
    #expect(cancelled.cancelled)
    _ = FileOpsPaste.finish(plan2, result: cancelled, clipboard: clip)
    #expect(clip.isCutPending)
}

/// The Cut isn't given back over something newer on the pasteboard.
@Test func fileOpsFailedMoveDoesNotResurrectAStaleCut() throws {
    let pb = FakePasteboard(), clip = FileOpsClipboard(pasteboard: pb)
    clip.cut([URL(fileURLWithPath: "/tmp/gone")])
    let plan = try #require(FileOpsPaste.begin(clip))
    pb.externalCopy([URL(fileURLWithPath: "/tmp/other")])
    _ = FileOpsPaste.finish(plan, result: FileOpsBatchResult(), clipboard: clip)
    #expect(!clip.isCutPending)
    #expect(clip.pendingPaste()?.isMove == false)
}

/// Two windows (two services) on one pasteboard share one clipboard: Cut in
/// A, Paste in B moves, and afterwards A no longer has a pending Cut (so a
/// later Paste in A can't move the originals again) and was told to refresh.
@Test func fileOpsTwoWindowsShareOneClipboard() throws {
    let s = try Sandbox(); defer { s.remove() }
    let a = try s.file("src/a.txt", "A")
    let dest = try s.folder("dest")
    let pb = FakePasteboard()
    let windowA = FileOpsClipboard.shared(for: pb), windowB = FileOpsClipboard.shared(for: pb)
    #expect(windowA === windowB)
    #expect(FileOpsClipboard.shared(for: FakePasteboard()) !== windowA)
    let changesSeenByA = ChangeCounter(windowA)

    windowA.cut([a])
    #expect(windowB.isCutPending)
    let plan = try #require(FileOpsPaste.begin(windowB))
    #expect(plan.isMove)
    #expect(!windowA.isCutPending)
    let result = FileOpsPaste.run(plan, into: dest)
    _ = FileOpsPaste.finish(plan, result: result, clipboard: windowB)
    #expect(s.text(dest.appendingPathComponent("a.txt")) == "A")
    #expect(windowA.pendingPaste() == nil)
    #expect(changesSeenByA.count >= 3)                  // cut, begin, finish
}

#if !canImport(Darwin)
// swift-corelibs FileManager is Sendable (Darwin's isn't): subclasses restate it.
extension BlindFileManager: @unchecked Sendable {}
extension ClashingCopyFileManager: @unchecked Sendable {}
extension UndeletableFileManager: @unchecked Sendable {}
#endif

#if os(macOS)
/// Regression: pasting or duplicating in a folder browsed as /private/… returned paths
/// without "/private" (standardizedFileURL drops it for existing paths), so the browser's
/// lexical ShellPath keys didn't place the new item in the folder shown and it wasn't
/// selected. Results keep the caller's spelling; same-folder detection still sees through it.
@Test func fileOpsResultsKeepThePrivatePrefixTheCallerUsed() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    try #require(dir.url.path.hasPrefix("/private/"))   // temp folders live under /private/var
    let privateFolder = try dir.dir("dest")
    let varFolder = URL(fileURLWithPath: String(privateFolder.path.dropFirst("/private".count)), isDirectory: true)
    let a = try dir.file("src/a.txt")

    let pasted = FileOpsTransfer.transfer([a], into: privateFolder, mode: .copy)
    let target = try #require(pasted.done.first?.result)
    #expect(target.path.hasPrefix("/private/"))
    #expect(ShellPath.isParent(privateFolder, of: target))

    let duplicated = FileOpsTransfer.duplicate([target])
    let copy = try #require(duplicated.done.first?.result)
    #expect(copy.lastPathComponent == "a copy.txt")
    #expect(ShellPath.isParent(privateFolder, of: copy))

    // Spelled /var for the source and /private/var for the folder: still the same folder,
    // so moving is a no-op and copying makes "a copy 2", not "a 2".
    let viaVar = varFolder.appendingPathComponent("a.txt")
    let moved = FileOpsTransfer.transfer([viaVar], into: privateFolder, mode: .move)
    #expect(moved.done.isEmpty && moved.failures.isEmpty)
    let copied = FileOpsTransfer.transfer([viaVar], into: privateFolder, mode: .copy)
    #expect(copied.done.map(\.result.lastPathComponent) == ["a copy 2.txt"])
}
#endif
