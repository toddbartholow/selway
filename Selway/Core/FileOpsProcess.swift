import Foundation

/// Errors raised by Selway's own file-operation logic (system errors from
/// FileManager are passed through unchanged).
enum FileOpsError: Error, Equatable, LocalizedError {
    case cancelled
    case toolFailed(tool: String, status: Int32, output: String)
    case duplicateNames(String)
    case unsupportedArchive(String)
    case intoItself(String)
    case notFound(String)
    case notAFolder(String)
    case unsafePath
    case quarantineFailed(Int)
    /// The archive's quarantine flag couldn't be read, so it wasn't extracted.
    case quarantineUnreadable(String)
    /// Undo found a different item where a copy used to be.
    case replacedSinceCopy(String)
    /// Undo or Redo found a different item where the one it recorded used to be.
    case replacedSince(String)
    /// A move between volumes copied the item but couldn't delete the original.
    case movedButOriginalRemains(name: String, destinationFolder: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return NSLocalizedString("The operation was cancelled.", comment: "File operation error")
        case let .toolFailed(tool, status, output):
            let message = String.localizedStringWithFormat(
                NSLocalizedString("%1$@ failed (exit status %2$d).", comment: "File operation command failure; tool name and exit status"),
                tool, status)
            return output.isEmpty ? message : message + "\n\n" + output
        case .duplicateNames(let name):
            return String.localizedStringWithFormat(NSLocalizedString("More than one selected item is named “%@”. Items in an archive need different names.", comment: "Archive error with duplicate item name"), name)
        case .unsupportedArchive(let name):
            return String.localizedStringWithFormat(NSLocalizedString("Selway can’t extract “%@”.", comment: "Archive extraction error with item name"), name)
        case .intoItself(let name):
            return String.localizedStringWithFormat(NSLocalizedString("“%@” can’t be copied or moved into itself.", comment: "File operation error with item name"), name)
        case .notFound(let name):
            return String.localizedStringWithFormat(NSLocalizedString("“%@” no longer exists.", comment: "File operation error with item name"), name)
        case .notAFolder(let name):
            return String.localizedStringWithFormat(NSLocalizedString("“%@” isn’t a folder.", comment: "File operation error with item name"), name)
        case .unsafePath:
            return NSLocalizedString("This folder’s name contains control characters (such as a line break), so Selway won’t type it into Terminal. Rename the folder and try again.", comment: "Terminal safety error")
        case .quarantineFailed(let count):
            return LocalizedCount.string(
                count,
                NSLocalizedString("Couldn’t mark %lld extracted items as downloaded, so the extraction was stopped to keep Gatekeeper checks in place.",
                                  comment: "Archive error when extracted items can’t be marked as downloaded"),
                one: "Couldn’t mark %lld extracted item as downloaded, so the extraction was stopped to keep Gatekeeper checks in place.",
                other: "Couldn’t mark %lld extracted items as downloaded, so the extraction was stopped to keep Gatekeeper checks in place.")
        case .quarantineUnreadable(let name):
            return String.localizedStringWithFormat(NSLocalizedString("Couldn’t check whether “%@” was downloaded from the internet, so it wasn’t extracted (to keep Gatekeeper checks in place).", comment: "Archive quarantine check error with item name"), name)
        case .replacedSinceCopy(let name):
            return String.localizedStringWithFormat(NSLocalizedString("“%@” has changed since it was copied (it is a different item now), so it was left alone.", comment: "Undo error with item name"), name)
        case .replacedSince(let name):
            return String.localizedStringWithFormat(NSLocalizedString("“%@” is no longer the item Selway moved or copied (something else has taken its place), so it was left alone.", comment: "Undo error with item name"), name)
        case let .movedButOriginalRemains(name, folder, reason):
            return String.localizedStringWithFormat(NSLocalizedString("“%1$@” was copied to “%2$@”, but the original couldn’t be removed (%3$@), so it now exists in both places. Check both copies before deleting either.", comment: "Move error with item, destination folder, and failure reason"), name, folder, reason)
        }
    }
}

/// Cooperative cancellation shared between the UI (Cancel button) and a
/// background operation. A running subprocess registers a handler so Cancel
/// terminates it instead of waiting for it to finish.
final class FileOpsCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (() -> Void)?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let h = handler
        lock.unlock()
        h?()
    }

    /// Installs (or with nil, removes) the action run on cancel. Runs it at once
    /// if cancellation already happened.
    func setCancelHandler(_ h: (() -> Void)?) {
        lock.lock()
        handler = h
        let fireNow = cancelled
        lock.unlock()
        if fireNow { h?() }
    }
}

/// Runs a command-line tool with an explicit argument vector (never a shell),
/// and turns a non-zero exit into an error carrying the tool's output.
enum FileOpsProcess {

    static func run(_ tool: String, _ arguments: [String], in directory: URL? = nil,
                    token: FileOpsCancellationToken? = nil) throws {
        if token?.isCancelled == true { throw FileOpsError.cancelled }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments     = arguments
        if let directory { p.currentDirectoryURL = directory }
        let output = Pipe()
        p.standardInput  = FileHandle.nullDevice
        p.standardOutput = output
        p.standardError  = output
        try p.run()
        token?.setCancelHandler { p.terminate() }
        defer { token?.setCancelHandler(nil) }
        // Drain before waiting so a chatty tool can't block on a full pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if token?.isCancelled == true { throw FileOpsError.cancelled }
        guard p.terminationReason == .exit, p.terminationStatus == 0 else {
            let text = String(decoding: data, as: UTF8.self)
                .split(separator: "\n").suffix(6).joined(separator: "\n")
            throw FileOpsError.toolFailed(tool: (tool as NSString).lastPathComponent,
                                          status: p.terminationStatus, output: text)
        }
    }
}
