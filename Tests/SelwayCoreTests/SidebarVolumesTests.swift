import Foundation
import Testing
@testable import SelwayCore

@Suite struct SidebarVolumesTests {
    private let home = URL(fileURLWithPath: "/Users/me")

    private func volume(_ path: String, _ name: String? = nil, root: Bool = false, builtIn: Bool = false,
                        ejectable: Bool = false, removable: Bool = false, local: Bool = true,
                        browsable: Bool = true, diskImage: Bool = false, disc: Bool = false) -> SidebarVolume {
        SidebarVolume(url: URL(fileURLWithPath: path, isDirectory: true),
                      name: name ?? URL(fileURLWithPath: path).lastPathComponent,
                      isRoot: root, isInternal: builtIn, isEjectable: ejectable, isRemovable: removable,
                      isLocal: local, isBrowsable: browsable, isDiskImage: diskImage, isOpticalDisc: disc)
    }

    // What this Mac reported (FileManager's volume keys and DiskArbitration) for each kind.
    private var startup:  SidebarVolume { volume("/", "Macintosh HD", root: true, builtIn: true) }
    private var data:     SidebarVolume { volume("/Volumes/Data", builtIn: true) }
    private var usb:      SidebarVolume { volume("/Volumes/T7") }
    private var stick:    SidebarVolume { volume("/Volumes/STICK", ejectable: true, removable: true) }
    private var sdCard:   SidebarVolume { volume("/Volumes/SD", builtIn: true, ejectable: true, removable: true) }
    private var image:    SidebarVolume { volume("/Volumes/Installer", ejectable: true, removable: true, diskImage: true) }
    private var dvd:      SidebarVolume { volume("/Volumes/MOVIE", ejectable: true, removable: true, disc: true) }
    private var share:    SidebarVolume { volume("/Volumes/Documents", local: false) }

    // MARK: Groups

    @Test func eachVolumeIsInFindersGroup() {
        #expect(startup.kind == .startupDisk)
        #expect(data.kind == .internalDisk)
        #expect(usb.kind == .externalDisk)
        #expect(image.kind == .discOrDiskImage)
        #expect(dvd.kind == .discOrDiskImage)
        #expect(share.kind == .network)
    }

    /// A USB stick and an SD card say they're removable (the card in the Mac's
    /// own reader, internal too), but Finder lists them as external disks, not
    /// with CDs and DVDs.
    @Test func removableDrivesAreExternalDisks() {
        #expect(stick.kind == .externalDisk)
        #expect(sdCard.kind == .externalDisk)
    }

    @Test func aServerIsNetworkWhateverElseItSays() {
        #expect(volume("/Volumes/S", local: false, diskImage: true).kind == .network)
        #expect(volume("/Volumes/S", builtIn: true, local: false).kind == .network)
    }

    @Test func eachKindHasItsSettingsGroup() {
        #expect(SidebarVolume.Kind.startupDisk.group == .hardDisks)
        #expect(SidebarVolume.Kind.internalDisk.group == .hardDisks)
        #expect(SidebarVolume.Kind.externalDisk.group == .externalDisks)
        #expect(SidebarVolume.Kind.discOrDiskImage.group == .discsAndImages)
        #expect(SidebarVolume.Kind.network.group == .networkVolumes)
    }

    // MARK: Order and filtering

    private var all: Set<SidebarVolume.Group> { Set(SidebarVolume.Group.allCases) }

    @Test func startupDiskFirstThenInternalExternalDiscsAndServers() {
        let rows = SidebarVolumes.rows([share, dvd, usb, image, data, startup], showing: all)
        #expect(rows.map(\.name) == ["Macintosh HD", "Data", "T7", "Installer", "MOVIE", "Documents"])
    }

    @Test func byNameWithinAGroupAsFinderSortsThem() {
        let rows = SidebarVolumes.rows([volume("/Volumes/b10"), volume("/Volumes/B2"), volume("/Volumes/a")],
                                       showing: all)
        #expect(rows.map(\.name) == ["a", "B2", "b10"])
        // The same name twice keeps one order, whichever way round they come.
        let one = volume("/Volumes/Untitled", "Untitled"), two = volume("/Volumes/Untitled 1", "Untitled")
        #expect(SidebarVolumes.sorted([two, one]) == [one, two])
        #expect(SidebarVolumes.sorted([one, two]) == [one, two])
    }

    @Test func hiddenGroupsAndUnbrowsableVolumesAreLeftOut() {
        let volumes = [startup, data, usb, image, share, volume("/Volumes/Recovery", browsable: false)]
        #expect(SidebarVolumes.rows(volumes, showing: [.externalDisks, .networkVolumes]).map(\.name)
                == ["T7", "Documents"])
        #expect(SidebarVolumes.rows(volumes, showing: [.hardDisks]).map(\.name) == ["Macintosh HD", "Data"])
        #expect(SidebarVolumes.rows(volumes, showing: []).isEmpty)
        #expect(!SidebarVolumes.rows(volumes, showing: all).contains { $0.name == "Recovery" })
    }

    @Test func everyGroupShowsByDefaultUnderASelwayKey() {
        #expect(SidebarVolume.Group.allCases.allSatisfy { $0.defaultShown })
        let keys = SidebarVolume.Group.allCases.map(\.key)
        #expect(Set(keys).count == 4)
        #expect(keys.allSatisfy { $0.hasPrefix("selwaySidebar") })
        #expect(SidebarVolume.Group.discsAndImages.title == "CDs, DVDs and disk images")
    }

    // MARK: Eject

    @Test func everythingButTheStartupAndInternalDisksEjects() {
        #expect(!startup.canEject)
        #expect(!data.canEject)
        // External drives often report neither ejectable nor removable.
        #expect(usb.canEject)
        #expect(stick.canEject && sdCard.canEject && image.canEject && dvd.canEject && share.canEject)
    }

    @Test func busyProcessNamesAreUniqueAndSorted() {
        #expect(SidebarVolumes.busyProcessNames(["Photos", "Preview", "Photos"]) == ["Photos", "Preview"])
        #expect(SidebarVolumes.busyProcessNames(["  ", "Preview"]) == ["Preview"])
    }

    @Test func busyAppNamesNameOnlyAppsAndSelwayOnlyWhenNothingElseHoldsTheDisk() {
        typealias P = SidebarVolumes.BusyProcess
        let selway = P(name: "Selway", isApp: true, isSelf: true)
        let photos = P(name: "Photos", isApp: true, isSelf: false)
        let preview = P(name: "Preview", isApp: true, isSelf: false)
        let daemon = P(name: "cloudphotod", isApp: false, isSelf: false)
        let tool = P(name: "2.1.307", isApp: false, isSelf: false)
        #expect(SidebarVolumes.busyAppNames([preview, daemon, selway, photos, tool, photos]) == ["Photos", "Preview"])
        // Only daemons and tools: no names, so the alert says programs may be using it.
        #expect(SidebarVolumes.busyAppNames([daemon, tool, selway]).isEmpty)
        #expect(SidebarVolumes.busyAppNames([selway]) == ["Selway"])
        // Another app called Selway is still named.
        #expect(SidebarVolumes.busyAppNames([selway, P(name: "Selway", isApp: true, isSelf: false)]) == ["Selway"])
        #expect(SidebarVolumes.busyAppNames([]).isEmpty)
    }

    @Test func busyEjectMessageNamesOneOrSeveralAppsAndFallsBackWhenUnknown() {
        #expect(SidebarVolumes.ejectFailure(name: "Backup", isBusy: true, reason: nil,
                                            using: ["Preview"]).title
                == "“Backup” wasn’t ejected because “Preview” is using it.")
        #expect(SidebarVolumes.ejectFailure(name: "Backup", isBusy: true, reason: nil,
                                            using: ["Preview", "Photos"]).title
                == "“Backup” wasn’t ejected because “Photos” and “Preview” are using it.")
        #expect(SidebarVolumes.ejectFailure(name: "Backup", isBusy: true, reason: nil,
                                            using: ["Preview", "Photos", "Music"]).title
                == "“Backup” wasn’t ejected because “Music”, “Photos” and other apps are using it.")
        #expect(SidebarVolumes.ejectFailure(name: "Backup", isBusy: true, reason: nil).title
                == "“Backup” wasn’t ejected because one or more programs may be using it.")
        #expect(SidebarVolumes.ejectFailure(name: "Backup", isBusy: true, reason: nil).detail
                == "Quit any app that may be using a file on it, then try again.")
    }

    @Test func apfsContainerResolvesThroughSchemeToPhysicalWholeDisk() {
        let chain = [
            SidebarVolumes.RegistryEntry(className: "IOMedia", isWhole: true, bsdName: "disk5"),
            SidebarVolumes.RegistryEntry(className: "AppleAPFSContainerScheme", isWhole: false, bsdName: nil),
            SidebarVolumes.RegistryEntry(className: "IOMedia", isWhole: false, bsdName: "disk4s2"),
            SidebarVolumes.RegistryEntry(className: "IOMedia", isWhole: true, bsdName: "disk4")
        ]
        let mappedDisk = SidebarVolumes.physicalWholeDisk(container: "disk5", chain: chain, isComposited: false)
        let apfs = SidebarVolume(url: URL(fileURLWithPath: "/Volumes/APFS"), name: "APFS", wholeDisk: mappedDisk)
        let hfs = SidebarVolume(url: URL(fileURLWithPath: "/Volumes/HFS"), name: "HFS", wholeDisk: "disk4")
        #expect(mappedDisk == "disk4")
        #expect(apfs.ejectKey == hfs.ejectKey)
    }

    @Test func physicalWholeDiskLeavesHFSAndCompositedContainersAlone() {
        let hfsChain = [SidebarVolumes.RegistryEntry(className: "IOMedia", isWhole: true, bsdName: "disk4")]
        #expect(SidebarVolumes.physicalWholeDisk(container: "disk4", chain: hfsChain, isComposited: false)
                == "disk4")

        let compositedChain = [
            SidebarVolumes.RegistryEntry(className: "IOMedia", isWhole: true, bsdName: "disk5"),
            SidebarVolumes.RegistryEntry(className: "AppleAPFSContainerScheme", isWhole: false, bsdName: nil),
            SidebarVolumes.RegistryEntry(className: "IOMedia", isWhole: false, bsdName: "disk4s2"),
            SidebarVolumes.RegistryEntry(className: "IOMedia", isWhole: true, bsdName: "disk4")
        ]
        #expect(SidebarVolumes.physicalWholeDisk(container: "disk5", chain: compositedChain, isComposited: true)
                == "disk5")
    }

    @Test func quickLookDropsOnlyItemsOnEjectedVolumeAndClosesWhenCurrentItemIsRemoved() {
        let volume = URL(fileURLWithPath: "/Volumes/USB", isDirectory: true)
        let usbItem = URL(fileURLWithPath: "/Volumes/USB/photo.jpg")
        let localItem = URL(fileURLWithPath: "/Users/me/preview.pdf")
        let currentRemains = SidebarVolumes.quickLookItems(afterUnmounting: volume,
                                                            urls: [usbItem, localItem], current: 1)
        #expect(currentRemains.urls == [localItem])
        #expect(currentRemains.current == 0)
        #expect(!currentRemains.shouldClose)
        let currentRemoved = SidebarVolumes.quickLookItems(afterUnmounting: volume,
                                                            urls: [usbItem, localItem], current: 0)
        #expect(currentRemoved.urls == [localItem])
        #expect(currentRemoved.shouldClose)
        let empty = SidebarVolumes.quickLookItems(afterUnmounting: volume, urls: [usbItem], current: nil)
        #expect(empty.urls.isEmpty)
        #expect(empty.shouldClose)
    }

    @Test func quickLookKeepsShowingTheSameItemWhenItemsAheadOfItAreRemoved() {
        let volume = URL(fileURLWithPath: "/Volumes/USB", isDirectory: true)
        let a = URL(fileURLWithPath: "/Volumes/USB/a.jpg")
        let b = URL(fileURLWithPath: "/Users/me/b.pdf")
        let c = URL(fileURLWithPath: "/Volumes/USB/c.jpg")
        let d = URL(fileURLWithPath: "/Users/me/d.txt")
        let e = URL(fileURLWithPath: "/Volumes/USBStick/e.txt")
        let update = SidebarVolumes.quickLookItems(afterUnmounting: volume, urls: [a, b, c, d, e], current: 3)
        #expect(update.urls == [b, d, e])
        #expect(update.current.map { update.urls[$0] } == d)
        #expect(!update.shouldClose)
        // An index the panel no longer has (or none) doesn't close it.
        let stale = SidebarVolumes.quickLookItems(afterUnmounting: volume, urls: [a, b], current: 7)
        #expect(stale.urls == [b] && stale.current == nil && !stale.shouldClose)
        let unknown = SidebarVolumes.quickLookItems(afterUnmounting: volume, urls: [a, b], current: nil)
        #expect(unknown.urls == [b] && unknown.current == nil && !unknown.shouldClose)
    }

    /// `links`: path → target, as `readlink` would give them. `servers`: the
    /// connected servers' mount points, whose links mustn't be read (`read`
    /// records every path that was).
    private func after(ejecting path: String, showing folder: String, links: [String: String] = [:],
                       home: URL? = nil, servers: [String] = [], read: Recorder? = nil) -> URL? {
        SidebarVolumes.folder(afterUnmounting: URL(fileURLWithPath: path, isDirectory: true),
                              showing: URL(fileURLWithPath: folder), home: home ?? self.home,
                              servers: servers.map { URL(fileURLWithPath: $0) },
                              readLink: { read?.paths.append($0); return links[$0] })
    }

    final class Recorder { var paths: [String] = [] }

    @Test func aWindowOnTheVolumeGoesHome() {
        #expect(after(ejecting: "/Volumes/USB", showing: "/Volumes/USB") == home)
        #expect(after(ejecting: "/Volumes/USB", showing: "/Volumes/USB/") == home)
        #expect(after(ejecting: "/Volumes/USB/", showing: "/Volumes/USB/photos/2026") == home)
    }

    @Test func aWindowElsewhereStays() {
        #expect(after(ejecting: "/Volumes/USB", showing: "/Users/me/Desktop") == nil)
        // A name that starts the same isn't the same volume.
        #expect(after(ejecting: "/Volumes/USB", showing: "/Volumes/USB 2/photos") == nil)
        #expect(after(ejecting: "/Volumes/USB", showing: "/Volumes") == nil)
    }

    /// ~/Downloads linked to a folder on the drive: the window shows a home
    /// path, but its folder is on the drive.
    /// The window has moved once the drive is gone, so the link points
    /// nowhere; it's read, not resolved, so it still counts.
    @Test func aFolderReachedThroughALinkIsOnTheVolumeItLinksTo() {
        let downloads = ["/Users/me/Downloads": "/Volumes/T7/Downloads"]
        #expect(after(ejecting: "/Volumes/T7", showing: "/Users/me/Downloads", links: downloads) == home)
        #expect(after(ejecting: "/Volumes/T7", showing: "/Users/me/Downloads/2026", links: downloads) == home)
        #expect(after(ejecting: "/Volumes/T7", showing: "/Users/me/Downloads") == nil)
        #expect(after(ejecting: "/Volumes/USB", showing: "/Users/me/Downloads", links: downloads) == nil)
    }

    @Test func homeOnTheVolumeSendsTheWindowToTheStartupDisk() {
        let home = URL(fileURLWithPath: "/Volumes/Home/me")
        #expect(after(ejecting: "/Volumes/Home", showing: "/Volumes/Home/me/src", home: home)
                == URL(fileURLWithPath: "/"))
        // /Users/me linked to the drive: home is on it all the same.
        #expect(after(ejecting: "/Volumes/Home", showing: "/Volumes/Home/me/src",
                      links: ["/Users/me": "/Volumes/Home/me"]) == URL(fileURLWithPath: "/"))
    }

    /// A window on another server, one that may have stopped answering: its
    /// path is never read, only compared.
    @Test func linksOnAConnectedServerAreNeverRead() {
        let read = Recorder()
        #expect(after(ejecting: "/Volumes/USB", showing: "/Volumes/Share/projects/app",
                      servers: ["/Volumes/Share"], read: read) == nil)
        #expect(!read.paths.contains { $0.hasPrefix("/Volumes/Share") })
        #expect(read.paths.contains("/Volumes"))
        // A link from this Mac onto the server is read up to the server.
        let viaLink = Recorder()
        #expect(after(ejecting: "/Volumes/USB", showing: "/Users/me/work/app",
                      links: ["/Users/me/work": "/Volumes/Share/work"], servers: ["/Volumes/Share"],
                      read: viaLink) == nil)
        #expect(viaLink.paths.contains("/Users/me/work"))
        #expect(!viaLink.paths.contains { $0.hasPrefix("/Volumes/Share") })
        #expect(SidebarVolumes.mayFollowLinks(at: URL(fileURLWithPath: "/Volumes/Share 2"),
                                              servers: [URL(fileURLWithPath: "/Volumes/Share")]))
        #expect(!SidebarVolumes.mayFollowLinks(at: URL(fileURLWithPath: "/Volumes/Share"),
                                               servers: [URL(fileURLWithPath: "/Volumes/Share")]))
    }

    /// A window's panes, active first: each pane on the volume leaves it,
    /// whether or not it's the active one, and the others stay.
    @Test func eachPaneOnTheVolumeLeavesIt() {
        // Which panes (by their index in the window) move, and where to.
        func after(ejecting path: String, showing folders: [String],
                   links: [String: String] = [:]) -> [String] {
            let panes = folders.enumerated().map { (index: $0.offset, folder: URL(fileURLWithPath: $0.element)) }
            return SidebarVolumes.moves(afterUnmounting: URL(fileURLWithPath: path, isDirectory: true),
                                        panes: panes, folder: \.folder, home: home,
                                        servers: [], readLink: { links[$0] })
                .map { "\($0.pane.index) \($0.to.path)" }
        }
        #expect(after(ejecting: "/Volumes/USB", showing: ["/Volumes/USB/a", "/Users/me/Desktop"]) == ["0 \(home.path)"])
        // The inactive pane (second here, the active pane coming first) moves too.
        #expect(after(ejecting: "/Volumes/USB", showing: ["/Users/me/Desktop", "/Volumes/USB"]) == ["1 \(home.path)"])
        #expect(after(ejecting: "/Volumes/USB", showing: ["/Volumes/USB/a", "/Volumes/USB/b"])
                == ["0 \(home.path)", "1 \(home.path)"])
        #expect(after(ejecting: "/Volumes/USB", showing: ["/Users/me", "/Volumes/USB 2"]) == [])
        // One reached through a link, beside one on the volume itself.
        #expect(after(ejecting: "/Volumes/T7", showing: ["/Users/me/Downloads", "/Volumes/T7/x"],
                      links: ["/Users/me/Downloads": "/Volumes/T7/Downloads"]) == ["0 \(home.path)", "1 \(home.path)"])
        #expect(after(ejecting: "/Volumes/USB", showing: []) == [])
    }

    @Test func panesWithoutFoldersAreSkippedWhenMovingOffAnEjectedVolume() {
        let panes: [(index: Int, folder: URL?)] = [
            (0, nil),
            (1, URL(fileURLWithPath: "/Volumes/USB/work"))
        ]
        let moves = SidebarVolumes.moves(afterUnmounting: URL(fileURLWithPath: "/Volumes/USB", isDirectory: true),
                                         panes: panes, folder: \.folder, home: home, servers: [], readLink: { _ in nil })
        #expect(moves.map { $0.pane.index } == [1])
        #expect(moves.map { $0.to } == [home])
    }

    /// A pane shown again after its folder went while it was hidden: up to the
    /// nearest folder still there, or home when its disk went (not /Volumes).
    @Test func aGoneFolderIsLeftForTheNearestOneOrHomeOffAGoneDisk() {
        func replacing(_ path: String, existing: Set<String>) -> String? {
            SidebarVolumes.folder(replacingGone: URL(fileURLWithPath: path), home: home,
                                  exists: { existing.contains($0) })?.path
        }
        let mac: Set = ["/", "/Users", "/Users/me", "/Volumes"]
        #expect(replacing("/Users/me/a/b", existing: mac) == "/Users/me")
        #expect(replacing("/Volumes/USB/a/b", existing: mac.union(["/Volumes/USB"])) == "/Volumes/USB")
        #expect(replacing("/Volumes/USB/a", existing: mac) == home.path)
        #expect(replacing("/Volumes/USB", existing: mac) == home.path)
        // Home on the disk that went too: the startup disk.
        #expect(replacing("/Volumes/USB/a", existing: ["/", "/Volumes"]) == "/")
        // Still there: stays.
        #expect(replacing("/Users/me", existing: mac) == nil)
    }

    // MARK: Following links

    private func follow(_ path: String, _ links: [String: String]) -> String {
        ShellPath.followingLinks(URL(fileURLWithPath: path), readLink: { links[$0] }).path
    }

    @Test func linksAreFollowedWhetherOrNotTheirTargetExists() {
        #expect(follow("/tmp/a/b", ["/tmp": "private/tmp"]) == "/private/tmp/a/b")
        #expect(follow("/x/link/c", ["/x/link": "../y"]) == "/y/c")
        #expect(follow("/x/link/c", ["/x/link": "/Volumes/Gone/z"]) == "/Volumes/Gone/z/c")
        // A link to a link.
        #expect(follow("/a/b", ["/a": "/c", "/c": "/d"]) == "/d/b")
        #expect(follow("/", [:]) == "/")
    }

    @Test func aLoopOfLinksStops() {
        _ = follow("/a/b", ["/a": "/b", "/b": "/a"])
    }

    @Test func skippedPathsAreNotRead() {
        var read: [String] = []
        let url = ShellPath.followingLinks(URL(fileURLWithPath: "/s/x/y"),
                                           readLink: { read.append($0); return nil },
                                           skip: { $0.path.hasPrefix("/s") })
        #expect(url.path == "/s/x/y")
        #expect(read.isEmpty)
    }

    /// Regression: `URL(fileURLWithPath:)` without `isDirectory:` looks at the
    /// disk to decide on a trailing slash, so skipped paths (a server that has
    /// stopped answering) were still read. Given a real folder, the URLs handed
    /// to `skip` and returned would end in "/" if it had been looked at.
    @Test func skippedPathsAreNotLookedAtEither() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarVolumesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var asked: [URL] = []
        let url = ShellPath.followingLinks(folder, readLink: { _ in nil }) { asked.append($0); return true }
        #expect(!asked.isEmpty)
        #expect(asked.allSatisfy { !$0.hasDirectoryPath })
        #expect(!url.hasDirectoryPath)
        #expect(ShellPath.same(url, folder))
    }

    // MARK: Ejecting a disk

    @Test func volumesOnOneDiskShareAnEjectKey() {
        var a = image, b = volume("/Volumes/Other", ejectable: true, removable: true, diskImage: true)
        a.wholeDisk = "disk12"; b.wholeDisk = "disk12"
        #expect(a.ejectKey == b.ejectKey)
        b.wholeDisk = "disk13"
        #expect(a.ejectKey != b.ejectKey)
        // A server's share has no disk: its path. A path named like a disk is still a path.
        #expect(share.ejectKey != volume("/Volumes/Data", local: false).ejectKey)
        #expect(volume("/disk12", local: false).ejectKey != a.ejectKey)
    }

    @Test func voiceOverHearsTheKind() {
        #expect([startup, data, usb, image, dvd, share].map(\.kindDescription)
                == ["Startup disk", "Internal disk", "External disk", "Disk image", "Disc", "Server"])
    }

    @Test func theStartupDiskNeverMovesAWindow() {
        #expect(after(ejecting: "/", showing: "/Users/me") == nil)
    }

    @Test func aBusyVolumeGetsFindersMessage() {
        let busy = SidebarVolumes.ejectFailure(name: "T7", isBusy: true, reason: "(OSStatus error -47.)")
        #expect(busy.title == "“T7” wasn’t ejected because one or more programs may be using it.")
        #expect(!busy.detail.contains("-47"))
        let other = SidebarVolumes.ejectFailure(name: "T7", isBusy: false, reason: " The disk is gone. ")
        #expect(other.title == "“T7” couldn’t be ejected.")
        #expect(other.detail == "The disk is gone.")
        #expect(!SidebarVolumes.ejectFailure(name: "T7", isBusy: false, reason: nil).detail.isEmpty)
    }

    @Test func busyErrorsAreRecognised() {
        #expect(SidebarVolumes.isBusy(errorDomain: "NSOSStatusErrorDomain", code: -47))
        #expect(SidebarVolumes.isBusy(errorDomain: "NSPOSIXErrorDomain", code: 16))
        #expect(!SidebarVolumes.isBusy(errorDomain: "NSOSStatusErrorDomain", code: -35))
        #expect(!SidebarVolumes.isBusy(errorDomain: "NSCocoaErrorDomain", code: -47))
    }

    // MARK: Selection

    private let desktop = URL(fileURLWithPath: "/Users/me/Desktop")
    private let usbURL  = URL(fileURLWithPath: "/Volumes/USB", isDirectory: true)
    private let rootURL = URL(fileURLWithPath: "/", isDirectory: true)

    private func match(_ path: URL, selected: SidebarItem? = nil, locations: [URL]? = nil,
                       pinned: [URL] = []) -> SidebarItem? {
        SidebarSelection.matchingItem(for: path, selected: selected, locations: locations ?? [home, desktop],
                                      volumes: [rootURL, usbURL], pinned: pinned)
    }

    @Test func theVolumeRowFollowsTheFolder() {
        #expect(match(URL(fileURLWithPath: "/")) == .volume(rootURL))
        #expect(match(URL(fileURLWithPath: "/Volumes/USB/")) == .volume(usbURL))
        #expect(match(URL(fileURLWithPath: "/Volumes/USB/photos")) == nil)
    }

    /// The sidebar's own order: Favorites, Locations, Pinned. A selected row for
    /// the folder stays whichever section it's in.
    @Test func locationsComeAfterFavoritesAndBeforePinned() {
        #expect(match(usbURL, pinned: [usbURL]) == .volume(usbURL))
        #expect(match(usbURL, locations: [usbURL]) == .location(usbURL))
        #expect(match(usbURL, selected: .pinned(usbURL), pinned: [usbURL]) == .pinned(usbURL))
        #expect(match(usbURL, selected: .recent(usbURL)) == .recent(usbURL))
        #expect(match(home, selected: .volume(usbURL)) == .location(home))
    }

    /// Regression: the selection stayed on an ejected drive's row (gone from
    /// the list) when the window was still on its path.
    @Test func aRowNoLongerListedIsntKept() {
        let gone = URL(fileURLWithPath: "/Volumes/Gone", isDirectory: true)
        #expect(match(gone, selected: .volume(gone)) == nil)
        #expect(match(desktop, selected: .location(desktop), locations: [home]) == nil)
        #expect(match(usbURL, selected: .pinned(usbURL)) == .volume(usbURL))
    }

    @Test func selectingAVolumeGoesThere() {
        #expect(SidebarSelection.userSelected(.volume(usbURL), currentPath: home, isAvailable: { _ in false })
                == .navigate(.folder(usbURL)))
        #expect(SidebarSelection.userSelected(.volume(usbURL), currentPath: URL(fileURLWithPath: "/Volumes/USB/"),
                                              isAvailable: { _ in true }) == .stay)
    }
}
