import AppKit
import SwiftUI

// MARK: - Empty space in the icon grid: clicks and the rubber band
//
// An AppKit view behind the icons takes the left button's presses on the
// space around and between them, as IconMouseView takes them on the icons.
// That includes the blank parts of each icon's cell, beside a short name or
// around the image, which IconMouseView gives way on (ShellIconHitArea), and
// the section headers, which hand their presses here (IconGridPassThrough):
// - a press that stays within ShellRubberBand's few points is a click, which
//   clears the selection (unless ⌘ or ⇧ is held), however the hand moves;
// - past that it draws Finder's rubber band, selecting the icons whose image
//   or name it touches while it is drawn (ShellRubberBand: plain replaces the
//   selection, ⌘ or ⇧ toggles against the selection it started with);
// - held past the grid's top or bottom edge, the band scrolls the grid and
//   keeps growing, until the pointer comes back or the button comes up.
// AppKit rather than a DragGesture: held still past the edge, the band has to
// go on scrolling the grid's NSScrollView with no events coming in, which
// this view can do from a timer; and its presses reach it the same way as the
// icons' do, so IconClickRouting can tell the two apart.
//
// Like IconMouseView it takes left clicks only, so a right-click on empty
// space still opens the grid's context menu and the scroll wheel still
// scrolls; it registers no drag types, so drops find the grid's drop area as
// before (FileDropSupport); and it is hidden from accessibility.
//
// The band is drawn by RubberBandOverlay, above the icons, and is the only
// view that redraws as it moves. It tests the icons' IconMouseViews, read
// afresh each time it moves (ShellBandTargets): an icon laid out has one over
// its cell, knowing where the icon's image and name are in it, which convert
// into this view's coordinates, the grid's (flipped) and the overlay's.

/// The rubber band in progress, and the icons it tests against.
@MainActor
final class IconRubberBand: ObservableObject {
    /// The band, in the grid's coordinates (IconGridBackgroundView's), while
    /// one is drawn.
    @Published private(set) var rect: CGRect?

    /// The grid's selection (IconGridActions keeps this current).
    var selection: Binding<Set<String>> = .constant([])
    /// Told when a band starts and ends (IconsView, so that selected cells
    /// needn't be redrawn each time the band changes the selection).
    var onActiveChange: (Bool) -> Void = { _ in }

    private var targets = ShellBandTargets()
    private var start = CGPoint.zero
    private var base: Set<String> = []
    private var mode = ShellRubberBand.Mode.replace

    var isActive: Bool { rect != nil }

    /// The view behind the icons, for the section headers to hand their
    /// presses to (IconGridPassThrough).
    weak var background: IconGridBackgroundView?

    /// Starts a band at `point`, with the icons laid out now (by id, where
    /// their parts are in the grid).
    func begin(at point: CGPoint, modifiers: ShellIconClick.Modifiers, laidOut: [String: [CGRect]]) {
        targets.reset()
        start = point
        base = selection.wrappedValue
        mode = ShellRubberBand.mode(for: modifiers)
        onActiveChange(true)
        move(to: point, laidOut: laidOut)
    }

    /// The pointer is at `point` (or the grid scrolled under it), with these
    /// icons laid out.
    func move(to point: CGPoint, laidOut: [String: [CGRect]]) {
        targets.update(laidOut: laidOut)
        let band = ShellRubberBand.rect(from: start, to: point)
        if rect != band { rect = band }
        let touched = ShellRubberBand.touched(by: band, icons: targets.icons)
        let selected = ShellRubberBand.selection(touched: touched, base: base, mode: mode)
        if selected != selection.wrappedValue { selection.wrappedValue = selected }
    }

    func end() {
        guard rect != nil else { return }
        rect = nil
        targets.reset()
        onActiveChange(false)
    }
}

/// An IconGridBackgroundView behind the icons.
struct IconGridBackground: NSViewRepresentable {
    let band: IconRubberBand
    /// Mouse-down on empty space, with the keys held.
    let onPress: (_ modifiers: ShellIconClick.Modifiers) -> Void
    /// Mouse-up after a press that didn't draw a band (a click).
    let onClick: (_ modifiers: ShellIconClick.Modifiers) -> Void

    func makeNSView(context: Context) -> IconGridBackgroundView {
        let view = IconGridBackgroundView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: IconGridBackgroundView, context: Context) {
        band.background = view
        view.band    = band
        view.onPress = onPress
        view.onClick = onClick
    }

    static func dismantleNSView(_ view: IconGridBackgroundView, coordinator: ()) {
        view.endBand()
    }
}

/// Takes the left button's presses on empty space in the grid (see above).
final class IconGridBackgroundView: NSView {
    var band: IconRubberBand?
    var onPress: (ShellIconClick.Modifiers) -> Void = { _ in }
    var onClick: (ShellIconClick.Modifiers) -> Void = { _ in }

    /// The press in progress: where it went down (window coordinates) and the
    /// keys held then.
    private var press: (at: NSPoint, modifiers: ShellIconClick.Modifiers)?
    /// The pointer's last position in the window while a band is drawn.
    private var pointer = NSPoint.zero
    /// Scrolls the grid while the pointer is past its edge, and follows the
    /// grid scrolling under the band however it scrolls.
    private var timer: Timer?
    /// Whether the band's mouse-up has gone elsewhere (see step()).
    private var release = ShellBandRelease()

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    /// As on an icon: a click in a window in the background clears the
    /// selection (or starts a band) as well as bringing the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = IconClickRouting.hitTesting ?? NSApp.currentEvent, IconMouseView.takes(event) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { endBand() }
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        endBand()
        let modifiers = ShellIconClick.Modifiers(event.modifierFlags)
        press = (event.locationInWindow, modifiers)
        onPress(modifiers)
    }

    override func mouseDragged(with event: NSEvent) {
        pointer = event.locationInWindow
        if let band, band.isActive {
            band.move(to: bandPoint(), laidOut: iconsLaidOut())
            return
        }
        guard let press,
              ShellRubberBand.starts(dx: Double(pointer.x - press.at.x), dy: Double(pointer.y - press.at.y)),
              let band else { return }
        let icons = iconsLaidOut()
        band.begin(at: clamped(convert(press.at, from: nil)), modifiers: press.modifiers, laidOut: icons)
        band.move(to: bandPoint(), laidOut: icons)
        startTimer()
    }

    override func mouseUp(with event: NSEvent) {
        defer { press = nil }
        if let band, band.isActive {
            pointer = event.locationInWindow
            finishBand()
        } else if let press {
            onClick(press.modifiers)
        }
    }

    /// Stretches the band to the pointer a last time and ends it, leaving
    /// selected what it touches there.
    private func finishBand() {
        band?.move(to: bandPoint(), laidOut: iconsLaidOut())
        endBand()
    }

    func endBand() {
        timer?.invalidate()
        timer = nil
        band?.end()
    }

    /// The pointer in the grid's coordinates, kept inside the grid.
    private func bandPoint() -> CGPoint { clamped(convert(pointer, from: nil)) }

    private func clamped(_ point: NSPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    /// The icons laid out in the grid now, by id, with where their image and
    /// name are in this view: one IconMouseView over each, in the same scroll
    /// view. (The grid keeps some it has laid out before hidden.)
    private func iconsLaidOut() -> [String: [CGRect]] {
        guard let root = enclosingScrollView?.documentView ?? superview else { return [:] }
        var icons: [String: [CGRect]] = [:]
        func visit(_ view: NSView) {
            guard let icon = view as? IconMouseView else { return view.subviews.forEach(visit) }
            guard let id = icon.itemID, !icon.isHiddenOrHasHiddenAncestor else { return }
            icons[id] = icon.partsOnIcon.map { convert($0, from: icon) }
        }
        visit(root)
        return icons
    }

    // MARK: Auto-scroll

    private func startTimer() {
        timer?.invalidate()
        release = ShellBandRelease()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.step() }
        }
        // Common modes, so it keeps firing however the run loop is waiting.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// One step of the timer: scroll if the pointer is past the top or bottom
    /// edge, then stretch the band to wherever the pointer is in the grid now.
    /// If the button has come up without its mouse-up reaching this view
    /// (something else took it), the band ends there, as on a mouse-up, and
    /// a mouse-up that comes in late does nothing. Until then, with the button
    /// up, it waits for the mouse-up on its way (ShellBandRelease).
    private func step() {
        guard let band, band.isActive else { return endBand() }
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        if release.isLost(buttonDown: buttonDown, at: ProcessInfo.processInfo.systemUptime) {
            press = nil
            return finishBand()
        }
        guard buttonDown else { return }
        scrollTowardsPointer()
        band.move(to: bandPoint(), laidOut: iconsLaidOut())
    }

    private func scrollTowardsPointer() {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let visible = clip.bounds
        let point = clip.convert(pointer, from: nil)
        // In the clip view's coordinates, measured downwards, less the part of
        // it under the title bar and toolbar (as FileDropView's autoscroll).
        let insets = scrollView.contentInsets
        let down: (CGFloat) -> Double = { Double(clip.isFlipped ? $0 : -$0) }
        let top    = clip.isFlipped ? visible.minY + insets.top : visible.maxY - insets.top
        let bottom = clip.isFlipped ? visible.maxY - insets.bottom : visible.minY + insets.bottom
        let step = ShellRubberBand.scrollStep(pointer: down(point.y), top: down(top), bottom: down(bottom))
        guard step != 0 else { return }
        var origin = visible.origin
        origin.y += clip.isFlipped ? step : -step
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: visible.size)).origin
        guard target != visible.origin else { return }
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
    }
}

// MARK: - Scrolling an icon into view (the arrow keys)

extension IconGridBackgroundView {
    /// What `reveal(itemID:)` found.
    enum Reveal: Equatable {
        /// The grid hasn't laid the icon out (nothing scrolled).
        case notLaidOut
        /// The grid scrolled towards it.
        case scrolled
        /// It shows already, or the grid can scroll no further towards it.
        case inView
    }

    /// Scrolls the grid as little as shows all of the icon for `itemID`, clear
    /// of the title bar and toolbar and of a whole group header pinned at the
    /// top (IconGridReveal). The icon is found by its IconMouseView and the
    /// headers by their IconGridPassThroughViews, in this view's scroll view.
    func reveal(itemID: String) -> Reveal {
        guard let scrollView = enclosingScrollView, let document = scrollView.documentView else { return .notLaidOut }
        var icon: IconMouseView?
        var headers: [NSView] = []
        func visit(_ view: NSView) {
            if let mouse = view as? IconMouseView {
                // The grid keeps some icons it has laid out before hidden.
                if mouse.itemID == itemID, !mouse.isHiddenOrHasHiddenAncestor { icon = mouse }
                return
            }
            if view is IconGridPassThroughView {
                if !view.isHiddenOrHasHiddenAncestor { headers.append(view) }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(document)
        guard let icon else { return .notLaidOut }

        let clip = scrollView.contentView
        let visible = clip.bounds
        // In the clip view's coordinates, measured downwards (as the rubber
        // band's auto-scroll measures them).
        func span(_ rect: NSRect) -> IconGridReveal.Span {
            clip.isFlipped ? .init(top: rect.minY, bottom: rect.maxY) : .init(top: -rect.maxY, bottom: -rect.minY)
        }
        let insets = scrollView.contentInsets
        let whole = span(visible)
        let viewport = IconGridReveal.Span(top: whole.top + insets.top, bottom: whole.bottom - insets.bottom)
        let covered = IconGridReveal.pinnedHeaderHeight(headers: headers.map { span(clip.convert($0.bounds, from: $0)) })
        guard let delta = IconGridReveal.scrollDelta(toReveal: span(clip.convert(icon.bounds, from: icon)),
                                                     in: viewport, covered: covered) else { return .inView }
        var origin = visible.origin
        origin.y += clip.isFlipped ? delta : -delta
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: visible.size)).origin
        guard target != visible.origin else { return .inView }
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
        return .scrolled
    }
}

/// Over something laid on top of the grid's empty space (a section header):
/// hands the left button's presses there to the view behind the icons, so
/// they clear the selection or start a rubber band as anywhere else that
/// isn't an icon. Anything else, a right-click or the scroll wheel, goes to
/// what is beneath, as with IconMouseView. Hidden from accessibility.
struct IconGridPassThrough: NSViewRepresentable {
    let band: IconRubberBand

    func makeNSView(context: Context) -> IconGridPassThroughView {
        let view = IconGridPassThroughView()
        view.band = band
        return view
    }

    func updateNSView(_ view: IconGridPassThroughView, context: Context) {
        view.band = band
    }
}

/// Hit-tests as the grid's IconGridBackgroundView for the left button's
/// events (see IconGridPassThrough).
final class IconGridPassThroughView: NSView {
    weak var band: IconRubberBand?

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = IconClickRouting.hitTesting ?? NSApp.currentEvent, IconMouseView.takes(event),
              let background = band?.background, background.window != nil, background.window === window
        else { return nil }
        return background
    }
}

/// Draws the rubber band in the system's colours: the accent colour, faint,
/// with a thin border, as NSCollectionView and Finder draw theirs.
struct RubberBandOverlay: View {
    @ObservedObject var band: IconRubberBand

    var body: some View {
        if let rect = band.rect {
            Rectangle()
                .fill(Color(nsColor: .controlAccentColor).opacity(0.18))
                .overlay(Rectangle().strokeBorder(Color(nsColor: .controlAccentColor).opacity(0.8), lineWidth: 1))
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
