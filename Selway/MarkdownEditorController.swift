import Foundation
import AppKit
import Combine

/// Shared handle so the format toolbar can reach the live `NSTextView`.
@MainActor
final class MarkdownEditorController: ObservableObject {
    weak var textView: NSTextView?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Every observer token, so re-attaching (each switch to Edit mode builds a new
    /// text view) replaces them instead of piling up.
    private var observers: [NSObjectProtocol] = []

    /// - Parameter undoManager: the editor's own undo manager (the text view's
    ///   delegate supplies it). Passed explicitly because `tv.undoManager` falls back
    ///   to the window's, which is nil before the view is in a window — and observing
    ///   with a nil object would match every undo manager in the app.
    func attach(_ tv: NSTextView, undoManager: UndoManager) {
        if textView === tv, !observers.isEmpty { refreshUndoState(); return }
        detach()
        textView = tv
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [.NSUndoManagerDidCloseUndoGroup,
                                          .NSUndoManagerDidUndoChange,
                                          .NSUndoManagerDidRedoChange]
        for name in names {
            observers.append(nc.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshUndoState() }
            })
        }
        observers.append(nc.addObserver(forName: NSText.didChangeNotification, object: tv, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshUndoState() }
        })
        refreshUndoState()
    }

    func detach() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
        textView = nil
        refreshUndoState()
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }

    func refreshUndoState() {
        canUndo = textView?.undoManager?.canUndo ?? false
        canRedo = textView?.undoManager?.canRedo ?? false
    }

    func run(_ action: (NSTextView) -> Void) {
        guard let tv = textView else { return }
        action(tv)
        refreshUndoState()
    }
}
