import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#endif

/// A volume's disk capacity, including reads that are in progress or did not
/// answer before their deadline.
enum DiskCapacityState: Equatable, Sendable {
    case known(total: Int64, free: Int64)
    case reading
    case unavailable
}

/// The values a disk overview needs for one mounted volume. `url` also lets a
/// view ask the platform for its volume icon without storing UI types here.
struct DiskOverviewEntry: Identifiable, Equatable, Sendable {
    let volume: SidebarVolume
    var capacity: DiskCapacityState

    var id: String { ShellPath.key(volume.url) }
    var name: String { volume.name }
    /// The host name of a mounted network share, when its mount source parsed.
    var serverName: String? { volume.server?.host }
    var isLowSpace: Bool { usage?.isLowSpace ?? false }

    var usage: DiskOverviewUsage? {
        guard case let .known(total, free) = capacity else { return nil }
        return DiskOverviewUsage(total: total, free: free)
    }

    /// Localized free and total sizes, or a readable state while capacity is
    /// being read or is unavailable.
    var capacityText: String {
        switch capacity {
        case let .known(total, free):
            let format = NSLocalizedString("%1$@ free of %2$@", comment: "Free and total space for a disk")
            return String.localizedStringWithFormat(format,
                DiskOverviewUsage.fileSize(free), DiskOverviewUsage.fileSize(total))
        case .reading:
            return NSLocalizedString("Reading disk space…", comment: "Disk capacity is being read")
        case .unavailable:
            return NSLocalizedString("Space unavailable", comment: "Disk capacity is unavailable")
        }
    }

    /// A whole sentence for VoiceOver, including the text equivalent of the
    /// low space color state.
    var accessibilitySentence: String {
        guard let usage else {
            if case .reading = capacity {
                let format = NSLocalizedString("%1$@, reading disk space.",
                                               comment: "VoiceOver sentence while disk capacity is being read")
                return String.localizedStringWithFormat(format, name)
            }
            let format = NSLocalizedString("%1$@, space information is unavailable.",
                                           comment: "VoiceOver sentence when disk capacity is unavailable")
            return String.localizedStringWithFormat(format, name)
        }
        if usage.isLowSpace {
            let format = NSLocalizedString("%1$@, %2$@ free of %3$@, %4$lld percent used. Low space.",
                                           comment: "VoiceOver sentence for a disk with low space")
            return String.localizedStringWithFormat(format, name, DiskOverviewUsage.fileSize(usage.free),
                                                    DiskOverviewUsage.fileSize(usage.total), usage.percentUsed)
        }
        let format = NSLocalizedString("%1$@, %2$@ free of %3$@, %4$lld percent used.",
                                       comment: "VoiceOver sentence for disk capacity")
        return String.localizedStringWithFormat(format, name, DiskOverviewUsage.fileSize(usage.free),
                                                DiskOverviewUsage.fileSize(usage.total), usage.percentUsed)
    }

    /// The name VoiceOver uses for this volume, including its server when the
    /// same share name can appear on more than one host.
    var accessibilityLabel: String {
        guard let serverName else { return name }
        let format = NSLocalizedString("%1$@ on %2$@", comment: "Disk name and server name for VoiceOver")
        return String.localizedStringWithFormat(format, name, serverName)
    }

    /// The space sentence VoiceOver reads as the value of the named volume.
    var accessibilityValue: String {
        guard let usage else { return capacityText }
        if usage.isLowSpace {
            let format = NSLocalizedString("%1$@ free of %2$@, %3$lld percent used. Low space.",
                                           comment: "VoiceOver value for a disk with low space")
            return String.localizedStringWithFormat(format, DiskOverviewUsage.fileSize(usage.free),
                                                    DiskOverviewUsage.fileSize(usage.total), usage.percentUsed)
        }
        let format = NSLocalizedString("%1$@ free of %2$@, %3$lld percent used.",
                                       comment: "VoiceOver value for disk capacity")
        return String.localizedStringWithFormat(format, DiskOverviewUsage.fileSize(usage.free),
                                                DiskOverviewUsage.fileSize(usage.total), usage.percentUsed)
    }

    /// Whole localized label for the red usage bar state.
    var lowSpaceLabel: String? {
        isLowSpace ? NSLocalizedString("Low space", comment: "Disk has at least 90 percent of its space used") : nil
    }
}

/// Percentage math shared by the usage bar, labels, and accessibility text.
struct DiskOverviewUsage: Equatable, Sendable {
    static let lowSpaceThreshold = 0.90

    let total: Int64
    let free: Int64

    /// Used fraction clamped to 0...1. A zero-sized volume has no usage.
    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - Double(free) / Double(total)))
    }

    /// Rounded to the nearest whole percent (half values round upward).
    var percentUsed: Int { Int((usedFraction * 100).rounded()) }

    var isLowSpace: Bool { total > 0 && usedFraction >= Self.lowSpaceThreshold }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// One of the two sections in the computer overview.
struct DiskOverviewGroup: Equatable, Sendable {
    enum Kind: Int, Equatable, Sendable { case devicesAndDrives, networkLocations }

    let kind: Kind
    let entries: [DiskOverviewEntry]

    var title: String {
        switch kind {
        case .devicesAndDrives:
            return NSLocalizedString("Devices and Drives", comment: "Disk overview group heading")
        case .networkLocations:
            return NSLocalizedString("Network Locations", comment: "Disk overview group heading")
        }
    }
}

/// The disk overview contents in the same classification and order as
/// Locations. Empty sections are omitted so a view can render `groups` as-is.
/// `capacities` holds what DiskCapacityReader has said so far, keyed by
/// `DiskOverviewEntry.id`; a volume missing from it is still being read.
struct DiskOverview: Equatable, Sendable {
    let groups: [DiskOverviewGroup]

    init(volumes: [SidebarVolume], capacities: [String: DiskCapacityState] = [:]) {
        func entry(_ volume: SidebarVolume) -> DiskOverviewEntry {
            DiskOverviewEntry(volume: volume, capacity: capacities[ShellPath.key(volume.url)] ?? .reading)
        }
        let ordered = SidebarVolumes.rows(volumes, showing: Set(SidebarVolume.Group.allCases))
        let devices = ordered.filter { $0.kind != .network }
        let network = ordered.filter { $0.kind == .network }
        groups = [
            DiskOverviewGroup(kind: .devicesAndDrives,
                              entries: devices.map(entry)),
            DiskOverviewGroup(kind: .networkLocations,
                              entries: network.map(entry))
        ].filter { !$0.entries.isEmpty }
    }
}

/// Moves the selection through the overview's group order, in its tile or row layout.
enum DiskOverviewNavigation {
    static func destination(sectionCounts: [Int], columns: Int, leadIndex: Int?,
                            direction: IconGridNavigation.Direction, isList: Bool) -> Int? {
        if isList && (direction == .left || direction == .right) { return nil }
        let counts = sectionCounts.map { max(0, $0) }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        guard let leadIndex, (0..<total).contains(leadIndex) else { return 0 }
        if isList {
            switch direction {
            case .up: return max(0, leadIndex - 1)
            case .down: return min(total - 1, leadIndex + 1)
            case .left, .right: return nil
            }
        }
        return IconGridNavigation.destination(sectionCounts: counts, columns: columns,
                                              leadIndex: leadIndex, direction: direction)
    }
}

/// A volume's free space as Finder shows it: the important-usage figure,
/// which counts purgeable space. Network shares, NFS mounts and Time Machine
/// disks report that as zero however much is free, so this falls back to the
/// available bytes. A zero with no available figure says nothing: nil.
enum VolumeFreeSpace {
    static func bytes(importantUsage: Int64?, available: Int?) -> Int64? {
        if let importantUsage, importantUsage > 0 { return importantUsage }
        return available.map(Int64.init)
    }
}

/// Reads volume capacity away from the caller's thread and returns after a
/// deadline. A timed out operation remains registered until its system read
/// actually returns, so repeated refreshes cannot create more than one stuck
/// read per volume. Retain one reader across refreshes to preserve that limit.
/// Different volumes are read independently.
final class DiskCapacityReader: @unchecked Sendable {
    typealias ReadCapacity = (URL) -> (total: Int64, free: Int64)?

    private struct PendingRead {
        /// Which read of the volume this is: a finished read's timer mustn't
        /// expire the next read of the same volume.
        let generation: Int
        var waiters: [CheckedContinuation<DiskCapacityState, Never>]
        var didTimeOut = false
    }

    private let timeout: TimeInterval
    private let readCapacity: ReadCapacity
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "studio.irq.selway.disk-capacity", qos: .utility,
                                      attributes: .concurrent)
    private var pending: [String: PendingRead] = [:]
    private var nextGeneration = 0

    convenience init(timeout: TimeInterval = 2) {
        self.init(timeout: timeout, readCapacity: Self.readSystemCapacity)
    }

    init(timeout: TimeInterval = 2, readCapacity: @escaping ReadCapacity) {
        self.timeout = max(0, timeout)
        self.readCapacity = readCapacity
    }

    /// Coalesces callers for the same volume. `reading` is returned by the
    /// overview model while no result is available; an expired read is
    /// reported as `unavailable`.
    func read(at url: URL) async -> DiskCapacityState {
        let key = ShellPath.key(url)
        return await withCheckedContinuation { continuation in
            lock.lock()
            if var current = pending[key] {
                if current.didTimeOut {
                    lock.unlock()
                    continuation.resume(returning: .unavailable)
                } else {
                    current.waiters.append(continuation)
                    pending[key] = current
                    lock.unlock()
                }
                return
            }
            nextGeneration += 1
            let generation = nextGeneration
            pending[key] = PendingRead(generation: generation, waiters: [continuation])
            lock.unlock()

            queue.async { [self] in
                let result = readCapacity(url).map { DiskCapacityState.known(total: $0.total, free: $0.free) }
                    ?? .unavailable
                complete(key: key, result: result)
            }
            queue.asyncAfter(deadline: .now() + timeout) { [self] in timeOut(key: key, generation: generation) }
        }
    }

    private func timeOut(key: String, generation: Int) {
        lock.lock()
        guard var current = pending[key], current.generation == generation, !current.didTimeOut else {
            lock.unlock()
            return
        }
        current.didTimeOut = true
        let waiters = current.waiters
        current.waiters = []
        pending[key] = current
        lock.unlock()
        waiters.forEach { $0.resume(returning: .unavailable) }
    }

    private func complete(key: String, result: DiskCapacityState) {
        lock.lock()
        guard let current = pending.removeValue(forKey: key) else { lock.unlock(); return }
        let waiters = current.waiters
        lock.unlock()
        waiters.forEach { $0.resume(returning: current.didTimeOut ? .unavailable : result) }
    }

    private static func readSystemCapacity(at url: URL) -> (total: Int64, free: Int64)? {
        #if canImport(Darwin)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        // As StatusBarView does, so the two agree.
        guard let free = VolumeFreeSpace.bytes(importantUsage: values.volumeAvailableCapacityForImportantUsage,
                                               available: values.volumeAvailableCapacity) else { return nil }
        return (Int64(total), free)
        #else
        return nil
        #endif
    }
}
