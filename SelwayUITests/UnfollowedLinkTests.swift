import XCTest

/// A link the listing doesn't follow, one into an automount folder, which
/// following would mount: shown as a link, not previewed, but opened all the
/// same when the user asks, as in Finder. Opening it used to hand it to
/// Finder, which followed it anyway. The automount folder is a stand-in, a
/// fixture folder the app is told to take for one (`-SelwayUITestAutofsFolder`).
final class UnfollowedLinkTests: SelwayUITestCase {

    func testARefusedLinkToAFolderOpensIntoIt() throws {
        try fixture.makeStandardContents()
        let target = try fixture.makeSibling("AutomountStandIn")
        try fixture.makeFile("deep.txt", size: 5, in: target)
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("Share").path,
                                                   withDestinationPath: target.path)
        try launch(defaults: ["selwayShowPreview": true], autofsFolder: target,
                   expecting: Fixture.standardListing + ["Share"])

        // Listed unfollowed: selected, the preview shows the link, not its target.
        click(item("Share"))
        XCTAssertTrue(identified("unfollowedLinkPreview").waitForExistence(timeout: 10),
                      "the preview doesn't show “Share” as a link it didn't follow")

        doubleClick(item("Share"))
        waitForFolder("Share", listing: "deep.txt")
        XCTAssertEqual(app.state, .runningForeground, "opening the link left Selway")
    }

    /// In Columns view, opening the link shows it as the next column, and
    /// that column stays: neither the click that comes with the double-click
    /// nor a later click on the link takes it away for a preview.
    func testARefusedFolderLinkStaysOpenAsAColumn() throws {
        try fixture.makeStandardContents()
        let target = try fixture.makeSibling("AutomountStandIn")
        try fixture.makeFile("deep.txt", size: 5, in: target)
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("Share").path,
                                                   withDestinationPath: target.path)
        try launch(autofsFolder: target, expecting: Fixture.standardListing + ["Share"])

        click(viewModeSegment("Columns"))
        let firstColumn = browserWindow.descendants(matching: .any).matching(identifier: "columnPane").firstMatch
        let share = text("Share", in: firstColumn)
        XCTAssertTrue(share.waitForExistence(timeout: 10), "Columns view doesn't list “Share”")

        doubleClick(share)
        let deep = text("deep.txt", in: browserWindow)
        XCTAssertTrue(deep.waitForExistence(timeout: 10), "opening “Share” didn't show it as a column")
        XCTAssertFalse(waitUntil(2) { !deep.exists }, "the column for “Share” closed after the double-click")

        click(share)
        XCTAssertFalse(waitUntil(2) { !deep.exists }, "a click on “Share” closed its column")
    }

    /// The fixture's standard contents, the stand-in automount folder holding
    /// deep.txt, and "Share", a link to it in the root.
    private func makeShare() throws -> URL {
        try fixture.makeStandardContents()
        let target = try fixture.makeSibling("AutomountStandIn")
        try fixture.makeFile("deep.txt", size: 5, in: target)
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("Share").path,
                                                   withDestinationPath: target.path)
        return target
    }

    /// A link whose target can't be reached (here, nothing is there) isn't
    /// opened: an alert says so, and the window stays where it was.
    func testALinkThatCantBeReachedSaysSo() throws {
        let target = try makeShare()
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("Gone").path,
                                                   withDestinationPath: target.appendingPathComponent("missing").path)
        try launch(autofsFolder: target, expecting: Fixture.standardListing + ["Share", "Gone"])

        doubleClick(item("Gone"))
        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no alert said “Gone” couldn't be opened")
        XCTAssertTrue(alert.staticTexts.matching(Self.named("“Gone” couldn’t be opened.")).firstMatch.exists,
                      "the alert doesn't name “Gone”")
        alert.buttons.firstMatch.click()
        XCTAssertEqual(shownFolderName, Fixture.rootName, "the window left the folder")
    }

    /// Where the app's follows wait until the test lets the link answer
    /// (`linkFollowGate`): a file in the fixture's container, made by `answer`.
    private var gate: URL { fixture.container.appendingPathComponent("link-follow-gate") }

    /// Lets the slow link answer.
    private func answer() throws {
        try Data().write(to: gate)
    }

    /// Following the link takes a while (an unreachable host's timeout; here
    /// the app waits until the test lets it answer). It used to freeze the
    /// window: now the window stays usable, the status bar says what it's
    /// opening, and the folder opens once the link answers.
    func testASlowLinkOpensWithoutFreezingTheWindow() throws {
        let target = try makeShare()
        try launch(autofsFolder: target, linkFollowGate: gate, expecting: Fixture.standardListing + ["Share"])

        doubleClick(item("Share"))
        waitForStatus("Opening “Share”")
        click(item("alpha.txt"))
        waitForStatus("1 selected")
        XCTAssertTrue(statusText.contains("Opening “Share”"), "the status bar stopped saying it's opening “Share”")
        try answer()
        waitForFolder("Share", listing: "deep.txt")
        XCTAssertFalse(statusText.contains("Opening"), "the status bar still says it's opening “Share”")
    }

    /// Going to another folder while the link is being followed drops it: the
    /// window stays where the user went.
    func testGoingElsewhereDropsASlowLink() throws {
        let target = try makeShare()
        try launch(autofsFolder: target, linkFollowGate: gate, expecting: Fixture.standardListing + ["Share"])

        doubleClick(item("Share"))
        waitForStatus("Opening “Share”")
        doubleClick(item(Fixture.folder))
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
        XCTAssertFalse(statusText.contains("Opening"), "the status bar still says it's opening “Share”")
        // The link answers only now, after the window has gone elsewhere.
        try answer()
        XCTAssertFalse(waitUntil(3) { self.shownFolderName != Fixture.folder },
                       "the link opened after the window went to another folder")
        XCTAssertFalse(statusText.contains("Opening"), "the status bar still says it's opening “Share”")
    }

    /// In Columns view, selecting something else in the column while the link
    /// is being followed drops it: no column opens for it.
    func testSelectingAnotherItemInColumnsDropsASlowLink() throws {
        let target = try makeShare()
        try launch(autofsFolder: target, linkFollowGate: gate, expecting: Fixture.standardListing + ["Share"])

        click(viewModeSegment("Columns"))
        let firstColumn = browserWindow.descendants(matching: .any).matching(identifier: "columnPane").firstMatch
        let share = text("Share", in: firstColumn)
        XCTAssertTrue(share.waitForExistence(timeout: 10), "Columns view doesn't list “Share”")

        doubleClick(share)
        waitForStatus("Opening “Share”")
        click(text("alpha.txt", in: firstColumn))
        XCTAssertTrue(waitUntil(5) { !self.statusText.contains("Opening") },
                      "the status bar still says it's opening “Share” after another item was selected")
        // The link answers only now, after the selection has moved.
        try answer()
        let deep = text("deep.txt", in: browserWindow)
        XCTAssertFalse(waitUntil(3) { deep.exists }, "“Share” opened as a column after another item was selected")
        XCTAssertFalse(statusText.contains("Opening"), "the status bar still says it's opening “Share”")
    }
}
