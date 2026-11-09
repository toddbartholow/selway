import Foundation
import Testing
@testable import SelwayCore

@Suite struct TimeMachineBackupsTests {
    private let uuid = "0B66AB23-B7E2-4BC1-AF51-260CB1817B29"
    private let snapshot = "com.apple.TimeMachine.2026-10-26-082530.backup"
    private let name = "2026-10-26-082530.backup"

    /// Stand-ins: a /Volumes folder in a temporary directory holding a disk
    /// and (unless left out) its .timemachine/<UUID> folder. Every file-system
    /// question is answered by the closures, and those that touch a path are
    /// recorded in `asked`.
    private final class Stage {
        let volumes: URL
        let disk: URL
        var snapshots: [String]
        var mounted: Set<String> = []
        var diskMounted = true
        var diskReadable = true
        var backupsReadable = true
        var asked: [String] = []
        var opened: [String] = []
        init(snapshots: [String], uuidFolder: Bool, uuid: String) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            volumes = root.appendingPathComponent("Volumes", isDirectory: true)
            disk = volumes.appendingPathComponent("Samsung_T5", isDirectory: true)
            self.snapshots = snapshots
            try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
            if uuidFolder {
                try FileManager.default.createDirectory(
                    at: volumes.appendingPathComponent(".timemachine/\(uuid)", isDirectory: true),
                    withIntermediateDirectories: true)
            }
        }
    }

    private func make(snapshots: [String]? = nil, uuidFolder: Bool = true) throws -> (TimeMachineBackups, Stage) {
        let stage = try Stage(snapshots: snapshots ?? [snapshot], uuidFolder: uuidFolder, uuid: uuid)
        let uuid = self.uuid
        let fs = TimeMachineBackups.FileSystem(
            snapshotNames: { stage.asked.append("snapshots \($0.path)"); return stage.snapshots },
            localMountPointKeys: {
                var keys = stage.mounted
                if stage.diskMounted { keys.insert(ShellPath.key(stage.disk)) }
                return keys
            },
            volumeUUID: { url in
                stage.asked.append("uuid \(url.path)")
                return ShellPath.same(url, stage.disk) ? uuid : nil
            },
            localVolumes: { stage.diskMounted ? [stage.disk] : [] },
            folderExists: { url in
                stage.asked.append("exists \(url.path)")
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            canOpen: { url in
                stage.opened.append(ShellPath.key(url))
                return ShellPath.same(url, stage.disk) ? stage.diskReadable : stage.backupsReadable
            })
        return (TimeMachineBackups(fileSystem: fs, volumesRoot: stage.volumes), stage)
    }

    private func mountPoint(_ stage: Stage) -> URL {
        stage.volumes.appendingPathComponent(".timemachine/\(uuid)/\(name)", isDirectory: true)
    }

    // MARK: - The backup disk

    @Test func aDiskWithItsUUIDFolderAndBackupsIsADestination() throws {
        let (backups, stage) = try make()
        let destination = try #require(backups.destination(at: stage.disk))
        #expect(destination.uuid == uuid)
        #expect(destination.isReadable)
        #expect(destination.backups.map(\.name) == [name])
    }

    @Test func aDiskSelwayMayNotOpenIsAnUnreadableDestination() throws {
        let (backups, stage) = try make()
        stage.diskReadable = false
        let destination = try #require(backups.destination(at: stage.disk))
        #expect(!destination.isReadable)
        #expect(destination.backups.isEmpty)
        #expect(!stage.asked.contains { $0.hasPrefix("snapshots") }, "snapshots were listed on a disk that can't be opened")
        let (other, otherStage) = try make(uuidFolder: false)
        otherStage.diskReadable = false
        #expect(other.destination(at: otherStage.disk) == nil, "an unreadable disk with no UUID folder isn't a Time Machine disk")
    }

    @Test func aDestinationRootIsKnownWithoutListingItsBackups() throws {
        let (backups, stage) = try make()
        #expect(backups.isDestinationRoot(stage.disk))
        #expect(!stage.asked.contains { $0.hasPrefix("snapshots") }, "snapshots were listed to tell a destination root")
        #expect(!backups.isDestinationRoot(stage.disk.appendingPathComponent("Folder", isDirectory: true)))
        let (other, otherStage) = try make(uuidFolder: false)
        #expect(!other.isDestinationRoot(otherStage.disk))
        stage.diskMounted = false
        #expect(!backups.isDestinationRoot(stage.disk))
    }

    @Test func aDiskWithoutItsUUIDFolderIsNot() throws {
        let (backups, stage) = try make(uuidFolder: false)
        #expect(backups.destination(at: stage.disk) == nil)
        #expect(!stage.asked.contains { $0.hasPrefix("snapshots") }, "snapshots were listed for a disk with no UUID folder")
    }

    @Test func aDiskWithOnlyOtherSnapshotsIsAnEmptyDestination() throws {
        let (backups, stage) = try make(snapshots: ["com.apple.os.update-1234", "com.apple.TimeMachine.bad.backup"])
        let destination = try #require(backups.destination(at: stage.disk))
        #expect(destination.backups.isEmpty)
    }

    @Test func diskContentsShowBackupsOnlyWhenHiddenFilesAreOffAndBackupsExist() throws {
        let (backups, stage) = try make()
        try Data().write(to: stage.disk.appendingPathComponent("backup_manifest.plist"))
        #expect(loadItems(at: stage.disk, showHidden: false, timeMachineBackups: backups).map(\.name) == [name])
        #expect(loadItems(at: stage.disk, showHidden: true, timeMachineBackups: backups).map(\.name) == ["backup_manifest.plist"])

        let (empty, emptyStage) = try make(snapshots: ["com.apple.os.update-1234"])
        try Data().write(to: emptyStage.disk.appendingPathComponent("backup_manifest.plist"))
        #expect(loadItems(at: emptyStage.disk, showHidden: false, timeMachineBackups: empty).map(\.name) == ["backup_manifest.plist"])
    }

    @Test func aFolderThatIsntAVolumeRootIsNotAskedAnything() throws {
        let (backups, stage) = try make()
        let inside = stage.disk.appendingPathComponent("Folder", isDirectory: true)
        #expect(backups.destination(at: inside) == nil)
        #expect(backups.destination(at: stage.volumes) == nil)
        #expect(backups.destination(at: URL(fileURLWithPath: "/Users/someone", isDirectory: true)) == nil)
        #expect(backups.destination(at: stage.volumes.appendingPathComponent(".timemachine", isDirectory: true)) == nil)
        #expect(stage.asked.isEmpty, "asked \(stage.asked)")
    }

    @Test func aVolumeRootThatIsntMountedIsNotAskedForItsUUID() throws {
        let (backups, stage) = try make()
        stage.diskMounted = false
        #expect(backups.destination(at: stage.disk) == nil)
        #expect(!stage.asked.contains { $0.hasPrefix("uuid") })
    }

    @Test func backupsAreNamedAsFinderNamesThemNewestFirst() throws {
        let (backups, stage) = try make(snapshots: [
            "com.apple.TimeMachine.2026-02-04-100405.backup", snapshot,
            "com.apple.TimeMachine.2026-13-01-000000.backup", "com.apple.os.update-1234",
        ])
        let list = backups.backups(for: stage.disk, uuid: uuid)
        #expect(list.map(\.name) == [name, "2026-02-04-100405.backup"])
        let first = try #require(list.first)
        #expect(first.url.path == mountPoint(stage).appendingPathComponent(name).path)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: first.date)
        #expect([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second] == [2026, 10, 26, 8, 25, 30])
    }

    @Test func aBackupIsAvailableOnlyWhenItsMountPointIsMounted() throws {
        let (backups, stage) = try make()
        #expect(backups.backups(for: stage.disk, uuid: uuid).first?.isMounted == false)
        stage.mounted = [ShellPath.key(mountPoint(stage))]
        #expect(backups.backups(for: stage.disk, uuid: uuid).first?.isMounted == true)
    }

    @Test func malformedNamesAreRejected() {
        #expect(TimeMachineBackups.backupName(fromSnapshot: snapshot) == name)
        #expect(TimeMachineBackups.backupName(fromSnapshot: "com.apple.TimeMachine.not-a-date.backup") == nil)
        #expect(TimeMachineBackups.backupName(fromSnapshot: "com.apple.TimeMachine.2026-10-26-082530") == nil)
        #expect(TimeMachineBackups.backupName(fromSnapshot: "com.apple.TimeMachine.2026-02-30-000000.backup") == nil)
        #expect(TimeMachineBackups.backupName(fromSnapshot: "2026-10-26-082530.backup") == nil)
    }

    // MARK: - Inside a backup

    @Test func insideABackupItsMountStateIsKnown() throws {
        let (backups, stage) = try make()
        let folder = mountPoint(stage).appendingPathComponent("\(name)/Macintosh HD - Data/Users", isDirectory: true)
        #expect(backups.backup(at: folder)?.isMounted == false)
        stage.mounted = [ShellPath.key(mountPoint(stage))]
        #expect(backups.backup(at: folder)?.isMounted == true)
        #expect(backups.backup(at: stage.disk) == nil)
        #expect(backups.backup(at: mountPoint(stage)) == nil, "the mount point itself isn't a backup's folder")
    }

    @Test func aMountedBackupSelwayMayNotOpenIsUnreadable() throws {
        let (backups, stage) = try make()
        let folder = mountPoint(stage).appendingPathComponent(name, isDirectory: true)
        stage.backupsReadable = false
        #expect(!backups.isUnreadableBackup(folder), "a backup that isn't mounted is unavailable, not unreadable")
        stage.mounted = [ShellPath.key(mountPoint(stage))]
        #expect(backups.isUnreadableBackup(folder))
        #expect(stage.opened.last == ShellPath.key(mountPoint(stage).appendingPathComponent(name, isDirectory: true)))
        stage.backupsReadable = true
        #expect(!backups.isUnreadableBackup(folder))
        #expect(!backups.isUnreadableBackup(stage.disk))
    }

    @Test func upFromABackupGoesToItsDisk() throws {
        let (backups, stage) = try make()
        let inner = mountPoint(stage).appendingPathComponent(name, isDirectory: true)
        #expect(ShellPath.same(backups.parentURL(for: inner), stage.disk))
        let below = inner.appendingPathComponent("Macintosh HD - Data", isDirectory: true)
        #expect(ShellPath.same(backups.parentURL(for: below), inner))
        stage.diskMounted = false
        #expect(ShellPath.same(backups.parentURL(for: inner), mountPoint(stage)), "without its disk, Up is plain")
    }

    @Test func thePathBarRunsFromTheDisk() throws {
        let (backups, stage) = try make()
        let inner = mountPoint(stage).appendingPathComponent(name, isDirectory: true)
        let folder = inner.appendingPathComponent("Macintosh HD - Data", isDirectory: true)
        let crumbs = try #require(backups.breadcrumbs(for: folder))
        let diskChain = ShellPath.ancestorChain(stage.disk)
        #expect(crumbs.map(\.name).suffix(3) == ["Samsung_T5", name, "Macintosh HD - Data"])
        #expect(crumbs.count == diskChain.count + 2)
        #expect(zip(crumbs, diskChain).allSatisfy { ShellPath.same($0.url, $1) })
        #expect(ShellPath.same(crumbs[crumbs.count - 2].url, inner))
        #expect(ShellPath.same(crumbs[crumbs.count - 1].url, folder))
        #expect(crumbs.first?.name == "/")
    }

    @Test func thePathBarIsPlainOutsideABackupOrWithoutItsDisk() throws {
        let (backups, stage) = try make()
        #expect(backups.breadcrumbs(for: stage.disk) == nil)
        #expect(backups.breadcrumbs(for: mountPoint(stage)) == nil)
        stage.diskMounted = false
        #expect(backups.breadcrumbs(for: mountPoint(stage).appendingPathComponent(name, isDirectory: true)) == nil)
    }

    @Test func everythingUnderTheSnapshotFolderIsReadOnly() throws {
        let (backups, stage) = try make()
        let root = stage.volumes.appendingPathComponent(".timemachine", isDirectory: true)
        #expect(backups.isSnapshotPath(root))
        #expect(backups.isSnapshotPath(mountPoint(stage)))
        #expect(backups.isSnapshotPath(mountPoint(stage).appendingPathComponent("\(name)/x", isDirectory: true)))
        #expect(!backups.isSnapshotPath(stage.disk))
        #expect(!backups.isSnapshotPath(stage.volumes.appendingPathComponent(".timemachinex", isDirectory: true)))
        #expect(stage.asked.isEmpty)
    }
}
