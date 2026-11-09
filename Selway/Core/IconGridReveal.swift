import Foundation

/// Scrolling the Icons view to the icon the arrow keys moved to, as little as
/// will show all of it, as Finder does. With Group By on, the group's header
/// is pinned over the top of the grid, so the icon has to come to rest below
/// it, not under it.
///
/// Everything here is in the scroll view's content coordinates, measured
/// downwards (y grows towards the end of the folder).
enum IconGridReveal {
    /// A stretch of the grid from `top` down to `bottom`.
    struct Span: Equatable {
        var top: CGFloat
        var bottom: CGFloat

        init(top: CGFloat, bottom: CGFloat) {
            self.top = top
            self.bottom = max(top, bottom)
        }

        var height: CGFloat { bottom - top }
    }

    /// How far down from the viewport's top the group header pinned there
    /// covers the grid once the icon has come to rest: a whole header. Not
    /// what covers it now: with the top of the window in the gap between two
    /// groups, or while the next group's header pushes the pinned one off, a
    /// header covers less (or nothing), but once an icon is at the top its own
    /// group's header is pinned over it in full (issue #24). Every header is
    /// the same height, so this is the tallest of those laid out. Zero with
    /// none (Group By off).
    static func pinnedHeaderHeight(headers: [Span]) -> CGFloat {
        headers.map(\.height).max() ?? 0
    }

    /// How far to scroll (positive is down) so that `item` shows in full in
    /// `viewport`, below the `covered` height at its top; nil when it already
    /// does. An icon above that space comes to rest just below the header, an
    /// icon below it at the bottom edge. One taller than the space shows its
    /// top, and once it does needs no more scrolling. Rounding in the layout
    /// can leave an icon a fraction of a point past an edge; that counts as in
    /// view.
    static func scrollDelta(toReveal item: Span, in viewport: Span, covered: CGFloat) -> CGFloat? {
        let top = viewport.top + max(0, covered)
        let bottom = max(top, viewport.bottom)
        let tolerance: CGFloat = 0.5
        if item.top < top - tolerance {
            return item.top - top
        }
        if item.bottom > bottom + tolerance, item.top > top + tolerance {
            // Down only as far as keeps the icon's top below the header.
            return min(item.bottom - bottom, item.top - top)
        }
        // In view, or taller than the space with its top already showing.
        return nil
    }
}
