import Foundation

// MARK: - Date category (Finder-style Recent / Older grouping)

/// Matches Finder's "Group by Date" buckets — including the "Previous 90 Days"
/// band Finder added after the old 30-day / Earlier split.
enum DateCategory: String, CaseIterable, Identifiable {
    case today        = "Today"
    case yesterday    = "Yesterday"
    case previous7    = "Previous 7 Days"
    case previous30   = "Previous 30 Days"
    case previous90   = "Previous 90 Days"
    case earlier      = "Earlier"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .today:      NSLocalizedString("Today", comment: "Date grouping section title")
        case .yesterday:  NSLocalizedString("Yesterday", comment: "Date grouping section title")
        case .previous7:  NSLocalizedString("Previous 7 Days", comment: "Date grouping section title")
        case .previous30: NSLocalizedString("Previous 30 Days", comment: "Date grouping section title")
        case .previous90: NSLocalizedString("Previous 90 Days", comment: "Date grouping section title")
        case .earlier:    NSLocalizedString("Earlier", comment: "Date grouping section title")
        }
    }

    /// Buckets by *calendar* days between `date` and `now` (so 23:59 two days ago
    /// is "Previous 7 Days", never "Yesterday"). Future dates count as Today.
    /// `now` / `calendar` are injectable for tests; grouping passes one fixed
    /// `now` so a long list can't straddle midnight.
    static func of(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> DateCategory {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days <= 0  { return .today }
        if days == 1  { return .yesterday }
        if days <= 7  { return .previous7 }
        if days <= 30 { return .previous30 }
        if days <= 90 { return .previous90 }
        return .earlier
    }
}

// MARK: - Grouping & folder order

/// How items are visually sectioned. Sort field still applies *inside* each group.
enum GroupBy: String, CaseIterable, Identifiable {
    case none = "None"
    case dateModified = "Date Modified"
    case dateCreated  = "Date Created"
    case kind         = "Kind"
    case extension_   = "Extension"
    case size         = "Size"
    case nameInitial  = "Name"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none:         NSLocalizedString("None", comment: "File grouping option")
        case .dateModified: NSLocalizedString("Date Modified", comment: "File grouping option")
        case .dateCreated:  NSLocalizedString("Date Created", comment: "File grouping option")
        case .kind:         NSLocalizedString("Kind", comment: "File grouping option")
        case .extension_:   NSLocalizedString("Extension", comment: "File grouping option")
        case .size:         NSLocalizedString("Size", comment: "File grouping option")
        case .nameInitial:  NSLocalizedString("Name", comment: "File grouping option")
        }
    }
}

/// Whether folders float above files, sink below, or mix with the sort.
enum FolderOrder: String, CaseIterable, Identifiable {
    case foldersFirst = "Folders on Top"
    case filesFirst   = "Files on Top"
    case mixed        = "Mixed (Sort Only)"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .foldersFirst: NSLocalizedString("Folders on Top", comment: "Folder order option")
        case .filesFirst:   NSLocalizedString("Files on Top", comment: "Folder order option")
        case .mixed:        NSLocalizedString("Mixed (Sort Only)", comment: "Folder order option")
        }
    }
}

/// A labeled section of already-sorted items used by list / icon / column views.
struct FileGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [FileItem]
}

/// Bucket absolute file sizes into Finder / Explorer-like bands.
enum SizeBand: String, CaseIterable, Identifiable {
    case folders     = "Folders"
    case zero        = "Zero KB"
    case tiny        = "1 KB – 100 KB"
    case small       = "100 KB – 1 MB"
    case medium      = "1 MB – 100 MB"
    case large       = "100 MB – 1 GB"
    case huge        = "Over 1 GB"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .folders: NSLocalizedString("Folders", comment: "File size grouping section title")
        case .zero:    NSLocalizedString("Zero KB", comment: "File size grouping section title")
        case .tiny:    NSLocalizedString("1 KB – 100 KB", comment: "File size grouping section title")
        case .small:   NSLocalizedString("100 KB – 1 MB", comment: "File size grouping section title")
        case .medium:  NSLocalizedString("1 MB – 100 MB", comment: "File size grouping section title")
        case .large:   NSLocalizedString("100 MB – 1 GB", comment: "File size grouping section title")
        case .huge:    NSLocalizedString("Over 1 GB", comment: "File size grouping section title")
        }
    }

    static func of(_ item: FileItem) -> SizeBand {
        if item.isBrowsableFolder { return .folders }
        let s = item.size
        if s <= 0          { return .zero }
        if s < 100_000     { return .tiny }
        if s < 1_000_000   { return .small }
        if s < 100_000_000 { return .medium }
        if s < 1_000_000_000 { return .large }
        return .huge
    }
}

// MARK: - Sort

enum SortField: String, CaseIterable, Identifiable {
    case name         = "Name"
    case dateModified = "Date Modified"
    case dateCreated  = "Date Created"
    case size         = "Size"
    case kind         = "Kind"
    case ext          = "Extension"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .name:         NSLocalizedString("Name", comment: "Sort field")
        case .dateModified: NSLocalizedString("Date Modified", comment: "Sort field")
        case .dateCreated:  NSLocalizedString("Date Created", comment: "Sort field")
        case .size:         NSLocalizedString("Size", comment: "Sort field")
        case .kind:         NSLocalizedString("Kind", comment: "Sort field")
        case .ext:          NSLocalizedString("Extension", comment: "Sort field")
        }
    }
}

enum ViewMode: String, CaseIterable {
    case list, icons, columns
    var icon: String {
        switch self {
        case .list:    "list.bullet"
        case .icons:   "square.grid.2x2"
        case .columns: "rectangle.split.3x1"
        }
    }
}

private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
    a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
}

/// Strict weak ordering: folder order, then `field` (reversed when descending),
/// then name ascending, then path — so equal keys keep one stable, Finder-like
/// order (file2 before file10) whatever order they arrived in.
func sortedItems(_ items: [FileItem],
                 by field: SortField,
                 ascending: Bool,
                 folderOrder: FolderOrder = .foldersFirst) -> [FileItem] {
    items.sorted { itemPrecedes($0, $1, by: field, ascending: ascending, folderOrder: folderOrder) }
}

/// Whether `a` comes before `b` in `sortedItems`' order.
func itemPrecedes(_ a: FileItem, _ b: FileItem,
                  by field: SortField,
                  ascending: Bool,
                  folderOrder: FolderOrder = .foldersFirst) -> Bool {
    if a.isBrowsableFolder != b.isBrowsableFolder {
        switch folderOrder {
        case .foldersFirst: return a.isBrowsableFolder
        case .filesFirst:   return b.isBrowsableFolder
        case .mixed:        break
        }
    }
    let primary: ComparisonResult
    switch field {
    case .name:         primary = a.name.localizedStandardCompare(b.name)
    case .dateModified: primary = compare(a.dateModified, b.dateModified)
    case .dateCreated:  primary = compare(a.dateCreated, b.dateCreated)
    case .size:         primary = compare(a.size, b.size)
    case .kind:         primary = a.kind.localizedStandardCompare(b.kind)
    case .ext:          primary = a.fileExtension.localizedStandardCompare(b.fileExtension)
    }
    if primary != .orderedSame {
        return (primary == .orderedAscending) == ascending
    }
    if field != .name {
        let byName = a.name.localizedStandardCompare(b.name)
        if byName != .orderedSame { return byName == .orderedAscending }
    }
    // Names that compare equal under localized rules ("a" / "A") — fall back to
    // the exact path so the order is total and repeatable.
    return a.id < b.id
}

// MARK: - Group

/// Split an already-sorted list into visible section groups. One pass over
/// `items` for every grouping, so 10k+ item folders stay cheap to re-render.
/// Items keep their sorted order inside each group.
func groupedItems(_ items: [FileItem],
                  by grouping: GroupBy,
                  now: Date = Date(),
                  calendar: Calendar = .current) -> [FileGroup] {
    guard !items.isEmpty else { return [] }

    switch grouping {
    case .none:
        return [FileGroup(id: "all", title: "", items: items)]

    case .dateModified, .dateCreated:
        let created = grouping == .dateCreated
        var buckets: [DateCategory: [FileItem]] = [:]
        for item in items {
            let cat = DateCategory.of(created ? item.dateCreated : item.dateModified,
                                      now: now, calendar: calendar)
            buckets[cat, default: []].append(item)
        }
        let prefix = created ? "dc" : "dm"
        return DateCategory.allCases.compactMap { cat in
            guard let g = buckets[cat] else { return nil }
            return FileGroup(id: "\(prefix)-\(cat.rawValue)", title: cat.displayName, items: g)
        }

    case .kind:
        // Preserve encounter order from the sorted list so relative sort holds.
        return groupedInEncounterOrder(items, idPrefix: "kind") {
            $0.kind.isEmpty ? NSLocalizedString("Unknown", comment: "File grouping section for items with no kind description") : $0.kind
        }

    case .extension_:
        return groupedInEncounterOrder(items, idPrefix: "ext") { item in
            if item.isBrowsableFolder { return NSLocalizedString("Folders", comment: "File extension grouping section for folders") }
            return item.fileExtension.isEmpty
                ? NSLocalizedString("Other", tableName: "Grouping", comment: "File extension grouping section for items without an extension")
                : item.fileExtension.uppercased()
        }

    case .size:
        var buckets: [SizeBand: [FileItem]] = [:]
        for item in items { buckets[SizeBand.of(item), default: []].append(item) }
        return SizeBand.allCases.compactMap { band in
            guard let g = buckets[band] else { return nil }
            return FileGroup(id: "sz-\(band.rawValue)", title: band.displayName, items: g)
        }

    case .nameInitial:
        var buckets: [String: [FileItem]] = [:]
        // The language Selway runs in: the first preferred language it has a
        // translation for, which needn't be the first preferred language.
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        for item in items { buckets[item.nameGroupKey(language: language), default: []].append(item) }
        return FileItem.orderedNameGroupKeys(Set(buckets.keys)).compactMap { key in
            guard let g = buckets[key] else { return nil }
            return FileGroup(id: "nm-\(key)", title: key, items: g)
        }
    }
}

private func groupedInEncounterOrder(_ items: [FileItem], idPrefix: String,
                                     key: (FileItem) -> String) -> [FileGroup] {
    var order: [String] = []
    var buckets: [String: [FileItem]] = [:]
    for item in items {
        let k = key(item)
        if buckets[k] == nil { order.append(k) }
        buckets[k, default: []].append(item)
    }
    return order.map { FileGroup(id: "\(idPrefix)-\($0)", title: $0, items: buckets[$0] ?? []) }
}
