import Foundation

// Decision logic behind BrowserWindowRouter and the Edit menu routing, kept
// free of AppKit so it can be tested.

// MARK: - External open batching

/// Groups external "open this folder" requests that arrive back to back.
/// Open With on a multi-selection delivers one request per item within a few
/// milliseconds: the first navigates the target window, the rest open windows
/// of their own. Several files from one folder all reveal that same folder,
/// so a folder already delivered in the current batch is dropped instead of
/// opening one identical window per file.
struct ShellOpenBatch {
    enum Placement: Equatable {
        /// Starts a new batch: navigate the target window.
        case first
        /// Another folder in the same batch: open a new window.
        case additional
        /// Already delivered in this batch: ignore.
        case duplicate
        /// The batch already opened `maxAdditional` windows: ignore. A web page can
        /// fire selway:// links as fast as it likes, and each would be a window.
        case overLimit
    }

    /// Requests closer together than this belong to the same batch. The
    /// window slides: each request extends it.
    let window: TimeInterval
    /// New windows one batch may open (besides the window it navigates).
    let maxAdditional: Int
    private var lastRequest: Date = .distantPast
    private var delivered: [URL] = []

    init(window: TimeInterval = 0.5, maxAdditional: Int = 20) {
        self.window = window
        self.maxAdditional = maxAdditional
    }

    mutating func place(_ url: URL, at now: Date = Date()) -> Placement {
        let sameBatch = now.timeIntervalSince(lastRequest) < window
        lastRequest = now
        if !sameBatch { delivered = [] }
        if ShellPath.contains(delivered, url) { return .duplicate }
        if sameBatch, delivered.count > maxAdditional { return .overLimit }
        delivered.append(url)
        return sameBatch ? .additional : .first
    }
}

// MARK: - Link dialogs

/// Limits the dialogs selway:// links can raise (a confirmation, or an error
/// about the request): any web page can fire those links, as fast as it likes,
/// and each dialog would need dismissing. One at a time, and at most
/// `maxPrompts` in any `period`; requests beyond that are dropped.
struct ShellLinkPromptLimiter {
    let maxPrompts: Int
    let period: TimeInterval
    private var shown: [Date] = []
    private(set) var isShowing = false

    init(maxPrompts: Int = 3, period: TimeInterval = 10) {
        self.maxPrompts = maxPrompts
        self.period = period
    }

    /// True when a dialog may be shown now; call `end` once it is dismissed.
    mutating func begin(at now: Date = Date()) -> Bool {
        guard !isShowing else { return false }
        shown.removeAll { now.timeIntervalSince($0) >= period }
        guard shown.count < maxPrompts else { return false }
        shown.append(now)
        isShowing = true
        return true
    }

    mutating func end() { isShowing = false }
}

// MARK: - Edit menu routing

/// Edit-menu commands Selway routes itself (it replaces the system
/// Undo/Redo and pasteboard groups so ⌘C/⌘V/⌘Z can act on files).
enum ShellEditCommand: CaseIterable {
    case undo, redo, cut, copy, paste, pasteAndMatchStyle, selectAll, delete

    /// False for commands that only ever mean something to text (Edit ▸ Delete
    /// deletes the text selection; moving files to the Trash is a separate,
    /// explicit command).
    var hasFileAction: Bool { self != .delete }
}

/// What kind of object has keyboard focus in the key window.
enum ShellResponderKind: Equatable {
    case none
    /// A text view or a text field's field editor.
    case textView
    case editableTextField
    case nonEditableTextField
    /// Any view inside a web view (the Ace code editor).
    case insideWebView
    case other

    /// File shortcuts (⌘C/⌘X/⌘V/⌘Z, Space) must leave these to the text.
    var isTextInput: Bool {
        switch self {
        case .textView, .editableTextField, .insideWebView: return true
        case .none, .nonEditableTextField, .other:           return false
        }
    }
}

enum ShellEditRoute: Equatable {
    /// Run the key browser window's file action.
    case browser
    /// Send the standard action down the responder chain (text editing,
    /// editor windows, sheets).
    case responderChain
}

enum ShellEditRouting {
    /// File actions run only when a browser window itself is key (not a sheet
    /// on it, the Quick Look panel or an editor window), it published its
    /// actions, and no text input has focus.
    static func fileActionsAllowed(hasBrowserActions: Bool,
                                   keyWindowIsBrowser: Bool,
                                   focus: ShellResponderKind) -> Bool {
        hasBrowserActions && keyWindowIsBrowser && !focus.isTextInput
    }

    static func route(_ command: ShellEditCommand,
                      hasBrowserActions: Bool,
                      keyWindowIsBrowser: Bool,
                      focus: ShellResponderKind) -> ShellEditRoute {
        guard command.hasFileAction,
              fileActionsAllowed(hasBrowserActions: hasBrowserActions,
                                 keyWindowIsBrowser: keyWindowIsBrowser,
                                 focus: focus)
        else { return .responderChain }
        return .browser
    }
}

// MARK: - Undo / Redo menu items

/// Title and state of Edit ▸ Undo and Edit ▸ Redo.
///
/// In a browser window they act on files: "Undo Paste", enabled only when
/// there is something to undo. Everywhere else — editor windows, and a text
/// field in the browser (search, path editor, inline rename) — ⌘Z belongs to
/// the text, whose undo state Selway can't see, so the item stays a plain,
/// enabled "Undo" and the responder chain decides.
struct ShellUndoMenuItem: Equatable {
    let title: String
    let isEnabled: Bool

    /// - Parameters:
    ///   - redo: Redo instead of Undo.
    ///   - browserFocused: a browser window is the focused scene.
    ///   - textInputFocused: a text field in it has keyboard focus.
    ///   - fileActionName: what the file Undo / Redo would reverse ("Paste"),
    ///     nil when there is nothing (or one is still running).
    static func make(redo: Bool, browserFocused: Bool, textInputFocused: Bool,
                     fileActionName: String?) -> ShellUndoMenuItem {
        let verb = redo
            ? NSLocalizedString("Redo", comment: "Redo menu item title")
            : NSLocalizedString("Undo", comment: "Undo menu item title")
        guard browserFocused, !textInputFocused else { return ShellUndoMenuItem(title: verb, isEnabled: true) }
        guard let name = fileActionName else { return ShellUndoMenuItem(title: verb, isEnabled: false) }
        guard !name.isEmpty else { return ShellUndoMenuItem(title: verb, isEnabled: true) }
        let title = redo
            ? String.localizedStringWithFormat(NSLocalizedString("Redo %@", comment: "Redo menu item title with file action"), name)
            : String.localizedStringWithFormat(NSLocalizedString("Undo %@", comment: "Undo menu item title with file action"), name)
        return ShellUndoMenuItem(title: title, isEnabled: true)
    }
}
