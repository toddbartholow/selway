import Foundation
import Testing
@testable import SelwayCore

@Suite struct SidebarFavoritesTests {
    private func urls(_ paths: [String]) -> [URL] { paths.map { URL(fileURLWithPath: $0) } }

    @Test func unmountedEntriesSurviveLoadAndSave() throws {
        let d = TestDefaults(); defer { d.cleanup() }
        let t = try TempDir(); defer { t.cleanup() }
        let present = try t.dir("Present").path
        let unmounted = "/Volumes/NotMounted-\(UUID().uuidString)/Projects"
        d.defaults.set([present, unmounted], forKey: FavoritesStore.defaultsKey)

        let store = FavoritesStore(defaults: d.defaults)
        let loaded = store.load()
        #expect(loaded.map(\.path) == [present, unmounted])
        #expect(FavoritesStore.isAvailable(loaded[0]))
        #expect(!FavoritesStore.isAvailable(loaded[1]))

        store.save(loaded)
        #expect(d.defaults.stringArray(forKey: FavoritesStore.defaultsKey) == [present, unmounted])
    }

    @Test func loadDropsDuplicatesAndBlanks() {
        let d = TestDefaults(); defer { d.cleanup() }
        d.defaults.set(["/a", "", "/b", "/a"], forKey: FavoritesStore.defaultsKey)
        #expect(FavoritesStore(defaults: d.defaults).load().map(\.path) == ["/a", "/b"])
    }

    @Test func loadDropsDuplicatesThatDifferOnlyInSpelling() {
        let d = TestDefaults(); defer { d.cleanup() }
        d.defaults.set(["/a/b", "/a/b/", "/c", "/a/./b", "/a/x/../b", "/c//"],
                       forKey: FavoritesStore.defaultsKey)
        let loaded = FavoritesStore(defaults: d.defaults).load()
        #expect(loaded.map(\.path) == ["/a/b", "/c"])
        let allFolders = loaded.allSatisfy { $0.hasDirectoryPath }
        #expect(allFolders)
        #expect(FavoritesStore.contains(loaded, URL(fileURLWithPath: "/a/./b")))
        #expect(FavoritesStore.unpinning(URL(fileURLWithPath: "/c/"), in: loaded).map(\.path) == ["/a/b"])
    }

    @Test func removingSeveralOffsetsRemovesExactlyThoseRows() {
        let list = urls(["/a", "/b", "/c", "/d", "/e"])
        #expect(FavoritesStore.removing(atOffsets: [1, 3], from: list).map(\.path) == ["/a", "/c", "/e"])
        #expect(FavoritesStore.removing(atOffsets: [3, 4], from: list).map(\.path) == ["/a", "/b", "/c"])
        #expect(FavoritesStore.removing(atOffsets: IndexSet(0..<5), from: list).isEmpty)
        #expect(FavoritesStore.removing(atOffsets: [], from: list) == list)
        #expect(FavoritesStore.removing(atOffsets: [9], from: list) == list)
    }

    @Test func pinAndUnpinCompareByPath() {
        let list = urls(["/a/b"])
        #expect(FavoritesStore.contains(list, URL(fileURLWithPath: "/a/b/", isDirectory: true)))
        #expect(FavoritesStore.pinning(URL(fileURLWithPath: "/a/b", isDirectory: true), in: list) == nil)
        let pinned = FavoritesStore.pinning(URL(fileURLWithPath: "/c"), in: list)
        #expect(pinned?.map(\.path) == ["/c", "/a/b"])
        #expect(pinned?.first?.hasDirectoryPath == true)
        #expect(FavoritesStore.unpinning(URL(fileURLWithPath: "/a/b/"), in: list).isEmpty)
    }
}
