import Foundation
import Testing
@testable import SelwayCore

// CGRect's initialisers and `==` come from CoreGraphics, which the Linux
// build doesn't have.
private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
}

private func same(_ a: CGRect, _ b: CGRect) -> Bool {
    a.origin.x == b.origin.x && a.origin.y == b.origin.y
        && a.size.width == b.size.width && a.size.height == b.size.height
}

private func same(_ a: [String: [CGRect]], _ b: [String: [CGRect]]) -> Bool {
    a.count == b.count && a.allSatisfy { id, parts in
        b[id].map { $0.count == parts.count && zip($0, parts).allSatisfy(same) } ?? false
    }
}

/// Finder's rubber band in Icons view: a drag from empty space selects the
/// icons it touches.
@Suite struct ShellRubberBandTests {
    /// Three icons in a row, 100 × 90 with 8 points between them, and one
    /// below the first, each taken as one part.
    private let frames: [String: [CGRect]] = [
        "a": [rect(16, 12, 100, 90)],
        "b": [rect(124, 12, 100, 90)],
        "c": [rect(232, 12, 100, 90)],
        "d": [rect(16, 114, 100, 90)],
    ]

    @Test func theBandIsTheSameWhicheverWayTheDragGoes() {
        let band = rect(10, 20, 30, 40)
        #expect(same(ShellRubberBand.rect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 40, y: 60)), band))
        #expect(same(ShellRubberBand.rect(from: CGPoint(x: 40, y: 60), to: CGPoint(x: 10, y: 20)), band))
        #expect(same(ShellRubberBand.rect(from: CGPoint(x: 40, y: 20), to: CGPoint(x: 10, y: 60)), band))
        #expect(same(ShellRubberBand.rect(from: CGPoint(x: 10, y: 60), to: CGPoint(x: 40, y: 20)), band))
    }

    @Test func theBandSelectsTheCellsItTouches() {
        // From the gap below b across into a and b.
        let band = ShellRubberBand.rect(from: CGPoint(x: 200, y: 108), to: CGPoint(x: 100, y: 60))
        #expect(ShellRubberBand.touched(by: band, icons: frames) == ["a", "b"])
        // The gap between a and b alone touches nothing.
        let gap = ShellRubberBand.rect(from: CGPoint(x: 117, y: 30), to: CGPoint(x: 123, y: 104))
        #expect(ShellRubberBand.touched(by: gap, icons: frames).isEmpty)
        // Everything.
        let all = ShellRubberBand.rect(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 400, y: 300))
        #expect(ShellRubberBand.touched(by: all, icons: frames) == ["a", "b", "c", "d"])
    }

    /// A band whose edge only meets a cell's doesn't select it.
    @Test func edgesThatOnlyMeetDontCount() {
        let band = rect(0, 12, 16, 50)    // ends where a starts
        #expect(ShellRubberBand.touched(by: band, icons: frames).isEmpty)
    }

    /// A drag straight up or across has no width (or height) yet; it still
    /// selects the cells it crosses.
    @Test func aBandWithNoWidthSelectsWhatItCrosses() {
        let line = ShellRubberBand.rect(from: CGPoint(x: 60, y: 210), to: CGPoint(x: 60, y: 50))
        #expect(line.size.width == 0)
        #expect(ShellRubberBand.touched(by: line, icons: frames) == ["a", "d"])
        let across = ShellRubberBand.rect(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 400, y: 50))
        #expect(ShellRubberBand.touched(by: across, icons: frames) == ["a", "b", "c"])
    }

    @Test func aPlainBandReplacesTheSelection() {
        #expect(ShellRubberBand.mode(for: []) == .replace)
        #expect(ShellRubberBand.selection(touched: ["b", "c"], base: ["a", "b"], mode: .replace) == ["b", "c"])
        #expect(ShellRubberBand.selection(touched: [], base: ["a"], mode: .replace) == [])
    }

    /// With ⌘ or ⇧ held, Finder flips what the band touches against the
    /// selection the drag started with.
    @Test func aBandWithCommandOrShiftTogglesAgainstTheStartingSelection() {
        #expect(ShellRubberBand.mode(for: .command) == .toggle)
        #expect(ShellRubberBand.mode(for: .shift) == .toggle)
        #expect(ShellRubberBand.mode(for: [.command, .shift]) == .toggle)
        #expect(ShellRubberBand.selection(touched: ["b", "c"], base: ["a", "b"], mode: .toggle) == ["a", "c"])
        // The band moving off an icon puts it back as it was.
        #expect(ShellRubberBand.selection(touched: [], base: ["a", "b"], mode: .toggle) == ["a", "b"])
    }

    /// A press on empty space is a click until it moves the same few points
    /// as a drag of an icon.
    /// An icon is its image and its name: a band that crosses only the blank
    /// part of its cell beside a short name doesn't select it; one that
    /// touches either part does.
    @Test func theBandSelectsAnIconByItsImageOrNameNotTheBlankPartOfItsCell() {
        // A 100 pt wide cell at x 16: image 70 × 70 centred, a short name below.
        let icons = ["a": [rect(31, 15, 70, 70), rect(46, 87, 40, 16)]]
        let besideName = ShellRubberBand.rect(from: CGPoint(x: 18, y: 110), to: CGPoint(x: 44, y: 88))
        #expect(ShellRubberBand.touched(by: besideName, icons: icons).isEmpty)
        let ontoName = ShellRubberBand.rect(from: CGPoint(x: 18, y: 110), to: CGPoint(x: 50, y: 95))
        #expect(ShellRubberBand.touched(by: ontoName, icons: icons) == ["a"])
        let ontoImage = ShellRubberBand.rect(from: CGPoint(x: 18, y: 10), to: CGPoint(x: 40, y: 20))
        #expect(ShellRubberBand.touched(by: ontoImage, icons: icons) == ["a"])
    }

    @Test func aBandStartsPastTheDragThreshold() {
        #expect(!ShellRubberBand.starts(dx: 2, dy: 2))
        #expect(!ShellRubberBand.starts(dx: 4, dy: 0))
        #expect(ShellRubberBand.starts(dx: 4, dy: 1))
        #expect(ShellRubberBand.starts(dx: 0, dy: -6))
    }

    @Test func theGridScrollsOnlyWithThePointerPastAnEdge() {
        #expect(ShellRubberBand.scrollStep(pointer: 300, top: 100, bottom: 500) == 0)
        #expect(ShellRubberBand.scrollStep(pointer: 100, top: 100, bottom: 500) == 0)
        #expect(ShellRubberBand.scrollStep(pointer: 500, top: 100, bottom: 500) == 0)
        #expect(ShellRubberBand.scrollStep(pointer: 99, top: 100, bottom: 500) < 0)
        #expect(ShellRubberBand.scrollStep(pointer: 501, top: 100, bottom: 500) > 0)
    }

    @Test func theFurtherPastTheEdgeTheFasterUpToALimit() {
        #expect(ShellRubberBand.scrollStep(pointer: 501, top: 100, bottom: 500) == 2)
        #expect(ShellRubberBand.scrollStep(pointer: 520, top: 100, bottom: 500) == 10)
        #expect(ShellRubberBand.scrollStep(pointer: 2000, top: 100, bottom: 500) == ShellRubberBand.maxScrollStep)
        #expect(ShellRubberBand.scrollStep(pointer: 80, top: 100, bottom: 500) == -10)
        #expect(ShellRubberBand.scrollStep(pointer: -900, top: 100, bottom: 500) == -ShellRubberBand.maxScrollStep)
    }
}

@Suite struct ShellBandTargetsTests {
    private let a = [rect(15, 3, 70, 70), rect(30, 75, 40, 16)]
    private let b = [rect(123, 3, 70, 70), rect(118, 75, 80, 30)]

    @Test func theIconsLaidOutAreWhereTheyAre() {
        var targets = ShellBandTargets()
        targets.update(laidOut: ["a": a, "b": b])
        #expect(same(targets.icons, ["a": a, "b": b]))
        // An icon that moved (another sort, icon size or grouping) is where it is now.
        let moved = [rect(123, 103, 70, 70), rect(118, 175, 80, 30)]
        targets.update(laidOut: ["a": a, "b": moved])
        #expect(same(targets.icons, ["a": a, "b": moved]))
    }

    /// A band scrolling the grid keeps the icons it scrolled past, which may
    /// no longer be laid out, until it ends.
    @Test func iconsScrolledPastStillCountUntilTheBandEnds() {
        var targets = ShellBandTargets()
        targets.update(laidOut: ["a": a, "b": b])
        let c = [rect(15, 403, 70, 70)]
        targets.update(laidOut: ["b": b, "c": c])
        #expect(same(targets.icons, ["a": a, "b": b, "c": c]))
        targets.reset()
        #expect(targets.icons.isEmpty)
    }

    /// Regression: the band's icons were collected from the cells' onAppear,
    /// onDisappear and frame changes, which a lazy grid doesn't send reliably:
    /// after going to another folder and back, a reload or grouping, the band
    /// knew of none and selected nothing until the view was switched. Each band
    /// now starts from the icons laid out, whatever was laid out before.
    @Test func eachBandStartsFromTheIconsLaidOutNow() {
        var targets = ShellBandTargets()
        targets.update(laidOut: ["/A/a": a, "/A/b": b])
        targets.reset()                                  // the band ends; another folder
        targets.update(laidOut: ["/B/a": a])
        #expect(same(targets.icons, ["/B/a": a]))
        targets.reset()                                  // and back, laid out where it was
        targets.update(laidOut: ["/A/a": a, "/A/b": b])
        #expect(same(targets.icons, ["/A/a": a, "/A/b": b]))
    }
}

/// Which part of an icon's cell is the icon, for clicks.
@Suite struct ShellIconHitAreaTests {
    /// A 100 × 110 cell: its image (with the highlight's padding) and a short
    /// name below it.
    private let parts = [rect(15, 3, 70, 70), rect(32, 75, 36, 16)]

    @Test func theImageAndTheNameAreTheIcon() {
        #expect(ShellIconHitArea.contains(parts, CGPoint(x: 50, y: 40)))
        #expect(ShellIconHitArea.contains(parts, CGPoint(x: 50, y: 80)))
    }

    /// Regression: the whole cell took the icon's clicks, so a press beside a
    /// short name selected the icon, or dragged it, instead of starting a
    /// rubber band, and a click there didn't clear the selection.
    @Test func theRestOfTheCellIsEmptySpace() {
        #expect(!ShellIconHitArea.contains(parts, CGPoint(x: 5, y: 80)))      // beside the name
        #expect(!ShellIconHitArea.contains(parts, CGPoint(x: 90, y: 40)))     // beside the image
        #expect(!ShellIconHitArea.contains(parts, CGPoint(x: 50, y: 100)))    // below the name
        #expect(!ShellIconHitArea.contains(parts, CGPoint(x: 50, y: 1)))      // above the image
    }

    /// A part includes its top and left edges, not its bottom and right.
    @Test func edges() {
        #expect(ShellIconHitArea.contains(parts, CGPoint(x: 15, y: 3)))
        #expect(!ShellIconHitArea.contains(parts, CGPoint(x: 85, y: 40)))
        #expect(!ShellIconHitArea.contains(parts, CGPoint(x: 50, y: 91)))
        #expect(!ShellIconHitArea.contains([], CGPoint(x: 50, y: 40)))
    }
}

/// When a band whose mouse-up hasn't come ends without it.
@Suite struct ShellBandReleaseTests {
    private let step = 1.0 / 60
    private let grace = ShellBandRelease.grace

    /// What a band's timer is told at steps with the button down or up at
    /// those times, from the band's start.
    private func lost(_ steps: [(down: Bool, at: Double)]) -> [Bool] {
        var release = ShellBandRelease()
        return steps.map { release.isLost(buttonDown: $0.down, at: $0.at) }
    }

    @Test func aBandGoesOnWhileTheButtonIsDown() {
        let steps = (0..<120).map { (down: true, at: Double($0) * step) }
        #expect(!lost(steps).contains(true))
    }

    /// Regression: the band ended at the first step that read the button up,
    /// where the last drag the app had handled left it. The button reads up
    /// before the app has the last drags and the mouse-up, so a quick ⌘-drag
    /// up onto an icon's name now and then stopped short of the name and left
    /// the icon untoggled (IconsViewTests' ⌘-drag test failed about one run in
    /// ten). The band now waits for the mouse-up on its way.
    @Test func theFirstStepsWithTheButtonUpWaitForTheMouseUp() {
        #expect(lost([(true, 10), (false, 10 + step), (false, 10 + 2 * step)]) == [false, false, false])
    }

    /// Something else took the mouse-up: the band ends once the button has
    /// read up for the grace period.
    @Test func aMouseUpThatDoesntComeIsLostAfterTheGracePeriod() {
        #expect(lost([(false, 10), (false, 10 + grace - step), (false, 10 + grace)]) == [false, false, true])
    }

    /// The first step to see the button up starts the wait, however long
    /// after the button came up it runs (the main thread may have been busy):
    /// the events sent meanwhile arrive before the next step.
    @Test func aLateFirstStepStillWaits() {
        #expect(lost([(true, 10), (false, 15), (false, 15 + grace)]) == [false, false, true])
    }

    /// Pressed again before the grace period ran out: a new press, so the
    /// band's mouse-up went elsewhere. The band ends then; it doesn't follow
    /// the new press with the pointer it last saw.
    @Test func aNewPressBeforeTheMouseUpEndsTheBand() {
        let steps = [(down: true, at: 10), (false, 10 + step), (true, 10.125)]
        #expect(lost(steps) == [false, false, true])
    }
}
