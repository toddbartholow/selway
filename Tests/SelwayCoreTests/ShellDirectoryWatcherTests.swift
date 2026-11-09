import Foundation
import Testing
@testable import SelwayCore

#if canImport(Darwin)

/// Collects watcher callbacks from the background callback queue.
private final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[String]] = []

    func record(_ urls: [URL]) {
        lock.lock(); defer { lock.unlock() }
        batches.append(urls.map(ShellPath.key).sorted())
    }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return batches }
    var keys: Set<String> { Set(all.flatMap { $0 }) }
    func reset() { lock.lock(); batches = []; lock.unlock() }
}

private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

private func makeTempDir() throws -> URL {
    // Note: resolvingSymlinksInPath gives the /var/… spelling (it drops a
    // leading /private); tests that care about /private/var spell it out.
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("ShellDirectoryWatcherTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

@Suite(.serialized) struct ShellDirectoryWatcherTests {
    private let callbackQueue = DispatchQueue(label: "ShellDirectoryWatcherTests.callbacks")

    @Test func reportsAddedAndRemovedEntries() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ChangeLog()
        let watcher = ShellDirectoryWatcher(throttle: 0.05, callbackQueue: callbackQueue) { log.record($0) }
        watcher.retain(dir)
        #expect(await waitUntil { watcher.armedKeys().contains(ShellPath.key(dir)) })

        let file = dir.appendingPathComponent("new.txt")
        try Data("x".utf8).write(to: file)
        #expect(await waitUntil { log.keys.contains(ShellPath.key(dir)) })

        log.reset()
        try FileManager.default.removeItem(at: file)
        #expect(await waitUntil { log.keys.contains(ShellPath.key(dir)) })
    }

    @Test func burstOfChangesIsCoalesced() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ChangeLog()
        let watcher = ShellDirectoryWatcher(throttle: 0.3, callbackQueue: callbackQueue) { log.record($0) }
        watcher.retain(dir)
        #expect(await waitUntil { !watcher.armedKeys().isEmpty })

        for i in 0..<20 {
            try Data().write(to: dir.appendingPathComponent("f\(i)"))
        }
        #expect(await waitUntil { !log.all.isEmpty })
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(log.all.count <= 2)   // 20 writes → one (at most two) reloads
    }

    @Test func symlinkedFolderReportsLogicalPath() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("target")
        let link   = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let log = ChangeLog()
        let watcher = ShellDirectoryWatcher(throttle: 0.05, callbackQueue: callbackQueue) { log.record($0) }
        watcher.retain(link)
        #expect(await waitUntil { watcher.armedKeys() == [ShellPath.key(link)] })

        try Data().write(to: target.appendingPathComponent("inside.txt"))
        #expect(await waitUntil { log.keys == [ShellPath.key(link)] })
    }

    @Test func deletedFolderIsReportedAndRearmedWhenRecreated() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let log = ChangeLog()
        let watcher = ShellDirectoryWatcher(throttle: 0.05, retryInterval: 0.1,
                                            callbackQueue: callbackQueue) { log.record($0) }
        watcher.retain(dir)
        let key = ShellPath.key(dir)
        #expect(await waitUntil { watcher.armedKeys().contains(key) })

        try FileManager.default.removeItem(at: dir)
        #expect(await waitUntil { log.keys.contains(key) })
        #expect(await waitUntil { !watcher.armedKeys().contains(key) })
        #expect(watcher.watchedKeys().contains(key))

        log.reset()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(await waitUntil { watcher.armedKeys().contains(key) })
        #expect(await waitUntil { log.keys.contains(key) })

        log.reset()
        try Data().write(to: dir.appendingPathComponent("again.txt"))
        #expect(await waitUntil { log.keys.contains(key) })
    }

    @Test func renamedFolderIsReported() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("before")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = ChangeLog()
        let watcher = ShellDirectoryWatcher(throttle: 0.05, callbackQueue: callbackQueue) { log.record($0) }
        watcher.retain(dir)
        #expect(await waitUntil { !watcher.armedKeys().isEmpty })

        try FileManager.default.moveItem(at: dir, to: base.appendingPathComponent("after"))
        #expect(await waitUntil { log.keys.contains(ShellPath.key(dir)) })
        #expect(await waitUntil { watcher.armedKeys().isEmpty })
    }

    /// /var is a symlink to /private/var. Keys used to depend on whether the
    /// folder existed ("/private" was stripped only then), so a folder deleted
    /// while watched could never be released and was retried forever.
    @Test(arguments: [false, true])
    func deletedFolderIsReleasedUnderEitherSpelling(privateSpelling: Bool) async throws {
        let tmp = FileManager.default.temporaryDirectory          // /var/folders/… on macOS
        let spelled = privateSpelling ? try #require(ModelPaths.realPath(tmp)) : tmp
        #expect(spelled.path.hasPrefix(privateSpelling ? "/private/var/" : "/var/"))
        let dir = spelled.appendingPathComponent("ShellDirectoryWatcherTests-\(UUID().uuidString)",
                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = ShellDirectoryWatcher(throttle: 0.05, retryInterval: 0.1,
                                            callbackQueue: callbackQueue) { _ in }
        watcher.retain(dir)
        #expect(await waitUntil { watcher.armedKeys().count == 1 })

        try FileManager.default.removeItem(at: dir)
        #expect(await waitUntil { watcher.armedKeys().isEmpty })
        watcher.release(dir)
        #expect(await waitUntil { watcher.watchedKeys().isEmpty })
    }

    /// Renaming a parent sends the watched folder's own vnode no event; the
    /// identity check on revalidate / flush must notice it.
    @Test func movedAncestorIsReportedOnRevalidate() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let child = base.appendingPathComponent("parent/child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let log = ChangeLog()
        let watcher = ShellDirectoryWatcher(throttle: 0.05, retryInterval: 30,
                                            callbackQueue: callbackQueue) { log.record($0) }
        watcher.retain(child)
        let key = ShellPath.key(child)
        #expect(await waitUntil { watcher.armedKeys() == [key] })

        try FileManager.default.moveItem(at: base.appendingPathComponent("parent"),
                                         to: base.appendingPathComponent("moved"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(log.all.isEmpty)                  // kqueue said nothing
        #expect(watcher.armedKeys() == [key])

        watcher.revalidate()
        #expect(await waitUntil { log.keys == [key] })
        #expect(watcher.armedKeys().isEmpty)
        #expect(watcher.watchedKeys() == [key])
    }

    /// A change in any watched folder re-checks the others, so a column showing
    /// the parent is enough to notice its child folder being moved away.
    @Test func movedAncestorIsReportedWhenAnotherWatchFlushes() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let child = base.appendingPathComponent("parent/child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let log = ChangeLog()
        let watcher = ShellDirectoryWatcher(throttle: 0.05, retryInterval: 30,
                                            callbackQueue: callbackQueue) { log.record($0) }
        watcher.retain(base)
        watcher.retain(child)
        #expect(await waitUntil { watcher.armedKeys().count == 2 })

        try FileManager.default.moveItem(at: base.appendingPathComponent("parent"),
                                         to: base.appendingPathComponent("moved"))
        #expect(await waitUntil { log.keys == [ShellPath.key(base), ShellPath.key(child)] })
        #expect(watcher.armedKeys() == [ShellPath.key(base)])
    }

    /// A FIFO that takes a watched folder's name must not be opened (a blocking
    /// open would stall the watcher's queue and stop auto-refresh app-wide).
    @Test func fifoReplacingFolderDoesNotBlockTheWatcher() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("watched", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let log = ChangeLog()
        let watcher = ShellDirectoryWatcher(throttle: 0.05, retryInterval: 0.05,
                                            callbackQueue: callbackQueue) { log.record($0) }
        watcher.retain(dir)
        let key = ShellPath.key(dir)
        #expect(await waitUntil { watcher.armedKeys() == [key] })

        try FileManager.default.removeItem(at: dir)
        #expect(mkfifo(dir.path, 0o600) == 0)
        try? await Task.sleep(nanoseconds: 300_000_000)    // several retries hit the FIFO

        // The queue must still answer (armedKeys is a queue.sync); probe it off
        // the test's thread so a stall fails the test instead of hanging it.
        let answered = ChangeLog()
        Thread.detachNewThread { answered.record(watcher.armedKeys().map { URL(fileURLWithPath: $0) }) }
        let alive = await waitUntil(timeout: 2) { !answered.all.isEmpty }
        #expect(alive, "watcher queue is blocked")
        guard alive else { return }        // anything else would hang on the queue too
        #expect(answered.all.first == [])

        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(await waitUntil { watcher.armedKeys() == [key] })
    }

    @Test func retainIsReferenceCounted() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ChangeLog()
        let watcher = ShellDirectoryWatcher(throttle: 0.05, callbackQueue: callbackQueue) { log.record($0) }
        // Same folder spelled two ways shares one watch.
        watcher.retain(dir)
        watcher.retain(URL(fileURLWithPath: dir.path + "/", isDirectory: true))
        #expect(await waitUntil { watcher.armedKeys().count == 1 })

        watcher.release(dir)
        #expect(await waitUntil { watcher.watchedKeys().count == 1 })
        // Still watched after the first release: changes keep being reported.
        try Data().write(to: dir.appendingPathComponent("still-watched.txt"))
        #expect(await waitUntil { log.keys.contains(ShellPath.key(dir)) })
        #expect(watcher.armedKeys().count == 1)

        watcher.release(dir)
        #expect(await waitUntil { watcher.watchedKeys().isEmpty })
        log.reset()

        try Data().write(to: dir.appendingPathComponent("ignored.txt"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(log.all.isEmpty)
    }
}

#endif
