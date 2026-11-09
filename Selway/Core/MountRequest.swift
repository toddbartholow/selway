import Foundation

/// How a mount came out.
enum MountOutcome: Equatable, Sendable {
    /// The mount points (several when the user picked several shares).
    case mounted([String])
    /// `status` is the backend's (NetFS's), for a log line. `paths` are any
    /// mount points it gave with the failure: with "already mounted", where
    /// the share is.
    case failed(ServerConnectFailure, status: Int32, paths: [String])
}

/// One asynchronous mount's bookkeeping, apart from the backend that mounts
/// (NetFS in the app; a fake in the tests), so its orderings can be tested.
///
/// The backend runs on `queue`, a serial queue, and reports on it. Whether it
/// has reported is kept on that queue too, so a cancel is only ever passed to
/// the backend for a request still pending: once its report has run, the
/// request is gone, and cancelling it could touch freed memory (NetFS's
/// `NetFSMountURLCancel`). The result is delivered once, on `deliverQueue`
/// (main in the app); `cancel()` is called there, and delivers `.cancelled`
/// at once, whatever the backend does after.
final class MountRequest<Handle>: @unchecked Sendable {
    /// Starts the backend on `queue`: its status (non-zero if it refused to
    /// start) and a handle to cancel it with. It must call `report` on `queue`,
    /// once, unless cancelled.
    typealias Begin = @Sendable (_ queue: DispatchQueue,
                                 _ report: @escaping @Sendable (_ status: Int32, _ paths: [String]) -> Void)
                                -> (status: Int32, handle: Handle?)

    private let queue: DispatchQueue
    private let deliverQueue: DispatchQueue
    private let cancelBackend: @Sendable (Handle) -> Void
    // Only on `queue`:
    private var handle: Handle?
    private var settled = false
    // Only on `deliverQueue`:
    private var completion: ((MountOutcome) -> Void)?
    private var cancelled = false

    init(queue: DispatchQueue, deliverOn deliverQueue: DispatchQueue,
         cancel: @escaping @Sendable (Handle) -> Void, completion: @escaping (MountOutcome) -> Void) {
        self.queue = queue
        self.deliverQueue = deliverQueue
        self.cancelBackend = cancel
        self.completion = completion
    }

    func start(_ begin: @escaping Begin) {
        queue.async {
            let started = begin(self.queue) { status, paths in
                self.settled = true
                self.deliverQueue.async { self.finish(status: status, paths: paths) }
            }
            guard started.status == 0 else {
                self.settled = true
                self.deliverQueue.async { self.finish(status: started.status, paths: []) }
                return
            }
            self.handle = started.handle
        }
    }

    /// On `deliverQueue`. The backend is told only if it hasn't reported yet;
    /// either way the caller hears `.cancelled`, and nothing after.
    func cancel() {
        guard completion != nil, !cancelled else { return }
        cancelled = true
        queue.async {
            if !self.settled, let handle = self.handle { self.cancelBackend(handle) }
            self.settled = true
        }
        deliver(.failed(.cancelled, status: -128, paths: []))
    }

    private func finish(status: Int32, paths: [String]) {
        guard !cancelled else { return }
        if let failure = ServerConnectFailure.classify(status: status) {
            deliver(.failed(failure, status: status, paths: paths))
        } else {
            deliver(.mounted(paths))
        }
    }

    private func deliver(_ outcome: MountOutcome) {
        let completion = self.completion
        self.completion = nil
        completion?(outcome)
    }
}
