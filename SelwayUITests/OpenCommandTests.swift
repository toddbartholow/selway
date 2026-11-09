import XCTest

/// File ▸ Open (⌘O, #39), as in Finder: enabled only with something selected,
/// and opening the selection as ⌘O does in each view. List and Icons view open
/// a folder in the window; Columns view goes into it as the next column,
/// selecting its first item (as →). ⌘O while text has focus (the inline
/// rename, the search field) stays the text's. The keys themselves are in
/// RenameKeysTests and ColumnsKeyboardTests.
final class OpenCommandTests: SelwayUITestCase {

    private let icons: [String: Any] = ["selwayViewMode": "icons"]

    /// The File menu's Open item, with the menu open.
    private func openMenuItem(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let menu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "no File menu", file: file, line: line)
        menu.click()
        let item = menu.menuItems["Open"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the File menu has no Open", file: file, line: line)
        return item
    }

    /// Chooses File ▸ Open with the mouse.
    private func chooseOpen(file: StaticString = #filePath, line: UInt = #line) {
        let item = openMenuItem(file: file, line: line)
        XCTAssertTrue(item.isEnabled, "File ▸ Open is disabled", file: file, line: line)
        item.click()
    }

    /// Checks File ▸ Open is disabled, and closes the menu.
    private func assertOpenDisabled(file: StaticString = #filePath, line: UInt = #line) {
        let item = openMenuItem(file: file, line: line)
        XCTAssertFalse(item.isEnabled, "File ▸ Open is enabled with nothing selected", file: file, line: line)
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: List view

    func testOpenOpensTheSelectedFolderInListView() throws {
        try launchWithStandardFixture()
        assertOpenDisabled()

        click(item(Fixture.folder))
        waitForStatus("1 selected")
        chooseOpen()
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    /// ⌘O in the rename field is the field's: the file doesn't open and the
    /// rename stays open.
    func testCommandOWhileRenamingDoesNotOpen() throws {
        try launchWithStandardFixture()
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))
        app.typeKey(.return, modifierFlags: [])
        let field = fileList.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "no rename field appeared")
        XCTAssertTrue(waitUntil(3) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true },
                      "the rename field didn't take the keys")
        let windows = app.windows.count

        app.typeKey("o", modifierFlags: .command)
        XCTAssertFalse(waitUntil(2) { self.app.windows.count != windows || !field.exists },
                       "⌘O in the rename field opened beta.txt or ended the rename")
        XCTAssertEqual(field.value as? String, "beta.txt")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// ⌘O in the search field is the field's: the selected folder doesn't open.
    func testCommandOInTheSearchFieldDoesNotOpen() throws {
        try launchWithStandardFixture()
        click(item(Fixture.folder))
        waitForStatus("1 selected")
        app.typeKey("f", modifierFlags: .command)
        let field = browserWindow.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F showed no search field")
        XCTAssertTrue(waitUntil(5) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true },
                      "the search field didn't take the keys")

        app.typeKey("o", modifierFlags: .command)
        XCTAssertFalse(waitUntil(2) { self.shownFolderName != Fixture.rootName },
                       "⌘O in the search field opened \(Fixture.folder)")
    }

    /// ⌘O with the sidebar focused opens the list's selection, as File ▸ Open
    /// chosen with the mouse does (Quick Look and Move to Trash act on it there
    /// too). The fixture's folder is pinned: a click on its row, already
    /// highlighted, gives the sidebar the keys without going anywhere.
    func testCommandOWithTheSidebarFocusedOpensTheSelection() throws {
        try fixture.makeStandardContents()
        try launch(defaults: ["pinnedFolders": [fixture.root.path]], expecting: Fixture.standardListing)
        let pinned = text(Fixture.rootName, in: sidebar)
        click(pinned)
        waitForFolder(Fixture.rootName)
        click(item(Fixture.folder))
        waitForStatus("1 selected")

        click(pinned)
        let sidebarFocused = waitUntil(5) {
            (self.sidebar.value(forKey: "hasKeyboardFocus") as? Bool) == true
                || (self.sidebar.outlines.firstMatch.value(forKey: "hasKeyboardFocus") as? Bool) == true
        }
        XCTAssertTrue(sidebarFocused, "the sidebar didn't take the keys")
        XCTAssertEqual(shownFolderName, Fixture.rootName)
        waitForStatus("1 selected")

        app.typeKey("o", modifierFlags: .command)
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    // MARK: Icons view

    func testOpenOpensTheSelectedFolderInIconsView() throws {
        try launchWithStandardFixture(defaults: icons)
        assertOpenDisabled()

        click(item(Fixture.folder))
        waitForStatus("1 selected")
        chooseOpen()
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    // MARK: Columns view

    /// Open goes into the selected folder as the next column, selecting its
    /// first item, as ⌘O and → do. After ← the folder is selected in the first
    /// column while the window's selection is empty: Open is still enabled.
    func testOpenGoesIntoTheSelectedFolderInColumnsView() throws {
        try launchWithStandardFixture()
        click(viewModeSegment("Columns"))
        let firstColumn = browserWindow.descendants(matching: .any).matching(identifier: "columnPane").firstMatch
        XCTAssertTrue(text("alpha.txt", in: firstColumn).waitForExistence(timeout: 10),
                      "Columns view doesn't list alpha.txt")
        assertOpenDisabled()

        click(text(Fixture.folder, in: firstColumn))
        XCTAssertTrue(text(Fixture.innerFile, in: browserWindow).waitForExistence(timeout: 10))
        chooseOpen()
        waitForStatus("1 selected — 10 bytes")
        waitForFolder(Fixture.folder)

        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { !self.statusText.contains("selected") }, "← left “\(statusText)” selected")
        chooseOpen()
        waitForStatus("1 selected — 10 bytes")
        waitForFolder(Fixture.folder)
    }
}
