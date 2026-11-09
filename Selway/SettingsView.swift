import SwiftUI
import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Cleans up after Selway 0.5.19 and earlier, whose "Open folders in Selway"
/// setting made Selway the system's default app for folders and set the global
/// `NSFileViewer` preference. The setting is gone: macOS 26 refuses to change
/// the folder handler for any app (LaunchServices returns paramErr, even for
/// Finder), and other apps' "Show in Finder" sends the `NSFileViewer` app the
/// same open event as "Open With", so a revealed text file opened in Selway's
/// editor. Both changes belong to the user's account and outlive the app, so
/// Settings offers to undo them while either is still in place.
enum DefaultFolderHandler {

    static var bundleURL: URL { Bundle.main.bundleURL }
    static var bundleID: String? { Bundle.main.bundleIdentifier }

    private static let finderBundleID = "com.apple.finder"

    private static let fileViewerKey = "NSFileViewer" as CFString

    /// True when LaunchServices currently routes folders to Selway. It stored
    /// the handler by bundle ID, so any copy of Selway counts (a second copy,
    /// or a Debug build, may be running while another is the handler).
    static var isFolderHandler: Bool {
        guard let id = bundleID,
              let current = NSWorkspace.shared.urlForApplication(toOpen: .folder) else { return false }
        return Bundle(url: current)?.bundleIdentifier == id
    }

    /// True when the global `NSFileViewer` preference names Selway.
    static var isGlobalFileViewer: Bool {
        guard let id = bundleID else { return false }
        return globalFileViewer == id
    }

    /// Set once macOS has refused to give folders back to Finder: Settings
    /// stops offering a button that can't work, until Selway is opened again.
    @MainActor private static var handlerRestoreRefused = false

    /// True while a change an older Selway made is still in place and Restore
    /// Finder can still try to undo it.
    @MainActor static var hasLeftover: Bool {
        #if SELWAY_UI_TESTING
        if let leftover = UITestHooks.folderHandlerLeftover { return leftover }
        #endif
        return (isFolderHandler && !handlerRestoreRefused) || isGlobalFileViewer
    }

    /// Gives folders back to Finder and removes Selway's NSFileViewer entry,
    /// and returns the status line saying how each went. Another app's handler
    /// or NSFileViewer value is left alone.
    @MainActor static func restoreFinder() -> String {
        let foldersRestored = String(localized: "Finder restored as the default for folders.", comment: "Status message after restoring Finder as the default folder handler")
        #if SELWAY_UI_TESTING
        if UITestHooks.isActive {
            // Only the stand-in leftover, never the user's own settings.
            guard UITestHooks.folderHandlerLeftover != nil else { return "Not changed while UI testing." }
            UITestHooks.folderHandlerLeftover = false
            return foldersRestored
        }
        #endif
        var lines: [String] = []
        if isFolderHandler {
            let status = LSSetDefaultRoleHandlerForContentType("public.folder" as CFString, .all,
                                                               finderBundleID as CFString)
            if status == noErr {
                lines.append(foldersRestored)
            } else if status == OSStatus(paramErr) {
                // What macOS 26 answers for public.folder, whichever app is named.
                handlerRestoreRefused = true
                lines.append(String(localized: "macOS didn’t let Selway give folders back to Finder.", comment: "Error when macOS refuses to make Finder the default app for folders again"))
            } else {
                let reason = NSError(domain: NSOSStatusErrorDomain, code: Int(status)).localizedDescription
                lines.append(String(localized: "Couldn’t restore Finder: \(reason)", comment: "Status message when making Finder the default app for folders again fails; the placeholder is the system's reason"))
            }
        }
        if isGlobalFileViewer {
            if let error = removeGlobalFileViewer() {
                lines.append(error.localizedDescription)
            } else {
                lines.append(String(localized: "Other apps’ “Show in Finder” uses Finder again.", comment: "Status message after Restore Finder removed Selway as the app other apps' Show in Finder uses"))
            }
        }
        return lines.isEmpty ? foldersRestored : lines.joined(separator: " ")
    }

    private static var globalFileViewer: String? {
        CFPreferencesCopyValue(fileViewerKey, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }

    /// Removes the global `NSFileViewer` preference
    /// (~/Library/Preferences/.GlobalPreferences), which apps use for "Reveal in
    /// Finder" / "Show in Finder". Returns an error if the removal didn't stick.
    private static func removeGlobalFileViewer() -> Error? {
        CFPreferencesSetValue(fileViewerKey, nil,
                              kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let synced = CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard synced, globalFileViewer == nil else {
            return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Couldn’t remove the system “NSFileViewer” preference.", comment: "Error removing the system default file viewer preference")
            ])
        }
        return nil
    }
}

// MARK: - Settings window

/// Settings, in tabs as in Finder: General, Browse, Sidebar, Tags,
/// Integrations and Advanced. A standard system form: it doesn't follow the
/// browser's Text Size, and every control has a label, and an explanation as
/// its tooltip and VoiceOver hint (SettingLabel).
struct SettingsView: View {
    private enum Tab: String { case general, browse, sidebar, tags, integrations, advanced }
    @AppStorage("selwaySettingsTab") private var tab = Tab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general.rawValue)
            BrowseSettingsTab()
                .tabItem { Label("Browse", systemImage: "list.bullet.rectangle") }
                .tag(Tab.browse.rawValue)
            SidebarSettingsTab()
                .tabItem { Label("Sidebar", systemImage: "sidebar.left") }
                .tag(Tab.sidebar.rawValue)
            TagsSettingsTab()
                .tabItem { Label("Tags", systemImage: "tag") }
                .tag(Tab.tags.rawValue)
            IntegrationsSettingsTab()
                .tabItem { Label("Integrations", systemImage: "terminal") }
                .tag(Tab.integrations.rawValue)
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
                .tag(Tab.advanced.rawValue)
        }
        .frame(width: SettingsLayout.width)
    }
}

enum SettingsLayout {
    static let width: CGFloat = 560
}

extension View {
    /// Sizes a Settings tab to its form, so every option shows without
    /// scrolling: a grouped Form's ideal height is its content's. Heights
    /// picked by hand fell short when macOS drew taller rows, and with each
    /// row added (issue #49). The tab stays within `cap` and the screen
    /// (SettingsWindowHeight), and its form scrolls beyond that. Still one
    /// height per tab, so the window keeps sizing to each tab.
    func settingsTabHeight(upTo cap: CGFloat? = nil) -> some View {
        modifier(SettingsTabHeight(cap: cap))
    }
}

private struct SettingsTabHeight: ViewModifier {
    let cap: CGFloat?
    /// The Settings window's screen (SettingsScreenHeightReader); until the
    /// window is known, the main screen's, so the first layout fits too.
    @State private var visibleScreenHeight: CGFloat?

    func body(content: Content) -> some View {
        let limit = SettingsWindowHeight.limit(
            upTo: cap, visibleScreenHeight: visibleScreenHeight ?? NSScreen.main?.visibleFrame.height)
        content
            .frame(maxHeight: limit ?? .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                SettingsScreenHeightReader { height in
                    if visibleScreenHeight != height { visibleScreenHeight = height }
                }
                .frame(width: 0, height: 0)
            }
    }
}

/// Reports the visible height of the screen containing the Settings window, again
/// when the window moves to another display or the screen's usable area changes
/// (resolution, the Dock). NSScreen.main can refer to another display while
/// Settings is on a secondary one.
struct SettingsScreenHeightReader: NSViewRepresentable {
    let onChange: (CGFloat?) -> Void

    func makeNSView(context: Context) -> _SettingsScreenHeightView {
        let view = _SettingsScreenHeightView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: _SettingsScreenHeightView, context: Context) {
        view.onChange = onChange
        view.publishHeight()
    }
}

final class _SettingsScreenHeightView: NSView {
    var onChange: ((CGFloat?) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let window {
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window,
                                   queue: .main) { [weak self] _ in self?.publishHeight() },
                center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                   queue: .main) { [weak self] _ in self?.publishHeight() },
            ]
        }
        publishHeight()
        // A window just placed may not have its screen yet, and placing it
        // doesn't post didChangeScreen: look again once it's on screen.
        DispatchQueue.main.async { [weak self] in self?.publishHeight() }
    }

    /// Out of a window, nothing: the last height (or the main screen's) stands.
    func publishHeight() {
        guard let height = window?.screen?.visibleFrame.height else { return }
        DispatchQueue.main.async { [weak self] in self?.onChange?(height) }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// A setting's title with its explanation under it, as macOS's own settings
/// show them. Use with `settingHelp` on the control, which gives the
/// explanation to the pointer and VoiceOver; the caption is hidden from
/// VoiceOver so it isn't read twice.
struct SettingLabel: View {
    let title: Text
    let note: Text?

    init(_ title: LocalizedStringResource, note: LocalizedStringResource? = nil) {
        self.title = Text(title)
        self.note = note.map { Text($0) }
    }

    init(verbatim title: String, note: LocalizedStringResource? = nil) {
        self.title = Text(verbatim: title)
        self.note = note.map { Text($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
            if let note {
                note.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Secondary text under a setting or section. Essential warnings use
/// `.subheadline`, which stays readable where `.caption` is small.
struct SettingNote: View {
    let text: Text
    var font: Font = .caption

    init(_ text: LocalizedStringResource, font: Font = .caption) {
        self.text = Text(text)
        self.font = font
    }

    init(verbatim text: String, font: Font = .caption) {
        self.text = Text(verbatim: text)
        self.font = font
    }

    var body: some View {
        text
            .font(font)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A warning or status line: the text in the primary colour (orange or green
/// text is too faint on the light background), the meaning in the icon.
struct SettingStatus: View {
    let text: Text
    let systemImage: String
    let tint: Color
    var font: Font = .subheadline

    init(text: LocalizedStringResource, systemImage: String, tint: Color, font: Font = .subheadline) {
        self.text = Text(text)
        self.systemImage = systemImage
        self.tint = tint
        self.font = font
    }

    init(verbatim text: String, systemImage: String, tint: Color, font: Font = .subheadline) {
        self.text = Text(verbatim: text)
        self.systemImage = systemImage
        self.tint = tint
        self.font = font
    }

    var body: some View {
        Label {
            text.fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(font)
    }
}

extension View {
    /// Names a control for VoiceOver by its title alone and gives its
    /// explanation as the tooltip and the VoiceOver hint; the hint spells
    /// shortcuts out ("Option-Command-Delete"), the tooltip keeps the symbols.
    func settingHelp(_ title: LocalizedStringResource, _ note: LocalizedStringResource?) -> some View {
        accessibilityLabel(Text(title))
            .help(Text(note ?? title))
            .accessibilityHint(note.map { KeyNames.spoken(String(localized: $0)) } ?? "")
    }

    func settingHelp(_ title: LocalizedStringResource, verbatimNote note: String) -> some View {
        accessibilityLabel(title)
            .help(Text(verbatim: note))
            .accessibilityHint(KeyNames.spoken(note))
    }

    func settingHelp(verbatimTitle title: String, _ note: LocalizedStringResource) -> some View {
        accessibilityLabel(Text(verbatim: title))
            .help(Text(note))
            .accessibilityHint(KeyNames.spoken(String(localized: note)))
    }
}

extension View {
    /// A tooltip that names shortcuts with their symbols, and the same text as
    /// the VoiceOver hint with them spelled out.
    func settingTip(_ text: LocalizedStringResource) -> some View {
        help(Text(text)).accessibilityHint(KeyNames.spoken(String(localized: text)))
    }
}

/// Has VoiceOver read `text`: a warning or result that appears in the Settings
/// window without the focus moving to it.
@MainActor
func announceInSettings(_ text: String) {
    NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: text,
                                    .priority: NSAccessibilityPriorityLevel.high.rawValue])
}

// MARK: - General

struct GeneralSettingsTab: View {
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var hasLeftover = false
    @State private var statusMessage: String?

    @AppStorage(NewWindowFolder.key)           private var newWindowRaw  = NewWindowFolder.defaultValue.rawValue
    @AppStorage(NewWindowFolder.customPathKey) private var customFolder  = ""
    /// The chosen folder as `NewWindowFolder.lookUp` found it: its display
    /// name, and whether the open panel may start there. Its last path
    /// component, unlooked at, until then.
    @State private var customFolderLook: NewWindowFolder.Look?
    @AppStorage(FolderOpenTarget.key)          private var openTargetRaw = FolderOpenTarget.defaultValue.rawValue
    @AppStorage(UserPreferences.textSizeKey)   private var textSizeRaw   = TextSize.actual.percent
    @AppStorage("launchAtLogin")               private var launchAtLogin = false

    private static let textSizeHelp: LocalizedStringResource = "Text, icons and rows in browser windows. Also in the View menu: Make Text Bigger (⌘+), Make Text Smaller (⌘−) and Actual Text Size (⌘0). The code editor and Markdown windows have their own sizes: use the same commands while one of them is in front."
    private static let newWindowHelp: LocalizedStringResource = "Where File → New Window and new windows start. A folder that isn’t there (an unplugged disk) opens Home instead."
    private static let openTargetHelp: LocalizedStringResource = "What double-clicking a folder in the file list does. The sidebar and the path bar always open folders in the same window."
    private static let loginHelp: LocalizedStringResource = "Opens Selway when you log in to your Mac. Also in the Selway menu."

    /// Snaps a hand-edited value, so the picker always shows a selection.
    private var textSizeBinding: Binding<Int> {
        Binding(
            get: { TextSize.fromStorage(textSizeRaw).percent },
            set: { textSizeRaw = TextSize.fromStorage($0).percent }
        )
    }

    private var autoCheckBinding: Binding<Bool> {
        Binding(
            get: { updateManager.automaticallyChecksForUpdates },
            set: { updateManager.setAutomaticallyChecksForUpdates($0) }
        )
    }

    /// Choosing "A folder you choose" asks for the folder at once; cancelling
    /// leaves the previous choice.
    private var newWindowBinding: Binding<NewWindowFolder> {
        Binding(
            get: { NewWindowFolder.fromStorage(newWindowRaw) },
            set: { choice in
                if choice == .custom && customFolder.isEmpty {
                    guard chooseFolder() else { return }
                }
                newWindowRaw = choice.rawValue
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: newWindowBinding) {
                    ForEach(NewWindowFolder.allCases, id: \.self) { choice in
                        Text(choice == .custom && !customFolder.isEmpty
                             ? customFolderLook?.name ?? (customFolder as NSString).lastPathComponent
                             : choice.title)
                            .tag(choice)
                    }
                } label: {
                    SettingLabel("New windows open", note: Self.newWindowHelp)
                }
                .settingHelp("New windows open", Self.newWindowHelp)
                .task(id: customFolder) {
                    let path = customFolder
                    customFolderLook = nil
                    guard !path.isEmpty, let look = await NewWindowFolder.lookUp(path),
                          path == customFolder else { return }
                    customFolderLook = look
                }

                if NewWindowFolder.fromStorage(newWindowRaw) == .custom {
                    LabeledContent("Folder") {
                        HStack {
                            Text(customFolder.isEmpty ? "None" : (customFolder as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button("Choose…") { _ = chooseFolder() }
                                .help("Choose the folder new windows open")
                                .accessibilityLabel("Choose folder for new windows")
                        }
                    }
                }

                Picker(selection: Binding(get: { FolderOpenTarget.fromStorage(openTargetRaw) },
                                          set: { openTargetRaw = $0.rawValue })) {
                    ForEach(FolderOpenTarget.allCases, id: \.self) { target in
                        // A literal, for translation (FolderOpenTarget.title is the same text).
                        switch target {
                        case .sameWindow: Text("The same window").tag(target)
                        case .newWindow:  Text("A new window").tag(target)
                        case .newTab:     Text("A new tab").tag(target)
                        }
                    }
                } label: {
                    SettingLabel("Double-click a folder to open it in", note: Self.openTargetHelp)
                }
                .settingHelp("Double-click a folder to open it in", Self.openTargetHelp)

                Toggle(isOn: Binding(get: { launchAtLogin },
                                     set: { launchAtLogin = LaunchAtLogin.set($0) })) {
                    SettingLabel("Open Selway at login")
                }
                .settingHelp("Open Selway at login", Self.loginHelp)
            } header: {
                Text("Windows")
            }

            Section("Appearance") {
                Picker(selection: textSizeBinding) {
                    ForEach(TextSize.all, id: \.percent) { size in
                        Text(size.isActual ? "\(size.label) (Actual Size)" : size.label).tag(size.percent)
                    }
                } label: {
                    SettingLabel("Text size", note: Self.textSizeHelp)
                }
                .settingHelp("Text size", Self.textSizeHelp)
            }

            Section("Updates") {
                LabeledContent("Version", value: updateManager.currentVersion)
                Toggle("Check for updates automatically", isOn: autoCheckBinding)
                    .help("Selway checks for a new version about once a day and asks before installing it.")
                Button("Check for Updates…") { updateManager.checkForUpdates() }
                    .disabled(!updateManager.canCheckForUpdates)
            }

            // Only while something an older Selway changed is left (DefaultFolderHandler).
            if hasLeftover || statusMessage != nil {
                Section {
                    if hasLeftover {
                        HStack(alignment: .firstTextBaseline) {
                            SettingNote(Self.leftoverNote)
                            Spacer()
                            Button("Restore Finder") { restoreFinder() }
                                .settingHelp("Restore Finder", Self.leftoverNote)
                        }
                    }
                    if let statusMessage {
                        SettingNote(verbatim: statusMessage, font: .subheadline)
                    }
                } header: {
                    Text("Default file browser")
                }
            }
        }
        .formStyle(.grouped)
        .settingsTabHeight()
        .onAppear {
            hasLeftover = DefaultFolderHandler.hasLeftover
            // An old result about something already undone doesn't stay.
            if !hasLeftover { statusMessage = nil }
        }
    }

    private static let leftoverNote: LocalizedStringResource = "An earlier version of Selway made itself the app that opens folders, or that other apps’ “Show in Finder” uses. Restore Finder to undo it."

    /// Asks for the folder new windows open; false when cancelled.
    private func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories    = true
        panel.canChooseFiles          = false
        panel.allowsMultipleSelection = false
        panel.prompt  = String(localized: "Choose", comment: "Open panel button title for choosing a folder")
        panel.message = String(localized: "Choose the folder new Selway windows open.", comment: "Open panel message for choosing the new window folder")
        if !customFolder.isEmpty, customFolderLook?.isSafe == true {
            panel.directoryURL = URL(fileURLWithPath: customFolder, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        customFolder = url.path
        newWindowRaw = NewWindowFolder.custom.rawValue
        return true
    }

    private func restoreFinder() {
        let message = DefaultFolderHandler.restoreFinder()
        hasLeftover = DefaultFolderHandler.hasLeftover
        statusMessage = message
        // The result appears under the button, away from the focus: say it,
        // every time (the same failure twice wouldn't change statusMessage).
        announceInSettings(message)
    }
}
