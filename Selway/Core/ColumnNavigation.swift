import Foundation

enum ColumnNavigation {
    /// The column a menu command (Edit ▸ Select All, File ▸ Open) acts on, of
    /// `count`: the focused one, else the one last selected in (the sidebar or
    /// a text field has the keys), else the last one shown.
    static func commandPane(focused: Int?, active: Int?, count: Int) -> Int? {
        focused ?? active ?? (count > 0 ? count - 1 : nil)
    }

    /// Finds the next name beginning with `query`, wrapping after the current row.
    /// `includingSelected` looks at the current row first: a query still being
    /// typed ("be" after "b") keeps it while it matches.
    static func typeToSelect(_ query: String, names: [String], selectedIndex: Int?,
                             includingSelected: Bool = false) -> Int? {
        guard !query.isEmpty, !names.isEmpty else { return nil }
        let start = selectedIndex.flatMap { names.indices.contains($0) ? $0 : nil } ?? -1
        let steps = includingSelected && start >= 0 ? 0..<names.count : 1..<(names.count + 1)
        for step in steps {
            let index = (start + step) % names.count
            let name = names[index]
            guard name.count >= query.count else { continue }
            let prefix = name.prefix(query.count)
            if prefix.compare(query, options: [.caseInsensitive, .diacriticInsensitive],
                              locale: .current) == .orderedSame {
                return index
            }
        }
        return nil
    }

    /// What a press on row `id` does to its column's selection (`selection`,
    /// ids; `order`, the rows' ids as shown, is read only for ⇧). ⇧ selects
    /// the rows from `anchor` (the row last clicked without ⇧, while it is
    /// still selected; otherwise the first selected row) through this one,
    /// in place of the selection; with nothing selected it is a plain click.
    /// ⌘ adds the row at once, or takes a selected one out when the button
    /// comes up without a drag (`deselectLater`), so a ⌘-drag from it carries
    /// every selected row. A plain press selects the row alone, except on a
    /// row inside a larger selection: that keeps the selection until the
    /// button comes up without a drag and the double-click interval has
    /// passed (`narrowLater`), so a drag from it carries every selected row
    /// and a double-click there opens them all, as in Finder and the icon
    /// grid (ShellPressRelease). ⇧ wins over ⌘.
    static func click(on id: String, selection: Set<String>, modifiers: ShellIconClick.Modifiers,
                      anchor: String?, order: @autoclosure () -> [String]) -> ShellIconClick {
        if extends(selection, modifiers: modifiers) {
            let order = order()
            let start = anchor.flatMap { selection.contains($0) ? order.firstIndex(of: $0) : nil }
                ?? order.firstIndex(where: selection.contains)
            guard let start, let end = order.firstIndex(of: id) else { return .keep }
            let range = Set(order[min(start, end)...max(start, end)])
            return range == selection ? .keep : .select(range)
        }
        if modifiers.contains(.command) {
            return ShellIconClick.toggle(id, in: selection)
        }
        return ShellIconClick.click(on: id, selection: selection)
    }

    /// ↑ or ↓ (`down`) from row `id` selected alone, as the list moves from
    /// one selected row: the row next to it, or with ⇧ (`extending`) both of
    /// them. At either end the row stays selected alone. For a key that comes
    /// while a click on `id` inside a larger selection waits to narrow it
    /// (ShellPressRelease.flush): the list would move from the whole selection.
    static func step(from id: String, order: [String], down: Bool, extending: Bool) -> Set<String> {
        guard let index = order.firstIndex(of: id) else { return [id] }
        let next = down ? index + 1 : index - 1
        guard order.indices.contains(next) else { return [id] }
        return extending ? [id, order[next]] : [order[next]]
    }

    /// Whether a click with `modifiers` extends `selection` with ⇧ (see
    /// `click`). Every other click makes its row the anchor.
    static func extends(_ selection: Set<String>, modifiers: ShellIconClick.Modifiers) -> Bool {
        modifiers.contains(.shift) && !selection.isEmpty
    }

    /// Whether a key's characters can be typed into a type-select query: printable
    /// text. Not Escape, Delete, Tab or Return (control characters), not the arrow
    /// and function keys (AppKit gives those private-use characters, U+F700–U+F8FF),
    /// and not a space on its own (Quick Look), which `TypeSelectBuffer` takes only
    /// in the middle of a query.
    static func isTypeSelectInput(_ characters: String) -> Bool {
        guard !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .privateUse, .format, .surrogate, .unassigned,
                 .lineSeparator, .paragraphSeparator, .spaceSeparator:
                return false
            default:
                return true
            }
        }
    }
}

/// The query typed so far for type-to-select, as Finder keeps it: keys typed
/// within `timeout` of each other add to it, and the same single letter typed
/// again starts over, so "b", "b" moves through the names starting with B.
struct TypeSelectBuffer {
    static let timeout: TimeInterval = 1.0

    private(set) var query = ""
    private var lastKeyAt = Date.distantPast

    /// True while a query is being typed: a space then belongs to it.
    func isTyping(at now: Date) -> Bool {
        !query.isEmpty && now.timeIntervalSince(lastKeyAt) <= Self.timeout
    }

    /// Adds `characters` typed at `now` and returns the query to look for.
    mutating func type(_ characters: String, at now: Date) -> String {
        let repeated = query.count == 1 &&
            query.compare(characters, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        if !isTyping(at: now) || repeated {
            query = characters
        } else {
            query += characters
        }
        lastKeyAt = now
        return query
    }
}
