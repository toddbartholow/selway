import Foundation

enum TabArrangement {
    /// The tab directly after `current` in the window's tab order.
    static func tabToRightIndex(count: Int, current: Int) -> Int? {
        guard count > 0, (0..<count).contains(current), current + 1 < count else { return nil }
        return current + 1
    }

    static func canMergeTab(isDual: Bool, hasTabToRight: Bool) -> Bool {
        !isDual && hasTabToRight
    }

    static func canMoveOtherPane(isDual: Bool) -> Bool { isDual }
}
