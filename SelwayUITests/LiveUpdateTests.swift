import XCTest

/// Files that change while they're listed (issues #34, #42): the list's Size
/// column, a column's rows, search results and the status bar's selection total
/// follow a file that grows or is retagged, as in Finder, without the folder
/// being read again by hand, and the selection and the scroll position stay
/// where they were.
final class LiveUpdateTests: SelwayUITestCase {

    func testAppendingToAListedFileUpdatesItsSize() throws {
        try launchWithStandardFixture()
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))           // 200 bytes

        try append(bytes: 300, to: fixture.root.appendingPathComponent("beta.txt"))
        waitForStatus(Self.oneSelected(bytes: 500), timeout: 5)
        let size = row("beta.txt", in: fileList).staticTexts.matching(Self.named("500 bytes")).firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 5), "beta.txt's Size cell didn't follow the file")
        XCTAssertTrue(row("beta.txt", in: fileList).isSelected, "the update dropped the selection")
    }

    func testAGrowingFileKeepsTheScrollPosition() throws {
        let names = (0..<60).map { String(format: "file-%02d.txt", $0) }
        for name in names { try fixture.makeFile(name, size: 100) }
        try launch(expecting: [names[0]], itemCount: names.count)

        // Down to the last file: the list scrolls to keep it in view.
        click(item(names[0]))
        waitForStatus(Self.oneSelected(bytes: 100))
        for _ in names.dropFirst() { app.typeKey(.downArrow, modifierFlags: []) }
        let last = item(names[names.count - 1])
        XCTAssertTrue(waitUntil(10) { last.exists && last.isHittable }, "the list didn't scroll to the last file")
        XCTAssertFalse(item(names[0]).exists && item(names[0]).isHittable, "the list didn't scroll")
        let before = row(names[names.count - 1], in: fileList).frame

        for _ in 0..<3 {
            try append(bytes: 100, to: fixture.root.appendingPathComponent(names[names.count - 1]))
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        waitForStatus(Self.oneSelected(bytes: 400), timeout: 5)
        let after = row(names[names.count - 1], in: fileList).frame
        XCTAssertEqual(after.minY, before.minY, accuracy: 1, "the list scrolled when the file grew")
        XCTAssertTrue(row(names[names.count - 1], in: fileList).isSelected, "the update dropped the selection")
    }

    // MARK: Columns view

    /// The selected file in a column is written to and retagged: its row shows
    /// the tag (only the column's own patch does that), and the status bar
    /// its new size, with the selection kept.
    func testChangingTheSelectedFileInAColumnUpdatesItsRowAndTheStatusBar() throws {
        try launchWithStandardFixture()
        showColumns()
        click(text("beta.txt", in: firstColumn))
        waitForStatus(Self.selection("beta.txt"))           // 200 bytes
        XCTAssertFalse(columnRow("beta.txt", tags: "Red").exists, "beta.txt has a tag to begin with")

        let beta = fixture.root.appendingPathComponent("beta.txt")
        try append(bytes: 300, to: beta)
        try tag(beta, with: ["Red\n6"])
        waitForStatus(Self.oneSelected(bytes: 500), timeout: 5)
        XCTAssertTrue(columnRow("beta.txt", tags: "Red").waitForExistence(timeout: 5),
                      "beta.txt's row didn't show its new tag")
        XCTAssertTrue(row("beta.txt", in: firstColumn).isSelected, "the update dropped the column's selection")
    }

    /// The last of many files, scrolled to and selected, grows and is retagged:
    /// its row updates where it is.
    func testAFileChangingInAColumnKeepsTheScrollPosition() throws {
        let names = (0..<60).map { String(format: "file-%02d.txt", $0) }
        for name in names { try fixture.makeFile(name, size: 100) }
        try launch(expecting: [names[0]], itemCount: names.count)
        showColumns(listing: names[0])

        // Down to the last file: the column scrolls to keep it in view.
        click(text(names[0], in: firstColumn))
        waitForStatus(Self.oneSelected(bytes: 100))
        for _ in names.dropFirst() { app.typeKey(.downArrow, modifierFlags: []) }
        let last = text(names[names.count - 1], in: firstColumn)
        XCTAssertTrue(waitUntil(10) { last.exists && last.isHittable }, "the column didn't scroll to the last file")
        let first = text(names[0], in: firstColumn)
        XCTAssertFalse(first.exists && first.isHittable, "the column didn't scroll")
        let before = row(names[names.count - 1], in: firstColumn).frame

        let file = fixture.root.appendingPathComponent(names[names.count - 1])
        for _ in 0..<3 {
            try append(bytes: 100, to: file)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        try tag(file, with: ["Red\n6"])
        waitForStatus(Self.oneSelected(bytes: 400), timeout: 5)
        XCTAssertTrue(columnRow(names[names.count - 1], tags: "Red").waitForExistence(timeout: 5),
                      "the row didn't show its new tag")
        let after = row(names[names.count - 1], in: firstColumn).frame
        XCTAssertEqual(after.minY, before.minY, accuracy: 1, "the column scrolled when the file changed")
        XCTAssertTrue(row(names[names.count - 1], in: firstColumn).isSelected, "the update dropped the selection")
    }

    // MARK: Search results

    func testAppendingToASearchResultUpdatesItsSize() throws {
        try launchWithStandardFixture()
        search(".txt")
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))

        try append(bytes: 300, to: fixture.root.appendingPathComponent("beta.txt"))
        waitForStatus(Self.oneSelected(bytes: 500), timeout: 5)
        let size = row("beta.txt", in: fileList).staticTexts.matching(Self.named("500 bytes")).firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 5), "beta.txt's Size cell didn't follow the file")
        XCTAssertTrue(row("beta.txt", in: fileList).isSelected, "the update dropped the selection")
    }

    func testAppendingToASearchResultInColumnsViewUpdatesTheStatusBar() throws {
        try launchWithStandardFixture()
        showColumns()
        search(".txt")
        click(text("beta.txt", in: browserWindow))
        waitForStatus(Self.selection("beta.txt"))

        try append(bytes: 300, to: fixture.root.appendingPathComponent("beta.txt"))
        waitForStatus(Self.oneSelected(bytes: 500), timeout: 5)
        XCTAssertTrue(row("beta.txt", in: browserWindow).isSelected, "the update dropped the selection")
    }

    // MARK: Helpers

    /// The first column in Columns view.
    private var firstColumn: XCUIElement {
        browserWindow.descendants(matching: .any).matching(identifier: "columnPane").firstMatch
    }

    /// The first column's row for `name` whose tags (its "Tags" element's
    /// value) are `tags`.
    private func columnRow(_ name: String, tags: String) -> XCUIElement {
        firstColumn.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", name))
            .containing(NSPredicate(format: "label == 'Tags' AND value == %@", tags)).firstMatch
    }

    /// Switches to Columns view and waits for the first column to list `name`.
    private func showColumns(listing name: String = "alpha.txt") {
        click(viewModeSegment("Columns"))
        XCTAssertTrue(text(name, in: firstColumn).waitForExistence(timeout: 10), "Columns view doesn't list \(name)")
    }

    /// Searches the fixture (This Folder) for `query`, which finds the standard
    /// files, and waits for the results (not the folder's own items filtered by
    /// name, shown while the search runs).
    private func search(_ query: String) {
        // ⌘F opens the toolbar's search field with an animation: keys typed
        // before it has focus are lost.
        app.typeKey("f", modifierFlags: .command)
        let field = browserWindow.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F showed no search field")
        XCTAssertTrue(waitUntil(5) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true },
                      "the search field didn't take the keys")
        field.typeText(query)
        waitForStatus("\(Fixture.files.count) found for")
        for name in Fixture.files.map(\.name) {
            XCTAssertTrue(text(name, in: browserWindow).waitForExistence(timeout: 10), "the results don't list \(name)")
        }
    }

    /// What the status bar says for one selected file of `bytes` bytes (under
    /// 1 KB: ByteCountFormatter counts them out), as `selection` does.
    private static func oneSelected(bytes: Int) -> String {
        "1 selected \u{2014} \(bytes) bytes"
    }

    /// Appends `bytes` bytes to the end of `url`, as a download or a log does.
    private func append(bytes: Int, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: UInt8(ascii: "x"), count: bytes))
    }
}
