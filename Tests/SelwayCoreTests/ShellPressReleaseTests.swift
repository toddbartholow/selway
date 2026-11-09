import Foundation
import Testing
@testable import SelwayCore

/// The mouse-up after a press on a selected file, shared by the icon grid and
/// the column browser (#41, #43).
@MainActor
@Suite struct ShellPressReleaseTests {
    /// A selection the release reads and writes, as a view's would be.
    private final class Selection {
        var ids: Set<String>
        var writes = 0
        init(_ ids: Set<String>) { self.ids = ids }
    }

    @discardableResult
    private func release(_ presses: ShellPressRelease, _ selection: Selection) -> Task<Void, Never>? {
        presses.release(selection: { selection.ids }, select: { selection.ids = $0; selection.writes += 1 })
    }

    /// Regression (#43): a ⌘-press on a selected item took it out at once, so a
    /// ⌘-drag from it carried that item alone. It keeps the selection until
    /// the mouse-up.
    @Test func aCommandPressOnASelectedItemDeselectsItOnlyAtTheMouseUp() {
        let selection = Selection(["a", "b", "c"])
        let presses = ShellPressRelease(interval: { 0 })
        presses.press(ShellIconClick.click(on: "b", selection: selection.ids, modifiers: .command,
                                           anchor: nil, order: []))
        #expect(selection.ids == ["a", "b", "c"])
        #expect(release(presses, selection) == nil)
        #expect(selection.ids == ["a", "c"])
    }

    /// The ⌘-drag carries every selected item: the drag cancels the deselection.
    @Test func aDragFromACommandPressKeepsTheSelection() {
        let selection = Selection(["a", "b", "c"])
        let presses = ShellPressRelease(interval: { 0 })
        presses.press(.deselectLater("b"))
        presses.cancel()
        #expect(release(presses, selection) == nil)
        #expect(selection.ids == ["a", "b", "c"])
        #expect(selection.writes == 0)
    }

    @Test func aCommandClickOnTheOnlySelectedItemLeavesNothingSelected() {
        let selection = Selection(["b"])
        let presses = ShellPressRelease(interval: { 0 })
        presses.press(.deselectLater("b"))
        release(presses, selection)
        #expect(selection.ids == [])
    }

    /// Regression (#41): Columns narrowed on the first mouse-up, so a
    /// double-click in a selection opened only the row clicked. Both views
    /// now wait out the double-click interval first.
    @Test func aPlainClickInsideASelectionNarrowsItAfterTheInterval() async {
        let selection = Selection(["a", "b", "c"])
        let presses = ShellPressRelease(interval: { 0 })
        presses.press(.narrowLater("b"))
        #expect(presses.narrowingID == "b")
        let wait = release(presses, selection)
        #expect(selection.ids == ["a", "b", "c"])
        await wait?.value
        #expect(selection.ids == ["b"])
        #expect(presses.narrowingID == nil)
    }

    /// The second press of a double-click comes before the interval is out and
    /// cancels the narrowing, so the double-click opens the whole selection.
    @Test func theSecondPressOfADoubleClickKeepsTheSelection() async {
        let selection = Selection(["a", "b", "c"])
        let presses = ShellPressRelease(interval: { 0 })
        presses.press(.narrowLater("b"))
        let wait = release(presses, selection)
        presses.cancel()
        await wait?.value
        #expect(selection.ids == ["a", "b", "c"])
        #expect(selection.writes == 0)
    }

    /// A new press ends the last one's narrowing too.
    @Test func anotherPressEndsAWaitingNarrowing() async {
        let selection = Selection(["a", "b", "c"])
        let presses = ShellPressRelease(interval: { 0 })
        presses.press(.narrowLater("b"))
        let wait = release(presses, selection)
        presses.press(.select(["a", "b", "c", "d"]))
        await wait?.value
        #expect(selection.writes == 0)
        #expect(presses.narrowingID == nil)
    }

    /// The item left the selection in the meantime: nothing to narrow to.
    @Test func aNarrowingSkipsAnItemNoLongerSelected() async {
        let selection = Selection(["a", "b", "c"])
        let presses = ShellPressRelease(interval: { 0 })
        presses.press(.narrowLater("b"))
        let wait = release(presses, selection)
        selection.ids = ["a", "c"]
        await wait?.value
        #expect(selection.ids == ["a", "c"])
    }

    /// A drag from the press (it cancels before any mouse-up) narrows nothing.
    @Test func aDragFromAPressInsideASelectionKeepsIt() {
        let selection = Selection(["a", "b"])
        let presses = ShellPressRelease(interval: { 0 })
        presses.press(.narrowLater("b"))
        presses.cancel()
        #expect(release(presses, selection) == nil)
        #expect(selection.ids == ["a", "b"])
    }

    /// Presses that changed the selection at once leave nothing for the mouse-up.
    @Test func otherPressesLeaveNothingForTheMouseUp() {
        let selection = Selection(["a"])
        let presses = ShellPressRelease(interval: { 0 })
        for click in [ShellIconClick.select(["a", "b"]), .keep, .clear] {
            presses.press(click)
            #expect(release(presses, selection) == nil)
        }
        #expect(selection.writes == 0)
    }

    /// A key that moves on from the item clicked (an arrow key, typing a
    /// name) narrows the selection at once rather than after the interval.
    @Test func flushNarrowsAtOnce() async {
        let selection = Selection(["a", "b", "c"])
        let presses = ShellPressRelease(interval: { 0 })
        presses.press(.narrowLater("b"))
        let wait = release(presses, selection)
        #expect(presses.flush() == "b")
        #expect(selection.ids == ["b"])
        #expect(presses.narrowingID == nil)
        // And the wait then does nothing more.
        await wait?.value
        #expect(selection.writes == 1)
        #expect(presses.flush() == nil)
    }

    /// Only a narrowing waiting after its mouse-up: not while the button is
    /// still down (it may yet drag), and not once cancelled.
    @Test func flushDoesNothingWithoutAWaitingNarrowing() {
        let selection = Selection(["a", "b", "c"])
        let presses = ShellPressRelease(interval: { 0 })
        #expect(presses.flush() == nil)
        presses.press(.narrowLater("b"))
        #expect(presses.flush() == nil)
        release(presses, selection)
        presses.cancel()
        #expect(presses.flush() == nil)
        #expect(selection.writes == 0)
    }

    /// The selection is read when the narrowing happens, not at the mouse-up.
    @Test func flushSkipsAnItemThatLeftTheSelection() {
        let selection = Selection(["a", "b", "c"])
        let presses = ShellPressRelease(interval: { 0 })
        presses.press(.narrowLater("b"))
        release(presses, selection)
        selection.ids = ["a", "c"]
        #expect(presses.flush() == nil)
        #expect(selection.ids == ["a", "c"])
    }
}
