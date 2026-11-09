import Foundation
import Testing
@testable import SelwayCore

/// The Acknowledgments window opens beside the About window, and on the screen.
@Suite struct AboutWindowPlacementTests {
    private let screen = CGRect(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 1440, height: 875))
    private let size = CGSize(width: 760, height: 548)

    // CGRect's geometry helpers come from CoreGraphics, which Linux doesn't have.
    private func minX(_ r: CGRect) -> CGFloat { r.origin.x }
    private func maxX(_ r: CGRect) -> CGFloat { r.origin.x + r.size.width }
    private func minY(_ r: CGRect) -> CGFloat { r.origin.y }
    private func maxY(_ r: CGRect) -> CGFloat { r.origin.y + r.size.height }
    private func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        minX(inner) >= minX(outer) && maxX(inner) <= maxX(outer) && minY(inner) >= minY(outer) && maxY(inner) <= maxY(outer)
    }
    private func overlap(_ a: CGRect, _ b: CGRect) -> Bool {
        minX(a) < maxX(b) && minX(b) < maxX(a) && minY(a) < maxY(b) && minY(b) < maxY(a)
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }
    private func same(_ a: CGRect, _ b: CGRect) -> Bool {
        a.origin.x == b.origin.x && a.origin.y == b.origin.y && a.size.width == b.size.width && a.size.height == b.size.height
    }

    private func frame(about: CGRect, in visible: CGRect? = nil) -> CGRect {
        AboutWindowPlacement.acknowledgmentsFrame(size: size, beside: about, in: visible ?? screen)
    }

    @Test func goesToTheRightOfAboutWithTheirTopsLevel() {
        let about = rect(100, 400, 320, 340)
        let placed = frame(about: about)
        #expect(same(placed, rect(432, 192, 760, 548)))
        #expect(!overlap(placed, about))
    }

    @Test func goesToTheLeftWhenTheRightHasNoRoom() {
        let about = rect(1000, 400, 320, 340)
        let placed = frame(about: about)
        #expect(maxX(placed) == minX(about) - 12)
        #expect(maxY(placed) == maxY(about))
        #expect(!overlap(placed, about))
    }

    /// A centered About window on a small screen leaves room on neither side: the window
    /// keeps to an edge of the screen rather than going off it.
    @Test func staysOnTheScreenWhenNeitherSideHasRoom() {
        let small = rect(0, 0, 1024, 640)
        let about = rect(352, 150, 320, 340)
        let placed = frame(about: about, in: small)
        #expect(contains(small, placed))
        #expect(maxX(placed) == maxX(small))
    }

    /// With room on neither side but more to About's left, the window keeps to the
    /// screen's left edge, covering less of About than it would on the right.
    @Test func keepsToTheLeftEdgeWhenTheLeftHasMoreRoom() {
        let small = rect(0, 0, 1024, 640)
        let about = rect(500, 280, 320, 340)    // 500 points to its left, 204 to its right
        let placed = frame(about: about, in: small)
        #expect(contains(small, placed))
        #expect(minX(placed) == minX(small))
        #expect(maxY(placed) == maxY(about))
        // It covers 260 points of About's width; at the right edge it would cover 556.
        #expect(maxX(placed) - minX(about) == 260)
    }

    /// The same on a second screen, whose visible frame doesn't start at zero: the left
    /// edge is the screen's, not x = 0.
    @Test func keepsToASecondScreensLeftEdge() {
        let second = rect(-1024, 100, 1024, 640)
        let about = rect(-524, 250, 320, 340)
        let placed = frame(about: about, in: second)
        #expect(contains(second, placed))
        #expect(minX(placed) == -1024)
    }

    @Test func staysBelowTheMenuBarAndAboveTheDock() {
        let visible = rect(0, 80, 1440, 770)
        // About high on the screen: Acknowledgments' top would be level with it.
        let high = frame(about: rect(100, 600, 320, 250), in: visible)
        #expect(maxY(high) <= maxY(visible))
        // About low on the screen: Acknowledgments would reach below the Dock.
        let low = frame(about: rect(100, 80, 320, 340), in: visible)
        #expect(minY(low) == minY(visible))
        #expect(contains(visible, low))
    }

    /// The screen's visible frame needn't start at zero: a second display's is offset.
    @Test func worksOnASecondScreen() {
        let second = rect(-1920, 0, 1920, 1055)
        let about = rect(-1100, 400, 320, 340)
        let placed = frame(about: about, in: second)
        #expect(contains(second, placed))
        #expect(minX(placed) == maxX(about) + 12)
    }

    @Test func shrinksOnlyToFitAScreenSmallerThanTheWindow() {
        let tiny = rect(0, 0, 640, 480)
        let placed = frame(about: rect(160, 70, 320, 340), in: tiny)
        #expect(same(placed, tiny))
    }

    /// A window closed on a display that's gone is off every screen and opens centered
    /// again; one still mostly or partly on a screen stays where it was.
    @Test func knowsAFrameLeftOffEveryScreen() {
        let screens = [screen, rect(1440, 0, 1920, 1080)]
        // On the first screen, on the second, and across both.
        #expect(AboutWindowPlacement.isOnScreen(rect(100, 400, 320, 340), screens: screens))
        #expect(AboutWindowPlacement.isOnScreen(rect(2000, 300, 320, 340), screens: screens))
        #expect(AboutWindowPlacement.isOnScreen(rect(1300, 300, 320, 340), screens: screens))
        // Where a third display to the left used to be.
        #expect(!AboutWindowPlacement.isOnScreen(rect(-1500, 300, 320, 340), screens: screens))
        // Only a sliver on the screen is too little to find and drag.
        #expect(!AboutWindowPlacement.isOnScreen(rect(-310, 300, 320, 340), screens: [screen]))
        #expect(!AboutWindowPlacement.isOnScreen(rect(100, 870, 320, 340), screens: [screen]))
        // With no screens at all, nothing is on one.
        #expect(!AboutWindowPlacement.isOnScreen(rect(100, 400, 320, 340), screens: []))
    }

    /// A window smaller than the overlap asked for counts when all of it is on a screen.
    @Test func countsASmallWindowWhollyOnAScreen() {
        #expect(AboutWindowPlacement.isOnScreen(rect(10, 10, 20, 20), screens: [screen]))
        #expect(!AboutWindowPlacement.isOnScreen(rect(-15, 10, 20, 20), screens: [screen]))
    }
}
