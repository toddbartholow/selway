import Foundation

/// File → Copy to Other Pane (F5) and Move to Other Pane (F6), as in Commander
/// One: the active pane's selection goes into the folder the other pane shows,
/// once the user confirms. This decides whether it can run (and if not, why),
/// which items go and where, what the confirmation says, and what the toast
/// says when it can't. The transfer itself is a drop's
/// (FileOperationsService.drop): progress, free names for clashes, one error
/// message and Undo.
///
/// Folders are told apart by what they are on disk (volume and inode), not by
/// how their paths are spelled: a pane can reach a folder through a symlink,
/// with or without /private, or typed in another case on a volume that
/// ignores case, and it's still the same folder. Comparing paths would get
/// those wrong one way or the other (lower-casing them as FileOpsDrop's
/// containment keys do would also take two folders on a case-sensitive volume
/// for one). The app reads the selection and both folders once (`Item`,
/// `Folder`, the `reading` initialisers), and `decide` compares what was read
/// without touching the disk.
enum ShellPaneTransfer {

    /// Why F5 / F6 do nothing (the app beeps, and says why in a toast).
    enum Refusal: Equatable, Sendable {
        /// The window shows one pane: there is no other pane to send to.
        case singlePane
        /// Nothing is selected in the active pane.
        case nothingSelected
        /// Both panes show the same folder.
        case sameFolder
        /// The destination pane shows the computer, not a folder.
        case otherPaneNotFolder
        /// A selected item (its name) is already in the other pane's folder
        /// (one of a search's results, say): copying it there would duplicate
        /// it beside itself, and moving it would do nothing.
        case alreadyThere(String)
        /// The other pane's folder is a selected folder (its name), or inside
        /// one: a folder can't go into itself.
        case intoItself(String)
    }

    /// A selected item, as read once.
    struct Item: Equatable, Sendable {
        let url: URL
        /// A real folder (not a symlink to one), which can't go inside itself.
        let isDirectory: Bool
        /// The item itself (a symlink, not what it leads to); nil if unreadable.
        let identity: FileOpsItemIdentity?
        /// The folder the item is in, then each folder above it, to the top of
        /// the disk (symlinks on the way followed).
        let ancestors: [FileOpsItemIdentity]

        init(url: URL, isDirectory: Bool, identity: FileOpsItemIdentity?, ancestors: [FileOpsItemIdentity]) {
            self.url = url; self.isDirectory = isDirectory; self.identity = identity; self.ancestors = ancestors
        }

        init(reading url: URL, fileManager fm: FileManager = .default) {
            self.init(reading: url, ancestors: { Folder.chain($0, fileManager: fm) }, fileManager: fm)
        }

        /// `url` as read, its folder's chain from `ancestors`.
        private init(reading url: URL, ancestors: (URL) -> [FileOpsItemIdentity], fileManager fm: FileManager) {
            let src = url.absoluteURL.standardized
            self.init(url: src, isDirectory: FileOpsNaming.isDirectory(src, fileManager: fm),
                      identity: FileOpsItemIdentity(src, fileManager: fm),
                      ancestors: ancestors(src.deletingLastPathComponent()))
        }

        /// `urls` as read, each folder's chain read once (`chain`) however
        /// many of them are in it: a Select All in a big folder reads one.
        static func reading(_ urls: [URL], fileManager fm: FileManager = .default,
                            chain: (URL) -> [FileOpsItemIdentity]) -> [Item] {
            var chains: [String: [FileOpsItemIdentity]] = [:]
            return urls.map { url in
                Item(reading: url, ancestors: { folder in
                    if let known = chains[folder.path] { return known }
                    let read = chain(folder)
                    chains[folder.path] = read
                    return read
                }, fileManager: fm)
            }
        }
    }

    /// A pane's folder, as read once.
    struct Folder: Equatable, Sendable {
        let url: URL
        /// The folder, then each folder above it, to the top of the disk
        /// (symlinks on the way followed); empty if it couldn't be read.
        let chain: [FileOpsItemIdentity]

        init(url: URL, chain: [FileOpsItemIdentity]) {
            self.url = url; self.chain = chain
        }

        init(reading url: URL, fileManager fm: FileManager = .default) {
            self.init(url: url, chain: Self.chain(url, fileManager: fm))
        }

        /// The folder itself, when it could be read.
        var identity: FileOpsItemIdentity? { chain.first }

        /// The identities of `folder` (symlinks followed, as realpath(3)
        /// does) and of each folder above it.
        static func chain(_ folder: URL, fileManager fm: FileManager = .default) -> [FileOpsItemIdentity] {
            guard let real = ModelPaths.realPath(folder) else { return [] }
            var chain: [FileOpsItemIdentity] = []
            var path = real.path
            while true {
                guard let identity = FileOpsItemIdentity(URL(fileURLWithPath: path), fileManager: fm) else { break }
                chain.append(identity)
                if path == "/" { break }
                let parent = (path as NSString).deletingLastPathComponent
                path = parent.isEmpty ? "/" : parent
            }
            return chain
        }

        /// The same folder as `other`: on disk if both were read, else by path.
        func isSame(as other: Folder) -> Bool {
            if let a = identity, let b = other.identity { return a == b }
            return ShellPath.same(url, other.url)
        }
    }

    /// What the confirmation offers to do.
    struct Plan: Equatable, Sendable {
        let mode: FileOpsTransfer.Mode
        /// The selected items, in the order selected, leaving out any inside
        /// a selected folder (they go with it).
        let sources: [URL]
        /// The folder the other pane shows.
        let destination: URL
        /// The sheet's question: "Copy “alpha.txt” to “Documents”?".
        let title: String
        /// The sheet's detail: where the items go, and what happens to a name
        /// that's taken there.
        let message: String
    }

    enum Decision: Equatable, Sendable {
        case confirm(Plan)
        case refuse(Refusal)
    }

    /// Whether the window can copy or move `selected` (read from the active
    /// pane, which shows `source`) into the other pane's folder,
    /// `destination`. `isDual` is whether the window shows two panes.
    /// `searching`: the active pane lists a search's or a tag's results, which
    /// can be from anywhere, so both panes on one folder doesn't rule it out
    /// (an item already in the other pane's folder still does).
    static func decide(_ mode: FileOpsTransfer.Mode, isDual: Bool, selected: [Item],
                       from source: Folder, into destination: Folder, searching: Bool = false) -> Decision {
        guard isDual else { return .refuse(.singlePane) }
        guard !selected.isEmpty else { return .refuse(.nothingSelected) }
        guard searching || !source.isSame(as: destination) else { return .refuse(.sameFolder) }
        let items = topLevel(selected)
        if let folder = items.first(where: { item in
            item.isDirectory && item.identity.map { destination.chain.contains($0) } == true
        }) {
            return .refuse(.intoItself(folder.url.lastPathComponent))
        }
        if let there = items.first(where: { item in
            guard let parent = item.ancestors.first, let folder = destination.identity else { return false }
            return parent == folder
        }) {
            return .refuse(.alreadyThere(there.url.lastPathComponent))
        }
        let names = items.map(\.url.lastPathComponent)
        return .confirm(Plan(mode: mode, sources: items.map(\.url), destination: destination.url,
                             title: title(mode, names: names, destination: destination.url),
                             message: message(mode, count: names.count, destination: destination.url)))
    }

    /// `decide` for URLs, reading them first: the selection's items, and the
    /// folders both panes show. It reads the disk (a few reads per item, and
    /// each folder's chain to the top), so the app calls it off the main thread.
    static func decide(_ mode: FileOpsTransfer.Mode, isDual: Bool, selected urls: [URL],
                       from sourceFolder: URL, into destinationFolder: URL, searching: Bool = false,
                       fileManager fm: FileManager = .default) -> Decision {
        // Nothing is read for a refusal that needs nothing read.
        if let refusal = refusalBeforeReading(isDual: isDual, selected: urls) { return .refuse(refusal) }
        let items = Item.reading(urls, fileManager: fm, chain: { Folder.chain($0, fileManager: fm) })
        return decide(mode, isDual: isDual, selected: items,
                      from: Folder(reading: sourceFolder, fileManager: fm),
                      into: Folder(reading: destinationFolder, fileManager: fm), searching: searching)
    }

    /// The refusals that need nothing read: one pane, no selection, or no folder destination.
    /// The app gives these at once, without going off the main thread.
    static func refusalBeforeReading(isDual: Bool, selected urls: [URL], hasFolderDestination: Bool = true) -> Refusal? {
        guard isDual else { return .singlePane }
        guard !urls.isEmpty else { return .nothingSelected }
        guard hasFolderDestination else { return .otherPaneNotFolder }
        return nil
    }

    /// `items` without those inside another selected folder (a search can
    /// list a folder and what's in it): they go with their folder, and
    /// sending them as well would leave copies of them beside it, or fail to
    /// move them once their folder had gone.
    static func topLevel(_ items: [Item]) -> [Item] {
        let folders = Set(items.filter(\.isDirectory).compactMap(\.identity).map(IdentityKey.init))
        guard !folders.isEmpty else { return items }
        return items.filter { item in !item.ancestors.contains { folders.contains(IdentityKey($0)) } }
    }

    /// FileOpsItemIdentity as a set member.
    private struct IdentityKey: Hashable {
        let device: UInt64
        let inode: UInt64
        init(_ identity: FileOpsItemIdentity) { device = identity.device; inode = identity.inode }
    }

    // MARK: The confirmation

    /// "Copy “alpha.txt” to “Documents”?", or "Move 3 items to “Documents”?".
    static func title(_ mode: FileOpsTransfer.Mode, names: [String], destination: URL) -> String {
        let folder = displayName(destination)
        if names.count == 1, let name = names.first {
            let format = mode == .copy
                ? NSLocalizedString("Copy “%1$@” to “%2$@”?", comment: "Confirmation to copy one item; item and folder names")
                : NSLocalizedString("Move “%1$@” to “%2$@”?", comment: "Confirmation to move one item; item and folder names")
            return String.localizedStringWithFormat(format, name, folder)
        }
        let format = mode == .copy
            ? NSLocalizedString("Copy %1$lld items to “%2$@”?", comment: "Confirmation to copy two or more items; count and folder name")
            : NSLocalizedString("Move %1$lld items to “%2$@”?", comment: "Confirmation to move two or more items; count and folder name")
        return String.localizedStringWithFormat(format, names.count, folder)
    }

    /// Where the items go, in full, and what a taken name does.
    static func message(_ mode: FileOpsTransfer.Mode, count: Int, destination: URL) -> String {
        let path = ShellPath.key(destination)
        guard count == 1 else {
            return String.localizedStringWithFormat(NSLocalizedString(
                "Into %@. Any whose names are taken there get new ones.",
                comment: "Confirmation detail for two or more items; destination folder path"), path)
        }
        let format = mode == .copy
            ? NSLocalizedString("Into %@. If its name is taken there, the copy gets a new one.",
                                comment: "Confirmation detail for copying one item; destination folder path")
            : NSLocalizedString("Into %@. If its name is taken there, the item gets a new one.",
                                comment: "Confirmation detail for moving one item; destination folder path")
        return String.localizedStringWithFormat(format, path)
    }

    // MARK: Refusals

    /// What the toast says when F5 / F6 can't run (the app beeps as well),
    /// `destination` being the other pane's folder.
    static func refusalMessage(_ refusal: Refusal, mode: FileOpsTransfer.Mode, destination: URL?) -> String {
        switch refusal {
        case .singlePane:
            if mode == .copy {
                return NSLocalizedString("Show Dual Pane to copy to the other pane", comment: "File operation status explaining dual pane is needed for copy")
            }
            return NSLocalizedString("Show Dual Pane to move to the other pane", comment: "File operation status explaining dual pane is needed for move")
        case .nothingSelected:
            if mode == .copy {
                return NSLocalizedString("Select items to copy first", comment: "File operation status explaining a selection is needed for copy")
            }
            return NSLocalizedString("Select items to move first", comment: "File operation status explaining a selection is needed for move")
        case .otherPaneNotFolder:
            return mode == .copy
                ? NSLocalizedString("Show a folder in the other pane to copy there", comment: "File operation status when the other pane shows the computer")
                : NSLocalizedString("Show a folder in the other pane to move there", comment: "File operation status when the other pane shows the computer")
        case .sameFolder:
            return NSLocalizedString("Both panes show the same folder", comment: "File operation status when both panes show the same folder")
        case .alreadyThere(let name):
            let folder = destination.map(displayName)
            return folder.map { String.localizedStringWithFormat(NSLocalizedString("“%1$@” is already in “%2$@”", comment: "File operation status with item and destination names"), name, $0) }
                ?? String.localizedStringWithFormat(NSLocalizedString("“%@” is already in that folder", comment: "File operation status with item name"), name)
        case .intoItself(let name):
            if mode == .copy {
                return String.localizedStringWithFormat(
                    NSLocalizedString("“%@” can’t be copied into itself", comment: "File operation status with item name for copy"), name)
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("“%@” can’t be moved into itself", comment: "File operation status with item name for move"), name)
        }
    }

    /// A folder's name, "/" for the top of the disk.
    private static func displayName(_ url: URL) -> String {
        let name = URL(fileURLWithPath: ShellPath.key(url)).lastPathComponent
        return name.isEmpty ? "/" : name
    }
}
