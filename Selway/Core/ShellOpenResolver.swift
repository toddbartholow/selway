import Foundation

/// Where an item opened goes.
enum ShellOpenTarget: Equatable, Sendable {
    /// Shown as a folder.
    case folder
    /// Selway's Markdown reader.
    case markdown
    /// Selway's text editor.
    case editor
    /// Its own app (NSWorkspace), as a package does.
    case app
    /// A link whose target can't be reached: it's gone, or its server isn't
    /// answering. Nothing opens; the user is told.
    case unreachable

    /// Where a file (not a folder) goes: a Markdown file to the reader, text
    /// to the editor (a known type or name at once, anything else as
    /// `isEditableText` says, which may read the file), the rest to its app.
    static func forFile(_ url: URL,
                        isEditableText: (URL) -> Bool = { TextFileDetector.isEditableText($0) }) -> ShellOpenTarget {
        let ext = url.pathExtension.lowercased()
        if ext == "md" { return .markdown }
        if !ext.isEmpty && TextFileDetector.knownTextExtensions.contains(ext) { return .editor }
        if TextFileDetector.knownTextFilenames.contains(url.lastPathComponent.lowercased()) { return .editor }
        return isEditableText(url) ? .editor : .app
    }

    /// Where the link at `url` leads, followed: a folder, a file (sniffed
    /// here, so nothing reads it again on the main thread to decide), or
    /// `unreachable`. Follows the link, so off the main thread.
    static func following(_ url: URL) -> ShellOpenTarget {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .unreachable }
        if isDirectory.boolValue { return FileItem.isBrowsableFolder(url) ? .folder : .app }
        return forFile(url)
    }

    /// The alert for links that couldn't be reached, by name.
    static func unreachableAlert(names: [String]) -> (title: String, detail: String) {
        let title = names.count == 1
            ? String.localizedStringWithFormat(NSLocalizedString("“%@” couldn’t be opened.", comment: "Alert title for an unreachable item"), names[0])
            : String.localizedStringWithFormat(NSLocalizedString("%lld items couldn’t be opened.", comment: "Alert title for several unreachable items"), names.count)
        let detail = names.count == 1
            ? NSLocalizedString("The item it links to can’t be found, or its server isn’t answering.", comment: "Alert detail for an unreachable item")
            : NSLocalizedString("The items they link to can’t be found, or their servers aren’t answering.", comment: "Alert detail for several unreachable items")
        return (title, detail)
    }
}

/// Decides how the items being opened (a double-click, Return, Open) open,
/// for one browser window.
///
/// Most are decided by the listing, with no look at the disk. A link the
/// listing didn't follow (`FileItem.isLinkNotFollowed`, one into an
/// automount folder) is followed for it, which can mount an NFS share or
/// wait out an unreachable host's timeout. On the main thread that froze
/// the window; here it runs on a thread of its own, which also decides how
/// a file there opens (`ShellOpenTarget.following`), while the window says
/// what it's opening (`pending`). The result is used only if it still
/// applies:
/// - a newer open, or `cancel` (the window went to another folder, changed
///   view, or closed), drops it;
/// - `isRelevant`, asked when it comes in and whenever the caller says
///   things changed (`recheck`), can drop it too (a column whose selection
///   has changed);
/// - the same items asked for again while they're being followed (→ after a
///   double-click in Columns) replace the first request's `apply`, without
///   following anything again;
/// - one link is followed by one thread at a time: asked for again (after
///   going away and coming back), it waits for the answer already coming
///   rather than starting another thread that would hang the same way.
///
/// Nothing is kept for a request dropped: only the request waiting holds
/// its closures. Used on the main thread only; `follow`, `startFollowing`
/// and `deliver` are injectable for the tests. (For the Swift 6 language
/// mode it would be `@MainActor`, and its closures `@Sendable`.)
final class ShellOpenResolver {
    /// What's being opened, while a link is followed for it.
    struct Pending: Equatable {
        /// The items asked for (FileItem.id), in order.
        let ids: [String]
        /// The name of the first link being followed, for the status bar.
        let name: String
    }

    /// How the items open: the ids of those shown as folders, and where each
    /// link the listing didn't follow led (by id).
    struct Resolution: Equatable {
        var folders: Set<String>
        var followed: [String: ShellOpenTarget]
    }

    /// The open waiting on a link, if any.
    private(set) var pending: Pending? {
        didSet { if pending != oldValue { onPendingChange(pending) } }
    }
    /// Told whenever `pending` changes (the window's status bar).
    var onPendingChange: (Pending?) -> Void = { _ in }

    private final class Request {
        let ids: [String]
        let links: [FileItem]
        let folders: Set<String>
        /// The links' keys (ShellPath.key) not answered yet.
        var waiting: Set<String>
        var followed: [String: ShellOpenTarget] = [:]
        var isRelevant: () -> Bool
        var apply: (Resolution) -> Void

        init(ids: [String], links: [FileItem], folders: Set<String>,
             isRelevant: @escaping () -> Bool, apply: @escaping (Resolution) -> Void) {
            self.ids = ids
            self.links = links
            self.folders = folders
            self.waiting = Set(links.map { ShellPath.key($0.url) })
            self.isRelevant = isRelevant
            self.apply = apply
        }
    }

    private let follow: (FileItem) -> ShellOpenTarget
    private let startFollowing: (@escaping () -> Void) -> Void
    private let deliver: (@escaping () -> Void) -> Void
    private var request: Request?
    /// The links being followed now (ShellPath.key), whoever asked.
    private var following: Set<String> = []

    init(follow: @escaping (FileItem) -> ShellOpenTarget = { ShellOpenTarget.following($0.url) },
         startFollowing: @escaping (@escaping () -> Void) -> Void = { follow in
             // Not a dispatch queue: a look-up stuck in the kernel would hold
             // one of its few threads.
             let thread = Thread(block: follow)
             thread.name = "studio.irq.selway.open-link"
             thread.qualityOfService = .userInitiated
             thread.start()
         },
         deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.follow = follow
        self.startFollowing = startFollowing
        self.deliver = deliver
    }

    /// Calls `apply` with how `items` open: at once when none of them is a
    /// link the listing didn't follow, otherwise once those are followed, if
    /// this is still the window's latest open and `isRelevant` says so.
    /// Either way it replaces any open still waiting, except one for the same
    /// items, whose `apply` and `isRelevant` this replaces instead.
    func resolve(_ items: [FileItem], isRelevant: @escaping () -> Bool = { true },
                 apply: @escaping (Resolution) -> Void) {
        let links = items.filter(\.isLinkNotFollowed)
        let ids = items.map(\.id)
        if let request, request.ids == ids, !links.isEmpty {
            request.isRelevant = isRelevant
            request.apply = apply
            return
        }
        let folders = Set(items.filter { !$0.isLinkNotFollowed && $0.isBrowsableFolder }.map(\.id))
        guard let first = links.first else {
            drop()
            apply(Resolution(folders: folders, followed: [:]))
            return
        }
        let request = Request(ids: ids, links: links, folders: folders, isRelevant: isRelevant, apply: apply)
        self.request = request
        pending = Pending(ids: ids, name: first.name)
        var asked = Set<String>()
        for link in links {
            let key = ShellPath.key(link.url)
            guard asked.insert(key).inserted, following.insert(key).inserted else { continue }
            let follow = self.follow, deliver = self.deliver
            startFollowing { [weak self] in
                let target = follow(link)
                deliver { self?.answered(key, target) }
            }
        }
    }

    /// Drops the open waiting, if any: its answer, when it comes, is ignored.
    /// A link still being followed stays so (no second thread starts for it).
    func cancel() { drop() }

    /// Asks the open waiting whether it still applies, and drops it if not.
    func recheck() {
        guard let request, !request.isRelevant() else { return }
        drop()
    }

    /// Whether a link at `url` is being followed now.
    func isFollowing(_ url: URL) -> Bool { following.contains(ShellPath.key(url)) }

    /// Whether an open is waiting (holding its closures).
    var isWaiting: Bool { request != nil }

    private func drop() {
        request = nil
        pending = nil
    }

    private func answered(_ key: String, _ target: ShellOpenTarget) {
        following.remove(key)
        guard let request, request.waiting.remove(key) != nil else { return }
        for link in request.links where ShellPath.key(link.url) == key { request.followed[link.id] = target }
        guard request.waiting.isEmpty else { return }
        drop()
        guard request.isRelevant() else { return }
        var folders = request.folders
        for (id, target) in request.followed where target == .folder { folders.insert(id) }
        request.apply(Resolution(folders: folders, followed: request.followed))
    }
}
