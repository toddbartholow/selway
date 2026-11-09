import SwiftUI
import ServiceManagement

@main
struct SelwayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var favorites = FavoritesService()

    init() {
        #if SELWAY_UI_TESTING
        // Before any preference is read or window opens (UITestHooks).
        UITestHooks.applyLaunchArguments()
        #endif
        // Start listening for external "open this folder" requests before the
        // first window exists.
        _ = BrowserWindowRouter.shared
    }

    var body: some Scene {
        // Each window the router asks for is opened with the id of its request
        // (BrowserWindowRouter.open); File ▸ New Window and the Dock open one
        // with none, and a restored window brings back last session's.
        WindowGroup(id: BrowserWindowRouter.windowGroupID, for: UUID.self) { $requestID in
            ContentView(requestID: requestID)
                .environmentObject(favorites)
                .textSizeRoot()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // View → Show / Hide Toolbar and Customize Toolbar….
            ToolbarCommands()
            AboutCommands()
            BrowserFileCommands()
            SelwayCommands()
            BrowserEditCommands()
            BrowserViewCommands()
            TextSizeCommands()
            BrowserGoCommands()
            BrowserWindowCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Folder requested while launching before any window is ready (cold launch).
    /// ContentView consumes this on first appear.
    static var pendingNavigationURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UserPreferences.migrateBrowseDefaultsIfNeeded()
        TextSizeCommands.installEqualsShortcut()
        ToolbarSearchField.keepVisible()
        // Scripts for Claude Code / Codex that a terminal app never ran.
        #if SELWAY_UI_TESTING
        // Not under UI tests: the temporary folder is shared with the user's own copy.
        let cleanStaleScripts = !UITestHooks.isActive
        #else
        let cleanStaleScripts = true
        #endif
        if cleanStaleScripts {
            DispatchQueue.global(qos: .utility).async { FileOpsSafety.removeStaleTerminalScripts() }
        }
        // Starts Sparkle, which schedules its own automatic checks (Settings → General).
        _ = UpdateManager.shared
        // Saved servers with Reconnect at Launch on: quietly, in the background.
        // Not under UI tests, whose saved servers are made up.
        #if SELWAY_UI_TESTING
        if !UITestHooks.isActive { MainActor.assumeIsolated { ServerReconnect.atLaunch() } }
        #else
        MainActor.assumeIsolated { ServerReconnect.atLaunch() }
        #endif
        // Sync stored toggle with actual SMAppService registration state
        if #available(macOS 13.0, *) {
            let enabled = SMAppService.mainApp.status == .enabled
            UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon does what it would without the About and Acknowledgments
    /// windows (DockReopen). AppKit counts them as the app's windows: with only About
    /// showing it would just bring that forward, and with only Acknowledgments minimized
    /// it would restore that, where a browser window should come back or open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            let router = BrowserWindowRouter.shared
            let windows = sender.windows.filter { !($0 is NSPanel) }
            let action = DockReopen.action(for: windows.map { window in
                let kind: DockReopen.Window.Kind = router.isBrowserWindow(window) ? .browser
                    : AboutWindowController.isAboutOrAcknowledgments(window) ? .aboutOrAcknowledgments : .other
                return DockReopen.Window(kind: kind, isVisible: window.isVisible, isMinimized: window.isMiniaturized)
            }, canOpenWindows: router.openWindow != nil)
            switch action {
            case .standard:
                return true
            case .restore(let index):
                windows[index].deminiaturize(nil)
                windows[index].makeKeyAndOrderFront(nil)
                return false
            case .openBrowserWindow:
                router.openNewTab(at: nil)
                return false
            case .chooseNewWindow:
                BrowserWindowRouter.chooseNewWindow()
                return false
            }
        }
    }

    // MARK: - Quit with unsaved editor changes

    /// Asks Save / Don't Save / Cancel when the code editor or the Markdown editor
    /// has unsaved changes (Quit, logout, or the quit request Sparkle sends before installing
    /// an update; a cancelled quit leaves the update waiting until the app really exits).
    /// File operations still running are dealt with first (wait / stop / don't
    /// quit), so none is cut off half-way.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        RunningOperationsReview.applicationShouldTerminate(sender) {
            UnsavedChangesReview.applicationShouldTerminate(sender)
        }
    }

    // MARK: - Open folders / selway:// links

    /// Handles both file URLs (folder/file opened with Selway, e.g. "Open With",
    /// `open -a`, or being the default folder handler) and the custom `selway://`
    /// scheme posted by the Finder Sync extension.
    func application(_ application: NSApplication, open urls: [URL]) {
        // The current Apple event is only readable while it is being handled.
        let fromOwnExtension = Self.currentEventIsFromOwnExtension()
        for url in urls { handleOpen(url, fromOwnExtension: fromOwnExtension) }
    }

    private func handleOpen(_ url: URL, fromOwnExtension: Bool) {
        if url.isFileURL {
            openFileURL(url)
        } else if let request = FileOpsURLScheme.parse(url) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.perform(request, fromOwnExtension: fromOwnExtension) }
            }
        }
    }

    /// A file or folder the user opened with Selway. Packages (an .app) and
    /// other files Selway doesn't open itself are revealed in their folder,
    /// never launched (see FileOpsURLPolicy.decideOpen).
    private func openFileURL(_ url: URL) {
        guard let decision = FileOpsURLPolicy.decideOpen(url) else { return }
        DispatchQueue.main.async {
            switch decision {
            case .browse(let folder):           Self.navigate(to: folder)
            case .reveal(_, let folder):        Self.navigate(to: folder)
            case .markdown(let file):           MarkdownWindowManager.shared.open(file)
            case .editText(let file):           EditorWindowManager.shared.open(file)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// A `selway://` request. Any web page can fire these links, so they
    /// never launch apps or open documents: `open` only shows a location (a
    /// plain folder, or the folder enclosing anything else), and actions with
    /// side effects run directly only when Selway's own Finder extension
    /// sent them — otherwise the user is asked first (FileOpsURLPolicy).
    @MainActor
    private func perform(_ request: FileOpsURLRequest, fromOwnExtension: Bool) {
        switch FileOpsURLPolicy.decide(request, fromOwnExtension: fromOwnExtension) {
        case .ignore:
            return
        case .show(let folder):
            Self.navigate(to: folder)
            NSApp.activate(ignoringOtherApps: true)
        case let .perform(action, folder, confirm):
            // Pinned before asking: the folder can be swapped for another (or for a symlink
            // to one) while the dialog is up, and the action must run on the folder that was
            // approved or not at all.
            guard let approved = FileOpsURLPolicy.FolderIdentity(folder) else { return }
            if confirm {
                guard let question = FileOpsURLPolicy.confirmation(for: action, folder: folder),
                      Self.confirmLinkRequest(question) else { return }
            }
            // The dialog waited on the user: a link in the path may lead into
            // an automount folder now. Checked before anything follows it.
            guard AutomountGuard.isSafe(folder.path), approved.matches(folder) else {
                Self.showLinkError(String(localized: "The folder changed, so nothing was done.", comment: "External link action error title"),
                                   String(localized: "“\(FileOpsURLPolicy.displayPath(folder.path))” was moved, replaced or turned into a link after the request arrived.", comment: "External link action error with folder path"))
                return
            }
            switch action {
            case .open:
                Self.navigate(to: folder)
            case .newFolder:
                do {
                    _ = try FileOpsCreation.createFolder(in: folder, named: DefaultNames.newFolder)
                } catch {
                    Self.showLinkError(String(localized: "Couldn’t create a folder in “\(FileOpsURLPolicy.displayPath(folder.lastPathComponent))”.", comment: "External link folder creation error with folder name"),
                                       error.localizedDescription)
                }
            case .terminal:
                TerminalLauncher.open(folder) { message in
                    Self.showLinkError(String(localized: "Couldn’t open \(TerminalChoice.current().name).", comment: "External link Terminal error with app name"), message)
                }
            }
        }
    }

    private static func navigate(to folder: URL) {
        AppDelegate.pendingNavigationURL = folder
        NotificationCenter.default.post(name: .navigateToPath, object: folder)
    }

    /// True if the Apple event being handled was sent by an executable inside
    /// this app's PlugIns folder, i.e. the bundled Finder Sync extension.
    private static func currentEventIsFromOwnExtension() -> Bool {
        guard let event   = NSAppleEventManager.shared().currentAppleEvent,
              let pidDesc = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)),
              let plugIns = Bundle.main.builtInPlugInsURL?.resolvingSymlinksInPath().path
        else { return false }
        let pid = pid_t(pidDesc.int32Value)
        guard pid > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        return executable.hasPrefix(plugIns + "/")
    }

    /// Asks before acting on a selway:// link. Cancel is the default
    /// button, so a Return typed for another app (or held down) can't approve
    /// it, and the app doesn't take focus to show it: it asks for attention
    /// (the Dock icon bounces) instead.
    /// Any web page can fire selway:// links: their dialogs are rate-limited.
    @MainActor private static var linkPrompts = ShellLinkPromptLimiter()

    @MainActor
    private static func confirmLinkRequest(_ confirmation: FileOpsURLPolicy.Confirmation) -> Bool {
        guard linkPrompts.begin() else {
            NSLog("Selway: ignored a selway:// request: too many in a short time.")
            return false
        }
        defer { linkPrompts.end() }
        requestAttention(.criticalRequest)
        let alert = NSAlert()
        alert.messageText     = confirmation.question
        alert.informativeText = confirmation.detail
        let action = alert.addButton(withTitle: confirmation.button)
        let cancel = alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button to cancel"))
        action.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private static func requestAttention(_ kind: NSApplication.RequestUserAttentionType) {
        if !NSApp.isActive { NSApp.requestUserAttention(kind) }
    }

    @MainActor
    private static func showLinkError(_ title: String, _ detail: String) {
        guard linkPrompts.begin() else {
            NSLog("Selway: %@ %@", title, detail)
            return
        }
        defer { linkPrompts.end() }
        requestAttention(.informationalRequest)
        let alert = NSAlert()
        alert.alertStyle      = .warning
        alert.messageText     = title
        alert.informativeText = detail
        alert.runModal()
    }
}

struct SelwayCommands: Commands {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage(UserPreferences.showHiddenKey) private var showHidden = false
    @AppStorage(FileOpsDeletePrefs.commandDeleteTrashesKey)   private var commandDeleteTrashes   = true
    @AppStorage(FileOpsDeletePrefs.confirmTrashKey)           private var confirmTrash           = false
    @AppStorage(FileOpsDeletePrefs.confirmPermanentDeleteKey) private var confirmPermanentDelete = true
    /// Actions of the key browser window; nil when no browser window is key.
    @FocusedValue(\.browserActions) private var actions
    @FocusedValue(\.sidebarEjectVolume) private var ejectVolume
    @FocusedValue(\.overviewEjectVolume) private var overviewEjectVolume
    @ObservedObject private var installed = InstalledAppsService.shared
    @ObservedObject private var textInput = TextInputObserver.shared

    private var deletePrefs: FileOpsDeletePrefs {
        FileOpsDeletePrefs(commandDeleteTrashes: commandDeleteTrashes, confirmTrash: confirmTrash,
                           confirmPermanentDelete: confirmPermanentDelete)
    }

    var body: some Commands {
        CommandMenu("Selway") {
            Button("New Folder") { perform { $0.newFolder() } }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(actions == nil)

            Button("New Text File") { perform { $0.newTextFile() } }
                .disabled(actions == nil)

            Button(FileOpsDeleteDecision.title(for: .moveToTrash, prefs: deletePrefs)) {
                delete { $0.moveToTrash() }
            }
            .keyboardShortcut(deleteShortcut(.moveToTrash))
            .disabled(actions == nil)

            Button(FileOpsDeleteDecision.title(for: .deletePermanently, prefs: deletePrefs)) {
                delete { $0.deletePermanently() }
            }
            .keyboardShortcut(deleteShortcut(.deletePermanently))
            .disabled(actions == nil)

            Button("Copy Path") { perform { $0.copyPath() } }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(actions == nil)

            Divider()

            Button(showHidden ? "Hide Hidden Files" : "Show Hidden Files") { perform { $0.toggleHidden() } }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(actions == nil)

            // ⌘Y like Finder. Space also works while a file list has focus; it is
            // handled by the list itself so typing a space in a text field is safe.
            Button("Quick Look") { perform { $0.quickLook() } }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(actions == nil)

            Button("Refresh") { perform { $0.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions == nil)

            Divider()

            // Finder's ⌘E: the drive, disk image or server selected under the
            // sidebar's Locations, or in the computer's overview. Text keeps ⌘E
            // (Use Selection for Find).
            let target = ejectVolume ?? overviewEjectVolume
            Button(target.map { String(localized: "Eject “\($0.name)”") } ?? String(localized: "Eject")) {
                perform { _ in if let target { VolumeEjector.shared.eject(target) } }
            }
            .keyboardShortcut(textInput.isActive ? nil : KeyboardShortcut("e", modifiers: .command))
            .disabled(actions == nil || target == nil)

            Divider()

            // The folder selected, or the one shown — as the toolbar buttons.
            ForEach(OpenTool.allCases.filter { installed.apps.shows($0) }, id: \.self) { tool in
                Button(tool.currentTitle) { perform { $0.openTool(tool) } }
                    .disabled(actions == nil)
            }

            Divider()

            CheckForUpdatesButton()

            Divider()

            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin },
                set: { launchAtLogin = LaunchAtLogin.set($0) }
            ))
        }
    }

    @MainActor
    private func perform(_ action: (BrowserActions) -> Void) {
        BrowserActions.perform(actions, action)
    }

    /// ⌘⌫ deletes to the start of the line in text, and a menu item claims its
    /// shortcut even when disabled. So the delete items carry their shortcuts
    /// only while a browser window is key and no text has focus; any other time
    /// the keys reach the text (a rename, the search field, the editors).
    private func deleteShortcut(_ command: FileOpsDeleteCommand) -> KeyboardShortcut? {
        guard actions != nil, !textInput.isActive else { return nil }
        switch FileOpsDeleteDecision.shortcut(for: command, prefs: deletePrefs) {
        case .commandDelete:       return KeyboardShortcut(.delete, modifiers: .command)
        case .optionCommandDelete: return KeyboardShortcut(.delete, modifiers: [.command, .option])
        }
    }

    /// A shortcut typed while text has focus (it took focus after the menu was
    /// built) goes to the text; the item chosen with the mouse acts on the files
    /// (FileOpsDeleteRouting).
    @MainActor
    private func delete(_ action: (BrowserActions) -> Void) {
        let route = FileOpsDeleteRouting.route(textHasFocus: TextInputFocus.isActive,
                                               fromKeyboard: NSApp.currentEvent?.type == .keyDown)
        // A key press with text focused never reaches the files, even if no text
        // view takes the command.
        if route == .text {
            if !NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil) {
                NSSound.beep()
            }
            return
        }
        BrowserActions.perform(actions, action)
    }
}

/// File ▸ Open (⌘O), as in Finder: the selection, opened as ⌘O opens it in the
/// view shown (ShellOpenCommand). Columns view goes into a folder as the next
/// column; List and Icons view open it in the window.
struct BrowserFileCommands: Commands {
    @FocusedValue(\.browserActions) private var actions
    /// Whether the key browser window shows two panes: Copy / Move to Other
    /// Pane are disabled without them.
    @FocusedValue(\.browserIsDual) private var isDual
    @FocusedValue(\.browserHasOpenableSelection) private var hasSelection
    @ObservedObject private var textInput = TextInputObserver.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            // As in Finder: a tab of the key browser window showing the folder
            // new windows open (Settings → General), or a window if none is key.
            Button("New Tab") { BrowserWindowRouter.shared.openNewTab(at: nil) }
                .keyboardShortcut("t", modifiers: .command)

            Button("Open") { open() }
                .keyboardShortcut(ShellOpenCommand.hasShortcut(browserIsKey: actions != nil,
                                                               textHasFocus: textInput.isActive)
                                  ? KeyboardShortcut("o", modifiers: .command) : nil)
                .disabled(!ShellOpenCommand.isEnabled(browserIsKey: actions != nil, hasSelection: hasSelection == true))

            Divider()

            // Commander One's F5 and F6, for a window showing two panes: the
            // active pane's selection into the other pane's folder, after a
            // confirmation. Disabled with one pane; without a selection, or
            // another folder to go to, they beep and say why (ShellPaneTransfer).
            Button("Copy to Other Pane") { BrowserActions.perform(actions) { $0.copyToOtherPane() } }
                .keyboardShortcut(functionKey(NSF5FunctionKey))
                .disabled(actions == nil || isDual != true)
            Button("Move to Other Pane") { BrowserActions.perform(actions) { $0.moveToOtherPane() } }
                .keyboardShortcut(functionKey(NSF6FunctionKey))
                .disabled(actions == nil || isDual != true)
        }
    }

    /// F5 or F6 with no modifier, while a browser window is key and no text
    /// has focus: in text, F5 is the text's (Complete), and a menu item takes
    /// its key even when disabled.
    private func functionKey(_ key: Int) -> KeyboardShortcut? {
        guard actions != nil, !textInput.isActive, let scalar = UnicodeScalar(UInt32(key)) else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(scalar)), modifiers: [])
    }

    /// ⌘O typed while text has focus is the text's; text has no Open, so it
    /// beeps, as it did before this item. A held ⌘O opens once.
    @MainActor
    private func open() {
        let event = NSApp.currentEvent
        switch ShellOpenCommand.route(textHasFocus: TextInputFocus.isActive, key: event?.shellItemKey,
                                      isRepeat: event?.isKeyRepeat == true) {
        case .text:      NSSound.beep()
        case .ignore:    break
        case .selection: BrowserActions.perform(actions) { $0.open() }
        }
    }
}

/// Go ▸ Back / Forward / Enclosing Folder / Go to Folder…, as in Finder.
struct BrowserGoCommands: Commands {
    @FocusedValue(\.browserActions) private var actions
    /// Whether the key browser window shows two panes, for Switch to Other Pane.
    @FocusedValue(\.browserIsDual) private var isDual
    /// The key browser window's history (its active pane's, published by
    /// ActivePaneFocus, which follows a pane switch), observed for the
    /// enabled state.
    @FocusedObject private var navigation: BrowserNavigation?
    /// A menu item claims its shortcut even when disabled, so ⌘↑ stays enabled
    /// while text has focus (in any window, e.g. the Markdown editor) and passes
    /// it on to the text.
    @ObservedObject private var textInput = TextInputObserver.shared

    var body: some Commands {
        CommandMenu("Go") {
            Button("Back") { history { $0.goBack() } }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(actions == nil || navigation?.history.canGoBack != true)
            Button("Forward") { history { $0.goForward() } }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(actions == nil || navigation?.history.canGoForward != true)
            Button("Enclosing Folder") {
                // In text (an inline rename, the path editor, search, the Markdown editor) ⌘↑ is
                // the text's: to the beginning, as it would be without this menu.
                if TextInputFocus.isActive {
                    NSApp.sendAction(#selector(NSResponder.moveToBeginningOfDocument(_:)), to: nil, from: nil)
                } else {
                    BrowserActions.perform(actions) { $0.goUp() }
                }
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!textInput.isActive && (actions == nil || navigation?.history.canGoUp != true))

            Divider()

            // In a window with two panes: the other one active, its list
            // focused. ⌃⌘O ("other"), beside View's ⌃⌘P: free in Selway,
            // Finder and macOS. Tab stays the key view loop's.
            Button("Switch to Other Pane") { BrowserActions.perform(actions) { $0.switchPane() } }
                .keyboardShortcut("o", modifiers: [.command, .control])
                .disabled(actions == nil || isDual != true)

            Divider()

            Button("Go to Folder…") { BrowserActions.perform(actions) { $0.goToFolder() } }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(actions == nil)
            // Finder's ⌘K. Only while a browser window is key: elsewhere (the
            // editors) the keys stay theirs.
            Button("Connect to Server…") { BrowserActions.perform(actions) { $0.connectToServer() } }
                .keyboardShortcut(actions == nil ? nil : KeyboardShortcut("k", modifiers: .command))
                .disabled(actions == nil)
        }
    }

    /// Back / Forward leave text being typed alone: leaving the folder would end
    /// an inline rename half-way.
    @MainActor
    private func history(_ action: (BrowserActions) -> Void) {
        if TextInputFocus.isActive { NSSound.beep(); return }
        BrowserActions.perform(actions, action)
    }
}

/// The View menu's browser settings, the toolbar's view, grouping, sort and panel
/// items in menu form. They're app-wide settings, like the toolbar's.
struct BrowserViewCommands: Commands {
    @FocusedValue(\.browserActions) private var actions
    /// Whether the key browser window shows two panes. Each pane then shows
    /// its own path bar and status bar whatever the settings say, and no
    /// preview, so those items have nothing to change there.
    @FocusedValue(\.browserIsDual) private var isDual
    @AppStorage(UserPreferences.viewModeKey)       private var viewModeRaw    = UserPreferences.defaultViewMode.rawValue
    @AppStorage(UserPreferences.sortFieldKey)      private var sortFieldRaw   = UserPreferences.defaultSortField.rawValue
    @AppStorage(UserPreferences.sortAscendingKey)  private var sortAscending  = UserPreferences.defaultSortAscending
    @AppStorage(UserPreferences.groupByKey)        private var groupByRaw     = UserPreferences.defaultGroupBy.rawValue
    @AppStorage(UserPreferences.folderOrderKey)    private var folderOrderRaw = UserPreferences.defaultFolderOrder.rawValue
    @AppStorage(UserPreferences.showPreviewKey)    private var showPreview    = false
    @AppStorage(UserPreferences.showColumnTreeKey) private var showColumnTree = false
    @AppStorage(UserPreferences.showPathBarKey)    private var showPathBar    = true
    @AppStorage(SettingsKeys.showStatusBar)        private var showStatusBar  = true

    private var viewMode: ViewMode { ViewMode.fromStorage(viewModeRaw) }

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            // Finder's order and shortcuts: ⌘1 Icons, ⌘2 List, ⌘3 Columns.
            ForEach(Array(ViewMode.finderOrder.enumerated()), id: \.element) { index, mode in
                Toggle(mode.menuTitle, isOn: Binding(
                    get: { viewMode == mode },
                    set: { if $0 { act { viewModeRaw = mode.rawValue } } }
                ))
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(actions == nil)
            }

            Divider()

            Picker("Group By", selection: Binding(get: { GroupBy.fromStorage(groupByRaw) },
                                                  set: { g in act { groupByRaw = g.rawValue } })) {
                ForEach(GroupBy.allCases) { g in Text(g.displayName).tag(g) }
            }
            .disabled(actions == nil)

            Menu("Sort By") {
                Picker("Sort By", selection: Binding(get: { SortField.fromStorage(sortFieldRaw) },
                                                     set: { f in act { sortFieldRaw = f.rawValue } })) {
                    ForEach(SortField.allCases) { f in Text(f.displayName).tag(f) }
                }
                .pickerStyle(.inline)
                Picker("Order", selection: Binding(get: { sortAscending },
                                                   set: { a in act { sortAscending = a } })) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .pickerStyle(.inline)
                Picker("Folders", selection: Binding(get: { FolderOrder.fromStorage(folderOrderRaw) },
                                                     set: { o in act { folderOrderRaw = o.rawValue } })) {
                    ForEach(FolderOrder.allCases) { o in Text(o.displayName).tag(o) }
                }
                .pickerStyle(.inline)
            }
            .disabled(actions == nil)

            Divider()

            Button(showPathBar ? "Hide Path Bar" : "Show Path Bar") { act { showPathBar.toggle() } }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(actions == nil || isDual == true)
            // ⌘/ as in Finder.
            Button(showStatusBar ? "Hide Status Bar" : "Show Status Bar") { act { showStatusBar.toggle() } }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(actions == nil || isDual == true)
            Button(showPreview ? "Hide Preview" : "Show Preview") { act { showPreview.toggle() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(actions == nil || isDual == true)
            Button(showColumnTree ? "Hide Folder Tree" : "Show Folder Tree") { act { showColumnTree.toggle() } }
                .disabled(actions == nil || viewMode != .columns)

            Divider()

            // Two panes side by side in this window (or tab); new windows and
            // tabs follow the last choice. ⌃⌘P: Finder, macOS and the rest of
            // Selway leave it free (⌥⌘D is the Dock's, ⇧⌘D Finder's Desktop,
            // ⌃⌘D Look Up).
            Button(isDual == true ? "Hide Dual Pane" : "Show Dual Pane") {
                BrowserActions.perform(actions) { $0.toggleDualPane() }
            }
            .keyboardShortcut("p", modifiers: [.command, .control])
            .disabled(actions == nil)
            // The divider in steps, as VoiceOver moves it; no shortcuts.
            Button("Make Left Pane Wider") { BrowserActions.perform(actions) { $0.widenPane(.left) } }
                .disabled(actions == nil || isDual != true)
            Button("Make Right Pane Wider") { BrowserActions.perform(actions) { $0.widenPane(.right) } }
                .disabled(actions == nil || isDual != true)
            Button("Make Panes Equal Width") { BrowserActions.perform(actions) { $0.equalizePanes() } }
                .disabled(actions == nil || isDual != true)

            Divider()
        }
    }

    /// Only while a browser window itself is key: not Quick Look or an editor.
    @MainActor
    private func act(_ change: () -> Void) {
        BrowserActions.perform(actions) { _ in change() }
    }
}

/// Commands for combining and separating a browser tab's panes.
struct BrowserWindowCommands: Commands {
    @FocusedValue(\.browserActions) private var actions
    @FocusedValue(\.browserIsDual) private var isDual
    @FocusedValue(\.browserHasTabToRight) private var hasTabToRight

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button(String(localized: "Merge Tab into Dual Pane", comment: "Window menu command that merges the next tab into the current window's second pane")) {
                BrowserActions.perform(actions) { $0.mergeTabIntoDualPane() }
            }
            .disabled(actions == nil || !TabArrangement.canMergeTab(isDual: isDual == true,
                                                                     hasTabToRight: hasTabToRight == true))

            Button(String(localized: "Move Other Pane to New Tab", comment: "Window menu command that moves the inactive pane into a new tab")) {
                BrowserActions.perform(actions) { $0.moveOtherPaneToNewTab() }
            }
            .disabled(actions == nil || !TabArrangement.canMoveOtherPane(isDual: isDual == true))
        }
    }
}

/// "Check for Updates…" in the Selway menu; disabled while Sparkle is already busy.
private struct CheckForUpdatesButton: View {
    @ObservedObject private var updates = UpdateManager.shared

    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheckForUpdates)
    }
}

// MARK: - Launch at login

enum LaunchAtLogin {
    /// Registers / unregisters the login item and returns the resulting state.
    /// Failures used to be swallowed (`try?`), leaving the menu checkmark out of
    /// sync with reality; now they're shown and the toggle reflects the system.
    @MainActor
    static func set(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            showAlert(title: enabled ? String(localized: "Couldn’t turn on Launch at Login", comment: "Launch at Login setting error")
                                     : String(localized: "Couldn’t turn off Launch at Login", comment: "Launch at Login setting error"),
                      message: error.localizedDescription,
                      offerSettings: true)
        }
        switch service.status {
        case .enabled:
            return true
        case .requiresApproval:
            if enabled {
                showAlert(title: String(localized: "Approve Selway in Login Items", comment: "Login item approval alert title"),
                          message: String(localized: "macOS needs your approval before Selway can open at login. Turn it on under System Settings → General → Login Items.", comment: "Login item approval alert detail"),
                          offerSettings: true)
            }
            return false
        default:
            return false
        }
    }

    @MainActor
    private static func showAlert(title: String, message: String, offerSettings: Bool) {
        let alert = NSAlert()
        alert.messageText     = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK", comment: "Alert button to dismiss"))
        if offerSettings { alert.addButton(withTitle: String(localized: "Open Login Items Settings", comment: "Alert button to open Login Items settings")) }
        if alert.runModal() == .alertSecondButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

extension Notification.Name {
    /// Posted by AppDelegate for external opens; BrowserWindowRouter delivers it
    /// to a single window.
    static let navigateToPath    = Notification.Name("navigateToPath")
    static let refreshDirectory  = Notification.Name("studio.irq.selway.refreshDirectory")
    /// Files in a watched folder (the object, its URL) changed in place; their
    /// names are in `DirectoryWatcher.changedNames` (DirectoryWatcher).
    static let directoryEntriesChanged = Notification.Name("studio.irq.selway.directoryEntriesChanged")
    /// An eject found the volume (the object, its URL) busy: previews of files
    /// on it let go before it tries again (VolumeEjector).
    static let releaseVolume     = Notification.Name("studio.irq.selway.releaseVolume")
    /// Select All was chosen (ContentView). A click inside the selection waiting
    /// to narrow it (ShellPressRelease) is dropped, in whichever window: when
    /// everything was already selected, Select All changes nothing a view sees.
    static let selectAllRequested = Notification.Name("studio.irq.selway.selectAllRequested")
}

/// How long a click inside a selection waits before narrowing it
/// (ShellPressRelease), in the icon grid and the columns: the double-click
/// interval, or under the UI tests the wait a test asks for
/// (UITestHooks.narrowingWait).
enum PressNarrowing {
    static var wait: TimeInterval {
        #if SELWAY_UI_TESTING
        if let wait = UITestHooks.narrowingWait { return wait }
        #endif
        return NSEvent.doubleClickInterval
    }
}

// MARK: - UI test hooks

#if SELWAY_UI_TESTING
/// Launch hooks for the SelwayUITests target (scripts/ui-test.sh). Compiled only
/// into the UITest build configuration, whose app has a bundle identifier of its
/// own (`studio.irq.selway.uitest`), so its preferences, saved windows and Sparkle
/// state are never the user's copy's, and no Finder extension is embedded. Debug
/// and Release builds don't contain any of this.
///
/// Even in that build nothing happens without `-SelwayUITesting YES` at launch,
/// so opening it by hand gives a plain (separate) copy of the app. The tests pass:
/// - `-SelwayUITestFolder <path>`: the folder the first window opens, through the
///   cold-launch path (`AppDelegate.pendingNavigationURL`);
/// - `-SelwayUITestDefaults <JSON object>`: preferences to start with (view mode,
///   sort, grouping, sidebar…), on top of factory settings with the first-run
///   sheet and the browse-defaults migration already done;
/// - `-SelwayUITestAutofsFolder <path>`: a fixture folder AutomountGuard takes
///   for an automount folder, so a link to it is listed unfollowed;
/// - `-SelwayUITestBonjour "Name|Other|…"`: the servers the sidebar's
///   Network row finds (see `bonjourServices`);
/// - `-SelwayUITestPromiseSource "name|fail:other"`: a panel to drag file
///   promises from (see `promisedFiles`);
/// - `-SelwayUITestFolderHandlerLeftover`: Settings shows Restore Finder as if
///   an older Selway had left its folder handler or NSFileViewer entry, and the
///   button clears only this stand-in (see `folderHandlerLeftover`).
/// Under the tests Sparkle isn't started, nothing is mounted (ServerMount) or
/// reconnected at launch, the network is never searched (NetworkNeighborhood
/// uses a stand-in, with or without the hook), stale terminal scripts in the shared temporary folder
/// are left alone, Restore Finder never changes the real folder handler or
/// NSFileViewer, and browser windows get known frames (see `place`).
enum UITestHooks {
    static let enabledArgument  = "-SelwayUITesting"
    static let folderArgument   = "-SelwayUITestFolder"
    static let defaultsArgument = "-SelwayUITestDefaults"
    static let volumesArgument  = "-SelwayUITestVolumes"
    static let mountStatusArgument = "-SelwayUITestMountStatus"
    static let autofsFolderArgument = "-SelwayUITestAutofsFolder"
    static let bonjourArgument = "-SelwayUITestBonjour"
    static let linkFollowGateArgument = "-SelwayUITestLinkFollowGate"
    static let promiseSourceArgument = "-SelwayUITestPromiseSource"
    static let timeMachineArgument = "-SelwayUITestTimeMachine"
    static let windowOpenDelayArgument = "-SelwayUITestWindowOpenDelay"
    static let folderHandlerLeftoverArgument = "-SelwayUITestFolderHandlerLeftover"

    /// The stand-in for what an older Selway left behind (DefaultFolderHandler):
    /// nil outside the tests and without the argument, then true until Restore
    /// Finder clears it.
    @MainActor static var folderHandlerLeftover: Bool? = {
        guard isActive, ProcessInfo.processInfo.arguments.contains(folderHandlerLeftoverArgument) else { return nil }
        return true
    }()

    /// Seconds the router waits before opening a window it was asked for, so a
    /// test can open one with File ▸ New Window in between (issue #84).
    static let windowOpenDelay: TimeInterval? = {
        guard isActive, let value = value(after: windowOpenDelayArgument) else { return nil }
        return TimeInterval(value)
    }()

    /// Launched by the UI tests: the UITest build's own bundle identifier (so the
    /// domain cleared below can never be the user's) and the enabling argument.
    static let isActive: Bool = {
        guard let id = Bundle.main.bundleIdentifier, id.hasSuffix(".uitest") else { return false }
        return ProcessInfo.processInfo.arguments.contains(enabledArgument)
    }()

    /// Called from `SelwayApp.init`, before any preference is read or window opens.
    static func applyLaunchArguments() {
        guard isActive, let domain = Bundle.main.bundleIdentifier else { return }
        let defaults = UserDefaults.standard
        // Every launch starts from factory settings (window frames and toolbar included).
        defaults.removePersistentDomain(forName: domain)
        defaults.set(true, forKey: UserPreferences.didShowFirstRunKey)
        defaults.set(true, forKey: UserPreferences.defaultsMigratedKey)
        if let json = value(after: defaultsArgument)?.data(using: .utf8),
           let values = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] {
            for (key, value) in values { defaults.set(value, forKey: key) }
        }
        if let path = value(after: folderArgument), !path.isEmpty {
            AppDelegate.pendingNavigationURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        if let path = value(after: autofsFolderArgument), !path.isEmpty {
            AutomountGuard.uiTestAutofsFolder = path
        }
        if let json = value(after: timeMachineArgument)?.data(using: .utf8),
           let stage = try? JSONDecoder().decode(UITestTimeMachine.self, from: json) {
            TimeMachineBackups.live = stage.backups
        }
    }

    /// A stand-in Time Machine disk (`-SelwayUITestTimeMachine`), since the
    /// tests can't make APFS snapshots or mount them: a JSON object with
    /// "volumes" (the fixture's stand-in for /Volumes), "disk" (a folder in
    /// it), "uuid", "snapshots" (the disk's snapshot names) and "mounted"
    /// (the mount points under volumes/.timemachine/<uuid> to treat as
    /// mounted), and optionally "unreadable" (the disk can't be opened, as
    /// without Full Disk Access). The folders are the fixture's own.
    private struct UITestTimeMachine: Decodable {
        let volumes: String
        let disk: String
        let uuid: String
        let snapshots: [String]
        let mounted: [String]
        let unreadable: Bool?

        var backups: TimeMachineBackups {
            let disk = URL(fileURLWithPath: disk, isDirectory: true)
            let mounted = Set(mounted.map { ShellPath.key(URL(fileURLWithPath: $0)) })
            let (uuid, snapshots, unreadable) = (uuid, snapshots, unreadable ?? false)
            let fileSystem = TimeMachineBackups.FileSystem(
                snapshotNames: { ShellPath.same($0, disk) ? snapshots : [] },
                localMountPointKeys: { mounted.union([ShellPath.key(disk)]) },
                volumeUUID: { ShellPath.same($0, disk) ? uuid : nil },
                localVolumes: { [disk] },
                folderExists: TimeMachineBackups.FileSystem.live.folderExists,
                canOpen: { !(unreadable && ShellPath.same($0, disk)) && TimeMachineBackups.FileSystem.live.canOpen($0) })
            return TimeMachineBackups(fileSystem: fileSystem,
                                      volumesRoot: URL(fileURLWithPath: volumes, isDirectory: true))
        }
    }

    /// Stand-ins for the volumes under Locations, so the tests never depend on
    /// (or eject) a real one: a JSON array of {"path", "name", "diskImage",
    /// "server", "remount"}, each path a folder in the test's fixture, and
    /// "remount" the server address a share would have been mounted from (for
    /// matching saved servers). Nil without the argument: the real volumes.
    static let volumes: [SidebarVolume]? = {
        guard isActive, let json = value(after: volumesArgument)?.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] else { return nil }
        return entries.compactMap { entry in
            guard let path = entry["path"] as? String, let name = entry["name"] as? String else { return nil }
            let isDiskImage = entry["diskImage"] as? Bool ?? false
            let remount = (entry["remount"] as? String).flatMap(URL.init(string:))
                .flatMap(ServerAddress.init(remountURL:))
            return SidebarVolume(url: URL(fileURLWithPath: path, isDirectory: true), name: name,
                                 isEjectable: isDiskImage, isRemovable: isDiskImage,
                                 isLocal: !(entry["server"] as? Bool ?? false) && remount == nil,
                                 isDiskImage: isDiskImage, server: remount)
        }
    }()

    /// What a mount reports under the UI tests, which never call NetFS
    /// (ServerMount): NetFS's status, `-SelwayUITestMountStatus`, by default
    /// 65 (EHOSTUNREACH: the server wasn't found).
    static let mountStatus: Int32 = value(after: mountStatusArgument).flatMap { Int32($0) } ?? 65

    /// The servers the Network row finds under the UI tests, which never
    /// search the real network (UITestNetworkBrowser): `-SelwayUITestBonjour`
    /// split at "|", each an SMB server's name, optionally after a behaviour
    /// ("drop:", "slow:", "lost:", "bad:"; see UITestBonjourEntry); "!denied"
    /// makes the search wait for Local Network access instead.
    /// Empty without the argument: nothing is found.
    static let bonjourServices: [String] = {
        guard isActive, let list = value(after: bonjourArgument), !list.isEmpty else { return [] }
        return list.components(separatedBy: "|")
    }()

    /// A file each follow of a link the listing didn't follow waits for
    /// (`-SelwayUITestLinkFollowGate`), standing in for an unreachable host
    /// that answers when the test says so: the test makes the file. Nil
    /// without the argument.
    static let linkFollowGate: String? = {
        guard isActive, let path = value(after: linkFollowGateArgument), !path.isEmpty else { return nil }
        return path
    }()

    /// The files a drag from the promise source panel promises
    /// (`-SelwayUITestPromiseSource "name|fail:other"`, see UITestPromiseSource),
    /// standing in for Mail, Photos or Safari. Empty without the argument: no panel.
    static let promisedFiles: [String] = {
        guard isActive, let list = value(after: promiseSourceArgument), !list.isEmpty else { return [] }
        return list.components(separatedBy: "|")
    }()

    /// How long a click inside a selection waits before narrowing it
    /// (PressNarrowing): `narrowingWaitKey` from the defaults (seconds), so
    /// that a test can press a key within the wait whatever XCUITest's pace.
    /// Nil without it: the double-click interval.
    static var narrowingWait: TimeInterval? {
        guard isActive else { return nil }
        let wait = UserDefaults.standard.double(forKey: narrowingWaitKey)
        return wait > 0 ? wait : nil
    }
    static let narrowingWaitKey = "selwayUITestNarrowingWait"

    private static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    // MARK: Window frames

    /// Browser windows in the order they appeared.
    @MainActor private static var windows: [WeakWindow] = []

    /// Gives browser windows known frames: one window is made large enough for
    /// the whole toolbar (no » overflow menu); two or more are tiled side by side,
    /// so none covers another's list (the drag-and-drop test). Called by each
    /// browser window once it's in an NSWindow.
    @MainActor static func place(_ window: NSWindow?) {
        guard isActive, let window else { return }
        windows.removeAll { $0.window == nil }
        guard !windows.contains(where: { $0.window === window }) else { return }
        let holder = WeakWindow()
        holder.window = window
        windows.append(holder)
        layOutWindows()
        // Again once SwiftUI has finished sizing a window it has just opened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { layOutWindows() }
        if !promisedFiles.isEmpty { UITestPromiseSource.show(promisedFiles) }
    }

    @MainActor private static func layOutWindows() {
        // A tab group is one window on screen: laid out through its selected tab.
        var groups = Set<ObjectIdentifier>()
        let live = windows.compactMap(\.window).compactMap { window -> NSWindow? in
            guard let group = window.tabGroup, group.windows.count > 1 else { return window }
            guard groups.insert(ObjectIdentifier(group)).inserted else { return nil }
            return group.selectedWindow ?? window
        }
        guard let first = live.first, let area = (first.screen ?? NSScreen.main)?.visibleFrame else { return }
        if live.count == 1 {
            let size = NSSize(width: min(1280, area.width - 40), height: min(800, area.height - 40))
            first.setFrame(NSRect(x: area.minX + 20, y: area.maxY - 20 - size.height,
                                  width: size.width, height: size.height), display: true)
            return
        }
        let width = (area.width / CGFloat(live.count)).rounded(.down)
        for (index, window) in live.enumerated() {
            window.setFrame(NSRect(x: area.minX + CGFloat(index) * width, y: area.minY,
                                   width: width, height: area.height), display: true)
        }
    }
}
#endif
