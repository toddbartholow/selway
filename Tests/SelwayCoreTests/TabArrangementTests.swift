import Testing
@testable import SelwayCore

struct TabArrangementTests {
    @Test func tabToRightUsesImmediateNeighbor() {
        #expect(TabArrangement.tabToRightIndex(count: 3, current: 0) == 1)
        #expect(TabArrangement.tabToRightIndex(count: 3, current: 1) == 2)
        #expect(TabArrangement.tabToRightIndex(count: 3, current: 2) == nil)
        #expect(TabArrangement.tabToRightIndex(count: 0, current: 0) == nil)
        #expect(TabArrangement.tabToRightIndex(count: 2, current: 2) == nil)
    }

    @Test func commandAvailability() {
        #expect(TabArrangement.canMergeTab(isDual: false, hasTabToRight: true))
        #expect(!TabArrangement.canMergeTab(isDual: true, hasTabToRight: true))
        #expect(!TabArrangement.canMergeTab(isDual: false, hasTabToRight: false))
        #expect(TabArrangement.canMoveOtherPane(isDual: true))
        #expect(!TabArrangement.canMoveOtherPane(isDual: false))
    }
}
