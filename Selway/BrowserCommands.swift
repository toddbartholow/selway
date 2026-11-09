import SwiftUI
import AppKit
import WebKit

// MARK: - Per-window browser actions
//
// Each browser window publishes its actions with `.focusedSceneValue`, and the
// menu commands read them with `@FocusedValue`. That way a command reaches
// exactly one window — the key one — instead of being broadcast through
// NotificationCenter to every open window (two windows used to create two
// folders, or toggle hidden files twice and end up where they started).

/// One instance per browser window, created once and published unchanged, so
/// re-rendering the window (which happens at progress-publish rate during a
/// copy) doesn't hand the menus a "new" value and rebuild them. The closures
/// read the window's live state when they run.
final class BrowserActions: Equatable {
    var newFolder:    () -> Void = {}
    var toggleHidden: () -> Void = {}
    var undo:         () -> Void = {}
    var redo:         () -> Void = {}
    var cut:          () -> Void = {}
    var copy:         () -> Void = {}
    var paste:        () -> Void = {}
    /// The toolbar's Paste: into the folder shown, whatever is selected.
    var pasteHere:    () -> Void = {}
    var selectAll:    () -> Void = {}
    var quickLook:    () -> Void = {}
    var canUndo:      () -> Bool = { false }
    var canRedo:      () -> Bool = { false }
    // Toolbar and menu bar (File menu, Go menu, Selway menu).
    /// File → Open (⌘O): the selection, as ⌘O opens it in the view shown.
    var open:              () -> Void = {}
    var goBack:            () -> Void = {}
    var goForward:         () -> Void = {}
    var goUp:              () -> Void = {}
    var newTextFile:       () -> Void = {}
    var moveToTrash:       () -> Void = {}
    var deletePermanently: () -> Void = {}
    var copyPath:          () -> Void = {}
    var refresh:           () -> Void = {}
    var openTool:          (OpenTool) -> Void = { _ in }
    var find:              () -> Void = {}
    var goToFolder:        () -> Void = {}
    /// Go → Connect to Server… (⌘K): the sheet on this window.
    var connectToServer:   () -> Void = {}
    /// View → Show / Hide Dual Pane: this window's second pane.
    var toggleDualPane:    () -> Void = {}
    /// Window → Merge Tab into Dual Pane / Move Other Pane to New Tab.
    var mergeTabIntoDualPane: () -> Void = {}
    var moveOtherPaneToNewTab: () -> Void = {}
    /// File → Copy to Other Pane (F5) / Move to Other Pane (F6): the active
    /// pane's selection into the other pane's folder, once confirmed.
    var copyToOtherPane:   () -> Void = {}
    var moveToOtherPane:   () -> Void = {}
    /// Go → Switch to Other Pane: the other pane active, its list focused.
    var switchPane:        () -> Void = {}
    /// View → Make Left / Right Pane Wider and Make Panes Equal Width.
    var widenPane:         (ShellPaneSplit.Side) -> Void = { _ in }
    var equalizePanes:     () -> Void = {}

    static func == (a: BrowserActions, b: BrowserActions) -> Bool { a === b }

    /// Drops every closure (they capture the window's view, and with it its
    /// services): called when the window closes, so the menus' last reference
    /// to this object can't keep a closed window's searches running.
    func reset() {
        newFolder = {}; toggleHidden = {}; undo = {}; redo = {}
        cut = {}; copy = {}; paste = {}; pasteHere = {}; selectAll = {}; quickLook = {}
        canUndo = { false }; canRedo = { false }
        open = {}; goBack = {}; goForward = {}; goUp = {}
        newTextFile = {}; moveToTrash = {}; deletePermanently = {}; copyPath = {}; refresh = {}
        openTool = { _ in }; find = {}; goToFolder = {}; connectToServer = {}
        toggleDualPane = {}; mergeTabIntoDualPane = {}; moveOtherPaneToNewTab = {}
        copyToOtherPane = {}; moveToOtherPane = {}
        widenPane = { _ in }; equalizePanes = {}; switchPane = {}
    }

    /// Runs a menu command only when a browser window itself is key — not a
    /// sheet on it, the Quick Look panel or an editor window.
    @MainActor
    static func perform(_ actions: BrowserActions?, _ action: (BrowserActions) -> Void) {
        guard let actions, BrowserWindowRouter.shared.isBrowserWindow(NSApp.keyWindow) else {
            NSSound.beep()
            return
        }
        action(actions)
    }
}

/// A browser window's Back / Forward history (NavigationHistory, Core), observed
/// by its toolbar and published to the Go menu.
final class BrowserNavigation: ObservableObject {
    @Published private(set) var history = NavigationHistory()

    func visit(_ url: URL) {
        visit(.folder(url))
    }

    func visit(_ location: BrowserLocation) {
        var next = history
        next.visit(location)
        if next != history { history = next }
    }

    /// The location to show for Back, skipping folders that are gone; nil if none.
    func back() -> BrowserLocation? { history.goBack(exists: { $0.folder.map(FileItem.isBrowsableFolder) ?? false }) }

    func forward() -> BrowserLocation? { history.goForward(exists: { $0.folder.map(FileItem.isBrowsableFolder) ?? false }) }

    /// The window moved to `location` (NavigationHistory.arrive).
    func arrive(at location: BrowserLocation, columnSelection: BrowserLocation?) {
        var next = history
        next.arrive(at: location, columnSelection: columnSelection)
        if next != history { history = next }
    }

    func arrive(at url: URL, columnSelection: URL?) {
        arrive(at: .folder(url), columnSelection: columnSelection.map(BrowserLocation.folder))
    }
}

/// Whether text has keyboard focus in the key window (a text field or text view,
/// including the toolbar's search field, which can't carry `browserTextInput()`).
/// Kept up to date as focus moves, so Edit ▸ Undo / Redo leave ⌘Z to the text
/// from the moment a field takes focus (see BrowserEditCommands).
final class TextInputObserver: ObservableObject {
    static let shared = TextInputObserver()
    @Published private(set) var isActive = false
    private weak var window: NSWindow?
    private var responderObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                               queue: .main) { [weak self] note in
                self?.watch(note.object as? NSWindow)
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                               queue: .main) { [weak self] note in
                if let self, (note.object as? NSWindow) === self.window { self.watch(nil) }
            },
            // Editing can start or end without the first responder changing.
            center.addObserver(forName: NSControl.textDidBeginEditingNotification, object: nil,
                               queue: .main) { [weak self] _ in self?.refresh() },
            center.addObserver(forName: NSControl.textDidEndEditingNotification, object: nil,
                               queue: .main) { [weak self] _ in self?.refresh() },
        ]
        watch(NSApp.keyWindow)
    }

    private func watch(_ window: NSWindow?) {
        responderObservation = nil
        self.window = window
        responderObservation = window?.observe(\.firstResponder) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        let active = MainActor.assumeIsolated { TextInputFocus.focus(in: window).isTextInput }
        if active != isActive { isActive = active }
    }
}

/// A window's "reload after a file operation" callback, for owners that outlive
/// the call: the undo history keeps one with every step. They hold this relay,
/// not a closure capturing the window's view, and the window empties it when
/// it closes, so a closed window (and its Spotlight queries) is released.
final class BrowserReloadRelay {
    var action: (() -> Void)?
    func callAsFunction() { action?() }
}

struct BrowserActionsKey: FocusedValueKey {
    typealias Value = BrowserActions
}

/// Set (true) by the browser's text fields while they have keyboard focus, so
/// Edit ▸ Undo / Redo leave ⌘Z to the text there (see ShellUndoMenuItem).
struct BrowserTextInputFocusKey: FocusedValueKey {
    typealias Value = Bool
}

/// The Locations row selected in the key window's sidebar, when it can be
/// ejected: what Selway ▸ Eject (⌘E) ejects.
struct SidebarEjectVolumeKey: FocusedValueKey {
    typealias Value = SidebarVolume
}

/// The key browser window shows two panes (View ▸ Show / Hide Dual Pane).
struct BrowserIsDualKey: FocusedValueKey {
    typealias Value = Bool
}

/// The key browser window has a tab directly to its right (Window ▸ Merge Tab
/// into Dual Pane).
struct BrowserHasTabToRightKey: FocusedValueKey {
    typealias Value = Bool
}

/// The key window's browser has something selected for File ▸ Open (in
/// Columns view, in the focused column).
struct BrowserHasOpenableSelectionKey: FocusedValueKey {
    typealias Value = Bool
}

/// The ejectable volume selected in the active pane's computer overview.
struct OverviewEjectVolumeKey: FocusedValueKey {
    typealias Value = SidebarVolume
}

extension FocusedValues {
    var browserIsDual: Bool? {
        get { self[BrowserIsDualKey.self] }
        set { self[BrowserIsDualKey.self] = newValue }
    }

    var browserHasTabToRight: Bool? {
        get { self[BrowserHasTabToRightKey.self] }
        set { self[BrowserHasTabToRightKey.self] = newValue }
    }

    var browserHasOpenableSelection: Bool? {
        get { self[BrowserHasOpenableSelectionKey.self] }
        set { self[BrowserHasOpenableSelectionKey.self] = newValue }
    }

    var overviewEjectVolume: SidebarVolume? {
        get { self[OverviewEjectVolumeKey.self] }
        set { self[OverviewEjectVolumeKey.self] = newValue }
    }

    var sidebarEjectVolume: SidebarVolume? {
        get { self[SidebarEjectVolumeKey.self] }
        set { self[SidebarEjectVolumeKey.self] = newValue }
    }

    var browserActions: BrowserActions? {
        get { self[BrowserActionsKey.self] }
        set { self[BrowserActionsKey.self] = newValue }
    }

    var browserTextInputFocused: Bool? {
        get { self[BrowserTextInputFocusKey.self] }
        set { self[BrowserTextInputFocusKey.self] = newValue }
    }
}

extension View {
    /// Marks a text field in a browser window: while it has focus, ⌘Z / ⇧⌘Z
    /// undo typing instead of file operations, and the Edit menu says so.
    func browserTextInput() -> some View {
        focusedValue(\.browserTextInputFocused, true)
    }
}

// MARK: - Text input detection

enum TextInputFocus {
    /// What has keyboard focus in the key window.
    @MainActor
    static func focus() -> ShellResponderKind { focus(in: NSApp.keyWindow) }

    @MainActor
    static func focus(in window: NSWindow?) -> ShellResponderKind {
        guard let responder = window?.firstResponder else { return .none }
        if responder is NSText { return .textView }   // field editor + text views
        if let field = responder as? NSTextField {
            return field.isEditable ? .editableTextField : .nonEditableTextField
        }
        var view = responder as? NSView
        while let v = view {
            if v is WKWebView { return .insideWebView }
            view = v.superview
        }
        return .other
    }

    /// True when the key window's first responder edits or selects text: a
    /// TextField's field editor, an NSTextView, or a web view (the Ace editor).
    /// File shortcuts (⌘C/⌘X/⌘V/⌘Z, Space) must leave those keys to the text.
    @MainActor
    static var isActive: Bool { focus().isTextInput }
}

// MARK: - Edit menu routing

extension ShellEditCommand {
    /// The standard responder-chain action for text views and other windows.
    var selector: Selector {
        switch self {
        case .undo:               return Selector(("undo:"))
        case .redo:               return Selector(("redo:"))
        case .cut:                return #selector(NSText.cut(_:))
        case .copy:               return #selector(NSText.copy(_:))
        case .paste:              return #selector(NSText.paste(_:))
        case .pasteAndMatchStyle: return #selector(NSTextView.pasteAsPlainText(_:))
        case .selectAll:          return #selector(NSText.selectAll(_:))
        case .delete:             return #selector(NSText.delete(_:))
        }
    }
}

@MainActor
enum EditCommandRouter {
    /// File operations run only when a browser window is key and no text input
    /// has focus. Everything else — search field, path editor, inline rename,
    /// sheets, editor / Markdown windows — gets the normal responder-chain action,
    /// exactly as if the default Edit menu were still in place. The decision is
    /// `ShellEditRouting` (Core, tested).
    static func perform(_ command: ShellEditCommand, browser: BrowserActions?) {
        let route = ShellEditRouting.route(
            command,
            hasBrowserActions: browser != nil,
            keyWindowIsBrowser: BrowserWindowRouter.shared.isBrowserWindow(NSApp.keyWindow),
            focus: TextInputFocus.focus())
        if route == .browser, let browser {
            switch command {
            case .undo:               browser.canUndo() ? browser.undo() : NSSound.beep()
            case .redo:               browser.canRedo() ? browser.redo() : NSSound.beep()
            case .cut:                browser.cut()
            case .copy:               browser.copy()
            case .paste:              browser.paste()
            case .selectAll:          browser.selectAll()
            case .pasteAndMatchStyle, .delete: NSSound.beep()
            }
            return
        }
        if !NSApp.sendAction(command.selector, to: nil, from: nil) {
            NSSound.beep()
        }
    }
}

// MARK: - Menu content

/// Replaces the system Undo/Redo and pasteboard (Cut … Select All) groups.
/// The default groups can't be used because the browser needs ⌘C/⌘V/⌘Z for
/// files; routing through `EditCommandRouter` keeps text editing working
/// everywhere else. The pasteboard items stay enabled so the shortcuts keep
/// reaching editor windows, which have no browser actions. Undo / Redo name
/// the file action in a browser window ("Undo Paste") and are disabled there
/// when there is nothing to undo, unless a text field has focus
/// (ShellUndoMenuItem).
struct BrowserEditCommands: Commands {
    @FocusedValue(\.browserActions) private var actions
    @FocusedValue(\.browserTextInputFocused) private var textInputFocused
    /// The focused browser window's file operations, observed so the titles
    /// and enabled state follow its Undo / Redo stacks.
    @FocusedObject private var fileOps: FileOperationsService?
    @ObservedObject private var textInput = TextInputObserver.shared

    private func item(redo: Bool) -> ShellUndoMenuItem {
        ShellUndoMenuItem.make(redo: redo,
                               browserFocused: actions != nil && fileOps != nil,
                               textInputFocused: textInputFocused == true || textInput.isActive,
                               fileActionName: redo ? fileOps?.redoActionName : fileOps?.undoActionName)
    }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            let undo = item(redo: false), redo = item(redo: true)
            Button(undo.title) { EditCommandRouter.perform(.undo, browser: actions) }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!undo.isEnabled)
            Button(redo.title) { EditCommandRouter.perform(.redo, browser: actions) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!redo.isEnabled)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut")   { EditCommandRouter.perform(.cut, browser: actions) }
                .keyboardShortcut("x", modifiers: .command)
            Button("Copy")  { EditCommandRouter.perform(.copy, browser: actions) }
                .keyboardShortcut("c", modifiers: .command)
            Button("Paste") { EditCommandRouter.perform(.paste, browser: actions) }
                .keyboardShortcut("v", modifiers: .command)
            Button("Paste and Match Style") {
                EditCommandRouter.perform(.pasteAndMatchStyle, browser: actions)
            }
            .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            // The system group had Delete (no shortcut: the Delete key itself
            // goes to the focused text). It only ever acts on text; moving files
            // to the Trash is a separate, explicit command.
            Button("Delete") { EditCommandRouter.perform(.delete, browser: actions) }
            Button("Select All") { EditCommandRouter.perform(.selectAll, browser: actions) }
                .keyboardShortcut("a", modifiers: .command)

            Divider()

            // The toolbar's search field: the toolbar shown, the field put back if
            // it was customized away, and focused (ToolbarSearchField.focus).
            Button("Find…") { BrowserActions.perform(actions) { $0.find() } }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
        }
    }
}
