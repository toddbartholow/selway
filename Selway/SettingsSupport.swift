import AppKit

// The app's side of settings whose logic lives in Core: reading them with the
// real file system, LaunchServices and UserDefaults.

extension NewWindowFolder {
    /// The folder a new browser window starts in.
    static func initialURL(_ defaults: UserDefaults = .standard) -> URL {
        resolve(defaults, home: FileManager.default.homeDirectoryForCurrentUser) { path in
            FileItem.isBrowsableFolder(URL(fileURLWithPath: path))
        }
    }

    /// A chosen folder as Settings shows it.
    struct Look {
        var name: String
        /// The guard lets it be looked at, so the open panel may start there.
        var isSafe: Bool
    }

    /// Folders being looked up. One on a share that has stopped answering
    /// holds its thread for good, so it isn't asked again while it does.
    @MainActor private static var lookingUp: Set<String> = []

    /// Looks `path` up on a thread of its own, not Swift's shared pool: the
    /// guard's walk and the display name can wait on a share for minutes,
    /// and a pool thread stuck in the kernel would be lost to every task in
    /// the app. Nil while an earlier look at it hasn't answered.
    @MainActor static func lookUp(_ path: String) async -> Look? {
        guard lookingUp.insert(path).inserted else { return nil }
        defer { lookingUp.remove(path) }
        return await withCheckedContinuation { continuation in
            let thread = Thread {
                let isSafe = !RecentFolders.isUnchecked(path)
                let name = isSafe ? FileManager.default.displayName(atPath: path) : (path as NSString).lastPathComponent
                continuation.resume(returning: Look(name: name, isSafe: isSafe))
            }
            thread.name = "studio.irq.selway.new-window-folder"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}

extension TerminalChoice {
    /// The terminal app to use now: the chosen one, or Terminal if it's missing.
    static func current(_ defaults: UserDefaults = .standard) -> TerminalResolution {
        resolve(fromStorage(defaults.string(forKey: key)), customPath: defaults.string(forKey: customPathKey))
    }

    /// `choice` resolved against the apps on this Mac.
    static func resolve(_ choice: TerminalApp, customPath: String?) -> TerminalResolution {
        resolve(choice, customPath: customPath,
                locate: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                isApp: { path in
                    var isDir: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                })
    }

    /// Whether a built-in choice is installed, for the Settings picker.
    static func isInstalled(_ app: TerminalApp) -> Bool {
        app.bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }
}

extension OpenTool {
    /// The settings key that shows or hides this tool's button; nil for Terminal,
    /// which is always available.
    var visibilityKey: String? {
        switch self {
        case .terminal: return nil
        case .vscode:   return SettingsKeys.showTool("vscode")
        case .claude:   return SettingsKeys.showTool("claude")
        case .cursor:   return SettingsKeys.showTool("cursor")
        case .codex:    return SettingsKeys.showTool("codex")
        }
    }

    /// Whether Settings → Integrations shows this tool (when it's installed).
    var isEnabledInSettings: Bool {
        guard let key = visibilityKey else { return true }
        return UserDefaults.standard.bool(forKey: key, default: true)
    }

    /// The menu title, naming the chosen terminal app ("Open in iTerm").
    var currentTitle: String {
        self == .terminal
            ? String(localized: "Open in \(InstalledAppsService.shared.terminal.name)", comment: "Menu title for opening a folder in the selected terminal app")
            : title
    }
}

extension InstalledApps {
    /// Installed, and not hidden in Settings → Integrations.
    func shows(_ tool: OpenTool) -> Bool { has(tool) && tool.isEnabledInSettings }
}
