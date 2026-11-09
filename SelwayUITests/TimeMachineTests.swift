import XCTest

/// A Time Machine backup disk lists its backups (#62). The tests can't make
/// APFS snapshots or mount them, so the app is given a stand-in disk
/// (UITestHooks.UITestTimeMachine): a folder for the disk, its snapshot names,
/// and which backups' mount points count as mounted.
final class TimeMachineTests: SelwayUITestCase {
    private let uuid = "0B66AB23-B7E2-4BC1-AF51-260CB1817B29"
    private let mountedBackup = "2026-10-26-082530.backup"
    private let unmountedBackup = "2026-10-20-091500.backup"
    private let backedUpVolume = "Macintosh HD - Data"
    private let diskName = "Backup Disk"

    /// A stand-in /Volumes holding the disk (with the manifest Time Machine
    /// leaves at its root) and its two backups' mount points, of which only
    /// the first is mounted and holds a backed-up volume. Launches at the disk.
    private func launchAtBackupDisk(unreadable: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        let volumes = try fixture.makeFolder("Volumes")
        let disk = try fixture.makeFolder(diskName, in: volumes)
        _ = try fixture.makeFile("backup_manifest.plist", size: 10, in: disk)
        _ = try fixture.makeFolder(".Spotlight-V100", in: disk)
        let backups = volumes.appendingPathComponent(".timemachine/\(uuid)", isDirectory: true)
        let mount = backups.appendingPathComponent(mountedBackup, isDirectory: true)
        let volume = mount.appendingPathComponent("\(mountedBackup)/\(backedUpVolume)", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        _ = try fixture.makeFile("notes.txt", size: 100, in: volume)
        try FileManager.default.createDirectory(at: backups.appendingPathComponent(unmountedBackup, isDirectory: true),
                                                withIntermediateDirectories: true)
        let stage: [String: Any] = [
            "volumes": volumes.path, "disk": disk.path, "uuid": uuid,
            "snapshots": ["com.apple.TimeMachine.\(mountedBackup)", "com.apple.TimeMachine.\(unmountedBackup)",
                          "com.apple.os.update-0123456789"],
            "mounted": [mount.path], "unreadable": unreadable,
        ]
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: stage), encoding: .utf8))
        // An unreadable disk lists nothing, so that test starts at /Volumes's stand-in.
        try launch(folder: unreadable ? volumes : disk, additionalArguments: ["-SelwayUITestTimeMachine", json],
                   expecting: unreadable ? [diskName] : [mountedBackup, unmountedBackup], file: file, line: line)
    }

    /// Opens the mounted backup's backed-up volume, which lists notes.txt.
    private func openBackedUpVolume(file: StaticString = #filePath, line: UInt = #line) {
        doubleClick(item(mountedBackup), file: file, line: line)
        waitForFolder(mountedBackup, listing: backedUpVolume, file: file, line: line)
        doubleClick(item(backedUpVolume), file: file, line: line)
        waitForFolder(backedUpVolume, listing: "notes.txt", file: file, line: line)
    }

    func testTheDiskListsItsBackupsAndShowHiddenListsItsFiles() throws {
        try launchAtBackupDisk()
        XCTAssertFalse(item("backup_manifest.plist").exists, "the disk listed its own files, not its backups")
        waitForStatus("2 items")

        app.typeKey(".", modifierFlags: [.command, .shift])
        XCTAssertTrue(item("backup_manifest.plist").waitForExistence(timeout: 10),
                      "Show Hidden Files didn't list the disk's own files")
        XCTAssertFalse(item(mountedBackup).exists, "the backups were still listed with hidden files shown")

        // The disk's own files are still read-only.
        item("backup_manifest.plist").rightClick()
        let rename = browserWindow.menuItems["Rename…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "the file's menu has no Rename…")
        XCTAssertFalse(rename.isEnabled, "Rename… is enabled for a file on a backup disk")
        app.typeKey(.escape, modifierFlags: [])
        let before = fixture.allFolders()
        app.typeKey("n", modifierFlags: [.command, .option])
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "New Folder showed an alert on a backup disk")
        XCTAssertEqual(fixture.allFolders(), before, "New Folder created a folder on a backup disk")

        click(item("backup_manifest.plist"))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(fileList.textFields.firstMatch.waitForExistence(timeout: 2), "Return showed an inline rename field on a backup disk")
        XCTAssertFalse(app.alerts.firstMatch.exists || app.dialogs.firstMatch.exists || app.sheets.firstMatch.exists,
                       "Return showed a rename prompt on a backup disk")
        XCTAssertTrue(item("backup_manifest.plist").exists, "Return renamed a file on a backup disk")

        app.typeKey(".", modifierFlags: [.command, .shift])
        XCTAssertTrue(item(mountedBackup).waitForExistence(timeout: 10), "hiding hidden files didn't bring the backups back")
    }

    func testABackupShowsUnderItsDiskAndUpReturnsToIt() throws {
        try launchAtBackupDisk()
        openBackedUpVolume()

        for segment in [diskName, mountedBackup, backedUpVolume] {
            XCTAssertTrue(pathBar.buttons[segment].exists, "the path bar has no “\(segment)”")
        }
        XCTAssertFalse(pathBar.buttons[".timemachine"].exists, "the path bar shows the snapshot mount")
        XCTAssertFalse(pathBar.buttons[uuid].exists, "the path bar shows the snapshot mount")

        app.typeKey(.upArrow, modifierFlags: .command)
        waitForFolder(mountedBackup, listing: backedUpVolume)
        app.typeKey(.upArrow, modifierFlags: .command)
        waitForFolder(diskName, listing: unmountedBackup)

        // The path bar's disk segment goes back to the backups as well.
        openBackedUpVolume()
        click(pathBar.buttons[diskName])
        waitForFolder(diskName, listing: mountedBackup)
    }

    func testABackupIsReadOnly() throws {
        try launchAtBackupDisk()
        openBackedUpVolume()
        let before = fixture.allFolders()

        // New Folder's shortcut is ⌥⌘N.
        app.typeKey("n", modifierFlags: [.command, .option])
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 2), "New Folder showed a sheet in a backup")
        XCTAssertFalse(app.alerts.firstMatch.exists, "New Folder showed a prompt in a backup")
        XCTAssertEqual(fixture.allFolders(), before, "New Folder created a folder in a backup")

        click(item("notes.txt"))
        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "Move to Trash asked about a file in a backup")
        XCTAssertTrue(item("notes.txt").exists, "Move to Trash removed a file from a backup")

        item("notes.txt").rightClick()
        let rename = browserWindow.menuItems["Rename…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "the file's menu has no Rename…")
        XCTAssertFalse(rename.isEnabled, "Rename… is enabled for a file in a backup")
        let trash = browserWindow.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Move to Trash")).firstMatch
        XCTAssertTrue(trash.exists, "the file's menu has no Move to Trash")
        XCTAssertFalse(trash.isEnabled, "Move to Trash is enabled for a file in a backup")
        XCTAssertTrue(browserWindow.menuItems["Copy"].isEnabled, "Copy isn't enabled for a file in a backup")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// In Columns, the disk's root column stays read-only once a folder in it
    /// is opened: each column goes by its own folder, not the pane's.
    func testTheDiskRootColumnStaysReadOnlyWithAFolderOpened() throws {
        try launchAtBackupDisk()
        click(viewModeSegment("Columns"))
        app.typeKey(".", modifierFlags: [.command, .shift])
        let manifest = text("backup_manifest.plist", in: browserWindow)
        XCTAssertTrue(manifest.waitForExistence(timeout: 10), "Show Hidden Files didn't list the disk's own files")

        click(text(".Spotlight-V100", in: browserWindow))
        waitForFolder(".Spotlight-V100")
        manifest.rightClick()
        let rename = browserWindow.menuItems["Rename…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "the file's menu has no Rename…")
        XCTAssertFalse(rename.isEnabled, "Rename… is enabled in the disk's column with a folder in it opened")
        app.typeKey(.escape, modifierFlags: [])

        click(manifest)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "Return asked for a new name on a backup disk")
        XCTAssertTrue(manifest.exists, "Return renamed a file on a backup disk")
    }

    func testADiskSelwayMayNotReadAsksForFullDiskAccess() throws {
        try launchAtBackupDisk(unreadable: true)
        doubleClick(item(diskName))

        XCTAssertTrue(identified("fullDiskAccess").waitForExistence(timeout: 10),
                      "a Time Machine disk Selway may not read didn't ask for Full Disk Access")
        XCTAssertTrue(browserWindow.buttons["Open Privacy & Security"].exists, "no button to open Privacy & Security")
        XCTAssertFalse(identified("fileList").exists, "the empty listing still shows under the note")

        app.typeKey(.upArrow, modifierFlags: .command)
        XCTAssertTrue(item(diskName).waitForExistence(timeout: 10), "⌘↑ didn't leave the disk")
        XCTAssertFalse(identified("fullDiskAccess").exists, "the note stayed after leaving the disk")
    }

    /// `name` in one of the columns' lists, not the window's title or path bar.
    private func inColumn(_ name: String) -> XCUIElement {
        browserWindow.descendants(matching: .any).matching(identifier: "columnPane")
            .descendants(matching: .staticText).matching(Self.named(name)).firstMatch
    }

    func testInColumnsABackupThatIsntMountedKeepsTheBackupsColumn() throws {
        try launchAtBackupDisk()
        click(viewModeSegment("Columns"))

        let mounted = inColumn(mountedBackup)
        let unmounted = inColumn(unmountedBackup)
        XCTAssertTrue(mounted.waitForExistence(timeout: 10), "Columns didn't list the mounted backup")
        XCTAssertTrue(unmounted.waitForExistence(timeout: 10), "Columns didn't list the unmounted backup")
        let movesDown = unmounted.frame.midY > mounted.frame.midY
        click(mounted)
        app.typeKey(movesDown ? .downArrow : .upArrow, modifierFlags: [])

        XCTAssertTrue(identified("backupUnavailable").waitForExistence(timeout: 10),
                      "the unmounted backup's column didn't show its note")
        waitForFolder(unmountedBackup)
        XCTAssertTrue(mounted.exists && unmounted.exists, "the backups column disappeared")

        // Nothing to go into: the note stays, and so does the column's focus.
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: .command)
        XCTAssertTrue(identified("backupUnavailable").exists, "→ or ⌘↓ left the note")
        XCTAssertTrue(mounted.exists && unmounted.exists, "→ or ⌘↓ lost the backups column")

        app.typeKey(movesDown ? .upArrow : .downArrow, modifierFlags: [])
        waitForFolder(mountedBackup)
        XCTAssertTrue(inColumn(backedUpVolume).waitForExistence(timeout: 10),
                      "the arrow keys stopped moving through the backups column")
        XCTAssertFalse(identified("backupUnavailable").exists, "the note stayed after selecting the mounted backup")
    }

    func testInColumnsADiskSelwayMayNotReadAsksInItsColumn() throws {
        try launchAtBackupDisk(unreadable: true)
        click(viewModeSegment("Columns"))
        let disk = inColumn(diskName)
        XCTAssertTrue(disk.waitForExistence(timeout: 10), "Columns didn't list the disk")
        click(disk)

        XCTAssertTrue(identified("fullDiskAccess").waitForExistence(timeout: 10),
                      "the unreadable disk's column didn't ask for Full Disk Access")
        XCTAssertTrue(browserWindow.buttons["Open Privacy & Security"].exists, "no button to open Privacy & Security")
        XCTAssertTrue(disk.exists, "the column listing the disk disappeared")
    }

    func testABackupThatIsntMountedSaysHowToOpenIt() throws {
        try launchAtBackupDisk()
        doubleClick(item(unmountedBackup))

        XCTAssertTrue(identified("backupUnavailable").waitForExistence(timeout: 10),
                      "opening a backup that isn't mounted didn't say it isn't available")
        XCTAssertTrue(browserWindow.buttons["Open Disk in Finder"].exists, "no button to open the disk in Finder")
        XCTAssertTrue(pathBar.buttons[diskName].exists, "the path bar doesn't show the backup under its disk")
        // It stays: the missing folder isn't treated as deleted.
        XCTAssertFalse(waitUntil(2) { !self.identified("backupUnavailable").exists },
                       "the pane left the backup that isn't mounted")

        app.typeKey(.upArrow, modifierFlags: .command)
        waitForFolder(diskName, listing: mountedBackup)
    }
}
