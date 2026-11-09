import SwiftUI
import AppKit

// MARK: - Shared file context menu
//
// One right-click menu for every browsing surface: the list Table, the grouped
// list, the icon grid, column panes and column search results. These used to be
// five hand-maintained copies that drifted apart (Paste into a .app bundle, a
// Trash that left the row on screen, three different rename flows).

struct FileContextMenu: View {
    /// The item that was right-clicked.
    let item: FileItem
    /// What the menu acts on — see `FileContextMenu.targets`.
    let targets: [FileItem]
    /// Opens the items given: Open acts on every target, as in Finder.
    let onOpen:       ([FileItem]) -> Void
    let onBrowseInto: (URL) -> Void
    let onRename:     (FileItem) -> Void
    let onReload:     () -> Void
    @ObservedObject var fileOps:   FileOperationsService
    @ObservedObject var favorites: FavoritesService
    /// The folder shown is read-only (a Time Machine disk with its hidden
    /// files shown), so its items are too.
    var isReadOnlyLocation = false

    /// Finder's rule: the whole selection if the clicked item is in it,
    /// otherwise just the clicked item.
    static func targets(clicked: FileItem, in files: [FileItem], selection: Set<String>) -> [FileItem] {
        ShellSelection.contextTargets(clicked: clicked, in: files, selection: selection) { $0.id }
    }

    private var urls: [URL] { targets.map(\.url) }
    private var count: Int { targets.count }
    private var isReadOnly: Bool { isReadOnlyLocation || targets.contains { TimeMachineBackups.isSnapshotPath($0.url) } }

    /// Paste goes into the clicked folder when it's the only target (unless it is
    /// one of the items being pasted, or inside one), else into the folder that
    /// contains the clicked item (ShellPasteTarget). Packages (.app etc.) are
    /// files here — pasting must never write into a bundle.
    private var pasteDestination: URL {
        ShellPasteTarget.destination(showing: item.url.deletingLastPathComponent(),
                                     contextMenuFolder: count == 1 && item.isBrowsableFolder ? item.url : nil,
                                     clipboard: fileOps.pasteboardURLs)
    }

    /// Single-item actions shown for this right-click (ShellItemMenu).
    private var shown: ShellItemMenu {
        ShellItemMenu(targetCount: count, isBrowsableFolder: item.isBrowsableFolder,
                      isPackage: item.isPackage, isArchive: item.isArchive)
    }

    var body: some View {
        let shown = self.shown
        Button(count > 1 ? "Open \(count) Items" as LocalizedStringKey : "Open") { onOpen(targets) }
        if shown.openInNewWindow {
            Button("Open in New Window") { BrowserWindowRouter.shared.openNewWindow(at: item.url) }
            // A tab of the window the menu is in (the key one).
            Button("Open in New Tab") { BrowserWindowRouter.shared.openNewTab(at: item.url) }
        }
        if shown.showPackageContents {
            Button("Show Package Contents") { onBrowseInto(item.url) }
        }
        Divider()
        Button("Quick Look") { QuickLookController.shared.show(urls) }
        Button("Get Info")   { showGetInfoInFinder(urls) }
        Divider()
        if shown.rename {
            Button("Rename…") { onRename(item) }
                .disabled(isReadOnly)
        }
        Button(count > 1 ? "Duplicate \(count) Items" as LocalizedStringKey : "Duplicate") {
            fileOps.duplicate(urls, reload: onReload)
        }.disabled(isReadOnly)
        Button(count > 1 ? "Make \(count) Aliases" as LocalizedStringKey : "Make Alias") {
            urls.forEach { fileOps.makeAlias(for: $0, reload: onReload) }
        }.disabled(isReadOnly)
        Button(count > 1 ? "Compress \(count) Items" as LocalizedStringKey : "Compress \"\(item.name)\"") {
            fileOps.compress(urls, reload: onReload)
        }.disabled(isReadOnly)
        if shown.extract {
            Button("Extract Here") { fileOps.extract(item.url, reload: onReload) }
                .disabled(isReadOnly)
        }
        Divider()
        Button("Cut")  { fileOps.cut(urls) }.disabled(isReadOnly)
        Button("Copy") { fileOps.copy(urls) }
        Button("Paste") { fileOps.paste(to: pasteDestination, reload: onReload) }
            .disabled(isReadOnly || fileOps.pasteboardURLs.isEmpty)
        Divider()
        Menu("Share") {
            Button("AirDrop") { fileOps.shareViaAirDrop(urls) }
            Divider()
            Button("Share…")  { fileOps.showShareSheet(for: urls) }
        }
        Divider()
        Menu("Tags") {
            TagMenuContent(targets: targets, fileOps: fileOps, onReload: onReload, isReadOnlyLocation: isReadOnly)
        }
        .disabled(isReadOnly)
        Divider()
        if shown.sidebarToggle {
            if let pinned = pinnedURL(for: item.url) {
                Button("Remove from Sidebar") { favorites.unpin(pinned) }
            } else {
                // FavoritesService.pin requires a directory-style URL; folders
                // listed through a symlink arrive without the trailing slash.
                Button("Add to Sidebar") {
                    favorites.pin(URL(fileURLWithPath: item.url.path, isDirectory: true))
                }
            }
            // A folder on a server's share: saved with its server, its row
            // reconnects the share when it isn't connected (a pinned folder
            // only dims). Worked out from the volumes already read.
            if let place = favorites.serverPlace(for: item.url) {
                Button("Save Server Folder in Sidebar") { favorites.addServer(place) }
                    .disabled(favorites.isSaved(place))
            }
        }
        Button("Show in Finder") { FileReveal.revealInFinder(urls) }
        Button(count > 1 ? "Copy \(count) Paths" as LocalizedStringKey : "Copy Path") {
            if let text = ShellCopyPath.text(selected: urls, folder: nil) { fileOps.copyPath(text) }
        }
        Divider()
        let prefs = DeleteFlow.prefs
        Button(FileOpsDeleteDecision.title(for: .moveToTrash, prefs: prefs), role: .destructive) {
            DeleteFlow.run(.moveToTrash, urls: urls, fileOps: fileOps, reload: onReload)
        }.disabled(isReadOnly)
        Button(FileOpsDeleteDecision.title(for: .deletePermanently, prefs: prefs), role: .destructive) {
            DeleteFlow.run(.deletePermanently, urls: urls, fileOps: fileOps, reload: onReload)
        }.disabled(isReadOnly)
    }

    /// The stored favorite matching `url` by path (favorites may be stored with
    /// or without a trailing slash, so `==` isn't reliable).
    private func pinnedURL(for url: URL) -> URL? {
        favorites.pinnedURLs.first { ShellPath.same($0, url) }
    }
}

// MARK: - Empty-space menu

struct BackgroundContextMenu: View {
    let directory: URL
    var isReadOnlyLocation = false
    let onReload:  () -> Void
    @ObservedObject var fileOps: FileOperationsService

    var body: some View {
        Button("Paste") { fileOps.paste(to: directory, reload: onReload) }
            .disabled(isReadOnlyLocation || TimeMachineBackups.isSnapshotPath(directory) || fileOps.pasteboardURLs.isEmpty)
        if let name = fileOps.undoActionName { Button("Undo \(name)") { fileOps.undo() } }
        if let name = fileOps.redoActionName { Button("Redo \(name)") { fileOps.redo() } }
        Divider()
        Button("Refresh") { onReload() }
    }
}

// MARK: - Rename / name prompts

enum NamePrompt {
    /// Modal name prompt used for renaming in the icon and column views and for
    /// New Folder / New File. Re-asks until the name is valid or the user cancels,
    /// so a name like "../x" can never reach the file system.
    /// With `renaming` (the item's current name), returning that name unedited, or
    /// text that trims to it, counts as Cancel (see ShellFileName.renameDecision).
    @MainActor
    static func ask(title: String, message: String, button: String, initial: String,
                    renaming currentName: String? = nil) -> String? {
        var text = initial
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText     = title
            alert.informativeText = problem.map { String(localized: "\($0)\n\n\(message)", comment: "Name prompt validation error and instructions") } ?? message
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button to cancel"))
            let tf = PromptTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            tf.stringValue = text
            alert.accessoryView = tf
            alert.window.initialFirstResponder = tf
            // The initial first responder isn't applied when the prompt is run
            // from a main-queue block (as Return's rename is, after the key):
            // the panel kept the keys, so a name typed went nowhere and Return
            // kept the old one. The field is focused again once the alert runs,
            // from the run loop: the main queue waits until the alert is closed.
            RunLoop.main.perform(inModes: [.modalPanel]) {
                MainActor.assumeIsolated { _ = tf.window?.makeFirstResponder(tf) }
            }
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            text = tf.stringValue
            if let currentName {
                switch ShellFileName.renameDecision(text, currentName: currentName) {
                case .unchanged:              return nil
                case .rename(let name):       return name
                case .invalid(let failure):   problem = ShellFileName.message(for: failure, name: text)
                }
                continue
            }
            switch ShellFileName.validate(text) {
            case .success(let name):     return name
            case .failure(let failure):  problem = ShellFileName.message(for: failure, name: text)
            }
        }
    }

    @MainActor
    static func rename(_ item: FileItem, fileOps: FileOperationsService, reload: @escaping () -> Void) {
        guard !TimeMachineBackups.isSnapshotPath(item.url) else { NSSound.beep(); return }
        guard let name = ask(title: String(localized: "Rename \"\(item.name)\"", comment: "Rename prompt title with the current item name"),
                             message: String(localized: "Enter a new name:", comment: "Instruction in a file or folder rename prompt"),
                             button: String(localized: "Rename", comment: "Rename prompt button title"),
                             initial: item.name, renaming: item.name) else { return }
        fileOps.rename(item.url, to: name, reload: reload)
    }

    /// Validates an inline-rename value; reports problems through the error sheet.
    /// Returns nil when there is nothing to do.
    @MainActor
    static func validatedInlineName(_ raw: String, for item: FileItem,
                                    fileOps: FileOperationsService) -> String? {
        guard !TimeMachineBackups.isSnapshotPath(item.url) else { NSSound.beep(); return nil }
        switch ShellFileName.renameDecision(raw, currentName: item.name) {
        case .unchanged:
            return nil
        case .rename(let name):
            return name
        case .invalid(.empty):
            return nil   // Finder: clearing the field just cancels
        case .invalid(let failure):
            fileOps.errorMessage = ShellFileName.message(for: failure, name: raw)
            return nil
        }
    }
}

/// Text field for modal prompts. While `runModal()` runs, AppKit disables menu
/// items whose target isn't the modal window — including the Edit commands in
/// BrowserCommands.swift, which replace the system Edit menu — so ⌘X/⌘C/⌘V/⌘A/⌘Z
/// would do nothing in the name field. Handle those key equivalents here and send
/// the standard actions to the field editor.
final class PromptTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let action: Selector?
        switch (flags, key) {
        case (.command, "x"):            action = #selector(NSText.cut(_:))
        case (.command, "c"):            action = #selector(NSText.copy(_:))
        case (.command, "v"):            action = #selector(NSText.paste(_:))
        case (.command, "a"):            action = #selector(NSText.selectAll(_:))
        case (.command, "z"):            action = Selector(("undo:"))
        case ([.command, .shift], "z"):  action = Selector(("redo:"))
        default:                         action = nil
        }
        if let action, currentEditor() != nil, NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Reveal in Finder

enum FileReveal {
    /// Reveals items in Finder itself. `NSWorkspace.selectFile` /
    /// `activateFileViewerSelecting` go to the NSFileViewer app, which is
    /// still Selway if an older version set it (DefaultFolderHandler), so
    /// "Show in Finder" would just bounce back here.
    static func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard DefaultFolderHandler.isGlobalFileViewer else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            return
        }
        let items = urls.map { "POSIX file \(appleScriptStringLiteral($0.path))" }.joined(separator: ", ")
        let src = """
        tell application "Finder"
            reveal {\(items)}
            activate
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&error)
        guard error != nil else { return }
        // Automation denied (or not yet allowed): at least open the enclosing
        // folders in Finder itself, without selecting the items.
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { return }
        let parents = Array(Set(urls.map { $0.deletingLastPathComponent() }))
        NSWorkspace.shared.open(parents, withApplicationAt: finder,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
