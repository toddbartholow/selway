import Foundation
import Testing
@testable import SelwayCore

@Suite struct ShellOpenBatchTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Feeds (path, seconds after t0) requests through one batch.
    private func placements(_ requests: [(String, TimeInterval)],
                            window: TimeInterval = 0.5) -> [ShellOpenBatch.Placement] {
        var batch = ShellOpenBatch(window: window)
        return requests.map { batch.place(URL(fileURLWithPath: $0.0), at: t0 + $0.1) }
    }

    @Test func separateOpensEachNavigate() {
        // The same folder again later is a new request, not a duplicate.
        #expect(placements([("/a", 0), ("/b", 2), ("/b", 4)]) == [.first, .first, .first])
    }

    @Test func severalFoldersAtOnceGetTheirOwnWindows() {
        #expect(placements([("/a", 0), ("/b", 0.01), ("/c", 0.02)]) == [.first, .additional, .additional])
    }

    /// Regression: opening several files from one folder revealed that folder
    /// once per file, one window each.
    @Test func filesFromOneFolderRevealItOnce() {
        #expect(placements([("/docs", 0), ("/docs/", 0.01), ("/docs", 0.02), ("/other", 0.03), ("/other", 0.04)])
                == [.first, .duplicate, .duplicate, .additional, .duplicate])
    }

    @Test func theWindowSlidesWithEachRequest() {
        // 0.8 is 0.4 s after the previous request, so still the same batch.
        #expect(placements([("/a", 0), ("/a", 0.4), ("/a", 0.8), ("/a", 1.5)])
                == [.first, .duplicate, .duplicate, .first])
    }
}

/// A page firing selway:// links in a burst can't open a window per link.
@Suite struct ShellOpenFloodTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aBurstOpensAtMostTheLimitOfWindows() {
        var batch = ShellOpenBatch(window: 0.5, maxAdditional: 3)
        let placements = (0..<10).map { batch.place(URL(fileURLWithPath: "/f\($0)"), at: t0 + Double($0) * 0.01) }
        #expect(placements == [.first, .additional, .additional, .additional,
                               .overLimit, .overLimit, .overLimit, .overLimit, .overLimit, .overLimit])
        // A request after the burst starts a new batch (navigates, opens no window).
        let later = batch.place(URL(fileURLWithPath: "/later"), at: t0 + 5)
        #expect(later == .first)
    }

    @Test func linkDialogsAreOneAtATimeAndFewPerPeriod() {
        var limiter = ShellLinkPromptLimiter(maxPrompts: 2, period: 10)
        let first = limiter.begin(at: t0)
        let whileShowing = limiter.begin(at: t0 + 1)
        limiter.end()
        let second = limiter.begin(at: t0 + 2)
        limiter.end()
        let third = limiter.begin(at: t0 + 3)
        let afterPeriod = limiter.begin(at: t0 + 10.5)
        limiter.end()
        #expect(first)
        #expect(!whileShowing, "not while one is showing")
        #expect(second)
        #expect(!third, "two in ten seconds already")
        #expect(afterPeriod)
    }
}

@Suite struct ShellEditRoutingTests {
    @Test func fileActionsNeedAKeyBrowserWithoutTextFocus() {
        #expect(ShellEditRouting.fileActionsAllowed(hasBrowserActions: true, keyWindowIsBrowser: true, focus: .other))
        #expect(ShellEditRouting.fileActionsAllowed(hasBrowserActions: true, keyWindowIsBrowser: true, focus: .none))
        #expect(ShellEditRouting.fileActionsAllowed(hasBrowserActions: true, keyWindowIsBrowser: true,
                                                    focus: .nonEditableTextField))
        // Search field / path editor / inline rename, Ace editor.
        for focus in [ShellResponderKind.textView, .editableTextField, .insideWebView] {
            #expect(!ShellEditRouting.fileActionsAllowed(hasBrowserActions: true, keyWindowIsBrowser: true,
                                                         focus: focus))
        }
        // A sheet, Quick Look panel or editor window is key.
        #expect(!ShellEditRouting.fileActionsAllowed(hasBrowserActions: true, keyWindowIsBrowser: false, focus: .other))
        // No browser window published actions.
        #expect(!ShellEditRouting.fileActionsAllowed(hasBrowserActions: false, keyWindowIsBrowser: true, focus: .other))
    }

    @Test func commandsGoToTheBrowserOnlyWhenAllowed() {
        for command in ShellEditCommand.allCases where command != .delete {
            #expect(ShellEditRouting.route(command, hasBrowserActions: true, keyWindowIsBrowser: true,
                                           focus: .other) == .browser)
            #expect(ShellEditRouting.route(command, hasBrowserActions: true, keyWindowIsBrowser: true,
                                           focus: .textView) == .responderChain)
            #expect(ShellEditRouting.route(command, hasBrowserActions: false, keyWindowIsBrowser: false,
                                           focus: .other) == .responderChain)
        }
    }

    /// Edit ▸ Delete only ever deletes text; it never trashes files.
    @Test func deleteAlwaysUsesTheResponderChain() {
        #expect(!ShellEditCommand.delete.hasFileAction)
        #expect(ShellEditRouting.route(.delete, hasBrowserActions: true, keyWindowIsBrowser: true,
                                       focus: .other) == .responderChain)
        #expect(ShellEditRouting.route(.delete, hasBrowserActions: true, keyWindowIsBrowser: true,
                                       focus: .textView) == .responderChain)
    }

    @Test func textInputKinds() {
        #expect(ShellResponderKind.textView.isTextInput)
        #expect(ShellResponderKind.editableTextField.isTextInput)
        #expect(ShellResponderKind.insideWebView.isTextInput)
        #expect(!ShellResponderKind.nonEditableTextField.isTextInput)
        #expect(!ShellResponderKind.other.isTextInput)
        #expect(!ShellResponderKind.none.isTextInput)
    }
}

@Suite struct ShellUndoMenuItemTests {
    @Test func browserItemsNameTheActionAndFollowAvailability() {
        #expect(ShellUndoMenuItem.make(redo: false, browserFocused: true, textInputFocused: false,
                                       fileActionName: "Paste") == ShellUndoMenuItem(title: "Undo Paste", isEnabled: true))
        #expect(ShellUndoMenuItem.make(redo: true, browserFocused: true, textInputFocused: false,
                                       fileActionName: "Move to Trash")
                == ShellUndoMenuItem(title: "Redo Move to Trash", isEnabled: true))
        #expect(ShellUndoMenuItem.make(redo: false, browserFocused: true, textInputFocused: false,
                                       fileActionName: nil) == ShellUndoMenuItem(title: "Undo", isEnabled: false))
        #expect(ShellUndoMenuItem.make(redo: true, browserFocused: true, textInputFocused: false,
                                       fileActionName: nil) == ShellUndoMenuItem(title: "Redo", isEnabled: false))
    }

    /// Text editing keeps ⌘Z: in an editor window or a browser text field the
    /// item stays enabled whatever the file history says.
    @Test func textKeepsAPlainEnabledItem() {
        for name in [nil, "Paste"] as [String?] {
            #expect(ShellUndoMenuItem.make(redo: false, browserFocused: false, textInputFocused: false,
                                           fileActionName: name) == ShellUndoMenuItem(title: "Undo", isEnabled: true))
            #expect(ShellUndoMenuItem.make(redo: true, browserFocused: true, textInputFocused: true,
                                           fileActionName: name) == ShellUndoMenuItem(title: "Redo", isEnabled: true))
        }
    }
}
