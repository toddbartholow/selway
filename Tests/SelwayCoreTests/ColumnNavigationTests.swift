import Foundation
import Testing
@testable import SelwayCore

@Suite struct ColumnNavigationTests {
    /// Select All and File ▸ Open (#39) act on the focused column, else the
    /// one last selected in, else the last one.
    @Test func menuCommandsActOnTheFocusedColumn() {
        #expect(ColumnNavigation.commandPane(focused: 1, active: 0, count: 3) == 1)
        #expect(ColumnNavigation.commandPane(focused: nil, active: 0, count: 3) == 0)
        #expect(ColumnNavigation.commandPane(focused: nil, active: nil, count: 3) == 2)
        #expect(ColumnNavigation.commandPane(focused: nil, active: nil, count: 0) == nil)
    }

    @Test func typeToSelectStartsAfterSelectionAndWraps() {
        let names = ["Alpha", "Beta", "Another"]
        #expect(ColumnNavigation.typeToSelect("a", names: names, selectedIndex: 0) == 2)
        #expect(ColumnNavigation.typeToSelect("a", names: names, selectedIndex: 2) == 0)
    }

    @Test func aLongerQueryKeepsTheSelectedRowWhileItMatches() {
        let names = ["beach", "bear", "cat"]
        #expect(ColumnNavigation.typeToSelect("bea", names: names, selectedIndex: 0, includingSelected: true) == 0)
        #expect(ColumnNavigation.typeToSelect("bear", names: names, selectedIndex: 0, includingSelected: true) == 1)
        #expect(ColumnNavigation.typeToSelect("c", names: names, selectedIndex: nil, includingSelected: true) == 2)
    }

    @Test func typeToSelectIgnoresCaseAndDiacritics() {
        #expect(ColumnNavigation.typeToSelect("resume", names: ["Résumé", "Other"], selectedIndex: nil) == 0)
    }

    @Test func typeToSelectHandlesEmptyAndMissingMatches() {
        #expect(ColumnNavigation.typeToSelect("", names: ["Alpha"], selectedIndex: nil) == nil)
        #expect(ColumnNavigation.typeToSelect("z", names: ["Alpha"], selectedIndex: nil) == nil)
        #expect(ColumnNavigation.typeToSelect("a", names: [], selectedIndex: nil) == nil)
    }

    @Test func printableKeysAreTypeSelectInput() {
        for key in ["a", "Z", "7", "é", "_", ".", "日"] {
            #expect(ColumnNavigation.isTypeSelectInput(key), "\(key)")
        }
    }

    @Test func controlArrowAndSpaceKeysAreNotTypeSelectInput() {
        let keys = ["", "\u{1B}", "\u{7F}", "\t", "\r", "\n", " ",
                    "\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}", "\u{F704}", "\u{F728}"]
        for key in keys {
            #expect(!ColumnNavigation.isTypeSelectInput(key), "\(key.unicodeScalars.map { $0.value })")
        }
    }

    // MARK: Clicks on a row

    private let order = ["a", "b", "c", "d", "e"]

    @Test func aPlainClickSelectsTheRowAlone() {
        #expect(ColumnNavigation.click(on: "b", selection: [], modifiers: [], anchor: nil, order: order)
                == .select(["b"]))
        #expect(ColumnNavigation.click(on: "b", selection: ["a"], modifiers: [], anchor: "a", order: order)
                == .select(["b"]))
        #expect(ColumnNavigation.click(on: "b", selection: ["b"], modifiers: [], anchor: "b", order: order) == .keep)
    }

    /// Regression (#27): a press on one of several selected rows selected it
    /// alone at once, so a drag from it carried only that row. The selection
    /// now stays until the button comes up without a drag.
    @Test func aPlainClickInsideALargerSelectionNarrowsItLater() {
        #expect(ColumnNavigation.click(on: "c", selection: ["a", "c"], modifiers: [], anchor: "a", order: order)
                == .narrowLater("c"))
    }

    /// Regression (#43): a ⌘-press on a selected row took it out at once, so a
    /// ⌘-drag from it carried that row alone. It goes at the mouse-up, as in
    /// the icon grid.
    @Test func commandClickTogglesTheRow() {
        #expect(ColumnNavigation.click(on: "c", selection: ["a"], modifiers: .command, anchor: "a", order: order)
                == .select(["a", "c"]))
        #expect(ColumnNavigation.click(on: "a", selection: ["a", "c"], modifiers: .command, anchor: "c",
                                       order: order) == .deselectLater("a"))
        #expect(ColumnNavigation.click(on: "a", selection: ["a"], modifiers: .command, anchor: "a", order: order)
                == .deselectLater("a"))
    }

    /// ⇧ replaces the selection with the range from the anchor, as the column
    /// always has (the icon grid adds the range to the selection instead).
    @Test func shiftClickSelectsTheRangeFromTheAnchor() {
        #expect(ColumnNavigation.click(on: "d", selection: ["b"], modifiers: .shift, anchor: "b", order: order)
                == .select(["b", "c", "d"]))
        #expect(ColumnNavigation.click(on: "a", selection: ["c", "e"], modifiers: .shift, anchor: "c", order: order)
                == .select(["a", "b", "c"]))
        #expect(ColumnNavigation.click(on: "c", selection: ["a"], modifiers: [.shift, .command], anchor: "a",
                                       order: order) == .select(["a", "b", "c"]))
        #expect(ColumnNavigation.click(on: "b", selection: ["a", "b"], modifiers: .shift, anchor: "a", order: order)
                == .keep)
    }

    @Test func shiftClickStartsFromTheFirstSelectedRowWithoutASelectedAnchor() {
        #expect(ColumnNavigation.click(on: "e", selection: ["c"], modifiers: .shift, anchor: nil, order: order)
                == .select(["c", "d", "e"]))
        #expect(ColumnNavigation.click(on: "e", selection: ["c"], modifiers: .shift, anchor: "a", order: order)
                == .select(["c", "d", "e"]))
    }

    @Test func shiftClickWithNothingSelectedIsAPlainClick() {
        #expect(ColumnNavigation.click(on: "c", selection: [], modifiers: .shift, anchor: "a", order: order)
                == .select(["c"]))
        #expect(!ColumnNavigation.extends([], modifiers: .shift))
        #expect(ColumnNavigation.extends(["a"], modifiers: .shift))
        #expect(!ColumnNavigation.extends(["a"], modifiers: .command))
    }

    @Test func shiftClickOnARowNoLongerShownKeepsTheSelection() {
        #expect(ColumnNavigation.click(on: "z", selection: ["a"], modifiers: .shift, anchor: "a", order: order)
                == .keep)
    }

    /// The rows' order is only worked out for a ⇧-click.
    @Test func onlyShiftClickReadsTheOrder() {
        var reads = 0
        func counted() -> [String] { reads += 1; return order }
        _ = ColumnNavigation.click(on: "c", selection: ["a"], modifiers: [], anchor: "a", order: counted())
        _ = ColumnNavigation.click(on: "c", selection: ["a"], modifiers: .command, anchor: "a", order: counted())
        #expect(reads == 0)
        _ = ColumnNavigation.click(on: "c", selection: ["a"], modifiers: .shift, anchor: "a", order: counted())
        #expect(reads == 1)
    }

    /// ↑/↓ while a click inside a selection waits to narrow it move on from
    /// the row clicked, not from the whole selection (the list's own move).
    @Test func anArrowStepsFromTheRowClicked() {
        #expect(ColumnNavigation.step(from: "c", order: order, down: true, extending: false) == ["d"])
        #expect(ColumnNavigation.step(from: "c", order: order, down: false, extending: false) == ["b"])
        #expect(ColumnNavigation.step(from: "c", order: order, down: true, extending: true) == ["c", "d"])
        #expect(ColumnNavigation.step(from: "c", order: order, down: false, extending: true) == ["b", "c"])
    }

    @Test func anArrowAtEitherEndKeepsTheRowAlone() {
        #expect(ColumnNavigation.step(from: "e", order: order, down: true, extending: false) == ["e"])
        #expect(ColumnNavigation.step(from: "a", order: order, down: false, extending: true) == ["a"])
        #expect(ColumnNavigation.step(from: "gone", order: order, down: true, extending: false) == ["gone"])
    }

    @Test func keysTypedQuicklyBuildOneQuery() {
        var buffer = TypeSelectBuffer()
        let start = Date()
        #expect(buffer.type("g", at: start) == "g")
        #expect(buffer.type("a", at: start.addingTimeInterval(0.3)) == "ga")
        #expect(buffer.isTyping(at: start.addingTimeInterval(0.5)))
        #expect(buffer.type("m", at: start.addingTimeInterval(0.6)) == "gam")
    }

    @Test func aPauseStartsANewQuery() {
        var buffer = TypeSelectBuffer()
        let start = Date()
        _ = buffer.type("g", at: start)
        #expect(!buffer.isTyping(at: start.addingTimeInterval(1.5)))
        #expect(buffer.type("b", at: start.addingTimeInterval(1.5)) == "b")
    }

    @Test func theSameLetterAgainStartsOver() {
        var buffer = TypeSelectBuffer()
        let start = Date()
        _ = buffer.type("b", at: start)
        #expect(buffer.type("B", at: start.addingTimeInterval(0.2)) == "B")
    }
}
