import AppKit

/// Move to Trash and Delete Permanently, as the menu bar, toolbar and context
/// menu run them: which one, and whether to ask first, come from Settings →
/// Advanced (FileOpsDeleteDecision, Core).
@MainActor
enum DeleteFlow {
    static var prefs: FileOpsDeletePrefs { FileOpsDeletePrefs(.standard) }

    /// Runs `command` on `urls`, asking first when the settings say so. Returns
    /// false when the user cancelled (the caller keeps its selection then). Items
    /// a Move to Trash had to leave (no Trash on their volume) and the user then
    /// chose to keep come back through `FileOperationsService.keptItems`.
    @discardableResult
    static func run(_ command: FileOpsDeleteCommand, urls: [URL], fileOps: FileOperationsService,
                    reload: @escaping () -> Void) -> Bool {
        guard !urls.isEmpty else { return false }
        let names = urls.map(\.lastPathComponent)
        switch FileOpsDeleteDecision.action(for: command, prefs: prefs) {
        case .trash(let confirm):
            if confirm && !confirmTrash(names) { return false }
            fileOps.trash(urls, reload: reload)
        case .deletePermanently(let confirm):
            if confirm && !confirmPermanentDelete(names) { return false }
            fileOps.permanentlyDelete(urls, reload: reload)
        }
        return true
    }

    static func confirmTrash(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText     = FileOpsDeleteText.trashQuestion(names)
        alert.informativeText = FileOpsDeleteText.trashDetail
        alert.addButton(withTitle: String(localized: "Move to Trash", comment: "Alert button to move items to the Trash"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button to cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Return and Escape both cancel: nothing brings the items back.
    static func confirmPermanentDelete(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText     = FileOpsDeleteText.permanentQuestion(names)
        alert.informativeText = FileOpsDeleteText.permanentDetail(count: names.count)
        alert.alertStyle      = .warning
        let delete = alert.addButton(withTitle: String(localized: "Delete Permanently", comment: "Alert button to delete items permanently"))
        delete.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button to cancel"))
        return SafeAlert.run(alert, safe: cancel, others: [delete]) == .alertFirstButtonReturn
    }

    /// Items Move to Trash left alone because their volume has no Trash. The
    /// user asked to trash them, not delete them, so this always asks, and
    /// Return and Escape cancel.
    static func confirmDeleteWithoutTrash(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText     = FileOpsDeleteText.noTrashQuestion(names)
        alert.informativeText = FileOpsDeleteText.noTrashDetail(count: names.count)
        alert.alertStyle      = .warning
        let delete = alert.addButton(withTitle: String(localized: "Delete Permanently", comment: "Alert button to delete items permanently"))
        delete.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button to cancel"))
        return SafeAlert.run(alert, safe: cancel, others: [delete]) == .alertFirstButtonReturn
    }
}

/// An alert whose safe answer takes both Return and Escape. NSAlert gives
/// Escape to a "Cancel" button only while Return is on another button, so
/// moving Return to Cancel would leave Escape doing nothing: a key monitor maps
/// it to the safe button while the alert is up.
@MainActor
enum SafeAlert {
    static func run(_ alert: NSAlert, safe: NSButton, others: [NSButton]) -> NSApplication.ModalResponse {
        others.forEach { $0.keyEquivalent = "" }
        safe.keyEquivalent = "\r"
        let window = alert.window
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window === window else { return event }   // Escape
            safe.performClick(nil)
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        // With Keyboard navigation on, Space presses the focused button: start
        // the focus on the safe one, not on the first button added.
        alert.window.initialFirstResponder = safe
        return alert.runModal()
    }
}

/// The rename question Finder asks when a file's extension changes (Settings →
/// Advanced → Warn before changing an extension).
@MainActor
enum ExtensionChangePrompt {
    enum Answer { case keep, use }

    /// Asks about `change`; "Don't ask again" turns the warning off.
    static func ask(_ change: FileOpsExtensionChange) -> Answer {
        let alert = NSAlert()
        alert.messageText     = change.question
        alert.informativeText = FileOpsExtensionChange.detail
        let keep = alert.addButton(withTitle: change.keepTitle)
        let use = alert.addButton(withTitle: change.useTitle)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don’t ask again", comment: "Alert suppression checkbox")
        // Escape keeps the extension, like Return.
        let answer: Answer = SafeAlert.run(alert, safe: keep, others: [use]) == .alertFirstButtonReturn ? .keep : .use
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(false, forKey: SettingsKeys.warnExtensionChange)
        }
        return answer
    }

    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.warnExtensionChange, default: true)
    }
}
