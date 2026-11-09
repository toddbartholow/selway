import Foundation
import Testing
@testable import SelwayCore

/// Regression: a click on an icon selected it only once the double-click
/// interval had run out (a double tap gesture ahead of the single one).
@Suite struct ShellIconClickTests {
    private let order = ["a", "b", "c", "d", "e"]

    /// Each mouse-down is told apart by its click count, so no click waits on
    /// another to tell a click from a double-click.
    @Test func theFirstPressSelectsTheSecondOpensAndLaterOnesDoNothing() {
        #expect(ShellIconClick.press(clickCount: 0) == .select)
        #expect(ShellIconClick.press(clickCount: 1) == .select)
        #expect(ShellIconClick.press(clickCount: 2) == .open)
        #expect(ShellIconClick.press(clickCount: 3) == .none)
    }

    /// Regression: a click on one folder and then, quickly, on another opened a
    /// folder. AppKit counted the second click as a double-click's, wherever it
    /// landed; Finder opens only when both presses are on the same item.
    @Test func aQuickClickOnAnotherIconSelectsItRatherThanOpening() {
        var presses = ShellIconClick.PressTracker()
        #expect(presses.press(on: "a", clickCount: 1, at: 10.0, interval: 0.5) == .select)
        #expect(presses.press(on: "b", clickCount: 2, at: 10.3, interval: 0.5) == .select)
        // And B's own second click then opens it, whatever AppKit's count.
        #expect(presses.press(on: "b", clickCount: 3, at: 10.5, interval: 0.5) == .open)
    }

    @Test func aDoubleClickOnOneIconOpensItAndAThirdClickDoesNothing() {
        var presses = ShellIconClick.PressTracker()
        #expect(presses.press(on: "a", clickCount: 1, at: 10.0, interval: 0.5) == .select)
        #expect(presses.press(on: "a", clickCount: 2, at: 10.2, interval: 0.5) == .open)
        #expect(presses.press(on: "a", clickCount: 3, at: 10.4, interval: 0.5) == .none)
    }

    /// The system's double-click speed decides: a press AppKit counts as a
    /// first click selects, however soon it comes.
    @Test func aPressAppKitCountsAsAFirstClickSelects() {
        var presses = ShellIconClick.PressTracker()
        _ = presses.press(on: "a", clickCount: 1, at: 10.0, interval: 0.5)
        #expect(presses.press(on: "a", clickCount: 1, at: 10.1, interval: 0.5) == .select)
    }

    @Test func aSecondPressAfterTheIntervalSelects() {
        var presses = ShellIconClick.PressTracker()
        _ = presses.press(on: "a", clickCount: 1, at: 10.0, interval: 0.5)
        #expect(presses.press(on: "a", clickCount: 2, at: 10.8, interval: 0.5) == .select)
        // A clock that went backwards isn't a double-click either.
        #expect(presses.press(on: "a", clickCount: 2, at: 9.0, interval: 0.5) == .select)
    }

    /// A click on empty space between two presses on one icon ends the series.
    @Test func aClickElsewhereInTheGridEndsTheSeries() {
        var presses = ShellIconClick.PressTracker()
        _ = presses.press(on: "a", clickCount: 1, at: 10.0, interval: 0.5)
        presses.reset()
        #expect(presses.press(on: "a", clickCount: 3, at: 10.3, interval: 0.5) == .select)
    }

    @Test func theFirstPressEverIsAFirstClick() {
        var presses = ShellIconClick.PressTracker()
        #expect(presses.press(on: "a", clickCount: 2, at: 10.0, interval: 0.5) == .select)
    }

    @Test func aClickOnAnUnselectedIconSelectsItAtOnce() {
        #expect(ShellIconClick.click(on: "b", selection: []) == .select(["b"]))
        #expect(ShellIconClick.click(on: "b", selection: ["a", "c"]) == .select(["b"]))
    }

    /// No write when nothing changes: every write redraws the selection.
    @Test func aClickOnTheOnlySelectedIconKeepsIt() {
        #expect(ShellIconClick.click(on: "b", selection: ["b"]) == .keep)
    }

    /// Finder keeps the selection under a click on one of its items, so that a
    /// double-click opens (and a drag carries) all of it.
    @Test func aClickInsideALargerSelectionNarrowsItLater() {
        #expect(ShellIconClick.click(on: "b", selection: ["a", "b", "c"]) == .narrowLater("b"))
    }

    @Test func withNoKeysHeldAClickIsAPlainClick() {
        #expect(ShellIconClick.click(on: "b", selection: ["a", "b"], modifiers: [], anchor: "a", order: order)
                == .narrowLater("b"))
        #expect(ShellIconClick.click(on: "c", selection: ["a"], modifiers: [], anchor: "a", order: order)
                == .select(["c"]))
    }

    /// ⌘ adds an icon at once. It takes a selected one out only once the click
    /// is over (#43): a ⌘-drag from it carries the whole selection.
    @Test func aCommandClickAddsAnIconOrTakesItOutLater() {
        #expect(ShellIconClick.click(on: "c", selection: ["a"], modifiers: .command, anchor: "a", order: order)
                == .select(["a", "c"]))
        #expect(ShellIconClick.click(on: "a", selection: ["a", "c"], modifiers: .command, anchor: "c", order: order)
                == .deselectLater("a"))
        #expect(ShellIconClick.click(on: "a", selection: ["a"], modifiers: .command, anchor: "a", order: order)
                == .deselectLater("a"))
    }

    @Test func aShiftClickAddsTheIconsFromTheLastOneClicked() {
        #expect(ShellIconClick.click(on: "d", selection: ["b"], modifiers: .shift, anchor: "b", order: order)
                == .select(["b", "c", "d"]))
        // Backwards too, and what was selected besides stays selected.
        #expect(ShellIconClick.click(on: "a", selection: ["c", "e"], modifiers: .shift, anchor: "c", order: order)
                == .select(["a", "b", "c", "e"]))
        // ⇧ wins over ⌘.
        #expect(ShellIconClick.click(on: "c", selection: ["a"], modifiers: [.shift, .command], anchor: "a",
                                     order: order) == .select(["a", "b", "c"]))
    }

    @Test func aShiftClickWithNoAnchorAddsTheIconAlone() {
        #expect(ShellIconClick.click(on: "c", selection: ["a"], modifiers: .shift, anchor: nil, order: order)
                == .select(["a", "c"]))
        // An anchor no longer shown (the folder reloaded without it).
        #expect(ShellIconClick.click(on: "c", selection: [], modifiers: .shift, anchor: "gone", order: order)
                == .select(["c"]))
        #expect(ShellIconClick.click(on: "c", selection: ["c"], modifiers: .shift, anchor: nil, order: order)
                == .keep)
    }

    /// The order is only read for a ⇧-click (it is every icon in the grid).
    @Test func onlyAShiftClickReadsTheOrder() {
        var reads = 0
        func counted() -> [String] { reads += 1; return order }
        _ = ShellIconClick.click(on: "c", selection: [], modifiers: [], anchor: "a", order: counted())
        _ = ShellIconClick.click(on: "c", selection: [], modifiers: .command, anchor: "a", order: counted())
        #expect(reads == 0)
        _ = ShellIconClick.click(on: "c", selection: [], modifiers: .shift, anchor: "a", order: counted())
        #expect(reads == 1)
    }

    /// Regression: a click on empty space in Icons view left the selection as it was.
    @Test func aClickOnTheBackgroundClearsTheSelection() {
        #expect(ShellIconClick.clickOnBackground(selection: ["a", "b"]) == .clear)
        #expect(ShellIconClick.clickOnBackground(selection: []) == .keep)
    }

    /// As in Finder, where ⌘ or ⇧ on empty space starts adding to the selection.
    @Test func aClickOnTheBackgroundWithCommandOrShiftKeepsTheSelection() {
        #expect(ShellIconClick.clickOnBackground(selection: ["a"], modifiers: .command) == .keep)
        #expect(ShellIconClick.clickOnBackground(selection: ["a"], modifiers: .shift) == .keep)
    }
}

/// IconClickRouting's click counts (ShellClickSeries), with stand-ins for views.
@Suite struct ShellClickSeriesTests {
    private final class View {
        let isIcon: Bool
        init(icon: Bool) { isIcon = icon }
    }

    private let icon = View(icon: true), otherIcon = View(icon: true)
    private let field = View(icon: false), otherField = View(icon: false)

    private func down(_ series: inout ShellClickSeries, _ count: Int, on hit: View?, after previous: View?) -> Int {
        series.mouseDown(clickCount: count, on: hit, after: previous, isIcon: \.isIcon)
    }

    /// Regression: a double-click on a word in a text field right after a
    /// click on an icon reached the field as clicks 1 and 3, a triple-click.
    @Test func theRestOfARewrittenSeriesIsCountedFromTheRewrittenClick() {
        var series = ShellClickSeries()
        #expect(down(&series, 1, on: icon, after: nil) == 1)
        #expect(down(&series, 2, on: field, after: icon) == 1)
        #expect(series.mouseUp(clickCount: 2) == 1)
        #expect(down(&series, 3, on: field, after: field) == 2)
        #expect(series.mouseUp(clickCount: 3) == 2)
        #expect(down(&series, 4, on: field, after: field) == 3)
        #expect(series.mouseUp(clickCount: 4) == 3)
    }

    @Test func aFirstClickEndsTheOffset() {
        var series = ShellClickSeries()
        _ = down(&series, 2, on: field, after: icon)
        #expect(series.offset == 1)
        #expect(down(&series, 1, on: field, after: field) == 1)
        #expect(series.offset == 0)
        #expect(series.mouseUp(clickCount: 1) == 1)
        #expect(down(&series, 2, on: field, after: field) == 2)
        #expect(series.mouseUp(clickCount: 2) == 2)
    }

    /// A repeat click that moves from one icon to another, or between an icon
    /// and anything else, starts a series of its own on the view under it.
    @Test func aRepeatClickThatMovesToOrFromAnIconIsAFirstClick() {
        var series = ShellClickSeries()
        #expect(down(&series, 2, on: otherIcon, after: icon) == 1)
        #expect(down(&series, 2, on: icon, after: field) == 1)
        // The view clicked before has gone (an icon scrolled away and freed).
        #expect(down(&series, 2, on: icon, after: nil) == 1)
    }

    /// Moving again in the same series counts from the latest move.
    @Test func aSecondMoveInOneSeriesCountsFromThere() {
        var series = ShellClickSeries()
        #expect(down(&series, 2, on: field, after: icon) == 1)
        #expect(down(&series, 3, on: otherIcon, after: field) == 1)
        #expect(series.offset == 2)
        #expect(down(&series, 4, on: otherIcon, after: otherIcon) == 2)
        #expect(series.mouseUp(clickCount: 4) == 2)
    }

    /// Without an icon, or on one view, the system's counts are left alone.
    @Test func clicksWithNoIconOrOnOneViewKeepTheirCounts() {
        var series = ShellClickSeries()
        #expect(down(&series, 2, on: otherField, after: field) == 2)
        #expect(down(&series, 3, on: otherField, after: otherField) == 3)
        #expect(down(&series, 2, on: icon, after: icon) == 2)
        #expect(series.mouseUp(clickCount: 2) == 2)
        #expect(series.offset == 0)
        #expect(down(&series, 2, on: nil, after: nil) == 2)
    }
}

@Suite struct ShellSelectionTests {
    private let items = ["a", "b", "c", "d"]

    @Test func clickInsideSelectionTargetsWholeSelectionInDisplayOrder() {
        let t = ShellSelection.contextTargets(clicked: "c", in: items, selection: ["d", "b", "c"]) { $0 }
        #expect(t == ["b", "c", "d"])
    }

    @Test func clickOutsideSelectionTargetsOnlyClickedItem() {
        // Regression: the grouped list and icon view used the selection here and
        // would trash files the user hadn't right-clicked.
        let t = ShellSelection.contextTargets(clicked: "a", in: items, selection: ["b", "c"]) { $0 }
        #expect(t == ["a"])
    }

    @Test func emptySelectionTargetsClickedItem() {
        #expect(ShellSelection.contextTargets(clicked: "b", in: items, selection: []) { $0 } == ["b"])
    }

    @Test func clickedItemMissingFromListStillTargeted() {
        #expect(ShellSelection.contextTargets(clicked: "z", in: items, selection: ["z"]) { $0 } == ["z"])
    }

    // MARK: Selection when a search starts or ends

    /// Regression: in Columns view a file selected in the results stayed selected
    /// (and hidden) after Escape, so ⌘C / Delete acted on it.
    @Test func columnViewDropsTheSelectionWhenASearchStartsOrEnds() {
        #expect(ShellSelection.afterSearchToggle(["/s/report.pdf"], inColumns: true).isEmpty)
        #expect(ShellSelection.afterSearchToggle([], inColumns: true).isEmpty)
    }

    @Test func listAndIconViewsKeepIt() {
        #expect(ShellSelection.afterSearchToggle(["/s/a", "/s/b"], inColumns: false) == ["/s/a", "/s/b"])
    }
}

@Suite struct ShellGenerationTests {
    @Test func onlyLatestTokenIsCurrent() {
        var g = ShellGeneration()
        let first = g.next()
        let second = g.next()
        #expect(!g.isCurrent(first))
        #expect(g.isCurrent(second))
    }

    @Test func staleResultIsDropped() {
        // Simulates two overlapping background loads finishing out of order.
        var g = ShellGeneration()
        var shown = "initial"
        let older = g.next()
        let newer = g.next()
        if g.isCurrent(newer) { shown = "newer" }
        if g.isCurrent(older) { shown = "older" }
        #expect(shown == "newer")
    }
}

@Suite struct ShellDisplayListTests {
    @Test func mergeUniqueKeepsFirstOccurrence() {
        let merged = ShellDisplayList.mergeUnique([["/a", "/b"], ["/b", "/c", "/a"]]) { $0 }
        #expect(merged == ["/a", "/b", "/c"])
    }

    @Test func prunedSelection() {
        #expect(ShellDisplayList.pruned(selection: ["a", "b"], visible: ["a", "b", "c"]) == nil)
        #expect(ShellDisplayList.pruned(selection: ["a", "x"], visible: ["a", "b"]) == ["a"])
        #expect(ShellDisplayList.pruned(selection: [], visible: ["a"]) == nil)
    }
}

/// ⌘V with a folder selected used to paste into that folder, so selecting a folder,
/// ⌘C, ⌘V failed with "can't be copied or moved into itself" (also after ⌘X).
@Suite struct ShellPasteTargetTests {
    let here = URL(fileURLWithPath: "/Users/me/Projects")
    let folder = URL(fileURLWithPath: "/Users/me/Projects/App")

    @Test func keyboardAndToolbarPasteGoIntoTheFolderShown() {
        #expect(ShellPasteTarget.destination(showing: here, clipboard: [folder]) == here)
        #expect(ShellPasteTarget.destination(showing: here, clipboard: [URL(fileURLWithPath: "/tmp/a.txt")]) == here)
    }

    @Test func folderContextMenuPastesIntoThatFolder() {
        let other = URL(fileURLWithPath: "/tmp/a.txt")
        #expect(ShellPasteTarget.destination(showing: here, contextMenuFolder: folder, clipboard: [other]) == folder)
    }

    @Test func folderNeverReceivesItselfOrAnAncestor() {
        #expect(ShellPasteTarget.destination(showing: here, contextMenuFolder: folder, clipboard: [folder]) == here)
        #expect(ShellPasteTarget.destination(showing: here, contextMenuFolder: folder,
                                             clipboard: [URL(fileURLWithPath: "/Users/me")]) == here)
        // A sibling whose name starts the same is not an ancestor.
        #expect(ShellPasteTarget.destination(showing: here, contextMenuFolder: folder,
                                             clipboard: [URL(fileURLWithPath: "/Users/me/Projects/Ap")]) == folder)
    }
}

@Suite struct ShellFileNameTests {
    @Test func acceptsAndTrimsOrdinaryNames() throws {
        #expect(try ShellFileName.validate("  Report 2.pdf \n").get() == "Report 2.pdf")
        #expect(try ShellFileName.validate(".hidden").get() == ".hidden")
        #expect(try ShellFileName.validate("a:b").get() == "a:b")
    }

    @Test func rejectsPathTraversalAndReservedNames() {
        #expect(ShellFileName.validate("../escape") == .failure(.containsSlash))
        #expect(ShellFileName.validate("a/b") == .failure(.containsSlash))
        #expect(ShellFileName.validate("..") == .failure(.reserved))
        #expect(ShellFileName.validate(".") == .failure(.reserved))
        #expect(ShellFileName.validate("   ") == .failure(.empty))
        #expect(ShellFileName.validate("a\u{0}b") == .failure(.containsNull))
    }

    /// Pressing Return without editing never renames: validation trims, so comparing
    /// its result with the name renamed "notes.txt " to "notes.txt" (and recorded an
    /// undo step), or failed when "notes.txt" existed.
    @Test func untouchedNameWithSurroundingSpacesIsNoChange() throws {
        #expect(try ShellFileName.validate("notes.txt ").get() == "notes.txt")   // why raw is compared first
        #expect(ShellFileName.renameDecision("notes.txt ", currentName: "notes.txt ") == .unchanged)
        #expect(ShellFileName.renameDecision(" a ", currentName: " a ") == .unchanged)
        #expect(ShellFileName.renameDecision("a ", currentName: "a") == .unchanged)
        #expect(ShellFileName.renameDecision("notes.txt", currentName: "notes.txt ") == .rename(to: "notes.txt"))
        #expect(ShellFileName.renameDecision(" b.txt ", currentName: "a.txt") == .rename(to: "b.txt"))
        #expect(ShellFileName.renameDecision("../x", currentName: "a.txt") == .invalid(.containsSlash))
        #expect(ShellFileName.renameDecision("  ", currentName: "a.txt") == .invalid(.empty))
    }

    @Test func rejectsOverlongNames() {
        #expect(ShellFileName.validate(String(repeating: "a", count: 255)) == .success(String(repeating: "a", count: 255)))
        #expect(ShellFileName.validate(String(repeating: "a", count: 256)) == .failure(.tooLong))
        // 128 two-byte characters = 256 bytes
        #expect(ShellFileName.validate(String(repeating: "é", count: 128)) == .failure(.tooLong))
    }
}

@Suite struct ShellReloadGateTests {
    @Test func reloadsPassWhileOpen() {
        var gate = ShellReloadGate()
        let now = gate.request()
        let deferred = gate.resume()
        #expect(now)
        #expect(!deferred)                    // nothing was held back
    }

    @Test func reloadsDuringARenameCollapseIntoOneAfterIt() {
        var gate = ShellReloadGate()
        gate.suspend()
        let first = gate.request(), second = gate.request()
        #expect(!first && !second)
        #expect(gate.hasDeferred)
        let onResume = gate.resume(), again = gate.resume()
        #expect(onResume)                     // one reload now
        #expect(!again)                       // and only one
        let afterwards = gate.request()
        #expect(afterwards)
    }

    @Test func renameWithoutChangesNeedsNoReload() {
        var gate = ShellReloadGate()
        gate.suspend()
        let deferred = gate.resume()
        #expect(!deferred)
    }

    /// A folder listed afresh while a reload was held back (a pane shown again)
    /// owes nothing when the rename ends, and stays shut until then.
    @Test func aFreshListingDropsTheHeldReload() {
        var gate = ShellReloadGate()
        gate.suspend()
        let held = gate.request()
        #expect(!held)
        gate.dropDeferred()
        #expect(gate.isSuspended && !gate.hasDeferred)
        let onResume = gate.resume()
        #expect(!onResume)
    }

    /// A rename flag that never clears (its field never got focus) mustn't freeze the
    /// folder: past `maxSuspension` the next request reopens the gate and reloads.
    @Test func aStuckSuspensionExpires() {
        var gate = ShellReloadGate()
        gate.suspend(now: 1_000)
        let early = gate.request(now: 1_000 + ShellReloadGate.maxSuspension - 1)
        #expect(!early)
        let late = gate.request(now: 1_000 + ShellReloadGate.maxSuspension)
        #expect(late)
        #expect(!gate.isSuspended && !gate.hasDeferred)
        let next = gate.request(now: 1_000 + ShellReloadGate.maxSuspension + 1)
        #expect(next)
        // The rename ending afterwards doesn't reload a second time.
        let onResume = gate.resume()
        #expect(!onResume)
    }

    @Test func aNewSuspensionRestartsTheClock() {
        var gate = ShellReloadGate()
        gate.suspend(now: 0)
        _ = gate.resume()
        gate.suspend(now: 500)
        let held = gate.request(now: 500 + ShellReloadGate.maxSuspension - 1)
        #expect(!held)
    }
}

@Suite struct GroupedItemsMemoTests {
    private let calendar = TestClock.calendar
    private let items = [FileItem.fixture("new.txt", modified: TestClock.daysAgo(0, hour: 9)),
                         FileItem.fixture("old.txt", modified: TestClock.daysAgo(1, hour: 9))]

    @Test func sameVersionSameDayIsCached() {
        let memo = GroupedItemsMemo()
        let first = memo.groups(items, version: 1, groupBy: .dateModified, now: TestClock.now, calendar: calendar)
        // A different array under the same version: the memo must not look at it.
        let cached = memo.groups([], version: 1, groupBy: .dateModified,
                                 now: TestClock.now.addingTimeInterval(3600), calendar: calendar)
        #expect(cached.map(\.title) == first.map(\.title))
        #expect(first.map(\.title) == ["Today", "Yesterday"])
    }

    /// Regression: keyed on version only, "Today" stayed "Today" after midnight.
    @Test func regroupsAfterMidnightWithoutANewVersion() {
        let memo = GroupedItemsMemo()
        let before = memo.groups(items, version: 7, groupBy: .dateModified, now: TestClock.now, calendar: calendar)
        #expect(before.map(\.title) == ["Today", "Yesterday"])
        let nextDay = calendar.date(byAdding: .day, value: 1, to: TestClock.now)!
        let after = memo.groups(items, version: 7, groupBy: .dateModified, now: nextDay, calendar: calendar)
        #expect(after.map(\.title) == ["Yesterday", "Previous 7 Days"])
    }

    @Test func versionOrGroupingChangeRegroups() {
        let memo = GroupedItemsMemo()
        _ = memo.groups(items, version: 1, groupBy: .dateModified, now: TestClock.now, calendar: calendar)
        #expect(memo.groups([items[0]], version: 2, groupBy: .dateModified,
                            now: TestClock.now, calendar: calendar).map(\.title) == ["Today"])
        #expect(memo.groups([items[0]], version: 2, groupBy: .none,
                            now: TestClock.now, calendar: calendar).map(\.id) == ["all"])
    }
}

@Suite struct ShellItemMenuTests {
    @Test func singleItemActionsNeedExactlyOneTarget() {
        let folder = ShellItemMenu(targetCount: 1, isBrowsableFolder: true, isPackage: false, isArchive: false)
        #expect(folder == ShellItemMenu(targetCount: 1, isBrowsableFolder: true, isPackage: false, isArchive: false))
        #expect(folder.rename && folder.openInNewWindow && folder.sidebarToggle)
        #expect(!folder.showPackageContents && !folder.extract)

        let app = ShellItemMenu(targetCount: 1, isBrowsableFolder: false, isPackage: true, isArchive: false)
        #expect(app.rename && app.showPackageContents && !app.openInNewWindow && !app.sidebarToggle)

        let zip = ShellItemMenu(targetCount: 1, isBrowsableFolder: false, isPackage: false, isArchive: true)
        #expect(zip.rename && zip.extract)
    }

    /// Several items: nothing that would act on the clicked one alone.
    @Test func multiSelectionHidesThem() {
        for count in [2, 5] {
            for (folder, package, archive) in [(true, false, false), (false, true, false), (false, false, true)] {
                let m = ShellItemMenu(targetCount: count, isBrowsableFolder: folder, isPackage: package, isArchive: archive)
                #expect(!m.rename && !m.openInNewWindow && !m.showPackageContents && !m.extract && !m.sidebarToggle)
            }
        }
    }
}

/// Regression: Go to Folder… (⇧⌘G) with the path bar hidden turned the bar's
/// setting back on for good.
@Suite struct ShellPathBarPresenceTests {
    @Test func goToFolderWithTheBarHiddenShowsItForTheEditOnly() {
        var bar = ShellPathBarPresence()
        #expect(!bar.isVisible(setting: false))
        #expect(bar.goToFolder(setting: false) == .showBarThenEdit)
        #expect(bar.isVisible(setting: false))
        bar.editingEnded()
        #expect(!bar.isVisible(setting: false))
    }

    @Test func goToFolderWithTheBarShownOpensItsEditor() {
        var bar = ShellPathBarPresence()
        #expect(bar.goToFolder(setting: true) == .openEditor)
        #expect(!bar.shownForEdit)
        #expect(bar.isVisible(setting: true))
    }

    @Test func askingAgainWhileTheBarIsShownForAnEditReopensTheEditor() {
        var bar = ShellPathBarPresence()
        _ = bar.goToFolder(setting: false)
        #expect(bar.goToFolder(setting: false) == .openEditor)
        #expect(bar.isVisible(setting: false))
    }

    /// Show Path Bar chosen during the edit: the bar stays when the edit ends.
    @Test func turningTheSettingOnDuringTheEditKeepsTheBar() {
        var bar = ShellPathBarPresence()
        _ = bar.goToFolder(setting: false)
        bar.editingEnded()
        #expect(bar.isVisible(setting: true))
    }
}
