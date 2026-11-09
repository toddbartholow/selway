import Foundation
import Testing
@testable import SelwayCore

// MARK: - Deciding

@Test func fileOpsPromiseDropTakesOnlyACopy() {
    let decide = FileOpsDrop.decidePromises
    #expect(decide(1, [], .all) == .drop(.copy))
    #expect(decide(3, .option, .copy) == .drop(.copy))
    // ⌘ narrows the source's mask to generic: a move only, which is refused,
    // since the source could delete its original once told of a move.
    #expect(decide(1, .command, .move) == .refuse(.notAllowed))
    #expect(decide(1, [], .move) == .refuse(.notAllowed))
    #expect(decide(1, [.option, .command], .all) == .refuse(.notAllowed))   // an alias
    #expect(decide(1, [], []) == .refuse(.notAllowed))
    #expect(decide(0, [], .all) == .refuse(.noFiles))
}

// MARK: - Counting the answers

@Test func fileOpsPromiseDropCountsEveryFileAPromiseNames() {
    // A legacy promise names three files on one pasteboard item; a promise
    // that names none still owes an answer.
    #expect(FileOpsPromiseDrop.expectedAnswers(fileNameCounts: [3, 1, 0]) == 5)
    #expect(FileOpsPromiseDrop.expectedAnswers(fileNameCounts: [0]) == 1)
}

@Test func fileOpsPromiseDropWaitsForEveryFileOfALegacyPromise() throws {
    let staging = URL(fileURLWithPath: "/stage", isDirectory: true)
    var batch = FileOpsPromiseDrop.Batch(staging: staging, destination: URL(fileURLWithPath: "/dest"))
    #expect(!batch.isComplete)                 // nothing owed yet: not called in
    batch.expect(FileOpsPromiseDrop.expectedAnswers(fileNameCounts: [3]))

    #expect(batch.answer(staging.appendingPathComponent("a.jpg"), failure: nil) == staging.appendingPathComponent("a.jpg"))
    #expect(!batch.isComplete)
    let failed = FileOpsFailure(name: "b.jpg", message: "The download failed.")
    #expect(batch.answer(staging.appendingPathComponent("b.jpg"), failure: failed) == nil)
    #expect(!batch.isComplete)
    #expect(batch.progress == FileOpsProgress(completed: 2, total: 3, currentName: ""))
    #expect(batch.answer(staging.appendingPathComponent("c.jpg"), failure: nil) != nil)
    #expect(batch.isComplete)
    // An answer past those owed still counts, and is landed.
    #expect(batch.answer(staging.appendingPathComponent("d.jpg"), failure: nil) != nil)
    #expect(batch.progress.total == 4)
    #expect(batch.finished(.answered).failures == [failed])
}

@Test func fileOpsPromiseDropRefusesAFileWrittenOutsideTheStagingFolder() {
    let staging = URL(fileURLWithPath: "/stage", isDirectory: true)
    var batch = FileOpsPromiseDrop.Batch(staging: staging, destination: URL(fileURLWithPath: "/dest"))
    batch.expect(3)
    #expect(batch.answer(URL(fileURLWithPath: "/Users/me/Documents/secret.txt"), failure: nil) == nil)
    #expect(batch.answer(staging, failure: nil) == nil)
    #expect(batch.answer(staging.appendingPathComponent("sub/inner.txt"), failure: nil) != nil)
    #expect(batch.result.failures.map(\.name) == ["secret.txt", "stage"])
}

@Test func fileOpsPromiseDropReportsPromisesNeverAnswered() {
    let staging = URL(fileURLWithPath: "/stage", isDirectory: true)
    var batch = FileOpsPromiseDrop.Batch(staging: staging, destination: URL(fileURLWithPath: "/dest"))
    batch.expect(3)
    _ = batch.answer(staging.appendingPathComponent("a.jpg"), failure: nil)
    let timedOut = batch.finished(.timedOut)
    #expect(timedOut.failures.count == 2)
    #expect(timedOut.failures.allSatisfy { $0.name == "an item" })
    #expect(!timedOut.cancelled)
    let cancelled = batch.finished(.cancelled)
    #expect(cancelled.cancelled)
    #expect(cancelled.failures.isEmpty)
}

@Test func fileOpsPromiseDropNamesAFailureByWhatItKnows() {
    #expect(FileOpsPromiseDrop.failureName(errorPath: "/stage/IMG_1.HEIC", promised: ["x"]) == "IMG_1.HEIC")
    #expect(FileOpsPromiseDrop.failureName(errorPath: nil, promised: ["note.eml"]) == "note.eml")
    #expect(FileOpsPromiseDrop.failureName(errorPath: "", promised: ["a", "b"]) == "an item")
    #expect(FileOpsPromiseDrop.failureName(errorPath: nil, promised: []) == "an item")
}

// MARK: - Landing the files

@Test func fileOpsPromiseDropStagesOutsideTheDestination() throws {
    let tmp = try TempDir(); defer { tmp.cleanup() }
    let dest = try tmp.dir("dest")
    let staging = try FileOpsPromiseDrop.makeStagingFolder(for: dest)
    defer { FileOpsPromiseDrop.removeStagingFolder(staging) }
    #expect(FileOpsNaming.isDirectory(staging))
    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    #expect(!FileOpsTransfer.isSameOrInside(staging, dest))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
}

@Test func fileOpsPromiseDropLandsEachFileWithAFreeName() throws {
    let tmp = try TempDir(); defer { tmp.cleanup() }
    let dest = try tmp.dir("dest")
    try tmp.file("dest/photo.jpg", bytes: 1)
    let staging = try tmp.dir("staging")
    var batch = FileOpsPromiseDrop.Batch(staging: staging, destination: dest)
    batch.expect(3)

    for (name, bytes) in [("photo.jpg", 2), ("note.txt", 3)] {
        let written = try tmp.file("staging/\(name)", bytes: bytes)
        let answer = batch.answer(written, failure: nil)
        let file = try #require(answer)
        batch.add(FileOpsPromiseDrop.land(file, into: dest))
    }
    // The source said it wrote a file that isn't there.
    let gone = batch.answer(staging.appendingPathComponent("gone.txt"), failure: nil)
    let missing = try #require(gone)
    batch.add(FileOpsPromiseDrop.land(missing, into: dest))
    #expect(batch.isComplete)

    let result = batch.finished(.answered)
    let landed = result.done.map(\.result.lastPathComponent)
    #expect(landed == ["photo 2.jpg", "note.txt"])
    #expect(result.failures.map(\.name) == ["gone.txt"])
    // The file that was there is untouched; the new one took a free name.
    #expect(try Data(contentsOf: dest.appendingPathComponent("photo.jpg")).count == 1)
    #expect(try Data(contentsOf: dest.appendingPathComponent("photo 2.jpg")).count == 2)
    // Undo trashes exactly the files the drop made, as for a copy.
    #expect(result.created.map(\.url.lastPathComponent) == landed)
    #expect(result.created.allSatisfy { $0.identity != nil })
    #expect(FileOpsUndoStep.undoingCopy(result.created) == .trash(result.created))

    FileOpsPromiseDrop.removeStagingFolder(staging)
    #expect(!FileManager.default.fileExists(atPath: staging.path))
}
