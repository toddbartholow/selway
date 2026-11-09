import SwiftUI
import AppKit

// MARK: - Detected IDE/tool state

struct InstalledApps {
    var vscode:     NSImage? = nil   // nil → not installed, don't show button
    var vscodePath: String?  = nil   // resolved app path for VS Code
    var claude:     NSImage? = nil
    var claudeCLI:  String?  = nil   // path to `claude` CLI
    var cursor:     NSImage? = nil
    var cursorPath: String?  = nil   // resolved app path for Cursor
    var codex:      NSImage? = nil
    var codexPath:  String?  = nil
}


/// A tool the browser can open a folder in (toolbar and Selway menu).
enum OpenTool: CaseIterable {
    case terminal, vscode, claude, cursor, codex

    var title: String {
        String(localized: "Open in \(shortTitle)", comment: "Toolbar and menu label for opening a folder in an app")
    }

    /// The toolbar item's name in the customization palette.
    var shortTitle: String {
        switch self {
        case .terminal: return "Terminal"
        case .vscode:   return "VS Code"
        case .claude:   return "Claude Code"
        case .cursor:   return "Cursor"
        case .codex:    return "Codex"
        }
    }
}

extension InstalledApps {
    /// What was found, for telling whether a check changed anything (icons
    /// aren't comparable).
    fileprivate var signature: [String] {
        [vscodePath, claudeCLI, cursorPath, codexPath].map { $0 ?? "" }
            + OpenTool.allCases.map { icon(for: $0) == nil ? "-" : "+" }
    }

    /// The tool's icon, nil when it isn't installed (Terminal always is).
    func icon(for tool: OpenTool) -> NSImage? {
        switch tool {
        case .terminal: return nil
        case .vscode:   return vscode
        case .claude:   return claude
        case .cursor:   return cursor
        case .codex:    return codex
        }
    }

    func has(_ tool: OpenTool) -> Bool { tool == .terminal || icon(for: tool) != nil }
}

// MARK: - IDE / tool detection

/// The IDEs and tools a folder can be opened in, shared by every window and the
/// Selway menu. Known apps show at once from a 6-hour cache; each browser window
/// re-checks in the background when it opens, as its toolbar used to.
final class InstalledAppsService: ObservableObject {
    static let shared = InstalledAppsService()

    @Published private(set) var apps = InstalledApps()
    /// The terminal app in use (Settings → Integrations), kept here so toolbars,
    /// which re-render often, don't ask LaunchServices each time.
    @Published private(set) var terminal = TerminalChoice.current()
    /// One check at a time for every window, and none again soon after one.
    private var detecting = false
    private var lastDetection: Date?
    private static let redetectAfter: TimeInterval = 5 * 60

    private var settingsSignature: [String] = []
    private var settingsObserver: NSObjectProtocol?

    private init() {
        loadCachedApps()
        // Settings → Integrations hides buttons and picks the terminal app, and
        // Advanced renames the delete buttons; the toolbars and the Selway menu
        // observe this service, so tell them.
        settingsSignature = Self.toolbarSettingsSignature()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let now = Self.toolbarSettingsSignature()
            if now != self.settingsSignature {
                self.settingsSignature = now
                self.terminal = TerminalChoice.current()
                self.objectWillChange.send()
            }
        }
    }

    private static func toolbarSettingsSignature() -> [String] {
        let d = UserDefaults.standard
        return OpenTool.allCases.map { $0.isEnabledInSettings ? "+" : "-" }
            + [d.string(forKey: TerminalChoice.key) ?? "", d.string(forKey: TerminalChoice.customPathKey) ?? ""]
            + [FileOpsDeleteDecision.title(for: .moveToTrash, prefs: FileOpsDeletePrefs(d)),
               FileOpsDeleteDecision.title(for: .deletePermanently, prefs: FileOpsDeletePrefs(d)),
               FileOpsDeletePrefs(d).commandDeleteTrashes ? "trash" : "delete"]
    }

    /// Published only when something was found or lost: every window's toolbar
    /// re-renders on a change.
    private func update(_ detected: InstalledApps) {
        if detected.signature != apps.signature { apps = detected }
    }

    // MARK: - App detection cache (UserDefaults, 6-hour TTL)

    private struct AppCache: Codable {
        let timestamp:  Double   // timeIntervalSince1970
        let vscodePath: String?
        let claudeCLI:  String?
        let claudeApp:  String?
        let cursorPath: String?
        let codexPath:  String?
        let codexCLI:   String?
    }
    private static let kCacheKey = "selwayAppDetectionCache.v2"
    private static let kCacheTTL: Double = 6 * 3600   // 6 hours

    private func loadCachedApps() {
        guard let data = UserDefaults.standard.data(forKey: Self.kCacheKey),
              let c    = try? JSONDecoder().decode(AppCache.self, from: data),
              Date().timeIntervalSince1970 - c.timestamp < Self.kCacheTTL
        else { return }

        let fm = FileManager.default
        var a  = InstalledApps()

        if let p = c.vscodePath, fm.fileExists(atPath: p) {
            a.vscodePath = p
            a.vscode     = NSWorkspace.shared.icon(forFile: p)
        }
        if let cli = c.claudeCLI, fm.fileExists(atPath: cli) {
            a.claudeCLI = cli
            if let app = c.claudeApp, fm.fileExists(atPath: app) {
                a.claude = NSWorkspace.shared.icon(forFile: app)
            } else {
                a.claude = NSImage(systemSymbolName: "brain.head.profile",
                                   accessibilityDescription: "Claude Code")
            }
        }
        if let p = c.cursorPath, fm.fileExists(atPath: p) {
            a.cursorPath = p
            a.cursor     = NSWorkspace.shared.icon(forFile: p)
        }
        if let p = c.codexPath, fm.fileExists(atPath: p) {
            a.codexPath = p
            a.codex     = NSWorkspace.shared.icon(forFile: p)
        } else if let cli = c.codexCLI, fm.fileExists(atPath: cli) {
            a.codex = NSImage(systemSymbolName: "terminal",
                              accessibilityDescription: "Codex")
        }
        update(a)
    }

    private func saveCachedApps(_ detected: InstalledApps, claudeApp: String?) {
        let c = AppCache(
            timestamp:  Date().timeIntervalSince1970,
            vscodePath: detected.vscodePath,
            claudeCLI:  detected.claudeCLI,
            claudeApp:  claudeApp,
            cursorPath: detected.cursorPath,
            codexPath:  detected.codexPath,
            codexCLI:   nil
        )
        if let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(data, forKey: Self.kCacheKey)
        }
    }

    // MARK: - App detection (background queue, no UI impact)

    /// Re-checks in the background (each browser window asks when it opens).
    func detectInstalledApps() {
        guard !detecting else { return }
        if let lastDetection, Date().timeIntervalSince(lastDetection) < Self.redetectAfter { return }
        detecting = true
        DispatchQueue.global(qos: .background).async {
            var detected = InstalledApps()

            // Returns the first matching app URL from bundle IDs or direct paths
            func appURL(bundleIDs: [String], appPaths: [String] = []) -> URL? {
                for bid in bundleIDs {
                    if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                        return u
                    }
                }
                for path in appPaths where FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
                return nil
            }

            func iconForApp(_ url: URL) -> NSImage {
                NSWorkspace.shared.icon(forFile: url.path)
            }

            // Find a CLI via login shell `which` — handles nvm, homebrew, etc.
            func whichCLI(_ name: String) -> String? {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-l", "-c", "which \(name) 2>/dev/null"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError  = Pipe()
                guard (try? p.run()) != nil else { return nil }
                p.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let result = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !result.isEmpty, FileManager.default.fileExists(atPath: result) else { return nil }
                return result
            }

            // Also check known fixed paths (fast, no shell spawn)
            func fixedCLI(_ paths: [String]) -> String? {
                paths.first { FileManager.default.fileExists(atPath: $0) }
            }

            // ── VS Code ───────────────────────────────────────────────────
            // Only show VS Code button when the VS Code *app* is installed (not CLI-only),
            // so we're sure we open VS Code and not Cursor's `code` shim.
            if let url = appURL(bundleIDs: ["com.microsoft.VSCode"],
                                appPaths: ["/Applications/Visual Studio Code.app"]) {
                detected.vscode     = iconForApp(url)
                detected.vscodePath = url.path
            }

            // ── Claude Code ───────────────────────────────────────────────
            // Only show the button when the `claude` CLI is actually installed.
            // Showing it without the CLI just confuses users (Terminal opens
            // but immediately shows "command not found").
            let claudeFixed = fixedCLI([
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
                "\(NSHomeDirectory())/.local/bin/claude",
                "\(NSHomeDirectory())/.claude/local/claude",
                "\(NSHomeDirectory())/.volta/bin/claude",
            ])
            let claudeCLIPath = claudeFixed ?? whichCLI("claude")
            let claudeAppURL  = appURL(
                bundleIDs: ["com.anthropic.claudefordesktop",
                            "com.anthropic.claude-mac",
                            "com.anthropic.claude"],
                appPaths:  ["/Applications/Claude.app"]
            )
            if let cliPath = claudeCLIPath {
                detected.claudeCLI = cliPath
                // Use Desktop app icon when available, else brain SF-symbol
                detected.claude = claudeAppURL.map { iconForApp($0) }
                    ?? NSImage(systemSymbolName: "brain.head.profile",
                               accessibilityDescription: "Claude Code")
            }

            // ── Cursor ───────────────────────────────────────────────────
            if let url = appURL(bundleIDs: ["com.todesktop.230313mzl4w4u92",
                                            "com.cursor.macos",
                                            "com.cursor.cursor"],
                                appPaths: ["/Applications/Cursor.app"]) {
                detected.cursor     = iconForApp(url)
                detected.cursorPath = url.path
            }

            // ── OpenAI Codex ─────────────────────────────────────────────
            if let url = appURL(bundleIDs: ["com.openai.codex",
                                            "com.openai.codex-desktop"],
                                appPaths: ["/Applications/Codex.app",
                                           "/Applications/OpenAI Codex.app"]) {
                detected.codex     = iconForApp(url)
                detected.codexPath = url.path
            } else {
                // Codex may be CLI-only
                let codexCLI = fixedCLI(["/usr/local/bin/codex", "/opt/homebrew/bin/codex"])
                    ?? whichCLI("codex")
                if codexCLI != nil {
                    detected.codex = NSImage(systemSymbolName: "terminal",
                                             accessibilityDescription: "Codex")
                }
            }

            let claudeAppPath = claudeAppURL?.path
            DispatchQueue.main.async {
                self.detecting = false
                self.lastDetection = Date()
                self.update(detected)
                // The chosen terminal may have been installed or deleted since.
                let terminal = TerminalChoice.current()
                if terminal != self.terminal { self.terminal = terminal }
                self.saveCachedApps(detected, claudeApp: claudeAppPath)
            }
        }
    }


    // MARK: - Open helpers

    /// Opens `url` (a folder) in `tool`; failures go to `onError`.
    @MainActor
    func open(_ tool: OpenTool, at url: URL, onError: @escaping @MainActor (String) -> Void) {
        switch tool {
        case .terminal:
            // Hand the folder to Terminal (like dropping it on Terminal's Dock icon):
            // nothing is typed, so no folder name can inject keystrokes.
            TerminalLauncher.open(url, onError: onError)
        case .vscode: openInVSCode(url, onError: onError)
        case .claude: openInClaudeCode(url, onError: onError)
        case .cursor: openInCursor(url, onError: onError)
        case .codex:  openInCodex(url, onError: onError)
        }
    }

    @MainActor
    private func openInVSCode(_ url: URL, onError: @escaping @MainActor (String) -> Void) {
        // Prefer opening via app bundle so we guarantee VS Code, not Cursor's `code` shim
        if let appPath = apps.vscodePath {
            openWithApp(url, appPath: appPath, appName: "VS Code", onError: onError)
        }
    }

    @MainActor
    private func openInClaudeCode(_ url: URL, onError: @escaping @MainActor (String) -> Void) {
        // Claude Code is a TUI — open a NEW Terminal window (which launches a
        // login shell, so PATH is fully configured including nvm / homebrew / npm).
        // Use the detected full CLI path when available, otherwise fall back to
        // the bare `claude` command which the login shell will resolve via PATH.
        TerminalLauncher.run(apps.claudeCLI ?? "claude", arguments: ["."], in: url, onError: onError)
    }

    @MainActor
    private func openInCursor(_ url: URL, onError: @escaping @MainActor (String) -> Void) {
        // Prefer app bundle — guarantees Cursor opens, not VS Code's code shim
        if let appPath = apps.cursorPath {
            openWithApp(url, appPath: appPath, appName: "Cursor", onError: onError)
            return
        }
        // Fallback: known Cursor CLIs
        let cliCandidates = [
            "/usr/local/bin/cursor",
            "/opt/homebrew/bin/cursor",
            "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
        ]
        if let cli = cliCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = [url.path]   // absolute, so never parsed as an option
            do { try p.run() } catch { onError(String(localized: "Couldn’t open Cursor: \(error.localizedDescription)", comment: "Error opening Cursor with the reason")) }
        }
    }

    @MainActor
    private func openInCodex(_ url: URL, onError: @escaping @MainActor (String) -> Void) {
        // App bundle takes priority
        if let appPath = apps.codexPath {
            openWithApp(url, appPath: appPath, appName: "Codex", onError: onError)
            return
        }
        // CLI (TUI) fallback — open in Terminal
        let cliCandidates = ["/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        if let cli = cliCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            TerminalLauncher.run(cli, in: url, onError: onError)
        }
    }

    @MainActor
    private func openWithApp(_ url: URL, appPath: String, appName: String,
                             onError: @escaping @MainActor (String) -> Void) {
        let report = onError
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: URL(fileURLWithPath: appPath),
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            guard let error else { return }
            let message = String(localized: "Couldn’t open \(appName): \(error.localizedDescription)", comment: "Error opening an application with its name and the reason")
            DispatchQueue.main.async { MainActor.assumeIsolated { report(message) } }
        }
    }
}

// MARK: - Terminal launching

/// Opens the terminal app chosen in Settings → Integrations (Terminal unless
/// changed, and Terminal when the chosen one is missing: TerminalChoice) at a
/// folder. Used by the toolbar and by `selway://terminal` requests forwarded
/// from the Finder extension.
///
/// Plain "Open in Terminal" hands the folder to the app, so nothing is typed.
/// Tools that need a command line (Claude Code, the Codex CLI) get a private
/// zsh script that changes to the folder and runs the tool. Terminal is told
/// with AppleScript's `do script` to type only the script's path into a new
/// window, so the user's login shell (which may be fish or tcsh, with their own
/// quoting rules) never sees the folder name. iTerm and Ghostty are handed the
/// script (as `run.command`) to open, which they run in a new window or tab;
/// with any other app chosen the tools run in Terminal, since an app that
/// opens the script without running it would leave the tool never started
/// (TerminalResolution.runMethod). Folders with control characters are refused.
@MainActor
enum TerminalLauncher {
    static func open(_ directory: URL, onError: @escaping @MainActor (String) -> Void) {
        // Terminal *runs* a script file it is asked to open, so only folders.
        guard FileOpsNaming.isDirectory(directory.resolvingSymlinksInPath()) else {
            onError(FileOpsError.notAFolder(directory.lastPathComponent).localizedDescription)
            return
        }
        let terminal = TerminalChoice.current()
        guard let app = terminal.url else {
            onError(String(localized: "Couldn’t find the Terminal app.", comment: "Terminal launch error"))
            return
        }
        NSWorkspace.shared.open([directory], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            let message = String(localized: "Couldn’t open \(terminal.name): \(error.localizedDescription)", comment: "Terminal launch error with application name and reason")
            DispatchQueue.main.async { MainActor.assumeIsolated { onError(message) } }
        }
    }

    static func run(_ executable: String, arguments: [String] = [], in directory: URL,
                    onError: @escaping @MainActor (String) -> Void) {
        let terminal = TerminalChoice.current()
        let prepared: FileOpsSafety.TerminalScript
        do {
            prepared = try FileOpsSafety.makeTerminalScript(
                cd: directory.path, run: executable, arguments: arguments,
                named: terminal.runMethod == .openScript ? "run.command" : "run")
        } catch {
            onError(error.localizedDescription)
            return
        }
        if terminal.runMethod == .openScript, let app = terminal.url {
            openScript(prepared, with: app, name: terminal.name, onError: onError)
            return
        }
        // `do script` without "in front window" always opens a new window/tab.
        let script = """
        tell application "Terminal"
            activate
            do script \(FileOpsSafety.appleScriptStringLiteral(prepared.typedCommand))
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let errors = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = errors
        let scriptFolder = prepared.directory
        p.terminationHandler = { proc in
            guard proc.terminationStatus != 0 else { return }
            try? FileManager.default.removeItem(at: scriptFolder)   // never ran
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = detail.isEmpty ? String(localized: "osascript failed.", comment: "Terminal launch error reason") : detail
            let message = String(localized: "Couldn’t open Terminal: \(reason)", comment: "Terminal launch error with reason")
            DispatchQueue.main.async { MainActor.assumeIsolated { onError(message) } }
        }
        do {
            try p.run()
        } catch {
            try? FileManager.default.removeItem(at: scriptFolder)
            onError(String(localized: "Couldn’t open Terminal: \(error.localizedDescription)", comment: "Terminal launch error with reason"))
        }
    }

    private static func openScript(_ prepared: FileOpsSafety.TerminalScript, with app: URL, name: String,
                                   onError: @escaping @MainActor (String) -> Void) {
        let scriptFolder = prepared.directory
        NSWorkspace.shared.open([prepared.script], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            try? FileManager.default.removeItem(at: scriptFolder)   // never ran
            let message = String(localized: "Couldn’t open \(name): \(error.localizedDescription)", comment: "Error opening a terminal application with its name and the reason")
            DispatchQueue.main.async { MainActor.assumeIsolated { onError(message) } }
        }
    }
}


// MARK: - Window toolbar

extension ViewMode {
    /// Finder's order, for the view switcher and View → as Icons ⌘1, List ⌘2, Columns ⌘3.
    static let finderOrder: [ViewMode] = [.icons, .list, .columns]

    var title: String {
        switch self {
        case .list:    return String(localized: "List", comment: "View mode name in the toolbar and View menu")
        case .icons:   return String(localized: "Icons", comment: "View mode name in the toolbar and View menu")
        case .columns: return String(localized: "Columns", comment: "View mode name in the toolbar and View menu")
        }
    }

    var menuTitle: String {
        switch self {
        case .icons:   return String(localized: "as Icons", comment: "View mode menu choice")
        case .list:    return String(localized: "as List", comment: "View mode menu choice")
        case .columns: return String(localized: "as Columns", comment: "View mode menu choice")
        }
    }
}

/// A browser window's toolbar, in the title bar as in Finder: Back / Forward and
/// Enclosing Folder before the title, then view, grouping and sort, the panels,
/// and the actions; the search field comes last (BrowserSearch). It can be
/// customized (View → Customize Toolbar…); the less used actions start in the
/// palette, and a narrow window moves what doesn't fit into the toolbar's »
/// menu. Each item is also in the menu bar.
///
/// Its inputs stay equal from one folder to the next, and each item reads the
/// settings and services it shows itself. Built from the window's state (the
/// folder, closures, `Binding(get:set:)`), every item was rebuilt and handed to
/// AppKit again on each navigation, which held up the sidebar's highlight.
struct BrowserToolbar: CustomizableToolbarContent {
    let actions:       BrowserActions
    /// The window's panes: the history and delete buttons look up the active
    /// pane in their own bodies, and observe its history or `hasSelection`.
    /// One object for the window's life, so a navigation, a selection or a
    /// pane switch doesn't change the toolbar's inputs.
    let panes:         BrowserPanes
    let apps:          InstalledApps
    /// The tools found and turned on in Settings → Integrations.
    let shownTools:    Set<OpenTool>
    let fileOps:       FileOperationsService

    var body: some CustomizableToolbarContent {
        navigationItems
        arrangementItems
        actionItems
        toolItems
    }

    // MARK: Navigation

    @ToolbarContentBuilder
    private var navigationItems: some CustomizableToolbarContent {
        ToolbarItem(id: "history", placement: .navigation) {
            HistoryButtons(panes: panes, actions: actions)
        }
        ToolbarItem(id: "goUp") {
            GoUpButton(panes: panes, actions: actions)
        }
    }

    // MARK: View, grouping, sort, panels

    @ToolbarContentBuilder
    private var arrangementItems: some CustomizableToolbarContent {
        ToolbarItem(id: "viewMode") { ViewModePicker() }
        ToolbarItem(id: "dualPane") { DualPaneToggle(panes: panes, actions: actions) }
        ToolbarItem(id: "groupBy") { GroupByMenu() }
        ToolbarItem(id: "sort") { SortMenu() }
        // Preview and Hidden Files start in the palette (the View and Selway menus
        // have them), leaving room for the search field at large text sizes.
        ToolbarItem(id: "preview", showsByDefault: false) { PreviewToggle() }
        // Always there, so customizing in another view keeps it; it only works in Columns.
        ToolbarItem(id: "columnTree") { ColumnTreeToggle() }
        ToolbarItem(id: "hidden", showsByDefault: false) { HiddenFilesToggle() }
    }

    // MARK: File actions

    @ToolbarContentBuilder
    private var actionItems: some CustomizableToolbarContent {
        ToolbarItem(id: "newFolder") {
            ToolbarButton("New Folder", "folder.badge.plus", help: "New Folder  ⌥⌘N") { actions.newFolder() }
        }
        ToolbarItem(id: "newFile", showsByDefault: false) {
            ToolbarButton("New Text File", "doc.badge.plus", help: "New Text File") { actions.newTextFile() }
        }
        // "delete" was Delete Permanently before Move to Trash existed; a toolbar
        // that had it now trashes, which Undo can reverse.
        ToolbarItem(id: "delete", showsByDefault: false) {
            DeleteToolbarButton(command: .moveToTrash, systemImage: "trash", panes: panes) {
                actions.moveToTrash()
            }
        }
        ToolbarItem(id: "deletePermanently", showsByDefault: false) {
            DeleteToolbarButton(command: .deletePermanently, systemImage: "xmark.bin", panes: panes) {
                actions.deletePermanently()
            }
        }
        ToolbarItem(id: "undo", showsByDefault: false) { UndoToolbarButton(fileOps: fileOps, redo: false) }
        ToolbarItem(id: "redo", showsByDefault: false) { UndoToolbarButton(fileOps: fileOps, redo: true) }
        ToolbarItem(id: "paste", showsByDefault: false) {
            PasteToolbarButton(fileOps: fileOps, panes: panes) { actions.pasteHere() }
        }
        ToolbarItem(id: "copyPath", showsByDefault: false) {
            ToolbarButton("Copy Path", "doc.on.clipboard.fill", help: "Copy the selected items’ paths, or this folder’s  ⌥⌘C") { actions.copyPath() }
        }
        ToolbarItem(id: "refresh", showsByDefault: false) {
            ToolbarButton("Refresh", "arrow.clockwise", help: "Refresh  ⌘R") { actions.refresh() }
        }
    }

    // MARK: Terminal and IDEs (only those found)

    @ToolbarContentBuilder
    private var toolItems: some CustomizableToolbarContent {
        ToolbarItem(id: "terminal") {
            ToolButton(tool: .terminal, icon: nil) { actions.openTool(.terminal) }
        }
        if let icon = apps.icon(for: .vscode), shownTools.contains(.vscode) {
            ToolbarItem(id: "vscode") { ToolButton(tool: .vscode, icon: icon) { actions.openTool(.vscode) } }
        }
        if let icon = apps.icon(for: .claude), shownTools.contains(.claude) {
            ToolbarItem(id: "claude") { ToolButton(tool: .claude, icon: icon) { actions.openTool(.claude) } }
        }
        if let icon = apps.icon(for: .cursor), shownTools.contains(.cursor) {
            ToolbarItem(id: "cursor") { ToolButton(tool: .cursor, icon: icon) { actions.openTool(.cursor) } }
        }
        if let icon = apps.icon(for: .codex), shownTools.contains(.codex) {
            ToolbarItem(id: "codex") { ToolButton(tool: .codex, icon: icon) { actions.openTool(.codex) } }
        }
    }
}

// MARK: - Toolbar items
//
// Each reads the preference or service it shows, so it updates on its own when
// that changes rather than with every change to the window.

private struct ViewModePicker: View {
    @AppStorage(UserPreferences.viewModeKey) private var viewModeRaw = UserPreferences.defaultViewMode.rawValue

    var body: some View {
        Picker("View", selection: Binding(get: { ViewMode.fromStorage(viewModeRaw) },
                                          set: { viewModeRaw = $0.rawValue })) {
            ForEach(ViewMode.finderOrder, id: \.self) { mode in
                Label(mode.title, systemImage: mode.icon).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .help("Show items as icons (⌘1), a list (⌘2) or columns (⌘3)")
        .accessibilityIdentifier("viewModePicker")
    }
}

private struct GroupByMenu: View {
    @AppStorage(UserPreferences.groupByKey) private var groupByRaw = UserPreferences.defaultGroupBy.rawValue

    var body: some View {
        let groupBy = GroupBy.fromStorage(groupByRaw)
        Menu {
            Picker("Group By", selection: Binding(get: { groupBy }, set: { groupByRaw = $0.rawValue })) {
                ForEach(GroupBy.allCases) { g in Text(g.displayName).tag(g) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(groupBy == .none ? "Group By" : "Grouped by \(groupBy.displayName)",
                  systemImage: groupBy == .none ? "rectangle.3.group" : "rectangle.3.group.fill")
        }
        .help(groupBy == .none ? "Group By" : "Grouped by \(groupBy.displayName)")
    }
}

private struct SortMenu: View {
    @AppStorage(UserPreferences.sortFieldKey)     private var sortFieldRaw   = UserPreferences.defaultSortField.rawValue
    @AppStorage(UserPreferences.sortAscendingKey) private var sortAscending  = UserPreferences.defaultSortAscending
    @AppStorage(UserPreferences.folderOrderKey)   private var folderOrderRaw = UserPreferences.defaultFolderOrder.rawValue

    var body: some View {
        let sortField = SortField.fromStorage(sortFieldRaw)
        let folderOrder = FolderOrder.fromStorage(folderOrderRaw)
        // Named after the current sort, like Group By, so the » menu and the
        // customization palette say what it is; the status bar shows it too.
        Menu {
            Picker("Sort By", selection: Binding(get: { sortField }, set: { sortFieldRaw = $0.rawValue })) {
                ForEach(SortField.allCases) { f in Text(f.displayName).tag(f) }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: $sortAscending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .pickerStyle(.inline)
            Picker("Folders", selection: Binding(get: { folderOrder }, set: { folderOrderRaw = $0.rawValue })) {
                ForEach(FolderOrder.allCases) { o in Text(o.displayName).tag(o) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sorted by \(sortField.displayName)", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityValue(sortAscending ? Text("Ascending") : Text("Descending"))
        .help(sortAscending
              ? "Sorted by \(sortField.displayName), ascending; \(folderOrder.displayName)"
              : "Sorted by \(sortField.displayName), descending; \(folderOrder.displayName)")
    }
}

private struct PreviewToggle: View {
    @AppStorage(UserPreferences.showPreviewKey) private var showPreview = false

    var body: some View {
        Toggle(isOn: $showPreview) {
            Label("Preview", systemImage: showPreview ? "doc.richtext.fill" : "doc.richtext")
        }
        .help(showPreview ? "Hide the preview panel  ⇧⌘P" : "Show the preview panel  ⇧⌘P")
    }
}

private struct DualPaneToggle: View {
    let panes: BrowserPanes
    let actions: BrowserActions

    var body: some View {
        let help = panes.isDual
            ? String(localized: "Hide Dual Pane", comment: "Help tag of the Dual Pane toolbar button while two panes are shown")
            : String(localized: "Show Dual Pane", comment: "Help tag of the Dual Pane toolbar button while one pane is shown")
        // A constant name with an On/Off value, as VoiceOver reads a toggle;
        // the help tag says what a click does.
        Toggle(isOn: Binding(get: { panes.isDual }, set: { _ in actions.toggleDualPane() })) {
            Label(String(localized: "Dual Pane", comment: "Name of the toolbar button that shows or hides the second pane (also in Customize Toolbar)"),
                  systemImage: "rectangle.split.2x1")
        }
        .help(help)
        .accessibilityValue(panes.isDual
            ? Text("On", comment: "VoiceOver value of the Dual Pane toolbar button while two panes are shown")
            : Text("Off", comment: "VoiceOver value of the Dual Pane toolbar button while one pane is shown"))
        .accessibilityIdentifier("dualPaneToggle")
    }
}

private struct ColumnTreeToggle: View {
    @AppStorage(UserPreferences.showColumnTreeKey) private var showColumnTree = false
    @AppStorage(UserPreferences.viewModeKey)       private var viewModeRaw    = UserPreferences.defaultViewMode.rawValue

    var body: some View {
        let inColumns = ViewMode.fromStorage(viewModeRaw) == .columns
        Toggle(isOn: $showColumnTree) {
            Label("Folder Tree", systemImage: showColumnTree ? "sidebar.left" : "rectangle.split.1x2")
        }
        .help(!inColumns ? "Folder Tree (Columns view only)"
              : showColumnTree ? "Show only the current folder in columns"
                               : "Show every folder from the top in columns")
        .disabled(!inColumns)
    }
}

private struct HiddenFilesToggle: View {
    @AppStorage(UserPreferences.showHiddenKey) private var showHidden = false

    var body: some View {
        Toggle(isOn: $showHidden) {
            Label("Hidden Files", systemImage: showHidden ? "eye" : "eye.slash")
        }
        .help(showHidden ? "Hide hidden files  ⇧⌘." : "Show hidden files  ⇧⌘.")
    }
}

/// Back / Forward, for the active pane, looked up here: a pane switch
/// re-renders only these buttons. They observe its history themselves (it
/// changes on every navigation, and as toolbar inputs it re-rendered the toolbar).
private struct HistoryButtons: View {
    let panes: BrowserPanes
    let actions: BrowserActions

    var body: some View {
        PaneHistoryButtons(navigation: panes.active.navigation, actions: actions)
    }
}

private struct PaneHistoryButtons: View {
    @ObservedObject var navigation: BrowserNavigation
    let actions: BrowserActions

    var body: some View {
        ControlGroup {
            Button { actions.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                .help("Back  ⌘[")
                .disabled(!navigation.history.canGoBack)
            Button { actions.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                .help("Forward  ⌘]")
                .disabled(!navigation.history.canGoForward)
        } label: {
            Label("Back/Forward", systemImage: "chevron.left.chevron.right")
        }
    }
}

/// Enclosing Folder, for the active pane (as HistoryButtons).
private struct GoUpButton: View {
    let panes: BrowserPanes
    let actions: BrowserActions

    var body: some View {
        PaneGoUpButton(navigation: panes.active.navigation, actions: actions)
    }
}

private struct PaneGoUpButton: View {
    @ObservedObject var navigation: BrowserNavigation
    let actions: BrowserActions

    var body: some View {
        Button { actions.goUp() } label: { Label("Enclosing Folder", systemImage: "arrow.up") }
            .help("Enclosing Folder  ⌘↑")
            .disabled(!navigation.history.canGoUp)
    }
}

private struct ToolbarButton: View {
    let title: Text
    let systemImage: String
    let help: Text
    let action: () -> Void

    init(_ title: LocalizedStringKey, _ systemImage: String, help: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.help = Text(help)
        self.action = action
    }

    init(verbatim title: String, _ systemImage: String, help: String, action: @escaping () -> Void) {
        self.title = Text(verbatim: title)
        self.systemImage = systemImage
        self.help = Text(verbatim: help)
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label { title } icon: { Image(systemName: systemImage) }
        }
            .help(help)
    }
}

private struct UndoToolbarButton: View {
    @ObservedObject var fileOps: FileOperationsService
    let redo: Bool

    var body: some View {
        if redo {
            let title: LocalizedStringKey = fileOps.redoActionName.map { "Redo \($0)" } ?? "Redo"
            let help: LocalizedStringKey = fileOps.redoActionName.map { "Redo \($0)  ⇧⌘Z" } ?? "Redo  ⇧⌘Z"
            ToolbarButton(title, "arrow.uturn.forward", help: help) { fileOps.redo() }
                .disabled(!fileOps.canRedo)
        } else {
            let title: LocalizedStringKey = fileOps.undoActionName.map { "Undo \($0)" } ?? "Undo"
            let help: LocalizedStringKey = fileOps.undoActionName.map { "Undo \($0)  ⌘Z" } ?? "Undo  ⌘Z"
            ToolbarButton(title, "arrow.uturn.backward", help: help) { fileOps.undo() }
                .disabled(!fileOps.canUndo)
        }
    }
}

private struct PasteToolbarButton: View {
    @ObservedObject var fileOps: FileOperationsService
    let panes: BrowserPanes
    let action: () -> Void

    var body: some View {
        ToolbarButton("Paste", "doc.on.clipboard", help: "Paste into this folder", action: action)
            .disabled(panes.active.model.isReadOnlyLocation || fileOps.pasteboardURLs.isEmpty)
    }
}

/// Named and labelled for what it does now (Settings → Advanced): "Move to
/// Trash" or "Delete Permanently…", with the shortcut it has in the menu.
/// InstalledAppsService announces changes to those settings.
private struct DeleteToolbarButton: View {
    let command: FileOpsDeleteCommand
    let systemImage: String
    /// Read in `body`: the active pane, and whether it has a selection.
    let panes: BrowserPanes
    let action: () -> Void
    @ObservedObject private var settings = InstalledAppsService.shared

    var body: some View {
        let prefs = DeleteFlow.prefs
        let shortcut = FileOpsDeleteDecision.shortcut(for: command, prefs: prefs).symbols
        let title = FileOpsDeleteDecision.title(for: command, prefs: prefs)
        let help = String(localized: "\(title)  \(shortcut)", comment: "Delete toolbar tooltip with its keyboard shortcut")
        ToolbarButton(verbatim: title, systemImage, help: help, action: action)
            .disabled(panes.active.model.isReadOnlyLocation || !panes.active.model.hasSelection)
    }
}

/// Terminal (named after the app chosen in Settings → Integrations) or an IDE.
private struct ToolButton: View {
    let tool: OpenTool
    let icon: NSImage?
    let action: () -> Void
    @ObservedObject private var installed = InstalledAppsService.shared

    var body: some View {
        if let icon {
            Button(action: action) {
                Label {
                    Text(verbatim: tool.shortTitle)
                } icon: {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                }
            }
            .help(tool == .claude
                  ? String(localized: "Open in Claude Code (opens \(installed.terminal.runnerName))", comment: "Tooltip for opening a folder in Claude Code, including its terminal app")
                  : tool.title)
        } else {
            let title = String(localized: "Open in \(installed.terminal.name)", comment: "Toolbar label for opening a folder in the selected terminal app")
            ToolbarButton(verbatim: title, "terminal", help: title, action: action)
        }
    }
}
