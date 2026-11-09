import Foundation
import Testing
@testable import SelwayCore

/// Records system activities instead of starting real ones.
private final class ActivityLog {
    var begun: [String] = []
    var ended = 0
    func tracker() -> FileOpsActivityTracker {
        FileOpsActivityTracker(beginActivity: { reason in self.begun.append(reason); return NSObject() },
                               endActivity: { _ in self.ended += 1 })
    }
}

@Test func fileOpsTrackerHoldsAnActivityPerOperation() {
    let log = ActivityLog(), tracker = log.tracker()
    #expect(tracker.isIdle)
    let a = tracker.begin("Copying", token: FileOpsCancellationToken())
    let b = tracker.begin("Extracting “x.zip”", token: FileOpsCancellationToken())
    #expect(!tracker.isIdle)
    #expect(tracker.runningTitles == ["Copying", "Extracting “x.zip”"])
    #expect(log.begun.count == 2 && log.ended == 0)
    tracker.end(a)
    #expect(tracker.runningTitles == ["Extracting “x.zip”"])
    tracker.end(b)
    #expect(tracker.isIdle)
    #expect(log.ended == 2)
}

/// Quit waits for this: it fires once, when the last operation ends.
@Test func fileOpsTrackerWhenIdleWaitsForTheLastOperation() {
    let tracker = ActivityLog().tracker()
    var fired = 0
    tracker.whenIdle { fired += 1 }
    #expect(fired == 1)                       // already idle: runs at once

    let a = tracker.begin("Copying", token: FileOpsCancellationToken())
    let b = tracker.begin("Moving", token: FileOpsCancellationToken())
    tracker.whenIdle { fired += 1 }
    tracker.end(a)
    #expect(fired == 1)
    tracker.end(b)
    #expect(fired == 2)
    let c = tracker.begin("Copying", token: FileOpsCancellationToken())
    tracker.end(c)
    #expect(fired == 2)                       // handlers run only once
}

@Test func fileOpsTrackerCancelAllCancelsEveryToken() {
    let tracker = ActivityLog().tracker()
    let t1 = FileOpsCancellationToken(), t2 = FileOpsCancellationToken()
    _ = tracker.begin("Copying", token: t1)
    _ = tracker.begin("Moving", token: t2)
    tracker.cancelAll()
    #expect(t1.isCancelled && t2.isCancelled)
}

/// "Stop and Quit": a cancelled copy stops between items, so no item is left
/// half-written under its real name, and then the tracker goes idle.
@Test func fileOpsStopAndQuitLeavesNoPartialItem() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let sources = try (1...50).map { try dir.file("src/\($0).bin", bytes: 64 * 1024) }
    let dest = try dir.dir("dest")
    let tracker = ActivityLog().tracker()
    let token = FileOpsCancellationToken()
    let id = tracker.begin("Copying", token: token)
    let idle = DispatchSemaphore(value: 0)
    tracker.whenIdle { idle.signal() }

    DispatchQueue.global().async {
        _ = FileOpsTransfer.transfer(sources, into: dest, mode: .copy, token: token) { p in
            if p.completed == 3 { tracker.cancelAll() }
        }
        tracker.end(id)
    }
    #expect(idle.wait(timeout: .now() + 10) == .success)
    let copied = try FileManager.default.contentsOfDirectory(atPath: dest.path)
    #expect(copied.count < sources.count)
    for name in copied {
        let size = try FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent(name).path)[.size] as? NSNumber
        #expect(size?.intValue == 64 * 1024, "\(name) is incomplete")
    }
}

// MARK: - Quit review

/// Drives FileOpsQuitReview the way AppKit does: `ask` stands in for the modal alert
/// (blocks run on the main queue meanwhile), `schedule` queues work for "after the reply".
private final class QuitHarness {
    let tracker = ActivityLog().tracker()
    let review = FileOpsQuitReview()
    var errors = 0
    var queued: [() -> Void] = []
    var finished: [Bool] = []

    func quit(_ ask: @escaping ([String]) -> FileOpsQuitReview.Choice) -> FileOpsQuitReview.Reply {
        review.shouldTerminate(tracker: tracker, errorCount: { self.errors }, ask: ask,
                               schedule: { self.queued.append($0) },
                               finish: { self.finished.append($0) })
    }

    func drain() {
        while !queued.isEmpty { queued.removeFirst()() }
    }
}

@Test func fileOpsQuitWithNothingRunningProceeds() {
    let h = QuitHarness()
    #expect(h.quit { _ in Issue.record("nothing to ask about"); return .wait } == .proceed)
    #expect(!h.review.isBusy && !h.review.isWaiting)
}

/// Regression: an operation that failed and finished while the alert was on screen,
/// before "Wait, Then Quit" was clicked, let the app quit over its error, because the
/// error count was read only after the alert returned.
@Test func fileOpsQuitStaysOpenForAnErrorRaisedWhileAsking() {
    let h = QuitHarness()
    let op = h.tracker.begin("Copying", token: FileOpsCancellationToken())
    let reply = h.quit { titles in
        #expect(titles == ["Copying"])
        h.errors += 1                 // the copy fails…
        h.tracker.end(op)             // …and finishes, all under the modal alert
        return .wait
    }
    #expect(reply == .later)
    #expect(h.review.isWaiting)
    #expect(h.finished.isEmpty)       // never replies before .later is returned
    h.drain()
    #expect(h.finished == [true])     // stay open: the error must be seen
    #expect(!h.review.isWaiting && !h.review.isBusy)
}

@Test func fileOpsQuitWaitsThenQuitsWhenNothingFailed() {
    let h = QuitHarness()
    let op = h.tracker.begin("Copying", token: FileOpsCancellationToken())
    #expect(h.quit { _ in .wait } == .later)
    h.drain()
    #expect(h.finished.isEmpty)       // still running
    h.tracker.end(op)
    h.drain()
    #expect(h.finished == [false])
}

@Test func fileOpsQuitStopCancelsAndDontQuitCancelsTheQuit() {
    let h = QuitHarness()
    let token = FileOpsCancellationToken()
    let op = h.tracker.begin("Copying", token: token)
    #expect(h.quit { _ in .dontQuit } == .cancel)
    #expect(!token.isCancelled && !h.review.isBusy && !h.review.isWaiting)

    #expect(h.quit { _ in .stop } == .later)
    #expect(token.isCancelled)
    h.errors += 1                     // an error while waiting also keeps the app open
    h.tracker.end(op)
    h.drain()
    #expect(h.finished == [true])
}

/// A second quit request while the alert is up or while waiting is refused: no second
/// alert, no second reply.
@Test func fileOpsQuitRefusesAReentrantRequest() {
    let h = QuitHarness()
    let op = h.tracker.begin("Copying", token: FileOpsCancellationToken())
    var nested: FileOpsQuitReview.Reply?
    let reply = h.quit { _ in
        nested = h.quit { _ in Issue.record("asked twice"); return .wait }
        return .wait
    }
    #expect(reply == .later)
    #expect(nested == .cancel)
    #expect(h.quit { _ in Issue.record("asked while waiting"); return .wait } == .cancel)
    h.tracker.end(op)
    h.drain()
    #expect(h.finished == [false])    // exactly one reply
    // Afterwards a new quit is reviewed normally.
    _ = h.tracker.begin("Moving", token: FileOpsCancellationToken())
    #expect(h.quit { _ in .dontQuit } == .cancel)
}
