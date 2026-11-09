import Foundation
import Testing
@testable import SelwayCore

/// MountRequest's orderings with a fake backend: nothing is mounted.
private final class FakeMount: @unchecked Sendable {
    let queue = DispatchQueue(label: "test.mount")
    let deliver = DispatchQueue(label: "test.deliver")
    private let lock = NSLock()
    private var _cancelled: [Int] = []
    private var _outcomes: [MountOutcome] = []
    var report: (@Sendable (Int32, [String]) -> Void)?
    lazy var request = MountRequest<Int>(
        queue: queue, deliverOn: deliver,
        cancel: { [unowned self] id in self.lock.withLock { self._cancelled.append(id) } },
        completion: { [unowned self] outcome in self.lock.withLock { self._outcomes.append(outcome) } })

    var cancelledHandles: [Int] { lock.withLock { _cancelled } }
    var outcomes: [MountOutcome] { lock.withLock { _outcomes } }

    /// Starts a backend that returns `status` and handle 7, and keeps its report.
    func start(status: Int32 = 0) {
        request.start { [unowned self] _, report in
            self.report = report
            return (status, 7)
        }
        settle()
    }

    /// The backend reports, on its queue.
    func finish(_ status: Int32, _ paths: [String] = []) { queue.sync { report?(status, paths) } }

    /// Lets both queues run what they have.
    func settle() {
        queue.sync {}
        deliver.sync {}
    }
}

@Suite struct MountRequestTests {
    @Test func aMountIsDeliveredOnce() {
        let m = FakeMount()
        m.start()
        m.finish(0, ["/Volumes/Share"])
        m.settle()
        m.finish(0, ["/Volumes/Again"])
        m.settle()
        #expect(m.outcomes == [.mounted(["/Volumes/Share"])])
    }

    @Test func failuresAreClassifiedAndKeepTheirMountPoints() {
        let m = FakeMount()
        m.start()
        m.finish(17, ["/Volumes/Share"])
        m.settle()
        #expect(m.outcomes == [.failed(.alreadyMounted, status: 17, paths: ["/Volumes/Share"])])
    }

    @Test func aBackendThatWontStartFails() {
        let m = FakeMount()
        m.start(status: 65)
        m.settle()
        #expect(m.outcomes == [.failed(.serverNotFound, status: 65, paths: [])])
        m.deliver.sync { m.request.cancel() }
        m.settle()
        #expect(m.cancelledHandles.isEmpty && m.outcomes.count == 1)
    }

    @Test func cancellingAPendingMountCancelsTheBackend() {
        let m = FakeMount()
        m.start()
        m.deliver.sync { m.request.cancel() }
        m.settle()
        #expect(m.cancelledHandles == [7])
        #expect(m.outcomes == [.failed(.cancelled, status: -128, paths: [])])
    }

    /// Window (a): the backend has reported, its result not yet delivered,
    /// when Cancel comes. The backend isn't told (its request is gone), and
    /// the caller hears only `.cancelled`.
    @Test func cancelAfterTheReportDoesntReachTheBackend() {
        let m = FakeMount()
        m.start()
        m.deliver.suspend()
        m.finish(0, ["/Volumes/Share"])
        m.request.cancel()        // the delivery queue is held, so this stands in for it
        m.queue.sync {}
        #expect(m.cancelledHandles.isEmpty)
        m.deliver.resume()
        m.settle()
        #expect(m.outcomes == [.failed(.cancelled, status: -128, paths: [])])
    }

    /// Window (b): Cancel before the backend has even started, which then
    /// fails at once. The cancel is never passed on.
    @Test func cancelBeforeAFastFailureDoesntReachTheBackend() {
        let m = FakeMount()
        m.queue.suspend()
        m.request.start { _, report in
            report(61, [])          // failed straight away, on the queue
            return (0, 7)
        }
        m.deliver.sync { m.request.cancel() }
        m.queue.resume()
        m.settle()
        #expect(m.cancelledHandles.isEmpty)
        #expect(m.outcomes == [.failed(.cancelled, status: -128, paths: [])])
    }

    /// Window (c): Cancel before the backend has handed back its handle, and
    /// before any report. The cancel waits on the queue behind the start, so
    /// it reaches the backend once the handle is there; a report after it is
    /// dropped.
    @Test func cancelBeforeTheHandleReachesTheBackendOnceItHasOne() {
        let m = FakeMount()
        m.queue.suspend()
        m.request.start { [unowned m] _, report in
            m.report = report
            return (0, 7)
        }
        m.deliver.sync { m.request.cancel() }
        #expect(m.cancelledHandles.isEmpty)
        m.queue.resume()
        m.settle()
        #expect(m.cancelledHandles == [7])
        #expect(m.outcomes == [.failed(.cancelled, status: -128, paths: [])])
        m.finish(0, ["/Volumes/Share"])
        m.settle()
        #expect(m.outcomes.count == 1)
    }

    @Test func cancellingTwiceDeliversOnce() {
        let m = FakeMount()
        m.start()
        m.deliver.sync { m.request.cancel(); m.request.cancel() }
        m.settle()
        #expect(m.cancelledHandles == [7] && m.outcomes.count == 1)
    }
}
