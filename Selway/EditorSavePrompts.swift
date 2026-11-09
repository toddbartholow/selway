import AppKit

// MARK: - Alerts shared by the code editor and the Markdown editor

// The wording, button order and button meanings live in Core/TextFileSavePlan.swift
// (EditorAlerts, TextFileSavePlan), where they are tested; this file shows them.

@MainActor
enum EditorPrompts {

    typealias CloseChoice = EditorCloseChoice

    /// Set while saving for quit: the app is waiting in a modal run-loop mode, so
    /// follow-up questions are shown app-modal rather than as sheets.
    static var preferAppModal = false

    /// Shows `alert` as a sheet on `window` when it can, otherwise app-modal.
    static func present(_ alert: NSAlert, for window: NSWindow?,
                        completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if !preferAppModal, let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    /// Shows `spec` and reports the meaning of the button that was clicked.
    static func ask<Choice>(_ spec: EditorAlertSpec<Choice>, window: NSWindow?,
                            completion: @escaping (Choice) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = spec.message
        alert.informativeText = spec.info
        for button in spec.buttons {
            let b = alert.addButton(withTitle: button.title)
            b.hasDestructiveAction = button.isDestructive
            if let key = button.commandKey {
                b.keyEquivalent = key
                b.keyEquivalentModifierMask = [.command]
            }
        }
        present(alert, for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            completion(spec.choice(forButtonAt: index))
        }
    }

    /// The standard "Save / Don't Save / Cancel" question for one document.
    static func confirmClose(documentName: String, window: NSWindow?,
                             completion: @escaping (CloseChoice) -> Void) {
        ask(EditorAlerts.confirmClose(documentName: documentName), window: window, completion: completion)
    }

    /// The same question for several documents at once (window close, quit).
    static func confirmCloseAll(documentNames: [String], window: NSWindow?,
                                completion: @escaping (CloseChoice) -> Void) {
        ask(EditorAlerts.confirmCloseAll(documentNames: documentNames), window: window, completion: completion)
    }

    static func showError(_ message: String, info: String, window: NSWindow?,
                          completion: @escaping () -> Void = {}) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: String(localized: "OK", comment: "Alert button to dismiss an error"))
        present(alert, for: window) { _ in completion() }
    }

    /// Explains why a file wasn't opened for editing (binary, unknown encoding, …).
    static func showCannotOpen(_ url: URL, error: Error, window: NSWindow?) {
        showError(String(localized: "“\(url.lastPathComponent)” can't be opened for editing.", comment: "Text editor open error with file name"),
                  info: error.localizedDescription, window: window)
    }

    /// Asks whether to reload an unmodified document that changed on disk.
    static func offerReload(documentName: String, window: NSWindow?, completion: @escaping (Bool) -> Void) {
        ask(EditorAlerts.offerReload(documentName: documentName), window: window, completion: completion)
    }
}

// MARK: - Closing windows from alert callbacks

/// The run loop side of `EditorDeferredClose` (Core/TextFileEditorClose.swift).
enum EditorWindowCloseScheduling {
    /// Runs `work` on a later turn of the main run loop: after the alert callback
    /// that asked for it has returned and the alert's sheet has left the window.
    /// Common modes, so it also runs while an app-modal alert is up.
    static func nextTurn(_ work: @escaping () -> Void) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { work() }
        }
    }
}

// MARK: - Save with conflict and encoding handling

@MainActor
enum TextFileSaveFlow {

    enum Outcome {
        /// Written; keep the new snapshot, format (if the user chose UTF-8) and
        /// path (it changes when the file or a folder was renamed by case only).
        case saved(TextFileSnapshot, TextFileFormat, URL)
        /// The file changed on disk and the user chose to discard their edits for it.
        case reloadRequested
        case cancelled
        /// Not written; the error has already been shown.
        case failed
    }

    /// Saves `text` to `url` (the document's `resolvedURL` from load, never a path to
    /// re-resolve), asking the user when the file changed on disk since `expected` or
    /// when the buffer can't be written in the file's encoding. `name` is the name
    /// the user knows the document by.
    static func save(text: String, to url: URL, name: String, format: TextFileFormat,
                     expected: TextFileSnapshot?, window: NSWindow?, force: Bool = false,
                     completion: @escaping (Outcome) -> Void) {
        let error: Error
        do {
            let saved = try TextFileIO.saveDocument(text, format: format, to: url, expected: expected, force: force)
            completion(.saved(saved.snapshot, format, saved.resolvedURL))
            return
        } catch let caught {
            error = caught
        }
        let exists = TextFileIO.snapshot(of: url) != nil
        switch TextFileSavePlan.step(after: error, name: name, fileExists: exists) {
        case .fail(let message, let info):
            EditorPrompts.showError(message, info: info, window: window) { completion(.failed) }
        case .ask(let spec):
            EditorPrompts.ask(spec, window: window) { choice in
                switch TextFileSavePlan.next(after: choice, format: format, force: force) {
                case .retry(let newFormat, let newForce):
                    save(text: text, to: url, name: name, format: newFormat, expected: expected,
                         window: window, force: newForce, completion: completion)
                case .reloadRequested:
                    completion(.reloadRequested)
                case .cancelled:
                    completion(.cancelled)
                }
            }
        }
    }
}

// MARK: - Quit with unsaved changes

/// Collects unsaved documents from every editor window when the app is asked to quit.
@MainActor
enum UnsavedChangesReview {

    private static let review = TextFileQuitReview()

    /// True from the moment a quit starts asking about unsaved documents until it is
    /// decided (including while they are being saved). Nothing may start another quit
    /// while this is true: a second terminate during a deferred reply ends the app at once,
    /// without waiting for the saves. (UpdateManager.checkForUpdates checks it, because
    /// Sparkle's window can send a new quit request with "Install and Relaunch".)
    static var isQuitting: Bool { review.isQuitting }

    static func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        let names = EditorWindowManager.shared.unsavedDocumentNames
                  + MarkdownWindowManager.shared.unsavedDocumentNames
        let reply = review.shouldTerminate(
            unsaved: names,
            ask: { names, answer in
                // runModal (no window): the app is about to quit and nothing else should run.
                EditorPrompts.confirmCloseAll(documentNames: names, window: nil, completion: answer)
            },
            schedule: { work in
                // The app now waits in the modal-panel run-loop mode; run there too.
                RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                    MainActor.assumeIsolated { work() }
                }
            },
            saveAll: { done in
                EditorPrompts.preferAppModal = true
                saveAll { ok in
                    EditorPrompts.preferAppModal = false
                    done(ok)
                }
            },
            reply: { ok in app.reply(toApplicationShouldTerminate: ok) })
        switch reply {
        case .now:    return .terminateNow
        case .cancel: return .terminateCancel
        case .later:  return .terminateLater
        }
    }

    /// Saves every editor's unsaved documents in turn, stopping at the first that
    /// isn't saved (cancelled conflict prompt, write error).
    static func saveAll(completion: @escaping (Bool) -> Void) {
        TextFileQuitReview.runInOrder([
            { EditorWindowManager.shared.saveAll(completion: $0) },
            { MarkdownWindowManager.shared.saveAll(completion: $0) },
        ], completion: completion)
    }
}
