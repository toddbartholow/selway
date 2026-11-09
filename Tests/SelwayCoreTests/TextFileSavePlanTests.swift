import Foundation
import Testing
@testable import SelwayCore

// MARK: - Alert tables: titles and meanings stay paired

/// NSAlert reports the clicked button by position. These pin which title sits at
/// each position and what clicking it does, so reordering titles can't turn
/// "Cancel" into "discard my edits".
@Test func closeAlertButtonsMeanWhatTheySay() {
    let spec = EditorAlerts.confirmClose(documentName: "notes.txt")
    #expect(spec.buttons.map(\.title) == ["Save", "Cancel", "Don't Save"])
    #expect(spec.choice(forButtonAt: 0) == .save)
    #expect(spec.choice(forButtonAt: 1) == .cancel)
    #expect(spec.choice(forButtonAt: 2) == .discard)
    #expect(spec.buttons[2].title == "Don't Save" && spec.buttons[2].isDestructive)
    #expect(spec.buttons[2].commandKey == "d")
    #expect(spec.choice(forButtonAt: 3) == .cancel, "anything unexpected keeps the edits")
    #expect(spec.choice(forButtonAt: -1000) == .cancel)
    #expect(spec.message.contains("“notes.txt”"))
}

@Test func closeAllAlertListsDocuments() {
    let one = EditorAlerts.confirmCloseAll(documentNames: ["a.md"])
    #expect(one == EditorAlerts.confirmClose(documentName: "a.md"))

    let names = (1...10).map { "f\($0).txt" }
    let many = EditorAlerts.confirmCloseAll(documentNames: names)
    #expect(many.buttons.map(\.title) == ["Save All", "Cancel", "Don't Save"])
    #expect(many.buttons.map(\.choice) == [.save, .cancel, .discard])
    #expect(many.message == "You have unsaved changes in 10 documents.")
    #expect(many.info.contains("• f8.txt") && !many.info.contains("• f9.txt"))
    #expect(many.info.contains("\n…and 2 more\n"))
    #expect(!many.info.contains("…and …and"))
}

@Test func reloadAlertButtons() {
    let spec = EditorAlerts.offerReload(documentName: "x")
    #expect(spec.buttons.map(\.title) == ["Reload", "Keep Current Version"])
    #expect(spec.choice(forButtonAt: 0) == true)
    #expect(spec.choice(forButtonAt: 1) == false)
    #expect(spec.choice(forButtonAt: 5) == false)
}

// MARK: - Save flow decisions

private func askSpec(_ step: TextFileSavePlan.Step) -> EditorAlertSpec<TextFileSavePlan.Choice>? {
    if case .ask(let spec) = step { return spec }
    return nil
}

@Test func conflictOnExistingFileOffersOverwriteCancelReload() throws {
    let step = TextFileSavePlan.step(after: TextFileIOError.changedOnDisk, name: "a.txt", fileExists: true)
    let spec = try #require(askSpec(step))
    #expect(spec.message == "“a.txt” was changed by another application since you opened it.")
    #expect(spec.buttons.map(\.title) == ["Overwrite", "Cancel", "Reload from Disk"])
    #expect(spec.buttons.map(\.choice) == [.overwrite, .cancel, .reload])
    #expect(spec.fallback == .cancel)
}

@Test func conflictOnMissingFileOffersToRecreate() throws {
    let step = TextFileSavePlan.step(after: TextFileIOError.changedOnDisk, name: "a.txt", fileExists: false)
    let spec = try #require(askSpec(step))
    #expect(spec.message == "“a.txt” was moved or deleted since you opened it.")
    #expect(spec.buttons.map(\.title) == ["Save", "Cancel"])
    #expect(spec.buttons.map(\.choice) == [.recreate, .cancel])
}

@Test func unencodableOffersUTF8() throws {
    let step = TextFileSavePlan.step(after: TextFileIOError.unencodable(encodingName: "ISO Latin-1"),
                                     name: "a.txt", fileExists: true)
    let spec = try #require(askSpec(step))
    #expect(spec.message == "“a.txt” can't be saved as ISO Latin-1.")
    #expect(spec.buttons.map(\.choice) == [.saveAsUTF8, .cancel])
}

@Test(arguments: [
    TextFileIOError.redirected(to: "/Users/me/.zshrc"),
    .folderReplaced("/Users/Shared/project"),
    .notWritable,
    .notRegularFile,
    .io("disk full"),
])
func otherErrorsAreShownNotAsked(error: TextFileIOError) {
    let step = TextFileSavePlan.step(after: error, name: "a.txt", fileExists: true)
    #expect(step == .fail(message: "“a.txt” couldn't be saved.", info: error.localizedDescription))
}

@Test func redirectErrorNamesTheLinkDestination() {
    let info = TextFileIOError.redirected(to: "/Users/me/.zshrc").localizedDescription
    #expect(info.contains("“/Users/me/.zshrc”"))
}

@Test func answersLeadToTheRightRetry() {
    let latin = TextFileFormat(encoding: .isoLatin1, hasBOM: false, lineEnding: .crlf)
    #expect(TextFileSavePlan.next(after: .overwrite, format: latin, force: false) == .retry(format: latin, force: true))
    #expect(TextFileSavePlan.next(after: .recreate, format: latin, force: false) == .retry(format: latin, force: true))
    #expect(TextFileSavePlan.next(after: .reload, format: latin, force: false) == .reloadRequested)
    #expect(TextFileSavePlan.next(after: .cancel, format: latin, force: true) == .cancelled)

    let bom16 = TextFileFormat(encoding: .utf16LittleEndian, hasBOM: true, lineEnding: .crlf)
    var utf8 = bom16
    utf8.encoding = .utf8
    utf8.hasBOM = false
    // UTF-8 keeps the line endings and doesn't add force (a later conflict still asks).
    #expect(TextFileSavePlan.next(after: .saveAsUTF8, format: bom16, force: false) == .retry(format: utf8, force: false))
    #expect(TextFileSavePlan.next(after: .saveAsUTF8, format: bom16, force: true) == .retry(format: utf8, force: true))
}

// MARK: - The code editor's reply to getDocContent

@Test func docReplyParsesOnlyCompleteReplies() {
    #expect(EditorDocReply.parse(nil) == nil)
    #expect(EditorDocReply.parse(NSNull()) == nil, "unknown id → null")
    #expect(EditorDocReply.parse("text") == nil)
    #expect(EditorDocReply.parse([String: Any]()) == nil)
    #expect(EditorDocReply.parse(["version": 1]) == nil, "missing text")
    #expect(EditorDocReply.parse(["text": 5, "version": 1]) == nil, "non-string text")
    #expect(EditorDocReply.parse(["text": "a"]) == nil, "missing version")
    #expect(EditorDocReply.parse(["text": "a", "version": "3"]) == nil, "non-numeric version")
    #expect(EditorDocReply.parse(["text": "a", "version": 1.5]) == nil, "fractional version")
    #expect(EditorDocReply.parse(["text": "a", "version": Double.nan]) == nil)

    let valid = EditorDocReply.parse(["text": "hello", "version": 3])
    #expect(valid?.text == "hello" && valid?.version == 3)
    let number = EditorDocReply.parse(["text": "", "version": NSNumber(value: 7)])
    #expect(number?.text == "" && number?.version == 7, "an empty document the page vouches for is valid")
    let double = EditorDocReply.parse(["text": "x", "version": 2.0])
    #expect(double?.version == 2)
}

// MARK: - Save queue

@Test func secondSaveWaitsForTheFirst() {
    let queue = TextFileSaveQueue<String>()
    var results: [Bool] = []
    #expect(queue.begin("a") { _ in Issue.record("the first save doesn't wait") })
    #expect(queue.isSaving("a"))
    #expect(!queue.begin("a") { results.append($0) })
    #expect(!queue.begin("a") { results.append($0) })
    #expect(queue.begin("b") { _ in }, "other documents don't wait")
    #expect(results.isEmpty)
    queue.finish("a", ok: true)
    #expect(results == [true, true])
    #expect(!queue.isSaving("a"))
    queue.finish("a", ok: false)
    #expect(results == [true, true], "waiters are told once")

    #expect(!queue.begin("b") { results.append($0) })
    queue.failAll()
    #expect(results == [true, true, false])
    #expect(!queue.isSaving("b"))
}

// MARK: - Crash loop guard

@Test func crashGuardStopsAfterThreeCrashesInAMinute() {
    var guardrail = EditorCrashGuard()
    let t0 = Date(timeIntervalSince1970: 1_000)
    let answers = [0, 10, 20].map { guardrail.shouldReopen(afterCrashAt: t0.addingTimeInterval(Double($0))) }
    #expect(answers == [true, true, false])

    var spaced = EditorCrashGuard()
    let spacedAnswers = (0..<10).map { spaced.shouldReopen(afterCrashAt: t0.addingTimeInterval(Double($0) * 61)) }
    #expect(spacedAnswers.allSatisfy { $0 })
}

// MARK: - Quit review sequencing

/// Drives TextFileQuitReview the way AppKit and the editors do.
private final class QuitHarness {
    let review = TextFileQuitReview()
    var answer: EditorCloseChoice? = .save
    var asked: [[String]] = []
    var scheduled: [() -> Void] = []
    var saveCalls = 0
    var pendingSave: ((Bool) -> Void)?
    var replies: [Bool] = []

    func quit(_ unsaved: [String] = ["a.txt"]) -> TextFileQuitReview.Reply {
        review.shouldTerminate(
            unsaved: unsaved,
            ask: { names, respond in
                self.asked.append(names)
                if let answer = self.answer { respond(answer) }
            },
            schedule: { self.scheduled.append($0) },
            saveAll: { done in self.saveCalls += 1; self.pendingSave = done },
            reply: { self.replies.append($0) })
    }

    func runScheduled() {
        let work = scheduled
        scheduled = []
        work.forEach { $0() }
    }
}

@Test func quitWithoutUnsavedChangesDoesntAsk() {
    let h = QuitHarness()
    #expect(h.quit([]) == .now)
    #expect(h.asked.isEmpty)
    #expect(!h.review.isQuitting)
}

@Test(arguments: [(EditorCloseChoice.discard, TextFileQuitReview.Reply.now), (.cancel, .cancel)])
func dontSaveQuitsAndCancelStays(choice: EditorCloseChoice, expected: TextFileQuitReview.Reply) {
    let h = QuitHarness()
    h.answer = choice
    #expect(h.quit() == expected)
    #expect(h.scheduled.isEmpty && h.saveCalls == 0 && h.replies.isEmpty)
    #expect(!h.review.isQuitting)
}

@Test func unansweredQuestionCancels() {
    let h = QuitHarness()
    h.answer = nil
    #expect(h.quit() == .cancel)
    #expect(!h.review.isQuitting)
}

@Test(arguments: [true, false])
func saveRepliesLaterExactlyOnce(saved: Bool) throws {
    let h = QuitHarness()
    #expect(h.quit(["a.txt", "b.md"]) == .later)
    #expect(h.asked == [["a.txt", "b.md"]])
    #expect(h.saveCalls == 0, "saving starts only after .later was returned")
    #expect(h.review.isQuitting)

    // A second quit request (the updater, a second ⌘Q) while saving: refused, not asked.
    #expect(h.quit() == .cancel)
    #expect(h.asked.count == 1)

    h.runScheduled()
    #expect(h.saveCalls == 1)
    #expect(h.review.isQuitting, "still deciding until the saves finish")
    let done = try #require(h.pendingSave)
    done(saved)
    done(!saved)
    #expect(h.replies == [saved], "one reply; a failed save cancels the quit")
    #expect(!h.review.isQuitting)

    // The next quit asks again.
    h.answer = .cancel
    #expect(h.quit() == .cancel)
    #expect(h.asked.count == 2)
}

@Test func runInOrderStopsAtFirstFailureAndCompletesOnce() {
    var ran: [Int] = []
    var results: [Bool] = []
    TextFileQuitReview.runInOrder([
        { done in ran.append(0); done(true); done(true) },
        { done in ran.append(1); done(false); done(true) },
        { done in ran.append(2); done(true) },
    ]) { results.append($0) }
    #expect(ran == [0, 1])
    #expect(results == [false])

    results = []
    TextFileQuitReview.runInOrder([]) { results.append($0) }
    #expect(results == [true])

    results = []
    var later: ((Bool) -> Void)?
    TextFileQuitReview.runInOrder([{ later = $0 }, { $0(true) }]) { results.append($0) }
    #expect(results.isEmpty, "waits for an asynchronous step")
    later?(true)
    #expect(results == [true])
}
