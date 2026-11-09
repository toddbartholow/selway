import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

// kqueue vnode sources (O_EVTONLY, DispatchSource file-system objects) and
// FSEvents are Darwin-only; the app is macOS-only, so Linux CI just skips the watcher.
#if canImport(Darwin)

/// Watches folders for entries being added, removed or renamed (and, with an
/// `entriesHandler`, files in them changed in place), and reports the changed
/// folders (by the logical URL they were registered with) at most once per
/// `throttle` interval.
///
/// Each watched folder holds one kqueue vnode source on an `O_EVTONLY` file
/// descriptor (it never blocks unmounting). Callers `retain` / `release` folders,
/// so several views showing the same folder share one descriptor.
///
/// - Symlinks: the descriptor is opened on the resolved path, but changes are
///   reported under the logical URL the caller registered.
/// - Deleted / renamed folder: the source is torn down (its vnode is gone), the
///   change is reported so the UI can react, and the watcher keeps retrying the
///   logical path every `retryInterval` so a folder recreated in place (git
///   checkout, atomic save of a directory) is picked up again.
/// - Moved / deleted ancestor: the folder's own vnode gets no event when a
///   parent is renamed, so armed watches are re-checked (the descriptor's
///   device / inode against the logical path's) on every flush and retry, and
///   whenever `revalidate()` is called (the app does when a window becomes key).
/// - Files changed in place: a file growing inside a folder doesn't change the
///   folder's vnode. With an `entriesHandler`, one FSEvents stream with file
///   events covers every armed folder, and the entries written to (or retagged)
///   directly inside one are reported with the folder, by name, in the same
///   throttled batches (ShellWatchChanges); changes further down are ignored.
///   A folder under /net, /home or /Network, or whose real path AutomountGuard
///   refuses, gets no stream: only its vnode is watched.
final class ShellDirectoryWatcher {
    typealias Handler = (_ changed: [URL]) -> Void
    /// Entries changed in place, by name, one batch per folder.
    typealias EntriesHandler = (_ changed: [EntryChanges]) -> Void

    /// Entries changed in place in one watched folder.
    struct EntryChanges: Equatable {
        /// The folder's logical URL, as it was retained.
        let folder: URL
        /// The folder's real path, as FSEvents reports it (`eventPath`): where
        /// Spotlight finds its files when the folder is reached through a link.
        let realPath: String
        let names: Set<String>
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode:  ino_t
    }

    private struct Watch {
        var logical: URL
        var count: Int
        var source: DispatchSourceFileSystemObject?
        /// The folder the descriptor was opened on.
        var identity: Identity?
        /// The folder's real path (`realpath`, as FSEvents reports paths) while
        /// armed, when it may be in the file-event stream.
        var eventPath: String?
    }

    private let queue = DispatchQueue(label: "studio.irq.selway.ShellDirectoryWatcher")
    private let throttle: TimeInterval
    private let retryInterval: TimeInterval
    private let callbackQueue: DispatchQueue
    private let handler: Handler
    private let entriesHandler: EntriesHandler?
    /// How long FSEvents holds file events back to batch them, on top of `throttle`.
    private let eventLatency: TimeInterval
    /// What AutomountGuard's walk of a folder's real path uses (the tests swap it).
    private let fileSystem: AutomountGuard.FileSystem

    // All state below is confined to `queue`.
    private var watches: [String: Watch] = [:]     // keyed by ShellPath.key
    private var pending = ShellWatchChanges()
    private var flushScheduled = false
    private var retryScheduled = false
    private var events: EventStream?
    /// The keys of the watches the stream covers, by `eventPath`.
    private var keysByEventPath: [String: [String]] = [:]
    private var streamUpdateScheduled = false
    /// The stream couldn't be made for the folders watched: tried again with the retries.
    private var streamFailed = false
    /// Stream builds still to fail on purpose (tests).
    private var streamFailuresToSimulate = 0

    /// `entriesHandler` turns on reporting files changed in place (nil: only
    /// folders are reported, and no FSEvents stream is made).
    init(throttle: TimeInterval = 0.4,
         retryInterval: TimeInterval = 2.0,
         eventLatency: TimeInterval = 0.1,
         fileSystem: AutomountGuard.FileSystem = .live,
         callbackQueue: DispatchQueue = .main,
         handler: @escaping Handler,
         entriesHandler: EntriesHandler? = nil) {
        self.throttle       = throttle
        self.retryInterval  = retryInterval
        self.eventLatency   = eventLatency
        self.fileSystem     = fileSystem
        self.callbackQueue  = callbackQueue
        self.handler        = handler
        self.entriesHandler = entriesHandler
    }

    deinit {
        // Sources capture `self` weakly; cancelling closes their descriptors.
        for watch in watches.values { watch.source?.cancel() }
        events?.stop()
    }

    // MARK: Public API (any thread)

    func retain(_ url: URL) {
        let key = ShellPath.key(url)
        queue.async {
            if var watch = self.watches[key] {
                watch.count += 1
                self.watches[key] = watch
                return
            }
            self.watches[key] = Watch(logical: url, count: 1, source: nil, identity: nil)
            if !self.arm(key) { self.scheduleRetry() }
        }
    }

    func release(_ url: URL) {
        let key = ShellPath.key(url)
        queue.async {
            guard var watch = self.watches[key] else { return }
            watch.count -= 1
            if watch.count > 0 {
                self.watches[key] = watch
                return
            }
            watch.source?.cancel()
            self.watches[key] = nil
            self.pending.remove(key)
            if watch.eventPath != nil { self.scheduleStreamUpdate() }
        }
    }

    /// Re-checks that every armed folder is still at its logical path and
    /// reports the ones that were moved or deleted along with an ancestor.
    func revalidate() {
        queue.async {
            if self.invalidateMoved() { self.scheduleFlush() }
        }
    }

    /// Keys with an open descriptor (for tests and diagnostics).
    func armedKeys() -> Set<String> {
        queue.sync { Set(watches.filter { $0.value.source != nil }.keys) }
    }

    /// Keys being watched, armed or not (for tests and diagnostics).
    func watchedKeys() -> Set<String> {
        queue.sync { Set(watches.keys) }
    }

    /// The real paths the file-event stream covers (for tests and diagnostics).
    func eventPaths() -> Set<String> {
        queue.sync { Set(events?.paths ?? []) }
    }

    // MARK: Internals (on `queue`)

    /// Opens a source for `key`. Returns false when the folder can't be opened
    /// (missing, no permission, or no longer a folder); the caller schedules a
    /// retry.
    @discardableResult
    private func arm(_ key: String) -> Bool {
        guard var watch = watches[key], watch.source == nil else { return true }
        let resolved = watch.logical.resolvingSymlinksInPath().path
        // O_DIRECTORY: a file or FIFO that took the folder's name fails with
        // ENOTDIR (treated as missing) instead of being watched. O_NONBLOCK:
        // opening a FIFO would otherwise block this serial queue for good.
        let fd = open(resolved, O_EVTONLY | O_NONBLOCK | O_DIRECTORY)
        guard fd >= 0 else { return false }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            close(fd)
            return false
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self, unowned source] in
            self?.handleEvent(key: key, flags: source.data, from: source)
        }
        source.setCancelHandler { close(fd) }
        watch.source = source
        watch.identity = Identity(device: st.st_dev, inode: st.st_ino)
        watch.eventPath = entriesHandler == nil ? nil : Self.eventPath(for: watch.logical, fileSystem: fileSystem)
        watches[key] = watch
        source.resume()
        if watch.eventPath != nil { scheduleStreamUpdate() }
        return true
    }

    /// The real path to watch `logical` under in the file-event stream, or nil
    /// when it mustn't be: a path under the automount folders is refused on its
    /// spelling alone, before anything is looked up, and the real path must pass
    /// AutomountGuard's walk. `realpath` runs on `logical` before that walk, but
    /// adds nothing new: `arm` has just opened the same path, so whatever it
    /// would mount is mounted already.
    ///
    /// FSEvents reports a folder on the Data volume by its firmlinked path
    /// (/private/tmp/x, /Users/me), while a folder opened through
    /// /System/Volumes/Data keeps that prefix through `realpath`. The shorter
    /// path is used when it passes the guard too and is the same folder.
    static func eventPath(for logical: URL, fileSystem fs: AutomountGuard.FileSystem = .live) -> String? {
        guard !AutomountPaths.contains(logical.path),
              let real = fs.realPath(logical.path),
              AutomountGuard.check(real, fileSystem: fs) == .safe else { return nil }
        let dataVolume = "/System/Volumes/Data"
        guard real.hasPrefix(dataVolume + "/") else { return real }
        let short = String(real.dropFirst(dataVolume.count))
        guard AutomountGuard.check(short, fileSystem: fs) == .safe else { return real }
        var a = stat(), b = stat()
        guard stat(real, &a) == 0, stat(short, &b) == 0,
              a.st_dev == b.st_dev, a.st_ino == b.st_ino else { return real }
        return short
    }

    private func handleEvent(key: String,
                             flags: DispatchSource.FileSystemEvent,
                             from source: DispatchSourceFileSystemObject) {
        guard let watch = watches[key], watch.source === source else { return }
        if !flags.isDisjoint(with: [.delete, .rename, .revoke]) {
            // The folder itself went away or moved: this descriptor now follows
            // the old vnode, so drop it and re-resolve the logical path later.
            disarm(key)
        }
        pending.folderChanged(key)
        scheduleFlush()
    }

    private func disarm(_ key: String) {
        guard var watch = watches[key] else { return }
        let hadEvents = watch.eventPath != nil
        watch.source?.cancel()
        watch.source = nil
        watch.identity = nil
        watch.eventPath = nil
        watches[key] = watch
        scheduleRetry()
        if hadEvents { scheduleStreamUpdate() }
    }

    /// True when the folder at `watch.logical` is the one the descriptor is
    /// open on. False when the path is gone or now names something else, e.g.
    /// after an ancestor was renamed, which sends the folder itself no event.
    private func isStillInPlace(_ watch: Watch) -> Bool {
        guard let identity = watch.identity else { return true }
        var st = stat()
        guard stat(watch.logical.path, &st) == 0 else { return false }
        return Identity(device: st.st_dev, inode: st.st_ino) == identity
    }

    /// Disarms and marks pending every armed watch that is no longer in place.
    /// Returns true when it found any.
    @discardableResult
    private func invalidateMoved() -> Bool {
        let moved = watches.filter { $0.value.source != nil && !isStillInPlace($0.value) }.keys
        for key in moved {
            disarm(key)
            pending.folderChanged(key)
        }
        return !moved.isEmpty
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + throttle) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        // Something changed on disk; a rename further up the tree may have
        // taken other watched folders with it.
        invalidateMoved()
        let batch = pending.take()
        let changed = batch.folders.compactMap { watches[$0]?.logical }
        let entries = batch.entries.compactMap { key, names -> EntryChanges? in
            // Only folders in the stream (with an `eventPath`) have entries.
            guard let watch = watches[key], let real = watch.eventPath else { return nil }
            return EntryChanges(folder: watch.logical, realPath: real, names: names)
        }
        if !changed.isEmpty {
            let handler = self.handler
            callbackQueue.async { handler(changed) }
        }
        if !entries.isEmpty, let entriesHandler {
            callbackQueue.async { entriesHandler(entries) }
        }
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + retryInterval) { [weak self] in self?.retryUnarmed() }
    }

    private func retryUnarmed() {
        retryScheduled = false
        if streamFailed {
            streamFailed = false
            scheduleStreamUpdate()
        }
        if invalidateMoved() { scheduleFlush() }
        var stillMissing = false
        for (key, watch) in watches where watch.source == nil {
            if arm(key) {
                // Reappeared: its contents may differ from what was last shown.
                pending.folderChanged(key)
                scheduleFlush()
            } else {
                stillMissing = true
            }
        }
        if stillMissing { scheduleRetry() }
    }

    // MARK: File events (on `queue`)

    /// Brings the stream in line with the armed folders, once for any number
    /// of changes queued before it runs (a column showing another folder
    /// releases one and retains the other).
    private func scheduleStreamUpdate() {
        guard entriesHandler != nil, !streamUpdateScheduled else { return }
        streamUpdateScheduled = true
        queue.async { [weak self] in self?.updateStream() }
    }

    private func updateStream() {
        streamUpdateScheduled = false
        var byPath: [String: [String]] = [:]
        for (key, watch) in watches {
            if let path = watch.eventPath { byPath[path, default: []].append(key) }
        }
        keysByEventPath = byPath
        let paths = byPath.keys.sorted()
        guard paths != events?.paths else { return }
        // The new stream starts before the old one stops, so folders that stay
        // watched lose no events: the old one delivers what it holds (up to
        // `eventLatency` old) before it's stopped. Events both report are
        // reported twice, which ShellWatchChanges takes as once.
        if let old = events {
            old.flush()
            queue.asyncAfter(deadline: .now() + eventLatency * 2 + 0.1) { old.stop() }
        }
        events = nil
        streamFailed = false
        guard !paths.isEmpty else { return }
        if streamFailuresToSimulate > 0 {
            streamFailuresToSimulate -= 1
        } else {
            events = EventStream(paths: paths, latency: eventLatency, queue: queue) { [weak self] events in
                self?.handleFileEvents(events)
            }
        }
        if events == nil {
            // FSEvents refused it: in-place changes would go unseen until the
            // folders watched changed. Try again with the folders' retries.
            streamFailed = true
            scheduleRetry()
        }
    }

    /// Makes the next `count` stream builds fail, as FSEvents can (for tests).
    func simulateStreamFailures(_ count: Int) {
        queue.sync { streamFailuresToSimulate = count }
    }

    /// Feeds file events to the watcher as if FSEvents had sent them (for tests:
    /// FSEvents can't be made to drop events on purpose).
    func receiveFileEvents(_ events: [(path: String, mustRescan: Bool)]) {
        queue.async {
            self.handleFileEvents(events.map { EventStream.Event(path: $0.path, mustRescan: $0.mustRescan) })
        }
    }

    /// Entries changed directly inside a watched folder are pending for it; the
    /// folder's own events and anything deeper are left out. Where FSEvents lost
    /// events (`mustRescan`), every folder at or below the path is reloaded whole.
    private func handleFileEvents(_ events: [EventStream.Event]) {
        var changed = false
        for event in events {
            if event.mustRescan {
                for (path, keys) in keysByEventPath where ShellEventPath.isSameOrInside(path, event.path) {
                    for key in keys where watches[key] != nil { pending.folderChanged(key) }
                    changed = true
                }
            }
            guard let (folder, name) = ShellEventPath.split(event.path),
                  let keys = keysByEventPath[folder] else { continue }
            for key in keys where watches[key]?.eventPath == folder {
                pending.entryChanged(name, in: key)
                changed = true
            }
        }
        if changed { scheduleFlush() }
    }
}

// MARK: - FSEvents stream

/// One FSEvents stream with file-level events (`kFSEventStreamCreateFlagFileEvents`)
/// over `paths`, delivering on `queue`. Paths in events are real paths.
private final class EventStream {
    struct Event {
        let path: String
        /// FSEvents dropped events at or below `path`: whatever it covers must be read again.
        let mustRescan: Bool
    }

    /// The callback's target. The stream retains it (the context's retain and
    /// release) for as long as it may call back, past `stop` if need be.
    private final class Target {
        let handler: ([Event]) -> Void
        /// The stream's folders: only events directly inside one are passed on.
        let folders: ShellEventFolders
        init(_ handler: @escaping ([Event]) -> Void, folders: ShellEventFolders) {
            self.handler = handler
            self.folders = folders
        }
    }

    let paths: [String]
    private let target: Target
    private var stream: FSEventStreamRef?

    init?(paths: [String], latency: TimeInterval, queue: DispatchQueue,
          handler: @escaping ([Event]) -> Void) {
        self.paths = paths
        target = Target(handler, folders: ShellEventFolders(paths))
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(target).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Target>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Target>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, Self.callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency, flags) else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    /// Asks FSEvents to deliver the events it's holding back now (on the queue).
    func flush() {
        if let stream { FSEventStreamFlushAsync(stream) }
    }

    /// Stops the stream. A batch FSEvents had already handed to the queue may
    /// still be delivered; the watcher's handler takes it like any other.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private static let rescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped)

    /// Passes on the events the watcher can use: those directly inside one of
    /// the stream's folders, and dropped-event notices. The rest (most of them,
    /// from a stream over "/") are turned away on their bytes, read in place
    /// where CFString holds them as UTF-8, so they cost no String.
    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let target = Unmanaged<Target>.fromOpaque(info).takeUnretainedValue()
        let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        var events: [Event] = []
        for i in 0..<min(count, CFArrayGetCount(paths)) {
            let path = unsafeBitCast(CFArrayGetValueAtIndex(paths, i), to: CFString.self)
            let mustRescan = eventFlags[i] & rescanFlags != 0
            if !mustRescan {
                let wanted: Bool
                if let bytes = CFStringGetCStringPtr(path, CFStringBuiltInEncodings.UTF8.rawValue) {
                    let length = strlen(bytes)
                    wanted = bytes.withMemoryRebound(to: UInt8.self, capacity: length) {
                        target.folders.holdsEntry(UnsafeBufferPointer(start: $0, count: length))
                    }
                } else {
                    wanted = target.folders.holdsEntry(path as String)
                }
                guard wanted else { continue }
            }
            events.append(Event(path: path as String, mustRescan: mustRescan))
        }
        if !events.isEmpty { target.handler(events) }
    }
}

#endif
