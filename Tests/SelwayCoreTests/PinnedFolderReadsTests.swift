import Foundation
import Testing
@testable import SelwayCore

/// PinnedFolderReader with fake folders: a read of one the test hangs waits
/// until the test answers it, as a folder on a share that has stopped
/// answering would.
@Suite struct PinnedFolderReadsTests {
    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var gates: [String: DispatchSemaphore] = [:]
        private var readCounts: [String: Int] = [:]
        private var lists: [[String: String]] = []

        func hang(_ path: String) { lock.withLock { gates[path] = DispatchSemaphore(value: 0) } }
        func answer(_ path: String) { lock.withLock { gates.removeValue(forKey: path) }?.signal() }
        func reads(of path: String) -> Int { lock.withLock { readCounts[path, default: 0] } }
        var published: [[String: String]] { lock.withLock { lists } }

        /// Paths ending in "gone" aren't there; "/net/..." is refused, "/missing/..." missing.
        func reader() -> PinnedFolderReader<String> {
            let hooks = PinnedFolderReader<String>.Hooks(
                check: { path in
                    path.hasPrefix("/net/") ? .refused : path.hasPrefix("/missing/") ? .missing : .safe
                },
                read: { [self] url in
                    let gate: DispatchSemaphore? = lock.withLock {
                        readCounts[url.path, default: 0] += 1
                        return gates[url.path]
                    }
                    gate?.wait()
                    return url.path.hasSuffix("gone") ? nil : "icon"
                },
                start: { work in Thread(block: work).start() })
            return PinnedFolderReader(hooks: hooks, grace: 0.2, deliver: { $0() }) { [self] answers in
                let list = answers.mapValues { answer -> String in
                    switch answer {
                    case .refused:         return "refused"
                    case .missing:         return "missing"
                    case .present(let id): return id
                    }
                }
                lock.withLock { lists.append(list) }
            }
        }

        /// The first list published from the `skipping`-th on that satisfies `condition`, waiting up to 5 s.
        func waitFor(skipping: Int = 0, _ condition: ([String: String]) -> Bool) -> [String: String]? {
            let deadline = Date(timeIntervalSinceNow: 5)
            while Date() < deadline {
                if let list = published.dropFirst(skipping).first(where: condition) { return list }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return nil
        }
    }

    private func key(_ path: String) -> String { ShellPath.key(URL(fileURLWithPath: path, isDirectory: true)) }
    private func urls(_ paths: String...) -> [URL] { paths.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    @Test func aFolderThatNeverAnswersDoesNotHoldUpTheOthers() throws {
        let world = World()
        world.hang("/Volumes/NAS/Docs")
        defer { world.answer("/Volumes/NAS/Docs") }
        let reader = world.reader()
        reader.refresh(urls("/Users/me/Work", "/Volumes/NAS/Docs", "/Volumes/USB/gone"))
        let list = try #require(world.waitFor { $0.count == 2 })
        #expect(list == [key("/Users/me/Work"): "icon", key("/Volumes/USB/gone"): "missing"])

        // Refreshes meanwhile don't pile reads up on it.
        let shown = world.published.count
        reader.refresh(urls("/Users/me/Work", "/Volumes/NAS/Docs", "/Volumes/USB/gone"))
        reader.refresh(urls("/Users/me/Work", "/Volumes/NAS/Docs", "/Volumes/USB/gone"))
        _ = world.waitFor(skipping: shown + 1) { _ in true }
        #expect(world.reads(of: "/Volumes/NAS/Docs") == 1)
        #expect(reader.isReading(key("/Volumes/NAS/Docs")))
    }

    @Test func aLateAnswerIsPublishedAndTheFolderReadAgainIfAskedMeanwhile() throws {
        let world = World()
        world.hang("/Volumes/NAS/Docs")
        let reader = world.reader()
        reader.refresh(urls("/Volumes/NAS/Docs"))
        _ = try #require(world.waitFor { _ in true })
        // Asked for while its read waits: once that's published, the folder
        // is marked to be read again rather than read a second time now.
        reader.refresh(urls("/Volumes/NAS/Docs"))
        _ = try #require(world.waitFor(skipping: 1) { _ in true })
        #expect(world.reads(of: "/Volumes/NAS/Docs") == 1)
        world.answer("/Volumes/NAS/Docs")
        let answered = try #require(world.waitFor { $0[key("/Volumes/NAS/Docs")] == "icon" })
        #expect(answered == [key("/Volumes/NAS/Docs"): "icon"])
        let deadline = Date(timeIntervalSinceNow: 5)
        while world.reads(of: "/Volumes/NAS/Docs") < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(world.reads(of: "/Volumes/NAS/Docs") == 2)
    }

    /// Recent refreshes at every visit: only the new folder, and those found
    /// missing, are read again.
    @Test func aRefreshCanLeaveAnsweredFoldersUnread() throws {
        let world = World()
        let reader = world.reader()
        reader.refresh(urls("/Users/me/Work", "/net/server/export", "/Volumes/USB/gone"))
        _ = try #require(world.waitFor { $0.count == 3 })

        let shown = world.published.count
        reader.refresh(urls("/Users/me/New", "/Users/me/Work", "/net/server/export", "/Volumes/USB/gone"),
                       rereadingAnswered: false)
        let list = try #require(world.waitFor(skipping: shown) { $0.count == 4 })
        #expect(list[key("/Users/me/New")] == "icon")
        #expect(list[key("/Users/me/Work")] == "icon")
        #expect(world.reads(of: "/Users/me/New") == 1)
        #expect(world.reads(of: "/Users/me/Work") == 1)
        #expect(world.reads(of: "/Volumes/USB/gone") == 2)

        // A plain refresh reads them all again.
        reader.refresh(urls("/Users/me/New", "/Users/me/Work"))
        let deadline = Date(timeIntervalSinceNow: 5)
        while world.reads(of: "/Users/me/Work") < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(world.reads(of: "/Users/me/Work") == 2)
    }

    /// Gone means found missing by the answer as it stands, and not being
    /// read again: a list published before a new read can't say that.
    @Test func aFolderIsGoneOnlyWhileItsMissingAnswerStands() throws {
        let world = World()
        let reader = world.reader()
        let gone = key("/Volumes/USB/gone")
        reader.refresh(urls("/Volumes/USB/gone"))
        _ = try #require(world.waitFor { $0[gone] == "missing" })
        #expect(reader.isGone(gone))

        world.hang("/Volumes/USB/gone")
        reader.refresh(urls("/Volumes/USB/gone"), rereadingAnswered: false)
        let deadline = Date(timeIntervalSinceNow: 5)
        while !reader.isReading(gone), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(!reader.isGone(gone))
        world.answer("/Volumes/USB/gone")
        while reader.isReading(gone), Date() < deadline + 5 { Thread.sleep(forTimeInterval: 0.01) }
        #expect(reader.isGone(gone))
        #expect(!reader.isGone(key("/Users/me/never-asked")))
    }

    @Test func refusedAndMissingFoldersAreNeverRead() throws {
        let world = World()
        let reader = world.reader()
        reader.refresh(urls("/net/server/export", "/missing/disk/folder"))
        let list = try #require(world.waitFor { $0.count == 2 })
        #expect(list == [key("/net/server/export"): "refused", key("/missing/disk/folder"): "missing"])
        #expect(world.reads(of: "/net/server/export") == 0)
        #expect(world.reads(of: "/missing/disk/folder") == 0)
    }

    @Test func anUnpinnedFoldersLateAnswerIsDropped() throws {
        let world = World()
        world.hang("/Volumes/NAS/Docs")
        let reader = world.reader()
        reader.refresh(urls("/Users/me/Work", "/Volumes/NAS/Docs"))
        _ = try #require(world.waitFor { $0[key("/Users/me/Work")] != nil })
        reader.refresh(urls("/Users/me/Work"))
        let unpinned = try #require(world.waitFor(skipping: 1) { _ in true })
        #expect(unpinned == [key("/Users/me/Work"): "icon"])
        let shown = world.published.count
        world.answer("/Volumes/NAS/Docs")
        let deadline = Date(timeIntervalSinceNow: 5)
        while reader.isReading(key("/Volumes/NAS/Docs")), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        // A list the answer made would be published after its read stops
        // counting as reading: one more refresh's list comes after it.
        reader.refresh(urls("/Users/me/Work"))
        _ = try #require(world.waitFor(skipping: shown) { _ in true })
        Thread.sleep(forTimeInterval: 0.3)
        #expect(world.published.dropFirst(shown).allSatisfy { $0[key("/Volumes/NAS/Docs")] == nil })
    }
}
