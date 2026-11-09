import Foundation
#if canImport(Darwin)
import Darwin

// <sys/snapshot.h> isn't part of Swift's Darwin module.
@_silgen_name("fs_snapshot_list")
private func fs_snapshot_list(_ fd: Int32, _ attrs: UnsafeMutablePointer<attrlist>,
                              _ buffer: UnsafeMutableRawPointer?, _ size: Int, _ flags: UInt32) -> Int32
#endif

/// A Time Machine backup disk (an APFS destination) and its backups.
///
/// Time Machine hides everything at the destination's root. The backups are
/// APFS snapshots named `com.apple.TimeMachine.<date>.backup`, which macOS
/// mounts read-only at `/Volumes/.timemachine/<volume UUID>/<date>.backup`
/// only when Finder or Time Machine asks; each holds a `<date>.backup` folder
/// with the backed-up volumes. Selway lists the snapshots (which needs no
/// privileges), never mounts one, and shows a backup as that inner folder.
///
/// Everything here is lexical first: nothing touches the disk unless the path
/// is a volume root right under /Volumes or lies under /Volumes/.timemachine,
/// and the volumes are found from the local mount table, so a
/// hung network share is never asked.
struct TimeMachineBackups {
    /// The real disks, or the UI tests' stand-ins (UITestHooks).
    static var live = TimeMachineBackups()

    struct FileSystem {
        /// The snapshot names on the volume mounted at a URL.
        var snapshotNames: (URL) -> [String]
        /// ShellPath.key values for local mount points, from the mount table.
        var localMountPointKeys: () -> Set<String>
        /// The volume UUID of a local volume root.
        var volumeUUID: (URL) -> String?
        /// The local volumes mounted right under /Volumes (from the mount
        /// table, without asking their file systems).
        var localVolumes: () -> [URL]
        var folderExists: (URL) -> Bool
        /// Whether this process may open a folder. macOS lets only apps with
        /// Full Disk Access read a Time Machine disk or its backups.
        var canOpen: (URL) -> Bool

        static let live = FileSystem(
            snapshotNames: liveSnapshotNames,
            localMountPointKeys: liveLocalMountPointKeys,
            volumeUUID: { (try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString },
            localVolumes: liveLocalVolumes,
            folderExists: { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            canOpen: { url in
                let fd = open(url.path, O_RDONLY)
                if fd >= 0 { close(fd) }
                return fd >= 0
            }
        )

        private static func liveLocalMountPointKeys() -> Set<String> {
            Set(MountTableEntry.current().lazy.filter(\.isLocal).map(\.key))
        }

        private static func liveLocalVolumes() -> [URL] {
            MountTableEntry.current().filter { $0.isLocal && isVolumeRoot($0.url, under: defaultVolumesRoot) }.map(\.url)
        }

        private static func liveSnapshotNames(_ volume: URL) -> [String] {
            #if canImport(Darwin)
            let fd = open(volume.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { return [] }
            defer { close(fd) }
            var attrs = attrlist()
            attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attrs.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME)
            let capacity = 64 * 1024
            var buffer = [UInt8](repeating: 0, count: capacity)
            var names: [String] = []
            // Each call returns the next entries that fit, and 0 at the end.
            // Each entry: its length, the attributes returned, then the name's
            // reference (offset from the reference, length with the NUL).
            while true {
                let count = buffer.withUnsafeMutableBytes { fs_snapshot_list(fd, &attrs, $0.baseAddress, capacity, 0) }
                guard count > 0 else { return count == 0 ? names : [] }
                buffer.withUnsafeBytes { bytes in
                    let header = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
                    var offset = 0
                    for _ in 0..<Int(count) {
                        guard offset + header + MemoryLayout<attrreference_t>.size <= capacity else { return }
                        let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                        guard length > 0, offset + length <= capacity else { return }
                        let returned = bytes.loadUnaligned(fromByteOffset: offset + MemoryLayout<UInt32>.size,
                                                           as: attribute_set_t.self)
                        let reference = bytes.loadUnaligned(fromByteOffset: offset + header, as: attrreference_t.self)
                        guard reference.attr_dataoffset >= 0 else { offset += length; continue }
                        let start = offset + header + Int(reference.attr_dataoffset)
                        let nameLength = Int(reference.attr_length) - 1
                        if returned.commonattr & UInt32(ATTR_CMN_NAME) != 0, nameLength > 0,
                           start >= offset, start <= offset + length, nameLength <= offset + length - start {
                            names.append(String(decoding: bytes[start..<(start + nameLength)], as: UTF8.self))
                        }
                        offset += length
                    }
                }
            }
            #else
            return []
            #endif
        }
    }

    /// A Time Machine disk: its volume UUID and backups, or, when Selway may
    /// not read it (no Full Disk Access), no backups and `isReadable` false.
    struct Destination: Equatable {
        let uuid: String
        let backups: [Backup]
        let isReadable: Bool
    }

    struct Backup: Equatable {
        /// As Finder names it: `2026-10-26-082530.backup`.
        let name: String
        /// The inner folder, `<mount point>/<name>`.
        let url: URL
        let date: Date
        let isMounted: Bool
    }

    static let defaultVolumesRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)

    let fileSystem: FileSystem
    let volumesRoot: URL
    var timeMachineRoot: URL { volumesRoot.appendingPathComponent(".timemachine", isDirectory: true) }

    init(fileSystem: FileSystem = .live, volumesRoot: URL = TimeMachineBackups.defaultVolumesRoot) {
        self.fileSystem = fileSystem
        self.volumesRoot = volumesRoot
    }

    // MARK: - The backup disk

    /// The destination when `url` is a Time Machine destination's root: a
    /// local volume mounted right under /Volumes that has a
    /// /Volumes/.timemachine/<UUID> folder, the folder Time Machine makes for
    /// its disks. Its backups are listed from its snapshots; one Selway may
    /// not open lists none, and nor does one with no backups yet.
    func destination(at url: URL) -> Destination? {
        guard Self.isVolumeRoot(url, under: volumesRoot) else { return nil }
        let localMountPointKeys = fileSystem.localMountPointKeys()
        guard let uuid = destinationUUID(at: url, localMountPointKeys: localMountPointKeys) else { return nil }
        guard fileSystem.canOpen(url) else { return Destination(uuid: uuid, backups: [], isReadable: false) }
        let backups = backups(for: url, uuid: uuid, localMountPointKeys: localMountPointKeys)
        return Destination(uuid: uuid, backups: backups, isReadable: true)
    }

    /// Whether `url` is a Time Machine destination's root, as `destination(at:)`
    /// decides, without listing its backups: for files dragged from there,
    /// which are copied, never moved.
    func isDestinationRoot(_ url: URL) -> Bool {
        Self.isVolumeRoot(url, under: volumesRoot)
            && destinationUUID(at: url, localMountPointKeys: fileSystem.localMountPointKeys()) != nil
    }

    private func destinationUUID(at url: URL, localMountPointKeys: Set<String>) -> String? {
        guard localMountPointKeys.contains(ShellPath.key(url)),
              let uuid = fileSystem.volumeUUID(url),
              fileSystem.folderExists(timeMachineRoot.appendingPathComponent(uuid, isDirectory: true))
        else { return nil }
        return uuid
    }

    /// The volume's Time Machine backups, newest first. Other snapshots and
    /// names that don't parse are left out.
    func backups(for volume: URL, uuid: String) -> [Backup] {
        let localMountPointKeys = fileSystem.localMountPointKeys()
        return backups(for: volume, uuid: uuid, localMountPointKeys: localMountPointKeys)
    }

    private func backups(for volume: URL, uuid: String, localMountPointKeys: Set<String>) -> [Backup] {
        fileSystem.snapshotNames(volume).compactMap { snapshot in
            guard let name = Self.backupName(fromSnapshot: snapshot), let date = Self.date(fromBackup: name)
            else { return nil }
            let mount = mountPoint(uuid: uuid, name: name)
            return Backup(name: name, url: mount.appendingPathComponent(name, isDirectory: true), date: date,
                          isMounted: localMountPointKeys.contains(ShellPath.key(mount)))
        }.sorted { $0.date > $1.date }
    }

    // MARK: - Inside a backup

    /// The backup `url` is in (its inner folder or anything below it), and
    /// whether it's mounted.
    func backup(at url: URL) -> Backup? {
        guard let match = snapshotPath(url), let date = Self.date(fromBackup: match.name) else { return nil }
        let mount = mountPoint(uuid: match.uuid, name: match.name)
        return Backup(name: match.name, url: mount.appendingPathComponent(match.name, isDirectory: true),
                      date: date, isMounted: fileSystem.localMountPointKeys().contains(ShellPath.key(mount)))
    }

    /// Whether `url` is in a mounted backup that Selway may not read (no Full
    /// Disk Access).
    func isUnreadableBackup(_ url: URL) -> Bool {
        guard let backup = backup(at: url), backup.isMounted else { return false }
        return !fileSystem.canOpen(backup.url)
    }

    /// The backup disk that `url`, inside a backup, comes from, if it's mounted.
    func disk(forSnapshotPath url: URL) -> URL? {
        snapshotPath(url).flatMap { disk(uuid: $0.uuid) }
    }

    /// Up from a backup's inner folder goes to its disk, as in Finder, never
    /// to the mount point. Elsewhere it's the parent folder.
    func parentURL(for url: URL) -> URL {
        if let match = snapshotPath(url), match.suffix.isEmpty, let disk = disk(uuid: match.uuid) {
            return disk
        }
        return url.deletingLastPathComponent()
    }

    /// The path bar's segments inside a backup: the disk's own chain, the
    /// backup, then the folders below it, each with the real URL it opens.
    /// nil outside a backup, or when its disk isn't mounted.
    func breadcrumbs(for url: URL) -> [(name: String, url: URL)]? {
        guard let match = snapshotPath(url), let disk = disk(uuid: match.uuid) else { return nil }
        let diskChain = ShellPath.ancestorChain(disk).map { ($0.lastPathComponent.isEmpty ? "/" : $0.lastPathComponent, $0) }
        var folder = mountPoint(uuid: match.uuid, name: match.name).appendingPathComponent(match.name, isDirectory: true)
        var chain = diskChain + [(match.name, folder)]
        for component in match.suffix {
            folder = folder.appendingPathComponent(component, isDirectory: true)
            chain.append((component, folder))
        }
        return chain
    }

    /// Whether `url` is under /Volumes/.timemachine: a backup, its contents
    /// or a mount point, all read-only. Lexical; touches nothing.
    func isSnapshotPath(_ url: URL) -> Bool {
        let path = ShellPath.key(url)
        let root = ShellPath.key(timeMachineRoot)
        return path == root || path.hasPrefix(root + "/")
    }

    static func isSnapshotPath(_ url: URL) -> Bool { live.isSnapshotPath(url) }

    // MARK: - Names

    /// `2026-10-26-082530.backup` for `com.apple.TimeMachine.2026-10-26-082530.backup`.
    static func backupName(fromSnapshot snapshot: String) -> String? {
        let prefix = "com.apple.TimeMachine."
        guard snapshot.hasPrefix(prefix) else { return nil }
        let name = String(snapshot.dropFirst(prefix.count))
        return date(fromBackup: name) == nil ? nil : name
    }

    /// The local time a backup named `2026-10-26-082530.backup` was made.
    static func date(fromBackup name: String) -> Date? {
        guard name.hasSuffix(".backup") else { return nil }
        let stamp = String(name.dropLast(".backup".count))
        guard stamp.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.isLenient = false
        return formatter.date(from: stamp)
    }

    // MARK: - Paths

    private struct SnapshotPath { let uuid: String; let name: String; let suffix: [String] }

    /// `<timemachine>/<UUID>/<name>/<name>/<suffix...>`, read from the path alone.
    private func snapshotPath(_ url: URL) -> SnapshotPath? {
        let root = ShellPath.key(timeMachineRoot) + "/"
        let path = ShellPath.key(url)
        guard path.hasPrefix(root) else { return nil }
        let parts = path.dropFirst(root.count).split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[1].hasSuffix(".backup"), parts[2] == parts[1] else { return nil }
        return SnapshotPath(uuid: parts[0], name: parts[1], suffix: Array(parts.dropFirst(3)))
    }

    private func mountPoint(uuid: String, name: String) -> URL {
        timeMachineRoot.appendingPathComponent(uuid, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    private func disk(uuid: String) -> URL? {
        fileSystem.localVolumes().first { fileSystem.volumeUUID($0) == uuid }
    }

    /// A folder right under `volumes`, other than .timemachine.
    static func isVolumeRoot(_ url: URL, under volumes: URL) -> Bool {
        let path = ShellPath.key(url)
        let root = ShellPath.key(volumes) + "/"
        guard path.hasPrefix(root) else { return false }
        let name = path.dropFirst(root.count)
        return !name.isEmpty && !name.contains("/") && name != ".timemachine"
    }
}
