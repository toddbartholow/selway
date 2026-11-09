import Foundation

// MARK: - Rubber-band selection in the icon grid

/// Finder's rubber band: a drag that starts on empty space in the icon grid
/// draws a rectangle and selects, while it is drawn, every icon whose image or
/// name it touches (ShellIconHitArea). A plain drag replaces the selection with those icons. With ⌘ or ⇧
/// held when the drag starts, it flips each icon it touches against the
/// selection the drag started with, as in Finder: icons that were selected
/// are taken out, the others added. (Finder treats ⇧ that way too; Selway
/// does the same with both rather than giving ⇧ a range of its own.)
///
/// Geometry is in the grid's coordinate space, y down. Plain arithmetic on
/// origin and size: CGRect's geometry helpers come from CoreGraphics, which
/// this Foundation-only module doesn't have on Linux.
enum ShellRubberBand {
    /// How a band combines the icons it touches with the selection.
    enum Mode: Equatable {
        /// Select exactly the icons touched.
        case replace
        /// Flip the icons touched against the selection the drag started with.
        case toggle
    }

    /// ⌘ or ⇧ held when the drag starts makes it toggle.
    static func mode(for modifiers: ShellIconClick.Modifiers) -> Mode {
        modifiers.isEmpty ? .replace : .toggle
    }

    /// Whether a press on empty space that has moved by (`dx`, `dy`) points
    /// draws a band yet. Up to that it is a click, which clears the selection.
    /// The same few points as a drag of an icon (ShellFileDrag.threshold).
    static func starts(dx: Double, dy: Double) -> Bool {
        ShellFileDrag.startsDrag(dx: dx, dy: dy)
    }

    /// The rectangle with corners `a` and `b`, whichever way the drag went.
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(origin: CGPoint(x: min(a.x, b.x), y: min(a.y, b.y)),
               size: CGSize(width: abs(a.x - b.x), height: abs(a.y - b.y)))
    }

    /// Whether the band touches a rectangle (a part of an icon). Edges that
    /// only meet don't count, but a band with no width or height yet (a
    /// straight drag) still touches the rectangles it crosses.
    static func touches(_ band: CGRect, _ part: CGRect) -> Bool {
        overlaps(band.origin.x, band.size.width, part.origin.x, part.size.width)
            && overlaps(band.origin.y, band.size.height, part.origin.y, part.size.height)
    }

    /// Whether a band's span from `a` (`aLength` long) and a part's from `b`
    /// share more than an end point. A band's span of no length is a line,
    /// which must fall inside the part's.
    private static func overlaps(_ a: CGFloat, _ aLength: CGFloat, _ b: CGFloat, _ bLength: CGFloat) -> Bool {
        aLength == 0 ? (b < a && a < b + bLength) : (a < b + bLength && b < a + aLength)
    }

    /// The icons, by id, the band touches: any of the parts of each that are
    /// the icon (ShellIconHitArea).
    static func touched(by band: CGRect, icons: [String: [CGRect]]) -> Set<String> {
        Set(icons.compactMap { id, parts in parts.contains { touches(band, $0) } ? id : nil })
    }

    /// The selection while the band touches `touched`. `base` is the selection
    /// the drag started with.
    static func selection(touched: Set<String>, base: Set<String>, mode: Mode) -> Set<String> {
        switch mode {
        case .replace: return touched
        case .toggle:  return base.symmetricDifference(touched)
        }
    }

    /// The fastest the grid scrolls under a band, in points a step.
    static let maxScrollStep: Double = 24

    /// How far to scroll the grid in one step (about a sixtieth of a second)
    /// with the pointer at `pointer` and the visible part of the grid from
    /// `top` to `bottom` (all y down): nothing while the pointer is inside;
    /// past the top or bottom edge, up or down, faster the further past, from
    /// 2 points a step up to `maxScrollStep`.
    static func scrollStep(pointer: Double, top: Double, bottom: Double) -> Double {
        func speed(_ past: Double) -> Double { min(maxScrollStep, max(2, past / 2)) }
        if pointer < top    { return -speed(top - pointer) }
        if pointer > bottom { return speed(pointer - bottom) }
        return 0
    }
}

// MARK: - The icons a band can select

/// Where the icons a rubber band tests against are while it is drawn, by id,
/// in the grid's coordinate space: the parts of each that are the icon
/// (ShellIconHitArea).
///
/// Read from the icons' own AppKit views each time the band moves
/// (IconGridBackgroundView), not collected from SwiftUI's onAppear,
/// onDisappear and onGeometryChange: in a lazy grid those don't come reliably.
/// A cell laid out again where it had been before reported no frame, so after
/// going to another folder and back, or a reload, the band knew of no icons;
/// and a cell that moved to another section (grouping) appeared before its old
/// self disappeared, so it counted as gone. The band then selected nothing
/// until switching views built the grid afresh.
///
/// The icons laid out now are where their views say. While a band scrolls the
/// grid, the ones it has scrolled past may no longer be laid out: they count
/// where they last were, which scrolling doesn't change, until the band ends.
struct ShellBandTargets {
    /// Every icon laid out since the band started, where its parts were last
    /// seen (ShellIconHitArea).
    private(set) var icons: [String: [CGRect]] = [:]

    init() {}

    /// The icons laid out now: where they are replaces where they were.
    mutating func update(laidOut: [String: [CGRect]]) {
        icons.merge(laidOut) { _, now in now }
    }

    /// A band starts or ends: none are known.
    mutating func reset() { icons = [:] }
}

// MARK: - A mouse-up that never arrives

/// Whether the left button came up without its mouse-up reaching the band's
/// view (something else took it), so the band should end without it. Asked at
/// each step of the band's timer with the button's state then
/// (NSEvent.pressedMouseButtons).
///
/// The button's state is the window server's, which runs ahead of the events
/// the app has handled: the button reads as up as soon as it is released,
/// while the last drags and the mouse-up may still be on their way. A band
/// that ended as soon as the button read up stopped where the last drag the
/// app had seen left it, short of where the pointer was let go, and the
/// mouse-up that followed did nothing. A quick ⌘-drag up onto an icon's name
/// could then leave that icon untoggled. So the mouse-up counts as lost only
/// once the button has read up for `grace` across two steps or more; the
/// events already sent arrive in between (the run loop takes them before the
/// timer is due again), and their mouse-up ends the band where it was let go.
/// The button down again after reading up is a new press, so the mouse-up
/// went elsewhere: the band ends then rather than following the new press.
struct ShellBandRelease {
    /// How long the button must read up, with no mouse-up, before the band
    /// ends without one: long enough for the events on their way, short
    /// enough not to be noticed when something else did take the mouse-up.
    static let grace: TimeInterval = 0.25

    /// When a step first saw the button up.
    private var upSince: TimeInterval?

    init() {}

    /// Whether the mouse-up is lost, at a step at `time` (seconds, any
    /// steady clock) with the button down or not.
    mutating func isLost(buttonDown: Bool, at time: TimeInterval) -> Bool {
        guard !buttonDown else { return upSince != nil }
        guard let since = upSince else {
            upSince = time
            return false
        }
        return time - since >= Self.grace
    }
}

// MARK: - Which part of a cell is the icon

/// The parts of an icon's cell that are the icon, as in Finder: its image and
/// its name, each with the highlight drawn behind it when it is selected. The
/// rest of the cell, the blank space beside a short name or around the image,
/// is empty space: a press there clears the selection or starts a rubber band,
/// and a band selects the icon only when it touches one of the parts.
///
/// A cell takes its column's whole width and its row's height, so before this
/// a band could start only in the narrow gaps between cells, the margins, or
/// below the last row, and a press beside a name selected the icon or dragged
/// it instead.
enum ShellIconHitArea {
    /// Whether `point` is on the icon whose parts are `parts` (both in the
    /// same coordinates). Each part includes its top and left edges but not its
    /// bottom and right ones, so a point on the line between two parts that
    /// meet is in one of them, not both.
    static func contains(_ parts: [CGRect], _ point: CGPoint) -> Bool {
        parts.contains { part in
            part.origin.x <= point.x && point.x < part.origin.x + part.size.width
                && part.origin.y <= point.y && point.y < part.origin.y + part.size.height
        }
    }
}
