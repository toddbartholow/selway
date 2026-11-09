import Foundation

// The editors' save, close and quit decisions, without AppKit: which question to
// ask, what each button means, and what happens next. EditorSavePrompts.swift and
// CodeEditorView.swift turn these into NSAlerts and WebKit calls.

// MARK: - Alerts as data

/// An alert's text and buttons, in on-screen order, each paired with its meaning.
/// NSAlert reports clicks by position, so keeping titles and meanings in one table
/// means reordering the buttons can't silently make "Cancel" discard edits.
struct EditorAlertSpec<Choice: Equatable>: Equatable {
    struct Button: Equatable {
        let title: String
        let choice: Choice
        /// Drawn as destructive (it throws away edits).
        var isDestructive = false
        /// A ⌘-key shortcut, e.g. "d" for Don't Save.
        var commandKey: String? = nil
    }

    var message: String
    var info: String
    var buttons: [Button]
    /// The meaning of any other response (e.g. the sheet was dismissed).
    var fallback: Choice

    /// The choice for the button at `index`, 0 being the first (default) button.
    func choice(forButtonAt index: Int) -> Choice {
        buttons.indices.contains(index) ? buttons[index].choice : fallback
    }
}

enum EditorCloseChoice: Equatable { case save, discard, cancel }

enum EditorAlerts {

    /// "Save / Cancel / Don't Save" for one document.
    static func confirmClose(documentName: String) -> EditorAlertSpec<EditorCloseChoice> {
        EditorAlertSpec(
            message: String.localizedStringWithFormat(NSLocalizedString("Do you want to save the changes you made to “%@”?", comment: "Confirm saving a document before closing"), documentName),
            info: NSLocalizedString("Your changes will be lost if you don't save them.", comment: "Save confirmation warning"),
            buttons: closeButtons(save: NSLocalizedString("Save", comment: "Alert button to save a document")), fallback: .cancel)
    }

    /// The same question for several documents (window close, quit).
    static func confirmCloseAll(documentNames: [String]) -> EditorAlertSpec<EditorCloseChoice> {
        guard documentNames.count > 1 else {
            return confirmClose(documentName: documentNames.first
                                ?? NSLocalizedString("Untitled", comment: "Placeholder document name when no document name is available"))
        }
        let list = documentNames.prefix(8).map { "• \($0)" }.joined(separator: "\n")
        let moreCount = documentNames.count - 8
        let moreFormat = NSLocalizedString("…and %lld more", comment: "Number of additional documents omitted from the list.")
        let more = documentNames.count > 8 ? "\n" + String.localizedStringWithFormat(moreFormat, moreCount) : ""
        let message = String.localizedStringWithFormat(
            NSLocalizedString("You have unsaved changes in %lld documents.", comment: "Close or quit confirmation for several documents"),
            documentNames.count)
        return EditorAlertSpec(
            message: message,
            info: "\(list)\(more)\n\n\(NSLocalizedString("Your changes will be lost if you don't save them.", comment: "Save confirmation warning"))",
            buttons: closeButtons(save: NSLocalizedString("Save All", comment: "Alert button to save all documents")), fallback: .cancel)
    }

    private static func closeButtons(save: String) -> [EditorAlertSpec<EditorCloseChoice>.Button] {
        [.init(title: save, choice: .save),
         .init(title: NSLocalizedString("Cancel", comment: "Alert button to cancel"), choice: .cancel),
         .init(title: NSLocalizedString("Don't Save", comment: "Alert button to discard unsaved changes"), choice: .discard, isDestructive: true, commandKey: "d")]
    }

    /// Reload an unmodified document that changed on disk? (true = reload)
    static func offerReload(documentName: String) -> EditorAlertSpec<Bool> {
        EditorAlertSpec(
            message: String.localizedStringWithFormat(NSLocalizedString("“%@” was changed by another application.", comment: "Alert that a document changed on disk"), documentName),
            info: NSLocalizedString("You have no unsaved changes in it. Reload it to show the version on disk?", comment: "Alert asking whether to reload a changed document"),
            buttons: [.init(title: NSLocalizedString("Reload", comment: "Alert button to reload a document"), choice: true),
                      .init(title: NSLocalizedString("Keep Current Version", comment: "Alert button to keep the current document version"), choice: false)],
            fallback: false)
    }
}

// MARK: - Save flow

enum TextFileSavePlan {

    enum Choice: Equatable {
        /// Write over a version another app saved.
        case overwrite
        /// Create the file again where it was (it was moved or deleted).
        case recreate
        /// Throw away the edits and show the version on disk.
        case reload
        case saveAsUTF8
        case cancel
    }

    /// What to do after `TextFileIO.save` failed.
    enum Step: Equatable {
        case ask(EditorAlertSpec<Choice>)
        /// Show this error; nothing was written.
        case fail(message: String, info: String)
    }

    /// What to do after the user answered.
    enum Next: Equatable {
        case retry(format: TextFileFormat, force: Bool)
        case reloadRequested
        case cancelled
    }

    /// The question (or error) for a failed save of the document the user knows as
    /// `name`. `fileExists`: whether anything is at the save path now.
    static func step(after error: Error, name: String, fileExists: Bool) -> Step {
        switch error as? TextFileIOError {
        case .changedOnDisk? where fileExists:
            return .ask(EditorAlertSpec(
                message: String.localizedStringWithFormat(NSLocalizedString("“%@” was changed by another application since you opened it.", comment: "Save conflict alert with document name"), name),
                info: NSLocalizedString("Overwrite replaces the version on disk with yours. Reload from Disk discards your unsaved changes.", comment: "Save conflict alert explanation"),
                buttons: [.init(title: NSLocalizedString("Overwrite", comment: "Alert button to overwrite a changed document"), choice: .overwrite),
                          .init(title: NSLocalizedString("Cancel", comment: "Alert button to cancel"), choice: .cancel),
                          .init(title: NSLocalizedString("Reload from Disk", comment: "Alert button to reload a document from disk"), choice: .reload, isDestructive: true)],
                fallback: .cancel))
        case .changedOnDisk?:
            return .ask(EditorAlertSpec(
                message: String.localizedStringWithFormat(NSLocalizedString("“%@” was moved or deleted since you opened it.", comment: "Save alert with document name"), name),
                info: NSLocalizedString("Saving creates it again at its original location.", comment: "Save alert explanation"),
                buttons: [.init(title: NSLocalizedString("Save", comment: "Alert button to save a document"), choice: .recreate),
                          .init(title: NSLocalizedString("Cancel", comment: "Alert button to cancel"), choice: .cancel)],
                fallback: .cancel))
        case .unencodable(let encodingName)?:
            return .ask(EditorAlertSpec(
                message: String.localizedStringWithFormat(NSLocalizedString("“%1$@” can't be saved as %2$@.", comment: "Encoding error alert with document name and encoding"), name, encodingName),
                info: String.localizedStringWithFormat(NSLocalizedString("It now contains characters that %@ can't represent. Save it as UTF-8 instead?", comment: "Encoding error alert explanation"), encodingName),
                buttons: [.init(title: NSLocalizedString("Save as UTF-8", comment: "Alert button to save a document as UTF-8"), choice: .saveAsUTF8),
                          .init(title: NSLocalizedString("Cancel", comment: "Alert button to cancel"), choice: .cancel)],
                fallback: .cancel))
        default:
            return .fail(message: String.localizedStringWithFormat(NSLocalizedString("“%@” couldn't be saved.", comment: "Text editor save error with document name"), name), info: error.localizedDescription)
        }
    }

    static func next(after choice: Choice, format: TextFileFormat, force: Bool) -> Next {
        switch choice {
        case .overwrite, .recreate:
            return .retry(format: format, force: true)
        case .saveAsUTF8:
            var utf8 = format
            utf8.encoding = .utf8
            utf8.hasBOM = false
            return .retry(format: utf8, force: force)
        case .reload:
            return .reloadRequested
        case .cancel:
            return .cancelled
        }
    }
}

// MARK: - Reply from the code editor page

enum EditorDocReply {
    /// Parses `Selway.getDocContent(id)`'s result, `{text: String, version: Int}`.
    /// Anything else (null for an unknown id, a missing or non-string text, a
    /// missing or non-integer version) is nil, so a failed lookup is never saved
    /// as an empty file.
    static func parse(_ value: Any?) -> (text: String, version: Int)? {
        guard let dict = value as? [String: Any], let text = dict["text"] as? String,
              let version = integer(dict["version"]) else { return nil }
        return (text, version)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            let d = number.doubleValue
            guard d.isFinite, d == d.rounded(), abs(d) < 9_007_199_254_740_992 else { return nil }
            return Int(d)
        }
        if let i = value as? Int { return i }
        if let d = value as? Double, d.isFinite, d == d.rounded(), abs(d) < 9_007_199_254_740_992 { return Int(d) }
        return nil
    }
}

// MARK: - One save per document at a time

/// Serialises saves per document. A save requested while one is running (⌘S's
/// conflict sheet is up and the user quits or closes the tab) waits for it instead
/// of failing silently.
final class TextFileSaveQueue<ID: Hashable> {
    private var waiters: [ID: [(Bool) -> Void]] = [:]

    func isSaving(_ id: ID) -> Bool { waiters[id] != nil }

    /// True when the caller should start saving `id` now. Otherwise a save is
    /// already running and `waiter` is called with its result when it finishes.
    func begin(_ id: ID, orWait waiter: @escaping (Bool) -> Void) -> Bool {
        if waiters[id] != nil {
            waiters[id]!.append(waiter)
            return false
        }
        waiters[id] = []
        return true
    }

    /// Ends the save of `id` and tells everyone who waited for it.
    func finish(_ id: ID, ok: Bool) {
        let waiting = waiters.removeValue(forKey: id) ?? []
        for waiter in waiting { waiter(ok) }
    }

    /// Ends every save (the editor's content process died): waiters get false.
    func failAll() {
        let all = waiters
        waiters = [:]
        for (_, waiting) in all { for waiter in waiting { waiter(false) } }
    }
}

// MARK: - Editor crash loop guard

/// Decides whether to reload the editor page after its content process died. A
/// page that keeps crashing (e.g. on a file that trips a WebKit bug) shouldn't be
/// reloaded forever.
struct EditorCrashGuard {
    var limit = 3
    var window: TimeInterval = 60
    private(set) var crashes: [Date] = []

    /// Records a crash; false once `limit` crashes happened within `window`.
    mutating func shouldReopen(afterCrashAt now: Date) -> Bool {
        crashes = crashes.filter { now.timeIntervalSince($0) < window } + [now]
        return crashes.count < limit
    }
}

// MARK: - Quit with unsaved changes

/// The order of events when the app is asked to quit with unsaved documents.
///
/// 1. Ask Save / Don't Save / Cancel (synchronously, as `runModal` does).
/// 2. Don't Save → quit now; Cancel → don't quit.
/// 3. Save → reply "later", then save everything and reply exactly once: quit only
///    if every document was saved.
///
/// `isQuitting` is true from step 1 until the decision is final. While it is, a
/// second quit request is refused; anything that can start a quit (Sparkle's Install
/// and Relaunch, via UpdaterPolicy) must check it first, because AppKit ends the app at
/// once when terminate is called again while a deferred reply is pending.
final class TextFileQuitReview {
    enum Reply: Equatable { case now, cancel, later }

    private(set) var isQuitting = false

    func shouldTerminate(unsaved: [String],
                         ask: ([String], @escaping (EditorCloseChoice) -> Void) -> Void,
                         schedule: (@escaping () -> Void) -> Void,
                         saveAll: @escaping (@escaping (Bool) -> Void) -> Void,
                         reply: @escaping (Bool) -> Void) -> Reply {
        guard !isQuitting else { return .cancel }
        guard !unsaved.isEmpty else { return .now }
        isQuitting = true
        var answer: EditorCloseChoice?
        ask(unsaved) { choice in if answer == nil { answer = choice } }
        guard answer == .save else {
            isQuitting = false
            return answer == .discard ? .now : .cancel
        }
        // Saving starts only after `.later` has been returned: replying before that
        // is invalid, and some saves finish synchronously.
        schedule { [self] in
            var replied = false
            saveAll { ok in
                guard !replied else { return }
                replied = true
                self.isQuitting = false
                reply(ok)
            }
        }
        return .later
    }

    /// Runs `steps` one after another, stopping at the first that fails.
    /// `completion` is called exactly once, even if a step calls back twice.
    static func runInOrder(_ steps: [(@escaping (Bool) -> Void) -> Void],
                           completion: @escaping (Bool) -> Void) {
        var done = false
        func finish(_ ok: Bool) {
            guard !done else { return }
            done = true
            completion(ok)
        }
        func run(_ index: Int) {
            guard index < steps.count else { finish(true); return }
            var called = false
            let step = steps[index]
            step { ok in
                guard !called else { return }
                called = true
                ok ? run(index + 1) : finish(false)
            }
        }
        run(0)
    }
}
