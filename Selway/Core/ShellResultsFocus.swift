import Foundation

/// Where keyboard focus goes from the search field (Return or ↓): to a list in
/// the file browser, never the sidebar's. Of the lists whose middle lies in the
/// browser's area, the one at the trailing edge: the last column in Columns view,
/// which is the leftmost in a right-to-left layout.
enum ShellResultsFocus {
    /// Frames are in one coordinate space (the window's). The index into
    /// `listFrames`, or nil when no list is in the browser's area.
    static func target(listFrames: [CGRect], browserArea: CGRect, rightToLeft: Bool) -> Int? {
        var best: Int?
        for (i, frame) in listFrames.enumerated() where isInArea(frame, browserArea: browserArea) {
            guard let current = best else { best = i; continue }
            let other = listFrames[current]
            let further = rightToLeft ? frame.origin.x < other.origin.x
                                      : frame.origin.x + frame.size.width > other.origin.x + other.size.width
            if further { best = i }
        }
        return best
    }

    /// Whether a list's visible frame belongs to the browser area (a pane's):
    /// its middle lies inside. An empty frame is a list scrolled out of sight
    /// (a column off the side), and belongs nowhere.
    static func isInArea(_ frame: CGRect, browserArea a: CGRect) -> Bool {
        // Plain arithmetic on origin and size: CGRect's geometry helpers come from
        // CoreGraphics, which this target doesn't use (it also builds on Linux).
        guard frame.size.width > 0, frame.size.height > 0 else { return false }
        let x = frame.origin.x + frame.size.width / 2, y = frame.origin.y + frame.size.height / 2
        return x >= a.origin.x && x < a.origin.x + a.size.width
            && y >= a.origin.y && y < a.origin.y + a.size.height
    }
}
