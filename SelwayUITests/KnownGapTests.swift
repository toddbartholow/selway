import XCTest

/// Finder behaviour Selway doesn't have yet, from the click-and-keyboard audit.
/// Each checks the behaviour as it should be, inside a non-strict
/// `XCTExpectFailure`: today the check fails and the test passes as an expected
/// failure (shown in the results), and once the behaviour exists the check
/// passes too. Then drop the `XCTExpectFailure` wrapper to make the test a
/// regular guard. Everything before the wrapper (launching, selecting) must
/// still work: a failure there is a real one. A gap that's closed moves to its
/// view's tests (Return renaming the selection is in RenameKeysTests).
final class KnownGapTests: SelwayUITestCase {

    /// Finder moves files dropped on a tab into the folder that tab shows.
    /// Selway's tabs are AppKit's, whose tab buttons take no file drops.
    func testDroppingAFileOnATabMovesItIntoThatTabsFolder() throws {
        try fixture.makeStandardContents()
        let subfolder = fixture.root.appendingPathComponent(Fixture.folder, isDirectory: true)
        // ⌘T opens the new tab on subfolder (the New windows folder).
        try launch(defaults: ["selwayNewWindowCustomFolder": subfolder.path], expecting: Fixture.standardListing)
        app.typeKey("t", modifierFlags: .command)
        let tabBar = browserWindow.tabGroups.firstMatch
        let subfolderTab = tabBar.tabs.matching(Self.named(Fixture.folder)).firstMatch
        XCTAssertTrue(subfolderTab.waitForExistence(timeout: 10), "⌘T opened no tab on \(Fixture.folder)")
        click(tabBar.tabs.matching(Self.named(Fixture.rootName)).firstMatch)
        waitForFolder(Fixture.rootName, listing: "alpha.txt")

        item("alpha.txt").click(forDuration: 0.8, thenDragTo: subfolderTab)
        expectGap("files dropped on a tab aren't moved into its folder") {
            XCTAssertTrue(waitUntil(5) { self.fixture.exists("alpha.txt", in: subfolder) },
                          "alpha.txt wasn't moved into \(Fixture.folder)")
        }
    }

    private func expectGap<R>(_ reason: String, _ check: () throws -> R) rethrows -> R {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        return try XCTExpectFailure("Known gap: \(reason)", options: options, failingBlock: check)
    }
}
