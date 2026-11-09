import SwiftUI
import AppKit
// LatinKeyboardLayout. Its EventModifiers hides SwiftUI's: name SwiftUI's in full.
import Carbon.HIToolbox

// Approximate height of the Table's column header row. Below this strip the pointer
// is over the rows, where the cursor must always be the plain arrow. Erring slightly
// tall keeps us from ever clobbering the header divider's resize cursor.
private let kTableHeaderStripHeight: CGFloat = 30

struct ListView: View {
    let files:         [FileItem]
    /// Changes whenever `files` is rebuilt (see ContentView.displayVersion).
    let filesVersion:  UInt
    @Binding var selectedIDs:      Set<String>
    @Binding var pendingRenameURL: URL?
    /// True while an inline rename is open; ContentView holds watcher reloads
    /// back meanwhile so the row being edited isn't rebuilt under the user.
    @Binding var isRenaming:       Bool
    let currentPath:   URL
    var isReadOnlyLocation = false
    @Binding var sortField:     SortField
    @Binding var sortAscending: Bool
    let groupBy:       GroupBy
    /// Opens every item given (PaneState.openItems).
    let onOpen:        ([FileItem]) -> Void
    /// A ⌘-double-click: opens them with folders in new tabs, as in Finder.
    let onOpenInNewTabs: ([FileItem]) -> Void
    let onBrowseInto:  (URL) -> Void
    let onReload:      () -> Void
    @ObservedObject var fileOps:   FileOperationsService
    @ObservedObject var favorites: FavoritesService
    /// The list shows search or tag results, not the folder: files dropped on
    /// empty space have no folder to go into (Finder refuses them too).
    var showsSearchResults = false

    @State private var sortOrder:       [KeyPathComparator<FileItem>] = [.init(\.name, order: .forward)]
    @State private var renamingID:      String?
    @State private var renameText:      String = ""
    @State private var renameCancelled: Bool   = false
    /// Bumped by every rename start, so a stale focus check can't end a newer rename.
    @State private var renameAttempt:   Int    = 0
    @FocusState private var renameActive: Bool
    @Environment(\.textScale) private var textScale

    var body: some View {
        if groupBy != .none {
            GroupedListView(
                files:            files,
                filesVersion:     filesVersion,
                selectedIDs:      $selectedIDs,
                pendingRenameURL: $pendingRenameURL,
                isRenaming:       $isRenaming,
                currentPath:      currentPath,
                groupBy:          groupBy,
                onOpen:           onOpen,
                onOpenInNewTabs:  onOpenInNewTabs,
                onBrowseInto:     onBrowseInto,
                onReload:         onReload,
                fileOps:          fileOps,
                favorites:        favorites,
                isReadOnlyLocation: isReadOnlyLocation,
                dropFolder:       dropFolder
            )
        } else {
            tableView
                .onChange(of: pendingRenameURL) { _, url in
                    guard let url, let item = files.first(where: { ShellPath.same($0.url, url) }) else { return }
                    startRename(item: item)
                    pendingRenameURL = nil
                }
                .onChange(of: renamingID) { _, id in isRenaming = id != nil }
                .onDisappear { isRenaming = false }
                .fileDropArea(dropFolder, fileOps: fileOps, reload: onReload)
        }
    }

    /// Where files dropped on empty space or on a file go.
    private var dropFolder: URL? { showsSearchResults || isReadOnlyLocation ? nil : currentPath }

    // MARK: - Table (non-grouped)

    private var tableView: some View {
        Table(of: FileItem.self, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 6) {
                    FileIconView(item: item, size: 16)
                    if renamingID == item.id {
                        TextField(text: $renameText) { EmptyView() }
                            .textFieldStyle(.plain)
                            .resetsCursorOnExit()
                            .focused($renameActive)
                            .browserTextInput()
                            .onSubmit {
                                if let it = files.first(where: { $0.id == renamingID }) {
                                    commitRename(for: it)
                                }
                            }
                            .onExitCommand { cancelRename() }
                    } else {
                        Text(item.name).lineLimit(1)
                            .foregroundStyle(isCutPending(item) ? Color.secondary : Color.primary)
                    }
                    TagDotsView(colors: item.tagColors, names: item.spokenTagNames, size: 10)
                }
                // A folder takes files dropped on its name; the whole Name cell
                // is the target. Not a gesture or a drag: the table keeps its clicks.
                .frame(maxWidth: .infinity, alignment: .leading)
                .folderDropTarget(!isReadOnlyLocation && item.isBrowsableFolder ? item.url : nil, fileOps: fileOps,
                                  verticalOutset: 3, reload: onReload)
            }
            .width(min: 140 * textScale, ideal: 280 * textScale, max: 600 * textScale)

            TableColumn("Date Modified", value: \.dateModified) { item in
                Text(item.formattedDateModified).foregroundStyle(.secondary)
            }.width(min: 100 * textScale, ideal: 148 * textScale, max: 240 * textScale)

            TableColumn("Date Created", value: \.dateCreated) { item in
                Text(item.formattedDateCreated).foregroundStyle(.secondary)
            }.width(min: 100 * textScale, ideal: 148 * textScale, max: 240 * textScale)

            TableColumn("Size", value: \.size) { item in
                Text(item.formattedSize).foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(min: 50 * textScale, ideal: 80 * textScale, max: 140 * textScale)

            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary)
            }.width(min: 60 * textScale, ideal: 110 * textScale, max: 200 * textScale)

            TableColumn("Extension", value: \.fileExtension) { item in
                Text(item.fileExtension.isEmpty ? "—" : item.fileExtension.uppercased())
                    .foregroundStyle(.secondary)
            }.width(min: 40 * textScale, ideal: 68 * textScale, max: 120 * textScale)
        } rows: {
            // The table drags the rows itself (every selected row, one file each).
            // A drag on a cell's contents took the clicks from the table, so
            // clicking a name or icon neither selected nor opened the item.
            ForEach(files) { item in
                TableRow(item)
                    .itemProvider { [url = item.url] in FileDragSupport.provider(for: [url]) }
            }
        }
        .accessibilityIdentifier("fileList")
        .onChange(of: sortOrder) { _, order in
            guard let first = order.first else { return }
            sortAscending = (first.order == .forward)
            switch first.keyPath {
            case \FileItem.name:          sortField = .name
            case \FileItem.dateModified:  sortField = .dateModified
            case \FileItem.dateCreated:   sortField = .dateCreated
            case \FileItem.size:          sortField = .size
            case \FileItem.kind:          sortField = .kind
            case \FileItem.fileExtension: sortField = .ext
            default: break
            }
        }
        .onChange(of: sortField)     { _, _ in syncSortOrder() }
        .onChange(of: sortAscending) { _, _ in syncSortOrder() }
        .onChange(of: files) { _, newFiles in
            if let id = renamingID, !newFiles.contains(where: { $0.id == id }) {
                renamingID = nil
            }
        }
        .onChange(of: renameActive)  { _, active in
            guard !active, let id = renamingID,
                  let item = files.first(where: { $0.id == id }) else { return }
            commitRename(for: item)
        }
        // A rename whose field never got focus ends when the selection moves on.
        .onChange(of: selectedIDs) { _, ids in
            if let id = renamingID, !renameActive, !ids.contains(id) { cancelRename() }
        }
        .onAppear { syncSortOrder() }
        // Return renames, ⌘O and ⌘↓ open, before the table takes Return as Open.
        .background(FileListKeys(isReadOnlyLocation: isReadOnlyLocation, onKey: { itemKey($0) }))
        .contextMenu(forSelectionType: String.self) { ids in contextMenu(for: ids) }
        primaryAction: { ids in
            // A double-click. Return is FileListKeys'; should one get here, it
            // still renames rather than opening. Any other key (⇧Return, or a
            // stale one behind an accessibility Open) opens, as before. A held
            // key's repeats do nothing: a held Return that just committed a
            // rename would otherwise start another.
            if NSApp.currentEvent?.isKeyRepeat == true { return }
            if NSApp.currentEvent?.shellItemKey == .rename { _ = itemKey(.rename); return }
            // Every selected item, in list order, as Finder opens them.
            let items = files.filter { ids.contains($0.id) }
            guard renamingID == nil, !items.isEmpty else { return }
            // After the click is done with: opening a folder replaces the rows,
            // the clicked one included, and doing that mid-click left the table
            // ignoring clicks for a while. With ⌘ held, folders open in new tabs.
            let inNewTabs = NSApp.currentEvent?.isCommandClick == true
            DispatchQueue.main.async { inNewTabs ? onOpenInNewTabs(items) : onOpen(items) }
        }
        // Space = Quick Look, only while the table itself has focus, and never
        // while a text field (inline rename) is taking the keystroke. A
        // window-level Space shortcut used to swallow spaces typed in the search
        // field and path editor.
        .onKeyPress(.space) {
            guard renamingID == nil, !TextInputFocus.isActive, !selectedIDs.isEmpty else { return .ignored }
            quickLook(ids: selectedIDs)
            return .handled
        }
        // Release the column-resize cursor once the pointer moves into the rows.
        // The Table's NSTableView header sets a resize cursor on its column dividers
        // and (like every AppKit drag) leaves it stuck after a resize. The header and
        // rows are the same view, so there's no enter/exit boundary to hook — instead
        // we watch the live pointer position: anywhere below the header strip the
        // cursor must be the plain arrow, so force it there. We never touch the header
        // region (resize cursor still shows while hovering/dragging a divider) and skip
        // it during an inline rename so the text I-beam isn't disturbed.
        .onContinuousHover { phase in
            guard renamingID == nil else { return }
            if case .active(let point) = phase, point.y > kTableHeaderStripHeight {
                NSCursor.arrow.set()
            }
        }
    }

    private func syncSortOrder() {
        let order: SortOrder = sortAscending ? .forward : .reverse
        switch sortField {
        case .name:         sortOrder = [KeyPathComparator(\.name,          order: order)]
        case .dateModified: sortOrder = [KeyPathComparator(\.dateModified,  order: order)]
        case .dateCreated:  sortOrder = [KeyPathComparator(\.dateCreated,   order: order)]
        case .size:         sortOrder = [KeyPathComparator(\.size,          order: order)]
        case .kind:         sortOrder = [KeyPathComparator(\.kind,          order: order)]
        case .ext:          sortOrder = [KeyPathComparator(\.fileExtension, order: order)]
        }
    }

    /// Return renames the one item selected, ⌘O and ⌘↓ open the selection
    /// (ShellItemKey). Returns whether the key was taken.
    private func itemKey(_ key: ShellItemKey) -> Bool {
        key.perform(on: files.filter { selectedIDs.contains($0.id) }, renaming: renamingID != nil,
                    rename: { startRename(item: $0) }, open: onOpen)
    }

    // MARK: - Inline rename helpers

    func startRename(item: FileItem) {
        guard !isReadOnlyLocation else { NSSound.beep(); return }
        renameCancelled = false
        renamingID      = item.id
        renameText      = item.name
        renameAttempt  += 1
        let attempt = renameAttempt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { renameActive = true }
        // Focus that never lands (row scrolled away, window no longer key) would
        // leave the rename open and ContentView holding watcher reloads back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if renameAttempt == attempt, renamingID == item.id, !renameActive { cancelRename() }
        }
    }

    private func commitRename(for item: FileItem) {
        renamingID   = nil
        renameActive = false
        guard !renameCancelled else { renameCancelled = false; return }
        guard let name = NamePrompt.validatedInlineName(renameText, for: item, fileOps: fileOps) else { return }
        fileOps.rename(item.url, to: name, reload: onReload)
    }

    private func cancelRename() {
        renameCancelled = true
        renamingID      = nil
    }

    // MARK: - Context menu
    // `ids` already follows Finder's rule (the selection when the clicked row is
    // selected, otherwise just the clicked row).

    @ViewBuilder
    func contextMenu(for ids: Set<String>) -> some View {
        let sel = files.filter { ids.contains($0.id) }
        if let item = sel.first {
            FileContextMenu(
                item:         item,
                targets:      sel,
                onOpen:       onOpen,
                onBrowseInto: onBrowseInto,
                onRename:     { pendingRenameURL = $0.url },
                onReload:     onReload,
                fileOps:      fileOps,
                favorites:    favorites,
                isReadOnlyLocation: isReadOnlyLocation
            )
        } else {
            BackgroundContextMenu(directory: currentPath, isReadOnlyLocation: isReadOnlyLocation, onReload: onReload, fileOps: fileOps)
        }
    }

    private func isCutPending(_ item: FileItem) -> Bool {
        guard fileOps.isCut else { return false }
        let key = ShellPath.key(item.url)
        return fileOps.clipboardURLs.contains { ShellPath.key($0) == key }
    }

    // MARK: - Helpers

    private func quickLook(ids: Set<String>) {
        let urls = files.filter { ids.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        QuickLookController.shared.show(urls)
    }
}

// MARK: - Date-grouped list view

struct GroupedListView: View {
    let files:       [FileItem]
    let filesVersion: UInt
    @Binding var selectedIDs:      Set<String>
    @Binding var pendingRenameURL: URL?
    @Binding var isRenaming:       Bool
    let currentPath: URL
    let groupBy:     GroupBy
    /// Opens every item given (PaneState.openItems).
    let onOpen:      ([FileItem]) -> Void
    /// A ⌘-double-click: opens them with folders in new tabs, as in Finder.
    let onOpenInNewTabs: ([FileItem]) -> Void
    let onBrowseInto:(URL) -> Void
    let onReload:    () -> Void
    @ObservedObject var fileOps:   FileOperationsService
    @ObservedObject var favorites: FavoritesService
    var isReadOnlyLocation = false
    /// Where files dropped on empty space or on a file go (see ListView).
    let dropFolder:  URL?

    @State private var renamingID:      String?
    @State private var renameText:      String = ""
    @State private var renameCancelled: Bool   = false
    /// Bumped by every rename start, so a stale focus check can't end a newer rename.
    @State private var renameAttempt:   Int    = 0
    @FocusState private var renameActive: Bool
    @State private var groupMemo = GroupedItemsMemo()

    private var groups: [FileGroup] { groupMemo.groups(files, version: filesVersion, groupBy: groupBy) }

    var body: some View {
        ScrollViewReader { proxy in
        List(selection: $selectedIDs) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        ZStack(alignment: .leading) {
                            GroupedRow(item: item, isSelected: selectedIDs.contains(item.id))
                                .opacity(renamingID == item.id ? 0 : 1)
                            if renamingID == item.id {
                                HStack(spacing: 8) {
                                    FileIconView(item: item, size: 18)
                                    TextField(text: $renameText) { EmptyView() }
                                        .textFieldStyle(.plain)
                                        .resetsCursorOnExit()
                                        .focused($renameActive)
                                        .browserTextInput()
                                        .onSubmit {
                                            if let it = files.first(where: { $0.id == renamingID }) {
                                                commitGroupedRename(for: it)
                                            }
                                        }
                                        .onExitCommand { cancelGroupedRename() }
                                    Spacer()
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .folderDropTarget(!isReadOnlyLocation && item.isBrowsableFolder ? item.url : nil, fileOps: fileOps, reload: onReload)
                        .tag(item.id)
                        .id(item.id)
                        // Dragged by the list, which keeps its clicks (see ListView.tableView).
                        .itemProvider { [url = item.url] in FileDragSupport.provider(for: [url]) }
                    }
                } header: {
                    DateSectionHeader(title: group.title, count: group.items.count)
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("fileList")
        // Return renames, ⌘O and ⌘↓ open (see ListView.tableView).
        .background(FileListKeys(isReadOnlyLocation: isReadOnlyLocation, onKey: { itemKey($0) }))
        .contextMenu(forSelectionType: String.self) { ids in
            let sel = files.filter { ids.contains($0.id) }
            if let item = sel.first {
                FileContextMenu(item: item, targets: sel, onOpen: onOpen, onBrowseInto: onBrowseInto,
                                onRename: { pendingRenameURL = $0.url }, onReload: onReload,
                                fileOps: fileOps, favorites: favorites, isReadOnlyLocation: isReadOnlyLocation)
            } else {
                BackgroundContextMenu(directory: currentPath, isReadOnlyLocation: isReadOnlyLocation, onReload: onReload, fileOps: fileOps)
            }
        } primaryAction: { ids in
            // A double-click (Return is FileListKeys', see ListView.tableView).
            if NSApp.currentEvent?.isKeyRepeat == true { return }
            if NSApp.currentEvent?.shellItemKey == .rename { _ = itemKey(.rename); return }
            // Every selected item, after the click is done with (see ListView.tableView).
            let items = files.filter { ids.contains($0.id) }
            guard renamingID == nil, !items.isEmpty else { return }
            let inNewTabs = NSApp.currentEvent?.isCommandClick == true
            DispatchQueue.main.async { inNewTabs ? onOpenInNewTabs(items) : onOpen(items) }
        }
        .onChange(of: selectedIDs) { _, ids in
            if let id = ids.first {
                // Only as far as it takes to show it: centring it moved the row
                // from under the pointer between the clicks of a double-click.
                proxy.scrollTo(id)
            }
            // A rename whose field never got focus ends when the selection moves on.
            if let id = renamingID, !renameActive, !ids.contains(id) { cancelGroupedRename() }
        }
        .onChange(of: files) { _, newFiles in
            if let id = renamingID, !newFiles.contains(where: { $0.id == id }) {
                renamingID = nil
            }
        }
        .onChange(of: renameActive) { _, active in
            guard !active, let id = renamingID,
                  let item = files.first(where: { $0.id == id }) else { return }
            commitGroupedRename(for: item)
        }
        .onChange(of: pendingRenameURL) { _, url in
            guard let url, let item = files.first(where: { ShellPath.same($0.url, url) }) else { return }
            startGroupedRename(item: item)
            pendingRenameURL = nil
        }
        .onChange(of: renamingID) { _, id in isRenaming = id != nil }
        .onDisappear { isRenaming = false }
        // Space = Quick Look while the list has focus (see ListView.tableView).
        .onKeyPress(.space) {
            guard renamingID == nil, !TextInputFocus.isActive else { return .ignored }
            let urls = files.filter { selectedIDs.contains($0.id) }.map(\.url)
            guard !urls.isEmpty else { return .ignored }
            QuickLookController.shared.show(urls)
            return .handled
        }
        .fileDropArea(dropFolder, fileOps: fileOps, reload: onReload)
        } // ScrollViewReader
    }

    /// Return, ⌘O and ⌘↓ (see ListView.itemKey).
    private func itemKey(_ key: ShellItemKey) -> Bool {
        key.perform(on: files.filter { selectedIDs.contains($0.id) }, renaming: renamingID != nil,
                    rename: { startGroupedRename(item: $0) }, open: onOpen)
    }

    // MARK: - Grouped inline rename helpers

    func startGroupedRename(item: FileItem) {
        guard !isReadOnlyLocation else { NSSound.beep(); return }
        renameCancelled = false
        renamingID      = item.id
        renameText      = item.name
        renameAttempt  += 1
        let attempt = renameAttempt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { renameActive = true }
        // See ListView.startRename: drop a rename whose field never got focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if renameAttempt == attempt, renamingID == item.id, !renameActive { cancelGroupedRename() }
        }
    }

    private func commitGroupedRename(for item: FileItem) {
        renamingID   = nil
        renameActive = false
        guard !renameCancelled else { renameCancelled = false; return }
        guard let name = NamePrompt.validatedInlineName(renameText, for: item, fileOps: fileOps) else { return }
        fileOps.rename(item.url, to: name, reload: onReload)
    }

    private func cancelGroupedRename() {
        renameCancelled = true
        renamingID      = nil
    }
}

struct GroupedRow: View {
    let item:       FileItem
    let isSelected: Bool
    var body: some View {
        HStack(spacing: 8) {
            FileIconView(item: item, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.name).scaledFont(size: 13).lineLimit(1)
                    TagDotsView(colors: item.tagColors, names: item.spokenTagNames, size: 9)
                }
                Text(item.kind + (item.isDirectory ? "" : " • \(item.formattedSize)"))
                    .scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            // When space runs short (large text, preview open) the date gives way
            // to the name, and neither wraps a word per line.
            .layoutPriority(1)
            Spacer()
            Text(item.formattedDateModified)
                .scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Date section header (Finder-style)

struct DateSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(nil)
            Spacer()
            Text("\(count) items")
                .scaledFont(size: 10)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }
}

// MARK: - Return, ⌘O and ⌘↓ on the selection

extension ShellItemKey {
    /// Does what the key does to `selected` (ShellItemKey.action), after the key
    /// is done with: a rename prompt is modal, and opening a folder replaces the
    /// rows. Text with focus keeps the key. Returns whether the key was taken.
    @MainActor
    func perform(on selected: [FileItem], renaming: Bool = false,
                 rename: @escaping (FileItem) -> Void, open: @escaping ([FileItem]) -> Void) -> Bool {
        let result = action(selected: selected, textHasFocus: TextInputFocus.isActive, renaming: renaming)
        switch result {
        case .rename(let item):
            ReturnRepeatGuard.shared.arm()
            DispatchQueue.main.async { rename(item) }
        case .open(let items):  DispatchQueue.main.async { open(items) }
        case .ignore, .pass:    break
        }
        return result.isHandled
    }
}

extension ShellItemKey.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.shift)   { insert(.shift) }
        if flags.contains(.option)  { insert(.option) }
        if flags.contains(.control) { insert(.control) }
    }

    init(_ modifiers: SwiftUI.EventModifiers) {
        self = []
        if modifiers.contains(.command) { insert(.command) }
        if modifiers.contains(.shift)   { insert(.shift) }
        if modifiers.contains(.option)  { insert(.option) }
        if modifiers.contains(.control) { insert(.control) }
    }
}

extension NSEvent {
    /// A click with ⌘ held: a ⌘-double-click opens folders in new tabs, as in Finder.
    var isCommandClick: Bool {
        (type == .leftMouseDown || type == .leftMouseUp) && modifierFlags.contains(.command)
    }

    /// A held key's repeat (`isARepeat`, which only key events may be asked).
    var isKeyRepeat: Bool {
        (type == .keyDown || type == .keyUp) && isARepeat
    }

    /// The key pressed, as ShellItemKey reads it; nil for any other key or event.
    var shellItemKey: ShellItemKey? {
        guard type == .keyDown else { return nil }
        return ShellItemKey.key(characters: charactersIgnoringModifiers ?? "", modifiers: .init(modifierFlags),
                                keyCode: Int(keyCode), latinLayout: LatinKeyboardLayout.characters(forKeyCode:))
    }
}

/// Return held down after it started a rename: its repeats would go on to the
/// name field (keeping the name unchanged and ending the rename) or the name
/// prompt (pressing Rename). They're dropped until the key comes up or is
/// pressed again, so only that one press's repeats are. A held Return that
/// commits a rename isn't armed here: the lists ignore its repeats instead
/// (the primary-action fallbacks and ColumnPane.handleKey). XCUITest can't
/// send key repeats, so none of this has a UI test.
@MainActor
final class ReturnRepeatGuard {
    static let shared = ReturnRepeatGuard()
    private var armed = false
    private var monitor: Any?

    /// Called as a Return press starts a rename.
    func arm() {
        armed = true
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.armed, event.keyCode == 36 || event.keyCode == 76 else { return event }  // Return, Enter
            guard event.type == .keyDown, event.isARepeat else {
                self.armed = false
                return event
            }
            return nil
        }
    }
}

/// The Mac's Latin keyboard layout (its ASCII-capable input source: ABC, US,
/// Dvorak...), which menus match ⌘ shortcuts against while a layout of other
/// letters (Russian, Greek) is in use.
enum LatinKeyboardLayout {
    /// What the key with `keyCode` types on it, without modifiers; nil if the
    /// layout can't be read.
    static func characters(forKeyCode keyCode: Int) -> String? {
        guard let code = UInt16(exactly: keyCode),
              let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        // The layout data belongs to the input source: keep that until it's read.
        return withExtendedLifetime(source) { () -> String? in
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            let capacity = 4
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: capacity)
            var length = 0
            let status = data.withUnsafeBytes { bytes -> OSStatus in
                guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                    return OSStatus(paramErr)
                }
                return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                      OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                      capacity, &length, &characters)
            }
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

extension KeyPress {
    /// The key's characters as ShellItemKey.key reads them (AppKit's).
    var itemKeyCharacters: String {
        switch key {
        case .return:    return "\r"
        case .downArrow: return "\u{F701}"
        default:         return characters
        }
    }

    /// The key pressed, as ShellItemKey reads it (NSEvent.shellItemKey): its
    /// key code, for the Latin layout, comes from the key event being handled,
    /// which a KeyPress doesn't carry.
    @MainActor
    var shellItemKey: ShellItemKey? {
        let event = NSApp.currentEvent
        return ShellItemKey.key(characters: itemKeyCharacters, modifiers: .init(modifiers),
                                keyCode: event?.type == .keyDown ? event.map { Int($0.keyCode) } : nil,
                                latinLayout: LatinKeyboardLayout.characters(forKeyCode:))
    }
}

/// Hands Return, ⌘O and ⌘↓ (ShellItemKey) to `onKey` while the list it's
/// behind (a table inside this view's area, so never the sidebar) has keyboard
/// focus, before the table sees them. A list with a primary action takes Return
/// as Open, just as it takes a double-click, so Return has to be caught on its
/// way there; nothing in the action itself says for certain which it was.
/// `onKey` returns whether it took the key. An inline rename, the search field
/// and the path editor are text views, not the table, so Return stays theirs.
///
/// It also has that table's row drags offer other apps what an icon's do
/// (FileMouseView.otherAppsOperations): SwiftUI's tables and lists offer them
/// a copy only (NSTableView's default) and have no way to say otherwise. Their
/// drags within Selway are unchanged. The receiver does the work, and the
/// folder's watcher shows the result; a move to the Trash from here can't be
/// undone in Selway, as SwiftUI keeps the table's drag-end callback.
struct FileListKeys: NSViewRepresentable {
    var isReadOnlyLocation = false
    let onKey: (ShellItemKey) -> Bool

    func makeNSView(context: Context) -> _FileListKeysView {
        let view = _FileListKeysView()
        view.onKey = onKey
        view.isReadOnlyLocation = isReadOnlyLocation
        return view
    }

    func updateNSView(_ view: _FileListKeysView, context: Context) {
        view.onKey = onKey
        view.isReadOnlyLocation = isReadOnlyLocation
        view.offerDragOutOperations()
    }

    static func dismantleNSView(_ view: _FileListKeysView, coordinator: ()) {
        view.stop()
    }
}

final class _FileListKeysView: NSView {
    var onKey: ((ShellItemKey) -> Bool)?
    var isReadOnlyLocation = false
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Not a held key's repeats: a held ⌘↓ would open folder after folder,
            // and a held Return's are ReturnRepeatGuard's (a held ⌘O's go on to
            // File ▸ Open, which drops them). The key is read last: on a
            // non-Latin layout that reads the Latin one, and every list has
            // a monitor.
            guard let self, let window = self.window, event.window === window, !event.isARepeat,
                  let table = window.firstResponder as? NSTableView, self.holds(table),
                  let key = event.shellItemKey,
                  self.onKey?(key) == true else { return event }
            return nil
        }
        offerDragOutOperations()
    }

    /// The table whose drags were last given other apps' operations.
    private weak var offeringTable: NSTableView?
    private var offeredReadOnlyLocation: Bool?

    /// Gives the table in this view's area other apps' drag operations
    /// (see FileListKeys), once SwiftUI has made it: after this turn of the
    /// run loop, and again whenever the view is updated, until it has.
    func offerDragOutOperations() {
        guard window != nil,
              offeringTable?.window !== window || offeredReadOnlyLocation != isReadOnlyLocation else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let content = self.window?.contentView,
                  let table = self.table(in: content) else { return }
            // A read-only folder's files are copied, never moved: not generic
            // either, which Finder takes as a move (FileMouseView).
            let readOnly: NSDragOperation = [.move, .generic, .delete]
            let external = isReadOnlyLocation
                ? FileMouseView.otherAppsOperations.subtracting(readOnly)
                : FileMouseView.otherAppsOperations
            // Within Selway the drop decides, and refuses to move these
            // (FileDropView), so SwiftUI's own mask is left alone.
            table.setDraggingSourceOperationMask(external, forLocal: false)
            self.offeringTable = table
            self.offeredReadOnlyLocation = self.isReadOnlyLocation
        }
    }

    /// The first table under `view` that `holds` says is this view's.
    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, !table.isHiddenOrHasHiddenAncestor, holds(table) { return table }
        for subview in view.subviews {
            if let table = table(in: subview) { return table }
        }
        return nil
    }

    /// Whether `table` lies within this view's area of the window. Compared by
    /// its scroll view: the table itself is as tall as its rows and can be far
    /// wider than the list (wide columns, large text), so its middle can lie
    /// outside the list.
    private func holds(_ table: NSTableView) -> Bool {
        let shown: NSView = table.enclosingScrollView ?? table
        let area = convert(bounds, to: nil)
        let frame = shown.convert(shown.bounds, to: nil)
        return frame.intersects(area) && (area.minX...area.maxX).contains(frame.midX)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
