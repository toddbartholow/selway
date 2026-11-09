import Foundation
import Testing
@testable import SelwayCore

// Move to Trash vs Delete Permanently: which runs, whether it asks, its menu
// title and shortcut; items on a volume without a Trash; and the undo of a
// Move to Trash, on real files with a fake Trash.

@Suite struct FileOpsDeleteTests {

    // MARK: Decision

    @Test func defaultsMatchFinder() {
        let prefs = FileOpsDeletePrefs()
        #expect(FileOpsDeleteDecision.action(for: .moveToTrash, prefs: prefs) == .trash(confirm: false))
        #expect(FileOpsDeleteDecision.action(for: .deletePermanently, prefs: prefs) == .deletePermanently(confirm: true))
        #expect(FileOpsDeleteDecision.shortcut(for: .moveToTrash, prefs: prefs) == .commandDelete)
        #expect(FileOpsDeleteDecision.shortcut(for: .deletePermanently, prefs: prefs) == .optionCommandDelete)
        #expect(FileOpsDeleteDecision.title(for: .moveToTrash, prefs: prefs) == "Move to Trash")
        #expect(FileOpsDeleteDecision.title(for: .deletePermanently, prefs: prefs) == "Delete Permanently…")
    }

    @Test func commandDeleteCanDeletePermanentlyInstead() {
        let prefs = FileOpsDeletePrefs(commandDeleteTrashes: false)
        #expect(FileOpsDeleteDecision.shortcut(for: .deletePermanently, prefs: prefs) == .commandDelete)
        #expect(FileOpsDeleteDecision.shortcut(for: .moveToTrash, prefs: prefs) == .optionCommandDelete)
        // The commands keep their names and confirmations: only the keys swap.
        #expect(FileOpsDeleteDecision.action(for: .deletePermanently, prefs: prefs) == .deletePermanently(confirm: true))
        #expect(FileOpsDeleteDecision.title(for: .moveToTrash, prefs: prefs) == "Move to Trash")
    }

    @Test func confirmationsFollowTheSettingsAndTheTitles() {
        let prefs = FileOpsDeletePrefs(confirmTrash: true, confirmPermanentDelete: false)
        #expect(FileOpsDeleteDecision.action(for: .moveToTrash, prefs: prefs) == .trash(confirm: true))
        #expect(FileOpsDeleteDecision.action(for: .deletePermanently, prefs: prefs) == .deletePermanently(confirm: false))
        #expect(FileOpsDeleteDecision.title(for: .moveToTrash, prefs: prefs) == "Move to Trash…")
        #expect(FileOpsDeleteDecision.title(for: .deletePermanently, prefs: prefs) == "Delete Permanently")
    }

    @Test func storedPrefsFallBackToTheDefaults() {
        let d = TestDefaults(); defer { d.cleanup() }
        #expect(FileOpsDeletePrefs(d.defaults) == FileOpsDeletePrefs())
        d.defaults.set(false, forKey: FileOpsDeletePrefs.commandDeleteTrashesKey)
        d.defaults.set(false, forKey: FileOpsDeletePrefs.confirmPermanentDeleteKey)
        #expect(FileOpsDeletePrefs(d.defaults)
                == FileOpsDeletePrefs(commandDeleteTrashes: false, confirmTrash: false, confirmPermanentDelete: false))
    }

    /// Read as the Settings toggles (`@AppStorage`) read them, so the menus and
    /// what runs can't disagree: "NO" given on the command line is false.
    @Test func storedPrefsReadStringsAsTheTogglesDo() {
        let d = TestDefaults(); defer { d.cleanup() }
        d.defaults.set("NO", forKey: FileOpsDeletePrefs.confirmPermanentDeleteKey)
        d.defaults.set("YES", forKey: FileOpsDeletePrefs.confirmTrashKey)
        #expect(FileOpsDeletePrefs(d.defaults)
                == FileOpsDeletePrefs(commandDeleteTrashes: true, confirmTrash: true, confirmPermanentDelete: false))
    }

    @Test func confirmationWording() {
        #expect(FileOpsDeleteText.permanentQuestion(["a.txt"]) == "Delete “a.txt” permanently?")
        #expect(FileOpsDeleteText.trashQuestion(["a", "b"]) == "Move 2 items to the Trash?")
        #expect(FileOpsDeleteText.permanentDetail(count: 1).contains("won’t be in the Trash"))
        #expect(FileOpsDeleteText.noTrashQuestion(["x"]) == "“x” can’t be moved to the Trash. Delete it permanently?")
        #expect(FileOpsDeleteText.noTrashQuestion(["x", "y", "z"])
                == "3 items can’t be moved to the Trash. Delete them permanently?")
    }

    /// A delete shortcut that reaches the menu while text has focus edits the
    /// text; the same item chosen with the mouse acts on the files.
    @Test func deleteMenuRouting() {
        #expect(FileOpsDeleteRouting.route(textHasFocus: true, fromKeyboard: true) == .text)
        #expect(FileOpsDeleteRouting.route(textHasFocus: true, fromKeyboard: false) == .files)
        #expect(FileOpsDeleteRouting.route(textHasFocus: false, fromKeyboard: true) == .files)
        #expect(FileOpsDeleteRouting.route(textHasFocus: false, fromKeyboard: false) == .files)
    }

    @Test func trashedAnnouncement() {
        #expect(FileOpsDeleteText.trashed(["a.txt"]) == "Moved “a.txt” to the Trash")
        #expect(FileOpsDeleteText.trashed(["a", "b"]) == "Moved 2 items to the Trash")
    }

    // MARK: Volumes without a Trash

    @Test func noTrashErrorsAreRecognised() {
        #expect(FileOpsTrashSupport.isNoTrash(CocoaError(.featureUnsupported)))
        #expect(FileOpsTrashSupport.isNoTrash(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EOPNOTSUPP))])
        #expect(FileOpsTrashSupport.isNoTrash(wrapped))
        // What trashItem reports when a volume's ".Trashes" is a file.
        let trashIsAFile = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                                   userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -1407)])
        #expect(FileOpsTrashSupport.isNoTrash(trashIsAFile))
        #expect(!FileOpsTrashSupport.isNoTrash(CocoaError(.fileWriteNoPermission)))
        #expect(!FileOpsTrashSupport.isNoTrash(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    @Test func itemsWithoutATrashAreSetAsideNotFailed() throws {
        let t = try TempDir(); defer { t.cleanup() }
        let trash = try t.dir(".FakeTrash")
        let a = try t.file("a.txt"), b = try t.file("b.txt"), c = try t.file("c.txt"), locked = try t.file("d.txt")
        let result = FileOpsTransfer.trash([a, b, c, locked]) { url in
            switch url.lastPathComponent {
            case "b.txt": throw CocoaError(.featureUnsupported)
            case "d.txt": throw CocoaError(.fileWriteNoPermission)
            default:
                let dest = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            }
        }
        #expect(result.done.map(\.source) == [a, c])
        #expect(result.noTrash == [b])
        #expect(result.failures.map(\.name) == ["d.txt"])
        #expect(FileManager.default.fileExists(atPath: b.path))   // left alone, for the permanent-delete offer

        // Undo covers what reached the Trash, and nothing else.
        let undo = try #require(FileOpsUndoStep.undoingTrash(result.done))
        #expect(undo.itemCount == 2)
        let outcome = undo.perform()
        #expect(outcome.result.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: c.path))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).isEmpty)
    }

    @Test func aMissingItemIsAFailureEvenWithANoTrashError() throws {
        let t = try TempDir(); defer { t.cleanup() }
        let gone = t.url.appendingPathComponent("gone.txt")
        let result = FileOpsTransfer.trash([gone]) { _ in throw CocoaError(.featureUnsupported) }
        #expect(result.noTrash.isEmpty)
        #expect(result.failures.map(\.name) == ["gone.txt"])
    }

    @Test func undoOfACopyReportsAnItemItCantTrash() throws {
        let t = try TempDir(); defer { t.cleanup() }
        let copy = try t.file("copy.txt")
        let result = FileOpsTransfer.trashCopies([FileOpsCreatedItem(recording: copy)]) { _ in
            throw CocoaError(.featureUnsupported)
        }
        #expect(result.noTrash.isEmpty)
        #expect(result.failures.map(\.name) == ["copy.txt"])
    }

    // MARK: Put Back

    /// Undo of Move to Trash puts each item back where it was (Finder's Put
    /// Back); Redo trashes the same items again; the second Undo restores them.
    @Test func undoPutsTrashedItemsBackAndRedoTrashesThemAgain() throws {
        let t = try TempDir(); defer { t.cleanup() }
        let trash = try t.dir(".FakeTrash")
        let trasher: FileOpsTransfer.Trasher = { url in
            let dest = FileOpsNaming.uniqueURL(in: trash, name: url.lastPathComponent,
                                               isDirectory: FileOpsNaming.isDirectory(url))
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
        let folder = try t.dir("Project")
        let file = try t.file("Project/notes.txt")
        let other = try t.file("notes.txt")   // same name, so the Trash renames one

        let trashed = FileOpsTransfer.trash([file, other], trasher: trasher)
        #expect(trashed.done.count == 2 && trashed.failures.isEmpty)
        #expect(Set(trashed.done.map(\.result.lastPathComponent)).count == 2)

        let undo = try #require(FileOpsUndoStep.undoingTrash(trashed.done))
        let putBack = undo.perform(trasher: trasher)
        #expect(putBack.result.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileOpsTransfer.exists(folder, .default))

        let redo = try #require(putBack.inverse)
        let again = redo.perform(trasher: trasher)
        #expect(again.result.done.count == 2)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let undoAgain = try #require(again.inverse)
        #expect(undoAgain.perform(trasher: trasher).result.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path) && FileManager.default.fileExists(atPath: other.path))
    }

    /// Put Back never replaces something that took the item's place meanwhile:
    /// it is reported, and the entry stays in the history to try again.
    @Test func putBackLeavesAnItemInTheWayAlone() throws {
        let t = try TempDir(); defer { t.cleanup() }
        let trash = try t.dir(".FakeTrash")
        let file = try t.file("report.txt")
        let trashed = FileOpsTransfer.trash([file]) { url in
            let dest = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
        try Data("new".utf8).write(to: file)

        var history = FileOpsUndoHistory<Void>()
        history.record(try #require(FileOpsUndoStep.undoingTrash(trashed.done)), actionName: "Move to Trash", payload: ())
        let begun = history.beginUndo()
        let running = try #require(begun)
        let outcome = running.entry.step.perform()
        history.finish(running, outcome: outcome)

        #expect(outcome.result.failures.count == 1)
        #expect(outcome.retryReasons == [.clash])
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
        #expect(history.undoActionName == "Move to Trash")   // still there to retry
        #expect(!history.canRedo)
    }
}
