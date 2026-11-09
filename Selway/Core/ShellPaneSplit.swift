import Foundation

/// How a dual-pane window's width is shared between its panes: the first
/// (leading) pane's share of the width they have, which the divider, View →
/// Make Left Pane Wider / Make Right Pane Wider / Make Panes Equal Width and
/// VoiceOver's increment and decrement change.
enum ShellPaneSplit {

    /// A side of the window as it shows on screen.
    enum Side: Equatable, Sendable {
        case left, right
    }

    /// How far one View menu command or one VoiceOver step moves the divider:
    /// a twentieth of the width.
    static let step = 0.05

    /// Neither pane is made narrower than this, at 100% text size; it grows
    /// with the text (`minPaneWidth(textScale:)`).
    static let baseMinPaneWidth = 220.0

    static func minPaneWidth(textScale: Double) -> Double {
        baseMinPaneWidth * max(textScale, 0.5)
    }

    /// `fraction` (the first pane's share), kept where both panes are at
    /// least `minPane` wide in `width`; half and half when they can't both be.
    static func clamped(_ fraction: Double, width: Double, minPane: Double) -> Double {
        guard width > 2 * minPane, minPane >= 0 else { return 0.5 }
        let least = minPane / width
        return min(max(fraction, least), 1 - least)
    }

    /// The first pane's share after making the pane on `side` a step wider.
    /// In a right-to-left layout the first pane is on the right.
    static func widened(_ fraction: Double, side: Side, rightToLeft: Bool,
                        width: Double, minPane: Double) -> Double {
        let firstIsLeft = !rightToLeft
        let firstGrows = (side == .left) == firstIsLeft
        let start = clamped(fraction, width: width, minPane: minPane)
        return clamped(start + (firstGrows ? step : -step), width: width, minPane: minPane)
    }

    /// The share of the pane on the left, as a whole percentage: what
    /// VoiceOver reads for the divider ("Left pane 60 percent").
    static func leftPercent(_ fraction: Double, rightToLeft: Bool, width: Double, minPane: Double) -> Int {
        let first = clamped(fraction, width: width, minPane: minPane)
        return Int(((rightToLeft ? 1 - first : first) * 100).rounded())
    }

    /// The first pane's share after a drag of `dx` points (positive to the
    /// right) that began at `start`.
    static func dragged(from start: Double, dx: Double, rightToLeft: Bool,
                        width: Double, minPane: Double) -> Double {
        guard width > 0 else { return clamped(start, width: width, minPane: minPane) }
        let moved = rightToLeft ? -dx : dx
        return clamped(start + moved / width, width: width, minPane: minPane)
    }
}
