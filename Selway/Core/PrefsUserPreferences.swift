import Foundation

/// Persisted browse preferences — defaults mirror macOS Finder with newest-first
/// date grouping. Users can change any setting; it sticks.
enum UserPreferences {
    static let viewModeKey       = "selwayViewMode"
    static let sortFieldKey      = "selwaySortField"
    static let sortAscendingKey  = "selwaySortAscending"
    static let groupByKey        = "selwayGroupBy"
    static let folderOrderKey    = "selwayFolderOrder"
    static let showHiddenKey     = "selwayShowHidden"
    static let showPreviewKey    = "selwayShowPreview"
    static let showColumnTreeKey = "selwayShowColumnTree"
    /// The path bar under the toolbar (View → Show / Hide Path Bar); on by default.
    static let showPathBarKey    = "selwayShowPathBar"
    /// Whether new windows and tabs show two panes (View → Show / Hide Dual
    /// Pane): the choice last made in any window. Off by default.
    static let dualPaneKey       = "selwayDualPane"
    /// Bumped key so 1.5.1 re-runs migration for users who got a narrow 1.5 pass
    /// (which set `legacyMigrated15Key`).
    static let defaultsMigratedKey = "selwayBrowseDefaultsMigrated151"
    static let legacyMigrated15Key = "selwayBrowseDefaultsMigrated15"
    static let didShowFirstRunKey  = "selwayDidShowFirstRun"
    /// Whole percentages; see `TextSize`. Browser windows, and the Markdown window.
    static let textSizeKey         = "selwayTextSize"
    static let markdownTextSizeKey = "selwayMarkdownTextSize"
    /// The icon view's icon size in points at 100% text size (the slider under
    /// the grid). Kept between launches: as the view's own state it went back to
    /// 64 whenever the icon view was rebuilt (another view mode, a new window).
    static let iconSizeKey         = "selwayIconSize"
    static let defaultIconSize: Double = 64
    static let iconSizeRange: ClosedRange<Double> = 32...128
    static let iconSizeStep:  Double = 8
    /// Quick Look thumbnails of files' contents in place of their type icons, in
    /// every view (Settings → Browse → Icon previews); on by default, as in Finder.
    static let showIconPreviewsKey = "selwayShowIconPreviews"
    static let defaultShowIconPreviews = true

    /// Whether icon previews are on, for code outside a view (a view reads
    /// `showIconPreviewsKey` with @AppStorage, so it follows a change live).
    static func showsIconPreviews(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: showIconPreviewsKey, default: defaultShowIconPreviews)
    }

    // Finder-like factory defaults: list + date groups + newest first + folders on top
    static let defaultViewMode:       ViewMode     = .list
    static let defaultSortField:      SortField    = .dateModified
    static let defaultSortAscending:  Bool         = false
    static let defaultGroupBy:        GroupBy      = .dateModified
    static let defaultFolderOrder:    FolderOrder  = .foldersFirst

    /// One-time: upgrades from pre-1.5 (or old factory Name A→Z / no grouping)
    /// get newest-first date sort + date-modified groups. Deliberate custom prefs
    /// (Size, Kind grouping, descending Name, etc.) are left alone. A missing sort
    /// or direction counts as the old factory Name A→Z, so a fresh install gets
    /// the defaults written out.
    static func migrateBrowseDefaultsIfNeeded(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: defaultsMigratedKey) else { return }
        defaults.set(true, forKey: defaultsMigratedKey)

        let sort = defaults.string(forKey: sortFieldKey) ?? SortField.name.rawValue
        let ascending = defaults.object(forKey: sortAscendingKey) == nil
            ? true : defaults.bool(forKey: sortAscendingKey)
        let group = defaults.string(forKey: groupByKey) ?? GroupBy.none.rawValue

        let nameAscending = sort == SortField.name.rawValue && ascending
        let groupLooksDefault =
            group == GroupBy.none.rawValue || group == GroupBy.dateModified.rawValue

        guard nameAscending && groupLooksDefault else { return }

        defaults.set(defaultSortField.rawValue, forKey: sortFieldKey)
        defaults.set(defaultSortAscending, forKey: sortAscendingKey)
        defaults.set(defaultGroupBy.rawValue, forKey: groupByKey)
        if defaults.object(forKey: viewModeKey) == nil {
            defaults.set(defaultViewMode.rawValue, forKey: viewModeKey)
        }
        if defaults.object(forKey: folderOrderKey) == nil {
            defaults.set(defaultFolderOrder.rawValue, forKey: folderOrderKey)
        }
    }

    /// The stored icon size as the slider can show it: clamped to its range and
    /// snapped to its steps, so a hand-edited value can't make icons vanish or
    /// fill the window. Anything unreadable is the default.
    static func iconSize(fromStorage raw: Double) -> Double {
        guard raw.isFinite else { return defaultIconSize }
        let clamped = min(max(raw, iconSizeRange.lowerBound), iconSizeRange.upperBound)
        let steps = ((clamped - iconSizeRange.lowerBound) / iconSizeStep).rounded()
        return iconSizeRange.lowerBound + steps * iconSizeStep
    }

    /// Apply factory browse defaults (Settings reset + install repair).
    static func applyFactoryBrowseDefaults(_ defaults: UserDefaults = .standard) {
        defaults.set(defaultViewMode.rawValue, forKey: viewModeKey)
        defaults.set(defaultSortField.rawValue, forKey: sortFieldKey)
        defaults.set(defaultSortAscending, forKey: sortAscendingKey)
        defaults.set(defaultGroupBy.rawValue, forKey: groupByKey)
        defaults.set(defaultFolderOrder.rawValue, forKey: folderOrderKey)
    }
}

// MARK: - AppStorage helpers (enum ↔ persisted raw string)

extension ViewMode {
    static func fromStorage(_ raw: String) -> ViewMode {
        ViewMode(rawValue: raw) ?? UserPreferences.defaultViewMode
    }
}

extension SortField {
    static func fromStorage(_ raw: String) -> SortField {
        SortField(rawValue: raw) ?? UserPreferences.defaultSortField
    }
}

extension GroupBy {
    static func fromStorage(_ raw: String) -> GroupBy {
        GroupBy(rawValue: raw) ?? UserPreferences.defaultGroupBy
    }
}

extension FolderOrder {
    static func fromStorage(_ raw: String) -> FolderOrder {
        FolderOrder(rawValue: raw) ?? UserPreferences.defaultFolderOrder
    }
}

// MARK: - The browse settings as stored now

/// The browse settings a browser pane lists, sorts and searches with, read
/// from UserDefaults when they're needed (`current`), with the keys and stored
/// values `@AppStorage` uses for them.
///
/// For code that runs after the view that set it up was rendered: a menu
/// command's closure, a pane's loading and search methods. An `@AppStorage`
/// read there gives the value from when the closure was made, which is how a
/// menu command came to act on a stale view mode (Edit ▸ Select All). Views
/// keep reading `@AppStorage`, so they re-render when a setting changes.
///
/// A missing or unreadable value is the default, as `@AppStorage` gives it.
struct BrowseSettings: Equatable {
    var viewMode:      ViewMode
    var sortField:     SortField
    var sortAscending: Bool
    var groupBy:       GroupBy
    var folderOrder:   FolderOrder
    var showHidden:    Bool
    /// The path bar under the toolbar (View → Show / Hide Path Bar).
    var showPathBar:   Bool

    /// The settings as `defaults` holds them.
    init(_ defaults: UserDefaults) {
        typealias P = UserPreferences
        viewMode      = .fromStorage(defaults.string(forKey: P.viewModeKey) ?? P.defaultViewMode.rawValue)
        sortField     = .fromStorage(defaults.string(forKey: P.sortFieldKey) ?? P.defaultSortField.rawValue)
        sortAscending = defaults.bool(forKey: P.sortAscendingKey, default: P.defaultSortAscending)
        groupBy       = .fromStorage(defaults.string(forKey: P.groupByKey) ?? P.defaultGroupBy.rawValue)
        folderOrder   = .fromStorage(defaults.string(forKey: P.folderOrderKey) ?? P.defaultFolderOrder.rawValue)
        showHidden    = defaults.bool(forKey: P.showHiddenKey, default: false)
        showPathBar   = defaults.bool(forKey: P.showPathBarKey, default: true)
    }

    /// The settings as they are now (the standard defaults).
    static var current: BrowseSettings { BrowseSettings(.standard) }
}
