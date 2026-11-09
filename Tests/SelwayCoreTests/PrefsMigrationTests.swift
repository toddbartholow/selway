import Foundation
import Testing
@testable import SelwayCore

@Suite struct PrefsMigrationTests {
    private typealias P = UserPreferences

    private func migrate(_ seed: [String: Any]) -> [String: Any] {
        let d = TestDefaults(); defer { d.cleanup() }
        for (k, v) in seed { d.defaults.set(v, forKey: k) }
        P.migrateBrowseDefaultsIfNeeded(d.defaults)
        return [P.sortFieldKey, P.sortAscendingKey, P.groupByKey, P.viewModeKey, P.folderOrderKey,
                P.defaultsMigratedKey]
            .reduce(into: [:]) { out, k in out[k] = d.defaults.object(forKey: k) }
    }

    private func isMigrated(_ prefs: [String: Any]) -> Bool {
        prefs[P.sortFieldKey] as? String == SortField.dateModified.rawValue
            && prefs[P.sortAscendingKey] as? Bool == false
            && prefs[P.groupByKey] as? String == GroupBy.dateModified.rawValue
    }

    @Test func freshInstallGetsFactoryDefaults() {
        let p = migrate([:])
        #expect(isMigrated(p))
        #expect(p[P.viewModeKey] as? String == ViewMode.list.rawValue)
        #expect(p[P.folderOrderKey] as? String == FolderOrder.foldersFirst.rawValue)
        #expect(p[P.defaultsMigratedKey] as? Bool == true)
    }

    @Test(arguments: [GroupBy.none.rawValue, GroupBy.dateModified.rawValue, nil])
    func nameAscendingWithDefaultLookingGroupIsMigrated(group: String?) {
        var seed: [String: Any] = [P.sortFieldKey: "Name", P.sortAscendingKey: true]
        if let group { seed[P.groupByKey] = group }
        #expect(isMigrated(migrate(seed)))
    }

    @Test func missingAscendingKeyCountsAsAscending() {
        #expect(isMigrated(migrate([P.sortFieldKey: "Name", P.groupByKey: "None"])))
    }

    @Test func nameDescendingIsUntouched() {
        let p = migrate([P.sortFieldKey: "Name", P.sortAscendingKey: false, P.groupByKey: "None"])
        #expect(p[P.sortFieldKey] as? String == "Name")
        #expect(p[P.sortAscendingKey] as? Bool == false)
        #expect(p[P.groupByKey] as? String == "None")
        #expect(p[P.defaultsMigratedKey] as? Bool == true)
    }

    @Test(arguments: [GroupBy.kind, .extension_, .size, .nameInitial, .dateCreated])
    func deliberateGroupingIsUntouched(group: GroupBy) {
        let p = migrate([P.sortFieldKey: "Name", P.sortAscendingKey: true, P.groupByKey: group.rawValue])
        #expect(p[P.sortFieldKey] as? String == "Name")
        #expect(p[P.groupByKey] as? String == group.rawValue)
    }

    @Test func deliberateGroupingWithNoSavedSortIsUntouched() {
        let p = migrate([P.groupByKey: GroupBy.kind.rawValue])
        #expect(p[P.groupByKey] as? String == GroupBy.kind.rawValue)
        #expect(p[P.sortFieldKey] == nil)
    }

    @Test(arguments: [SortField.size, .kind, .ext, .dateCreated])
    func otherSortsAreUntouched(sort: SortField) {
        let p = migrate([P.sortFieldKey: sort.rawValue, P.sortAscendingKey: true, P.groupByKey: "None"])
        #expect(p[P.sortFieldKey] as? String == sort.rawValue)
        #expect(p[P.sortAscendingKey] as? Bool == true)
        #expect(p[P.groupByKey] as? String == "None")
    }

    @Test func garbageSortIsLeftAloneAndFallsBackWhenRead() {
        let p = migrate([P.sortFieldKey: "Bogus", P.groupByKey: "Nope", P.viewModeKey: "???"])
        #expect(p[P.sortFieldKey] as? String == "Bogus")
        #expect(SortField.fromStorage("Bogus") == P.defaultSortField)
        #expect(GroupBy.fromStorage("Nope") == P.defaultGroupBy)
        #expect(ViewMode.fromStorage("???") == P.defaultViewMode)
        #expect(FolderOrder.fromStorage("") == P.defaultFolderOrder)
        #expect(SortField.fromStorage("Size") == .size)
    }

    @Test func existingViewModeAndFolderOrderArePreserved() {
        let p = migrate([P.sortFieldKey: "Name", P.sortAscendingKey: true,
                         P.viewModeKey: ViewMode.columns.rawValue,
                         P.folderOrderKey: FolderOrder.mixed.rawValue])
        #expect(isMigrated(p))
        #expect(p[P.viewModeKey] as? String == ViewMode.columns.rawValue)
        #expect(p[P.folderOrderKey] as? String == FolderOrder.mixed.rawValue)
    }

    @Test func secondRunIsANoOp() {
        let d = TestDefaults(); defer { d.cleanup() }
        P.migrateBrowseDefaultsIfNeeded(d.defaults)
        // User then picks Name A→Z flat on purpose; a later launch must not undo it.
        d.defaults.set("Name", forKey: P.sortFieldKey)
        d.defaults.set(true, forKey: P.sortAscendingKey)
        d.defaults.set("None", forKey: P.groupByKey)
        P.migrateBrowseDefaultsIfNeeded(d.defaults)
        #expect(d.defaults.string(forKey: P.sortFieldKey) == "Name")
        #expect(d.defaults.string(forKey: P.groupByKey) == "None")
    }

    @Test func userWithOld15FlagStillGets151Pass() {
        let p = migrate([P.legacyMigrated15Key: true, P.sortFieldKey: "Name",
                         P.sortAscendingKey: true, P.groupByKey: "None"])
        #expect(isMigrated(p))
        #expect(P.legacyMigrated15Key != P.defaultsMigratedKey)
    }

    @Test func doesNotTouchStandardDefaults() {
        let before = UserDefaults.standard.object(forKey: P.defaultsMigratedKey) as? Bool
        _ = migrate([:])
        #expect(UserDefaults.standard.object(forKey: P.defaultsMigratedKey) as? Bool == before)
    }

    @Test func factoryResetWritesEveryBrowseKey() {
        let d = TestDefaults(); defer { d.cleanup() }
        d.defaults.set("Size", forKey: P.sortFieldKey)
        d.defaults.set(ViewMode.icons.rawValue, forKey: P.viewModeKey)
        P.applyFactoryBrowseDefaults(d.defaults)
        #expect(d.defaults.string(forKey: P.viewModeKey) == P.defaultViewMode.rawValue)
        #expect(d.defaults.string(forKey: P.sortFieldKey) == P.defaultSortField.rawValue)
        #expect(d.defaults.bool(forKey: P.sortAscendingKey) == P.defaultSortAscending)
        #expect(d.defaults.string(forKey: P.groupByKey) == P.defaultGroupBy.rawValue)
        #expect(d.defaults.string(forKey: P.folderOrderKey) == P.defaultFolderOrder.rawValue)
    }
}
