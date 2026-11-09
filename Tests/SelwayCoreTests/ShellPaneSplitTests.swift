import Foundation
import Testing
@testable import SelwayCore

// How a dual-pane window shares its width (the divider and View → Make Left /
// Right Pane Wider).

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@Test func paneSplitKeepsBothPanesAtLeastTheirMinimum() {
    // 1000 points, panes of at least 220: the first gets 22% to 78%.
    #expect(near(ShellPaneSplit.clamped(0.5, width: 1000, minPane: 220), 0.5))
    #expect(near(ShellPaneSplit.clamped(0.1, width: 1000, minPane: 220), 0.22))
    #expect(near(ShellPaneSplit.clamped(0.95, width: 1000, minPane: 220), 0.78))
}

@Test func paneSplitIsHalfAndHalfWhenThereIsNoRoom() {
    #expect(near(ShellPaneSplit.clamped(0.3, width: 440, minPane: 220), 0.5))
    #expect(near(ShellPaneSplit.clamped(0.3, width: 300, minPane: 220), 0.5))
    #expect(near(ShellPaneSplit.clamped(0.3, width: 0, minPane: 220), 0.5))
}

@Test func paneSplitMinimumGrowsWithTheText() {
    #expect(ShellPaneSplit.minPaneWidth(textScale: 1) == 220)
    #expect(ShellPaneSplit.minPaneWidth(textScale: 1.5) == 330)
}

@Test func paneSplitWidensTheSideAsShown() {
    // Left to right: the first pane is the left one.
    #expect(near(ShellPaneSplit.widened(0.5, side: .left, rightToLeft: false, width: 1000, minPane: 220), 0.55))
    #expect(near(ShellPaneSplit.widened(0.5, side: .right, rightToLeft: false, width: 1000, minPane: 220), 0.45))
    // Right to left: the first pane is on the right.
    #expect(near(ShellPaneSplit.widened(0.5, side: .left, rightToLeft: true, width: 1000, minPane: 220), 0.45))
    #expect(near(ShellPaneSplit.widened(0.5, side: .right, rightToLeft: true, width: 1000, minPane: 220), 0.55))
    // Never past the minimum.
    #expect(near(ShellPaneSplit.widened(0.77, side: .left, rightToLeft: false, width: 1000, minPane: 220), 0.78))
}

@Test func paneSplitReadsTheLeftPanesShare() {
    #expect(ShellPaneSplit.leftPercent(0.6, rightToLeft: false, width: 1000, minPane: 220) == 60)
    #expect(ShellPaneSplit.leftPercent(0.6, rightToLeft: true, width: 1000, minPane: 220) == 40)
    // Widening the left pane always raises what's read, whichever way the layout runs.
    for rtl in [false, true] {
        let wider = ShellPaneSplit.widened(0.5, side: .left, rightToLeft: rtl, width: 1000, minPane: 220)
        #expect(ShellPaneSplit.leftPercent(wider, rightToLeft: rtl, width: 1000, minPane: 220) == 55)
    }
}

@Test func paneSplitFollowsADrag() {
    #expect(near(ShellPaneSplit.dragged(from: 0.5, dx: 100, rightToLeft: false, width: 1000, minPane: 220), 0.6))
    // The first pane is on the right in a right-to-left layout: dragging right narrows it.
    #expect(near(ShellPaneSplit.dragged(from: 0.5, dx: 100, rightToLeft: true, width: 1000, minPane: 220), 0.4))
    #expect(near(ShellPaneSplit.dragged(from: 0.5, dx: -900, rightToLeft: false, width: 1000, minPane: 220), 0.22))
}
