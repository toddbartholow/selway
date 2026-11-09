import XCTest

/// VoiceOver hears a file's tags wherever its coloured dots are shown (#52):
/// an element labelled "Tags" whose value is their names, in List, Icons and
/// Columns view, search results and the preview. A tag without a colour draws
/// no dot but is still read; a file without tags has no such element.
final class TagAccessibilityTests: SelwayUITestCase {

    /// beta.txt has a coloured tag and one without a colour; gamma.txt only
    /// the one without (no dot at all); alpha.txt none. A name no Mac gives a
    /// colour of its own.
    private static let uncoloured = "Selway Uncoloured"
    private static let betaTags = "Red, \(uncoloured)"

    private func launchTagged(_ defaults: [String: Any] = [:]) throws {
        try fixture.makeStandardContents()
        try tag(fixture.root.appendingPathComponent("beta.txt"), with: ["Red\n6", "\(Self.uncoloured)\n0"])
        try tag(fixture.root.appendingPathComponent("gamma.txt"), with: ["\(Self.uncoloured)\n0"])
        try launch(defaults: defaults, expecting: Fixture.standardListing)
    }

    /// Launched in List view (the launch waits for its file list), then
    /// switched to Columns view, as LiveUpdateTests does.
    private func launchTaggedInColumns() throws {
        try launchTagged()
        click(viewModeSegment("Columns"))
        XCTAssertTrue(text("alpha.txt", in: firstColumn).waitForExistence(timeout: 10),
                      "Columns view doesn't list alpha.txt")
    }

    /// The first column in Columns view.
    private var firstColumn: XCUIElement { identified("columnPane") }

    func testListRowsReadTheirTags() throws {
        try launchTagged()
        expectTags(Self.betaTags, in: row("beta.txt", in: fileList), "beta.txt's row")
        expectTags(Self.uncoloured, in: row("gamma.txt", in: fileList), "gamma.txt's row")
        XCTAssertFalse(tags(in: row("alpha.txt", in: fileList)).exists, "alpha.txt's row reads tags it hasn't got")
    }

    func testIconsReadTheirTags() throws {
        try launchTagged(["selwayViewMode": "icons"])
        expectTags(Self.betaTags, in: labelled("beta.txt", in: fileList), "beta.txt's icon")
        expectTags(Self.uncoloured, in: labelled("gamma.txt", in: fileList), "gamma.txt's icon")
        XCTAssertFalse(tags(in: labelled("alpha.txt", in: fileList)).exists, "alpha.txt's icon reads tags it hasn't got")
    }

    /// Columns rows read their tags (since #51, now from the dots' own view),
    /// a colourless one included, and say which is selected, as icons do.
    func testColumnRowsReadTheirTagsAndSelection() throws {
        try launchTaggedInColumns()
        let column = firstColumn
        let gamma = labelled("gamma.txt", in: column)
        expectTags(Self.betaTags, in: labelled("beta.txt", in: column), "beta.txt's column row")
        expectTags(Self.uncoloured, in: gamma, "gamma.txt's column row")
        XCTAssertFalse(gamma.isSelected, "gamma.txt's row is selected before it's clicked")
        click(text("gamma.txt", in: column))
        waitForStatus(Self.selection("gamma.txt"))
        XCTAssertTrue(waitUntil(5) { gamma.isSelected }, "gamma.txt's column row doesn't say it's selected")
    }

    /// Search results in Columns view are a list of their own (not the columns).
    func testSearchResultsInColumnsViewReadTheirTags() throws {
        try launchTaggedInColumns()
        app.typeKey("f", modifierFlags: .command)
        let field = browserWindow.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F showed no search field")
        XCTAssertTrue(waitUntil(5) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true },
                      "the search field didn't take the keys")
        field.typeText("beta")
        waitForStatus("1 found for")
        expectTags(Self.betaTags, in: row("beta.txt", in: browserWindow), "beta.txt's search result")
    }

    func testThePreviewReadsTheSelectedFilesTags() throws {
        try launchTagged(["selwayShowPreview": true])
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))
        expectTags(Self.betaTags, count: 2, "the preview of beta.txt (as well as its row)")
    }

    func testTheColumnsPreviewReadsTheSelectedFilesTags() throws {
        try launchTaggedInColumns()
        click(text("beta.txt", in: firstColumn))
        waitForStatus(Self.selection("beta.txt"))
        expectTags(Self.betaTags, count: 2, "the preview column of beta.txt (as well as its row)")
    }

    // MARK: Helpers

    private static let tagsElement = NSPredicate(format: "label == 'Tags'")

    /// The "Tags" element inside `holder`.
    private func tags(in holder: XCUIElement) -> XCUIElement {
        holder.descendants(matching: .any).matching(Self.tagsElement).firstMatch
    }

    /// The element labelled `name` in `container` that holds a "Tags" element:
    /// an icon, or a column row's content (not the name's own text, nor the
    /// list's own row, whose selection doesn't need the item's trait).
    private func labelled(_ name: String, in container: XCUIElement) -> XCUIElement {
        let item = NSPredicate(format: "label == %@ AND elementType != %lu AND elementType != %lu", name,
                               XCUIElement.ElementType.tableRow.rawValue,
                               XCUIElement.ElementType.outlineRow.rawValue)
        return container.descendants(matching: .any).matching(item).containing(Self.tagsElement).firstMatch
    }

    private func expectTags(_ value: String, in holder: XCUIElement, _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let element = tags(in: holder)
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(what) has no Tags element", file: file, line: line)
        XCTAssertEqual(element.value as? String, value, "\(what) reads the wrong tags", file: file, line: line)
    }

    /// `count` "Tags" elements reading `value` in the window.
    private func expectTags(_ value: String, count: Int, _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let matches = browserWindow.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Tags' AND value == %@", value))
        XCTAssertTrue(waitUntil(10) { matches.count == count },
                      "\(what): \(matches.count) Tags elements read “\(value)”, not \(count)", file: file, line: line)
    }
}
