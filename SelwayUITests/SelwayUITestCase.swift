import SystemConfiguration
import XCTest

/// Shared setup and queries for Selway's UI tests.
///
/// Each test gets its own `Fixture` folder and launches the UITest build of the
/// app (bundle identifier `studio.irq.selway.uitest`, its own preferences, no
/// Finder extension) with `-SelwayUITesting YES`, which makes the app start from
/// factory settings with the first-run sheet already seen (see `UITestHooks` in
/// Selway/SelwayApp.swift). `launch` opens the first window on the fixture and
/// waits for its listing; nothing here sleeps for a fixed time.
///
/// Queries go by accessibility identifier where the app sets one (`fileList`,
/// `sidebar`, `pathBar`, `statusBar`, `viewModePicker`, `fileIcon`) and by role
/// and name otherwise. They don't assume whether SwiftUI exposes a list's rows
/// as table rows or outline rows. Clicks land on the middle of the element they
/// name, double-clicks included.
@MainActor
class SelwayUITestCase: XCTestCase {
    private(set) var app: XCUIApplication!
    private(set) var fixture: Fixture!

    /// Launch arguments `UITestHooks` reads (Selway/SelwayApp.swift).
    private enum Hook {
        static let enabled  = "-SelwayUITesting"
        static let folder   = "-SelwayUITestFolder"
        static let defaults = "-SelwayUITestDefaults"
        static let volumes  = "-SelwayUITestVolumes"
        static let autofsFolder = "-SelwayUITestAutofsFolder"
        static let bonjour = "-SelwayUITestBonjour"
        static let linkFollowGate = "-SelwayUITestLinkFollowGate"
        static let promiseSource = "-SelwayUITestPromiseSource"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        fixture = try Fixture()
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning { app.terminate() }
        fixture?.remove()
        app = nil
        fixture = nil
        try super.tearDownWithError()
    }

    // MARK: Launching

    /// The preferences every test starts with: List view sorted by name A→Z,
    /// folders on top, no grouping, path and status bars shown, no preview, and
    /// type icons rather than Quick Look thumbnails (icon previews off, so
    /// tests that measure icons don't depend on when a thumbnail arrives;
    /// IconPreviewTests turns them on). The
    /// sidebar shows only Applications under Favorites (no Desktop / Documents /
    /// Downloads, which would ask for privacy permission), no Locations (what's
    /// there depends on the drives and servers connected; no Network row
    /// either), no Recent and no Tags; new windows and opened folders stay
    /// inside the fixture.
    func standardDefaults() -> [String: Any] {
        [
            "selwayViewMode": "list",
            "selwaySortField": "Name",
            "selwaySortAscending": true,
            "selwayGroupBy": "None",
            "selwayFolderOrder": "Folders on Top",
            "selwayShowHidden": false,
            "selwayShowPreview": false,
            "selwayShowIconPreviews": false,
            "selwayShowPathBar": true,
            "selwayShowStatusBar": true,
            "selwaySidebarFavorites": "applications",
            "selwaySidebarShowRecent": false,
            "selwaySidebarShowTags": false,
            "selwaySidebarShowHardDisks": false,
            "selwaySidebarShowExternalDisks": false,
            "selwaySidebarShowDiscsAndImages": false,
            "selwaySidebarShowNetworkVolumes": false,
            "selwaySidebarShowNetwork": false,
            "selwayNewWindowFolder": "custom",
            "selwayNewWindowCustomFolder": fixture.root.path,
            "selwayOpenFoldersIn": "sameWindow",
        ]
    }

    /// Fills the fixture with its standard contents, launches the app on it and
    /// waits for the listing.
    func launchWithStandardFixture(defaults overrides: [String: Any] = [:],
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        try fixture.makeStandardContents()
        try launch(defaults: overrides, expecting: Fixture.standardListing, file: file, line: line)
    }

    /// Launches the app with the first window on `folder` (the fixture's root by
    /// default) and waits until it lists every name in `expecting`. `volumes`
    /// replaces the Mac's volumes under Locations with stand-ins: each a
    /// folder in the fixture, {"path", "name", "diskImage", "server"}.
    /// `autofsFolder` is a fixture folder the app's automount guard takes for
    /// an automount folder (a link to it is listed unfollowed). `bonjour` is
    /// what the sidebar's Network row finds (the app never searches the real
    /// network under the tests): servers' names, "afp:" before an AFP one's,
    /// or "!denied" for Local Network access turned off. `linkFollowGate`
    /// makes following a link the listing didn't follow (to open it) wait,
    /// as for an unreachable host, until that file exists: the test decides
    /// when the link answers, so nothing depends on how long a step takes.
    /// `promisedFiles` opens a panel ("Promise Source") whose drag promises
    /// those files, "fail:" before one that fails. `itemCount` is the
    /// folder's count when `expecting` names only some of its items (a lazy
    /// grid shows only the icons on screen).
    func launch(defaults overrides: [String: Any] = [:], volumes: [[String: Any]]? = nil, folder: URL? = nil,
                autofsFolder: URL? = nil, bonjour: [String]? = nil, linkFollowGate: URL? = nil,
                promisedFiles: [String]? = nil, additionalArguments: [String] = [],
                expecting names: [String], itemCount: Int? = nil, checksItemCount: Bool = true,
                file: StaticString = #filePath, line: UInt = #line) throws {
        let values = standardDefaults().merging(overrides) { _, new in new }
        let json = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        app.launchArguments = [
            Hook.enabled, "YES",
            Hook.folder, (folder ?? fixture.root).path,
            Hook.defaults, String(decoding: json, as: UTF8.self),
            // No windows restored from an earlier run of the UITest build.
            "-ApplePersistenceIgnoreState", "YES",
            // English, whatever the Mac's language: the tests look for English text.
            "-AppleLanguages", "(en)",
        ]
        if let volumes {
            let list = try JSONSerialization.data(withJSONObject: volumes, options: [.sortedKeys])
            app.launchArguments += [Hook.volumes, String(decoding: list, as: UTF8.self)]
        }
        if let autofsFolder {
            app.launchArguments += [Hook.autofsFolder, autofsFolder.path]
        }
        if let bonjour {
            app.launchArguments += [Hook.bonjour, bonjour.joined(separator: "|")]
        }
        if let linkFollowGate {
            app.launchArguments += [Hook.linkFollowGate, linkFollowGate.path]
        }
        if let promisedFiles {
            app.launchArguments += [Hook.promiseSource, promisedFiles.joined(separator: "|")]
        }
        app.launchArguments += additionalArguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "Selway didn't come to the front",
                      file: file, line: line)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 20), "no browser window appeared", file: file, line: line)
        waitForListing(names, itemCount: itemCount, checksItemCount: checksItemCount, file: file, line: line)
    }

    /// Waits until the file list shows every name and the status bar counts
    /// them, or counts `itemCount` items when given. `checksItemCount` false
    /// skips the count, for launches whose status bar isn't in English.
    func waitForListing(_ names: [String], itemCount: Int? = nil, checksItemCount: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(fileList.waitForExistence(timeout: 15), "no file list", file: file, line: line)
        for name in names {
            XCTAssertTrue(item(name).waitForExistence(timeout: 15), "“\(name)” isn't listed", file: file, line: line)
        }
        guard checksItemCount else { return }
        let count = itemCount ?? names.count
        waitForStatus("\(count) \(count == 1 ? "item" : "items")", file: file, line: line)
    }

    // MARK: Elements

    /// The browser window (the window with a sidebar, which editor windows and
    /// alerts don't have). Tests with more than one browser window find them by
    /// title instead.
    var browserWindow: XCUIElement {
        app.windows.containing(NSPredicate(format: "identifier == %@", "sidebar")).firstMatch
    }

    /// The element with accessibility identifier `identifier` in `container`
    /// (the browser window by default).
    func identified(_ identifier: String, in container: XCUIElement? = nil) -> XCUIElement {
        (container ?? browserWindow).descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The computer overview's tile or row for the volume named `name`. Its
    /// identifier ends in whether the selection is drawn emphasized; nil
    /// matches either.
    func diskTile(_ name: String, emphasized: Bool? = nil, in container: XCUIElement? = nil) -> XCUIElement {
        let states = emphasized.map { [$0] } ?? [true, false]
        let ids = states.map { "diskTile-\(name)-\($0 ? "emphasized" : "unemphasized")" }
        return (container ?? browserWindow).descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", ids)).firstMatch
    }

    /// The list, the icon grid or (grouped) the sectioned list: whichever shows the files.
    var fileList: XCUIElement { identified("fileList") }
    var sidebar: XCUIElement { identified("sidebar") }
    var statusBar: XCUIElement { identified("statusBar") }
    var pathBar: XCUIElement { identified("pathBar") }

    /// This Mac's name, which the app shows for the computer in Locations. Read
    /// as the app reads it: `Host.current()` can wait on DNS.
    var computerName: String {
        SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Computer"
    }

    /// Checks whether `menu` ▸ `title` is enabled, and closes the menu.
    func assertMenuItem(_ title: String, in menu: String, isEnabled enabled: Bool, _ when: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let bar = app.menuBars.menuBarItems[menu]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "no \(menu) menu", file: file, line: line)
        bar.click()
        let item = bar.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the \(menu) menu has no \(title)", file: file, line: line)
        XCTAssertEqual(item.isEnabled, enabled, "\(when): \(menu) ▸ \(title) is \(item.isEnabled ? "enabled" : "disabled")",
                       file: file, line: line)
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Matches an element whose label, title or value is `name`. (SwiftUI text
    /// on macOS carries its string as the value; buttons and rows as the label.)
    static func named(_ name: String) -> NSPredicate {
        NSPredicate(format: "label == %@ OR title == %@ OR value == %@", name, name, name)
    }

    /// The text `name` in `container`.
    func text(_ name: String, in container: XCUIElement) -> XCUIElement {
        container.staticTexts.matching(Self.named(name)).firstMatch
    }

    /// A file's name as shown in the file list.
    func item(_ name: String, in list: XCUIElement? = nil) -> XCUIElement {
        text(name, in: list ?? fileList)
    }

    /// The list row (table or outline row) showing `name`.
    func row(_ name: String, in container: XCUIElement) -> XCUIElement {
        let rowTypes = NSPredicate(format: "elementType == %lu OR elementType == %lu",
                                   XCUIElement.ElementType.tableRow.rawValue,
                                   XCUIElement.ElementType.outlineRow.rawValue)
        let showingName = NSPredicate(format: "elementType == %lu AND (label == %@ OR value == %@)",
                                      XCUIElement.ElementType.staticText.rawValue, name, name)
        return container.descendants(matching: .any).matching(rowTypes).containing(showingName).firstMatch
    }

    /// Sets `url`'s tags in place, as another app would: Finder's tags
    /// attribute, each entry a name and its colour ("Red\n6"; "\n0" for none).
    func tag(_ url: URL, with entries: [String]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        let result = data.withUnsafeBytes {
            setxattr(url.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, data.count, 0, 0)
        }
        XCTAssertEqual(result, 0, "couldn't tag \(url.lastPathComponent): errno \(errno)")
    }

    // MARK: Status bar

    /// Everything the status bar says: "4 items, 1 selected — 100 bytes, Sorted by …".
    var statusText: String {
        guard statusBar.exists else { return "" }
        return [statusBar.label, statusBar.value as? String ?? ""].joined(separator: " ")
    }

    func waitForStatus(_ fragment: String, timeout: TimeInterval = 10,
                       file: StaticString = #filePath, line: UInt = #line) {
        let said = waitUntil(timeout) { self.statusText.contains(fragment) }
        XCTAssertTrue(said, "the status bar never said “\(fragment)”; it says “\(statusText)”",
                      file: file, line: line)
    }

    /// What the status bar says for a selection of the standard files, e.g.
    /// "2 selected — 500 bytes" for alpha.txt and gamma.txt.
    static func selection(_ names: String...) -> String {
        let bytes = Fixture.files.filter { names.contains($0.name) }.reduce(0) { $0 + $1.size }
        return "\(names.count) selected — \(bytes) bytes"
    }

    // MARK: Waiting

    /// Polls `condition` (about ten times a second) until it holds or `timeout`
    /// passes. Returns whether it held.
    @discardableResult
    func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// The folder the browser window shows: its title, which is the folder's
    /// name, or else the path bar's last folder.
    var shownFolderName: String {
        guard browserWindow.exists else { return "" }
        let title = browserWindow.title
        if !title.isEmpty { return title }
        let crumbs = pathBar.buttons.allElementsBoundByIndex.map(\.label).filter { $0 != "Copy Path" }
        return crumbs.last ?? ""
    }

    /// Waits until the browser window shows the folder `name` (and lists `child`).
    func waitForFolder(_ name: String, listing child: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
        let arrived = waitUntil(10) { self.shownFolderName == name }
        XCTAssertTrue(arrived, "the window shows “\(shownFolderName)”, not “\(name)”", file: file, line: line)
        if let child {
            XCTAssertTrue(item(child).waitForExistence(timeout: 10), "“\(name)” doesn't list “\(child)”",
                          file: file, line: line)
        }
    }

    // MARK: Pointer

    /// The middle of `element`.
    func middle(of element: XCUIElement) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    /// A point in the browser window, from screen coordinates (as in `frame`).
    func windowPoint(x: CGFloat, y: CGFloat) -> XCUICoordinate {
        let window = browserWindow.frame
        return browserWindow.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x - window.minX, dy: y - window.minY))
    }

    func click(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "nothing to click: \(element)", file: file, line: line)
        middle(of: element).click()
    }

    func doubleClick(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "nothing to double-click: \(element)",
                      file: file, line: line)
        middle(of: element).doubleClick()
    }

    /// The middle of the file icon in `name`'s list row. The icon is a few points
    /// left of the name (16 pt wide in List view, 18 in the grouped list), so
    /// if the icon isn't exposed as its own element, that's where the point goes.
    func iconPoint(of name: String, file: StaticString = #filePath, line: UInt = #line) -> XCUICoordinate {
        let label = item(name)
        XCTAssertTrue(label.waitForExistence(timeout: 10), "“\(name)” isn't listed", file: file, line: line)
        let icon = row(name, in: fileList).images.matching(identifier: "fileIcon").firstMatch
        if icon.exists, !icon.frame.isEmpty, icon.frame.maxX <= label.frame.minX + 1 {
            return middle(of: icon)
        }
        return label.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: -15, dy: 0))
    }

    // MARK: Settings

    /// Opens Settings (⌘,) at `tab` ("Browse", "Sidebar"…) and returns its window.
    @discardableResult
    func openSettings(tab: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        // SwiftUI's Settings window, not the browser window (whose toolbar may
        // have a button of the same name).
        let settings = app.windows.matching(NSPredicate(format: "identifier == %@ OR title == %@",
                                                        "com_apple_SwiftUI_Settings_window", "General")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings didn't open", file: file, line: line)
        let button = settings.toolbars.buttons[tab].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Settings has no \(tab) tab", file: file, line: line)
        button.click()
        return settings
    }

    // MARK: Toolbar

    /// The toolbar view-mode picker's segment for `mode` (Icons, List, Columns),
    /// as ToolbarTests finds it.
    func viewModeSegment(_ mode: String) -> XCUIElement {
        let found = identified("viewModePicker")
        let picker = found.exists ? found : browserWindow.toolbars.radioGroups.firstMatch
        for candidates in [picker.radioButtons, picker.buttons] {
            let named = candidates.matching(Self.named(mode)).firstMatch
            if named.exists { return named }
        }
        return picker.radioButtons.element(boundBy: ["Icons", "List", "Columns"].firstIndex(of: mode) ?? 0)
    }

    /// A toolbar button by its label ("Back", "Forward", "New Folder").
    func toolbarButton(_ label: String) -> XCUIElement {
        let toolbar = browserWindow.toolbars.firstMatch
        let button = toolbar.buttons.matching(Self.named(label)).firstMatch
        if button.waitForExistence(timeout: 3) { return button }
        return toolbar.descendants(matching: .any).matching(Self.named(label)).firstMatch
    }

    /// True for a selected segment, radio button, checkbox or row.
    static func isOn(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        if element.isSelected { return true }
        if let number = element.value as? NSNumber { return number.boolValue }
        if let string = element.value as? String { return string == "1" }
        return false
    }
}
