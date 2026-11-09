import XCTest

/// Two panes side by side in a window (View ▸ Show / Hide Dual Pane, ⌃⌘P),
/// Go ▸ Switch to Other Pane (⌃⌘O), and Commander One's F5 / F6, which copy
/// or move the active pane's selection into the other pane's folder after
/// asking.
///
/// Each pane is an accessibility group, "pane0" (the left) and "pane1" (the
/// right), selected while it's the pane the menus, toolbar, sidebar and
/// title follow (its "Active" value reaches VoiceOver as AXValueDescription,
/// which XCUITest doesn't read). The views inside keep their identifiers
/// (fileList, statusBar, pathBar), so queries are scoped to a pane.
final class DualPaneTests: SelwayUITestCase {

    // MARK: Panes

    private func pane(_ index: Int) -> XCUIElement { identified("pane\(index)") }

    /// The file list of pane `index`.
    private func list(_ index: Int) -> XCUIElement { identified("fileList", in: pane(index)) }

    /// Every file list in the browser window (one element per list, or more
    /// if the list's views each carry the identifier: compared, not counted).
    private var listCount: Int {
        browserWindow.descendants(matching: .any).matching(identifier: "fileList").count
    }

    /// What pane `index`'s status bar says.
    private func status(_ index: Int) -> String {
        let bar = identified("statusBar", in: pane(index))
        guard bar.exists else { return "" }
        return [bar.label, bar.value as? String ?? ""].joined(separator: " ")
    }

    /// Waits until pane `index`'s status bar says `fragment`.
    private func waitForStatus(_ fragment: String, inPane index: Int,
                               file: StaticString = #filePath, line: UInt = #line) {
        let said = waitUntil(10) { self.status(index).contains(fragment) }
        XCTAssertTrue(said, "pane\(index)'s status bar never said “\(fragment)”; it says “\(status(index))”",
                      file: file, line: line)
    }

    private func isActive(_ index: Int) -> Bool {
        pane(index).isSelected
    }

    /// Waits until pane `index` is the active one, and the other isn't.
    private func waitForActive(_ index: Int, file: StaticString = #filePath, line: UInt = #line) {
        let other = 1 - index
        let settled = waitUntil(5) { self.isActive(index) && !self.isActive(other) }
        XCTAssertTrue(settled, "pane\(index) isn't the only active pane (pane0 selected: \(pane(0).isSelected), "
                      + "pane1 selected: \(pane(1).isSelected))", file: file, line: line)
    }

    /// Waits until pane `index` lists `name`.
    private func waitForItem(_ name: String, inPane index: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(item(name, in: list(index)).waitForExistence(timeout: 10), "pane\(index) doesn't list “\(name)”",
                      file: file, line: line)
    }

    /// ⌃⌘P, then waits for the second pane, which opens on the first pane's folder.
    private func showDualPane(listing name: String = "alpha.txt", file: StaticString = #filePath, line: UInt = #line) {
        app.typeKey("p", modifierFlags: [.command, .control])
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "⌃⌘P showed no second pane", file: file, line: line)
        waitForItem(name, inPane: 1, file: file, line: line)
    }

    /// The standard fixture in two panes: the left on the fixture's root,
    /// active, with alpha.txt selected; the right on `subfolder`.
    private func launchWithRightPaneInSubfolder(defaults: [String: Any] = [:],
                                                file: StaticString = #filePath, line: UInt = #line) throws {
        try launchWithStandardFixture(defaults: defaults, file: file, line: line)
        showDualPane(file: file, line: line)
        doubleClick(item(Fixture.folder, in: list(1)), file: file, line: line)
        waitForItem(Fixture.innerFile, inPane: 1, file: file, line: line)
        click(item("alpha.txt", in: list(0)), file: file, line: line)
        waitForActive(0, file: file, line: line)
        waitForFolder(Fixture.rootName, file: file, line: line)
        waitForStatus(Self.selection("alpha.txt"), inPane: 0, file: file, line: line)
    }

    /// Chooses `title` in the menu bar's `menu` menu.
    private func choose(_ title: String, in menu: String, file: StaticString = #filePath, line: UInt = #line) {
        let bar = app.menuBars.menuBarItems[menu]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "no \(menu) menu", file: file, line: line)
        bar.click()
        let item = bar.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the \(menu) menu has no \(title)", file: file, line: line)
        XCTAssertTrue(item.isEnabled, "\(menu) ▸ \(title) is disabled", file: file, line: line)
        item.click()
    }

    /// The confirmation F5 / F6 show.
    private var transferSheet: XCUIElement { app.sheets.firstMatch }

    /// Waits for the confirmation and checks it asks `question` (a heading,
    /// not a static text, so any element type).
    private func waitForTransferSheet(asking question: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(transferSheet.waitForExistence(timeout: 10), "no confirmation", file: file, line: line)
        let heading = transferSheet.descendants(matching: .any).matching(Self.named(question)).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5),
                      "the confirmation doesn't ask “\(question)”", file: file, line: line)
    }

    /// Waits for the window's toast to say `message`.
    private func waitForToast(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(text(message, in: browserWindow).waitForExistence(timeout: 5),
                      "no toast said “\(message)”", file: file, line: line)
    }

    /// ⌃⌘P: View ▸ Show / Hide Dual Pane.
    private func toggleDualPane() {
        app.typeKey("p", modifierFlags: [.command, .control])
    }

    /// Copy refuses a computer overview as the destination and explains the
    /// requirement in the window's toast.
    func testCopyToComputerOverviewShowsRefusalToast() throws {
        try launchWithStandardFixture()
        showDualPane()
        click(identified("pathBar", in: pane(1)))
        waitForActive(1)
        click(identified("sidebarComputer", in: sidebar))
        waitForFolder(computerName)

        click(item("alpha.txt", in: list(0)))
        waitForActive(0)
        app.typeKey(.F5, modifierFlags: [])
        waitForToast("Show a folder in the other pane to copy there")
    }

    /// Selway ▸ Eject (⌘E) offers the active pane's overview tile, never the
    /// one selected in the other pane.
    func testEjectFollowsTheActivePanesOverviewTile() throws {
        try fixture.makeStandardContents()
        let volume = try fixture.makeFolder("overview-drive")
        try launch(volumes: [["path": volume.path, "name": "Overview Drive", "diskImage": true]],
                   expecting: Fixture.standardListing + ["overview-drive"])
        showDualPane()
        click(identified("pathBar", in: pane(1)))
        waitForActive(1)
        click(identified("sidebarComputer", in: sidebar))
        waitForFolder(computerName)
        click(diskTile("Overview Drive", in: pane(1)))
        assertEjectItem("Eject “Overview Drive”", isEnabled: true, "with the active pane's tile selected")

        click(item("alpha.txt", in: list(0)))
        waitForActive(0)
        assertEjectItem("Eject", isEnabled: false, "with a tile selected only in the inactive pane")
    }

    /// A selected tile keeps its selection but changes emphasis with its pane.
    func testOverviewSelectionEmphasisFollowsTheActivePane() throws {
        try fixture.makeStandardContents()
        let volume = try fixture.makeFolder("overview-drive")
        try launch(defaults: ["selwayViewMode": "icons"],
                   volumes: [["path": volume.path, "name": "Overview Drive", "diskImage": true]],
                   expecting: Fixture.standardListing + ["overview-drive"])
        showDualPane()

        click(identified("sidebarComputer", in: sidebar))
        waitForFolder(computerName)
        click(identified("pathBar", in: pane(1)))
        waitForActive(1)
        click(identified("sidebarComputer", in: sidebar))
        XCTAssertTrue(diskTile("Overview Drive", in: pane(0)).waitForExistence(timeout: 10))
        XCTAssertTrue(diskTile("Overview Drive", in: pane(1)).waitForExistence(timeout: 10))

        click(diskTile("Overview Drive", in: pane(0)))
        click(diskTile("Overview Drive", in: pane(1)))
        waitForActive(1)
        XCTAssertTrue(diskTile("Overview Drive", emphasized: true, in: pane(1)).waitForExistence(timeout: 5),
                      "the active pane's selected tile isn't emphasized")
        XCTAssertTrue(diskTile("Overview Drive", emphasized: false, in: pane(0)).waitForExistence(timeout: 5),
                      "the inactive pane's selected tile isn't unemphasized")
        XCTAssertTrue(diskTile("Overview Drive", in: pane(0)).isSelected, "the inactive pane's tile lost its selection")

        click(diskTile("Overview Drive", in: pane(0)))
        waitForActive(0)
        XCTAssertTrue(diskTile("Overview Drive", emphasized: true, in: pane(0)).waitForExistence(timeout: 5),
                      "selection emphasis didn't follow the pane switch")
        XCTAssertTrue(diskTile("Overview Drive", emphasized: false, in: pane(1)).waitForExistence(timeout: 5),
                      "the other pane's selected tile stayed emphasized")
        XCTAssertTrue(diskTile("Overview Drive", in: pane(1)).isSelected, "the inactive pane's tile lost its selection")
    }

    /// Checks the Eject item in the app's own Selway menu: the second menu bar
    /// item with that title, after the application menu.
    private func assertEjectItem(_ title: String, isEnabled enabled: Bool, _ when: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let menu = app.menuBars.menuBarItems.matching(NSPredicate(format: "title == %@", "Selway")).element(boundBy: 1)
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "no Selway menu", file: file, line: line)
        menu.click()
        let item = menu.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the Selway menu has no \(title)", file: file, line: line)
        XCTAssertEqual(item.isEnabled, enabled, "\(when): Selway ▸ \(title) is \(item.isEnabled ? "enabled" : "disabled")",
                       file: file, line: line)
        app.typeKey(.escape, modifierFlags: [])
    }

    /// The first column of pane `index` in Columns view.
    private func firstColumn(_ index: Int) -> XCUIElement { identified("columnPane", in: pane(index)) }

    /// The size in bytes of the file at `relativePath` in `parent`.
    private func size(of relativePath: String, in parent: URL) -> Int? {
        let path = parent.appendingPathComponent(relativePath).path
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    }

    // MARK: Showing and hiding

    /// View ▸ Show Dual Pane shows a second list beside the first, on the same
    /// folder; Hide Dual Pane leaves one.
    func testTheViewMenuShowsTwoListsAndHidesOne() throws {
        try launchWithStandardFixture()
        XCTAssertFalse(pane(1).exists, "a new window shows two panes")
        let single = listCount
        XCTAssertGreaterThan(single, 0, "no file list")

        choose("Show Dual Pane", in: "View")
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "no second pane")
        waitForItem("alpha.txt", inPane: 1)
        waitForItem("alpha.txt", inPane: 0)
        XCTAssertTrue(waitUntil(5) { self.listCount == 2 * single },
                      "the window shows \(listCount) lists, not \(2 * single)")
        // Each pane has its own path bar and status bar.
        XCTAssertTrue(identified("pathBar", in: pane(1)).exists, "the second pane has no path bar")
        XCTAssertTrue(identified("statusBar", in: pane(1)).exists, "the second pane has no status bar")
        waitForActive(0)

        choose("Hide Dual Pane", in: "View")
        XCTAssertTrue(waitUntil(5) { !self.pane(1).exists }, "the second pane is still shown")
        XCTAssertTrue(waitUntil(5) { self.listCount == single }, "the window shows \(listCount) lists, not \(single)")
        waitForListing(Fixture.standardListing)
    }

    /// Hiding the second pane while it's active keeps it: it becomes the one
    /// pane, on its folder. Shown again, the other comes back on its own.
    func testHidingKeepsTheActivePane() throws {
        try launchWithStandardFixture()
        showDualPane()
        doubleClick(item(Fixture.folder, in: list(1)))
        waitForItem(Fixture.innerFile, inPane: 1)
        waitForActive(1)

        app.typeKey("p", modifierFlags: [.command, .control])
        XCTAssertTrue(waitUntil(5) { !self.pane(1).exists }, "the second pane is still shown")
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)

        app.typeKey("p", modifierFlags: [.command, .control])
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "⌃⌘P didn't show the second pane again")
        waitForItem(Fixture.innerFile, inPane: 0)
        waitForItem("alpha.txt", inPane: 1)
    }

    /// A hidden pane watches nothing; shown again, it lists what changed in
    /// its folder meanwhile.
    func testAPaneShownAgainListsWhatChangedWhileHidden() throws {
        try launchWithRightPaneInSubfolder()
        toggleDualPane()
        XCTAssertTrue(waitUntil(5) { !self.pane(1).exists }, "the second pane is still shown")
        try fixture.makeFile("late.txt", size: 1, in: fixture.root.appendingPathComponent(Fixture.folder))

        toggleDualPane()
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "⌃⌘P didn't show the second pane again")
        waitForItem("late.txt", inPane: 1)
    }

    /// A pane whose folder went while it was hidden (deleted, renamed, its
    /// disk ejected) shows the nearest folder that's still there.
    func testAPaneWhoseFolderWentWhileHiddenShowsTheFolderAbove() throws {
        try launchWithRightPaneInSubfolder()
        toggleDualPane()
        XCTAssertTrue(waitUntil(5) { !self.pane(1).exists }, "the second pane is still shown")
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(Fixture.folder))
        XCTAssertTrue(waitUntil(10) { !self.item(Fixture.folder, in: self.list(0)).exists },
                      "the left pane still lists \(Fixture.folder)")

        toggleDualPane()
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "⌃⌘P didn't show the second pane again")
        waitForItem("alpha.txt", inPane: 1)
        XCTAssertTrue(waitUntil(5) { self.pane(1).label.hasSuffix(Fixture.rootName) },
                      "the second pane is “\(pane(1).label)”, not on \(Fixture.rootName)")
    }

    /// The second pane first opens on the first pane's folder. Hidden and
    /// shown again, it keeps its own folder, wherever the first has gone.
    func testTheSecondPaneOpensOnTheFirstPanesFolder() throws {
        try launchWithStandardFixture()
        doubleClick(item(Fixture.folder))
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)

        showDualPane(listing: Fixture.innerFile)
        XCTAssertFalse(item("alpha.txt", in: list(1)).exists, "the second pane opened on \(Fixture.rootName)")
        waitForActive(0)

        toggleDualPane()
        XCTAssertTrue(waitUntil(5) { !self.pane(1).exists }, "the second pane is still shown")
        app.typeKey("[", modifierFlags: .command)
        waitForFolder(Fixture.rootName, listing: "alpha.txt")

        toggleDualPane()
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "⌃⌘P didn't show the second pane again")
        waitForItem(Fixture.innerFile, inPane: 1)
        waitForItem("alpha.txt", inPane: 0)
        XCTAssertFalse(item("alpha.txt", in: list(1)).exists, "the second pane followed the first back")
    }

    /// The window opens with two panes when they were shown last: the left
    /// one active, both on the folder new windows open.
    func testLaunchingWithTheDualSettingShowsTwoPanes() throws {
        try launchWithStandardFixture(defaults: ["selwayDualPane": true])
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "the window shows one pane")
        waitForItem("alpha.txt", inPane: 0)
        waitForItem("alpha.txt", inPane: 1)
        waitForActive(0)
    }

    /// Each pane is named for its side and its folder, and the active one
    /// says so.
    func testThePanesAreNamedForTheirSideAndFolder() throws {
        try launchWithStandardFixture()
        showDualPane()
        XCTAssertTrue(waitUntil(5) { self.pane(0).label == "Left pane, \(Fixture.rootName)" },
                      "the left pane is called “\(pane(0).label)”")
        XCTAssertTrue(waitUntil(5) { self.pane(1).label == "Right pane, \(Fixture.rootName)" },
                      "the right pane is called “\(pane(1).label)”")

        doubleClick(item(Fixture.folder, in: list(1)))
        waitForItem(Fixture.innerFile, inPane: 1)
        XCTAssertTrue(waitUntil(5) { self.pane(1).label == "Right pane, \(Fixture.folder)" },
                      "the right pane is called “\(pane(1).label)”")
        waitForActive(1)
    }

    /// In a window with two panes, the path and status bars are always shown
    /// and the preview isn't, whatever the View menu says, and its items for
    /// them are disabled. With one pane again, the settings are back.
    func testDualPaneShowsBothBarsAndNoPreview() throws {
        try launchWithStandardFixture(defaults: ["selwayDualPane": true, "selwayShowPathBar": false,
                                                 "selwayShowStatusBar": false, "selwayShowPreview": true])
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "the window shows one pane")
        for index in [0, 1] {
            XCTAssertTrue(identified("pathBar", in: pane(index)).exists, "pane\(index) has no path bar")
            XCTAssertTrue(identified("statusBar", in: pane(index)).exists, "pane\(index) has no status bar")
        }
        XCTAssertFalse(identified("previewPanel").exists, "a pane shows the preview")
        assertMenuItem("Show Path Bar", in: "View", isEnabled: false, "with two panes")
        assertMenuItem("Show Status Bar", in: "View", isEnabled: false, "with two panes")
        assertMenuItem("Hide Preview", in: "View", isEnabled: false, "with two panes")

        toggleDualPane()
        XCTAssertTrue(waitUntil(5) { !self.pane(1).exists }, "the second pane is still shown")
        XCTAssertTrue(identified("previewPanel").waitForExistence(timeout: 10), "the preview didn't come back")
        XCTAssertTrue(waitUntil(5) { !self.pathBar.exists && !self.statusBar.exists },
                      "the path or status bar is still shown with one pane")
        assertMenuItem("Show Path Bar", in: "View", isEnabled: true, "with one pane")
        assertMenuItem("Show Status Bar", in: "View", isEnabled: true, "with one pane")
        assertMenuItem("Hide Preview", in: "View", isEnabled: true, "with one pane")
    }

    // MARK: The active pane

    /// A click in a pane makes it the active one: its header is highlighted
    /// (the group is selected) and the window's title is its folder. A
    /// click on its status bar does, as well as one on a file.
    func testAClickActivatesAPaneAndTheTitleFollowsIt() throws {
        try launchWithStandardFixture()
        showDualPane()
        waitForActive(0)

        doubleClick(item(Fixture.folder, in: list(1)))
        waitForItem(Fixture.innerFile, inPane: 1)
        waitForActive(1)
        waitForFolder(Fixture.folder)

        click(item("beta.txt", in: list(0)))
        waitForActive(0)
        waitForFolder(Fixture.rootName)

        click(identified("statusBar", in: pane(1)))
        waitForActive(1)
        waitForFolder(Fixture.folder)
    }

    /// A sidebar row takes the active pane there; the other stays where it
    /// was. Either pane.
    func testASidebarClickNavigatesTheActivePaneOnly() throws {
        let pinned = try fixture.makeSibling("pinned-one")
        try fixture.makeFile("one.txt", size: 1, in: pinned)
        let other = try fixture.makeSibling("pinned-two")
        try fixture.makeFile("two.txt", size: 2, in: other)
        try fixture.makeStandardContents()
        try launch(defaults: ["pinnedFolders": [pinned.path, other.path]], expecting: Fixture.standardListing)
        showDualPane()

        click(item("beta.txt", in: list(1)))
        waitForActive(1)
        click(text("pinned-one", in: sidebar))
        waitForItem("one.txt", inPane: 1)
        waitForFolder("pinned-one")
        XCTAssertTrue(item("alpha.txt", in: list(0)).exists, "the left pane left the fixture's root")
        XCTAssertFalse(item("one.txt", in: list(0)).exists, "the left pane went to pinned-one too")

        click(item("beta.txt", in: list(0)))
        waitForActive(0)
        click(text("pinned-two", in: sidebar))
        waitForItem("two.txt", inPane: 0)
        waitForFolder("pinned-two")
        XCTAssertTrue(item("one.txt", in: list(1)).exists, "the right pane left pinned-one")
        XCTAssertFalse(item("two.txt", in: list(1)).exists, "the right pane went to pinned-two too")
    }

    /// Go ▸ Back, the toolbar's Back, File ▸ Open and the search field are the
    /// active pane's: only the right pane has been somewhere to go back to,
    /// only the left has a selection, and each keeps its own search.
    func testTheMenusToolbarAndSearchFieldFollowTheActivePane() throws {
        try launchWithRightPaneInSubfolder(defaults: ["selwaySearchDefaultScope": "This Folder"])
        let back = toolbarButton("Back")

        XCTAssertTrue(waitUntil(5) { !back.isEnabled }, "Back is enabled for the left pane")
        assertMenuItem("Back", in: "Go", isEnabled: false, "left pane active")
        assertMenuItem("Open", in: "File", isEnabled: true, "left pane active, alpha.txt selected")

        click(identified("statusBar", in: pane(1)))
        waitForActive(1)
        XCTAssertTrue(waitUntil(5) { back.isEnabled }, "Back is disabled for the right pane")
        assertMenuItem("Back", in: "Go", isEnabled: true, "right pane active")
        assertMenuItem("Open", in: "File", isEnabled: false, "right pane active, nothing selected")

        app.typeKey("f", modifierFlags: .command)
        let field = browserWindow.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F showed no search field")
        XCTAssertTrue(waitUntil(5) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true },
                      "the search field didn't take the keys")
        field.typeText("inn")
        let query = { field.value as? String ?? "" }
        XCTAssertTrue(waitUntil(5) { query().contains("inn") }, "the search field says “\(query())”")

        click(identified("statusBar", in: pane(0)))
        waitForActive(0)
        XCTAssertTrue(waitUntil(5) { !query().contains("inn") }, "the left pane shows the right pane's search")
        XCTAssertTrue(item("beta.txt", in: list(0)).exists, "the left pane was searched")

        click(identified("statusBar", in: pane(1)))
        waitForActive(1)
        XCTAssertTrue(waitUntil(5) { query().contains("inn") }, "the right pane's search is gone: “\(query())”")
    }

    /// New Folder (⌥⌘N) makes the folder in the active pane's folder.
    func testNewFolderGoesIntoTheActivePanesFolder() throws {
        try launchWithRightPaneInSubfolder()
        let subfolder = fixture.root.appendingPathComponent(Fixture.folder)
        click(identified("statusBar", in: pane(1)))
        waitForActive(1)
        let before = fixture.allFolders()

        app.typeKey("n", modifierFlags: [.command, .option])
        let create = app.buttons.matching(Self.named("Create")).firstMatch
        if create.waitForExistence(timeout: 5) {
            create.click()
        } else {
            XCTAssertTrue(pane(1).textFields.firstMatch.waitForExistence(timeout: 5),
                          "New Folder neither asked for a name nor started renaming the new folder")
            app.typeKey(.return, modifierFlags: [])
        }

        var added = Set<String>()
        XCTAssertTrue(waitUntil(10) {
            added = self.fixture.allFolders().subtracting(before)
            return !added.isEmpty
        }, "no folder appeared in the fixture")
        guard let path = added.first else { return }
        let url = URL(fileURLWithPath: path)
        XCTAssertEqual(url.deletingLastPathComponent().path, Fixture.canonicalPath(subfolder.path),
                       "the new folder went into \(url.deletingLastPathComponent().path), not the right pane's folder")
        waitForItem(url.lastPathComponent, inPane: 1)
    }

    /// Go ▸ Switch to Other Pane (⌃⌘O) makes the other pane active and gives
    /// its list the keys: ↓ then selects there.
    func testSwitchToOtherPaneMovesTheActivePaneAndTheKeys() throws {
        try launchWithRightPaneInSubfolder()

        app.typeKey("o", modifierFlags: [.command, .control])
        waitForActive(1)
        waitForFolder(Fixture.folder)
        app.typeKey(.downArrow, modifierFlags: [])
        waitForStatus("1 selected", inPane: 1)
        waitForStatus(Self.selection("alpha.txt"), inPane: 0)

        choose("Switch to Other Pane", in: "Go")
        waitForActive(0)
        waitForFolder(Fixture.rootName)
        app.typeKey(.downArrow, modifierFlags: [])
        waitForStatus(Self.selection("beta.txt"), inPane: 0)
        waitForStatus("1 selected", inPane: 1)
    }

    /// Switch to Other Pane is disabled with one pane.
    func testSwitchToOtherPaneIsDisabledWithOnePane() throws {
        try launchWithStandardFixture()
        assertMenuItem("Switch to Other Pane", in: "Go", isEnabled: false, "with one pane")
        showDualPane()
        assertMenuItem("Switch to Other Pane", in: "Go", isEnabled: true, "with two panes")
    }

    /// Hiding the second pane while it's active leaves the keys in the list
    /// that stays: ↓ moves its selection on.
    func testHidingTheActiveRightPaneKeepsTheKeysInItsList() throws {
        try launchWithStandardFixture()
        showDualPane()
        click(item("beta.txt", in: list(1)))
        waitForActive(1)
        waitForStatus(Self.selection("beta.txt"), inPane: 1)

        toggleDualPane()
        XCTAssertTrue(waitUntil(5) { !self.pane(1).exists }, "the second pane is still shown")
        waitForStatus(Self.selection("beta.txt"))
        app.typeKey(.downArrow, modifierFlags: [])
        waitForStatus(Self.selection("gamma.txt"))
    }

    // MARK: F5 and F6

    /// F5 asks, then copies the selection into the other pane's folder.
    func testF5CopiesTheSelectionIntoTheOtherPanesFolder() throws {
        try launchWithRightPaneInSubfolder()
        let subfolder = fixture.root.appendingPathComponent(Fixture.folder)

        app.typeKey(.F5, modifierFlags: [])
        waitForTransferSheet(asking: "Copy “alpha.txt” to “\(Fixture.folder)”?")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(waitUntil(10) { self.fixture.exists("alpha.txt", in: subfolder) },
                      "alpha.txt wasn't copied into \(Fixture.folder)")
        XCTAssertTrue(fixture.exists("alpha.txt"), "the copy took alpha.txt away from \(Fixture.rootName)")
        waitForItem("alpha.txt", inPane: 1)
        // The copy is selected where it landed, and the left pane stays active.
        waitForStatus(Self.selection("alpha.txt"), inPane: 1)
        XCTAssertTrue(pane(0).isSelected && !pane(1).isSelected, "the copy landing made the right pane active")
    }

    /// F6 asks, then moves the selection; ⌘Z puts it back.
    func testF6MovesTheSelectionAndCommandZUndoesIt() throws {
        try launchWithRightPaneInSubfolder()
        let subfolder = fixture.root.appendingPathComponent(Fixture.folder)

        app.typeKey(.F6, modifierFlags: [])
        waitForTransferSheet(asking: "Move “alpha.txt” to “\(Fixture.folder)”?")
        click(transferSheet.buttons["Move"].firstMatch)

        XCTAssertTrue(waitUntil(10) { self.fixture.exists("alpha.txt", in: subfolder) && !self.fixture.exists("alpha.txt") },
                      "alpha.txt wasn't moved into \(Fixture.folder)")
        waitForItem("alpha.txt", inPane: 1)
        waitForStatus(Self.selection("alpha.txt"), inPane: 1)
        XCTAssertTrue(pane(0).isSelected && !pane(1).isSelected, "the move landing made the right pane active")

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil(10) { self.fixture.exists("alpha.txt") && !self.fixture.exists("alpha.txt", in: subfolder) },
                      "⌘Z didn't move alpha.txt back")
        waitForItem("alpha.txt", inPane: 0)
    }

    /// Escape on the confirmation does nothing.
    func testEscapeCancelsTheConfirmation() throws {
        try launchWithRightPaneInSubfolder()
        let subfolder = fixture.root.appendingPathComponent(Fixture.folder)

        app.typeKey(.F5, modifierFlags: [])
        waitForTransferSheet(asking: "Copy “alpha.txt” to “\(Fixture.folder)”?")
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(waitUntil(5) { !self.transferSheet.exists }, "Escape didn't close the confirmation")
        // A barrier, not a wait: F5 asks again only once the app has handled
        // the Escape, by when a copy it started would have begun.
        app.typeKey(.F5, modifierFlags: [])
        waitForTransferSheet(asking: "Copy “alpha.txt” to “\(Fixture.folder)”?")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { !self.transferSheet.exists }, "Escape didn't close the second confirmation")
        XCTAssertFalse(fixture.exists("alpha.txt", in: subfolder), "Escape copied alpha.txt anyway")
        XCTAssertFalse(item("alpha.txt", in: list(1)).exists, "the right pane lists alpha.txt")
    }

    /// With both panes on one folder, F5 neither asks nor copies, and says
    /// why. Once the other pane is elsewhere, it asks.
    func testF5WithBothPanesOnOneFolderDoesNothing() throws {
        try launchWithStandardFixture()
        showDualPane()
        click(item("alpha.txt", in: list(0)))
        waitForActive(0)
        waitForStatus(Self.selection("alpha.txt"), inPane: 0)

        app.typeKey(.F5, modifierFlags: [])
        // The toast comes instead of the confirmation, so once it's shown
        // there's no confirmation still to come.
        waitForToast("Both panes show the same folder")
        XCTAssertFalse(transferSheet.exists, "F5 asked to copy into the folder alpha.txt is in")
        XCTAssertFalse(fixture.exists("alpha 2.txt"), "F5 copied alpha.txt beside itself")

        doubleClick(item(Fixture.folder, in: list(1)))
        waitForItem(Fixture.innerFile, inPane: 1)
        click(item("alpha.txt", in: list(0)))
        waitForActive(0)
        app.typeKey(.F5, modifierFlags: [])
        waitForTransferSheet(asking: "Copy “alpha.txt” to “\(Fixture.folder)”?")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// F6 from the right pane moves its selection into the left pane's folder.
    func testF6MovesFromTheRightPaneIntoTheLeftPanesFolder() throws {
        try launchWithRightPaneInSubfolder()
        let subfolder = fixture.root.appendingPathComponent(Fixture.folder)
        click(item(Fixture.innerFile, in: list(1)))
        waitForActive(1)
        waitForStatus("1 selected", inPane: 1)

        app.typeKey(.F6, modifierFlags: [])
        waitForTransferSheet(asking: "Move “\(Fixture.innerFile)” to “\(Fixture.rootName)”?")
        click(transferSheet.buttons["Move"].firstMatch)

        XCTAssertTrue(waitUntil(10) {
            self.fixture.exists(Fixture.innerFile) && !self.fixture.exists(Fixture.innerFile, in: subfolder)
        }, "\(Fixture.innerFile) wasn't moved into \(Fixture.rootName)")
        waitForItem(Fixture.innerFile, inPane: 0)
    }

    /// A name taken in the other pane's folder: the copy gets a new one, and
    /// the file there is left as it was.
    func testF5GivesTheCopyANewNameWhenTheNameIsTaken() throws {
        let subfolder = try fixture.makeFolder(Fixture.folder)
        try fixture.makeFile("alpha.txt", size: 7, in: subfolder)
        try launchWithRightPaneInSubfolder()
        waitForItem("alpha.txt", inPane: 1)

        app.typeKey(.F5, modifierFlags: [])
        waitForTransferSheet(asking: "Copy “alpha.txt” to “\(Fixture.folder)”?")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(waitUntil(10) { self.fixture.exists("alpha 2.txt", in: subfolder) },
                      "the copy wasn't made as “alpha 2.txt”")
        XCTAssertEqual(size(of: "alpha 2.txt", in: subfolder), 100, "“alpha 2.txt” isn't the copy of alpha.txt")
        XCTAssertEqual(size(of: "alpha.txt", in: subfolder), 7, "the copy replaced the alpha.txt already there")
        XCTAssertEqual(size(of: "alpha.txt", in: fixture.root), 100, "the copy changed the original")
        waitForItem("alpha 2.txt", inPane: 1)
    }

    /// F5 while the search field has the keys is the field's: no
    /// confirmation. Back in the list, it asks.
    func testF5InTheSearchFieldDoesNothing() throws {
        try launchWithRightPaneInSubfolder(defaults: ["selwaySearchDefaultScope": "This Folder"])
        app.typeKey("f", modifierFlags: .command)
        let field = browserWindow.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F showed no search field")
        XCTAssertTrue(waitUntil(5) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true },
                      "the search field didn't take the keys")

        app.typeKey(.F5, modifierFlags: [])
        XCTAssertFalse(transferSheet.waitForExistence(timeout: 2), "F5 in the search field asked to copy")
        // F5 is the text system's Complete there, as in any text field: it
        // lists completions and puts the first in the field. Escape closes
        // the list and keeps the word, so clear the field to list the folder.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(item("alpha.txt", in: list(0)).waitForExistence(timeout: 5),
                      "clearing F5's completion didn't list the folder again")

        click(item("alpha.txt", in: list(0)))
        waitForActive(0)
        app.typeKey(.F5, modifierFlags: [])
        waitForTransferSheet(asking: "Copy “alpha.txt” to “\(Fixture.folder)”?")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// With one pane, Copy and Move to Other Pane are disabled, and F5 does
    /// nothing.
    func testF5DoesNothingWithOnePane() throws {
        try launchWithStandardFixture()
        click(item("alpha.txt"))
        waitForStatus(Self.selection("alpha.txt"))
        assertMenuItem("Copy to Other Pane", in: "File", isEnabled: false, "with one pane")
        assertMenuItem("Move to Other Pane", in: "File", isEnabled: false, "with one pane")

        app.typeKey(.F5, modifierFlags: [])
        XCTAssertFalse(transferSheet.waitForExistence(timeout: 2), "F5 asked to copy with one pane")
        XCTAssertFalse(fixture.exists("alpha 2.txt"), "F5 copied alpha.txt with one pane")
    }

    /// In Columns view F5 takes the selection ⌘C would: a file selected in a
    /// column. A folder selected in a column is the folder shown, with
    /// nothing selected in it (as for ⌘C), so F5 says to select something.
    func testF5InColumnsViewTakesWhatCommandCWould() throws {
        try launchWithStandardFixture()
        showDualPane()
        click(viewModeSegment("Columns"))
        XCTAssertTrue(text(Fixture.folder, in: firstColumn(1)).waitForExistence(timeout: 10),
                      "the right pane's Columns view doesn't list \(Fixture.folder)")
        click(text(Fixture.folder, in: firstColumn(1)))
        waitForActive(1)
        XCTAssertTrue(text(Fixture.innerFile, in: pane(1)).waitForExistence(timeout: 10),
                      "the right pane didn't show \(Fixture.folder)")

        click(text("alpha.txt", in: firstColumn(0)))
        waitForActive(0)
        app.typeKey(.F5, modifierFlags: [])
        waitForTransferSheet(asking: "Copy “alpha.txt” to “\(Fixture.folder)”?")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { !self.transferSheet.exists }, "Escape didn't close the confirmation")

        click(text(Fixture.folder, in: firstColumn(0)))
        XCTAssertTrue(text(Fixture.innerFile, in: pane(0)).waitForExistence(timeout: 10),
                      "the left pane didn't show \(Fixture.folder)")
        app.typeKey(.F5, modifierFlags: [])
        waitForToast("Select items to copy first")
        XCTAssertFalse(transferSheet.exists, "F5 asked to copy a folder selected in a column")
    }

    // MARK: Drag and drop

    /// A file dragged from one pane to the other's list goes into that pane's
    /// folder, as a drop anywhere does: on one volume, it moves.
    func testDraggingAFileToTheOtherPaneMovesIt() throws {
        try launchWithRightPaneInSubfolder()
        let subfolder = fixture.root.appendingPathComponent(Fixture.folder)

        // Near the bottom of the right list, well below its one row, so the
        // drop is on the folder it shows, not on an item in it.
        let below = list(1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        middle(of: item("alpha.txt", in: list(0))).click(forDuration: 0.8, thenDragTo: below)

        XCTAssertTrue(waitUntil(10) { self.fixture.exists("alpha.txt", in: subfolder) },
                      "alpha.txt wasn't moved into \(Fixture.folder)")
        XCTAssertFalse(fixture.exists("alpha.txt"), "the drop copied alpha.txt instead of moving it")
        waitForItem("alpha.txt", inPane: 1)
    }

    // MARK: New tabs

    /// A new tab (⌘T) shows two panes when the window it came from did; each
    /// tab then shows one or two on its own.
    func testANewTabKeepsTheDualSetting() throws {
        try launchWithStandardFixture()
        showDualPane()

        app.typeKey("t", modifierFlags: .command)
        let tabBar = browserWindow.tabGroups.firstMatch
        XCTAssertTrue(waitUntil(10) { tabBar.exists && tabBar.tabs.count == 2 }, "⌘T opened no tab")
        XCTAssertTrue(waitUntil(10) { Self.isOn(tabBar.tabs.element(boundBy: 1)) }, "the new tab isn't the one shown")
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "the new tab shows one pane")
        waitForItem("alpha.txt", inPane: 0)
        waitForItem("alpha.txt", inPane: 1)

        // One pane in this tab; the first tab keeps its two.
        app.typeKey("p", modifierFlags: [.command, .control])
        XCTAssertTrue(waitUntil(5) { !self.pane(1).exists }, "the new tab still shows two panes")
        click(tabBar.tabs.element(boundBy: 0))
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "hiding a pane in the new tab hid the first tab's")
    }

    /// A new tab follows the last choice in any tab: one pane, after hiding
    /// one in another tab, even from a tab that shows two.
    func testANewTabAfterHidingAPaneInAnotherTabShowsOne() throws {
        try launchWithStandardFixture()
        showDualPane()
        app.typeKey("t", modifierFlags: .command)
        let tabBar = browserWindow.tabGroups.firstMatch
        XCTAssertTrue(waitUntil(10) { tabBar.exists && tabBar.tabs.count == 2 }, "⌘T opened no tab")
        XCTAssertTrue(waitUntil(10) { Self.isOn(tabBar.tabs.element(boundBy: 1)) }, "the new tab isn't the one shown")
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "the new tab shows one pane")
        toggleDualPane()
        XCTAssertTrue(waitUntil(5) { !self.pane(1).exists }, "the new tab still shows two panes")

        click(tabBar.tabs.element(boundBy: 0))
        XCTAssertTrue(waitUntil(10) { Self.isOn(tabBar.tabs.element(boundBy: 0)) }, "the first tab isn't the one shown")
        XCTAssertTrue(pane(1).waitForExistence(timeout: 10), "the first tab lost its second pane")
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitUntil(10) { tabBar.tabs.count == 3 && !Self.isOn(tabBar.tabs.element(boundBy: 0)) },
                      "⌘T opened no third tab")
        waitForItem("alpha.txt", inPane: 0)
        XCTAssertFalse(pane(1).exists, "the third tab shows two panes")
    }
}
