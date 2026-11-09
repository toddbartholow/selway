import AppKit
import XCTest

/// Clicking sidebar rows. The list's selection drives navigation (SidebarView),
/// so a click must both go to the folder and leave its row highlighted.
final class SidebarTests: SelwayUITestCase {

    /// Two pinned folders inside the fixture.
    func testClickingAPinnedRowGoesThereAndHighlightsIt() throws {
        let one = try fixture.makeFolder("pinned-one")
        try fixture.makeFile("one.txt", size: 1, in: one)
        let two = try fixture.makeFolder("pinned-two")
        try fixture.makeFile("two.txt", size: 2, in: two)
        try launch(defaults: ["pinnedFolders": [one.path, two.path]], expecting: ["pinned-one", "pinned-two"])

        let oneRow = row("pinned-one", in: sidebar)
        let twoRow = row("pinned-two", in: sidebar)
        XCTAssertTrue(oneRow.waitForExistence(timeout: 10), "pinned-one isn't in the sidebar")
        XCTAssertFalse(oneRow.isSelected, "a pinned row is highlighted before any click")

        click(text("pinned-one", in: sidebar))
        waitForFolder("pinned-one", listing: "one.txt")
        XCTAssertTrue(waitUntil(5) { oneRow.isSelected }, "pinned-one's row isn't highlighted")

        click(text("pinned-two", in: sidebar))
        waitForFolder("pinned-two", listing: "two.txt")
        XCTAssertTrue(waitUntil(5) { twoRow.isSelected && !oneRow.isSelected },
                      "the highlight didn't move to pinned-two")
    }

    /// Recent folders the automount guard refuses are listed without being
    /// looked at (a look mounted them again, or waited on a host that had
    /// gone, at every launch), even one that isn't there; a folder that's gone
    /// from anywhere else is left out. The automount folder is a stand-in, a
    /// fixture folder the app takes for one (`-SelwayUITestAutofsFolder`), so
    /// nothing is mounted.
    func testRecentFoldersUnderAnAutomountFolderAreListedUnchecked() throws {
        try fixture.makeStandardContents()
        let automount = try fixture.makeSibling("AutomountStandIn")
        let unchecked = automount.appendingPathComponent("NotLookedAt", isDirectory: true)
        let gone = fixture.container.appendingPathComponent("GoneFolder", isDirectory: true)
        let kept = try fixture.makeSibling("KeptFolder")
        try launch(defaults: ["selwaySidebarShowRecent": true,
                              "recentFolders": [unchecked.path, gone.path, kept.path]],
                   autofsFolder: automount, expecting: Fixture.standardListing)

        XCTAssertTrue(text("KeptFolder", in: sidebar).waitForExistence(timeout: 10),
                      "a Recent folder that's there isn't listed")
        XCTAssertTrue(text("NotLookedAt", in: sidebar).exists,
                      "a Recent folder in the automount folder isn't listed")
        XCTAssertFalse(text("GoneFolder", in: sidebar).exists, "a Recent folder that's gone is listed")
    }

    /// /Applications, the one Favorites row the tests show: it needs no privacy
    /// permission. The folder is only listed, never changed.
    func testClickingAFavoritesRowGoesThereAndHighlightsIt() throws {
        try launchWithStandardFixture()
        let applications = row("Applications", in: sidebar)
        XCTAssertTrue(applications.waitForExistence(timeout: 10), "Applications isn't in the sidebar")

        click(text("Applications", in: sidebar))
        waitForFolder("Applications")
        XCTAssertTrue(waitUntil(5) { applications.isSelected }, "Applications' row isn't highlighted")
    }

    /// A row under Locations. VoiceOver reads each as one element named after
    /// the volume, whatever role SwiftUI gives it.
    private func locationRow(_ name: String) -> XCUIElement {
        let rowTypes = NSPredicate(format: "elementType == %lu OR elementType == %lu",
                                   XCUIElement.ElementType.tableRow.rawValue,
                                   XCUIElement.ElementType.outlineRow.rawValue)
        return sidebar.descendants(matching: .any).matching(rowTypes)
            .containing(NSPredicate(format: "label == %@ OR value == %@ OR title == %@", name, name, name))
            .firstMatch
    }

    private func ejectButton(_ name: String) -> XCUIElement {
        sidebar.buttons.matching(NSPredicate(format: "label == %@", "Eject \(name)")).firstMatch
    }

    /// The startup disk under Locations (Hard disks shown): its row goes to "/"
    /// and stays highlighted, and it has no eject button. Only listed, never changed.
    func testClickingTheStartupDiskGoesThereAndHighlightsIt() throws {
        let name = try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey])
            .volumeLocalizedName ?? "Macintosh HD"
        try launchWithStandardFixture(defaults: ["selwaySidebarShowHardDisks": true])
        let startup = locationRow(name)
        XCTAssertTrue(startup.waitForExistence(timeout: 10), "\(name) isn't in the sidebar")
        XCTAssertFalse(ejectButton(name).exists, "the startup disk has an eject button")

        click(startup)
        waitForFolder(name, listing: "Applications")
        XCTAssertTrue(waitUntil(5) { startup.isSelected }, "\(name)'s row isn't highlighted")
    }

    /// A disk image under Locations: a stand-in, a folder in the fixture, so no
    /// real volume is touched. Its row has a button named "Eject <name>" for
    /// VoiceOver. Clicking the button doesn't select the row or leave the
    /// folder; the folder isn't a mount point, so nothing is ejected and no
    /// alert appears. The row itself still opens the folder.
    func testAnEjectableRowHasAnEjectButton() throws {
        let image = try fixture.makeFolder("image-volume")
        try fixture.makeFile("inside.txt", size: 1, in: image)
        let name = "Selway Test Image"
        try launch(defaults: ["selwaySidebarShowDiscsAndImages": true],
                   volumes: [["path": image.path, "name": name, "diskImage": true]],
                   expecting: ["image-volume"])
        let imageRow = locationRow(name)
        XCTAssertTrue(imageRow.waitForExistence(timeout: 10), "\(name) isn't in the sidebar")
        let eject = ejectButton(name)
        XCTAssertTrue(eject.waitForExistence(timeout: 5), "\(name) has no button named “Eject \(name)”")

        click(eject)
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 2), "ejecting a folder showed an alert")
        XCTAssertFalse(app.dialogs.firstMatch.exists, "ejecting a folder showed an alert")
        XCTAssertFalse(imageRow.isSelected, "clicking the eject button selected the row")
        XCTAssertTrue(item("image-volume").exists, "clicking the eject button left the folder")

        click(imageRow)
        waitForFolder("image-volume", listing: "inside.txt")
        XCTAssertTrue(waitUntil(5) { imageRow.isSelected }, "\(name)'s row isn't highlighted")
    }

    /// The computer row opens the overview, whose tile follows the stand-in
    /// volume list. Its name is also the pane title and the final path crumb.
    func testComputerRowShowsDiskOverviewAndTracksHistory() throws {
        try fixture.makeStandardContents()
        let volume = try fixture.makeFolder("overview-drive")
        try fixture.makeFile("inside.txt", size: 1, in: volume)
        try launch(volumes: [["path": volume.path, "name": "Overview Drive", "diskImage": true]],
                   expecting: Fixture.standardListing + ["overview-drive"])

        let computer = identified("sidebarComputer", in: sidebar)
        XCTAssertTrue(computer.waitForExistence(timeout: 10), "Locations has no Computer row")
        XCTAssertEqual(computer.label, computerName, "the Computer row's accessibility label isn't its name")
        click(computer)
        waitForFolder(computerName)
        let tile = diskTile("Overview Drive")
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "the overview has no tile for the stand-in volume")
        XCTAssertEqual(tile.label, "Overview Drive", "the tile's accessibility label isn't the volume's name")
        XCTAssertEqual(tile.elementType, .button, "VoiceOver doesn't see the tile as a button")
        XCTAssertTrue(waitUntil(10) { (tile.value as? String)?.contains("free of") == true },
                      "the tile never showed its free space: “\(tile.value ?? "")”")
        XCTAssertTrue(text(computerName, in: pathBar).exists, "the path bar doesn't show the computer name")

        click(tile)
        assertMenuItem("Open", in: "File", isEnabled: true, "with a tile selected")
        click(toolbarButton("Back"))
        waitForFolder(Fixture.rootName, listing: "alpha.txt")
        click(toolbarButton("Forward"))
        waitForFolder(computerName)
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "Forward didn't return to the overview")
        assertMenuItem("Open", in: "File", isEnabled: false, "back at the computer, where nothing is selected")
    }

    /// A double-click opens the tile's own volume, not the first one.
    func testDoubleClickingOverviewTileOpensItsVolume() throws {
        try fixture.makeStandardContents()
        let first = try fixture.makeFolder("overview-drive")
        try fixture.makeFile("inside.txt", size: 1, in: first)
        let second = try fixture.makeFolder("second-drive")
        try fixture.makeFile("second.txt", size: 1, in: second)
        try launch(volumes: [["path": first.path, "name": "Overview Drive", "diskImage": true],
                             ["path": second.path, "name": "Second Drive", "diskImage": true]],
                   expecting: Fixture.standardListing + ["overview-drive", "second-drive"])
        click(identified("sidebarComputer", in: sidebar))

        doubleClick(diskTile("Second Drive"))
        waitForFolder("second-drive", listing: "second.txt")
    }

    /// File ▸ Open (⌘O) opens the selected tile's volume.
    func testOpenOpensTheSelectedOverviewTile() throws {
        try fixture.makeStandardContents()
        let volume = try fixture.makeFolder("overview-drive")
        try fixture.makeFile("inside.txt", size: 1, in: volume)
        try launch(volumes: [["path": volume.path, "name": "Overview Drive", "diskImage": true]],
                   expecting: Fixture.standardListing + ["overview-drive"])
        click(identified("sidebarComputer", in: sidebar))
        let tile = diskTile("Overview Drive")
        click(tile)

        app.typeKey("o", modifierFlags: .command)
        waitForFolder("overview-drive", listing: "inside.txt")
    }

    /// In Icons view, → moves the selection to the next tile, and ⌘↓ opens the
    /// one it moved to.
    func testOverviewArrowSelectionAndCommandDownOpen() throws {
        try fixture.makeStandardContents()
        let first = try fixture.makeFolder("overview-drive")
        try fixture.makeFile("inside.txt", size: 1, in: first)
        let second = try fixture.makeFolder("second-drive")
        try fixture.makeFile("second.txt", size: 1, in: second)
        try launch(defaults: ["selwayViewMode": "icons"],
                   volumes: [["path": first.path, "name": "Overview Drive", "diskImage": true],
                             ["path": second.path, "name": "Second Drive", "diskImage": true]],
                   expecting: Fixture.standardListing + ["overview-drive", "second-drive"])
        click(identified("sidebarComputer", in: sidebar))
        let firstTile = diskTile("Overview Drive")
        let secondTile = diskTile("Second Drive")
        XCTAssertTrue(firstTile.waitForExistence(timeout: 10))
        XCTAssertTrue(secondTile.waitForExistence(timeout: 10))
        click(firstTile)
        XCTAssertTrue(waitUntil(5) { firstTile.isSelected }, "clicking the first tile didn't select it")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { secondTile.isSelected && !firstTile.isSelected },
                      "→ didn't move the selection to the second tile")
        app.typeKey(.downArrow, modifierFlags: .command)
        waitForFolder("second-drive", listing: "second.txt")
        // The opened folder's grid has keyboard focus without a click.
        app.typeKey(.downArrow, modifierFlags: [])
        waitForStatus("1 selected")
    }

    /// Back restores the opened drive's selection, and the overview owns focus
    /// when it appears so arrows work without clicking a tile first.
    func testOverviewBackRestoresSelectionAndKeyboardFocus() throws {
        try fixture.makeStandardContents()
        let first = try fixture.makeFolder("overview-drive")
        let second = try fixture.makeFolder("second-drive")
        try launch(defaults: ["selwayViewMode": "icons"],
                   volumes: [["path": first.path, "name": "Overview Drive", "diskImage": true],
                             ["path": second.path, "name": "Second Drive", "diskImage": true]],
                   expecting: Fixture.standardListing + ["overview-drive", "second-drive"])
        click(identified("sidebarComputer", in: sidebar))
        let firstTile = diskTile("Overview Drive")
        let secondTile = diskTile("Second Drive")
        XCTAssertTrue(firstTile.waitForExistence(timeout: 10))
        click(firstTile)
        app.typeKey(.downArrow, modifierFlags: .command)
        waitForFolder("overview-drive")
        app.typeKey("[", modifierFlags: .command)
        waitForFolder(computerName)
        XCTAssertTrue(waitUntil(5) { firstTile.isSelected }, "Back didn't restore the opened tile's selection")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { secondTile.isSelected }, "the overview didn't keep keyboard focus on arrival")
    }

    /// ⌥⌘C copies the selected overview volume's path.
    func testCopyPathShortcutUsesSelectedOverviewTile() throws {
        try fixture.makeStandardContents()
        let volume = try fixture.makeFolder("overview-drive")
        try launch(volumes: [["path": volume.path, "name": "Overview Drive", "diskImage": true]],
                   expecting: Fixture.standardListing + ["overview-drive"])
        click(identified("sidebarComputer", in: sidebar))
        click(diskTile("Overview Drive"))
        app.typeKey("c", modifierFlags: [.command, .option])
        XCTAssertTrue(waitUntil(5) { NSPasteboard.general.string(forType: .string) == volume.path },
                      "Copy Path didn't copy the selected volume's path")
    }

    /// Clicking unused overview space clears the selection used by File ▸ Open,
    /// and ⌥⌘C then copies nothing.
    func testClickingEmptyOverviewSpaceClearsSelection() throws {
        try fixture.makeStandardContents()
        let volume = try fixture.makeFolder("overview-drive")
        try launch(defaults: ["selwayViewMode": "icons"],
                   volumes: [["path": volume.path, "name": "Overview Drive", "diskImage": true]],
                   expecting: Fixture.standardListing + ["overview-drive"])
        click(identified("sidebarComputer", in: sidebar))
        click(diskTile("Overview Drive"))
        assertMenuItem("Open", in: "File", isEnabled: true, "with a tile selected")
        let overview = identified("diskOverview")
        overview.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.9)).click()
        assertMenuItem("Open", in: "File", isEnabled: false, "after clicking empty overview space")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("unchanged", forType: .string)
        app.typeKey("c", modifierFlags: [.command, .option])
        assertMenuItem("Open", in: "File", isEnabled: false, "after ⌥⌘C with nothing selected")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "unchanged",
                       "⌥⌘C copied a path with no tile selected")
    }

    /// The tile's context menu opens it, and copies its path with the file
    /// menu's Copy Path (and its toast).
    func testOverviewContextMenuOpensAndCopiesPath() throws {
        try fixture.makeStandardContents()
        let volume = try fixture.makeFolder("overview-drive")
        try fixture.makeFile("inside.txt", size: 1, in: volume)
        try launch(volumes: [["path": volume.path, "name": "Overview Drive", "diskImage": true]],
                   expecting: Fixture.standardListing + ["overview-drive"])
        click(identified("sidebarComputer", in: sidebar))
        let tile = diskTile("Overview Drive")
        XCTAssertTrue(tile.waitForExistence(timeout: 10))

        tile.rightClick()
        // In the window: File ▸ Open is in the menu bar.
        let open = browserWindow.menuItems["Open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "the tile context menu has no Open item")
        open.click()
        waitForFolder("overview-drive", listing: "inside.txt")

        click(identified("sidebarComputer", in: sidebar))
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.rightClick()
        let copyPath = browserWindow.menuItems["Copy Path"]
        XCTAssertTrue(copyPath.waitForExistence(timeout: 5), "the tile context menu has no Copy Path item")
        copyPath.click()
        XCTAssertTrue(text("Path copied", in: browserWindow).waitForExistence(timeout: 5),
                      "Copy Path didn't show its confirmation")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), volume.path, "Copy Path copied something else")
    }

    /// List mode uses the same diskTile identifiers and opens a row on a
    /// double-click.
    func testOverviewListRowsOpenOnDoubleClick() throws {
        try fixture.makeStandardContents()
        let volume = try fixture.makeFolder("overview-drive")
        try fixture.makeFile("inside.txt", size: 1, in: volume)
        try launch(defaults: ["selwayViewMode": "list"],
                   volumes: [["path": volume.path, "name": "Overview Drive", "diskImage": true]],
                   expecting: Fixture.standardListing + ["overview-drive"])
        click(identified("sidebarComputer", in: sidebar))
        let row = diskTile("Overview Drive")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the list layout has no disk row")
        doubleClick(row)
        waitForFolder("overview-drive", listing: "inside.txt")
        // The opened folder's list has keyboard focus without a click.
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { self.row("inside.txt", in: self.fileList).isSelected },
                      "↓ didn't select a row in the folder opened from the overview")
    }

    /// With doubled localization strings, a List row sits on one line in a
    /// wide pane and stacks in a narrow one, rather than truncating.
    func testOverviewListStacksForDoubleLocalizedText() throws {
        try fixture.makeStandardContents()
        let volume = try fixture.makeFolder("overview-drive")
        try launch(defaults: ["selwayViewMode": "list"],
                   volumes: [["path": volume.path, "name": "Overview Drive", "diskImage": true]],
                   additionalArguments: ["-NSDoubleLocalizedStrings", "YES"],
                   expecting: Fixture.standardListing + ["overview-drive"], checksItemCount: false)
        click(identified("sidebarComputer", in: sidebar))
        let row = diskTile("Overview Drive")
        XCTAssertTrue(waitUntil(10) { (row.value as? String)?.contains("free of") == true },
                      "the row never showed its capacity")
        let wideHeight = row.frame.height

        // Two panes halve the width (the second opens at the computer too).
        app.typeKey("p", modifierFlags: [.command, .control])
        XCTAssertTrue(identified("pane1").waitForExistence(timeout: 10), "⌃⌘P showed no second pane")
        let narrowRow = diskTile("Overview Drive", in: identified("pane0"))
        XCTAssertTrue(waitUntil(5) { narrowRow.frame.height > wideHeight + 10 },
                      "the row didn't stack in the narrower pane (\(wideHeight) high when wide, "
                      + "\(narrowRow.frame.height) in a pane \(identified("pane0").frame.width) wide)")
    }

    /// At a large Text Size the List rows stack the bar under the name, and a
    /// click on the row's middle (on the bar) still selects it.
    func testClickingAStackedOverviewRowSelectsIt() throws {
        try fixture.makeStandardContents()
        let volume = try fixture.makeFolder("overview-drive")
        try launch(defaults: ["selwayViewMode": "list", "selwayTextSize": 200],
                   volumes: [["path": volume.path, "name": "Overview Drive", "diskImage": true]],
                   expecting: Fixture.standardListing + ["overview-drive"])
        click(identified("sidebarComputer", in: sidebar))
        let row = diskTile("Overview Drive")
        XCTAssertTrue(waitUntil(10) { (row.value as? String)?.contains("free of") == true },
                      "the row never showed its free space")
        click(row)
        XCTAssertTrue(waitUntil(5) { row.isSelected }, "clicking the stacked row didn't select it")
        assertMenuItem("Open", in: "File", isEnabled: true, "with the stacked row selected")
    }

    func testNewFolderShortcutAtComputerDoesNotPromptOrCreate() throws {
        try fixture.makeStandardContents()
        let volume = try fixture.makeFolder("overview-drive")
        try launch(volumes: [["path": volume.path, "name": "Overview Drive", "diskImage": true]],
                   expecting: Fixture.standardListing + ["overview-drive"])
        click(identified("sidebarComputer", in: sidebar))
        waitForFolder(computerName)
        let before = fixture.allFolders()

        // New Folder's current shortcut is ⌥⌘N (as shown by its toolbar help).
        app.typeKey("n", modifierFlags: [.command, .option])

        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 2), "New Folder showed a sheet at the computer")
        XCTAssertFalse(app.alerts.firstMatch.exists, "New Folder showed a prompt at the computer")
        XCTAssertEqual(fixture.allFolders(), before, "New Folder created something at the computer")
    }
}
