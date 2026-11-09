import Foundation
import Testing
@testable import SelwayCore

#if canImport(Darwin)

/// Collects both kinds of watcher callback from the background callback queue.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var folderBatches: [[String]] = []
    private var entryBatches: [[String: Set<String>]] = []
    /// The real path reported with each folder's entries, by the folder's key.
    private var reportedRealPaths: [String: String] = [:]

    func folders(_ urls: [URL]) {
        lock.lock(); defer { lock.unlock() }
        folderBatches.append(urls.map(ShellPath.key).sorted())
    }
    func entries(_ changed: [ShellDirectoryWatcher.EntryChanges]) {
        lock.lock(); defer { lock.unlock() }
        var byKey: [String: Set<String>] = [:]
        for change in changed {
            byKey[ShellPath.key(change.folder), default: []].formUnion(change.names)
            reportedRealPaths[ShellPath.key(change.folder)] = change.realPath
        }
        entryBatches.append(byKey)
    }
    /// The real path last reported with `folder`'s entries.
    func realPath(of folder: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        return reportedRealPaths[ShellPath.key(folder)]
    }
    var folderKeys: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(folderBatches.flatMap { $0 }) }
    var entryBatchCount: Int { lock.lock(); defer { lock.unlock() }; return entryBatches.count }
    /// Every name reported changed in `folder`.
    func names(in folder: URL) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return entryBatches.reduce(into: Set<String>()) { $0.formUnion($1[ShellPath.key(folder)] ?? []) }
    }
    var entryKeys: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(entryBatches.flatMap(\.keys)) }
    func reset() { lock.lock(); folderBatches = []; entryBatches = []; reportedRealPaths = [:]; lock.unlock() }
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
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("ShellDirectoryWatcherFileEventsTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

private func realPath(_ url: URL) throws -> String {
    try #require(ModelPaths.realPath(url)).path
}

private func append(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

/// Files changed in place (FSEvents file events), on top of the folder watching
/// ShellDirectoryWatcherTests covers.
@Suite(.serialized) struct ShellDirectoryWatcherFileEventsTests {
    private let callbackQueue = DispatchQueue(label: "ShellDirectoryWatcherFileEventsTests.callbacks")

    private func makeWatcher(_ log: EventLog, throttle: TimeInterval = 0.05,
                             fileSystem: AutomountGuard.FileSystem = .live) -> ShellDirectoryWatcher {
        ShellDirectoryWatcher(throttle: throttle, eventLatency: 0.05, fileSystem: fileSystem,
                              callbackQueue: callbackQueue,
                              handler: { log.folders($0) }, entriesHandler: { log.entries($0) })
    }

    /// Retains `dir` and waits until its stream is running, then for anything
    /// FSEvents had from just before (the test's own setup) to pass.
    private func watch(_ dir: URL, with watcher: ShellDirectoryWatcher, log: EventLog) async throws {
        let path = try #require(ShellDirectoryWatcher.eventPath(for: dir))
        watcher.retain(dir)
        #expect(await waitUntil { watcher.eventPaths().contains(path) })
        try? await Task.sleep(nanoseconds: 300_000_000)
        log.reset()
    }

    @Test func appendingToAFileReportsItAsAnEntry() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("download.log")
        try Data("start".utf8).write(to: file)
        let log = EventLog()
        let watcher = makeWatcher(log)
        try await watch(dir, with: watcher, log: log)

        try append(" more", to: file)
        #expect(await waitUntil { log.names(in: dir) == ["download.log"] })
        // The folder's own listing didn't change: no whole-folder reload.
        #expect(!log.folderKeys.contains(ShellPath.key(dir)))
    }

    /// Tags live in an extended attribute: another app retagging a file changes
    /// nothing else about it.
    @Test func retaggingAFileReportsItAsAnEntry() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tagged.txt")
        try Data("x".utf8).write(to: file)
        let log = EventLog()
        let watcher = makeWatcher(log)
        try await watch(dir, with: watcher, log: log)

        let value = Array("v".utf8)
        #expect(setxattr(file.path, "studio.irq.selway.test", value, value.count, 0, 0) == 0)
        #expect(await waitUntil { log.names(in: dir) == ["tagged.txt"] })
    }

    @Test func changesBelowTheFolderAreIgnored() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let inner = sub.appendingPathComponent("inner.log")
        try Data("start".utf8).write(to: inner)
        let marker = dir.appendingPathComponent("marker.log")
        try Data("start".utf8).write(to: marker)
        let log = EventLog()
        let watcher = makeWatcher(log)
        try await watch(dir, with: watcher, log: log)

        try append(" more", to: inner)
        try append(" more", to: inner)
        // A change in the folder itself, after those: once it's reported, the
        // writes below would have been too, so their absence means something.
        try append(" more", to: marker)
        #expect(await waitUntil { log.names(in: dir).contains("marker.log") })
        #expect(!log.names(in: dir).contains("inner.log"))
        #expect(!log.entryKeys.contains(ShellPath.key(sub)))   // not watched itself
    }

    /// Where FSEvents dropped events, every watched folder at or below the path
    /// it names is reloaded whole; others aren't.
    @Test func droppedEventsReloadTheFoldersBelow() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("watched", isDirectory: true)
        let other = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = EventLog()
        let watcher = makeWatcher(log)
        watcher.retain(other)
        try await watch(dir, with: watcher, log: log)
        #expect(await waitUntil { watcher.eventPaths().count == 2 })
        log.reset()

        watcher.receiveFileEvents([(path: try realPath(base), mustRescan: true)])
        #expect(await waitUntil { log.folderKeys == [ShellPath.key(dir)] })

        log.reset()
        watcher.receiveFileEvents([(path: "/nowhere-watched", mustRescan: true),
                                   (path: try realPath(dir) + "/a.log", mustRescan: false)])
        #expect(await waitUntil { log.names(in: dir) == ["a.log"] })
        #expect(log.folderKeys.isEmpty)
    }

    /// realpath keeps /System/Volumes/Data on a folder opened that way, but
    /// FSEvents reports its firmlinked path (/private/var/...).
    @Test func aFolderOpenedThroughTheDataVolumeIsMatched() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = try realPath(dir)                                    // /private/var/folders/...
        let spelled = URL(fileURLWithPath: "/System/Volumes/Data" + real, isDirectory: true)
        try #require(FileManager.default.fileExists(atPath: spelled.path))
        #expect(ShellDirectoryWatcher.eventPath(for: spelled) == real)

        let file = dir.appendingPathComponent("a.log")
        try Data("start".utf8).write(to: file)
        let log = EventLog()
        let watcher = makeWatcher(log)
        try await watch(spelled, with: watcher, log: log)
        try append(" more", to: file)
        #expect(await waitUntil { log.names(in: spelled) == ["a.log"] })
    }

    /// A file written without pause is reported while it's written, but no
    /// more often than once per throttle interval.
    @Test func continuousWritesAreThrottled() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("busy.log")
        try Data().write(to: file)
        let log = EventLog()
        let throttle = 0.25
        let watcher = makeWatcher(log, throttle: throttle)
        try await watch(dir, with: watcher, log: log)

        let writing: TimeInterval = 1.5
        let start = Date()
        while Date().timeIntervalSince(start) < writing {
            try append("line\n", to: file)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 400_000_000)       // the last batch
        let batches = log.entryBatchCount
        #expect(batches >= 3, "only \(batches) updates while the file was written for \(writing) s")
        #expect(batches <= Int(writing / throttle) + 2, "\(batches) updates in \(writing) s")
        #expect(log.names(in: dir) == ["busy.log"])
    }

    @Test func symlinkedFolderReportsEntriesUnderItsLogicalPath() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("target", isDirectory: true)
        let link   = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let file = target.appendingPathComponent("a.log")
        try Data("start".utf8).write(to: file)
        let log = EventLog()
        let watcher = makeWatcher(log)
        try await watch(link, with: watcher, log: log)
        #expect(watcher.eventPaths() == [try realPath(target)])

        try append(" more", to: file)
        #expect(await waitUntil { log.entryKeys == [ShellPath.key(link)] })
        #expect(log.names(in: link) == ["a.log"])
        // Where Spotlight finds the file: search results there match it.
        #expect(log.realPath(of: link) == (try realPath(target)))
    }

    /// A stream FSEvents won't make is tried again, as a folder that can't be
    /// opened is, rather than left off until the folders watched change.
    @Test func aFailedStreamIsRetried() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = EventLog()
        let watcher = ShellDirectoryWatcher(throttle: 0.05, retryInterval: 0.1, eventLatency: 0.05,
                                            callbackQueue: callbackQueue,
                                            handler: { log.folders($0) }, entriesHandler: { log.entries($0) })
        watcher.simulateStreamFailures(2)
        let path = try #require(ShellDirectoryWatcher.eventPath(for: dir))
        watcher.retain(dir)
        #expect(await waitUntil { !watcher.armedKeys().isEmpty })
        #expect(watcher.eventPaths().isEmpty)
        #expect(await waitUntil { watcher.eventPaths() == [path] })
    }

    /// The stream covers the armed folders: one for each, gone when released.
    @Test func streamFollowsRetainAndRelease() async throws {
        let a = try makeTempDir(), b = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let log = EventLog()
        let watcher = makeWatcher(log)
        let realA = try realPath(a), realB = try realPath(b)
        watcher.retain(a)
        watcher.retain(b)
        #expect(await waitUntil { watcher.eventPaths() == [realA, realB] })
        watcher.release(a)
        #expect(await waitUntil { watcher.eventPaths() == [realB] })
        watcher.release(b)
        #expect(await waitUntil { watcher.eventPaths().isEmpty })
    }

    /// Without an entries handler, the watcher only watches folders, as before.
    @Test func noStreamWithoutAnEntriesHandler() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = ShellDirectoryWatcher(throttle: 0.05, callbackQueue: callbackQueue) { _ in }
        watcher.retain(dir)
        #expect(await waitUntil { !watcher.armedKeys().isEmpty })
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(watcher.eventPaths().isEmpty)
    }

    /// A folder below one AutomountGuard takes for autofs is watched for its
    /// entries only (its vnode), never through FSEvents.
    @Test func noStreamForAFolderTheGuardRefuses() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("share", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let autofs = try realPath(base)
        var fs = AutomountGuard.FileSystem.live
        let entry = fs.entry, type = fs.fileSystemType
        // As UITestHooks' autofs folder: a device of its own, and "autofs".
        fs.entry = { path in
            guard var e = entry(path) else { return nil }
            if path == autofs { e.device = ~e.device }
            return e
        }
        fs.fileSystemType = { $0 == autofs ? "autofs" : type($0) }
        #expect(ShellDirectoryWatcher.eventPath(for: dir) == (try realPath(dir)))
        #expect(ShellDirectoryWatcher.eventPath(for: dir, fileSystem: fs) == nil)

        let log = EventLog()
        let watcher = makeWatcher(log, fileSystem: fs)
        watcher.retain(dir)
        #expect(await waitUntil { !watcher.armedKeys().isEmpty })
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(watcher.eventPaths().isEmpty)
    }

    /// Paths under the automount folders aren't resolved or looked at.
    @Test(arguments: ["/net/host/export", "/home/someone", "/Network/Servers/host"])
    func automountPathsAreNeverLookedUp(_ path: String) {
        var looked: [String] = []
        let fs = AutomountGuard.FileSystem(
            entry: { looked.append($0); return nil },
            readLink: { looked.append($0); return nil },
            fileSystemType: { looked.append($0); return nil },
            realPath: { looked.append($0); return $0 })
        #expect(ShellDirectoryWatcher.eventPath(for: URL(fileURLWithPath: path, isDirectory: true),
                                                 fileSystem: fs) == nil)
        #expect(looked.isEmpty)
    }
}

#endif
