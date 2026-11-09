import Foundation
import Testing
@testable import SelwayCore

/// ShellOpenResolver with links that answer when a test says so: following
/// one is a job the test runs, and nothing reads the disk.
@Suite struct ShellOpenResolverTests {
    /// The resolver's world: where each link leads, the follows started and
    /// not yet answered, and what was followed.
    final class World {
        var targets: [String: ShellOpenTarget] = [:]
        private(set) var follows: [() -> Void] = []
        private(set) var followed: [String] = []
        private(set) var pendingNames: [String?] = []

        lazy var resolver: ShellOpenResolver = {
            let resolver = ShellOpenResolver(
                follow: { [unowned self] item in
                    followed.append(item.name)
                    return targets[item.name] ?? .unreachable
                },
                startFollowing: { [unowned self] in follows.append($0) },
                deliver: { $0() })
            resolver.onPendingChange = { [unowned self] in pendingNames.append($0?.name) }
            return resolver
        }()

        /// The oldest follow started answers.
        func answerNext() { follows.removeFirst()() }
    }

    private func link(_ name: String) -> FileItem {
        var item = FileItem.fixture(name)
        item.isLinkNotFollowed = true
        return item
    }

    private let folder = FileItem.fixture("Docs", folder: true)
    private let file = FileItem.fixture("a.txt")

    /// Nothing to follow: decided at once from the listing, with no thread.
    @Test func itemsTheListingDecidedAreDecidedAtOnce() {
        let world = World()
        var applied: ShellOpenResolver.Resolution?
        world.resolver.resolve([folder, file]) { applied = $0 }
        #expect(applied == .init(folders: [folder.id], followed: [:]))
        #expect(world.follows.isEmpty)
        #expect(world.resolver.pending == nil)
    }

    /// The bug: following a link ran on the main thread and froze the window.
    /// Now nothing is applied until the follow answers, and meanwhile the
    /// window says what it's opening.
    @Test func aLinkIsFollowedOffTheMainThread() {
        let world = World()
        world.targets = ["Share": .folder]
        let share = link("Share")
        var applied: ShellOpenResolver.Resolution?
        world.resolver.resolve([share, file]) { applied = $0 }
        #expect(applied == nil)
        #expect(world.resolver.pending == ShellOpenResolver.Pending(ids: [share.id, file.id], name: "Share"))
        #expect(world.follows.count == 1)
        #expect(world.followed.isEmpty)

        world.answerNext()
        #expect(applied == .init(folders: [share.id], followed: [share.id: .folder]))
        #expect(world.resolver.pending == nil)
        #expect(world.pendingNames == ["Share", nil])
    }

    /// How a file at the end of a link opens is decided by the follow, off
    /// the main thread, and handed back: nothing reads it again to decide.
    @Test func aLinkToAFileSaysHowItOpens() {
        let world = World()
        world.targets = ["Note": .editor, "Gone": .unreachable]
        let note = link("Note"), gone = link("Gone")
        var applied: ShellOpenResolver.Resolution?
        world.resolver.resolve([note, gone]) { applied = $0 }
        world.answerNext()
        world.answerNext()
        #expect(applied == .init(folders: [], followed: [note.id: .editor, gone.id: .unreachable]))
    }

    /// Going to another folder (or closing the window) drops the open: the
    /// answer, when it comes, does nothing.
    @Test func aCancelledOpenIsNeverApplied() {
        let world = World()
        world.targets = ["Share": .folder]
        var applied = false
        world.resolver.resolve([link("Share")]) { _ in applied = true }
        world.resolver.cancel()
        #expect(world.resolver.pending == nil)
        world.answerNext()
        #expect(!applied)
    }

    /// A cancel lets go of the open's closures (and whatever they hold, a
    /// window's model), while the follow keeps running.
    @Test func cancellingReleasesTheOpen() {
        final class Window {}
        let world = World()
        world.targets = ["Share": .folder]
        let share = link("Share")
        weak var gone: Window?
        do {
            let window = Window()
            gone = window
            world.resolver.resolve([share], isRelevant: { _ = window; return true }) { _ in _ = window }
        }
        #expect(gone != nil)
        #expect(world.resolver.isWaiting)
        world.resolver.cancel()
        #expect(gone == nil)
        #expect(!world.resolver.isWaiting)
        #expect(world.resolver.isFollowing(share.url))
    }

    /// A newer open lets go of the one it replaces too.
    @Test func aNewerOpenReleasesTheOneItReplaces() {
        final class Window {}
        let world = World()
        weak var gone: Window?
        do {
            let window = Window()
            gone = window
            world.resolver.resolve([link("One")]) { _ in _ = window }
        }
        world.resolver.resolve([link("Two")]) { _ in }
        #expect(gone == nil)
    }

    @Test func anOpenNoLongerRelevantIsNeverApplied() {
        let world = World()
        world.targets = ["Share": .folder]
        var stillThere = true
        var applied = false
        world.resolver.resolve([link("Share")], isRelevant: { stillThere }) { _ in applied = true }
        stillThere = false
        world.answerNext()
        #expect(!applied)
        #expect(world.resolver.pending == nil)
    }

    /// The caller says something changed (a column's selection): an open no
    /// longer relevant is dropped at once, so the status bar stops saying
    /// it's opening.
    @Test func aRecheckDropsAnOpenNoLongerRelevant() {
        let world = World()
        world.targets = ["Share": .folder]
        var stillThere = true
        var applied = false
        world.resolver.resolve([link("Share")], isRelevant: { stillThere }) { _ in applied = true }
        world.resolver.recheck()
        #expect(world.resolver.pending?.name == "Share")
        stillThere = false
        world.resolver.recheck()
        #expect(world.resolver.pending == nil)
        stillThere = true
        world.answerNext()
        #expect(!applied)
    }

    /// A newer open wins: the older one's answer is dropped.
    @Test func aNewerOpenReplacesOneWaiting() {
        let world = World()
        world.targets = ["One": .folder, "Two": .folder]
        var applied: [String] = []
        world.resolver.resolve([link("One")]) { _ in applied.append("One") }
        world.resolver.resolve([link("Two")]) { _ in applied.append("Two") }
        #expect(world.resolver.pending?.name == "Two")
        world.answerNext()
        #expect(applied.isEmpty)
        world.answerNext()
        #expect(applied == ["Two"])
    }

    /// Opening a plain file meanwhile replaces the open waiting too.
    @Test func anOpenDecidedAtOnceReplacesOneWaiting() {
        let world = World()
        world.targets = ["Share": .folder]
        var applied: [ShellOpenResolver.Resolution] = []
        world.resolver.resolve([link("Share")]) { applied.append($0) }
        world.resolver.resolve([file]) { applied.append($0) }
        #expect(world.resolver.pending == nil)
        world.answerNext()
        #expect(applied == [.init(folders: [], followed: [:])])
    }

    /// The same items asked again while waiting (→ after a double-click in
    /// Columns) follow nothing again, and the later request's `apply` is the
    /// one run, once.
    @Test func theSameOpenAskedAgainReplacesTheFirstsApply() {
        let world = World()
        world.targets = ["Share": .folder]
        let share = link("Share")
        var applied: [String] = []
        world.resolver.resolve([share]) { _ in applied.append("open") }
        world.resolver.resolve([share]) { _ in applied.append("enter") }
        #expect(world.follows.count == 1)
        world.answerNext()
        #expect(applied == ["enter"])
    }

    /// A link still being followed (an unreachable host) isn't followed by a
    /// second thread when asked again after a cancel: the new open waits for
    /// the answer already coming.
    @Test func aLinkIsFollowedByOneThreadAtATime() {
        let world = World()
        world.targets = ["Share": .folder]
        let share = link("Share")
        var applied: [ShellOpenResolver.Resolution] = []
        world.resolver.resolve([share]) { applied.append($0) }
        world.resolver.cancel()
        world.resolver.resolve([share]) { applied.append($0) }
        #expect(world.follows.count == 1)
        #expect(world.resolver.isFollowing(share.url))
        world.answerNext()
        #expect(applied == [.init(folders: [share.id], followed: [share.id: .folder])])
        #expect(!world.resolver.isFollowing(share.url))
    }

    /// Several links: applied once all have answered, whatever the order.
    @Test func severalLinksAreAppliedOnceAllHaveAnswered() {
        let world = World()
        world.targets = ["One": .folder, "Two": .app]
        let one = link("One"), two = link("Two")
        var applied: ShellOpenResolver.Resolution?
        world.resolver.resolve([one, folder, two]) { applied = $0 }
        #expect(world.follows.count == 2)
        world.answerNext()
        #expect(applied == nil)
        world.answerNext()
        #expect(applied == .init(folders: [one.id, folder.id], followed: [one.id: .folder, two.id: .app]))
    }

    /// The window's status bar follows what the resolver is waiting on.
    @Test @MainActor func theModelShowsTheLinkBeingOpened() {
        let world = World()
        world.targets = ["Share": .folder]
        let model = BrowserModel(openResolver: world.resolver)
        model.openResolver.resolve([link("Share")]) { _ in }
        #expect(model.openingLinkName == "Share")
        world.answerNext()
        #expect(model.openingLinkName == nil)
    }

    // MARK: Where a file opens

    @Test func filesOpenWhereTheirTypeSays() {
        let sniffed: (URL) -> Bool = { _ in Issue.record("sniffed"); return false }
        #expect(ShellOpenTarget.forFile(URL(fileURLWithPath: "/x/README.md"), isEditableText: sniffed) == .markdown)
        #expect(ShellOpenTarget.forFile(URL(fileURLWithPath: "/x/main.swift"), isEditableText: sniffed) == .editor)
        #expect(ShellOpenTarget.forFile(URL(fileURLWithPath: "/x/Makefile"), isEditableText: sniffed) == .editor)
        #expect(ShellOpenTarget.forFile(URL(fileURLWithPath: "/x/notes"), isEditableText: { _ in true }) == .editor)
        #expect(ShellOpenTarget.forFile(URL(fileURLWithPath: "/x/photo.jpg"), isEditableText: { _ in false }) == .app)
    }

    /// Following a real link in a temporary folder: to a folder, a text
    /// file, nothing (broken), and a package.
    @Test func followingALinkSaysWhereItLeads() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let folder = try dir.dir("folder")
        let text = try dir.file("notes.txt", bytes: 10)
        let app = try dir.dir("Tool.app")
        let toFolder = try dir.link("to-folder", to: folder.path)
        let toText = try dir.link("to-text", to: text.path)
        let broken = try dir.link("broken", to: dir.url.appendingPathComponent("gone").path)
        let toApp = try dir.link("to-app", to: app.path)
        #expect(ShellOpenTarget.following(toFolder) == .folder)
        #expect(ShellOpenTarget.following(toText) == .editor)
        #expect(ShellOpenTarget.following(broken) == .unreachable)
        #expect(ShellOpenTarget.following(toApp) == .app)
    }

    @Test func theAlertNamesWhatCouldntBeReached() {
        #expect(ShellOpenTarget.unreachableAlert(names: ["Share"]).title == "“Share” couldn’t be opened.")
        #expect(ShellOpenTarget.unreachableAlert(names: ["A", "B"]).title == "2 items couldn’t be opened.")
    }
}
