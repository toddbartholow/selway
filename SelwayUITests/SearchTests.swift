import XCTest

/// The toolbar's search field (Edit ▸ Find…, ⌘F) and the scope bar under it:
/// results replace the listing and the status bar counts them, a scope change
/// searches again, Escape clears the search and lists the folder again, and ↓
/// moves from the field to the results (ToolbarSearchField.installKeys).
///
/// Only the fixture is ever searched: every test starts in This Folder (set
/// explicitly, not left to Settings) and moves at most to This Folder &
/// Subfolders. The Spotlight scopes (Desktop … Entire Mac) aren't chosen.
final class SearchTests: SelwayUITestCase {

    func testTypingAQueryListsTheResultsAndCountsThem() throws {
        try launchSearchFixture()
        search("beta")
        waitForStatus("1 found for “beta” in This Folder")
        waitForStatus("1 item")
        XCTAssertTrue(item("beta.txt").waitForExistence(timeout: 10), "the results don't list beta.txt")
        for name in ["alpha.txt", "gamma.txt", Fixture.folder] {
            XCTAssertTrue(waitUntil(5) { !self.item(name).exists }, "the results list \(name), which doesn't match")
        }
    }

    /// inner.txt is in the subfolder: not found in This Folder, found in This
    /// Folder & Subfolders, and gone again back in This Folder.
    func testChangingTheScopeSearchesAgain() throws {
        try launchSearchFixture()
        search("inner")
        waitForStatus("No results for “inner” in This Folder")

        chooseScope("This Folder & Subfolders")
        waitForStatus("1 found for “inner” in This Folder & Subfolders")
        XCTAssertTrue(item(Fixture.innerFile).waitForExistence(timeout: 10),
                      "This Folder & Subfolders doesn't list \(Fixture.innerFile)")

        chooseScope("This Folder")
        waitForStatus("No results for “inner” in This Folder")
        XCTAssertTrue(waitUntil(5) { !self.item(Fixture.innerFile).exists },
                      "This Folder still lists \(Fixture.innerFile)")
    }

    /// Escape in the field clears it and the search: the folder's own items
    /// come back, with the status bar's sort line in place of the count found.
    func testEscapeClearsTheSearchAndListsTheFolderAgain() throws {
        try launchSearchFixture()
        let field = search("beta")
        waitForStatus("1 found for “beta” in This Folder")

        app.typeKey(.escape, modifierFlags: [])
        waitForListing(Fixture.standardListing)
        waitForStatus("Sorted by Name")
        XCTAssertFalse(statusText.contains("found for"), "the status bar still counts results: “\(statusText)”")
        let value = field.value as? String ?? ""
        XCTAssertFalse(value.contains("beta"), "the search field still holds “\(value)”")
    }

    /// ↓ in the field gives the results the keys: the next ↓ selects the
    /// first of them, which it wouldn't in the field (the field keeps ↓).
    func testDownArrowMovesFromTheFieldToTheResults() throws {
        try launchSearchFixture()
        let field = search(".txt")
        waitForStatus("\(Fixture.files.count) found for “.txt” in This Folder")
        for name in Fixture.files.map(\.name) {
            XCTAssertTrue(item(name).waitForExistence(timeout: 10), "the results don't list \(name)")
        }
        XCTAssertFalse(statusText.contains("selected"), "something is selected before ↓: “\(statusText)”")

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { (field.value(forKey: "hasKeyboardFocus") as? Bool) != true },
                      "↓ left the keys in the search field")

        app.typeKey(.downArrow, modifierFlags: [])
        waitForStatus(Self.selection("alpha.txt"))
        waitForStatus("\(Fixture.files.count) found for “.txt” in This Folder")
    }

    // MARK: Helpers

    /// The standard fixture, with searches starting in This Folder.
    private func launchSearchFixture(file: StaticString = #filePath, line: UInt = #line) throws {
        try launchWithStandardFixture(defaults: ["selwaySearchDefaultScope": "This Folder"], file: file, line: line)
    }

    /// Focuses the search field with ⌘F and types `query`. Returns the field.
    @discardableResult
    private func search(_ query: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        // ⌘F opens the toolbar's search field with an animation: keys typed
        // before it has focus are lost.
        app.typeKey("f", modifierFlags: .command)
        let field = browserWindow.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F showed no search field", file: file, line: line)
        XCTAssertTrue(waitUntil(5) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true },
                      "the search field didn't take the keys", file: file, line: line)
        field.typeText(query)
        return field
    }

    /// Clicks `scope` in the scope bar shown under the toolbar while searching:
    /// a button for each scope, labelled "Search, <scope>" (macOS 26).
    private func chooseScope(_ scope: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = browserWindow.buttons.matching(NSPredicate(format: "label == %@", "Search, \(scope)")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no scope bar shows “\(scope)”", file: file, line: line)
        click(button, file: file, line: line)
    }
}
