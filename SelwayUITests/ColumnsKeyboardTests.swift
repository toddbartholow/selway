import XCTest

/// Columns view with the keyboard (#11), as in Finder: ↑/↓ move within a
/// column, → goes into the selected folder, ← goes back to it, typing a name
/// selects it, ⌘A selects the column, Return renames (and with several items
/// selected does nothing), ⌘↓ and ⌘O go into a folder. Clicks replace the
/// selection. The status bar shows the window's selection, which is what Copy,
/// Delete and Quick Look act on.
///
/// The fixture's root lists, in order: subfolder (inner.txt, inner2.txt),
/// zfolder, alpha.txt, beta.txt, gamma.txt. zfolder isn't first, so ← keeping
/// its selection is told apart from ← selecting the column's first item.
final class ColumnsKeyboardTests: SelwayUITestCase {

    private static let secondFolder = "zfolder"
    private static let secondInner = "z-inner.txt"
    /// A second file in subfolder, after inner.txt (10 bytes).
    private static let innerFile2 = "inner2.txt"

    private var firstColumn: XCUIElement {
        browserWindow.descendants(matching: .any).matching(identifier: "columnPane").firstMatch
    }

    private func launchInColumns() throws {
        try fixture.makeStandardContents()
        let folder = try fixture.makeFolder(Self.secondFolder)
        try fixture.makeFile(Self.secondInner, size: 20, in: folder)
        try fixture.makeFile(Self.innerFile2, size: 30, in: fixture.root.appendingPathComponent(Fixture.folder))
        try launch(expecting: [Fixture.folder, Self.secondFolder] + Fixture.files.map(\.name))
        click(viewModeSegment("Columns"))
        XCTAssertTrue(text("alpha.txt", in: firstColumn).waitForExistence(timeout: 10),
                      "Columns view doesn't list alpha.txt")
    }

    private func press(_ key: XCUIKeyboardKey, _ modifiers: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(key, modifierFlags: modifiers)
    }

    /// Whether a column shows `name` (a file inside a folder's column).
    private func columnShows(_ name: String) -> XCUIElement {
        text(name, in: browserWindow)
    }

    func testArrowKeysMoveThroughTheColumns() throws {
        try launchInColumns()
        click(text("alpha.txt", in: firstColumn))
        waitForStatus(Self.selection("alpha.txt"))

        press(.downArrow)
        waitForStatus(Self.selection("beta.txt"))

        // Up past alpha.txt onto zfolder: its contents show as the next column.
        press(.upArrow)
        press(.upArrow)
        waitForFolder(Self.secondFolder)
        XCTAssertTrue(columnShows(Self.secondInner).waitForExistence(timeout: 10),
                      "selecting zfolder didn't show its column")

        // → goes into zfolder and selects its first item.
        press(.rightArrow)
        waitForStatus("1 selected — 20 bytes")

        // ← comes back to zfolder, which stays selected with its column shown.
        press(.leftArrow)
        waitForFolder(Self.secondFolder)
        XCTAssertFalse(waitUntil(2) { !self.columnShows(Self.secondInner).exists },
                       "← closed zfolder's column")
        XCTAssertFalse(statusText.contains("selected"), "← left “\(statusText)” selected")

        // ↓ from zfolder goes on to alpha.txt, so ← kept zfolder selected.
        press(.downArrow)
        waitForStatus(Self.selection("alpha.txt"))
        waitForFolder(Fixture.rootName)
        XCTAssertFalse(waitUntil(2) { self.columnShows(Self.secondInner).exists },
                       "zfolder's column stayed after alpha.txt was selected")
    }

    func testTypingANameSelectsIt() throws {
        try launchInColumns()
        click(text("alpha.txt", in: firstColumn))
        waitForStatus(Self.selection("alpha.txt"))

        app.typeText("g")
        waitForStatus(Self.selection("gamma.txt"))
        // After a pause, a new query.
        Thread.sleep(forTimeInterval: 1.3)
        app.typeText("be")
        waitForStatus(Self.selection("beta.txt"))
    }

    func testShiftDownExtendsTheSelectionWithoutOpeningAColumn() throws {
        try launchInColumns()
        click(text("alpha.txt", in: firstColumn))
        waitForStatus(Self.selection("alpha.txt"))

        press(.downArrow, .shift)
        press(.downArrow, .shift)
        waitForStatus(Self.selection("alpha.txt", "beta.txt", "gamma.txt"))
        waitForFolder(Fixture.rootName)
    }

    func testSelectAllSelectsTheFocusedColumn() throws {
        try launchInColumns()
        click(text(Fixture.folder, in: firstColumn))
        XCTAssertTrue(columnShows(Fixture.innerFile).waitForExistence(timeout: 10))
        press(.rightArrow)
        waitForStatus("1 selected — 10 bytes")

        // Only subfolder's column: nothing hidden in the first column is selected.
        app.typeKey("a", modifierFlags: .command)
        waitForStatus("2 selected — 40 bytes")
        waitForFolder(Fixture.folder)

        // Back in the first column, ⌘A selects its five items and closes the
        // column to its right.
        press(.leftArrow)
        waitForFolder(Fixture.folder)
        app.typeKey("a", modifierFlags: .command)
        waitForStatus("5 selected")
        waitForFolder(Fixture.rootName)
        XCTAssertFalse(waitUntil(2) { self.columnShows(Fixture.innerFile).exists },
                       "subfolder's column stayed after ⌘A in the first column")
    }

    func testAClickReplacesTheSelection() throws {
        try launchInColumns()
        click(text("alpha.txt", in: firstColumn))
        waitForStatus(Self.selection("alpha.txt"))
        click(text("gamma.txt", in: firstColumn))
        waitForStatus(Self.selection("gamma.txt"))
    }

    func testCommandClickAddsToTheSelection() throws {
        try launchInColumns()
        click(text("alpha.txt", in: firstColumn))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .command) { click(text("gamma.txt", in: firstColumn)) }
        waitForStatus(Self.selection("alpha.txt", "gamma.txt"))
    }

    func testShiftClickExtendsFromTheRowLastClicked() throws {
        try launchInColumns()
        click(text("gamma.txt", in: firstColumn))
        waitForStatus(Self.selection("gamma.txt"))
        XCUIElement.perform(withKeyModifiers: .shift) { click(text("alpha.txt", in: firstColumn)) }
        waitForStatus(Self.selection("alpha.txt", "beta.txt", "gamma.txt"))
        waitForFolder(Fixture.rootName)
    }

    /// A paste selects the copy in the window (what ⌘⌫ would trash): the column
    /// must highlight it too, not the file copied.
    func testAPastedCopyIsTheHighlightedSelection() throws {
        try launchInColumns()
        click(text("alpha.txt", in: firstColumn))
        waitForStatus(Self.selection("alpha.txt"))
        app.typeKey("c", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)
        let copy = "alpha copy.txt"
        XCTAssertTrue(text(copy, in: firstColumn).waitForExistence(timeout: 10), "the paste made no copy")
        waitForStatus("6 items, 1 selected — 100 bytes")
        XCTAssertTrue(waitUntil(5) { self.row(copy, in: self.firstColumn).isSelected },
                      "the copy is the window's selection but isn't highlighted")
        XCTAssertFalse(row("alpha.txt", in: firstColumn).isSelected, "alpha.txt still looks selected")
    }

    func testReturnRenamesTheSelectedFile() throws {
        try launchInColumns()
        click(text("beta.txt", in: firstColumn))
        waitForStatus(Self.selection("beta.txt"))

        press(.return)
        let field = app.dialogs.textFields.firstMatch
        let sheetField = app.sheets.textFields.firstMatch
        XCTAssertTrue(waitUntil(5) { field.exists || sheetField.exists }, "Return didn't ask for a new name")
        let shown = field.exists ? field : sheetField
        XCTAssertEqual(shown.value as? String, "beta.txt")
        press(.escape)
        XCTAssertTrue(waitUntil(5) { !field.exists && !sheetField.exists }, "the rename prompt stayed open")
        XCTAssertTrue(fixture.exists("beta.txt"))
    }

    /// The prompt's field takes what's typed straight away. It once kept the
    /// keys from the field (the prompt, run after the key from a main-queue
    /// block, never focused it), so Return kept the old name.
    func testReturnRenameKeepsTheNameTyped() throws {
        try launchInColumns()
        click(text("beta.txt", in: firstColumn))
        waitForStatus(Self.selection("beta.txt"))

        press(.return)
        let field = app.dialogs.textFields.firstMatch
        let sheetField = app.sheets.textFields.firstMatch
        XCTAssertTrue(waitUntil(5) { field.exists || sheetField.exists }, "Return didn't ask for a new name")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("renamed.txt")
        press(.return)
        XCTAssertTrue(text("renamed.txt", in: firstColumn).waitForExistence(timeout: 10),
                      "the column doesn't show the new name")
        XCTAssertTrue(fixture.exists("renamed.txt"))
        XCTAssertFalse(fixture.exists("beta.txt"))
    }

    /// As in Finder: no prompt, nothing opened.
    func testReturnWithSeveralSelectedDoesNothing() throws {
        try launchInColumns()
        click(text("alpha.txt", in: firstColumn))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .command) { click(text("gamma.txt", in: firstColumn)) }
        waitForStatus(Self.selection("alpha.txt", "gamma.txt"))
        let windows = app.windows.count

        press(.return)
        let happened = waitUntil(2) {
            self.app.dialogs.textFields.firstMatch.exists || self.app.sheets.textFields.firstMatch.exists
                || self.app.windows.count != windows
        }
        XCTAssertFalse(happened, "Return with several items selected did something")
        waitForStatus(Self.selection("alpha.txt", "gamma.txt"))
    }

    /// ⌘↓ and ⌘O go into the selected folder, as → does, selecting its first item.
    func testCommandDownAndCommandOGoIntoTheSelectedFolder() throws {
        try launchInColumns()
        click(text(Fixture.folder, in: firstColumn))
        XCTAssertTrue(columnShows(Fixture.innerFile).waitForExistence(timeout: 10))

        press(.downArrow, .command)
        waitForStatus("1 selected — 10 bytes")
        waitForFolder(Fixture.folder)

        press(.leftArrow)
        XCTAssertTrue(waitUntil(5) { !self.statusText.contains("selected") }, "← left “\(statusText)” selected")
        app.typeKey("o", modifierFlags: .command)
        waitForStatus("1 selected — 10 bytes")
        waitForFolder(Fixture.folder)
    }
}
