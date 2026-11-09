import Foundation
#if canImport(Glibc)
import Glibc
#endif

// MARK: - FileItem

/// Value snapshot of one directory entry. Equality and hashing cover every
/// field, so SwiftUI re-renders a row whose size / date / tags changed even
/// though its `id` didn't. Selection and rename state key off `id`, not the item.
struct FileItem: Identifiable, Hashable {
    /// Stable path-based id so selection / rename survive directory reloads.
    let id:            String
    let url:           URL
    let name:          String
    let isDirectory:   Bool
    let isPackage:     Bool      // opaque bundle (.app, .pages, …) — open, don't browse
    let isHidden:      Bool
    let size:          Int64
    let dateModified:  Date
    let dateCreated:   Date
    let kind:          String
    let fileExtension: String

    /// The legacy colour label (Finder info). Kept in step with the tags by
    /// FileOpsTags; files from old apps may have only this.
    let labelNumber: Int
    /// macOS tags (several per file), with the colour stored with each.
    let tags:        [FileTag]
    /// A symlink Selway didn't follow: broken, or leading into an automount
    /// folder (see `load`). It's shown as the link itself, a file.
    var isLinkNotFollowed = false
    /// For a link the listing followed, its target's modification date and
    /// size: `dateModified` and `size` are the link's own (as Finder lists a
    /// link), which don't change when the file it leads to is edited. nil for
    /// anything else. Only what a thumbnail is keyed by uses them
    /// (`contentModified`, `contentSize`).
    var targetModified: Date?
    var targetSize: Int64?

    /// When the contents shown for this item last changed: the target's for a
    /// followed link, else the item's own.
    var contentModified: Date { targetModified ?? dateModified }
    /// The size of the contents shown for this item (as `contentModified`).
    var contentSize: Int64 { targetSize ?? size }

    var tagNames: [String] { tags.map(\.name) }

    /// A backup listed at its Time Machine disk's root, which may not be
    /// mounted, so nothing is read from it.
    static func timeMachineBackup(_ backup: TimeMachineBackups.Backup) -> FileItem {
        let url = backup.url
        return FileItem(id: url.path, url: url, name: backup.name, isDirectory: true, isPackage: false,
                        isHidden: false, size: 0, dateModified: backup.date, dateCreated: backup.date,
                        kind: NSLocalizedString("Folder", comment: "Kind description for a folder"),
                        fileExtension: "backup", labelNumber: 0, tags: [])
    }

    /// Keys needed to browse / sort / group. Kind isn't a key: asking for it per
    /// file made folder opens wait on Launch Services, so `load` asks once per
    /// extension (`KindCache`). Tags aren't a key either: `tagNamesKey` drops each
    /// tag's colour, so `load` reads the tags attribute itself (one getxattr per
    /// file, which is what the key cost too). The sidebar Tags section, tag
    /// filters and Clear Tags read them straight from the listing.
    static let resourceKeys: [URLResourceKey] = {
        var keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .creationDateKey, .isHiddenKey, .isSymbolicLinkKey,
        ]
        #if os(macOS)
        keys += [.isPackageKey, .labelNumberKey, .isAliasFileKey]
        #endif
        return keys
    }()

    /// Extra keys for Get Info enrichment (optional second pass).
    static let enrichKeys: [URLResourceKey] = {
        #if os(macOS)
        return [.localizedTypeDescriptionKey, .tagNamesKey]
        #else
        return []
        #endif
    }()

    /// True when double-click should navigate into this item like a normal folder.
    /// Application bundles and other opaque packages launch instead (Finder behaviour).
    var isBrowsableFolder: Bool { isDirectory && !isPackage }

    /// What a tag change on `items` writes to: not links the listing didn't
    /// follow (`isLinkNotFollowed`), whose tags would be written where they
    /// lead, mounting it; and how many of those it leaves out.
    static func tagTargets(_ items: [FileItem]) -> (items: [FileItem], skippedLinks: Int) {
        let taggable = items.filter { !$0.isLinkNotFollowed }
        return (taggable, items.count - taggable.count)
    }

    /// URL-level check used before a `FileItem` exists (path bar / external opens).
    /// Prefer `item.isBrowsableFolder` when a `FileItem` is already loaded.
    static func isBrowsableFolder(_ url: URL) -> Bool {
        // Fast path: .app is never browsable as a folder.
        if url.pathExtension.lowercased() == "app" { return false }
        // fileExists follows symlinks (including /tmp → /private/tmp style links).
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return !isPackageDirectory(ModelPaths.realPath(url) ?? url)
    }

    /// Whether opening this item (a double-click, Return, Open) shows it as a
    /// folder. A link listing didn't follow (`isLinkNotFollowed`) is followed
    /// now, as Finder does on a user's action: the user asked for it, so
    /// whatever it mounts is theirs to mount. Anything else is decided by the
    /// listing (`isBrowsableFolder`), with no look at the disk.
    func opensAsFolder(isFolder: (URL) -> Bool = FileItem.isBrowsableFolder) -> Bool {
        isLinkNotFollowed ? isFolder(url) : isBrowsableFolder
    }

    /// `shownAs` is the path the item is presented under when `url` was listed
    /// through a symlinked parent (see `loadItems`); defaults to `url`.
    /// `isSafeLink` says whether the symlink at a path may be followed (the
    /// tests swap it). By default it's walked from the folder holding it
    /// (AutomountGuard.isSafeLink(atPath:)). That folder wasn't necessarily
    /// opened by Selway (a Spotlight result's), but it is sound to start
    /// there: the item's own path has been resolved before the guard is
    /// asked, every folder in it included (by `resourceValues` below for a
    /// fresh URL such as Spotlight's, or by the listing a URL came from), so
    /// whatever that path mounts is mounted already, and resolving it again
    /// mounts nothing new. What the walk looks up beyond that folder gets the
    /// guard's checks (AutomountGuard.Seed). A walk from "/" would add no
    /// safety, only refuse every link whose own path is under /home or /net.
    static func load(from url: URL, shownAs: URL? = nil,
                     isSafeLink: (String) -> Bool = { AutomountGuard.isSafeLink(atPath: $0) }) -> FileItem? {
        guard let v = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
        let ext = url.pathExtension.lowercased()
        var isDir = v.isDirectory ?? false
        #if os(macOS)
        let labelNumber = v.labelNumber ?? 0
        var isPkg = v.isPackage ?? (ext == "app")
        #else
        let labelNumber = 0
        var isPkg = isDir && ext == "app"
        #endif
        // Following a link looks its target up, and one into an automount folder
        // (/net/<host>, any autofs map) would mount that just by listing this
        // folder: such a link isn't followed, for its kind or its tags.
        let linkNotFollowed = v.isSymbolicLink == true && !isSafeLink(url.path)
        let tags = loadTags(url, labelNumber: labelNumber, followingLinks: !linkNotFollowed)
        // A symlink reports itself as a non-directory; treat it as whatever it points
        // at so links like ~/Downloads → /Volumes/… open as folders. `stat` follows
        // the link (resolvingSymlinksInPath would strip /private and land on another
        // link). Broken and looping links stay files.
        // The same `stat` gives the date and size a followed link's thumbnail is
        // keyed by (`targetModified`): not for a folder, which has none.
        var target: TargetStat?
        if v.isSymbolicLink == true && !linkNotFollowed {
            let found = targetStat(url.path)
            isDir = found?.isDirectory ?? false
            isPkg = isDir && (ModelPaths.realPath(url).map(isPackageDirectory) ?? false)
            if let found, !isDir || isPkg { target = found }
        } else if linkNotFollowed {
            isDir = false
            isPkg = false
        }
        // Only a plain file teaches the cache its extension's kind: Launch Services
        // calls a symlink or a Finder alias "Alias", and a link's target can have
        // another extension. Links and aliases use what plain files taught it.
        #if os(macOS)
        let isLinkOrAlias = v.isSymbolicLink == true || v.isAliasFile == true
        #else
        let isLinkOrAlias = v.isSymbolicLink == true
        #endif
        let kindProbe = isLinkOrAlias ? nil : url
        let url = shownAs ?? url
        let kind = fileKind(extension: ext, isDirectory: isDir, isPackage: isPkg, probe: kindProbe)
        return FileItem(
            id:            url.path,
            url:           url,
            name:          url.lastPathComponent,
            isDirectory:   isDir,
            isPackage:     isPkg,
            // Linux Foundation doesn't report dot-files as hidden; macOS already does.
            isHidden:      (v.isHidden ?? false) || url.lastPathComponent.hasPrefix("."),
            size:          Int64(v.fileSize ?? 0),
            dateModified:  v.contentModificationDate ?? .distantPast,
            dateCreated:   v.creationDate ?? .distantPast,
            kind:          kind,
            fileExtension: ext,
            labelNumber:   labelNumber,
            tags:          tags,
            isLinkNotFollowed: linkNotFollowed,
            targetModified: target?.modified,
            targetSize: target?.size
        )
    }

    /// "Folder", Finder's kind for the extension ("Plain Text Document",
    /// "Application"), or "TXT File" where Launch Services isn't there (Linux), has
    /// no answer, or hasn't seen a plain file with this extension yet (a link's).
    private static func fileKind(extension ext: String, isDirectory: Bool, isPackage: Bool, probe: URL?) -> String {
        if isDirectory && !isPackage {
            return NSLocalizedString("Folder", comment: "Kind description for a folder")
        }
        if ext.isEmpty {
            return NSLocalizedString("File", comment: "Kind description for a file without an extension")
        }
        #if canImport(Darwin)
        if let kind = KindCache.kind(forExtension: ext, probe: probe) { return kind }
        #endif
        return String.localizedStringWithFormat(
            NSLocalizedString("%1$@ File", comment: "Kind description for a file with its extension"),
            ext.uppercased())
    }

    #if canImport(Darwin)
    /// Finder's kind per extension, learnt from the first plain file that has it
    /// (a lookup costs about 0.1 ms on a local disk). An extension Launch Services
    /// can't describe is remembered too, so it isn't asked again. Listings load off
    /// the main thread, hence the lock; it isn't held while Launch Services is asked,
    /// so a slow network volume doesn't hold up other listings.
    private enum KindCache {
        private static let lock = NSLock()
        private static var kinds: [String: String?] = [:]

        static func kind(forExtension ext: String, probe: URL?) -> String? {
            lock.lock()
            let cached = kinds[ext]
            lock.unlock()
            if let cached { return cached }
            guard let probe else { return nil }
            let found = (try? probe.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?
                .localizedTypeDescription.flatMap { $0.isEmpty ? nil : $0 }
            lock.lock()
            defer { lock.unlock() }
            // Another listing may have asked meanwhile: an answer beats a failure.
            if case let .some(.some(earlier)) = kinds[ext] { return earlier }
            kinds[ext] = .some(found)
            return found
        }
    }
    #endif

    /// What `stat` says about where a link leads.
    private struct TargetStat {
        let isDirectory: Bool
        let modified: Date
        let size: Int64
    }

    /// `stat` of `path`, following links: nil when nothing is there (a broken
    /// or looping link).
    private static func targetStat(_ path: String) -> TargetStat? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        #if canImport(Darwin)
        let time = st.st_mtimespec
        #else
        let time = st.st_mtim
        #endif
        let modified = Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
        return TargetStat(isDirectory: st.st_mode & S_IFMT == S_IFDIR, modified: modified, size: Int64(st.st_size))
    }

    /// The stored tags, or for a file with only a legacy colour label, that
    /// colour's tag (as `tagNamesKey` reports it). Unreadable tags read as none.
    private static func loadTags(_ url: URL, labelNumber: Int, followingLinks: Bool) -> [FileTag] {
        if let entries = try? FinderTagStore.readEntries(atPath: url.path, followingLinks: followingLinks) {
            return entries.map(FileTag.init(entry:)).filter { !$0.name.isEmpty }
        }
        guard let name = labelToColorName[labelNumber] else { return [] }
        return [FileTag(name: name, color: labelNumber)]
    }

    /// Package check for a real (non-symlink) directory URL.
    private static func isPackageDirectory(_ url: URL) -> Bool {
        #if os(macOS)
        if let v = try? url.resourceValues(forKeys: [.isPackageKey]), let p = v.isPackage { return p }
        #endif
        return url.pathExtension.lowercased() == "app"
    }

    func dateCategory(now: Date = Date(), calendar: Calendar = .current) -> DateCategory {
        DateCategory.of(dateModified, now: now, calendar: calendar)
    }
    func dateCreatedCategory(now: Date = Date(), calendar: Calendar = .current) -> DateCategory {
        DateCategory.of(dateCreated, now: now, calendar: calendar)
    }
    var dateCategory: DateCategory { dateCategory() }
    var dateCreatedCategory: DateCategory { dateCreatedCategory() }

    /// Orders present "Group by Name" keys: A to Z, then other letters in the order
    /// of the user's language, then the gojuon rows, then #.
    static func orderedNameGroupKeys(_ keys: Set<String>, locale: Locale = .current) -> [String] {
        let latin = (UInt8(ascii: "A")...UInt8(ascii: "Z")).map { String(UnicodeScalar($0)) }
        let latinSet = Set(latin)
        let kanaRows = ["あ", "か", "さ", "た", "な", "は", "ま", "や", "ら", "わ"]
        let kanaSet = Set(kanaRows)
        let other = keys.filter { $0 != "#" && !latinSet.contains($0) && !kanaSet.contains($0) }.sorted {
            $0.compare($1, locale: locale) == .orderedAscending
        }
        return latin.filter(keys.contains) + other + kanaRows.filter(keys.contains)
            + (keys.contains("#") ? ["#"] : [])
    }

    /// "Group by Name" key: folded Latin initials ("é" → "E", fullwidth "Ａ" → "A"),
    /// or the capital of any other letter that has one ("й" → "Й", "æ" → "Æ", which
    /// Danish sorts after Z). Greek folds its accents too ("ά" → "Α"); other scripts
    /// keep theirs, since "й" is a letter of its own in Russian. Digits, symbols,
    /// other caseless scripts, Georgian (whose capitals are only for all-caps text), letters
    /// with no single capital ("ß") and blank names → "#".
    /// Kana go under their gojuon row (あ か さ ... わ). Kanji go under the row of the
    /// name's first word's reading, only on macOS and only when `language`, the
    /// language Selway runs in ("ja", "ja-JP"), is Japanese: Chinese users get no
    /// Japanese readings.
    func nameGroupKey(language: String) -> String {
        guard let first = name.first(where: { !$0.isWhitespace }) else { return "#" }
        if let kanaKey = Self.kanaRowKey(for: String(first)) { return kanaKey }
        #if canImport(Darwin)
        if Self.isJapanese(language), Self.isHan(first),
           let reading = JapaneseReading.of(name),
           let key = Self.kanaRowKey(for: reading) {
            return key
        }
        #endif
        return Self.letterGroupKey(first)
    }

    /// Whether a language identifier ("ja", "ja-JP", "ja_JP") is Japanese, and not
    /// merely one starting with "ja" ("jam").
    static func isJapanese(_ language: String) -> Bool {
        language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased() == "ja"
    }

    private static func letterGroupKey(_ first: Character) -> String {
        if let a = first.asciiValue {
            switch a {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): return String(first)
            case UInt8(ascii: "a")...UInt8(ascii: "z"): return String(UnicodeScalar(a - 32))
            default: return "#"
            }
        }
        let folded = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                           locale: Locale(identifier: "en_US_POSIX"))
        let foldedScalars = Array(folded.unicodeScalars)
        let foldedIsASCIIWord = !foldedScalars.isEmpty && foldedScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
        }
        if foldedIsASCIIWord {
            guard foldedScalars.count == 1, let a = foldedScalars.first else { return "#" }
            let value = a.value >= 97 ? a.value - 32 : a.value
            return String(UnicodeScalar(value)!)
        }
        let isGreek = first.unicodeScalars.first.map {
            (0x0370...0x03FF).contains($0.value) || (0x1F00...0x1FFF).contains($0.value)
        } ?? false
        let upper = (isGreek ? folded : String(first)).uppercased()
        let lower = String(first).lowercased()
        guard first.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }),
              first.unicodeScalars.allSatisfy({
                  CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
              }),
              upper.count == 1, upper != lower,
              lower.unicodeScalars.first?.properties.titlecaseMapping != lower else { return "#" }
        return upper
    }

    private static func kanaRowKey(for value: String) -> String? {
        let compatible = value.precomposedStringWithCompatibilityMapping
        guard !compatible.unicodeScalars.isEmpty else { return nil }
        var hiragana = String.UnicodeScalarView()
        for scalar in compatible.unicodeScalars {
            let value = scalar.value
            if (0x30A1...0x30F6).contains(value), let mapped = UnicodeScalar(value - 0x60) {
                hiragana.append(mapped)
            } else if (0x30F7...0x30FA).contains(value),
                      let mapped = UnicodeScalar(value - 0x68) {
                hiragana.append(mapped)
            } else if let mapped = phoneticExtensionByScalar[value] {
                hiragana.append(mapped)
            } else {
                hiragana.append(scalar)
            }
        }
        let decomposed = String(hiragana).decomposedStringWithCanonicalMapping
        guard let base = decomposed.unicodeScalars.first(where: {
            !CharacterSet.nonBaseCharacters.contains($0)
        }) else { return nil }
        let value = base.value
        guard (0x3041...0x3096).contains(value) else { return nil }
        return Self.kanaRowByScalar[value]
    }

    private static let kanaRowByScalar: [UInt32: String] = [
        0x3041: "あ", 0x3042: "あ", 0x3043: "あ", 0x3044: "あ", 0x3045: "あ", 0x3046: "あ",
        0x3047: "あ", 0x3048: "あ", 0x3049: "あ", 0x304A: "あ", 0x304B: "か", 0x304C: "か",
        0x304D: "か", 0x304E: "か", 0x304F: "か", 0x3050: "か", 0x3051: "か", 0x3052: "か",
        0x3053: "か", 0x3054: "か", 0x3055: "さ", 0x3056: "さ", 0x3057: "さ", 0x3058: "さ",
        0x3059: "さ", 0x305A: "さ", 0x305B: "さ", 0x305C: "さ", 0x305D: "さ", 0x305E: "さ",
        0x305F: "た", 0x3060: "た", 0x3061: "た", 0x3062: "た", 0x3063: "た", 0x3064: "た",
        0x3065: "た", 0x3066: "た", 0x3067: "た", 0x3068: "た", 0x3069: "た", 0x306A: "な",
        0x306B: "な", 0x306C: "な", 0x306D: "な", 0x306E: "な", 0x306F: "は", 0x3070: "は",
        0x3071: "は", 0x3072: "は", 0x3073: "は", 0x3074: "は", 0x3075: "は", 0x3076: "は",
        0x3077: "は", 0x3078: "は", 0x3079: "は", 0x307A: "は", 0x307B: "は", 0x307C: "は",
        0x307D: "は", 0x307E: "ま", 0x307F: "ま", 0x3080: "ま", 0x3081: "ま", 0x3082: "ま",
        0x3083: "や", 0x3084: "や", 0x3085: "や", 0x3086: "や", 0x3087: "や", 0x3088: "や",
        0x3089: "ら", 0x308A: "ら", 0x308B: "ら", 0x308C: "ら", 0x308D: "ら", 0x308E: "わ",
        0x308F: "わ", 0x3090: "わ", 0x3091: "わ", 0x3092: "わ", 0x3093: "わ", 0x3094: "あ",
        0x3095: "か", 0x3096: "か",
    ]

    private static let phoneticExtensionByScalar: [UInt32: UnicodeScalar] = [
        0x31F0: "く", 0x31F1: "し", 0x31F2: "す", 0x31F3: "と",
        0x31F4: "ぬ", 0x31F5: "は", 0x31F6: "ひ", 0x31F7: "ふ",
        0x31F8: "へ", 0x31F9: "ほ", 0x31FA: "む", 0x31FB: "ら",
        0x31FC: "り", 0x31FD: "る", 0x31FE: "れ", 0x31FF: "ろ",
    ]

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x20000...0x3134F).contains(scalar.value)
        }
    }

    #if canImport(Darwin)
    /// The reading of the name's first word in hiragana ("写真.jpg" → "しゃしん"), or nil.
    /// One tokenizer serves every call: creating one per name took about 0.2 ms, which
    /// made grouping a folder of thousands of names visibly slow; reused, it's about 6 µs.
    private enum JapaneseReading {
        private static let lock = NSLock()
        private static let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, "" as CFString, CFRange(location: 0, length: 0),
            kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale)

        static func of(_ name: String) -> String? {
            let text = name as CFString
            lock.lock()
            defer { lock.unlock() }
            guard let tokenizer else { return nil }
            // The tokenizer reads `text` again in the calls after SetString.
            return withExtendedLifetime(text) {
                CFStringTokenizerSetString(tokenizer, text, CFRange(location: 0, length: CFStringGetLength(text)))
                guard CFStringTokenizerAdvanceToNextToken(tokenizer) != [],
                      let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                          tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
                      !latin.isEmpty else { return nil }
                return latin.applyingTransform(.latinToHiragana, reverse: false)
            }
        }
    }
    #endif

    // Standard color name → label number, mirrors macOS Finder.
    static let colorNameToLabel: [String: Int] = [
        "gray": 1, "green": 2, "purple": 3, "blue": 4,
        "yellow": 5, "red": 6, "orange": 7
    ]
    static let labelToColorName: [Int: String] = [
        1: "Gray", 2: "Green", 3: "Purple", 4: "Blue",
        5: "Yellow", 6: "Red", 7: "Orange"
    ]

    // Order the 7 standard colors are presented in the Tags menu (matches Finder).
    static let colorMenuOrder = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]
    static let colorMenuNumbers = [6, 7, 5, 2, 4, 3, 1]

    /// True when this item carries the standard tag for `color` (see
    /// TagColorNames.isStandard), as the Tags menu shows it checked.
    func hasColorTag(_ color: Int, names: TagColorNames = .english) -> Bool {
        tags.contains { names.isStandard($0, color: color) }
    }

    /// `hasColorTag` by English colour name ("red", "Red").
    func hasColorTag(_ name: String) -> Bool {
        guard let color = FileItem.colorNameToLabel[name.lowercased()] else { return false }
        return hasColorTag(color)
    }

    /// The colours of the item's tag dots, in the order the tags are stored:
    /// the colour stored with each tag, so renamed and custom coloured tags get
    /// theirs (see FileTag.displayColor). Falls back to the legacy label when
    /// no tag has a colour.
    var tagColorNumbers: [Int] {
        let colors = tags.map(\.displayColor).filter { $0 != 0 }
        if !colors.isEmpty { return colors }
        return FileItem.labelToColorName[labelNumber] == nil ? [] : [labelNumber]
    }

    /// The names VoiceOver reads for the tag dots (TagDotsView): the tags',
    /// or, for a dot from a legacy colour label alone (a tags attribute with
    /// no names beside it), that colour's.
    var spokenTagNames: [String] {
        if !tagNames.isEmpty { return tagNames }
        return tagColorNumbers.compactMap { FileItem.labelToColorName[$0] }
    }

    /// Archives Selway extracts itself (zip and tarballs), the only items
    /// offered "Extract Here". Disk images, installer packages, .7z/.rar and
    /// bare .gz files are not: "extracting" those meant opening them with their
    /// default app, and a .pkg opens Installer.
    var isArchive: Bool {
        !isDirectory && FileOpsArchive.kind(forName: name) != nil
    }
}

// MARK: - Loading

/// List `url`'s children. Lists the path directly so children keep the path the
/// user opened; only when that fails with ENOTDIR (a symlinked folder) does it
/// list the link's real target and re-parent the children under `url`.
/// Unreadable, missing, broken or looping paths → [].
/// `fileSystem` is what AutomountGuard's walk of each link uses (the tests swap it).
func loadItems(at url: URL, showHidden: Bool,
               fileSystem: AutomountGuard.FileSystem = .live,
               timeMachineBackups: TimeMachineBackups = .live) -> [FileItem] {
    // A Time Machine disk lists its backups (everything at its root is hidden).
    if !showHidden, let destination = timeMachineBackups.destination(at: url), !destination.backups.isEmpty {
        return destination.backups.map(FileItem.timeMachineBackup)
    }
    let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
    let keys = FileItem.resourceKeys
    let fm = FileManager.default
    func listRealTarget() -> [URL] {
        guard let real = ModelPaths.realPath(url), real.path != url.path else { return [] }
        return (try? fm.contentsOfDirectory(at: real, includingPropertiesForKeys: keys, options: opts)) ?? []
    }
    var urls: [URL]
    do {
        urls = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: opts)
        // swift-corelibs-foundation (Linux) returns [] instead of ENOTDIR for a
        // symlinked folder; an empty listing costs one lstat to rule that out.
        if urls.isEmpty, (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            urls = listRealTarget()
        }
    } catch where ModelPaths.isNotDirectoryError(error) {
        urls = listRealTarget()
    } catch {
        return []
    }
    var items: [FileItem] = []
    items.reserveCapacity(urls.count)
    let parent = url.path
    // The folder was just listed, so its links are walked from it (made ready
    // at the first link): only where each one leads is checked.
    let seed = AutomountGuard.Seed(folder: parent, fileSystem: fileSystem)
    for child in urls {
        // Foundation sometimes lists an absolute link's children under the target
        // path even when the direct listing succeeds — re-parent those too. The
        // child URL already knows whether it's a directory, so no extra stat.
        let shown = child.deletingLastPathComponent().path == parent
            ? nil
            : url.appendingPathComponent(child.lastPathComponent, isDirectory: child.hasDirectoryPath)
        if let item = FileItem.load(from: child, shownAs: shown, isSafeLink: seed.allowsLink(atPath:)) {
            items.append(item)
        }
    }
    return items
}

// MARK: - Path helpers

enum ModelPaths {
    /// `url` as a new URL, for reading a file again: a URL keeps the resource
    /// values Foundation read for it (a listing's prefetched keys included), so
    /// asking the same URL again gives the size and dates it had then. Says
    /// whether it's a folder from `url`, so making it looks nothing up.
    static func fresh(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
    }

    /// Fully resolved path via realpath(3). Unlike `resolvingSymlinksInPath`, it
    /// doesn't strip a leading /private (which can land on another symlink such as
    /// /tmp or /var). nil for broken / looping / missing paths.
    static func realPath(_ url: URL) -> URL? {
        guard let p = realpath(url.path, nil) else { return nil }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p), isDirectory: url.hasDirectoryPath)
    }

    /// Present `url` (found under `realRoot`) under `logicalRoot` instead — e.g.
    /// /Volumes/T7/Users/me/Downloads/a.pdf → ~/Downloads/a.pdf. URLs outside
    /// `realRoot` are returned unchanged.
    static func rebase(_ url: URL, from realRoot: URL, to logicalRoot: URL) -> URL {
        let root = realRoot.path
        let path = url.path
        guard root != logicalRoot.path else { return url }
        if path == root { return logicalRoot }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return url }
        return logicalRoot.appendingPathComponent(String(path.dropFirst(prefix.count)),
                                                  isDirectory: url.hasDirectoryPath)
    }

    static func isNotDirectoryError(_ error: Error) -> Bool {
        var e: NSError? = error as NSError
        while let ns = e {
            if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOTDIR) { return true }
            e = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
