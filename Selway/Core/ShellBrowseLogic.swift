import Foundation

// MARK: - Context-menu targets

enum ShellSelection {
    /// Finder's rule for what a right-click acts on: the whole selection when the
    /// clicked item is part of it, otherwise only the clicked item. Acting on the
    /// selection when the user right-clicked something else would trash or move
    /// files they never pointed at. Result keeps display order.
    static func contextTargets<T>(clicked: T,
                                  in items: [T],
                                  selection: Set<String>,
                                  id: (T) -> String) -> [T] {
        let clickedID = id(clicked)
        guard selection.contains(clickedID) else { return [clicked] }
        let selected = items.filter { selection.contains(id($0)) }
        return selected.isEmpty ? [clicked] : selected
    }

    /// The selection once a search starts or ends. In Columns view the results
    /// list and the column browser are different lists, so a selection made in
    /// one is hidden in the other, where ⌘C, Delete or Quick Look would still act
    /// on it: it's dropped. List and Icons show the same items either way (the
    /// display list prunes whatever is no longer shown).
    static func afterSearchToggle(_ selection: Set<String>, inColumns: Bool) -> Set<String> {
        inColumns ? [] : selection
    }
}

// MARK: - Clicks in the icon grid

/// What a click on an icon (or a column's row, ColumnNavigation.click) does
/// to the selection, as in Finder. The grid selects on mouse-down rather than
/// after the double-click interval: waiting to rule out a double-click made
/// every click feel slow. Two presses on a selected item wait instead, so
/// that a drag from them carries the whole selection (ShellPressRelease): a
/// plain press inside a larger selection keeps it until the interval after
/// the mouse-up (so a double-click there opens all of it), and a ⌘-press on
/// a selected item takes it out only at the mouse-up.
enum ShellIconClick: Equatable {
    /// Select exactly these now.
    case select(Set<String>)
    /// Nothing changes: the item is already the whole selection.
    case keep
    /// Keep the selection for now; select only this item once the click is
    /// over without a drag and the double-click interval has passed, so a
    /// double-click there opens all of the selection.
    case narrowLater(String)
    /// Keep the selection for now (a ⌘-press on a selected item); take this
    /// item out of it once the click is over without a drag, so a ⌘-drag (a
    /// move, FileOpsDrop) carries the whole selection, as in Finder.
    case deselectLater(String)
    /// Clear the selection (a click on empty space).
    case clear

    /// The keys held with a click that change what it selects.
    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        /// ⌘: add the icon to the selection, or take it out.
        static let command = Modifiers(rawValue: 1 << 0)
        /// ⇧: select every icon from the last one clicked to this one.
        static let shift   = Modifiers(rawValue: 1 << 1)
    }

    /// A plain click (no ⌘ or ⇧).
    static func click(on id: String, selection: Set<String>) -> ShellIconClick {
        if selection == [id] { return .keep }
        if selection.contains(id) { return .narrowLater(id) }
        return .select([id])
    }

    /// A click with the keys held. ⌘ adds the icon or takes it out, as in
    /// Finder. ⇧ adds every icon from `anchor` (the last icon clicked without
    /// ⇧) to this one, in the order the grid shows them (`order`, ids, only
    /// read for a ⇧-click), as AppKit's collection views do; with no anchor
    /// still shown it adds the icon alone. ⇧ wins when both are held.
    static func click(on id: String, selection: Set<String>, modifiers: Modifiers,
                      anchor: String?, order: @autoclosure () -> [String]) -> ShellIconClick {
        if modifiers.contains(.shift) {
            return extend(selection, to: id, from: anchor, order: order())
        }
        if modifiers.contains(.command) {
            return toggle(id, in: selection)
        }
        return click(on: id, selection: selection)
    }

    /// A ⌘-click: adds an unselected item at once, and takes a selected one
    /// out once the click is over (`deselectLater`).
    static func toggle(_ id: String, in selection: Set<String>) -> ShellIconClick {
        selection.contains(id) ? .deselectLater(id) : .select(selection.union([id]))
    }

    static func extend(_ selection: Set<String>, to id: String, from anchor: String?,
                       order: [String]) -> ShellIconClick {
        guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
            return selection.contains(id) ? .keep : .select(selection.union([id]))
        }
        let range = order[min(from, to)...max(from, to)]
        let extended = selection.union(range)
        return extended == selection ? .keep : .select(extended)
    }

    /// What a mouse-down on an icon does: the first click of a series selects,
    /// the second opens (a double-click), and a third or later does nothing, as
    /// in Finder.
    enum Press: Equatable { case select, open, none }

    static func press(clickCount: Int) -> Press {
        switch clickCount {
        case ...1: return .select
        case 2:    return .open
        default:   return .none
        }
    }

    /// Counts the clicks of a series on one icon, so that a double-click opens
    /// only when both of its presses land on the same icon, as in Finder.
    ///
    /// AppKit's click count alone isn't enough. It counts every click within
    /// the double-click interval, wherever it lands: a click on one folder and
    /// then, quickly, on another (or on empty space, then a folder) is a
    /// "double-click" to AppKit, and with nothing else checked the second
    /// press opened a folder the user only meant to select. Here a press
    /// continues a series only when AppKit counts it as a repeat (so the
    /// system's double-click speed still decides), it is on the icon the last
    /// press was on, and it comes within `interval` of that press. Anything
    /// else starts a new series: it selects.
    struct PressTracker {
        private var last: (id: String, time: TimeInterval, count: Int)?

        init() {}

        /// The press on icon `id` at `time` (seconds, the event's timestamp),
        /// with AppKit's `clickCount` for it.
        mutating func press(on id: String, clickCount: Int, at time: TimeInterval,
                            interval: TimeInterval) -> Press {
            var count = 1
            if clickCount > 1, let last, last.id == id, time >= last.time, time - last.time <= interval {
                count = last.count + 1
            }
            last = (id, time, count)
            return ShellIconClick.press(clickCount: count)
        }

        /// A click anywhere else in the grid (empty space, a rubber band)
        /// ends the series.
        mutating func reset() { last = nil }
    }

    /// A click on empty space in the grid clears the selection, as in Finder,
    /// unless ⌘ or ⇧ is held (Finder keeps it, to add to it).
    static func clickOnBackground(selection: Set<String>, modifiers: Modifiers = []) -> ShellIconClick {
        selection.isEmpty || !modifiers.isEmpty ? .keep : .clear
    }
}

// MARK: - Multi-clicks that move to another view

/// The click counts the app gives a series of clicks that IconClickRouting
/// moves to another view.
///
/// The window server counts quick clicks as one series wherever they land.
/// When a repeat click lands on a different view from the click before it
/// and either of them is an icon, the app hands AppKit a copy of it with a
/// click count of one, so that the view under the pointer gets it as the
/// first click of a series of its own. The rest of the system's series then
/// belongs to that view, and its counts go on from the system's: a
/// double-click on a word in a text field right after a click on an icon
/// reached the field as clicks 1 and 3, a triple-click. So the counts of
/// later clicks in the series, and of their mouse-ups, are counted from the
/// one rewritten (less `offset`), until a click the system counts as a first
/// click starts a series afresh.
struct ShellClickSeries: Equatable {
    /// How many of the system's clicks came before the click that was
    /// rewritten to a first click; none while the series is left as it is.
    private(set) var offset = 0

    init() {}

    /// The click count for a mouse-down the system counts as `clickCount`,
    /// on `hit` (the view under the pointer) after one on `previous` (nil if
    /// there was none or it has gone). Clicks that stay on one view, and
    /// clicks with no icon involved, keep the system's count less `offset`.
    mutating func mouseDown<Target: AnyObject>(clickCount: Int, on hit: Target?, after previous: Target?,
                                               isIcon: (Target) -> Bool) -> Int {
        guard clickCount > 1 else {
            offset = 0
            return clickCount
        }
        let moved = previous == nil || hit !== previous
        if moved && (hit.map(isIcon) == true || previous.map(isIcon) == true) {
            offset = clickCount - 1
            return 1
        }
        return max(1, clickCount - offset)
    }

    /// The click count for a mouse-up: its mouse-down's, as given above.
    func mouseUp(clickCount: Int) -> Int {
        clickCount > 1 ? max(1, clickCount - offset) : clickCount
    }
}

/// Which of the file menu's single-item actions it offers. Rename, Open in
/// New Window, Show Package Contents, Extract Here and Add to / Remove from
/// Sidebar act on the clicked item alone, so with several items targeted they
/// are left out rather than quietly ignoring the rest of the selection
/// (Finder swaps Rename for a batch "Rename N Items…", which Selway
/// doesn't have). Open, Quick Look, Get Info and the rest act on every target.
struct ShellItemMenu: Equatable {
    let rename: Bool
    let openInNewWindow: Bool
    let showPackageContents: Bool
    let extract: Bool
    let sidebarToggle: Bool

    init(targetCount: Int, isBrowsableFolder: Bool, isPackage: Bool, isArchive: Bool) {
        let single = targetCount == 1
        rename              = single
        openInNewWindow     = single && isBrowsableFolder
        showPackageContents = single && !isBrowsableFolder && isPackage
        extract             = single && isArchive
        sidebarToggle       = single && isBrowsableFolder
    }
}

// MARK: - Paste target

/// Where Paste puts the clipboard's items, as in Finder: the folder being shown
/// (⌘V, the toolbar), even with a folder selected, so copying a folder and
/// pasting duplicates it beside itself instead of failing with "can't be
/// copied into itself". Only Paste chosen from a single folder's own context
/// menu targets that folder, and even then not when the folder is one of the
/// items being pasted or inside one of them: that falls back to the folder
/// being shown.
enum ShellPasteTarget {
    static func destination(showing currentFolder: URL, contextMenuFolder: URL? = nil,
                            clipboard: [URL]) -> URL {
        guard let folder = contextMenuFolder,
              !clipboard.contains(where: { ShellPath.isSameOrInside(folder, $0) }) else { return currentFolder }
        return folder
    }
}

// MARK: - Path bar for Go to Folder…

/// Whether the path bar is on screen. Go to Folder… (⇧⌘G) types into the bar's
/// editor; with the bar hidden in View or Settings it shows the bar for that one
/// edit and hides it again when the edit ends (a folder gone to, Escape, or a
/// click elsewhere), leaving the setting alone. Turning the setting on was the
/// old way, and the bar then stayed for good.
struct ShellPathBarPresence: Equatable {
    enum GoToFolder: Equatable {
        /// The bar is on screen: open its editor.
        case openEditor
        /// The bar is being shown for the edit: it opens its editor when it appears.
        case showBarThenEdit
    }

    /// Shown for a Go to Folder… edit while the setting hides the bar.
    private(set) var shownForEdit = false

    func isVisible(setting: Bool) -> Bool { setting || shownForEdit }

    mutating func goToFolder(setting: Bool) -> GoToFolder {
        if isVisible(setting: setting) { return .openEditor }
        shownForEdit = true
        return .showBarThenEdit
    }

    mutating func editingEnded() { shownForEdit = false }
}

// MARK: - Stale async results

/// Monotonic token for "latest request wins": take a token before starting
/// background work and drop the result unless the token is still current.
struct ShellGeneration: Equatable {
    private(set) var current: UInt = 0

    @discardableResult
    mutating func next() -> UInt {
        current &+= 1
        return current
    }

    func isCurrent(_ token: UInt) -> Bool { token == current }
}

// MARK: - Display-list helpers

enum ShellDisplayList {
    /// Concatenate lists, keeping the first occurrence of each key.
    static func mergeUnique<T>(_ lists: [[T]], key: (T) -> String) -> [T] {
        var seen = Set<String>()
        var out: [T] = []
        for list in lists {
            for element in list where seen.insert(key(element)).inserted {
                out.append(element)
            }
        }
        return out
    }

    /// Selection minus ids that are no longer displayed, so copy / delete never
    /// act on items the user can't see. Returns nil when nothing changes.
    static func pruned(selection: Set<String>, visible: Set<String>) -> Set<String>? {
        let kept = selection.intersection(visible)
        return kept.count == selection.count ? nil : kept
    }
}

// MARK: - Deferred reloads

/// Holds watcher-driven reloads back while something on screen must not be
/// rebuilt under the user (an inline rename: a reload that changed the row
/// being edited took its focus and committed the half-typed name). Reloads
/// requested meanwhile collapse into one that runs when the gate reopens.
///
/// A rename whose field never got focus could leave the gate shut and the
/// folder frozen, so a suspension lasts at most `maxSuspension`: the first
/// request after that reopens the gate and reloads. Times are monotonic
/// (`ProcessInfo.systemUptime`), so a clock change can't stretch it.
struct ShellReloadGate: Equatable {
    static let maxSuspension: TimeInterval = 120

    private(set) var isSuspended = false
    private(set) var hasDeferred = false
    private var suspendedAt: TimeInterval?

    mutating func suspend(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        isSuspended = true
        suspendedAt = now
    }

    /// True when the caller should reload now; false when it was deferred.
    mutating func request(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard isSuspended else { return true }
        if let since = suspendedAt, now - since >= Self.maxSuspension {
            isSuspended = false
            suspendedAt = nil
            hasDeferred = false
            return true
        }
        hasDeferred = true
        return false
    }

    /// Reopens the gate. True when a reload was deferred and should run now.
    mutating func resume() -> Bool {
        isSuspended = false
        suspendedAt = nil
        defer { hasDeferred = false }
        return hasDeferred
    }

    /// The folder has just been listed again: a reload held back is owed no
    /// longer. The gate stays as it was, shut while a rename is open.
    mutating func dropDeferred() {
        hasDeferred = false
    }
}

// MARK: - Grouping memo

/// Caches `groupedItems` between body evaluations. Grouping 10k items on every
/// render (selection change, hover, toast) was a visible stall. `version` must
/// change whenever the files change (ContentView bumps it on every rebuild);
/// a counter is cheaper than comparing 10k-item arrays on each render.
///
/// Date groups ("Today", "Yesterday", …) are relative to the current day, so
/// the day is part of the key: the first render after midnight regroups.
final class GroupedItemsMemo {
    private struct Key: Equatable {
        let version: UInt
        let groupBy: GroupBy
        let day:     Date
    }
    private var key: Key?
    private var cached: [FileGroup] = []

    func groups(_ files: [FileItem], version: UInt, groupBy: GroupBy,
                now: Date = Date(), calendar: Calendar = .current) -> [FileGroup] {
        let newKey = Key(version: version, groupBy: groupBy, day: calendar.startOfDay(for: now))
        if key == newKey { return cached }
        cached = groupedItems(files, by: groupBy, now: now, calendar: calendar)
        key = newKey
        return cached
    }
}
