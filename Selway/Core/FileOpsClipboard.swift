import Foundation

/// The parts of a system pasteboard the file clipboard needs. The app wraps
/// NSPasteboard.general; tests use an in-memory fake.
protocol FileOpsPasteboard: AnyObject {
    /// Changes whenever anyone (this app or another) replaces the contents.
    var changeCount: Int { get }
    /// File URLs currently on the pasteboard (non-file URLs are ignored).
    func readFileURLs() -> [URL]
    /// Replaces the contents with `urls` and returns the new change count.
    @discardableResult func writeFileURLs(_ urls: [URL]) -> Int
    func clearContents()
    /// Replaces the contents with plain text (Copy Path).
    func writeString(_ string: String)
}

/// A pending Cut as it was when its Paste started: the pasteboard change
/// count recorded at Cut time and the items cut.
struct FileOpsCutMark: Equatable, Sendable {
    let changeCount: Int
    let urls: [URL]
}

/// Cut / Copy / Paste state for files.
///
/// Paste reads the system pasteboard, which another app may have replaced since
/// Selway's Cut. A Cut is therefore honoured (paste moves) only while the
/// pasteboard's change count is still the one recorded at Cut time; anything
/// newer is pasted as a copy, so files the user only copied elsewhere are
/// never moved.
///
/// There is one clipboard per pasteboard (`shared(for:)`), shared by every
/// window: a Cut in one window and a Paste in another is a move, and once it
/// is used up no window still thinks it is pending. Every change posts
/// `didChange` so windows can refresh their dimming.
final class FileOpsClipboard {
    /// Posted (object: the clipboard) whenever the Cut state changes.
    static let didChange = Notification.Name("studio.irq.selway.FileOpsClipboard.didChange")

    private let pasteboard: FileOpsPasteboard
    private(set) var cutURLs: [URL] = []
    private var cutChangeCount: Int?

    init(pasteboard: FileOpsPasteboard) {
        self.pasteboard = pasteboard
    }

    // MARK: One clipboard per pasteboard

    private struct Entry { weak var pasteboard: FileOpsPasteboard?; let clipboard: FileOpsClipboard }
    private static let registryLock = NSLock()
    private static var registry: [ObjectIdentifier: Entry] = [:]

    /// The clipboard every user of `pasteboard` shares.
    static func shared(for pasteboard: FileOpsPasteboard) -> FileOpsClipboard {
        registryLock.lock(); defer { registryLock.unlock() }
        let key = ObjectIdentifier(pasteboard)
        if let entry = registry[key], entry.pasteboard === pasteboard { return entry.clipboard }
        registry = registry.filter { $0.value.pasteboard != nil }
        let clipboard = FileOpsClipboard(pasteboard: pasteboard)
        registry[key] = Entry(pasteboard: pasteboard, clipboard: clipboard)
        return clipboard
    }

    // MARK: Cut / Copy

    func copy(_ urls: [URL]) {
        pasteboard.writeFileURLs(urls)
        cutChangeCount = nil
        cutURLs = []
        changed()
    }

    func cut(_ urls: [URL]) {
        cutChangeCount = pasteboard.writeFileURLs(urls)
        cutURLs = urls
        changed()
    }

    /// Copy Path: puts text on the pasteboard, which also ends any pending Cut.
    func copyString(_ string: String) {
        pasteboard.writeString(string)
        cutChangeCount = nil
        cutURLs = []
        changed()
    }

    /// True while the pasteboard still holds exactly what our last Cut put there.
    var isCutPending: Bool {
        guard let cutChangeCount else { return false }
        return cutChangeCount == pasteboard.changeCount
    }

    var fileURLs: [URL] { pasteboard.readFileURLs() }

    /// What a Paste right now would do, or nil if there are no files to paste.
    func pendingPaste() -> (urls: [URL], isMove: Bool)? {
        let urls = pasteboard.readFileURLs()
        guard !urls.isEmpty else { return nil }
        return (urls, isCutPending)
    }

    // MARK: Move lifecycle

    /// Uses up a pending Cut when its Paste starts, so a second Paste copies
    /// instead of moving the same files again. Returns the mark to pass to
    /// `finishMove` or `cancelMove` (nil if there was no pending Cut).
    func beginMove() -> FileOpsCutMark? {
        let mark = isCutPending ? cutChangeCount.map { FileOpsCutMark(changeCount: $0, urls: cutURLs) } : nil
        cutChangeCount = nil
        cutURLs = []
        changed()
        return mark
    }

    /// After a cut-and-paste the pasteboard points at the old locations; clear it
    /// if it still holds our Cut (never another app's newer contents).
    func finishMove(_ mark: FileOpsCutMark?) {
        if let mark, mark.changeCount == pasteboard.changeCount { pasteboard.clearContents() }
        changed()
    }

    /// A move that moved nothing (cancelled before the first item, or every
    /// item failed) gives the Cut back, so the next Paste moves again, as long
    /// as nothing newer has been put on the pasteboard meanwhile.
    func cancelMove(_ mark: FileOpsCutMark?) {
        guard let mark, mark.changeCount == pasteboard.changeCount, cutChangeCount == nil else { return }
        cutChangeCount = mark.changeCount
        cutURLs = mark.urls
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

// MARK: - Paste, start to finish

/// What Paste is about to do.
struct FileOpsPastePlan: Equatable, Sendable {
    let sources: [URL]
    let isMove: Bool
    let cutMark: FileOpsCutMark?
}

/// The sequencing behind Paste, shared by every window: decide move or copy,
/// use up the Cut while the move runs, then settle the clipboard and say how
/// to undo. `begin` and `finish` run on the main thread; `run` off it.
enum FileOpsPaste {

    /// nil when there is nothing to paste. A move takes the Cut at once, so a
    /// second Paste while it runs copies instead of moving again.
    static func begin(_ clipboard: FileOpsClipboard) -> FileOpsPastePlan? {
        guard let pending = clipboard.pendingPaste() else { return nil }
        let mark = pending.isMove ? clipboard.beginMove() : nil
        return FileOpsPastePlan(sources: pending.urls, isMove: pending.isMove, cutMark: mark)
    }

    static func run(_ plan: FileOpsPastePlan, into destination: URL,
                    fileManager fm: FileManager = .default,
                    token: FileOpsCancellationToken? = nil,
                    progress: FileOpsTransfer.ProgressHandler? = nil) -> FileOpsBatchResult {
        FileOpsTransfer.transfer(plan.sources, into: destination, mode: plan.isMove ? .move : .copy,
                                 fileManager: fm, token: token, progress: progress)
    }

    /// Clears the pasteboard after a move that moved something, gives the Cut
    /// back after one that moved nothing, and returns the undo (nil when
    /// nothing changed).
    static func finish(_ plan: FileOpsPastePlan, result: FileOpsBatchResult,
                       clipboard: FileOpsClipboard) -> FileOpsUndoStep? {
        settleClipboard(plan, result: result, clipboard: clipboard)
        return undoStep(for: plan, result: result)
    }

    /// The clipboard half of `finish` (main thread).
    static func settleClipboard(_ plan: FileOpsPastePlan, result: FileOpsBatchResult,
                                clipboard: FileOpsClipboard) {
        guard plan.isMove else { return }
        if result.done.isEmpty {
            clipboard.cancelMove(plan.cutMark)
        } else {
            clipboard.finishMove(plan.cutMark)
        }
    }

    /// The undo half of `finish`: nil when nothing changed. Recording a move
    /// reads every moved item's attributes, so the app calls this off the main
    /// thread, right after `run`.
    static func undoStep(for plan: FileOpsPastePlan, result: FileOpsBatchResult) -> FileOpsUndoStep? {
        .undoingTransfer(plan.isMove ? .move : .copy, result)
    }
}
