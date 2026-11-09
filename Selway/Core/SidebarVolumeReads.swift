import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - The mount table

/// A file system in the kernel's mount table, as `getfsstat(MNT_NOWAIT)`
/// lists it. That asks no file system anything, so a server that has stopped
/// answering can't hold it up, unlike `mountedVolumeURLs`, which reads each
/// volume's details as it lists them.
struct MountTableEntry: Hashable, Sendable {
    /// Where it's mounted ("/Volumes/USB"), as a folder URL.
    let url: URL
    /// `MNT_LOCAL`: a disk, not a server's share.
    let isLocal: Bool
    /// Not mounted `nobrowse` (`MNT_DONTBROWSE`): the system volumes, autofs
    /// maps and the like are, and `.skipHiddenVolumes` leaves them out.
    let isBrowsable: Bool
    /// `f_fstypename`: "apfs", "smbfs", "nfs", "autofs"…
    let fileSystemType: String
    /// `f_mntfromname`, what's mounted: "/dev/disk4s1",
    /// "//user@host/share", "host:/export".
    let mountedFrom: String
    /// `f_fsid`: tells this mount from another mounted at the same path
    /// before or after it.
    let fileSystemID: UInt64

    /// ShellPath.key of the mount point.
    var key: String { ShellPath.key(url) }

    /// The server a share was mounted from, read from the table alone
    /// (`ServerAddress(mountedFrom:fileSystemType:)`); nil for a disk.
    var server: ServerAddress? {
        isLocal ? nil : ServerAddress(mountedFrom: mountedFrom, fileSystemType: fileSystemType)
    }

    init(path: String, isLocal: Bool, isBrowsable: Bool = true, fileSystemType: String = "",
         mountedFrom: String = "", fileSystemID: UInt64 = 0) {
        url = URL(fileURLWithPath: path, isDirectory: true)
        self.isLocal = isLocal
        self.isBrowsable = isBrowsable
        self.fileSystemType = fileSystemType
        self.mountedFrom = mountedFrom
        self.fileSystemID = fileSystemID
    }

    /// The mounts in the table, in its order. Empty off Darwin (Linux, where
    /// the tests give their own).
    static func current() -> [MountTableEntry] {
        #if canImport(Darwin)
        // Room for a few mounted between the count and the read.
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var buffer = Array(repeating: statfs(), count: Int(count) + 8)
        let read = buffer.withUnsafeMutableBufferPointer { buf in
            getfsstat(buf.baseAddress, Int32(buf.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard read > 0 else { return [] }
        return buffer.prefix(Int(read)).map { info in
            var info = info
            func string<T>(_ field: inout T) -> String {
                withUnsafeBytes(of: &field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
            let id = UInt64(UInt32(bitPattern: info.f_fsid.val.0)) << 32 | UInt64(UInt32(bitPattern: info.f_fsid.val.1))
            return MountTableEntry(path: string(&info.f_mntonname),
                                   isLocal: info.f_flags & UInt32(MNT_LOCAL) != 0,
                                   isBrowsable: info.f_flags & UInt32(MNT_DONTBROWSE) == 0,
                                   fileSystemType: string(&info.f_fstypename),
                                   mountedFrom: string(&info.f_mntfromname),
                                   fileSystemID: id)
        }
        #else
        return []
        #endif
    }

    /// The mounts Locations reads: browsable ones, not autofs (a direct map
    /// mounted without `nobrowse` would be looked up, so mounted, by reading
    /// it), and one per mount point: of mounts stacked at one path, the last,
    /// which is the one on top.
    static func shown(_ table: [MountTableEntry]) -> [MountTableEntry] {
        var seen = Set<String>()
        let topmost = table.reversed().filter { mount in
            mount.isBrowsable && mount.fileSystemType.lowercased() != "autofs" && seen.insert(mount.key).inserted
        }
        return topmost.reversed()
    }

    /// Every network mount point, including ones Locations doesn't show:
    /// hidden and `nobrowse` mounts, autofs maps, and NFS home mounts. This
    /// only filters mount records; it doesn't ask any mounted file system.
    static func networkMountPoints(_ table: [MountTableEntry]) -> Set<String> {
        Set(table.lazy.filter { !$0.isLocal }.map(\.key))
    }
}

extension ServerAddress {
    /// The address a share was mounted from, as the mount table names it
    /// (`f_mntfromname`), for a share that hasn't said its remount URL yet:
    /// SMB's "//user@host/share" (a guest's "//GUEST:@host/share"), NFS's
    /// "host:/export", WebDAV's and FTP's URL. Parsed as an address typed
    /// is, so any password in it is dropped. Nil for an SMB share mounted
    /// with a password in its name: the table doesn't escape one, so a "/"
    /// in it would pass for the start of the share's path, and the rest of
    /// the password for its host. Nil for anything else too (AFP names its
    /// mounts otherwise).
    init?(mountedFrom from: String, fileSystemType type: String) {
        let text: String
        switch type.lowercased() {
        case "smbfs":
            guard from.hasPrefix("//") else { return nil }
            // The user's part runs up to the last "@" (the host's name has
            // none); a ":" in it starts a password, bar a guest's empty one.
            let rest = from.dropFirst(2)
            if let at = rest.lastIndex(of: "@") {
                let user = rest[..<at]
                guard !user.contains(":") || user == "GUEST:" else { return nil }
            }
            text = "smb:" + from
        case "nfs":
            // The host is up to the first ":/" (an IPv6 one has no "/").
            guard let separator = from.range(of: ":/") else { return nil }
            var host = String(from[..<separator.lowerBound])
            guard !host.isEmpty, !host.contains("/"),
                  let path = String(from[from.index(after: separator.lowerBound)...])
                    .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
            if host.contains(":") && !host.hasPrefix("[") { host = "[" + host + "]" }
            text = "nfs://" + host + path
        case "webdav", "ftp":
            guard from.contains("://") else { return nil }
            text = from
        default:
            return nil
        }
        guard case .success(let parsed) = Self.parse(text) else { return nil }
        self = parsed.address
    }
}

// MARK: - Reading the volumes

/// Reads the mounted volumes for the sidebar's Locations so that a server
/// that has stopped answering holds nothing else up. Reading a share's
/// details asks its server, which for one that has gone away can take
/// minutes; on one serial queue that held up every later read, so a USB
/// stick plugged in meanwhile didn't appear.
///
/// Each read:
/// - takes the mounts from the mount table (`MountTableEntry.current`, which
///   asks no file system), those `MountTableEntry.shown` keeps;
/// - reads ordinary disks together and starts a read of each server share
///   and disk image on a thread of its own;
/// - reuses a read for a mount that hasn't answered yet: a mount that has
///   stopped answering has one read waiting on it, never a pile of them;
/// - waits up to `grace` for the reads it started, so mounts that answer
///   at once are in the first list published, without a placeholder first;
/// - publishes the disks and the shares: each isolated mount as it last
///   answered, or its `placeholder` until it does. A mount is still mounted while
///   table lists it, so it stays listed (and can be ejected) whatever its
///   reads do: one that fails keeps its last answer or its placeholder, and
///   is read again after a while (`retryDelay`).
///
/// A read that answers later publishes again, unless that mount has
/// been unmounted meanwhile, or another mounted at its path (the table's
/// `fileSystemID` tells them apart): that one gets reads of its own. Reads
/// asked for while one is waiting to start are the same read. `Volume` is
/// whatever the app reads for a volume (its row and icon); the tests use
/// their own.
///
/// For the Swift 6 language mode, the hooks and
/// `deliver` would need to be `@Sendable` (the state is guarded by
/// `condition`, hence `@unchecked`), and `publish` `@MainActor`.
final class SidebarVolumeReader<Volume>: @unchecked Sendable {
    /// What the reader asks of the system; the tests give fakes.
    struct Hooks {
        /// The mount table, in its order (`MountTableEntry.current`).
        var mountTable: () -> [MountTableEntry]
        /// Which of the local mounts given (all of them, each read) are disk
        /// images, by key, told from the mount table alone.
        var diskImages: ([MountTableEntry]) -> Set<String> = { _ in [] }
        /// Reads ordinary disks together; entries it can't read are left out.
        var readDisks: ([MountTableEntry]) -> [(MountTableEntry, Volume)]
        /// Reads one server share or disk image; nil when it can't be read. May take minutes.
        var readMount: (MountTableEntry) -> Volume?
        /// Stands for a share or disk image that hasn't answered yet, read from nothing but
        /// the mount table.
        var placeholder: (MountTableEntry) -> Volume
        /// Runs a mount's read on a thread of its own. Not a dispatch queue:
        /// a read stuck in the kernel would hold one of its few threads.
        var startMountRead: (@escaping () -> Void) -> Void = { read in
            let thread = Thread(block: read)
            thread.name = "studio.irq.selway.mount-read"
            thread.qualityOfService = .utility
            thread.start()
        }
        /// Runs the work after the delay given (a failed mount read again).
        var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// How long a read waits for the shares it asked before publishing.
    let grace: TimeInterval
    private let hooks: Hooks
    /// Hands a list to `publish`'s caller (the main queue in the app). Lists
    /// arrive in the order they were made; one made before a list already
    /// handed over is dropped.
    private let deliver: (@escaping () -> Void) -> Void
    private let publish: ([Volume]) -> Void
    private let queue = DispatchQueue(label: "studio.irq.selway.volume-reads", qos: .userInitiated)

    /// A server share or disk image mounted now, by mount point (`MountTableEntry.key`).
    private struct Share {
        /// The mount this is about: a share mounted again at the same path
        /// is another one.
        let mount: MountTableEntry
        /// Its last answer.
        var volume: Volume?
        var isReading = false
        /// Reads that have failed since it last answered.
        var failures = 0
        /// Whether a retry is waiting for its time: a share has one at most,
        /// however many of its reads fail meanwhile.
        var retryPending = false
    }

    /// Guards everything below; reads that answer signal it.
    private let condition = NSCondition()
    /// What the last read found: the mounts shown, and the disks read.
    private var mounts: [MountTableEntry] = []
    private var disks: [(MountTableEntry, Volume)] = []
    private var diskImages: Set<String> = []
    private var shares: [String: Share] = [:]
    /// The shares a read is waiting on, during its `grace`.
    private var awaited: Set<String> = []
    /// Share reads started that haven't answered, for any mount.
    private var running = 0
    private var queued = false
    private var made = 0
    private var delivered = 0

    init(hooks: Hooks, grace: TimeInterval = 0.5,
         deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         publish: @escaping ([Volume]) -> Void) {
        self.hooks = hooks
        self.grace = grace
        self.deliver = deliver
        self.publish = publish
    }

    /// How long after its `failures`-th failed read in a row a share is read
    /// again: 30 s, doubling each time, at most 10 minutes.
    static func retryDelay(failures: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(failures, 1) - 1)), 600)
    }

    /// Reads the volumes again in the background. One asked for while another
    /// is waiting to start is the same read.
    func refresh() {
        condition.lock()
        defer { condition.unlock() }
        guard !queued else { return }
        queued = true
        queue.async { [self] in
            condition.lock()
            queued = false
            condition.unlock()
            read()
        }
    }

    /// Whether a read of the mount at `mountPoint` (ShellPath.key) is waiting
    /// for an answer.
    func isReading(_ mountPoint: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return shares[mountPoint]?.isReading ?? false
    }

    /// Mount reads started that haven't answered yet, for mounts still
    /// mounted or not.
    var sharesBeingRead: Int {
        condition.lock()
        defer { condition.unlock() }
        return running
    }

    private func read() {
        let table = MountTableEntry.shown(hooks.mountTable())
        let images = hooks.diskImages(table.filter(\.isLocal))
        let readDisks = hooks.readDisks(table.filter { $0.isLocal && !images.contains($0.key) })

        condition.lock()
        mounts = table
        disks = readDisks
        diskImages = images
        var now: [String: Share] = [:]
        var started: [MountTableEntry] = []
        for mount in table where !mount.isLocal || images.contains(mount.key) {
            // A mount unmounted, or another mounted in its place, is
            // forgotten: the one there now is read afresh.
            var share = shares[mount.key].flatMap { $0.mount == mount ? $0 : nil } ?? Share(mount: mount)
            if !share.isReading {
                share.isReading = true
                started.append(mount)
            }
            now[mount.key] = share
        }
        shares = now
        running += started.count
        awaited = Set(started.map(\.key))
        condition.unlock()

        for mount in started { startRead(mount) }

        condition.lock()
        let deadline = Date(timeIntervalSinceNow: grace)
        while awaited.contains(where: { shares[$0]?.isReading == true }), condition.wait(until: deadline) {}
        awaited = []
        let list = madeList()
        condition.unlock()
        list()
    }

    private func startRead(_ mount: MountTableEntry) {
        hooks.startMountRead { [self] in answered(mount, hooks.readMount(mount)) }
    }

    private func answered(_ mount: MountTableEntry, _ volume: Volume?) {
        condition.lock()
        running -= 1
        // Unmounted meanwhile, or another mount mounted at its path: dropped.
        guard var share = shares[mount.key], share.mount == mount else {
            condition.broadcast()
            condition.unlock()
            return
        }
        share.isReading = false
        if let volume {
            share.volume = volume
            share.failures = 0
        } else {
            share.failures += 1
        }
        shares[mount.key] = share
        let waitedFor = awaited.contains(mount.key)
        condition.broadcast()
        // The read waiting on it publishes it.
        let list = waitedFor ? nil : madeList()
        // Any read can fail, the ones a refresh starts too: a retry already
        // waiting reads it again, so a share's retries never pile up.
        let retry = volume == nil && !share.retryPending
        if retry { shares[mount.key]?.retryPending = true }
        let failures = share.failures
        condition.unlock()
        list?()
        if retry {
            hooks.after(Self.retryDelay(failures: failures)) { [weak self] in self?.readAgain(mount) }
        }
    }

    /// A mount whose read failed, read again if it's still mounted, hasn't
    /// answered since, and isn't being read already.
    ///
    /// Only the table says it's still mounted: a share unmounted without
    /// the app being told stays in `shares` until the next refresh, and a
    /// read of its mount point then would read the directory left there, on
    /// the startup disk, and list that as the share.
    private func readAgain(_ mount: MountTableEntry) {
        condition.lock()
        guard var share = shares[mount.key], share.mount == mount else {
            condition.unlock()
            return
        }
        share.retryPending = false
        shares[mount.key] = share
        let wanted = !share.isReading && share.failures > 0
        condition.unlock()
        guard wanted else { return }

        let mounted = MountTableEntry.shown(hooks.mountTable()).contains {
            $0.key == mount.key && $0.fileSystemID == mount.fileSystemID
        }

        condition.lock()
        // Checked again: a refresh may have read it, or dropped it, meanwhile.
        guard var now = shares[mount.key], now.mount == mount, !now.isReading, now.failures > 0 else {
            condition.unlock()
            return
        }
        guard mounted else {
            shares[mount.key] = nil
            mounts.removeAll { $0 == mount }
            let list = madeList()
            condition.unlock()
            list()
            return
        }
        now.isReading = true
        shares[mount.key] = now
        running += 1
        condition.unlock()
        startRead(mount)
    }

    /// The list as it stands, numbered, and the work that hands it over.
    /// Called with the lock held; the work runs after it's released.
    private func madeList() -> () -> Void {
        // The disks first, disk images among them, then the shares, each in
        // the table's order.
        var volumes: [Volume] = []
        let byKey = Dictionary(disks.map { ($0.0.key, $0.1) }, uniquingKeysWith: { first, _ in first })
        for mount in mounts.filter(\.isLocal) + mounts.filter({ !$0.isLocal }) {
            if mount.isLocal && !diskImages.contains(mount.key) {
                if let disk = byKey[mount.key] { volumes.append(disk) }
            } else {
                volumes.append(shares[mount.key]?.volume ?? hooks.placeholder(mount))
            }
        }
        made += 1
        let number = made
        return { [self] in
            deliver { [self] in
                condition.lock()
                let isNewest = number > delivered
                if isNewest { delivered = number }
                condition.unlock()
                if isNewest { publish(volumes) }
            }
        }
    }
}
