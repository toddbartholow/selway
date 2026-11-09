import Foundation
import Testing
@testable import SelwayCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TextFileTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func bytes(_ values: [UInt8]) -> Data { Data(values) }

private func binaryPlist() throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: ["key": "value", "n": 42],
                                       format: .binary, options: 0)
}

/// Samples whose encoding, BOM and line endings must survive decode → encode unchanged.
private let roundTripSamples: [(name: String, data: Data, encoding: String.Encoding, bom: Bool, ending: TextLineEnding)] = [
    ("empty", Data(), .utf8, false, .lf),
    ("utf8 lf", Data("héllo\nwörld\n".utf8), .utf8, false, .lf),
    ("utf8 no trailing newline", Data("one line".utf8), .utf8, false, .lf),
    ("utf8 crlf", Data("a\r\nb\r\n".utf8), .utf8, false, .crlf),
    ("utf8 cr", Data("a\rb\r".utf8), .utf8, false, .cr),
    ("utf8 bom", bytes([0xEF, 0xBB, 0xBF]) + Data("x = 1\n".utf8), .utf8, true, .lf),
    ("emoji", Data("👩‍💻 done\n".utf8), .utf8, false, .lf),
    ("latin1", bytes([0x63, 0x61, 0x66, 0xE9, 0x0A, 0xFC, 0x62, 0x65, 0x72, 0x0A]), .isoLatin1, false, .lf),
    ("latin1 crlf", bytes([0x6E, 0x61, 0xEF, 0x76, 0x65, 0x0D, 0x0A]), .isoLatin1, false, .crlf),
    ("utf16le bom crlf", bytes([0xFF, 0xFE]) + "line1\r\nlïne2\r\n".data(using: .utf16LittleEndian)!,
     .utf16LittleEndian, true, .crlf),
    ("utf16be bom", bytes([0xFE, 0xFF]) + "hello\nwörld\n".data(using: .utf16BigEndian)!,
     .utf16BigEndian, true, .lf),
    ("utf32le bom", bytes([0xFF, 0xFE, 0x00, 0x00]) + "abc\n".data(using: .utf32LittleEndian)!,
     .utf32LittleEndian, true, .lf),
]

// MARK: - Codec

@Test(arguments: roundTripSamples.map { $0.name })
func codecRoundTripsBytes(name: String) throws {
    let sample = roundTripSamples.first { $0.name == name }!
    let (text, format) = try TextFileCodec.decode(sample.data)
    #expect(format.encoding == sample.encoding)
    #expect(format.hasBOM == sample.bom)
    #expect(format.lineEnding == sample.ending)
    #expect(!text.contains("\r"), "editor buffers are LF-only")
    #expect(try TextFileCodec.encode(text, as: format) == sample.data)
}

@Test func codecDecodesUTF16Content() throws {
    let data = bytes([0xFE, 0xFF]) + "wörld\r\n".data(using: .utf16BigEndian)!
    let (text, format) = try TextFileCodec.decode(data)
    #expect(text == "wörld\n")
    #expect(format.lineEnding == .crlf)
}

@Test func codecRestoresLineEndingsAfterEdit() throws {
    let (text, format) = try TextFileCodec.decode(Data("a\r\nb\r\n".utf8))
    let edited = text + "c\n"
    #expect(try TextFileCodec.encode(edited, as: format) == Data("a\r\nb\r\nc\r\n".utf8))
    // Pasted CRLF/CR text is normalised to the file's terminator too.
    #expect(try TextFileCodec.encode("x\r\ny\rz", as: format) == Data("x\r\ny\r\nz".utf8))
}

@Test func codecReportsMixedLineEndings() throws {
    let (text, format) = try TextFileCodec.decode(Data("a\r\nb\r\nc\nd\r\n".utf8))
    #expect(format.lineEnding == .crlf)
    #expect(format.hadMixedLineEndings)
    #expect(text == "a\nb\nc\nd\n")
}

@Test(arguments: [
    ("NUL bytes", Data([0x41, 0x00, 0x42, 0x43])),
    ("control bytes", Data([UInt8](repeating: 0x01, count: 40) + Array("text".utf8))),
    ("bplist magic", Data("bplist00 looks like text".utf8)),
])
func codecRefusesBinary(name: String, data: Data) {
    #expect(throws: TextFileCodecError.binary) { try TextFileCodec.decode(data) }
}

@Test func codecRefusesRealBinaryPlist() throws {
    #expect(throws: TextFileCodecError.binary) { try TextFileCodec.decode(try binaryPlist()) }
}

@Test func codecRefusesBrokenUTF16() {
    // BOM followed by an odd number of bytes can't be UTF-16.
    let data = bytes([0xFF, 0xFE, 0x41, 0x00, 0x42])
    #expect(throws: TextFileCodecError.undecodable) { try TextFileCodec.decode(data) }
}

@Test func codecRefusesUnencodableEdits() throws {
    let (_, format) = try TextFileCodec.decode(bytes([0x63, 0x61, 0x66, 0xE9]))
    #expect(format.encoding == .isoLatin1)
    #expect(throws: TextFileCodecError.unencodable(.isoLatin1)) {
        try TextFileCodec.encode("price: €5", as: format)
    }
}

/// Windows-1252 text (curly quotes, €, em dash in 0x80–0x9F) used to be read as
/// Latin-1, which turned those bytes into invisible C1 controls, and "Save as
/// UTF-8" then wrote the controls.
@Test func codecReadsWindows1252Punctuation() throws {
    // “Hi” €5 — ok
    let data = bytes([0x93, 0x48, 0x69, 0x94, 0x20, 0x80, 0x35, 0x20, 0x97, 0x20, 0x6F, 0x6B, 0x0D, 0x0A])
    let (text, format) = try TextFileCodec.decode(data)
    #expect(format.encoding == .windowsCP1252)
    #expect(format.lineEnding == .crlf)
    #expect(text == "\u{201C}Hi\u{201D} \u{20AC}5 \u{2014} ok\n")
    #expect(try TextFileCodec.encode(text, as: format) == data, "unedited save is byte-identical")
    var utf8 = format
    utf8.encoding = .utf8
    #expect(try TextFileCodec.encode(text, as: utf8) == Data("\u{201C}Hi\u{201D} \u{20AC}5 \u{2014} ok\r\n".utf8))
}

@Test func codecFallsBackToMacRomanForBytesWindows1252LacksAndLatin1Otherwise() throws {
    // 0x8D is undefined in Windows-1252; in Mac OS Roman it is ç.
    let mac = bytes([0x46, 0x72, 0x61, 0x6E, 0x8D, 0x61, 0x69, 0x73, 0x0A])
    let (macText, macFormat) = try TextFileCodec.decode(mac)
    #expect(try TextFileCodec.encode(macText, as: macFormat) == mac)
    #if canImport(Darwin)   // corelibs Foundation's Mac OS Roman tables differ
    #expect(macFormat.encoding == .macOSRoman)
    #expect(macText == "Français\n")
    #endif
    // No 0x80–0x9F bytes: plain Latin-1, as before.
    let (_, latin) = try TextFileCodec.decode(bytes([0x63, 0x61, 0x66, 0xE9]))
    #expect(latin.encoding == .isoLatin1)
}

@Test(arguments: [
    ("", TextLineEnding.lf, false),
    ("a\nb", .lf, false),
    ("a\r\nb\r\n", .crlf, false),
    ("a\rb", .cr, false),
    ("a\nb\r\nc\r\n", .crlf, true),
    ("a\nb\nc\r\n", .lf, true),
])
func lineEndingDetection(text: String, ending: TextLineEnding, mixed: Bool) {
    let result = TextFileCodec.detectLineEnding(in: text)
    #expect(result.0 == ending)
    #expect(result.mixed == mixed)
}

// MARK: - Load / save on disk

@Test(arguments: roundTripSamples.map { $0.name })
func uneditedFileSavesByteForByte(name: String) throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let sample = roundTripSamples.first { $0.name == name }!
    let url = dir.appendingPathComponent("file.txt")
    try sample.data.write(to: url)

    let loaded = try TextFileIO.load(url)
    try TextFileIO.save(loaded.text, format: loaded.format, to: loaded.resolvedURL, expected: loaded.snapshot)
    #expect(try Data(contentsOf: url) == sample.data)
}

@Test func loadRefusesBinaryPlistFile() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("Info.plist")
    let original = try binaryPlist()
    try original.write(to: url)
    #expect(throws: TextFileIOError.binary) { try TextFileIO.load(url) }
    #expect(try Data(contentsOf: url) == original)
}

@Test func loadRefusesDirectory() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: TextFileIOError.notRegularFile) { try TextFileIO.load(dir) }
}

@Test func saveThroughSymlinkUpdatesTargetAndKeepsLink() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    let target = dir.appendingPathComponent("real.txt")
    let link = dir.appendingPathComponent("link.txt")
    try Data("old\n".utf8).write(to: target)
    try fm.createSymbolicLink(at: link, withDestinationURL: target)

    let loaded = try TextFileIO.load(link)
    try TextFileIO.save("new\n", format: loaded.format, to: loaded.resolvedURL, expected: loaded.snapshot)

    #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == target.path)
    #expect(try String(contentsOf: target, encoding: .utf8) == "new\n")
    #expect(try String(contentsOf: link, encoding: .utf8) == "new\n")
}

@Test func saveThroughRelativeSymlinkInLinkedFolder() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    let realDir = dir.appendingPathComponent("real", isDirectory: true)
    try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
    try Data("v1".utf8).write(to: realDir.appendingPathComponent("notes.txt"))
    try fm.createSymbolicLink(atPath: realDir.appendingPathComponent("alias.txt").path,
                              withDestinationPath: "notes.txt")
    try fm.createSymbolicLink(at: dir.appendingPathComponent("linked"), withDestinationURL: realDir)

    let viaLinks = dir.appendingPathComponent("linked/alias.txt")
    let loaded = try TextFileIO.load(viaLinks)
    try TextFileIO.save("v2", format: loaded.format, to: loaded.resolvedURL, expected: loaded.snapshot)

    #expect(try fm.destinationOfSymbolicLink(atPath: realDir.appendingPathComponent("alias.txt").path) == "notes.txt")
    #expect(try String(contentsOf: realDir.appendingPathComponent("notes.txt"), encoding: .utf8) == "v2")
    #expect(TextFileIO.isSameFile(viaLinks, realDir.appendingPathComponent("notes.txt")))
}

@Test func saveDetectsExternalChange() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("a.txt")
    try Data("mine\n".utf8).write(to: url)
    let loaded = try TextFileIO.load(url)

    try Data("theirs, longer\n".utf8).write(to: url, options: .atomic)
    #expect(TextFileIO.hasChanged(url, since: loaded.snapshot))
    #expect(throws: TextFileIOError.changedOnDisk) {
        try TextFileIO.save("edited\n", format: loaded.format, to: loaded.resolvedURL, expected: loaded.snapshot)
    }
    #expect(try String(contentsOf: url, encoding: .utf8) == "theirs, longer\n")

    let snap = try TextFileIO.save("edited\n", format: loaded.format, to: loaded.resolvedURL,
                                   expected: loaded.snapshot, force: true)
    #expect(try String(contentsOf: url, encoding: .utf8) == "edited\n")
    #expect(!TextFileIO.hasChanged(url, since: snap))
}

@Test func saveDetectsDeletedFile() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("gone.txt")
    try Data("x".utf8).write(to: url)
    let loaded = try TextFileIO.load(url)
    try FileManager.default.removeItem(at: url)
    #expect(throws: TextFileIOError.changedOnDisk) {
        try TextFileIO.save("y", format: loaded.format, to: loaded.resolvedURL, expected: loaded.snapshot)
    }
}

@Test(.enabled(if: getuid() != 0, "root can write mode-444 files")) func saveRefusesReadOnlyFile() throws {
    let dir = try makeTempDir()
    let fm = FileManager.default
    let url = dir.appendingPathComponent("ro.txt")
    defer {
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try? fm.removeItem(at: dir)
    }
    try Data("keep".utf8).write(to: url)
    try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
    let loaded = try TextFileIO.load(url)
    #expect(throws: TextFileIOError.notWritable) {
        try TextFileIO.save("lost", format: loaded.format, to: loaded.resolvedURL, expected: loaded.snapshot)
    }
    #expect(try String(contentsOf: url, encoding: .utf8) == "keep")
}

@Test func saveRefusesUnencodableText() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("legacy.txt")
    let original = bytes([0x63, 0x61, 0x66, 0xE9])
    try original.write(to: url)
    let loaded = try TextFileIO.load(url)
    #expect(throws: TextFileIOError.unencodable(encodingName: "ISO Latin-1")) {
        try TextFileIO.save("café €", format: loaded.format, to: loaded.resolvedURL, expected: loaded.snapshot)
    }
    #expect(try Data(contentsOf: url) == original)
}

@Test func hardLinksAreTheSameFile() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.txt")
    let b = dir.appendingPathComponent("b.txt")
    try Data("x".utf8).write(to: a)
    try FileManager.default.linkItem(at: a, to: b)
    #expect(TextFileIO.isSameFile(a, b))
    #expect(!TextFileIO.isSameFile(a, dir.appendingPathComponent("missing.txt")))
}

// MARK: - Detector

@Test func detectorSniffsPlists() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let binary = dir.appendingPathComponent("bin.plist")
    try binaryPlist().write(to: binary)
    let xml = dir.appendingPathComponent("xml.plist")
    try PropertyListSerialization.data(fromPropertyList: ["k": "v"], format: .xml, options: 0).write(to: xml)

    // Plists are sniffed even when sniffing unknown types is off.
    #expect(!TextFileDetector.isEditableText(binary, sniffUnknown: false))
    #expect(TextFileDetector.isEditableText(xml, sniffUnknown: false))
    #expect(!TextFileDetector.knownTextExtensions.contains("plist"))
}

@Test(arguments: [true, false])
func detectorHonoursSniffSetting(sniff: Bool) throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let unknown = dir.appendingPathComponent("notes.weird")
    try Data("plain text".utf8).write(to: unknown)
    let known = dir.appendingPathComponent("code.swift")
    try Data("let x = 1".utf8).write(to: known)
    let binary = dir.appendingPathComponent("blob.weird")
    try Data([0x00, 0x01, 0x02]).write(to: binary)

    #expect(TextFileDetector.isEditableText(unknown, sniffUnknown: sniff) == sniff)
    #expect(TextFileDetector.isEditableText(known, sniffUnknown: sniff))
    #expect(!TextFileDetector.isEditableText(binary, sniffUnknown: sniff))
}

@Test func detectorTreatsUTF16AsText() {
    let data = bytes([0xFF, 0xFE]) + "hi".data(using: .utf16LittleEndian)!
    #expect(TextFileDetector.sniffIsText(data))
}

/// A FIFO swapped in after the type check (an attacker looping
/// rename-swaps between a file and a FIFO in a shared folder) must not block
/// the sniff: it used to hang in open(2), on the main thread.
@Test func detectorSniffSurvivesFIFOSwappedInAfterCheck() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("swap.weird")
    try Data("plain text".utf8).write(to: file)
    let done = DispatchSemaphore(value: 0)
    let result = LockedBox<Bool?>(nil)
    // Its own thread: under a parallel test run the shared GCD pool can be busy for
    // seconds, which would look like a hang.
    Thread.detachNewThread {
        let isText = TextFileDetector.sniffIsText(file, beforeOpen: { url in
            try? FileManager.default.removeItem(at: url)
            _ = mkfifo(url.path, 0o600)
        })
        result.value = isText
        done.signal()
    }
    let finished = done.wait(timeout: .now() + 3) == .success
    if !finished {
        // Release the blocked open so the thread can finish.
        let w = open(file.path, O_WRONLY | O_NONBLOCK)
        if w >= 0 { close(w) }
        _ = done.wait(timeout: .now() + 3)
    }
    #expect(finished, "sniff blocked on a FIFO")
    #expect(result.value == false)
}

/// Loading checks the type before opening: a link like x.txt -> /dev/cu.* must
/// not open the device (that can reset the board on a serial port). Observed
/// through a FIFO: a writer blocked in open(2) is released only if someone
/// opens the FIFO for reading.
@Test func loadDoesNotOpenNonRegularTarget() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fifo = dir.appendingPathComponent("pipe")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    let link = dir.appendingPathComponent("x.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)
    let writerOpened = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        let w = open(fifo.path, O_WRONLY)   // blocks until a reader opens
        if w >= 0 { close(w) }
        writerOpened.signal()
    }
    Thread.sleep(forTimeInterval: 0.2)      // let the writer block
    #expect(throws: TextFileIOError.notRegularFile) { try TextFileIO.load(link) }
    #expect(throws: TextFileIOError.notRegularFile) { try TextFileIO.load(fifo) }
    #expect(writerOpened.wait(timeout: .now() + 0.5) == .timedOut, "the FIFO was opened")
    // Release the writer.
    let r = open(fifo.path, O_RDONLY | O_NONBLOCK)
    _ = writerOpened.wait(timeout: .now() + 3)
    if r >= 0 { close(r) }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

@Test func detectorDoesNotOpenFIFOs() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fifo = dir.appendingPathComponent("pipe.weird")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(!TextFileDetector.isEditableText(fifo, sniffUnknown: true))
    #expect(throws: TextFileIOError.notRegularFile) { try TextFileIO.load(fifo) }
}
