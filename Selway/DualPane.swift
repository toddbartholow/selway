import SwiftUI
import AppKit

// MARK: - The panes side by side

/// How a dual window's width is shared between its panes (ShellPaneSplit):
/// the first pane's share, which the divider, the View menu's Make Left /
/// Right Pane Wider and Make Panes Equal Width, and VoiceOver change, all
/// through `widen` and `equalize`. Kept per window by BrowserPanes, so the
/// menus reach it; @Observable, so only PaneSplit, which reads `fraction`,
/// re-renders when it changes. What the rule needs besides (the width, the
/// least a pane may have, the layout's direction) is told by PaneSplit as it
/// lays the panes out, and not observed.
@MainActor
@Observable
final class PaneSplitState {
    /// The first (leading) pane's share of the width, as last set.
    var fraction = 0.5
    @ObservationIgnored var width = 0.0
    @ObservationIgnored var minPane = ShellPaneSplit.baseMinPaneWidth
    @ObservationIgnored var rightToLeft = false

    /// `fraction` as the panes show it: both at least `minPane` wide.
    var shown: Double { ShellPaneSplit.clamped(fraction, width: width, minPane: minPane) }

    /// The pane on `side` (as seen on screen), a step wider.
    func widen(_ side: ShellPaneSplit.Side) {
        fraction = ShellPaneSplit.widened(fraction, side: side, rightToLeft: rightToLeft, width: width, minPane: minPane)
    }

    /// Half and half.
    func equalize() { fraction = 0.5 }

    /// The left pane's share, in whole percent.
    var leftPercent: Int {
        ShellPaneSplit.leftPercent(fraction, rightToLeft: rightToLeft, width: width, minPane: minPane)
    }
}

/// A browser window's panes: the first alone, or with the second beside it
/// and a divider between them that can be dragged (double-click it for
/// half and half again), as View → Show / Hide Dual Pane says.
///
/// The first pane keeps its place in the view tree whether or not the second
/// is shown (`HStack { first; if isDual { divider; second } }`), so showing or
/// hiding the second doesn't rebuild the first, its list or its selection.
///
/// The split is `split`'s, which only this view reads: the window's body
/// doesn't re-render while the divider is dragged, and the panes, whose
/// inputs stay equal, don't either.
struct PaneSplit<First: View, Second: View>: View {
    let isDual: Bool
    let split: PaneSplitState
    let first: First
    let second: Second
    /// `split.fraction` when the divider was pressed, while it's dragged.
    @State private var dragStart: Double?
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.textScale) private var textScale

    init(isDual: Bool, split: PaneSplitState, @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.isDual = isDual
        self.split = split
        self.first = first()
        self.second = second()
    }

    var body: some View {
        GeometryReader { geometry in
            let available = max(Double(geometry.size.width) - 1, 0)
            let minPane = ShellPaneSplit.minPaneWidth(textScale: Double(textScale))
            let share = ShellPaneSplit.clamped(split.fraction, width: available, minPane: minPane)
            HStack(spacing: 0) {
                first
                    .frame(width: isDual ? CGFloat((available * share).rounded()) : nil)
                if isDual {
                    divider(available: available, minPane: minPane)
                    second
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // What the menus' and VoiceOver's steps need, kept up to date.
            .onChange(of: available, initial: true) { _, width in split.width = width }
            .onChange(of: minPane, initial: true) { _, least in split.minPane = least }
            .onChange(of: layoutDirection, initial: true) { _, direction in
                split.rightToLeft = direction == .rightToLeft
            }
        }
    }

    /// The 1-point line, with a wider handle over it that takes the drags,
    /// shows the resize cursor, and is the splitter VoiceOver finds.
    private func divider(available: Double, minPane: Double) -> some View {
        let rightToLeft = layoutDirection == .rightToLeft
        let percent = ShellPaneSplit.leftPercent(split.fraction, rightToLeft: rightToLeft,
                                                 width: available, minPane: minPane)
        return Divider()
            .accessibilityHidden(true)
            .overlay {
                PaneDividerHandle(
                    label: String(localized: "Pane divider"),
                    value: String(localized: "Left pane \(percent) percent"),
                    onBegin: { dragStart = ShellPaneSplit.clamped(split.fraction, width: available, minPane: minPane) },
                    onDrag: { dx in
                        guard let start = dragStart else { return }
                        split.fraction = ShellPaneSplit.dragged(from: start, dx: Double(dx), rightToLeft: rightToLeft,
                                                                width: available, minPane: minPane)
                    },
                    onEnd: { dragStart = nil },
                    onReset: { split.equalize() },
                    // A splitter's increment moves it right: the left pane grows.
                    onIncrement: { split.widen(.left) },
                    onDecrement: { split.widen(.right) })
                .frame(width: 7)
            }
            .zIndex(1)
    }
}

// MARK: - The divider's handle

/// The divider's handle: an AppKit view, so the resize cursor and the drag
/// work over the AppKit lists beside it, where SwiftUI's gestures and hover
/// don't reach reliably. It reports how far the pointer has moved since the
/// press, in points, positive to the right. For VoiceOver it's a splitter
/// ("Pane divider", "Left pane 50 percent") that increments and decrements.
private struct PaneDividerHandle: NSViewRepresentable {
    let label: String
    let value: String
    let onBegin: () -> Void
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    let onIncrement: () -> Void
    let onDecrement: () -> Void

    func makeNSView(context: Context) -> PaneDividerHandleView { PaneDividerHandleView() }

    func updateNSView(_ view: PaneDividerHandleView, context: Context) {
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onReset = onReset
        view.onIncrement = onIncrement
        view.onDecrement = onDecrement
        view.setAccessibilityLabel(label)
        if view.accessibilityValue() as? String != value {
            view.setAccessibilityValue(value)
            NSAccessibility.post(element: view, notification: .valueChanged)
        }
    }
}

final class PaneDividerHandleView: NSView {
    var onBegin: () -> Void = {}
    var onDrag: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}
    var onReset: () -> Void = {}
    var onIncrement: () -> Void = {}
    var onDecrement: () -> Void = {}
    private var pressX: CGFloat?
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityIdentifier("paneDivider")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityIdentifier("paneDivider")
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityOrientation() -> NSAccessibilityOrientation { .vertical }

    override func accessibilityPerformIncrement() -> Bool {
        onIncrement()
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onDecrement()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            pressX = nil
            onReset()
            return
        }
        pressX = event.locationInWindow.x
        onBegin()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressX else { return }
        NSCursor.resizeLeftRight.set()
        onDrag(event.locationInWindow.x - pressX)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressX != nil else { return }
        pressX = nil
        onEnd()
    }
}

// MARK: - Which pane is active

/// Makes the pane the user is working in the active one (BrowserPanes.active),
/// in a window showing two: the pane clicked, anywhere in it (its path bar,
/// its list or the space below it, its status bar), with any button, and the
/// pane that takes keyboard focus (Tab, or ↓ from the search field).
///
/// From AppKit rather than SwiftUI: the lists are AppKit tables, which take
/// the clicks before a SwiftUI tap gesture on the pane would see them. A
/// local monitor sees every mouse-down first (as ContextClickTracker does),
/// and key-value observing the window's first responder sees focus move (as
/// TextInputObserver does). Each finds the pane by where the click or the
/// focused view is in the window (PaneState.paneArea).
@MainActor
final class ActivePaneTracker {
    private weak var panes: BrowserPanes?
    private weak var window: NSWindow?
    private var monitor: Any?
    private var responderObservation: NSKeyValueObservation?

    /// Follows `window` for `panes`: from the window's appearing until it
    /// disappears (`stop`). Called again when the window changes (a tab moved
    /// to a window of its own); does nothing new otherwise.
    func follow(_ window: NSWindow?, for panes: BrowserPanes) {
        self.panes = panes
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] event in
                // Local monitors run on the main thread.
                MainActor.assumeIsolated { self?.mouseDown(event) }
                return event
            }
        }
        guard let window, window !== self.window || responderObservation == nil else { return }
        self.window = window
        responderObservation = window.observe(\.firstResponder) { [weak self] _, _ in
            // After the change is done with (and on the main thread, where KVO
            // of the first responder is sent anyway).
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.responderChanged() } }
        }
    }

    /// Stops following: the window has gone, or is out of sight.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        responderObservation = nil
        window = nil
    }

    private func mouseDown(_ event: NSEvent) {
        guard let panes, panes.isDual, let window, event.window === window else { return }
        let point = event.locationInWindow
        // The divider between the panes is neither's.
        if window.contentView?.superview?.hitTest(point) is PaneDividerHandleView { return }
        guard let pane = panes.pane(at: point), pane !== panes.active else { return }
        panes.activate(pane)
        // Keyboard focus goes with it, unless the click gave it focus itself
        // (a row, a field): arrow keys then move in the pane the user sees as
        // active. Once the click is done with.
        DispatchQueue.main.async { [weak window] in
            guard let window, panes.active === pane,
                  let focused = Self.frame(of: window.firstResponder),
                  let other = Self.pane(showing: focused, in: panes),
                  other !== pane else { return }
            pane.focusResults(rightToLeft: panes.layoutDirection == .rightToLeft)
        }
    }

    private func responderChanged() {
        guard let panes, panes.isDual, let window,
              let focused = Self.frame(of: window.firstResponder),
              let pane = Self.pane(showing: focused, in: panes) else { return }
        panes.activate(pane)
    }

    /// The pane a focused view is in, by its two ends; none for one that
    /// spans both, such as the hosting view SwiftUI leaves first responder
    /// with after a click on the computer's overview: its middle is in one
    /// pane whichever pane was clicked.
    private static func pane(showing frame: NSRect, in panes: BrowserPanes) -> PaneState? {
        let start = panes.pane(at: NSPoint(x: frame.minX + 1, y: frame.midY))
        let end = panes.pane(at: NSPoint(x: frame.maxX - 1, y: frame.midY))
        guard let start, start === end else { return nil }
        return start
    }

    /// Where a responder that's a view shows, in window coordinates: its
    /// visible part (a list's bounds run the length of its rows).
    private static func frame(of responder: NSResponder?) -> NSRect? {
        guard let view = responder as? NSView, view.window != nil else { return nil }
        let visible = view.visibleRect
        guard !visible.isEmpty else { return nil }
        return view.convert(visible, to: nil)
    }
}

/// Where a pane is in a dual window: which side it's on is read for
/// VoiceOver, left to right as the panes show (the first is on the right in
/// a right-to-left layout). The direction is always SwiftUI's, the one the
/// panes are laid out by: the group labels read it from the environment, and
/// the announcements from BrowserPanes.layoutDirection, which mirrors it.
enum PanePosition: Equatable {
    case first, second

    func isLeft(_ direction: LayoutDirection) -> Bool {
        (self == .first) == (direction == .leftToRight)
    }
}

// MARK: - The pane's header and group

/// The path bar's background: the bar's material, tinted with the selection
/// colour on the active pane of a dual window (greyed while the window isn't
/// key, as a selection is), with an accent line under it. `isActive` is nil
/// in a window with one pane, which shows the plain bar.
struct PaneHeaderBackground: View {
    let isActive: Bool?
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        ZStack {
            Rectangle().fill(.bar)
            if isActive == true {
                Color(nsColor: windowIsKey ? .selectedContentBackgroundColor
                                           : .unemphasizedSelectedContentBackgroundColor)
                    .opacity(windowIsKey ? 0.22 : 0.6)
            }
        }
    }

    private var windowIsKey: Bool { controlActiveState != .inactive }
}

/// The line under the path bar: on the active pane of a dual window, three
/// points high in the text colour (the accent colour can be yellow or
/// graphite, too faint against the bar), or the secondary text colour while
/// the window isn't key (unless Increase Contrast is on); a divider otherwise.
/// Both keep at least 3:1 against the bar in light and dark mode. Its height,
/// and the current folder's name in semibold in the path bar, tell the active
/// pane without its colour.
struct PaneHeaderEdge: View {
    let isActive: Bool?
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if isActive == true {
            Rectangle()
                .fill(controlActiveState == .inactive && contrast != .increased ? Color.secondary : Color.primary)
                .frame(height: 3)
        } else {
            Divider()
        }
    }
}

// MARK: - Copy / Move to Other Pane

/// File → Copy / Move to Other Pane's confirmation, for `.sheet(item:)`.
struct PaneTransferRequest: Identifiable {
    let id = UUID()
    let plan: ShellPaneTransfer.Plan
}

/// Whether F5 / F6 are reading the selection, off the main thread, before
/// they ask: a key held down then only beeps, as it does once the sheet is
/// up. Held, not observed, so it doesn't re-render the window.
final class PaneTransferCheck {
    var isRunning = false
}

/// Asks before F5 / F6 copy or move the selection into the other pane's
/// folder: how many items (or which one), and where. Return confirms, Escape
/// cancels.
struct PaneTransferSheet: View {
    let plan: ShellPaneTransfer.Plan
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.textScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: plan.mode == .copy ? "doc.on.doc" : "folder")
                    .scaledFont(size: 22)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: plan.title)
                        .scaledFont(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: plan.message)
                        .scaledFont(size: 12)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                confirmButton
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420 * textScale)
        .accessibilityIdentifier("paneTransferSheet")
    }

    @ViewBuilder
    private var confirmButton: some View {
        switch plan.mode {
        case .copy: Button("Copy") { confirm() }
        case .move: Button("Move") { confirm() }
        }
    }

    private func confirm() {
        dismiss()
        onConfirm()
    }
}
