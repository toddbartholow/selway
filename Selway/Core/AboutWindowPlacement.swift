import Foundation

/// Where the About and Acknowledgments windows open: Acknowledgments beside About, not
/// over it, and neither off the screens.
///
/// Plain arithmetic on origin and size: CGRect's geometry helpers come from CoreGraphics,
/// which this Foundation-only module doesn't have on Linux.
enum AboutWindowPlacement {
    /// The Acknowledgments window's frame (in screen coordinates, origin at the bottom left,
    /// as AppKit has them) for a window of `size` beside `about`, on a screen whose
    /// visible frame is `visible`.
    ///
    /// It goes to About's right, top edges level, or to its left when the right has no
    /// room. With room on neither side it keeps to the screen edge on the roomier side,
    /// covering as little of About as it can. It always stays inside `visible`, and is
    /// made smaller only when it's bigger than the screen.
    static func acknowledgmentsFrame(size: CGSize, beside about: CGRect, in visible: CGRect,
                                     gap: CGFloat = 12) -> CGRect {
        let screenMinX = visible.origin.x, screenMaxX = visible.origin.x + visible.size.width
        let screenMinY = visible.origin.y, screenMaxY = visible.origin.y + visible.size.height
        let aboutMinX = about.origin.x, aboutMaxX = about.origin.x + about.size.width
        let aboutMaxY = about.origin.y + about.size.height

        let width = min(size.width, visible.size.width)
        let height = min(size.height, visible.size.height)
        let right = aboutMaxX + gap
        let left = aboutMinX - gap - width
        let x: CGFloat
        if right + width <= screenMaxX {
            x = right
        } else if left >= screenMinX {
            x = left
        } else if screenMaxX - aboutMaxX >= aboutMinX - screenMinX {
            x = screenMaxX - width
        } else {
            x = screenMinX
        }
        let y = aboutMaxY - height
        return CGRect(origin: CGPoint(x: clamp(x, screenMinX, screenMaxX - width),
                                      y: clamp(y, screenMinY, screenMaxY - height)),
                      size: CGSize(width: width, height: height))
    }

    /// Whether a window at `frame` shows enough on one of `screens` (their frames, in the
    /// same coordinates) to be seen and dragged: at least `minimumOverlap` points of it
    /// across and down on one screen, or all of it for a smaller window. A window closed
    /// on a display that has since been unplugged, or moved, can be off all of them.
    static func isOnScreen(_ frame: CGRect, screens: [CGRect], minimumOverlap: CGFloat = 40) -> Bool {
        let neededAcross = max(min(minimumOverlap, frame.size.width), 1)
        let neededDown = max(min(minimumOverlap, frame.size.height), 1)
        return screens.contains { screen in
            let across = min(frame.origin.x + frame.size.width, screen.origin.x + screen.size.width)
                - max(frame.origin.x, screen.origin.x)
            let down = min(frame.origin.y + frame.size.height, screen.origin.y + screen.size.height)
                - max(frame.origin.y, screen.origin.y)
            return across >= neededAcross && down >= neededDown
        }
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        max(low, min(value, high))
    }
}
