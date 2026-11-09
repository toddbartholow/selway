import XCTest

/// The sidebar's Network row (under Locations). Nothing here searches the
/// network: under the UI tests the app always uses a stand-in browser, which
/// finds the servers `-SelwayUITestBonjour` names, and a stand-in resolver,
/// which gives the n-th of them the host "selway-uitest-<n>.local" (or, by a
/// prefix on the name, goes away, is slow, finds nothing, or gives an address
/// Selway won't use: UITestBonjourEntry). Nothing is mounted either: a
/// connection reports "server not found" after a moment
/// (UITestHooks.mountStatus), as in ConnectToServerTests.
final class NetworkBrowserTests: SelwayUITestCase {
    /// Hosts: Studio is selway-uitest-1, Old Mac -2, NAS -3.
    nonisolated static let servers = ["Studio", "Old Mac", "NAS"]
    nonisolated static let listed = ["NAS", "Old Mac", "Studio"]

    var sheet: XCUIElement { app.sheets.firstMatch }
    var addressField: XCUIElement { sheet.textFields["serverAddress"] }
    var problem: XCUIElement { sheet.staticTexts["connectProblem"] }
    var notice: XCUIElement { sheet.staticTexts["connectNotice"] }
    var progress: XCUIElement { sheet.staticTexts["connectProgress"] }

    func launchWithNetwork(_ bonjour: [String] = servers, defaults: [String: Any] = [:],
                           file: StaticString = #filePath, line: UInt = #line) throws {
        try fixture.makeStandardContents()
        try launch(defaults: ["selwaySidebarShowNetwork": true].merging(defaults) { _, new in new },
                   bonjour: bonjour, expecting: Fixture.standardListing, file: file, line: line)
        XCTAssertTrue(networkLabel.waitForExistence(timeout: 10), "no Network row under Locations",
                      file: file, line: line)
    }

    /// The Network row's own element (its name).
    var networkLabel: XCUIElement { identified("networkRow", in: sidebar) }

    /// A server under Network, by the name it shows.
    func networkServer(_ name: String) -> XCUIElement {
        let element = NSPredicate(format: "identifier == %@ AND label == %@", "networkServer", name)
        return sidebar.descendants(matching: .any).matching(element).firstMatch
    }

    var networkServers: XCUIElementQuery {
        sidebar.descendants(matching: .any).matching(identifier: "networkServer")
    }

    var status: XCUIElement { identified("networkStatus", in: sidebar) }

    /// The list row around an element of the sidebar, for its highlight and
    /// disclosure triangle.
    func listRow(containing element: NSPredicate) -> XCUIElement {
        let rowTypes = NSPredicate(format: "elementType == %lu OR elementType == %lu",
                                   XCUIElement.ElementType.tableRow.rawValue,
                                   XCUIElement.ElementType.outlineRow.rawValue)
        return sidebar.descendants(matching: .any).matching(rowTypes).containing(element).firstMatch
    }

    var networkListRow: XCUIElement {
        listRow(containing: NSPredicate(format: "identifier == %@", "networkRow"))
    }

    func serverListRow(_ name: String) -> XCUIElement {
        listRow(containing: NSPredicate(format: "identifier == %@ AND label == %@", "networkServer", name))
    }

    /// The names under Network, top to bottom.
    var listedNames: [String] {
        networkServers.allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }.map(\.label)
    }

    /// Opens or closes Network with its disclosure triangle, which it must have.
    func clickDisclosureTriangle(file: StaticString = #filePath, line: UInt = #line) {
        let triangle = networkListRow.disclosureTriangles.firstMatch
        XCTAssertTrue(triangle.waitForExistence(timeout: 5), "the Network row has no disclosure triangle",
                      file: file, line: line)
        triangle.click()
    }

    /// Highlights Network, then opens (→) or closes (←) it with the keyboard.
    func disclose(open: Bool, file: StaticString = #filePath, line: UInt = #line) {
        if !networkListRow.isSelected { click(networkLabel, file: file, line: line) }
        XCTAssertTrue(waitUntil(5) { self.networkListRow.isSelected }, "clicking Network didn't highlight it",
                      file: file, line: line)
        app.typeKey(open ? .rightArrow : .leftArrow, modifierFlags: [])
    }

    func waitForServers(_ names: [String] = listed, file: StaticString = #filePath, line: UInt = #line) {
        let listed = waitUntil(10) { self.listedNames == names }
        XCTAssertTrue(listed, "Network lists \(listedNames), not \(names)", file: file, line: line)
    }

    func openNetwork(listing names: [String] = listed, file: StaticString = #filePath, line: UInt = #line) {
        clickDisclosureTriangle(file: file, line: line)
        waitForServers(names, file: file, line: line)
    }

    /// Waits for the sheet to show `address`, found and not yet connecting.
    func waitForFoundAddress(_ address: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Connect to Server didn't open", file: file, line: line)
        XCTAssertTrue(waitUntil(10) { self.addressField.value as? String == address },
                      "the sheet shows \(addressField.value ?? "nothing"), not \(address)", file: file, line: line)
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "no word that the server was found", file: file, line: line)
    }

    /// Whether the address field has the keyboard focus: what's typed lands in it.
    func addressFieldTakesTyping(file: StaticString = #filePath, line: UInt = #line) {
        let before = addressField.value as? String ?? ""
        app.typeText("x")
        XCTAssertTrue(waitUntil(3) { (self.addressField.value as? String ?? "") == before + "x" },
                      "the address field doesn't have the focus", file: file, line: line)
    }

    /// Cancel, and Cancel again if the first stopped a connection instead.
    func closeSheet(file: StaticString = #filePath, line: UInt = #line) {
        sheet.buttons["Cancel"].click()
        if !waitUntil(2, { !self.sheet.exists }), sheet.buttons["Cancel"].exists { sheet.buttons["Cancel"].click() }
        XCTAssertTrue(waitUntil(5) { !self.sheet.exists }, "Cancel didn't close the sheet", file: file, line: line)
    }

    // MARK: Opening and closing

    /// Closed at launch, with nothing under it (it hasn't searched). Opened,
    /// it lists the servers found, one row per name, sorted; closed and
    /// opened again, it lists them again.
    func testOpeningNetworkListsTheServersAndClosingHidesThem() throws {
        try launchWithNetwork()
        XCTAssertFalse(networkServers.firstMatch.waitForExistence(timeout: 2), "Network is open at launch")
        XCTAssertFalse(status.exists, "Network shows a search at launch")

        openNetwork()
        XCTAssertFalse(status.exists, "a placeholder shows beside the servers")

        clickDisclosureTriangle()
        XCTAssertTrue(waitUntil(5) { !self.networkServers.firstMatch.exists }, "closing Network left its servers")

        openNetwork()
        XCTAssertTrue(item(Fixture.standardListing[0]).exists, "opening Network left the folder")
    }

    /// → and ← on the highlighted Network row open and close it; ← on a
    /// server under it goes back up to Network.
    func testArrowKeysOpenAndCloseNetwork() throws {
        try launchWithNetwork()
        disclose(open: true)
        waitForServers()

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { self.serverListRow("NAS").isSelected }, "↓ didn't move onto the first server")
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { self.networkListRow.isSelected }, "← on a server didn't go up to Network")

        disclose(open: false)
        XCTAssertTrue(waitUntil(5) { !self.networkServers.firstMatch.exists }, "← didn't close Network")
        disclose(open: true)
        waitForServers()
    }

    /// Network can be reached and opened without the pointer: into the
    /// sidebar with Tab, down to Network, → to open it, ↓ onto a server.
    func testNetworkCanBeReachedWithTheKeyboardAlone() throws {
        try launchWithNetwork()
        let anySelected = { () -> Bool in
            self.sidebar.descendants(matching: .outlineRow).allElementsBoundByIndex.contains(where: \.isSelected)
                || self.sidebar.descendants(matching: .tableRow).allElementsBoundByIndex.contains(where: \.isSelected)
        }
        // Into the sidebar: ⇧⇥ (or ⇥) moves the focus there from the file list.
        var inSidebar = false
        for flags: XCUIElement.KeyModifierFlags in [.shift, .shift, .shift, [], [], []] where !inSidebar {
            app.typeKey(.tab, modifierFlags: flags)
            app.typeKey(.downArrow, modifierFlags: [])
            inSidebar = waitUntil(1) { anySelected() }
        }
        XCTAssertTrue(inSidebar, "Tab never reached the sidebar")
        for _ in 0..<5 where !networkListRow.isSelected {
            app.typeKey(.downArrow, modifierFlags: [])
            _ = waitUntil(1) { self.networkListRow.isSelected }
        }
        XCTAssertTrue(networkListRow.isSelected, "↓ didn't reach Network")
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForServers()
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { self.serverListRow("NAS").isSelected }, "↓ didn't move onto a server")
        XCTAssertFalse(sheet.waitForExistence(timeout: 2), "arrowing onto a server started connecting")
    }

    /// The placeholder row can't be highlighted: ↓ from Network goes past it.
    func testTheArrowKeysSkipThePlaceholder() throws {
        try launchWithNetwork([], defaults: ["selwaySavedServers": [["id": "away", "name": "Away Share",
                                                                    "address": "smb://selway-uitest.invalid/Away"]]])
        clickDisclosureTriangle()
        XCTAssertTrue(status.waitForExistence(timeout: 5), "no placeholder under Network")
        click(networkLabel)
        XCTAssertTrue(waitUntil(5) { self.networkListRow.isSelected }, "clicking Network didn't highlight it")
        app.typeKey(.downArrow, modifierFlags: [])
        let away = listRow(containing: NSPredicate(format: "label == %@", "Away Share"))
        XCTAssertTrue(waitUntil(5) { away.isSelected }, "↓ from Network didn't go past the placeholder")
        XCTAssertFalse(listRow(containing: NSPredicate(format: "identifier == %@", "networkStatus")).isSelected)
    }

    /// Settings → Sidebar → Network off takes the row away (and its search
    /// with it); back on, it's closed again, with nothing under it.
    func testTheSettingsSwitchHidesTheRow() throws {
        try launchWithNetwork()
        openNetwork()

        let settings = openSettings(tab: "Sidebar")
        // By identifier: its label carries the note under it, and "Network
        // volumes" is beside it.
        let toggle = settings.descendants(matching: .any).matching(identifier: "settingsShowNetwork").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no Network switch in Settings → Sidebar")
        XCTAssertTrue(Self.isOn(toggle), "the Network switch is off")
        toggle.click()
        XCTAssertTrue(waitUntil(5) { !self.networkLabel.exists }, "turning the switch off left the Network row")
        XCTAssertFalse(networkServers.firstMatch.exists, "servers are listed without the Network row")

        toggle.click()
        XCTAssertTrue(networkLabel.waitForExistence(timeout: 5), "turning the switch on didn't bring the row back")
        XCTAssertFalse(networkServers.firstMatch.waitForExistence(timeout: 2), "the row came back open")
        XCTAssertFalse(status.exists, "the row came back searching")
        app.typeKey("w", modifierFlags: .command)
    }

    // MARK: Connecting

    /// A click on a server opens Connect to Server looking it up; it stops
    /// at the address it resolved to (not its name), for the user to check,
    /// and connects on Connect. The stand-in mount says it wasn't found.
    func testClickingAServerShowsTheResolvedAddressAndConnectsOnConnect() throws {
        try launchWithNetwork()
        openNetwork()
        click(networkServer("NAS"))

        waitForFoundAddress("smb://selway-uitest-3.local")
        XCTAssertFalse(problem.waitForExistence(timeout: 2), "it connected without asking")
        XCTAssertTrue((notice.value as? String ?? "").contains("NAS"), "the note doesn't name the server")
        sheet.buttons["Connect"].click()
        XCTAssertTrue(problem.waitForExistence(timeout: 10), "Connect didn't connect")
        let text = problem.value as? String ?? ""
        XCTAssertTrue(text.contains("selway-uitest-3.local") && text.contains("wasn’t found"), "unexpected error: \(text)")
        closeSheet()
        XCTAssertTrue(item(Fixture.standardListing[0]).exists, "the window left its folder")
    }

    /// A server connected to before (in Recent Servers) connects as soon as
    /// it's found.
    func testAServerInRecentServersConnectsAtOnce() throws {
        try launchWithNetwork(defaults: ["selwayRecentServers": ["smb://selway-uitest-1.local/Share"]])
        openNetwork()
        click(networkServer("Studio"))
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "clicking a server didn't open Connect to Server")
        XCTAssertTrue(problem.waitForExistence(timeout: 10), "a known server didn't connect at once")
        XCTAssertEqual(addressField.value as? String, "smb://selway-uitest-1.local")
        closeSheet()
    }

    /// The arrow keys move the highlight onto a server and past it without
    /// connecting (a login prompt mustn't appear just for moving through the
    /// sidebar); Return looks it up, and the highlight stays on it.
    func testArrowingOntoAServerOnlyHighlightsIt() throws {
        try launchWithNetwork()
        disclose(open: true)
        waitForServers()

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { self.serverListRow("NAS").isSelected }, "↓ didn't highlight the server")
        XCTAssertFalse(sheet.waitForExistence(timeout: 2), "arrowing onto a server started connecting")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { self.serverListRow("Old Mac").isSelected }, "the highlight didn't move on")
        XCTAssertFalse(sheet.waitForExistence(timeout: 2), "arrowing past a server started connecting")
        XCTAssertTrue(item(Fixture.standardListing[0]).exists, "arrowing onto a server left the folder")

        app.typeKey(.return, modifierFlags: [])
        waitForFoundAddress("smb://selway-uitest-2.local")
        closeSheet()
        XCTAssertTrue(serverListRow("Old Mac").isSelected, "Return moved the highlight off the server")
    }

    /// The row's menu: Connect looks the server up; Save Server in Sidebar
    /// shows its address, and "+" saves it under the row's name.
    func testTheContextMenuConnectsAndSaves() throws {
        try launchWithNetwork()
        openNetwork()

        networkServer("Studio").rightClick()
        let connect = app.menuItems["Connect"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "the server's menu has no Connect")
        connect.click()
        waitForFoundAddress("smb://selway-uitest-1.local")
        closeSheet()

        networkServer("NAS").rightClick()
        let save = app.menuItems["Save Server in Sidebar"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "the server's menu has no Save Server in Sidebar")
        save.click()
        waitForFoundAddress("smb://selway-uitest-3.local")
        XCTAssertTrue((notice.value as? String ?? "").contains("+"), "the note doesn't say to click +")
        XCTAssertFalse(problem.waitForExistence(timeout: 2), "saving connected")
        sheet.buttons["Add to Sidebar"].click()
        XCTAssertTrue(waitUntil(5) { (self.notice.value as? String ?? "").contains("in the sidebar") },
                      "“+” didn't save it")
        closeSheet()
        let saved = sidebar.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "savedServer.notConnected", "NAS"))
            .firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "the saved server isn't under Locations by its name")
    }

    /// Cancel while a server is being looked up stops the lookup; the sheet
    /// stays, ready for an address.
    func testCancelWhileLookingAServerUp() throws {
        try launchWithNetwork(["slow:Slow", "NAS"])
        openNetwork(listing: ["NAS", "Slow"])
        click(networkServer("Slow"))
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "clicking a server didn't open Connect to Server")
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "no progress while looking it up")
        XCTAssertTrue((progress.value as? String ?? "").contains("Slow"), "the progress doesn't name the server")
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(waitUntil(5) { !self.progress.exists }, "Cancel didn't stop the lookup")
        XCTAssertTrue(sheet.exists, "Cancel during the lookup closed the sheet")
        XCTAssertEqual(addressField.value as? String ?? "", "", "an address arrived after Cancel")
        addressFieldTakesTyping()
        closeSheet()
    }

    /// A lookup that finds nothing, or an address Selway won't use, says so
    /// under the field, which has the focus, and nothing connects.
    func testFailedLookupsSaySoAndFocusTheField() throws {
        try launchWithNetwork(["lost:Lost", "bad:Bad"])
        openNetwork(listing: ["Bad", "Lost"])

        click(networkServer("Lost"))
        XCTAssertTrue(problem.waitForExistence(timeout: 10), "no word that the server wasn't found")
        XCTAssertTrue((problem.value as? String ?? "").contains("Couldn’t find “Lost”"), "\(problem.value ?? "")")
        addressFieldTakesTyping()
        closeSheet()

        click(networkServer("Bad"))
        XCTAssertTrue(problem.waitForExistence(timeout: 10), "no word that the address was refused")
        let text = problem.value as? String ?? ""
        XCTAssertTrue(text.contains("won’t connect to") && text.contains("above"), "unexpected message: \(text)")
        XCTAssertFalse(text.contains("example.com"), "the refused host is shown as if usable")
        addressFieldTakesTyping()
        closeSheet()
    }

    // MARK: Servers coming and going

    /// A highlighted server that goes away hands the highlight to Network.
    func testAHighlightedServerThatGoesAwayHandsTheHighlightToNetwork() throws {
        try launchWithNetwork(["drop:Gone", "Stays"])
        disclose(open: true)
        waitForServers(["Gone", "Stays"])
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { self.serverListRow("Gone").isSelected }, "↓ didn't highlight the server")
        XCTAssertTrue(waitUntil(15) { !self.networkServer("Gone").exists }, "the server didn't go away")
        XCTAssertTrue(waitUntil(5) { self.networkListRow.isSelected }, "the highlight didn't move to Network")
        XCTAssertTrue(networkServer("Stays").exists)
    }

    // MARK: Names from the network

    /// A name with a direction override or a control character is shown with
    /// a "�" in its place, to VoiceOver too, and an over-long one is cut.
    func testHostileNamesAreShownSafely() throws {
        let long = String(repeating: "W", count: 200)
        try launchWithNetwork(["Evil\u{202E}gnp.exe", "Bell\u{7}Name", "Alex’s 👨‍💻 Mac", long])
        clickDisclosureTriangle()
        XCTAssertTrue(networkServer("Evil\u{FFFD}gnp.exe").waitForExistence(timeout: 10),
                      "the override isn't shown as a replacement mark: \(listedNames)")
        XCTAssertTrue(networkServer("Bell\u{FFFD}Name").exists, "the control character isn't shown as a mark")
        XCTAssertTrue(networkServer("Alex’s 👨‍💻 Mac").exists, "an emoji name was changed: \(listedNames)")
        XCTAssertTrue(networkServer(String(repeating: "W", count: 62) + "…").exists, "a long name wasn't cut")
        for name in listedNames {
            XCTAssertFalse(name.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\u{7}" },
                           "a hidden character reached the sidebar: \(name.unicodeScalars.map(\.value))")
        }
    }

    /// Two names that would look the same are told apart.
    func testNamesThatLookTheSameAreNumbered() throws {
        try launchWithNetwork(["Office NAS", "Office\u{A0}NAS"])
        openNetwork(listing: ["Office NAS", "Office NAS (2)"])
    }

    // MARK: Nothing to list

    /// With nothing found, the row under Network says it's searching, then
    /// that no servers were found. (Network's own value, "No servers found",
    /// is VoiceOver's value description, which XCUITest can't read: see
    /// NetworkServersTests.theNetworkRowsValueSaysHowTheSearchIsGoing in Core.)
    func testNoServersFoundAfterASearch() throws {
        try launchWithNetwork([])
        clickDisclosureTriangle()
        XCTAssertTrue(status.waitForExistence(timeout: 5), "no placeholder while searching")
        XCTAssertTrue(waitUntil(10) { self.status.label == "No servers found" },
                      "the placeholder says “\(status.label)”, not “No servers found”")
        XCTAssertFalse(networkServers.firstMatch.exists)
    }

    /// With Local Network access off, the row says where to turn it on, in
    /// words VoiceOver reads ("then", not "›").
    func testLocalNetworkAccessOffSaysWhereToAllowIt() throws {
        try launchWithNetwork(["!denied"])
        clickDisclosureTriangle()
        XCTAssertTrue(waitUntil(10) { self.status.label.contains("Local Network") },
                      "the placeholder says “\(status.label)”")
        XCTAssertTrue(status.label.contains("Privacy & Security"), "it doesn't say where: \(status.label)")
        XCTAssertFalse(status.label.contains("›"), "VoiceOver reads a “›”: \(status.label)")
    }
}
