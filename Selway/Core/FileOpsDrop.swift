import Foundation

/// Files dropped on a folder: whether the drop moves or copies them, and when
/// it is refused, by Finder's rules. A drop on the same volume moves and one
/// from another volume copies; ⌥ forces a copy and ⌘ a move. Dropping a folder
/// into itself (or one of its subfolders) is refused, and so is moving items
/// into the folder they are already in, which Finder treats as doing nothing.
///
/// The app reads the drag (its file URLs, the keys held, what the source
/// allows) once into `Item`s, asks `decide` on every update while it hovers,
/// and runs the drop through FileOperationsService.drop, which is Paste's
/// transfer: progress, free names for clashes, one error message and Undo.
enum FileOpsDrop {

    /// The keys that change what a drop does.
    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }
        static let option  = Modifiers(rawValue: 1 << 0)
        static let command = Modifiers(rawValue: 1 << 1)
    }

    /// What the drag's source lets the destination do with its items.
    struct Allowed: OptionSet, Hashable, Sendable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }
        static let copy = Allowed(rawValue: 1 << 0)
        static let move = Allowed(rawValue: 1 << 1)
        static let all: Allowed = [.copy, .move]
    }

    /// Why a drop is refused.
    enum Refusal: Equatable, Sendable {
        /// No file URLs or file promises in the drag (text, a web link).
        case noFiles
        /// The keys held ask for something the source doesn't allow (or for
        /// an alias, which Selway doesn't make by dragging).
        case notAllowed
        /// A dragged folder is the destination or one of its ancestors.
        case intoItself(String)
        /// A move into the folder every item is already in.
        case alreadyThere
    }

    enum Decision: Equatable, Sendable {
        case drop(FileOpsTransfer.Mode)
        case refuse(Refusal)
    }

    /// A dragged item as read when the drag arrives, so hovering over one
    /// folder after another doesn't touch the disk for every item again.
    struct Item: Equatable, Sendable {
        let url: URL
        /// A real folder (not a symlink to one), which can't go inside itself.
        let isDirectory: Bool
        /// The volume the item is on; nil if it couldn't be read.
        let device: UInt64?
        /// `FileOpsTransfer.folderKey` of the folder it is in.
        let parentKey: String
        /// `FileOpsTransfer.containmentKey` of the item.
        let containmentKey: String

        init(url: URL, isDirectory: Bool, device: UInt64?, parentKey: String, containmentKey: String) {
            self.url = url; self.isDirectory = isDirectory; self.device = device
            self.parentKey = parentKey; self.containmentKey = containmentKey
        }

        /// Reads `url` the way FileOpsTransfer.transfer will treat it. The
        /// volume is the item's own: a symlink moves as itself, so it is on
        /// the volume of the folder holding it, wherever it points.
        init(reading url: URL, fileManager fm: FileManager = .default) {
            let src = url.absoluteURL.standardized
            self.init(url: src,
                      isDirectory: FileOpsNaming.isDirectory(src, fileManager: fm),
                      device: FileOpsItemIdentity(src, fileManager: fm)?.device,
                      parentKey: FileOpsTransfer.folderKey(src.deletingLastPathComponent()),
                      containmentKey: FileOpsTransfer.containmentKey(src))
        }
    }

    /// The folder a drop would go into, read once per drag.
    struct Destination: Equatable, Sendable {
        let url: URL
        /// The volume the folder's contents are on (a symlinked folder's
        /// target); nil if it couldn't be read.
        let device: UInt64?
        let folderKey: String
        let containmentKey: String

        init(url: URL, device: UInt64?, folderKey: String, containmentKey: String) {
            self.url = url; self.device = device
            self.folderKey = folderKey; self.containmentKey = containmentKey
        }

        init(reading url: URL, fileManager fm: FileManager = .default) {
            let dest = url.absoluteURL.standardized
            self.init(url: dest,
                      device: FileOpsItemIdentity(dest.resolvingSymlinksInPath(), fileManager: fm)?.device,
                      folderKey: FileOpsTransfer.folderKey(dest),
                      containmentKey: FileOpsTransfer.containmentKey(dest))
        }
    }

    // MARK: Deciding

    /// Move or copy, or nil when the keys held and the source leave nothing
    /// to do. With no key held a drop on the same volume moves (a copy if
    /// the source only allows that) and any other copies; it never falls
    /// back to moving, which would take the items away from where they were.
    static func mode(sameVolume: Bool, modifiers: Modifiers, allowed: Allowed) -> FileOpsTransfer.Mode? {
        switch (modifiers.contains(.option), modifiers.contains(.command)) {
        case (true, true):
            return nil   // ⌥⌘ makes an alias in Finder
        case (true, false):
            return allowed.contains(.copy) ? .copy : nil
        case (false, true):
            return allowed.contains(.move) ? .move : nil
        case (false, false):
            if sameVolume && allowed.contains(.move) { return .move }
            return allowed.contains(.copy) ? .copy : nil
        }
    }

    /// True when every item is on the destination's volume. Anything that
    /// couldn't be read counts as another volume, so the drop copies.
    static func isSameVolume(_ items: [Item], as destination: Destination) -> Bool {
        guard let device = destination.device, !items.isEmpty else { return false }
        return items.allSatisfy { $0.device == device }
    }

    /// What dropping `items` on `destination` does, without touching the disk.
    /// A folder that can't take one of the items refuses the whole drop, as
    /// in Finder, rather than taking the others and reporting an error.
    static func decide(_ items: [Item], into destination: Destination,
                       modifiers: Modifiers, allowed: Allowed) -> Decision {
        guard !items.isEmpty else { return .refuse(.noFiles) }
        guard let mode = mode(sameVolume: isSameVolume(items, as: destination),
                              modifiers: modifiers, allowed: allowed) else { return .refuse(.notAllowed) }
        if let folder = items.first(where: {
            $0.isDirectory && FileOpsTransfer.isSameOrInside(key: destination.containmentKey,
                                                             folderKey: $0.containmentKey)
        }) {
            return .refuse(.intoItself(folder.url.lastPathComponent))
        }
        if mode == .move && items.allSatisfy({ $0.parentKey == destination.folderKey }) {
            return .refuse(.alreadyThere)
        }
        return .drop(mode)
    }

    /// What dropping `count` file promises does (a Mail attachment, a photo
    /// from Photos, an image from Safari): the source writes new files, so it
    /// is a copy wherever they come from. Only a source that allows a copy is
    /// taken: one that allows only a move (as AppKit narrows the mask while ⌘
    /// is held) could delete its original once told of a move, while a file it
    /// wrote might still fail to land. ⌥⌘ asks for an alias, which a promise
    /// can't be.
    static func decidePromises(count: Int, modifiers: Modifiers, allowed: Allowed) -> Decision {
        guard count > 0 else { return .refuse(.noFiles) }
        guard !modifiers.contains([.option, .command]), allowed.contains(.copy) else { return .refuse(.notAllowed) }
        return .drop(.copy)
    }

    /// `decide` for URLs, reading them first (tests and one-off callers).
    static func decide(_ urls: [URL], into folder: URL, modifiers: Modifiers = [], allowed: Allowed = .all,
                       fileManager fm: FileManager = .default) -> Decision {
        decide(urls.map { Item(reading: $0, fileManager: fm) },
               into: Destination(reading: folder, fileManager: fm),
               modifiers: modifiers, allowed: allowed)
    }

    // MARK: Reading the drag

    /// What a drag's source allows, from AppKit's source operation mask
    /// (NSDragOperation's raw values: copy 1, link 2, generic 4, private 8,
    /// move 16, delete 32). Generic means "whatever the destination does",
    /// which for files is a move, as in Finder. AppKit narrows the mask to
    /// copy while ⌥ is held and to generic while ⌘ is, when the source allows.
    ///
    /// A drag from Selway itself allows both, whatever its mask says: Selway
    /// does the move or copy, not the source. SwiftUI's list rows say "move
    /// only" within the app and its icons "copy only", which would otherwise
    /// make one of the two impossible.
    static func allowed(sourceOperationMask mask: UInt, fromThisApp: Bool) -> Allowed {
        if fromThisApp { return .all }
        var allowed: Allowed = []
        if mask & 1 != 0 { allowed.insert(.copy) }
        if mask & (4 | 16) != 0 { allowed.insert(.move) }
        return allowed
    }
}
