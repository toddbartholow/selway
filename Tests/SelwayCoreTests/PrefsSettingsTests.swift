import Foundation
import Testing
@testable import SelwayCore

// The tabbed Settings window's values: defaults, validation of stored values,
// the sidebar's choices, and Reset All Settings.

@Suite struct PrefsSettingsTests {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    // MARK: New windows open

    @Test func newWindowFolderDefaultsToHomeAndIgnoresJunk() {
        #expect(NewWindowFolder.fromStorage(nil) == .home)
        #expect(NewWindowFolder.fromStorage("Desktop") == .home)   // raw values are lowercase
        #expect(NewWindowFolder.fromStorage("downloads") == .downloads)
    }

    @Test func newWindowFolderResolvesEachChoice() {
        let folders: Set<String> = ["/Users/someone/Desktop", "/Users/someone/Documents",
                                    "/Users/someone/Downloads", "/Volumes/Work/Projects", "/tmp/last"]
        func resolve(_ choice: NewWindowFolder, custom: String? = nil, recent: [String] = []) -> String {
            NewWindowFolder.resolve(choice, customPath: custom, recentPaths: recent, home: home,
                                    isFolder: folders.contains).path
        }
        #expect(resolve(.home) == home.path)
        #expect(resolve(.desktop) == "/Users/someone/Desktop")
        #expect(resolve(.documents) == "/Users/someone/Documents")
        #expect(resolve(.downloads) == "/Users/someone/Downloads")
        #expect(resolve(.custom, custom: "/Volumes/Work/Projects") == "/Volumes/Work/Projects")
        // The newest Recent folder that still exists.
        #expect(resolve(.last, recent: ["/gone", "", "/tmp/last", "/Users/someone/Desktop"]) == "/tmp/last")
    }

    @Test func newWindowLastFolderSkipsGuardRefusedRecentPaths() {
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        var lookedUp: [String] = []
        let result = NewWindowFolder.resolve(.last, customPath: nil,
                                             recentPaths: ["/net/server/share", "/Users/me/Docs"],
                                             home: home, isFolder: { path in lookedUp.append(path); return true },
                                             isUnchecked: { $0.hasPrefix("/net/") })
        #expect(result.path == "/Users/me/Docs")
        #expect(lookedUp == ["/Users/me/Docs", "/Users/me/Docs"])
    }

    @Test func newWindowFolderFallsBackToHomeWhenTheFolderIsMissing() {
        func resolve(_ choice: NewWindowFolder, custom: String? = nil, recent: [String] = []) -> URL {
            NewWindowFolder.resolve(choice, customPath: custom, recentPaths: recent, home: home, isFolder: { _ in false })
        }
        #expect(resolve(.desktop) == home)
        #expect(resolve(.custom, custom: "/Volumes/Unplugged/Work") == home)
        #expect(resolve(.custom, custom: "") == home)
        #expect(resolve(.custom) == home)
        #expect(resolve(.last) == home)
        #expect(resolve(.last, recent: ["/gone"]) == home)
    }

    @Test func customNewWindowFolderIsCheckedBeforeItIsLookedUp() {
        var lookedUp: [String] = []
        let refused = NewWindowFolder.resolve(.custom, customPath: "/refused/export", recentPaths: [],
                                              home: home, isFolder: { lookedUp.append($0); return true },
                                              isUnchecked: { $0 == "/refused/export" })
        #expect(refused == home)
        #expect(lookedUp.isEmpty)

        let safe = NewWindowFolder.resolve(.custom, customPath: "/safe/Work", recentPaths: [],
                                           home: home, isFolder: { $0 == "/safe/Work" },
                                           isUnchecked: { _ in false })
        #expect(safe.path == "/safe/Work")

        let missing = NewWindowFolder.resolve(.custom, customPath: "/safe/Gone", recentPaths: [],
                                              home: home, isFolder: { _ in false },
                                              isUnchecked: { _ in false })
        #expect(missing == home)
    }

    @Test func newWindowFolderReadsTheStoredChoice() {
        let d = TestDefaults(); defer { d.cleanup() }
        d.defaults.set("last", forKey: NewWindowFolder.key)
        d.defaults.set(["/tmp/a", "/tmp/b"], forKey: RecentFolders.defaultsKey)
        let url = NewWindowFolder.resolve(d.defaults, home: home, isFolder: { $0 == "/tmp/b" })
        #expect(url.path == "/tmp/b")
    }

    @Test func folderOpenTargetDefaultsToTheSameWindow() {
        #expect(FolderOpenTarget.fromStorage(nil) == .sameWindow)
        #expect(FolderOpenTarget.fromStorage("tab") == .sameWindow)
        #expect(FolderOpenTarget.fromStorage("newWindow") == .newWindow)
        #expect(FolderOpenTarget.fromStorage("newTab") == .newTab)
    }

    /// Stored as identifiers like its siblings, so the setting survives a
    /// change of the titles shown (or their translation).
    @Test func folderOpenTargetStoresIdentifiers() {
        #expect(FolderOpenTarget.allCases.map(\.rawValue) == ["sameWindow", "newWindow", "newTab"])
        for target in FolderOpenTarget.allCases {
            #expect(FolderOpenTarget.fromStorage(target.rawValue) == target)
        }
        #expect(FolderOpenTarget.newTab.title == "A new tab")
    }

    @Test func folderOpenTargetSendsFoldersWhereItSays() {
        #expect(FolderOpenTarget.sameWindow.destination == .here)
        #expect(FolderOpenTarget.newWindow.destination == .newWindows)
        #expect(FolderOpenTarget.newTab.destination == .newTabs)
    }

    @Test func searchScopesKeepStoredValuesAndEnglishDisplayNames() {
        let expected = ["This Folder", "This Folder & Subfolders", "Desktop", "Documents", "Downloads", "Home Folder", "Entire Mac"]
        #expect(SearchScope.allCases.map(\.rawValue) == expected)
        #expect(SearchScope.allCases.map(\.displayName) == expected)
    }

    @Test func defaultSearchScopeIsThisFolderUnlessEntireMac() {
        let d = TestDefaults(); defer { d.cleanup() }
        #expect(SearchScope.defaultScope(d.defaults) == .thisFolder)
        d.defaults.set(SearchScope.entireMac.rawValue, forKey: SettingsKeys.defaultSearchScope)
        #expect(SearchScope.defaultScope(d.defaults) == .entireMac)
        // Only the two offered choices count; anything else is This Folder.
        d.defaults.set(SearchScope.downloads.rawValue, forKey: SettingsKeys.defaultSearchScope)
        #expect(SearchScope.defaultScope(d.defaults) == .thisFolder)
        d.defaults.set("Everywhere", forKey: SettingsKeys.defaultSearchScope)
        #expect(SearchScope.defaultScope(d.defaults) == .thisFolder)
    }

    // MARK: Sidebar

    @Test func sidebarFavoritesDefaultToTheFourShownBefore() {
        #expect(SidebarPrefs.favorites(fromStorage: nil) == [.home, .desktop, .documents, .downloads])
        #expect(SidebarPrefs.defaultFavoritesStorage == "home,desktop,documents,downloads")
        // An empty value is a deliberate "none", not the defaults.
        #expect(SidebarPrefs.favorites(fromStorage: "").isEmpty)
    }

    @Test func sidebarFavoritesKeepTheirOrderAndDropUnknownNames() {
        let items = SidebarPrefs.favorites(fromStorage: "music, home,bogus,,home,iCloudDrive")
        #expect(items == [.home, .music, .iCloudDrive])
        #expect(SidebarPrefs.storage(for: items) == "home,music,iCloudDrive")
    }

    @Test func sidebarFavoriteToggles() {
        var raw: String? = nil
        raw = SidebarPrefs.setting(.desktop, shown: false, in: raw)
        #expect(raw == "home,documents,downloads")
        raw = SidebarPrefs.setting(.applications, shown: true, in: raw)
        #expect(raw == "home,documents,downloads,applications")
        raw = SidebarPrefs.setting(.applications, shown: true, in: raw)   // already on: unchanged
        #expect(raw == "home,documents,downloads,applications")
    }

    @Test func sidebarFavoriteURLs() {
        let raw = "home,applications,pictures,iCloudDrive"
        let withoutICloud = SidebarPrefs.favoriteURLs(fromStorage: raw, home: home, isFolder: { _ in false })
        #expect(withoutICloud.map(\.path) == ["/Users/someone", "/Applications", "/Users/someone/Pictures"])
        let withICloud = SidebarPrefs.favoriteURLs(fromStorage: raw, home: home, isFolder: { _ in true })
        #expect(withICloud.last?.path == "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs")
        #expect(SidebarFavoriteItem.specialName(for: withICloud[3], home: home) == "iCloud Drive")
        #expect(SidebarFavoriteItem.specialName(for: withICloud[0], home: home) == nil)
    }

    @Test func recentCountIsClamped() {
        #expect(SidebarPrefs.recentCount(nil) == 8)
        #expect(SidebarPrefs.recentCount(0) == 8)       // missing as an Int reads as 0
        #expect(SidebarPrefs.recentCount(-3) == 1)
        #expect(SidebarPrefs.recentCount(5) == 5)
        #expect(SidebarPrefs.recentCount(99) == 20)
    }

    @Test func hiddenTagsIgnoreCaseAndDuplicates() {
        var raw = ""
        raw = SidebarPrefs.setting(tag: "Work", hidden: true, in: raw)
        raw = SidebarPrefs.setting(tag: "work", hidden: true, in: raw)
        raw = SidebarPrefs.setting(tag: "Red", hidden: true, in: raw)
        #expect(SidebarPrefs.hiddenTags(fromStorage: raw) == ["work", "Red"])
        #expect(SidebarPrefs.isHidden("RED", in: raw))
        raw = SidebarPrefs.setting(tag: "WORK", hidden: false, in: raw)
        #expect(SidebarPrefs.hiddenTags(fromStorage: raw) == ["Red"])
        #expect(SidebarPrefs.hiddenTags(fromStorage: "\n\nA\n\na\nB") == ["A", "B"])
    }

    // MARK: Sidebar tags

    private func names(_ rows: [SidebarTag]) -> [String] { rows.map(\.name) }
    private let standard = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]

    /// Finder lists the colour tags whether or not the folder uses them.
    @Test func sidebarAlwaysListsTheColourTagsInFindersOrder() {
        let rows = SidebarPrefs.tagRows(names: .english, known: [], inFolder: [], hiddenStorage: "")
        #expect(names(rows) == standard)
        #expect(rows.map(\.color) == [6, 7, 5, 2, 4, 3, 1])
        #expect(rows.allSatisfy { $0.isStandard })
    }

    @Test func sidebarUsesTheUsersNamesForColourTags() {
        let renamed = TagColorNames(fileLabels: ["None", "Gray", "Green", "Purple", "Blue", "Yellow", "Urgent", "Orange"])
        // Files tagged before the rename still say "Red": that's the same tag.
        let rows = SidebarPrefs.tagRows(names: renamed, known: [FileTag(name: "Red", color: 6)],
                                        inFolder: [FileTag(name: "urgent", color: 6)], hiddenStorage: "")
        #expect(names(rows) == ["Urgent", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
    }

    /// Custom tags follow alphabetically, once each, with their colours; the
    /// folder's own tags show before the Mac-wide scan has found them.
    @Test func sidebarListsCustomTagsAfterTheColours() {
        let known = [FileTag(name: "Work", color: 0), FileTag(name: "home", color: 4), FileTag(name: "Project", color: 2)]
        let folder = [FileTag(name: "work", color: 3), FileTag(name: "Archive", color: 0), FileTag(name: "Blue", color: 4)]
        let rows = SidebarPrefs.tagRows(names: .english, known: known, inFolder: folder, hiddenStorage: "")
        let custom = Array(rows.dropFirst(standard.count))
        #expect(names(custom) == ["Archive", "home", "Project", "work"])
        #expect(custom.map(\.color) == [0, 4, 2, 3])
        #expect(!custom.contains { $0.isStandard })
        // Natural order, without regard to case.
        let numbered = SidebarPrefs.tagRows(names: .english, known: [],
                                            inFolder: [FileTag(name: "Tag 10", color: 0), FileTag(name: "tag 9", color: 0)],
                                            hiddenStorage: "")
        #expect(names(Array(numbered.dropFirst(standard.count))) == ["tag 9", "Tag 10"])
    }

    @Test func sidebarLeavesOutHiddenTags() {
        var raw = SidebarPrefs.setting(tag: "red", hidden: true, in: "")
        raw = SidebarPrefs.setting(tag: "WORK", hidden: true, in: raw)
        let rows = SidebarPrefs.tagRows(names: .english, known: [FileTag(name: "Work", color: 0)],
                                        inFolder: [FileTag(name: "Home", color: 0)], hiddenStorage: raw)
        #expect(names(rows) == ["Orange", "Yellow", "Green", "Blue", "Purple", "Gray", "Home"])
    }

    @Test func knownTagsRoundTripThroughStorage() {
        let tags = [FileTag(name: "Project", color: 2), FileTag(name: "Work", color: 0)]
        let stored = SidebarPrefs.storage(knownTags: tags)
        #expect(stored == ["Project\n2", "Work"])
        #expect(SidebarPrefs.knownTags(fromStorage: stored + ["", "project\n5"]) == tags)
    }

    // MARK: Spoken shortcuts

    @Test func shortcutsAreSpelledOutForVoiceOver() {
        #expect(KeyNames.spoken("⌥⌘⌫ deletes permanently.") == "Option-Command-Delete deletes permanently.")
        #expect(KeyNames.spoken("Edit → Undo (⌘Z) puts items back") == "Edit, Undo (Command-Z) puts items back")
        #expect(KeyNames.spoken("Bigger (⌘+), Smaller (⌘−) and Actual (⌘0)")
                == "Bigger (Command-Plus), Smaller (Command-Minus) and Actual (Command-0)")
        #expect(KeyNames.spoken("Hidden files (⇧⌘.)") == "Hidden files (Shift-Command-Period)")
        #expect(KeyNames.spoken("No shortcut here.") == "No shortcut here.")
    }

    // MARK: Reset all settings

    @Test func resetRemovesSettingsAndKeepsDataAndFlags() {
        let keys = SettingsReset.keysToRemove(from: [
            "selwayViewMode", "selwayTextSize", "selwayEditorFontSize", "selwayTerminalApp",
            "selwaySidebarFavorites", "selwayShowTool.vscode",
            UserPreferences.defaultsMigratedKey, UserPreferences.legacyMigrated15Key,
            UserPreferences.didShowFirstRunKey, "selwayAppDetectionCache.v2",
            "recentFolders", "pinnedFolders", "launchAtLogin", "NSWindow Frame main", "SUEnableAutomaticChecks",
        ])
        #expect(keys == ["selwayEditorFontSize", "selwayShowTool.vscode", "selwaySidebarFavorites",
                         "selwayTerminalApp", "selwayTextSize", "selwayViewMode"])
    }

    @Test func resetAllWritesTheBrowseDefaultsBack() {
        let d = TestDefaults(); defer { d.cleanup() }
        d.defaults.set("icons", forKey: UserPreferences.viewModeKey)
        d.defaults.set("Size", forKey: UserPreferences.sortFieldKey)
        d.defaults.set(150, forKey: UserPreferences.textSizeKey)
        d.defaults.set(false, forKey: FileOpsDeletePrefs.confirmPermanentDeleteKey)
        d.defaults.set(true, forKey: UserPreferences.defaultsMigratedKey)
        d.defaults.set(["/tmp/x"], forKey: RecentFolders.defaultsKey)

        let removed = SettingsReset.resetAll(d.defaults, domain: d.suite)
        #expect(removed.contains(UserPreferences.textSizeKey))
        #expect(d.defaults.object(forKey: UserPreferences.textSizeKey) == nil)
        #expect(d.defaults.object(forKey: FileOpsDeletePrefs.confirmPermanentDeleteKey) == nil)
        #expect(FileOpsDeletePrefs(d.defaults).confirmPermanentDelete)
        #expect(d.defaults.string(forKey: UserPreferences.viewModeKey) == UserPreferences.defaultViewMode.rawValue)
        #expect(d.defaults.string(forKey: UserPreferences.sortFieldKey) == UserPreferences.defaultSortField.rawValue)
        #expect(d.defaults.bool(forKey: UserPreferences.defaultsMigratedKey))
        #expect(d.defaults.stringArray(forKey: RecentFolders.defaultsKey) == ["/tmp/x"])
    }
}

// The icon view's size slider, kept between launches (it reset to 64 whenever
// the icon view was rebuilt).
@Suite struct PrefsIconSizeTests {
    @Test func storedSizesInRangeAreKept() {
        #expect(UserPreferences.iconSize(fromStorage: 32) == 32)
        #expect(UserPreferences.iconSize(fromStorage: 96) == 96)
        #expect(UserPreferences.iconSize(fromStorage: 128) == 128)
    }

    @Test func storedSizesOutsideTheSliderClampToItsEnds() {
        #expect(UserPreferences.iconSize(fromStorage: 0) == 32)
        #expect(UserPreferences.iconSize(fromStorage: -40) == 32)
        #expect(UserPreferences.iconSize(fromStorage: 4000) == 128)
    }

    @Test func storedSizesSnapToTheSlidersSteps() {
        #expect(UserPreferences.iconSize(fromStorage: 50) == 48)
        #expect(UserPreferences.iconSize(fromStorage: 61) == 64)
    }

    @Test func unreadableSizesGiveTheDefault() {
        #expect(UserPreferences.iconSize(fromStorage: .nan) == UserPreferences.defaultIconSize)
        #expect(UserPreferences.iconSize(fromStorage: .infinity) == UserPreferences.defaultIconSize)
        #expect(UserPreferences.defaultIconSize == 64)
        #expect(UserPreferences.iconSizeRange.contains(UserPreferences.defaultIconSize))
    }

    @Test func resetAllSettingsForgetsIt() {
        #expect(SettingsReset.keysToRemove(from: [UserPreferences.iconSizeKey]) == [UserPreferences.iconSizeKey])
    }
}
