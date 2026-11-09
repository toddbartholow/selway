import Foundation
import Testing
@testable import SelwayCore

struct ShellListingPatchTests {
    private let folder = URL(fileURLWithPath: "/fixture", isDirectory: true)
    private let sub    = FileItem.fixture("sub", folder: true)
    private let alpha  = FileItem.fixture("alpha.txt", size: 100)
    private let beta   = FileItem.fixture("beta.log", size: 200)
    private var listing: [FileItem] { [sub, alpha, beta] }

    /// A loader that knows `items` (by path) and records what it was asked for.
    private final class Disk {
        var items: [String: FileItem]
        private(set) var asked: [URL] = []
        init(_ items: [FileItem]) { self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.url.path, $0) }) }
        func load(_ url: URL) -> FileItem? {
            asked.append(url)
            return items[url.path]
        }
    }

    private func patched(_ result: ShellListingPatch.Result) -> [FileItem]? {
        if case .patched(let items) = result { return items }
        return nil
    }

    @Test func aGrowingFileIsReplacedInPlace() throws {
        let grown = FileItem.fixture("beta.log", size: 5_000, modified: TestClock.daysAgo(0, hour: 13))
        let disk = Disk([sub, alpha, grown])
        let items = try #require(patched(ShellListingPatch.apply(["beta.log"], to: listing, in: folder,
                                                                 showHidden: false, load: disk.load)))
        #expect(items == [sub, alpha, grown])
        #expect(items[2].id == beta.id)                // the selection keeps it
        #expect(disk.asked == [beta.url])              // nothing else is read
    }

    /// The caller sorts: by size, the grown file moves.
    @Test func thePatchedListingSortsAgain() throws {
        let grown = FileItem.fixture("alpha.txt", size: 9_000)
        let disk = Disk([sub, grown, beta])
        let items = try #require(patched(ShellListingPatch.apply(["alpha.txt"], to: listing, in: folder,
                                                                 showHidden: false, load: disk.load)))
        #expect(sortedItems(items, by: .size, ascending: true).map(\.name) == ["sub", "beta.log", "alpha.txt"])
    }

    /// Listed items are read at their listed path, as a new URL (a folder's
    /// with its trailing slash), so the id and the URL stay the same.
    @Test func listedItemsAreReadAtTheirListedPath() {
        let disk = Disk([sub, alpha, beta])
        _ = ShellListingPatch.apply(["sub"], to: listing, in: folder, showHidden: false, load: disk.load)
        #expect(disk.asked == [sub.url])
        #expect(disk.asked.first?.hasDirectoryPath == true)
    }

    /// The listed URL keeps the resource values Foundation read when the folder
    /// was listed: read through it, a file that grew still had its old size.
    /// Real files and the real loader, end to end.
    @Test func aFileThatGrewIsReadAgainFromDisk() throws {
        // The real path: listed through the /var link, the items' URLs would be
        // made anew under it and have nothing cached.
        let tmp = ModelPaths.realPath(FileManager.default.temporaryDirectory) ?? FileManager.default.temporaryDirectory
        let dir = tmp.appendingPathComponent("ShellListingPatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("beta.txt")
        try Data(repeating: 0, count: 200).write(to: file)
        let listed = loadItems(at: dir, showHidden: false)
        #expect(listed.map(\.size) == [200])

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 1, count: 300))
        try handle.close()

        let items = try #require(patched(ShellListingPatch.apply(["beta.txt"], to: listed, in: dir,
                                                                 showHidden: false)))
        #expect(items.map(\.size) == [500])
        #expect(items.map(\.id) == listed.map(\.id))
    }

    @Test func aFileReadTheSameLeavesTheListingUnchanged() {
        let disk = Disk([sub, alpha, beta])
        #expect(ShellListingPatch.apply(["beta.log"], to: listing, in: folder, showHidden: false,
                                        load: disk.load) == .unchanged)
    }

    @Test func aGoneEntryNeedsAFullListing() {
        let disk = Disk([sub, alpha])
        #expect(ShellListingPatch.apply(["beta.log"], to: listing, in: folder, showHidden: false,
                                        load: disk.load) == .needsFullListing)
    }

    @Test func aNewVisibleEntryNeedsAFullListing() {
        let new = FileItem.fixture("new.txt")
        let disk = Disk([sub, alpha, beta, new])
        #expect(ShellListingPatch.apply(["new.txt"], to: listing, in: folder, showHidden: false,
                                        load: disk.load) == .needsFullListing)
        // Read as a file at the folder's path: building its URL looks nothing up.
        #expect(disk.asked.map(\.path) == ["/fixture/new.txt"])
        #expect(disk.asked.first?.hasDirectoryPath == false)
    }

    /// .DS_Store and other hidden files change all the time and aren't listed:
    /// nothing to sort or show.
    @Test func hiddenEntriesThatArentListedAreSkipped() {
        let store = FileItem.fixture(".DS_Store")
        let disk = Disk([sub, alpha, beta, store])
        #expect(ShellListingPatch.apply([".DS_Store"], to: listing, in: folder, showHidden: false,
                                        load: disk.load) == .unchanged)
        #expect(disk.asked.isEmpty)                    // a dot-file isn't even read
    }

    /// With hidden files shown, a hidden one not yet listed is new.
    @Test func hiddenEntriesShownNeedAFullListingWhenNew() {
        let store = FileItem.fixture(".DS_Store")
        let disk = Disk([sub, alpha, beta, store])
        #expect(ShellListingPatch.apply([".DS_Store"], to: listing, in: folder, showHidden: true,
                                        load: disk.load) == .needsFullListing)
    }

    /// A listed file that was hidden meanwhile (chflags hidden) leaves the listing.
    @Test func aListedEntryNowHiddenNeedsAFullListing() {
        let hidden = FileItem(id: alpha.id, url: alpha.url, name: alpha.name, isDirectory: false,
                              isPackage: false, isHidden: true, size: 100, dateModified: alpha.dateModified,
                              dateCreated: alpha.dateCreated, kind: alpha.kind,
                              fileExtension: alpha.fileExtension, labelNumber: 0, tags: [])
        let disk = Disk([sub, hidden, beta])
        #expect(ShellListingPatch.apply(["alpha.txt"], to: listing, in: folder, showHidden: false,
                                        load: disk.load) == .needsFullListing)
        #expect(patched(ShellListingPatch.apply(["alpha.txt"], to: listing, in: folder, showHidden: true,
                                                load: disk.load)) != nil)
    }

    /// Written and deleted between two looks (a temporary file): nothing to show.
    @Test func anUnlistedEntryAlreadyGoneIsSkipped() {
        let disk = Disk([sub, alpha, beta])
        #expect(ShellListingPatch.apply(["tmp123"], to: listing, in: folder, showHidden: false,
                                        load: disk.load) == .unchanged)
    }

    // MARK: Reloading a column or the window's folder

    /// `listing` is sorted by size (mixed) as well as by name: alpha.txt grows
    /// past beta.log and moves.
    @Test func aReloadWithChangesPatchesAndSorts() throws {
        let grown = FileItem.fixture("alpha.txt", size: 9_000)
        let disk = Disk([sub, grown, beta])
        var listed = 0
        let reload = try #require(ShellListingPatch.reload(folder, changed: (["alpha.txt"], listing),
                                                           showHidden: false, sortedBy: .size, ascending: true,
                                                           folderOrder: .mixed,
                                                           list: { _, _ in listed += 1; return [] }, load: disk.load))
        #expect(reload.items.map(\.name) == ["sub", "beta.log", "alpha.txt"])
        #expect(reload.items.last?.size == 9_000)
        #expect(!reload.isFullListing)
        #expect(!reload.keepsOrder)
        #expect(listed == 0)                           // the folder isn't listed again
    }

    /// Sorted by name, a file that grows stays where it was: nothing moves.
    @Test func aReloadThatMovesNothingKeepsTheOrder() throws {
        let grown = FileItem.fixture("alpha.txt", size: 9_000)
        let reload = try #require(ShellListingPatch.reload(folder, changed: (["alpha.txt"], listing),
                                                           showHidden: false, sortedBy: .name, ascending: true,
                                                           folderOrder: .foldersFirst,
                                                           load: Disk([sub, grown, beta]).load))
        #expect(reload.items == [sub, grown, beta])
        #expect(reload.keepsOrder)
        #expect(!reload.isFullListing)
    }

    @Test func aReloadWithNothingChangedGivesNothing() {
        let disk = Disk([sub, alpha, beta])
        let reload = ShellListingPatch.reload(folder, changed: (["beta.log"], listing), showHidden: false,
                                              sortedBy: .name, ascending: true, folderOrder: .foldersFirst,
                                              list: { _, _ in Issue.record("listed"); return [] }, load: disk.load)
        #expect(reload == nil)
    }

    /// A new entry, or no changes given (a full reload): the folder is listed whole.
    @Test func aReloadListsTheFolderWhenItMust() {
        let new = FileItem.fixture("new.txt")
        let disk = Disk([sub, alpha, beta, new])
        var asked: [(URL, Bool)] = []
        let list = { (url: URL, hidden: Bool) -> [FileItem] in
            asked.append((url, hidden))
            return [new, beta, alpha, sub]
        }
        let patched = ShellListingPatch.reload(folder, changed: (["new.txt"], listing), showHidden: true,
                                               sortedBy: .name, ascending: true, folderOrder: .foldersFirst,
                                               list: list, load: disk.load)
        #expect(patched?.items.map(\.name) == ["sub", "alpha.txt", "beta.log", "new.txt"])
        #expect(patched?.isFullListing == true)
        let full = ShellListingPatch.reload(folder, changed: nil, showHidden: false,
                                            sortedBy: .name, ascending: true, folderOrder: .foldersFirst,
                                            list: list, load: disk.load)
        #expect(full?.items.map(\.name) == ["sub", "alpha.txt", "beta.log", "new.txt"])
        #expect(full?.isFullListing == true)
        #expect(asked.map(\.0) == [folder, folder])
        #expect(asked.map(\.1) == [true, false])
    }

    // MARK: Keeping a patched list in order

    private func bySize(_ a: FileItem, _ b: FileItem) -> Bool {
        itemPrecedes(a, b, by: .size, ascending: true, folderOrder: .mixed)
    }

    /// Items that changed but stay in order: the list is kept as it is.
    @Test func changedItemsStillInOrderStay() {
        let items = (0..<6).map { FileItem.fixture("f\($0)", size: Int64($0 * 10)) }
        var patched = items
        patched[2] = FileItem.fixture("f2", size: 25)     // still between 10 and 30
        let result = ShellListingPatch.reordered(patched, changed: [2], precedes: bySize)
        #expect(result.items == patched)
        #expect(!result.moved)
    }

    /// Only the changed items move, and the list ends up as a full sort leaves it.
    @Test func changedItemsOutOfOrderMoveToTheirPlace() {
        let items = (0..<8).map { FileItem.fixture("f\($0)", size: Int64($0 * 10)) }
        var patched = items
        patched[1] = FileItem.fixture("f1", size: 75)     // to just before f7 (70 < 75)
        patched[6] = FileItem.fixture("f6", size: 0)      // to the front, after f0 by name
        patched[7] = FileItem.fixture("f7", size: 5)      // next to it
        let result = ShellListingPatch.reordered(patched, changed: [1, 6, 7], precedes: bySize)
        #expect(result.moved)
        #expect(result.items == patched.sorted(by: bySize))
        #expect(result.items.map(\.name) == ["f0", "f6", "f7", "f2", "f3", "f4", "f5", "f1"])
    }

    @Test func theFirstAndLastItemsCanMove() {
        let items = (0..<4).map { FileItem.fixture("f\($0)", size: Int64($0 * 10)) }
        var patched = items
        patched[0] = FileItem.fixture("f0", size: 99)
        patched[3] = FileItem.fixture("f3", size: 1)
        let result = ShellListingPatch.reordered(patched, changed: [0, 3], precedes: bySize)
        #expect(result.items.map(\.name) == ["f3", "f1", "f2", "f0"])
    }

    /// Sorted search results stay sorted: a result that grew moves, by size.
    @Test func aSortedSearchResultThatGrewMoves() throws {
        let grown = FileItem.fixture("alpha.txt", size: 900)
        let results = [alpha, beta]                       // by size: 100, 200
        let items = try #require(patched(ShellListingPatch.apply(paths: [ShellPath.key(alpha.url)],
                                                                 toResults: results, showHidden: false,
                                                                 sortedBy: .size, ascending: true,
                                                                 folderOrder: .foldersFirst,
                                                                 load: Disk([grown, beta]).load)))
        #expect(items == [beta, grown])
    }

    // MARK: Search results

    /// Results from several folders: only the one at the changed path is read.
    private let elsewhere = FileItem.fixture("beta.log", size: 50, parent: "/other")

    @Test func aGrowingSearchResultIsReplacedInPlace() throws {
        let grown = FileItem.fixture("beta.log", size: 5_000)
        let disk = Disk([alpha, grown, elsewhere])
        let results = [alpha, beta, elsewhere]
        let items = try #require(patched(ShellListingPatch.apply(paths: [ShellPath.key(beta.url)], toResults: results,
                                                                 showHidden: false, load: disk.load)))
        #expect(items == [alpha, grown, elsewhere])
        #expect(items[1].id == beta.id)
        #expect(disk.asked == [beta.url])              // not the other folder's beta.log
    }

    /// A folder search's results, read through their URLs, then a file grows:
    /// read again, it has its new size. Real files and the real loader.
    @Test func aSearchResultThatGrewIsReadAgainFromDisk() throws {
        let tmp = ModelPaths.realPath(FileManager.default.temporaryDirectory) ?? FileManager.default.temporaryDirectory
        let dir = tmp.appendingPathComponent("ShellListingPatchTests-\(UUID().uuidString)", isDirectory: true)
        let inner = dir.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = inner.appendingPathComponent("beta.txt")
        try Data(repeating: 0, count: 200).write(to: file)
        let results = LocalSearch.search(in: dir, query: "beta", recursive: true, showHidden: false)
            .compactMap { FileItem.load(from: $0) }
        #expect(results.map(\.size) == [200])

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 1, count: 300))
        try handle.close()

        let items = try #require(patched(ShellListingPatch.apply(paths: [ShellPath.key(file)], toResults: results,
                                                                 showHidden: false)))
        #expect(items.map(\.size) == [500])
        #expect(items.map(\.id) == results.map(\.id))
    }

    @Test func aSearchResultReadTheSameLeavesTheResultsUnchanged() {
        let disk = Disk([alpha, beta])
        #expect(ShellListingPatch.apply(paths: [ShellPath.key(beta.url)], toResults: [alpha, beta],
                                        showHidden: false, load: disk.load) == .unchanged)
    }

    /// A file written in a results folder that isn't a result (a new one comes
    /// with a folder change, which runs the search again).
    @Test func pathsThatArentResultsAreSkipped() {
        let disk = Disk([alpha, beta])
        #expect(ShellListingPatch.apply(paths: ["/fixture/new.txt"], toResults: [alpha, beta],
                                        showHidden: false, load: disk.load) == .unchanged)
        #expect(disk.asked.isEmpty)
    }

    @Test func aGoneSearchResultRunsTheSearchAgain() {
        let disk = Disk([alpha])
        #expect(ShellListingPatch.apply(paths: [ShellPath.key(beta.url)], toResults: [alpha, beta],
                                        showHidden: false, load: disk.load) == .needsFullListing)
    }

    /// A result hidden meanwhile (chflags hidden) leaves a search that doesn't
    /// show hidden files: it runs again.
    @Test func aSearchResultNowHiddenRunsTheSearchAgain() throws {
        let hidden = FileItem(id: beta.id, url: beta.url, name: beta.name, isDirectory: false,
                              isPackage: false, isHidden: true, size: 200, dateModified: beta.dateModified,
                              dateCreated: beta.dateCreated, kind: beta.kind,
                              fileExtension: beta.fileExtension, labelNumber: 0, tags: [])
        let disk = Disk([alpha, hidden])
        #expect(ShellListingPatch.apply(paths: [ShellPath.key(beta.url)], toResults: [alpha, beta],
                                        showHidden: false, load: disk.load) == .needsFullListing)
        let shown = try #require(patched(ShellListingPatch.apply(paths: [ShellPath.key(beta.url)],
                                                                 toResults: [alpha, beta], showHidden: true,
                                                                 load: disk.load)))
        #expect(shown == [alpha, hidden])
    }

    /// A folder opened through a link: Spotlight reports its files under the
    /// real path, a folder search under the path opened.
    @Test func resultPathsCoverTheFolderOpenedAndItsRealPath() {
        let opened = URL(fileURLWithPath: "/Users/me/Downloads", isDirectory: true)
        #expect(ShellListingPatch.resultPaths(["a.zip"], in: opened, realPath: "/Volumes/T7/Users/me/Downloads")
            == ["/Users/me/Downloads/a.zip", "/Volumes/T7/Users/me/Downloads/a.zip"])
        #expect(ShellListingPatch.resultPaths(["a.zip", "b"], in: opened, realPath: "/Users/me/Downloads")
            == ["/Users/me/Downloads/a.zip", "/Users/me/Downloads/b"])
        #expect(ShellListingPatch.resultPaths(["a.zip"], in: opened, realPath: nil) == ["/Users/me/Downloads/a.zip"])
    }

    /// A Spotlight result under the real path is read again when the folder
    /// opened through the link reports it.
    @Test func aResultUnderTheRealPathIsMatched() throws {
        let real = FileItem.fixture("a.zip", size: 10, parent: "/Volumes/T7/Users/me/Downloads")
        let grown = FileItem.fixture("a.zip", size: 900, parent: "/Volumes/T7/Users/me/Downloads")
        let paths = ShellListingPatch.resultPaths(["a.zip"], in: URL(fileURLWithPath: "/Users/me/Downloads"),
                                                  realPath: "/Volumes/T7/Users/me/Downloads")
        let items = try #require(patched(ShellListingPatch.apply(paths: paths, toResults: [real], showHidden: false,
                                                                 load: Disk([grown]).load)))
        #expect(items == [grown])
    }

    /// Search results hold folders as "dir/" URLs; the watcher names them without the slash.
    @Test func aFolderResultIsMatchedWithoutItsSlash() throws {
        let tagged = FileItem.fixture("sub", folder: true, tags: ["Red"])
        let disk = Disk([tagged])
        let items = try #require(patched(ShellListingPatch.apply(paths: ["/fixture/sub"], toResults: [sub],
                                                                 showHidden: false, load: disk.load)))
        #expect(items == [tagged])
        #expect(disk.asked.first?.hasDirectoryPath == true)
    }

    // MARK: Loads in flight

    @Test func aPatchMayStartOnlyWhenNoLoadIsInFlight() {
        var loads = ShellListingLoads()
        #expect(!loads.isLoading)
        let now = loads.changed(["a"])
        #expect(now)
        let first = loads.start()
        #expect(loads.isLoading)
        let landed = loads.finish(first)
        #expect(landed)
        #expect(!loads.isLoading)
    }

    @Test func onlyTheLatestLoadLands() {
        var loads = ShellListingLoads()
        let older = loads.start()
        let newer = loads.start()
        let olderLanded = loads.finish(older)
        #expect(!olderLanded)
        #expect(loads.isLoading)                       // the newer one is still on its way
        let newerLanded = loads.finish(newer)
        #expect(newerLanded)
        #expect(!loads.isLoading)
    }

    /// A pane that stops (hidden, its window closed) drops the load in flight:
    /// it doesn't land, and nothing waits for it.
    @Test func aCancelledLoadDoesntLand() {
        var loads = ShellListingLoads()
        let token = loads.start()
        let waits = loads.changed(["a"])
        #expect(!waits)
        loads.cancel()
        #expect(!loads.isLoading)
        let landed = loads.finish(token)
        #expect(!landed)
        #expect(loads.takeDeferred() == nil)
        let now = loads.changed(["b"])
        #expect(now)                                   // a patch may start again
    }

    /// A folder slower to list than the watcher's interval, with a file in it
    /// being written: each change waits for the load in flight instead of
    /// starting it over, so the load lands, and the changes are patched in after.
    @Test func changesDuringALoadWaitForItToLand() {
        var loads = ShellListingLoads()
        let full = loads.start()
        for tick in 0..<5 {
            let now = loads.changed(["busy.log", "tick\(tick)"])
            #expect(!now)
        }
        #expect(loads.generation.current == full)      // never restarted
        #expect(loads.takeDeferred() == nil)           // not before it lands
        let landed = loads.finish(full)
        #expect(landed)
        #expect(loads.takeDeferred() == ["busy.log", "tick0", "tick1", "tick2", "tick3", "tick4"])
        #expect(loads.takeDeferred() == nil)           // taken once
    }

    /// A patch in flight holds changes back the same way.
    @Test func changesDuringAPatchWaitForIt() {
        var loads = ShellListingLoads()
        let first = loads.changed(["busy.log"])
        #expect(first)
        let patch = loads.start()
        let second = loads.changed(["busy.log"])
        #expect(!second)
        let landed = loads.finish(patch)
        #expect(landed)
        #expect(loads.takeDeferred() == ["busy.log"])
    }

    /// A full load started meanwhile (a sort change, Refresh) reads every entry
    /// after the changes happened: they don't need patching in after it.
    @Test func aNewFullLoadTakesInTheWaitingChanges() {
        var loads = ShellListingLoads()
        let older = loads.start()
        let now = loads.changed(["busy.log"])
        #expect(!now)
        let newer = loads.start()
        let olderLanded = loads.finish(older)
        #expect(!olderLanded)
        let newerLanded = loads.finish(newer)
        #expect(newerLanded)
        #expect(loads.takeDeferred() == nil)
    }
}
