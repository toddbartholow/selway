import Foundation
import Testing
@testable import SelwayCore

/// Issue #26: Return renames the selected item, as in Finder, rather than
/// opening it; ⌘O and ⌘↓ open.
@Suite struct ShellItemKeysTests {
    @Test func returnAndEnterRename() {
        #expect(ShellItemKey.key(characters: "\r", modifiers: []) == .rename)
        #expect(ShellItemKey.key(characters: "\u{3}", modifiers: []) == .rename)
    }

    @Test func commandOAndCommandDownOpen() {
        #expect(ShellItemKey.key(characters: "o", modifiers: .command) == .open)
        #expect(ShellItemKey.key(characters: "O", modifiers: .command) == .open)
        #expect(ShellItemKey.key(characters: "\u{F701}", modifiers: .command) == .open)
    }

    /// ⌘↑ is Go ▸ Enclosing Folder, a plain ↓ moves the selection, ⇧⌘O and
    /// ⌥Return are other shortcuts: none of them is the selection's.
    @Test func otherKeysAndModifiersAreNotTheSelections() {
        #expect(ShellItemKey.key(characters: "\r", modifiers: .command) == nil)
        #expect(ShellItemKey.key(characters: "\r", modifiers: .option) == nil)
        #expect(ShellItemKey.key(characters: "\r", modifiers: .shift) == nil)
        #expect(ShellItemKey.key(characters: "o", modifiers: []) == nil)
        #expect(ShellItemKey.key(characters: "o", modifiers: [.command, .shift]) == nil)
        #expect(ShellItemKey.key(characters: "\u{F701}", modifiers: []) == nil)
        #expect(ShellItemKey.key(characters: "\u{F701}", modifiers: [.command, .option]) == nil)
        #expect(ShellItemKey.key(characters: "\u{F700}", modifiers: .command) == nil)
        #expect(ShellItemKey.key(characters: " ", modifiers: []) == nil)
        #expect(ShellItemKey.key(characters: "", modifiers: []) == nil)
    }

    /// Issue #40: on a Russian or Greek layout ⌘ with the key in O's place
    /// types that layout's letter; the key's Latin character makes it ⌘O.
    @Test func commandOOpensOnANonLatinLayout() {
        #expect(ShellItemKey.key(characters: "щ", latinCharacters: "o", modifiers: .command) == .open)
        #expect(ShellItemKey.key(characters: "ο", latinCharacters: "o", modifiers: .command) == .open)
        #expect(ShellItemKey.key(characters: "Щ", latinCharacters: "O", modifiers: .command) == .open)
        // Without the Latin character (or with another key's) it's no shortcut.
        #expect(ShellItemKey.key(characters: "щ", modifiers: .command) == nil)
        #expect(ShellItemKey.key(characters: "ц", latinCharacters: "w", modifiers: .command) == nil)
    }

    /// The layout's own letter without ⌘ type-selects, so it's never Open;
    /// nor is ⇧⌘ with it.
    @Test func aNonLatinLetterWithoutCommandIsNotOpen() {
        #expect(ShellItemKey.key(characters: "щ", latinCharacters: "o", modifiers: []) == nil)
        #expect(ShellItemKey.key(characters: "щ", latinCharacters: "o", modifiers: .shift) == nil)
        #expect(ShellItemKey.key(characters: "щ", latinCharacters: "o", modifiers: [.command, .shift]) == nil)
        #expect(!ShellItemKey.needsLatinCharacters("щ", modifiers: []))
    }

    /// A Latin layout's letters are what they say: on Dvorak the key in O's
    /// ANSI place types "r", and ⌘ with it is ⌘R, not Open.
    @Test func aLatinLayoutsOwnLetterWins() {
        #expect(ShellItemKey.key(characters: "r", latinCharacters: "o", modifiers: .command) == nil)
        #expect(!ShellItemKey.needsLatinCharacters("r", modifiers: .command))
        #expect(ShellItemKey.key(characters: "o", latinCharacters: "s", modifiers: .command) == .open)
    }

    /// The arrow keys are the same on every layout: ⌘↓ opens and ⌘↑ doesn't,
    /// whatever their Latin characters.
    @Test func arrowKeysNeedNoLatinCharacters() {
        #expect(!ShellItemKey.needsLatinCharacters("\u{F701}", modifiers: .command))
        #expect(!ShellItemKey.needsLatinCharacters("\u{F700}", modifiers: .command))
        #expect(ShellItemKey.key(characters: "\u{F700}", latinCharacters: "o", modifiers: .command) == nil)
        #expect(ShellItemKey.key(characters: "\u{F701}", latinCharacters: "x", modifiers: .command) == .open)
        #expect(!ShellItemKey.needsLatinCharacters("", modifiers: .command))
    }

    @Test func ansiCharactersKnowOnlyOsKey() {
        #expect(ShellItemKey.ansiCharacters(forKeyCode: 0x1F) == "o")
        #expect(ShellItemKey.ansiCharacters(forKeyCode: 0x0F) == nil)  // kVK_ANSI_R
    }

    /// From a key event: the Latin layout is asked for ⌘ with a non-ASCII
    /// letter, and only then; the ANSI O key stands in when it can't be read.
    @Test func aKeyEventReadsTheLatinLayoutOnlyWhenNeeded() {
        var asked: [Int] = []
        let layout: (Int) -> String? = { code in asked.append(code); return code == 0x1F ? "o" : "x" }
        #expect(ShellItemKey.key(characters: "щ", modifiers: .command, keyCode: 0x1F, latinLayout: layout) == .open)
        #expect(asked == [0x1F])
        #expect(ShellItemKey.key(characters: "ц", modifiers: .command, keyCode: 0x0D, latinLayout: layout) == nil)
        #expect(asked == [0x1F, 0x0D])

        asked = []
        #expect(ShellItemKey.key(characters: "o", modifiers: .command, keyCode: 0x1F, latinLayout: layout) == .open)
        #expect(ShellItemKey.key(characters: "щ", modifiers: [], keyCode: 0x1F, latinLayout: layout) == nil)
        #expect(ShellItemKey.key(characters: "\u{F701}", modifiers: .command, keyCode: 0x7D, latinLayout: layout)
                == .open)
        #expect(asked.isEmpty)

        // No Latin layout to read: the ANSI O key is still ⌘O.
        #expect(ShellItemKey.key(characters: "щ", modifiers: .command, keyCode: 0x1F, latinLayout: { _ in nil })
                == .open)
        // No key code (a KeyPress outside a key event): only the characters count.
        #expect(ShellItemKey.key(characters: "щ", modifiers: .command, keyCode: nil, latinLayout: layout) == nil)
        #expect(asked.isEmpty)
    }

    @Test func returnRenamesTheOneItemSelected() {
        #expect(ShellItemKey.rename.action(selected: ["a"], textHasFocus: false, renaming: false) == .rename("a"))
    }

    /// Finder does nothing; the key is still taken, so a list doesn't open them.
    @Test func returnWithSeveralSelectedIsTakenAndDoesNothing() {
        let action = ShellItemKey.rename.action(selected: ["a", "b"], textHasFocus: false, renaming: false)
        #expect(action == .ignore)
        #expect(action.isHandled)
    }

    @Test func openOpensEverythingSelectedInOrder() {
        #expect(ShellItemKey.open.action(selected: ["b", "a"], textHasFocus: false, renaming: false)
                == .open(["b", "a"]))
        #expect(ShellItemKey.open.action(selected: ["a"], textHasFocus: false, renaming: false) == .open(["a"]))
    }

    @Test func nothingSelectedPassesTheKeyOn() {
        let none: [String] = []
        #expect(ShellItemKey.rename.action(selected: none, textHasFocus: false, renaming: false) == .pass)
        #expect(ShellItemKey.open.action(selected: none, textHasFocus: false, renaming: false) == .pass)
        #expect(!ShellItemKeyAction<String>.pass.isHandled)
    }

    /// Return in the rename field commits the name; in the search field or
    /// the path editor it's theirs too.
    @Test func textWithTheKeysKeepsThem() {
        for key in [ShellItemKey.rename, .open] {
            #expect(key.action(selected: ["a"], textHasFocus: true, renaming: false) == .pass)
            #expect(key.action(selected: ["a"], textHasFocus: false, renaming: true) == .pass)
        }
    }
}

/// Issue #39: File ▸ Open (⌘O) in the menu bar.
@Suite struct ShellOpenCommandTests {
    /// ⌘O typed in text that took focus after the menu was built stays the
    /// text's; chosen with the mouse, Open opens the selection.
    @Test func typedKeysInTextAreTheTexts() {
        #expect(ShellOpenCommand.route(textHasFocus: true, key: .open, isRepeat: false) == .text)
        #expect(ShellOpenCommand.route(textHasFocus: true, key: nil, isRepeat: false) == .selection)
        #expect(ShellOpenCommand.route(textHasFocus: false, key: .open, isRepeat: false) == .selection)
        #expect(ShellOpenCommand.route(textHasFocus: false, key: nil, isRepeat: false) == .selection)
    }

    /// Return choosing Open in a menu reached with ⌃F2 or VoiceOver isn't
    /// ⌘O: it opens the selection, also while the search field has focus.
    @Test func anotherKeyChoosingOpenOpens() {
        #expect(ShellOpenCommand.route(textHasFocus: true, key: .rename, isRepeat: false) == .selection)
    }

    /// A held ⌘O opens once: its repeats (which the lists pass on) do nothing,
    /// so Columns view doesn't go into folder after folder.
    @Test func aHeldKeysRepeatsDoNothing() {
        #expect(ShellOpenCommand.route(textHasFocus: false, key: .open, isRepeat: true) == .ignore)
        #expect(ShellOpenCommand.route(textHasFocus: true, key: .open, isRepeat: true) == .ignore)
    }

    /// No ⌘O on the item while text has focus or an editor window is key, so
    /// the key goes to them as before.
    @Test func theShortcutIsOnlyForTheFiles() {
        #expect(ShellOpenCommand.hasShortcut(browserIsKey: true, textHasFocus: false))
        #expect(!ShellOpenCommand.hasShortcut(browserIsKey: true, textHasFocus: true))
        #expect(!ShellOpenCommand.hasShortcut(browserIsKey: false, textHasFocus: false))
    }

    @Test func enabledOnlyWithASelection() {
        #expect(ShellOpenCommand.isEnabled(browserIsKey: true, hasSelection: true))
        #expect(!ShellOpenCommand.isEnabled(browserIsKey: true, hasSelection: false))
        #expect(!ShellOpenCommand.isEnabled(browserIsKey: false, hasSelection: true))
    }
}
