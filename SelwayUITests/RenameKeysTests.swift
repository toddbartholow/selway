import XCTest

/// Return and ⌘O / ⌘↓ on the selection, as in Finder (#26). Return starts
/// renaming the one item selected: in the list's row (List view, grouped or
/// not) or with a name prompt (Icons view, as its context menu's Rename does).
/// Return there commits the new name and Escape cancels it. Return with
/// several items selected does nothing. ⌘O and ⌘↓ open the selection, as a
/// double-click does. Columns view's search results rename with the prompt;
/// the column browser's keys are in ColumnsKeyboardTests. XCUITest can't hold
/// a key down to repeat it, so what a held Return does (ReturnRepeatGuard, in
/// ListView.swift) isn't tested here.
final class RenameKeysTests: SelwayUITestCase {

    private let grouped: [String: Any] = ["selwayGroupBy": "Date Modified"]
    private let icons: [String: Any] = ["selwayViewMode": "icons"]

    private func press(_ key: XCUIKeyboardKey, _ modifiers: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(key, modifierFlags: modifiers)
    }

    private func press(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags) {
        app.typeKey(key, modifierFlags: modifiers)
    }

    /// The list's inline rename field.
    private var renameField: XCUIElement { fileList.textFields.firstMatch }

    /// The name prompt's field (Icons view), whether AppKit shows the prompt
    /// as a dialog or a sheet.
    private var promptField: XCUIElement? {
        for field in [app.dialogs.textFields.firstMatch, app.sheets.textFields.firstMatch] where field.exists {
            return field
        }
        return nil
    }

    /// Waits for the inline rename field to show `name` and take the keys.
    private func waitForRenameField(showing name: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = renameField
        XCTAssertTrue(field.waitForExistence(timeout: 3), "no rename field appeared", file: file, line: line)
        XCTAssertEqual(field.value as? String, name, file: file, line: line)
        let focused = waitUntil(3) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        XCTAssertTrue(focused, "the rename field didn't take the keys", file: file, line: line)
    }

    /// Waits for the name prompt to show `name` with its field taking the keys
    /// (typing straight away once went to the alert's buttons).
    private func waitForPrompt(showing name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitUntil(5) { self.promptField != nil }, "Return didn't ask for a new name",
                      file: file, line: line)
        XCTAssertEqual(promptField?.value as? String, name, file: file, line: line)
        let focused = waitUntil(3) { (self.promptField?.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        XCTAssertTrue(focused, "the name prompt's field didn't take the keys", file: file, line: line)
    }

    /// Waits a moment and checks that nothing started: no rename field or
    /// prompt, and no window opened (a text file opens in an editor window).
    private func assertNothingHappened(windows: Int, file: StaticString = #filePath, line: UInt = #line) {
        let happened = waitUntil(2) {
            self.renameField.exists || self.promptField != nil || self.app.windows.count != windows
        }
        XCTAssertFalse(happened, "Return with several items selected did something", file: file, line: line)
    }

    /// Selects alpha.txt and gamma.txt.
    private func selectTwoFiles() {
        click(item("alpha.txt"))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .command) { click(item("gamma.txt")) }
        waitForStatus(Self.selection("alpha.txt", "gamma.txt"))
    }

    // MARK: List view

    func testReturnStartsRenamingTheSelectedFile() throws {
        try launchWithStandardFixture()
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))

        press(.return)
        waitForRenameField(showing: "beta.txt")
    }

    func testReturnWhileRenamingCommitsTheNewName() throws {
        try launchWithStandardFixture()
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))
        press(.return)
        waitForRenameField(showing: "beta.txt")

        press("a", .command)
        app.typeText("renamed.txt")
        press(.return)
        XCTAssertTrue(item("renamed.txt").waitForExistence(timeout: 10), "the list doesn't show the new name")
        XCTAssertFalse(renameField.exists, "the rename field stayed open")
        XCTAssertTrue(fixture.exists("renamed.txt"))
        XCTAssertFalse(fixture.exists("beta.txt"))
    }

    func testEscapeCancelsTheRename() throws {
        try launchWithStandardFixture()
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))
        press(.return)
        waitForRenameField(showing: "beta.txt")

        press("a", .command)
        app.typeText("renamed.txt")
        press(.escape)
        XCTAssertTrue(waitUntil(5) { !self.renameField.exists }, "the rename field stayed open")
        XCTAssertTrue(item("beta.txt").waitForExistence(timeout: 5))
        XCTAssertTrue(fixture.exists("beta.txt"))
        XCTAssertFalse(fixture.exists("renamed.txt"))
    }

    /// Only Return itself renames: ⇧Return is left to the list, which takes it
    /// as Open (beta.txt opens in an editor window), as it did before.
    func testShiftReturnOpensRatherThanRenaming() throws {
        try launchWithStandardFixture()
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))
        let windows = app.windows.count

        press(.return, .shift)
        XCTAssertTrue(waitUntil(10) { self.app.windows.count > windows }, "⇧Return didn't open beta.txt")
        XCTAssertFalse(renameField.exists, "⇧Return started a rename")
    }

    func testReturnWithSeveralSelectedDoesNothing() throws {
        try launchWithStandardFixture()
        selectTwoFiles()
        let windows = app.windows.count

        press(.return)
        assertNothingHappened(windows: windows)
        waitForStatus(Self.selection("alpha.txt", "gamma.txt"))
        waitForFolder(Fixture.rootName)
    }

    func testCommandOOpensTheSelectedFolder() throws {
        try launchWithStandardFixture()
        click(item(Fixture.folder))
        waitForStatus("1 selected")
        press("o", .command)
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    func testCommandDownOpensTheSelectedFolder() throws {
        try launchWithStandardFixture()
        click(item(Fixture.folder))
        waitForStatus("1 selected")
        press(.downArrow, .command)
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    /// ⌘O opens a file as a double-click does: a text file in an editor window.
    func testCommandOOpensTheSelectedFile() throws {
        try launchWithStandardFixture()
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))
        let windows = app.windows.count

        press("o", .command)
        XCTAssertTrue(waitUntil(10) { self.app.windows.count > windows }, "⌘O didn't open beta.txt")
        XCTAssertFalse(renameField.exists, "⌘O started a rename")
    }

    // MARK: List view, grouped

    func testReturnRenamesInTheGroupedList() throws {
        try launchWithStandardFixture(defaults: grouped)
        waitForStatus("Grouped by Date Modified")
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))

        press(.return)
        waitForRenameField(showing: "beta.txt")
        press("a", .command)
        app.typeText("renamed.txt")
        press(.return)
        XCTAssertTrue(item("renamed.txt").waitForExistence(timeout: 10), "the list doesn't show the new name")
        XCTAssertTrue(fixture.exists("renamed.txt"))
        XCTAssertFalse(fixture.exists("beta.txt"))
    }

    func testEscapeCancelsTheRenameInTheGroupedList() throws {
        try launchWithStandardFixture(defaults: grouped)
        waitForStatus("Grouped by Date Modified")
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))
        press(.return)
        waitForRenameField(showing: "beta.txt")

        press("a", .command)
        app.typeText("renamed.txt")
        press(.escape)
        XCTAssertTrue(waitUntil(5) { !self.renameField.exists }, "the rename field stayed open")
        XCTAssertTrue(item("beta.txt").waitForExistence(timeout: 5))
        XCTAssertTrue(fixture.exists("beta.txt"))
        XCTAssertFalse(fixture.exists("renamed.txt"))
    }

    func testCommandOOpensTheSelectedFolderInTheGroupedList() throws {
        try launchWithStandardFixture(defaults: grouped)
        waitForStatus("Grouped by Date Modified")
        click(item(Fixture.folder))
        waitForStatus("1 selected")
        press("o", .command)
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    func testReturnWithSeveralSelectedDoesNothingInTheGroupedList() throws {
        try launchWithStandardFixture(defaults: grouped)
        waitForStatus("Grouped by Date Modified")
        selectTwoFiles()
        let windows = app.windows.count

        press(.return)
        assertNothingHappened(windows: windows)
    }

    func testCommandDownOpensTheSelectedFolderInTheGroupedList() throws {
        try launchWithStandardFixture(defaults: grouped)
        waitForStatus("Grouped by Date Modified")
        click(item(Fixture.folder))
        waitForStatus("1 selected")
        press(.downArrow, .command)
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    // MARK: Icons view

    func testReturnAsksForANewNameInIconsView() throws {
        try launchWithStandardFixture(defaults: icons)
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))

        press(.return)
        waitForPrompt(showing: "beta.txt")
        press("a", .command)
        app.typeText("renamed.txt")
        press(.return)
        XCTAssertTrue(waitUntil(5) { self.promptField == nil }, "the rename prompt stayed open")
        XCTAssertTrue(item("renamed.txt").waitForExistence(timeout: 10), "the grid doesn't show the new name")
        XCTAssertTrue(fixture.exists("renamed.txt"))
        XCTAssertFalse(fixture.exists("beta.txt"))
    }

    func testEscapeCancelsTheRenameInIconsView() throws {
        try launchWithStandardFixture(defaults: icons)
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))

        press(.return)
        waitForPrompt(showing: "beta.txt")
        press("a", .command)
        app.typeText("renamed.txt")
        press(.escape)
        XCTAssertTrue(waitUntil(5) { self.promptField == nil }, "the rename prompt stayed open")
        XCTAssertTrue(item("beta.txt").waitForExistence(timeout: 5))
        XCTAssertTrue(fixture.exists("beta.txt"))
        XCTAssertFalse(fixture.exists("renamed.txt"))
    }

    func testReturnWithSeveralSelectedDoesNothingInIconsView() throws {
        try launchWithStandardFixture(defaults: icons)
        selectTwoFiles()
        let windows = app.windows.count

        press(.return)
        assertNothingHappened(windows: windows)
        waitForStatus(Self.selection("alpha.txt", "gamma.txt"))
    }

    func testCommandOAndCommandDownOpenTheSelectedFolderInIconsView() throws {
        try launchWithStandardFixture(defaults: icons)
        click(item(Fixture.folder))
        waitForStatus("1 selected")
        press("o", .command)
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)

        press("[", .command)
        waitForFolder(Fixture.rootName, listing: "beta.txt")
        click(item(Fixture.folder))
        waitForStatus("1 selected")
        press(.downArrow, .command)
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    // MARK: Columns view, search results

    /// Columns view searching the fixture for ".txt": the column browser gives
    /// way to a list of alpha.txt, beta.txt and gamma.txt.
    private func searchInColumns() throws {
        try launchWithStandardFixture()
        click(viewModeSegment("Columns"))
        let column = identified("columnPane")
        XCTAssertTrue(text("alpha.txt", in: column).waitForExistence(timeout: 10),
                      "Columns view doesn't list alpha.txt")
        // ⌘F opens the toolbar's search field with an animation: keys typed
        // before it has focus are lost.
        press("f", .command)
        let field = browserWindow.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F showed no search field")
        XCTAssertTrue(waitUntil(5) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true },
                      "the search field didn't take the keys")
        field.typeText(".txt")
        XCTAssertTrue(waitUntil(10) { !column.exists }, "the search didn't replace the columns")
        for name in Fixture.files.map(\.name) {
            XCTAssertTrue(text(name, in: browserWindow).waitForExistence(timeout: 10), "the results don't list \(name)")
        }
    }

    func testReturnAsksForANewNameInColumnsSearchResults() throws {
        try searchInColumns()
        click(text("beta.txt", in: browserWindow))
        waitForStatus(Self.selection("beta.txt"))

        press(.return)
        waitForPrompt(showing: "beta.txt")
        press("a", .command)
        app.typeText("renamed.txt")
        press(.escape)
        XCTAssertTrue(waitUntil(5) { self.promptField == nil }, "the rename prompt stayed open")
        XCTAssertTrue(fixture.exists("beta.txt"))
        XCTAssertFalse(fixture.exists("renamed.txt"))
    }

    func testReturnWithSeveralSelectedDoesNothingInColumnsSearchResults() throws {
        try searchInColumns()
        click(text("alpha.txt", in: browserWindow))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .command) { click(text("gamma.txt", in: browserWindow)) }
        waitForStatus(Self.selection("alpha.txt", "gamma.txt"))
        let windows = app.windows.count

        press(.return)
        assertNothingHappened(windows: windows)
        waitForStatus(Self.selection("alpha.txt", "gamma.txt"))
    }
}
