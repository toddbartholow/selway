import XCTest

/// Back / Forward with the keyboard (Go ▸ Back ⌘[, Forward ⌘]) and the
/// toolbar's buttons, which must follow the history's state.
final class NavigationTests: SelwayUITestCase {

    func testBackAndForwardFollowTheHistory() throws {
        try launchWithStandardFixture()
        let back = toolbarButton("Back")
        let forward = toolbarButton("Forward")
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no Back button in the toolbar")
        XCTAssertTrue(forward.exists, "no Forward button in the toolbar")
        assertEnabled(back: false, forward: false, "on launch")

        doubleClick(item(Fixture.folder))
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
        assertEnabled(back: true, forward: false, "after opening subfolder")

        app.typeKey("[", modifierFlags: .command)
        waitForFolder(Fixture.rootName, listing: "alpha.txt")
        assertEnabled(back: false, forward: true, "after ⌘[")

        app.typeKey("]", modifierFlags: .command)
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
        assertEnabled(back: true, forward: false, "after ⌘]")

        // The buttons themselves.
        click(back)
        waitForFolder(Fixture.rootName, listing: "alpha.txt")
        assertEnabled(back: false, forward: true, "after clicking Back")
        click(forward)
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
        assertEnabled(back: true, forward: false, "after clicking Forward")
    }

    private func assertEnabled(back: Bool, forward: Bool, _ when: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let backButton = toolbarButton("Back")
        let forwardButton = toolbarButton("Forward")
        let settled = waitUntil(5) { backButton.isEnabled == back && forwardButton.isEnabled == forward }
        XCTAssertTrue(settled, "\(when): Back is \(backButton.isEnabled ? "enabled" : "disabled"), "
                      + "Forward is \(forwardButton.isEnabled ? "enabled" : "disabled")", file: file, line: line)
    }
}
