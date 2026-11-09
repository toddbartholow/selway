import Foundation

// Closing editor tabs and windows, without AppKit. CodeEditorView.swift and
// MarkdownReaderView.swift turn these decisions into WebKit calls and NSWindow.close().

// MARK: - Closing a tab

/// What closing one tab of the code editor leaves behind.
struct EditorTabClosePlan: Equatable {
    /// The tabs still open, in order.
    var remaining: [String]
    /// The tab to show next; nil when none is left.
    var active: String?

    /// The window goes once its last tab is closed: it must never keep showing
    /// text that no open document backs (typing there could never be saved).
    var closesWindow: Bool { remaining.isEmpty }

    /// Closing `id` (an unknown id changes nothing). The active tab stays active;
    /// if it was the one closed, the last remaining tab takes over.
    static func closing(_ id: String, tabs: [String], active: String?) -> EditorTabClosePlan {
        let remaining = tabs.filter { $0 != id }
        let stillOpen = active.flatMap { remaining.contains($0) ? $0 : nil }
        return EditorTabClosePlan(remaining: remaining, active: stillOpen ?? remaining.last)
    }
}

// MARK: - Closing a window from a callback

/// Closes an editor window on a later turn of the run loop.
///
/// Closes are requested from inside alert callbacks: Don't Save, a save that went
/// through a conflict sheet, the "editor keeps stopping" error. A sheet's
/// completion handler runs while the sheet is still attached to the window, and
/// `NSWindow.performClose` refuses (it beeps) while a sheet is attached, so the
/// window stayed open after its last document was gone: still showing the text,
/// still accepting typing, with nothing left to save it to. Running the close
/// once the callback has returned (and the sheet has gone) avoids that.
///
/// Requests made before the close has run are merged; the latest one is used.
final class EditorDeferredClose {
    private let schedule: (@escaping () -> Void) -> Void
    private var pending: (stillWanted: () -> Bool, close: () -> Void)?

    /// `schedule` runs its argument later on the main thread, never synchronously
    /// (the app passes `DispatchQueue.main.async`, which also runs while an alert
    /// is up app-modally).
    init(schedule: @escaping (@escaping () -> Void) -> Void) {
        self.schedule = schedule
    }

    /// A close is waiting to run.
    var isPending: Bool { pending != nil }

    /// Runs `close` on a later turn, unless `stillWanted()` is false by then (for
    /// example a file was opened in the window meanwhile).
    func request(when stillWanted: @escaping () -> Bool = { true }, _ close: @escaping () -> Void) {
        let alreadyScheduled = pending != nil
        pending = (stillWanted, close)
        guard !alreadyScheduled else { return }
        schedule { [weak self] in
            guard let self, let request = self.pending else { return }
            self.pending = nil
            if request.stillWanted() { request.close() }
        }
    }
}
