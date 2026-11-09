import Foundation
import AppKit
import Combine

// MARK: - Action feedback (drives the in-app toast)

struct ActionFeedback {
    let icon: String
    let message: String
}

// MARK: - Safe AppleScript helpers
//
// Filenames on macOS may legally contain double quotes and backslashes. Building
// an AppleScript source string by interpolating a raw path lets a crafted file
// name break out of the string literal and inject arbitrary AppleScript (which
// can run shell commands) — a real code-execution risk when the user merely
// right-clicks a downloaded file. Always wrap untrusted text with this helper so
// it becomes a single, properly escaped AppleScript string literal.

/// Escapes `s` and wraps it in double quotes so it is a safe AppleScript string
/// literal — backslashes first, then quotes.
func appleScriptStringLiteral(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// Opens the native Finder "Get Info" window for each URL, with the path safely
/// escaped against AppleScript injection.
func showGetInfoInFinder(_ urls: [URL]) {
    for url in urls {
        let pathLiteral = appleScriptStringLiteral(url.path)
        let src = """
        tell application "Finder"
            activate
            open information window of (POSIX file \(pathLiteral) as alias)
        end tell
        """
        NSAppleScript(source: src)?.executeAndReturnError(nil)
    }
}

// MARK: - Folder / File creation

@MainActor
final class FolderCreationService: ObservableObject {
    @Published var lastCreatedURL:     URL?
    @Published var errorMessage:       String?
    @Published var lastActionFeedback: ActionFeedback?
    /// Creates one folder (never intermediate ones) with a validated, free name.
    func createFolder(at path: URL, name: String = DefaultNames.newFolder) {
        do {
            let target = try FileOpsCreation.createFolder(in: path, named: name)
            lastActionFeedback = ActionFeedback(icon: "folder.badge.plus",
                                                message: String(localized: "Created \"\(target.lastPathComponent)\"", comment: "Toast after creating a folder"))
            lastCreatedURL = target
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Creates an empty file with a validated, free name; never truncates an existing one.
    func createFile(at path: URL, name: String = DefaultNames.untitledTextFile) {
        do {
            let target = try FileOpsCreation.createFile(in: path, named: name)
            lastActionFeedback = ActionFeedback(icon: "doc.badge.plus",
                                                message: String(localized: "Created \"\(target.lastPathComponent)\"", comment: "Toast after creating a text file"))
            lastCreatedURL = target
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - System pasteboard adapter

/// NSPasteboard as the clipboard's storage. Reads only file URLs, so a web
/// link or text on the pasteboard is never treated as something to paste.
final class SystemFilePasteboard: FileOpsPasteboard {
    /// The general pasteboard, as one object so every window shares one
    /// FileOpsClipboard (see FileOpsClipboard.shared(for:)).
    static let general = SystemFilePasteboard()

    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    var changeCount: Int { pasteboard.changeCount }

    func readFileURLs() -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self],
                                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    func writeFileURLs(_ urls: [URL]) -> Int {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        return pasteboard.changeCount
    }

    func clearContents() { pasteboard.clearContents() }

    func writeString(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

// MARK: - Progress of a running file operation

/// Live progress for one background operation; drives FileOperationProgressView.
@MainActor
final class FileOperationProgress: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    @Published private(set) var completed    = 0
    @Published private(set) var total:         Int
    @Published private(set) var currentName  = ""
    @Published private(set) var isCancelling = false
    let token = FileOpsCancellationToken()
    fileprivate var isVisible  = false
    fileprivate var isFinished = false

    init(title: LocalizedStringResource, total: Int) {
        self.title = String(localized: title)
        self.total = total
    }

    /// nil for work with no item count (compress / extract): show an indeterminate bar.
    var fractionCompleted: Double? {
        total > 0 ? min(1, Double(completed) / Double(total)) : nil
    }

    func cancel() {
        isCancelling = true
        token.cancel()
    }

    fileprivate func update(_ p: FileOpsProgress) {
        completed   = p.completed
        total       = p.total
        currentName = p.currentName
    }
}

// MARK: - File operations (cut / copy / paste / rename / duplicate / undo)

/// Runs file operations for the views. Everything that touches many files or
/// may take long (paste, duplicate, trash, delete, compress, extract, tags)
/// runs on a serial background queue with progress and Cancel; results, one
/// combined error message and undo registration come back on the main actor.
@MainActor
final class FileOperationsService: ObservableObject {
    private enum TransferFeedback { case moved, pasted, copied }
    /// Items last cut (or copied) in Selway; views dim them while a Cut is pending.
    @Published var clipboardURLs:      [URL]           = []
    @Published var isCut:              Bool            = false
    @Published var lastOpURL:          URL?
    /// Several items an operation made (a drop of file promises): the window
    /// selects them all when they land in the folder it shows.
    @Published var lastLandedURLs:     [URL]?
    @Published var errorMessage:       String?
    @Published var lastActionFeedback: ActionFeedback?
    /// Items a Move to Trash left in place (their volume has no Trash) that the
    /// user then chose not to delete permanently: the window selects them again.
    @Published var keptItems: [URL]?
    /// The operation to show in FileOperationProgressView (nil when idle or when
    /// the current work is too quick to be worth showing).
    @Published private(set) var activeOperation: FileOperationProgress?

    /// This window's Undo / Redo stacks; the payload is the reload action of
    /// the view that started the operation.
    @Published private var history = FileOpsUndoHistory<() -> Void>()
    private let clipboard: FileOpsClipboard
    private let unarchiverLocator: () -> URL?
    private let trasher: FileOpsTransfer.Trasher
    private let workQueue = DispatchQueue(label: "studio.irq.selway.FileOperations", qos: .userInitiated)
    private var operations: [FileOperationProgress] = []
    private var observers = Set<AnyCancellable>()

    /// The browser window showing this service (set by
    /// FileOperationProgressStrip). Once it has closed, errors from operations
    /// that were still running are shown in an alert of their own.
    private weak var hostWindow: NSWindow?
    private var hostWindowClosed = false
    private var hostWindowObserver: AnyCancellable?

    /// Errors reported by any window's background operations; the quit review
    /// uses it to stay open when an operation it waited for failed.
    static private(set) var reportedErrorCount = 0

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    /// What Undo / Redo would act on ("Paste"); nil when unavailable.
    var undoActionName: String? { history.undoActionName }
    var redoActionName: String? { history.redoActionName }

    /// The pasteboard, Trash and The Unarchiver lookup are injectable so the
    /// service can be driven without touching the user's real ones. Every
    /// service on the same pasteboard shares one clipboard, so Cut in one
    /// window and Paste in another moves.
    init(pasteboard: FileOpsPasteboard = SystemFilePasteboard.general,
         trasher: @escaping FileOpsTransfer.Trasher = FileOpsTransfer.systemTrash,
         unarchiverLocator: @escaping () -> URL? = FileOperationsService.locateTheUnarchiver) {
        self.clipboard         = FileOpsClipboard.shared(for: pasteboard)
        self.trasher           = trasher
        self.unarchiverLocator = unarchiverLocator
        // For the Share picker's position (showShareSheet).
        ContextClickTracker.install()

        // Another window's Cut / Paste, or another app replacing the
        // pasteboard (checked when a window becomes key or the app becomes
        // active), changes what should be dimmed here.
        let center = NotificationCenter.default
        center.publisher(for: FileOpsClipboard.didChange, object: clipboard)
            .merge(with: center.publisher(for: NSWindow.didBecomeKeyNotification),
                   center.publisher(for: NSApplication.didBecomeActiveNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.syncClipboardState() }
            }
            .store(in: &observers)
    }

    /// Called by the progress strip when it lands in a window.
    func attach(to window: NSWindow) {
        guard hostWindow !== window else { return }
        hostWindow = window
        hostWindowClosed = false
        hostWindowObserver = NotificationCenter.default
            .publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.hostWindowClosed = true }
            }
    }

    /// Shows an error from a background operation: in this window's error
    /// sheet, or, if the window closed while the operation ran, in an alert
    /// (nothing would show the sheet).
    private func presentError(_ message: String) {
        Self.reportedErrorCount += 1
        if hostWindow != nil && !hostWindowClosed {
            errorMessage = message
            return
        }
        if hostWindow == nil && !hostWindowClosed && hostWindowObserver == nil {
            errorMessage = message   // never attached (no strip yet): keep the old path
            return
        }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle      = .warning
            alert.messageText     = String(localized: "A file operation from a closed window had problems", comment: "Alert title for a file operation error")
            alert.informativeText = message
            alert.runModal()
        }
    }

    /// The Unarchiver, if installed (modern bundle-id lookup).
    nonisolated static func locateTheUnarchiver() -> URL? {
        ["cx.c3.theunarchiver", "com.macpaw.site.theunarchiver"].lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    // MARK: Clipboard

    func copy(_ urls: [URL]) {
        clipboard.copy(urls)
        syncClipboardState(showing: urls)
        lastActionFeedback = ActionFeedback(icon: "doc.on.doc", message: String(localized: "Copied \(label(urls))", comment: "Toast after copying selected items"))
    }

    func cut(_ urls: [URL]) {
        clipboard.cut(urls)
        syncClipboardState(showing: urls)
        lastActionFeedback = ActionFeedback(icon: "scissors", message: String(localized: "Cut \(label(urls))", comment: "Toast after cutting selected items"))
    }

    /// File URLs a Paste would use right now (from the system pasteboard).
    var pasteboardURLs: [URL] { clipboard.fileURLs }

    /// Re-reads the shared clipboard (call before relying on `isCut`, e.g.
    /// when a menu opens; it also runs on every clipboard change and whenever
    /// a window becomes key).
    func syncClipboardState(showing urls: [URL]? = nil) {
        let cut = clipboard.isCutPending
        let shown = urls ?? clipboard.cutURLs
        if isCut != cut { isCut = cut }
        if clipboardURLs != shown { clipboardURLs = shown }
    }

    // MARK: Paste

    /// Pastes the pasteboard's files into `destination`. It moves them only if
    /// they are still the ones Selway cut (see FileOpsClipboard); otherwise
    /// it copies.
    func paste(to destination: URL, reload: @escaping () -> Void) {
        guard let plan = FileOpsPaste.begin(clipboard) else { return }
        syncClipboardState()
        transfer(plan.sources, into: destination, mode: plan.isMove ? .move : .copy,
                 actionName: plan.isMove ? String(localized: "Move", comment: "Undo action name for moving pasted items")
                                         : String(localized: "Paste", comment: "Undo action name for pasting items"),
                 icon: "doc.on.clipboard",
                 feedback: plan.isMove ? .moved : .pasted, reload: reload) { [weak self] result in
            guard let self else { return }
            FileOpsPaste.settleClipboard(plan, result: result, clipboard: self.clipboard)
            self.syncClipboardState()
        }
    }

    // MARK: Drop

    /// Moves or copies files dropped on `folder` (FileOpsDrop decides which)
    /// the way Paste does: in the background with progress, free names for
    /// clashes, one error message, Undo, and the first item selected when it
    /// lands in the folder shown. Unlike Paste it leaves the clipboard alone.
    func drop(_ urls: [URL], into folder: URL, mode: FileOpsTransfer.Mode, reload: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        transfer(urls, into: folder, mode: mode,
                 actionName: mode == .move ? String(localized: "Move", comment: "Undo action name for moving items")
                                            : String(localized: "Copy", comment: "Undo action name for copying items"),
                 icon: mode == .move ? "folder" : "doc.on.doc",
                 feedback: mode == .move ? .moved : .copied, reload: reload)
    }

    /// File promises dropped on `folder` (a Mail attachment, a photo from
    /// Photos): each source writes its file into a staging folder, on a
    /// background queue, and each file moves into `folder` as it arrives, with
    /// a free name if its own is taken (FileOpsPromiseDrop). Progress, Cancel
    /// and Quit's wait cover the whole drop, from the first promise to the
    /// last; at the end come one error message for the promises that failed
    /// or never answered, Undo (which trashes the new files, as for a copy)
    /// and the new files selected when they land in the folder shown
    /// (PromiseDrop).
    func receivePromises(_ promises: [NSFilePromiseReceiver], into folder: URL, reload: @escaping () -> Void) {
        guard !promises.isEmpty else { return }
        let staging: URL
        do {
            staging = try FileOpsPromiseDrop.makeStagingFolder(for: folder)
        } catch {
            presentError(String(localized: "Couldn’t receive the dropped items: \(error.localizedDescription)", comment: "Error receiving dropped files with the reason"))
            return
        }
        let (op, activity) = beginOperation("Receiving", total: 0)
        PromiseDrop(service: self, op: op, activity: activity, staging: staging, folder: folder, reload: reload)
            .start(promises)
    }

    /// The end of a PromiseDrop: `result` is every file that landed and every
    /// promise that failed or never answered, of `total` owed.
    fileprivate func promisesLanded(_ result: FileOpsBatchResult, total: Int, reload: @escaping () -> Void) {
        report(result, total: total, action: .copy)
        reload()
        guard !result.done.isEmpty else { return }
        if let undo = FileOpsUndoStep.undoingCopy(result.created) {
            registerUndo(undo, actionName: String(localized: "Copy", comment: "Undo action name for copying dropped items"), reload: reload)
        }
        let landed = result.done.map(\.result)
        lastActionFeedback = ActionFeedback(icon: "doc.on.doc",
                                            message: String(localized: "Copied \(label(landed))\(cancelNote(result, total: total))", comment: "Toast after receiving copied files"))
        lastLandedURLs = landed
    }

    // MARK: Drag out

    /// Files dragged from this window to another app, which moved them or (the
    /// Dock's Trash) deleted them: the folders they left are refreshed, and a
    /// move to the Trash is recorded for Undo once the files turn up there
    /// (FileOpsDragOut). The Dock has Finder do the move, which may finish a
    /// moment after the drag ends, so this looks a few times over about four
    /// seconds. A move elsewhere can't be undone: where the files went isn't
    /// known.
    func draggedOut(_ files: [FileOpsCreatedItem], ending: FileOpsDragOut.Ending) {
        guard ending != .kept, !files.isEmpty else { return }
        let folders = Self.distinctFolders(of: files.map(\.url))
        Self.refresh(folders)
        guard ending == .trashed else { return }
        findTrashed(files, folders: folders, delays: [0.1, 0.25, 0.5, 1, 2])
    }

    /// The folders `urls` are in, each once.
    private static func distinctFolders(of urls: [URL]) -> [URL] {
        urls.map { $0.deletingLastPathComponent() }.reduce(into: [URL]()) { folders, folder in
            if !folders.contains(where: { ShellPath.same($0, folder) }) { folders.append(folder) }
        }
    }

    /// Reloads every window and column showing one of `folders`.
    private static func refresh(_ folders: [URL]) {
        for folder in folders { NotificationCenter.default.post(name: .refreshDirectory, object: folder) }
    }

    /// Waits out `delays` (seconds, one per look) until none of `files` is
    /// left in place, then records the ones found in the Trash.
    private func findTrashed(_ files: [FileOpsCreatedItem], folders: [URL], delays: [Double]) {
        guard let delay = delays.first else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            let settled = delays.count == 1 || !files.contains { FileOpsDragOut.isInPlace($0) }
            let found = settled ? FileOpsDragOut.trashed(files, trash: { url in
                try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                             appropriateFor: url.deletingLastPathComponent(), create: false)
            }) : []
            let undo = FileOpsUndoStep.undoingTrash(found)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard settled else {
                        return self.findTrashed(files, folders: folders, delays: Array(delays.dropFirst()))
                    }
                    guard let undo else { return }
                    Self.refresh(folders)
                    self.registerUndo(undo, actionName: String(localized: "Move to Trash", comment: "Undo action name for moving items to the Trash"), reload: { Self.refresh(folders) })
                    self.lastActionFeedback = ActionFeedback(
                        icon: "trash", message: FileOpsDeleteText.trashed(found.map(\.source.lastPathComponent)))
                }
            }
        }
    }

    /// Paste and drop: FileOpsTransfer.transfer on the work queue, then (on
    /// the main actor) `settle`, one error message for the batch, the reload,
    /// Undo under `actionName`, a toast starting with `done`, and the first
    /// result as `lastOpURL` so the window selects it.
    private func transfer(_ sources: [URL], into destination: URL, mode: FileOpsTransfer.Mode,
                          actionName: String, icon: String, feedback: TransferFeedback,
                          reload: @escaping () -> Void,
                          settle: ((FileOpsBatchResult) -> Void)? = nil) {
        let total = sources.count
        run(mode == .move ? "Moving" : "Copying", total: total, { token, progress in
            // The undo of a move reads every moved item's attributes: do it here, off
            // the main thread, as Trash does.
            let result = FileOpsTransfer.transfer(sources, into: destination, mode: mode,
                                                  token: token, progress: progress)
            return (result, FileOpsUndoStep.undoingTransfer(mode, result))
        }, completion: { [weak self] outcome in
            guard let self else { return }
            let (result, undo) = outcome
            settle?(result)
            self.report(result, total: total, action: mode == .move ? .move : .copy)
            reload()
            guard !result.done.isEmpty else { return }

            if let undo { self.registerUndo(undo, actionName: actionName, reload: reload) }
            let landed = result.done.map(\.result)
            self.lastActionFeedback = ActionFeedback(
                icon: icon,
                message: {
                    let items = self.label(landed)
                    let cancellation = self.cancelNote(result, total: total)
                    switch feedback {
                    case .moved:  return String(localized: "Moved \(items)\(cancellation)", comment: "Toast after moving items")
                    case .pasted: return String(localized: "Pasted \(items)\(cancellation)", comment: "Toast after pasting items")
                    case .copied: return String(localized: "Copied \(items)\(cancellation)", comment: "Toast after copying items")
                    }
                }()
            )
            self.lastOpURL = landed.first
        })
    }

    // MARK: Rename

    /// Asks first when the rename changes a file's extension (Settings →
    /// Advanced); "Keep" applies the rest of the new name with the old extension.
    func rename(_ url: URL, to typedName: String, reload: @escaping () -> Void) {
        var newName = typedName
        if ExtensionChangePrompt.isOn, !Self.isPlainFolder(url),
           let change = FileOpsExtensionChange.detect(oldName: url.lastPathComponent, newName: typedName),
           ExtensionChangePrompt.ask(change) == .keep {
            newName = change.keepingOldExtension(newName: typedName)
            guard newName != url.lastPathComponent else { reload(); return }
        }
        do {
            let newURL = try FileOpsCreation.rename(url, to: newName)
            if let undo = FileOpsUndoStep.undoingMove([FileOpsMovedItem(source: url, result: newURL)]) {
                registerUndo(undo, actionName: String(localized: "Rename", comment: "Undo action name for renaming an item"), reload: reload)
            }
            lastActionFeedback = ActionFeedback(icon: "pencil", message: String(localized: "Renamed to \"\(newURL.lastPathComponent)\"", comment: "Toast after renaming an item"))
            lastOpURL = newURL
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Duplicate

    func duplicate(_ urls: [URL], reload: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        run("Duplicating", total: urls.count, { token, progress in
            FileOpsTransfer.duplicate(urls, token: token, progress: progress)
        }, completion: { [weak self] result in
            guard let self else { return }
            self.report(result, total: urls.count, action: .duplicate)
            reload()
            guard !result.done.isEmpty else { return }
            let created = result.created
            if let undo = FileOpsUndoStep.undoingCopy(created) {
                self.registerUndo(undo, actionName: String(localized: "Duplicate", comment: "Undo action name for duplicating items"), reload: reload)
            }
            self.lastActionFeedback = ActionFeedback(
                icon: "plus.square.on.square",
                message: String(localized: "Duplicated \(self.label(created.map(\.url)))\(self.cancelNote(result, total: urls.count))", comment: "Toast after duplicating items")
            )
            self.lastOpURL = created.first?.url
        })
    }

    // MARK: Trash

    func trash(_ urls: [URL], reload: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        let trasher = self.trasher
        run("Moving to Trash", total: urls.count, { token, progress in
            // The undo records which items landed in the Trash; do that here, off
            // the main thread, right after trashing them.
            let result = FileOpsTransfer.trash(urls, trasher: trasher, token: token, progress: progress)
            return (result, FileOpsUndoStep.undoingTrash(result.done))
        }, completion: { [weak self] outcome in
            guard let self else { return }
            let (result, undo) = outcome
            self.report(result, total: urls.count, action: .moveToTrash)
            reload()
            if !result.noTrash.isEmpty {
                // After this completion returns: the alert runs a modal loop.
                let noTrash = result.noTrash
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard DeleteFlow.confirmDeleteWithoutTrash(noTrash.map(\.lastPathComponent)) else {
                            self.keptItems = noTrash
                            return
                        }
                        self.permanentlyDelete(noTrash, reload: reload)
                    }
                }
            }
            guard !result.done.isEmpty else { return }
            if let undo { self.registerUndo(undo, actionName: String(localized: "Move to Trash", comment: "Undo action name for moving items to the Trash"), reload: reload) }
            self.lastActionFeedback = ActionFeedback(
                icon: "trash",
                message: FileOpsDeleteText.trashed(result.done.map(\.source.lastPathComponent))
                    + self.cancelNote(result, total: urls.count)
            )
        })
    }

    // MARK: - Extract archive

    /// Extract Here. Zip and tar archives are unpacked by Selway into a new
    /// item with a free name (never over existing files), keeping the archive's
    /// quarantine flag. The Unarchiver, when installed, handles them itself.
    /// Other formats are refused, never opened with their default app (a .pkg
    /// would start Installer).
    func extract(_ url: URL, reload: @escaping () -> Void) {
        guard FileOpsArchive.kind(forName: url.lastPathComponent) != nil else {
            errorMessage = FileOpsError.unsupportedArchive(url.lastPathComponent).localizedDescription
            return
        }
        if let unarchiver = unarchiverLocator() {
            NSWorkspace.shared.open([url], withApplicationAt: unarchiver,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                let message = error.map { String(localized: "Couldn’t open “\(url.lastPathComponent)” in The Unarchiver: \($0.localizedDescription)", comment: "Error opening an archive in The Unarchiver with the reason") }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let message { self.presentError(message) }
                        reload()
                    }
                }
            }
            return
        }
        let name = url.lastPathComponent
        run("Extracting “\(name)”", total: 0, { token, _ in
            Result { try FileOpsArchive.extract(url, token: token) }
        }, completion: { [weak self] result in
            guard let self else { return }
            reload()
            switch result {
            case .success(let out):
                self.lastActionFeedback = ActionFeedback(icon: "archivebox",
                                                         message: String(localized: "Extracted \"\(out.lastPathComponent)\"", comment: "Toast after extracting an archive"))
                self.lastOpURL = out
            case .failure(FileOpsError.cancelled):
                self.lastActionFeedback = ActionFeedback(icon: "xmark.circle", message: String(localized: "Extraction cancelled", comment: "Toast when archive extraction is cancelled"))
            case .failure(let error):
                self.presentError(String(localized: "Couldn’t extract “\(name)”: \(error.localizedDescription)", comment: "Archive extraction error with item name and reason"))
            }
        })
    }

    // MARK: - Compress (zip)

    /// Compress: "<name>.zip" for one item, "Archive.zip" for several, created
    /// next to the first item with a free name.
    func compress(_ urls: [URL], reload: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        run("Compressing", total: 0, { token, _ in
            Result { try FileOpsArchive.compress(urls, token: token) }
        }, completion: { [weak self] result in
            guard let self else { return }
            reload()
            switch result {
            case .success(let archive):
                self.lastActionFeedback = ActionFeedback(icon: "doc.zipper",
                                                         message: String(localized: "Created \"\(archive.lastPathComponent)\"", comment: "Toast after creating a compressed archive"))
                self.lastOpURL = archive
            case .failure(FileOpsError.cancelled):
                self.lastActionFeedback = ActionFeedback(icon: "xmark.circle", message: String(localized: "Compression cancelled", comment: "Toast when archive compression is cancelled"))
            case .failure(let error):
                self.presentError(String(localized: "Couldn’t compress \(self.label(urls)): \(error.localizedDescription)", comment: "Archive compression error with item names and reason"))
            }
        })
    }

    // MARK: - Make Alias (symlink)

    func makeAlias(for url: URL, reload: @escaping () -> Void) {
        let isDir = FileOpsNaming.isDirectory(url)
        let (stem, ext) = FileOpsNaming.split(url.lastPathComponent, isDirectory: isDir)
        let dest = FileOpsNaming.uniqueURL(in: url.deletingLastPathComponent(),
                                           name: FileOpsNaming.join("\(stem) alias", ext), isDirectory: false)
        do {
            try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: url)
            lastOpURL = dest
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Tags (Finder-compatible: real color tags, multiple per file, toggle)

    /// Toggle a standard Finder color tag (1...7) on the given files, mirroring
    /// Finder: if EVERY file already has the color's tag it is removed from all;
    /// otherwise it is added to all. Other tags on the file (additional colors,
    /// custom text tags, and the colours stored with them) are kept as they
    /// were. `names` are the user's names for the colours. See FileOpsTags.
    /// `skippedLinks` counts links left out of `urls` (FileItem.tagTargets),
    /// for the message.
    func toggleColorTag(_ color: Int, names: TagColorNames, on urls: [URL], skippedLinks: Int = 0,
                        reload: @escaping () -> Void) {
        guard !urls.isEmpty, FileTag.validColors.contains(color) else { return }
        let name = names.name(for: color)
        run("Tagging", total: urls.count, { token, progress in
            FileOpsTags.toggleColor(color, names: names, on: urls, token: token, progress: progress)
                ?? (false, FileOpsBatchResult())
        }, completion: { [weak self] outcome in
            guard let self else { return }
            let (removed, result) = outcome
            self.report(result, total: urls.count, action: removed ? .removeTag(name) : .tag)
            reload()
            guard !result.done.isEmpty else { return }
            self.lastActionFeedback = ActionFeedback(
                icon:    removed ? "tag.slash" : "tag.fill",
                message: (removed
                    ? String(localized: "Removed \(name) tag", comment: "Toast after removing a color tag")
                    : String(localized: "Tagged \(name)", comment: "Toast after adding a color tag"))
                    + FileOpsTags.skippedNote(links: skippedLinks)
            )
        })
    }

    /// Remove every tag (colors + custom) from the given files. `skippedLinks`
    /// as for toggleColorTag.
    func clearTags(on urls: [URL], skippedLinks: Int = 0, reload: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        run("Clearing tags", total: urls.count, { token, progress in
            FileOpsTags.clear(urls, token: token, progress: progress)
        }, completion: { [weak self] result in
            guard let self else { return }
            self.report(result, total: urls.count, action: .clearTags)
            reload()
            guard !result.done.isEmpty else { return }
            self.lastActionFeedback = ActionFeedback(icon: "tag.slash", message: String(localized: "Cleared tags", comment: "Toast after clearing item tags")
                                                     + FileOpsTags.skippedNote(links: skippedLinks))
        })
    }

    // MARK: - Copy path to clipboard

    /// Puts `path` on the clipboard, with this window's "Path copied" toast
    /// (only this window's: it was a notification every window answered).
    func copyPath(_ path: String) {
        clipboard.copyString(path)
        syncClipboardState()
        lastActionFeedback = ActionFeedback(icon: "doc.on.clipboard.fill", message: String(localized: "Path copied", comment: "Toast after copying an item path"))
    }

    // MARK: - Share

    /// Opens the picker at the right-click that opened the context menu, which is
    /// on the item (ShellPopoverAnchor); it used to open at the window's corner.
    func showShareSheet(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async {
            guard let win = NSApp.keyWindow, let view = win.contentView else { return }
            let anchor = ShellPopoverAnchor.point(lastClick: ContextClickTracker.last,
                                                  window: win.windowNumber,
                                                  now: ProcessInfo.processInfo.systemUptime,
                                                  mouse: win.mouseLocationOutsideOfEventStream,
                                                  content: view.convert(view.bounds, to: nil))
            let point = view.convert(anchor, from: nil)
            // Below the point, whichever way the view's y axis runs.
            NSSharingServicePicker(items: urls.map { $0 as NSURL })
                .show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: view,
                      preferredEdge: view.isFlipped ? .maxY : .minY)
        }
    }

    func shareViaAirDrop(_ urls: [URL]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls.map { $0 as NSURL })
    }

    /// A folder the user sees as a folder, not a package (an app or bundle,
    /// whose extension matters like a file's).
    private static func isPlainFolder(_ url: URL) -> Bool {
        FileOpsNaming.isDirectory(url) && !NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    // MARK: - Permanent delete (no undo — caller must confirm first)

    func permanentlyDelete(_ urls: [URL], reload: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        run("Deleting", total: urls.count, { token, progress in
            FileOpsTransfer.delete(urls, token: token, progress: progress)
        }, completion: { [weak self] result in
            guard let self else { return }
            self.report(result, total: urls.count, action: .delete)
            reload()
            guard !result.done.isEmpty else { return }
            self.lastActionFeedback = ActionFeedback(
                icon: "trash.fill",
                message: String(localized: "Permanently deleted \(self.label(result.done.map(\.source)))\(self.cancelNote(result, total: urls.count))", comment: "Toast after permanently deleting items")
            )
        })
    }

    // MARK: Undo / Redo

    /// Starts the undo of the last operation. The step runs in the background;
    /// when it finishes, what it did goes on the Redo stack (see
    /// FileOpsUndoHistory) and it reports "Undone" or its errors itself.
    func undo() {
        guard let running = history.beginUndo() else { return }
        perform(running)
    }

    /// Starts the redo of the last undo (see `undo`).
    func redo() {
        guard let running = history.beginRedo() else { return }
        perform(running)
    }

    private func registerUndo(_ step: FileOpsUndoStep, actionName: String, reload: @escaping () -> Void) {
        history.record(step, actionName: actionName, payload: reload)
    }

    /// Undo of a move, rename or trash puts items back, never over something
    /// new; undo of a copy or duplicate trashes exactly the copies made. Redo
    /// runs the inverse of what the undo did, with the same checks.
    private func perform(_ running: FileOpsUndoHistory<() -> Void>.Running) {
        let step = running.entry.step
        let name = running.entry.actionName
        let reload = running.entry.payload
        let isUndo = running.direction == .undo
        let trasher = self.trasher
        run(isUndo ? "Undoing \(name)" : "Redoing \(name)", total: step.itemCount, { token, progress in
            step.perform(trasher: trasher, token: token, progress: progress)
        }, completion: { [weak self] outcome in
            guard let self else { return }
            self.history.finish(running, outcome: outcome)
            reload()
            let result = outcome.result
            if let summary = FileOpsErrorSummary.message(action: step.errorAction, failures: result.failures,
                                                         total: step.itemCount) {
                let note = outcome.historyNote(redo: !isUndo, actionName: name).map { "\n\n" + $0 } ?? ""
                let message = isUndo
                    ? String(localized: "Undo \(name) was incomplete.\n\n\(summary)\(note)", comment: "Error when undoing an operation is incomplete")
                    : String(localized: "Redo \(name) was incomplete.\n\n\(summary)\(note)", comment: "Error when redoing an operation is incomplete")
                self.presentError(message)
            }
            guard !result.done.isEmpty else { return }
            let complete = result.failures.isEmpty && !result.cancelled
            let message: String
            switch (isUndo, complete) {
            case (true, true):   message = String(localized: "Undone: \(name)", comment: "Toast after fully undoing an operation")
            case (true, false):  message = String(localized: "Partly undone: \(name)", comment: "Toast after partially undoing an operation")
            case (false, true):  message = String(localized: "Redone: \(name)", comment: "Toast after fully redoing an operation")
            case (false, false): message = String(localized: "Partly redone: \(name)", comment: "Toast after partially redoing an operation")
            }
            self.lastActionFeedback = ActionFeedback(icon: isUndo ? "arrow.uturn.backward" : "arrow.uturn.forward",
                                                     message: message)
            if let landed = step.landedURL(in: result) { self.lastOpURL = landed }
        })
    }

    // MARK: Background runner

    /// Runs `work` on the serial file-operation queue, with a progress object
    /// the UI can show (after a short delay, so quick operations don't flash a
    /// bar) and cancel. `completion` runs on the main actor.
    private func run<Output>(_ title: LocalizedStringResource, total: Int,
                             _ work: @escaping (FileOpsCancellationToken, @escaping FileOpsTransfer.ProgressHandler) -> Output,
                             completion: @escaping @MainActor (Output) -> Void) {
        let (op, activity) = beginOperation(title, total: total)
        let token = op.token
        workQueue.async {
            var lastReport = Date.distantPast
            let result = work(token) { p in
                // Throttle UI updates; always deliver the final one.
                let now = Date()
                guard p.completed >= p.total || now.timeIntervalSince(lastReport) >= 0.1 else { return }
                lastReport = now
                DispatchQueue.main.async { MainActor.assumeIsolated { op.update(p) } }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.endOperation(op)
                    completion(result)
                    FileOpsActivityTracker.shared.end(activity)
                }
            }
        }
    }

    /// A new operation in the progress strip (shown if it is still running
    /// after a moment), and in the app's activities: Quit waits for (or
    /// stops) it, and the system won't idle-sleep or terminate the app while
    /// it runs. Pass the activity to FileOpsActivityTracker.end when done.
    private func beginOperation(_ title: LocalizedStringResource, total: Int) -> (FileOperationProgress, UUID) {
        let op = FileOperationProgress(title: title, total: total)
        operations.append(op)
        let activity = FileOpsActivityTracker.shared.begin(String(localized: title), token: op.token)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                op.isVisible = true
                self?.refreshActiveOperation()
            }
        }
        return (op, activity)
    }

    /// Takes a finished operation out of the progress strip.
    fileprivate func endOperation(_ op: FileOperationProgress) {
        op.isFinished = true
        operations.removeAll { $0 === op }
        refreshActiveOperation()
    }

    private func refreshActiveOperation() {
        let next = operations.first { $0.isVisible && !$0.isFinished }
        if activeOperation !== next { activeOperation = next }
    }

    // MARK: Helpers

    /// One error sheet for the whole batch, listing every failure.
    private func report(_ result: FileOpsBatchResult, total: Int, action: FileOpsErrorSummary.Action) {
        if let summary = FileOpsErrorSummary.message(action: action, failures: result.failures, total: total) {
            presentError(summary)
        }
    }

    private func cancelNote(_ result: FileOpsBatchResult, total: Int) -> String {
        guard result.cancelled else { return "" }
        let note = String(localized: "(cancelled, \(result.done.count) of \(total) done)",
                          comment: "Completed item count in a cancelled file operation.")
        // Full-width CJK punctuation (Japanese "（") carries its own spacing.
        let fullWidth = note.unicodeScalars.first.map {
            (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value)
        } ?? false
        return fullWidth ? note : " " + note
    }

    private func label(_ urls: [URL]) -> String {
        urls.count == 1
            ? String(localized: "“\(urls[0].lastPathComponent)”",
                     comment: "One item's name in quotation marks, in a completed-operation toast (\"Copied “photo.jpg”\"). Use your language's quotation marks.")
            : String(localized: "\(urls.count) items", comment: "Number of items in a completed operation.")
    }
}

// MARK: - A drop of file promises

/// One drop of file promises (FileOperationsService.receivePromises), from
/// the drop until its last promise has answered, Cancel (or Quit), or the
/// promises have gone quiet for `patience`. Each file moves into the folder
/// as it arrives (FileOpsPromiseDrop.land), on a queue of the drop's own, so
/// a slow download holds up no other operation. The drop keeps itself alive
/// (its timer and the promises' readers hold it), and removes its staging
/// folder and ends its activity even if its window has closed; only the
/// report, Undo and the selection need the window's service.
@MainActor
private final class PromiseDrop {
    /// How long the drop waits for its next answer before reporting the
    /// promises still owed as never written.
    static let patience: TimeInterval = 120
    /// Where the promises' readers are called.
    private static let readers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "studio.irq.selway.FilePromises.readers"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private weak var service: FileOperationsService?
    private let op: FileOperationProgress
    private let activity: UUID
    private let reload: () -> Void
    private var batch: FileOpsPromiseDrop.Batch
    private var promises: [NSFilePromiseReceiver] = []
    /// Moves the files in, one at a time, then removes the staging folder.
    private let queue = DispatchQueue(label: "studio.irq.selway.FilePromises", qos: .userInitiated)
    private var lastAnswer = Date()
    /// Checks for Cancel and for promises gone quiet.
    private var watch: Timer?
    /// Set once the drop has ended; answers after that are late.
    private var ending: FileOpsPromiseDrop.Batch.Ending?

    init(service: FileOperationsService, op: FileOperationProgress, activity: UUID,
         staging: URL, folder: URL, reload: @escaping () -> Void) {
        self.service = service
        self.op = op
        self.activity = activity
        self.reload = reload
        batch = FileOpsPromiseDrop.Batch(staging: staging, destination: folder)
    }

    func start(_ promises: [NSFilePromiseReceiver]) {
        self.promises = promises
        for (index, promise) in promises.enumerated() {
            promise.receivePromisedFiles(atDestination: batch.staging, options: [:],
                                         operationQueue: Self.readers) { url, error in
                // With an error, `url` is to be ignored: the error's path, if
                // any, names the file.
                let path = (error as NSError?)?.userInfo[NSFilePathErrorKey] as? String
                let message = error?.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.answer(url, from: index, failed: message, path: path) }
                }
            }
        }
        // A promise names its files only once called in (above). Every answer
        // reaches the drop after this, through the main queue.
        batch.expect(FileOpsPromiseDrop.expectedAnswers(fileNameCounts: promises.map(\.fileNames.count)))
        op.update(batch.progress)
        let watch = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { self.check() } }
        RunLoop.main.add(watch, forMode: .common)
        self.watch = watch
    }

    private func answer(_ url: URL, from index: Int, failed message: String?, path: String?) {
        lastAnswer = Date()
        let failure = message.map {
            FileOpsFailure(name: FileOpsPromiseDrop.failureName(errorPath: path, promised: promises[index].fileNames),
                           message: $0)
        }
        guard ending == nil else { return late(url, failure) }
        guard let file = batch.answer(url, failure: failure) else { return answered() }
        let destination = batch.destination
        queue.async {
            let landed = FileOpsPromiseDrop.land(file, into: destination)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.batch.add(landed)
                    self.answered()
                }
            }
        }
    }

    private func answered() {
        op.update(batch.progress)
        if ending == nil, batch.isComplete { end(.answered) }
    }

    private func check() {
        guard ending == nil else { return }
        if op.token.isCancelled {
            end(.cancelled)
        } else if Date().timeIntervalSince(lastAnswer) > Self.patience {
            end(.timedOut)
        }
    }

    /// Ends the drop after the files already on their way in have landed
    /// (the queue is serial, and each landing reports back to the main queue
    /// before this does).
    private func end(_ ending: FileOpsPromiseDrop.Batch.Ending) {
        self.ending = ending
        watch?.invalidate()
        watch = nil
        let staging = batch.staging
        queue.async {
            FileOpsPromiseDrop.removeStagingFolder(staging)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.ended(ending) } }
        }
    }

    private func ended(_ ending: FileOpsPromiseDrop.Batch.Ending) {
        service?.endOperation(op)
        FileOpsActivityTracker.shared.end(activity)
        service?.promisesLanded(batch.finished(ending), total: batch.progress.total, reload: reload)
    }

    /// An answer after the drop ended (a promise that named fewer files than
    /// it wrote, or one that answered after the wait ran out): the file is
    /// moved in, or the failure reported, on its own. After Cancel it is left.
    private func late(_ url: URL, _ failure: FileOpsFailure?) {
        guard ending != .cancelled else { return }
        var extra = FileOpsPromiseDrop.Batch(staging: batch.staging, destination: batch.destination)
        extra.expect(1)
        let reload = self.reload
        guard let file = extra.answer(url, failure: failure) else {
            service?.promisesLanded(extra.finished(.answered), total: 1, reload: reload)
            return
        }
        let destination = batch.destination, answered = extra
        queue.async {
            let landed = FileOpsPromiseDrop.land(file, into: destination)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var extra = answered
                    extra.add(landed)
                    self.service?.promisesLanded(extra.finished(.answered), total: 1, reload: reload)
                }
            }
        }
    }
}

// MARK: - Quit while file operations run

/// Quitting (⌘Q, logout, Sparkle's Install and Relaunch) while a copy, move or
/// extraction runs would cut it off and leave a half-written item under its
/// real name. Asks to wait for them, stop them, or not quit.
@MainActor
enum RunningOperationsReview {

    private static let review = FileOpsQuitReview()

    /// True while a quit waits on running operations (`.terminateLater` is
    /// pending). A second `NSApp.terminate` then would quit without the review,
    /// so code that can start a quit (UpdateManager.checkForUpdates) checks this first.
    static var isWaiting: Bool { review.isWaiting }

    /// `next` is the rest of the quit review (unsaved editors); it runs once
    /// no operation is left. The order of events, and why the error count is
    /// read before the alert, is in `FileOpsQuitReview`.
    static func applicationShouldTerminate(
        _ app: NSApplication,
        then next: @escaping @MainActor () -> NSApplication.TerminateReply
    ) -> NSApplication.TerminateReply {
        let reply = review.shouldTerminate(
            tracker: FileOpsActivityTracker.shared,
            errorCount: { MainActor.assumeIsolated { FileOperationsService.reportedErrorCount } },
            ask: askToWait,
            schedule: { work in
                // Reply only after .terminateLater has been returned; the app now
                // waits in the modal-panel run-loop mode, so schedule it there.
                RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                    MainActor.assumeIsolated { work() }
                }
            },
            finish: { errorsWhileWaiting in
                MainActor.assumeIsolated {
                    // Something failed while we asked or waited: stay open so its error is seen.
                    if errorsWhileWaiting {
                        app.reply(toApplicationShouldTerminate: false)
                        return
                    }
                    switch next() {
                    case .terminateNow:    app.reply(toApplicationShouldTerminate: true)
                    case .terminateCancel: app.reply(toApplicationShouldTerminate: false)
                    default:               break   // `next` replies itself
                    }
                }
            })
        switch reply {
        case .proceed: return next()
        case .cancel:  return .terminateCancel
        case .later:   return .terminateLater
        }
    }

    private static func askToWait(_ titles: [String]) -> FileOpsQuitReview.Choice {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = titles.count == 1
            ? String(localized: "“\(titles[0])” is still running.", comment: "Quit confirmation title while one file operation is running")
            : String(localized: "\(titles.count) file operations are still running.", comment: "Quit confirmation title while multiple file operations are running")
        alert.informativeText = String(localized: "Quitting now would interrupt it and could leave a half-finished item behind. Selway can wait for it to finish, or stop it after the current item and then quit.", comment: "Quit confirmation detail while file operations are running")
        alert.addButton(withTitle: String(localized: "Wait, Then Quit", comment: "Alert button to wait for file operations before quitting"))
        alert.addButton(withTitle: String(localized: "Stop and Quit", comment: "Alert button to stop file operations and quit"))
        alert.addButton(withTitle: String(localized: "Don’t Quit", comment: "Alert button to cancel quitting"))
        switch alert.runModal() {
        case .alertThirdButtonReturn:  return .dontQuit
        case .alertSecondButtonReturn: return .stop
        default:                       return .wait
        }
    }
}

// MARK: - Quick Look bridge

import Quartz

final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()
    private(set) var urls: [URL] = []
    private var releaseObserver: NSObjectProtocol?

    override init() {
        super.init()
        // An eject found the volume busy: a file shown here may be what holds it.
        releaseObserver = NotificationCenter.default.addObserver(
            forName: .releaseVolume, object: nil, queue: .main) { [weak self] note in
                guard let self, let volume = note.object as? URL,
                      self.urls.contains(where: { ShellPath.isSameOrInside($0, volume) }) else { return }
                let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
                let update = SidebarVolumes.quickLookItems(afterUnmounting: volume, urls: self.urls,
                                                           current: panel?.currentPreviewItemIndex)
                self.urls = update.urls
                guard let panel, panel.isVisible else { return }
                if update.shouldClose {
                    panel.orderOut(nil)
                } else {
                    // Removed items ahead of the one shown move it up the list.
                    panel.reloadData()
                    if let current = update.current { panel.currentPreviewItemIndex = current }
                }
            }
    }

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate   = self
        panel.isVisible ? panel.reloadData() : panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        (urls.indices.contains(index) ? urls[index] : urls[0]) as NSURL
    }
}

// MARK: - QL responder chain shim

import SwiftUI

struct QLResponderSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> _QLResponderView { _QLResponderView() }
    func updateNSView(_ nsView: _QLResponderView, context: Context) {}
}

final class _QLResponderView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window else { return }
        if !(w.nextResponder is _QLResponderView) {
            nextResponder   = w.nextResponder
            w.nextResponder = self
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookController.shared
        panel.delegate   = QuickLookController.shared
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

// MARK: - Context-click position

/// Where the last right-click (or Control-click) in one of the app's windows
/// landed. SwiftUI's context menus don't say where they were opened, and what
/// they open (the Share picker) should appear there rather than at a corner.
@MainActor
enum ContextClickTracker {
    private(set) static var last: ShellPopoverAnchor.Click?
    private static var monitor: Any?

    /// Starts watching; once per app, however many windows call it.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            // Local monitors run on the main thread.
            MainActor.assumeIsolated {
                if event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                   let window = event.window {
                    last = ShellPopoverAnchor.Click(window: window.windowNumber, point: event.locationInWindow,
                                                    time: ProcessInfo.processInfo.systemUptime)
                }
            }
            return event
        }
    }
}
