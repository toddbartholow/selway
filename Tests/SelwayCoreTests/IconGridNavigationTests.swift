import Foundation
import Testing
@testable import SelwayCore

@Suite struct IconGridNavigationTests {
    @Test func horizontalMovesAcrossRowsAndSectionsAndStopsAtEnds() {
        let sections = [3, 2]
        #expect(IconGridNavigation.destination(sectionCounts: sections, columns: 3, leadIndex: 1, direction: .right) == 2)
        #expect(IconGridNavigation.destination(sectionCounts: sections, columns: 3, leadIndex: 2, direction: .right) == 3)
        #expect(IconGridNavigation.destination(sectionCounts: sections, columns: 3, leadIndex: 3, direction: .left) == 2)
        #expect(IconGridNavigation.destination(sectionCounts: sections, columns: 3, leadIndex: 0, direction: .left) == 0)
        #expect(IconGridNavigation.destination(sectionCounts: sections, columns: 3, leadIndex: 4, direction: .right) == 4)
    }

    @Test func verticalMovesWithinASectionAndAcrossSectionBoundaries() {
        let sections = [7, 5]
        #expect(IconGridNavigation.destination(sectionCounts: sections, columns: 3, leadIndex: 1, direction: .down) == 4)
        #expect(IconGridNavigation.destination(sectionCounts: sections, columns: 3, leadIndex: 4, direction: .up) == 1)
        #expect(IconGridNavigation.destination(sectionCounts: sections, columns: 3, leadIndex: 6, direction: .down) == 7)
        #expect(IconGridNavigation.destination(sectionCounts: sections, columns: 3, leadIndex: 7, direction: .up) == 6)
        #expect(IconGridNavigation.destination(sectionCounts: sections, columns: 3, leadIndex: 0, direction: .up) == 0)
        #expect(IconGridNavigation.destination(sectionCounts: sections, columns: 3, leadIndex: 11, direction: .down) == 11)
    }

    @Test func shortLastRowClampsTheColumn() {
        #expect(IconGridNavigation.destination(sectionCounts: [8], columns: 3, leadIndex: 5, direction: .down) == 7)
        #expect(IconGridNavigation.destination(sectionCounts: [8], columns: 3, leadIndex: 7, direction: .up) == 4)
    }

    @Test func singleColumnAndSingleItemGridsStayInBounds() {
        #expect(IconGridNavigation.destination(sectionCounts: [2, 1], columns: 1, leadIndex: 0, direction: .down) == 1)
        #expect(IconGridNavigation.destination(sectionCounts: [2, 1], columns: 1, leadIndex: 1, direction: .down) == 2)
        #expect(IconGridNavigation.destination(sectionCounts: [1], columns: 1, leadIndex: 0, direction: .up) == 0)
        #expect(IconGridNavigation.destination(sectionCounts: [1], columns: 1, leadIndex: nil, direction: .left) == 0)
    }

    @Test func emptyGridHasNoDestination() {
        #expect(IconGridNavigation.destination(sectionCounts: [], columns: 4, leadIndex: nil, direction: .right) == nil)
        #expect(IconGridNavigation.destination(sectionCounts: [0, 0], columns: 4, leadIndex: 0, direction: .down) == nil)
    }

    @Test func adaptiveColumnCountAccountsForSpacing() {
        #expect(IconGridNavigation.columnCount(width: 100, minimum: 100, spacing: 8) == 1)
        #expect(IconGridNavigation.columnCount(width: 207, minimum: 100, spacing: 8) == 1)
        #expect(IconGridNavigation.columnCount(width: 216, minimum: 100, spacing: 8) == 2)
        #expect(IconGridNavigation.columnCount(width: 324, minimum: 100, spacing: 8) == 3)
        #expect(IconGridNavigation.columnCount(width: 500, minimum: 100, spacing: 8) == 4)
    }

    @Test func columnCountAtAnExactColumnBoundary() {
        // 4 columns of 119.6 and 3 gaps of 8 need 502.4 pt; 5 would need 630.0000000000001.
        #expect(IconGridNavigation.columnCount(width: 630, minimum: (72 + 20) * 1.3, spacing: 8) == 4)
        #expect(IconGridNavigation.columnCount(width: 630, minimum: 119.6, spacing: 8) == 5)
    }

    @Test func crossingIntoAShorterSectionClampsTheColumn() {
        #expect(IconGridNavigation.destination(sectionCounts: [3, 1], columns: 3, leadIndex: 2, direction: .down) == 3)
        #expect(IconGridNavigation.destination(sectionCounts: [7, 5], columns: 3, leadIndex: 8, direction: .up) == 6)
    }

    @Test func emptySectionsAreSkipped() {
        #expect(IconGridNavigation.destination(sectionCounts: [3, 0, 2], columns: 3, leadIndex: 1, direction: .down) == 4)
        #expect(IconGridNavigation.destination(sectionCounts: [3, 0, 2], columns: 3, leadIndex: 4, direction: .up) == 1)
    }

    @Test func noLeadOrALeadOutsideTheGridStartsAtTheFirstItem() {
        for direction in [IconGridNavigation.Direction.right, .left, .down, .up] {
            #expect(IconGridNavigation.destination(sectionCounts: [4], columns: 2, leadIndex: nil, direction: direction) == 0)
            #expect(IconGridNavigation.destination(sectionCounts: [4], columns: 2, leadIndex: 99, direction: direction) == 0)
        }
    }

    // MARK: Lead and anchor

    private let order = ["a", "b", "c", "d", "e"]

    @Test func theLeadIsTheLastIconMovedToWhileItIsSelected() {
        #expect(IconGridNavigation.lead("c", selection: ["a", "b", "c"], order: order) == "c")
    }

    @Test func aDeselectedLeadFallsBackToTheFirstSelectedIcon() {
        #expect(IconGridNavigation.lead("a", selection: ["d", "c"], order: order) == "c")
        #expect(IconGridNavigation.lead(nil, selection: ["e", "b"], order: order) == "b")
        #expect(IconGridNavigation.lead("a", selection: [], order: order) == nil)
    }

    @Test func aPlainMoveSelectsOnlyTheNewIcon() {
        let move = IconGridNavigation.move(to: "d", from: "c", anchor: "a", selection: ["a", "b", "c"],
                                           extending: false, order: order)
        #expect(move == .init(selection: ["d"], lead: "d", anchor: "d"))
    }

    @Test func shiftWithNothingSelectedSelectsTheIconAlone() {
        let move = IconGridNavigation.move(to: "a", from: nil, anchor: "c", selection: [],
                                           extending: true, order: order)
        #expect(move == .init(selection: ["a"], lead: "a", anchor: "a"))
    }

    @Test func shiftExtendsFromTheAnchor() {
        let move = IconGridNavigation.move(to: "d", from: "c", anchor: "b", selection: ["b", "c"],
                                           extending: true, order: order)
        #expect(move == .init(selection: ["b", "c", "d"], lead: "d", anchor: "b"))
    }

    @Test func shiftExtendsFromTheLeadWhenTheAnchorIsNoLongerSelected() {
        // ⌘-clicks left only "c" selected; the anchor "a" was deselected.
        let move = IconGridNavigation.move(to: "d", from: "c", anchor: "a", selection: ["c"],
                                           extending: true, order: order)
        #expect(move == .init(selection: ["c", "d"], lead: "d", anchor: "c"))
    }
}
