import Foundation
import Testing
@testable import SelwayCore

@Test func fileOpsDragOutReadsWhatTheReceiverDid() {
    // NSDragOperation: copy 1, link 2, generic 4, private 8, move 16, delete 32.
    #expect(FileOpsDragOut.ending(operation: 0) == .kept)        // no drop
    #expect(FileOpsDragOut.ending(operation: 1) == .kept)        // Mail, another volume
    #expect(FileOpsDragOut.ending(operation: 2) == .kept)        // an alias
    #expect(FileOpsDragOut.ending(operation: 16) == .moved)      // Finder, same volume
    #expect(FileOpsDragOut.ending(operation: 4) == .moved)       // ⌘ held
    #expect(FileOpsDragOut.ending(operation: 32) == .trashed)    // the Dock's Trash
    // A receiver that echoes several operations: never the Trash, and with a
    // copy or link among them the files are taken to be kept.
    #expect(FileOpsDragOut.ending(operation: 1 | 2 | 4 | 16 | 32) == .kept)
    #expect(FileOpsDragOut.ending(operation: 16 | 32) == .moved)
    #expect(FileOpsDragOut.ending(operation: .max) == .kept)
}

@Test func fileOpsDragOutFindsAFileUnderItsOwnNameWithoutListingTheTrash() throws {
    let tmp = try TempDir(); defer { tmp.cleanup() }
    let trash = try tmp.dir("Trash")
    let file = try tmp.file("folder/a.txt", bytes: 3)
    let recorded = FileOpsCreatedItem(recording: file)
    try FileManager.default.moveItem(at: file, to: trash.appendingPathComponent("a.txt"))
    // The Trash can't be listed (as ~/.Trash without Full Disk Access), but
    // the file can still be found under its own name.
    try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: trash.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trash.path) }

    #expect(FileOpsDragOut.trashed([recorded], trash: { _ in trash })
            == [FileOpsMovedItem(source: file, result: trash.appendingPathComponent("a.txt"))])
}

@Test func fileOpsDragOutFindsFilesTheTrashTook() throws {
    let tmp = try TempDir(); defer { tmp.cleanup() }
    let fm = FileManager.default
    let trash = try tmp.dir("Trash")
    let report = try tmp.file("folder/report.pdf", bytes: 3)
    let notes = try tmp.file("folder/notes.txt", bytes: 4)
    let kept = try tmp.file("folder/kept.txt", bytes: 5)
    let files = [report, notes, kept].map { FileOpsCreatedItem(recording: $0) }

    // report.pdf took a new name in the Trash, which already held another
    // file of that name; notes.txt went in under its own.
    try tmp.file("Trash/report.pdf", bytes: 9)
    try fm.moveItem(at: report, to: trash.appendingPathComponent("report 10.42.07.pdf"))
    try fm.moveItem(at: notes, to: trash.appendingPathComponent("notes.txt"))

    let found = FileOpsDragOut.trashed(files, trash: { _ in trash })

    #expect(found == [FileOpsMovedItem(source: report, result: trash.appendingPathComponent("report 10.42.07.pdf")),
                      FileOpsMovedItem(source: notes, result: trash.appendingPathComponent("notes.txt"))])
    #expect(FileOpsDragOut.isInPlace(files[2]))
    #expect(!FileOpsDragOut.isInPlace(files[0]))
    // Undo puts them back where they were.
    #expect(FileOpsUndoStep.undoingTrash(found) != nil)
}

@Test func fileOpsDragOutFindsNothingWhereTheFileWasReplaced() throws {
    let tmp = try TempDir(); defer { tmp.cleanup() }
    let trash = try tmp.dir("Trash")
    let file = try tmp.file("folder/a.txt", bytes: 3)
    let recorded = FileOpsCreatedItem(recording: file)
    // Gone from its place, but the Trash's a.txt is another file (made
    // first, so it can't be given the removed file's inode).
    try tmp.file("Trash/a.txt", bytes: 3)
    try FileManager.default.removeItem(at: file)

    #expect(FileOpsDragOut.trashed([recorded], trash: { _ in trash }).isEmpty)
    #expect(FileOpsDragOut.trashed([recorded], trash: { _ in nil }).isEmpty)
}
