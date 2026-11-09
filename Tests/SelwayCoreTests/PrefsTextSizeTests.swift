import Foundation
import Testing
@testable import SelwayCore

@Suite struct PrefsTextSizeTests {
    @Test func defaultIsActualSize() {
        #expect(TextSize.actual.percent == 100)
        #expect(TextSize.actual.scale == 1)
        #expect(TextSize.actual.isActual)
        #expect(UserPreferences.textSizeKey == "selwayTextSize")
    }

    @Test func stepsAreAscendingAndStartAtActualSize() {
        #expect(TextSize.steps == [100, 115, 130, 150, 175, 200])
        #expect(TextSize.all.map(\.percent) == TextSize.steps)
        #expect(TextSize.all == TextSize.all.sorted())
    }

    @Test(arguments: TextSize.steps)
    func validStepsAreKept(percent: Int) {
        #expect(TextSize(percent: percent).percent == percent)
    }

    @Test(arguments: [(0, 100), (-50, 100), (99, 100), (107, 100), (108, 115), (122, 115),
                      (123, 130), (140, 130), (141, 150), (163, 175), (176, 175), (187, 175),
                      (188, 200), (201, 200), (1000, 200), (Int.min, 100), (Int.max, 200)])
    func otherValuesSnapToTheNearestStep(raw: Int, expected: Int) {
        #expect(TextSize.fromStorage(raw).percent == expected)
    }

    @Test func biggerWalksUpToTheLargestStep() {
        var size = TextSize.actual
        var seen = [size.percent]
        while let next = size.bigger { size = next; seen.append(size.percent) }
        #expect(seen == TextSize.steps)
        #expect(!size.canGoBigger)
        #expect(size.canGoSmaller)
    }

    @Test func smallerWalksDownToActualSize() {
        var size = TextSize(percent: 200)
        var seen = [size.percent]
        while let next = size.smaller { size = next; seen.append(size.percent) }
        #expect(seen == TextSize.steps.reversed())
        #expect(size == .actual)
        #expect(!size.canGoSmaller)
        #expect(size.canGoBigger)
    }

    @Test func middleStepsGoBothWays() {
        let size = TextSize(percent: 130)
        #expect(size.bigger?.percent == 150)
        #expect(size.smaller?.percent == 115)
        #expect(size.scale == 1.3)
        #expect(size.label == "130%")
        #expect(!size.isActual)
    }
}

@Suite struct TextSizeRoutingTests {
    private func value(_ change: TextSizeChange, _ target: TextSizeTarget, _ stored: Int?) -> Int? {
        TextSizeRouting.newValue(change, for: target, stored: stored)
    }

    @Test func eachTargetHasItsOwnKey() {
        #expect(TextSizeTarget.browser.key == "selwayTextSize")
        #expect(TextSizeTarget.markdown.key == "selwayMarkdownTextSize")
        #expect(TextSizeTarget.codeEditor.key == "selwayEditorFontSize")
        #expect(TextSizeTarget.none.key == nil)
    }

    @Test(arguments: [TextSizeTarget.browser, .markdown])
    func percentagesStepThroughTheSizes(target: TextSizeTarget) {
        #expect(value(.bigger, target, nil) == 115)
        #expect(value(.bigger, target, 100) == 115)
        #expect(value(.bigger, target, 175) == 200)
        #expect(value(.bigger, target, 200) == nil)
        #expect(value(.smaller, target, 200) == 175)
        #expect(value(.smaller, target, 115) == 100)
        #expect(value(.smaller, target, 100) == nil)
        #expect(value(.smaller, target, nil) == nil)
    }

    @Test(arguments: [TextSizeTarget.browser, .markdown])
    func badStoredPercentagesStepFromTheirSnappedSize(target: TextSizeTarget) {
        #expect(value(.bigger, target, 140) == 150)    // 140 reads as 130
        #expect(value(.smaller, target, 140) == 115)
        #expect(value(.bigger, target, 900) == nil)    // reads as 200
        #expect(value(.smaller, target, -5) == nil)    // reads as 100
        #expect(value(.actual, target, 90) == nil)     // already reads as 100%
    }

    @Test(arguments: [TextSizeTarget.browser, .markdown])
    func actualSizeForPercentages(target: TextSizeTarget) {
        #expect(value(.actual, target, 150) == 100)
        #expect(value(.actual, target, 200) == 100)
        #expect(value(.actual, target, 100) == nil)
        #expect(value(.actual, target, nil) == nil)
    }

    @Test func editorStepsOnePointWithinItsRange() {
        #expect(value(.bigger, .codeEditor, nil) == 15)
        #expect(value(.bigger, .codeEditor, 14) == 15)
        #expect(value(.smaller, .codeEditor, 14) == 13)
        #expect(value(.bigger, .codeEditor, 35) == 36)
        #expect(value(.bigger, .codeEditor, 36) == nil)
        #expect(value(.smaller, .codeEditor, 9) == 8)
        #expect(value(.smaller, .codeEditor, 8) == nil)
    }

    @Test func outOfRangeEditorSizesStepFromTheNearestEnd() {
        // Bigger never shrinks a too-big value, nor Smaller grow a too-small one.
        #expect(value(.bigger, .codeEditor, 60) == nil)
        #expect(value(.smaller, .codeEditor, 60) == 35)
        #expect(value(.smaller, .codeEditor, 2) == nil)
        #expect(value(.bigger, .codeEditor, 2) == 9)
        #expect(value(.bigger, .codeEditor, Int.max) == nil)
        #expect(value(.smaller, .codeEditor, Int.min) == nil)
        #expect(EditorFontSize.clamped(60) == 36)
        #expect(EditorFontSize.clamped(2) == 8)
    }

    @Test func actualSizeForTheEditor() {
        #expect(value(.actual, .codeEditor, 20) == 14)
        #expect(value(.actual, .codeEditor, 60) == 14)
        #expect(value(.actual, .codeEditor, 14) == nil)
        #expect(value(.actual, .codeEditor, nil) == nil)
    }

    @Test(arguments: [TextSizeChange.bigger, .smaller, .actual])
    func nothingChangesWithoutATarget(change: TextSizeChange) {
        #expect(value(change, .none, 150) == nil)
        #expect(value(change, .none, nil) == nil)
    }

    @Test func announcementsNameTheSetting() {
        #expect(TextSizeRouting.announcement(for: .browser, value: 150) == "Text size 150%")
        #expect(TextSizeRouting.announcement(for: .markdown, value: 130) == "Markdown text size 130%")
        #expect(TextSizeRouting.announcement(for: .codeEditor, value: 15) == "Editor font size 15 points")
    }
}
