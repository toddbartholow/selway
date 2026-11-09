import XCTest
import AppKit

/// Each Settings tab shows all its options without scrolling (issue #49): its
/// height was picked by hand, and fell short when macOS drew taller rows and
/// as rows were added.
final class SettingsWindowTests: SelwayUITestCase {

    /// Tags is left out: its list grows with the tags on this Mac, and past
    /// its cap it is meant to scroll. So is any tab on a screen too short for
    /// it (Sidebar on a laptop), as long as it's as tall as the screen allows.
    func testEveryTabShowsAllItsOptionsWithoutScrolling() throws {
        try launchWithStandardFixture()
        // SettingsWindowHeight's limit: the visible height less 100 for the bars.
        let screenLimit = try XCTUnwrap(NSScreen.main).visibleFrame.height - 100
        for tab in ["General", "Browse", "Sidebar", "Integrations", "Advanced"] {
            let settings = openSettings(tab: tab)
            let form = settings.scrollViews.firstMatch
            XCTAssertTrue(form.waitForExistence(timeout: 5), "Settings → \(tab) has no form")
            // The window resizes to the tab, animated.
            _ = waitUntil(3) { self.isSettled(form) }

            // A grouped form shows a scroll bar only when its content is taller
            // than the form.
            if form.scrollBars.count > 0 {
                XCTAssertGreaterThanOrEqual(settings.frame.height, screenLimit,
                                            "Settings → \(tab) scrolls, though the screen has room for all of it")
            } else {
                let last = try XCTUnwrap(lowestControl(in: form), "Settings → \(tab) has no controls")
                XCTAssertLessThanOrEqual(last.frame.maxY, form.frame.maxY + 1,
                                         "Settings → \(tab): “\(last.label)” is below the bottom of the window")
            }
            settings.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(waitUntil(5) { !settings.exists }, "Settings didn't close")
        }
    }

    /// "Open folders in Selway" is gone (macOS 26 refuses the folder handler),
    /// and without anything an older Selway left behind, General has no
    /// Restore Finder either.
    func testGeneralHasNoFolderHandlerSetting() throws {
        try launchWithStandardFixture()
        let settings = openSettings(tab: "General")
        let form = settings.scrollViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5), "Settings → General has no form")
        XCTAssertTrue(form.descendants(matching: .any)["Check for updates automatically"].waitForExistence(timeout: 5),
                      "Settings → General didn't finish showing")
        for type in [XCUIElement.ElementType.checkBox, .switch] {
            XCTAssertFalse(form.descendants(matching: type)["Open folders in Selway"].exists,
                           "Settings → General still has Open folders in Selway")
        }
        XCTAssertFalse(form.buttons["Restore Finder"].exists,
                       "Settings → General offers Restore Finder with nothing to restore")
    }

    /// With a stand-in for what an older Selway left (UITestHooks.folderHandlerLeftover),
    /// General offers Restore Finder, and the button goes once it has restored.
    func testRestoreFinderUndoesAnOlderSelwaysChanges() throws {
        try fixture.makeStandardContents()
        try launch(additionalArguments: ["-SelwayUITestFolderHandlerLeftover", "YES"], expecting: Fixture.standardListing)
        let settings = openSettings(tab: "General")
        let restore = settings.buttons["Restore Finder"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 5), "Settings → General doesn't offer Restore Finder")
        restore.click()

        let done = settings.staticTexts.matching(NSPredicate(
            format: "value == %@ OR label == %@",
            "Finder restored as the default for folders.", "Finder restored as the default for folders.")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Restore Finder didn't say it restored Finder")
        XCTAssertTrue(waitUntil(5) { !restore.exists }, "Restore Finder is still offered after restoring")
    }

    private static let controlTypes: [XCUIElement.ElementType] = [
        .checkBox, .switch, .button, .popUpButton, .slider, .stepper, .textField, .radioButton, .menuButton,
    ]

    /// The control lowest in the form: the last one there is. Below the
    /// visible part of a form, controls report where they are laid out.
    private func lowestControl(in form: XCUIElement) -> XCUIElement? {
        Self.controlTypes
            .flatMap { form.descendants(matching: $0).allElementsBoundByIndex }
            .filter { $0.exists && !$0.frame.isEmpty }
            .max { $0.frame.maxY < $1.frame.maxY }
    }

    /// The form's frame is the same twice in a row, a moment apart.
    private func isSettled(_ form: XCUIElement) -> Bool {
        let first = form.frame
        Thread.sleep(forTimeInterval: 0.3)
        return form.frame == first
    }
}
