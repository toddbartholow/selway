import Foundation
import Testing
@testable import SelwayCore

// MARK: - sortedItems

@Suite struct ModelSortTests {
    @Test func sortFieldsKeepStoredValuesAndEnglishDisplayNames() {
        let expected = ["Name", "Date Modified", "Date Created", "Size", "Kind", "Extension"]
        #expect(SortField.allCases.map(\.rawValue) == expected)
        #expect(SortField.allCases.map(\.displayName) == expected)
    }

    @Test func folderOrderKeepsStoredValuesAndEnglishDisplayNames() {
        let expected = ["Folders on Top", "Files on Top", "Mixed (Sort Only)"]
        #expect(FolderOrder.allCases.map(\.rawValue) == expected)
        #expect(FolderOrder.allCases.map(\.displayName) == expected)
    }

    @Test func groupByKeepsStoredValuesAndEnglishDisplayNames() {
        let expected = ["None", "Date Modified", "Date Created", "Kind", "Extension", "Size", "Name"]
        #expect(GroupBy.allCases.map(\.rawValue) == expected)
        #expect(GroupBy.allCases.map(\.displayName) == expected)
    }

    @Test func dateCategoriesKeepIdentifiersAndEnglishDisplayNames() {
        let expected = ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Previous 90 Days", "Earlier"]
        #expect(DateCategory.allCases.map(\.rawValue) == expected)
        #expect(DateCategory.allCases.map(\.id) == expected)
        #expect(DateCategory.allCases.map(\.displayName) == expected)
    }

    @Test func sizeBandsKeepIdentifiersAndEnglishDisplayNames() {
        let expected = ["Folders", "Zero KB", "1 KB – 100 KB", "100 KB – 1 MB", "1 MB – 100 MB", "100 MB – 1 GB", "Over 1 GB"]
        #expect(SizeBand.allCases.map(\.rawValue) == expected)
        #expect(SizeBand.allCases.map(\.id) == expected)
        #expect(SizeBand.allCases.map(\.displayName) == expected)
    }
    private func names(_ items: [FileItem]) -> [String] { items.map(\.name) }

    @Test func nameSortUsesFinderNumericOrder() {
        let items = ["file10", "file2", "File1", "file1.txt"].map { FileItem.fixture($0) }
        #expect(names(sortedItems(items, by: .name, ascending: true))
                == ["File1", "file1.txt", "file2", "file10"])
        #expect(names(sortedItems(items, by: .name, ascending: false))
                == ["file10", "file2", "file1.txt", "File1"])
    }

    @Test(arguments: SortField.allCases, [true, false])
    func tiesAreStableWhateverTheInputOrder(field: SortField, ascending: Bool) {
        // Same size / dates / kind / extension: only the name tie-break separates them.
        let items = ["b10.txt", "b2.txt", "a.txt", "c.txt", "b1.txt"].map {
            FileItem.fixture($0, size: 42)
        }
        let expected = sortedItems(items, by: field, ascending: ascending)
        var rng = SeededRandom(seed: 7)
        for _ in 0..<50 {
            #expect(sortedItems(items.shuffled(using: &rng), by: field, ascending: ascending) == expected)
        }
        if field != .name {
            // Ties fall back to name ascending in both directions.
            #expect(names(expected) == ["a.txt", "b1.txt", "b2.txt", "b10.txt", "c.txt"])
        }
    }

    @Test func caseOnlyDifferencesStillHaveATotalOrder() {
        let items = [FileItem.fixture("a"), FileItem.fixture("A"), FileItem.fixture("a", parent: "/other")]
        for ascending in [true, false] {
            let one = sortedItems(items, by: .name, ascending: ascending)
            #expect(sortedItems(items.reversed(), by: .name, ascending: ascending) == one)
            #expect(sortedItems([items[1], items[2], items[0]], by: .name, ascending: ascending) == one)
        }
    }

    @Test func descendingReversesPrimaryKeyOnly() {
        let items = [
            FileItem.fixture("x", size: 1), FileItem.fixture("b", size: 5),
            FileItem.fixture("a", size: 5), FileItem.fixture("y", size: 9),
        ]
        #expect(names(sortedItems(items, by: .size, ascending: false)) == ["y", "a", "b", "x"])
        #expect(names(sortedItems(items, by: .size, ascending: true)) == ["x", "a", "b", "y"])
    }

    @Test(arguments: FolderOrder.allCases, [true, false])
    func folderOrderIsRespected(order: FolderOrder, ascending: Bool) {
        let items = [
            FileItem.fixture("b.txt"), FileItem.fixture("Zeta", folder: true),
            FileItem.fixture("a.txt"), FileItem.fixture("Alpha", folder: true),
            FileItem.fixture("App.app", package: true),   // package sorts as a file
        ]
        let sorted = sortedItems(items, by: .name, ascending: ascending, folderOrder: order)
        var rng = SeededRandom(seed: 3)
        for _ in 0..<20 {
            #expect(sortedItems(items.shuffled(using: &rng), by: .name, ascending: ascending,
                                folderOrder: order) == sorted)
        }
        let folderFlags = sorted.map(\.isBrowsableFolder)
        switch order {
        case .foldersFirst: #expect(folderFlags == [true, true, false, false, false])
        case .filesFirst:   #expect(folderFlags == [false, false, false, true, true])
        case .mixed:
            #expect(names(sorted) == (ascending
                ? ["a.txt", "Alpha", "App.app", "b.txt", "Zeta"]
                : ["Zeta", "b.txt", "App.app", "Alpha", "a.txt"]))
        }
    }

    @Test func dateAndKindAndExtensionSorts() {
        let old = FileItem.fixture("old.md", modified: TestClock.daysAgo(10), created: TestClock.daysAgo(1))
        let new = FileItem.fixture("new.pdf", modified: TestClock.daysAgo(1), created: TestClock.daysAgo(10))
        #expect(names(sortedItems([old, new], by: .dateModified, ascending: false)) == ["new.pdf", "old.md"])
        #expect(names(sortedItems([old, new], by: .dateCreated, ascending: false)) == ["old.md", "new.pdf"])
        #expect(names(sortedItems([new, old], by: .ext, ascending: true)) == ["old.md", "new.pdf"])
        #expect(names(sortedItems([new, old], by: .kind, ascending: true)) == ["old.md", "new.pdf"])
    }
}

// MARK: - groupedItems

@Suite struct ModelGroupTests {
    private func group(_ items: [FileItem], _ by: GroupBy) -> [FileGroup] {
        groupedItems(items, by: by, now: TestClock.now, calendar: TestClock.calendar)
    }
    private func titles(_ groups: [FileGroup]) -> [String] { groups.map(\.title) }

    @Test(arguments: GroupBy.allCases)
    func emptyInputHasNoGroups(by: GroupBy) {
        #expect(group([], by).isEmpty)
    }

    @Test func noneIsOneUntitledGroup() {
        let items = [FileItem.fixture("b"), FileItem.fixture("a")]
        let groups = group(items, .none)
        #expect(groups.count == 1)
        #expect(groups[0].id == "all" && groups[0].title == "" && groups[0].items == items)
    }

    @Test func dateBuckets() {
        let cases: [(Date, DateCategory)] = [
            (TestClock.now.addingTimeInterval(3_600), .today),   // future → Today
            (TestClock.daysAgo(0, hour: 0), .today),
            (TestClock.daysAgo(1, hour: 23), .yesterday),
            (TestClock.daysAgo(2, hour: 23), .previous7),         // calendar days, not 24h periods
            (TestClock.daysAgo(7), .previous7),
            (TestClock.daysAgo(8), .previous30),
            (TestClock.daysAgo(30), .previous30),
            (TestClock.daysAgo(31), .previous90),
            (TestClock.daysAgo(90), .previous90),
            (TestClock.daysAgo(91), .earlier),
            (.distantPast, .earlier),
        ]
        for (date, expected) in cases {
            #expect(DateCategory.of(date, now: TestClock.now, calendar: TestClock.calendar) == expected,
                    "\(date)")
        }
    }

    @Test func dateGroupsFollowCategoryOrderAndSkipEmptyBuckets() {
        let items = [
            FileItem.fixture("old", modified: TestClock.daysAgo(200), created: TestClock.daysAgo(0)),
            FileItem.fixture("today", modified: TestClock.daysAgo(0), created: TestClock.daysAgo(40)),
            FileItem.fixture("week", modified: TestClock.daysAgo(3), created: TestClock.daysAgo(40)),
            FileItem.fixture("today2", modified: TestClock.daysAgo(0), created: TestClock.daysAgo(200)),
        ]
        let modified = group(items, .dateModified)
        #expect(titles(modified) == ["Today", "Previous 7 Days", "Earlier"])
        #expect(modified[0].items.map(\.name) == ["today", "today2"])   // input order kept
        #expect(modified.map(\.id) == ["dm-Today", "dm-Previous 7 Days", "dm-Earlier"])

        let created = group(items, .dateCreated)
        #expect(titles(created) == ["Today", "Previous 90 Days", "Earlier"])
        #expect(created[1].items.map(\.name) == ["today", "week"])
        #expect(created[0].id == "dc-Today")
    }

    @Test func kindGroupsUseFirstSeenOrder() {
        let items = [
            FileItem.fixture("a.txt", kind: "Text"), FileItem.fixture("b", kind: ""),
            FileItem.fixture("c.png", kind: "Image"), FileItem.fixture("d.txt", kind: "Text"),
        ]
        let groups = group(items, .kind)
        #expect(titles(groups) == ["Text", "Unknown", "Image"])
        #expect(groups[0].items.map(\.name) == ["a.txt", "d.txt"])
        #expect(groups[1].id == "kind-Unknown")
    }

    @Test func extensionGroups() {
        let items = [
            FileItem.fixture("b.TXT"), FileItem.fixture("Docs", folder: true),
            FileItem.fixture("README"), FileItem.fixture("Tool.app", package: true),
            FileItem.fixture("a.txt"),
        ]
        let groups = group(items, .extension_)
        #expect(titles(groups) == ["TXT", "Folders", "Other", "APP"])
        #expect(groups[0].items.map(\.name) == ["b.TXT", "a.txt"])
    }

    @Test func sizeBandBoundaries() {
        let cases: [(Int64, SizeBand)] = [
            (0, .zero), (1, .tiny), (99_999, .tiny), (100_000, .small), (999_999, .small),
            (1_000_000, .medium), (99_999_999, .medium), (100_000_000, .large),
            (999_999_999, .large), (1_000_000_000, .huge), (-1, .zero),
        ]
        for (size, band) in cases {
            #expect(SizeBand.of(.fixture("f", size: size)) == band, "\(size)")
        }
        #expect(SizeBand.of(.fixture("d", folder: true, size: 5_000_000)) == .folders)
        #expect(SizeBand.of(.fixture("p.app", package: true, size: 5_000_000)) == .medium)
    }

    @Test func sizeGroupsFollowBandOrder() {
        let items = [
            FileItem.fixture("huge", size: 2_000_000_000), FileItem.fixture("zero"),
            FileItem.fixture("dir", folder: true), FileItem.fixture("tiny", size: 10),
            FileItem.fixture("zero2"),
        ]
        let groups = group(items, .size)
        #expect(titles(groups) == ["Folders", "Zero KB", "1 KB – 100 KB", "Over 1 GB"])
        #expect(groups[1].items.map(\.name) == ["zero", "zero2"])
    }

    @Test func nameInitialKeys() {
        let cases: [(String, String)] = [
            ("apple", "A"), ("  apple", "A"), ("\tzebra", "Z"), ("Banana", "B"),
            ("é", "E"), ("Ünits", "U"), ("\u{0065}\u{0301}clair", "E"),   // decomposed é
            ("1password", "#"), ("_tmp", "#"), ("", "#"), ("   ", "#"),
            ("йота", "Й"), ("ё", "Ё"), ("ωmega", "Ω"), ("Üй", "U"),
            ("日本", "#"), ("שלום", "#"), ("中a", "#"), ("ß", "#"), ("æble", "Æ"), ("Йота", "Й"), ("Ωmega", "Ω"),
            ("Άρης", "Α"), ("έλενα", "Ε"), ("Ａpple", "A"), ("ｚebra", "Z"), ("ანა", "#"), ("😀", "#"),
            ("あさ", "あ"), ("きつね", "か"), ("すし", "さ"), ("たこ", "た"), ("なまえ", "な"),
            ("はな", "は"), ("まつ", "ま"), ("やま", "や"), ("りんご", "ら"), ("わに", "わ"),
            ("カメラ写真", "か"), ("ガラス", "か"), ("ぱん", "は"), ("っぽい", "た"),
            ("ヷ", "わ"), ("ヸ", "わ"), ("ヹ", "わ"), ("ヺ", "わ"),
            ("ゃく", "や"), ("ゎ", "わ"), ("ゔ", "あ"), ("ゐ", "わ"), ("ゑ", "わ"), ("を", "わ"), ("ん", "わ"),
            ("ｶﾒﾗ", "か"), ("ㇰ", "か"), ("ゟ", "や"), ("ヿ", "か"), ("ー", "#"), ("ゝ", "#"), ("ゞ", "#"), ("ヽ", "#"), ("ヾ", "#"),
        ]
        for (name, key) in cases {
            // English, so a Mac set to Japanese doesn't read "日本" as な.
            #expect(FileItem.fixture(name).nameGroupKey(language: "en") == key, "\(name.debugDescription)")
        }
    }

    @Test func onlyJapaneseLanguageIdentifiersCountAsJapanese() {
        for language in ["ja", "ja-JP", "ja_JP", "JA"] { #expect(FileItem.isJapanese(language), "\(language)") }
        for language in ["en", "en-JP", "jam", "zh-Hans", ""] { #expect(!FileItem.isJapanese(language), "\(language)") }
    }

    @Test func kanjiUseJapaneseReadingsOnlyOnMacForJapaneseLanguage() {
        #if canImport(Darwin)
        let cases = [("写真", "さ"), ("書類", "さ"), ("音楽", "あ")]
        for (name, key) in cases {
            #expect(FileItem.fixture(name).nameGroupKey(language: "ja") == key, "\(name.debugDescription)")
            #expect(FileItem.fixture(name).nameGroupKey(language: "ja-JP") == key, "\(name.debugDescription)")
            for other in ["en", "en-JP", "jam", "zh-Hans"] {
                #expect(FileItem.fixture(name).nameGroupKey(language: other) == "#", "\(name.debugDescription) \(other)")
            }
        }
        #else
        for name in ["写真", "書類", "音楽"] {
            #expect(FileItem.fixture(name).nameGroupKey(language: "ja") == "#", "\(name.debugDescription)")
        }
        #endif
    }

    @Test func nameGroupsAreAlphabeticalWithHashLast() {
        let items = ["#hash", "zed", "Apple", "éclair", "42", "avocado"].map { FileItem.fixture($0) }
        let groups = group(items, .nameInitial)
        #expect(titles(groups) == ["A", "E", "Z", "#"])
        #expect(groups[0].items.map(\.name) == ["Apple", "avocado"])
        #expect(groups[3].items.map(\.name) == ["#hash", "42"])
        #expect(groups[0].id == "nm-A")
    }

    @Test func otherScriptsSortInAlphabeticalOrder() {
        // Code-point order would put Ё (U+0401) before А and Ґ (U+0490) after Я.
        let keys: Set<String> = ["Я", "Ё", "А", "Ґ", "Β", "Α", "#", "B", "A"]
        #expect(FileItem.orderedNameGroupKeys(keys, locale: Locale(identifier: "en"))
                == ["A", "B", "Α", "Β", "А", "Ґ", "Ё", "Я", "#"])
    }

    @Test func kanaRowsFollowOtherLettersInExplicitGojuonOrder() {
        let keys: Set<String> = ["わ", "は", "я", "Β", "А", "か", "さ", "A", "あ", "#", "た", "な", "ま", "や", "ら"]
        #expect(FileItem.orderedNameGroupKeys(keys, locale: Locale(identifier: "en"))
                == ["A", "Β", "А", "я", "あ", "か", "さ", "た", "な", "は", "ま", "や", "ら", "わ", "#"])
    }

    @Test func nameGroupsPutOtherScriptsAfterLatin() {
        let items = ["שלום", "йота", "Ωmega", "zebra", "Αλφα", "#hash", "Apple"]
            .map { FileItem.fixture($0) }
        let groups = group(items, .nameInitial)
        #expect(titles(groups) == ["A", "Z", "Α", "Ω", "Й", "#"])
        #expect(groups.allSatisfy { !$0.items.isEmpty })
    }

    @Test(arguments: GroupBy.allCases)
    func everyItemLandsInExactlyOneGroup(by: GroupBy) {
        var rng = SeededRandom(seed: 11)
        let items = (0..<2_000).map { i in
            FileItem.fixture("\(["a", "B", "é", "1", " z"][i % 5])file\(i).\(["txt", "png", ""][i % 3])",
                             folder: i % 17 == 0,
                             size: Int64.random(in: 0...2_000_000_000, using: &rng),
                             modified: TestClock.daysAgo(Int.random(in: 0...400, using: &rng)),
                             created: TestClock.daysAgo(Int.random(in: 0...400, using: &rng)))
        }
        let groups = group(items, by)
        #expect(groups.flatMap(\.items).count == items.count)
        #expect(Set(groups.flatMap(\.items).map(\.id)) == Set(items.map(\.id)))
        #expect(Set(groups.map(\.id)).count == groups.count)
        #expect(groups.allSatisfy { !$0.items.isEmpty })
    }

    @Test func groupingTwentyThousandItemsByNameIsFast() {
        let items = (0..<20_000).map { FileItem.fixture("\(UnicodeScalar(UInt8(65 + $0 % 26)))item\($0)") }
        let start = Date()
        let groups = group(items, .nameInitial)
        let elapsed = Date().timeIntervalSince(start)
        #expect(groups.count == 26)
        // One pass now (~0.015 s here). The old 27 filter passes with a regex per
        // item per pass took ~0.6 s on the same Mac, so this bound catches a
        // return to that while leaving ~15x headroom for slow CI.
        #expect(elapsed < 0.25, "took \(elapsed)s")
    }
}

// MARK: - Equality

@Suite struct ModelEqualityTests {
    @Test func equalityCoversMoreThanTheID() {
        let a = FileItem.fixture("a.txt", size: 1)
        let resized = FileItem.fixture("a.txt", size: 2)
        let retagged = FileItem.fixture("a.txt", size: 1, tags: ["Red"])
        let touched = FileItem.fixture("a.txt", size: 1, modified: TestClock.daysAgo(1))
        #expect(a.id == resized.id)
        #expect(a != resized && a != retagged && a != touched)
        #expect(a == FileItem.fixture("a.txt", size: 1))
        #expect(Set([a, resized, retagged, touched, FileItem.fixture("a.txt", size: 1)]).count == 4)
    }

    @Test func tagHelpers() {
        let item = FileItem.fixture("x.zip", tags: ["Red", "Work"])
        #expect(item.hasColorTag("red") && item.hasColorTag("RED") && !item.hasColorTag("Blue"))
        #expect(item.isArchive && !FileItem.fixture("x.txt").isArchive)
        #expect(FileItem.colorMenuOrder.allSatisfy { FileItem.colorNameToLabel[$0.lowercased()] != nil })
        for (name, n) in FileItem.colorNameToLabel {
            #expect(FileItem.labelToColorName[n]?.lowercased() == name)
        }
    }
}

/// Deterministic RNG so shuffles are reproducible across runs and platforms.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
