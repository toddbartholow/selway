import Foundation

/// What a press on a file leaves for its mouse-up, in the icon grid and the
/// column browser alike, so that the two agree (ShellIconClick). A press acts
/// at once, except on an item already selected, where a drag from the press
/// has to carry the whole selection:
/// - a plain press inside a larger selection (`narrowLater`) selects its item
///   alone once the button has come up without a drag and the double-click
///   interval has passed. The second press of a double-click comes first and
///   `cancel`s it, so a double-click there opens the whole selection, as in
///   Finder;
/// - a ⌘-press on a selected item (`deselectLater`) takes it out of the
///   selection at the mouse-up, so a ⌘-drag (a move) carries all of it.
///
/// While a narrowing waits, the views `cancel` it (leaving the selection as
/// it is) on a drag, another press, Select All, or a menu opening (a context
/// menu acts on the selection it opened on); Columns also on any other change
/// to the column's selection or folder. Keys that move on from the item
/// clicked (the arrow keys, typing a name) `flush` it first, so they move on
/// from that item alone.
@MainActor
final class ShellPressRelease {
    /// The press waiting for its mouse-up: `narrowLater` or `deselectLater`.
    private var pressed: ShellIconClick?
    /// A narrowing waiting out the double-click interval after its mouse-up.
    private var narrowing: Task<Void, Never>?
    /// The narrowing's item, with what reads and replaces the selection.
    private var waiting: (id: String, selection: () -> Set<String>, select: (Set<String>) -> Void)?
    /// The item a press or `narrowing` will select alone.
    private(set) var narrowingID: String?
    /// The double-click interval, read at each mouse-up (a system setting).
    private let interval: () -> TimeInterval

    init(interval: @escaping () -> TimeInterval) {
        self.interval = interval
    }

    /// A press that began a series of clicks, with what it did to the
    /// selection. Ends whatever an earlier press left waiting.
    func press(_ click: ShellIconClick) {
        cancel()
        switch click {
        case .narrowLater(let id):
            pressed = click
            narrowingID = id
        case .deselectLater:
            pressed = click
        case .select, .keep, .clear:
            break
        }
    }

    /// The button came up without a drag. `selection` reads the selection
    /// as it is then (at the mouse-up, and when the narrowing happens);
    /// `select` replaces it. Returns the wait before narrowing, when there is
    /// one (the tests wait for it).
    @discardableResult
    func release(selection: @escaping () -> Set<String>,
                 select: @escaping (Set<String>) -> Void) -> Task<Void, Never>? {
        guard let pressed else { return nil }
        self.pressed = nil
        switch pressed {
        case .deselectLater(let id):
            let selected = selection()
            if selected.contains(id) { select(selected.subtracting([id])) }
            return nil
        case .narrowLater(let id):
            waiting = (id, selection, select)
            let wait = interval()
            let task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self, self.waiting?.id == id else { return }
                self.flush()
            }
            narrowing = task
            return task
        case .select, .keep, .clear:
            return nil
        }
    }

    /// Narrows the selection now, if a narrowing is waiting out the interval
    /// after its mouse-up. Returns its item, when it is still selected (and
    /// so now selected alone); nil if nothing was waiting or the item has
    /// left the selection.
    @discardableResult
    func flush() -> String? {
        guard let waiting else { return nil }
        cancel()
        let selected = waiting.selection()
        guard selected.contains(waiting.id) else { return nil }
        if selected != [waiting.id] { waiting.select([waiting.id]) }
        return waiting.id
    }

    /// Leaves the selection as it is (see the type's description).
    func cancel() {
        pressed = nil
        narrowing?.cancel()
        narrowing = nil
        waiting = nil
        narrowingID = nil
    }
}
