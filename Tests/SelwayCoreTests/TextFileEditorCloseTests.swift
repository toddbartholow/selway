import Foundation
import Testing
@testable import SelwayCore

// Closing editor tabs and windows (Core/TextFileEditorClose.swift). The bug these
// pin: ⌘W on the only, modified tab → Don't Save removed the document but left the
// window open (performClose ran inside the alert's callback and was refused),
// still showing and accepting text that could no longer be saved.

// MARK: - Tab close plan

@Test func closingTheOnlyTabClosesTheWindow() {
    let plan = EditorTabClosePlan.closing("a", tabs: ["a"], active: "a")
    #expect(plan.remaining.isEmpty)
    #expect(plan.active == nil)
    #expect(plan.closesWindow)
}

@Test func closingTheActiveTabShowsTheLastRemaining() {
    let plan = EditorTabClosePlan.closing("b", tabs: ["a", "b", "c"], active: "b")
    #expect(plan.remaining == ["a", "c"])
    #expect(plan.active == "c")
    #expect(!plan.closesWindow)
}

@Test func closingAnotherTabKeepsTheActiveOne() {
    let plan = EditorTabClosePlan.closing("c", tabs: ["a", "b", "c"], active: "a")
    #expect(plan.remaining == ["a", "b"])
    #expect(plan.active == "a")
    #expect(!plan.closesWindow)
}

@Test func closingAnUnknownTabChangesNothing() {
    let plan = EditorTabClosePlan.closing("zz", tabs: ["a", "b"], active: "b")
    #expect(plan.remaining == ["a", "b"])
    #expect(plan.active == "b")
    #expect(!plan.closesWindow)
    // A stale active id never survives: some open tab is always shown.
    #expect(EditorTabClosePlan.closing("a", tabs: ["a", "b"], active: "gone").active == "b")
    #expect(EditorTabClosePlan.closing("a", tabs: ["a", "b"], active: nil).active == "b")
}

// MARK: - Deferred window close

/// A run loop stand-in: scheduled work runs only when `turn()` is called.
private final class FakeRunLoop {
    var queue: [() -> Void] = []
    func schedule(_ work: @escaping () -> Void) { queue.append(work) }
    func turn() {
        let work = queue
        queue = []
        work.forEach { $0() }
    }
}

@Test func deferredCloseNeverRunsInsideTheCallerAndRunsOnTheNextTurn() {
    let loop = FakeRunLoop()
    let closer = EditorDeferredClose(schedule: loop.schedule)
    var closed = 0
    // Called from inside an alert's completion handler: the sheet is still attached,
    // so closing now would be refused. Nothing may happen until the handler returns.
    closer.request { closed += 1 }
    #expect(closed == 0)
    #expect(closer.isPending)
    loop.turn()
    #expect(closed == 1)
    #expect(!closer.isPending)
    loop.turn()
    #expect(closed == 1, "runs once")
}

@Test func deferredCloseMergesRequestsAndUsesTheLatest() {
    let loop = FakeRunLoop()
    let closer = EditorDeferredClose(schedule: loop.schedule)
    var log: [String] = []
    closer.request { log.append("first") }
    closer.request { log.append("second") }
    #expect(loop.queue.count == 1, "scheduled once")
    loop.turn()
    #expect(log == ["second"])

    // After it ran, a new request schedules again.
    closer.request { log.append("third") }
    loop.turn()
    #expect(log == ["second", "third"])
}

@Test func deferredCloseIsSkippedWhenNoLongerWanted() {
    let loop = FakeRunLoop()
    let closer = EditorDeferredClose(schedule: loop.schedule)
    var tabs = 0
    var closed = false
    closer.request(when: { tabs == 0 }) { closed = true }
    tabs = 1   // a file was opened in the window before the close ran
    loop.turn()
    #expect(!closed)
    #expect(!closer.isPending)

    tabs = 0
    closer.request(when: { tabs == 0 }) { closed = true }
    loop.turn()
    #expect(closed)
}

@Test func deferredCloseOutlivedByItsOwnerDoesNothing() {
    let loop = FakeRunLoop()
    var closer: EditorDeferredClose? = EditorDeferredClose(schedule: loop.schedule)
    var closed = false
    closer?.request { closed = true }
    closer = nil   // the window manager went away first
    loop.turn()
    #expect(!closed)
}
