import Foundation

/// A lookup under way; `cancel` stops it, and its completion isn't called
/// after that: the resolver hands its result through `finish`, which drops
/// it once cancelled (or once delivered).
@MainActor
final class NetworkResolution {
    private(set) var isLive = true
    private var onCancel: (() -> Void)?

    /// What stops the lookup itself (a DNSServiceRef going), on cancel.
    func whenCancelled(_ body: @escaping () -> Void) {
        onCancel = isLive ? body : nil
    }

    func cancel() {
        guard isLive else { return }
        isLive = false
        onCancel?()
        onCancel = nil
    }

    /// Runs `deliver` (the completion) unless cancelled; once.
    func finish(_ deliver: () -> Void) {
        guard isLive else { return }
        isLive = false
        onCancel = nil
        deliver()
    }
}
