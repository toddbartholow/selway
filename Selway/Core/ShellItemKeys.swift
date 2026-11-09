import Foundation

// MARK: - Return, ⌘O and ⌘↓ on the selection

/// The keys that rename or open the selected items, as in Finder: Return (or
/// the keypad's Enter) renames the one item selected and does nothing to
/// several; ⌘O and ⌘↓ open everything selected. The views say which key was
/// pressed, what is selected and whether text has the keys; this says what
/// happens (ShellItemKeyAction).
enum ShellItemKey: Equatable {
    /// Return or Enter, with no modifiers.
    case rename
    /// ⌘O or ⌘↓.
    case open

    /// The keys held with a press. Caps Lock and the numeric-pad and function
    /// flags (which the arrow keys carry) aren't among them.
    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let shift   = Modifiers(rawValue: 1 << 1)
        static let option  = Modifiers(rawValue: 1 << 2)
        static let control = Modifiers(rawValue: 1 << 3)
    }

    /// The key typed: its characters without modifiers, as AppKit reports them
    /// (Return "\r", the keypad's Enter "\u{3}", ↓ U+F701), and the keys held.
    /// `latinCharacters` is what the same key types on a Latin layout, read
    /// only when the layout in use types something else (needsLatinCharacters):
    /// on a Russian or Greek layout, ⌘ with the key in O's place is ⌘O, as
    /// menus take it. A Latin layout's own letters win, so Dvorak's ⌘O is still
    /// its O key. Nil for any other key.
    static func key(characters: String, latinCharacters: String? = nil, modifiers: Modifiers) -> ShellItemKey? {
        if let key = key(typed: characters, modifiers: modifiers) { return key }
        guard let latinCharacters, needsLatinCharacters(characters, modifiers: modifiers) else { return nil }
        return key(typed: latinCharacters, modifiers: modifiers)
    }

    /// The key typed, as above, from its key code (nil when unknown):
    /// `latinLayout` says what a key code types on the Mac's Latin layout, or
    /// nil if that can't be read (ansiCharacters then stands in). It's asked
    /// only when needsLatinCharacters says so, which is rarely.
    static func key(characters: String, modifiers: Modifiers, keyCode: Int?,
                    latinLayout: (Int) -> String?) -> ShellItemKey? {
        var latin: String?
        if let keyCode, needsLatinCharacters(characters, modifiers: modifiers) {
            latin = latinLayout(keyCode) ?? ansiCharacters(forKeyCode: keyCode)
        }
        return key(characters: characters, latinCharacters: latin, modifiers: modifiers)
    }

    /// Whether a key's `characters` (without modifiers) are worth reading on a
    /// Latin layout too: with ⌘ held, for a letter that isn't ASCII. Not the
    /// arrow and function keys (U+F700 to U+F8FF), which are the same on every
    /// layout, and not keys typed without ⌘, which type-select in that layout.
    static func needsLatinCharacters(_ characters: String, modifiers: Modifiers) -> Bool {
        guard modifiers.contains(.command), !characters.isEmpty else { return false }
        let scalars = characters.unicodeScalars
        return scalars.contains { !$0.isASCII }
            && !scalars.contains { $0.properties.generalCategory == .privateUse }
    }

    /// What the key with `keyCode` types on the ANSI (US) layout, for when the
    /// Mac's Latin layout can't be read. Only O's key (kVK_ANSI_O, 0x1F): the
    /// one letter among these keys.
    static func ansiCharacters(forKeyCode keyCode: Int) -> String? {
        keyCode == 0x1F ? "o" : nil
    }

    private static func key(typed characters: String, modifiers: Modifiers) -> ShellItemKey? {
        switch characters {
        case "\r", "\u{3}":
            return modifiers.isEmpty ? .rename : nil
        case "\u{F701}", "o", "O":
            return modifiers == .command ? .open : nil
        default:
            return nil
        }
    }

    /// What the key does to `selected` (in the order shown). `textHasFocus` (a
    /// rename field, the search field, the path editor) and `renaming` (an
    /// inline rename already open) leave the key to the text: Return there
    /// commits the name.
    func action<ID: Equatable>(selected: [ID], textHasFocus: Bool, renaming: Bool) -> ShellItemKeyAction<ID> {
        guard !textHasFocus, !renaming, let first = selected.first else { return .pass }
        switch self {
        case .rename: return selected.count == 1 ? .rename(first) : .ignore
        case .open:   return .open(selected)
        }
    }
}

/// What Return, ⌘O or ⌘↓ does (ShellItemKey.action).
enum ShellItemKeyAction<ID: Equatable>: Equatable {
    /// Start renaming this item.
    case rename(ID)
    /// Open these items.
    case open([ID])
    /// Take the key and do nothing: Return with several items selected, which
    /// a list would otherwise take as Open.
    case ignore
    /// Not the selection's: the key goes on to whatever else takes it.
    case pass

    /// Whether the view takes the key (anything but `pass`).
    var isHandled: Bool { self != .pass }
}

// MARK: - File ▸ Open

/// File ▸ Open (⌘O), as in Finder: opens the key browser window's selection
/// the way ⌘O does in its view (ShellItemKey.open): Columns view goes into a
/// folder as the next column, List and Icons view open it in the window. The
/// lists take ⌘O themselves while they have the keys, before the menu sees it;
/// the menu item is how the mouse opens the selection, and how ⌘O does from
/// elsewhere in the window (the sidebar, say).
enum ShellOpenCommand: Equatable {
    /// Open the selection.
    case selection
    /// Leave ⌘O to the text with focus, as it was before the menu item.
    case text
    /// Do nothing: a held ⌘O's repeats. The lists pass those on (a held ⌘↓
    /// would open folder after folder), and the menu doesn't drop them.
    case ignore

    /// What choosing the item does. `key` is the key that chose it (nil for
    /// the mouse, or another key: Return in a menu reached with ⌃F2 or
    /// VoiceOver), and `isRepeat` whether that's a held key's repeat. ⌘O typed
    /// while text has focus is the text's: it took focus after the menu was
    /// built, so the item still had the key (hasShortcut). Chosen any other
    /// way, it opens the selection.
    static func route(textHasFocus: Bool, key: ShellItemKey?, isRepeat: Bool) -> ShellOpenCommand {
        if isRepeat { return .ignore }
        return textHasFocus && key == .open ? .text : .selection
    }

    /// Whether the item carries ⌘O. A menu item takes its key even when it's
    /// disabled, so it has none while text has focus (a rename, the search
    /// field, the path editor) or no browser window is key (an editor
    /// window): ⌘O goes to them, as before.
    static func hasShortcut(browserIsKey: Bool, textHasFocus: Bool) -> Bool {
        browserIsKey && !textHasFocus
    }

    /// Whether the item is enabled: a browser window is key and has something
    /// selected where Open acts (in Columns view, the focused column).
    static func isEnabled(browserIsKey: Bool, hasSelection: Bool) -> Bool {
        browserIsKey && hasSelection
    }
}
