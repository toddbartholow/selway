import Foundation
import Testing
@testable import SelwayCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Undo → Redo → Undo round trips of every file operation on real files, and
// the clashes on the way: something that takes a name in between is reported
// and never overwritten, and an item that was replaced is never moved.

/// A temp folder with a fake Trash, so nothing touches the real one.
private struct Bench {
    let dir: TempDir
    let trash: URL
    var root: URL { dir.url }

    init() throws {
        dir = try TempDir()
        trash = try dir.dir(".FakeTrash")
    }

    func cleanup() { dir.cleanup() }

    @discardableResult
    func file(_ rel: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    func exists(_ url: URL) -> Bool { FileOpsTransfer.exists(url, .default) }
    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// Moves into the fake Trash under a free name, as the system Trash does.
    var trasher: FileOpsTransfer.Trasher {
        let trash = self.trash
        return { url in
            let dest = FileOpsNaming.uniqueURL(in: trash, name: url.lastPathComponent,
                                               isDirectory: FileOpsNaming.isDirectory(url))
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
    }

    /// Runs `step`, expecting no failures, and returns its inverse.
    func run(_ step: FileOpsUndoStep, sourceLocation: SourceLocation = #_sourceLocation) throws -> FileOpsUndoStep {
        let outcome = step.perform(trasher: trasher)
        #expect(outcome.result.failures.isEmpty, sourceLocation: sourceLocation)
        return try #require(outcome.inverse, sourceLocation: sourceLocation)
    }
}

// MARK: - Round trips

@Test func fileOpsUndoRedoPasteCopy() throws {
    let b = try Bench(); defer { b.cleanup() }
    let a = try b.file("src/a.txt", "A")
    let dest = try b.dir.dir("dest")
    let copy = dest.appendingPathComponent("a.txt")
    let pasted = FileOpsTransfer.transfer([a], into: dest, mode: .copy)

    let undo = try #require(FileOpsUndoStep.undoingCopy(pasted.created))
    let redo = try b.run(undo)                       // undo: the copy goes to the Trash
    #expect(!b.exists(copy))
    #expect(b.names(b.trash) == ["a.txt"])
    #expect(b.text(a) == "A")
    guard case .putBack = redo else { Issue.record("redo of a copy puts it back: \(redo)"); return }

    let undoAgain = try b.run(redo)                  // redo: the same copy comes back
    #expect(b.text(copy) == "A")
    #expect(b.names(b.trash).isEmpty)
    #expect(undoAgain == .trash([FileOpsCreatedItem(recording: copy)]))
    #expect(pasted.created.first?.identity == FileOpsItemIdentity(copy))   // the very same file

    _ = try b.run(undoAgain)                         // undo again
    #expect(!b.exists(copy))
    #expect(b.text(a) == "A")
}

@Test func fileOpsUndoRedoDuplicate() throws {
    let b = try Bench(); defer { b.cleanup() }
    let a = try b.file("a.txt", "A")
    let dup = FileOpsTransfer.duplicate([a])
    let copy = b.root.appendingPathComponent("a copy.txt")
    #expect(dup.created.map(\.url) == [copy])

    let redo = try b.run(try #require(FileOpsUndoStep.undoingCopy(dup.created)))
    #expect(b.names(b.root) == [".FakeTrash", "a.txt"])
    let undoAgain = try b.run(redo)
    #expect(b.text(copy) == "A")
    _ = try b.run(undoAgain)
    #expect(b.names(b.root) == [".FakeTrash", "a.txt"])
}

@Test func fileOpsUndoRedoRename() throws {
    let b = try Bench(); defer { b.cleanup() }
    let old = try b.file("old.txt", "R")
    let new = try FileOpsCreation.rename(old, to: "new.txt")

    let undo = try #require(FileOpsUndoStep.undoingMove([FileOpsMovedItem(source: old, result: new)]))
    let redo = try b.run(undo)
    #expect(b.text(old) == "R" && !b.exists(new))
    #expect(redo == .move([FileOpsUndoMove(from: old, to: new, identity: FileOpsItemIdentity(old))]))
    let undoAgain = try b.run(redo)
    #expect(b.text(new) == "R" && !b.exists(old))
    _ = try b.run(undoAgain)
    #expect(b.text(old) == "R" && !b.exists(new))
}

@Test func fileOpsUndoRedoMove() throws {
    let b = try Bench(); defer { b.cleanup() }
    let a = try b.file("src/a.txt", "A")
    let folder = try b.dir.dir("src/folder")
    try b.file("src/folder/inner.txt", "I")
    let dest = try b.dir.dir("dest")
    let moved = FileOpsTransfer.transfer([a, folder], into: dest, mode: .move)
    #expect(moved.done.count == 2)

    let redo = try b.run(try #require(FileOpsUndoStep.undoingMove(moved.done)))
    #expect(b.names(dest).isEmpty)
    #expect(b.text(b.root.appendingPathComponent("src/folder/inner.txt")) == "I")
    let undoAgain = try b.run(redo)
    #expect(b.names(dest) == ["a.txt", "folder"])
    #expect(b.names(a.deletingLastPathComponent()).isEmpty)
    _ = try b.run(undoAgain)
    #expect(b.names(a.deletingLastPathComponent()) == ["a.txt", "folder"])
}

@Test func fileOpsUndoRedoTrash() throws {
    let b = try Bench(); defer { b.cleanup() }
    let a = try b.file("a.txt", "A")
    let trashed = FileOpsTransfer.trash([a], trasher: b.trasher)

    let undo = try #require(FileOpsUndoStep.undoingTrash(trashed.done))
    guard case .putBack = undo else { Issue.record("undo of Trash puts back: \(undo)"); return }
    let redo = try b.run(undo)                       // undo: out of the Trash
    #expect(b.text(a) == "A" && b.names(b.trash).isEmpty)
    #expect(redo == .trash([FileOpsCreatedItem(recording: a)]))
    let undoAgain = try b.run(redo)                  // redo: into the Trash again
    #expect(!b.exists(a) && b.names(b.trash) == ["a.txt"])
    _ = try b.run(undoAgain)                         // undo again
    #expect(b.text(a) == "A")
}

// MARK: - Clashes and replaced items

/// Redo of a move whose destination name was taken meanwhile: reported, the
/// newcomer kept, the item left where it is, nothing to reverse.
@Test func fileOpsRedoMoveReportsClash() throws {
    let b = try Bench(); defer { b.cleanup() }
    let a = try b.file("src/a.txt", "moved")
    let dest = try b.dir.dir("dest")
    let moved = FileOpsTransfer.transfer([a], into: dest, mode: .move)
    let redo = try b.run(try #require(FileOpsUndoStep.undoingMove(moved.done)))

    let newcomer = try b.file("dest/a.txt", "newcomer")
    let outcome = redo.perform(trasher: b.trasher)
    #expect(outcome.result.done.isEmpty)
    #expect(outcome.result.failures.map(\.name) == ["a.txt"])
    #expect(outcome.inverse == nil)
    #expect(outcome.remainder == redo && outcome.removedCount == 0)   // kept to retry
    #expect(b.text(newcomer) == "newcomer")
    #expect(b.text(a) == "moved")
}

/// Undo of a rename after the old name was taken: reported, not overwritten.
@Test func fileOpsUndoRenameReportsClash() throws {
    let b = try Bench(); defer { b.cleanup() }
    let old = try b.file("old.txt", "R")
    let new = try FileOpsCreation.rename(old, to: "new.txt")
    let undo = try #require(FileOpsUndoStep.undoingMove([FileOpsMovedItem(source: old, result: new)]))
    try b.file("old.txt", "newcomer")

    let outcome = undo.perform(trasher: b.trasher)
    #expect(outcome.result.failures.map(\.name) == ["new.txt"])
    #expect(outcome.remainder == undo)
    #expect(b.text(old) == "newcomer" && b.text(new) == "R")
}

/// Redo of a Paste after something new took the copy's name: the copy stays
/// in the Trash, the new item is untouched.
@Test func fileOpsRedoPasteReportsClash() throws {
    let b = try Bench(); defer { b.cleanup() }
    let a = try b.file("src/a.txt", "A")
    let dest = try b.dir.dir("dest")
    let pasted = FileOpsTransfer.transfer([a], into: dest, mode: .copy)
    let redo = try b.run(try #require(FileOpsUndoStep.undoingCopy(pasted.created)))

    let newcomer = try b.file("dest/a.txt", "new work")
    let outcome = redo.perform(trasher: b.trasher)
    #expect(outcome.result.done.isEmpty && outcome.result.failures.count == 1)
    #expect(outcome.remainder == redo)
    #expect(b.text(newcomer) == "new work")
    #expect(b.text(b.trash.appendingPathComponent("a.txt")) == "A")
}

/// Redo of a Paste after the Trash was emptied: reported, nothing changes
/// (the sources are not copied again), and it can never work, so it leaves
/// the history instead of blocking it.
@Test func fileOpsRedoPasteAfterTrashEmptied() throws {
    let b = try Bench(); defer { b.cleanup() }
    let a = try b.file("src/a.txt", "A")
    let dest = try b.dir.dir("dest")
    let pasted = FileOpsTransfer.transfer([a], into: dest, mode: .copy)
    var h = FileOpsUndoHistory<Void>()
    h.record(try #require(FileOpsUndoStep.undoingCopy(pasted.created)), actionName: "Paste", payload: ())
    let undo = try started(h.beginUndo())
    h.finish(undo, outcome: undo.entry.step.perform(trasher: b.trasher))
    #expect(h.redoActionName == "Paste")
    try FileManager.default.removeItem(at: b.trash.appendingPathComponent("a.txt"))

    let redo = try started(h.beginRedo())
    let outcome = redo.entry.step.perform(trasher: b.trasher)
    h.finish(redo, outcome: outcome)
    #expect(outcome.result.failures.first?.message.contains("no longer exists") == true)
    #expect(outcome.remainder == nil && outcome.removedCount == 1)
    #expect(b.names(dest).isEmpty)
    #expect(h.undoStack.isEmpty && h.redoStack.isEmpty)
    #expect(outcome.historyNote(redo: true, actionName: "Paste")
            == "“Paste” can’t be redone any more, so it was removed from the redo history.")
}

/// Another app saving the renamed file atomically gives it a new inode; it is
/// still the user's file, so Undo Rename (and Redo) still move it.
@Test func fileOpsUndoRenameAfterAtomicSave() throws {
    let b = try Bench(); defer { b.cleanup() }
    let old = try b.file("a.txt", "v1")
    let new = try FileOpsCreation.rename(old, to: "b.txt")
    let undo = try #require(FileOpsUndoStep.undoingMove([FileOpsMovedItem(source: old, result: new)]))
    let before = FileOpsItemIdentity(new)
    try Data("v2".utf8).write(to: new, options: .atomic)
    #expect(FileOpsItemIdentity(new) != before)

    let redo = try b.run(undo)
    #expect(b.text(old) == "v2" && !b.exists(new))
    _ = try b.run(redo)
    #expect(b.text(new) == "v2" && !b.exists(old))
}

/// Putting back out of the Trash checks the item is the one trashed: once the
/// Trash is emptied, a later item can take the same Trash name.
@Test func fileOpsUndoTrashLeavesReusedTrashNameAlone() throws {
    let b = try Bench(); defer { b.cleanup() }
    let a = try b.file("a.txt", "A")
    let trashed = FileOpsTransfer.trash([a], trasher: b.trasher)
    let undo = try #require(FileOpsUndoStep.undoingTrash(trashed.done))
    let inTrash = b.trash.appendingPathComponent("a.txt")
    // The item leaves the Trash (kept elsewhere, so its inode can't be reused —
    // Linux file systems hand a freed inode straight to the next file), and
    // another a.txt is trashed later under the same name.
    try FileManager.default.moveItem(at: inTrash, to: b.root.appendingPathComponent("kept.txt"))
    try Data("someone else".utf8).write(to: inTrash)

    let outcome = undo.perform(trasher: b.trasher)
    #expect(outcome.result.done.isEmpty && outcome.remainder == nil && outcome.removedCount == 1)
    #expect(outcome.result.failures.first?.message.contains("no longer the item") == true)
    #expect(!b.exists(a))
    #expect(b.text(inTrash) == "someone else")
}

/// Redo of Move to Trash after the restored item was replaced: the new item
/// is not trashed.
@Test func fileOpsRedoTrashLeavesReplacedItemAlone() throws {
    let b = try Bench(); defer { b.cleanup() }
    let a = try b.file("a.txt", "A")
    let trashed = FileOpsTransfer.trash([a], trasher: b.trasher)
    let redo = try b.run(try #require(FileOpsUndoStep.undoingTrash(trashed.done)))

    // Moved away (not deleted, so the new file can't get its inode back).
    try FileManager.default.moveItem(at: a, to: b.root.appendingPathComponent("kept.txt"))
    try b.file("a.txt", "replacement")
    let outcome = redo.perform(trasher: b.trasher)
    #expect(outcome.result.done.isEmpty)
    #expect(outcome.result.failures.first?.message.contains("no longer the item") == true)
    #expect(b.text(a) == "replacement")
    #expect(b.names(b.trash).isEmpty)
}

/// Undo of Move to Trash when the original name is taken: stays in the Trash.
@Test func fileOpsUndoTrashReportsClash() throws {
    let b = try Bench(); defer { b.cleanup() }
    let a = try b.file("a.txt", "A")
    let trashed = FileOpsTransfer.trash([a], trasher: b.trasher)
    let undo = try #require(FileOpsUndoStep.undoingTrash(trashed.done))
    try b.file("a.txt", "newcomer")

    let outcome = undo.perform(trasher: b.trasher)
    #expect(outcome.result.failures.count == 1 && outcome.inverse == nil)
    #expect(outcome.remainder == undo)
    #expect(b.text(a) == "newcomer")
    #expect(b.text(b.trash.appendingPathComponent("a.txt")) == "A")
}

/// A partly done step reverses only what it did.
@Test func fileOpsPartlyDoneUndoInvertsOnlyWhatMoved() throws {
    let b = try Bench(); defer { b.cleanup() }
    let a = try b.file("src/a.txt", "A")
    let c = try b.file("src/c.txt", "C")
    let dest = try b.dir.dir("dest")
    let moved = FileOpsTransfer.transfer([a, c], into: dest, mode: .move)
    try b.file("src/c.txt", "newcomer")

    let outcome = try #require(FileOpsUndoStep.undoingMove(moved.done)).perform(trasher: b.trasher)
    #expect(outcome.result.done.map(\.result) == [a])
    guard case .move(let moves) = try #require(outcome.inverse) else { Issue.record("expected move"); return }
    #expect(moves.map(\.from) == [a])
    #expect(moves.map(\.to) == [dest.appendingPathComponent("a.txt")])
    // c.txt clashed: it is what's left to retry.
    guard case .move(let left) = try #require(outcome.remainder) else { Issue.record("expected move"); return }
    #expect(left.map(\.to) == [c])
}

/// Undo cancelled part-way keeps the items it didn't reach.
@Test func fileOpsCancelledUndoKeepsTheRest() throws {
    let b = try Bench(); defer { b.cleanup() }
    let names = ["1.txt", "2.txt", "3.txt"]
    let sources = try names.map { try b.file("src/\($0)", $0) }
    let dest = try b.dir.dir("dest")
    let moved = FileOpsTransfer.transfer(sources, into: dest, mode: .move)
    var h = FileOpsUndoHistory<Void>()
    h.record(try #require(FileOpsUndoStep.undoingMove(moved.done)), actionName: "Move", payload: ())

    let token = FileOpsCancellationToken()
    let undo = try started(h.beginUndo())
    // Cancel once the second item has started: the third is never reached.
    let outcome = undo.entry.step.perform(trasher: b.trasher, token: token) { p in
        if p.completed == 1 { token.cancel() }
    }
    h.finish(undo, outcome: outcome)
    #expect(outcome.result.cancelled && outcome.result.done.count == 2 && outcome.result.failures.isEmpty)
    #expect(outcome.historyNote(redo: false, actionName: "Move") == nil)
    // The two moved back can be redone; the third is still to undo.
    #expect(h.undoActionName == "Move" && h.redoActionName == "Move")
    #expect(h.redoStack.count == 1)

    // Undo again finishes the last item.
    let rest = try started(h.beginUndo())
    guard case .move(let left) = rest.entry.step else { Issue.record("expected move"); return }
    #expect(left.map(\.to) == [sources[2]])
    h.finish(rest, outcome: rest.entry.step.perform(trasher: b.trasher))
    #expect(names.allSatisfy { b.exists(b.root.appendingPathComponent("src/\($0)")) })
    #expect(h.undoStack.isEmpty && h.redoStack.count == 2)
}

/// The reviewer's case: Trash a file, rename another, then something makes
/// both steps impossible (the trashed file is deleted from the Trash, and the
/// renamed file is removed). Each failing ⌘Z drops its entry instead of
/// failing forever, so the history empties instead of sticking.
@Test func fileOpsPermanentFailuresLeaveTheHistory() throws {
    let b = try Bench(); defer { b.cleanup() }
    let other = try b.file("other.txt", "O")
    let a = try b.file("a.txt", "A")
    var h = FileOpsUndoHistory<Void>()
    let trashed = FileOpsTransfer.trash([other], trasher: b.trasher)
    h.record(try #require(FileOpsUndoStep.undoingTrash(trashed.done)), actionName: "Move to Trash", payload: ())
    let renamed = try FileOpsCreation.rename(a, to: "b.txt")
    h.record(try #require(FileOpsUndoStep.undoingMove([FileOpsMovedItem(source: a, result: renamed)])),
             actionName: "Rename", payload: ())

    // An atomic save to b.txt no longer blocks Undo Rename.
    try Data("A2".utf8).write(to: renamed, options: .atomic)
    let undoRename = try started(h.beginUndo())
    h.finish(undoRename, outcome: undoRename.entry.step.perform(trasher: b.trasher))
    #expect(b.text(a) == "A2")
    #expect(h.undoActionName == "Move to Trash")

    // The trashed file was deleted from the Trash: Undo can never put it back.
    try FileManager.default.removeItem(at: b.trash.appendingPathComponent("other.txt"))
    let undoTrash = try started(h.beginUndo())
    let outcome = undoTrash.entry.step.perform(trasher: b.trasher)
    h.finish(undoTrash, outcome: outcome)
    #expect(outcome.remainder == nil && outcome.removedCount == 1)
    #expect(h.undoStack.isEmpty)
    #expect(h.redoActionName == "Rename")             // the redo of the rename is untouched
    #expect(outcome.historyNote(redo: false, actionName: "Move to Trash")
            == "“Move to Trash” can’t be undone any more, so it was removed from the undo history.")
}

/// A mix: the permanent failure is dropped, the clash kept.
@Test func fileOpsMixedFailuresKeepOnlyTheClash() throws {
    let b = try Bench(); defer { b.cleanup() }
    let x = try b.file("src/x.txt", "X")
    let y = try b.file("src/y.txt", "Y")
    let dest = try b.dir.dir("dest")
    let moved = FileOpsTransfer.transfer([x, y], into: dest, mode: .move)
    try FileManager.default.removeItem(at: dest.appendingPathComponent("x.txt"))   // gone for good
    try b.file("src/y.txt", "in the way")                                          // clash

    let outcome = try #require(FileOpsUndoStep.undoingMove(moved.done)).perform(trasher: b.trasher)
    #expect(outcome.result.failures.count == 2 && outcome.removedCount == 1)
    guard case .move(let left) = try #require(outcome.remainder) else { Issue.record("expected move"); return }
    #expect(left.map(\.to) == [y])
    #expect(outcome.historyNote(redo: false, actionName: "Move")
            == "The item that can’t be restored was removed from the undo history. "
             + "Move what’s in the way, then choose Undo Move again to finish.")
}

// MARK: - Which failures may work later

/// copyItem that writes part of the copy, then hits a clash inside it, as a
/// move between volumes does for "a" and "A" onto a case-insensitive volume.
private final class NestedClashFileManager: FileManager {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try createDirectory(at: dstURL, withIntermediateDirectories: false)
        throw CocoaError(.fileWriteFileExists,
                         userInfo: [NSFilePathErrorKey: srcURL.appendingPathComponent("A").path,
                                    "NSDestinationFilePath": dstURL.appendingPathComponent("A").path])
    }
}

#if !canImport(Darwin)
// swift-corelibs FileManager is Sendable (Darwin's isn't): subclasses restate it.
extension NestedClashFileManager: @unchecked Sendable {}
#endif

private func thrownError(_ body: () throws -> Void) -> Error? {
    do { try body(); return nil } catch { return error }
}

/// A clash inside a copy between volumes isn't something in the way at the
/// destination: trying again can't help, so the item isn't kept to retry (it
/// would block everything older forever) and the note doesn't say to move
/// something out of the way.
@Test func fileOpsUndoClashInsideACopyIsNotRetried() throws {
    let b = try Bench(); defer { b.cleanup() }
    let from = try b.dir.dir("dest/d")
    let to = b.root.appendingPathComponent("src/d")
    try b.dir.dir("src")
    let fm = NestedClashFileManager()
    let nested = try #require(thrownError { try FileOpsTransfer.moveAcrossVolumes(from, to: to, fileManager: fm) })
    #expect(!b.exists(to), "the partial copy is removed")
    #expect(FileOpsUndoFailure(nested, item: from, destination: to, fileManager: fm) == .permanent)

    // Something at the destination itself is a clash, kept to retry.
    let atDestination = CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: from.path,
                                                                    "NSDestinationFilePath": to.path])
    #expect(FileOpsUndoFailure(atDestination, item: from, destination: to) == .clash)
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST), userInfo: [NSFilePathErrorKey: from.path])
    #expect(FileOpsUndoFailure(posix, item: from, destination: to) == .clash)
    // Nothing says where (a trasher's error): assume it's in the way.
    #expect(FileOpsUndoFailure(CocoaError(.fileWriteFileExists), item: from, destination: nil) == .clash)
}

/// A volume that isn't connected or a locked folder may be fixed by the user,
/// so the item stays to retry; an item that is gone (its folder still there)
/// or replaced never comes back, so it is dropped.
@Test func fileOpsUndoTransientFailuresAreKept() throws {
    let b = try Bench(); defer { b.cleanup() }
    let volumes = try b.dir.dir("Volumes")
    let mounted = try b.dir.dir("Volumes/Disk")
    let here = try b.file("Volumes/Disk/here.txt", "H")
    func kind(_ error: Error, item: URL, destination: URL? = nil) -> FileOpsUndoFailure {
        FileOpsUndoFailure(error, item: item, destination: destination, mountFolders: [volumes.path])
    }
    let ejected = volumes.appendingPathComponent("USB")
    let onEjected = ejected.appendingPathComponent("Docs/a.txt")
    let enoent = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))

    // The item's volume is gone (Redo of a move back onto it, Undo of a trash).
    #expect(kind(FileOpsError.notFound("a.txt"), item: onEjected, destination: here) == .volumeMissing)
    // The destination's volume is gone (Undo of a move off it).
    #expect(kind(enoent, item: here, destination: onEjected) == .volumeMissing)
    #expect(kind(FileOpsError.notFound("a.txt"), item: onEjected) == .volumeMissing)
    // The item is gone from a folder that is still there: never comes back.
    #expect(kind(FileOpsError.notFound("x.txt"), item: mounted.appendingPathComponent("x.txt"), destination: here)
            == .permanent)
    // Its folder was deleted from a volume that is still there: likewise.
    #expect(kind(FileOpsError.notFound("x.txt"), item: mounted.appendingPathComponent("Gone/x.txt"))
            == .permanent)
    // Replaced stays dropped, even with the volume gone.
    #expect(kind(FileOpsError.replacedSince("a.txt"), item: onEjected) == .permanent)

    // Locked: no permission to move it out of or into a folder.
    #expect(kind(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), item: here, destination: here) == .locked)
    #expect(kind(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)), item: here, destination: here) == .locked)
    #expect(kind(CocoaError(.fileWriteNoPermission), item: here) == .locked)
    #expect(kind(CocoaError(.fileReadNoPermission), item: here) == .locked)
    // Anything else can't be expected to change.
    #expect(kind(CocoaError(.fileWriteUnknown), item: here, destination: here) == .permanent)

    #expect(FileOpsUndoFailure.clash.mayWorkLater && FileOpsUndoFailure.volumeMissing.mayWorkLater
            && FileOpsUndoFailure.locked.mayWorkLater && !FileOpsUndoFailure.permanent.mayWorkLater)
}

/// Undo of a move whose original folder is locked: the item stays in the undo
/// history and the note says to unlock it, not to move something away.
@Test func fileOpsUndoIntoALockedFolderIsKept() throws {
    guard geteuid() != 0 else { return }   // root ignores folder permissions
    let b = try Bench(); defer { b.cleanup() }
    let a = try b.file("src/a.txt", "A")
    let src = a.deletingLastPathComponent()
    let dest = try b.dir.dir("dest")
    let moved = FileOpsTransfer.transfer([a], into: dest, mode: .move)
    let undo = try #require(FileOpsUndoStep.undoingMove(moved.done))
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: src.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.path) }

    let outcome = undo.perform(trasher: b.trasher)
    #expect(outcome.result.failures.count == 1 && outcome.removedCount == 0)
    #expect(outcome.remainder == undo)
    #expect(outcome.historyNote(redo: false, actionName: "Move")
            == "Unlock the locked item or folder, then choose Undo Move again to finish.")
}

@Test func fileOpsUndoHistoryNoteSaysWhatToFix() {
    let item = FileOpsMovedItem(source: URL(fileURLWithPath: "/x"), result: URL(fileURLWithPath: "/y"))
    func note(_ reasons: Set<FileOpsUndoFailure>, removed: Int = 0) -> String? {
        let failures = Array(repeating: FileOpsFailure(name: "a", message: "m"), count: reasons.count + removed)
        return FileOpsUndoOutcome(result: FileOpsBatchResult(done: [item], failures: failures), inverse: nil,
                                  remainder: reasons.isEmpty ? nil : .move([]), removedCount: removed,
                                  retryReasons: reasons)
            .historyNote(redo: true, actionName: "Move")
    }
    #expect(note([.clash]) == "Move what’s in the way, then choose Redo Move again to finish.")
    #expect(note([.volumeMissing])
            == "Reconnect the missing disk or server, then choose Redo Move again to finish.")
    #expect(note([.locked])
            == "Unlock the locked item or folder, then choose Redo Move again to finish.")
    #expect(note([.clash, .volumeMissing])
            == "Move what’s in the way and reconnect the missing disk or server, then choose Redo Move again to finish.")
    #expect(note([.locked, .clash])
            == "Move what’s in the way and unlock the locked item or folder, then choose Redo Move again to finish.")
    #expect(note([.volumeMissing, .locked])
            == "Reconnect the missing disk or server and unlock the locked item or folder, then choose Redo Move again to finish.")
    #expect(note([.locked, .volumeMissing, .clash], removed: 1)
            == "The item that can’t be restored was removed from the redo history. "
             + "Move what’s in the way, reconnect the missing disk or server and unlock the locked item or folder, "
             + "then choose Redo Move again to finish.")
    #expect(note([], removed: 1) == "The item that can’t be restored was removed from the redo history.")
}

// MARK: - Undo / Redo stacks

private func outcome(done: Int, inverse: FileOpsUndoStep?, remainder: FileOpsUndoStep? = nil,
                     removed: Int = 0) -> FileOpsUndoOutcome {
    let item = FileOpsMovedItem(source: URL(fileURLWithPath: "/x"), result: URL(fileURLWithPath: "/y"))
    return FileOpsUndoOutcome(result: FileOpsBatchResult(done: Array(repeating: item, count: done)),
                              inverse: inverse, remainder: remainder, removedCount: removed)
}

/// `#require` can't take a mutating call.
private func started<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}

private func step(_ name: String) -> FileOpsUndoStep {
    .trash([FileOpsCreatedItem(url: URL(fileURLWithPath: "/\(name)"), identity: nil)])
}

@Test func fileOpsUndoHistoryUndoThenRedo() throws {
    var h = FileOpsUndoHistory<Int>()
    #expect(!h.canUndo && !h.canRedo && h.undoActionName == nil)
    h.record(step("paste"), actionName: "Paste", payload: 1)
    #expect(h.canUndo && !h.canRedo && h.undoActionName == "Paste")

    let undo = try started(h.beginUndo())
    #expect(undo.entry.step == step("paste") && undo.entry.payload == 1)
    #expect(!h.canUndo && !h.canRedo)                 // nothing else starts meanwhile
    #expect(h.beginUndo() == nil && h.beginRedo() == nil)
    h.finish(undo, outcome: outcome(done: 1, inverse: step("putback")))
    #expect(!h.canUndo && h.canRedo && h.redoActionName == "Paste")

    let redo = try started(h.beginRedo())
    #expect(redo.entry.step == step("putback") && redo.entry.payload == 1)
    h.finish(redo, outcome: outcome(done: 1, inverse: step("again")))
    #expect(h.canUndo && !h.canRedo && h.undoActionName == "Paste")
    #expect(h.undoStack.last?.step == step("again"))
}

@Test func fileOpsUndoHistoryNewOperationClearsRedo() throws {
    var h = FileOpsUndoHistory<Int>()
    h.record(step("a"), actionName: "Paste", payload: 0)
    let undo = try started(h.beginUndo())
    h.finish(undo, outcome: outcome(done: 1, inverse: step("b")))
    #expect(h.canRedo)
    h.record(step("c"), actionName: "Rename", payload: 0)
    #expect(!h.canRedo && h.undoActionName == "Rename")
}

/// An operation recorded while an undo runs wins: the undo's inverse doesn't
/// come back as a Redo of something older.
@Test func fileOpsUndoHistoryOperationDuringUndoDropsItsRedo() throws {
    var h = FileOpsUndoHistory<Int>()
    h.record(step("a"), actionName: "Paste", payload: 0)
    let undo = try started(h.beginUndo())
    h.record(step("b"), actionName: "Rename", payload: 0)
    h.finish(undo, outcome: outcome(done: 1, inverse: step("a-inverse")))
    #expect(!h.canRedo)
    #expect(h.undoStack.map(\.actionName) == ["Rename"])
}

/// A step that clashed (or was cancelled) keeps what's left, so the user can
/// clear the clash and try again — below anything newer.
@Test func fileOpsUndoHistoryClashedStepGoesBack() throws {
    var h = FileOpsUndoHistory<Int>()
    h.record(step("a"), actionName: "Move", payload: 0)
    let undo = try started(h.beginUndo())
    h.finish(undo, outcome: outcome(done: 0, inverse: nil, remainder: step("a")))
    #expect(h.undoActionName == "Move" && !h.canRedo)

    let again = try started(h.beginUndo())
    h.record(step("b"), actionName: "Paste", payload: 0)
    h.finish(again, outcome: outcome(done: 0, inverse: nil, remainder: step("a")))
    #expect(h.undoStack.map(\.actionName) == ["Move", "Paste"])

    // Same for a redo that clashed.
    var r = FileOpsUndoHistory<Int>()
    r.record(step("a"), actionName: "Rename", payload: 0)
    r.finish(try started(r.beginUndo()), outcome: outcome(done: 1, inverse: step("a2")))
    r.finish(try started(r.beginRedo()), outcome: outcome(done: 0, inverse: nil, remainder: step("a2")))
    #expect(r.redoActionName == "Rename" && !r.canUndo)
}

/// A step that can never succeed leaves the history, so the older entries
/// below it can still be undone.
@Test func fileOpsUndoHistoryDeadStepIsDropped() throws {
    var h = FileOpsUndoHistory<Int>()
    h.record(step("old"), actionName: "Paste", payload: 0)
    h.record(step("dead"), actionName: "Rename", payload: 0)
    h.finish(try started(h.beginUndo()), outcome: outcome(done: 0, inverse: nil, removed: 1))
    #expect(h.undoActionName == "Paste" && !h.canRedo)

    var r = FileOpsUndoHistory<Int>()
    r.record(step("a"), actionName: "Paste", payload: 0)
    r.finish(try started(r.beginUndo()), outcome: outcome(done: 1, inverse: step("a2")))
    r.finish(try started(r.beginRedo()), outcome: outcome(done: 0, inverse: nil, removed: 1))
    #expect(!r.canUndo && !r.canRedo)
}

/// Partly done with a remainder: the done part goes to the other stack, the
/// rest back where it came from.
@Test func fileOpsUndoHistoryPartlyDoneSplits() throws {
    var h = FileOpsUndoHistory<Int>()
    h.record(step("a"), actionName: "Move", payload: 0)
    h.finish(try started(h.beginUndo()), outcome: outcome(done: 1, inverse: step("done"), remainder: step("left")))
    #expect(h.undoStack.map(\.step) == [step("left")])
    #expect(h.redoStack.map(\.step) == [step("done")])
}

/// A redo finishing after a newer operation lands below it on the Undo stack.
@Test func fileOpsUndoHistoryRedoDuringOperationKeepsOrder() throws {
    var h = FileOpsUndoHistory<Int>()
    h.record(step("a"), actionName: "Move", payload: 0)
    h.finish(try started(h.beginUndo()), outcome: outcome(done: 1, inverse: step("a2")))
    let redo = try started(h.beginRedo())
    h.record(step("b"), actionName: "Paste", payload: 0)
    h.finish(redo, outcome: outcome(done: 1, inverse: step("a3")))
    #expect(h.undoStack.map(\.actionName) == ["Move", "Paste"])
    #expect(h.undoActionName == "Paste")
}

/// Every step undone and redone through the stacks on real files.
@Test func fileOpsUndoHistoryRoundTripOnDisk() throws {
    let b = try Bench(); defer { b.cleanup() }
    let a = try b.file("a.txt", "A")
    var h = FileOpsUndoHistory<Void>()
    let dup = FileOpsTransfer.duplicate([a])
    h.record(try #require(FileOpsUndoStep.undoingCopy(dup.created)), actionName: "Duplicate", payload: ())
    let copy = b.root.appendingPathComponent("a copy.txt")

    for _ in 0..<2 {
        let undo = try started(h.beginUndo())
        h.finish(undo, outcome: undo.entry.step.perform(trasher: b.trasher))
        #expect(!b.exists(copy) && h.redoActionName == "Duplicate")
        let redo = try started(h.beginRedo())
        h.finish(redo, outcome: redo.entry.step.perform(trasher: b.trasher))
        #expect(b.text(copy) == "A" && h.undoActionName == "Duplicate")
    }
}
