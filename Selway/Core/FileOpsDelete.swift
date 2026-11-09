import Foundation

// Move to Trash and Delete Permanently: which one a command runs, whether it
// asks first, and how the menu names it (Settings → Advanced).
//
// ⌘⌫ moves to the Trash and ⌥⌘⌫ deletes permanently, as in Finder. Someone who
// wants ⌘⌫ to delete permanently can swap the two; the items keep their names
// either way, so a menu never says "Move to Trash" for something that deletes.

/// What the user asked for (a menu item, the toolbar or the context menu).
enum FileOpsDeleteCommand: Sendable {
    case moveToTrash, deletePermanently
}

/// The keyboard shortcut a delete command carries in the menu.
enum FileOpsDeleteShortcut: Equatable, Sendable {
    /// ⌘⌫
    case commandDelete
    /// ⌥⌘⌫
    case optionCommandDelete

    var symbols: String {
        switch self {
        case .commandDelete:       return "⌘⌫"
        case .optionCommandDelete: return "⌥⌘⌫"
        }
    }
}

/// What runs, and whether it asks first.
enum FileOpsDeleteAction: Equatable, Sendable {
    case trash(confirm: Bool)
    case deletePermanently(confirm: Bool)
}

struct FileOpsDeletePrefs: Equatable, Sendable {
    static let commandDeleteTrashesKey    = "selwayCommandDeleteTrashes"
    static let confirmTrashKey            = "selwayConfirmTrash"
    static let confirmPermanentDeleteKey  = "selwayConfirmPermanentDelete"

    /// ⌘⌫ moves to the Trash (else it deletes permanently, and ⌥⌘⌫ trashes).
    var commandDeleteTrashes = true
    /// Ask before moving to the Trash. Off by default: Undo puts items back.
    var confirmTrash = false
    /// Ask before deleting permanently. On by default; nothing brings the items back.
    var confirmPermanentDelete = true

    init(commandDeleteTrashes: Bool = true, confirmTrash: Bool = false, confirmPermanentDelete: Bool = true) {
        self.commandDeleteTrashes = commandDeleteTrashes
        self.confirmTrash = confirmTrash
        self.confirmPermanentDelete = confirmPermanentDelete
    }

    /// The stored settings, read as the Settings window's toggles read them;
    /// nothing stored is the default.
    init(_ defaults: UserDefaults) {
        self.init(commandDeleteTrashes: defaults.bool(forKey: Self.commandDeleteTrashesKey, default: true),
                  confirmTrash: defaults.bool(forKey: Self.confirmTrashKey, default: false),
                  confirmPermanentDelete: defaults.bool(forKey: Self.confirmPermanentDeleteKey, default: true))
    }
}

enum FileOpsDeleteDecision {
    static func action(for command: FileOpsDeleteCommand, prefs: FileOpsDeletePrefs) -> FileOpsDeleteAction {
        switch command {
        case .moveToTrash:       return .trash(confirm: prefs.confirmTrash)
        case .deletePermanently: return .deletePermanently(confirm: prefs.confirmPermanentDelete)
        }
    }

    static func shortcut(for command: FileOpsDeleteCommand, prefs: FileOpsDeletePrefs) -> FileOpsDeleteShortcut {
        let trashGetsCommandDelete = prefs.commandDeleteTrashes
        switch command {
        case .moveToTrash:       return trashGetsCommandDelete ? .commandDelete : .optionCommandDelete
        case .deletePermanently: return trashGetsCommandDelete ? .optionCommandDelete : .commandDelete
        }
    }

    /// The menu or toolbar title: an ellipsis when the command asks first.
    static func title(for command: FileOpsDeleteCommand, prefs: FileOpsDeletePrefs) -> String {
        switch action(for: command, prefs: prefs) {
        case .trash(let confirm):
            if confirm {
                return NSLocalizedString("Move to Trash…", comment: "Menu title for moving selected items to the Trash with confirmation")
            }
            return NSLocalizedString("Move to Trash", comment: "Menu title for moving selected items to the Trash without confirmation")
        case .deletePermanently(let confirm):
            if confirm {
                return NSLocalizedString("Delete Permanently…", comment: "Menu title for permanently deleting selected items with confirmation")
            }
            return NSLocalizedString("Delete Permanently", comment: "Menu title for permanently deleting selected items without confirmation")
        }
    }
}

/// Where a delete menu command goes. A menu item's shortcut can arrive after
/// text took focus (the menus step aside for text, but not instantly): typed
/// ⌘⌫ then still edits the text. Chosen with the mouse, it is the file command.
enum FileOpsDeleteRouting: Equatable, Sendable {
    case text, files

    static func route(textHasFocus: Bool, fromKeyboard: Bool) -> FileOpsDeleteRouting {
        textHasFocus && fromKeyboard ? .text : .files
    }
}

// MARK: - Confirmation wording

enum FileOpsDeleteText {
    /// What the toast shows and VoiceOver announces after a Move to Trash.
    static func trashed(_ names: [String]) -> String {
        names.count == 1
            ? String.localizedStringWithFormat(NSLocalizedString("Moved “%@” to the Trash", comment: "Status after moving one item, by name, to the Trash"), names[0])
            : String.localizedStringWithFormat(NSLocalizedString("Moved %lld items to the Trash", comment: "Status after moving several items to the Trash"), names.count)
    }

    static func trashQuestion(_ names: [String]) -> String {
        names.count == 1
            ? String.localizedStringWithFormat(NSLocalizedString("Move “%@” to the Trash?", comment: "Move to Trash confirmation for one item, by name"), names[0])
            : String.localizedStringWithFormat(NSLocalizedString("Move %lld items to the Trash?", comment: "Move to Trash confirmation for several items"), names.count)
    }

    static let trashDetail = NSLocalizedString("You can put items back with Edit → Undo, or from the Trash.", comment: "Move to Trash confirmation detail")

    static func permanentQuestion(_ names: [String]) -> String {
        names.count == 1
            ? String.localizedStringWithFormat(NSLocalizedString("Delete “%@” permanently?", comment: "Delete Permanently confirmation for one item, by name"), names[0])
            : String.localizedStringWithFormat(NSLocalizedString("Delete %lld items permanently?", comment: "Delete Permanently confirmation for several items"), names.count)
    }

    static func permanentDetail(count: Int) -> String {
        count == 1
            ? NSLocalizedString("This item will be deleted immediately. You can’t undo this action, and it won’t be in the Trash.", comment: "Delete Permanently confirmation detail for one item")
            : NSLocalizedString("These items will be deleted immediately. You can’t undo this action, and they won’t be in the Trash.", comment: "Delete Permanently confirmation detail for several items")
    }

    /// Items whose volume has no Trash: offered a permanent delete instead.
    static func noTrashQuestion(_ names: [String]) -> String {
        names.count == 1
            ? String.localizedStringWithFormat(NSLocalizedString("“%@” can’t be moved to the Trash. Delete it permanently?", comment: "Offer to delete one item, by name, on a volume without a Trash"), names[0])
            : String.localizedStringWithFormat(NSLocalizedString("%lld items can’t be moved to the Trash. Delete them permanently?", comment: "Offer to delete several items on a volume without a Trash"), names.count)
    }

    static func noTrashDetail(count: Int) -> String {
        count == 1
            ? NSLocalizedString("The volume it’s on doesn’t have a Trash. Deleting permanently can’t be undone.", comment: "Detail for one item on a volume without a Trash")
            : NSLocalizedString("The volume they’re on doesn’t have a Trash. Deleting permanently can’t be undone.", comment: "Detail for several items on a volume without a Trash")
    }
}

// MARK: - Volumes without a Trash

enum FileOpsTrashSupport {
    /// Whether `error`, from moving an item to the Trash, means its volume has
    /// no Trash (some network shares, and volumes that don't support one):
    /// trying again won't help, but a permanent delete may work.
    static func isNoTrash(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.featureUnsupported.rawValue { return true }
        if ns.domain == NSPOSIXErrorDomain { return ns.code == Int(ENOTSUP) || ns.code == Int(EOPNOTSUPP) }
        // errFSNotAFolder: the volume's Trash (".Trashes") is a file, so it can't
        // be used (macOS reports it under "couldn't be moved to the trash").
        if ns.domain == NSOSStatusErrorDomain && ns.code == -1407 { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isNoTrash(underlying) }
        return false
    }
}
