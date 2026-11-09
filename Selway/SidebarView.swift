import SwiftUI
import AppKit
import DiskArbitration
import IOKit
import IOKit.storage
import UniformTypeIdentifiers

// SidebarItem, and the row matching / selection / Recent decisions, live in
// Core/SidebarSelection.swift; which volumes Locations lists, in
// Core/SidebarVolumes.swift.

// MARK: - Favorites service (pinned folders and mounted volumes)

/// Pinned folders, saved servers and mounted volumes for the sidebar.
/// Persistence and list edits live in `FavoritesStore` and `SavedServers`
/// (Core); this adds publishing and volume mount tracking, so pins on a
/// disconnected drive stay listed (dimmed) instead of being dropped, and
/// Locations follows drives coming and going.
class FavoritesService: ObservableObject {
    @Published var pinnedURLs: [URL] = []
    /// Servers (or folders on them) saved to the sidebar, listed under Locations.
    @Published private(set) var savedServers: [SavedServer] = []
    /// What the pinned folders' last reads found, by ShellPath.key, icons
    /// included: one asked for on the main thread would wait on a share that
    /// has stopped answering (PinnedFolderReader). None yet for a folder
    /// that hasn't answered.
    @Published private(set) var pinnedFolders: [String: PinnedFolderAnswer<NSImage>] = [:]
    /// Every mounted volume Finder would list; the sidebar picks the rows
    /// (SidebarVolumes.rows).
    @Published private(set) var volumes: [SidebarVolume] = []
    /// The volumes' icons by path (ShellPath.key), read with them: asking for
    /// one on the main thread would wait on a server that has stopped answering.
    @Published private(set) var volumeIcons: [String: NSImage] = [:]

    private let store: FavoritesStore
    private let serverStore: SavedServersStore
    private var volumeObservers: [NSObjectProtocol] = []
    /// Reading a volume's details asks its file system, which for a server
    /// that has stopped answering can take minutes: never on the main thread,
    /// and never holding up the other volumes (SidebarVolumeReader).
    private var volumeReader: SidebarVolumeReader<MountedVolume>?
    /// The same for the pinned folders.
    private var pinnedReader: PinnedFolderReader<NSImage>?

    init(store: FavoritesStore = FavoritesStore(), serverStore: SavedServersStore = SavedServersStore()) {
        self.store = store
        self.serverStore = serverStore
        pinnedReader = PinnedFolderReader(hooks: .init(read: Self.readFolderIcon)) { [weak self] answers in
            self?.pinnedFolders = answers
        }
        load()
        savedServers = serverStore.load()
        volumeReader = SidebarVolumeReader(hooks: MountedVolume.hooks) { [weak self] read in
            self?.show(read)
        }
        refreshVolumes()
        let nc = NSWorkspace.shared.notificationCenter
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                           NSWorkspace.didRenameVolumeNotification].map {
            nc.addObserver(forName: $0, object: nil, queue: .main) { [weak self] note in
                if note.name == NSWorkspace.didUnmountNotification,
                   let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    self?.moveWindows(offVolume: volume)
                }
                if note.name == NSWorkspace.didMountNotification {
                    MainActor.assumeIsolated { VolumeEjector.shared.mounted() }
                }
                self?.refreshAvailability()
                self?.refreshVolumes()
            }
        }
    }

    deinit {
        volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func load() {
        pinnedURLs = store.load()
        refreshAvailability()
    }

    func refreshAvailability() {
        pinnedReader?.refresh(pinnedURLs)
    }

    /// A pinned or Recent folder's icon, drawn on a reader's thread, not when
    /// the row draws it: a custom icon's image is read from the folder lazily,
    /// which on the main thread could wait on a share that has stopped answering.
    /// One that can't be drawn gets the generic icon: the folder's own would
    /// be read when the row draws it.
    static func readFolderIcon(_ url: URL) -> NSImage? {
        guard FavoritesStore.isAvailable(url) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        guard let pixels = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return NSWorkspace.shared.icon(for: .folder)
        }
        return NSImage(cgImage: pixels, size: NSSize(width: 32, height: 32))
    }

    /// Until its read answers, a pinned folder counts as there.
    func isAvailable(_ url: URL) -> Bool {
        if case .missing = pinnedFolders[ShellPath.key(url)] { return false }
        return true
    }

    /// A pinned folder's icon, as read; nil until it's been read, and for
    /// one the guard refused.
    func pinnedIcon(_ url: URL) -> NSImage? {
        if case .present(let icon) = pinnedFolders[ShellPath.key(url)] { return icon }
        return nil
    }

    /// A volume has gone, whoever ejected it (Selway, Finder, diskutil) or
    /// pulled it out: windows showing a folder on it go home. Afterwards, not
    /// before ejecting, so it covers all of them, and the other volumes on a
    /// disk ejected with the one clicked.
    private func moveWindows(offVolume volume: URL) {
        // MNT_NOWAIT includes network mounts that aren't sidebar rows and is
        // available from launch, before the first volume read has finished.
        // Keep the volume rows too, in case the mount table can't identify a
        // particular server mount.
        var serverPaths = MountTableEntry.networkMountPoints(MountTableEntry.current())
        // Disk images too: one on a share that has gone hangs like the share.
        serverPaths.formUnion(volumes.filter { !$0.isLocal || $0.isDiskImage }.map { ShellPath.key($0.url) })
        let servers = serverPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        MainActor.assumeIsolated {
            BrowserWindowRouter.shared.moveWindows(offVolume: volume, servers: servers)
        }
    }

    /// Reads the volumes again in the background: the disks at once, the
    /// servers' shares as they answer (SidebarVolumeReader). Only the latest
    /// list is published, and only when something changed.
    func refreshVolumes() {
        #if SELWAY_UI_TESTING
        // The stand-ins UI tests give (UITestHooks.volumes).
        if let volumes = UITestHooks.volumes {
            DispatchQueue.main.async { [weak self] in self?.show(volumes.map { MountedVolume(volume: $0) }) }
            return
        }
        #endif
        volumeReader?.refresh()
    }

    /// A new list of the volumes, on the main thread.
    private func show(_ read: [MountedVolume]) {
        let volumes = read.map(\.volume)
        var icons: [String: NSImage] = [:]
        for item in read { if let icon = item.icon { icons[ShellPath.key(item.volume.url)] = icon } }
        MainActor.assumeIsolated { VolumeEjector.shared.listed(volumes) }
        // Icons first, so the rows drawn for new volumes have theirs.
        if volumes != self.volumes || Set(icons.keys) != Set(volumeIcons.keys) {
            volumeIcons = icons
        }
        if volumes != self.volumes { self.volumes = volumes }
    }

    /// The volume's icon from the last read, or the generic one: never read
    /// from the volume here.
    func icon(for volume: SidebarVolume) -> NSImage {
        volumeIcons[ShellPath.key(volume.url)] ?? NSWorkspace.shared.icon(for: .volume)
    }

    func pin(_ url: URL) {
        guard FavoritesStore.isAvailable(url),
              let updated = FavoritesStore.pinning(url, in: pinnedURLs) else { return }
        pinnedURLs = updated
        save()
    }

    func unpin(_ url: URL) {
        pinnedURLs = FavoritesStore.unpinning(url, in: pinnedURLs)
        save()
    }

    /// List `onDelete` — removes all swiped / selected rows in one go.
    func remove(atOffsets offsets: IndexSet) {
        pinnedURLs = FavoritesStore.removing(atOffsets: offsets, from: pinnedURLs)
        save()
    }

    func isPinned(_ url: URL) -> Bool { FavoritesStore.contains(pinnedURLs, url) }

    // MARK: Saved servers

    /// Adds `server` under Locations; false when that place is saved already.
    @discardableResult
    func addServer(_ server: SavedServer) -> Bool {
        guard let updated = SavedServers.adding(server, to: savedServers) else { return false }
        savedServers = updated
        serverStore.save(savedServers)
        return true
    }

    func removeServer(id: String) {
        savedServers = SavedServers.removing(id: id, from: savedServers)
        serverStore.save(savedServers)
    }

    func setReconnectAtLaunch(_ on: Bool, id: String) {
        savedServers = SavedServers.setting(reconnectAtLaunch: on, id: id, in: savedServers)
        serverStore.save(savedServers)
    }

    func savedServer(id: String) -> SavedServer? { savedServers.first { $0.id == id } }

    /// Whether `server`'s place is saved already.
    func isSaved(_ server: SavedServer) -> Bool { savedServers.contains { $0.isSamePlace(as: server) } }

    /// Where the share `address` is mounted, from the last read of the volumes.
    func mountPoint(for address: ServerAddress) -> URL? {
        SidebarServers.mountPoint(for: address, in: volumes)
    }

    /// The saved server for `folder` on a mounted server's share (its
    /// remount address, and the folder's path on it), or nil when the folder
    /// isn't on one. Works from the last read of the volumes: nothing is read
    /// from the server.
    func serverPlace(for folder: URL, name: String? = nil) -> SavedServer? {
        let onServers = volumes.filter { $0.server != nil && ShellPath.isSameOrInside(folder, $0.url) }
        // The deepest mount point holding it (a share mounted inside another).
        guard let volume = onServers.max(by: { ShellPath.key($0.url).count < ShellPath.key($1.url).count }),
              let server = volume.server,
              let path = SavedServers.folder(folder, onVolume: volume.url) else { return nil }
        return SavedServer.make(mounting: server, folder: path, name: name ?? (path.isEmpty ? volume.name : nil))
    }

    private func save() {
        store.save(pinnedURLs)
        refreshAvailability()
    }
}

// MARK: - Reading the mounted volumes

/// A volume as read for the sidebar: its row, and its icon.
struct MountedVolume {
    var volume: SidebarVolume
    var icon: NSImage?

    private static let resourceKeys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey, .volumeIsEjectableKey,
        .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsBrowsableKey, .effectiveIconKey,
        .volumeURLForRemountingKey,
    ]

    /// How the sidebar reads the volumes: the mount table, then each
    /// volume's file system. Off the main thread (SidebarVolumeReader).
    static let hooks = SidebarVolumeReader<MountedVolume>.Hooks(
        mountTable: MountTableEntry.current,
        diskImages: DiskImageMounts.among,
        readDisks: { disks in
            let session = DASessionCreate(kCFAllocatorDefault)
            return disks.compactMap { mount in read(mount.url, session: session).map { (mount, $0) } }
        },
        readMount: { mount in
            read(mount.url, session: mount.isLocal ? DASessionCreate(kCFAllocatorDefault) : nil)
        },
        placeholder: placeholder)

    /// A volume's row and icon, read from its file system; nil when it can't
    /// be read. `session` tells disk images and discs apart (DiskArbitration).
    private static func read(_ url: URL, session: DASession?) -> MountedVolume? {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
        let isLocal = values.volumeIsLocal ?? true
        // No resource value says "disk image" or "CD"; DiskArbitration's
        // description of the device does. A server's share has no device.
        let disk = isLocal ? session.flatMap { DiskDescription(volume: url, session: $0) } : nil
        let volume = SidebarVolume(url: url,
                                   name: values.volumeLocalizedName ?? url.lastPathComponent,
                                   isRoot: values.volumeIsRootFileSystem ?? (url.path == "/"),
                                   isInternal: values.volumeIsInternal ?? false,
                                   isEjectable: values.volumeIsEjectable ?? false,
                                   isRemovable: values.volumeIsRemovable ?? false,
                                   isLocal: isLocal,
                                   isBrowsable: values.volumeIsBrowsable ?? true,
                                   isDiskImage: disk?.isDiskImage ?? false,
                                   isOpticalDisc: disk?.isOpticalDisc ?? false,
                                   wholeDisk: disk?.wholeDisk,
                                   // Without its password (a guest login's "GUEST:"), at once.
                                   server: isLocal ? nil : values.volumeURLForRemounting.flatMap(ServerAddress.init(remountURL:)))
        return MountedVolume(volume: volume, icon: values.effectiveIcon as? NSImage)
    }

    /// A share that hasn't answered yet: listed under its mount point's name,
    /// with the generic icon, so it can still be seen and ejected, and with
    /// the server it was mounted from (the mount table's), so a saved server
    /// matches it rather than offering to connect again. Nothing is read
    /// from it.
    private static func placeholder(_ mount: MountTableEntry) -> MountedVolume {
        let name = mount.url.lastPathComponent
        return MountedVolume(volume: SidebarVolume(url: mount.url, name: name.isEmpty ? mount.url.path : name,
                                                   isEjectable: mount.isLocal,
                                                   isLocal: mount.isLocal,
                                                   isDiskImage: mount.isLocal,
                                                   server: mount.server))
    }

    /// Which local mounts are disk images, read on their own
    /// (SidebarVolumeReader.Hooks.diskImages). Told from the device the
    /// mount table names, never by looking at the volume (what hangs), and
    /// remembered while mounted, so one taken for an image stays one. A
    /// device DiskArbitration can't describe counts as one: read on its own,
    /// it can't hold up the other disks. Only the volume reader's serial
    /// queue calls it.
    private enum DiskImageMounts {
        /// By mount point, device and file system ID, for the mounts in the
        /// last table: one gone is forgotten, as its device's name may come
        /// back for another disk.
        private static var known: [String: Bool] = [:]
        private static let session = DASessionCreate(kCFAllocatorDefault)

        static func among(_ mounts: [MountTableEntry]) -> Set<String> {
            var now: [String: Bool] = [:]
            for mount in mounts {
                let id = "\(mount.fileSystemID) \(mount.mountedFrom) \(mount.key)"
                now[id] = known[id] ?? classify(mount)
            }
            known = now
            return Set(mounts.filter { known["\($0.fileSystemID) \($0.mountedFrom) \($0.key)"] == true }.map(\.key))
        }

        private static func classify(_ mount: MountTableEntry) -> Bool {
            // A disk's device, or a snapshot of one ("…@/dev/disk5s1"). A local
            // mount on no disk (macFUSE, FSKit) may hang as an image can: read
            // on its own too, but for the startup disk.
            guard let range = mount.mountedFrom.range(of: "/dev/disk") else { return mount.key != "/" }
            let device = String(mount.mountedFrom[range.lowerBound...].dropFirst("/dev/".count))
            guard let session, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, device),
                  let info = DADiskCopyDescription(disk) as? [String: Any] else { return true }
            return DiskDescription.isDiskImage(info)
        }
    }

    /// What DiskArbitration says about the device a volume is on.
    private struct DiskDescription {
        let isDiskImage: Bool
        let isOpticalDisc: Bool
        /// "disk4": every volume on its physical disk is ejected along with this one.
        let wholeDisk: String?

        init?(volume: URL, session: DASession) {
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
                  let info = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
            func string(_ key: CFString) -> String? {
                (info[key as String] as? String)?.trimmingCharacters(in: .whitespaces)
            }
            isDiskImage = Self.isDiskImage(info)
            isOpticalDisc = ["IOCDMedia", "IODVDMedia", "IOBDMedia"].contains(string(kDADiskDescriptionMediaKindKey))
            // The name points into the whole disk's object: copied while it's alive.
            let deviceWholeDisk = DADiskCopyWholeDisk(disk).flatMap { whole in
                withExtendedLifetime(whole) { DADiskGetBSDName(whole).map { String(cString: $0) } }
            }
            wholeDisk = deviceWholeDisk.flatMap { Self.physicalWholeDisk(for: $0) } ?? deviceWholeDisk
        }

        /// A mounted .dmg (or .sparsebundle) is a "Disk Image" device on the
        /// "Virtual Interface"; either says so.
        static func isDiskImage(_ info: [String: Any]) -> Bool {
            func string(_ key: CFString) -> String? {
                (info[key as String] as? String)?.trimmingCharacters(in: .whitespaces)
            }
            return string(kDADiskDescriptionDeviceModelKey) == "Disk Image"
                || string(kDADiskDescriptionDeviceProtocolKey) == "Virtual Interface"
        }

        /// APFS volumes' whole disk is a synthesized container. Follow its
        /// registry chain to the whole media shared with HFS volumes.
        private static func physicalWholeDisk(for container: String) -> String? {
            guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, container) else { return nil }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            guard service != 0 else { return nil }
            var entry = service
            var chain: [SidebarVolumes.RegistryEntry] = []
            var isComposited = false
            while true {
                var classBuffer = [CChar](repeating: 0, count: Int(MemoryLayout<io_name_t>.size))
                guard IOObjectGetClass(entry, &classBuffer) == KERN_SUCCESS else {
                    IOObjectRelease(entry)
                    break
                }
                let className = String(cString: classBuffer)
                if className == "AppleAPFSContainerScheme" {
                    isComposited = IORegistryEntryCreateCFProperty(entry, "APFSComposited" as CFString,
                                                                   kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
                }
                let isMedia = className == "IOMedia"
                let isWhole = isMedia
                    && (IORegistryEntryCreateCFProperty(entry, kIOMediaWholeKey as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false)
                let bsdName = isMedia
                    ? IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString,
                                                      kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                    : nil
                chain.append(SidebarVolumes.RegistryEntry(className: className, isWhole: isWhole,
                                                           bsdName: bsdName))
                var parent: io_registry_entry_t = 0
                let hasParent = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
                IOObjectRelease(entry)
                guard hasParent else { break }
                entry = parent
            }
            return SidebarVolumes.physicalWholeDisk(container: container, chain: chain,
                                                    isComposited: isComposited)
        }
    }
}

// MARK: - Ejecting a volume

/// Eject, from a Locations row's button or menu and Selway ▸ Eject (⌘E). One
/// instance; the sidebar observes which disks are being ejected.
@MainActor
final class VolumeEjector: ObservableObject {
    static let shared = VolumeEjector()

    /// The disks being ejected (SidebarVolume.ejectKey): their rows show
    /// progress, and another click on any volume on them does nothing.
    @Published private(set) var ejecting: Set<String> = []
    /// Disks ejected whose rows are still listed: a click on one before the
    /// list catches up would otherwise report a failure.
    private var ejected: Set<String> = []
    /// The disks in the sidebar's last read of the volumes, and the volumes
    /// on each (a drive's partitions, an APFS container's volumes).
    private var listedKeys: Set<String> = []
    private var listedVolumes: [String: [URL]] = [:]

    private enum Outcome {
        case ejected
        /// Gone already (ejected some other way): nothing to say.
        case notMounted
        case failed(SidebarVolumes.EjectFailure)
    }

    func isEjecting(_ volume: SidebarVolume) -> Bool { ejecting.contains(volume.ejectKey) }

    func eject(_ volume: SidebarVolume) {
        let key = volume.ejectKey
        guard volume.canEject, !ejecting.contains(key), !ejected.contains(key) else { return }
        ejecting.insert(key)
        let url = volume.url, name = volume.name
        // The disk's other volumes eject with it, so any of them can hold it.
        let siblings = (listedVolumes[key] ?? []).filter { ShellPath.key($0) != ShellPath.key(url) }
        // Unmounting can take seconds (a disk being flushed, a slow server).
        // Windows on the volume move once it has gone (FavoritesService).
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.unmount(url, name: name, siblings: siblings)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { VolumeEjector.shared.finish(key, name: name, outcome) }
            }
        }
    }

    /// A new read of the volumes (FavoritesService): disks no longer listed
    /// can be ejected again, should they come back.
    func listed(_ volumes: [SidebarVolume]) {
        listedKeys = Set(volumes.map(\.ejectKey))
        listedVolumes = Dictionary(grouping: volumes, by: \.ejectKey).mapValues { $0.map(\.url) }
        ejected.formIntersection(listedKeys)
    }

    /// A volume has mounted: it may be a disk just ejected, put back before
    /// the reads caught up (one held up by a server that has stopped
    /// answering), which must be ejectable again. A click on a disk already
    /// gone finds it isn't mounted and says nothing.
    func mounted() {
        ejected.removeAll()
    }

    private func finish(_ key: String, name: String, _ outcome: Outcome) {
        ejecting.remove(key)
        switch outcome {
        case .ejected:
            if listedKeys.contains(key) { ejected.insert(key) }
            announce(String(localized: "“\(name)” ejected", comment: "VoiceOver announcement after ejecting a volume"))
        case .notMounted:
            break
        case .failed(let failure):
            show(failure)
        }
    }

    /// Runs off the main thread. A volume still busy is tried once more after
    /// a moment, once Selway's own previews of files on it have let go: Quick
    /// Look keeps a PDF or a sound it shows open (in its own process), and a
    /// listing that was reading the volume may just have finished.
    nonisolated private static func unmount(_ url: URL, name: String, siblings: [URL]) -> Outcome {
        for attempt in 0..<2 {
            guard isMountPoint(url) else { return .notMounted }
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                return .ejected
            } catch {
                let error = error as NSError
                let isBusy = SidebarVolumes.isBusy(errorDomain: error.domain, code: error.code)
                if isBusy && attempt == 0 {
                    DispatchQueue.main.sync {
                        for volume in [url] + siblings {
                            NotificationCenter.default.post(name: .releaseVolume, object: volume)
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                let processes = isBusy ? Self.processesUsing([url] + siblings) : []
                return .failed(SidebarVolumes.ejectFailure(name: name, isBusy: isBusy,
                                                           reason: error.localizedDescription,
                                                           using: processes))
            }
        }
        return .notMounted
    }

    /// The apps to name when `volumes` are busy. DiskArbitration's dissenter
    /// has no useful EBUSY explanation.
    nonisolated private static func processesUsing(_ volumes: [URL]) -> [String] {
        SidebarVolumes.busyAppNames(volumes.flatMap(processesUsingVolume))
    }

    /// The processes visible to this user with files open on the volume, from libproc.
    nonisolated private static func processesUsingVolume(_ url: URL) -> [SidebarVolumes.BusyProcess] {
        let needed = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, url.path, UInt32(PROC_LISTPIDSPATH_PATH_IS_VOLUME), nil, 0)
        guard needed > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 32)
        let bytes = buffer.withUnsafeMutableBytes {
            proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, url.path, UInt32(PROC_LISTPIDSPATH_PATH_IS_VOLUME),
                              $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return [] }
        let count = min(Int(bytes) / MemoryLayout<pid_t>.size, buffer.count)
        return Set(buffer.prefix(count)).compactMap { pid -> SidebarVolumes.BusyProcess? in
            guard pid > 0 else { return nil }
            let isSelf = pid == getpid()
            if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
                return .init(name: name, isApp: app.activationPolicy != .prohibited, isSelf: isSelf)
            }
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
            return .init(name: String(cString: name), isApp: false, isSelf: isSelf)
        }
    }

    /// True while a file system is mounted at `url` itself (its mount point,
    /// not a folder on the volume underneath). False only when that's certain:
    /// any other error (a server timing out, a disk failing) leaves it to the
    /// eject to try, and to report.
    nonisolated private static func isMountPoint(_ url: URL) -> Bool {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else {
            let error = errno
            return error != ENOENT && error != ENOTDIR
        }
        let mountedOn = withUnsafeBytes(of: &info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return ShellPath.key(URL(fileURLWithPath: mountedOn)) == ShellPath.key(url)
    }

    /// On the key browser window, as a sheet; otherwise app-modal. If Selway
    /// isn't in front (an eject can take a while), it asks for attention.
    private func show(_ failure: SidebarVolumes.EjectFailure) {
        let alert = NSAlert()
        alert.alertStyle      = .warning
        alert.messageText     = failure.title
        alert.informativeText = failure.detail
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
        let window = [NSApp.keyWindow, NSApp.mainWindow].lazy.compactMap { $0 }
            .first { BrowserWindowRouter.shared.isBrowserWindow($0) && $0.attachedSheet == nil }
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// VoiceOver hears that it went: the row just disappears.
    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

// MARK: - The tags in use on this Mac, for the sidebar

/// What the sidebar's Tags section lists besides the current folder's tags:
/// the user's names for the colour tags, and the custom tags found on this Mac.
/// Finder lists all of them whatever folder is open.
///
/// The custom tags come from a Spotlight query for every tagged file, run on a
/// background queue when a window opens or the app comes to the front and the
/// last scan is more than `staleAfter` old, and kept in UserDefaults so the
/// sidebar has them at launch. One instance serves every window.
@MainActor
final class TagCatalog: ObservableObject {
    static let shared = TagCatalog()

    @Published private(set) var colorNames: TagColorNames
    @Published private(set) var knownTags: [FileTag]

    /// How old a scan may get before a window opening or the app coming to
    /// the front starts another.
    static let staleAfter: TimeInterval = 10 * 60
    /// A scan still running after this long is given up and can start again.
    private static let scanTimeout: TimeInterval = 2 * 60

    private let defaults: UserDefaults
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "studio.irq.selway.tag-scan"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()
    private var query: NSMetadataQuery?
    /// A scan's query on its way to `queue`, its operation queue: it isn't
    /// Sendable, but once the main actor has set it up it's started, read and
    /// stopped only there, and the main actor just compares it with `query`.
    private struct QueuedQuery: @unchecked Sendable { let query: NSMetadataQuery }
    private var queryObserver: NSObjectProtocol?
    private var scanStarted: Date?
    private var lastScan: Date?
    private var observers: [NSObjectProtocol] = []

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        colorNames = .current
        knownTags = SidebarPrefs.knownTags(fromStorage: defaults.stringArray(forKey: SidebarPrefs.knownTagsKey) ?? [])
        // Renaming a colour tag in Finder → Settings → Tags.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didChangeFileLabelsNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshColorNames() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshColorNames()
                    self?.scanIfStale()
                }
            })
    }

    private func refreshColorNames() {
        let names = TagColorNames.current
        if names != colorNames { colorNames = names }
    }

    /// Starts a scan unless one ran recently or is running.
    func scanIfStale() {
        if let started = scanStarted, Date().timeIntervalSince(started) > Self.scanTimeout { stopQuery() }
        guard query == nil else { return }
        if let lastScan, Date().timeIntervalSince(lastScan) < Self.staleAfter { return }
        scan()
    }

    private func scan() {
        guard let predicate = NSPredicate(fromMetadataQueryString: "kMDItemUserTags == \"*\"") else { return }
        let q = NSMetadataQuery()
        q.searchScopes   = [NSMetadataQueryLocalComputerScope]
        q.predicate      = predicate
        q.operationQueue = queue
        let queued = QueuedQuery(query: q)
        // Runs on `queue`: reading thousands of results (and a file per tag
        // name for its colour) stays off the main thread.
        queryObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: q, queue: queue) { [weak self] _ in
                let q = queued.query
                q.disableUpdates()
                let hits = (0..<q.resultCount).compactMap { i -> TagScan.Hit? in
                    guard let item = q.result(at: i) as? NSMetadataItem,
                          let names = item.value(forAttribute: "kMDItemUserTags") as? [String],
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                    return TagScan.Hit(names: names, path: path)
                }
                q.stop()
                let tags = TagScan.tags(from: hits)
                DispatchQueue.main.async { self?.finish(queued.query, tags: tags) }
            }
        query = q
        scanStarted = Date()
        queue.addOperation { queued.query.start() }
    }

    private func finish(_ q: NSMetadataQuery, tags: [FileTag]) {
        guard q === query else { return }
        stopQuery()
        lastScan = Date()
        if tags != knownTags {
            knownTags = tags
            defaults.set(SidebarPrefs.storage(knownTags: tags), forKey: SidebarPrefs.knownTagsKey)
        }
    }

    private func stopQuery() {
        if let q = query {
            let queued = QueuedQuery(query: q)
            queue.addOperation { queued.query.stop() }
        }
        if let queryObserver { NotificationCenter.default.removeObserver(queryObserver) }
        queryObserver = nil
        query = nil
        scanStarted = nil
    }
}

// MARK: - Recent folders

/// The sidebar's Recent folders, shared by every window, and read like the
/// pinned ones (PinnedFolderReader): the guard's walk and the icon of a folder
/// on a share that has gone can take minutes, so neither happens on the main
/// thread. Its own object, watched only by the sidebars, because it changes
/// at every visit.
@MainActor
final class RecentFoldersModel: ObservableObject {
    static let shared = RecentFoldersModel()

    /// Most recent first; a folder already shown keeps its row
    /// (RecentFolders.visible). Those found missing leave.
    @Published private(set) var folders: [URL] = []
    /// What the reader found, by ShellPath.key; none yet for a folder not read.
    @Published private(set) var answers: [String: PinnedFolderAnswer<NSImage>] = [:]
    /// Whether the first answers have come. Until then the section stays
    /// hidden, so folders that have gone don't flash up and vanish.
    @Published private(set) var isListed = false

    /// Stored folders not shown, read but kept back until they're found
    /// there: one that left with its drive comes back when it's mounted.
    private var waiting: [URL] = []
    private var reader: PinnedFolderReader<NSImage>?
    private var mountObservers: [NSObjectProtocol] = []

    private init() {
        reader = PinnedFolderReader(hooks: .init(read: FavoritesService.readFolderIcon)) { [weak self] answers in
            // Delivered on the main queue.
            MainActor.assumeIsolated { self?.answered(answers) }
        }
        // Read when the first sidebar appears (recheck), before the section shows.
        folders = storedFolders()
        let center = NSWorkspace.shared.notificationCenter
        mountObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recheck() }
            }
        }
    }

    /// A folder's icon, as read; nil until then, and for one the guard refused.
    func icon(_ url: URL) -> NSImage? {
        if case .present(let icon)? = answers[ShellPath.key(url)] { return icon }
        return nil
    }

    /// Stores a visit to `url` and reads it (and any folder found missing) in
    /// the background; the others keep their answers.
    func visit(_ url: URL, limit: Int) {
        let defaults = UserDefaults.standard
        let stored = defaults.stringArray(forKey: RecentFolders.defaultsKey) ?? []
        defaults.set(RecentFolders.stored(stored, visiting: url.path), forKey: RecentFolders.defaultsKey)
        let rows = RecentFolders.visible(folders, visiting: url, limit: limit)
        if rows != folders { folders = rows }
        waiting.removeAll { ShellPath.same($0, url) }
        reader?.refresh(folders + waiting, rereadingAnswered: false)
    }

    /// Reads every folder again, keeping the rows' order: one deleted, or on
    /// a drive ejected, leaves, and stored ones found again come back. When a
    /// sidebar appears and when a volume comes or goes.
    func recheck() {
        waiting = storedFolders().filter { !ShellPath.contains(folders, $0) }
        reader?.refresh(folders + waiting)
    }

    private func storedFolders() -> [URL] {
        RecentFolders.urls(UserDefaults.standard.stringArray(forKey: RecentFolders.defaultsKey) ?? [])
    }

    private func answered(_ answers: [String: PinnedFolderAnswer<NSImage>]) {
        if !Self.same(answers, self.answers) { self.answers = answers }
        // Gone by the reader's answer now, not this list's: a folder read
        // again since it was made may be there after all.
        let merged = RecentFolders.merged(folders, waiting: waiting, answers: answers) { [reader] in
            reader?.isGone($0) == true
        }
        waiting = merged.waiting
        if merged.rows != folders { folders = merged.rows }
        if !isListed { isListed = true }
    }

    /// Whether two lists say the same, the same icons included, so a visit
    /// that read nothing new doesn't redraw every sidebar.
    private static func same(_ a: [String: PinnedFolderAnswer<NSImage>],
                             _ b: [String: PinnedFolderAnswer<NSImage>]) -> Bool {
        a.count == b.count && a.allSatisfy { key, answer in
            switch (answer, b[key]) {
            case (.refused, .refused?), (.missing, .missing?): return true
            case (.present(let x), .present(let y)?):         return x === y
            default:                                           return false
            }
        }
    }
}

// MARK: - Sidebar view

struct SidebarView: View {
    @Binding var location:        BrowserLocation
    @Binding var selection:       SidebarItem?
    @Binding var activeTagFilter: SidebarTag?
    /// The current folder's tags, listed even before the Mac-wide scan finds them.
    let usedTags: [FileTag]
    /// Runs files dropped on a folder row (see sidebarDropTarget).
    let fileOps: FileOperationsService
    let onReload: () -> Void
    /// Connects to a saved server that isn't connected (Connect to Server's
    /// sheet, already connecting), then shows it.
    let onConnect: (SavedServer) -> Void
    /// A server under Network chosen: Connect to Server's sheet looks it up,
    /// then connects to it (and shows it) or, for Save Server in Sidebar,
    /// shows its address to save.
    let onConnectNetwork: (NetworkServer, ConnectSheetRequest.NetworkPurpose) -> Void
    @EnvironmentObject var favorites: FavoritesService
    /// Only the sidebars watch Recent: it changes at every visit.
    @ObservedObject private var recent = RecentFoldersModel.shared
    @ObservedObject private var tagCatalog = TagCatalog.shared
    @ObservedObject private var ejector = VolumeEjector.shared
    /// The Network row open. Closed at every launch and in every new window,
    /// never restored: open, it searches the network at once, and a search
    /// is what brings up macOS's Local Network prompt, which must wait for
    /// the user to ask for it.
    @State private var networkExpanded = false
    /// This sidebar, to NetworkNeighborhood (which searches while any
    /// sidebar has Network open).
    @State private var sidebarID = UUID()
    /// Not observed here: the rows under Network observe it (NetworkServerRows),
    /// and exist only while it's open, so a search doesn't redraw sidebars
    /// that have it closed.
    private var network: NetworkNeighborhood { .shared }
    @Environment(\.textScale) private var textScale
    @Environment(\.sidebarRowSize) private var rowSize
    // What to show: Settings → Sidebar and Tags (SidebarPrefs).
    @AppStorage(SidebarPrefs.favoritesKey)   private var favoritesRaw: String?
    @AppStorage(SidebarPrefs.showRecentKey)  private var showRecent  = true
    @AppStorage(SidebarPrefs.recentCountKey) private var recentCount = SidebarPrefs.defaultRecentCount
    @AppStorage(SidebarPrefs.showTagsKey)    private var showTags    = true
    @AppStorage(SidebarPrefs.hiddenTagsKey)  private var hiddenTags  = ""
    @AppStorage(SidebarPrefs.showHardDisksKey)      private var showHardDisks      = true
    @AppStorage(SidebarPrefs.showExternalDisksKey)  private var showExternalDisks  = true
    @AppStorage(SidebarPrefs.showDiscsAndImagesKey) private var showDiscsAndImages = true
    @AppStorage(SidebarPrefs.showNetworkVolumesKey) private var showNetworkVolumes = true
    @AppStorage(SidebarPrefs.showNetworkKey)        private var showNetwork        = true

    var body: some View {
        List(selection: userSelection) {

            // ── System locations ──────────────────────────────────────────
            Section {
                ForEach(systemLocations, id: \.self) { url in
                    SidebarRow(url: url)
                        .sidebarDropTarget(url, fileOps: fileOps, reload: onReload)
                        .tag(SidebarItem.location(url))
                }
            } header: {
                // No heading over an empty section (every Favorite turned off).
                if !systemLocations.isEmpty { SidebarSectionTitle("Favorites") }
            }

            // ── Locations: the startup disk, drives, disk images, servers ──
            // ── and the saved servers that aren't standing behind a volume ──
            let servers = serverRows
            Section {
                Label {
                    Text(BrowserLocation.computerName).lineLimit(1).scaledDefaultFont(size: rowSize.textSize)
                } icon: {
                    Image(systemName: "desktopcomputer").imageScale(.small)
                        .scaledDefaultFont(size: 16 * textScale)
                }
                .labelStyle(SidebarLabelStyle(scale: textScale))
                .tag(SidebarItem.computer)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(BrowserLocation.computerName))
                .accessibilityValue(Text("Computer"))
                .help(BrowserLocation.computerName)
                .accessibilityIdentifier("sidebarComputer")

                ForEach(volumes, id: \.url) { volume in
                    volumeRow(volume)
                }
                if showNetwork {
                    networkGroup
                }
                ForEach(servers, id: \.server.id) { row in
                    serverRow(row)
                }
            } header: {
                SidebarSectionTitle("Locations")
            }

            // ── User-pinned folders ───────────────────────────────────────
            pinnedSection

            // ── Recent ────────────────────────────────────────────────────
            if showRecent && recent.isListed && !recent.folders.isEmpty {
                Section {
                    ForEach(recent.folders.prefix(SidebarPrefs.recentCount(recentCount)), id: \.self) { url in
                        SidebarRow(url: url, icon: recent.icon(url) ?? Self.folderIcon)
                            .sidebarDropTarget(url, fileOps: fileOps, reload: onReload)
                            .tag(SidebarItem.recent(url))
                    }
                } header: {
                    SidebarSectionTitle("Recent")
                }
            }

            // ── Tags: the colour tags, then the Mac's custom tags (as Finder) ──
            let tags = SidebarPrefs.tagRows(names: tagCatalog.colorNames, known: tagCatalog.knownTags,
                                            inFolder: usedTags, hiddenStorage: hiddenTags)
            if showTags && !tags.isEmpty {
                Section {
                    ForEach(tags, id: \.self) { tag in
                        tagRow(tag: tag)
                    }
                } header: {
                    SidebarSectionTitle("Tags")
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar")
        .onAppear {
            recent.recheck()
            selection = matchingItem(for: location)
            if showTags { tagCatalog.scanIfStale() }
            // Hidden while this sidebar was away: it can't be left open, unwatched.
            if !showNetwork { networkExpanded = false }
            network.setWatching(networkExpanded && showNetwork, id: sidebarID)
        }
        // The window closing (or the sidebar going) stops this sidebar's search.
        .onDisappear { network.setWatching(false, id: sidebarID) }
        .onChange(of: networkExpanded) { _, open in
            network.setWatching(open && showNetwork, id: sidebarID)
            // A server row closed away can't stay highlighted (Return would connect it).
            if !open, case .networkServer? = selection { selection = .network }
        }
        .onChange(of: showNetwork) { _, shown in
            if !shown { networkExpanded = false }
            network.setWatching(networkExpanded && shown, id: sidebarID)
            // The row gone: the highlight goes back to the folder shown.
            if !shown { selection = matchingItem(for: location) }
        }
        .onChange(of: showTags) { _, shown in if shown { tagCatalog.scanIfStale() } }
        .onChange(of: location) { _, location in
            // Not `hasDirectoryPath`: a folder reached through a symlink (e.g. a
            // ~/Downloads link to another volume) has no trailing slash.
            if let path = location.folder, FileItem.isBrowsableFolder(path) { addToRecent(path) }
            selection = matchingItem(for: location)
        }
        // The rows changing (here or in another window) leaves a highlighted
        // Network row highlighted while it's shown.
        .onChange(of: favorites.pinnedURLs) { _, _ in selection = matchingItem(for: location, keepingNetwork: true) }
        .onChange(of: volumes) { _, _ in selection = matchingItem(for: location, keepingNetwork: true) }
        // Saved servers added or removed, or one connecting while its share has
        // no volume row (Network volumes off): the highlight follows.
        .onChange(of: serverRows) { _, _ in selection = matchingItem(for: location, keepingNetwork: true) }
        // Return on a saved server that isn't connected, or a server under
        // Network, connects it; the arrow keys only move the highlight (see
        // userSelection).
        .onKeyPress(.return) { activateSelectedServer() ? .handled : .ignored }
        // → and ← open and close Network, as they do any outline row, and ←
        // on a server under it goes up to it. Only the plain keys: with ⌘,
        // ⌥, ⌃ or ⇧ they go on to whatever else they do.
        .onKeyPress(keys: [.rightArrow, .leftArrow], phases: [.down, .repeat]) { press in
            guard press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]) else { return .ignored }
            return discloseNetwork(press.key == .rightArrow) ? .handled : .ignored
        }
        // What Selway ▸ Eject (⌘E) ejects in this window.
        .focusedSceneValue(\.sidebarEjectVolume, ejectTarget)
    }

    /// The list's selection drives navigation, not a tap gesture on each row: a
    /// gesture on the row's label took the click from the list, so the folder changed
    /// but the highlight didn't follow. Only the user's own selections navigate; the
    /// app setting `selection` to follow the folder never does, so the two can't
    /// feed back into each other (or send a new window to the wrong folder).
    ///
    /// A saved server that isn't connected connects only when the selection
    /// came from a click (the event being handled is a mouse button's: the
    /// list selects on mouse-down), never from the arrow keys, so moving
    /// through the sidebar can't bring up a login prompt. Return, a click on
    /// a row already highlighted (`serverRow`'s tap), and the row's Connect
    /// actions connect too.
    private var userSelection: Binding<SidebarItem?> {
        Binding(get: { selection }, set: { item in
            selection = item
            let rows = serverRows
            let serverFolder = { (id: String) in rows.first { $0.server.id == id }?.folder }
            let outcome = Self.isClick(NSApp.currentEvent)
                ? SidebarSelection.activated(item, location: location, isAvailable: favorites.isAvailable,
                                             serverFolder: serverFolder)
                : SidebarSelection.userSelected(item, location: location, isAvailable: favorites.isAvailable,
                                                serverFolder: serverFolder)
            perform(outcome)
        })
    }

    /// `fromKeyboard`: Return, which leaves the highlight on the row it
    /// connected (the user is moving through the list with the keys); a
    /// click's highlight goes back to the folder shown, so a click on the row
    /// selects it again (after Cancel, or a failure).
    private func perform(_ outcome: SidebarSelection.Outcome, fromKeyboard: Bool = false) {
        switch outcome {
        case .stay:              break
        case .unavailable:       NSSound.beep()
        case .navigate(let location): self.location = location
        case .connect(let id):
            if let server = favorites.savedServer(id: id) { onConnect(server) }
            if !fromKeyboard { DispatchQueue.main.async { selection = matchingItem(for: location) } }
        case .connectNetworkServer(let id):
            if let server = network.server(id: id) { onConnectNetwork(server, .connect) }
            if !fromKeyboard { DispatchQueue.main.async { selection = matchingItem(for: location) } }
        }
    }

    @ViewBuilder
    private var pinnedSection: some View {
        if !favorites.pinnedURLs.isEmpty {
            Section {
                ForEach(favorites.pinnedURLs, id: \.self) { url in
                    let available = favorites.isAvailable(url)
                    // Its icon as read in the background: the row never looks
                    // at the folder itself.
                    SidebarRow(url: url, icon: favorites.pinnedIcon(url) ?? Self.folderIcon, isAvailable: available)
                        // Hovering a drag reads the folder (FileOpsDrop.Destination):
                        // only one that answered, not one refused or not read yet.
                        .sidebarDropTarget(favorites.pinnedIcon(url) != nil ? url : nil, fileOps: fileOps, reload: onReload)
                        .tag(SidebarItem.pinned(url))
                        .contextMenu {
                            Button("Remove from Pinned") { favorites.unpin(url) }
                        }
                }
                .onDelete { favorites.remove(atOffsets: $0) }
            } header: {
                SidebarSectionTitle("Pinned")
            }
        }
    }

    /// A mouse click, not a key: what's being handled when the list's
    /// selection changes. Drags (several rows) don't count.
    private static func isClick(_ event: NSEvent?) -> Bool {
        guard let type = event?.type else { return false }
        return type == .leftMouseDown || type == .leftMouseUp
    }

    /// Return on a highlighted saved server that isn't connected, or on a
    /// server under Network (while it's open); false (the key goes on) for
    /// anything else.
    private func activateSelectedServer() -> Bool {
        if case .networkServer(let id)? = selection, networkExpanded, network.server(id: id) != nil {
            perform(.connectNetworkServer(id), fromKeyboard: true)
            return true
        }
        guard case .server(let id)? = selection,
              serverRows.contains(where: { $0.server.id == id && !$0.isConnected }) else { return false }
        perform(.connect(id), fromKeyboard: true)
        return true
    }

    /// → (`open`) or ← on the highlighted Network row opens or closes it; ← on
    /// a server under it highlights Network. False (the key goes on) otherwise.
    private func discloseNetwork(_ open: Bool) -> Bool {
        switch selection {
        case .network?:
            guard networkExpanded != open else { return false }
            networkExpanded = open
            return true
        case .networkServer?:
            guard !open else { return false }
            selection = .network
            return true
        default:
            return false
        }
    }

    /// `keepingNetwork`: the rows changed, not the folder: a highlighted
    /// Network row that's still shown keeps the highlight.
    private func matchingItem(for location: BrowserLocation, keepingNetwork: Bool = false) -> SidebarItem? {
        SidebarSelection.matchingItem(for: location, selected: selection, locations: systemLocations,
                                      volumes: volumes.map(\.url), servers: serverRows,
                                      pinned: favorites.pinnedURLs,
                                      networkShown: keepingNetwork ? networkItemsShown : [])
    }

    /// The Network rows on screen: Network (unless turned off), and the
    /// servers under it while it's open.
    private var networkItemsShown: Set<SidebarItem> {
        guard showNetwork else { return [] }
        var items: Set<SidebarItem> = [.network]
        if networkExpanded { items.formUnion(network.servers.map { .networkServer($0.id) }) }
        return items
    }

    /// The saved servers' rows under Locations, after the volumes. A share
    /// that's mounted and listed is its volume's row instead (SidebarServers).
    private var serverRows: [SidebarServerRow] {
        SidebarServers.rows(favorites.savedServers, mounted: favorites.volumes, listed: volumes)
    }

    /// The Locations rows, as Settings → Sidebar chooses.
    private var volumes: [SidebarVolume] {
        let shown: [SidebarVolume.Group: Bool] = [.hardDisks: showHardDisks, .externalDisks: showExternalDisks,
                                                  .discsAndImages: showDiscsAndImages,
                                                  .networkVolumes: showNetworkVolumes]
        return SidebarVolumes.rows(favorites.volumes, showing: Set(shown.filter(\.value).keys))
    }

    /// The selected Locations row, if it can be ejected.
    private var ejectTarget: SidebarVolume? {
        guard case .volume(let url)? = selection else { return nil }
        return volumes.first { ShellPath.same($0.url, url) && $0.canEject }
    }

    /// A volume under Locations: its own name (a drive's name, not its mount
    /// point's), and an eject button on the ones that eject.
    private func volumeRow(_ volume: SidebarVolume) -> some View {
        let isEjecting = ejector.isEjecting(volume)
        let eject: (() -> Void)? = volume.canEject && !isEjecting ? { ejector.eject(volume) } : nil
        let buttonWidth = SidebarEjectButton.width(scale: textScale)
        return SidebarRow(url: volume.url, name: volume.name, icon: favorites.icon(for: volume),
                          volume: SidebarRow.VolumeInfo(kind: volume.kindDescription, eject: eject))
            .frame(maxWidth: .infinity, alignment: .leading)
            // Room for the eject button, laid over it at the row's full height.
            .padding(.trailing, volume.canEject ? buttonWidth + 2 : 0)
            .overlay(alignment: .trailing) {
                if volume.canEject {
                    SidebarEjectButton(volume: volume, isEjecting: isEjecting, width: buttonWidth)
                }
            }
            .sidebarDropTarget(volume.url, fileOps: fileOps, reload: onReload)
        .tag(SidebarItem.volume(volume.url))
        .contextMenu {
            if volume.canEject {
                Button("Eject “\(volume.name)”") { ejector.eject(volume) }
                    .disabled(isEjecting)
            }
            // A server's share: saved, it stays in the sidebar once
            // disconnected, and a click connects it again. While it's mounted
            // this row stands in for the saved one, so its settings are here.
            if let server = volume.server {
                let place = SavedServer.make(mounting: server, folder: "", name: volume.name)
                let saved = favorites.savedServers.first { $0.isSamePlace(as: place) }
                Divider()
                Toggle("Save Server in Sidebar", isOn: Binding(
                    get: { saved != nil },
                    set: { on in
                        if on { favorites.addServer(place) } else if let saved { favorites.removeServer(id: saved.id) }
                    }))
                if let saved {
                    Toggle("Reconnect at Launch", isOn: Binding(
                        get: { saved.reconnectAtLaunch },
                        set: { favorites.setReconnectAtLaunch($0, id: saved.id) }))
                }
            }
        }
    }

    /// A saved server (or a folder on one). Dimmed while it isn't connected,
    /// and choosing it connects; once connected it goes to its folder.
    private func serverRow(_ row: SidebarServerRow) -> some View {
        let server = row.server
        let connect: (() -> Void)? = row.isConnected ? nil : { onConnect(server) }
        let glyphWidth = SidebarEjectButton.width(scale: textScale)
        return SidebarRow(url: row.folder ?? server.fullAddress.url, name: server.sidebarDisplayName, icon: SidebarRow.serverIcon,
                          isAvailable: row.isConnected,
                          server: SidebarRow.ServerInfo(address: server.fullAddress.displayAddress, connect: connect))
            .frame(maxWidth: .infinity, alignment: .leading)
            // Where a volume's eject button goes: a sign that it isn't connected.
            .padding(.trailing, row.isConnected ? 0 : glyphWidth + 2)
            .overlay(alignment: .trailing) {
                if !row.isConnected {
                    Image(systemName: "network.slash")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .frame(width: glyphWidth)
                        .accessibilityHidden(true)
                }
            }
            .sidebarDropTarget(row.folder, fileOps: fileOps, reload: onReload)
            // A click on a dimmed row connects even when it's highlighted
            // already (arrowed onto), when the list's selection doesn't change.
            // The tap takes the click from the list, which for a row that
            // isn't connected only costs the highlight.
            .modifier(ConnectOnTap(connect: connect))
        .tag(SidebarItem.server(server.id))
        .contextMenu {
            if !row.isConnected {
                Button("Connect") { onConnect(server) }
            }
            Toggle("Reconnect at Launch", isOn: Binding(
                get: { server.reconnectAtLaunch },
                set: { favorites.setReconnectAtLaunch($0, id: server.id) }))
                .disabled(server.isServerOnly)
            Divider()
            Button("Remove from Sidebar") { favorites.removeServer(id: server.id) }
        }
    }

    /// Network, under Locations: open, it lists the file servers advertised
    /// on the network (NetworkNeighborhood), or a dimmed row saying it's
    /// searching, found none, or isn't allowed to look. Its triangle, → and ←
    /// open and close it; selecting it does nothing else.
    private var networkGroup: some View {
        DisclosureGroup(isExpanded: $networkExpanded) {
            if networkExpanded {
                NetworkServerRows(connect: { onConnectNetwork($0, .connect) },
                                  save: { onConnectNetwork($0, .save) })
            }
        } label: {
            NetworkRowLabel(isOpen: networkExpanded, selection: $selection)
                .tag(SidebarItem.network)
        }
    }

    private var systemLocations: [URL] {
        SidebarPrefs.favoriteURLs(fromStorage: favoritesRaw, home: FileManager.default.homeDirectoryForCurrentUser) {
            FileItem.isBrowsableFolder(URL(fileURLWithPath: $0))
        }
    }

    /// The generic folder icon, for a row whose folder mustn't be looked at.
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)

    private func addToRecent(_ url: URL) {
        recent.visit(url, limit: SidebarPrefs.recentCount(recentCount))
    }

    @ViewBuilder
    private func tagRow(tag: SidebarTag) -> some View {
        let isActive = activeTagFilter == tag
        let dot = (11 * textScale).rounded()
        HStack(spacing: 6) {
            // The colour stored with the tag; a tag without one gets an empty
            // circle, as in Finder.
            if let color = FileItem.colorForLabelNumber(tag.color) {
                Circle()
                    .fill(color)
                    .frame(width: dot, height: dot)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            } else {
                Circle()
                    .strokeBorder(Color.secondary, lineWidth: 1)
                    .frame(width: dot, height: dot)
            }
            Text(tag.name)
                .scaledFont(size: 12)
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            Spacer()
            if isActive {
                Image(systemName: "checkmark")
                    .scaledFont(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .listRowBackground(isActive ? Color.accentColor.opacity(0.1) : Color.clear)
        .onTapGesture {
            activeTagFilter = isActive ? nil : tag
        }
        .contextMenu {
            Button("Hide “\(tag.name)” in Sidebar") {
                if isActive { activeTagFilter = nil }
                hiddenTags = SidebarPrefs.setting(tag: tag.name, hidden: true, in: hiddenTags)
            }
        }
    }
}

private extension View {
    /// Files dropped on a folder row go into it, as in Finder's sidebar. The
    /// target spans the row's width, behind the label, so the list keeps its
    /// clicks and selection (see FileDropSupport.swift); nil for a pinned
    /// folder whose volume isn't connected.
    func sidebarDropTarget(_ folder: URL?, fileOps: FileOperationsService,
                           reload: @escaping () -> Void) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .folderDropTarget(folder, fileOps: fileOps, verticalOutset: 3, reload: reload)
    }
}

struct SidebarRow: View {
    let url: URL
    /// The name to show instead of the folder's (a volume's own name).
    var name: String?
    /// The icon to show instead of reading the folder's (a volume's, read in
    /// the background: see FavoritesService.volumeIcons).
    var icon: NSImage?
    /// False for a pinned folder whose volume isn't mounted — shown dimmed.
    var isAvailable = true
    /// A volume under Locations (nil for a folder).
    var volume: VolumeInfo?
    /// A saved server under Locations (nil for anything else).
    var server: ServerInfo?
    @Environment(\.textScale) private var textScale
    @Environment(\.sidebarRowSize) private var rowSize
    private var displayName: String {
        if let name { return name }
        if let name = SidebarFavoriteItem.specialName(for: url, home: FileManager.default.homeDirectoryForCurrentUser) {
            return name
        }
        return url.lastPathComponent.isEmpty
            ? String(localized: "Macintosh HD", comment: "Fallback name for the startup disk in the sidebar")
            : url.lastPathComponent
    }
    var body: some View {
        Label {
            Text(displayName).lineLimit(1).scaledDefaultFont(size: rowSize.textSize)
        } icon: {
            Image(nsImage: icon ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: (16 * textScale).rounded(), height: (16 * textScale).rounded())
        }
        .labelStyle(SidebarLabelStyle(scale: textScale))
        .modifier(VolumeRowAccessibility(name: displayName, volume: volume))
        .modifier(ServerRowAccessibility(name: displayName, isConnected: isAvailable, server: server))
        .opacity(isAvailable ? 1 : 0.45)
        // The full name when a long one is cut off.
        .help(helpText)
    }

    private var helpText: String {
        if let server {
            return isAvailable ? server.address
                : String(localized: "“\(displayName)” isn’t connected. Click to connect to \(server.address).",
                         comment: "Tooltip for a saved server that is not connected")
        }
        return isAvailable ? displayName
            : String(localized: "\(url.path) is not available. Connect its volume to open it.",
                     comment: "Tooltip for an unavailable sidebar volume")
    }
}

extension SidebarRow {
    /// What a saved server's row needs.
    struct ServerInfo {
        /// Its address without a password (ServerAddress.displayString).
        let address: String
        /// Connect, offered as the row's action while it isn't connected.
        let connect: (() -> Void)?
    }

    /// The system's file server icon (Finder's for a server), made once.
    static let serverIcon: NSImage = NSWorkspace.shared.icon(for: UTType("com.apple.file-server") ?? .volume)

    /// The Network row's: the system's network icon, as in Finder.
    static let networkIcon: NSImage = NSImage(named: NSImage.networkName) ?? serverIcon

    /// A server under Network: the generic networked computer, Finder's icon
    /// for one whose model it doesn't know.
    static let networkServerIcon: NSImage = UTType("public.generic-pc").map { NSWorkspace.shared.icon(for: $0) }
        ?? serverIcon

    /// What VoiceOver needs about a volume's row.
    struct VolumeInfo {
        /// "External disk", "Server"… (SidebarVolume.kindDescription).
        let kind: String
        /// Eject, offered as the row's action; nil when it doesn't eject.
        let eject: (() -> Void)?
    }
}

/// A volume's row is one element for VoiceOver: its name, its kind as the
/// value, and Eject among its actions, so it can be ejected from the row
/// without finding the button.
private struct VolumeRowAccessibility: ViewModifier {
    let name: String
    let volume: SidebarRow.VolumeInfo?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let volume {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(name)
                .accessibilityValue(volume.kind)
                .accessibilityActions {
                    if let eject = volume.eject { Button("Eject “\(name)”", action: eject) }
                }
        } else {
            content
        }
    }
}

/// The rows under an open Network: the servers found, then a dimmed row for
/// any more than are listed, or the placeholder. The only views observing
/// NetworkNeighborhood: they exist only while Network is open.
private struct NetworkServerRows: View {
    let connect: (NetworkServer) -> Void
    let save: (NetworkServer) -> Void
    @ObservedObject private var network = NetworkNeighborhood.shared

    var body: some View {
        ForEach(network.list.servers) { server in
            serverRow(server)
        }
        if let more = network.list.moreText {
            NetworkNoteRow(text: more, detail: String(localized: "Only the first \(NetworkServers.maxRows) servers found are listed.", comment: "Explanation that the Network sidebar row lists a limited number of servers"),
                           identifier: "networkMore")
        }
        if let placeholder = network.placeholder {
            NetworkPlaceholderRow(placeholder: placeholder)
        }
    }

    /// A server found on the network. Its name is made safe to show
    /// (NetworkServers.displayName). A click or Return connects (Connect to
    /// Server's sheet looks it up, then mounts it, the system's login prompt
    /// allowed); the arrow keys only move the highlight.
    private func serverRow(_ server: NetworkServer) -> some View {
        let connect = { self.connect(server) }
        return NetworkSidebarRow(name: server.displayName, icon: SidebarRow.networkServerIcon)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(server.displayName)
            .accessibilityValue(Text("SMB server"))
            .accessibilityHint(Text("Looks it up and connects"))
            // After the element is made, so VoiceOver keeps it as the row's help.
            .help("“\(server.displayName)” shares files over SMB. Click to connect.")
            .accessibilityActions {
                Button("Connect", action: connect)
                Button("Save Server in Sidebar") { save(server) }
            }
            // For the UI tests (as savedServer.notConnected).
            .accessibilityIdentifier("networkServer")
            .frame(maxWidth: .infinity, alignment: .leading)
            // A click connects even when the row is highlighted already
            // (arrowed onto), when the list's selection doesn't change.
            .modifier(ConnectOnTap(connect: connect))
            .tag(SidebarItem.networkServer(server.id))
            .contextMenu {
                Button("Connect", action: connect)
                Divider()
                Button("Save Server in Sidebar") { save(server) }
            }
    }
}

/// A dimmed, unselectable line under Network ("12 more servers…").
private struct NetworkNoteRow: View {
    let text: String
    let detail: String
    let identifier: String
    @Environment(\.sidebarRowSize) private var rowSize

    var body: some View {
        Text(verbatim: text)
            .scaledDefaultFont(size: rowSize.textSize)
            .foregroundStyle(.secondary)
            .accessibilityLabel(text)
            .accessibilityHint(detail)
            .accessibilityIdentifier(identifier)
            .help(detail)
    }
}

/// A row under Network, or Network itself: a name and an icon at the
/// sidebar's text size, laid out as SidebarRow lays out a folder's.
/// Its tooltip goes on after its accessibility element is made (so VoiceOver
/// keeps it), by whoever makes it.
private struct NetworkSidebarRow: View {
    let name: String
    let icon: NSImage
    @Environment(\.textScale) private var textScale
    @Environment(\.sidebarRowSize) private var rowSize

    var body: some View {
        Label {
            // Verbatim: a name from the network is never markup. Cut in the
            // middle, so a " (2)" that tells two rows apart stays in view.
            Text(verbatim: name).lineLimit(1).truncationMode(.middle).scaledDefaultFont(size: rowSize.textSize)
        } icon: {
            Image(nsImage: icon)
                .resizable().frame(width: (16 * textScale).rounded(), height: (16 * textScale).rounded())
        }
        .labelStyle(SidebarLabelStyle(scale: textScale))
    }
}

/// The Network row itself. Its value tells VoiceOver how the search is going
/// while it's open (NetworkStatus), and each opening announces the search's
/// outcome once. A highlighted server that goes away hands the highlight to
/// it. One view per sidebar, so these happen once (not once per row).
private struct NetworkRowLabel: View {
    let isOpen: Bool
    @Binding var selection: SidebarItem?
    @ObservedObject private var network = NetworkNeighborhood.shared
    @State private var said = NetworkStatus.Said()

    private var serverCount: Int { network.list.servers.count + network.list.hiddenCount }

    var body: some View {
        NetworkSidebarRow(name: String(localized: "Network", comment: "The Network row under Locations in the sidebar (and its VoiceOver name), and the label of its switch in Settings → Sidebar."),
                          icon: SidebarRow.networkIcon)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Network")
            .accessibilityValue(NetworkStatus.value(isOpen: isOpen, placeholder: network.placeholder,
                                                    serverCount: serverCount))
            .accessibilityIdentifier("networkRow")
            .help("File servers on your network. Open to look for them.")
            .onChange(of: isOpen) { _, open in
                if open { said = NetworkStatus.Said() }
            }
            .onChange(of: network.placeholder) { _, _ in announceIfDue() }
            .onChange(of: serverCount) { _, _ in announceIfDue() }
            .onChange(of: network.list.servers) { _, servers in
                if case .networkServer(let id)? = selection, !servers.contains(where: { $0.id == id }) {
                    selection = .network
                }
            }
    }

    private func announceIfDue() {
        guard isOpen,
              let text = NetworkStatus.announcement(placeholder: network.placeholder, serverCount: serverCount,
                                                    said: &said) else { return }
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

/// The dimmed row under Network when it has no servers to list: searching
/// (with a spinner), none found, Local Network access off, no network. Not
/// selectable (no tag). VoiceOver reads the text, with the detail as its hint.
private struct NetworkPlaceholderRow: View {
    let placeholder: NetworkPlaceholder
    @Environment(\.sidebarRowSize) private var rowSize

    var body: some View {
        HStack(spacing: 6) {
            if placeholder == .searching {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            // Wraps in full: it says where the setting is. What needs doing is
            // in the primary colour; a search going as it should, dimmed.
            Text(placeholder.text)
                .scaledDefaultFont(size: rowSize.textSize)
                .foregroundStyle(placeholder.needsAttention ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(placeholder.spokenText)
        .accessibilityHint(placeholder.detail)
        .accessibilityIdentifier("networkStatus")
        .help(placeholder.detail)
    }
}

/// Clicking a saved server that isn't connected (nil `connect`: nothing).
private struct ConnectOnTap: ViewModifier {
    let connect: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let connect {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: connect)
        } else {
            content
        }
    }
}

/// A saved server's row is one element for VoiceOver: its name, "Not
/// connected" (or "Server") as the value, and Connect among its actions.
private struct ServerRowAccessibility: ViewModifier {
    let name: String
    let isConnected: Bool
    let server: SidebarRow.ServerInfo?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let server {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(name)
                .accessibilityValue(isConnected ? Text("Server") : Text("Not connected"))
                .accessibilityHint(isConnected ? Text(verbatim: "") : Text("Connects to \(server.address)"))
                .accessibilityActions {
                    if let connect = server.connect { Button("Connect", action: connect) }
                }
                // For the UI tests: SwiftUI gives a row's value to VoiceOver as
                // its value description, which XCUITest can't read.
                .accessibilityIdentifier(isConnected ? "savedServer.connected" : "savedServer.notConnected")
        } else {
            content
        }
    }
}

/// A Locations row's eject button, as in Finder: the glyph the size of the
/// row's text, the target the row's full height and at least 22 points wide,
/// so it's easy to hit at the small row size. While the volume is being
/// ejected, a spinner instead.
private struct SidebarEjectButton: View {
    let volume: SidebarVolume
    let isEjecting: Bool
    let width: CGFloat
    @Environment(\.sidebarRowSize) private var rowSize

    static func width(scale: CGFloat) -> CGFloat { max(22, (16 * scale).rounded() + 6) }

    var body: some View {
        Group {
            if isEjecting {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel(Text("Ejecting \(volume.name)"))
            } else {
                Button { VolumeEjector.shared.eject(volume) } label: {
                    Image(systemName: "eject.fill")
                        .imageScale(.small)
                        .scaledDefaultFont(size: rowSize.textSize)
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Eject “\(volume.name)”")
                .accessibilityLabel(Text("Eject \(volume.name)"))
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        // Out to the row's edges, as its drop target (sidebarDropTarget).
        .padding(.vertical, -3)
    }
}

extension SidebarRowSize {
    /// The row text size System Settings' "Sidebar icon size" gives (Small, Medium,
    /// Large), which larger text sizes scale from.
    fileprivate var textSize: CGFloat {
        switch self {
        case .small: return 11
        case .large: return 15
        default:     return 13
        }
    }
}

/// A sidebar section title ("Favorites"…) at the window's text size.
private struct SidebarSectionTitle: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .scaledDefaultFont(size: 11, weight: .bold)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The sidebar list sizes its rows' Label icons itself, ignoring their frame. At
/// 100% the label is left exactly as the system draws it; at other text sizes the
/// row lays it out itself, so the icon follows the text size. Only the label's
/// insides change between the two: the row keeps its identity and selection.
private struct SidebarLabelStyle: LabelStyle {
    let scale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        if scale == 1 {
            Label(configuration)
        } else {
            HStack(spacing: (6 * scale).rounded()) {
                configuration.icon.accessibilityHidden(true)
                configuration.title
            }
            .accessibilityElement(children: .combine)
        }
    }
}
