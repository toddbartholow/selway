import Foundation

/// What the sidebar knows of a pinned folder.
enum PinnedFolderAnswer<Info> {
    /// `AutomountGuard` refused it: under `/net`, `/home` or `/Network`,
    /// where looking at it would mount it. Shown as there, unlooked at.
    case refused
    /// Not there: on a volume not mounted, or gone.
    case missing
    /// There, with what the app read of it (its icon).
    case present(Info)

    var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }
}

/// Reads the pinned folders off the main thread, as SidebarVolumeReader
/// reads the volumes: a folder on a share that has stopped answering can
/// take minutes to look up, and its row must never look at it on the main
/// thread meanwhile.
///
/// Each read:
/// - checks each folder with `AutomountGuard` and then reads it, on a thread
///   of its own, unless a read of that folder hasn't answered yet: that one
///   is read again once it does, so a folder that has stopped answering
///   has one read waiting on it, never a pile of them;
/// - waits up to `grace` for the reads it started, so folders that answer
///   at once are in the first answers published;
/// - publishes each folder's last answer (none for one that hasn't
///   answered yet). A read that answers later publishes again.
///
/// For the Swift 6 language mode, the hooks, `deliver` and `publish` would
/// need to be `@Sendable` (the state is guarded by `condition`, hence
/// `@unchecked`).
final class PinnedFolderReader<Info>: @unchecked Sendable {
    /// What the reader asks of the system; the tests give fakes.
    struct Hooks {
        var check: (String) -> AutomountGuard.Verdict = { AutomountGuard.check($0) }
        /// Reads a folder the guard let through; nil when it isn't there.
        /// May take minutes.
        var read: (URL) -> Info?
        /// Runs a folder's read on a thread of its own. Not a dispatch queue:
        /// a read stuck in the kernel would hold one of its few threads.
        var start: (@escaping () -> Void) -> Void = { read in
            let thread = Thread(block: read)
            thread.name = "studio.irq.selway.pinned-read"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    let grace: TimeInterval
    private let hooks: Hooks
    /// Hands the answers to `publish`'s caller (the main queue in the app).
    /// Answers made before ones already handed over are dropped.
    private let deliver: (@escaping () -> Void) -> Void
    private let publish: ([String: PinnedFolderAnswer<Info>]) -> Void
    private let queue = DispatchQueue(label: "studio.irq.selway.pinned-reads", qos: .userInitiated)

    /// Guards everything below; reads that answer signal it.
    private let condition = NSCondition()
    /// The folders pinned now, by ShellPath.key.
    private var pinned: [String: URL] = [:]
    /// Their last answers.
    private var answers: [String: PinnedFolderAnswer<Info>] = [:]
    /// Folders with a read that hasn't answered, pinned now or not.
    private var reading: Set<String> = []
    /// Folders a refresh asked for while they were being read.
    private var readAgain: Set<String> = []
    /// The reads a refresh is waiting on, during its `grace`.
    private var awaited: Set<String> = []
    /// The folders the next read is for; a refresh asked for while one is
    /// waiting to start is the same read.
    private var latest: [URL] = []
    /// Whether the next read is for every folder, or only those without an
    /// answer (or found missing): a refresh asking for all of them wins.
    private var latestRereads = true
    private var queued = false
    private var made = 0
    private var delivered = 0

    init(hooks: Hooks, grace: TimeInterval = 0.3,
         deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         publish: @escaping ([String: PinnedFolderAnswer<Info>]) -> Void) {
        self.hooks = hooks
        self.grace = grace
        self.deliver = deliver
        self.publish = publish
    }

    /// Reads `urls`, the folders pinned now, again in the background. With
    /// `rereadingAnswered` false, a folder already answered as there (or
    /// refused) keeps its answer, and its icon, unread: only new folders and
    /// those found missing are read.
    func refresh(_ urls: [URL], rereadingAnswered: Bool = true) {
        condition.lock()
        defer { condition.unlock() }
        latest = urls
        latestRereads = queued ? latestRereads || rereadingAnswered : rereadingAnswered
        guard !queued else { return }
        queued = true
        queue.async { [self] in
            condition.lock()
            queued = false
            let urls = latest
            let rereads = latestRereads
            condition.unlock()
            read(urls, rereadingAnswered: rereads)
        }
    }

    /// Whether the folder `key` (ShellPath.key) was last found missing and
    /// isn't being read again: the answer as it stands now, which a published
    /// list made earlier may not show yet.
    func isGone(_ key: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return answers[key]?.isMissing == true && !reading.contains(key)
    }

    /// Whether a read of the folder `key` (ShellPath.key) hasn't answered.
    func isReading(_ key: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return reading.contains(key)
    }

    /// A folder's answer, read from the file system: the guard's verdict,
    /// then a read of a folder it lets through.
    static func answer(for url: URL, check: (String) -> AutomountGuard.Verdict,
                       read: (URL) -> Info?) -> PinnedFolderAnswer<Info> {
        switch check(url.path) {
        case .refused: return .refused
        case .missing: return .missing
        case .safe:    return read(url).map { .present($0) } ?? .missing
        }
    }

    private func read(_ urls: [URL], rereadingAnswered: Bool) {
        condition.lock()
        pinned = Dictionary(urls.map { (ShellPath.key($0), $0) }, uniquingKeysWith: { first, _ in first })
        answers = answers.filter { pinned[$0.key] != nil }
        var started: [(key: String, url: URL)] = []
        for (key, url) in pinned {
            if !rereadingAnswered, let answer = answers[key], !answer.isMissing {
                continue
            } else if reading.contains(key) {
                readAgain.insert(key)
            } else {
                reading.insert(key)
                started.append((key, url))
            }
        }
        awaited = Set(started.map(\.key))
        condition.unlock()

        for folder in started { startRead(folder.key, folder.url) }

        condition.lock()
        let deadline = Date(timeIntervalSinceNow: grace)
        while !awaited.isDisjoint(with: reading), condition.wait(until: deadline) {}
        awaited = []
        let list = madeList()
        condition.unlock()
        list()
    }

    private func startRead(_ key: String, _ url: URL) {
        hooks.start { [self] in
            answered(key, Self.answer(for: url, check: hooks.check, read: hooks.read))
        }
    }

    private func answered(_ key: String, _ answer: PinnedFolderAnswer<Info>) {
        condition.lock()
        reading.remove(key)
        // Unpinned meanwhile: dropped.
        let isPinned = pinned[key] != nil
        if isPinned { answers[key] = answer }
        let waitedFor = awaited.contains(key)
        condition.broadcast()
        // The refresh waiting on it publishes it.
        let list = isPinned && !waitedFor ? madeList() : nil
        let again = readAgain.remove(key) != nil ? pinned[key] : nil
        if again != nil { reading.insert(key) }
        condition.unlock()
        list?()
        if let again { startRead(key, again) }
    }

    /// The answers as they stand, numbered, and the work that hands them
    /// over. Called with the lock held; the work runs after it's released.
    private func madeList() -> () -> Void {
        let snapshot = answers
        made += 1
        let number = made
        return { [self] in
            deliver { [self] in
                condition.lock()
                let isNewest = number > delivered
                if isNewest { delivered = number }
                condition.unlock()
                if isNewest { publish(snapshot) }
            }
        }
    }
}
