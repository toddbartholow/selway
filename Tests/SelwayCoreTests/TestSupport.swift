import Foundation
@testable import SelwayCore

// Shared helpers for SelwayCore tests.

/// A fresh, empty directory removed by `cleanup()` (call it in `defer`).
/// `url` is the directory's real path (no /var → /private/var link in it), so
/// paths that come back from listings compare equal.
struct TempDir {
    let url: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelwayCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = ModelPaths.realPath(base) ?? base
    }

    func cleanup() {
        // Restore permissions so an unreadable test folder can be deleted.
        if let e = FileManager.default.enumerator(atPath: url.path) {
            while let rel = e.nextObject() as? String {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: url.appendingPathComponent(rel).path)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func file(_ rel: String, bytes: Int = 0) throws -> URL {
        let u = url.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: u)
        return u
    }

    @discardableResult
    func dir(_ rel: String) throws -> URL {
        let u = url.appendingPathComponent(rel, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Symlink at `rel` whose stored target is `destination` verbatim (may be relative).
    @discardableResult
    func link(_ rel: String, to destination: String) throws -> URL {
        let u = url.appendingPathComponent(rel)
        try FileManager.default.createSymbolicLink(atPath: u.path, withDestinationPath: destination)
        return u
    }
}

/// Isolated UserDefaults suite; call `cleanup()` in `defer`.
///
/// Suites come from a small pool of fixed names, leased one per live
/// instance. A fresh UUID suite per test left an empty <suite>.plist behind in
/// ~/Library/Preferences on every run (cfprefsd writes it back after
/// removePersistentDomain, so deleting the file doesn't stick); reusing names
/// bounds that at one file per concurrently running test.
struct TestDefaults {
    let suite: String
    let defaults: UserDefaults
    private let slot: Int

    init() {
        slot = SuitePool.lease()
        suite = "SelwayCoreTests.defaults.\(slot)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)   // leftovers from a crashed run
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        SuitePool.giveBack(slot)
    }

    private enum SuitePool {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var inUse = Set<Int>()

        static func lease() -> Int {
            lock.lock(); defer { lock.unlock() }
            var n = 0
            while inUse.contains(n) { n += 1 }
            inUse.insert(n)
            return n
        }

        static func giveBack(_ n: Int) {
            lock.lock(); defer { lock.unlock() }
            inUse.remove(n)
        }
    }
}

/// Fixed clock for date-bucket tests: 2026-03-15 12:00 UTC, Gregorian, UTC.
enum TestClock {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static let now: Date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 12))!

    static func daysAgo(_ days: Int, hour: Int = 12) -> Date {
        let day = calendar.date(byAdding: .day, value: -days, to: now)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }
}

extension FileItem {
    /// In-memory item for sort / group tests (no disk access).
    static func fixture(_ name: String,
                        folder: Bool = false,
                        package: Bool = false,
                        size: Int64 = 0,
                        modified: Date = TestClock.now,
                        created: Date = TestClock.now,
                        kind: String? = nil,
                        tags: [String] = [],
                        labelNumber: Int = 0,
                        parent: String = "/fixture") -> FileItem {
        let url = URL(fileURLWithPath: parent).appendingPathComponent(name, isDirectory: folder)
        let ext = url.pathExtension.lowercased()
        return FileItem(
            id: url.path, url: url, name: name,
            isDirectory: folder || package, isPackage: package, isHidden: name.hasPrefix("."),
            size: size, dateModified: modified, dateCreated: created,
            kind: kind ?? (folder ? "Folder" : (ext.isEmpty ? "File" : "\(ext.uppercased()) File")),
            fileExtension: ext, labelNumber: labelNumber,
            tags: tags.map { FileTag(name: $0, color: FileItem.colorNameToLabel[$0.lowercased()] ?? 0) })
    }
}

#if os(macOS)
/// Runs command-line tools (hdiutil, mount_msdos, scripts) for tests.
enum TestTool {
    struct Result {
        let status: Int32
        /// Standard output only (so `-plist` output parses).
        let output: String
        let errors: String
        /// Both streams, for failure messages.
        var text: String { output + errors }
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }

    /// Runs a tool with stdin closed (or fed `input`), capturing stdout and stderr separately.
    /// Stderr is drained on its own thread so neither pipe can fill up and stall the tool.
    static func run(_ tool: String, _ arguments: [String], environment: [String: String]? = nil,
                    input: Data? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "", errors: error.localizedDescription)
        }
        if let stdin, let input {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        let errorBox = DataBox()
        let drained = DispatchSemaphore(value: 0)
        let errorReader = err.fileHandleForReading
        Thread.detachNewThread {
            errorBox.data = errorReader.readDataToEndOfFile()
            drained.signal()
        }
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      output: String(decoding: outputData, as: UTF8.self),
                      errors: String(decoding: errorBox.data, as: UTF8.self))
    }

    /// Detaches every device attached from `dmg` (found by image path in `hdiutil info`, so
    /// an APFS image's synthesized container goes too).
    static func detachImages(of dmg: URL) {
        let info = run("/usr/bin/hdiutil", ["info", "-plist"])
        guard info.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: Data(info.output.utf8), format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return }
        let wanted = dmg.resolvingSymlinksInPath().path
        for image in images {
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == wanted else { continue }
            let devices = (image["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["dev-entry"] as? String }
            let wholeDisks = devices.filter { !$0.dropFirst("/dev/disk".count).contains("s") }
            guard let device = wholeDisks.first ?? devices.first else { continue }
            if run("/usr/bin/hdiutil", ["detach", device, "-quiet"]).status != 0 {
                _ = run("/usr/bin/hdiutil", ["detach", device, "-force", "-quiet"])
            }
        }
    }
}
#endif
