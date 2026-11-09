import Foundation
import Testing
@testable import SelwayCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Local images in the Markdown reader (Core/MarkdownLocalImages.swift): how image
// references resolve against the document's folder, the selwayimg: URLs the page loads
// them from, and what the reader's scheme handler agrees to serve.

private let notes = URL(fileURLWithPath: "/Users/me/Notes")

/// The smallest valid PNG: 1×1, transparent.
private let png = Data([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
])

// MARK: - Resolving references

@Test(arguments: [
    ("pic.png",                    "/Users/me/Notes/pic.png"),
    ("Docs/pic.png",               "/Users/me/Notes/Docs/pic.png"),
    ("./Docs/../pic.png",          "/Users/me/Notes/pic.png"),
    ("../img/a.png",               "/Users/me/img/a.png"),
    ("../../../../../../x.png",    "/x.png"),
    ("/Volumes/Shared/p.png",      "/Volumes/Shared/p.png"),
    ("file:///tmp/b.png",          "/tmp/b.png"),
    ("file://localhost/tmp/b.png", "/tmp/b.png"),
    ("my%20pic.png",               "/Users/me/Notes/my pic.png"),
    ("pic.png?raw=1#top",          "/Users/me/Notes/pic.png"),
    ("100%.png",                   "/Users/me/Notes/100%.png"),
    ("Docs//pic.png",              "/Users/me/Notes/Docs/pic.png"),
])
func imageReferencesResolveAgainstTheDocumentsFolder(reference: String, path: String) {
    #expect(MarkdownLocalImages.resolve(reference, relativeTo: notes)?.path == path)
}

@Test(arguments: [
    "https://example.com/a.png", "http://example.com/a.png", "//cdn.example.com/a.png",
    "#top", "", "   ", "?q=1", "mailto:me@example.com", "data:image/png;base64,AAAA",
    "file://server/share/a.png", "x-other:a.png", "pic%00.png", "../../../../../..",
])
func otherReferencesNameNoLocalImage(reference: String) {
    #expect(MarkdownLocalImages.resolve(reference, relativeTo: notes) == nil)
}

// MARK: - Page URLs

@Test(arguments: [
    "/Users/me/Notes/Docs/pic.png", "/Users/me/my pic.png", "/tmp/a\"b<c>&d'e.png",
    "/tmp/100% #1?.png", "/tmp/Résumé 📷.png", "/tmp/semi;colon,comma.png",
])
func pageURLsRoundTripAndStayInert(path: String) throws {
    let page = MarkdownLocalImages.pageURL(for: URL(fileURLWithPath: path))
    #expect(page.hasPrefix("selwayimg://local/"))
    let rest = page.dropFirst("selwayimg://local".count)
    #expect(rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/-._~%".contains($0)) }, "\(page)")
    let url = try #require(URL(string: page))
    #expect(MarkdownLocalImages.file(forPageURL: url)?.path == path)
}

@Test(arguments: [
    "file:///tmp/a.png", "selwayimg://other/tmp/a.png", "selwayimg://local/tmp/../etc/a.png",
    "selwayimg://local/tmp/./a.png", "selwayimg://local/", "selwayimg://local/a.png?x=1", "selwayimg://local/a.png#f",
    "selwayimg://local/a%00.png", "https://local/tmp/a.png",
])
func onlyPageURLsTheRendererMakesNameAFile(url: String) throws {
    #expect(MarkdownLocalImages.file(forPageURL: try #require(URL(string: url))) == nil)
}

// MARK: - Serving

@Test func servesAReferencedImageNextToTheDocument() throws {
    let dir = try TempDir()
    defer { dir.cleanup() }
    let pic = dir.url.appendingPathComponent("Docs/pic.png")
    try FileManager.default.createDirectory(at: pic.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: pic)
    let file = try #require(MarkdownLocalImages.resolve("Docs/pic.png", relativeTo: dir.url))
    let served = try MarkdownImageLoader(allowedPaths: [file.path]).loadNow(file)
    #expect(served.data == png)
    #expect(served.mimeType == "image/png")
}

@Test func refusesWhatTheDocumentDidNotReference() throws {
    let dir = try TempDir()
    defer { dir.cleanup() }
    let pic = dir.url.appendingPathComponent("pic.png")
    try png.write(to: pic)
    #expect(throws: MarkdownLocalImages.LoadError.notReferenced) {
        try MarkdownImageLoader(allowedPaths: []).loadNow(pic)
    }
    #expect(throws: MarkdownLocalImages.LoadError.notReferenced) {
        try MarkdownImageLoader(allowedPaths: [dir.url.appendingPathComponent("other.png").path]).loadNow(pic)
    }
}

@Test func refusesFilesThatAreNotImages() throws {
    let dir = try TempDir()
    defer { dir.cleanup() }
    let fm = FileManager.default
    let secret = dir.url.appendingPathComponent("id_ed25519")
    try Data("-----BEGIN OPENSSH PRIVATE KEY-----\n".utf8).write(to: secret)
    let text = dir.url.appendingPathComponent("notes.txt")
    try Data("hello".utf8).write(to: text)
    // A key renamed or linked as an image, text named .png, a folder and a FIFO.
    let fake = dir.url.appendingPathComponent("fake.png")
    try Data("-----BEGIN OPENSSH PRIVATE KEY-----\n".utf8).write(to: fake)
    let linkToKey = dir.url.appendingPathComponent("key.png")
    try fm.createSymbolicLink(atPath: linkToKey.path, withDestinationPath: secret.path)
    let linkToText = dir.url.appendingPathComponent("text.png")
    try fm.createSymbolicLink(atPath: linkToText.path, withDestinationPath: "notes.txt")
    let folder = dir.url.appendingPathComponent("folder.png")
    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
    let fifo = dir.url.appendingPathComponent("pipe.png")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    let missing = dir.url.appendingPathComponent("missing.png")

    let cases: [(URL, MarkdownLocalImages.LoadError)] = [
        (secret, .notAnImageName), (text, .notAnImageName), (fake, .notAnImage),
        (linkToKey, .notAnImageName), (linkToText, .notAnImageName),
        (folder, .notRegularFile), (fifo, .notRegularFile), (missing, .notFound),
    ]
    for (file, error) in cases {
        #expect(throws: error, "\(file.lastPathComponent)") {
            try MarkdownImageLoader(allowedPaths: [file.path]).loadNow(file)
        }
    }
}

@Test func followsLinksToImagesAndCapsTheSize() throws {
    let dir = try TempDir()
    defer { dir.cleanup() }
    let real = dir.url.appendingPathComponent("assets/real.png")
    try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: real)
    let link = dir.url.appendingPathComponent("doc/pic.png")
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../assets/real.png")
    #expect(try MarkdownImageLoader(allowedPaths: [link.path]).loadNow(link).data == png)

    #expect(throws: MarkdownLocalImages.LoadError.tooLarge) {
        try MarkdownImageLoader(allowedPaths: [real.path], maxBytesPerImage: png.count - 1).loadNow(real)
    }
    #expect(try MarkdownImageLoader(allowedPaths: [real.path], maxBytesPerImage: png.count).loadNow(real).data == png)
}

@Test func recognisesImageFormatsByContent() {
    func type(_ bytes: [UInt8]) -> String? { MarkdownLocalImages.imageType(of: Data(bytes)) }
    #expect(type([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]) == "image/jpeg")
    #expect(type(Array("GIF89a....".utf8)) == "image/gif")
    #expect(type(Array("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)) == "image/webp")
    #expect(type([0, 0, 0, 0x18] + Array("ftypheic".utf8) + [0, 0, 0, 0]) == "image/heic")
    #expect(type([0, 0, 0, 0x18] + Array("ftypavif".utf8) + [0, 0, 0, 0]) == "image/avif")
    #expect(type([0, 0, 0, 0x18] + Array("ftypisom".utf8) + [0, 0, 0, 0]) == nil, "an MP4 isn't an image")
    #expect(type(Array("<?xml version=\"1.0\"?>\n<!-- x -->\n<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8))
            == "image/svg+xml")
    #expect(type(Array("<html><body><svg/></body></html>".utf8)) == nil)
    #expect(type(Array("hello".utf8)) == nil)
    #expect(type([]) == nil)
}

// MARK: - Limits: one small document can't make the reader read gigabytes

/// Spellings of one file: through a link to its own folder (`l -> .`), and in
/// other letter cases where the volume ignores case. Each is a different
/// reference, but the file is read from disk once per rendering.
@Test func eachFileIsReadOncePerRenderingHoweverItIsSpelled() throws {
    let dir = try TempDir()
    defer { dir.cleanup() }
    try png.write(to: dir.url.appendingPathComponent("big.png"))
    try FileManager.default.createSymbolicLink(atPath: dir.url.appendingPathComponent("l").path,
                                               withDestinationPath: ".")
    var spellings = (0..<30).map { n in
        dir.url.appendingPathComponent(String(repeating: "l/", count: n) + "big.png")
    }
    if FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("BIG.png").path) {
        spellings += ["BIG.png", "Big.png", "bIG.PNG", "BiG.pNg"].map { dir.url.appendingPathComponent($0) }
    }
    let loader = MarkdownImageLoader(allowedPaths: Set(spellings.map(\.path)))
    for file in spellings {
        #expect(try loader.loadNow(file).data == png, "\(file.path)")
    }
    #expect(loader.diskReads == 1)
}

@Test func servingStopsAtTheDocumentsByteBudget() throws {
    let dir = try TempDir()
    defer { dir.cleanup() }
    let a = dir.url.appendingPathComponent("a.png"), b = dir.url.appendingPathComponent("b.png")
    try png.write(to: a)
    try png.write(to: b)
    let c = dir.url.appendingPathComponent("c.png")
    try png.write(to: c)
    let loader = MarkdownImageLoader(allowedPaths: [a.path, b.path, c.path], maxBytesPerDocument: png.count * 2)
    _ = try loader.loadNow(a)
    _ = try loader.loadNow(b)
    #expect(throws: MarkdownLocalImages.LoadError.documentBudgetExceeded) { try loader.loadNow(c) }
    #expect(loader.diskReads == 2, "nothing is read once the budget is spent")
}

/// Reads still queued when WebKit stopped their request, or when a newer rendering
/// replaced the loader, are skipped instead of reading (up to the budget) for a page
/// that is gone.
@Test func queuedReadsForStoppedRequestsOrOldRenderingsAreSkipped() throws {
    let dir = try TempDir()
    defer { dir.cleanup() }
    let a = dir.url.appendingPathComponent("a.png")
    try png.write(to: a)
    let queue = DispatchQueue(label: "test.images")
    let loader = MarkdownImageLoader(allowedPaths: [a.path], queue: queue)
    let results = LockedResults()
    let done = DispatchGroup()
    queue.suspend()
    done.enter()
    loader.load(a, isWanted: { false }) { results.add($0); done.leave() }   // WebKit stopped it
    done.enter()
    loader.load(a) { results.add($0); done.leave() }
    loader.cancel()                                                         // a newer rendering
    queue.resume()
    #expect(done.wait(timeout: .now() + 5) == .success)
    #expect(results.cancelledCount == 2)
    #expect(loader.diskReads == 0)
}

private final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Result<MarkdownImageLoader.Image, Error>] = []
    func add(_ r: Result<MarkdownImageLoader.Image, Error>) { lock.lock(); all.append(r); lock.unlock() }
    var cancelledCount: Int {
        lock.lock(); defer { lock.unlock() }
        return all.filter {
            if case .failure(let e) = $0 { return (e as? MarkdownLocalImages.LoadError) == .cancelled }
            return false
        }.count
    }
}

/// WebKit fetches an image again during one rendering (scrolling back, memory
/// pressure); serving the cached bytes again costs nothing, so a long session
/// doesn't lose its images to the budget.
@Test func servingACachedImageAgainDoesNotSpendTheBudget() throws {
    let dir = try TempDir()
    defer { dir.cleanup() }
    let a = dir.url.appendingPathComponent("a.png"), b = dir.url.appendingPathComponent("b.png")
    try png.write(to: a)
    try png.write(to: b)
    let loader = MarkdownImageLoader(allowedPaths: [a.path, b.path], maxBytesPerDocument: png.count * 2)
    for _ in 0..<10 { #expect(try loader.loadNow(a).data == png) }
    #expect(try loader.loadNow(b).data == png)
    #expect(try loader.loadNow(a).data == png)
    #expect(loader.diskReads == 2)
}

/// A FIFO, device or socket named like an image is refused while the path is
/// walked (from the lstat already done), before anything opens it: opening a
/// device can have side effects even when nothing is read.
@Test func specialFilesAreRefusedBeforeOpening() throws {
    let dir = try TempDir()
    defer { dir.cleanup() }
    let fifo = dir.url.appendingPathComponent("pipe.png")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(throws: MarkdownLocalImages.LoadError.notRegularFile) {
        try MarkdownImageLoader.resolveLocally(fifo.path)
    }
    // Through a link too (the walk reaches the device itself).
    let device = dir.url.appendingPathComponent("null.png")
    try FileManager.default.createSymbolicLink(atPath: device.path, withDestinationPath: "/dev/null")
    #expect(throws: MarkdownLocalImages.LoadError.notRegularFile) {
        try MarkdownImageLoader.resolveLocally(device.path)
    }
    let loader = MarkdownImageLoader(allowedPaths: [fifo.path, device.path])
    var opened: [String] = []
    loader.beforeOpen = { opened.append($0) }
    #expect(throws: MarkdownLocalImages.LoadError.notRegularFile) { try loader.loadNow(fifo) }
    #expect(throws: MarkdownLocalImages.LoadError.notRegularFile) { try loader.loadNow(device) }
    #expect(opened.isEmpty)
}

#if os(macOS)
/// A folder on the resolved path swapped for a link after the walk checked it
/// (and before the open) isn't followed: the open refuses a link anywhere on
/// the path (O_NOFOLLOW_ANY), not only at its end.
@Test func aFolderSwappedForALinkAfterTheWalkIsRefused() throws {
    let dir = try TempDir()
    defer { dir.cleanup() }
    let pic = dir.url.appendingPathComponent("sub/pic.png")
    try FileManager.default.createDirectory(at: pic.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: pic)
    let loader = MarkdownImageLoader(allowedPaths: [pic.path])
    loader.beforeOpen = { _ in
        let sub = dir.url.appendingPathComponent("sub"), elsewhere = dir.url.appendingPathComponent("elsewhere")
        try? FileManager.default.moveItem(at: sub, to: elsewhere)
        try? FileManager.default.createSymbolicLink(atPath: sub.path, withDestinationPath: elsewhere.path)
    }
    #expect(throws: MarkdownLocalImages.LoadError.unreadable) { try loader.loadNow(pic) }
    #expect(loader.diskReads == 0)
}
#endif

@Test func linkLoopsAreRefused() throws {
    let dir = try TempDir()
    defer { dir.cleanup() }
    let loop = dir.url.appendingPathComponent("loop.png")
    try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop.png")
    #expect(throws: MarkdownLocalImages.LoadError.tooManyLinks) {
        try MarkdownImageLoader(allowedPaths: [loop.path]).loadNow(loop)
    }
}

/// Looking a path up under /net or /Network (or ~ via /home on macOS) can mount a
/// network share; nothing there is touched, directly or through a link.
@Test func automountFoldersAreNeverLookedUp() throws {
    #expect(MarkdownLocalImages.isAutomountPath("/net"))
    #expect(MarkdownLocalImages.isAutomountPath("/net/server/share/a.png"))
    #expect(MarkdownLocalImages.isAutomountPath("/Network/Servers/x/a.png"))
    #expect(!MarkdownLocalImages.isAutomountPath("/netflix/a.png"))
    #expect(!MarkdownLocalImages.isAutomountPath("/Users/me/net/a.png"))

    let direct = URL(fileURLWithPath: "/net/server.example/share/a.png")
    #expect(throws: MarkdownLocalImages.LoadError.notLocal) {
        try MarkdownImageLoader(allowedPaths: [direct.path]).loadNow(direct)
    }
    let dir = try TempDir()
    defer { dir.cleanup() }
    let link = dir.url.appendingPathComponent("pic.png")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Network/Servers/x/a.png")
    #expect(throws: MarkdownLocalImages.LoadError.notLocal) {
        try MarkdownImageLoader(allowedPaths: [link.path]).loadNow(link)
    }
}

@Test func loadsRunOnTheLoadersQueue() throws {
    let dir = try TempDir()
    defer { dir.cleanup() }
    let a = dir.url.appendingPathComponent("a.png")
    try png.write(to: a)
    let queue = DispatchQueue(label: "test.images")
    let key = DispatchSpecificKey<Bool>()
    queue.setSpecific(key: key, value: true)
    let loader = MarkdownImageLoader(allowedPaths: [a.path], queue: queue)
    let group = DispatchGroup()
    var results: [Bool] = []
    let lock = NSLock()
    for _ in 0..<5 {
        group.enter()
        loader.load(a) { result in
            let onQueue = DispatchQueue.getSpecific(key: key) == true
            lock.lock(); results.append(onQueue && (try? result.get().data) == png); lock.unlock()
            group.leave()
        }
    }
    #expect(group.wait(timeout: .now() + 10) == .success)
    #expect(results == [true, true, true, true, true])
    #expect(loader.diskReads == 1)
}
