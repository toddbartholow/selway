import Foundation
import Testing
@testable import SelwayCore

/// SidebarVolumeReader with a made-up mount table and shares that answer, or
/// don't, when a test says so. Nothing here reads a real volume.
@Suite(.serialized) struct SidebarVolumeReadsTests {
    /// The fakes the reader is given, and what it published.
    final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var table: [MountTableEntry]
        /// Reads that wait until `answer` lets them go, by `World.name`.
        private var gates: [String: DispatchSemaphore] = [:]
        /// Shares whose reads fail, by `World.name`.
        private var failing: Set<String> = []
        private var shareReads: [String: Int] = [:]
        private var disksRead: [[String]] = []
        private var tableReads = 0
        private var retries: [() -> Void] = []
        private var retryDelays: [TimeInterval] = []
        private(set) var lists: [[String]] = []
        private let published = DispatchSemaphore(value: 0)

        init(_ table: [MountTableEntry]) { self.table = table }

        /// A mount's name in the fakes: its path, and its file system ID
        /// when it isn't 0 (another share mounted at the same path).
        static func name(_ mount: MountTableEntry) -> String {
            mount.fileSystemID == 0 ? mount.key : "\(mount.key)@\(mount.fileSystemID)"
        }

        func setTable(_ entries: [MountTableEntry]) { locked { table = entries } }
        func hang(_ name: String) { locked { gates[name] = DispatchSemaphore(value: 0) } }
        func fail(_ name: String, _ failing: Bool = true) {
            locked {
                if failing { self.failing.insert(name) } else { self.failing.remove(name) }
            }
        }

        /// Lets the hung read of `name` answer.
        func answer(_ name: String) { locked { gates.removeValue(forKey: name) }?.signal() }

        /// Lets every hung read go, so no test leaves a thread waiting.
        func answerAll() {
            for gate in locked({ Array(gates.values) }) { gate.signal() }
            locked { gates = [:] }
        }

        func reads(of name: String) -> Int { locked { shareReads[name, default: 0] } }
        var disksGiven: [[String]] { locked { disksRead } }
        var mountTableReads: Int { locked { tableReads } }
        var delays: [TimeInterval] { locked { retryDelays } }
        var last: [String]? { locked { lists.last } }
        var all: [[String]] { locked { lists } }

        /// Runs the retries asked for so far, as if their time had come.
        func runRetries() {
            let due = locked { () -> [() -> Void] in
                defer { retries = [] }
                return retries
            }
            due.forEach { $0() }
        }

        var hooks: SidebarVolumeReader<String>.Hooks {
            SidebarVolumeReader<String>.Hooks(
                mountTable: { [self] in
                    locked {
                        tableReads += 1
                        return table
                    }
                },
                diskImages: { Set($0.filter { $0.mountedFrom == "disk-image" }.map(\.key)) },
                readDisks: { [self] disks in
                    let paths = disks.map(\.key)
                    locked { disksRead.append(paths) }
                    return disks.map { ($0, "disk:" + $0.key) }
                },
                readMount: { [self] share in
                    let name = World.name(share)
                    let gate: DispatchSemaphore? = locked {
                        shareReads[name, default: 0] += 1
                        return gates[name]
                    }
                    gate?.wait()
                    return locked { failing.contains(name) } ? nil : "share:" + name
                },
                placeholder: { "waiting:" + World.name($0) },
                after: { [self] delay, work in
                    locked {
                        retryDelays.append(delay)
                        retries.append(work)
                    }
                })
        }

        func reader(grace: TimeInterval = 0.05,
                    deliver: @escaping (@escaping () -> Void) -> Void = { $0() }) -> SidebarVolumeReader<String> {
            SidebarVolumeReader(hooks: hooks, grace: grace, deliver: deliver) { [self] list in
                locked { lists.append(list) }
                published.signal()
            }
        }

        /// Waits for a list `matching`, among those published after the
        /// first `skipping`.
        @discardableResult
        func waitFor(skipping: Int = 0, _ matching: ([String]) -> Bool) -> [String]? {
            let deadline = Date(timeIntervalSinceNow: 5)
            while true {
                if let found = locked({ lists }).dropFirst(skipping).last(where: matching) { return found }
                guard published.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success
                else { return nil }
            }
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private static let root  = MountTableEntry(path: "/", isLocal: true)
    private static let usb   = MountTableEntry(path: "/Volumes/USB", isLocal: true)
    private static let stick = MountTableEntry(path: "/Volumes/STICK", isLocal: true)
    private static let share = MountTableEntry(path: "/Volumes/Documents", isLocal: false)
    private static let other = MountTableEntry(path: "/Volumes/Media", isLocal: false)
    private static let image = MountTableEntry(path: "/Volumes/Image", isLocal: true, mountedFrom: "disk-image")

    /// Waits up to 5 s for `condition`.
    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 5)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    @Test func theDisksArePublishedWhileAShareHangs() throws {
        let world = World([Self.root, Self.usb, Self.share])
        world.hang("/Volumes/Documents")
        defer { world.answerAll() }
        let reader = world.reader()
        reader.refresh()
        let list = try #require(world.waitFor { $0.contains("disk:/Volumes/USB") })
        #expect(list == ["disk:/", "disk:/Volumes/USB", "waiting:/Volumes/Documents"])
    }

    /// The bug: one share that stopped answering held up every later read,
    /// so a USB stick plugged in meanwhile didn't appear.
    @Test func aDiskMountedWhileAShareHangsAppears() throws {
        let world = World([Self.root, Self.share])
        world.hang("/Volumes/Documents")
        defer { world.answerAll() }
        let reader = world.reader()
        reader.refresh()
        try #require(world.waitFor { $0.contains("waiting:/Volumes/Documents") } != nil)
        waitUntil { world.reads(of: "/Volumes/Documents") == 1 }

        world.setTable([Self.root, Self.share, Self.stick])
        reader.refresh()
        let list = try #require(world.waitFor { $0.contains("disk:/Volumes/STICK") })
        #expect(list.contains("waiting:/Volumes/Documents"))
        // One read waits on the share, however often the volumes are read.
        reader.refresh()
        waitUntil { world.disksGiven.count == 3 }
        try #require(world.waitFor(skipping: 2) { _ in true } != nil)
        #expect(world.reads(of: "/Volumes/Documents") == 1)
        #expect(reader.isReading("/Volumes/Documents"))
    }

    @Test func aShareThatAnswersLateIsPublished() throws {
        let world = World([Self.root, Self.share])
        world.hang("/Volumes/Documents")
        defer { world.answerAll() }
        let reader = world.reader()
        reader.refresh()
        try #require(world.waitFor { $0.contains("waiting:/Volumes/Documents") } != nil)

        world.answer("/Volumes/Documents")
        let list = try #require(world.waitFor { $0.contains("share:/Volumes/Documents") })
        #expect(list == ["disk:/", "share:/Volumes/Documents"])
    }

    @Test func aDiskImageThatNeverAnswersDoesNotHoldUpDisksOrRefreshes() throws {
        let world = World([Self.root, Self.image, Self.usb])
        world.hang("/Volumes/Image")
        defer { world.answerAll() }
        let reader = world.reader()
        reader.refresh()
        let list = try #require(world.waitFor { $0.contains("disk:/Volumes/USB") })
        #expect(list == ["disk:/", "waiting:/Volumes/Image", "disk:/Volumes/USB"])
        #expect(world.disksGiven == [["/", "/Volumes/USB"]])

        world.setTable([Self.root, Self.image, Self.usb, Self.stick])
        reader.refresh()
        let next = try #require(world.waitFor(skipping: 1) { $0.contains("disk:/Volumes/STICK") })
        #expect(next == ["disk:/", "waiting:/Volumes/Image", "disk:/Volumes/USB", "disk:/Volumes/STICK"])
    }

    @Test func aDiskImageAnswerReplacesItsPlaceholderAndUnmountedImageIsDropped() throws {
        let world = World([Self.root, Self.image, Self.usb])
        world.hang("/Volumes/Image")
        defer { world.answerAll() }
        let reader = world.reader()
        reader.refresh()
        try #require(world.waitFor { $0.contains("waiting:/Volumes/Image") } != nil)
        world.answer("/Volumes/Image")
        let answered = try #require(world.waitFor { $0.contains("share:/Volumes/Image") })
        #expect(answered == ["disk:/", "share:/Volumes/Image", "disk:/Volumes/USB"])

        world.hang("/Volumes/Image")
        world.setTable([Self.root, Self.image, Self.usb])
        reader.refresh()
        waitUntil { reader.isReading("/Volumes/Image") }
        world.setTable([Self.root, Self.usb])
        reader.refresh()
        let dropped = try #require(world.waitFor { $0 == ["disk:/", "disk:/Volumes/USB"] })
        #expect(dropped == ["disk:/", "disk:/Volumes/USB"])
    }

    /// A share that answers within the grace period is in the first list,
    /// with no placeholder shown first.
    @Test func aShareThatAnswersAtOnceHasNoPlaceholder() throws {
        let world = World([Self.root, Self.share])
        let reader = world.reader(grace: 5)
        reader.refresh()
        let list = try #require(world.waitFor { !$0.isEmpty })
        #expect(list == ["disk:/", "share:/Volumes/Documents"])
        #expect(world.all.count == 1)
    }

    /// A share that answered before and is slow now keeps its last answer
    /// rather than going back to a placeholder.
    @Test func aShareKeepsItsLastAnswerWhileItIsReadAgain() throws {
        let world = World([Self.root, Self.share])
        let reader = world.reader()
        reader.refresh()
        try #require(world.waitFor { $0.contains("share:/Volumes/Documents") } != nil)

        world.hang("/Volumes/Documents")
        defer { world.answerAll() }
        world.setTable([Self.root, Self.share, Self.usb])
        waitUntil { !reader.isReading("/Volumes/Documents") }
        reader.refresh()
        let list = try #require(world.waitFor { $0.contains("disk:/Volumes/USB") })
        #expect(list == ["disk:/", "disk:/Volumes/USB", "share:/Volumes/Documents"])
        #expect(world.reads(of: "/Volumes/Documents") == 2)
    }

    /// One share hanging doesn't hold up another share's answer.
    @Test func eachShareIsReadOnItsOwn() throws {
        let world = World([Self.root, Self.share, Self.other])
        world.hang("/Volumes/Documents")
        defer { world.answerAll() }
        let reader = world.reader()
        reader.refresh()
        let list = try #require(world.waitFor { $0.contains("share:/Volumes/Media") })
        #expect(list == ["disk:/", "waiting:/Volumes/Documents", "share:/Volumes/Media"])
    }

    @Test func aShareUnmountedBeforeItAnswersIsNotListed() throws {
        let world = World([Self.root, Self.share])
        world.hang("/Volumes/Documents")
        defer { world.answerAll() }
        let reader = world.reader()
        reader.refresh()
        try #require(world.waitFor { $0.contains("waiting:/Volumes/Documents") } != nil)

        world.setTable([Self.root])
        reader.refresh()
        try #require(world.waitFor { $0 == ["disk:/"] } != nil)
        let published = world.all.count
        world.answer("/Volumes/Documents")
        waitUntil { reader.sharesBeingRead == 0 }
        #expect(reader.sharesBeingRead == 0)
        #expect(world.all.count == published)
        #expect(world.last == ["disk:/"])
    }

    /// Mounted again after that, it's read afresh.
    @Test func aShareMountedAgainIsReadAgain() throws {
        let world = World([Self.root, Self.share])
        let reader = world.reader()
        reader.refresh()
        try #require(world.waitFor { $0.contains("share:/Volumes/Documents") } != nil)
        world.setTable([Self.root])
        reader.refresh()
        try #require(world.waitFor { $0 == ["disk:/"] } != nil)

        world.hang("/Volumes/Documents")
        defer { world.answerAll() }
        world.setTable([Self.root, Self.share])
        let before = world.all.count
        reader.refresh()
        let list = try #require(world.waitFor(skipping: before) { $0.count == 2 })
        #expect(list == ["disk:/", "waiting:/Volumes/Documents"])
    }

    /// Another share mounted at the same path while the first one's read
    /// hangs: it gets a read of its own, and the first one's answer, when it
    /// comes, isn't taken for it.
    @Test func anAnswerForTheShareMountedBeforeIsIgnored() throws {
        let first = MountTableEntry(path: "/Volumes/Documents", isLocal: false, fileSystemID: 1)
        let second = MountTableEntry(path: "/Volumes/Documents", isLocal: false, fileSystemID: 2)
        let world = World([Self.root, first])
        world.hang("/Volumes/Documents@1")
        world.hang("/Volumes/Documents@2")
        defer { world.answerAll() }
        let reader = world.reader()
        reader.refresh()
        try #require(world.waitFor { $0.contains("waiting:/Volumes/Documents@1") } != nil)

        world.setTable([Self.root, second])
        reader.refresh()
        try #require(world.waitFor { $0.contains("waiting:/Volumes/Documents@2") } != nil)
        waitUntil { world.reads(of: "/Volumes/Documents@2") == 1 }
        #expect(world.reads(of: "/Volumes/Documents@2") == 1)

        let published = world.all.count
        world.answer("/Volumes/Documents@1")
        waitUntil { reader.sharesBeingRead == 1 }
        #expect(world.all.count == published)
        world.answer("/Volumes/Documents@2")
        let list = try #require(world.waitFor { $0.contains("share:/Volumes/Documents@2") })
        #expect(list == ["disk:/", "share:/Volumes/Documents@2"])
    }

    /// A share whose read fails is still mounted: it stays listed (and can be
    /// ejected), and is read again after a while.
    @Test func aShareWhoseReadFailsStaysAndIsReadAgain() throws {
        let world = World([Self.root, Self.share])
        world.fail("/Volumes/Documents")
        let reader = world.reader(grace: 5)
        reader.refresh()
        let list = try #require(world.waitFor { !$0.isEmpty })
        #expect(list == ["disk:/", "waiting:/Volumes/Documents"])
        waitUntil { world.delays.count == 1 }
        #expect(world.delays == [SidebarVolumeReader<String>.retryDelay(failures: 1)])

        world.fail("/Volumes/Documents", false)
        world.runRetries()
        let answered = try #require(world.waitFor { $0.contains("share:/Volumes/Documents") })
        #expect(answered == ["disk:/", "share:/Volumes/Documents"])
        #expect(world.reads(of: "/Volumes/Documents") == 2)
    }

    /// Once it has answered, a failed read keeps the last answer.
    @Test func aFailedReadKeepsTheLastAnswer() throws {
        let world = World([Self.root, Self.share])
        let reader = world.reader(grace: 5)
        reader.refresh()
        try #require(world.waitFor { $0.contains("share:/Volumes/Documents") } != nil)
        world.fail("/Volumes/Documents")
        reader.refresh()
        waitUntil { world.delays.count == 1 }
        #expect(world.last == ["disk:/", "share:/Volumes/Documents"])
    }

    /// A share unmounted before its retry is due isn't read again.
    @Test func aRetryForAShareGoneIsDropped() throws {
        let world = World([Self.root, Self.share])
        world.fail("/Volumes/Documents")
        let reader = world.reader(grace: 5)
        reader.refresh()
        try #require(world.waitFor { !$0.isEmpty } != nil)
        waitUntil { world.delays.count == 1 }
        world.setTable([Self.root])
        reader.refresh()
        try #require(world.waitFor { $0 == ["disk:/"] } != nil)
        world.runRetries()
        #expect(world.reads(of: "/Volumes/Documents") == 1)
    }

    /// Reads a refresh starts can fail too: a share that fails at once,
    /// refreshed again and again, still has one retry waiting, not one more
    /// for each refresh.
    @Test func aShareHasOneRetryAtATime() throws {
        let world = World([Self.root, Self.share])
        world.fail("/Volumes/Documents")
        let reader = world.reader(grace: 5)
        reader.refresh()
        try #require(world.waitFor { !$0.isEmpty } != nil)
        waitUntil { world.delays.count == 1 }
        reader.refresh()
        waitUntil { world.reads(of: "/Volumes/Documents") == 2 && reader.sharesBeingRead == 0 }
        try #require(world.reads(of: "/Volumes/Documents") == 2)
        #expect(world.delays.count == 1)

        for round in 1...2 {
            world.runRetries()
            waitUntil { world.reads(of: "/Volumes/Documents") == 2 + round && reader.sharesBeingRead == 0 }
            waitUntil { world.delays.count == 1 + round }
            #expect(world.reads(of: "/Volumes/Documents") == 2 + round)
            #expect(world.delays.count == 1 + round)
        }
        let retry = SidebarVolumeReader<String>.retryDelay
        #expect(world.delays == [retry(1), retry(3), retry(4)])
    }

    /// A share that has answered since its read failed isn't read again.
    @Test func aRetryForAShareThatHasAnsweredIsDropped() throws {
        let world = World([Self.root, Self.share])
        world.fail("/Volumes/Documents")
        let reader = world.reader(grace: 5)
        reader.refresh()
        try #require(world.waitFor { !$0.isEmpty } != nil)
        waitUntil { world.delays.count == 1 }
        world.fail("/Volumes/Documents", false)
        reader.refresh()
        try #require(world.waitFor { $0.contains("share:/Volumes/Documents") } != nil)
        world.runRetries()
        #expect(world.reads(of: "/Volumes/Documents") == 2)
        #expect(world.delays.count == 1)
    }

    /// A share unmounted without the app being told (no refresh) isn't read
    /// again: its mount point is a bare directory on the startup disk now.
    /// The retry finds it gone from the table and drops it.
    @Test func aRetryChecksTheShareIsStillMounted() throws {
        let world = World([Self.root, Self.share])
        world.fail("/Volumes/Documents")
        let reader = world.reader(grace: 5)
        reader.refresh()
        try #require(world.waitFor { !$0.isEmpty } != nil)
        waitUntil { world.delays.count == 1 }
        let tableReads = world.mountTableReads
        world.setTable([Self.root])
        world.runRetries()
        let list = try #require(world.waitFor { $0 == ["disk:/"] })
        #expect(list == ["disk:/"])
        #expect(world.mountTableReads == tableReads + 1)
        #expect(world.reads(of: "/Volumes/Documents") == 1)
        #expect(!reader.isReading("/Volumes/Documents"))
        #expect(world.delays.count == 1)
    }

    /// Nor is one with another share mounted at its path meanwhile: that one
    /// is the next refresh's to read.
    @Test func aRetryChecksTheShareIsTheSameOne() throws {
        let before = MountTableEntry(path: "/Volumes/Documents", isLocal: false, fileSystemID: 1)
        let after = MountTableEntry(path: "/Volumes/Documents", isLocal: false, fileSystemID: 2)
        let world = World([Self.root, before])
        world.fail("/Volumes/Documents@1")
        let reader = world.reader(grace: 5)
        reader.refresh()
        try #require(world.waitFor { !$0.isEmpty } != nil)
        waitUntil { world.delays.count == 1 }
        world.setTable([Self.root, after])
        world.runRetries()
        try #require(world.waitFor { $0 == ["disk:/"] } != nil)
        #expect(world.reads(of: "/Volumes/Documents@1") == 1)
        #expect(world.reads(of: "/Volumes/Documents@2") == 0)

        reader.refresh()
        let list = try #require(world.waitFor { $0.contains("share:/Volumes/Documents@2") })
        #expect(list == ["disk:/", "share:/Volumes/Documents@2"])
    }

    @Test func retriesBackOff() {
        let delay = SidebarVolumeReader<String>.retryDelay
        #expect(delay(1) == 30)
        #expect(delay(2) == 60)
        #expect(delay(3) == 120)
        #expect(delay(10) == 600)
    }

    /// Volumes mounted `nobrowse` (the system's, autofs maps) and autofs
    /// mounts aren't read at all.
    @Test func hiddenAndAutofsMountsAreNotRead() throws {
        let world = World([Self.root,
                           MountTableEntry(path: "/System/Volumes/Data", isLocal: true, isBrowsable: false),
                           MountTableEntry(path: "/Volumes/Hidden", isLocal: false, isBrowsable: false),
                           MountTableEntry(path: "/Volumes/Direct", isLocal: false, fileSystemType: "autofs")])
        let reader = world.reader()
        reader.refresh()
        let list = try #require(world.waitFor { !$0.isEmpty })
        #expect(list == ["disk:/"])
        #expect(world.disksGiven == [["/"]])
        #expect(world.reads(of: "/Volumes/Hidden") == 0)
        #expect(world.reads(of: "/Volumes/Direct") == 0)
    }

    /// Link following skips every network mount, even when Locations cannot
    /// display it or its mount source doesn't map to a saved server address.
    @Test func networkMountPointsIncludeHiddenAndAutofsMounts() {
        let table = [Self.root,
                     MountTableEntry(path: "/Volumes/Visible", isLocal: false),
                     MountTableEntry(path: "/Volumes/Hidden", isLocal: false, isBrowsable: false),
                     MountTableEntry(path: "/net", isLocal: false, fileSystemType: "autofs"),
                     MountTableEntry(path: "/Users/home", isLocal: false, fileSystemType: "nfs"),
                     MountTableEntry(path: "/System/Volumes/Data", isLocal: true, isBrowsable: false)]

        #expect(MountTableEntry.networkMountPoints(table) == [
            "/Volumes/Visible", "/Volumes/Hidden", "/net", "/Users/home",
        ])
    }

    /// Mounts stacked at one path are one volume: the one on top, mounted last.
    @Test func stackedMountsAreReadOnce() {
        let under = MountTableEntry(path: "/Volumes/Documents", isLocal: false, mountedFrom: "//a/x", fileSystemID: 1)
        let over = MountTableEntry(path: "/Volumes/Documents/", isLocal: false, mountedFrom: "//b/y", fileSystemID: 2)
        let shown = MountTableEntry.shown([Self.root, under, Self.usb, over])
        #expect(shown == [Self.root, Self.usb, over])
    }

    /// A list made before one already handed over is dropped, so an older
    /// list can't replace a newer one.
    @Test func anOlderListNeverReplacesANewerOne() throws {
        final class Queue: @unchecked Sendable {
            let lock = NSLock()
            var work: [() -> Void] = []
        }
        let queue = Queue()
        let world = World([Self.root, Self.share])
        world.hang("/Volumes/Documents")
        defer { world.answerAll() }
        let reader = world.reader(deliver: { work in
            queue.lock.lock()
            queue.work.append(work)
            queue.lock.unlock()
        })
        reader.refresh()
        waitUntil { queue.lock.withLock { queue.work.count } == 1 }
        world.answer("/Volumes/Documents")
        waitUntil { queue.lock.withLock { queue.work.count } == 2 }
        let work = queue.lock.withLock { queue.work }
        try #require(work.count == 2)

        work.reversed().forEach { $0() }
        #expect(world.all == [["disk:/", "share:/Volumes/Documents"]])
    }

    /// Reads asked for while one is running (here held in its grace period
    /// by a share that doesn't answer) are run once after it, together.
    @Test func readsAskedForMeanwhileAreRunOnce() throws {
        let world = World([Self.root, Self.share])
        world.hang("/Volumes/Documents")
        defer { world.answerAll() }
        let reader = world.reader(grace: 1)
        reader.refresh()
        waitUntil { world.reads(of: "/Volumes/Documents") == 1 }
        #expect(world.mountTableReads == 1)
        #expect(world.all.isEmpty)

        reader.refresh()
        reader.refresh()
        reader.refresh()
        try #require(world.waitFor { _ in world.all.count == 2 } != nil)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(world.mountTableReads == 2)
        #expect(world.reads(of: "/Volumes/Documents") == 1)
    }

    // MARK: Servers from the mount table

    @Test func smbSharesGiveTheirAddressWithoutAPassword() throws {
        let guest = try #require(ServerAddress(mountedFrom: "//GUEST:@NAS._smb._tcp.local/Documents",
                                               fileSystemType: "smbfs"))
        #expect(guest.scheme == .smb)
        #expect(guest.host == "nas._smb._tcp.local")
        #expect(guest.path == "/Documents")
        #expect(guest.user == "GUEST")
        #expect(!guest.url.absoluteString.contains(":@"))

        let user = try #require(ServerAddress(mountedFrom: "//alex@nas.local/My%20Share", fileSystemType: "smbfs"))
        #expect(user.scheme == .smb)
        #expect(user.host == "nas.local")
        #expect(user.user == "alex")
        #expect(user.path == "/My Share")
    }

    /// A password in the table's name isn't escaped, so where it ends can't
    /// be told: a "/" in it would make the rest of it the host. No address
    /// at all, rather than one made of a password.
    @Test func smbSharesMountedWithAPasswordGiveNoAddress() {
        #expect(ServerAddress(mountedFrom: "//alex:secret@nas.local/My%20Share", fileSystemType: "smbfs") == nil)
        #expect(ServerAddress(mountedFrom: "//user:12/x@host/share", fileSystemType: "smbfs") == nil)
        #expect(ServerAddress(mountedFrom: "//user:a@b@host/share", fileSystemType: "smbfs") == nil)
        #expect(ServerAddress(mountedFrom: "//GUEST:x@host/share", fileSystemType: "smbfs") == nil)
    }

    /// Matched with the address the share reports once it answers: the same
    /// server and share, whoever logged in.
    @Test func anSMBShareMatchesItsRemountAddress() throws {
        let fromTable = try #require(ServerAddress(mountedFrom: "//GUEST:@NAS._smb._tcp.local/Documents",
                                                   fileSystemType: "smbfs"))
        let remount = try #require(URL(string: "smb://GUEST:@NAS._smb._tcp.local/Documents")
            .flatMap(ServerAddress.init(remountURL:)))
        #expect(fromTable.matchKey == remount.matchKey)
    }

    @Test func nfsExportsGiveTheirAddress() throws {
        let nfs = try #require(ServerAddress(mountedFrom: "192.0.2.35:/srv/nfs/Backups", fileSystemType: "nfs"))
        #expect(nfs.scheme == .nfs)
        #expect(nfs.host == "192.0.2.35")
        #expect(nfs.path == "/srv/nfs/Backups")

        let spaced = try #require(ServerAddress(mountedFrom: "nas.local:/export/My Files", fileSystemType: "nfs"))
        #expect(spaced.path == "/export/My Files")

        let v6 = try #require(ServerAddress(mountedFrom: "fe80::1:/export", fileSystemType: "nfs"))
        #expect(v6.host == "fe80::1")
        #expect(v6.path == "/export")
    }

    @Test func webDAVSharesGiveTheirAddress() throws {
        let dav = try #require(ServerAddress(mountedFrom: "https://user:pw@dav.example.com/files", fileSystemType: "webdav"))
        #expect(dav.scheme == .https)
        #expect(dav.host == "dav.example.com")
        #expect(!dav.url.absoluteString.contains("pw"))
    }

    @Test func otherMountsGiveNoAddress() {
        #expect(ServerAddress(mountedFrom: "/dev/disk4s1", fileSystemType: "apfs") == nil)
        #expect(ServerAddress(mountedFrom: "afp_0TQgyl0Pd8Ds00x0", fileSystemType: "afpfs") == nil)
        #expect(ServerAddress(mountedFrom: "map auto_home", fileSystemType: "autofs") == nil)
        #expect(ServerAddress(mountedFrom: "noslash", fileSystemType: "smbfs") == nil)
        #expect(ServerAddress(mountedFrom: "nohost", fileSystemType: "nfs") == nil)
        #expect(MountTableEntry(path: "/Volumes/X", isLocal: true, fileSystemType: "smbfs",
                                mountedFrom: "//host/share").server == nil)
        #expect(MountTableEntry(path: "/Volumes/X", isLocal: false, fileSystemType: "smbfs",
                                mountedFrom: "//host/share").server?.path == "/share")
    }

    #if canImport(Darwin)
    /// The real table (getfsstat, which asks no file system anything) has the
    /// startup disk, local and browsable, with its type and ID.
    @Test func theMountTableListsTheStartupDisk() {
        let root = MountTableEntry.current().first { $0.key == "/" }
        #expect(root?.isLocal == true)
        #expect(root?.isBrowsable == true)
        #expect(root?.fileSystemType.isEmpty == false)
        #expect(root?.fileSystemID != 0)
    }
    #endif
}
