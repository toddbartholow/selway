import SwiftUI
import AppKit

private let kDefaultColWidth: CGFloat = 230
private let kMinColWidth:     CGFloat = 120
private let kPreviewWidth:    CGFloat = 260

// MARK: - Columns view (macOS Finder-style)

struct ColumnsView: View {
    @Binding var currentPath: URL
    /// The read-only Time Machine disk's root among the columns, if any
    /// (BrowserModel.timeMachineRoot).
    var timeMachineRoot: URL?
    let showHidden:     Bool
    let showColumnTree: Bool
    let groupBy:        GroupBy
    let sortField:      SortField
    let sortAscending:  Bool
    let folderOrder:    FolderOrder
    @ObservedObject var fileOps:   FileOperationsService
    @ObservedObject var favorites: FavoritesService
    // Search support — when isSearchActive the column browser is replaced by a flat results list
    let searchResults:  [FileItem]
    let isSearchActive: Bool
    /// The current folder's Time Machine note, shown in its column, which then
    /// has no list to go into.
    let backupNote: BackupNote?
    /// The window's selection, for the search results: the arrow keys move it, and
    /// Return or a double-click opens, as in the list view.
    @Binding var selectedIDs: Set<String>
    /// Opens a file (never a folder: the column view shows those itself) the
    /// same way List/Icons do (Markdown reader, Ace, workspace).
    let onOpen: (URL) -> Void
    /// Opens every item given (search results, or several selected in a column),
    /// as List/Icons do (PaneState.openItems).
    let onOpenResults: ([FileItem]) -> Void
    /// A ⌘-double-click: opens the items with folders in new tabs, as in Finder.
    let onOpenInNewTabs: ([FileItem]) -> Void
    /// Files were selected in a column: (files, folder containing them). None
    /// when the column's selection was cleared: its folder is then the current one.
    let onSelectFiles: ([URL], URL) -> Void
    /// The highlighted file was dropped (columns rebuilt); clear the shared selection.
    let onClearSelection: () -> Void
    /// Refreshes the search results after a file operation on one of them.
    let onSearchReload: () -> Void
    /// A folder selected within the column browser: shown, but (as in Finder) not
    /// a Back / Forward step.
    let onSelectFolder: (URL) -> Void
    /// Bumped by Edit ▸ Select All: selects everything in the focused column.
    let selectAllRequest: Int
    /// Bumped by File ▸ Open: the focused column opens its selection, as ⌘O.
    let openRequest: Int
    /// Whether the column File ▸ Open acts on has something selected, as it changes.
    let onCommandPaneSelection: (Bool) -> Void
    /// The window's selection (in the current folder): what Copy, Delete and
    /// Quick Look act on. Shown in the columns when something other than the
    /// columns changed it (followWindowSelection).
    let windowSelection: [FileItem]
    /// The window is waiting for a listing to select files the columns picked.
    let hasPendingSelection: Bool
    /// The window's (BrowserModel.openResolver): follows a link the listing
    /// didn't follow, off the main thread, when it's opened.
    let openResolver: ShellOpenResolver

    @State private var columns:         [URL]          = []
    @State private var colWidths:       [Int: CGFloat] = [:]
    @State private var selectedFileURL: URL?
    /// The selected file is a link the listing didn't follow: no preview of it.
    @State private var selectedFileIsUnfollowedLink = false
    /// Each column's selection, by path (ShellPath.key): the folder shown in the
    /// next column, the previewed file, or the items selected there together.
    /// Columns don't share one: the window's selection (`selectedIDs`) is cleared
    /// whenever the current folder changes, which happens as folders are selected.
    @State private var paneSelections: [Int: Set<String>] = [:]
    @FocusState private var focusedPane: Int?
    /// The column the user last selected in: Select All's column when none has focus.
    @State private var activePane: Int?
    /// The column → went into, which selects its first item once it's listed.
    @State private var enteringPane: Int?
    @State private var selectAllPane = ColumnPaneRequest()
    @State private var openPane = ColumnPaneRequest()
    /// A press on a selected row, waiting for its mouse-up: a plain press inside
    /// a larger selection narrows it to the row after the double-click interval,
    /// a ⌘-press takes the row out (ShellPressRelease). One for all the columns,
    /// as only one press is under way at a time: a press in another column
    /// ends the last one's wait, and → can narrow before going in.
    @State private var pressReleases = ShellPressRelease(interval: { PressNarrowing.wait })
    /// Nil until the user drags it: the default follows the text size.
    @State private var previewWidth:    CGFloat?
    @Environment(\.textScale) private var textScale

    /// Grows less than the text, like the list's preview panel.
    private var defaultPreviewWidth: CGFloat { kPreviewWidth * min(textScale, 1.5) }

    var body: some View {
        Group {
            if isSearchActive {
                searchResultsView
            } else {
                columnBrowserView
            }
        }
        // The results and the column browser select different things. The window's
        // selection is reset as one gives way to the other (PaneState.searchToggled); the
        // column highlight goes too, so the browser doesn't come back showing a
        // file that isn't the selection.
        .onChange(of: isSearchActive) { _, _ in
            // An open waiting on a link in a column is for columns now hidden.
            openResolver.cancel()
            selectedFileURL = nil
            if let last = columns.indices.last { paneSelections[last] = nil }
        }
    }

    // MARK: - Search results flat list

    private var searchResultsView: some View {
        List(searchResults, selection: $selectedIDs) { item in
            HStack(spacing: 8) {
                FileIconView(item: item, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(item.name)
                            .scaledFont(size: 12)
                            .lineLimit(1)
                        TagDotsView(colors: item.tagColors, names: item.spokenTagNames, size: 9)
                    }
                    Text(item.url.deletingLastPathComponent().path)
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if item.isBrowsableFolder {
                    Image(systemName: "chevron.forward")
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            // A folder result takes drops; the results as a whole show no one
            // folder, so drops anywhere else are refused.
            .folderDropTarget(item.isBrowsableFolder ? item.url : nil, fileOps: fileOps, reload: onSearchReload)
            // Dragged by the list, which keeps its clicks (see ListView.tableView).
            .itemProvider { [url = item.url] in FileDragSupport.provider(for: [url]) }
        }
        .listStyle(.plain)
        // Return renames (with a prompt, as in the columns), ⌘O and ⌘↓ open
        // (see ListView.tableView).
        .background(FileListKeys { searchResultKey($0) })
        // `ids` is the selection when the row clicked is in it, otherwise that row
        // (as in the list view); the menu acts on all of them.
        .contextMenu(forSelectionType: String.self) { ids in
            let targets = searchResults.filter { ids.contains($0.id) }
            if let item = targets.first {
                searchResultContextMenu(item: item, targets: targets)
            }
        } primaryAction: { ids in
            // A double-click (Return is FileListKeys', see ListView.tableView).
            if NSApp.currentEvent?.isKeyRepeat == true { return }
            if NSApp.currentEvent?.shellItemKey == .rename { _ = searchResultKey(.rename); return }
            // Every selected result, after the click is done with (see ListView.tableView).
            let items = searchResults.filter { ids.contains($0.id) }
            guard !items.isEmpty else { return }
            let inNewTabs = NSApp.currentEvent?.isCommandClick == true
            DispatchQueue.main.async { inNewTabs ? onOpenInNewTabs(items) : onOpenResults(items) }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Return, ⌘O and ⌘↓ on the selected results (see ListView.itemKey).
    private func searchResultKey(_ key: ShellItemKey) -> Bool {
        key.perform(on: searchResults.filter { selectedIDs.contains($0.id) },
                    rename: { NamePrompt.rename($0, fileOps: fileOps, reload: onSearchReload) },
                    open: onOpenResults)
    }

    // MARK: - Normal column browser

    private var columnBrowserView: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { idx, dir in
                        paneAndHandle(idx: idx, dir: dir)
                    }
                    // Preview column — auto-shown when a file is selected, just like macOS Finder
                    if let fileURL = selectedFileURL {
                        ResizeHandle { delta in
                            previewWidth = max(180, (previewWidth ?? defaultPreviewWidth) + delta)
                        }
                        ColumnPreviewPane(url: fileURL, isLinkNotFollowed: selectedFileIsUnfollowedLink)
                            .frame(width: previewWidth ?? defaultPreviewWidth)
                            .id("preview")
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            }
            .onChange(of: columns) { _, cols in
                if let last = cols.indices.last {
                    withAnimation { proxy.scrollTo(last, anchor: .trailing) }
                }
            }
            .onChange(of: selectedFileURL) { _, url in
                if url != nil {
                    DispatchQueue.main.async {
                        withAnimation { proxy.scrollTo("preview", anchor: .trailing) }
                    }
                }
            }
            // ← can move into a column scrolled out of sight on the left.
            .onChange(of: focusedPane) { _, pane in
                guard let pane else { return }
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(pane) } }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .background(ColumnArrowKeys { arrow, _ in arrowKey(right: arrow == .right) })
        // A click inside a selection waiting to narrow it is dropped by Select
        // All (which may change nothing a column sees, everything being
        // selected already) and by any menu opening: a context menu acts on
        // the selection it opened on.
        .onReceive(NotificationCenter.default.publisher(for: .selectAllRequested)) { _ in
            pressReleases.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            pressReleases.cancel()
        }
        .onChange(of: windowSelection) { _, items in followWindowSelection(items) }
        .onChange(of: selectAllRequest) { _, _ in
            guard let pane = commandPane else { return }
            selectAllPane = ColumnPaneRequest(pane: pane, serial: selectAllPane.serial + 1)
        }
        .onChange(of: openRequest) { _, _ in
            guard let pane = commandPane else { return NSSound.beep() }
            openPane = ColumnPaneRequest(pane: pane, serial: openPane.serial + 1)
        }
        .onChange(of: commandPaneHasSelection, initial: true) { _, has in onCommandPaneSelection(has) }
        .onAppear       { buildColumns() }
        .onChange(of: currentPath)    { _, newPath in
            // Clicks inside the column view update `columns` first and then set
            // currentPath to the last column — keep that trail. Any other
            // navigation (sidebar, path bar, a folder created elsewhere) rebuilds.
            // Compared by path: `columns` holds "dir/" URLs while currentPath may
            // arrive without the slash, and URL == would collapse the trail.
            if !ShellPath.same(columns.last, newPath) { buildColumns() }
        }
        .onChange(of: showColumnTree) { _, _ in buildColumns() }
        .onChange(of: backupNote) { _, _ in leaveNoteColumn() }
        // An open waiting on a link in a column is dropped as soon as that
        // column's folder or selection changes, not when the link answers.
        .onChange(of: columns) { _, _ in openResolver.recheck() }
        .onChange(of: paneSelections) { _, _ in openResolver.recheck() }
        // Gone (another view): its columns can't be asked any more.
        .onDisappear { openResolver.cancel() }
    }

    @ViewBuilder
    private func paneAndHandle(idx: Int, dir: URL) -> some View {
        if isBackupNoteColumn(idx: idx, dir: dir), let backupNote {
            BackupNoteView(note: backupNote)
                .frame(width: previewWidth ?? defaultPreviewWidth, alignment: .topLeading)
                .id(idx)
        } else {
            ColumnPane(
                paneIndex:      idx,
                focusedPane:    $focusedPane,
                selectedKeys:   paneSelections[idx] ?? [],
                currentKeys:    { paneSelections[idx] ?? [] },
                releases:       pressReleases,
                isEntering:     enteringPane == idx,
                selectAllRequest: selectAllPane,
                openRequest:    openPane,
                directory:      dir,
                // Each column by its own folder: the pane's is the last column's.
                isReadOnlyLocation: TimeMachineBackups.isSnapshotPath(dir)
                    || timeMachineRoot.map { ShellPath.same($0, dir) } == true,
                showHidden:     showHidden,
                groupBy:        groupBy,
                sortField:      sortField,
                sortAscending:  sortAscending,
                folderOrder:    folderOrder,
                onSelectItems:  { picked in select(picked, in: idx) },
                onSelectionPruned: { keys in paneSelections[idx] = keys },
                onEnter:        { item in enter(item, from: idx) },
                onOpenFolder: { url in
                    showFolder(url, after: idx)
                },
                onOpenLink:   { item in openLink(item, from: idx) },
                onBrowseInto: { url in
                    showColumn(url, after: idx)
                    currentPath = url
                },
                onOpen:      onOpen,
                onOpenItems: onOpenResults,
                onOpenInNewTabs: onOpenInNewTabs,
                fileOps:   fileOps,
                favorites: favorites
            )
            .frame(width: colWidths[idx, default: kDefaultColWidth * textScale], alignment: .topLeading)
            .id(idx)
        }

        ResizeHandle { delta in
            if isBackupNoteColumn(idx: idx, dir: dir) {
                previewWidth = max(180, (previewWidth ?? defaultPreviewWidth) + delta)
            } else {
                let current = colWidths[idx, default: kDefaultColWidth * textScale]
                colWidths[idx] = max(kMinColWidth * textScale, current + delta)
            }
        }
    }

    /// Column `idx` shows the current folder's note (backupNote) instead of a list.
    private func isBackupNoteColumn(idx: Int, dir: URL) -> Bool {
        idx == columns.indices.last && backupNote.map { ShellPath.same(dir, $0.folder) } == true
    }

    /// A column that turned into a note once its folder was read: → or ⌘↓
    /// may have sent focus into it before then. Focus goes back to the column
    /// that selected it, and nothing waits to select its first item.
    private func leaveNoteColumn() {
        guard let last = columns.indices.last, isBackupNoteColumn(idx: last, dir: columns[last]) else { return }
        let back = last > 0 ? last - 1 : nil
        if activePane == last { activePane = back }
        if focusedPane == last { focusedPane = back }
        if enteringPane == last {
            enteringPane = nil
            // The key's focus is set a turn later (goInto, arrowKey), so may still be to come.
            DispatchQueue.main.async { if focusedPane == last { focusedPane = back } }
        }
    }

    // MARK: - Selection

    /// The column Edit ▸ Select All and File ▸ Open act on (ColumnNavigation.commandPane).
    private var commandPane: Int? {
        ColumnNavigation.commandPane(focused: focusedPane, active: activePane, count: columns.count)
    }

    private var commandPaneHasSelection: Bool {
        guard let pane = commandPane else { return false }
        return !(paneSelections[pane] ?? []).isEmpty
    }

    /// The user selected `picked` in column `idx`: a click, the arrow keys,
    /// typing a name, ⌘A. One folder is shown as the next column and one file
    /// previewed; with none or several, the column is the last one shown.
    private func select(_ picked: [FileItem], in idx: Int) {
        guard columns.indices.contains(idx) else { return }
        activePane = idx
        enteringPane = nil
        let dir = columns[idx]
        if picked.count == 1 {
            let item = picked[0]
            if item.isBrowsableFolder {
                showFolder(item.url, after: idx)
                return
            }
            if item.isLinkNotFollowed, columns.indices.contains(idx + 1),
               ShellPath.same(columns[idx + 1], item.url) {
                // A link the listing didn't follow, already opened as the next
                // column: a click on it (or the tap that comes with a
                // double-click) keeps that column, as for a folder.
                paneSelections[idx] = [ShellPath.key(item.url)]
                return
            }
            selectedFileURL = item.url
            selectedFileIsUnfollowedLink = item.isLinkNotFollowed
        } else {
            selectedFileURL = nil
        }
        trimColumns(after: idx)
        paneSelections[idx] = Set(picked.map { ShellPath.key($0.url) })
        // The folder holding the selection becomes the current folder (it was
        // left pointing at a deeper, now hidden column, so New Folder / Paste
        // went somewhere the user couldn't see).
        onSelectFiles(picked.map(\.url), dir)
    }

    /// Shows the window's selection when something other than the columns
    /// changed it (a paste, New Folder, Undo, a drop, items Move to Trash kept):
    /// the column showing the current folder selects those items, so what ⌘⌫
    /// and ⌘C act on is always what's highlighted. A single folder is shown as
    /// the next column, as when it's clicked, but stays the selection.
    private func followWindowSelection(_ items: [FileItem]) {
        guard !isSearchActive, !hasPendingSelection,
              let idx = columns.lastIndex(where: { ShellPath.same($0, currentPath) }) else { return }
        let keys = Set(items.map { ShellPath.key($0.url) })
        let folder = items.count == 1 && items[0].isBrowsableFolder ? items[0] : nil
        let file = items.count == 1 && folder == nil ? items[0] : nil
        let next = columns.indices.contains(idx + 1) ? columns[idx + 1] : nil
        let shown = (paneSelections[idx] ?? []) == keys
            && (next == nil ? folder == nil : folder.map { ShellPath.same(next, $0.url) } ?? false)
            && (selectedFileURL == nil ? file == nil : file.map { ShellPath.same(selectedFileURL, $0.url) } ?? false)
        guard !shown else { return }
        if let folder {
            showColumn(folder.url, after: idx)
        } else {
            trimColumns(after: idx)
            paneSelections[idx] = keys
            selectedFileURL = file?.url
            selectedFileIsUnfollowedLink = file?.isLinkNotFollowed ?? false
        }
    }

    /// →: into the folder selected in column `idx`, selecting its first item.
    private func enter(_ item: FileItem, from idx: Int) {
        let shown = columns.indices.contains(idx + 1) && ShellPath.same(columns[idx + 1], item.url)
        if shown {
            guard !isBackupNoteColumn(idx: idx + 1, dir: columns[idx + 1]) else { return }
            return goInto(idx + 1)
        }
        // A link the listing didn't follow: followed now, once, as Open does,
        // off the main thread (resolve); anything else at once.
        resolve(item, in: idx) { target in
            switch target {
            case .folder:
                showFolder(item.url, after: idx)
                goInto(idx + 1)
            case .unreachable:
                FileOpener.showUnreachable([item.name])
            default:
                NSSound.beep()
            }
        }
    }

    /// Focus to column `idx`, which selects its first item once it's listed.
    private func goInto(_ idx: Int) {
        guard columns.indices.contains(idx), !isBackupNoteColumn(idx: idx, dir: columns[idx]) else { return }
        enteringPane = idx
        DispatchQueue.main.async { focusedPane = idx }
    }

    /// Open (a double-click, Open) on a link the listing didn't follow in
    /// column `idx`: a folder it leads to is shown as the next column, a
    /// file opens where the follow decided, and one that couldn't be reached
    /// says so.
    private func openLink(_ item: FileItem, from idx: Int) {
        resolve(item, in: idx) { target in
            switch target {
            case .folder:      showFolder(item.url, after: idx)
            case .unreachable: FileOpener.showUnreachable([item.name])
            default:           FileOpener.open(item.url, as: target)
            }
        }
    }

    /// Where `item` in column `idx` opens (the window's ShellOpenResolver,
    /// which follows a link the listing didn't follow off the main thread;
    /// anything else that isn't a folder is `.app` here). Dropped once
    /// column `idx` no longer shows the same folder with that item alone
    /// selected (`recheck` on each change, and when the answer comes).
    private func resolve(_ item: FileItem, in idx: Int, then: @escaping (ShellOpenTarget) -> Void) {
        guard columns.indices.contains(idx) else { return }
        let folder = columns[idx]
        let key = ShellPath.key(item.url)
        openResolver.resolve([item], isRelevant: {
            columns.indices.contains(idx) && ShellPath.same(columns[idx], folder) && paneSelections[idx] == [key]
        }) { resolution in
            then(resolution.followed[item.id] ?? (resolution.folders.contains(item.id) ? .folder : .app))
        }
    }

    /// ← / → in the focused column (ColumnArrowKeys). → goes into the folder
    /// shown next (a link the listing didn't follow goes in with ⌘↓ / ⌘O). A
    /// click on a folder inside a selection, waiting to narrow it, narrows it
    /// first (ShellPressRelease.flush), which shows that folder next.
    private func arrowKey(right: Bool) -> Bool {
        guard let pane = focusedPane, columns.indices.contains(pane) else { return false }
        if right {
            pressReleases.flush()
            guard columns.indices.contains(pane + 1),
                  paneSelections[pane] == [ShellPath.key(columns[pane + 1])],
                  !isBackupNoteColumn(idx: pane + 1, dir: columns[pane + 1]) else { return false }
            activePane = pane
            enteringPane = pane + 1
            DispatchQueue.main.async { focusedPane = pane + 1 }
            return true
        }
        guard pane > 0 else { return false }
        leave(pane)
        return true
    }

    /// ←: back to column `idx - 1`, where the folder column `idx` shows stays
    /// selected, with nothing selected inside it (as a click on that folder).
    private func leave(_ idx: Int) {
        guard idx > 0, columns.indices.contains(idx) else { return }
        activePane = idx - 1
        enteringPane = nil
        showFolder(columns[idx], after: idx - 1)
        focusedPane = idx - 1
    }

    /// The folder selected or opened in column `idx`, shown as the next column.
    private func showFolder(_ url: URL, after idx: Int) {
        showColumn(url, after: idx)
        onSelectFolder(url)
    }

    /// Shows `url` as the column after `idx`, selected in `idx`, and no preview.
    private func showColumn(_ url: URL, after idx: Int) {
        columns = Array(columns.prefix(idx + 1)) + [url]
        paneSelections = paneSelections.filter { $0.key < idx }
        paneSelections[idx] = [ShellPath.key(url)]
        selectedFileURL = nil
    }

    /// Closes the columns after `idx`, and their selections.
    private func trimColumns(after idx: Int) {
        columns = Array(columns.prefix(idx + 1))
        paneSelections = paneSelections.filter { $0.key <= idx }
    }

    // MARK: - Context menu for search result rows

    private func searchResultContextMenu(item: FileItem, targets: [FileItem]) -> some View {
        FileContextMenu(
            item:         item,
            targets:      targets,
            onOpen:       onOpenResults,
            onBrowseInto: { currentPath = $0 },
            onRename:     { NamePrompt.rename($0, fileOps: fileOps, reload: onSearchReload) },
            // Re-runs the search so a trashed / renamed result doesn't linger.
            onReload:     onSearchReload,
            fileOps:      fileOps,
            favorites:    favorites
        )
    }

    private func buildColumns() {
        if selectedFileURL != nil { onClearSelection() }
        selectedFileURL = nil
        enteringPane = nil
        activePane = nil
        if showColumnTree {
            // Full ancestor chain up to root (logical path — symlinks stay as opened)
            var chain = ShellPath.ancestorChain(currentPath)
            chain[chain.count - 1] = currentPath
            columns = chain
        } else {
            // Default: show only the current folder, no ancestor tree
            columns = [currentPath]
        }
        // Each column selects the folder shown in the next one.
        var selections: [Int: Set<String>] = [:]
        for idx in columns.indices.dropLast() { selections[idx] = [ShellPath.key(columns[idx + 1])] }
        paneSelections = selections
    }
}

// MARK: - Preview column (mirrors Finder's rightmost preview pane)

struct ColumnPreviewPane: View {
    let url: URL
    /// A link the listing didn't follow: previewing it would follow it.
    let isLinkNotFollowed: Bool
    @State private var item: FileItem?
    /// Reads of the file after it changed on disk; a newer read or another
    /// file selected meanwhile drops an older one's result.
    @State private var rereads = ShellGeneration()
    @Environment(\.textScale) private var textScale

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isLinkNotFollowed {
                    UnfollowedLinkPreview()
                } else {
                    QLSidebarPreview(url: url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let item {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        FileIconView(item: item, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .scaledFont(size: 12, weight: .semibold)
                                .lineLimit(3)
                            TagDotsView(colors: item.tagColors, names: item.spokenTagNames, size: 10)
                        }
                    }
                    Divider()
                    detailRow("Kind:",     item.kind)
                    detailRow("Size:",     item.formattedSize)
                    detailRow("Modified:", item.formattedDateModified)
                    detailRow("Created:",  item.formattedDateCreated)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        // A fresh URL: the selected item's is the listing's, which would give
        // back the size and dates the file had when the folder was listed.
        .onAppear   { item = FileItem.load(from: ModelPaths.fresh(url)) }
        .onChange(of: url) { _, u in
            rereads.next()
            item = FileItem.load(from: ModelPaths.fresh(u))
        }
        // The file changed in place (DirectoryWatcher): its size and dates
        // follow, read off the main thread (a file being written sends these
        // a few times a second).
        .onReceive(NotificationCenter.default.publisher(for: .directoryEntriesChanged)) { n in
            guard let folder = n.object as? URL, ShellPath.isParent(folder, of: url),
                  DirectoryWatcher.changedNames(n)?.contains(url.lastPathComponent) == true else { return }
            let token = rereads.next()
            let file = url
            DispatchQueue.global(qos: .userInitiated).async {
                let loaded = FileItem.load(from: ModelPaths.fresh(file))
                DispatchQueue.main.async {
                    guard rereads.isCurrent(token) else { return }
                    item = loaded
                }
            }
        }
    }

    private func detailRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label).scaledFont(.caption).foregroundStyle(.secondary)
                .frame(width: 52 * textScale, alignment: .leading)
            Text(value).scaledFont(.caption).lineLimit(2)
        }
    }
}

// MARK: - Drag handle between column panes
//
// Cursor is managed explicitly via NSTrackingArea enter/exit + the SwiftUI drag
// lifecycle — NOT via addCursorRect. Cursor rects are SUPPRESSED by AppKit during
// a drag, so a rect-based handle leaves the resize cursor "stuck" after you grab,
// drag, and release over a non-rect area (the file list). Managing the cursor
// directly on enter/exit/drag-end guarantees it is released the instant there is
// nothing left to drag.
//
// The flow:
//   • pointer enters handle      → resizeLeftRight
//   • pointer leaves (no drag)   → arrow
//   • drag in progress           → resizeLeftRight re-asserted every change
//   • drag ends                  → arrow, unless still hovering the handle
// During a drag we keep `hovering` accurate (the tracking area uses
// .enabledDuringMouseDrag) but suppress the arrow reset, so the resize cursor
// stays put while you actually resize.

private struct ResizeHandle: View {
    let onDrag: (CGFloat) -> Void
    @State private var hovering:  Bool    = false
    @State private var dragging:  Bool    = false
    @State private var lastDelta: CGFloat = 0

    var body: some View {
        Color.clear
            .frame(width: 8)
            .overlay(
                Rectangle()
                    .fill(hovering
                          ? Color.accentColor.opacity(0.7)
                          : Color(nsColor: .separatorColor).opacity(0.5))
                    .frame(width: 1)
            )
            .overlay(ResizeCursorTracker(isHovering: $hovering, isDragging: $dragging))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        dragging = true
                        NSCursor.resizeLeftRight.set()   // keep resize cursor for the whole drag
                        let delta = v.translation.width - lastDelta
                        lastDelta  = v.translation.width
                        onDrag(delta)
                    }
                    .onEnded { _ in
                        lastDelta = 0
                        dragging  = false
                        // Release immediately unless the pointer is still on the handle.
                        if hovering { NSCursor.resizeLeftRight.set() }
                        else        { NSCursor.arrow.set() }
                    }
            )
    }
}

// Transparent overlay NSView that manages the resize cursor and hover state via
// geometry-based NSTrackingArea enter/exit events (instant, no cursor-rect lag).
// hitTest returns nil so SwiftUI gestures on the parent still fire normally.
private struct ResizeCursorTracker: NSViewRepresentable {
    @Binding var isHovering: Bool
    @Binding var isDragging: Bool
    func makeNSView(context: Context) -> _ResizeCursorTrackerView {
        _ResizeCursorTrackerView(isHovering: $isHovering, isDragging: $isDragging)
    }
    func updateNSView(_ v: _ResizeCursorTrackerView, context: Context) {}
}

private final class _ResizeCursorTrackerView: NSView {
    private var _isHovering: Binding<Bool>
    private var _isDragging: Binding<Bool>
    private var trackingArea: NSTrackingArea?

    init(isHovering: Binding<Bool>, isDragging: Binding<Bool>) {
        self._isHovering = isHovering
        self._isDragging = isDragging
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        guard !bounds.isEmpty else { return }
        // .enabledDuringMouseDrag keeps `hovering` accurate while resizing so the
        // drag-end handler knows whether to release the cursor.
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        _isHovering.wrappedValue = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        _isHovering.wrappedValue = false
        // Only release when not actively resizing — otherwise the cursor would
        // flicker to arrow the moment the pointer slips past the 8-pt handle.
        if !_isDragging.wrappedValue { NSCursor.arrow.set() }
    }
}

// MARK: - ← / → between columns

/// Hands the arrow keys in `arrows` to `onArrow` while one of the column lists
/// (a table inside this view's bounds, so never the sidebar) has keyboard
/// focus: ← and → without modifiers, ↑ and ↓ with or without ⇧. A SwiftUI
/// List is an NSOutlineView, which takes ← and → for expanding and collapsing
/// rows, and ↑ and ↓ for its own selection, before `onKeyPress` sees them.
/// `onArrow` gets the key and whether ⇧ was held, and returns whether it used
/// the key; one it didn't use goes on to the list.
struct ColumnArrowKeys: NSViewRepresentable {
    enum Arrow { case left, right, up, down }

    var arrows: Set<Arrow> = [.left, .right]
    let onArrow: (_ arrow: Arrow, _ shift: Bool) -> Bool

    func makeNSView(context: Context) -> _ColumnArrowKeysView {
        let view = _ColumnArrowKeysView()
        view.arrows = arrows
        view.onArrow = onArrow
        return view
    }

    func updateNSView(_ view: _ColumnArrowKeysView, context: Context) {
        view.arrows = arrows
        view.onArrow = onArrow
    }

    static func dismantleNSView(_ view: _ColumnArrowKeysView, coordinator: ()) {
        view.stop()
    }
}

final class _ColumnArrowKeysView: NSView {
    var arrows: Set<ColumnArrowKeys.Arrow> = []
    var onArrow: ((ColumnArrowKeys.Arrow, Bool) -> Bool)?
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  let arrow = Self.arrow(keyCode: event.keyCode), self.arrows.contains(arrow) else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            let shift = flags == .shift && (arrow == .up || arrow == .down)
            guard flags.isEmpty || shift,
                  let table = window.firstResponder as? NSTableView, self.contains(table),
                  self.onArrow?(arrow, shift) == true else { return event }
            return nil
        }
    }

    private static func arrow(keyCode: UInt16) -> ColumnArrowKeys.Arrow? {
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default:  return nil
        }
    }

    /// Whether `view` lies within this view's area of the window (the columns).
    private func contains(_ view: NSView) -> Bool {
        let area = convert(bounds, to: nil)
        let frame = view.convert(view.bounds, to: nil)
        // A list's table is as tall as its rows, so only its horizontal middle is
        // compared; the sidebar's lies left of the columns.
        return frame.intersects(area) && (area.minX...area.maxX).contains(frame.midX)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Column pane

/// A request for one column, told apart from the last one by `serial`.
struct ColumnPaneRequest: Equatable {
    var pane: Int?
    var serial = 0
}

struct ColumnPane: View {
    let paneIndex:      Int
    var focusedPane:    FocusState<Int?>.Binding
    /// This column's selection, by path (ShellPath.key); ColumnsView keeps it.
    let selectedKeys:   Set<String>
    /// The selection as it is when called, for a closure kept for later
    /// (`selectedKeys` is the one this view was drawn with).
    let currentKeys:    () -> Set<String>
    /// The columns' presses on selected rows, waiting for their mouse-up
    /// (ColumnsView.pressReleases).
    let releases:       ShellPressRelease
    /// → went into this column: select its first item once it's listed.
    let isEntering:     Bool
    /// Select All, when its `pane` is this one.
    let selectAllRequest: ColumnPaneRequest
    /// File ▸ Open, when its `pane` is this one.
    let openRequest:    ColumnPaneRequest
    let directory:      URL
    var isReadOnlyLocation = false
    let showHidden:     Bool
    let groupBy:        GroupBy
    let sortField:      SortField
    let sortAscending:  Bool
    let folderOrder:    FolderOrder
    /// The user selected these items here: none, one or several, in list order.
    let onSelectItems:  ([FileItem]) -> Void
    /// Selected items went away (trashed, renamed, deleted elsewhere): what's
    /// left of the selection, kept without opening or previewing anything.
    let onSelectionPruned: (Set<String>) -> Void
    /// ⌘↓ / ⌘O with a folder (or a link the listing didn't follow) selected: go
    /// into it. ← and → are ColumnArrowKeys' (the list never passes them on).
    let onEnter:        (FileItem) -> Void
    /// A folder opened (a double-click, Open): shown as the next column.
    let onOpenFolder:   (URL) -> Void
    /// A link the listing didn't follow opened: ColumnsView follows it, off
    /// the main thread, and shows it as the next column or opens it.
    let onOpenLink:     (FileItem) -> Void
    let onBrowseInto:   (URL) -> Void
    let onOpen:         (URL) -> Void
    /// Opens several items at once (PaneState.openItems, which asks first for many).
    let onOpenItems:    ([FileItem]) -> Void
    /// A ⌘-double-click: opens the items with folders in new tabs, as in Finder.
    let onOpenInNewTabs: ([FileItem]) -> Void
    @ObservedObject var fileOps:   FileOperationsService
    @ObservedObject var favorites: FavoritesService

    @State private var items:  [FileItem]  = []
    // Grouped alongside `items` in the background load, not on every render.
    @State private var groups: [FileGroup] = []
    /// ShellPath.key of each of `items`, worked out in the same load.
    @State private var itemKeys: [String] = []
    /// The folder's name, for VoiceOver ("Documents, list").
    @State private var title = ""
    /// Loads of the folder, full or patched with files changed in place.
    @State private var loads = ShellListingLoads()
    @State private var watchedDirectory: URL?
    @State private var typeSelect = TypeSelectBuffer()
    /// The folder `items` were listed from (ShellPath.key); nil while the
    /// column's folder is loading, so → and ⌘A never act on another folder's rows.
    @State private var loadedKey: String?
    /// Where a ⇧-click extends from: the row last clicked.
    @State private var anchorID: String?
    /// Presses on the rows, between a mouse-down and its mouse-up or drag.
    @State private var rowPresses = ColumnRowPresses()

    private var isLoaded: Bool { loadedKey == ShellPath.key(directory) }

    /// The rows in the order they're shown (by group when grouped).
    private var shownItems: [FileItem] { groupBy == .none ? items : groups.flatMap(\.items) }

    /// `selectedKeys` as the ids of the listed items.
    private var selectedIDs: Set<String> { ids(for: selectedKeys) }

    /// The listed items with these keys, as ids.
    private func ids(for keys: Set<String>) -> Set<String> {
        guard !keys.isEmpty else { return [] }
        var ids = Set<String>()
        for (item, key) in zip(items, itemKeys) where keys.contains(key) { ids.insert(item.id) }
        return ids
    }

    /// The list's selection. Only the list sets it (a click, ↑/↓, ⇧/⌘): what
    /// the user picked goes to ColumnsView, which keeps it in `selectedKeys`.
    private var listSelection: Binding<Set<String>> {
        Binding(
            get: { selectedIDs },
            set: { ids in
                guard ids != selectedIDs else { return }
                onSelectItems(shownItems.filter { ids.contains($0.id) })
            }
        )
    }

    var body: some View {
        let selected = selectedIDs
        List(selection: listSelection) { rows(selected: selected) }
        .listStyle(.plain)
        .accessibilityIdentifier("columnPane")
        .accessibilityLabel(title)
        .focused(focusedPane, equals: paneIndex)
        .onKeyPress { press in handleKey(press) }
        .background(ColumnArrowKeys(arrows: [.up, .down]) { arrow, shift in
            stepFromClick(down: arrow == .down, extending: shift)
        })
        // ⌘↓ and ⌘O go into the folder selected (or open the selection), as in
        // Finder. Caught on their way to the list (FileListKeys): it takes ↓ as
        // its own, ⌘ or not, so ⌘↓ never reached onKeyPress and moved down a row.
        // Taken even with nothing selected, which then does nothing.
        .background(FileListKeys(isReadOnlyLocation: isReadOnlyLocation, onKey: { key in
            guard key == .open else { return false }
            open(selectedItems, fromKeyboard: true)
            return true
        }))
        // Background right-click (empty space or empty folder)
        .contextMenu {
            BackgroundContextMenu(directory: directory, isReadOnlyLocation: isReadOnlyLocation, onReload: refreshAfterFileOp, fileOps: fileOps)
        }
        // Files dropped on empty space or on a file go into this column's folder.
        .fileDropArea(isReadOnlyLocation ? nil : directory, fileOps: fileOps, reload: refreshAfterFileOp)
        .onAppear    { watch(directory); reload() }
        .onDisappear {
            releases.cancel()
            if let watchedDirectory { DirectoryWatcher.shared.release(watchedDirectory) }
            watchedDirectory = nil
        }
        // A click inside the selection waiting to narrow it (release) is
        // dropped once anything else changes the selection (a paste, a
        // listing that drops a selected row). A press in another column
        // ends it too, through `releases`.
        .onChange(of: selectedKeys) { _, _ in releases.cancel() }
        // Columns are kept by position, so this one may now show another folder:
        // drop the old rows at once rather than when the new ones arrive.
        .onChange(of: directory) { _, newDir in
            releases.cancel()
            items = []
            groups = []
            itemKeys = []
            loadedKey = nil
            anchorID = nil
            watch(newDir)
            reload()
        }
        .onChange(of: showHidden)    { _, _ in reload() }
        .onChange(of: groupBy)       { _, _ in reload() }
        .onChange(of: sortField)     { _, _ in reload() }
        .onChange(of: sortAscending) { _, _ in reload() }
        .onChange(of: folderOrder)   { _, _ in reload() }
        .onChange(of: isEntering) { _, _ in selectFirstIfEntering() }
        .onChange(of: selectAllRequest) { _, request in
            guard request.pane == paneIndex, isLoaded, !items.isEmpty else { return }
            onSelectItems(shownItems)
        }
        // Does what ⌘O does here (FileListKeys, above).
        .onChange(of: openRequest) { _, request in
            guard request.pane == paneIndex else { return }
            if !open(selectedItems, fromKeyboard: true) { NSSound.beep() }
        }
        // Posted by file operations and by DirectoryWatcher when this folder changes.
        .onReceive(NotificationCenter.default.publisher(for: .refreshDirectory)) { notif in
            if let url = notif.object as? URL, ShellPath.same(url, directory) { reload() }
        }
        // Files in the folder changed in place (a download or a log growing, a
        // file retagged): just those are read again, as in the list.
        .onReceive(NotificationCenter.default.publisher(for: .directoryEntriesChanged)) { n in
            guard let url = n.object as? URL, ShellPath.same(url, directory),
                  let names = DirectoryWatcher.changedNames(n) else { return }
            reload(changed: names)
        }
        // Date groups ("Today", "Yesterday") are computed at load time relative
        // to the current day; regroup after midnight.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                    .receive(on: DispatchQueue.main)) { _ in
            if groupBy != .none { reload() }
        }
    }

    @ViewBuilder
    private func rows(selected: Set<String>) -> some View {
        if groupBy != .none {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in rowFor(item, selected: selected) }
                } header: {
                    DateSectionHeader(title: group.title, count: group.items.count)
                }
            }
        } else {
            ForEach(items) { item in rowFor(item, selected: selected) }
        }
    }

    @ViewBuilder
    private func rowFor(_ item: FileItem, selected: Set<String>) -> some View {
        ColumnRow(item: item)
            // AppKit's mouse handling, not tap gestures and onDrag: a press the
            // hand moves a point or two is still a click, and a drag carries
            // every selected file (FileMouseView, as in the icon grid). It takes
            // left clicks only, so the context menu below still opens, and is
            // hidden from accessibility, where the row stays the element.
            .overlay {
                FileRowMouseArea(onPress:   { press(item, clickCount: $0, modifiers: $1, at: $2) },
                                 onRelease: { release() },
                                 dragFiles: { dragFiles(for: item, pixelSide: $0) },
                                 iconSize:  ColumnRow.iconSize,
                                 iconInset: ColumnRow.horizontalPadding,
                                 isReadOnlyLocation: isReadOnlyLocation)
                    .accessibilityHidden(true)
            }
            .folderDropTarget(!isReadOnlyLocation && item.isBrowsableFolder ? item.url : nil, fileOps: fileOps, reload: refreshAfterFileOp)
            .contentShape(Rectangle())
            .contextMenu { columnContextMenu(item: item, selected: selected) }
            // For VoiceOver, as for an icon (IconGridCell): the row's content is
            // a container named for its item, whose press selects the row, as a
            // click does, and whose "Open" opens it, as a double-click does. The
            // tap gestures gave it a press before; the mouse view above is
            // hidden. The list's own row selection is unchanged. Its tags are
            // read by an element of their own inside it (TagDotsView): SwiftUI
            // gives a container no value. They're its custom content too, heard
            // without interacting into the row.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(item.name)
            .accessibilityTags(item.spokenTagNames)
            .accessibilityAddTraits(selected.contains(item.id) ? .isSelected : [])
            .accessibilityAction { selectOnly(item) }
            .accessibilityAction(named: "Open") { open([item]) }
    }

    // MARK: - Clicks

    /// Mouse-down on a row at `time` (the event's timestamp): the first click
    /// of a series selects, the second on the same row opens, any later ones
    /// do nothing. A quick click on another row starts a series of its own
    /// (ShellIconClick.PressTracker). Returns whether the press began a
    /// series, the only press that can become a drag.
    private func press(_ item: FileItem, clickCount: Int, modifiers: ShellIconClick.Modifiers,
                       at time: TimeInterval) -> Bool {
        releases.cancel()
        rowPresses.drag = nil
        switch rowPresses.tracker.press(on: item.id, clickCount: clickCount, at: time,
                                        interval: NSEvent.doubleClickInterval) {
        case .select:
            click(item, modifiers: modifiers)
            return true
        case .open:
            // The selection when the row is in it, as in Finder and the icon
            // grid: the first click's narrowing waited out the double-click
            // interval (ShellPressRelease), and this press cancelled it. One
            // row opens as it always has (a folder as the next column).
            // Several open as ⌘O and the context menu's Open do
            // (PaneState.openItems, ShellOpenPlan): files each in their app,
            // and folders each in a window of their own, since the columns
            // show only one folder next; a lone folder among files is shown
            // here. After the click is done with, as in the icon grid: opening
            // a folder changes the columns, and opening many asks first.
            // With ⌘ held, folders open in new tabs instead, as in Finder.
            let targets = FileContextMenu.targets(clicked: item, in: shownItems, selection: selectedIDs)
            if modifiers.contains(.command) {
                DispatchQueue.main.async { onOpenInNewTabs(targets) }
            } else {
                DispatchQueue.main.async { open(targets) }
            }
            return false
        case .none:
            return false
        }
    }

    /// A click on a row (ColumnNavigation.click): plain replaces the selection,
    /// ⌘ toggles the row, ⇧ extends from the row last clicked (or the first
    /// selected one). The row's mouse view takes the click from the list, which
    /// neither selects nor takes keyboard focus for it, so the click does both.
    private func click(_ item: FileItem, modifiers: ShellIconClick.Modifiers) {
        focusedPane.wrappedValue = paneIndex
        let selected = selectedIDs
        let click = ColumnNavigation.click(on: item.id, selection: selected, modifiers: modifiers,
                                           anchor: anchorID, order: shownItems.map(\.id))
        if !ColumnNavigation.extends(selected, modifiers: modifiers) { anchorID = item.id }
        var after = selected
        if case .select(let ids) = click {
            after = ids
            onSelectItems(shownItems.filter { ids.contains($0.id) })
        }
        releases.press(click)
        rowPresses.drag = (item.id, items, after)
    }

    /// Selects the row alone, at once, as a click on it does once the button
    /// comes up (VoiceOver's press on a row).
    private func selectOnly(_ item: FileItem) {
        releases.cancel()
        rowPresses.drag = nil
        focusedPane.wrappedValue = paneIndex
        anchorID = item.id
        if selectedIDs != [item.id] { onSelectItems([item]) }
    }

    /// Mouse-up after a press that didn't drag (ShellPressRelease): a ⌘-click
    /// on a selected row takes it out now; a plain click inside a larger
    /// selection selects its row alone once the double-click interval has
    /// passed, as in the icon grid, so a double-click there opens them all.
    /// The selection is read as it is then (`currentKeys`), not as this view
    /// was drawn.
    private func release() {
        rowPresses.drag = nil
        let shown = shownItems
        releases.release(selection: { ids(for: currentKeys()) },
                         select:    { ids in onSelectItems(shown.filter { ids.contains($0.id) }) })
    }

    /// ↑/↓ (⇧ to extend) while a click on a row of this column, inside its
    /// selection, waits to narrow it: the list would move on from the whole
    /// selection, so the narrowing happens now (ShellPressRelease.flush) and
    /// the key moves on from that row (ColumnNavigation.step). Otherwise the
    /// key is the list's.
    private func stepFromClick(down: Bool, extending: Bool) -> Bool {
        guard let id = releases.narrowingID, shownItems.contains(where: { $0.id == id }),
              let row = releases.flush() else { return false }
        let shown = shownItems
        let ids = ColumnNavigation.step(from: row, order: shown.map(\.id), down: down, extending: extending)
        if ids != [row] { onSelectItems(shown.filter { ids.contains($0.id) }) }
        return true
    }

    /// The files a drag from `item` carries: the selection when the item is in
    /// it, otherwise the item (FileDragSupport.dragFiles). The selection is the
    /// one the press left, which SwiftUI may not have drawn the row with yet.
    /// None unless this row's press is the one under way, so a drag never
    /// carries a file that wasn't pressed.
    private func dragFiles(for item: FileItem, pixelSide: CGFloat) -> [FileMouseView.DragFile] {
        releases.cancel()
        let pressed = rowPresses.drag
        rowPresses.drag = nil
        guard let pressed, pressed.id == item.id else { return [] }
        return FileDragSupport.dragFiles(for: item, files: pressed.files, selectedIDs: pressed.selection,
                                         pixelSide: pixelSide)
    }

    // MARK: - Keyboard

    /// The items selected in this column, in the order shown.
    private var selectedItems: [FileItem] {
        let ids = selectedIDs
        return ids.isEmpty ? [] : shownItems.filter { ids.contains($0.id) }
    }

    /// ↑/↓ (with ⇧ to extend) are the list's own, and ⌘↓ / ⌘O FileListKeys'.
    /// The rest, as in Finder.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Arrow keys carry the numeric-pad flag; Caps Lock doesn't change a shortcut.
        let modifiers = press.modifiers.subtracting([.numericPad, .capsLock])
        let ids = selectedIDs
        let selected = selectedItems
        switch (press.key, modifiers) {
        case (.return, []):
            // Renames, as in Finder. After the key: the prompt is modal. Not on a
            // held key's repeats, which would start another rename after one
            // Return committed.
            guard press.phase != .repeat, selected.count == 1 else { return .ignored }
            let item = selected[0]
            ReturnRepeatGuard.shared.arm()
            DispatchQueue.main.async {
                guard !isReadOnlyLocation else { NSSound.beep(); return }
                NamePrompt.rename(item, fileOps: fileOps, reload: refreshAfterFileOp)
            }
            return .handled
        case (.return, [.command]):
            return open(selected, fromKeyboard: true) ? .handled : .ignored
        case (.space, []):
            // A space in the middle of a typed name is part of it; otherwise Quick Look.
            if typeSelect.isTyping(at: Date()) { return typeToSelect(" ", selected: ids) }
            guard !selected.isEmpty else { return .ignored }
            QuickLookController.shared.show(selected.map(\.url))
            return .handled
        default:
            break
        }
        guard modifiers.isSubset(of: [.shift]), ColumnNavigation.isTypeSelectInput(press.characters)
        else { return .ignored }
        return typeToSelect(press.characters, selected: ids)
    }

    /// Selects the next name starting with what's been typed.
    private func typeToSelect(_ characters: String, selected: Set<String>) -> KeyPress.Result {
        // A click inside the selection waiting to narrow it narrows it now, so
        // the name is looked for from that row on (ShellPressRelease.flush).
        var ids = selected
        if let id = releases.narrowingID, ids.contains(id), let row = releases.flush() { ids = [row] }
        let query = typeSelect.type(characters, at: Date())
        let shown = shownItems
        let current = ids.isEmpty ? nil : shown.firstIndex { ids.contains($0.id) }
        // A query being typed keeps the current row while it still matches;
        // a new one moves on from it.
        guard let index = ColumnNavigation.typeToSelect(query, names: shown.map(\.name), selectedIndex: current,
                                                        includingSelected: query.count > 1)
        else { return .handled }
        if ids != [shown[index].id] { onSelectItems([shown[index]]) }
        return .handled
    }

    /// Opens `targets`: several through PaneState.openItems; one folder (a link
    /// the listing didn't follow included, followed now, once) as the next column,
    /// gone into from the keyboard (⌘↓ / ⌘O, as →); anything else opens.
    @discardableResult
    private func open(_ targets: [FileItem], fromKeyboard: Bool = false) -> Bool {
        guard let item = targets.first else { return false }
        if targets.count > 1 {
            onOpenItems(targets)
        } else if fromKeyboard, item.isBrowsableFolder || item.isLinkNotFollowed {
            onEnter(item)
        } else if item.isLinkNotFollowed {
            onOpenLink(item)
        } else if item.isBrowsableFolder {
            onOpenFolder(item.url)
        } else {
            onOpen(item.url)
        }
        return true
    }

    // MARK: - Context menu

    /// Acts on the selection when the item is in it, otherwise on the item alone (Finder's rule).
    private func columnContextMenu(item: FileItem, selected: Set<String>) -> some View {
        let targets = selected.contains(item.id) ? shownItems.filter { selected.contains($0.id) } : [item]
        return FileContextMenu(
            item:         item,
            targets:      targets,
            onOpen:       { open($0) },
            onBrowseInto: onBrowseInto,
            onRename:     { NamePrompt.rename($0, fileOps: fileOps, reload: refreshAfterFileOp) },
            onReload:     refreshAfterFileOp,
            fileOps:      fileOps,
            favorites:    favorites,
            isReadOnlyLocation: isReadOnlyLocation
        )
    }

    // MARK: - Helpers

    private func watch(_ url: URL) {
        if let old = watchedDirectory { DirectoryWatcher.shared.release(old) }
        DirectoryWatcher.shared.retain(url)
        watchedDirectory = url
    }

    /// After a listing of this column's folder came in, replacing `oldKeys`.
    private func listed(replacing oldKeys: [String]) {
        if selectFirstIfEntering() { return }
        // Selected items that went away (trashed, renamed elsewhere, the folder
        // shown next deleted) leave the selection, so nothing acts on them.
        guard !selectedKeys.isEmpty else { return }
        let before = selectedKeys.intersection(oldKeys)
        let after = selectedKeys.intersection(itemKeys)
        guard !before.isEmpty, after.count < before.count else { return }
        if after.isEmpty {
            onSelectItems([])
        } else {
            onSelectionPruned(after)
        }
    }

    /// → went into this column: its first item, once the folder is listed (or
    /// nothing, when it's empty).
    @discardableResult
    private func selectFirstIfEntering() -> Bool {
        guard isEntering, isLoaded else { return false }
        onSelectItems(shownItems.first.map { [$0] } ?? [])
        return true
    }

    /// Reload after a file operation, as a refresh notification for this column's
    /// folder (which it observes, above). File operations keep this callback in
    /// the undo history: a closure capturing this view would keep a closed
    /// window's services alive through it.
    private var refreshAfterFileOp: () -> Void {
        let dir = directory
        return { NotificationCenter.default.post(name: .refreshDirectory, object: dir) }
    }

    /// Lists the folder again. With `changed` (entries the watcher saw change in
    /// place), only those are read again and patched into the rows, which keep
    /// their ids, so the selection and the scroll position stay; while a load is
    /// in flight they wait for it (ShellListingLoads), as in PaneState.reload.
    ///
    /// The closures below run on this view as it was when the load started
    /// (its `isEntering` and `selectedKeys` may be out of date by then), so a
    /// patch, whose rows are the same items, doesn't select or prune anything:
    /// only a full listing goes through `listed`.
    private func reload(changed names: Set<String>? = nil) {
        if let names, !loads.changed(names) { return }
        let patch  = names.map { (names: $0, listing: items) }
        let token  = loads.start()
        let field  = sortField
        let asc    = sortAscending
        let fold   = folderOrder
        let hidden = showHidden
        let dir    = directory
        let grouping = groupBy
        DispatchQueue.global(qos: .userInitiated).async {
            let reloaded = ShellListingPatch.reload(dir, changed: patch, showHidden: hidden,
                                                    sortedBy: field, ascending: asc, folderOrder: fold)
            let grouped = reloaded.map { grouping == .none ? [] : groupedItems($0.items, by: grouping) }
            // The rows' keys are made again only when rows came, went or moved.
            let keys = reloaded.flatMap { $0.keepsOrder ? nil : $0.items.map { ShellPath.key($0.url) } }
            let name = reloaded?.isFullListing == true ? FileManager.default.displayName(atPath: dir.path) : nil
            DispatchQueue.main.async {
                guard loads.finish(token) else { return }
                if let reloaded, let grouped {
                    if reloaded.isFullListing {
                        let oldKeys = itemKeys
                        groups    = grouped
                        itemKeys  = keys ?? []
                        title     = name ?? title
                        items     = reloaded.items
                        loadedKey = ShellPath.key(dir)
                        listed(replacing: oldKeys)
                    } else if loadedKey == ShellPath.key(dir) {
                        // Still the rows patched (`loadedKey` is this column's
                        // state now, not as the load started).
                        groups = grouped
                        if let keys { itemKeys = keys }
                        items  = reloaded.items
                    }
                }
                // Files that changed while this load was on its way.
                if let more = loads.takeDeferred() { reload(changed: more) }
            }
        }
    }
}

// MARK: - Column row

/// A column's presses on its rows (ColumnPane.press), kept across redraws.
@MainActor
final class ColumnRowPresses {
    /// The last press, so a double-click opens only when both presses land
    /// on one row.
    var tracker = ShellIconClick.PressTracker()
    /// The row pressed, with the column's files and its selection once the
    /// press had selected: what a drag from the press carries. Only while
    /// the button is down: the drag or the mouse-up clears it.
    var drag: (id: String, files: [FileItem], selection: Set<String>)?
}

struct ColumnRow: View {
    let item: FileItem

    /// The icon's side at 100%, and the row's padding before it (where
    /// FileRowMouseView starts the drag image).
    static let iconSize: CGFloat = 16
    static let horizontalPadding: CGFloat = 4

    var body: some View {
        HStack(spacing: 6) {
            FileIconView(item: item, size: Self.iconSize)
            Text(item.name).scaledFont(size: 12).lineLimit(1)
            TagDotsView(colors: item.tagColors, names: item.spokenTagNames, size: 9)
            Spacer()
            if item.isBrowsableFolder {
                Image(systemName: "chevron.forward").scaledFont(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, Self.horizontalPadding)
    }
}
