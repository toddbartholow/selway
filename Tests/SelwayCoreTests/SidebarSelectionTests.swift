import Foundation
import Testing
@testable import SelwayCore

@Suite struct SidebarSelectionTests {
    private let home      = URL(fileURLWithPath: "/Users/me")
    private let desktop   = URL(fileURLWithPath: "/Users/me/Desktop")
    private let downloads = URL(fileURLWithPath: "/Users/me/Downloads")
    private let project   = URL(fileURLWithPath: "/Users/me/src/project")
    private let drive     = URL(fileURLWithPath: "/Volumes/Backup/work")
    private let other     = URL(fileURLWithPath: "/tmp/elsewhere")
    private var locations: [URL] { [home, desktop, downloads] }

    private func match(_ path: URL, selected: SidebarItem? = nil, pinned: [URL] = []) -> SidebarItem? {
        SidebarSelection.matchingItem(for: path, selected: selected, locations: locations, pinned: pinned)
    }

    // MARK: Which row follows the folder

    @Test func favoritesComeBeforePinned() {
        #expect(match(desktop, pinned: [desktop]) == .location(desktop))
        #expect(match(project, pinned: [project]) == .pinned(project))
        #expect(match(other, pinned: [project]) == nil)
    }

    @Test func anotherSpellingOfTheFolderMatches() {
        #expect(match(URL(fileURLWithPath: "/Users/me/Desktop/")) == .location(desktop))
    }

    /// Regression: a Recent row that's also a Favorite jumped up to Favorites when
    /// selected, so arrowing down the list looped back.
    @Test func selectedRecentRowThatIsAlsoAFavoriteStays() {
        #expect(match(home, selected: .recent(home)) == .recent(home))
        #expect(match(project, selected: .recent(project), pinned: [project]) == .recent(project))
    }

    @Test func selectionForAnotherFolderGivesWay() {
        #expect(match(desktop, selected: .recent(project)) == .location(desktop))
        #expect(match(other, selected: .recent(project)) == nil)
    }

    // MARK: What a user selection does

    private func select(_ item: SidebarItem?, at path: URL,
                        available: Set<URL> = []) -> SidebarSelection.Outcome {
        SidebarSelection.userSelected(item, currentPath: path,
                                      isAvailable: { !available.isEmpty ? available.contains($0) : true })
    }

    @Test func selectingAnotherFolderNavigates() {
        #expect(select(.location(desktop), at: home) == .navigate(.folder(desktop)))
        #expect(select(.recent(project), at: home) == .navigate(.folder(project)))
        #expect(select(.pinned(project), at: home) == .navigate(.folder(project)))
    }

    @Test func selectingTheFolderShownOrNothingStays() {
        #expect(select(.location(home), at: home) == .stay)
        #expect(select(.recent(URL(fileURLWithPath: "/Users/me/")), at: home) == .stay)
        #expect(select(nil, at: home) == .stay)
    }

    /// Regression: an unavailable pinned folder cleared the selection, so the arrow
    /// keys couldn't move past it. It's a beep with the highlight left there, never
    /// a navigation.
    @Test func unavailablePinnedFolderIsABeepNotANavigation() {
        let outcome = SidebarSelection.userSelected(.pinned(drive), currentPath: home, isAvailable: { $0 != drive })
        #expect(outcome == .unavailable)
        // Only pinned rows are checked: Favorites and Recent always exist.
        #expect(SidebarSelection.userSelected(.recent(desktop), currentPath: home, isAvailable: { _ in false })
                == .navigate(.folder(desktop)))
    }

    /// Regression: the app moving the highlight to follow the folder navigated
    /// (sending a new window to the wrong folder). Whatever row the sync picks, it
    /// is the folder shown, so even through the user's path it does nothing.
    @Test(arguments: ["/Users/me", "/Users/me/Desktop", "/Users/me/src/project", "/tmp/elsewhere"])
    func followingTheFolderNeverNavigates(path: String) {
        let url = URL(fileURLWithPath: path)
        for selected: SidebarItem? in [nil, .recent(home), .recent(url), .location(desktop)] {
            let synced = match(url, selected: selected, pinned: [project])
            #expect(SidebarSelection.userSelected(synced, currentPath: url, isAvailable: { _ in true }) == .stay)
        }
    }

    @Test func computerIsListedAndCanBeSelectedAsALocation() {
        #expect(SidebarItem.computer.url == nil)
        #expect(SidebarSelection.isListed(.computer, [], [], [], []))
        #expect(SidebarSelection.matchingItem(for: .computer, selected: nil, locations: [], pinned: []) == .computer)
        #expect(SidebarSelection.userSelected(.computer, location: .folder(home), isAvailable: { _ in true })
                == .navigate(.computer))
        #expect(SidebarSelection.userSelected(.computer, location: .computer, isAvailable: { _ in true }) == .stay)
        #expect(SidebarSelection.activated(.computer, location: .folder(home), isAvailable: { _ in true })
                == .navigate(.computer))
        // A highlighted Network row that's still shown keeps the highlight at the computer too.
        #expect(SidebarSelection.matchingItem(for: .computer, selected: .network, locations: [], pinned: [],
                                              networkShown: [.network]) == .network)
    }

    // MARK: Saved servers

    private func server(_ id: String, _ text: String, mountedAt folder: String?) throws -> SidebarServerRow {
        let address = try ServerAddress.parse(text).get().address
        return SidebarServerRow(server: SavedServer.make(id: id, typed: address),
                                folder: folder.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    /// A saved server that isn't connected has no folder: it never matches the
    /// folder shown. Selecting it (the arrow keys) only highlights it;
    /// activating it (a click, Return, Connect) connects, by id.
    @Test func onlyActivatingAnUnconnectedServerConnects() throws {
        let row = try server("s1", "smb://nas/Media", mountedAt: nil)
        #expect(SidebarSelection.userSelected(.server("s1"), currentPath: home, isAvailable: { _ in false },
                                              serverFolder: { _ in row.folder }) == .stay)
        #expect(SidebarSelection.activated(.server("s1"), currentPath: home, isAvailable: { _ in false },
                                           serverFolder: { _ in row.folder }) == .connect("s1"))
        // Activating anything else is selecting it.
        #expect(SidebarSelection.activated(.location(desktop), currentPath: home, isAvailable: { _ in true })
                == .navigate(.folder(desktop)))
        #expect(SidebarSelection.activated(.pinned(drive), currentPath: home, isAvailable: { _ in false })
                == .unavailable)
        #expect(SidebarSelection.activated(nil, currentPath: home, isAvailable: { _ in true }) == .stay)
        #expect(SidebarSelection.matchingItem(for: home, selected: .server("s1"), locations: [],
                                              servers: [row], pinned: []) == nil)
        #expect(SidebarItem.server("s1").url == nil)
    }

    /// The Network row and the servers under it have no folder. Selecting
    /// one (the arrow keys) only highlights it; activating a server (a click,
    /// Return) connects it, by id; activating the Network row does nothing.
    @Test func onlyActivatingANetworkServerConnects() {
        #expect(SidebarSelection.userSelected(.networkServer("nas"), currentPath: home,
                                              isAvailable: { _ in true }) == .stay)
        #expect(SidebarSelection.activated(.networkServer("nas"), currentPath: home,
                                           isAvailable: { _ in true }) == .connectNetworkServer("nas"))
        #expect(SidebarSelection.userSelected(.network, currentPath: home, isAvailable: { _ in true }) == .stay)
        #expect(SidebarSelection.activated(.network, currentPath: home, isAvailable: { _ in true }) == .stay)
        #expect(SidebarItem.network.url == nil && SidebarItem.networkServer("nas").url == nil)
        // The highlight leaves them for the folder shown.
        #expect(SidebarSelection.matchingItem(for: home, selected: .networkServer("nas"), locations: [home],
                                              pinned: []) == .location(home))
        #expect(SidebarSelection.matchingItem(for: other, selected: .network, locations: [home], pinned: []) == nil)
    }

    /// A Network row stays highlighted while it's shown when the other rows
    /// change (a drive mounted in another window), and lets go once it isn't.
    @Test func aShownNetworkRowKeepsTheHighlight() {
        let shown: Set<SidebarItem> = [.network, .networkServer("nas")]
        #expect(SidebarSelection.matchingItem(for: home, selected: .networkServer("nas"), locations: [home],
                                              pinned: [], networkShown: shown) == .networkServer("nas"))
        #expect(SidebarSelection.matchingItem(for: home, selected: .network, locations: [home],
                                              pinned: [], networkShown: shown) == .network)
        // Gone: the folder's row.
        #expect(SidebarSelection.matchingItem(for: home, selected: .networkServer("gone"), locations: [home],
                                              pinned: [], networkShown: shown) == .location(home))
        // Other rows aren't kept by it.
        #expect(SidebarSelection.matchingItem(for: home, selected: .pinned(project), locations: [home],
                                              pinned: [], networkShown: shown) == .location(home))
    }

    @Test func selectingAConnectedServerGoesToItsFolder() throws {
        let row = try server("s1", "smb://nas/Media/Sub", mountedAt: "/Volumes/Media/Sub")
        let folder = try #require(row.folder)
        let lookup: (String) -> URL? = { $0 == "s1" ? folder : nil }
        #expect(SidebarSelection.userSelected(.server("s1"), currentPath: home, isAvailable: { _ in true },
                                              serverFolder: lookup) == .navigate(.folder(folder)))
        #expect(SidebarSelection.userSelected(.server("s1"), currentPath: URL(fileURLWithPath: "/Volumes/Media/Sub/"),
                                              isAvailable: { _ in true }, serverFolder: lookup) == .stay)
        #expect(SidebarSelection.activated(.server("s1"), currentPath: home, isAvailable: { _ in true },
                                           serverFolder: lookup) == .navigate(.folder(folder)))
        // An id no longer saved: connecting finds nothing to do.
        #expect(SidebarSelection.activated(.server("gone"), currentPath: home, isAvailable: { _ in true },
                                           serverFolder: lookup) == .connect("gone"))
    }

    /// Locations' order: volumes, then the connected saved servers, before Pinned.
    @Test func aConnectedServerFollowsTheFolderAfterTheVolumes() throws {
        let row = try server("s1", "smb://nas/Media/Sub", mountedAt: "/Volumes/Media/Sub")
        let sub = URL(fileURLWithPath: "/Volumes/Media/Sub")
        #expect(SidebarSelection.matchingItem(for: sub, selected: nil, locations: [], volumes: [],
                                              servers: [row], pinned: [sub]) == .server("s1"))
        #expect(SidebarSelection.matchingItem(for: sub, selected: nil, locations: [], volumes: [sub],
                                              servers: [row], pinned: []) == .volume(sub))
        // Selected and still listed, it stays even where a volume row matches too.
        #expect(SidebarSelection.matchingItem(for: sub, selected: .server("s1"), locations: [], volumes: [sub],
                                              servers: [row], pinned: []) == .server("s1"))
        // Removed from the sidebar, the highlight moves on.
        #expect(SidebarSelection.matchingItem(for: sub, selected: .server("s1"), locations: [], volumes: [sub],
                                              servers: [], pinned: []) == .volume(sub))
    }

    @Test func followingTheFolderNeverConnects() throws {
        let rows = [try server("a", "smb://nas/A", mountedAt: nil),
                    try server("b", "smb://nas/B/x", mountedAt: "/Volumes/B/x")]
        for path in ["/Users/me", "/Volumes/B/x", "/Volumes/A"] {
            let url = URL(fileURLWithPath: path)
            for selected: SidebarItem? in [nil, .server("a"), .server("b")] {
                let synced = SidebarSelection.matchingItem(for: url, selected: selected, locations: locations,
                                                           servers: rows, pinned: [])
                let outcome = SidebarSelection.userSelected(synced, currentPath: url, isAvailable: { _ in true },
                                                            serverFolder: { id in rows.first { $0.server.id == id }?.folder })
                #expect(outcome == .stay)
            }
        }
        // Arrowing onto any row never connects: selecting isn't activating.
        for row in rows {
            let outcome = SidebarSelection.userSelected(.server(row.server.id), currentPath: home,
                                                        isAvailable: { _ in true },
                                                        serverFolder: { id in rows.first { $0.server.id == id }?.folder })
            #expect(outcome != .connect(row.server.id))
        }
    }

    // MARK: Recent

    private func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/r/\($0)") } }

    /// Regression: visiting a folder already in Recent moved its row to the top,
    /// so rows jumped under the pointer and while arrowing.
    @Test func visitingAListedFolderKeepsTheRows() {
        let rows = urls("a", "b", "c")
        #expect(RecentFolders.visible(rows, visiting: URL(fileURLWithPath: "/r/c")) == rows)
        #expect(RecentFolders.visible(rows, visiting: URL(fileURLWithPath: "/r/b/")) == rows)
    }

    @Test func aNewFolderGoesOnTopAndTheListIsCapped() {
        let rows = urls("a", "b", "c", "d", "e", "f", "g", "h")
        let next = RecentFolders.visible(rows, visiting: URL(fileURLWithPath: "/r/new"))
        #expect(next.first == URL(fileURLWithPath: "/r/new"))
        #expect(Array(next.prefix(RecentFolders.defaultVisibleLimit)) == [URL(fileURLWithPath: "/r/new")] + rows.prefix(7))
        let many = (0..<25).map { URL(fileURLWithPath: "/r/\($0)") }
        #expect(RecentFolders.visible(many, visiting: URL(fileURLWithPath: "/r/x")).count == RecentFolders.storedLimit)
    }

    /// Settings → Sidebar's count: a user who shows 12 keeps 12 after visiting a
    /// new folder, and a folder listed but not shown comes to the top.
    @Test func theVisibleLimitComesFromTheSetting() {
        let rows = (0..<12).map { URL(fileURLWithPath: "/r/\($0)") }
        let next = RecentFolders.visible(rows, visiting: URL(fileURLWithPath: "/r/new"), limit: 12)
        #expect(next.count == 13 && next.first == URL(fileURLWithPath: "/r/new"))
        #expect(Array(next.prefix(12)) == [URL(fileURLWithPath: "/r/new")] + rows.prefix(11))
        #expect(RecentFolders.visible(rows, visiting: URL(fileURLWithPath: "/r/10"), limit: 12) == rows)
        let hidden = RecentFolders.visible(rows, visiting: URL(fileURLWithPath: "/r/10"), limit: 3)
        #expect(hidden.first == URL(fileURLWithPath: "/r/10") && hidden.count == 12)
    }

    @Test func theStoredListMovesToTheTopAndIsCapped() {
        #expect(RecentFolders.stored(["/a", "/b", "/c"], visiting: "/c") == ["/c", "/a", "/b"])
        #expect(RecentFolders.stored([], visiting: "/a") == ["/a"])
        let long = (0..<30).map { "/\($0)" }
        let stored = RecentFolders.stored(long, visiting: "/new")
        #expect(stored.count == RecentFolders.storedLimit)
        #expect(stored.first == "/new")
        #expect(RecentFolders.defaultVisibleLimit == 8 && RecentFolders.storedLimit == 20)
        #expect(SidebarPrefs.recentCountRange == 1...RecentFolders.storedLimit)
    }

    /// Folders gone leave Recent; refused ones and those not answered yet
    /// stay, in their order, and stored folders found again join at the end.
    @Test func recentDropsGoneFoldersAndTakesBackOnesFoundAgain() {
        let rows = RecentFolders.urls(["/Users/me/Docs", "/net/nas/export", "/Users/me/gone",
                                       "/Volumes/USB/reread", "/Users/me/new"])
        let waiting = RecentFolders.urls(["/Volumes/USB/back", "/Volumes/USB/away", "/Volumes/NAS/unread",
                                          "/Users/me/Docs"])
        let answers: [String: PinnedFolderAnswer<String>] = [
            ShellPath.key(rows[0]): .present("icon"), ShellPath.key(rows[1]): .refused,
            ShellPath.key(rows[2]): .missing, ShellPath.key(rows[3]): .missing,
            ShellPath.key(waiting[0]): .present("icon"), ShellPath.key(waiting[1]): .missing,
        ]
        // The reader says now: "gone" is missing; "reread" is being read again.
        let merged = RecentFolders.merged(rows, waiting: waiting, answers: answers) {
            $0 == ShellPath.key(rows[2]) || $0 == ShellPath.key(waiting[1])
        }
        #expect(merged.rows.map(\.path) == ["/Users/me/Docs", "/net/nas/export", "/Volumes/USB/reread",
                                            "/Users/me/new", "/Volumes/USB/back"])
        #expect(merged.waiting.map(\.path) == ["/Volumes/USB/away", "/Volumes/NAS/unread"])

        // One the list says is there but the reader has since found gone waits.
        let since = RecentFolders.merged([], waiting: [waiting[0]], answers: answers) { _ in true }
        #expect(since.rows.isEmpty)
        #expect(since.waiting == [waiting[0]])

        // No more rows than are stored.
        let many = RecentFolders.urls((0..<RecentFolders.storedLimit).map { "/Users/me/f\($0)" })
        let full = RecentFolders.merged(many, waiting: [waiting[0]], answers: answers) { _ in false }
        #expect(full.rows == many)
    }

    @Test func recentURLsAreMadeWithoutLookingAtTheirPaths() {
        let urls = RecentFolders.urls(["/Users/me/Docs", "/Volumes/NAS/Share"])
        #expect(urls.map(\.path) == ["/Users/me/Docs", "/Volumes/NAS/Share"])
        #expect(urls.allSatisfy { $0.hasDirectoryPath })
    }

    @Test func aFolderTheGuardRefusesIsUnchecked() {
        #expect(RecentFolders.isUnchecked("/net/nas.example/export"))
        #expect(RecentFolders.isUnchecked("/Users/me/link") { _ in .refused })
        #expect(!RecentFolders.isUnchecked("/Users/me/Docs") { _ in .safe })
        #expect(!RecentFolders.isUnchecked("/Users/me/gone") { _ in .missing })
    }

    /// By default the guard decides, and a path under /net is refused by its
    /// name alone, before anything is looked up. So is one under /home, on
    /// macOS (auto_home; on Linux it's the local users' folders).
    @Test func aFolderUnderNetIsRefusedByDefault() {
        var paths = ["/net/nas.example/export", "/Network/Servers/nas/x"]
        #if os(macOS)
        paths.append("/home/me/project")
        #endif
        #expect(paths.allSatisfy { RecentFolders.isUnchecked($0) })
    }
}

/// CGRect's (x:y:width:height:) and .zero are CoreGraphics', which Core doesn't use.
private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
    CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: w, height: h))
}

@Suite struct ShellResultsFocusTests {
    private let browser = rect(200, 0, 800, 600)
    private let sidebar = rect(0, 0, 200, 600)

    @Test func theSidebarIsNeverTheTarget() {
        #expect(ShellResultsFocus.target(listFrames: [sidebar], browserArea: browser, rightToLeft: false) == nil)
        let list = rect(200, 30, 800, 570)
        #expect(ShellResultsFocus.target(listFrames: [sidebar, list], browserArea: browser, rightToLeft: false) == 1)
    }

    @Test func theLastColumnIsTheTrailingOne() {
        let columns = [rect(200, 30, 230, 570),
                       rect(438, 30, 230, 570),
                       rect(676, 30, 230, 570)]
        #expect(ShellResultsFocus.target(listFrames: [sidebar] + columns, browserArea: browser,
                                         rightToLeft: false) == 3)
    }

    @Test func rightToLeftTrailingIsLeftmost() {
        // Mirrored window: browser on the left, sidebar on the right.
        let area = rect(0, 0, 800, 600)
        let rtlSidebar = rect(800, 0, 200, 600)
        let columns = [rect(570, 30, 230, 570),
                       rect(332, 30, 230, 570)]
        #expect(ShellResultsFocus.target(listFrames: [rtlSidebar] + columns, browserArea: area,
                                         rightToLeft: true) == 2)
    }

    @Test func listsOutOfSightAreSkipped() {
        let scrolledAway = rect(0, 0, 0, 0)
        let visible = rect(300, 30, 230, 570)
        #expect(ShellResultsFocus.target(listFrames: [visible, scrolledAway], browserArea: browser,
                                         rightToLeft: false) == 0)
    }

    /// Two panes side by side: each list belongs to the pane it's in.
    @Test func aListBelongsToThePaneItIsIn() {
        let left = rect(200, 0, 400, 600), right = rect(600, 0, 400, 600)
        let leftList = rect(200, 30, 400, 570), rightList = rect(600, 30, 400, 570)
        #expect(ShellResultsFocus.isInArea(leftList, browserArea: left))
        #expect(!ShellResultsFocus.isInArea(leftList, browserArea: right))
        #expect(ShellResultsFocus.isInArea(rightList, browserArea: right))
        #expect(!ShellResultsFocus.isInArea(rightList, browserArea: left))
        #expect(!ShellResultsFocus.isInArea(sidebar, browserArea: left))
        #expect(!ShellResultsFocus.isInArea(rect(300, 30, 0, 0), browserArea: left))
    }
}
