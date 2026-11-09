import Foundation
import Testing
@testable import SelwayCore

@Suite struct PrefsBrowseSettingsTests {
    private typealias P = UserPreferences

    private func settings(_ seed: [String: Any]) -> BrowseSettings {
        let d = TestDefaults(); defer { d.cleanup() }
        for (k, v) in seed { d.defaults.set(v, forKey: k) }
        return BrowseSettings(d.defaults)
    }

    @Test func nothingStoredIsTheDefaults() {
        let s = settings([:])
        #expect(s.viewMode == P.defaultViewMode)
        #expect(s.sortField == P.defaultSortField)
        #expect(s.sortAscending == P.defaultSortAscending)
        #expect(s.groupBy == P.defaultGroupBy)
        #expect(s.folderOrder == P.defaultFolderOrder)
        #expect(s.showHidden == false)
        #expect(s.showPathBar == true)
    }

    @Test func storedValuesAreRead() {
        let s = settings([
            P.viewModeKey: ViewMode.columns.rawValue,
            P.sortFieldKey: SortField.size.rawValue,
            P.sortAscendingKey: true,
            P.groupByKey: GroupBy.kind.rawValue,
            P.folderOrderKey: FolderOrder.mixed.rawValue,
            P.showHiddenKey: true,
            P.showPathBarKey: false,
        ])
        #expect(s.viewMode == .columns)
        #expect(s.sortField == .size)
        #expect(s.sortAscending == true)
        #expect(s.groupBy == .kind)
        #expect(s.folderOrder == .mixed)
        #expect(s.showHidden == true)
        #expect(s.showPathBar == false)
    }

    /// As `@AppStorage` reads a Boolean: "NO" or 0 from the command line counts.
    @Test func falseStoredOverDefaultTrueIsFalse() {
        #expect(settings([P.showPathBarKey: "NO"]).showPathBar == false)
        #expect(settings([P.sortAscendingKey: 0]).sortAscending == false)
    }

    @Test func unreadableValuesAreTheDefaults() {
        let s = settings([
            P.viewModeKey: "Gallery",
            P.sortFieldKey: 3,
            P.groupByKey: "",
            P.folderOrderKey: "Folders Last",
        ])
        #expect(s.viewMode == P.defaultViewMode)
        #expect(s.sortField == P.defaultSortField)
        #expect(s.groupBy == P.defaultGroupBy)
        #expect(s.folderOrder == P.defaultFolderOrder)
    }

    @Test func aChangeIsSeenOnTheNextRead() {
        let d = TestDefaults(); defer { d.cleanup() }
        #expect(BrowseSettings(d.defaults).showHidden == false)
        d.defaults.set(true, forKey: P.showHiddenKey)
        #expect(BrowseSettings(d.defaults).showHidden == true)
    }
}
