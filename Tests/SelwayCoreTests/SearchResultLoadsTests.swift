import Foundation
import Testing
@testable import SelwayCore

/// Reading the search results and patching the ones changed in place: when a
/// change waits, is held for a rename, or runs the search again.
struct SearchResultLoadsTests {
    private let beta: Set<String> = ["/fixture/beta.log"]
    private let grown = FileItem.fixture("beta.log", size: 5_000)

    @Test func aPatchMayStartWhenNothingIsBeingRead() {
        var loads = SearchResultLoads()
        let now = loads.changed(beta, renaming: false)
        #expect(now)
    }

    /// A new search's first results: the list is empty while they're read, and
    /// a file saved meanwhile is patched in once they land, not lost.
    @Test func changesWhileResultsAreReadArePatchedOnceTheyLand() {
        var loads = SearchResultLoads()
        let conversion = loads.startConversion()
        let now = loads.changed(beta, renaming: false)
        #expect(!now)
        #expect(loads.takeDeferred() == nil)            // not before they land
        let landed = loads.finishConversion(conversion)
        #expect(landed)
        #expect(loads.takeDeferred() == beta)
        #expect(loads.takeDeferred() == nil)
    }

    @Test func changesWhileAPatchIsReadWaitForIt() {
        var loads = SearchResultLoads()
        let patch = loads.startPatch()
        let now = loads.changed(["/fixture/alpha.txt"], renaming: false)
        #expect(!now)
        #expect(loads.finishPatch(patch, paths: beta, result: .patched([grown]), renaming: false) == .show([grown]))
        #expect(loads.takeDeferred() == ["/fixture/alpha.txt"])
    }

    @Test func changesDuringARenameAreHeldUntilItEnds() {
        var loads = SearchResultLoads()
        let now = loads.changed(beta, renaming: true)
        #expect(!now)
        #expect(loads.takeDeferred() == nil)
        #expect(loads.takeHeld() == beta)
        #expect(loads.takeHeld() == nil)                // taken once
    }

    /// A patch that started before the rename and lands during it isn't shown:
    /// it's held, like the changes that come during the rename.
    @Test func aPatchLandingDuringARenameIsHeld() {
        var loads = SearchResultLoads()
        let patch = loads.startPatch()
        #expect(loads.finishPatch(patch, paths: beta, result: .patched([grown]), renaming: true) == .nothing)
        #expect(loads.takeHeld() == beta)
    }

    @Test func aGoneOrHiddenResultRunsTheSearchAgain() {
        var loads = SearchResultLoads()
        let patch = loads.startPatch()
        #expect(loads.finishPatch(patch, paths: beta, result: .needsFullListing, renaming: false) == .rerun)
    }

    @Test func aResultReadTheSameShowsNothingNew() {
        var loads = SearchResultLoads()
        let patch = loads.startPatch()
        #expect(loads.finishPatch(patch, paths: beta, result: .unchanged, renaming: false) == .nothing)
    }

    /// Results converted again (a new search, a re-sort) replace a patch in
    /// flight, and read every result: what was held or waiting is in them.
    @Test func aConversionReplacesAPatchAndTakesInWhatWaited() {
        var loads = SearchResultLoads()
        _ = loads.changed(beta, renaming: true)
        let patch = loads.startPatch()
        _ = loads.changed(["/fixture/alpha.txt"], renaming: false)
        let conversion = loads.startConversion()
        #expect(loads.finishPatch(patch, paths: beta, result: .patched([grown]), renaming: false) == .nothing)
        let landed = loads.finishConversion(conversion)
        #expect(landed)
        #expect(loads.takeDeferred() == nil)
        #expect(loads.takeHeld() == nil)
    }

    /// The engine's URLs keep the values first read through them: results
    /// converted again (a re-sort) after a file grew show its new size.
    @Test func resultsConvertedAgainAreReadFromDisk() throws {
        let tmp = ModelPaths.realPath(FileManager.default.temporaryDirectory) ?? FileManager.default.temporaryDirectory
        let dir = tmp.appendingPathComponent("SearchResultLoadsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("beta.txt")
        try Data(repeating: 0, count: 200).write(to: file)
        let urls = LocalSearch.search(in: dir, query: "beta", recursive: false, showHidden: false)
        // As the engine's URLs are once converted: read through.
        #expect(urls.compactMap { FileItem.load(from: $0) }.map(\.size) == [200])
        #expect(SearchResultLoads.items(urls, sortedBy: .name, ascending: true, folderOrder: .foldersFirst)
            .map(\.size) == [200])

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 1, count: 300))
        try handle.close()

        let again = SearchResultLoads.items(urls, sortedBy: .size, ascending: true, folderOrder: .foldersFirst)
        #expect(again.map(\.size) == [500])
        #expect(again.map(\.id) == [file.path])
    }
}
