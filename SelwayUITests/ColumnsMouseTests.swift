import AppKit
import XCTest

/// Clicking and dragging rows in Columns view (#27), where each row has an
/// AppKit view taking its clicks and starting its drags (FileRowMouseView),
/// as the icon grid has (IconsViewTests, DragOutTests).
///
/// The fixture's root lists, in order: subfolder (inner.txt), alpha.txt,
/// beta.txt, gamma.txt.
final class ColumnsMouseTests: SelwayUITestCase {

    private var firstColumn: XCUIElement { identified("columnPane") }

    /// `narrowingWait` stretches the wait before a click inside a selection
    /// narrows it (UITestHooks.narrowingWait), so keys can come within it.
    private func launchInColumns(narrowingWait: TimeInterval? = nil) throws {
        try launchWithStandardFixture(defaults: narrowingWait.map { ["selwayUITestNarrowingWait": $0] } ?? [:])
        click(viewModeSegment("Columns"))
        XCTAssertTrue(text("alpha.txt", in: firstColumn).waitForExistence(timeout: 10),
                      "Columns view doesn't list alpha.txt")
    }

    /// What the fixture's root holds, by name.
    private var rootContents: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: fixture.root.path)) ?? []).sorted()
    }

    /// Regression: a row pressed and moved by a point or two while the button
    /// was down didn't select. SwiftUI's onDrag started a drag at the first
    /// point of movement (common with a trackpad), and the drag took the
    /// click. A press that moves less than a few points is a click, as in
    /// Finder, and starts no drag.
    func testAPressThatMovesALittleSelectsTheRowWithoutDragging() throws {
        try launchInColumns()
        let drags = NSPasteboard(name: .drag).changeCount
        for (name, move) in [("beta.txt", CGVector(dx: 2, dy: 1)), ("gamma.txt", CGVector(dx: -1, dy: 2)),
                             ("alpha.txt", CGVector(dx: 3, dy: 0))] {
            let row = text(name, in: firstColumn)
            XCTAssertTrue(row.waitForExistence(timeout: 10), "“\(name)” isn't listed")
            let start = middle(of: row)
            start.click(forDuration: 0.05, thenDragTo: start.withOffset(move))
            waitForStatus(Self.selection(name), timeout: 5)
        }

        // A folder pressed the same way is selected and shown as the next column.
        let folder = middle(of: text(Fixture.folder, in: firstColumn))
        folder.click(forDuration: 0.05, thenDragTo: folder.withOffset(CGVector(dx: 2, dy: -1)))
        XCTAssertTrue(text(Fixture.innerFile, in: browserWindow).waitForExistence(timeout: 10),
                      "a press on “\(Fixture.folder)” that moved a little didn't show its column")

        // No drag started: the drag pasteboard changes with every drag (if the
        // runner's sandbox hides it, the selections above are the check), and
        // nothing moved.
        XCTAssertEqual(NSPasteboard(name: .drag).changeCount, drags,
                       "a press that moved a few points started a drag")
        XCTAssertEqual(rootContents, Fixture.standardListing.sorted(), "a press that moved a little moved a file")
    }

    /// A press that moves past the threshold still drags, and a drag from one
    /// of several selected rows carries all of them (onDrag's one item
    /// provider carried only the row dragged). Dropped on a folder in the same
    /// column, on the same volume, they move into it.
    func testDraggingSelectedRowsOntoAFolderMovesThemAll() throws {
        try launchInColumns()
        click(text("alpha.txt", in: firstColumn))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .command) { click(text("gamma.txt", in: firstColumn)) }
        waitForStatus(Self.selection("alpha.txt", "gamma.txt"))

        // From gamma.txt, the second of the two: the drag carries the selection,
        // not only the row under the pointer.
        let target = text(Fixture.folder, in: firstColumn)
        middle(of: text("gamma.txt", in: firstColumn)).click(forDuration: 0.8, thenDragTo: middle(of: target))

        let subfolder = fixture.root.appendingPathComponent(Fixture.folder, isDirectory: true)
        let expected = [Fixture.innerFile, "alpha.txt", "gamma.txt"].sorted()
        let moved = waitUntil(10) {
            (try? FileManager.default.contentsOfDirectory(atPath: subfolder.path))?.sorted() == expected
        }
        let found = ((try? FileManager.default.contentsOfDirectory(atPath: subfolder.path)) ?? []).sorted()
        XCTAssertTrue(moved, "\(Fixture.folder) holds \(found), not \(expected)")
        XCTAssertEqual(rootContents, [Fixture.folder, "beta.txt"].sorted(),
                       "the drop copied the files instead of moving them, or moved beta.txt too")
    }

    /// Regression (#43): a ⌘-press on a selected row took it out of the
    /// selection at once, so a ⌘-drag from it (⌘ makes the drop a move)
    /// carried that row alone. Finder keeps the selection for a ⌘-drag; the
    /// row now leaves it only when the button comes up without a drag. A
    /// ⌘-click still adds a row at once and takes a selected one out.
    func testCommandDraggingASelectedRowMovesTheWholeSelection() throws {
        try launchInColumns()
        click(text("alpha.txt", in: firstColumn))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .command) { click(text("beta.txt", in: firstColumn)) }
        waitForStatus(Self.selection("alpha.txt", "beta.txt"))
        XCUIElement.perform(withKeyModifiers: .command) { click(text("gamma.txt", in: firstColumn)) }
        waitForStatus(Self.selection("alpha.txt", "beta.txt", "gamma.txt"))
        // A ⌘-click (another row in between, so it is no double-click) takes beta.txt out.
        XCUIElement.perform(withKeyModifiers: .command) { click(text("beta.txt", in: firstColumn)) }
        waitForStatus(Self.selection("alpha.txt", "gamma.txt"))

        let target = middle(of: text(Fixture.folder, in: firstColumn))
        let gamma = middle(of: text("gamma.txt", in: firstColumn))
        XCUIElement.perform(withKeyModifiers: .command) { gamma.click(forDuration: 0.8, thenDragTo: target) }

        let subfolder = fixture.root.appendingPathComponent(Fixture.folder, isDirectory: true)
        let expected = [Fixture.innerFile, "alpha.txt", "gamma.txt"].sorted()
        let moved = waitUntil(10) {
            (try? FileManager.default.contentsOfDirectory(atPath: subfolder.path))?.sorted() == expected
        }
        let found = ((try? FileManager.default.contentsOfDirectory(atPath: subfolder.path)) ?? []).sorted()
        XCTAssertTrue(moved, "\(Fixture.folder) holds \(found), not \(expected): the ⌘-drag lost the selection")
        XCTAssertEqual(rootContents, [Fixture.folder, "beta.txt"].sorted(),
                       "the ⌘-drag copied the files instead of moving them, or moved beta.txt too")
    }

    /// A click on one of several selected rows selects it alone once the
    /// button has come up and the double-click interval has passed (a press
    /// there keeps the selection, for a drag or a double-click), as in the
    /// icon grid. That the selection stays while the button is down is pinned
    /// by testDraggingSelectedRowsOntoAFolderMovesThemAll, and that it stays
    /// for a double-click by testDoubleClickInsideTheSelectionOpensAllOfIt.
    func testAClickInsideTheSelectionSelectsThatRow() throws {
        try launchInColumns()
        click(text("alpha.txt", in: firstColumn))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .shift) { click(text("gamma.txt", in: firstColumn)) }
        waitForStatus(Self.selection("alpha.txt", "beta.txt", "gamma.txt"))

        click(text("beta.txt", in: firstColumn))
        waitForStatus(Self.selection("beta.txt"))
    }

    /// The wait the tests below give a click inside a selection before it
    /// narrows it: long enough for the keys that follow the click to come
    /// within it.
    private static let narrowingWait: TimeInterval = 3

    /// Selects alpha.txt through gamma.txt and clicks beta.txt, which keeps the
    /// three selected while the click waits to narrow them.
    private func clickInsideASelectionOfThree() {
        click(text("alpha.txt", in: firstColumn))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .shift) { click(text("gamma.txt", in: firstColumn)) }
        waitForStatus(Self.selection("alpha.txt", "beta.txt", "gamma.txt"))
        click(text("beta.txt", in: firstColumn))
    }

    /// Whether the status bar still says `status` after the click's wait has
    /// passed (checked all along, so a narrowing in between shows).
    private func keepsSaying(_ status: String) -> Bool {
        !waitUntil(Self.narrowingWait + 1.5) { !self.statusText.contains(status) }
    }

    /// Review of #41: ↓ while a click inside the selection waited to narrow it
    /// moved on from the whole selection (the list's own move), and the
    /// narrowing then undid the key. It narrows to the row clicked first.
    func testAnArrowKeyDuringTheWaitMovesOnFromTheRowClicked() throws {
        try launchInColumns(narrowingWait: Self.narrowingWait)
        clickInsideASelectionOfThree()
        app.typeKey(.downArrow, modifierFlags: .shift)
        let expected = Self.selection("beta.txt", "gamma.txt")
        waitForStatus(expected, timeout: 2)
        XCTAssertTrue(keepsSaying(expected), "the selection changed after ⇧↓; the status bar says “\(statusText)”")
    }

    /// Review of #41: → did nothing on a folder clicked inside a selection
    /// until the narrowing showed its column. It goes in at once.
    func testRightGoesIntoAFolderClickedInsideTheSelection() throws {
        try launchInColumns(narrowingWait: Self.narrowingWait)
        click(text(Fixture.folder, in: firstColumn))
        XCTAssertTrue(text(Fixture.innerFile, in: browserWindow).waitForExistence(timeout: 10),
                      "selecting “\(Fixture.folder)” didn't show its column")
        XCUIElement.perform(withKeyModifiers: .shift) { click(text("alpha.txt", in: firstColumn)) }
        waitForStatus("2 selected")
        click(text(Fixture.folder, in: firstColumn))
        app.typeKey(.rightArrow, modifierFlags: [])
        // In “subfolder”, its first item selected.
        waitForStatus("1 selected — 10 bytes", timeout: 2)
        XCTAssertTrue(keepsSaying("1 selected — 10 bytes"),
                      "the selection changed after →; the status bar says “\(statusText)”")
    }

    /// Review of #41: Select All during the wait (everything already selected,
    /// so the column saw no change), or a context menu opened during it, was
    /// undone by the narrowing; the menu then acted on rows no longer
    /// highlighted. Both now drop the narrowing.
    func testSelectAllOrAMenuDuringTheWaitKeepsTheSelection() throws {
        try launchInColumns(narrowingWait: Self.narrowingWait)
        click(text("alpha.txt", in: firstColumn))     // focuses the column
        waitForStatus(Self.selection("alpha.txt"))
        app.typeKey("a", modifierFlags: .command)
        waitForStatus("4 selected")
        click(text("beta.txt", in: firstColumn))
        app.typeKey("a", modifierFlags: .command)
        XCTAssertTrue(keepsSaying("4 selected"), "Select All didn't keep everything selected; " +
                      "the status bar says “\(statusText)”")

        let everything = Self.selection("alpha.txt", "beta.txt", "gamma.txt")
        click(text("alpha.txt", in: firstColumn))
        waitForStatus(Self.selection("alpha.txt"), timeout: Self.narrowingWait + 5)
        clickInsideASelectionOfThree()
        text("beta.txt", in: firstColumn).rightClick()
        let getInfo = app.menuItems["Get Info"].firstMatch
        XCTAssertTrue(getInfo.waitForExistence(timeout: 5), "a right-click on beta.txt opened no item menu")
        XCTAssertTrue(keepsSaying(everything), "the selection narrowed under the open menu; " +
                      "the status bar says “\(statusText)”")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { !getInfo.exists }, "the menu stayed open")
        XCTAssertTrue(statusText.contains(everything), "closing the menu changed the selection to “\(statusText)”")
    }

    /// A quick click on one row and then on another selects the second and
    /// opens nothing. macOS counts quick clicks as one series wherever they
    /// land, and the window sends the second click to the view that took the
    /// first: without IconClickRouting the second click reached the first
    /// row as a double-click and opened it. Folders are used so that a
    /// regression shows as the wrong column, not a file opened in another
    /// app: in Columns, opening a folder shows it as the next column.
    ///
    /// As in IconsViewTests, XCUITest may space the clicks wider than the
    /// double-click interval and gives each its own click count, so this may
    /// not repeat the series a hand makes; ShellClickSeriesTests and the press
    /// tracker's tests cover the counting itself.
    func testAQuickClickOnAnotherRowSelectsItWithoutOpening() throws {
        try fixture.makeStandardContents()
        let zfolder = try fixture.makeFolder("zfolder")
        try fixture.makeFile("z-inner.txt", size: 20, in: zfolder)
        try launch(expecting: Fixture.standardListing + ["zfolder"])
        click(viewModeSegment("Columns"))
        XCTAssertTrue(text("zfolder", in: firstColumn).waitForExistence(timeout: 10),
                      "Columns view doesn't list zfolder")

        let zRow = middle(of: text("zfolder", in: firstColumn))
        let subRow = middle(of: text(Fixture.folder, in: firstColumn))
        let started = Date()
        zRow.click()
        subRow.click()
        let gap = Date().timeIntervalSince(started)
        XCTContext.runActivity(named: "both clicks within \(String(format: "%.2f", gap)) s") { _ in }

        waitForFolder(Fixture.folder)
        XCTAssertTrue(text(Fixture.innerFile, in: browserWindow).waitForExistence(timeout: 10),
                      "a quick click on “\(Fixture.folder)” after one on zfolder didn't show its column")
        XCTAssertFalse(waitUntil(2) { self.text("z-inner.txt", in: self.browserWindow).exists },
                       "the second click opened zfolder instead of selecting “\(Fixture.folder)”")
        XCTAssertEqual(app.windows.count, 1, "the clicks opened a window")
    }

    /// A right-click on a row opens the row's menu, not the column's: the
    /// row's mouse view takes left clicks only. So does a ⌃-click, which is a
    /// right-click to AppKit.
    func testARightClickOrControlClickOnARowOpensItsMenu() throws {
        try launchInColumns()
        let beta = text("beta.txt", in: firstColumn)
        let getInfo = app.menuItems["Get Info"].firstMatch

        beta.rightClick()
        XCTAssertTrue(getInfo.waitForExistence(timeout: 5), "a right-click on beta.txt opened no item menu")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { !getInfo.exists }, "the menu stayed open")

        XCUIElement.perform(withKeyModifiers: .control) { middle(of: beta).click() }
        XCTAssertTrue(getInfo.waitForExistence(timeout: 5), "a ⌃-click on beta.txt opened no item menu")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { !getInfo.exists }, "the menu stayed open")
    }

    /// A double-click on a file row opens it: the second press reaches the
    /// row as the second click of a series on it (ShellIconClick.PressTracker).
    /// A text file opens in Selway's own editor, a window of its own. (The
    /// other double-click in Columns, UnfollowedLinkTests, is on a link.)
    func testDoubleClickOpensAFile() throws {
        try launchInColumns()
        let windows = app.windows.count
        doubleClick(text("beta.txt", in: firstColumn))
        XCTAssertTrue(waitUntil(10) { self.app.windows.count > windows },
                      "a double-click on beta.txt opened no window; there are \(app.windows.count)")
        XCTAssertTrue(fixture.exists("beta.txt"))
    }

    /// Regression (#41): a double-click on one row of a multiple selection
    /// opened only that row: the first click narrowed the selection on its
    /// mouse-up. The narrowing now waits out the double-click interval, as in
    /// the icon grid, so the double-click opens every selected row, as in
    /// Finder. Text files open in Selway's editor, one window with a tab for
    /// each.
    func testDoubleClickInsideTheSelectionOpensAllOfIt() throws {
        try launchInColumns()
        click(text("alpha.txt", in: firstColumn))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .shift) { click(text("beta.txt", in: firstColumn)) }
        waitForStatus(Self.selection("alpha.txt", "beta.txt"))

        doubleClick(text("alpha.txt", in: firstColumn))
        // The editor: the window named for the file it shows, with a tab named
        // for each file opened, and none for gamma.txt, which wasn't selected.
        let editor = app.windows.matching(NSPredicate(format: "title IN %@", ["alpha.txt", "beta.txt"])).firstMatch
        let tab = { (name: String) in
            editor.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", name, name)).firstMatch
        }
        let opened = waitUntil(10) { tab("alpha.txt").exists && tab("beta.txt").exists }
        if !opened, editor.exists {
            let dump = XCTAttachment(string: editor.debugDescription)
            dump.lifetime = .keepAlways
            add(dump)
        }
        XCTAssertTrue(opened,
                      "a double-click on alpha.txt with beta.txt selected too didn't open both; " +
                      "the windows are \(app.windows.allElementsBoundByIndex.map(\.title))")
        XCTAssertFalse(tab("gamma.txt").exists, "the double-click opened gamma.txt, which wasn't selected")
    }
}
