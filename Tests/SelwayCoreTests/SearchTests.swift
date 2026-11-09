import Foundation
import Testing
@testable import SelwayCore

@Suite struct SearchMatcherTests {
    @Test func extensionPrefixMatchesExtensionOnly() {
        #expect(SearchMatcher.matches(name: "Report.PDF", query: ".pdf"))
        #expect(SearchMatcher.matches(name: "report.pdf", query: ".PDF"))
        #expect(!SearchMatcher.matches(name: "pdf-notes.txt", query: ".pdf"))
        #expect(!SearchMatcher.matches(name: "report.pdf.zip", query: ".pdf"))
        #expect(SearchMatcher.matches(name: "archive.tar.gz", query: ".gz"))
        #expect(!SearchMatcher.matches(name: "archive.tar.gz", query: ".tar.gz"))  // last extension only
    }

    @Test func emptyQueriesMatchNothing() {
        #expect(!SearchMatcher.matches(name: "anything", query: "."))
        #expect(!SearchMatcher.matches(name: ".hidden", query: "."))
        #expect(!SearchMatcher.matches(name: "anything", query: ""))
    }

    @Test func nameQueryIsCaseAndDiacriticInsensitive() {
        #expect(SearchMatcher.matches(name: "Quarterly REPORT.docx", query: "report"))
        #expect(SearchMatcher.matches(name: "Café menu.txt", query: "cafe"))
        #expect(SearchMatcher.matches(name: "cafe menu.txt", query: "CAFÉ"))
        #expect(SearchMatcher.matches(name: "Ünïcödé.txt", query: "unicode"))
        #expect(!SearchMatcher.matches(name: "notes.txt", query: "report"))
    }

    @Test func composedAndDecomposedFormsMatch() {
        let nfc = "caf\u{00E9}.txt", nfd = "cafe\u{0301}.txt"
        #expect(SearchMatcher.matches(name: nfd, query: "caf\u{00E9}"))
        #expect(SearchMatcher.matches(name: nfc, query: "cafe\u{0301}"))
        #expect(SearchMatcher.matches(name: "日本語ファイル.txt", query: "日本"))
        #expect(SearchMatcher.matches(name: "emoji 😀 file", query: "😀"))
    }

    #if canImport(Darwin)
    @Test func spotlightPredicateMirrorsMatcher() {
        let ext = SearchMatcher.spotlightPredicate(for: ".pdf")
        #expect(ext.predicateFormat == #"kMDItemFSExtension ==[cd] "pdf""#)
        let name = SearchMatcher.spotlightPredicate(for: "Report \"Q1\"")
        #expect(name.predicateFormat == #"kMDItemFSName CONTAINS[cd] "Report \"Q1\"""#)
        #expect(SearchMatcher.spotlightPredicate(for: ".").predicateFormat == "FALSEPREDICATE")
        #expect(SearchMatcher.spotlightPredicate(for: "").predicateFormat == "FALSEPREDICATE")
    }
    #endif

    @Test func scopesSplitIntoLocalAndSpotlight() {
        #expect(SearchScope.allCases.filter(\.isLocal) == [.thisFolder, .thisFolderRecursive])
        let here = URL(fileURLWithPath: "/somewhere")
        #expect(SearchScope.thisFolder.baseURL(currentPath: here) == here)
        #expect(SearchScope.thisFolderRecursive.baseURL(currentPath: here) == here)
    }
}

@Suite struct LocalSearchTests {
    private func names(_ urls: [URL]) -> Set<String> { Set(urls.map(\.lastPathComponent)) }

    private func tree() throws -> TempDir {
        let t = try TempDir()
        try t.file("report.pdf")
        try t.file("Report-old.PDF")
        try t.file(".report-hidden.pdf")
        try t.file("notes.txt")
        try t.file("sub/deep report.pdf")
        try t.file("sub/.hiddendir/report-in-hidden.pdf")
        try t.file("Bundle.app/Contents/report-inside-package.pdf")
        return t
    }

    @Test func flatSearchOnlyLooksInTheFolder() throws {
        let t = try tree(); defer { t.cleanup() }
        let found = LocalSearch.search(in: t.url, query: "report", recursive: false, showHidden: false)
        #expect(names(found) == ["report.pdf", "Report-old.PDF"])
        #expect(names(LocalSearch.search(in: t.url, query: ".pdf", recursive: false, showHidden: false))
                == ["report.pdf", "Report-old.PDF"])
    }

    @Test func showHiddenIsHonoured() throws {
        let t = try tree(); defer { t.cleanup() }
        #expect(names(LocalSearch.search(in: t.url, query: "report", recursive: false, showHidden: true))
                == ["report.pdf", "Report-old.PDF", ".report-hidden.pdf"])
        #expect(names(LocalSearch.search(in: t.url, query: "report", recursive: true, showHidden: true))
                    .subtracting(packageHits) == ["report.pdf", "Report-old.PDF", ".report-hidden.pdf", "deep report.pdf",
                    "report-in-hidden.pdf"])
    }

    @Test func recursiveSearchSkipsHiddenFiles() throws {
        let t = try tree(); defer { t.cleanup() }
        let found = LocalSearch.search(in: t.url, query: "report", recursive: true, showHidden: false)
        #expect(names(found).subtracting(packageHits)
                == ["report.pdf", "Report-old.PDF", "deep report.pdf"])
        #expect(found.contains(t.url.appendingPathComponent("sub/deep report.pdf")))
    }

    #if os(macOS)
    @Test func recursiveSearchSkipsPackageContents() throws {
        let t = try tree(); defer { t.cleanup() }
        for hidden in [true, false] {
            let found = LocalSearch.search(in: t.url, query: "report", recursive: true, showHidden: hidden)
            #expect(names(found).isDisjoint(with: packageHits))
            #expect(names(LocalSearch.search(in: t.url, query: "Bundle", recursive: true, showHidden: hidden))
                    == ["Bundle.app"])
        }
    }
    #endif

    /// Files inside Bundle.app — packages are a macOS concept, so Linux descends.
    private let packageHits: Set<String> = ["report-inside-package.pdf"]

    @Test func emptyQueryFindsNothing() throws {
        let t = try tree(); defer { t.cleanup() }
        #expect(LocalSearch.search(in: t.url, query: "", recursive: true, showHidden: true).isEmpty)
        #expect(LocalSearch.search(in: t.url, query: ".", recursive: true, showHidden: true).isEmpty)
    }

    @Test(arguments: [true, false])
    func resultsThroughASymlinkedFolderUseTheLinkPath(recursive: Bool) throws {
        let t = try TempDir(); defer { t.cleanup() }
        try t.file("real/hit.txt")
        try t.file("real/sub/hit2.txt")
        let link = try t.link("Downloads", to: t.url.appendingPathComponent("real").path)
        let found = LocalSearch.search(in: link, query: "hit", recursive: recursive, showHidden: false)
        let expected = recursive
            ? ["Downloads/hit.txt", "Downloads/sub/hit2.txt"] : ["Downloads/hit.txt"]
        #expect(Set(found.map(\.path)) == Set(expected.map { t.url.appendingPathComponent($0).path }))
    }

    @Test func symlinkCyclesDoNotLoop() throws {
        let t = try TempDir(); defer { t.cleanup() }
        try t.file("a/match.txt")
        try t.link("a/up", to: "..")          // a/up → t
        try t.link("a/self", to: ".")         // a/self → a
        try t.link("loop", to: "loop")        // self-loop
        let found = LocalSearch.search(in: t.url, query: "match", recursive: true, showHidden: false)
        #expect(found.map(\.lastPathComponent) == ["match.txt"])
        // Searching *from* a looping link finds nothing rather than hanging.
        #expect(LocalSearch.search(in: t.url.appendingPathComponent("loop"), query: "x",
                                   recursive: true, showHidden: false).isEmpty)
    }

    @Test func stopsAtTheResultCap() throws {
        let t = try TempDir(); defer { t.cleanup() }
        for i in 0..<30 { try t.file("d\(i % 3)/hit\(i).txt") }
        #expect(LocalSearch.search(in: t.url, query: "hit", recursive: true, showHidden: false,
                                   limit: 10).count == 10)
        #expect(LocalSearch.search(in: t.url.appendingPathComponent("d0"), query: "hit",
                                   recursive: false, showHidden: false, limit: 4).count == 4)
        #expect(LocalSearch.resultLimit == 5_000)
    }

    @Test func cancellationReturnsNothing() throws {
        let t = try tree(); defer { t.cleanup() }
        #expect(LocalSearch.search(in: t.url, query: "report", recursive: true, showHidden: false,
                                   isCancelled: { true }).isEmpty)
        #expect(LocalSearch.search(in: t.url, query: "report", recursive: false, showHidden: false,
                                   isCancelled: { true }).isEmpty)
    }

    /// Cancelled part-way through the walk: the matches found so far are
    /// dropped and the walk stops right away.
    @Test(arguments: [true, false])
    func cancellationMidWalkReturnsNothingAndStops(recursive: Bool) throws {
        let t = try TempDir(); defer { t.cleanup() }
        for i in 0..<40 { try t.file(recursive ? "d\(i % 4)/hit\(i).txt" : "hit\(i).txt") }
        final class Counter { var calls = 0 }
        let counter = Counter()
        let cancelAfter = 15
        let found = LocalSearch.search(in: t.url, query: "hit", recursive: recursive, showHidden: false,
                                       isCancelled: { counter.calls += 1; return counter.calls > cancelAfter })
        #expect(found.isEmpty)
        #expect(counter.calls == cancelAfter + 1)
        // Sanity: uncancelled, the same walk finds everything.
        #expect(LocalSearch.search(in: t.url, query: "hit", recursive: recursive,
                                   showHidden: false).count == 40)
    }

    @Test func missingFolderFindsNothing() {
        #expect(LocalSearch.search(in: URL(fileURLWithPath: "/no/such/folder/\(UUID())"), query: "a",
                                   recursive: true, showHidden: false).isEmpty)
    }
}

@Suite struct SearchRunStateTests {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    private let docs = URL(fileURLWithPath: "/Users/me/Documents", isDirectory: true)

    @Test func onlyTheLatestSearchMayPublish() {
        var run = SearchRunState()
        let first = run.start(scope: .thisFolder, directory: home).token
        #expect(run.accepts(first))
        let second = run.start(scope: .thisFolder, directory: home).token
        #expect(!run.accepts(first))          // slow first search finishing late
        #expect(run.accepts(second))
    }

    @Test func cancelAndResetRejectRunningWork() {
        var run = SearchRunState()
        let token = run.start(scope: .entireMac, directory: home).token
        run.cancel()
        #expect(!run.accepts(token))

        let again = run.start(scope: .entireMac, directory: home).token
        run.reset()                            // query cleared
        #expect(!run.accepts(again))           // a queued Spotlight update is dropped
        #expect(run.resultsOrigin == nil)
    }

    @Test func resultsFromAnotherScopeOrFolderAreClearedAtOnce() {
        var run = SearchRunState()
        #expect(run.start(scope: .entireMac, directory: home).clearResults)
        // Refining the query in the same place keeps the old hits until new ones arrive.
        #expect(!run.start(scope: .entireMac, directory: home).clearResults)
        #expect(!run.start(scope: .entireMac, directory: URL(fileURLWithPath: "/Users/me/")).clearResults)
        #expect(run.start(scope: .thisFolder, directory: home).clearResults)
        #expect(run.start(scope: .thisFolder, directory: docs).clearResults)
        run.reset()
        #expect(run.start(scope: .thisFolder, directory: docs).clearResults)
    }
}

@Suite struct SearchRefreshTests {
    private let base = URL(fileURLWithPath: "/Users/me/Projects", isDirectory: true)
    private func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

    @Test func thisFolderRerunsOnlyForItsOwnFolder() {
        #expect(SearchRefresh.shouldRerun(query: "a", scope: .thisFolder, base: base, changed: url("/Users/me/Projects")))
        // Spelled with a trailing slash, as watched folders sometimes are.
        #expect(SearchRefresh.shouldRerun(query: "a", scope: .thisFolder, base: base, changed: url("/Users/me/Projects/")))
        #expect(!SearchRefresh.shouldRerun(query: "a", scope: .thisFolder, base: base, changed: url("/Users/me/Projects/sub")))
        #expect(!SearchRefresh.shouldRerun(query: "a", scope: .thisFolder, base: base, changed: url("/Users/me")))
    }

    @Test func recursiveSearchRerunsForAnyFolderInside() {
        let s = SearchScope.thisFolderRecursive
        #expect(SearchRefresh.shouldRerun(query: "a", scope: s, base: base, changed: url("/Users/me/Projects")))
        #expect(SearchRefresh.shouldRerun(query: "a", scope: s, base: base, changed: url("/Users/me/Projects/x/y")))
        #expect(!SearchRefresh.shouldRerun(query: "a", scope: s, base: base, changed: url("/Users/me/Projects2")))
        #expect(!SearchRefresh.shouldRerun(query: "a", scope: s, base: base, changed: url("/Users/me")))
    }

    /// Spotlight scopes update themselves; no query means no search to re-run.
    @Test func spotlightScopesAndEmptyQueriesDoNotRerun() {
        for scope in SearchScope.allCases where !scope.isLocal {
            #expect(!SearchRefresh.shouldRerun(query: "a", scope: scope, base: base, changed: base))
        }
        #expect(!SearchRefresh.shouldRerun(query: "", scope: .thisFolder, base: base, changed: base))
    }

    @Test func prunesOnlyMissingItemsInsideTheChangedFolder() {
        let rows = ["/p/a.txt", "/p/gone.txt", "/p/sub/gone2.txt", "/q/gone.txt", "/p"].map(url)
        var checked: [String] = []
        let kept = SearchRefresh.pruned(rows, afterChangeIn: url("/p"), url: { $0 }) { u in
            checked.append(u.path)
            return !u.lastPathComponent.hasPrefix("gone")
        }
        #expect(kept?.map(\.path) == ["/p/a.txt", "/q/gone.txt", "/p"])
        // Rows outside the changed folder (and the folder itself) aren't even looked at.
        #expect(checked == ["/p/a.txt", "/p/gone.txt", "/p/sub/gone2.txt"])
        #expect(SearchRefresh.pruned(rows, afterChangeIn: url("/p"), url: { $0 }, exists: { _ in true }) == nil)
    }

    @Test func prunesRealFiles() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let a = try dir.file("a.txt"), b = try dir.file("b.txt")
        let link = try dir.link("dangling", to: "nowhere")
        try FileManager.default.removeItem(at: b)
        let kept = SearchRefresh.pruned([a, b, link], afterChangeIn: dir.url, url: { $0 },
                                        exists: { FileOpsTransfer.exists($0, .default) })
        #expect(kept == [a, link])            // a dangling symlink is still an item
    }

    /// Feeds a script of calls through one throttle and returns the answers
    /// (`#expect` can't take a mutating call directly).
    private func answers(_ calls: [String]) -> [Bool] {
        var t = SearchRefreshThrottle()
        return calls.map { call in
            switch call {
            case "request": return t.request()
            case "fire":    return t.fire(holding: false)
            case "hold":    return t.fire(holding: true)
            case "drop":    t.dropDeferred(); return false
            default:        return t.resume()
            }
        }
    }

    @Test func throttleOwesNothingOnceTheSearchRanAgain() {
        // held behind a rename, then run afresh (a pane shown again): the
        // rename ending runs nothing more, and the next change schedules
        #expect(answers(["request", "hold", "drop", "resume", "request"])
                == [true, false, false, false, true])
    }

    @Test func throttleCoalescesABurst() {
        // schedule, two changes ride along, run, a later change schedules again
        #expect(answers(["request", "request", "request", "fire", "request"])
                == [true, false, false, true, true])
    }

    @Test func throttleWaitsWhileHolding() {
        // scheduled, inline rename open, already waiting, rename ended → run,
        // nothing left; then a normal run and a resume with nothing waiting
        #expect(answers(["request", "hold", "request", "resume", "resume", "request", "fire", "resume"])
                == [true, false, false, true, false, true, true, false])
    }
}

@Suite struct SearchRerunStateTests {
    /// Runs a script of calls; returns the answers of the ones that answer.
    private func answers(_ calls: [String]) -> [Bool] {
        var r = SearchRerunState()
        var out: [Bool] = []
        for call in calls {
            switch call {
            case "refresh":  out.append(r.requestRefresh())
            case "started":  r.walkStarted()
            case "finished": out.append(r.walkFinished())
            default:         r.reset()
            }
        }
        return out
    }

    @Test func refreshWithNothingRunningStartsAtOnce() {
        #expect(answers(["refresh"]) == [true])
        #expect(answers(["started", "finished", "refresh"]) == [false, true])
    }

    /// The bug: refreshes during a long walk cancelled it every time. Now they
    /// collapse into one more run after it.
    @Test func refreshesDuringAWalkRunOnceMoreAfterIt() {
        #expect(answers(["started", "refresh", "refresh", "refresh", "finished"]) == [false, false, false, true])
        // The extra run sees every change; a quiet one finishes for good.
        #expect(answers(["started", "refresh", "finished", "started", "finished"]) == [false, true, false])
    }

    /// The user starting another search wins at once and forgets the pending run.
    @Test func userSearchResets() {
        #expect(answers(["started", "refresh", "reset", "refresh"]) == [false, true])
        #expect(answers(["started", "refresh", "reset", "started", "finished"]) == [false, false])
    }
}
