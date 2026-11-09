import Foundation

/// File promises dropped on a folder: a Mail attachment, a photo from Photos,
/// an image from Safari. The source, not Selway, writes each file, under a
/// name it picks, into the folder it is given, and it may overwrite an item
/// of that name or fail on it. So the app has the promises written into a
/// staging folder of their own (`makeStagingFolder`) and moves each file into
/// the folder dropped on as it arrives (`land`) the way a copy lands there: a
/// name that is taken gets a free one ("a 2.txt"), as Paste's does, and Undo
/// trashes exactly the files the drop made. A `Batch` keeps count of the
/// answers and gathers what landed and what failed.
///
/// Only a source that allows a copy is taken (FileOpsDrop.decidePromises), so
/// whatever is left in the staging folder at the end (a file that couldn't
/// be moved in, or one written after Cancel) is a copy the source still has,
/// and the staging folder can go.
enum FileOpsPromiseDrop {

    /// A new, empty folder for promises dropped on `destination` to be written
    /// into: a temporary folder on its volume where the system has one (so
    /// moving the files into place renames rather than copies them), else one
    /// in the temporary folder. Every promise of a drag must be written into
    /// the same folder (NSFilePromiseReceiver), so a drop has one.
    static func makeStagingFolder(for destination: URL, fileManager fm: FileManager = .default) throws -> URL {
        if let replacement = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                         appropriateFor: destination, create: true) {
            return replacement
        }
        let fallback = fm.temporaryDirectory
            .appendingPathComponent("Selway drop \(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// How many answers a drop's promises owe: one per file each names, read
    /// once they have been called in (a promise names none before that, and a
    /// legacy one can name several), and at least one each.
    static func expectedAnswers(fileNameCounts: [Int]) -> Int {
        fileNameCounts.reduce(0) { $0 + max(1, $1) }
    }

    /// The name to report a failed promise by: the file its error names, else
    /// the promise's one file, else a translatable fallback name.
    static func failureName(errorPath: String?, promised names: [String]) -> String {
        if let errorPath, !errorPath.isEmpty { return URL(fileURLWithPath: errorPath).lastPathComponent }
        return names.count == 1 ? names[0] : NSLocalizedString("an item", comment: "Fallback name for a promised file with no known name")
    }

    /// Moves one file a promise wrote into `destination`, with a free name if
    /// its own is taken. The file moved in is `created` (and `done`), for an
    /// Undo that trashes it as it does a copy. Synchronous: run it off the
    /// main thread.
    static func land(_ file: URL, into destination: URL, fileManager fm: FileManager = .default) -> FileOpsBatchResult {
        var result = FileOpsTransfer.transfer([file], into: destination, mode: .move, fileManager: fm)
        result.created = result.done.map { FileOpsCreatedItem(recording: $0.result, fileManager: fm) }
        return result
    }

    /// Removes the staging folder and anything left in it.
    static func removeStagingFolder(_ staging: URL, fileManager fm: FileManager = .default) {
        try? fm.removeItem(at: staging)
    }

    /// One drop's answers, as they come in.
    struct Batch: Equatable, Sendable {
        /// How a batch ended.
        enum Ending: Equatable, Sendable {
            /// Every promise answered.
            case answered
            /// The user cancelled (or quit) while promises were outstanding.
            case cancelled
            /// The promises stopped answering for too long.
            case timedOut
        }

        let staging: URL
        let destination: URL
        /// Answers owed (`expectedAnswers`); 0 until the promises are called in.
        private(set) var expected = 0
        private(set) var answered = 0
        /// The files landed so far, and the failures.
        private(set) var result = FileOpsBatchResult()

        init(staging: URL, destination: URL) {
            self.staging = staging; self.destination = destination
        }

        /// Sets the answers owed, once the promises have been called in.
        mutating func expect(_ count: Int) { expected = count }

        /// Every answer owed has come.
        var isComplete: Bool { expected > 0 && answered >= expected }

        /// Progress: answers in, of those owed (more if more came).
        var progress: FileOpsProgress {
            FileOpsProgress(completed: answered, total: max(expected, answered), currentName: "")
        }

        /// A promise answered: it wrote `file`, or it failed (`failure`).
        /// Returns the file to land, if it is in the staging folder; one
        /// written anywhere else is reported, not moved. An answer past those
        /// owed still counts (a promise that named fewer files than it wrote).
        mutating func answer(_ file: URL, failure: FileOpsFailure?) -> URL? {
            answered += 1
            if let failure {
                result.failures.append(failure)
                return nil
            }
            // By the folder it is in, which exists, so its path resolves as the
            // staging folder's does (/private/var stays as it is).
            guard FileOpsTransfer.isSameOrInside(file.deletingLastPathComponent(), staging) else {
                result.failures.append(FileOpsFailure(name: file.lastPathComponent,
                                                      message: NSLocalizedString("Its app didn’t write it where Selway asked.", comment: "Promised file drop failure")))
                return nil
            }
            return file
        }

        /// Adds what `land` did with one file.
        mutating func add(_ landed: FileOpsBatchResult) {
            result.done += landed.done
            result.created += landed.created
            result.failures += landed.failures
        }

        /// The batch's result once it has ended: on a timeout each answer
        /// still owed is a failure; on Cancel the result says so.
        func finished(_ ending: Ending) -> FileOpsBatchResult {
            var final = result
            switch ending {
            case .answered:
                break
            case .cancelled:
                final.cancelled = true
            case .timedOut:
                let missing = max(0, expected - answered)
                final.failures += Array(repeating: FileOpsFailure(name: "an item",
                                                                  message: NSLocalizedString("Its app stopped before writing it.", comment: "Promised file drop failure")),
                                        count: missing)
            }
            return final
        }
    }
}
