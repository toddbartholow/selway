import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The Settings tabs after General (SettingsView.swift). Each setting is stored
// under its own `selway…` key and takes effect at once, in every window.

// MARK: - Browse

struct BrowseSettingsTab: View {
    @AppStorage(UserPreferences.viewModeKey)       private var viewModeRaw    = UserPreferences.defaultViewMode.rawValue
    @AppStorage(UserPreferences.sortFieldKey)      private var sortFieldRaw   = UserPreferences.defaultSortField.rawValue
    @AppStorage(UserPreferences.sortAscendingKey)  private var sortAscending  = UserPreferences.defaultSortAscending
    @AppStorage(UserPreferences.groupByKey)        private var groupByRaw     = UserPreferences.defaultGroupBy.rawValue
    @AppStorage(UserPreferences.folderOrderKey)    private var folderOrderRaw = UserPreferences.defaultFolderOrder.rawValue
    @AppStorage(UserPreferences.showHiddenKey)     private var showHidden     = false
    @AppStorage(UserPreferences.showPathBarKey)    private var showPathBar    = true
    @AppStorage(SettingsKeys.showStatusBar)        private var showStatusBar  = true
    @AppStorage(UserPreferences.showPreviewKey)    private var showPreview    = false
    @AppStorage(UserPreferences.showColumnTreeKey) private var showColumnTree = false
    @AppStorage(UserPreferences.showIconPreviewsKey) private var showIconPreviews = UserPreferences.defaultShowIconPreviews

    private static let arrangeNote: LocalizedStringResource = "The toolbar and the View menu change these too. They apply to every window."
    private static let resetNote: LocalizedStringResource = "List view, grouped by Date Modified, newest first, folders on top: the settings a new install starts with."

    var body: some View {
        Form {
            Section {
                Picker("View as", selection: Binding(get: { ViewMode.fromStorage(viewModeRaw) },
                                                     set: { viewModeRaw = $0.rawValue })) {
                    ForEach(ViewMode.finderOrder, id: \.self) { Text($0.title).tag($0) }
                }
                .settingTip("Icons (⌘1), List (⌘2) or Columns (⌘3)")

                Picker("Sort by", selection: Binding(get: { SortField.fromStorage(sortFieldRaw) },
                                                     set: { sortFieldRaw = $0.rawValue })) {
                    ForEach(SortField.allCases) { Text($0.displayName).tag($0) }
                }
                .help("What items are sorted by, inside each group")

                Picker("Order", selection: $sortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .help("Ascending is A to Z, oldest first and smallest first")

                Picker("Group by", selection: Binding(get: { GroupBy.fromStorage(groupByRaw) },
                                                      set: { groupByRaw = $0.rawValue })) {
                    ForEach(GroupBy.allCases) { Text($0.displayName).tag($0) }
                }
                .help("Sections such as Today, Yesterday and Previous 7 Days, or None")

                Picker("Folders", selection: Binding(get: { FolderOrder.fromStorage(folderOrderRaw) },
                                                     set: { folderOrderRaw = $0.rawValue })) {
                    ForEach(FolderOrder.allCases) { Text($0.displayName).tag($0) }
                }
                .help("Whether folders come before files, after them, or sorted with them")

                HStack(alignment: .firstTextBaseline) {
                    SettingNote(Self.resetNote)
                        .accessibilityHidden(true)   // the button's hint says it
                    Spacer()
                    Button("Reset to Finder Defaults") {
                        UserPreferences.applyFactoryBrowseDefaults()
                        viewModeRaw    = UserPreferences.defaultViewMode.rawValue
                        sortFieldRaw   = UserPreferences.defaultSortField.rawValue
                        sortAscending  = UserPreferences.defaultSortAscending
                        groupByRaw     = UserPreferences.defaultGroupBy.rawValue
                        folderOrderRaw = UserPreferences.defaultFolderOrder.rawValue
                    }
                    .help(Self.resetNote)
                    .accessibilityHint(Self.resetNote)
                }
            } header: {
                Text("Arrange")
            } footer: {
                SettingNote(Self.arrangeNote)
            }

            Section("Show") {
                Toggle("Hidden files", isOn: $showHidden)
                    .settingTip("Files and folders whose names start with a dot, and others macOS hides. Selway → Show Hidden Files (⇧⌘.)")
                Toggle("Icon previews", isOn: $showIconPreviews)
                    .settingTip("A preview of each file’s contents in place of its icon, for pictures, PDFs, movies and documents, in every view")
                    // For the UI tests: "Preview panel" is below it.
                    .accessibilityIdentifier("settingsShowIconPreviews")
                Toggle("Path bar", isOn: $showPathBar)
                    .settingTip("The folder’s path under the toolbar. View → Show Path Bar (⌥⌘P)")
                Toggle("Status bar", isOn: $showStatusBar)
                    .settingTip("Item count, selection size, free space and how the list is sorted. View → Show Status Bar (⌘/)")
                Toggle("Preview panel", isOn: $showPreview)
                    .settingTip("A preview of the selected item beside the list or icons. View → Show Preview (⇧⌘P)")
                Toggle("Folder tree in Columns view", isOn: $showColumnTree)
                    .settingTip("Columns start at the top of the disk instead of at the current folder. View → Show Folder Tree")
            }
        }
        .formStyle(.grouped)
        .settingsTabHeight()
    }
}

// MARK: - Sidebar

struct SidebarSettingsTab: View {
    @AppStorage(SidebarPrefs.favoritesKey)   private var favoritesRaw: String?
    @AppStorage(SidebarPrefs.showRecentKey)  private var showRecent  = true
    @AppStorage(SidebarPrefs.recentCountKey) private var recentCount = SidebarPrefs.defaultRecentCount
    @AppStorage(SidebarPrefs.showTagsKey)    private var showTags    = true
    @AppStorage(SidebarPrefs.showHardDisksKey)      private var showHardDisks      = true
    @AppStorage(SidebarPrefs.showExternalDisksKey)  private var showExternalDisks  = true
    @AppStorage(SidebarPrefs.showDiscsAndImagesKey) private var showDiscsAndImages = true
    @AppStorage(SidebarPrefs.showNetworkVolumesKey) private var showNetworkVolumes = true
    @AppStorage(SidebarPrefs.showNetworkKey)        private var showNetwork        = true

    private let home = FileManager.default.homeDirectoryForCurrentUser

    /// Saved servers have no switch here: like Pinned folders, they're listed
    /// because they were added, and go with Remove from Sidebar.
    private static let locationsNote = String(localized: "Drives, disk images and servers have an eject button. Selway → Eject (⌘E) ejects the one selected. Servers you add with Go → Connect to Server… (⌘K) are listed too, even with Network volumes off; Remove from Sidebar in a server’s menu takes it out. Network lists the file servers on your network once you open it.", comment: "Settings note describing what appears under Locations in the sidebar")

    private static let networkNote: LocalizedStringResource = "Servers on your network, listed when you open it"

    private func binding(_ group: SidebarVolume.Group) -> Binding<Bool> {
        switch group {
        case .hardDisks:      return $showHardDisks
        case .externalDisks:  return $showExternalDisks
        case .discsAndImages: return $showDiscsAndImages
        case .networkVolumes: return $showNetworkVolumes
        }
    }

    private func help(_ group: SidebarVolume.Group) -> LocalizedStringKey {
        switch group {
        case .hardDisks:      return "The startup disk (Macintosh HD) and any other disk inside this Mac"
        case .externalDisks:  return "Drives connected to this Mac, such as USB and Thunderbolt drives and memory cards"
        case .discsAndImages: return "CDs and DVDs, and disk images you’ve opened"
        case .networkVolumes: return "Shared folders on servers this Mac is connected to"
        }
    }

    private func binding(_ item: SidebarFavoriteItem) -> Binding<Bool> {
        Binding(get: { SidebarPrefs.favorites(fromStorage: favoritesRaw).contains(item) },
                set: { favoritesRaw = SidebarPrefs.setting(item, shown: $0, in: favoritesRaw) })
    }

    private var iCloudAvailable: Bool {
        FileItem.isBrowsableFolder(SidebarFavoriteItem.iCloudDrive.url(home: home))
    }

    private var count: Int { SidebarPrefs.recentCount(recentCount) }

    var body: some View {
        Form {
            Section {
                ForEach(SidebarFavoriteItem.allCases, id: \.self) { item in
                    if item == .iCloudDrive && !iCloudAvailable {
                        Toggle(isOn: binding(item)) {
                            SettingLabel(verbatim: item.title, note: "iCloud Drive isn’t turned on for this Mac. The row appears once it is.")
                        }
                        .settingHelp(verbatimTitle: item.title, "Shown once iCloud Drive is turned on for this Mac")
                    } else {
                        Toggle(item.title, isOn: binding(item))
                            .help(item.url(home: home).path)
                    }
                }
            } header: {
                Text("Favorites")
            } footer: {
                SettingNote("Add any other folder with “Add to Sidebar” in its menu. It’s listed under Pinned.")
            }

            Section {
                ForEach(SidebarVolume.Group.allCases, id: \.self) { group in
                    Toggle(group.title, isOn: binding(group))
                        .help(help(group))
                }
                // Finder's "Bonjour computers".
                Toggle(isOn: $showNetwork) {
                    SettingLabel("Network", note: Self.networkNote)
                }
                .settingHelp("Network", Self.networkNote)
                // For the UI tests: "Network volumes" is beside it.
                .accessibilityIdentifier("settingsShowNetwork")
            } header: {
                Text("Locations")
            } footer: {
                SettingNote(verbatim: Self.locationsNote)
                    .accessibilityLabel(KeyNames.spoken(Self.locationsNote))
            }

            Section("Recent") {
                Toggle("Recent folders", isOn: $showRecent)
                    .help("The folders you opened last, newest first")
                Stepper(value: Binding(get: { count }, set: { recentCount = SidebarPrefs.recentCount($0) }),
                        in: SidebarPrefs.recentCountRange) {
                    Text("Show up to \(count) folders")
                }
                .disabled(!showRecent)
                // Named by the words on screen, the number as its value.
                .accessibilityLabel("Show up to")
                .accessibilityValue(Text("\(count) folders"))
                .help("How many recent folders the sidebar lists (1 to \(SidebarPrefs.recentCountRange.upperBound))")
            }

            Section {
                Toggle(isOn: $showTags) {
                    SettingLabel("Tags", note: "Finder’s colour tags and the other tags used on this Mac. Choose which ones in the Tags tab.")
                }
                .settingHelp("Tags", "Finder’s colour tags and the other tags used on this Mac. Choose which ones in the Tags tab.")
            } header: {
                Text("Tags")
            }
        }
        .formStyle(.grouped)
        .settingsTabHeight()
    }
}

// MARK: - Tags

struct TagsSettingsTab: View {
    @AppStorage(SidebarPrefs.showTagsKey)   private var showTags   = true
    @AppStorage(SidebarPrefs.hiddenTagsKey) private var hiddenTags = ""
    @ObservedObject private var tagCatalog = TagCatalog.shared

    /// What the sidebar lists with nothing hidden (Finder's seven colour tags
    /// under the user's names, then the custom tags found on this Mac), then any
    /// other hidden tag, so it can be shown again.
    private var tags: [SidebarTag] {
        let all = SidebarPrefs.tagRows(names: tagCatalog.colorNames, known: tagCatalog.knownTags,
                                       inFolder: [], hiddenStorage: "")
        let others = SidebarPrefs.hiddenTags(fromStorage: hiddenTags).filter { tag in
            !all.contains { $0.name.caseInsensitiveCompare(tag) == .orderedSame }
                && tagCatalog.colorNames.color(named: tag) == nil
        }
        return all + others.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { SidebarTag(name: $0, color: 0, isStandard: false) }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show Tags in the sidebar", isOn: $showTags)
                    .settingTip("Also in Settings → Sidebar")
            } footer: {
                SettingNote("The sidebar lists Finder’s colour tags and the other tags used on this Mac. Clicking one finds every item with that tag on this Mac.")
            }

            Section {
                ForEach(tags, id: \.self) { tag in
                    Toggle(isOn: Binding(get: { !SidebarPrefs.isHidden(tag.name, in: hiddenTags) },
                                         set: { hiddenTags = SidebarPrefs.setting(tag: tag.name, hidden: !$0, in: hiddenTags) })) {
                        HStack(spacing: 8) {
                            Group {
                                if let color = FileItem.colorForLabelNumber(tag.color) {
                                    Circle()
                                        .fill(color)
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                                } else {
                                    Circle().strokeBorder(Color.secondary, lineWidth: 1)
                                }
                            }
                            .frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                            Text(tag.name)
                        }
                    }
                    .accessibilityLabel("Show \(tag.name) in the sidebar")
                    .accessibilityHint(showTags ? Text(verbatim: "") : Text("Turn on Show Tags in the sidebar to choose tags"))
                }
            } header: {
                Text("Show in the sidebar")
            } footer: {
                SettingNote("To hide another tag, right-click it in the sidebar and choose Hide in Sidebar. Tags are Finder’s: rename or recolour them in Finder, and Selway uses the new names.")
            }
            .disabled(!showTags)
        }
        .formStyle(.grouped)
        // The tag list grows with the tags on this Mac: past this, it scrolls.
        .settingsTabHeight(upTo: 640)
        .onAppear { if showTags { tagCatalog.scanIfStale() } }
    }
}

// MARK: - Integrations

struct IntegrationsSettingsTab: View {
    @ObservedObject private var installed = InstalledAppsService.shared
    @AppStorage(TerminalChoice.key)           private var terminalRaw = TerminalChoice.defaultApp.rawValue
    @AppStorage(TerminalChoice.customPathKey) private var customTerminal = ""
    @AppStorage(TextFileDetector.sniffUnknownKey) private var sniffUnknown = true
    @AppStorage(EditorFontSize.key)               private var fontSize     = EditorFontSize.defaultSize
    @AppStorage(SettingsKeys.editorWrap)          private var wrap         = false
    @AppStorage(SettingsKeys.editorMinimap)       private var minimap      = true
    @AppStorage(SettingsKeys.editorSublimeKeys)   private var sublimeKeys  = false

    private static let terminalNote: LocalizedStringResource = "Used by Open in Terminal, Claude Code and the Codex command-line tool. If the app you choose isn’t on this Mac, Selway uses Terminal."
    private static let sniffNote: LocalizedStringResource = "When on, files without a known code extension open in Selway’s editor if they look like text. When off, only known text and code files do."

    private var choice: TerminalApp { TerminalChoice.fromStorage(terminalRaw) }

    /// Choosing Other… with no app picked yet asks for one; cancelling leaves
    /// the previous choice.
    private var terminalBinding: Binding<TerminalApp> {
        Binding(get: { choice }, set: { app in
            if app == .other && customTerminal.isEmpty {
                guard chooseTerminalApp() else { return }
            }
            terminalRaw = app.rawValue
        })
    }

    private func terminalTitle(_ app: TerminalApp) -> String {
        if app == .other {
            return customTerminal.isEmpty
                ? String(localized: "Other…", comment: "Choice to select a custom terminal app")
                : TerminalChoice.appName(atPath: customTerminal)
        }
        return TerminalChoice.isInstalled(app)
            ? app.name
            : String(localized: "\(app.name) (not installed)", comment: "Terminal app choice when that app is not installed")
    }

    var body: some View {
        // From the picker's own values, so the notes follow it at once.
        let resolution = TerminalChoice.resolve(choice, customPath: customTerminal)
        let fallback = TerminalChoice.fallbackNote(for: choice, customPath: customTerminal, resolution: resolution)
        Form {
            Section {
                Picker(selection: terminalBinding) {
                    ForEach(TerminalApp.builtIn, id: \.self) { Text(terminalTitle($0)).tag($0) }
                    Divider()
                    Text(terminalTitle(.other)).tag(TerminalApp.other)
                } label: {
                    SettingLabel("Terminal app", note: Self.terminalNote)
                }
                .settingHelp("Terminal app", Self.terminalNote)

                if choice == .other {
                    LabeledContent("Other app") {
                        HStack {
                            Text(customTerminal.isEmpty ? "None" : (customTerminal as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Choose…") { _ = chooseTerminalApp() }
                                .help("Choose a terminal app in Applications")
                                .accessibilityLabel("Choose other terminal app")
                        }
                    }
                }
                if let fallback {
                    SettingStatus(verbatim: fallback, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
                if let note = resolution.runnerNote {
                    SettingStatus(verbatim: note, systemImage: "info.circle", tint: .secondary, font: .caption)
                }
            } header: {
                Text("Terminal")
            }

            Section {
                ForEach([OpenTool.vscode, .cursor, .claude, .codex], id: \.self) { tool in
                    toolToggle(tool)
                }
            } header: {
                Text("Toolbar and menu buttons")
            } footer: {
                SettingNote("A button appears for each app Selway finds on this Mac. Claude Code opens in \(resolution.runnerName).")
            }

            Section("Text editor") {
                Toggle(isOn: $sniffUnknown) {
                    SettingLabel("Open unknown file types in the editor", note: Self.sniffNote)
                }
                .settingHelp("Open unknown file types in the editor", Self.sniffNote)

                Stepper(value: Binding(get: { EditorFontSize.clamped(fontSize) },
                                       set: { fontSize = EditorFontSize.clamped($0) }),
                        in: EditorFontSize.range) {
                    Text("Font size: \(EditorFontSize.clamped(fontSize)) pt")
                }
                .accessibilityLabel("Font size")
                .accessibilityValue("\(EditorFontSize.clamped(fontSize)) points")
                .settingTip("Also View → Make Text Bigger or Smaller while the editor is in front")

                Toggle("Wrap long lines", isOn: $wrap)
                    .help("Wrap lines at the window’s edge instead of scrolling sideways")
                Toggle("Show the minimap", isOn: $minimap)
                    .settingTip("A small overview of the file beside the text (⇧⌘M in the editor)")
                Toggle("Sublime Text key bindings", isOn: $sublimeKeys)
                    .help("Use Sublime Text’s keyboard shortcuts in the editor")
            }
        }
        .formStyle(.grouped)
        .settingsTabHeight()
        .onAppear { installed.detectInstalledApps() }
        // The warning appears below the picker, away from the focus: say it.
        .onChange(of: fallback) { _, note in
            if let note { announceInSettings(note) }
        }
    }

    @ViewBuilder
    private func toolToggle(_ tool: OpenTool) -> some View {
        let key = tool.visibilityKey ?? ""
        let isInstalled = installed.apps.has(tool)
        // Off while not installed: there's no button to show.
        Toggle(isOn: Binding(get: { isInstalled && UserDefaults.standard.bool(forKey: key, default: true) },
                             set: { UserDefaults.standard.set($0, forKey: key) })) {
            if isInstalled {
                Text(verbatim: tool.shortTitle)
            } else {
                SettingLabel(verbatim: tool.shortTitle, note: "Not found on this Mac")
            }
        }
        .disabled(!isInstalled)
        .settingHelp("Show \(tool.shortTitle)",
                     isInstalled ? "Show the \(tool.shortTitle) button" : "\(tool.shortTitle) isn’t installed")
    }

    /// Asks for a terminal app; false when cancelled.
    private func chooseTerminalApp() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes     = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt  = String(localized: "Choose", comment: "Open panel button title for choosing a terminal app")
        panel.message = String(localized: "Choose the terminal app Selway opens folders in.", comment: "Open panel message for choosing a terminal app")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        customTerminal = url.path
        terminalRaw = TerminalApp.other.rawValue
        return true
    }
}

// MARK: - Advanced

struct AdvancedSettingsTab: View {
    @AppStorage(FileOpsDeletePrefs.commandDeleteTrashesKey)   private var commandDeleteTrashes   = true
    @AppStorage(FileOpsDeletePrefs.confirmTrashKey)           private var confirmTrash           = false
    @AppStorage(FileOpsDeletePrefs.confirmPermanentDeleteKey) private var confirmPermanentDelete = true
    @AppStorage(SettingsKeys.warnExtensionChange)             private var warnExtension          = true
    @AppStorage(SettingsKeys.defaultSearchScope)              private var searchScopeRaw         = SearchScope.thisFolder.rawValue

    private static let trashNote: LocalizedStringResource = "Edit → Undo (⌘Z) puts trashed items back where they were."
    private static let permanentNote: LocalizedStringResource = "Deleted items don’t go to the Trash, and Undo can’t bring them back."
    private static let extensionNote: LocalizedStringResource = "Ask before a rename changes, adds or removes a file’s extension, which can change the app it opens in."
    private static let noConfirmWarning: LocalizedStringResource = "Delete Permanently removes items at once, without asking. They can’t be recovered."
    private static let scopeNote: LocalizedStringResource = "Where a search in a new window looks first. Change it under the search field while you search."

    private var commandDeleteNote: LocalizedStringResource {
        commandDeleteTrashes ? "⌥⌘⌫ deletes permanently." : "⌥⌘⌫ moves to the Trash."
    }

    private var commandDeleteHelp: LocalizedStringResource {
        commandDeleteTrashes
            ? "What Command-Delete does to the selected items. ⌥⌘⌫ deletes permanently."
            : "What Command-Delete does to the selected items. ⌥⌘⌫ moves to the Trash."
    }

    /// Turning the permanent-delete question off asks first.
    private var confirmPermanentBinding: Binding<Bool> {
        Binding(get: { confirmPermanentDelete }, set: { on in
            if on || Self.confirmSkippingPermanentDelete() { confirmPermanentDelete = on }
        })
    }

    var body: some View {
        Form {
            Section("Deleting") {
                Picker(selection: $commandDeleteTrashes) {
                    Text("Moves items to the Trash").tag(true)
                    Text("Deletes items permanently").tag(false)
                } label: {
                    SettingLabel("⌘⌫ (Command-Delete)", note: commandDeleteNote)
                }
                .settingHelp("Command-Delete", commandDeleteHelp)

                Toggle(isOn: $confirmTrash) {
                    SettingLabel("Ask before moving items to the Trash", note: Self.trashNote)
                }
                .settingHelp("Ask before moving items to the Trash", Self.trashNote)

                Toggle(isOn: confirmPermanentBinding) {
                    SettingLabel("Ask before deleting permanently", note: Self.permanentNote)
                }
                .settingHelp("Ask before deleting permanently", Self.permanentNote)

                if !confirmPermanentDelete {
                    SettingStatus(text: Self.noConfirmWarning, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
            }

            Section("Renaming") {
                Toggle(isOn: $warnExtension) {
                    SettingLabel("Warn before changing an extension", note: Self.extensionNote)
                }
                .settingHelp("Warn before changing an extension", Self.extensionNote)
            }

            Section("Searching") {
                Picker(selection: Binding(get: { SearchScope.defaultScope() },
                                          set: { searchScopeRaw = $0.rawValue })) {
                    Text("This Folder").tag(SearchScope.thisFolder)
                    Text("This Mac").tag(SearchScope.entireMac)
                } label: {
                    SettingLabel("Search in", note: Self.scopeNote)
                }
                .settingHelp("Search in", Self.scopeNote)
            }

            Section("Folders outside Selway") {
                SettingStatus(text: "Folders opened from the Desktop, Finder, the Dock or other apps open in Finder. macOS doesn’t let another app take that over.",
                              systemImage: "exclamationmark.triangle", tint: .orange, font: .caption)
                SettingStatus(text: "To open one in Selway, choose Open in Selway from Finder’s shortcut menu.",
                              systemImage: "info.circle", tint: .secondary, font: .caption)
            }

            Section {
                HStack(alignment: .firstTextBaseline) {
                    SettingNote("Pinned and recent folders, Launch at Login and update checks stay as they are.")
                    Spacer()
                    Button("Reset All Settings…", role: .destructive) { Self.confirmResetAll() }
                        .help("Put every Selway setting back to how a new install starts")
                }
            }
        }
        .formStyle(.grouped)
        .settingsTabHeight()
    }

    private static func confirmSkippingPermanentDelete() -> Bool {
        let alert = NSAlert()
        alert.alertStyle      = .warning
        alert.messageText     = String(localized: "Delete permanently without asking?", comment: "Confirm disabling permanent delete confirmation")
        alert.informativeText = String(localized: "Delete Permanently will remove items at once. They won’t go to the Trash, and Undo can’t bring them back.", comment: "Permanent delete warning")
        let off = alert.addButton(withTitle: String(localized: "Don’t Ask", comment: "Alert button to disable confirmation"))
        off.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button to cancel"))
        return SafeAlert.run(alert, safe: cancel, others: [off]) == .alertFirstButtonReturn
    }

    private static func confirmResetAll() {
        let alert = NSAlert()
        alert.alertStyle      = .warning
        alert.messageText     = String(localized: "Reset all settings?", comment: "Confirm resetting settings")
        alert.informativeText = String(localized: "Every Selway setting goes back to how a new install starts: views, sidebar, text sizes, the editor, the terminal app and deleting. Pinned and recent folders, Launch at Login and update checks stay as they are.", comment: "Reset settings warning")
        let reset = alert.addButton(withTitle: String(localized: "Reset", comment: "Alert button to reset settings"))
        reset.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button to cancel"))
        guard SafeAlert.run(alert, safe: cancel, others: [reset]) == .alertFirstButtonReturn else { return }
        SettingsReset.resetAll(.standard, domain: Bundle.main.bundleIdentifier)
    }
}
