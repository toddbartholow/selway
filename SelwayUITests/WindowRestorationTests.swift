import XCTest

/// Windows macOS brings back at launch (Quit and Keep Windows) reopen on the
/// folders they showed (WindowFolderRestorer).
///
/// The first launch closes any windows an earlier run left to bring back, so
/// quitting saves only its own. Both launches keep windows on ⌘Q
/// (`NSQuitAlwaysKeepsWindows`), whatever the Mac's "Close windows when
/// quitting an application" setting, which swaps ⌘Q and ⌥⌘Q.
final class WindowRestorationTests: SelwayUITestCase {

    private static let keepsWindows = ["-NSQuitAlwaysKeepsWindows", "YES"]

    private func pane(_ index: Int) -> XCUIElement { identified("pane\(index)") }
    private func list(_ index: Int) -> XCUIElement { identified("fileList", in: pane(index)) }

    private func waitForItem(_ name: String, inPane index: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(item(name, in: list(index)).waitForExistence(timeout: 10),
                      "pane\(index) doesn't list “\(name)”", file: file, line: line)
    }

    /// A folder the New windows folder setting points at, so a pane that fell
    /// back to it is told apart from one restored on the fixture's root.
    private func makeNewWindowFolder() throws -> URL {
        let folder = try fixture.makeSibling("NewWindowFolder")
        try fixture.makeFile("elsewhere.txt", size: 1, in: folder)
        return folder
    }

    /// Two panes, the first in `subfolder` and the second on the fixture's
    /// root, then ⌘Q, keeping the window.
    private func showTwoFoldersAndQuit() throws {
        try fixture.makeStandardContents()
        try launch(folder: fixture.root, additionalArguments: Self.keepsWindows, savedWindows: .forgotten,
                   expecting: Fixture.standardListing)
        app.typeKey("p", modifierFlags: [.command, .control])
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "⌃⌘P showed no second pane")
        waitForItem("alpha.txt", inPane: 1)
        doubleClick(item(Fixture.folder, in: list(0)))
        waitForItem(Fixture.innerFile, inPane: 0)
        waitForItem("alpha.txt", inPane: 1)

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(waitUntil(10) { self.app.state == .notRunning }, "⌘Q didn't quit Selway")
    }

    func testQuitAndKeepWindowsReopensEachPanesFolder() throws {
        try showTwoFoldersAndQuit()
        let newWindowFolder = try makeNewWindowFolder()

        try launch(defaults: ["selwayNewWindowCustomFolder": newWindowFolder.path],
                   additionalArguments: Self.keepsWindows, savedWindows: .restored, expecting: [Fixture.innerFile])
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "the restored window lost its second pane")
        waitForItem(Fixture.innerFile, inPane: 0)
        waitForItem("alpha.txt", inPane: 1)
        XCTAssertFalse(item("elsewhere.txt", in: browserWindow).exists,
                       "a restored pane opened on the New windows folder")
    }

    /// Each restored window reopens on its own folder, not another window's:
    /// the places are saved by window.
    func testEachRestoredWindowReopensOnItsOwnFolder() throws {
        try fixture.makeStandardContents()
        let other = try fixture.makeSibling("OtherWindow")
        try fixture.makeFile("other.txt", size: 1, in: other)
        try launch(defaults: ["selwayNewWindowCustomFolder": other.path], folder: fixture.root,
                   additionalArguments: Self.keepsWindows, savedWindows: .forgotten,
                   expecting: Fixture.standardListing)
        // File ▸ New Window opens at the "new windows open" folder: OtherWindow.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(window(titled: "OtherWindow").waitForExistence(timeout: 10), "no second window on OtherWindow")
        XCTAssertTrue(item("other.txt", in: window(titled: "OtherWindow")).waitForExistence(timeout: 10),
                      "the second window doesn't list other.txt")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(waitUntil(10) { self.app.state == .notRunning }, "⌘Q didn't quit Selway")
        let newWindowFolder = try makeNewWindowFolder()

        try launch(defaults: ["selwayNewWindowCustomFolder": newWindowFolder.path],
                   additionalArguments: Self.keepsWindows, savedWindows: .restored,
                   expecting: [], checksItemCount: false)
        let first = window(titled: Fixture.rootName), second = window(titled: "OtherWindow")
        XCTAssertTrue(first.waitForExistence(timeout: 10), "no restored window on \(Fixture.rootName)")
        XCTAssertTrue(second.waitForExistence(timeout: 10), "no restored window on OtherWindow")
        XCTAssertTrue(item("alpha.txt", in: first).waitForExistence(timeout: 10),
                      "the window on \(Fixture.rootName) doesn't list alpha.txt")
        XCTAssertTrue(item("other.txt", in: second).waitForExistence(timeout: 10),
                      "the window on OtherWindow doesn't list other.txt")
        XCTAssertFalse(text("elsewhere.txt", in: app).exists, "a restored window opened on the New windows folder")
    }

    private func window(titled title: String) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title == %@", title)).firstMatch
    }

    /// A saved folder that's gone leaves its pane on the New windows folder;
    /// the other pane still reopens on its own.
    func testAPaneWhoseFolderIsGoneOpensTheNewWindowsFolder() throws {
        try showTwoFoldersAndQuit()
        let newWindowFolder = try makeNewWindowFolder()
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(Fixture.folder, isDirectory: true))

        try launch(defaults: ["selwayNewWindowCustomFolder": newWindowFolder.path],
                   additionalArguments: Self.keepsWindows, savedWindows: .restored, expecting: ["elsewhere.txt"])
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "the restored window lost its second pane")
        waitForItem("elsewhere.txt", inPane: 0)
        waitForItem("alpha.txt", inPane: 1)
    }
}
