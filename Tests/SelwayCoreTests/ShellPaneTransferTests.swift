import Foundation
import Testing
@testable import SelwayCore

// File → Copy to Other Pane (F5) / Move to Other Pane (F6).

// MARK: - Made-up folders (no disk)

/// Made-up identities: a folder's is its number, and its chain runs up through
/// the numbers given.
private func id(_ n: UInt64) -> FileOpsItemIdentity { FileOpsItemIdentity(device: 1, inode: n) }

private func folder(_ path: String, _ chain: UInt64...) -> ShellPaneTransfer.Folder {
    ShellPaneTransfer.Folder(url: URL(fileURLWithPath: path), chain: chain.map(id))
}

private func item(_ path: String, _ identity: UInt64, folder isDirectory: Bool = false,
                  in ancestors: UInt64...) -> ShellPaneTransfer.Item {
    ShellPaneTransfer.Item(url: URL(fileURLWithPath: path), isDirectory: isDirectory, identity: id(identity),
                           ancestors: ancestors.map(id))
}

// The made-up disk: / (1) holds v (2), which holds left (10) and right (20).
// left holds a.txt (11), b.txt (12) and sub (13), which holds inner.txt (14).
// right holds c.txt (21).
private let left = folder("/v/left", 10, 2, 1)
private let right = folder("/v/right", 20, 2, 1)
private let sub = folder("/v/left/sub", 13, 10, 2, 1)
private let a = item("/v/left/a.txt", 11, in: 10, 2, 1)
private let b = item("/v/left/b.txt", 12, in: 10, 2, 1)
private let subItem = item("/v/left/sub", 13, folder: true, in: 10, 2, 1)
private let inner = item("/v/left/sub/inner.txt", 14, in: 13, 10, 2, 1)
private let c = item("/v/right/c.txt", 21, in: 20, 2, 1)

private func decide(_ mode: FileOpsTransfer.Mode, isDual: Bool = true, _ items: [ShellPaneTransfer.Item],
                    from source: ShellPaneTransfer.Folder = left,
                    into dest: ShellPaneTransfer.Folder = right,
                    searching: Bool = false) -> ShellPaneTransfer.Decision {
    ShellPaneTransfer.decide(mode, isDual: isDual, selected: items, from: source, into: dest, searching: searching)
}

private func confirmed(_ decision: ShellPaneTransfer.Decision) -> ShellPaneTransfer.Plan? {
    if case .confirm(let plan) = decision { return plan }
    return nil
}

// MARK: - Deciding

@Test func paneTransferConfirmsTheSelectionIntoTheOtherPanesFolder() throws {
    let plan = try #require(confirmed(decide(.move, [a, subItem])))
    #expect(plan.mode == .move)
    #expect(plan.sources.map(\.path) == ["/v/left/a.txt", "/v/left/sub"])
    #expect(plan.destination.path == "/v/right")
}

@Test func paneTransferNeedsTwoPanes() {
    #expect(decide(.copy, isDual: false, [a]) == .refuse(.singlePane))
    // Said before anything else: one pane has no other pane, selection or not.
    #expect(decide(.copy, isDual: false, []) == .refuse(.singlePane))
}

@Test func paneTransferNeedsASelection() {
    #expect(decide(.copy, []) == .refuse(.nothingSelected))
    #expect(decide(.move, []) == .refuse(.nothingSelected))
}

@Test func paneTransferRefusesWhenBothPanesShowOneFolder() {
    #expect(decide(.copy, [a], into: left) == .refuse(.sameFolder))
    // Spelled another way (a symlink, another case): the same folder on disk.
    #expect(decide(.move, [a], into: folder("/v/LEFT", 10, 2, 1)) == .refuse(.sameFolder))
    // Folders that couldn't be read are compared by path.
    #expect(decide(.copy, [a], from: folder("/x/one"), into: folder("/x/one/")) == .refuse(.sameFolder))
    #expect(confirmed(decide(.copy, [a], from: folder("/x/one"), into: folder("/x/two"))) != nil)
}

/// A search lists results from anywhere: with both panes on one folder, a
/// result from elsewhere can still go there, and one already there can't.
@Test func paneTransferFromSearchResultsLooksAtTheItemsNotThePanes() throws {
    let plan = try #require(confirmed(decide(.copy, [c], into: left, searching: true)))
    #expect(plan.sources.map(\.path) == ["/v/right/c.txt"])
    #expect(plan.destination.path == "/v/left")
    #expect(decide(.copy, [a], into: left, searching: true) == .refuse(.alreadyThere("a.txt")))
    #expect(decide(.copy, [c], into: left) == .refuse(.sameFolder))
}

@Test func paneTransferRefusesAFolderIntoItselfOrBelow() throws {
    // The other pane shows a selected folder, or a folder inside one.
    #expect(decide(.copy, [subItem], into: sub) == .refuse(.intoItself("sub")))
    #expect(decide(.move, [a, subItem], into: folder("/v/left/sub/deeper", 15, 13, 10, 2, 1))
            == .refuse(.intoItself("sub")))
    // A sibling whose name starts the same is not inside it.
    let sibling = folder("/v/left/sub2", 16, 10, 2, 1)
    let plan = try #require(confirmed(decide(.copy, [subItem], into: sibling)))
    #expect(plan.sources.map(\.lastPathComponent) == ["sub"])
}

@Test func paneTransferRefusesItemsAlreadyInTheOtherPanesFolder() {
    // A search in the left pane lists a file that's in the right pane's folder.
    #expect(decide(.copy, [a, c]) == .refuse(.alreadyThere("c.txt")))
    #expect(decide(.move, [c]) == .refuse(.alreadyThere("c.txt")))
}

@Test func paneTransferLeavesOutItemsInsideASelectedFolder() throws {
    // A search lists sub and inner.txt, which is in it: sub takes it along.
    #expect(ShellPaneTransfer.topLevel([subItem, inner, a]) == [subItem, a])
    #expect(ShellPaneTransfer.topLevel([inner, a]) == [inner, a])
    let plan = try #require(confirmed(decide(.copy, [inner, subItem])))
    #expect(plan.sources.map(\.lastPathComponent) == ["sub"])
    #expect(plan.title == "Copy “sub” to “right”?")
}

// MARK: - Reading the disk

/// A temporary folder holding `left` and `right`, `a.txt` in left.
private struct Disk {
    let root: URL
    let left: URL
    let right: URL
    let file: URL

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("ShellPaneTransfer-\(UUID().uuidString)", isDirectory: true)
        left = root.appendingPathComponent("left", isDirectory: true)
        right = root.appendingPathComponent("right", isDirectory: true)
        file = left.appendingPathComponent("a.txt")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: file)
    }

    func link(_ name: String, to target: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// Whether the volume holding the folder ignores case.
    var ignoresCase: Bool {
        FileManager.default.fileExists(atPath: file.path.uppercased())
            && FileManager.default.fileExists(atPath: left.path.uppercased())
    }
}

@Test func paneTransferReadsURLsBeforeDeciding() throws {
    let disk = try Disk()
    defer { disk.remove() }
    let decision = ShellPaneTransfer.decide(.copy, isDual: true, selected: [disk.file], from: disk.left, into: disk.right)
    let plan = try #require(confirmed(decision))
    #expect(plan.sources.map(\.lastPathComponent) == ["a.txt"])
    #expect(ShellPath.same(plan.destination, disk.right))
    #expect(ShellPaneTransfer.decide(.copy, isDual: true, selected: [disk.file], from: disk.left, into: disk.left)
            == .refuse(.sameFolder))
    #expect(ShellPaneTransfer.decide(.copy, isDual: false, selected: [disk.file], from: disk.left, into: disk.right)
            == .refuse(.singlePane))
    #expect(ShellPaneTransfer.decide(.move, isDual: true, selected: [], from: disk.left, into: disk.right)
            == .refuse(.nothingSelected))
}

/// A selection of many items in one folder reads that folder's chain once.
@Test func paneTransferReadsEachFolderOnce() throws {
    let disk = try Disk()
    defer { disk.remove() }
    let names = ["a.txt", "b.txt", "c.txt"]
    for name in names.dropFirst() {
        try Data().write(to: disk.left.appendingPathComponent(name))
    }
    var read: [String] = []
    let items = ShellPaneTransfer.Item.reading(names.map { disk.left.appendingPathComponent($0) }, chain: { folder in
        read.append(folder.path)
        return ShellPaneTransfer.Folder.chain(folder)
    })
    #expect(read.count == 1)
    #expect(items.map(\.url.lastPathComponent) == names)
    #expect(items.allSatisfy { $0.ancestors == items[0].ancestors && !$0.ancestors.isEmpty })
    #expect(items.map(\.ancestors) == names.map {
        ShellPaneTransfer.Item(reading: disk.left.appendingPathComponent($0)).ancestors
    })
}

@Test func paneTransferSeesOneFolderHoweverItIsSpelled() throws {
    let disk = try Disk()
    defer { disk.remove() }
    func sameFolder(_ other: URL) -> Bool {
        ShellPaneTransfer.decide(.copy, isDual: true, selected: [disk.file], from: disk.left, into: other)
            == .refuse(.sameFolder)
    }
    // Through a symlink to it.
    #expect(sameFolder(try disk.link("leftLink", to: disk.left)))
    // With a trailing slash, and with a step out and back.
    #expect(sameFolder(URL(fileURLWithPath: disk.left.path + "/")))
    #expect(sameFolder(disk.right.appendingPathComponent("../left")))
    #if canImport(Darwin)
    // The temporary folder is under /private on macOS: with or without it.
    let real = try #require(ModelPaths.realPath(disk.left))
    let spellings = [real.path, real.path.hasPrefix("/private/") ? String(real.path.dropFirst("/private".count)) : real.path]
    for path in spellings { #expect(sameFolder(URL(fileURLWithPath: path))) }
    #endif
    // In another case, where the volume ignores case.
    if disk.ignoresCase {
        #expect(sameFolder(URL(fileURLWithPath: disk.left.path.uppercased())))
    }
}

@Test func paneTransferFollowsSymlinksTheWayTheDiskDoes() throws {
    let disk = try Disk()
    defer { disk.remove() }
    let fm = FileManager.default
    // A symlink in the selection to a folder that holds the destination goes
    // as a link, not as that folder: nothing goes into itself.
    let linkToRoot = try disk.link("rootLink", to: disk.root)
    let movedLink = disk.left.appendingPathComponent("rootLink")
    try fm.moveItem(at: linkToRoot, to: movedLink)
    #expect(confirmed(ShellPaneTransfer.decide(.copy, isDual: true, selected: [movedLink], from: disk.left,
                                          into: disk.right)) != nil)
    // A real folder whose inside the other pane reaches through a symlink:
    // the destination is in the folder all the same.
    let inside = disk.left.appendingPathComponent("inside", isDirectory: true)
    try fm.createDirectory(at: inside, withIntermediateDirectories: true)
    let insideLink = try disk.link("insideLink", to: inside)
    #expect(ShellPaneTransfer.decide(.move, isDual: true, selected: [disk.left], from: disk.root, into: insideLink)
            == .refuse(.intoItself("left")))
}

@Test func paneTransferSeesItemsAlreadyThereHoweverTheFolderIsSpelled() throws {
    let disk = try Disk()
    defer { disk.remove() }
    let other = try disk.link("leftLink", to: disk.left)
    // A search from the right pane lists a.txt, and the left pane shows its
    // folder through a symlink.
    #expect(ShellPaneTransfer.decide(.move, isDual: true, selected: [disk.file], from: disk.right, into: other)
            == .refuse(.alreadyThere("a.txt")))
}

// MARK: - The confirmation

@Test func paneTransferNamesOneItemAndCountsSeveral() {
    let docs = URL(fileURLWithPath: "/Users/me/Documents")
    #expect(ShellPaneTransfer.title(.copy, names: ["alpha.txt"], destination: docs)
            == "Copy “alpha.txt” to “Documents”?")
    #expect(ShellPaneTransfer.title(.move, names: ["alpha.txt"], destination: docs)
            == "Move “alpha.txt” to “Documents”?")
    #expect(ShellPaneTransfer.title(.copy, names: ["a", "b"], destination: docs)
            == "Copy 2 items to “Documents”?")
    #expect(ShellPaneTransfer.title(.move, names: ["a", "b", "c"], destination: docs)
            == "Move 3 items to “Documents”?")
    // A folder with a trailing slash, and the top of the disk.
    #expect(ShellPaneTransfer.title(.copy, names: ["a"], destination: URL(fileURLWithPath: "/Users/me/Documents/"))
            == "Copy “a” to “Documents”?")
    #expect(ShellPaneTransfer.title(.copy, names: ["a"], destination: URL(fileURLWithPath: "/")) == "Copy “a” to “/”?")
}

@Test func paneTransferSaysWhereTheItemsGo() {
    let docs = URL(fileURLWithPath: "/Users/me/Documents/")
    #expect(ShellPaneTransfer.message(.copy, count: 1, destination: docs)
            == "Into /Users/me/Documents. If its name is taken there, the copy gets a new one.")
    #expect(ShellPaneTransfer.message(.move, count: 1, destination: docs)
            == "Into /Users/me/Documents. If its name is taken there, the item gets a new one.")
    #expect(ShellPaneTransfer.message(.move, count: 2, destination: docs)
            == "Into /Users/me/Documents. Any whose names are taken there get new ones.")
}

@Test func paneTransferPlanCarriesTheTexts() throws {
    let plan = try #require(confirmed(decide(.move, [a, b])))
    #expect(plan.title == "Move 2 items to “right”?")
    #expect(plan.message == "Into /v/right. Any whose names are taken there get new ones.")
}

// MARK: - Refusals

@Test func paneTransferSaysWhyItCant() {
    let docs = URL(fileURLWithPath: "/Users/me/Documents")
    func say(_ refusal: ShellPaneTransfer.Refusal, _ mode: FileOpsTransfer.Mode = .copy) -> String {
        ShellPaneTransfer.refusalMessage(refusal, mode: mode, destination: docs)
    }
    #expect(say(.singlePane) == "Show Dual Pane to copy to the other pane")
    #expect(say(.singlePane, .move) == "Show Dual Pane to move to the other pane")
    #expect(say(.nothingSelected) == "Select items to copy first")
    #expect(say(.nothingSelected, .move) == "Select items to move first")
    #expect(ShellPaneTransfer.refusalBeforeReading(isDual: true, selected: [a.url], hasFolderDestination: false)
            == .otherPaneNotFolder)
    #expect(ShellPaneTransfer.refusalBeforeReading(isDual: true, selected: [], hasFolderDestination: false)
            == .nothingSelected)
    #expect(ShellPaneTransfer.refusalMessage(.otherPaneNotFolder, mode: .copy, destination: nil)
            == "Show a folder in the other pane to copy there")
    #expect(ShellPaneTransfer.refusalMessage(.otherPaneNotFolder, mode: .move, destination: nil)
            == "Show a folder in the other pane to move there")
    #expect(say(.sameFolder) == "Both panes show the same folder")
    #expect(say(.alreadyThere("a.txt")) == "“a.txt” is already in “Documents”")
    #expect(say(.intoItself("sub")) == "“sub” can’t be copied into itself")
    #expect(say(.intoItself("sub"), .move) == "“sub” can’t be moved into itself")
    #expect(ShellPaneTransfer.refusalMessage(.alreadyThere("a.txt"), mode: .copy, destination: nil)
            == "“a.txt” is already in that folder")
}
