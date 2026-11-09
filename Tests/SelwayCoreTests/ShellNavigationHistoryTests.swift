import Foundation
import Testing
@testable import SelwayCore

@Suite struct ShellNavigationHistoryTests {
    private let a = URL(fileURLWithPath: "/tmp/nav/a")
    private let b = URL(fileURLWithPath: "/tmp/nav/b")
    private let c = URL(fileURLWithPath: "/tmp/nav/c")
    private let d = URL(fileURLWithPath: "/tmp/nav/d")
    private let all: (BrowserLocation) -> Bool = { _ in true }

    private func history(_ urls: URL...) -> NavigationHistory {
        var h = NavigationHistory()
        for url in urls { h.visit(url) }
        return h
    }

    @Test func startsWithNowhereToGo() {
        var h = NavigationHistory(current: a)
        #expect(!h.canGoBack && !h.canGoForward)
        #expect(h.goBack(exists: all) == nil)
        #expect(h.goForward(exists: all) == nil)
        #expect(h.current == .folder(a))
    }

    @Test func visitsBuildTheBackList() {
        let h = history(a, b, c)
        #expect(h.current == .folder(c))
        #expect(h.backStack == [.folder(a), .folder(b)])
        #expect(h.canGoBack && !h.canGoForward)
    }

    @Test func backThenForwardRetraceTheSteps() {
        var h = history(a, b, c)
        #expect(h.goBack(exists: all) == .folder(b))
        #expect(h.goBack(exists: all) == .folder(a))
        #expect(!h.canGoBack)
        #expect(h.forwardStack == [.folder(c), .folder(b)])
        #expect(h.goForward(exists: all) == .folder(b))
        #expect(h.goForward(exists: all) == .folder(c))
        #expect(!h.canGoForward)
        #expect(h.backStack == [.folder(a), .folder(b)])
    }

    @Test func visitingAfterGoingBackDropsForward() {
        var h = history(a, b, c)
        _ = h.goBack(exists: all)            // at b
        h.visit(d)
        #expect(!h.canGoForward)
        #expect(h.backStack == [.folder(a), .folder(b)])
        #expect(h.current == .folder(d))
    }

    @Test func visitingTheFolderShownChangesNothing() {
        var h = history(a, b)
        _ = h.goBack(exists: all)            // at a, forward [b]
        h.visit(URL(fileURLWithPath: "/tmp/nav/a/"))   // same folder, other spelling
        #expect(h.canGoForward)
        #expect(h.backStack.isEmpty)
        #expect(h.current == .folder(a))
    }

    @Test func missingFoldersAreSkippedAndDropped() {
        var h = history(a, b, c, d)
        let gone: Set<URL> = [b, c]
        #expect(h.goBack(exists: { $0.folder.map { !gone.contains($0) } ?? true }) == .folder(a))
        #expect(h.backStack.isEmpty)
        #expect(h.forwardStack == [.folder(d)])
    }

    @Test func nothingLeftWhenEveryStepIsMissing() {
        var h = history(a, b)
        #expect(h.goBack(exists: { _ in false }) == nil)
        #expect(h.current == .folder(b))     // stays put
        #expect(!h.canGoBack)
        #expect(!h.canGoForward)
    }

    @Test func copiesOfTheCurrentFolderAreSkipped() {
        // a → b → a → c, b gone: Back from c reaches a; the next Back would be b
        // (gone) and then a again, which is the folder shown.
        var h = history(a, b, a, c)
        let exists: (BrowserLocation) -> Bool = { $0 != .folder(b) }
        #expect(h.goBack(exists: exists) == .folder(a))
        #expect(h.goBack(exists: exists) == nil)
        #expect(h.current == .folder(a))
    }

    @Test func forwardSkipsMissingFoldersToo() {
        var h = history(a, b, c)
        _ = h.goBack(exists: all)
        _ = h.goBack(exists: all)            // at a, forward [c, b]
        #expect(h.goForward(exists: { $0 != .folder(b) }) == .folder(c))
        #expect(h.backStack == [.folder(a)])
    }

    @Test func historyIsBounded() {
        var h = NavigationHistory()
        for i in 0...(NavigationHistory.limit + 10) { h.visit(URL(fileURLWithPath: "/tmp/nav/\(i)")) }
        #expect(h.backStack.count == NavigationHistory.limit)
        #expect(h.backStack.first == .folder(URL(fileURLWithPath: "/tmp/nav/10")))
    }

    @Test func columnSelectionMovesWithoutAStep() {
        var h = history(a, b)
        h.replaceCurrent(c)                  // selected in the column browser
        h.replaceCurrent(d)
        #expect(h.current == .folder(d))
        #expect(h.backStack == [.folder(a)])
        #expect(h.goBack(exists: all) == .folder(a))  // straight back past the column selections
        #expect(h.forwardStack == [.folder(d)])
    }

    @Test func realNavigationAfterColumnSelectionKeepsTheSelectedFolder() {
        var h = history(a)
        h.replaceCurrent(b)
        h.visit(c)
        #expect(h.backStack == [.folder(b)])
    }

    @Test func enclosingFolderStopsAtTheRoot() {
        #expect(!NavigationHistory().canGoUp)
        #expect(!NavigationHistory(current: URL(fileURLWithPath: "/")).canGoUp)
        #expect(!NavigationHistory(current: .computer).canGoUp)
        #expect(NavigationHistory(current: a).canGoUp)
        #expect(NavigationHistory(current: URL(fileURLWithPath: "/Users")).canGoUp)
    }

    @Test func arrivingFromTheColumnBrowserIsNotAStep() {
        var h = history(a, b)
        h.arrive(at: c, columnSelection: c)                          // a folder selected in a column
        #expect(h.current == .folder(c) && h.backStack == [.folder(a)])
        h.arrive(at: URL(fileURLWithPath: "/tmp/nav/d/"), columnSelection: d)   // another spelling
        #expect(h.backStack == [.folder(a)])
        h.arrive(at: a, columnSelection: nil)                        // real navigation
        #expect(h.backStack == [.folder(a), .folder(URL(fileURLWithPath: "/tmp/nav/d/"))])
    }

    @Test func aColumnSelectionForAnotherFolderStillCountsAsAStep() {
        // The browser asked for c, but the window ended up elsewhere (sidebar click
        // in between): that's a real step.
        var h = history(a)
        h.arrive(at: b, columnSelection: c)
        #expect(h.backStack == [.folder(a)])
        #expect(h.current == .folder(b))
    }

    @Test func arrivingAfterBackChangesNothing() {
        var h = history(a, b)
        let url = h.goBack(exists: all)                              // at a
        h.arrive(at: url!, columnSelection: nil)
        #expect(h.canGoForward)
        #expect(h.backStack.isEmpty)
    }

    @Test func computerParticipatesInHistoryAndAlwaysExists() {
        var h = history(a, b)
        h.visit(.computer)
        #expect(!h.canGoUp)
        #expect(h.backStack == [.folder(a), .folder(b)])
        var consulted = false
        #expect(h.goBack(exists: { _ in consulted = true; return true }) == .folder(b))
        #expect(consulted)
        consulted = false
        #expect(h.goForward(exists: { _ in consulted = true; return false }) == .computer)
        #expect(!consulted)
        #expect(h.current == .computer)
        #expect(!h.canGoUp)
    }

    @Test func computerIsSkippedAsTheCurrentHistoryEntryWithoutExistsCheck() {
        var h = NavigationHistory(current: .computer)
        h.visit(a)
        var consulted = false
        #expect(h.goBack(exists: { _ in consulted = true; return false }) == .computer)
        #expect(!consulted)
    }
}
