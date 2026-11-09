import XCTest
import AppKit

/// Selway ▸ About Selway opens Selway's own About window (not the standard panel): name,
/// version, author, links and copyright, and an Acknowledgments window with the licenses
/// of the software that ships inside the app.
///
/// The links aren't opened under the UI tests: the app records the address a click would
/// have opened (AboutLinks), and the test reads it from `aboutOpenedURL`, so no browser
/// window appears.
final class AboutWindowTests: SelwayUITestCase {

    /// Each link button: its accessibility identifier, its title and the address it opens.
    private static let links: [(id: String, title: String, url: String)] = [
        ("aboutLink-website", "Website", "https://toddbartholow.github.io/selway/"),
        ("aboutLink-github", "GitHub", "https://github.com/toddbartholow/selway"),
        ("aboutLink-changelog", "Changelog", "https://github.com/toddbartholow/selway/blob/main/CHANGELOG.md"),
        ("aboutLink-reportBug", "Report a bug", "https://github.com/toddbartholow/selway/issues/new"),
    ]

    func testAboutWindowShowsSelwayAndOpensItsLinks() throws {
        try launchWithStandardFixture()
        let about = openAbout()

        XCTAssertEqual(label(of: identified("aboutName", in: about)), "Selway")
        let version = label(of: identified("aboutVersion", in: about))
        XCTAssertNotNil(version.range(of: #"^v\d+(\.\d+)+ \(build \d+\)$"#, options: .regularExpression),
                        "the version reads “\(version)”, not like v0.5.21 (build 22)")
        XCTAssertEqual(label(of: identified("aboutAuthor", in: about)), "By Todd Bartholow")
        XCTAssertEqual(label(of: identified("aboutCopyright", in: about)), "© 2026 Todd Bartholow. MIT License.")

        for link in Self.links {
            let button = identified(link.id, in: about)
            XCTAssertTrue(button.waitForExistence(timeout: 5), "About has no \(link.title) button")
            XCTAssertEqual(button.title.isEmpty ? button.label : button.title, link.title)
            XCTAssertTrue(button.isEnabled, "\(link.title) is disabled")
            button.click()
            let opened = identified("aboutOpenedURL", in: about)
            XCTAssertTrue(waitUntil(5) { self.label(of: opened) == link.url },
                          "\(link.title) opened “\(label(of: opened))”, not \(link.url)")
        }
        XCTAssertTrue(identified("aboutAcknowledgments", in: about).exists, "About has no Acknowledgments button")

        // ⌘W closes it, and choosing About again brings back just one.
        about.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil(5) { !about.exists }, "⌘W didn't close the About window")
        _ = openAbout()
        _ = openAbout()
        XCTAssertEqual(aboutWindows.count, 1, "choosing About Selway twice opened a second window")
    }

    func testEscapeClosesTheAboutWindow() throws {
        try launchWithStandardFixture()
        let about = openAbout()
        about.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { !about.exists }, "Escape didn't close the About window")
    }

    /// AppKit offers an unclaimed key equivalent to every window: Escape typed in a browser
    /// window mustn't close the About window behind it.
    func testEscapeInABrowserWindowLeavesAboutOpen() throws {
        try launchWithStandardFixture()
        let about = openAbout()
        pointInBrowserWindow(outside: about).click()
        app.typeKey(.escape, modifierFlags: [])
        // Give a wrongly handled Escape time to close it.
        XCTAssertFalse(waitUntil(2) { !about.exists }, "Escape in the browser window closed About")

        // About itself still closes with Escape once it's key again.
        _ = openAbout()
        about.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { !about.exists }, "Escape didn't close the About window")
    }

    func testAcknowledgmentsListFinderFlowAndSparkleWithTheirLicenses() throws {
        try launchWithStandardFixture()
        let about = openAbout()
        let acknowledgments = openAcknowledgments(from: about)
        for (id, name) in [("finderflow", "FinderFlow"), ("sparkle", "Sparkle"), ("ace", "Ace")] {
            let row = identified("acknowledgment-\(id)", in: acknowledgments)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Acknowledgments doesn't list \(name)")
            XCTAssertEqual(label(of: row), name)
        }

        // FinderFlow is selected first, with its whole MIT notice.
        let notice = identified("acknowledgmentText", in: acknowledgments)
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "no license text is shown")
        XCTAssertTrue(label(of: notice).contains("Gobinda Tarafdar"), "FinderFlow's notice isn't shown first")
        XCTAssertTrue(label(of: notice).contains("Permission is hereby granted"), "FinderFlow's license isn't whole")

        click(identified("acknowledgment-sparkle", in: acknowledgments))
        XCTAssertTrue(waitUntil(5) { self.label(of: notice).contains("Andy Matuschak") },
                      "selecting Sparkle didn't show its notice")
        XCTAssertTrue(label(of: identified("acknowledgmentName", in: acknowledgments)).hasPrefix("Sparkle"))
        XCTAssertTrue(text("MIT License", in: acknowledgments).exists, "Sparkle's license isn't named")

        // Its own ⌘W closes it and leaves the About window.
        acknowledgments.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil(5) { !acknowledgments.exists }, "⌘W didn't close Acknowledgments")
        XCTAssertTrue(about.exists, "closing Acknowledgments closed the About window too")
    }

    /// The list has the focus when the window opens, so the arrow keys work without a
    /// click; the selected component's website link opens its address; Escape closes
    /// the window and leaves About.
    func testAcknowledgmentsTakesArrowKeysOpensWebsitesAndClosesWithEscape() throws {
        try launchWithStandardFixture()
        let about = openAbout()
        let acknowledgments = openAcknowledgments(from: about)
        let notice = identified("acknowledgmentText", in: acknowledgments)
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "no license text is shown")
        XCTAssertTrue(waitUntil(5) { self.label(of: notice).contains("Gobinda Tarafdar") }, "FinderFlow isn't selected first")

        acknowledgments.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { self.label(of: notice).contains("Andy Matuschak") },
                      "↓ in a window just opened didn't select Sparkle: the list doesn't have the focus")

        let homepage = identified("acknowledgmentHomepage", in: acknowledgments)
        XCTAssertTrue(homepage.waitForExistence(timeout: 5), "Sparkle's notice has no website link")
        XCTAssertEqual(homepage.label, "Website, sparkle-project.org")
        homepage.click()
        let opened = identified("aboutOpenedURL", in: acknowledgments)
        XCTAssertTrue(waitUntil(5) { self.label(of: opened) == "https://sparkle-project.org" },
                      "Sparkle's website link opened “\(label(of: opened))”")

        acknowledgments.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { !acknowledgments.exists }, "Escape didn't close Acknowledgments")
        XCTAssertTrue(about.exists, "Escape in Acknowledgments closed the About window too")
    }

    /// Acknowledgments opens beside About rather than over it, their tops level.
    func testAcknowledgmentsOpensBesideAbout() throws {
        try launchWithStandardFixture()
        let about = openAbout()
        let acknowledgments = openAcknowledgments(from: about)
        let aboutFrame = about.frame, frame = acknowledgments.frame
        // On a screen too narrow for it on either side, it keeps to an edge over part of
        // About instead (AboutWindowPlacementTests covers that).
        let visible = try XCTUnwrap(visibleFrame(around: aboutFrame), "About isn't on any screen")
        let room = max(aboutFrame.minX - visible.minX, visible.maxX - aboutFrame.maxX)
        try XCTSkipIf(room < frame.width + 12, "this screen has no room beside About for Acknowledgments")

        XCTAssertFalse(frame.intersects(aboutFrame), "Acknowledgments (\(frame)) covers About (\(aboutFrame))")
        XCTAssertEqual(frame.minY, aboutFrame.minY, accuracy: 4, "Acknowledgments' top isn't level with About's")
        XCTAssertTrue(visible.contains(frame), "Acknowledgments (\(frame)) is partly off the screen (\(visible))")
    }

    /// The window keeps its size whatever is selected: a long license scrolls in its pane
    /// rather than growing the window.
    func testALongLicenseLeavesTheAcknowledgmentsWindowItsSize() throws {
        try launchWithStandardFixture()
        let about = openAbout()
        let acknowledgments = openAcknowledgments(from: about)
        let notice = identified("acknowledgmentText", in: acknowledgments)
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "no license text is shown")
        let size = acknowledgments.frame.size

        click(identified("acknowledgment-ace", in: acknowledgments))
        XCTAssertTrue(waitUntil(5) { self.label(of: notice).contains("Ajax.org") }, "selecting Ace didn't show its notice")
        XCTAssertFalse(waitUntil(2) { acknowledgments.frame.size != size },
                       "selecting Ace resized Acknowledgments from \(size) to \(acknowledgments.frame.size)")

        // XQLint, last in the list, has the whole Apache License: the longest text there.
        let name = identified("acknowledgmentName", in: acknowledgments)
        for _ in 0..<40 where !label(of: name).hasPrefix("XQLint") {
            let shown = label(of: name)
            acknowledgments.typeKey(.downArrow, modifierFlags: [])
            _ = waitUntil(2) { self.label(of: name) != shown }
        }
        XCTAssertTrue(waitUntil(5) { self.label(of: name).hasPrefix("XQLint") }, "↓ never reached XQLint")
        XCTAssertTrue(waitUntil(5) { self.label(of: notice).contains("END OF TERMS AND CONDITIONS") },
                      "XQLint's Apache License isn't shown whole")
        XCTAssertFalse(waitUntil(2) { acknowledgments.frame.size != size },
                       "selecting XQLint resized Acknowledgments from \(size) to \(acknowledgments.frame.size)")
    }

    /// The View menu's text size items change browser, editor and Markdown windows: with
    /// About or Acknowledgments in front there's nothing for them to change.
    func testTextSizeItemsAreDisabledWithAboutInFront() throws {
        try launchWithStandardFixture(defaults: ["selwayTextSize": 100])
        // A browser window in front at the actual size can make its text bigger.
        assertMenuItem("Make Text Bigger", in: "View", isEnabled: true, "with the browser window in front")

        let about = openAbout()
        assertMenuItem("Make Text Bigger", in: "View", isEnabled: false, "with About in front")
        assertMenuItem("Make Text Smaller", in: "View", isEnabled: false, "with About in front")

        _ = openAcknowledgments(from: about)
        assertMenuItem("Make Text Bigger", in: "View", isEnabled: false, "with Acknowledgments in front")
    }

    // MARK: Helpers

    /// The visible frame, in XCUITest's coordinates (origin at the top left of the main
    /// screen, y down), of the screen holding the middle of `frame`.
    private func visibleFrame(around frame: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let flipped = NSScreen.screens.map { screen -> CGRect in
            let visible = screen.visibleFrame
            return CGRect(x: visible.minX, y: primary.frame.maxY - visible.maxY,
                          width: visible.width, height: visible.height)
        }
        return flipped.first { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
    }

    private var aboutWindows: XCUIElementQuery {
        app.windows.matching(NSPredicate(format: "identifier == %@", "aboutWindow"))
    }

    /// Chooses About Selway from the app menu (the first menu named Selway; the second is
    /// Selway's own commands) and returns its window.
    private func openAbout(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let appMenu = app.menuBars.menuBarItems.matching(NSPredicate(format: "title == %@", "Selway"))
            .element(boundBy: 0)
        XCTAssertTrue(appMenu.waitForExistence(timeout: 5), "no Selway menu", file: file, line: line)
        appMenu.click()
        let item = appMenu.menuItems["About Selway"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the Selway menu has no About Selway", file: file, line: line)
        item.click()
        let about = aboutWindows.firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 10), "About Selway didn't open its window", file: file, line: line)
        XCTAssertEqual(about.title, "About Selway", file: file, line: line)
        return about
    }

    /// Clicks the About window's Acknowledgments button and returns the window it opens.
    private func openAcknowledgments(from about: XCUIElement, file: StaticString = #filePath,
                                     line: UInt = #line) -> XCUIElement {
        identified("aboutAcknowledgments", in: about).click()
        let acknowledgments = app.windows.matching(NSPredicate(format: "identifier == %@ OR title == %@",
                                                                "acknowledgmentsWindow", "Acknowledgments")).firstMatch
        XCTAssertTrue(acknowledgments.waitForExistence(timeout: 10), "Acknowledgments didn't open", file: file, line: line)
        return acknowledgments
    }

    /// A harmless place in the browser window (its status bar, or else empty sidebar)
    /// that `window` doesn't cover, so clicking it makes the browser window key.
    private func pointInBrowserWindow(outside window: XCUIElement, file: StaticString = #filePath,
                                      line: UInt = #line) -> XCUICoordinate {
        XCTAssertTrue(browserWindow.waitForExistence(timeout: 10), "no browser window", file: file, line: line)
        let covered = window.frame
        for candidate in [statusBar, sidebar] where candidate.exists {
            let frame = candidate.frame
            for x in stride(from: frame.minX + 8, to: frame.maxX - 8, by: 40) {
                // Low in the sidebar, below its rows; the middle of the status bar.
                let y = candidate == sidebar ? frame.maxY - 12 : frame.midY
                if !covered.contains(CGPoint(x: x, y: y)) {
                    return candidate.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: x - frame.minX, dy: y - frame.minY))
                }
            }
        }
        XCTFail("the About window covers the browser window's status bar and sidebar", file: file, line: line)
        return middle(of: statusBar)
    }

    /// A SwiftUI text's string, which macOS carries as its value (or else its label).
    private func label(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }
}
