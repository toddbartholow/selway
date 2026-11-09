import Foundation

/// A Favorites row the sidebar can show (Settings → Sidebar). The first four
/// are on by default, as they were before the setting existed.
enum SidebarFavoriteItem: String, CaseIterable, Sendable {
    case home, desktop, documents, downloads
    case applications, pictures, music, movies, iCloudDrive

    var title: String {
        switch self {
        case .home:         return NSLocalizedString("Home", comment: "Sidebar favorite folder name")
        case .desktop:      return NSLocalizedString("Desktop", comment: "Sidebar favorite folder name")
        case .documents:    return NSLocalizedString("Documents", comment: "Sidebar favorite folder name")
        case .downloads:    return NSLocalizedString("Downloads", comment: "Sidebar favorite folder name")
        case .applications: return NSLocalizedString("Applications", comment: "Sidebar favorite folder name")
        case .pictures:     return NSLocalizedString("Pictures", comment: "Sidebar favorite folder name")
        case .music:        return NSLocalizedString("Music", comment: "Sidebar favorite folder name")
        case .movies:       return NSLocalizedString("Movies", comment: "Sidebar favorite folder name")
        case .iCloudDrive:  return NSLocalizedString("iCloud Drive", comment: "Sidebar favorite folder name")
        }
    }

    static let defaultShown: [SidebarFavoriteItem] = [.home, .desktop, .documents, .downloads]

    /// Where the row goes. Applications is the system folder, not ~/Applications.
    func url(home: URL) -> URL {
        switch self {
        case .home:         return home
        case .desktop:      return home.appendingPathComponent("Desktop", isDirectory: true)
        case .documents:    return home.appendingPathComponent("Documents", isDirectory: true)
        case .downloads:    return home.appendingPathComponent("Downloads", isDirectory: true)
        case .applications: return URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .pictures:     return home.appendingPathComponent("Pictures", isDirectory: true)
        case .music:        return home.appendingPathComponent("Music", isDirectory: true)
        case .movies:       return home.appendingPathComponent("Movies", isDirectory: true)
        case .iCloudDrive:
            return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        }
    }

    /// The row's name where the folder's own name isn't it: iCloud Drive's
    /// folder is "com~apple~CloudDocs". nil for every other folder.
    static func specialName(for url: URL, home: URL) -> String? {
        ShellPath.same(url, SidebarFavoriteItem.iCloudDrive.url(home: home)) ? SidebarFavoriteItem.iCloudDrive.title : nil
    }
}

/// What the sidebar shows (Settings → Sidebar and Tags).
enum SidebarPrefs {
    /// The Favorites rows shown, as their raw values joined by commas.
    static let favoritesKey     = "selwaySidebarFavorites"
    static let showRecentKey    = "selwaySidebarShowRecent"
    static let recentCountKey   = "selwaySidebarRecentCount"
    static let showTagsKey      = "selwaySidebarShowTags"
    /// Tags left out of the sidebar, one per line (a tag name can't contain a
    /// line break: Finder stores name and colour separated by one).
    static let hiddenTagsKey    = "selwaySidebarHiddenTags"
    /// The tags last found in use on this Mac (TagCatalog), as stored entries
    /// ("Name\nColour"), so the sidebar lists them at launch before a new scan.
    static let knownTagsKey     = "selwayKnownTags"
    // Locations: Finder's "Show in sidebar" groups (SidebarVolume.Group).
    static let showHardDisksKey      = "selwaySidebarShowHardDisks"
    static let showExternalDisksKey  = "selwaySidebarShowExternalDisks"
    static let showDiscsAndImagesKey = "selwaySidebarShowDiscsAndImages"
    static let showNetworkVolumesKey = "selwaySidebarShowNetworkVolumes"
    /// The Network row under Locations (Finder's "Bonjour computers"). On to
    /// start with: the row searches only once it's opened.
    static let showNetworkKey        = "selwaySidebarShowNetwork"
    static let defaultRecentCount = RecentFolders.defaultVisibleLimit
    /// Up to as many as the Recent list remembers (`RecentFolders.storedLimit`).
    static let recentCountRange   = 1...RecentFolders.storedLimit

    static var defaultFavoritesStorage: String { storage(for: SidebarFavoriteItem.defaultShown) }

    /// The rows to show, in the sidebar's fixed order. Unknown names are
    /// ignored; nothing stored means the defaults. An empty string is a
    /// deliberate "none".
    static func favorites(fromStorage raw: String?) -> [SidebarFavoriteItem] {
        guard let raw else { return SidebarFavoriteItem.defaultShown }
        let names = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return SidebarFavoriteItem.allCases.filter { names.contains($0.rawValue) }
    }

    static func storage(for items: [SidebarFavoriteItem]) -> String {
        let set = Set(items)
        return SidebarFavoriteItem.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }

    /// `raw` with `item` turned on or off.
    static func setting(_ item: SidebarFavoriteItem, shown: Bool, in raw: String?) -> String {
        var items = favorites(fromStorage: raw)
        items.removeAll { $0 == item }
        if shown { items.append(item) }
        return storage(for: items)
    }

    /// The rows' folders. iCloud Drive appears only while its folder exists
    /// (signed out of iCloud, or Drive turned off, it's not there).
    static func favoriteURLs(fromStorage raw: String?, home: URL, isFolder: (String) -> Bool) -> [URL] {
        favorites(fromStorage: raw).compactMap { item in
            let url = item.url(home: home)
            if item == .iCloudDrive && !isFolder(url.path) { return nil }
            return url
        }
    }

    static func recentCount(_ stored: Int?) -> Int {
        guard let stored, stored != 0 else { return defaultRecentCount }
        return min(max(stored, recentCountRange.lowerBound), recentCountRange.upperBound)
    }

    // MARK: Tags

    static func hiddenTags(fromStorage raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(separator: "\n").map(String.init).filter { name in
            !name.isEmpty && seen.insert(name.lowercased()).inserted
        }
    }

    static func storage(hiddenTags: [String]) -> String {
        Self.hiddenTags(fromStorage: hiddenTags.joined(separator: "\n")).joined(separator: "\n")
    }

    /// `raw` with `tag` hidden or shown again. Tag names are matched without
    /// regard to case, as Finder does.
    static func setting(tag: String, hidden: Bool, in raw: String) -> String {
        var tags = hiddenTags(fromStorage: raw).filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
        if hidden { tags.append(tag) }
        return storage(hiddenTags: tags)
    }

    static func isHidden(_ tag: String, in raw: String) -> Bool {
        hiddenTags(fromStorage: raw).contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    /// The tags the sidebar lists, as Finder does: the seven colour tags
    /// always, under the user's names and in Finder's order, then the custom
    /// tags in use on this Mac (`known`, from the background scan) and in the
    /// folder being viewed (`inFolder`, which the scan may not have found yet),
    /// alphabetically. Hidden tags are left out. A custom tag's colour is the
    /// one its files store; a tag named after a colour is that colour's row.
    static func tagRows(names: TagColorNames, known: [FileTag], inFolder: [FileTag],
                        hiddenStorage raw: String) -> [SidebarTag] {
        let hidden = Set(hiddenTags(fromStorage: raw).map { $0.lowercased() })
        let standard = names.standardTags.map { SidebarTag(name: $0.name, color: $0.color, isStandard: true) }
        let custom = FileTag.distinct(inFolder + known)
            .filter { names.color(named: $0.name) == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { SidebarTag(name: $0.name, color: $0.color, isStandard: false) }
        return (standard + custom).filter { !hidden.contains($0.name.lowercased()) }
    }

    static func knownTags(fromStorage entries: [String]) -> [FileTag] {
        FileTag.distinct(entries.map(FileTag.init(entry:)))
    }

    static func storage(knownTags tags: [FileTag]) -> [String] { tags.map(\.entry) }
}

/// A row in the sidebar's Tags section, and the tag filter it sets.
struct SidebarTag: Hashable, Sendable {
    let name: String
    /// 1...7, or 0 for a custom tag without a colour.
    let color: Int
    /// One of Finder's seven colour tags (under the user's name for it). Its
    /// filter also finds the colour's English name and the legacy colour label.
    let isStandard: Bool

    /// The tag names the filter finds: for a colour tag, the user's name and
    /// the English one (files tagged before a rename keep the old name).
    var searchNames: [String] {
        guard isStandard, let english = FileItem.labelToColorName[color],
              english.caseInsensitiveCompare(name) != .orderedSame else { return [name] }
        return [name, english]
    }

    /// True when `item` belongs under this tag: it has a tag of that name, or
    /// for a colour tag, the colour's legacy label.
    func matches(_ item: FileItem) -> Bool {
        let wanted = searchNames
        return item.tags.contains { tag in
            wanted.contains { $0.localizedCaseInsensitiveCompare(tag.name) == .orderedSame }
        } || (isStandard && item.labelNumber == color)
    }
}
