import Foundation
import Testing
@testable import SelwayCore

@Test(arguments: [
    ("a.zip", FileOpsArchiveKind?.some(.zip)),
    ("A.ZIP", .zip),
    ("a.tar", .tar),
    ("a.tar.gz", .tar),
    ("a.tgz", .tar),
    ("a.tar.bz2", .tar),
    ("a.tar.xz", .tar),
    ("a.tbz", .tar),
    ("a.tbz2", .tar),
    ("a.txz", .tar),
    ("a.tzst", .tar),
    ("a.tar.zst", .tar),
    ("a.tar.lz", .tar),
    ("a.tar.lzma", .tar),
    ("a.tar.Z", .tar),
    ("a.gz", nil),          // not a tarball: handed to the default app
    ("a.7z", nil),
    ("a.dmg", nil),
    ("a.pkg", nil),
    ("a.rar", nil),
    ("a.bz2", nil),
])
func fileOpsArchiveKind(name: String, kind: FileOpsArchiveKind?) {
    #expect(FileOpsArchive.kind(forName: name) == kind)
}

@Test func fileOpsArchiveNames() {
    #expect(FileOpsArchive.extractedFolderName(forArchiveNamed: "a.tar.gz") == "a")
    #expect(FileOpsArchive.extractedFolderName(forArchiveNamed: "Photos 2024.zip") == "Photos 2024")
    #expect(FileOpsArchive.archiveName(for: [URL(fileURLWithPath: "/x/a.txt")]) == "a.txt.zip")
    #expect(FileOpsArchive.archiveName(for: [URL(fileURLWithPath: "/x/a"), URL(fileURLWithPath: "/x/b")]) == "Archive.zip")
}

/// Staging that holds read-only folders (as an archive can leave it) is
/// still removed completely.
@Test func fileOpsRemoveStagingHandlesReadOnlyTree() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let staging = try dir.dir("staging")
    try dir.file("staging/rx/inner.txt", bytes: 3)
    try dir.file("staging/xonly/f.txt", bytes: 3)
    try dir.file("staging/ro.txt", bytes: 3)
    let fm = FileManager.default
    try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: staging.appendingPathComponent("ro.txt").path)
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: staging.appendingPathComponent("rx").path)
    try fm.setAttributes([.posixPermissions: 0o111], ofItemAtPath: staging.appendingPathComponent("xonly").path)
    FileOpsArchive.removeStaging(staging, fileManager: fm)
    #expect(!fm.fileExists(atPath: staging.path))
}

#if os(macOS)

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selway-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func zipEntries(_ zip: URL) throws -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
    p.arguments = ["-1", zip.path]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}

/// Files named like zip options are archived as files and never interpreted.
/// The probe: with the old argv ("-r", dest, names…) zip would see "-T -TT python3"
/// and run `python3 <archive>`, which executes the archived __main__.py and
/// writes MARKER. Here MARKER must never appear.
@Test func fileOpsCompressTreatsDashNamesAsFiles() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("src")
    let marker = dir.appendingPathComponent("MARKER")
    let names = ["-T", "-TT", "python3", "__main__.py", "--help", "-@"]
    for name in names { try write("x", src.appendingPathComponent(name)) }
    try write("open(\(String(reflecting: marker.path)), 'w').write('ran')\n", src.appendingPathComponent("__main__.py"))

    let archive = try FileOpsArchive.compress(names.map { src.appendingPathComponent($0) })
    #expect(archive.lastPathComponent == "Archive.zip")
    #expect(archive.deletingLastPathComponent().path == src.path)
    #expect(Set(try zipEntries(archive)) == Set(names))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func fileOpsCompressHandlesSeveralParentFolders() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("one/a.txt"), b = dir.appendingPathComponent("two/sub/b.txt")
    try write("A", a); try write("B", b)
    try write("existing", dir.appendingPathComponent("one/Archive.zip"))

    let archive = try FileOpsArchive.compress([a, b])
    #expect(archive.lastPathComponent == "Archive 2.zip")
    #expect(Set(try zipEntries(archive)) == ["a.txt", "b.txt"])
    #expect(try String(contentsOf: dir.appendingPathComponent("one/Archive.zip"), encoding: .utf8) == "existing")
}

@Test func fileOpsCompressRefusesSameNameFromTwoFolders() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("one/same.txt"), b = dir.appendingPathComponent("two/SAME.txt")
    try write("1", a); try write("2", b)
    #expect(throws: FileOpsError.duplicateNames("SAME.txt")) { try FileOpsArchive.compress([a, b]) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("one").path) == ["same.txt"])
}

@Test func fileOpsCompressStoresSymlinksAsLinks() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let folder = dir.appendingPathComponent("folder")
    try write("x", folder.appendingPathComponent("f.txt"))
    try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("up").path,
                                               withDestinationPath: "..")
    let archive = try FileOpsArchive.compress([folder])
    #expect(archive.lastPathComponent == "folder.zip")
    let entries = try zipEntries(archive)
    #expect(entries.contains("folder/up"))
    #expect(!entries.contains { $0.hasPrefix("folder/up/") })
}

@Test func fileOpsExtractMultipleItemsIntoNewFolderWithoutOverwriting() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("src")
    try write("archived a", src.appendingPathComponent("a.txt"))
    try write("archived b", src.appendingPathComponent("b.txt"))
    let archive = try FileOpsArchive.compress([src.appendingPathComponent("a.txt"), src.appendingPathComponent("b.txt")])
    // Things already next to the archive that a naive "unzip -o" would clobber:
    // the edited original and an existing "Archive" folder.
    try write("edited", src.appendingPathComponent("a.txt"))
    try write("mine", src.appendingPathComponent("Archive/a.txt"))

    let out = try FileOpsArchive.extract(archive)
    #expect(out.lastPathComponent == "Archive 2")
    #expect(try String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8) == "archived a")
    #expect(try String(contentsOf: src.appendingPathComponent("a.txt"), encoding: .utf8) == "edited")
    #expect(try String(contentsOf: src.appendingPathComponent("Archive/a.txt"), encoding: .utf8) == "mine")
}

@Test func fileOpsExtractSingleItemGetsFreeName() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("src")
    let folder = src.appendingPathComponent("Folder.v2")
    try write("inside", folder.appendingPathComponent("f.txt"))
    let archive = try FileOpsArchive.compress([folder])

    let out = try FileOpsArchive.extract(archive)
    #expect(out.lastPathComponent == "Folder.v2 2")
    #expect(try String(contentsOf: out.appendingPathComponent("f.txt"), encoding: .utf8) == "inside")
    #expect(try String(contentsOf: folder.appendingPathComponent("f.txt"), encoding: .utf8) == "inside")
}

/// Extracting an app twice gives "Demo 2.app" (still a bundle), not
/// "Demo.app 2".
@Test func fileOpsExtractNumbersPackagesBeforeExtension() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let work = dir.appendingPathComponent("work"), downloads = dir.appendingPathComponent("downloads")
    try write("#!/bin/sh\n", work.appendingPathComponent("Demo.app/Contents/MacOS/Demo"))
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let archive = downloads.appendingPathComponent("demo.tgz")
    try FileOpsProcess.run("/usr/bin/tar", ["-c", "-z", "-f", archive.path, "Demo.app"], in: work)
    #expect(try FileOpsArchive.extract(archive).lastPathComponent == "Demo.app")
    #expect(try FileOpsArchive.extract(archive).lastPathComponent == "Demo 2.app")
}

/// Builds an archive whose entry is stored as "../escape.txt" (bsdtar's -s
/// rewrites the stored name), then checks extraction can't write beside the
/// archive's folder.
@Test(arguments: [("evil.zip", ["--format", "zip"]), ("evil.tar.gz", ["-z"])])
func fileOpsExtractContainsDotDotEntries(name: String, formatArgs: [String]) throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let work = dir.appendingPathComponent("work"), downloads = dir.appendingPathComponent("downloads")
    try write("escaped", work.appendingPathComponent("escape.txt"))
    try write("fine", work.appendingPathComponent("ok.txt"))
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let archive = downloads.appendingPathComponent(name)
    try FileOpsProcess.run("/usr/bin/tar", ["-c", "-f", archive.path] + formatArgs
                           + ["-s", ",^escape,../escape,", "escape.txt", "ok.txt"], in: work)

    _ = try? FileOpsArchive.extract(archive)   // ditto contains it, bsdtar refuses it
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("escape.txt").path))
    #expect(!FileManager.default.fileExists(atPath: downloads.appendingPathComponent("escape.txt").path))
    // Anything that did come out is inside the new folder, not loose in downloads.
    for item in try FileManager.default.contentsOfDirectory(atPath: downloads.path) {
        #expect(item == name || item == "evil")
    }
}

@Test func fileOpsExtractFailureReportsAndLeavesNothing() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let bogus = dir.appendingPathComponent("broken.tar.gz")
    try write("not really an archive", bogus)
    #expect(throws: FileOpsError.self) { try FileOpsArchive.extract(bogus) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["broken.tar.gz"])
}

/// Everything extracted carries exactly the archive's quarantine value, even
/// when the archive stores its own (here "user approved", 0x0040) values for
/// the items: bsdtar would restore those from pax headers, ditto from
/// __MACOSX, and they used to be kept because propagation skipped items that
/// already had a value.
/// An archive (in `dir`/downloads) holding Tool.app and README, each stored
/// with its own "user approved" (0x0040) quarantine value: bsdtar would
/// restore those from pax headers, ditto from __MACOSX.
private func plantedArchive(named name: String, in dir: URL) throws -> URL {
    let work = dir.appendingPathComponent("work"), downloads = dir.appendingPathComponent("downloads")
    let tool = work.appendingPathComponent("Tool.app/Contents/MacOS/Tool")
    try write("#!/bin/sh\n", tool)
    try write("readme", work.appendingPathComponent("README"))
    let planted = Data("0040;00000000;Attacker;".utf8)
    for rel in ["Tool.app", "Tool.app/Contents", "Tool.app/Contents/MacOS", "Tool.app/Contents/MacOS/Tool", "README"] {
        #expect(FileOpsQuarantine.set(planted, on: work.appendingPathComponent(rel)))
    }
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let archive = downloads.appendingPathComponent(name)
    if name.hasSuffix(".zip") {
        // --sequesterRsrc stores the xattrs in __MACOSX, which ditto -x restores.
        try FileOpsProcess.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", work.path, archive.path])
    } else {
        // bsdtar stores xattrs (SCHILY.xattr.*) by default in create mode.
        try FileOpsProcess.run("/usr/bin/tar", ["-c", "-z", "-f", archive.path, "Tool.app", "README"], in: work)
    }
    return archive
}

/// Every item in `out` (and `out` itself) carries exactly `expected`
/// (nil: no quarantine at all). Returns how many items were checked.
@discardableResult
private func expectQuarantine(_ expected: String?, under out: URL) -> Int {
    var checked = 1
    #expect(FileOpsQuarantine.value(of: out).map { String(decoding: $0, as: UTF8.self) } == expected)
    for case let url as URL in FileManager.default.enumerator(at: out, includingPropertiesForKeys: nil)! {
        let value = FileOpsQuarantine.value(of: url).map { String(decoding: $0, as: UTF8.self) }
        #expect(value == expected, "\(url.lastPathComponent) has \(value ?? "no quarantine")")
        checked += 1
    }
    return checked
}

/// Everything extracted carries exactly the archive's quarantine value, even
/// when the archive stores its own (here "user approved", 0x0040) values for
/// the items. They used to be kept because propagation skipped items that
/// already had a value.
@Test(arguments: ["q.zip", "q.tar.gz"])
func fileOpsExtractKeepsQuarantine(name: String) throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try plantedArchive(named: name, in: dir)
    #expect(FileOpsQuarantine.set(Data("0083;65000000;Safari;".utf8), on: archive))

    let out = try FileOpsArchive.extract(archive)
    #expect(expectQuarantine("0083;65000000;Safari;", under: out) >= 5)
    #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("__MACOSX").path))
}

/// Extract Here on a symlink to a quarantined archive (e.g. "open.zip" ->
/// "inner.zip", both from a downloaded zip: extraction marks inner.zip but
/// skips links) quarantines what comes out with the target's value. The link
/// itself carries no quarantine, and reading it instead of its target used to
/// skip propagation entirely, leaving the stored "user approved" values.
@Test(arguments: ["inner.zip", "inner.tar.gz"])
func fileOpsExtractThroughSymlinkUsesTargetsQuarantine(name: String) throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try plantedArchive(named: name, in: dir)
    #expect(FileOpsQuarantine.set(Data("0083;65000000;Safari;".utf8), on: archive))
    let linkName = name.replacingOccurrences(of: "inner", with: "open")
    let link = archive.deletingLastPathComponent().appendingPathComponent(linkName)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: name)

    let out = try FileOpsArchive.extract(link)
    #expect(out.deletingLastPathComponent().path == link.deletingLastPathComponent().path)
    #expect(expectQuarantine("0083;65000000;Safari;", under: out) >= 5)
}

/// Names starting with "._": Foundation's directory listings on Darwin leave out
/// regular files named like that, so propagation never saw them. With ditto's
/// --norsrc they are extracted as ordinary files, so a quarantined zip holding
/// Pkg/._Run.command (executable) and a link Pkg/Run.command -> ._Run.command
/// gave a script that opened without a Gatekeeper check. Every entry, orphan
/// "._" files and a "._X.app" bundle included, must get the archive's value.
///
/// bsdtar reads a "._" regular file as the AppleDouble metadata of the entry after
/// it unless an AppleDouble entry of its own comes first, which a Mac writes only
/// for files with extended attributes. So with `macMetadata` every planted item
/// gets one, as files made on a Mac usually have (com.apple.provenance, for one),
/// and the "._" files come out as files. Without it the tarball is like one made
/// on Linux, or on a Mac from files with no extended attributes.
private func appleDoubleNamedArchive(named name: String, in dir: URL, macMetadata: Bool = true) throws -> URL {
    let work = dir.appendingPathComponent("work"), downloads = dir.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let archive = downloads.appendingPathComponent(name)
    let zip = name.hasSuffix(".zip")
    // bsdtar won't archive "._" files from disk (it takes them for metadata), so for
    // tar they are written as "AD_…" and renamed to "._…" in the archive (-s).
    let p = zip ? "._" : "AD_"
    try write("#!/bin/sh\necho hi\n", work.appendingPathComponent("Pkg/\(p)Run.command"))
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: work.appendingPathComponent("Pkg/\(p)Run.command").path)
    try FileManager.default.createSymbolicLink(atPath: work.appendingPathComponent("Pkg/Run.command").path,
                                               withDestinationPath: "._Run.command")
    try write("o", work.appendingPathComponent("\(p)orphan"))
    try write("x", work.appendingPathComponent("\(p)X.app/Contents/MacOS/X"))
    try write("y", work.appendingPathComponent("\(p)X.app/Contents/\(p)y"))
    try write("r", work.appendingPathComponent("readme.txt"))
    if zip {
        // Info-ZIP stores "._" files as they are (-y: the link as a link).
        try FileOpsProcess.run("/usr/bin/zip", ["-r", "-y", "-q", archive.path, "--",
                                                "./Pkg", "./._orphan", "./._X.app", "./readme.txt"], in: work)
    } else {
        let items = ["Pkg", "AD_orphan", "AD_X.app", "readme.txt"]
        var options = ["-c", "-z", "-f", archive.path, "-s", ",AD_,._,g"]
        if macMetadata {
            for case let rel as String in FileManager.default.enumerator(atPath: work.path)! {
                let ok = setxattr(work.appendingPathComponent(rel).path, "org.example.selway-test",
                                  "1", 1, 0, XATTR_NOFOLLOW) == 0
                try #require(ok, "\(rel) has no extended attribute")
            }
        } else {
            options += ["--no-mac-metadata", "--no-xattrs"]
        }
        try FileOpsProcess.run("/usr/bin/tar", options + items, in: work)
    }
    #expect(FileOpsQuarantine.set(Data("0083;65000000;Safari;".utf8), on: archive))
    return archive
}

@Test(arguments: ["ad.zip", "ad.tgz"])
func fileOpsExtractMarksAppleDoubleNamedFiles(name: String) throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try appleDoubleNamedArchive(named: name, in: dir)
    let out = try FileOpsArchive.extract(archive)
    #expect(out.lastPathComponent == "ad")
    let expected = ["Pkg", "Pkg/._Run.command", "._orphan", "._X.app", "._X.app/Contents",
                    "._X.app/Contents/MacOS", "._X.app/Contents/MacOS/X", "._X.app/Contents/._y", "readme.txt"]
    for rel in [""] + expected {
        let url = rel.isEmpty ? out : out.appendingPathComponent(rel)
        let value = FileOpsQuarantine.value(of: url).map { String(decoding: $0, as: UTF8.self) }
        #expect(value == "0083;65000000;Safari;", "\(rel) has \(value ?? "no quarantine")")
    }
    // The link is extracted as a link (Gatekeeper checks the file it leads to).
    let link = try FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("Pkg/Run.command").path)
    #expect(link == "._Run.command")
}

/// The same "._" names in a tarball without Mac metadata: bsdtar takes the "._"
/// regular files for the metadata of the entries after them and doesn't extract
/// them (Selway restores no stored metadata), so only the "._X.app" folder keeps
/// its name. This pins that such a tarball extracts at all and that every item
/// that comes out (seven, links aside) carries the archive's quarantine; the
/// Mac-metadata case above covers quarantine on "._" files.
@Test func fileOpsExtractMarksATarballWithoutMacMetadata() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try appleDoubleNamedArchive(named: "ad.tgz", in: dir, macMetadata: false)
    let out = try FileOpsArchive.extract(archive)
    for rel in ["Pkg", "._X.app/Contents/MacOS/X", "readme.txt"] {
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent(rel).path), "\(rel) is missing")
    }
    var checked = 0
    func visit(_ url: URL, _ rel: String) throws {
        let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        if type == .typeSymbolicLink { return }
        let value = FileOpsQuarantine.value(of: url).map { String(decoding: $0, as: UTF8.self) }
        #expect(value == "0083;65000000;Safari;", "\(rel) has \(value ?? "no quarantine")")
        checked += 1
        if type == .typeDirectory {
            for name in try FileOpsDirectory.entries(atPath: url.path) {
                try visit(url.appendingPathComponent(name), rel.isEmpty ? name : rel + "/" + name)
            }
        }
    }
    try visit(out, "")
    #expect(checked == 7)
}

/// The unfiltered listing keeps "._" names that FileManager drops.
@Test func fileOpsDirectoryListingKeepsAppleDoubleNames() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    try dir.file("._a"); try dir.file("a"); try dir.dir("._B.app")
    #expect(try FileOpsDirectory.entries(atPath: dir.url.path).sorted() == ["._B.app", "._a", "a"])
    try dir.link("link", to: dir.url.path)
    #expect(throws: (any Error).self) { try FileOpsDirectory.entries(atPath: dir.url.appendingPathComponent("link").path) }
}

/// Quarantine values stored in the archive are never restored, even when the
/// archive itself isn't quarantined: ditto's __MACOSX metadata is dropped
/// like bsdtar's stored xattrs, and the __MACOSX folder isn't left behind.
@Test(arguments: ["plain.zip", "plain.tar.gz"])
func fileOpsExtractDropsStoredQuarantine(name: String) throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try plantedArchive(named: name, in: dir)
    let out = try FileOpsArchive.extract(archive)
    #expect(expectQuarantine(nil, under: out) >= 5)
    #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("__MACOSX").path))
}

/// Propagation fails closed: when the archive's quarantine can't be read
/// (anything but "there is none"), extraction stops instead of going on as if
/// the archive were not quarantined.
@Test func fileOpsQuarantineUnreadableArchiveFails() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let archive = try dir.file("locked.zip", bytes: 4)
    let root = try dir.dir("root")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: archive.path)
    #expect(throws: FileOpsError.quarantineUnreadable("locked.zip")) {
        try FileOpsQuarantine.propagate(from: archive, to: root, fileManager: .default)
    }
    #expect(throws: FileOpsError.quarantineUnreadable("locked.zip")) {
        try FileOpsArchive.extract(archive)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).sorted() == ["locked.zip", "root"])
    // "No quarantine" is not an error.
    let plain = try dir.file("plain.zip", bytes: 4)
    #expect(try FileOpsQuarantine.read(plain) == nil)
}

/// A link that leads nowhere is refused before anything runs.
@Test func fileOpsExtractBrokenSymlinkIsNotFound() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let link = try dir.link("gone.zip", to: "missing.zip")
    #expect(throws: FileOpsError.notFound("gone.zip")) { try FileOpsArchive.extract(link) }
}

/// A quarantined tarball whose entries are read-only: a 0444 file, a 0555
/// folder and a 0111 folder (searchable, not listable). Built from an mtree
/// spec so the modes don't depend on the disk.
private func readOnlyTarball(in dir: URL) throws -> URL {
    let work = dir.appendingPathComponent("work"), downloads = dir.appendingPathComponent("downloads")
    try write("hello\n", work.appendingPathComponent("content"))
    try write("""
        #mtree
        ./ro.txt type=file mode=0444 contents=content
        ./rx type=dir mode=0555
        ./rx/inner.txt type=file mode=0644 contents=content
        ./xonly type=dir mode=0111
        ./xonly/f.txt type=file mode=0644 contents=content

        """, work.appendingPathComponent("spec"))
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let archive = downloads.appendingPathComponent("ro.tgz")
    try FileOpsProcess.run("/usr/bin/tar", ["-c", "-z", "-f", archive.path, "@spec"], in: work)
    #expect(FileOpsQuarantine.set(Data("0083;65000000;Safari;".utf8), on: archive))
    return archive
}

private func mode(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

/// setxattr needs owner write, and walking a folder needs read + search: the
/// extraction opens each item just long enough and puts its mode back.
@Test func fileOpsExtractMarksReadOnlyItems() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let archive = try readOnlyTarball(in: dir.url)
    let out = try FileOpsArchive.extract(archive)
    #expect(out.lastPathComponent == "ro")
    #expect(mode(out.appendingPathComponent("ro.txt")) == 0o444)
    #expect(mode(out.appendingPathComponent("rx")) == 0o555)
    #expect(mode(out.appendingPathComponent("xonly")) == 0o111)
    // Reading an xattr needs read permission too.
    try FileManager.default.setAttributes([.posixPermissions: 0o511], ofItemAtPath: out.appendingPathComponent("xonly").path)
    let q = Data("0083;65000000;Safari;".utf8)
    for rel in ["", "ro.txt", "rx", "rx/inner.txt", "xonly", "xonly/f.txt"] {
        let url = rel.isEmpty ? out : out.appendingPathComponent(rel)
        #expect(FileOpsQuarantine.value(of: url) == q, "\(rel) not marked")
    }
}

/// If the quarantine can't be written the extraction stops, and nothing is
/// left behind: not next to the archive, and not in staging, even though
/// staging holds read-only folders whose children can't simply be removed.
@Test func fileOpsExtractQuarantineFailureAbortsAndCleansUp() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let archive = try readOnlyTarball(in: dir.url)
    let staging = try dir.dir("staging")
    #expect(throws: FileOpsError.self) {
        try FileOpsArchive.extract(archive, stagingIn: staging, markQuarantine: { _, _ in false })
    }
    do {
        try FileOpsArchive.extract(archive, stagingIn: staging, markQuarantine: { _, _ in false })
        Issue.record("extraction should have failed")
    } catch let FileOpsError.quarantineFailed(count) {
        #expect(count == 6)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: archive.deletingLastPathComponent().path) == ["ro.tgz"])
}

/// bsdtar never restores stored attributes or file flags.
@Test func fileOpsTarExtractOptionsDropStoredMetadata() {
    for flag in ["--no-xattrs", "--no-mac-metadata", "--no-fflags"] {
        #expect(FileOpsArchive.tarExtractOptions.contains(flag))
    }
}

/// ditto drops resource forks, extended attributes and quarantine stored in
/// the archive (the __MACOSX AppleDouble data); Selway sets the archive's
/// own quarantine itself.
@Test func fileOpsDittoExtractOptionsDropStoredMetadata() {
    #expect(FileOpsArchive.dittoExtractOptions == ["--norsrc", "--noextattr", "--noqtn", "--noacl"])
}

/// Names reach zip literally: wildcard matching off (-nw), after "--", and
/// as "./name" so a leading dash isn't an option. (macOS's zip doesn't expand
/// wildcards in plain arguments today, so -nw is pinned by argv.)
@Test func fileOpsZipArgumentsAreLiteral() {
    let args = FileOpsArchive.zipArguments(archive: URL(fileURLWithPath: "/t/A.zip"), names: ["*.txt", "-T"])
    #expect(args == ["-r", "-y", "-q", "-nw", "/t/A.zip", "--", "./*.txt", "./-T"])
}

/// A name with wildcard characters is archived as itself.
@Test func fileOpsCompressTakesNamesLiterally() throws {
    let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let star = dir.appendingPathComponent("src/*.txt"), bracket = dir.appendingPathComponent("src/[ab].txt")
    try write("star", star); try write("bracket", bracket)
    try write("a", dir.appendingPathComponent("src/a.txt"))
    let archive = try FileOpsArchive.compress([star, bracket])
    #expect(Set(try zipEntries(archive)) == ["*.txt", "[ab].txt"])
}

@Test func fileOpsCancelTerminatesRunningTool() throws {
    let token = FileOpsCancellationToken()
    // A dedicated thread, not the shared GCD pool: under a busy pool (e.g. a parallel
    // build) asyncAfter fired seconds late and tripped the 5 s bound.
    Thread.detachNewThread { usleep(200_000); token.cancel() }
    let start = Date()
    #expect(throws: FileOpsError.cancelled) { try FileOpsProcess.run("/bin/sleep", ["10"], token: token) }
    #expect(Date().timeIntervalSince(start) < 5)
}

@Test func fileOpsToolFailureCarriesExitStatus() {
    #expect(throws: FileOpsError.toolFailed(tool: "false", status: 1, output: "")) {
        try FileOpsProcess.run("/usr/bin/false", [])
    }
}

#endif
