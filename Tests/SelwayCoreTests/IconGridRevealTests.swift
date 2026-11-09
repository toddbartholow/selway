import Foundation
import Testing
@testable import SelwayCore

@Suite struct IconGridRevealTests {
    private typealias Span = IconGridReveal.Span

    /// A 600-point viewport scrolled 1000 points down.
    private let viewport = Span(top: 1000, bottom: 1600)

    @Test func anIconInViewDoesntScroll() {
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 1100, bottom: 1180), in: viewport, covered: 24) == nil)
        // Exactly against either edge (below the header at the top).
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 1024, bottom: 1104), in: viewport, covered: 24) == nil)
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 1520, bottom: 1600), in: viewport, covered: 24) == nil)
    }

    @Test func aFractionOfAPointPastAnEdgeCountsAsInView() {
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 1520.4, bottom: 1600.4), in: viewport, covered: 0) == nil)
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 1023.6, bottom: 1103.6), in: viewport, covered: 24) == nil)
    }

    @Test func anIconBelowScrollsDownToTheBottomEdge() {
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 1590, bottom: 1670), in: viewport, covered: 24) == 70)
        // Far below: the same rule, however far.
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 3000, bottom: 3080), in: viewport, covered: 0) == 1480)
    }

    @Test func anIconAboveScrollsUpToJustBelowThePinnedHeader() {
        // Above the viewport.
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 900, bottom: 980), in: viewport, covered: 24) == -124)
        // In the viewport, but under the header: scrolling it to the top (as
        // scrollTo with no anchor does) isn't enough.
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 1000, bottom: 1080), in: viewport, covered: 24) == -24)
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 1010, bottom: 1090), in: viewport, covered: 24) == -14)
        // No header (Group By off): to the top edge.
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 900, bottom: 980), in: viewport, covered: 0) == -100)
    }

    @Test func anIconTallerThanTheSpaceShowsItsTop() {
        let short = Span(top: 1000, bottom: 1100)
        // Below: down until its top is just below the header, no further.
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 1050, bottom: 1250), in: short, covered: 24) == 26)
        // Above: up to its top.
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 900, bottom: 1100), in: short, covered: 24) == -124)
        // Its top just below the header already: no more scrolling, though
        // its bottom is past the edge.
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 1024, bottom: 1224), in: short, covered: 24) == nil)
    }

    /// The whole header, wherever the headers are now: one pushed half off
    /// the top, or none at the top at all, still pins in full over the icon
    /// once it is there (issue #24).
    @Test func theCoveredHeightIsAWholeHeaderWhereverTheHeadersAre() {
        // Pinned at the top, and further down a header in the flow.
        #expect(IconGridReveal.pinnedHeaderHeight(headers: [Span(top: 1000, bottom: 1024),
                                                            Span(top: 1300, bottom: 1324)]) == 24)
        // Half pushed off by the next group's header.
        #expect(IconGridReveal.pinnedHeaderHeight(headers: [Span(top: 990, bottom: 1014),
                                                            Span(top: 1014, bottom: 1038)]) == 24)
        // The top of the window in the gap between two groups.
        #expect(IconGridReveal.pinnedHeaderHeight(headers: [Span(top: 1040, bottom: 1064)]) == 24)
        // Group By off.
        #expect(IconGridReveal.pinnedHeaderHeight(headers: []) == 0)
    }

    /// The case the UI run caught: ↑ to a group's last row while the next
    /// group's header pushes the first one's off the top. Measured now, the
    /// header covers 10 points; scrolled with that, the icon ends up 14 points
    /// under the first group's header once it pins in full.
    @Test func anIconAboveComesToRestBelowAWholeHeaderWhileTheHeaderIsPushedOff() {
        let headers = [Span(top: 986, bottom: 1010), Span(top: 1010, bottom: 1034)]
        let covered = IconGridReveal.pinnedHeaderHeight(headers: headers)
        let item = Span(top: 900, bottom: 998)
        let delta = IconGridReveal.scrollDelta(toReveal: item, in: viewport, covered: covered)
        #expect(delta == -124)
        // After the scroll, with its own header pinned in full, it is in view.
        let after = Span(top: viewport.top + (delta ?? 0), bottom: viewport.bottom + (delta ?? 0))
        #expect(IconGridReveal.scrollDelta(toReveal: item, in: after, covered: 24) == nil)
    }

    /// A viewport no taller than the header (a window dragged very short):
    /// the icon's top goes just below the header.
    @Test func aSpanIsNeverUpsideDown() {
        #expect(Span(top: 10, bottom: 4).height == 0)
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 1100, bottom: 1180), in: Span(top: 1000, bottom: 900),
                                           covered: 24) == 76)
        #expect(IconGridReveal.scrollDelta(toReveal: Span(top: 1100, bottom: 1180), in: Span(top: 1000, bottom: 1010),
                                           covered: 24) == 76)
    }
}
