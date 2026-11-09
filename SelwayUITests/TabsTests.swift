import XCTest

/// Browser windows as tabs, as in Finder: File ▸ New Tab (⌘T) and the tab
/// bar's + open a tab on the folder new windows open (Settings → General),
/// Open in New Tab and a ⌘-double-click open a folder in one, and Settings can
/// open every folder in a tab. Tabs are AppKit's: the tab bar (an
/// accessibility tab group in the window, shown once there are two tabs) has
/// a tab named for each tab's folder, left to right. The editor and
/// Markdown windows never join a browser's tabs.
final class TabsTests: SelwayUITestCase {

    // MARK: Tabs

    /// The browser window's tab bar, when it shows (two tabs or more).
    private var tabBar: XCUIElement { browserWindow.tabGroups.firstMatch }

    /// The tabs' titles, left to right; none while the tab bar is hidden (one tab).
    private var tabTitles: [String] {
        guard tabBar.exists else { return [] }
        return tabBar.tabs.allElementsBoundByIndex.map { $0.title.isEmpty ? $0.label : $0.title }
    }

    /// The tab named for the folder `name`.
    private func tab(_ name: String) -> XCUIElement {
        tabBar.tabs.matching(Self.named(name)).firstMatch
    }

    /// Waits until the window's tabs are `titles`, in order; for a window
    /// with one tab, until the tab bar has gone.
    private func waitForTabs(_ titles: [String], file: StaticString = #filePath, line: UInt = #line) {
        let expected = titles.count > 1 ? titles : []
        let arrived = waitUntil(10) { self.tabTitles == expected }
        if !arrived {
            let dump = XCTAttachment(string: browserWindow.debugDescription)
            dump.lifetime = .keepAlways
            add(dump)
        }
        XCTAssertTrue(arrived, "the tabs are \(tabTitles), not \(titles)", file: file, line: line)
    }

    /// The browser window showing the folder `name` (with several windows open).
    private func window(showing name: String) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title == %@", name)).firstMatch
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

    /// The standard fixture, with the first window on `subfolder`: a tab on the
    /// New windows folder (the fixture's root) then shows something else.
    private func launchInSubfolder(defaults: [String: Any] = [:]) throws {
        try fixture.makeStandardContents()
        try launch(defaults: defaults, folder: fixture.root.appendingPathComponent(Fixture.folder),
                   expecting: [Fixture.innerFile])
        waitForFolder(Fixture.folder)
    }

    // MARK: New Tab

    /// ⌘T adds a tab after the others, on the folder new windows open, and
    /// selects it; the first tab keeps its folder.
    func testCommandTOpensATabOnTheNewWindowsFolder() throws {
        try launchInSubfolder()

        app.typeKey("t", modifierFlags: .command)
        waitForTabs([Fixture.folder, Fixture.rootName])
        waitForFolder(Fixture.rootName, listing: "alpha.txt")

        click(tab(Fixture.folder))
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)

        // macOS's tab overview, in the View menu as in Finder (the changelog says so).
        let view = app.menuBars.menuBarItems["View"]
        XCTAssertTrue(view.waitForExistence(timeout: 5), "no View menu")
        view.click()
        XCTAssertTrue(view.menuItems["Show All Tabs"].waitForExistence(timeout: 5), "the View menu has no Show All Tabs")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// File ▸ New Tab, chosen with the mouse, does the same.
    func testFileNewTabOpensATab() throws {
        try launchInSubfolder()

        choose("New Tab", in: "File")
        waitForTabs([Fixture.folder, Fixture.rootName])
        waitForFolder(Fixture.rootName, listing: "alpha.txt")
    }

    /// The tab bar's + opens a tab on the New windows folder, as ⌘T does.
    func testTheTabBarsPlusButtonOpensATab() throws {
        try launchInSubfolder()
        app.typeKey("t", modifierFlags: .command)
        waitForTabs([Fixture.folder, Fixture.rootName])
        click(tab(Fixture.folder))
        waitForFolder(Fixture.folder)

        let naming = NSPredicate(format: "label ==[c] %@ OR title ==[c] %@ OR identifier CONTAINS[c] %@",
                                 "New Tab", "New Tab", "newtab")
        let plus = browserWindow.descendants(matching: .button).matching(naming).firstMatch
        if !plus.waitForExistence(timeout: 5) {
            let dump = XCTAttachment(string: browserWindow.debugDescription)
            dump.lifetime = .keepAlways
            add(dump)
        }
        click(plus)
        waitForTabs([Fixture.folder, Fixture.rootName, Fixture.rootName])
        waitForFolder(Fixture.rootName, listing: "alpha.txt")
    }

    /// ⌘W closes the tab shown; the window stays, on the other tab.
    func testCommandWClosesOnlyTheTabShown() throws {
        try launchInSubfolder()
        app.typeKey("t", modifierFlags: .command)
        waitForTabs([Fixture.folder, Fixture.rootName])
        waitForFolder(Fixture.rootName, listing: "alpha.txt")

        app.typeKey("w", modifierFlags: .command)
        waitForTabs([Fixture.folder])
        XCTAssertTrue(browserWindow.waitForExistence(timeout: 5), "⌘W closed the whole window")
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    // MARK: Opening folders in tabs

    /// The context menu's Open in New Tab opens the folder in a tab of this window.
    func testOpenInNewTabShowsTheFolder() throws {
        try launchWithStandardFixture()

        item(Fixture.folder).rightClick()
        let open = app.menuItems["Open in New Tab"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "the folder's menu has no Open in New Tab")
        open.click()
        waitForTabs([Fixture.rootName, Fixture.folder])
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    /// Issue #84: a window opened with ⌘N while a tab is on its way doesn't
    /// take that tab's folder and join the tabs in its place. The tab's window
    /// is held back 8 s (UITestHooks.windowOpenDelay), so ⌘N's comes first.
    func testANewWindowDoesNotTakeATabStillOnItsWay() throws {
        try fixture.makeStandardContents()
        try launch(additionalArguments: ["-SelwayUITestWindowOpenDelay", "8"], expecting: Fixture.standardListing)
        waitForFolder(Fixture.rootName)

        item(Fixture.folder).rightClick()
        let open = app.menuItems["Open in New Tab"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "the folder's menu has no Open in New Tab")
        open.click()
        app.typeKey("n", modifierFlags: .command)

        // ⌘N's window: on the New windows folder (the root), a window of its own.
        let onRoot = app.windows.matching(NSPredicate(format: "title == %@", Fixture.rootName))
        XCTAssertTrue(waitUntil(4) { onRoot.count == 2 },
                      "⌘N didn't open a second window on \(Fixture.rootName); windows: \(app.windows.allElementsBoundByIndex.map(\.title))")
        XCTAssertFalse(app.windows.matching(NSPredicate(format: "title == %@", Fixture.folder)).firstMatch.exists,
                       "⌘N's window took the tab's folder")
        XCTAssertEqual(app.tabGroups.count, 0, "a window joined the tabs before the tab came")

        // Then the tab comes, on the folder, after the window it was asked from.
        let tabbed = app.tabGroups.firstMatch
        XCTAssertTrue(waitUntil(15) {
            tabbed.exists && tabbed.tabs.allElementsBoundByIndex.map { $0.title.isEmpty ? $0.label : $0.title }
                == [Fixture.rootName, Fixture.folder]
        }, "the tab didn't join its window")
    }

    /// A ⌘-double-click on a folder opens it in a new tab, as in Finder (List view).
    func testCommandDoubleClickOpensAFolderInANewTab() throws {
        try launchWithStandardFixture()

        XCUIElement.perform(withKeyModifiers: .command) { doubleClick(item(Fixture.folder)) }
        waitForTabs([Fixture.rootName, Fixture.folder])
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    /// The same in Icons view.
    func testCommandDoubleClickOpensAFolderInANewTabInIconsView() throws {
        try launchWithStandardFixture(defaults: ["selwayViewMode": "icons"])

        XCUIElement.perform(withKeyModifiers: .command) { doubleClick(item(Fixture.folder)) }
        waitForTabs([Fixture.rootName, Fixture.folder])
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    /// The same in Columns view, where a plain double-click shows the folder
    /// as the next column. The first click selects the folder, so the first
    /// tab is named for it too (Columns view names a window for its selected
    /// folder, as Finder does); the new tab starts at the folder, its first
    /// column listing what's inside.
    func testCommandDoubleClickOpensAFolderInANewTabInColumnsView() throws {
        try launchWithStandardFixture()
        click(viewModeSegment("Columns"))
        let firstColumn = { self.browserWindow.descendants(matching: .any).matching(identifier: "columnPane").firstMatch }
        let folder = text(Fixture.folder, in: firstColumn())
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "Columns view doesn't list \(Fixture.folder)")

        XCUIElement.perform(withKeyModifiers: .command) { doubleClick(folder) }
        waitForTabs([Fixture.folder, Fixture.folder])
        XCTAssertTrue(text(Fixture.innerFile, in: firstColumn()).waitForExistence(timeout: 10),
                      "the new tab's first column isn't \(Fixture.folder)")
        XCTAssertFalse(text("alpha.txt", in: firstColumn()).exists, "the new tab starts at \(Fixture.rootName)")
    }

    /// Settings → General → Double-click a folder to open it in: A new tab.
    /// A double-click opens the folder in a tab, and the first tab keeps its
    /// folder; ⌘O on two folders opens both, each in a tab, in list order.
    func testFoldersOpenInTabsWhenSettingsSaySo() throws {
        try fixture.makeStandardContents()
        try fixture.makeFolder("other")
        try launch(defaults: ["selwayOpenFoldersIn": "newTab"], expecting: ["other"] + Fixture.standardListing)

        doubleClick(item(Fixture.folder))
        waitForTabs([Fixture.rootName, Fixture.folder])
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)

        click(tab(Fixture.rootName))
        waitForFolder(Fixture.rootName, listing: "alpha.txt")
        click(item("other"))
        XCUIElement.perform(withKeyModifiers: .command) { click(item(Fixture.folder)) }
        waitForStatus("2 selected")
        app.typeKey("o", modifierFlags: .command)
        waitForTabs([Fixture.rootName, Fixture.folder, "other", Fixture.folder])
    }

    // MARK: Moving tabs

    /// Window ▸ Move Tab to New Window and Merge All Windows keep each tab's
    /// folder, and the folder moved is still watched: a file made in it shows
    /// up without a refresh, before and after merging again.
    func testAMovedTabKeepsItsFolderAndFollowsChanges() throws {
        try launchInSubfolder()
        app.typeKey("t", modifierFlags: .command)
        waitForTabs([Fixture.folder, Fixture.rootName])
        waitForFolder(Fixture.rootName, listing: "alpha.txt")

        choose("Move Tab to New Window", in: "Window")
        let rootWindow = window(showing: Fixture.rootName)
        let subWindow = window(showing: Fixture.folder)
        XCTAssertTrue(rootWindow.waitForExistence(timeout: 10), "no window on \(Fixture.rootName) after the move")
        XCTAssertTrue(subWindow.waitForExistence(timeout: 10), "no window on \(Fixture.folder) after the move")
        try fixture.makeFile("late.txt", size: 10)
        XCTAssertTrue(item("late.txt", in: identified("fileList", in: rootWindow)).waitForExistence(timeout: 10),
                      "the moved tab didn't list late.txt, made after the move")

        choose("Merge All Windows", in: "Window")
        let merged = waitUntil(10) { Set(self.tabTitles) == [Fixture.folder, Fixture.rootName] }
        XCTAssertTrue(merged, "Merge All Windows left the tabs \(tabTitles)")
        click(tab(Fixture.rootName))
        waitForFolder(Fixture.rootName, listing: "late.txt")
        try fixture.makeFile("later.txt", size: 10)
        XCTAssertTrue(item("later.txt").waitForExistence(timeout: 10),
                      "the merged tab didn't list later.txt, made after the merge")
        click(tab(Fixture.folder))
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    // MARK: Editor windows

    /// The editor opens a window of its own, never a browser tab, and Merge
    /// All Windows leaves it out.
    func testTheEditorWindowStaysOutOfBrowserTabs() throws {
        try launchWithStandardFixture()
        app.typeKey("t", modifierFlags: .command)
        waitForTabs([Fixture.rootName, Fixture.rootName])
        waitForFolder(Fixture.rootName, listing: "beta.txt")

        doubleClick(item("beta.txt"))
        let editor = window(showing: "beta.txt")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "a double-click on beta.txt opened no editor")
        XCTAssertFalse(editor.tabGroups.firstMatch.exists, "the editor window has a tab bar")
        waitForTabs([Fixture.rootName, Fixture.rootName])

        // From the browser: the editor may not join its tabs.
        click(item("alpha.txt"))
        let windowMenu = app.menuBars.menuBarItems["Window"]
        windowMenu.click()
        let merge = windowMenu.menuItems["Merge All Windows"]
        if merge.waitForExistence(timeout: 3), merge.isEnabled {
            merge.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the editor window went")
        XCTAssertFalse(tabTitles.contains("beta.txt"), "the editor joined the browser's tabs: \(tabTitles)")
        waitForTabs([Fixture.rootName, Fixture.rootName])
    }
}
