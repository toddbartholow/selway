import Foundation
import Testing
@testable import SelwayCore

@Suite(.serialized) struct DiskOverviewTests {
    private func volume(_ path: String, _ name: String, kind: DiskKind = .external,
                       browsable: Bool = true, server: ServerAddress? = nil) -> SidebarVolume {
        SidebarVolume(url: URL(fileURLWithPath: path, isDirectory: true), name: name,
                      isRoot: kind == .startup, isInternal: kind == .builtIn,
                      isLocal: kind != .network, isBrowsable: browsable,
                      isDiskImage: kind == .image, server: server)
    }

    private enum DiskKind: Equatable { case startup, builtIn, external, image, network }

    private var allGroups: [SidebarVolume] {
        let share = try! ServerAddress.parse("smb://192.0.2.36/Sounds").get().address
        return [volume("/Volumes/Z", "Zed"),
                volume("/Volumes/Share", "Sounds", kind: .network, server: share),
                volume("/Volumes/Image", "Installer", kind: .image),
                volume("/Volumes/Data", "Data", kind: .builtIn),
                volume("/", "Macintosh HD", kind: .startup),
                volume("/Volumes/Hidden", "Hidden", browsable: false)]
    }

    @Test func groupsUseLocationsClassificationAndOrder() throws {
        let overview = DiskOverview(volumes: allGroups)
        #expect(overview.groups.map(\.kind) == [.devicesAndDrives, .networkLocations])
        #expect(overview.groups.map(\.title) == ["Devices and Drives", "Network Locations"])
        #expect(overview.groups[0].entries.map(\.name) == ["Macintosh HD", "Data", "Zed", "Installer"])
        #expect(overview.groups[1].entries.map(\.name) == ["Sounds"])
        let share = try #require(overview.groups[1].entries.first)
        #expect(share.serverName == "192.0.2.36")
        #expect(share.capacity == .reading)
    }

    @Test func capacitiesFillTheirEntriesAndOthersStayReading() {
        let overview = DiskOverview(volumes: allGroups,
                                    capacities: ["/": .known(total: 1_000, free: 50), "/Volumes/Share": .unavailable])
        let entries = overview.groups.flatMap(\.entries)
        #expect(entries.first { $0.name == "Macintosh HD" }?.capacity == .known(total: 1_000, free: 50))
        #expect(entries.first { $0.name == "Sounds" }?.capacity == .unavailable)
        #expect(entries.first { $0.name == "Zed" }?.capacity == .reading)
    }

    @Test func emptyGroupsAreOmittedAndUnbrowsableVolumesAreLeftOut() {
        let overview = DiskOverview(volumes: [volume("/Volumes/Hidden", "Hidden", browsable: false)])
        #expect(overview.groups.isEmpty)
    }

    @Test func navigationUsesGridRowsAcrossGroupsAndHonorsListDirections() {
        #expect(DiskOverviewNavigation.destination(sectionCounts: [3, 2], columns: 2, leadIndex: nil,
                                                   direction: .left, isList: false) == 0)
        #expect(DiskOverviewNavigation.destination(sectionCounts: [3, 2], columns: 2, leadIndex: 2,
                                                   direction: .down, isList: false) == 3)
        #expect(DiskOverviewNavigation.destination(sectionCounts: [3, 2], columns: 2, leadIndex: 3,
                                                   direction: .up, isList: false) == 2)
        #expect(DiskOverviewNavigation.destination(sectionCounts: [2, 2], columns: 4, leadIndex: 1,
                                                   direction: .down, isList: true) == 2)
        #expect(DiskOverviewNavigation.destination(sectionCounts: [2, 2], columns: 4, leadIndex: 2,
                                                   direction: .up, isList: true) == 1)
        #expect(DiskOverviewNavigation.destination(sectionCounts: [2, 2], columns: 4, leadIndex: 1,
                                                   direction: .left, isList: true) == nil)
        #expect(DiskOverviewNavigation.destination(sectionCounts: [2, 2], columns: 4, leadIndex: nil,
                                                   direction: .right, isList: true) == nil)
    }

    @Test func usageRoundsToNearestIntegerAndClamps() {
        #expect(DiskOverviewUsage(total: 1_000, free: 101).usedFraction == 0.899)
        #expect(DiskOverviewUsage(total: 1_000, free: 101).percentUsed == 90)
        #expect(!DiskOverviewUsage(total: 1_000, free: 101).isLowSpace)
        #expect(DiskOverviewUsage(total: 1_000, free: 100).usedFraction == 0.9)
        #expect(DiskOverviewUsage(total: 1_000, free: 100).isLowSpace)
        #expect(DiskOverviewUsage(total: 200, free: 199).percentUsed == 1)
        #expect(DiskOverviewUsage(total: 1_000, free: 1_001).usedFraction == 0)
        #expect(DiskOverviewUsage(total: 1_000, free: 0).usedFraction == 1)
        #expect(DiskOverviewUsage(total: 1_000, free: -10).usedFraction == 1)
    }

    @Test func freeSpacePrefersImportantUsageUnlessTheVolumeReportsNone() {
        // A local APFS disk: purgeable space counts.
        #expect(VolumeFreeSpace.bytes(importantUsage: 52_200_170_489, available: 39_092_703_232) == 52_200_170_489)
        // An SMB or NFS share, or a Time Machine disk: important usage is zero.
        #expect(VolumeFreeSpace.bytes(importantUsage: 0, available: 37_338_363_064_320) == 37_338_363_064_320)
        #expect(VolumeFreeSpace.bytes(importantUsage: nil, available: 271_019_831_296) == 271_019_831_296)
        // Really full.
        #expect(VolumeFreeSpace.bytes(importantUsage: 0, available: 0) == 0)
        // A zero important figure is no reading on its own.
        #expect(VolumeFreeSpace.bytes(importantUsage: 0, available: nil) == nil)
        #expect(VolumeFreeSpace.bytes(importantUsage: nil, available: nil) == nil)
    }

    @Test func zeroTotalHasNoUsageOrLowSpace() {
        let usage = DiskOverviewUsage(total: 0, free: 0)
        #expect(usage.usedFraction == 0)
        #expect(usage.percentUsed == 0)
        #expect(!usage.isLowSpace)
    }

    @Test func capacityAndAccessibilityTextAreWholeEnglishStrings() {
        let disk = volume("/", "Macintosh HD", kind: .startup)
        let entry = DiskOverviewEntry(volume: disk, capacity: .known(total: 1_000_000_000_000,
                                                                    free: 67_800_000_000))
        let free = DiskOverviewUsage.fileSize(67_800_000_000)
        let total = DiskOverviewUsage.fileSize(1_000_000_000_000)
        #expect(entry.capacityText == "\(free) free of \(total)")
        #expect(entry.accessibilitySentence == "Macintosh HD, \(free) free of \(total), 93 percent used. Low space.")
        #expect(entry.accessibilityLabel == "Macintosh HD")
        #expect(entry.accessibilityValue == "\(free) free of \(total), 93 percent used. Low space.")
        #expect(entry.lowSpaceLabel == "Low space")

        let normal = DiskOverviewEntry(volume: disk, capacity: .known(total: 1_000, free: 200))
        #expect(normal.accessibilitySentence == "Macintosh HD, \(DiskOverviewUsage.fileSize(200)) free of \(DiskOverviewUsage.fileSize(1_000)), 80 percent used.")
        #expect(normal.accessibilityValue == "\(DiskOverviewUsage.fileSize(200)) free of \(DiskOverviewUsage.fileSize(1_000)), 80 percent used.")
        #expect(normal.lowSpaceLabel == nil)

        let unavailable = DiskOverviewEntry(volume: disk, capacity: .unavailable)
        #expect(unavailable.capacityText == "Space unavailable")
        #expect(unavailable.accessibilitySentence == "Macintosh HD, space information is unavailable.")
        #expect(unavailable.accessibilityValue == "Space unavailable")
        #expect(unavailable.lowSpaceLabel == nil)

        let reading = DiskOverviewEntry(volume: disk, capacity: .reading)
        #expect(reading.accessibilitySentence == "Macintosh HD, reading disk space.")
        #expect(reading.accessibilityValue == "Reading disk space…")
    }

    @Test func shareAccessibilityNameIncludesItsServer() throws {
        let server = try ServerAddress.parse("smb://files.example.com/home").get().address
        let share = DiskOverviewEntry(volume: volume("/Volumes/home", "home", kind: .network, server: server),
                                      capacity: .unavailable)
        #expect(share.accessibilityLabel == "home on files.example.com")
    }

    @Test func aHungReadTimesOutAndFurtherRefreshesDoNotStartAnotherRead() async {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let count = LockedInt()
        let reader = DiskCapacityReader(timeout: 0.08) { _ in
            count.increment()
            started.signal()
            release.wait()
            return (100, 25)
        }
        let url = URL(fileURLWithPath: "/Volumes/Slow", isDirectory: true)
        let first = Task { await reader.read(at: url) }
        #expect(await waitForSignal(started) == .success)

        let second = await reader.read(at: url)
        let firstResult = await first.value
        #expect(firstResult == .unavailable)
        #expect(second == .unavailable)
        #expect(count.value == 1)
        release.signal()
    }

    @Test func aHungNetworkReadDoesNotBlockAnotherVolume() async {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let reader = DiskCapacityReader(timeout: 0.3) { url in
            if url.lastPathComponent == "Network" {
                started.signal()
                release.wait()
                return nil
            }
            return (1_000, 250)
        }
        defer { release.signal() }
        let network = Task { await reader.read(at: URL(fileURLWithPath: "/Volumes/Network")) }
        #expect(await waitForSignal(started) == .success)
        #expect(await reader.read(at: URL(fileURLWithPath: "/Volumes/Local")) == .known(total: 1_000, free: 250))
        #expect(await network.value == .unavailable)
    }

    /// A read that finished early leaves its timer behind. When it fires, a
    /// later read of the same volume still within its own time is unaffected.
    @Test func anEarlierReadsTimerDoesNotExpireTheNextRead() async throws {
        let count = LockedInt()
        let release = DispatchSemaphore(value: 0)
        let reader = DiskCapacityReader(timeout: 2) { _ in
            count.increment()
            if count.value > 1 { release.wait() }
            return (100, 25)
        }
        let url = URL(fileURLWithPath: "/Volumes/Share", isDirectory: true)
        // The first timer fires at 2 s and the second read's at 2.8 s; the
        // second read answers between them.
        #expect(await reader.read(at: url) == .known(total: 100, free: 25))
        try await Task.sleep(for: .milliseconds(800))
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.6) { release.signal() }
        #expect(await reader.read(at: url) == .known(total: 100, free: 25))
    }

    private final class LockedInt: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
        func increment() { lock.lock(); stored += 1; lock.unlock() }
    }

    /// Waits on a GCD thread: blocking a Swift concurrency thread can starve
    /// the pool while other tests run in parallel.
    private func waitForSignal(_ semaphore: DispatchSemaphore) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: semaphore.wait(timeout: .now() + 1)) }
        }
    }
}
