import Testing
@testable import SelwayCore

@Suite struct SettingsWindowHeightTests {
    @Test func hasNoLimitWithoutACapOrAScreen() {
        #expect(SettingsWindowHeight.limit(visibleScreenHeight: nil) == nil)
    }

    @Test func limitsHeightToTheVisibleAreaOnTheSettingsScreen() {
        #expect(SettingsWindowHeight.limit(visibleScreenHeight: 680) == 580)
    }

    @Test func respectsMinimumHeightOnAShortScreen() {
        #expect(SettingsWindowHeight.limit(visibleScreenHeight: 450) == 400)
    }

    @Test func usesTheTabsCapWhenTheScreenHasRoom() {
        #expect(SettingsWindowHeight.limit(upTo: 640, visibleScreenHeight: 1320) == 640)
    }

    @Test func usesTheTabsCapWhenTheScreenIsUnknown() {
        #expect(SettingsWindowHeight.limit(upTo: 640, visibleScreenHeight: nil) == 640)
    }

    @Test func aShortScreenWinsOverTheTabsCap() {
        #expect(SettingsWindowHeight.limit(upTo: 640, visibleScreenHeight: 600) == 500)
    }
}
