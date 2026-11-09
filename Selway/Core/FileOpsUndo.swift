import Foundation

// Undo and Redo for file operations.
//
// Every step, run, says how to reverse what it actually did (its inverse), so
// Undo and Redo are the same mechanism pointed in opposite directions:
//
//   operation         undo                         redo (inverse of the undo)
//   Move, Rename      .move  (back to the source)  .move  (to the destination again)
//   Move to Trash     .putBack (out of the Trash)  .trash (the restored items again)
//   Paste (copy),     .trash (exactly the copies)  .putBack (the same copies, out of
//   Duplicate                                       the Trash the undo put them in)
//
// Redo of a copy puts back the very copies the undo trashed rather than copying
// the sources again: the sources may have changed since, and Redo means "bring
// back what Undo took away". If the Trash was emptied in between, the redo
// reports that the copy no longer exists and changes nothing.
//
// Nothing is ever overwritten: an item goes back only to a free name (an
// exclusive rename). Out of the Trash and into it, the item must also still be
// the one recorded (same volume and inode): Trash names are reused once the
// Trash is emptied, and a different item that took a copy's name must not be
// trashed. A move or rename has no such check — another app saving the file
// atomically gives it a new inode, and it is still the user's item at that name.
//
// What a step couldn't do is sorted by whether it might work later
// (`FileOpsUndoFailure`): an item in the way (a clash), on a volume that isn't
// connected, in a locked folder, or not reached before Cancel stays in the
// history as the step's remainder, to try again; an item that is gone,
// replaced or unreadable never will, and is dropped (with a note saying so),
// so it can't block everything older on the stack.

/// One item an undo or redo moves: from where it is now to where it goes.
struct FileOpsUndoMove: Equatable, Sendable {
    /// Where the item is now.
    let from: URL
    /// Where it goes back to.
    let to: URL
    /// Which file was at `from` when this was recorded; nil if it couldn't be
    /// read, and then the move is refused rather than guessed.
    let identity: FileOpsItemIdentity?

    init(from: URL, to: URL, identity: FileOpsItemIdentity?) {
        self.from = from; self.to = to; self.identity = identity
    }

    /// The move that reverses `item` (which went from `source` to `result`),
    /// recording the item now at `result`.
    init(reversing item: FileOpsMovedItem, fileManager fm: FileManager = .default) {
        self.init(from: item.result, to: item.source,
                  identity: FileOpsItemIdentity(item.result, fileManager: fm))
    }
}

/// How to reverse a finished operation (or a finished undo).
enum FileOpsUndoStep: Equatable, Sendable {
    /// Move items back where they were: undo of Move and Rename, and their redo.
    case move([FileOpsUndoMove])
    /// Put items back out of the Trash: undo of Move to Trash, and redo of
    /// Paste (copy) / Duplicate.
    case putBack([FileOpsUndoMove])
    /// Move exactly these items to the Trash: undo of Paste (copy) / Duplicate,
    /// and redo of Move to Trash.
    case trash([FileOpsCreatedItem])

    // MARK: Undo for a finished operation (nil when it did nothing)

    /// Undo for a Move or Rename that moved `done`.
    static func undoingMove(_ done: [FileOpsMovedItem], fileManager fm: FileManager = .default) -> FileOpsUndoStep? {
        done.isEmpty ? nil : .move(done.map { FileOpsUndoMove(reversing: $0, fileManager: fm) })
    }

    /// Undo for a Move to Trash; `done` pairs each original with its Trash URL.
    static func undoingTrash(_ done: [FileOpsMovedItem], fileManager fm: FileManager = .default) -> FileOpsUndoStep? {
        done.isEmpty ? nil : .putBack(done.map { FileOpsUndoMove(reversing: $0, fileManager: fm) })
    }

    /// Undo for a Paste (copy) or Duplicate that made `created`.
    static func undoingCopy(_ created: [FileOpsCreatedItem]) -> FileOpsUndoStep? {
        created.isEmpty ? nil : .trash(created)
    }

    /// Undo for a Paste or a drop that ran FileOpsTransfer.transfer in `mode`.
    /// Recording a move reads every moved item's attributes: call it off the
    /// main thread, right after the transfer.
    static func undoingTransfer(_ mode: FileOpsTransfer.Mode, _ result: FileOpsBatchResult) -> FileOpsUndoStep? {
        switch mode {
        case .move: return undoingMove(result.done)
        case .copy: return undoingCopy(result.created)
        }
    }

    // MARK: Running a step

    /// Runs the step (meant for the file-operation queue) and returns what it
    /// did, the step that reverses exactly that, and what is left to retry.
    func perform(trasher: @escaping FileOpsTransfer.Trasher = FileOpsTransfer.systemTrash,
                 fileManager fm: FileManager = .default,
                 token: FileOpsCancellationToken? = nil,
                 progress: FileOpsTransfer.ProgressHandler? = nil) -> FileOpsUndoOutcome {
        switch self {
        case .move(let moves):
            let run = Self.each(moves, name: \.from.lastPathComponent, token: token, progress: progress,
                                failure: { FileOpsUndoFailure($1, item: $0.from, destination: $0.to, fileManager: fm) }) { move in
                try Self.move(move, checkingIdentity: false, fileManager: fm)
            }
            return FileOpsUndoOutcome(result: run.result,
                                      inverse: Self.undoingMove(run.result.done, fileManager: fm),
                                      remainder: run.retry.isEmpty ? nil : .move(run.retry),
                                      removedCount: run.removed, retryReasons: run.reasons)
        case .putBack(let moves):
            let run = Self.each(moves, name: \.from.lastPathComponent, token: token, progress: progress,
                                failure: { FileOpsUndoFailure($1, item: $0.from, destination: $0.to, fileManager: fm) }) { move in
                try Self.move(move, checkingIdentity: true, fileManager: fm)
            }
            let restored = run.result.done.map { FileOpsCreatedItem(recording: $0.result, fileManager: fm) }
            return FileOpsUndoOutcome(result: run.result,
                                      inverse: restored.isEmpty ? nil : .trash(restored),
                                      remainder: run.retry.isEmpty ? nil : .putBack(run.retry),
                                      removedCount: run.removed, retryReasons: run.reasons)
        case .trash(let items):
            let run = Self.each(items, name: \.url.lastPathComponent, token: token, progress: progress,
                                failure: { FileOpsUndoFailure($1, item: $0.url, destination: nil, fileManager: fm) }) { item in
                let name = item.url.lastPathComponent
                guard FileOpsTransfer.exists(item.url, fm) else { throw FileOpsError.notFound(name) }
                guard let recorded = item.identity, FileOpsItemIdentity(item.url, fileManager: fm) == recorded else {
                    throw FileOpsError.replacedSince(name)
                }
                return try trasher(item.url).map { FileOpsMovedItem(source: item.url, result: $0) }
            }
            return FileOpsUndoOutcome(result: run.result,
                                      inverse: Self.undoingTrash(run.result.done, fileManager: fm),
                                      remainder: run.retry.isEmpty ? nil : .trash(run.retry),
                                      removedCount: run.removed, retryReasons: run.reasons)
        }
    }

    /// One undo move, never over something at `to`.
    private static func move(_ move: FileOpsUndoMove, checkingIdentity: Bool,
                             fileManager fm: FileManager) throws -> FileOpsMovedItem {
        let name = move.from.lastPathComponent
        guard FileOpsTransfer.exists(move.from, fm) else { throw FileOpsError.notFound(name) }
        if checkingIdentity {
            guard let recorded = move.identity, FileOpsItemIdentity(move.from, fileManager: fm) == recorded else {
                throw FileOpsError.replacedSince(name)
            }
        }
        try FileOpsTransfer.moveWithoutReplacing(move.from, to: move.to, fileManager: fm)
        return FileOpsMovedItem(source: move.from, result: move.to)
    }

    private struct ItemRun<Item> {
        var result = FileOpsBatchResult()
        var retry: [Item] = []
        var removed = 0
        /// Why the failed items kept in `retry` failed.
        var reasons: Set<FileOpsUndoFailure> = []
    }

    /// Runs `body` on each item, keeping going after failures. Items not
    /// reached before Cancel, and items whose failure may work later
    /// (`failure` says which), are kept to retry; the rest are dropped.
    /// `body` returning nil means done but with nothing to reverse.
    private static func each<Item>(_ items: [Item], name: (Item) -> String,
                                   token: FileOpsCancellationToken?,
                                   progress: FileOpsTransfer.ProgressHandler?,
                                   failure: (Item, Error) -> FileOpsUndoFailure,
                                   _ body: (Item) throws -> FileOpsMovedItem?) -> ItemRun<Item> {
        var run = ItemRun<Item>()
        for (i, item) in items.enumerated() {
            if token?.isCancelled == true {
                run.result.cancelled = true
                run.retry += items[i...]
                break
            }
            progress?(FileOpsProgress(completed: i, total: items.count, currentName: name(item)))
            do {
                if let moved = try body(item) { run.result.done.append(moved) }
            } catch {
                run.result.failures.append(FileOpsFailure(name: name(item), message: error.localizedDescription))
                let kind = failure(item, error)
                if kind.mayWorkLater {
                    run.retry.append(item)
                    run.reasons.insert(kind)
                } else {
                    run.removed += 1
                }
            }
        }
        progress?(FileOpsProgress(completed: items.count, total: items.count, currentName: ""))
        return run
    }

    var itemCount: Int {
        switch self {
        case .move(let items), .putBack(let items): return items.count
        case .trash(let items): return items.count
        }
    }

    /// Action for an error summary.
    var errorAction: FileOpsErrorSummary.Action {
        switch self {
        case .move:    return .moveBack
        case .putBack: return .putBack
        case .trash:   return .moveToTrash
        }
    }

    /// Where a moved item ended up, for selecting it afterwards (nil for the Trash).
    func landedURL(in result: FileOpsBatchResult) -> URL? {
        switch self {
        case .move, .putBack: return result.done.first?.result
        case .trash:          return nil
        }
    }
}

/// Why one item of an undo or redo step failed, which decides whether it stays
/// in the history to try again.
enum FileOpsUndoFailure: Hashable, Sendable {
    /// Something is in the way at the destination itself.
    case clash
    /// The volume the item or its destination is on isn't connected (ejected
    /// disk, unmounted server).
    case volumeMissing
    /// No permission to move it: the item or a folder on the way is locked.
    case locked
    /// It never will work: the item is gone or replaced, or the error is one
    /// nothing the user does is expected to change.
    case permanent

    /// Whether the item stays in the history to try again.
    var mayWorkLater: Bool { self != .permanent }

    /// Folders volumes are mounted in: a missing folder whose nearest existing
    /// ancestor is one of these is a volume that isn't connected.
    static var mountFolders: [String] {
        #if os(macOS)
        return ["/Volumes"]
        #else
        return ["/media", "/mnt", "/run/media"]
        #endif
    }

    /// Classifies `error` from moving `item` to `destination` (nil for a move
    /// to the Trash).
    init(_ error: Error, item: URL, destination: URL?, fileManager fm: FileManager = .default,
         mountFolders: [String] = FileOpsUndoFailure.mountFolders) {
        let missingVolume = ([item] + (destination.map { [$0] } ?? [])).contains {
            Self.isOnMissingVolume($0, fileManager: fm, mountFolders: mountFolders)
        }
        if let e = error as? FileOpsError {
            // Gone with its volume may come back; gone from a folder that is
            // there, or replaced, never will.
            if case .notFound = e, missingVolume { self = .volumeMissing } else { self = .permanent }
            return
        }
        if let e = error as? CocoaError, e.code == .fileWriteFileExists {
            // Only an item at the destination itself can be moved out of the way.
            // A clash inside a copy between volumes ("a" and "A" onto a
            // case-insensitive volume) happens again however often it is tried.
            if let destination, !FileOpsTransfer.clashIsAt(destination, e) { self = .permanent; return }
            self = .clash
            return
        }
        let ns = error as NSError
        let posix = ns.domain == NSPOSIXErrorDomain ? POSIXErrorCode(rawValue: Int32(truncatingIfNeeded: ns.code)) : nil
        if posix == .EEXIST || posix == .ENOTEMPTY {
            self = .clash   // the exclusive rename found `destination` taken
            return
        }
        if missingVolume { self = .volumeMissing; return }
        let noPermission = posix == .EACCES || posix == .EPERM
            || (ns.domain == NSCocoaErrorDomain
                && [CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileReadNoPermission.rawValue].contains(ns.code))
        self = noPermission ? .locked : .permanent
    }

    /// Whether the folder `url` is in isn't there because its volume isn't
    /// mounted: the nearest folder above it that exists is a mount folder.
    /// A folder deleted from a volume that is connected doesn't count.
    static func isOnMissingVolume(_ url: URL, fileManager fm: FileManager,
                                  mountFolders: [String]) -> Bool {
        // Lexical only: `standardizedFileURL` drops "/private" from paths that
        // exist, so an existing mount folder and a missing one under it wouldn't match.
        var folder = url.deletingLastPathComponent().standardized
        guard !FileOpsTransfer.exists(folder, fm) else { return false }
        while folder.path != "/" {
            let parent = folder.deletingLastPathComponent()
            if FileOpsTransfer.exists(parent, fm) {
                return mountFolders.contains { URL(fileURLWithPath: $0).standardized.path == parent.path }
            }
            folder = parent
        }
        return false
    }
}

/// What running an undo or redo step did, how to reverse that, and what is
/// left of it.
struct FileOpsUndoOutcome: Equatable, Sendable {
    let result: FileOpsBatchResult
    /// Reverses what was done; nil when nothing was.
    let inverse: FileOpsUndoStep?
    /// The items that may still work later (a clash, a volume or lock to fix,
    /// or not reached before Cancel); they stay in the history. nil when there
    /// are none.
    let remainder: FileOpsUndoStep?
    /// Items that never will (gone, replaced, unreadable); dropped from the history.
    let removedCount: Int
    /// Why the items kept in `remainder` failed (empty when none did).
    let retryReasons: Set<FileOpsUndoFailure>

    init(result: FileOpsBatchResult, inverse: FileOpsUndoStep?,
         remainder: FileOpsUndoStep? = nil, removedCount: Int = 0,
         retryReasons: Set<FileOpsUndoFailure> = []) {
        self.result = result; self.inverse = inverse
        self.remainder = remainder; self.removedCount = removedCount
        self.retryReasons = retryReasons
    }

    /// What became of the history entry, to add to the error message (nil
    /// when there is nothing to say). `actionName` is e.g. "Rename".
    func historyNote(redo: Bool, actionName: String) -> String? {
        let command: String
        if redo {
            command = String.localizedStringWithFormat(NSLocalizedString("Redo %@", comment: "Redo command name"), actionName)
        } else {
            command = String.localizedStringWithFormat(NSLocalizedString("Undo %@", comment: "Undo command name"), actionName)
        }
        if removedCount > 0 && result.done.isEmpty && remainder == nil {
            if redo {
                return String.localizedStringWithFormat(
                    NSLocalizedString("“%@” can’t be redone any more, so it was removed from the redo history.", comment: "Redo history error"),
                    actionName)
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("“%@” can’t be undone any more, so it was removed from the undo history.", comment: "Undo history error"),
                actionName)
        }
        var notes: [String] = []
        if removedCount > 0 {
            if redo {
                notes.append(removedCount == 1
                    ? NSLocalizedString("The item that can’t be restored was removed from the redo history.", comment: "Redo history note for one item")
                    : NSLocalizedString("The items that can’t be restored were removed from the redo history.", comment: "Redo history note for several items"))
            } else {
                notes.append(removedCount == 1
                    ? NSLocalizedString("The item that can’t be restored was removed from the undo history.", comment: "Undo history note for one item")
                    : NSLocalizedString("The items that can’t be restored were removed from the undo history.", comment: "Undo history note for several items"))
            }
        }
        let fixMask = (retryReasons.contains(.clash) ? 1 : 0)
            | (retryReasons.contains(.volumeMissing) ? 2 : 0)
            | (retryReasons.contains(.locked) ? 4 : 0)
        if fixMask != 0 {
            let sentence: String
            switch fixMask {
            case 1: sentence = NSLocalizedString("Move what’s in the way, then choose %@ again to finish.", comment: "Suggested fix for an undo or redo conflict")
            case 2: sentence = NSLocalizedString("Reconnect the missing disk or server, then choose %@ again to finish.", comment: "Suggested fix for undo or redo on a missing volume")
            case 4: sentence = NSLocalizedString("Unlock the locked item or folder, then choose %@ again to finish.", comment: "Suggested fix for undo or redo permission failure")
            case 3: sentence = NSLocalizedString("Move what’s in the way and reconnect the missing disk or server, then choose %@ again to finish.", comment: "Suggested fixes for an undo or redo conflict and missing volume")
            case 5: sentence = NSLocalizedString("Move what’s in the way and unlock the locked item or folder, then choose %@ again to finish.", comment: "Suggested fixes for an undo or redo conflict and permission failure")
            case 6: sentence = NSLocalizedString("Reconnect the missing disk or server and unlock the locked item or folder, then choose %@ again to finish.", comment: "Suggested fixes for a missing volume and permission failure")
            default: sentence = NSLocalizedString("Move what’s in the way, reconnect the missing disk or server and unlock the locked item or folder, then choose %@ again to finish.", comment: "Suggested fixes for an undo or redo conflict, missing volume, and permission failure")
            }
            notes.append(String.localizedStringWithFormat(sentence, command))
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}

// MARK: - Undo and redo stacks

/// The Undo / Redo stacks of one browser window. A new operation clears Redo;
/// a finished undo puts its inverse on Redo and a finished redo puts its
/// inverse back on Undo. While an undo or redo runs, neither can start (its
/// inverse isn't known until it finishes).
///
/// What a step couldn't do but might later (a clash, a volume or lock to fix,
/// or items not reached before Cancel) goes back on the stack it came from, so the user can clear
/// the clash and try again; items that never can (gone, replaced) are
/// dropped, so a dead entry can't block everything older. The inverse covers
/// what did happen.
///
/// `Payload` is whatever the caller needs again when the step runs (the app
/// keeps the window's reload action there).
struct FileOpsUndoHistory<Payload> {
    struct Entry {
        let step: FileOpsUndoStep
        let actionName: String
        let payload: Payload
    }

    enum Direction: Equatable, Sendable { case undo, redo }

    /// An undo or redo that has started; hand it back to `finish`.
    struct Running {
        let entry: Entry
        let direction: Direction
        fileprivate let generation: UInt
        fileprivate let undoDepth: Int
    }

    private(set) var undoStack: [Entry] = []
    private(set) var redoStack: [Entry] = []
    private(set) var isRunning = false
    /// Bumped by every new operation, so a step that finishes after one was
    /// recorded doesn't revive a Redo that the new operation cleared.
    private var generation = ShellGeneration()

    init() {}

    var canUndo: Bool { !isRunning && !undoStack.isEmpty }
    var canRedo: Bool { !isRunning && !redoStack.isEmpty }
    /// Name of the action Undo would reverse ("Paste"), nil when Undo is unavailable.
    var undoActionName: String? { canUndo ? undoStack.last?.actionName : nil }
    var redoActionName: String? { canRedo ? redoStack.last?.actionName : nil }

    /// A new operation finished: it can be undone, and Redo no longer applies.
    mutating func record(_ step: FileOpsUndoStep, actionName: String, payload: Payload) {
        generation.next()
        undoStack.append(Entry(step: step, actionName: actionName, payload: payload))
        redoStack.removeAll()
    }

    mutating func beginUndo() -> Running? { begin(.undo) }
    mutating func beginRedo() -> Running? { begin(.redo) }

    private mutating func begin(_ direction: Direction) -> Running? {
        guard !isRunning else { return nil }
        let popped = direction == .undo ? undoStack.popLast() : redoStack.popLast()
        guard let entry = popped else { return nil }
        isRunning = true
        return Running(entry: entry, direction: direction,
                       generation: generation.current, undoDepth: undoStack.count)
    }

    /// Settles a finished undo or redo: the inverse of what it did goes on the
    /// other stack, and its remainder (what may still work) back where it came
    /// from. A step with no remainder is gone from the history.
    mutating func finish(_ running: Running, outcome: FileOpsUndoOutcome) {
        isRunning = false
        let unchanged = generation.isCurrent(running.generation)
        let name = running.entry.actionName
        let payload = running.entry.payload
        if let inverse = outcome.inverse {
            let entry = Entry(step: inverse, actionName: name, payload: payload)
            switch running.direction {
            case .undo: if unchanged { redoStack.append(entry) }
            case .redo: pushUndo(entry, depth: running.undoDepth, unchanged: unchanged)
            }
        }
        if let remainder = outcome.remainder {
            let entry = Entry(step: remainder, actionName: name, payload: payload)
            switch running.direction {
            case .undo: pushUndo(entry, depth: running.undoDepth, unchanged: unchanged)
            case .redo: if unchanged { redoStack.append(entry) }
            }
        }
    }

    /// Onto the Undo stack: on top, or — when newer operations were recorded
    /// while the step ran — below them, where it was.
    private mutating func pushUndo(_ entry: Entry, depth: Int, unchanged: Bool) {
        if unchanged {
            undoStack.append(entry)
        } else {
            undoStack.insert(entry, at: min(depth, undoStack.count))
        }
    }
}
