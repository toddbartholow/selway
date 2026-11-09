import XCTest

/// Clicking in List view, ungrouped (a SwiftUI Table). Ported from the click
/// scripts used to check the row-level drag fix: clicks on a name or an icon
/// used to be taken by the cell's own drag and neither selected nor opened.
final class ListViewTests: SelwayUITestCase {

    func testClickOnANameSelectsTheFile() throws {
        try launchWithStandardFixture()
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))
        XCTAssertTrue(row("beta.txt", in: fileList).isSelected, "beta.txt's row isn't highlighted")
        XCTAssertFalse(row("alpha.txt", in: fileList).isSelected)
    }

    func testDoubleClickOnAFolderNameOpensIt() throws {
        try launchWithStandardFixture()
        doubleClick(item(Fixture.folder))
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    func testDoubleClickOnAFolderIconOpensIt() throws {
        try launchWithStandardFixture()
        iconPoint(of: Fixture.folder).doubleClick()
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    func testDoubleClickInTheDateModifiedColumnOpensTheFolder() throws {
        try launchWithStandardFixture()
        dateModifiedPoint(of: Fixture.folder).doubleClick()
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    func testCommandClickAddsToTheSelection() throws {
        try launchWithStandardFixture()
        click(item("alpha.txt"))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .command) { click(item("gamma.txt")) }
        waitForStatus(Self.selection("alpha.txt", "gamma.txt"))
        XCTAssertTrue(row("alpha.txt", in: fileList).isSelected)
        XCTAssertFalse(row("beta.txt", in: fileList).isSelected, "⌘-click selected the rows in between")
        XCTAssertTrue(row("gamma.txt", in: fileList).isSelected)
    }

    func testShiftClickExtendsTheSelection() throws {
        try launchWithStandardFixture()
        click(item("alpha.txt"))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .shift) { click(item("gamma.txt")) }
        waitForStatus(Self.selection("alpha.txt", "beta.txt", "gamma.txt"))
        XCTAssertTrue(row("beta.txt", in: fileList).isSelected, "⇧-click didn't take in the row between")
    }

    /// Kind reads as Finder's does, not as "TXT File".
    func testKindReadsLikeFinders() throws {
        try launchWithStandardFixture()
        let beta = row("beta.txt", in: fileList)
        XCTAssertTrue(text("Plain Text Document", in: beta).waitForExistence(timeout: 5),
                      "beta.txt's Kind isn't Plain Text Document")
        XCTAssertFalse(text("TXT File", in: beta).exists)
        XCTAssertTrue(text("Folder", in: row(Fixture.folder, in: fileList)).exists,
                      "\(Fixture.folder)'s Kind isn't Folder")
    }

    // MARK: Helpers

    /// A point in `name`'s row, in the Date Modified column: the row's second
    /// cell when the row exposes one cell per column, else below the column's
    /// header.
    private func dateModifiedPoint(of name: String, file: StaticString = #filePath,
                                   line: UInt = #line) -> XCUICoordinate {
        let label = item(name)
        XCTAssertTrue(label.waitForExistence(timeout: 10), "“\(name)” isn't listed", file: file, line: line)
        var x: CGFloat?
        let cells = row(name, in: fileList).cells
        if cells.count >= 6 {               // Name, Date Modified, Date Created, Size, Kind, Extension
            x = cells.element(boundBy: 1).frame.midX
        } else {
            let header = browserWindow.buttons.matching(Self.named("Date Modified")).firstMatch
            if header.exists { x = header.frame.midX }
        }
        guard let x else {
            XCTFail("can't find the Date Modified column", file: file, line: line)
            return middle(of: label)
        }
        XCTAssertGreaterThan(x, label.frame.maxX, "the Date Modified point isn't right of the name",
                             file: file, line: line)
        return windowPoint(x: x, y: label.frame.midY)
    }
}
