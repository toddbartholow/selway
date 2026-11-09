import SwiftUI
import AppKit

// SearchScope lives in Core/SearchMatching.swift.

/// The browser window's search: the field at the end of the toolbar, and while
/// searching a scope bar under it ("This Folder", "Entire Mac"…), as in Finder.
/// The field shows and edits the active pane's search; the pane runs it
/// (PaneSearchChanges reacts to the query and scope, PaneState.runSearch).
struct BrowserSearch: ViewModifier {
    /// Read in `body` for the active pane, so a pane switch re-renders only
    /// this modifier, not the window.
    let panes: BrowserPanes
    /// Return in the field: after searching, the results take keyboard focus.
    var onSubmit: () -> Void = {}

    func body(content: Content) -> some View {
        let pane = panes.active
        content.modifier(PaneSearchField(pane: pane, searchEngine: pane.searchEngine, onSubmit: onSubmit))
    }
}

/// The field and scope bar, bound to one pane's search engine, which it
/// observes. No `.onChange` here: when the active pane changes the values
/// bound change with it, and a reaction here would run (or clear) a search
/// in the pane just switched to.
private struct PaneSearchField: ViewModifier {
    let pane: PaneState
    @ObservedObject var searchEngine: SearchEngine
    let onSubmit: () -> Void

    func body(content: Content) -> some View {
        content
            .searchable(text: $searchEngine.query, placement: .toolbar, prompt: "Name or .ext (e.g. .pdf)")
            .searchScopes($searchEngine.selectedScope) {
                ForEach(SearchScope.allCases, id: \.self) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .onSubmit(of: .search) {
                pane.runSearch()
                onSubmit()
            }
    }
}

// MARK: - The toolbar's search field (AppKit side)

@MainActor
enum ToolbarSearchField {
    /// Edit ▸ Find… (⌘F): shows the toolbar if it's hidden, puts the search field
    /// back if it was customized away, and focuses it. False if there's no field.
    @discardableResult
    static func focus(in window: NSWindow?) -> Bool {
        guard let window, let toolbar = window.toolbar else { return false }
        let wasHidden = !toolbar.isVisible
        if wasHidden { toolbar.isVisible = true }
        if let item = item(in: toolbar), !wasHidden {
            item.beginSearchInteraction()
            return true
        }
        if item(in: toolbar) == nil {
            // Put back for good: browser windows share one toolbar configuration
            // (autosaved), so the field returns in every browser window, and stays.
            guard let id = identifier(in: toolbar) else { return false }
            toolbar.insertItem(withItemIdentifier: id, at: toolbar.items.count)
        }
        // A toolbar just shown, or an item just added, is laid out over the next
        // passes (with an animation); focus once it's there.
        for delay in [0.0, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if !isEditing(in: window) { item(in: toolbar)?.beginSearchInteraction() }
            }
        }
        return true
    }

    /// Keeps the search item in the toolbar when space runs short (large text
    /// sizes widen the sidebar): other items go to » first. Short of room the
    /// toolbar still shows it as a button, which opens the field (as ⌘F does).
    /// Set as each search item is added, including after customizing.
    static func keepVisible() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSToolbar.willAddItemNotification, object: nil, queue: .main) { note in
            if let item = note.userInfo?["item"] as? NSSearchToolbarItem {
                MainActor.assumeIsolated { prioritize(item) }
            }
        }
        for window in NSApp.windows {
            window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.forEach(prioritize)
        }
    }

    private static func prioritize(_ item: NSSearchToolbarItem) {
        item.visibilityPriority = .high
        item.preferredWidthForSearchField = 180
    }

    private static func item(in toolbar: NSToolbar) -> NSSearchToolbarItem? {
        toolbar.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first
    }

    private static var knownIdentifier: NSToolbarItem.Identifier?

    /// The search item's identifier, asked of the toolbar's own delegate. The one
    /// found before is used again only while this toolbar still allows it.
    private static func identifier(in toolbar: NSToolbar) -> NSToolbarItem.Identifier? {
        guard let delegate = toolbar.delegate,
              let allowed = delegate.toolbarAllowedItemIdentifiers?(toolbar) else { return nil }
        if let knownIdentifier, allowed.contains(knownIdentifier) { return knownIdentifier }
        knownIdentifier = allowed.first {
            delegate.toolbar?(toolbar, itemForItemIdentifier: $0, willBeInsertedIntoToolbar: false)
                is NSSearchToolbarItem
        }
        return knownIdentifier
    }

    /// The search field of `window`'s toolbar, if it is the one being typed in.
    static func isEditing(in window: NSWindow?) -> Bool {
        guard let editor = window?.firstResponder as? NSTextView,
              let field = editor.delegate as? NSSearchField else { return false }
        return field.window === window && !(window?.contentView.map(field.isDescendant(of:)) ?? false)
    }

    /// ↓ in the search field moves to the results; Escape clears the search and
    /// leaves the field (one press). Return is the field's own: it searches, then
    /// BrowserSearch's onSubmit moves on. Returns the monitor, for removing.
    ///
    /// The monitor sees keys before the input method. While a Japanese or Chinese
    /// composition is open (marked text), ↓ picks a candidate and Escape cancels
    /// the composition, so both are left to it. Return needs no check: an input
    /// method takes it to commit the composition, so it never reaches the field's
    /// action (and onSubmit).
    static func installKeys(window: @escaping () -> NSWindow?,
                            toResults: @escaping () -> Void,
                            clear: @escaping () -> Void) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let w = window(), event.window === w, isEditing(in: w),
                  (w.firstResponder as? NSTextView)?.hasMarkedText() != true else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard modifiers.isEmpty else { return event }
            switch event.keyCode {
            case 125:                  // ↓
                toResults()
                return nil
            case 53:                   // Escape
                clear()
                // Once the list shows the folder again (in Columns view the results
                // list gives way to the column browser).
                DispatchQueue.main.async { toResults() }
                return nil
            default:
                return event
            }
        }
    }
}
