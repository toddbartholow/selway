import Foundation
import Testing
@testable import SelwayCore

struct WindowFolderRestorationTests {
    private let dual = WindowFolderSnapshot(first: .folder(path: "/one"), second: .computer, isDual: true)
    private let single = WindowFolderSnapshot(first: nil, second: nil, isDual: false)

    @Test func savedWindowsRoundTripEachPaneAndLayout() {
        let saved = SavedWindowFolders(windows: ["browser-AppWindow-1": dual, "browser-AppWindow-2": single])
        #expect(SavedWindowFolders.decode(saved.encoded()) == saved)
    }

    @Test func theSameWindowsAlwaysEncodeTheSame() {
        let saved = SavedWindowFolders(windows: ["b": single, "a": dual, "c": dual])
        #expect(saved.encoded() == saved.encoded())
        #expect(saved.encoded() == SavedWindowFolders.decode(saved.encoded())?.encoded())
    }

    @Test func malformedSavedWindowsAreIgnored() {
        #expect(SavedWindowFolders.decode(nil) == nil)
        #expect(SavedWindowFolders.decode(Data()) == nil)
        #expect(SavedWindowFolders.decode(Data("not saved windows".utf8)) == nil)
    }

    @Test func onlyOpenWindowsAreKept() {
        let saved = SavedWindowFolders(windows: ["open": dual, "closed": single])
        #expect(saved.keeping(["open", "never saved"]).windows == ["open": dual])
        #expect(saved.keeping([]).windows.isEmpty)
    }

    @Test func eachWindowsSnapshotIsGivenOutOnce() {
        var saved = SavedWindowFolders(windows: ["one": dual, "two": single])
        #expect(saved.take("one") == dual)
        #expect(saved.take("one") == nil)
        #expect(saved.take("unknown") == nil)
        #expect(saved.windows == ["two": single])
    }

    @Test func onlyWindowsRestoredWithoutLiveRequestsUseSavedPlaces() {
        #expect(WindowFolderRestoration.shouldRestore(hasLiveRequest: false, isRestoringWindows: true))
        #expect(!WindowFolderRestoration.shouldRestore(hasLiveRequest: true, isRestoringWindows: true))
        #expect(!WindowFolderRestoration.shouldRestore(hasLiveRequest: false, isRestoringWindows: false))
    }

    @Test func aFolderIsLookedAtOnlyWhenTheGuardAllowsIt() {
        var looked: [String] = []
        let isFolder: (String) -> Bool = { looked.append($0); return true }
        #expect(WindowFolderRestoration.canReopen("/Users/me/Work", isSafe: { _ in true }, isFolder: isFolder))
        #expect(!WindowFolderRestoration.canReopen("/net/server/share", isSafe: { _ in false }, isFolder: isFolder))
        #expect(!WindowFolderRestoration.canReopen("", isSafe: { _ in true }, isFolder: isFolder))
        #expect(looked == ["/Users/me/Work"])
    }

    @Test func aFolderThatIsGoneIsNotReopened() {
        #expect(!WindowFolderRestoration.canReopen("/Volumes/Gone/Docs", isSafe: { _ in true }, isFolder: { _ in false }))
    }
}
