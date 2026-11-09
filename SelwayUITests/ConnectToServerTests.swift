import XCTest

/// Go → Connect to Server… (⌘K) and saved servers under Locations. Nothing here
/// mounts anything: under the UI tests the app never calls NetFS (a mount
/// reports "server not found" after a moment; UITestHooks.mountStatus), since
/// macOS's login agent shows a dialog of its own for a failed connection and
/// waits for it to be dismissed. Saved servers are made-up preferences.
final class ConnectToServerTests: SelwayUITestCase {
    private var sheet: XCUIElement { app.sheets.firstMatch }
    private var addressField: XCUIElement { sheet.textFields["serverAddress"] }
    private var problem: XCUIElement { sheet.staticTexts["connectProblem"] }
    private var problemText: String { problem.value as? String ?? "" }

    private func openSheet(file: StaticString = #filePath, line: UInt = #line) {
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "⌘K didn't open Connect to Server", file: file, line: line)
        XCTAssertTrue(addressField.waitForExistence(timeout: 5), "the sheet has no address field",
                      file: file, line: line)
        addressField.click()
    }

    /// ⌘K opens the sheet with its field focused; a `file:` address is refused
    /// under the field, saying why, and the sheet stays; Cancel closes it.
    func testCommandKOpensTheSheetAnInvalidAddressIsRefusedAndCancelCloses() throws {
        try launchWithStandardFixture()
        openSheet()
        XCTAssertEqual(addressField.label, "Server address")

        addressField.typeText("file:///etc/passwd")
        sheet.buttons["Connect"].click()
        XCTAssertTrue(problem.waitForExistence(timeout: 5), "no error under the field")
        XCTAssertTrue(problemText.contains("“file:”"), "the error doesn't say why: \(problemText)")
        XCTAssertTrue(sheet.exists, "the sheet closed on an invalid address")

        // Typing again clears it.
        addressField.typeText("x")
        XCTAssertTrue(waitUntil(3) { !self.problem.exists }, "the error stayed while typing")

        sheet.buttons["Cancel"].click()
        XCTAssertTrue(waitUntil(5) { !self.sheet.exists }, "Cancel didn't close the sheet")
        XCTAssertTrue(item(Fixture.standardListing[0]).exists, "the window left its folder")
    }

    /// An address with no server, and Escape closing the sheet.
    func testAMissingServerIsRefusedAndEscapeCloses() throws {
        try launchWithStandardFixture()
        openSheet()
        addressField.typeText("smb:///share\r")
        XCTAssertTrue(problem.waitForExistence(timeout: 5), "Return didn't check the address")
        XCTAssertTrue(problemText.contains("server"), "unexpected error: \(problemText)")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { !self.sheet.exists }, "Escape didn't close the sheet")
    }

    /// "+" saves what's typed to the sidebar: a dimmed row under Locations,
    /// "Not connected" to VoiceOver. No password typed is kept.
    func testPlusAddsTheServerToTheSidebar() throws {
        try launchWithStandardFixture()
        openSheet()
        addressField.typeText("smb://someone:secret@selway-uitest.invalid/Plus Share")
        sheet.buttons["Add to Sidebar"].click()
        XCTAssertTrue(sheet.staticTexts["connectNotice"].waitForExistence(timeout: 5), "no word that it was added")
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(waitUntil(5) { !self.sheet.exists }, "Cancel didn't close the sheet")

        let row = serverRow("Plus Share")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the saved server isn't under Locations")
        XCTAssertEqual(row.identifier, "savedServer.notConnected")
        XCTAssertFalse(row.label.contains("secret"), "the password shows in the sidebar")
    }
}

/// Saved servers' rows, from made-up preferences and stand-in volumes.
final class SavedServerRowTests: SelwayUITestCase {
    static let saved: [[String: Any]] = [
        ["id": "away", "address": "smb://selway-uitest.invalid/Away", "name": "Away Share"],
        ["id": "here", "address": "smb://selway-uitest.invalid/Here", "name": "Saved Here"],
    ]

    func testNonASCIIHostShowsPunycodeInSidebarAndRecentServers() throws {
        let lookalike = "gооgle.invalid"
        let shownHost = "gооgle.invalid (xn--ggle-55da.invalid)"
        let saved = [["id": "lookalike", "address": "smb://\(lookalike)/Share", "name": lookalike]]
        try launchWithStandardFixture(defaults: [
            "selwaySavedServers": saved,
            "selwayRecentServers": ["smb://\(lookalike)/Share"],
        ])

        let savedRow = serverRow(shownHost)
        XCTAssertTrue(savedRow.waitForExistence(timeout: 10), "the saved row doesn't include the ASCII host")
        XCTAssertFalse(serverRow(lookalike).exists, "the saved row hides the ASCII host form")

        app.typeKey("k", modifierFlags: .command)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "⌘K didn't open Connect to Server")
        // The row's text is its value, not its label.
        let recent = sheet.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                  "xn--ggle-55da.invalid", "xn--ggle-55da.invalid")).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5), "the recent server doesn't show punycode")
        let text = recent.label + ((recent.value as? String) ?? "")
        XCTAssertTrue(text.contains(lookalike), "the recent server hides its Unicode host")
        sheet.buttons["Cancel"].click()
    }

    /// A saved server that isn't mounted is a dimmed row; one whose share is
    /// mounted (a stand-in volume with its remount address) is the volume's row
    /// only, not a second one.
    func testASavedServerIsDimmedUntilItsShareIsMounted() throws {
        let here = try fixture.makeFolder("here-volume")
        try fixture.makeFile("inside.txt", size: 1, in: here)
        try launch(defaults: ["selwaySavedServers": Self.saved, "selwaySidebarShowNetworkVolumes": true],
                   volumes: [["path": here.path, "name": "Here Volume",
                              "remount": "smb://GUEST:@SELWAY-UITEST.invalid/here"]],
                   expecting: ["here-volume"])
        let away = serverRow("Away Share")
        XCTAssertTrue(away.waitForExistence(timeout: 10), "the saved server isn't under Locations")
        XCTAssertEqual(away.identifier, "savedServer.notConnected")
        XCTAssertTrue(serverRow("Here Volume").waitForExistence(timeout: 5), "the mounted share isn't listed")
        XCTAssertFalse(serverRow("Saved Here").exists, "a mounted saved server has a second row")
    }

    /// Choosing the dimmed row opens Connect to Server already connecting to
    /// it; the server isn't found (the stand-in mount says so), which is said
    /// under the field, and the window stays where it was.
    func testClickingADimmedServerConnectsAndReportsTheFailure() throws {
        try fixture.makeStandardContents()
        try launch(defaults: ["selwaySavedServers": Self.saved], expecting: Fixture.standardListing)
        let away = serverRow("Away Share")
        XCTAssertTrue(away.waitForExistence(timeout: 10), "the saved server isn't under Locations")
        click(away)

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "choosing the row didn't open Connect to Server")
        XCTAssertEqual(sheet.textFields["serverAddress"].value as? String, "smb://selway-uitest.invalid/Away")
        let problem = sheet.staticTexts["connectProblem"]
        XCTAssertTrue(problem.waitForExistence(timeout: 10), "no error for a server that doesn't exist")
        let text = problem.value as? String ?? ""
        XCTAssertTrue(text.contains("selway-uitest.invalid") && text.contains("wasn’t found"), "unexpected error: \(text)")
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(waitUntil(5) { !sheet.exists }, "Cancel didn't close the sheet")
        XCTAssertTrue(item(Fixture.standardListing[0]).exists, "the window left its folder")
    }
}

extension SavedServerRowTests {
    /// The list row around a Locations element, for its highlight.
    private func listRow(_ name: String) -> XCUIElement {
        let rowTypes = NSPredicate(format: "elementType == %lu OR elementType == %lu",
                                   XCUIElement.ElementType.tableRow.rawValue,
                                   XCUIElement.ElementType.outlineRow.rawValue)
        return sidebar.descendants(matching: .any).matching(rowTypes)
            .containing(NSPredicate(format: "label == %@", name)).firstMatch
    }

    /// The arrow keys move the highlight onto a dimmed saved server and past
    /// it without connecting (a login prompt mustn't appear just for moving
    /// through the sidebar). Return connects it, and so does a click on it
    /// while it's highlighted.
    func testArrowingOntoADimmedServerOnlyHighlightsIt() throws {
        try fixture.makeStandardContents()
        try launch(defaults: ["selwaySavedServers": Self.saved], expecting: Fixture.standardListing)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(serverRow("Away Share").waitForExistence(timeout: 10), "the saved server isn't under Locations")
        // Computer is the row above the saved servers, so start from it.
        click(identified("sidebarComputer", in: sidebar))
        waitForFolder(computerName)

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { self.listRow("Away Share").isSelected }, "the arrow key didn't highlight the row")
        XCTAssertFalse(sheet.waitForExistence(timeout: 2), "arrowing onto a saved server started connecting")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { self.listRow("Saved Here").isSelected }, "the highlight didn't move past it")
        XCTAssertFalse(sheet.waitForExistence(timeout: 2), "arrowing past a saved server started connecting")
        XCTAssertEqual(shownFolderName, computerName, "arrowing onto a saved server left the computer")

        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { self.listRow("Away Share").isSelected }, "the arrow key didn't go back")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Return on a saved server didn't connect")
        XCTAssertEqual(sheet.textFields["serverAddress"].value as? String, "smb://selway-uitest.invalid/Away")
        XCTAssertTrue(sheet.staticTexts["connectProblem"].waitForExistence(timeout: 10), "no result")
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(waitUntil(5) { !sheet.exists }, "Cancel didn't close the sheet")

        // Highlighted with the keys, then clicked.
        click(identified("sidebarComputer", in: sidebar))
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { self.listRow("Away Share").isSelected }, "the arrow key didn't highlight the row")
        XCTAssertFalse(sheet.waitForExistence(timeout: 2), "arrowing onto a saved server started connecting")
        click(serverRow("Away Share"))
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "clicking a highlighted saved server didn't connect")
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(waitUntil(5) { !sheet.exists }, "Cancel didn't close the sheet")
    }
}

extension SelwayUITestCase {
    /// A Locations row's VoiceOver element by its name, not the list row around
    /// it. A saved server's says whether it's connected in its identifier.
    func serverRow(_ name: String) -> XCUIElement {
        let element = NSPredicate(format: "label == %@ AND elementType != %lu AND elementType != %lu", name,
                                  XCUIElement.ElementType.tableRow.rawValue,
                                  XCUIElement.ElementType.outlineRow.rawValue)
        return sidebar.descendants(matching: .any).matching(element).firstMatch
    }
}
