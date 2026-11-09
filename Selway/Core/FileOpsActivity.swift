import Foundation

/// Every file operation running anywhere in the app, across all windows.
///
/// Quitting (⌘Q, logout, or Sparkle's Install and Relaunch) must not cut a copy
/// off half-way, and closing a window doesn't stop the operation it started.
/// The app asks this tracker what is still running, can cancel everything,
/// and waits for `whenIdle` before it terminates. Each operation also holds a
/// system activity (no idle sleep, no sudden or automatic termination) while
/// it runs.
///
/// Thread-safe; `whenIdle` handlers run on the thread that ends the last
/// operation (the main thread in the app).
final class FileOpsActivityTracker: @unchecked Sendable {

    static let shared = FileOpsActivityTracker()

    typealias BeginActivity = (_ reason: String) -> AnyObject?
    typealias EndActivity = (AnyObject) -> Void

    private struct Running {
        let title: String
        let token: FileOpsCancellationToken
        let activity: AnyObject?
    }

    private let lock = NSLock()
    private var running: [UUID: Running] = [:]
    private var order: [UUID] = []
    private var idleHandlers: [() -> Void] = []
    private let beginActivity: BeginActivity
    private let endActivity: EndActivity

    init(beginActivity: @escaping BeginActivity = FileOpsActivityTracker.systemBeginActivity,
         endActivity: @escaping EndActivity = FileOpsActivityTracker.systemEndActivity) {
        self.beginActivity = beginActivity
        self.endActivity = endActivity
    }

    /// Registers a running operation; pass the result to `end` when it is done.
    func begin(_ title: String, token: FileOpsCancellationToken) -> UUID {
        let id = UUID()
        let activity = beginActivity("Selway: \(title)")
        lock.lock()
        running[id] = Running(title: title, token: token, activity: activity)
        order.append(id)
        lock.unlock()
        return id
    }

    /// Marks an operation finished. When it was the last one, the pending
    /// `whenIdle` handlers run (in the order they were added).
    func end(_ id: UUID) {
        lock.lock()
        let entry = running.removeValue(forKey: id)
        order.removeAll { $0 == id }
        var handlers: [() -> Void] = []
        if running.isEmpty {
            handlers = idleHandlers
            idleHandlers = []
        }
        lock.unlock()
        if let activity = entry?.activity { endActivity(activity) }
        handlers.forEach { $0() }
    }

    var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return running.isEmpty
    }

    /// Titles of the running operations, oldest first.
    var runningTitles: [String] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { running[$0]?.title }
    }

    /// Asks every running operation to stop (each stops after its current
    /// item, or kills its tool, and removes any partial output).
    func cancelAll() {
        lock.lock()
        let tokens = running.values.map(\.token)
        lock.unlock()
        tokens.forEach { $0.cancel() }
    }

    /// Runs `handler` once nothing is running: right away if already idle,
    /// otherwise when the last running operation ends.
    func whenIdle(_ handler: @escaping () -> Void) {
        lock.lock()
        if running.isEmpty {
            lock.unlock()
            handler()
            return
        }
        idleHandlers.append(handler)
        lock.unlock()
    }

    // MARK: System activity

    static func systemBeginActivity(_ reason: String) -> AnyObject? {
        #if canImport(Darwin)
        // .userInitiated: no idle system sleep, no sudden or automatic termination.
        return ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: reason) as AnyObject
        #else
        return nil
        #endif
    }

    static func systemEndActivity(_ activity: AnyObject) {
        #if canImport(Darwin)
        if let activity = activity as? NSObjectProtocol {
            ProcessInfo.processInfo.endActivity(activity)
        }
        #endif
    }
}

// MARK: - Quit while operations run

/// The order of events when the app is asked to quit while file operations run.
///
/// 1. Note how many errors have been reported so far, then ask Wait / Stop / Don't Quit
///    (synchronously, as `runModal` does). The count is taken *before* asking: the main
///    queue keeps running under a modal alert, so an operation can fail and finish while
///    the question is on screen, and its error must still keep the app open.
/// 2. Don't Quit → cancel. Stop → cancel every operation. Either way, reply "later".
/// 3. Once nothing runs, decide exactly once: stay open if any error was reported since
///    step 1, otherwise go on quitting.
///
/// `isBusy` is true from step 1 until the decision; a quit request meanwhile is refused
/// (`.cancel`), so a second alert and a second reply can't happen. `isWaiting` is true
/// from step 2 until the decision; anything that can start a quit (Sparkle's Install and
/// Relaunch, via UpdaterPolicy) checks it first.
final class FileOpsQuitReview {
    enum Choice: Equatable { case wait, stop, dontQuit }
    enum Reply: Equatable {
        /// Nothing is running: carry on with the rest of the quit review now.
        case proceed
        case cancel
        /// `finish` is called later, exactly once.
        case later
    }

    private(set) var isBusy = false
    private(set) var isWaiting = false

    /// `schedule` must run its block after this call has returned (on the main run loop in
    /// the app). `finish(true)` means an error was reported while asking or waiting, so the
    /// app should stay open.
    func shouldTerminate(tracker: FileOpsActivityTracker,
                         errorCount: @escaping () -> Int,
                         ask: ([String]) -> Choice,
                         schedule: @escaping (@escaping () -> Void) -> Void,
                         finish: @escaping (_ errorsWhileWaiting: Bool) -> Void) -> Reply {
        guard !isBusy else { return .cancel }
        let titles = tracker.runningTitles
        guard !titles.isEmpty else { return .proceed }
        isBusy = true
        let errorsBefore = errorCount()
        switch ask(titles) {
        case .dontQuit:
            isBusy = false
            return .cancel
        case .stop:
            tracker.cancelAll()
        case .wait:
            break
        }
        isWaiting = true
        tracker.whenIdle {
            schedule { [self] in
                guard isWaiting else { return }
                isWaiting = false
                isBusy = false
                finish(errorCount() != errorsBefore)
            }
        }
        return .later
    }
}
