import Foundation

/// The arrow keys in the Icons view, as in Finder: ← and → move through the
/// icons in display order, ↑ and ↓ to the same column of the row above or below.
enum IconGridNavigation {
    enum Direction: Equatable {
        case right, left, down, up
    }

    /// The selection after an arrow key, and where the next one starts.
    struct Move: Equatable {
        let selection: Set<String>
        let lead: String
        /// Where a ⇧-arrow's or ⇧-click's range starts.
        let anchor: String
    }

    /// Where the arrow keys move from: `lead` (the icon last clicked or moved
    /// to) while it is still selected, else the first selected icon in `order`
    /// (after a rubber band, or a ⌘-click that deselected it). Nil with nothing
    /// selected.
    static func lead(_ lead: String?, selection: Set<String>, order: [String]) -> String? {
        if let lead, selection.contains(lead) { return lead }
        return order.first(where: selection.contains)
    }

    /// An arrow key moved from `lead` to `id`. Without ⇧, or with nothing
    /// selected, `id` is selected alone. With ⇧ the selection extends to it as
    /// a ⇧-click does (ShellIconClick.extend), from `anchor`, or from `lead`
    /// when the anchor is no longer selected.
    static func move(to id: String, from lead: String?, anchor: String?, selection: Set<String>,
                     extending: Bool, order: [String]) -> Move {
        guard extending, !selection.isEmpty else { return Move(selection: [id], lead: id, anchor: id) }
        let start = anchor.flatMap { selection.contains($0) ? $0 : nil } ?? lead ?? id
        let extended: Set<String>
        if case .select(let ids) = ShellIconClick.extend(selection, to: id, from: start, order: order) {
            extended = ids
        } else {
            extended = selection
        }
        return Move(selection: extended, lead: id, anchor: start)
    }

    /// The index of the item to select, in the sections' display order.
    static func destination(sectionCounts: [Int], columns: Int, leadIndex: Int?, direction: Direction) -> Int? {
        let counts = sectionCounts.map { max(0, $0) }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        guard let leadIndex, (0..<total).contains(leadIndex) else { return 0 }

        switch direction {
        case .right:
            return min(leadIndex + 1, total - 1)
        case .left:
            return max(leadIndex - 1, 0)
        case .down, .up:
            return verticalDestination(sectionCounts: counts, columns: max(1, columns),
                                       leadIndex: leadIndex, movingDown: direction == .down)
        }
    }

    /// How many columns a LazyVGrid with one `.adaptive(minimum:)` GridItem lays
    /// out in `width`: the most, `n`, whose columns are each at least `minimum`
    /// wide after the `n - 1` gaps. The division alone can come out one too
    /// many when the width is exactly at a column boundary and `minimum` isn't
    /// a whole number (a 630-pt grid at 119.6 has 4 columns, not 5).
    static func columnCount(width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard width > 0, minimum > 0 else { return 1 }
        var count = max(1, Int((width + spacing) / (minimum + spacing)))
        if count > 1, (width - CGFloat(count - 1) * spacing) / CGFloat(count) < minimum { count -= 1 }
        return count
    }

    private static func verticalDestination(sectionCounts: [Int], columns: Int, leadIndex: Int,
                                             movingDown: Bool) -> Int {
        var sectionStart = 0
        for (sectionIndex, count) in sectionCounts.enumerated() {
            guard leadIndex < sectionStart + count else {
                sectionStart += count
                continue
            }

            let localIndex = leadIndex - sectionStart
            let row = localIndex / columns
            let column = localIndex % columns
            let rowCount = (count + columns - 1) / columns
            let nextRow = row + (movingDown ? 1 : -1)

            if (0..<rowCount).contains(nextRow) {
                let rowStart = nextRow * columns
                return sectionStart + rowStart + min(column, count - rowStart - 1)
            }

            let step = movingDown ? 1 : -1
            var adjacent = sectionIndex + step
            while sectionCounts.indices.contains(adjacent) {
                let adjacentCount = sectionCounts[adjacent]
                if adjacentCount > 0 {
                    let adjacentRows = (adjacentCount + columns - 1) / columns
                    let targetRow = movingDown ? 0 : adjacentRows - 1
                    let rowStart = targetRow * columns
                    let precedingCount = sectionCounts[..<adjacent].reduce(0, +)
                    return precedingCount + rowStart + min(column, adjacentCount - rowStart - 1)
                }
                adjacent += step
            }
            return leadIndex
        }
        return leadIndex
    }
}
