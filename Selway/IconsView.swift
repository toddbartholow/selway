import SwiftUI
import AppKit

struct IconsView: View {
    let files:       [FileItem]
    /// Changes whenever `files` is rebuilt (see ContentView.displayVersion).
    let filesVersion: UInt
    @Binding var selectedIDs: Set<String>
    let currentPath: URL
    var isReadOnlyLocation = false
    let groupBy:     GroupBy
    /// Opens every item given (PaneState.openItems).
    let onOpen:      ([FileItem]) -> Void
    /// A ⌘-double-click: opens them with folders in new tabs, as in Finder.
    let onOpenInNewTabs: ([FileItem]) -> Void
    let onBrowseInto:(URL) -> Void
    let onReload:    () -> Void
    @ObservedObject var fileOps:   FileOperationsService
    @ObservedObject var favorites: FavoritesService
    /// Bumped to give the grid keyboard focus (Return / ↓ in the search field).
    var focusRequest = 0
    /// The grid shows search or tag results: files dropped on empty space
    /// have no folder to go into (see ListView).
    var showsSearchResults = false

    /// At 100%; FileIconView applies the text size on top. Stored, so it survives
    /// the view being rebuilt (as `@State` it went back to 64 each time), and read
    /// through `iconSize(fromStorage:)` so a hand-edited value stays on the slider.
    @AppStorage(UserPreferences.iconSizeKey) private var storedIconSize = UserPreferences.defaultIconSize
    @State private var groupMemo = GroupedItemsMemo()
    @State private var actions = IconGridActions()
    /// A rubber band is being drawn (see the cells' `selection` below).
    @State private var rubberBanding = false
    /// The scroll view's height, the least the grid's content fills.
    @State private var viewportHeight: CGFloat = 0
    @FocusState private var gridFocused: Bool
    @Environment(\.textScale) private var textScale

    private var iconSize: CGFloat { CGFloat(UserPreferences.iconSize(fromStorage: storedIconSize)) }

    private var iconSizeBinding: Binding<Double> {
        Binding(get: { UserPreferences.iconSize(fromStorage: storedIconSize) },
                set: { storedIconSize = UserPreferences.iconSize(fromStorage: $0) })
    }

    /// The narrowest a column may be, and the gap between columns: `columns`
    /// lays the grid out with them and the arrow keys count its columns with them.
    private var columnMinimum: CGFloat { (iconSize + 20) * textScale }
    private static let columnSpacing: CGFloat = 8

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: columnMinimum, maximum: (iconSize + 40) * textScale),
                  spacing: Self.columnSpacing)]
    }

    /// How many icons each row holds, as `columns` lays them out.
    private var navigationColumnCount: Int {
        IconGridNavigation.columnCount(width: actions.gridWidth, minimum: columnMinimum,
                                       spacing: Self.columnSpacing)
    }

    private var groups: [FileGroup] { groupMemo.groups(files, version: filesVersion, groupBy: groupBy) }

    var body: some View {
        let _ = updateActions()
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    // One grid for every group, each a Section: a grid per group in a
                    // LazyVStack hid the icons of a group not yet laid out from
                    // scrollTo, so ↓ into the next group didn't scroll (issue #24).
                    LazyVGrid(columns: columns, spacing: 12, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.items) { item in
                                    // While a rubber band is drawn the selected cells
                                    // don't take the selection itself: it changes as the
                                    // band moves, and only the cells it selects or
                                    // deselects need drawing again. No context menu can
                                    // open meanwhile; the cells get it when the band ends.
                                    let selected = selectedIDs.contains(item.id)
                                    IconGridCell(item: item, iconSize: iconSize,
                                                 selection: selected ? .init(ids: rubberBanding ? [] : selectedIDs,
                                                                             filesVersion: filesVersion) : nil,
                                                 isReadOnlyLocation: isReadOnlyLocation,
                                                 actions: actions, fileOps: fileOps, favorites: favorites)
                                        .equatable()
                                        .id(item.id)
                                }
                            } header: {
                                if groupBy != .none, !group.title.isEmpty {
                                    DateSectionHeader(title: group.title, count: group.items.count)
                                        // Empty space too, as in Finder: a press here clears
                                        // the selection or starts a rubber band, even with
                                        // the header pinned over the icons. The arrow keys
                                        // find the pinned header by it, to keep the icon
                                        // they move to clear of it (IconGridBackgroundView.reveal).
                                        .overlay { IconGridPassThrough(band: actions.band).accessibilityHidden(true) }
                                        // 8 points from the edges, past the icons' 16.
                                        .padding(.horizontal, -8)
                                        // 16 points above the first row, as when each
                                        // group was a grid of its own, rather than the
                                        // rows' 12. Clear: pinned, the icons show through
                                        // it as they scroll under the header, and clicks
                                        // there reach them.
                                        .padding(.bottom, 4)
                                }
                            }
                        }
                    }
                    // On the actions, not in @State: only the arrow keys read it, so
                    // a resize needn't draw the whole grid again.
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { actions.gridWidth = $0 }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    // At least as tall as the scroll view, so the space below the last
                    // icon is part of the grid and a click (or a rubber band) can start
                    // there.
                    .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .top)
                    // Behind the icons: a press on an icon is the icon's, a press on
                    // the space around and between them is this one's, a click that
                    // clears the selection or a drag that draws Finder's rubber band
                    // (IconGridBackgroundView). Above them, the band itself.
                    .background {
                        IconGridBackground(band: actions.band,
                                           onPress: { _ in actions.pressBackground() },
                                           onClick: { actions.clickBackground(modifiers: $0) })
                            .accessibilityHidden(true)
                    }
                    .overlay(alignment: .topLeading) {
                        RubberBandOverlay(band: actions.band)
                    }
                }
                // Less any safe area the scroll view insets its content by, so a short
                // folder doesn't scroll by that much.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    max(0, proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom)
                } action: { viewportHeight = $0 }
                .accessibilityIdentifier("fileList")
                .background(Color(nsColor: .textBackgroundColor))
                .contextMenu {
                    BackgroundContextMenu(directory: currentPath, isReadOnlyLocation: isReadOnlyLocation, onReload: onReload, fileOps: fileOps)
                }
                // Space = Quick Look while the grid has focus (clicking an icon focuses
                // it). Text fields elsewhere in the window keep their spaces.
                .focusable()
                .focusEffectDisabled()
                .focused($gridFocused)
                .onChange(of: focusRequest) { _, _ in gridFocused = true }
                // A click inside the selection waiting to narrow it is dropped by
                // Select All and by any menu opening (IconGridActions.cancelPress).
                .onReceive(NotificationCenter.default.publisher(for: .selectAllRequested)) { _ in
                    actions.cancelPress()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                    actions.cancelPress()
                }
                .onKeyPress(.space) {
                    guard !TextInputFocus.isActive else { return .ignored }
                    let urls = files.filter { selectedIDs.contains($0.id) }.map(\.url)
                    guard !urls.isEmpty else { return .ignored }
                    QuickLookController.shared.show(urls)
                    return .handled
                }
                // Return renames the selected icon (with a prompt, as its context
                // menu's Rename does), ⌘O and ⌘↓ open the selection (ShellItemKey).
                .onKeyPress(phases: .down) { press in
                    guard let key = press.shellItemKey else { return .ignored }
                    let taken = key.perform(on: files.filter { selectedIDs.contains($0.id) },
                                            rename: {
                                                guard !isReadOnlyLocation else { NSSound.beep(); return }
                                                NamePrompt.rename($0, fileOps: fileOps, reload: onReload)
                                            },
                                            open: onOpen)
                    return taken ? .handled : .ignored
                }
                // The arrow keys move the selection as in Finder (IconGridNavigation),
                // ⇧ extends it. ⌘↓ opens (above); ⌘, ⌥ and ⌃ arrows are otherwise
                // left to the menu shortcuts.
                .onKeyPress(keys: [.rightArrow, .leftArrow, .downArrow, .upArrow], phases: [.down, .repeat]) { press in
                    // Defensive, as for Space: a text field that has the keys
                    // (the rename prompt, the search field) normally keeps them.
                    guard !TextInputFocus.isActive else { return .ignored }
                    guard !press.modifiers.contains(.command), !press.modifiers.contains(.option),
                          !press.modifiers.contains(.control) else { return .ignored }
                    let direction: IconGridNavigation.Direction
                    switch press.key {
                    case .rightArrow: direction = .right
                    case .leftArrow: direction = .left
                    case .downArrow: direction = .down
                    case .upArrow: direction = .up
                    default: return .ignored
                    }
                    let order = actions.displayOrder().map(\.id)
                    let lead = actions.lead(in: order)
                    guard let destination = IconGridNavigation.destination(
                        sectionCounts: groups.map { $0.items.count }, columns: navigationColumnCount,
                        leadIndex: lead.flatMap(order.firstIndex(of:)), direction: direction),
                          order.indices.contains(destination) else {
                        return .ignored
                    }
                    actions.moveLead(to: order[destination], from: lead,
                                     extending: press.modifiers.contains(.shift), order: order)
                    // No animation: a held key would queue a scroll per repeat.
                    actions.reveal(order[destination]) { scrollProxy.scrollTo($0, anchor: nil) }
                    return .handled
                }
                .fileDropArea(showsSearchResults || isReadOnlyLocation ? nil : currentPath, fileOps: fileOps, reload: onReload)
            }

            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3").scaledFont(.caption2).foregroundStyle(.secondary)
                Slider(value: iconSizeBinding, in: UserPreferences.iconSizeRange, step: UserPreferences.iconSizeStep)
                    .frame(width: 100 * textScale)
                Image(systemName: "square.grid.2x2").scaledFont(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    /// The cells read these when clicked, opened or dragged, so a cell whose
    /// item and selected state are unchanged needn't be drawn again.
    private func updateActions() {
        actions.files        = files
        actions.selection    = $selectedIDs
        actions.onOpen       = onOpen
        actions.onOpenInNewTabs = onOpenInNewTabs
        actions.onBrowseInto = onBrowseInto
        actions.onReload     = onReload
        let focus = $gridFocused
        actions.focusGrid = { focus.wrappedValue = true }
        actions.band.selection = $selectedIDs
        let banding = $rubberBanding
        actions.band.onActiveChange = { banding.wrappedValue = $0 }
        let memo = groupMemo, files = files, version = filesVersion, groupBy = groupBy
        actions.displayOrder = { memo.groups(files, version: version, groupBy: groupBy).flatMap(\.items) }
    }
}

// MARK: - Cells

/// One icon with its clicks and drag-out (IconMouseArea), drop target and
/// context menu.
///
/// Equatable on what it draws (the item, the size, whether it is selected) so
/// a selection change redraws only the cells it selects or deselects, not
/// every icon in the folder. A selected cell also takes the selection and the
/// list's version: its context menu acts on the whole selection, so it must be
/// rebuilt when either changes. An unselected cell's menu acts on its item
/// alone. Everything else (the files, the selection when the drag starts, the
/// callbacks) is read from `actions` when it is needed.
struct IconGridCell: View, Equatable {
    struct Selection: Equatable {
        let ids: Set<String>
        let filesVersion: UInt
    }

    let item: FileItem
    let iconSize: CGFloat
    /// Nil when the item isn't selected.
    let selection: Selection?
    /// The folder's, for the cell's drags, drops and menu: a change redraws it.
    let isReadOnlyLocation: Bool
    let actions: IconGridActions
    let fileOps: FileOperationsService
    let favorites: FavoritesService

    // SwiftUI compares views on the main thread.
    nonisolated static func == (a: IconGridCell, b: IconGridCell) -> Bool {
        MainActor.assumeIsolated {
            a.item == b.item && a.iconSize == b.iconSize && a.selection == b.selection
                && a.isReadOnlyLocation == b.isReadOnlyLocation
                && a.actions === b.actions && a.fileOps === b.fileOps && a.favorites === b.favorites
        }
    }

    var body: some View {
        let actions = self.actions, item = self.item
        IconCell(item: item, iconSize: iconSize, isSelected: selection != nil)
            // AppKit's mouse handling, not tap gestures and onDrag: a press the
            // hand moves a point or two is still a click (see IconMouseView). It
            // takes left clicks on the icon's image and name only, where they
            // are in the cell (IconHitParts), so the context menu below still
            // opens and a press on the rest of the cell is on empty space. It is
            // hidden from accessibility (the cell's actions below stand in for
            // its clicks). The rubber band finds the icons by these views
            // (IconGridBackgroundView).
            .overlayPreferenceValue(IconHitParts.self) { parts in
                GeometryReader { cell in
                    IconMouseArea(itemID:    item.id,
                                  hitParts:  parts.map { cell[$0] },
                                  onPress:   { actions.press(item, clickCount: $0, modifiers: $1, at: $2) },
                                  onRelease: { actions.release() },
                                  dragFiles: { actions.dragFiles(for: item, pixelSide: $0) },
                                  iconSize:  iconSize,
                                  isReadOnlyLocation: isReadOnlyLocation)
                }
                .accessibilityHidden(true)
            }
            // A folder takes drops on its image and name only, like its clicks;
            // beside a short name they go into the folder shown.
            .iconDropTarget(!isReadOnlyLocation && item.isBrowsableFolder ? item.url : nil,
                            fileOps: fileOps, reload: { actions.onReload() })
            // For VoiceOver, the icon is one element named for its item, selected
            // or not: its press selects the item, as a click does, and "Open"
            // opens it, as a double-click does. Its picture and name stay
            // elements inside it (the UI tests find icons by them), and so do its
            // tags (TagDotsView): SwiftUI gives a container no value. They're
            // its custom content too, heard without interacting into the icon.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(item.name)
            .accessibilityTags(item.spokenTagNames)
            .accessibilityAddTraits(selection != nil ? .isSelected : [])
            .accessibilityAction { actions.selectOnly(item) }
            .accessibilityAction(named: "Open") { actions.open(item) }
            .contextMenu {
                FileContextMenu(
                    item:         item,
                    targets:      FileContextMenu.targets(clicked: item, in: actions.files,
                                                          selection: selection?.ids ?? []),
                    onOpen:       { actions.onOpen($0) },
                    onBrowseInto: { actions.onBrowseInto($0) },
                    onRename:     { NamePrompt.rename($0, fileOps: fileOps, reload: { actions.onReload() }) },
                    onReload:     { actions.onReload() },
                    fileOps:      fileOps,
                    favorites:    favorites,
                    isReadOnlyLocation: isReadOnlyLocation
                )
            }
    }
}

/// What the icon cells do, holding the grid's current files, selection and
/// callbacks (IconsView refreshes them every time it is drawn). A reference
/// that stays the same, so cells compare equal across redraws.
@MainActor
final class IconGridActions {
    var files: [FileItem] = []
    var selection: Binding<Set<String>> = .constant([])
    var onOpen: ([FileItem]) -> Void = { _ in }
    var onOpenInNewTabs: ([FileItem]) -> Void = { _ in }
    var onBrowseInto: (URL) -> Void = { _ in }
    var onReload: () -> Void = {}
    var focusGrid: () -> Void = {}
    /// The rubber band on empty space.
    let band = IconRubberBand()

    /// The grid's items in the order it shows them (by group), for ⇧-click.
    var displayOrder: () -> [FileItem] = { [] }
    /// The width the grid lays its icons out in, inside its padding, for ↑ and ↓.
    var gridWidth: CGFloat = 0
    /// The icon last clicked or moved to with the arrow keys.
    private var leadID: String?

    /// The last icon clicked or moved to without ⇧: where a ⇧-click's or
    /// ⇧-arrow's range starts.
    private var anchor: String?
    /// The last press on an icon, so a double-click opens only when both
    /// presses land on that icon.
    private var presses = ShellIconClick.PressTracker()
    /// A press on a selected icon, waiting for its mouse-up: a plain press
    /// inside a larger selection narrows it to the icon after the double-click
    /// interval, a ⌘-press takes the icon out (ShellPressRelease). A drag
    /// from either carries the whole selection.
    private let releases = ShellPressRelease(interval: { PressNarrowing.wait })

    /// Mouse-down on an icon at `time` (the event's timestamp): the first click
    /// of a series selects (with ⌘ or ⇧, adds to the selection), the second on
    /// the same icon opens, any later ones do nothing. A quick click on another
    /// icon starts a series of its own (ShellIconClick.PressTracker). Returns
    /// whether the press began a series, the only press that can become a drag.
    @discardableResult
    func press(_ item: FileItem, clickCount: Int, modifiers: ShellIconClick.Modifiers,
               at time: TimeInterval) -> Bool {
        // A band still waiting for a mouse-up that went elsewhere ends here,
        // as on a press on the grid's empty space (IconGridBackgroundView).
        band.background?.endBand()
        releases.cancel()
        switch presses.press(on: item.id, clickCount: clickCount, at: time, interval: NSEvent.doubleClickInterval) {
        case .select: select(item, modifiers: modifiers); return true
        case .open:   open(item, inNewTabs: modifiers.contains(.command)); return false
        case .none:   return false
        }
    }

    private func select(_ item: FileItem, modifiers: ShellIconClick.Modifiers) {
        focusGrid()
        let click = ShellIconClick.click(on: item.id, selection: selection.wrappedValue, modifiers: modifiers,
                                         anchor: anchor, order: displayOrder().map(\.id))
        if !modifiers.contains(.shift) { anchor = item.id }
        leadID = item.id
        if case .select(let ids) = click { selection.wrappedValue = ids }
        releases.press(click)
    }

    /// Selects the item alone, at once, as a click on it does once the button
    /// comes up (VoiceOver's press on an icon).
    func selectOnly(_ item: FileItem) {
        releases.cancel()
        presses.reset()
        focusGrid()
        anchor = item.id
        leadID = item.id
        if selection.wrappedValue != [item.id] { selection.wrappedValue = [item.id] }
    }

    /// Where the arrow keys move from (IconGridNavigation.lead).
    func lead(in order: [String]) -> String? {
        IconGridNavigation.lead(leadID, selection: selection.wrappedValue, order: order)
    }

    /// An arrow key moved from `lead` to `id` (IconGridNavigation.move).
    func moveLead(to id: String, from lead: String?, extending: Bool, order: [String]) {
        // A click inside a larger selection that is still waiting to narrow it
        // narrows it now, so ⇧ extends from that icon alone.
        var selected = selection.wrappedValue
        if let narrowing = releases.narrowingID, selected.contains(narrowing) { selected = [narrowing] }
        releases.cancel()
        presses.reset()
        focusGrid()
        let move = IconGridNavigation.move(to: id, from: lead, anchor: anchor, selection: selected,
                                           extending: extending, order: order)
        leadID = move.lead
        anchor = move.anchor
        if selection.wrappedValue != move.selection { selection.wrappedValue = move.selection }
    }

    /// Checks, once a frame, that the icon the arrow keys moved to comes to
    /// rest in view (see `reveal`); the next key's reveal replaces it.
    private var revealCheck: Timer?
    /// How many times `revealCheck` has looked.
    private var revealChecks = 0

    /// Scrolls the grid as little as shows all of the icon for `id`, below the
    /// pinned group header (IconGridBackgroundView.reveal). An icon the lazy
    /// grid hasn't laid out yet is brought in with `scrollTo` (the
    /// ScrollViewReader's), which leaves it at the top edge when it was above,
    /// under the header. Whenever the grid scrolled, it looks again once a
    /// frame until the icon shows: a timer fires after the run loop has laid
    /// the grid out, which DispatchQueue.main.async needn't, and a fifth of a
    /// second is ample (an offscreen probe needed one turn).
    func reveal(_ id: String, scrollTo: (String) -> Void) {
        revealCheck?.invalidate()
        revealCheck = nil
        switch band.background?.reveal(itemID: id) ?? .notLaidOut {
        case .inView: return
        case .scrolled: break
        case .notLaidOut: scrollTo(id)
        }
        revealChecks = 0
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.checkReveal(id) }
        }
        // Common modes, so it fires however the run loop is waiting.
        RunLoop.main.add(timer, forMode: .common)
        revealCheck = timer
    }

    private func checkReveal(_ id: String) {
        revealChecks += 1
        let found = band.background?.reveal(itemID: id) ?? .inView
        if found == .inView || revealChecks >= 12 {
            revealCheck?.invalidate()
            revealCheck = nil
        }
    }

    /// Leaves the selection as it is, dropping a click inside it that waits to
    /// narrow it: Select All, or a menu opening (a context menu acts on the
    /// selection it opened on; ShellPressRelease).
    func cancelPress() {
        releases.cancel()
    }

    /// Mouse-up after a press that didn't drag (ShellPressRelease).
    func release() {
        releases.release(selection: { [weak self] in self?.selection.wrappedValue ?? [] },
                         select:    { [weak self] in self?.selection.wrappedValue = $0 })
    }

    /// Mouse-down on empty space: the start of a click there or of a rubber
    /// band. Either ends a series of clicks on an icon.
    func pressBackground() {
        releases.cancel()
        presses.reset()
        focusGrid()
    }

    /// A click on empty space (a press that didn't draw a rubber band) clears
    /// the selection, unless ⌘ or ⇧ was held when it went down.
    func clickBackground(modifiers: ShellIconClick.Modifiers) {
        if ShellIconClick.clickOnBackground(selection: selection.wrappedValue, modifiers: modifiers) == .clear {
            selection.wrappedValue = []
        }
    }

    /// The selection when the item is in it, as in Finder (and the list);
    /// otherwise the item. Opened after the click is done with, as in the
    /// list (ListView.tableView): opening a folder replaces the icons, the
    /// clicked one included, and asking before opening many runs a modal
    /// alert, neither of which should happen inside its mouse-down. A
    /// ⌘-double-click opens folders in new tabs, as in Finder.
    func open(_ item: FileItem, inNewTabs: Bool = false) {
        releases.cancel()
        let targets = FileContextMenu.targets(clicked: item, in: files, selection: selection.wrappedValue)
        let onOpen = inNewTabs ? self.onOpenInNewTabs : self.onOpen
        DispatchQueue.main.async { onOpen(targets) }
    }

    /// The files a drag that starts on `item` carries: the selection when the
    /// item is in it, otherwise the item (FileDragSupport.urlsForDrag), each
    /// with its icon as loaded so far (FileDragSupport.dragFiles).
    func dragFiles(for item: FileItem, pixelSide: CGFloat) -> [FileMouseView.DragFile] {
        releases.cancel()
        return FileDragSupport.dragFiles(for: item, files: files, selectedIDs: selection.wrappedValue,
                                         pixelSide: pixelSide)
    }
}

/// An icon and its name, highlighted as in Finder when selected: the image on
/// a grey rounded box, the name on the accent colour. Those two are the icon
/// (`iconHitPart`): the rest of the cell, which takes its column's width, is
/// empty space for clicks and the rubber band.
struct IconCell: View {
    let item: FileItem; let iconSize: CGFloat; let isSelected: Bool
    var body: some View {
        // Laid out as before the highlight was split: the image 6 points from
        // the top (IconMouseView's drag image starts there) and the name as wide
        // as the cell less 12.
        VStack(spacing: 2) {
            ZStack(alignment: .bottomTrailing) {
                FileIconView(item: item, size: iconSize)
                TagDotsView(colors: item.tagColors, names: item.spokenTagNames, size: 10)
                    .offset(x: 2, y: 2)
                    .accessibilitySortPriority(-1)          // read after the name
            }
            .padding(3)
            .background(isSelected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .iconHitPart(cornerRadius: 5)
            Text(item.name).scaledFont(.caption).lineLimit(2).multilineTextAlignment(.center)
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .iconHitPart(cornerRadius: 4)
        }
        .padding(.horizontal, 2).padding(.vertical, 3)
        .frame(maxWidth: .infinity)
    }
}
