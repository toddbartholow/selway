import AppKit
import SwiftUI

// MARK: - Clicks and drag-out on an icon
//
// Each icon in the grid has one of these laid over its cell, in place of
// SwiftUI's tap gestures and `onDrag`. `onDrag` started a drag as soon as the pointer
// moved a point with the button down, and the drag took the click: a hand
// that moved a point or two while clicking (about one click in three or four)
// left the icon unselected, and the next click on empty space seemed to need
// two. The clicks and drags are FileMouseView's, shared with the column
// browser's rows (FileDragSupport.swift). Here, as in Finder:
// - mouse-down selects at once (ShellIconClick, with ⌘ and ⇧), and the second
//   mouse-down of a double-click on the same icon opens (see IconClickRouting
//   and ShellIconClick.PressTracker for why AppKit's click count isn't enough);
// - the press stays a click until the pointer has moved past
//   ShellFileDrag.threshold, then becomes a drag with one dragging item per
//   file it carries (`onDrag`'s one item provider carried only the first);
// - mouse-up after a press that didn't drag ends the click (a plain click
//   inside a larger selection narrows it then; see IconGridActions).
//
// Only the left button's clicks on the icon's image or name are this view's
// (ShellIconHitArea; IconCell marks those parts with `iconHitPart`). On the
// rest of the cell hitTest gives way to the grid's background, as in Finder,
// so a press beside a short name clears the selection or starts a rubber band
// (IconGridBackgroundView). For anything but the left button it gives way to
// the SwiftUI cell beneath, so a right-click or ⌃-click still opens the
// cell's context menu and the scroll wheel still scrolls (the column
// browser's ResizeCursorTracker relies on the same thing). Drops find
// a folder icon's FileDropView by its registered types, not by hitTest, so
// this view, which registers none, doesn't come between them. It is hidden
// from accessibility: the cell (IconGridCell) is the element there, with
// actions that select and open its item, and its name and icon inside it.

/// An IconMouseView over a SwiftUI view.
struct IconMouseArea: NSViewRepresentable {
    /// The icon's item, so the rubber band can tell which icon this view is
    /// over (IconGridBackgroundView).
    let itemID: String
    /// Where the icon's image and name are in this view (IconHitParts): the
    /// parts that take its clicks and that a rubber band selects it by.
    let hitParts: [CGRect]
    /// Mouse-down on the icon: the event's click count, the keys held and the
    /// event's timestamp. Returns whether the press began a series of clicks
    /// on the icon (it selected rather than opened).
    let onPress: (_ clickCount: Int, _ modifiers: ShellIconClick.Modifiers, _ time: TimeInterval) -> Bool
    /// Mouse-up after a single press that didn't become a drag.
    let onRelease: () -> Void
    /// The files a drag carries, the pressed one first, for a drag image of
    /// the given side in pixels. Read when the drag starts, not when the cell
    /// was drawn.
    let dragFiles: (_ pixelSide: CGFloat) -> [FileMouseView.DragFile]
    /// The icon's side at 100%, for the drag image; the window's text size
    /// scales it, as in FileIconView.
    let iconSize: CGFloat
    let isReadOnlyLocation: Bool

    func makeNSView(context: Context) -> IconMouseView {
        let view = IconMouseView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: IconMouseView, context: Context) {
        view.itemID    = itemID
        view.hitParts  = hitParts
        view.onPress   = onPress
        view.onRelease = onRelease
        view.dragFiles = dragFiles
        view.isReadOnlyLocation = isReadOnlyLocation
        view.iconSide  = (iconSize * context.environment.textScale).rounded()
        view.fileOperations = context.environment.fileOperations
    }
}

/// The parts of an icon's cell that are the icon (ShellIconHitArea), for its
/// IconMouseArea: IconCell marks them with `iconHitPart`, and the cell reads
/// them with `overlayPreferenceValue`.
struct IconHitParts: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value += nextValue()
    }
}

extension View {
    /// Marks this view as a part of an icon that takes its clicks (its image
    /// or its name, IconHitParts), for IconMouseView and for SwiftUI's own
    /// hit-testing, which the context menu goes by: a rounded rectangle over
    /// the whole view, not only the pixels drawn in it.
    func iconHitPart(cornerRadius: CGFloat) -> some View {
        contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .anchorPreference(key: IconHitParts.self, value: .bounds) { [$0] }
    }
}

/// Takes an icon's left-button clicks and starts its drags (see above).
final class IconMouseView: FileMouseView {
    var itemID: String?
    /// In this view's coordinates; none before SwiftUI has placed them.
    var hitParts: [CGRect] = []

    /// How far below the top of the cell its image is (IconCell).
    private static let cellPadding: CGFloat = 6

    override init() {
        super.init()
        iconSide = 64
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Which events are this view's

    /// Only the icon's image and name (ShellIconHitArea).
    override func takesClick(at point: NSPoint) -> Bool {
        ShellIconHitArea.contains(partsOnIcon, point)
    }

    /// The parts of the cell that are the icon, in this view's coordinates:
    /// its image and name, or the whole cell until they are known.
    var partsOnIcon: [CGRect] { hitParts.isEmpty ? [bounds] : hitParts }

    // MARK: Dragging out

    /// The image, centred at the top of the cell.
    override func iconFrame(side: CGFloat) -> NSRect {
        NSRect(x: (bounds.width - side) / 2, y: Self.cellPadding, width: side, height: side)
    }
}

// MARK: - Multi-clicks that move to another view

/// Starts a new click series when a click lands on a different view from the
/// click before it and either of them is an icon (or a column's row: either
/// is a FileMouseView, a view per file).
///
/// The window server can count quick clicks as one series even when they land
/// on different icons, and NSWindow sends the second and later mouse-downs of
/// a series to the view that took the first, without hit-testing them again.
/// With a view per icon that went wrong both ways: a click on one folder and
/// then, quickly, on another (or on empty space) reached the first folder's
/// view as its second click and opened that folder; a click on empty space
/// and then on a folder reached the grid's background and selected nothing.
/// (Finder's and NSCollectionView's items share one view, which hit-tests
/// every click itself.) This watches left mouse-downs and, for one that would
/// be misrouted like that, hands AppKit a copy with a click count of one,
/// which it hit-tests and delivers to the view under the pointer as the first
/// click of a new series. The rest of that series, and the
/// mouse-ups, are counted from there (ShellClickSeries), so a double-click in
/// a text field just after a click on an icon is a double-click there. Clicks
/// that stay on one view, and clicks with no icon or row involved, are left
/// as they are. The icon or row then decides for itself whether a press opens
/// (ShellIconClick.PressTracker).
@MainActor
enum IconClickRouting {
    /// The event FileMouseView.hitTest is asked about while this hit-tests a
    /// mouse-down itself (NSApp.currentEvent isn't that event yet).
    private(set) static var hitTesting: NSEvent?
    /// The view the last left mouse-down went to, in any window.
    private static weak var lastHit: NSView?
    /// The counts of the series in progress.
    private static var series = ShellClickSeries()
    private static var monitor: Any?

    /// Starts watching; once per app, however many icons and rows call it.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            // Local monitors run on the main thread.
            let count = MainActor.assumeIsolated { clickCount(for: event) }
            guard count != event.clickCount else { return event }
            return NSEvent.mouseEvent(with: event.type, location: event.locationInWindow,
                                      modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                      windowNumber: event.windowNumber, context: nil,
                                      eventNumber: event.eventNumber, clickCount: count,
                                      pressure: event.pressure) ?? event
        }
    }

    /// The click count AppKit should see for a left mouse-down or mouse-up:
    /// the one the series gives it (when that isn't the system's, the
    /// monitor hands AppKit a copy with it).
    private static func clickCount(for event: NSEvent) -> Int {
        guard event.type == .leftMouseDown else { return series.mouseUp(clickCount: event.clickCount) }
        let hit = view(under: event)
        let previous = lastHit
        lastHit = hit
        return series.mouseDown(clickCount: event.clickCount, on: hit, after: previous,
                                isIcon: { $0 is FileMouseView })
    }

    /// The view a fresh mouse-down at the event's point would go to.
    private static func view(under event: NSEvent) -> NSView? {
        // The frame view has no superview: its hitTest takes window coordinates.
        guard let frame = event.window?.contentView?.superview else { return nil }
        hitTesting = event
        defer { hitTesting = nil }
        return frame.hitTest(event.locationInWindow)
    }
}
