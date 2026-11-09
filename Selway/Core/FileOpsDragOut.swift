import Foundation

/// Files dragged out of Selway to another app. Selway offers other apps
/// everything Finder does (copy, move, link, delete) and the receiver does
/// the work, so all Selway can do afterwards is see what became of the files:
/// refresh the folders they left, and, for a drag to the Dock's Trash, find
/// them in the Trash so Undo can put them back. A move's destination isn't
/// known, so a move can't be undone from here.
enum FileOpsDragOut {

    /// What a drag left of its files, by the operation the receiver reported.
    enum Ending: Equatable, Sendable {
        /// A copy, a link, or no drop: the files are where they were.
        case kept
        /// Moved (Finder on the same volume, or with ⌘ held).
        case moved
        /// Deleted: the Dock's Trash has Finder move them to the Trash.
        case trashed
    }

    /// The ending for AppKit's operation (NSDragOperation's raw values: copy
    /// 1, link 2, generic 4, private 8, move 16, delete 32). A receiver
    /// reports the one operation it did; one that echoes several (the whole
    /// mask, say) is taken at its word only as far as is safe: a copy or link
    /// among them keeps the files, and only a delete alone counts as the
    /// Trash. Generic is a move for files, as when Selway takes a drop
    /// (FileOpsDrop.allowed).
    static func ending(operation: UInt) -> Ending {
        if operation == 32 { return .trashed }
        if operation & (1 | 2) != 0 { return .kept }
        if operation & (4 | 16) != 0 { return .moved }
        return .kept
    }

    /// Whether `file` (as it was when its drag started) is still where it was.
    static func isInPlace(_ file: FileOpsCreatedItem, fileManager fm: FileManager = .default) -> Bool {
        guard let identity = file.identity else { return FileOpsTransfer.exists(file.url, fm) }
        return FileOpsItemIdentity(file.url, fileManager: fm) == identity
    }

    /// Where `files` went in the Trash: each that has left its place, looked
    /// for in `trash(for:)`, its volume's Trash, by identity (volume and
    /// inode, which a move to the Trash keeps). First under its own name,
    /// which needs no listing: the user's Trash can't be listed without Full
    /// Disk Access. Then, where the Trash can be listed, among the items whose
    /// names start with its own name less its extension, since the Trash
    /// renames an item whose name is taken there. Files not found are left out.
    static func trashed(_ files: [FileOpsCreatedItem], trash: (URL) -> URL?,
                        fileManager fm: FileManager = .default) -> [FileOpsMovedItem] {
        var listings: [URL: [String]] = [:]
        return files.compactMap { file in
            guard let identity = file.identity, !isInPlace(file, fileManager: fm),
                  let folder = trash(file.url) else { return nil }
            let name = file.url.lastPathComponent
            let sameName = folder.appendingPathComponent(name)
            if FileOpsItemIdentity(sameName, fileManager: fm) == identity {
                return FileOpsMovedItem(source: file.url, result: sameName)
            }
            if listings[folder] == nil { listings[folder] = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] }
            let stem = FileOpsNaming.split(name, isDirectory: false).stem
            let found = listings[folder, default: []]
                .filter { $0 != name && $0.hasPrefix(stem) }
                .sorted()
                .lazy
                .map { folder.appendingPathComponent($0) }
                .first { FileOpsItemIdentity($0, fileManager: fm) == identity }
            return found.map { FileOpsMovedItem(source: file.url, result: $0) }
        }
    }
}
