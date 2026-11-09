import Foundation
import Testing
@testable import SelwayCore

// MARK: - Move or copy

private typealias Mods = FileOpsDrop.Modifiers
private typealias Allowed = FileOpsDrop.Allowed

/// (same volume, keys held, what the source allows) → what the drop does.
private let modeCases: [(Bool, Mods, Allowed, FileOpsTransfer.Mode?)] = [
    (true,  [],                  .all,  .move),   // same volume moves
    (false, [],                  .all,  .copy),   // another volume copies
    (true,  .option,             .all,  .copy),   // ⌥ forces a copy
    (false, .command,            .all,  .move),   // ⌘ forces a move
    (true,  [.option, .command], .all,  nil),     // ⌥⌘ is Finder's make-alias
    (true,  [],                  .copy, .copy),   // a source that only allows copying
    (false, [],                  .move, nil),     // never moves off another volume unasked
    (true,  .option,             .move, nil),
    (false, .command,            .copy, nil),
    (true,  [],                  [],    nil),
]

@Test(arguments: modeCases.indices)
func fileOpsDropModeFollowsVolumeKeysAndSource(index: Int) {
    let (same, mods, allowed, expected) = modeCases[index]
    #expect(FileOpsDrop.mode(sameVolume: same, modifiers: mods, allowed: allowed) == expected)
}

@Test func fileOpsDropReadsTheSourceOperationMask() {
    // NSDragOperation: copy 1, link 2, generic 4, private 8, move 16, delete 32, every UInt.max.
    #expect(FileOpsDrop.allowed(sourceOperationMask: .max, fromThisApp: false) == .all)
    #expect(FileOpsDrop.allowed(sourceOperationMask: 1, fromThisApp: false) == .copy)       // ⌥ held
    #expect(FileOpsDrop.allowed(sourceOperationMask: 4, fromThisApp: false) == .move)       // ⌘ held
    #expect(FileOpsDrop.allowed(sourceOperationMask: 16, fromThisApp: false) == .move)
    #expect(FileOpsDrop.allowed(sourceOperationMask: 2, fromThisApp: false) == [])          // link only
    #expect(FileOpsDrop.allowed(sourceOperationMask: 0, fromThisApp: false) == [])
    // Selway's own rows say "move only" or "copy only"; Selway does the work itself.
    #expect(FileOpsDrop.allowed(sourceOperationMask: 16, fromThisApp: true) == .all)
    #expect(FileOpsDrop.allowed(sourceOperationMask: 1, fromThisApp: true) == .all)
}

// MARK: - Deciding without the disk

private func item(_ path: String, folder: Bool = false, device: UInt64? = 1) -> FileOpsDrop.Item {
    let url = URL(fileURLWithPath: path)
    return FileOpsDrop.Item(url: url, isDirectory: folder, device: device,
                            parentKey: url.deletingLastPathComponent().path, containmentKey: path)
}

private func destination(_ path: String, device: UInt64? = 1) -> FileOpsDrop.Destination {
    FileOpsDrop.Destination(url: URL(fileURLWithPath: path), device: device, folderKey: path, containmentKey: path)
}

@Test func fileOpsDropDecidesFromWhatWasRead() {
    let dest = destination("/v/dest")
    #expect(FileOpsDrop.decide([item("/v/src/a.txt")], into: dest, modifiers: [], allowed: .all) == .drop(.move))
    #expect(FileOpsDrop.decide([item("/v/src/a.txt", device: 2)], into: dest, modifiers: [], allowed: .all) == .drop(.copy))
    // One item from another volume makes the whole drop a copy.
    #expect(FileOpsDrop.decide([item("/v/src/a.txt"), item("/w/b.txt", device: 2)], into: dest,
                               modifiers: [], allowed: .all) == .drop(.copy))
    // An item that couldn't be read, or a folder that couldn't, copies too.
    #expect(FileOpsDrop.decide([item("/v/src/a.txt", device: nil)], into: dest, modifiers: [], allowed: .all) == .drop(.copy))
    #expect(FileOpsDrop.decide([item("/v/src/a.txt")], into: destination("/v/dest", device: nil),
                               modifiers: [], allowed: .all) == .drop(.copy))
    #expect(FileOpsDrop.decide([], into: dest, modifiers: [], allowed: .all) == .refuse(.noFiles))
    #expect(FileOpsDrop.decide([item("/v/src/a.txt")], into: dest, modifiers: [.option, .command],
                               allowed: .all) == .refuse(.notAllowed))
}

@Test func fileOpsDropRefusesAFolderIntoItselfOrBelow() {
    let folder = item("/v/p", folder: true)
    #expect(FileOpsDrop.decide([folder], into: destination("/v/p"), modifiers: [], allowed: .all)
            == .refuse(.intoItself("p")))
    #expect(FileOpsDrop.decide([folder], into: destination("/v/p/child/deeper"), modifiers: .option, allowed: .all)
            == .refuse(.intoItself("p")))
    // A sibling whose name starts the same is not inside it.
    #expect(FileOpsDrop.decide([folder], into: destination("/v/p2"), modifiers: [], allowed: .all) == .drop(.move))
    // One bad item refuses the whole drop, as in Finder.
    #expect(FileOpsDrop.decide([item("/v/a.txt"), folder], into: destination("/v/p/child"),
                               modifiers: [], allowed: .all) == .refuse(.intoItself("p")))
    // A file named like the destination's ancestor is just a file.
    #expect(FileOpsDrop.decide([item("/v/p")], into: destination("/v/p/child"), modifiers: [], allowed: .all) == .drop(.move))
}

@Test func fileOpsDropMovingIntoTheSameFolderIsRefusedButCopyingIsNot() {
    let dest = destination("/v/src")
    let a = item("/v/src/a.txt"), b = item("/v/src/b.txt")
    #expect(FileOpsDrop.decide([a, b], into: dest, modifiers: [], allowed: .all) == .refuse(.alreadyThere))
    #expect(FileOpsDrop.decide([a, b], into: dest, modifiers: .command, allowed: .all) == .refuse(.alreadyThere))
    // ⌥ copies next to the originals ("a copy.txt"), as in Finder.
    #expect(FileOpsDrop.decide([a, b], into: dest, modifiers: .option, allowed: .all) == .drop(.copy))
    // From another volume it's a copy, so it isn't "already there" either.
    #expect(FileOpsDrop.decide([item("/v/src/a.txt", device: 2)], into: dest, modifiers: [], allowed: .all) == .drop(.copy))
    // Some items from elsewhere: those move, the rest are left where they are.
    #expect(FileOpsDrop.decide([a, item("/v/other/c.txt")], into: dest, modifiers: [], allowed: .all) == .drop(.move))
}

// MARK: - Real folders

@Test func fileOpsDropOnRealFoldersRefusesWhatTransferWouldRefuseOrSkip() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let parent = try dir.dir("p")
    let child = try dir.dir("p/child")
    let file = try dir.file("p/a.txt")

    #expect(FileOpsDrop.decide([parent], into: parent) == .refuse(.intoItself("p")))
    #expect(FileOpsDrop.decide([parent], into: child) == .refuse(.intoItself("p")))
    #expect(FileOpsDrop.decide([parent], into: child, modifiers: .option) == .refuse(.intoItself("p")))
    #expect(FileOpsDrop.decide([file, child], into: parent) == .refuse(.alreadyThere))
    #expect(FileOpsDrop.decide([file], into: child) == .drop(.move))
    #expect(FileOpsDrop.decide([file], into: parent, modifiers: .option) == .drop(.copy))

    // What the transfer does with the same drops: it fails the folder and skips the move.
    let into = FileOpsTransfer.transfer([parent], into: child, mode: .move)
    #expect(into.done.isEmpty && into.failures.map(\.name) == ["p"])
    let there = FileOpsTransfer.transfer([file, child], into: parent, mode: .move)
    #expect(there.done.isEmpty && there.failures.isEmpty)
}

@Test func fileOpsDropFollowsSymlinksLikeTheTransfer() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let parent = try dir.dir("p")
    try dir.dir("p/child")
    // A folder reached through a link is still inside the dragged folder.
    let linkToChild = try dir.link("toChild", to: "p/child")
    #expect(FileOpsDrop.decide([parent], into: linkToChild) == .refuse(.intoItself("p")))
    // A dragged link to a folder is a link, not the folder: it can go inside its target.
    let linkToParent = try dir.link("toParent", to: "p")
    #expect(FileOpsDrop.decide([linkToParent], into: parent) == .drop(.move))
}

/// Regression: files dropped on a symlink to the folder they are already in
/// were "moved" there, which renamed each to a free name beside itself
/// ("a 2.txt"). Finder does nothing; so does the transfer itself.
@Test func fileOpsDropOnALinkToTheItemsOwnFolderIsRefused() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let a = try dir.file("p/a.txt")
    let b = try dir.file("p/b.txt")
    let link = try dir.link("toP", to: "p")
    #expect(FileOpsDrop.decide([a, b], into: link) == .refuse(.alreadyThere))
    #expect(FileOpsDrop.decide([a], into: link, modifiers: .option) == .drop(.copy))
    // And the other way: items listed through the link, dropped on the real folder.
    let viaLink = link.appendingPathComponent("a.txt")
    #expect(FileOpsDrop.decide([viaLink], into: dir.url.appendingPathComponent("p")) == .refuse(.alreadyThere))

    let moved = FileOpsTransfer.transfer([a, b], into: link, mode: .move)
    #expect(moved.done.isEmpty && moved.failures.isEmpty)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.appendingPathComponent("p").path).sorted()
    #expect(names == ["a.txt", "b.txt"])
    // A copy there is a duplicate beside the original, as in the folder itself.
    let copied = FileOpsTransfer.transfer([a], into: link, mode: .copy)
    #expect(copied.done.map(\.result.lastPathComponent) == ["a copy.txt"])
    // Spelled through the link, as the window showing it lists its items.
    #expect(copied.done.map(\.result) == [link.appendingPathComponent("a copy.txt")])
}

#if os(macOS)
/// /var is a link to /private/var: the folder an item is in counts as the
/// destination however either is spelled, as in FileOpsTransfer.transfer.
@Test func fileOpsDropKnowsTheSameFolderUnderAnotherSpelling() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let file = try dir.file("a.txt")
    let real = dir.url.path
    try #require(real.hasPrefix("/private/var/"), "the temporary folder isn't under /private/var: \(real)")
    let viaVar = URL(fileURLWithPath: String(real.dropFirst("/private".count)), isDirectory: true)
    #expect(FileOpsDrop.decide([file], into: viaVar) == .refuse(.alreadyThere))
}
#endif

@Test func fileOpsDropSameVolumeForTemporaryFolders() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let a = try dir.file("src/a.txt")
    let folder = try dir.dir("src/folder")
    let dest = try dir.dir("dest")
    let items = [a, folder].map { FileOpsDrop.Item(reading: $0) }
    #expect(items.allSatisfy { $0.device != nil })
    #expect(items.map(\.isDirectory) == [false, true])
    #expect(FileOpsDrop.isSameVolume(items, as: FileOpsDrop.Destination(reading: dest)))
    #expect(FileOpsDrop.decide([a, folder], into: dest) == .drop(.move))

    // A missing item can't be placed on a volume: the drop copies (and the
    // transfer reports it missing).
    let missing = dir.url.appendingPathComponent("src/gone.txt")
    #expect(FileOpsDrop.Item(reading: missing).device == nil)
    #expect(FileOpsDrop.decide([a, missing], into: dest) == .drop(.copy))
}

#if os(macOS)
/// /dev is a file system of its own (devfs), so it stands in for another volume.
@Test func fileOpsDropAnotherVolumeCopies() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let a = try dir.file("a.txt")
    let dev = FileOpsDrop.Destination(reading: URL(fileURLWithPath: "/dev", isDirectory: true))
    let item = FileOpsDrop.Item(reading: a)
    try #require(dev.device != nil && dev.device != item.device)
    #expect(!FileOpsDrop.isSameVolume([item], as: dev))
    #expect(FileOpsDrop.decide([item], into: dev, modifiers: [], allowed: .all) == .drop(.copy))
    #expect(FileOpsDrop.decide([item], into: dev, modifiers: .command, allowed: .all) == .drop(.move))
}

/// A real second volume: a small disk image mounted in a temporary folder
/// (hidden, nothing opened, always detached), so it only runs when asked:
/// `SELWAY_RUN_HDIUTIL_TESTS=1 ./scripts/test.sh --filter fileOpsDropOntoAMountedVolume`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SELWAY_RUN_HDIUTIL_TESTS"] == "1"))
func fileOpsDropOntoAMountedVolumeCopiesAndKeepsTheOriginal() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let image = dir.url.appendingPathComponent("drop.dmg")
    let mount = try dir.dir("mnt")
    let create = TestTool.run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "16m", "-fs", "HFS+",
                                                   "-volname", "SELWAYDROP", image.path])
    try #require(create.status == 0, "\(create.text)")
    defer { TestTool.detachImages(of: image) }
    let attach = TestTool.run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noautoopen",
                                                   "-mountpoint", mount.path, image.path])
    try #require(attach.status == 0, "\(attach.text)")

    let a = try dir.file("a.txt", bytes: 3)
    let folder = try dir.dir("folder")
    try dir.file("folder/inner.txt", bytes: 2)
    guard case .drop(let mode) = FileOpsDrop.decide([a, folder], into: mount) else {
        Issue.record("the drop onto another volume was refused"); return
    }
    #expect(mode == .copy)
    let result = FileOpsTransfer.transfer([a, folder], into: mount, mode: mode)
    #expect(result.failures.isEmpty)
    #expect(FileManager.default.fileExists(atPath: a.path))
    #expect(FileManager.default.fileExists(atPath: mount.appendingPathComponent("folder/inner.txt").path))
    // Dragging the copies back with ⌘ moves them off the image.
    let copies = result.done.map(\.result)
    #expect(FileOpsDrop.decide(copies, into: try dir.dir("back"), modifiers: .command) == .drop(.move))
}
#endif

// MARK: - Undo

@Test func fileOpsDropUndoIsPastes() throws {
    let moved = FileOpsBatchResult(done: [FileOpsMovedItem(source: URL(fileURLWithPath: "/a"),
                                                             result: URL(fileURLWithPath: "/b/a"))])
    guard case .move(let back)? = FileOpsUndoStep.undoingTransfer(.move, moved) else {
        Issue.record("a move's undo isn't a move back"); return
    }
    #expect(back.count == 1)
    let created = FileOpsCreatedItem(url: URL(fileURLWithPath: "/b/a"), identity: nil)
    #expect(FileOpsUndoStep.undoingTransfer(.copy, FileOpsBatchResult(created: [created])) == .trash([created]))
    #expect(FileOpsUndoStep.undoingTransfer(.move, FileOpsBatchResult()) == nil)
    #expect(FileOpsUndoStep.undoingTransfer(.copy, FileOpsBatchResult()) == nil)
}
