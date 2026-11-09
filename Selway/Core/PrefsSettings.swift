import Foundation

// Settings added with the tabbed Settings window (General, Browse, Advanced).
// Every key keeps the `selway` prefix; older keys (`UserPreferences`,
// `EditorFontSize.key`, `TextFileDetector.sniffUnknownKey`, …) are unchanged, so
// existing settings carry over. A missing or unreadable value counts as the
// default, so a hand-edited plist can't leave a picker without a selection.

extension UserDefaults {
    /// The stored Boolean, read as `@AppStorage` reads it (so "YES" or 1 from
    /// the command line counts), or `fallback` when nothing is stored.
    func bool(forKey key: String, default fallback: Bool) -> Bool {
        object(forKey: key) == nil ? fallback : bool(forKey: key)
    }
}

/// Keyboard shortcuts written out for VoiceOver hints: "⌥⌘⌫" is read as
/// "Option-Command-Delete". The visible captions keep the symbols.
enum KeyNames {
    private static let modifiers: [Character: String] = [
        "⌃": NSLocalizedString("Control", tableName: "KeyNames", comment: "Spoken name of the Control key in a shortcut"),
        "⌥": NSLocalizedString("Option", tableName: "KeyNames", comment: "Spoken name of the Option key in a shortcut"),
        "⇧": NSLocalizedString("Shift", tableName: "KeyNames", comment: "Spoken name of the Shift key in a shortcut"),
        "⌘": NSLocalizedString("Command", tableName: "KeyNames", comment: "Spoken name of the Command key in a shortcut"),
    ]
    private static let keys: [Character: String] = [
        "⌫": NSLocalizedString("Delete", tableName: "KeyNames", comment: "Spoken name of the Delete key in a shortcut"),
        "⌦": NSLocalizedString("Forward Delete", tableName: "KeyNames", comment: "Spoken name of the Forward Delete key in a shortcut"),
        "↩": NSLocalizedString("Return", tableName: "KeyNames", comment: "Spoken name of the Return key in a shortcut"),
        "⎋": NSLocalizedString("Escape", tableName: "KeyNames", comment: "Spoken name of the Escape key in a shortcut"),
        "⇥": NSLocalizedString("Tab", tableName: "KeyNames", comment: "Spoken name of the Tab key in a shortcut"),
        "↑": NSLocalizedString("Up Arrow", tableName: "KeyNames", comment: "Spoken name of the Up Arrow key in a shortcut"),
        "↓": NSLocalizedString("Down Arrow", tableName: "KeyNames", comment: "Spoken name of the Down Arrow key in a shortcut"),
        "←": NSLocalizedString("Left Arrow", tableName: "KeyNames", comment: "Spoken name of the Left Arrow key in a shortcut"),
        "→": NSLocalizedString("Right Arrow", tableName: "KeyNames", comment: "Spoken name of the Right Arrow key in a shortcut"),
        "+": NSLocalizedString("Plus", tableName: "KeyNames", comment: "Spoken name of the Plus key in a shortcut"),
        "−": NSLocalizedString("Minus", tableName: "KeyNames", comment: "Spoken name of the Minus key in a shortcut"),
        "-": NSLocalizedString("Minus", tableName: "KeyNames", comment: "Spoken name of the Minus key in a shortcut"),
        "=": NSLocalizedString("Equals", tableName: "KeyNames", comment: "Spoken name of the Equals key in a shortcut"),
        ".": NSLocalizedString("Period", tableName: "KeyNames", comment: "Spoken name of the Period key in a shortcut"),
        ",": NSLocalizedString("Comma", tableName: "KeyNames", comment: "Spoken name of the Comma key in a shortcut"),
        "/": NSLocalizedString("Slash", tableName: "KeyNames", comment: "Spoken name of the Slash key in a shortcut"),
        "[": NSLocalizedString("Left Bracket", tableName: "KeyNames", comment: "Spoken name of the Left Bracket key in a shortcut"),
        "]": NSLocalizedString("Right Bracket", tableName: "KeyNames", comment: "Spoken name of the Right Bracket key in a shortcut"),
    ]

    /// `text` with each shortcut (modifier symbols and the key after them)
    /// spelled out, and a menu path's "→" read as a comma ("Edit, Undo").
    static func spoken(_ text: String) -> String {
        var out = ""
        var chars = Array(text.replacingOccurrences(of: " → ", with: ", "))[...]
        while let c = chars.first {
            guard modifiers[c] != nil else { out.append(c); chars = chars.dropFirst(); continue }
            var words: [String] = []
            while let m = chars.first, let name = modifiers[m] { words.append(name); chars = chars.dropFirst() }
            if let key = chars.first, !key.isWhitespace {
                words.append(keys[key] ?? String(key).uppercased())
                chars = chars.dropFirst()
            }
            out += words.joined(separator: "-")
        }
        return out
    }
}

/// Where a new browser window starts (Settings → General → New windows open).
enum NewWindowFolder: String, CaseIterable, Sendable {
    case home, desktop, documents, downloads
    /// The folder last shown in any window (the newest Recent entry).
    case last
    /// A folder the user chose (`customPathKey`).
    case custom

    static let key           = "selwayNewWindowFolder"
    static let customPathKey = "selwayNewWindowCustomFolder"
    static let defaultValue: NewWindowFolder = .home

    static func fromStorage(_ raw: String?) -> NewWindowFolder {
        raw.flatMap(NewWindowFolder.init(rawValue:)) ?? defaultValue
    }

    var title: String {
        switch self {
        case .home:      return NSLocalizedString("Home", comment: "New Window folder choice")
        case .desktop:   return NSLocalizedString("Desktop", comment: "New Window folder choice")
        case .documents: return NSLocalizedString("Documents", comment: "New Window folder choice")
        case .downloads: return NSLocalizedString("Downloads", comment: "New Window folder choice")
        case .last:      return NSLocalizedString("The last folder shown", comment: "New Window folder choice")
        case .custom:    return NSLocalizedString("A folder you choose", comment: "New Window folder choice")
        }
    }

    /// The folder a new window shows. Anything that isn't a folder right now (an
    /// unmounted volume, a deleted folder, no recent folder yet) falls back to
    /// Home, so a window always opens somewhere real.
    static func resolve(_ choice: NewWindowFolder, customPath: String?, recentPaths: [String],
                        home: URL, isFolder: (String) -> Bool,
                        isUnchecked: (String) -> Bool = { RecentFolders.isUnchecked($0) }) -> URL {
        let candidate: String?
        switch choice {
        case .home:      candidate = nil
        case .desktop:   candidate = home.appendingPathComponent("Desktop").path
        case .documents: candidate = home.appendingPathComponent("Documents").path
        case .downloads: candidate = home.appendingPathComponent("Downloads").path
        case .last:      candidate = recentPaths.first { !$0.isEmpty && !isUnchecked($0) && isFolder($0) }
        case .custom:
            candidate = customPath.flatMap { path in
                path.isEmpty || isUnchecked(path) ? nil : path
            }
        }
        guard let path = candidate, isFolder(path) else { return home }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// `resolve` with the stored choice; `recentKey` is the sidebar's Recent list.
    static func resolve(_ defaults: UserDefaults, home: URL, recentKey: String = RecentFolders.defaultsKey,
                        isFolder: (String) -> Bool) -> URL {
        resolve(fromStorage(defaults.string(forKey: key)),
                customPath: defaults.string(forKey: customPathKey),
                recentPaths: defaults.stringArray(forKey: recentKey) ?? [],
                home: home, isFolder: isFolder)
    }
}

/// What opening a folder in the file list does (Settings → General). Clicking a
/// sidebar row or the path bar always stays in the window, as in Finder.
enum FolderOpenTarget: String, CaseIterable, Sendable {
    case sameWindow, newWindow, newTab

    static let key = "selwayOpenFoldersIn"
    static let defaultValue: FolderOpenTarget = .sameWindow

    static func fromStorage(_ raw: String?) -> FolderOpenTarget {
        raw.flatMap(FolderOpenTarget.init(rawValue:)) ?? defaultValue
    }

    var title: String {
        switch self {
        case .sameWindow: return NSLocalizedString("The same window", comment: "Folder open target choice")
        case .newWindow:  return NSLocalizedString("A new window", comment: "Folder open target choice")
        case .newTab:     return NSLocalizedString("A new tab", comment: "Folder open target choice")
        }
    }

    /// Where ShellOpenPlan sends the folders opened.
    var destination: ShellFolderDestination {
        switch self {
        case .sameWindow: return .here
        case .newWindow:  return .newWindows
        case .newTab:     return .newTabs
        }
    }
}

/// Browse, Advanced and Integrations settings that are a plain on/off.
enum SettingsKeys {
    /// The status bar under the file list; on by default.
    static let showStatusBar         = "selwayShowStatusBar"
    /// Ask before a rename changes, adds or removes a file's extension (Finder's default).
    static let warnExtensionChange   = "selwayWarnExtensionChange"
    /// The scope a new search starts in.
    static let defaultSearchScope    = "selwaySearchDefaultScope"
    static let editorWrap            = "selwayEditorWrap"
    static let editorSublimeKeys     = "selwayEditorSublimeKeys"
    static let editorMinimap         = "selwayEditorMinimap"

    /// Whether each IDE button is shown (toolbar and Selway menu) when installed.
    static func showTool(_ id: String) -> String { "selwayShowTool." + id }
}

extension SearchScope {
    /// The scopes offered as the default in Settings: the two ends, as in Finder.
    static let defaultChoices: [SearchScope] = [.thisFolder, .entireMac]

    /// The stored default scope; anything else (or nothing) is This Folder.
    static func defaultScope(_ defaults: UserDefaults = .standard) -> SearchScope {
        defaults.string(forKey: SettingsKeys.defaultSearchScope).flatMap(SearchScope.init(rawValue:))
            .flatMap { defaultChoices.contains($0) ? $0 : nil } ?? .thisFolder
    }
}

// MARK: - Reset all settings

enum SettingsReset {
    /// Keys under the `selway` prefix that aren't settings: one-time migration
    /// and first-run flags (resetting them would re-run the migration or the
    /// welcome sheet) and caches.
    static let keptPrefixes = [
        "selwayBrowseDefaultsMigrated",
        UserPreferences.didShowFirstRunKey,
        "selwayAppDetectionCache",
    ]

    /// The keys of `all` that Reset All Settings removes. Pinned and recent
    /// folders are the user's data, not settings, and have no `selway` prefix;
    /// "launchAtLogin" mirrors the system's login item, which Reset leaves alone.
    static func keysToRemove(from all: [String]) -> [String] {
        all.filter { key in key.hasPrefix("selway") && !keptPrefixes.contains { key.hasPrefix($0) } }
            .sorted()
    }

    /// Removes every setting and writes the Finder-like browse defaults back, so
    /// the next launch doesn't take a missing sort for an old install. Returns
    /// the keys removed.
    @discardableResult
    static func resetAll(_ defaults: UserDefaults, domain: String?) -> [String] {
        let all = domain.flatMap { defaults.persistentDomain(forName: $0) }.map { Array($0.keys) }
            ?? Array(defaults.dictionaryRepresentation().keys)
        let keys = keysToRemove(from: all)
        keys.forEach(defaults.removeObject(forKey:))
        UserPreferences.applyFactoryBrowseDefaults(defaults)
        return keys
    }
}
