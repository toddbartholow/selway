import XCTest

final class MergeTabsTests: SelwayUITestCase {
    private var tabBar: XCUIElement { browserWindow.tabGroups.firstMatch }
    private func pane(_ index: Int) -> XCUIElement { identified("pane\(index)") }
    private func list(_ index: Int) -> XCUIElement { identified("fileList", in: pane(index)) }

    private var tabTitles: [String] {
        guard tabBar.exists else { return [] }
        return tabBar.tabs.allElementsBoundByIndex.map { $0.title.isEmpty ? $0.label : $0.title }
    }

    private func waitForTabs(_ titles: [String], file: StaticString = #filePath, line: UInt = #line) {
        let expected = titles.count > 1 ? titles : []
        XCTAssertTrue(waitUntil(10) { self.tabTitles == expected },
                      "the tabs are \(tabTitles), not \(titles)", file: file, line: line)
    }

    private func tab(_ name: String) -> XCUIElement {
        tabBar.tabs.matching(Self.named(name)).firstMatch
    }

    /// Whether `tab` is the one in front. A window tab is a radio button whose
    /// value is 1 while it's selected; its `isSelected` stays false.
    private func isFront(_ tab: XCUIElement) -> Bool {
        (tab.value as? NSNumber)?.intValue == 1
    }

    /// The Dual Pane toolbar button's state: a toggle's value is 1 while on.
    private func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? NSNumber)?.intValue == 1
    }

    private func choose(_ title: String, in menu: String, file: StaticString = #filePath, line: UInt = #line) {
        let menuBar = app.menuBars.menuBarItems[menu]
        XCTAssertTrue(menuBar.waitForExistence(timeout: 5), "no \(menu) menu", file: file, line: line)
        menuBar.click()
        let item = menuBar.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the \(menu) menu has no \(title)", file: file, line: line)
        XCTAssertTrue(item.isEnabled, "\(menu) ▸ \(title) is disabled", file: file, line: line)
        item.click()
    }

    private func waitForItem(_ name: String, inPane index: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(item(name, in: list(index)).waitForExistence(timeout: 10),
                      "pane\(index) doesn't list \(name)", file: file, line: line)
    }

    private func openTabForFolder(_ folder: String) {
        item(folder).rightClick()
        let open = app.menuItems["Open in New Tab"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "no Open in New Tab item")
        open.click()
    }

    private func launchWithTwoTabs() throws {
        try launchWithStandardFixture()
        openTabForFolder(Fixture.folder)
        waitForTabs([Fixture.rootName, Fixture.folder])
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
        tab(Fixture.rootName).click()
        waitForFolder(Fixture.rootName)
    }

    func testDualPaneToolbarButtonTogglesAndTracksShortcut() throws {
        try launchWithStandardFixture()
        let toggle = identified("dualPaneToggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no Dual Pane toolbar button")
        XCTAssertFalse(isOn(toggle), "the button is on in a single-pane window: \(toggle.debugDescription)")

        toggle.click()
        XCTAssertTrue(identified("pane1").waitForExistence(timeout: 10), "toolbar didn't show the second pane")
        XCTAssertTrue(waitUntil(5) { self.isOn(toggle) }, "the button is off with two panes: \(toggle.debugDescription)")

        app.typeKey("p", modifierFlags: [.command, .control])
        XCTAssertTrue(waitUntil(5) { !self.identified("pane1").exists }, "⌃⌘P didn't hide the second pane")
        XCTAssertTrue(waitUntil(5) { !self.isOn(toggle) }, "the button stayed on after ⌃⌘P")
    }

    func testMergeAndMoveOtherPaneRestoreTwoTabs() throws {
        try launchWithTwoTabs()
        tab(Fixture.folder).click()
        waitForFolder(Fixture.folder)
        assertMenuItem("Merge Tab into Dual Pane", in: "Window", isEnabled: false, "on the last tab")
        tab(Fixture.rootName).click()
        waitForFolder(Fixture.rootName)
        assertMenuItem("Merge Tab into Dual Pane", in: "Window", isEnabled: true, "with a tab to the right")
        choose("Merge Tab into Dual Pane", in: "Window")

        waitForTabs([Fixture.rootName])
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "merge didn't show the right pane")
        XCTAssertTrue(pane(0).isSelected, "the original pane should stay active")
        waitForItem("alpha.txt", inPane: 0)
        waitForItem(Fixture.innerFile, inPane: 1)
        assertMenuItem("Merge Tab into Dual Pane", in: "Window", isEnabled: false, "in a dual-pane window")

        choose("Move Other Pane to New Tab", in: "Window")
        waitForTabs([Fixture.rootName, Fixture.folder])
        XCTAssertTrue(waitUntil(10) { !self.pane(1).exists }, "the window still has two panes")
        waitForFolder(Fixture.rootName)
        XCTAssertEqual(tabTitles, [Fixture.rootName, Fixture.folder], "the new tab should follow the current tab")
        XCTAssertTrue(isFront(tab(Fixture.rootName)),
                      "moving the pane should leave the current tab selected: \(tab(Fixture.rootName).debugDescription)")
        waitForItem("alpha.txt", inPane: 0)
        assertMenuItem("Move Other Pane to New Tab", in: "Window", isEnabled: false, "in a single-pane window")
    }

    func testMergeUsesOnlyImmediateRightTab() throws {
        try fixture.makeStandardContents()
        let thirdFolder = try fixture.makeFolder("third")
        try fixture.makeFile("third.txt", size: 10, in: thirdFolder)
        try launch(defaults: standardDefaults(), expecting: Fixture.standardListing + ["third"])
        openTabForFolder(Fixture.folder)
        waitForTabs([Fixture.rootName, Fixture.folder])
        waitForFolder(Fixture.folder)
        tab(Fixture.rootName).click()
        waitForFolder(Fixture.rootName)
        openTabForFolder("third")
        waitForTabs([Fixture.rootName, Fixture.folder, "third"])
        waitForFolder("third", listing: "third.txt")
        tab(Fixture.rootName).click()
        waitForFolder(Fixture.rootName)

        choose("Merge Tab into Dual Pane", in: "Window")
        waitForTabs([Fixture.rootName, "third"])
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "merge didn't show the right pane")
        waitForItem(Fixture.innerFile, inPane: 1)
        XCTAssertFalse(item("third.txt", in: list(1)).exists, "merge used a tab beyond the immediate neighbor")

        // Moving it back puts it where it was, right after the current tab
        // rather than after the last one.
        choose("Move Other Pane to New Tab", in: "Window")
        waitForTabs([Fixture.rootName, Fixture.folder, "third"])
        XCTAssertTrue(isFront(tab(Fixture.rootName)),
                      "moving the pane should leave the current tab selected: \(tab(Fixture.rootName).debugDescription)")
        assertMenuItem("Merge Tab into Dual Pane", in: "Window", isEnabled: true, "with the moved tab to the right again")
    }

    /// With dual pane remembered for new windows, the tab a pane moves to still
    /// has one pane, and the move doesn't change what new tabs get.
    func testMovedPaneTabIsSinglePaneWhenDualIsRemembered() throws {
        try launchWithStandardFixture(defaults: ["selwayDualPane": true])
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "the window should start with two panes")
        waitForItem("alpha.txt", inPane: 1)

        choose("Move Other Pane to New Tab", in: "Window")
        waitForTabs([Fixture.rootName, Fixture.rootName])
        XCTAssertTrue(waitUntil(10) { !self.pane(1).exists }, "the window still has two panes")
        XCTAssertTrue(isFront(tabBar.tabs.element(boundBy: 0)), "moving the pane should leave the current tab selected")

        let moved = tabBar.tabs.element(boundBy: 1)
        moved.click()
        XCTAssertTrue(waitUntil(5) { self.isFront(moved) }, "the moved pane's tab didn't come forward: \(moved.debugDescription)")
        waitForItem("alpha.txt", inPane: 0)
        XCTAssertFalse(pane(1).exists, "the moved pane's tab should have one pane")

        // New tabs still start with two panes: the move left the remembered layout alone.
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitUntil(10) { self.tabTitles.count == 3 }, "⌘T didn't open a third tab")
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "a new tab should still get two panes")
    }
}
