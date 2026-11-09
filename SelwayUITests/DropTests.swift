import XCTest

/// Files dropped on a window. Finder can't be scripted from here without
/// driving the user's own Finder windows, so the file comes from a second
/// Selway window: a row drag carries the same file URL a Finder drag does.
/// The UI-test hooks tile the two windows side by side so neither covers the
/// other.
final class DropTests: SelwayUITestCase {

    /// A file dropped on a window's file list goes into the folder it shows.
    /// Both windows are on one volume, so the drop moves it, as in Finder.
    func testDroppingAFileOnAnotherWindowMovesItThere() throws {
        let target = try fixture.makeSibling("DropTarget")
        try launchWithStandardFixture(defaults: ["selwayNewWindowCustomFolder": target.path])

        // File ▸ New Window opens at the "new windows open" folder: DropTarget.
        app.typeKey("n", modifierFlags: .command)
        let targetWindow = app.windows.matching(NSPredicate(format: "title == %@", "DropTarget")).firstMatch
        XCTAssertTrue(targetWindow.waitForExistence(timeout: 10), "no second window on DropTarget")
        let targetList = identified("fileList", in: targetWindow)
        XCTAssertTrue(targetList.waitForExistence(timeout: 10), "the second window has no file list")

        let sourceWindow = app.windows.matching(NSPredicate(format: "title == %@", Fixture.rootName)).firstMatch
        let alpha = item("alpha.txt", in: identified("fileList", in: sourceWindow))
        click(alpha)                             // brings the source window forward; the target stays visible
        XCTAssertTrue(waitUntil(5) { !targetWindow.frame.intersects(alpha.frame) },
                      "the second window covers alpha.txt")

        alpha.click(forDuration: 0.8, thenDragTo: targetList)

        let arrived = waitUntil(10) { self.fixture.exists("alpha.txt", in: target) }
        XCTAssertTrue(arrived, "alpha.txt wasn't moved into DropTarget")
        XCTAssertFalse(fixture.exists("alpha.txt"),
                       "alpha.txt is still in \(Fixture.rootName): the drop copied it instead of moving it")
        XCTAssertTrue(item("alpha.txt", in: targetList).waitForExistence(timeout: 10),
                      "DropTarget's window doesn't list alpha.txt")
    }

    // MARK: File promises

    /// Issue #29: a drag that carries file promises rather than files (a Mail
    /// attachment, a photo from Photos, an image from Safari) was refused. The
    /// promises come from a panel in the app (UITestPromiseSource), which
    /// writes them as those apps do, through NSFilePromiseProvider.
    func testDroppingFilePromisesWritesTheFilesIntoTheFolder() throws {
        try fixture.makeStandardContents()
        try launch(promisedFiles: ["promised.txt", "alpha.txt"], expecting: Fixture.standardListing)

        try dragPromises()

        // alpha.txt is taken: the promised one gets a free name, as a copy does.
        let arrived = waitUntil(10) { self.fixture.exists("promised.txt") && self.fixture.exists("alpha 2.txt") }
        let found = ((try? FileManager.default.contentsOfDirectory(atPath: fixture.root.path)) ?? []).sorted()
        XCTAssertTrue(arrived, "\(Fixture.rootName) holds \(found), not promised.txt and alpha 2.txt")
        let alpha = try FileManager.default.attributesOfItem(atPath: fixture.root.appendingPathComponent("alpha.txt").path)
        XCTAssertEqual((alpha[.size] as? NSNumber)?.intValue, 100, "the promise wrote over alpha.txt")
        // Both new files are listed and selected.
        XCTAssertTrue(item("promised.txt").waitForExistence(timeout: 10), "the list doesn't show promised.txt")
        waitForStatus("2 selected")
    }

    /// A promise its source fails to write is reported, and nothing is left behind.
    func testAFilePromiseThatFailsIsReported() throws {
        try fixture.makeStandardContents()
        try launch(promisedFiles: ["fail:broken.txt"], expecting: Fixture.standardListing)

        try dragPromises()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no error for the promise that failed")
        let naming = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "broken.txt", "broken.txt")
        XCTAssertTrue(sheet.staticTexts.matching(naming).firstMatch.waitForExistence(timeout: 5),
                      "the error doesn't name broken.txt")
        XCTAssertFalse(fixture.exists("broken.txt"), "a promise that failed left broken.txt in the folder")
    }

    /// Drags the promise source panel's files onto the empty space below the
    /// list's rows.
    private func dragPromises(file: StaticString = #filePath, line: UInt = #line) throws {
        let source = app.descendants(matching: .any).matching(identifier: "promiseSource").firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), "no promise source panel", file: file, line: line)
        let list = fileList.frame
        let point = CGPoint(x: list.midX, y: list.minY + list.height * 0.8)
        let panel = app.windows.matching(NSPredicate(format: "title == %@", "Promise Source")).firstMatch
        guard !panel.frame.contains(point) else {
            throw XCTSkip("the promise source panel covers the file list on this screen")
        }
        middle(of: source).click(forDuration: 0.8, thenDragTo: windowPoint(x: point.x, y: point.y))
    }
}
