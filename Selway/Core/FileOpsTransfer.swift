import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One item an operation could not handle.
struct FileOpsFailure: Equatable, Sendable {
    let name: String
    let message: String

    init(name: String, message: String) {
        self.name = name; self.message = message
    }

    init(_ url: URL, _ error: Error) {
        name = url.lastPathComponent
        message = error.localizedDescription
    }
}

/// An item that moved or was created: where it came from and where it is now.
struct FileOpsMovedItem: Equatable, Sendable {
    let source: URL
    let result: URL
}

/// Which file an item is (volume and inode), so Undo can tell a copy it made
/// from something that took the copy's name later.
struct FileOpsItemIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(device: UInt64, inode: UInt64) {
        self.device = device; self.inode = inode
    }

    /// The item at `url` itself (a final symlink is not followed); nil if gone.
    init?(_ url: URL, fileManager fm: FileManager = .default) {
        guard let a = try? fm.attributesOfItem(atPath: url.path),
              let dev = a[.systemNumber] as? NSNumber, let ino = a[.systemFileNumber] as? NSNumber
        else { return nil }
        device = dev.uint64Value; inode = ino.uint64Value
    }
}

/// A copy Selway made and which file it was when the copy finished.
struct FileOpsCreatedItem: Equatable, Sendable {
    let url: URL
    let identity: FileOpsItemIdentity?

    init(url: URL, identity: FileOpsItemIdentity?) {
        self.url = url; self.identity = identity
    }

    /// Records `url` as it is now.
    init(recording url: URL, fileManager fm: FileManager = .default) {
        self.init(url: url, identity: FileOpsItemIdentity(url, fileManager: fm))
    }
}

/// Progress of a batch, reported per item.
struct FileOpsProgress: Equatable, Sendable {
    var completed: Int
    var total: Int
    var currentName: String
}

/// Outcome of a batch: what succeeded, what failed, and whether the user
/// cancelled before every item was attempted.
struct FileOpsBatchResult: Equatable, Sendable {
    var done: [FileOpsMovedItem] = []
    var failures: [FileOpsFailure] = []
    var cancelled = false
    /// Copies made (Paste as copy, Duplicate) and which files they were when
    /// finished, for an Undo that only trashes those exact items.
    var created: [FileOpsCreatedItem] = []
    /// Move to Trash: items left where they were because their volume has no
    /// Trash (`FileOpsTrashSupport`). They aren't in `failures`: the user is
    /// offered a permanent delete instead.
    var noTrash: [URL] = []
}

/// The work behind Paste, Duplicate, Move to Trash, Delete and their undos.
/// Every function is synchronous and meant to run off the main thread; it
/// keeps going after a failure, collects every error, checks the token between
/// items, and never replaces an existing item.
enum FileOpsTransfer {

    enum Mode: Sendable { case copy, move }

    typealias Trasher = (URL) throws -> URL?
    typealias ProgressHandler = (FileOpsProgress) -> Void

    /// Moves an item to the Trash, returning where it ended up (for undo).
    static func systemTrash(_ url: URL) throws -> URL? {
        #if os(macOS)
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return out as URL?
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    // MARK: Paste

    /// Copies or moves `sources` into `destination`. Name clashes get a free
    /// name ("a 2.txt"); copying into the item's own folder makes "a copy.txt";
    /// moving an item into the folder it is already in is a no-op.
    ///
    /// Results keep the caller's spelling of the paths (only `.` and `..` are
    /// folded): `standardizedFileURL` would also drop a leading "/private" from
    /// an existing path, and the browser, which compares lexical `ShellPath`
    /// keys, then didn't recognise the new item as being in the folder shown.
    static func transfer(_ sources: [URL], into destination: URL, mode: Mode,
                         fileManager fm: FileManager = .default,
                         token: FileOpsCancellationToken? = nil,
                         progress: ProgressHandler? = nil) -> FileOpsBatchResult {
        var result = FileOpsBatchResult()
        let dest = destination.absoluteURL.standardized
        let destKey = folderKey(dest)
        for (i, rawSource) in sources.enumerated() {
            if token?.isCancelled == true { result.cancelled = true; break }
            let src = rawSource.absoluteURL.standardized
            progress?(FileOpsProgress(completed: i, total: sources.count, currentName: src.lastPathComponent))
            do {
                guard exists(src, fm) else { throw FileOpsError.notFound(src.lastPathComponent) }
                let isDir = FileOpsNaming.isDirectory(src, fileManager: fm)
                if isDir && isSameOrInside(dest, src) { throw FileOpsError.intoItself(src.lastPathComponent) }
                // Same folder however it is spelled (/var vs /private/var, a symlink).
                let sameFolder = folderKey(src.deletingLastPathComponent()) == destKey
                if mode == .move && sameFolder { continue }
                let target: URL
                if sameFolder {
                    // Named in the destination as spelled, which may be a link
                    // to the source's folder: the window showing it then finds
                    // the copy among its own items.
                    let name = FileOpsNaming.duplicateURL(for: src, isDirectory: isDir, fileManager: fm).lastPathComponent
                    target = dest.appendingPathComponent(name, isDirectory: isDir)
                } else {
                    target = FileOpsNaming.uniqueURL(in: dest, name: src.lastPathComponent,
                                                     isDirectory: isDir, fileManager: fm)
                }
                switch mode {
                case .copy:
                    try copyRemovingPartial(src, to: target, fileManager: fm)
                    result.created.append(FileOpsCreatedItem(recording: target, fileManager: fm))
                case .move:
                    try moveWithoutReplacing(src, to: target, fileManager: fm)
                }
                result.done.append(FileOpsMovedItem(source: src, result: target))
            } catch {
                result.failures.append(FileOpsFailure(src, error))
            }
        }
        progress?(FileOpsProgress(completed: sources.count, total: sources.count, currentName: ""))
        return result
    }

    // MARK: Duplicate

    /// Copies each item next to itself as "name copy", "name copy 2", …,
    /// keeping the caller's spelling of the path (see `transfer`).
    static func duplicate(_ urls: [URL], fileManager fm: FileManager = .default,
                          token: FileOpsCancellationToken? = nil,
                          progress: ProgressHandler? = nil) -> FileOpsBatchResult {
        var result = FileOpsBatchResult()
        for (i, raw) in urls.enumerated() {
            if token?.isCancelled == true { result.cancelled = true; break }
            let url = raw.absoluteURL.standardized
            progress?(FileOpsProgress(completed: i, total: urls.count, currentName: url.lastPathComponent))
            do {
                guard exists(url, fm) else { throw FileOpsError.notFound(url.lastPathComponent) }
                let target = FileOpsNaming.duplicateURL(for: url, isDirectory: FileOpsNaming.isDirectory(url, fileManager: fm),
                                                        fileManager: fm)
                try copyRemovingPartial(url, to: target, fileManager: fm)
                result.created.append(FileOpsCreatedItem(recording: target, fileManager: fm))
                result.done.append(FileOpsMovedItem(source: url, result: target))
            } catch {
                result.failures.append(FileOpsFailure(url, error))
            }
        }
        progress?(FileOpsProgress(completed: urls.count, total: urls.count, currentName: ""))
        return result
    }

    // MARK: Trash / delete

    /// Moves items to the Trash; `done` pairs each original with its Trash URL.
    /// Items on a volume without a Trash go to `noTrash`, not `failures`.
    static func trash(_ urls: [URL], trasher: Trasher = systemTrash,
                      token: FileOpsCancellationToken? = nil,
                      progress: ProgressHandler? = nil) -> FileOpsBatchResult {
        var result = FileOpsBatchResult()
        for (i, url) in urls.enumerated() {
            if token?.isCancelled == true { result.cancelled = true; break }
            progress?(FileOpsProgress(completed: i, total: urls.count, currentName: url.lastPathComponent))
            do {
                if let inTrash = try trasher(url) {
                    result.done.append(FileOpsMovedItem(source: url, result: inTrash))
                }
            } catch where FileOpsTrashSupport.isNoTrash(error) && exists(url, .default) {
                result.noTrash.append(url)
            } catch {
                result.failures.append(FileOpsFailure(url, error))
            }
        }
        progress?(FileOpsProgress(completed: urls.count, total: urls.count, currentName: ""))
        return result
    }

    /// Permanently deletes items (the caller has already confirmed).
    static func delete(_ urls: [URL], fileManager fm: FileManager = .default,
                       token: FileOpsCancellationToken? = nil,
                       progress: ProgressHandler? = nil) -> FileOpsBatchResult {
        var result = FileOpsBatchResult()
        for (i, url) in urls.enumerated() {
            if token?.isCancelled == true { result.cancelled = true; break }
            progress?(FileOpsProgress(completed: i, total: urls.count, currentName: url.lastPathComponent))
            do {
                try fm.removeItem(at: url)
                result.done.append(FileOpsMovedItem(source: url, result: url))
            } catch {
                result.failures.append(FileOpsFailure(url, error))
            }
        }
        progress?(FileOpsProgress(completed: urls.count, total: urls.count, currentName: ""))
        return result
    }

    // MARK: Undo

    /// Undo for a move, rename or trash: puts each `result` back at `source`.
    /// An item that now occupies the original location is left alone and the
    /// clash is reported, never overwritten.
    static func moveBack(_ items: [FileOpsMovedItem], fileManager fm: FileManager = .default,
                         token: FileOpsCancellationToken? = nil,
                         progress: ProgressHandler? = nil) -> FileOpsBatchResult {
        var result = FileOpsBatchResult()
        for (i, item) in items.enumerated() {
            if token?.isCancelled == true { result.cancelled = true; break }
            progress?(FileOpsProgress(completed: i, total: items.count, currentName: item.result.lastPathComponent))
            do {
                try moveWithoutReplacing(item.result, to: item.source, fileManager: fm)
                result.done.append(FileOpsMovedItem(source: item.result, result: item.source))
            } catch {
                result.failures.append(FileOpsFailure(item.result, error))
            }
        }
        progress?(FileOpsProgress(completed: items.count, total: items.count, currentName: ""))
        return result
    }

    /// Undo for a copy or duplicate: moves the copies to the Trash (recoverable)
    /// rather than deleting them outright. Only an item that is still the
    /// recorded copy (same volume and inode) is trashed; anything that has
    /// taken its name since is left alone and reported.
    static func trashCopies(_ items: [FileOpsCreatedItem], trasher: Trasher = systemTrash,
                            fileManager fm: FileManager = .default,
                            token: FileOpsCancellationToken? = nil,
                            progress: ProgressHandler? = nil) -> FileOpsBatchResult {
        var verified: [URL] = []
        var failures: [FileOpsFailure] = []
        for item in items {
            let name = item.url.lastPathComponent
            guard exists(item.url, fm) else {
                failures.append(FileOpsFailure(name: name, message: FileOpsError.notFound(name).localizedDescription))
                continue
            }
            guard let recorded = item.identity, FileOpsItemIdentity(item.url, fileManager: fm) == recorded else {
                failures.append(FileOpsFailure(name: name, message: FileOpsError.replacedSinceCopy(name).localizedDescription))
                continue
            }
            verified.append(item.url)
        }
        var result = trash(verified, trasher: trasher, token: token, progress: progress)
        // An undo has nothing to offer instead: an item it can't trash is a failure.
        result.failures += result.noTrash.map {
            FileOpsFailure(name: $0.lastPathComponent, message: CocoaError(.featureUnsupported).localizedDescription)
        }
        result.noTrash = []
        result.failures += failures
        return result
    }

    // MARK: Primitives

    /// Renames `src` to `dest`, failing with `.fileWriteFileExists` instead of
    /// replacing an existing item. Uses an atomic exclusive rename where the
    /// platform has one. Between volumes the item is copied and the original
    /// then deleted (see `moveAcrossVolumes`).
    static func moveWithoutReplacing(_ src: URL, to dest: URL, fileManager fm: FileManager) throws {
        #if canImport(Darwin)
        // A case-only rename ("a.txt" → "A.txt") names the same file on a
        // case-insensitive volume, so the exclusive rename would refuse it.
        // On a case-sensitive volume "A.txt" may be a different file: refuse then.
        if FileOpsNaming.collisionKey(src.path) == FileOpsNaming.collisionKey(dest.path) {
            if exists(dest, fm) && !isSameFile(src, dest, fm) {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: dest.path])
            }
            guard rename(src.path, dest.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: src.path])
            }
            return
        }
        if renamex_np(src.path, dest.path, UInt32(RENAME_EXCL)) == 0 { return }
        let err = errno
        if err == EEXIST { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: dest.path]) }
        if err == EXDEV {
            try moveAcrossVolumes(src, to: dest, fileManager: fm)
            return
        }
        if err != ENOTSUP && err != EINVAL {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                          userInfo: [NSFilePathErrorKey: src.path])
        }
        #else
        if let a = FileOpsItemIdentity(src, fileManager: fm),
           let b = FileOpsItemIdentity(dest.deletingLastPathComponent(), fileManager: fm),
           a.device != b.device {
            try moveAcrossVolumes(src, to: dest, fileManager: fm)
            return
        }
        #endif
        if exists(dest, fm) { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: dest.path]) }
        try fm.moveItem(at: src, to: dest)
    }

    /// A move between volumes: copy (removing a partial copy on failure), then
    /// delete the original. If that delete fails the item exists in both
    /// places, which is reported as such rather than as a plain failure.
    static func moveAcrossVolumes(_ src: URL, to dest: URL, fileManager fm: FileManager) throws {
        try copyRemovingPartial(src, to: dest, fileManager: fm)
        do {
            try fm.removeItem(at: src)
        } catch {
            throw FileOpsError.movedButOriginalRemains(name: src.lastPathComponent,
                                                       destinationFolder: dest.deletingLastPathComponent().lastPathComponent,
                                                       reason: error.localizedDescription)
        }
    }

    /// Copies, and if the copy fails part-way removes the incomplete copy so it
    /// can't be mistaken for a good one. `dest` was free just before, so what is
    /// removed is only what this copy wrote — except when the failure is that
    /// `dest` itself appeared in the meantime, which belongs to someone else.
    /// A clash *inside* the copy (e.g. "a" and "A" from a case-sensitive
    /// volume) is a partial copy like any other; its error still says "file
    /// exists", but not at `dest`, so Undo doesn't take it for something in the
    /// way (`FileOpsUndoFailure`).
    static func copyRemovingPartial(_ src: URL, to dest: URL, fileManager fm: FileManager) throws {
        do {
            try fm.copyItem(at: src, to: dest)
        } catch let e as CocoaError where e.code == .fileWriteFileExists && clashIsAt(dest, e) {
            throw e
        } catch {
            if exists(dest, fm) { try? fm.removeItem(at: dest) }
            throw error
        }
    }

    /// Whether a "file exists" error is about `dest` itself. FileManager puts
    /// the clashing destination in "NSDestinationFilePath" (macOS) or
    /// NSFilePathErrorKey (elsewhere); with neither, assume it is `dest` so
    /// nothing that might not be ours is deleted.
    static func clashIsAt(_ dest: URL, _ error: CocoaError) -> Bool {
        let path = (error.userInfo["NSDestinationFilePath"] as? String)
                ?? (error.userInfo[NSFilePathErrorKey] as? String)
        guard let path else { return true }
        return URL(fileURLWithPath: path).standardizedFileURL.path == dest.standardizedFileURL.path
    }

    /// lstat-style existence (a dangling symlink still exists).
    static func exists(_ url: URL, _ fm: FileManager) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    /// Same volume and inode, without following a final symlink.
    static func isSameFile(_ a: URL, _ b: URL, _ fm: FileManager) -> Bool {
        guard let x = try? fm.attributesOfItem(atPath: a.path),
              let y = try? fm.attributesOfItem(atPath: b.path),
              let xd = x[.systemNumber] as? NSNumber, let yd = y[.systemNumber] as? NSNumber,
              let xi = x[.systemFileNumber] as? NSNumber, let yi = y[.systemFileNumber] as? NSNumber
        else { return false }
        return xd == yd && xi == yi
    }

    /// True if `url` is `folder` or somewhere inside it.
    static func isSameOrInside(_ url: URL, _ folder: URL) -> Bool {
        isSameOrInside(key: containmentKey(url), folderKey: containmentKey(folder))
    }

    /// `isSameOrInside` for keys made by `containmentKey`.
    static func isSameOrInside(key a: String, folderKey b: String) -> Bool {
        a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }

    /// Where an item really is (symlinks resolved), as the volume compares
    /// names: what `isSameOrInside` compares.
    static func containmentKey(_ url: URL) -> String {
        FileOpsNaming.collisionKey(url.resolvingSymlinksInPath().path)
    }

    /// A folder's path for telling whether an item is directly in it, however
    /// it is spelled (/var vs /private/var, or a symlink to the folder): an
    /// item whose parent has the same key as the destination is in its own
    /// folder. Symlinks are resolved, so a drop on a link to the items' own
    /// folder doesn't "move" them to free names beside themselves. Names keep
    /// their case: unlike `containmentKey`, two folders that differ only in
    /// case on a case-sensitive volume stay apart.
    static func folderKey(_ folder: URL) -> String {
        folder.absoluteURL.standardized.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// Turns a batch's failures into one readable message.
enum FileOpsErrorSummary {

    enum Action {
        case copy, move, duplicate, moveToTrash, delete, clearTags, moveBack, putBack
        case tag, removeTag(String)

        /// "Couldn’t copy 2 of 3 items:", a whole sentence for each action.
        func batchHeader(failed: Int, total: Int) -> String {
            switch self {
            case .copy:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t copy %1$lld of %2$lld items:", comment: "Summary of a file operation: how many items failed, of how many"), failed, total)
            case .move:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t move %1$lld of %2$lld items:", comment: "Summary of a file operation: how many items failed, of how many"), failed, total)
            case .duplicate:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t duplicate %1$lld of %2$lld items:", comment: "Summary of a file operation: how many items failed, of how many"), failed, total)
            case .moveToTrash:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t move to the Trash %1$lld of %2$lld items:", comment: "Summary of a file operation: how many items failed, of how many"), failed, total)
            case .delete:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t delete %1$lld of %2$lld items:", comment: "Summary of a file operation: how many items failed, of how many"), failed, total)
            case .clearTags:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t clear the tags of %1$lld of %2$lld items:", comment: "Summary of a file operation: how many items failed, of how many"), failed, total)
            case .moveBack:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t move back %1$lld of %2$lld items:", comment: "Summary of a file operation: how many items failed, of how many"), failed, total)
            case .putBack:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t put back %1$lld of %2$lld items:", comment: "Summary of a file operation: how many items failed, of how many"), failed, total)
            case .tag:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t tag %1$lld of %2$lld items:", comment: "Summary of a file operation: how many items failed, of how many"), failed, total)
            case .removeTag(let name):
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t remove the %1$@ tag from %2$lld of %3$lld items:", comment: "Summary of a file operation: how many items failed, of how many"), name, failed, total)
            }
        }

        func singleFailure(_ failure: FileOpsFailure) -> String {
            switch self {
            case .copy:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t copy “%1$@”: %2$@", comment: "Copy failure with item name and reason"), failure.name, failure.message)
            case .move:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t move “%1$@”: %2$@", comment: "Move failure with item name and reason"), failure.name, failure.message)
            case .duplicate:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t duplicate “%1$@”: %2$@", comment: "Duplicate failure with item name and reason"), failure.name, failure.message)
            case .moveToTrash:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t move to the Trash “%1$@”: %2$@", comment: "Trash failure with item name and reason"), failure.name, failure.message)
            case .delete:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t delete “%1$@”: %2$@", comment: "Delete failure with item name and reason"), failure.name, failure.message)
            case .clearTags:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t clear the tags of “%1$@”: %2$@", comment: "Clear tags failure with item name and reason"), failure.name, failure.message)
            case .moveBack:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t move back “%1$@”: %2$@", comment: "Undo move failure with item name and reason"), failure.name, failure.message)
            case .putBack:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t put back “%1$@”: %2$@", comment: "Undo Trash failure with item name and reason"), failure.name, failure.message)
            case .tag:
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t tag “%1$@”: %2$@", comment: "Tag failure with item name and reason"), failure.name, failure.message)
            case .removeTag(let name):
                return String.localizedStringWithFormat(NSLocalizedString("Couldn’t remove the %1$@ tag from “%2$@”: %3$@", comment: "Remove tag failure with tag name, item, and reason"), name, failure.name, failure.message)
            }
        }
    }

    /// nil when nothing failed.
    static func message(action: Action, failures: [FileOpsFailure], total: Int, limit: Int = 5) -> String? {
        guard !failures.isEmpty else { return nil }
        if failures.count == 1 && total <= 1 {
            return action.singleFailure(failures[0])
        }
        let header = action.batchHeader(failed: failures.count, total: max(total, failures.count))
        var lines = failures.prefix(limit).map {
            String.localizedStringWithFormat(NSLocalizedString("• %@: %@", comment: "File operation failure list entry with item name and reason"), $0.name, $0.message)
        }
        if failures.count > limit {
            lines.append(String.localizedStringWithFormat(NSLocalizedString("• and %lld more", comment: "Additional file operation failure count"), failures.count - limit))
        }
        return ([header] + lines).joined(separator: "\n")
    }
}
