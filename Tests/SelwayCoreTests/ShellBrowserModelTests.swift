import Foundation
import Observation
import Testing
@testable import SelwayCore

@Suite @MainActor struct BrowserModelTests {
    private let a = FileItem.fixture("a.txt")
    private let b = FileItem.fixture("b.pdf", tags: ["Red"])
    private let c = FileItem.fixture("Notes", folder: true, tags: ["Blue", "Red"])

    private func refresh(_ model: BrowserModel, query: String = "", hasSearchResults: Bool = false) {
        model.refreshDisplay(query: query, hasSearchResults: hasSearchResults,
                             sortField: .name, ascending: true, folderOrder: .foldersFirst)
    }

    /// True when `change` notified an observer of what `read` reads.
    private func notifies(_ read: @escaping () -> Void, when change: () -> Void) -> Bool {
        // Set by the change handler, which runs inside `change()`, on this thread.
        nonisolated(unsafe) var fired = false
        withObservationTracking(read) { fired = true }
        change()
        return fired
    }

    private func listed(_ items: [FileItem]) -> BrowserModel {
        let model = BrowserModel()
        model.setRawFiles(items)
        refresh(model)
        return model
    }

    // MARK: What a change re-renders

    /// The point of the model: selecting a row mustn't update the views that
    /// show the folder or the listing (the sidebar, path bar, title).
    @Test func selectingNotifiesOnlySelectionObservers() {
        let model = listed([a, b])
        #expect(!notifies({ _ = model.location; _ = model.displayFiles; _ = model.usedTags }) {
            model.selectedIDs = [a.id]
        })
        #expect(notifies({ _ = model.selectedIDs }) { model.selectedIDs = [b.id] })
    }

    /// The toolbar's delete buttons care only whether there's a selection.
    @Test func hasSelectionChangesOnlyBetweenEmptyAndNot() {
        let model = listed([a, b])
        #expect(notifies({ _ = model.hasSelection }) { model.selectedIDs = [a.id] })
        #expect(model.hasSelection)
        #expect(!notifies({ _ = model.hasSelection }) { model.selectedIDs = [a.id, b.id] })
        #expect(notifies({ _ = model.hasSelection }) { model.selectedIDs = [] })
        #expect(!model.hasSelection)
    }

    /// Clearing an empty selection (every navigation does) updates nothing.
    @Test func settingAnEqualSelectionNotifiesNoOne() {
        let model = listed([a])
        #expect(!notifies({ _ = model.selectedIDs }) { model.selectedIDs = [] })
    }

    @Test func bookkeepingIsNotObserved() {
        let model = listed([a])
        #expect(!notifies({ _ = model.pendingSelectURLs; _ = model.quietNavigation }) {
            model.pendingSelectURLs = [a.url]
            model.quietNavigation = a.url
            _ = model.listingLoads.start()
        })
    }

    // MARK: Display list

    @Test func usedTagsAreSortedAndUnique() {
        let model = listed([a, b, c])
        #expect(model.usedTags == [FileTag(name: "Blue", color: 4), FileTag(name: "Red", color: 6)])
        #expect(!notifies({ _ = model.usedTags }) { model.setRawFiles([c, b]) })
    }

    /// A custom tag's row shows only that tag's items, not every item of its colour.
    @Test func customTagFilterMatchesByName() {
        let project = FileItem.fixture("p.txt", tags: ["Project"])
        let model = listed([a, b, project])
        model.activeTagFilter = SidebarTag(name: "project", color: 6, isStandard: false)
        refresh(model)
        #expect(model.displayFiles == [project])
    }

    @Test func rebuildingBumpsVersionAndIndexesItems() {
        let model = listed([a, b])
        let version = model.displayVersion
        refresh(model)
        #expect(model.displayVersion == version &+ 1)
        #expect(model.displayIndex[b.id] == 1)
    }

    @Test func selectionLosesItemsNoLongerShown() {
        let model = listed([a, b])
        model.selectedIDs = [a.id, b.id]
        refresh(model, query: "pdf")
        #expect(model.displayFiles == [b])
        #expect(model.selectedIDs == [b.id])
    }

    @Test func searchFiltersTheFolderUntilResultsArrive() {
        let model = listed([a, b])
        let found = FileItem.fixture("elsewhere.txt", parent: "/other")
        model.searchDisplayFiles = [found]
        refresh(model, query: "a.")
        #expect(model.displayFiles == [a])
        refresh(model, query: "a.", hasSearchResults: true)
        #expect(model.displayFiles == [found])
    }

    /// Spotlight's matches plus the folder's own tagged items, once each.
    @Test func tagFilterMergesSpotlightAndLocalMatches() {
        let model = listed([a, b, c])
        let remote = FileItem.fixture("far.txt", tags: ["Red"], parent: "/far")
        model.tagDisplayFiles = [remote, b]
        model.activeTagFilter = SidebarTag(name: "Red", color: 6, isStandard: true)
        refresh(model)
        #expect(model.displayFiles.map(\.name) == ["Notes", "b.pdf", "far.txt"])
    }

    #if os(macOS)
    /// A folder reached through a symlink (the user's ~/Downloads links to
    /// another volume): Spotlight reports the real path, the listing the path
    /// the user opened. The item shows once, under the path they browsed.
    @Test func tagFilterShowsAnItemOnceWhenBrowsedThroughASymlink() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let real = dir.url.appendingPathComponent("real", isDirectory: true)
        let tagged = try dir.file("real/Project")
        try FileManager.default.removeItem(at: tagged)
        try FileManager.default.createDirectory(at: tagged, withIntermediateDirectories: true)
        try FileOpsTags.writeEntries(["Red\n6"], to: tagged)
        let link = dir.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let model = BrowserModel()
        model.location = .folder(link)
        model.setRawFiles(loadItems(at: link, showHidden: false))
        model.activeTagFilter = SidebarTag(name: "Red", color: 6, isStandard: true)
        let spotlight = [tagged]   // the real path, as Spotlight reports it

        // Converted as ContentView does: shown under the folder being browsed.
        model.tagDisplayFiles = BrowserModel.tagResultItems(spotlight, shownUnder: link)
        refresh(model)
        #expect(model.displayFiles.map(\.url.path) == [link.appendingPathComponent("Project").path])

        // Even unconverted, the folder's own item wins.
        model.tagDisplayFiles = spotlight.compactMap { FileItem.load(from: $0) }
        refresh(model)
        #expect(model.displayFiles.map(\.url.path) == [link.appendingPathComponent("Project").path])
    }
    #endif

    /// A link the listing didn't follow isn't resolved for the tag merge
    /// either (realpath follows it, mounting what it leads into): only its
    /// folder is, which gives the link's own real path.
    @Test func mergingTagsDoesntResolveARefusedLink() {
        var refused = FileItem.fixture("share", tags: ["Red"])
        refused.isLinkNotFollowed = true
        let plain = FileItem.fixture("b.pdf", tags: ["Red"])
        var asked: [String] = []
        let realPath: (URL) -> URL? = { asked.append($0.path); return URL(fileURLWithPath: "/real" + $0.path) }
        let spotlight = [FileItem.fixture("share", tags: ["Red"], parent: "/real/fixture"),
                         FileItem.fixture("b.pdf", tags: ["Red"], parent: "/real/fixture"),
                         FileItem.fixture("export", tags: ["Red"], parent: "/net/host")]
        let merged = BrowserModel.mergedTagItems(local: [refused, plain], spotlight: spotlight, realPath: realPath)
        #expect(asked == ["/fixture", "/fixture/b.pdf"])
        #expect(merged.map(\.url.path) == ["/fixture/share", "/fixture/b.pdf", "/net/host/export"])
    }

    /// The same on disk: the refused link's target, found by Spotlight, is
    /// another item, not the link resolved.
    @Test func aRefusedLinksTargetStaysItsOwnTagResult() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let target = try dir.file("target.txt")
        let link = try dir.link("link.txt", to: "target.txt")
        let refused = try #require(FileItem.load(from: link, isSafeLink: { _ in false }))
        let found = try #require(FileItem.load(from: target))
        let merged = BrowserModel.mergedTagItems(local: [refused], spotlight: [found])
        #expect(merged.map(\.url.path) == [link.path, target.path])
        let followed = try #require(FileItem.load(from: link))
        #expect(BrowserModel.mergedTagItems(local: [followed], spotlight: [found]).map(\.url.path) == [link.path])
    }

    @Test func selectedItemIsTheFirstShownSelection() {
        let model = listed([a, b])
        #expect(model.selectedItem == nil)
        model.selectedIDs = [b.id]
        #expect(model.selectedItem == b)
        #expect(model.selectedURLs == [b.url])
        #expect(model.displayedItem(at: URL(fileURLWithPath: "/fixture/a.txt")) == a)
    }
}
