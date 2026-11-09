import XCTest

/// New Folder and the toolbar's view-mode picker.
final class ToolbarTests: SelwayUITestCase {

    /// ⌥⌘N makes a folder in the folder shown, beside the selection, as in
    /// Finder, even when the selection is a folder: it once went inside the
    /// selected folder and then took the window there (see ShellNewItemTarget).
    /// How it's named (today a name prompt, perhaps Finder's inline rename
    /// later) is left open: both are accepted.
    func testNewFolderCreatesAFolderBesideTheSelectionAndStartsNamingIt() throws {
        try launchWithStandardFixture()
        click(item(Fixture.folder))              // the window has focus; a folder is selected
        waitForStatus("1 selected")
        let before = fixture.allFolders()

        app.typeKey("n", modifierFlags: [.command, .option])

        let create = app.buttons.matching(Self.named("Create")).firstMatch
        if create.waitForExistence(timeout: 5) {
            // The name prompt, its field filled in with a name to accept or change.
            let field = app.textFields.matching(NSPredicate(format: "value == %@", "New Folder")).firstMatch
            XCTAssertTrue(field.exists, "the New Folder prompt has no name field")
            create.click()
        } else {
            let field = fileList.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5),
                          "New Folder neither asked for a name nor started renaming the new folder")
            app.typeKey(.return, modifierFlags: [])
        }

        var added = Set<String>()
        let appeared = waitUntil(10) {
            added = self.fixture.allFolders().subtracting(before)
            return !added.isEmpty
        }
        XCTAssertTrue(appeared, "no folder appeared in the fixture")
        guard let path = added.first else { return }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        XCTAssertEqual(parent, fixture.root.path,
                       "the new folder went into \(parent), not the folder shown (beside the selected “\(Fixture.folder)”)")
        XCTAssertEqual(shownFolderName, Fixture.rootName, "New Folder took the window to another folder")
        let name = URL(fileURLWithPath: path).lastPathComponent
        XCTAssertTrue(item(name).waitForExistence(timeout: 10), "the new folder “\(name)” isn't listed")
    }

    /// Guards the toolbar fix (5dc0b08): the toolbar is no longer rebuilt on every
    /// change, so the picker must update itself when ⌘1 / ⌘2 / ⌘3 change the view.
    func testViewModePickerFollowsTheKeyboardShortcuts() throws {
        try launchWithStandardFixture()
        click(item("alpha.txt"))                 // keyboard focus in the browser window
        assertPicker(shows: "List")

        app.typeKey("1", modifierFlags: .command)
        assertPicker(shows: "Icons")
        app.typeKey("3", modifierFlags: .command)
        assertPicker(shows: "Columns")
        app.typeKey("2", modifierFlags: .command)
        assertPicker(shows: "List")
        XCTAssertTrue(item("alpha.txt").waitForExistence(timeout: 10), "List view didn't come back")
    }

    // MARK: Helpers

    /// The picker's segments in order (Finder's: Icons, List, Columns).
    private static let modes = ["Icons", "List", "Columns"]

    private var viewModePicker: XCUIElement {
        let picker = identified("viewModePicker")
        return picker.exists ? picker : browserWindow.toolbars.radioGroups.firstMatch
    }

    private func segment(_ mode: String) -> XCUIElement {
        let picker = viewModePicker
        for candidates in [picker.radioButtons, picker.buttons] {
            let named = candidates.matching(Self.named(mode)).firstMatch
            if named.exists { return named }
        }
        return picker.radioButtons.element(boundBy: Self.modes.firstIndex(of: mode) ?? 0)
    }

    private func assertPicker(shows mode: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(viewModePicker.waitForExistence(timeout: 10), "no view-mode picker in the toolbar",
                      file: file, line: line)
        let shown = waitUntil(5) {
            Self.modes.allSatisfy { Self.isOn(self.segment($0)) == ($0 == mode) }
        }
        let on = Self.modes.filter { Self.isOn(segment($0)) }
        XCTAssertTrue(shown, "the picker shows \(on) instead of \(mode)", file: file, line: line)
    }
}
