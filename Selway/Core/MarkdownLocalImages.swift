import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Local images in the Markdown reader

/// How the Markdown reader shows images stored on disk.
///
/// The rendered page is an HTML string loaded with a file:// base URL, and WebKit
/// gives such a page no read access to files, so `<img src="Docs/pic.png">` never
/// loaded. Instead, every local image the document references is resolved here
/// against the document's folder and rewritten to `selwayimg://local/<path>`, which
/// the reader's scheme handler serves with a `MarkdownImageLoader`. The page's
/// Content-Security-Policy allows images from `selwayimg:` only (plus http/https once
/// the user allows remote images); JavaScript stays off.
///
/// What may be served: only files the rendered document itself referenced (the
/// allow-list from rendering), whose name and real target (after symlinks) both
/// have an image extension, that are regular files no larger than `maxBytes`, and
/// whose bytes really are an image. Relative paths may climb with `..` and
/// absolute paths are allowed (`../img/a.png` is common, and the document could
/// name any path anyway): the guarantee is that nothing but image files the
/// document names is ever read, so a document can't make the reader display, say,
/// a key file renamed or linked as `pic.png`.
enum MarkdownLocalImages {

    /// The URL scheme local images are served under.
    static let scheme = "selwayimg"
    private static let host = "local"

    /// Larger files aren't shown (decoding them would stall the reader).
    static let maxBytes = 50 * 1024 * 1024

    enum LoadError: Error, Equatable {
        /// The rendered document didn't reference this file.
        case notReferenced
        /// The name, or the file a link at the name leads to, isn't an image's.
        case notAnImageName
        case notFound
        case notRegularFile
        case tooLarge
        /// The bytes aren't one of the image formats served.
        case notAnImage
        case unreadable
        /// On a network volume, or somewhere looking it up could mount one.
        case notLocal
        /// Too many links on the way (a loop).
        case tooManyLinks
        /// The rendering already read `maxBytesPerDocument` from disk.
        case documentBudgetExceeded
        /// The request was stopped, or a newer rendering replaced this one, before
        /// its turn came: nothing was read.
        case cancelled
    }

    /// Image extensions served, by MIME type sniffed from the content.
    static let imageExtensions: Set<String> = [
        "png", "apng", "jpg", "jpeg", "jpe", "gif", "webp", "bmp", "tif", "tiff",
        "ico", "heic", "heif", "avif", "svg",
    ]

    // MARK: Resolving references

    /// The file an image reference names: a relative path resolved against
    /// `folder` (the document's), an absolute path, or a `file:` URL (local host
    /// only). Percent-escapes are decoded; a query or fragment is dropped; `.` and
    /// `..` are resolved lexically, as a browser resolves URLs. nil for remote and
    /// other URLs, and for references that name no file.
    static func resolve(_ reference: String, relativeTo folder: URL) -> URL? {
        var s = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.hasPrefix("#"), !s.hasPrefix("//") else { return nil }
        let path: String
        if let scheme = MarkdownToHTML.urlScheme(s) {
            guard scheme == "file", let url = URL(string: s) else { return nil }
            let host = (url.host ?? "").lowercased()
            guard host.isEmpty || host == "localhost" else { return nil }
            path = url.path
        } else {
            if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
            guard !s.isEmpty else { return nil }
            let decoded = s.removingPercentEncoding ?? s
            path = decoded.hasPrefix("/") ? decoded : folder.path + "/" + decoded
        }
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let normalized = normalize(path)
        guard normalized != "/" else { return nil }
        return URL(fileURLWithPath: normalized)
    }

    /// `path` with empty, `.` and `..` components resolved lexically.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    // MARK: Page URLs

    /// Only these characters appear unescaped in a page URL, so it is safe in any
    /// HTML attribute or URL position.
    private static let pathCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-._~")

    /// The URL the page loads `file` (a result of `resolve`) from.
    static func pageURL(for file: URL) -> String {
        let encoded = file.path.addingPercentEncoding(withAllowedCharacters: pathCharacters) ?? ""
        return "\(scheme)://\(host)\(encoded)"
    }

    /// The file a page URL stands for; nil for anything `pageURL` doesn't produce.
    static func file(forPageURL url: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              url.query == nil, url.fragment == nil,
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let path = encoded.removingPercentEncoding,
              path.hasPrefix("/"), !path.contains("\0"), normalize(path) == path, path != "/"
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: Limits

    /// Distinct local images one rendering may reference; later ones show their
    /// alt text. Spellings of one file (case variants on a case-insensitive
    /// volume, `l/l/l/a.png` through a link to `.`) are distinct references, so
    /// without a cap a few kilobytes of Markdown could reference a large file
    /// thousands of times.
    static let maxImagesPerDocument = 200

    /// Bytes one rendering may read from disk in all: each file (by device and
    /// inode) counts once, however often the page fetches it again; past this,
    /// images not yet read aren't served.
    static let maxBytesPerDocument = 200 * 1024 * 1024

    /// Folders where merely looking a path up can mount a network share (autofs).
    /// Nothing under them is touched.
    static func isAutomountPath(_ path: String) -> Bool { AutomountPaths.contains(path) }

    static func hasImageExtension(_ name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// The MIME type of an image, from its first bytes; nil if it isn't one served.
    static func imageType(of data: Data) -> String? {
        let b = [UInt8](data.prefix(32))
        func starts(_ sig: [UInt8], at offset: Int = 0) -> Bool {
            b.count >= offset + sig.count && Array(b[offset..<(offset + sig.count)]) == sig
        }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return "image/gif" }
        if starts(Array("RIFF".utf8)) && starts(Array("WEBP".utf8), at: 8) { return "image/webp" }
        if starts(Array("BM".utf8)) { return "image/bmp" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
        if starts([0x00, 0x00, 0x01, 0x00]) { return "image/x-icon" }
        if starts(Array("ftyp".utf8), at: 4), b.count >= 12 {
            switch String(decoding: b[8..<12], as: UTF8.self) {
            case "avif", "avis":                                 return "image/avif"
            case "heic", "heix", "hevc", "hevx", "mif1", "msf1": return "image/heic"
            default: break
            }
        }
        // SVG is text: an <svg element near the start (after an XML declaration,
        // comments or a doctype). WebKit runs no script in an SVG shown by <img>.
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        if let svg = head.range(of: "<svg") {
            let before = head[..<svg.lowerBound]
            let prolog = before.replacingOccurrences(of: #"<\?xml[^>]*\?>|<!--[\s\S]*?-->|<!doctype[^>]*>|\s|\x{FEFF}"#,
                                                     with: "", options: .regularExpression)
            if prolog.isEmpty { return "image/svg+xml" }
        }
        return nil
    }
}

// MARK: - Serving

/// Reads the local images of one rendering of a Markdown document, for the
/// reader's scheme handler. Make a new one for each rendering.
///
/// Serves a file only if the rendering referenced it (`allowedPaths`, from
/// `MarkdownToHTML.Rendered.localImages`), its name and its real target both
/// have an image extension, every folder on the way is on a local volume (no
/// automount folders are even looked up), it is a regular file of at most
/// `maxBytesPerImage` and its bytes are an image. Each file (by device and
/// inode, however it was spelled) is read from disk at most once and counts
/// once against `maxBytesPerDocument`, the bytes read in all; serving it again
/// from the cache is free. Reads run one at a time on a
/// dedicated serial queue, never on Swift's shared task threads.
final class MarkdownImageLoader: @unchecked Sendable {   // state is only touched on `queue`
    typealias Image = (data: Data, mimeType: String)

    /// Shared by every loader: the reader reads one image at a time.
    static let readQueue = DispatchQueue(label: "studio.irq.selway.MarkdownImages", qos: .userInitiated)

    private let allowedPaths: Set<String>
    private let maxBytesPerImage: Int
    private let maxBytesPerDocument: Int
    private let queue: DispatchQueue
    private var cache: [FileIdentity: Image] = [:]
    /// Bytes read from disk for this rendering (each file once).
    private var bytesRead = 0
    /// Files read from disk so far (for tests).
    private(set) var diskReads = 0
    /// Called with the resolved path just before it is opened (tests use it to
    /// change the path between the walk and the open).
    var beforeOpen: ((String) -> Void)?

    init(allowedPaths: Set<String>,
         maxBytesPerImage: Int = MarkdownLocalImages.maxBytes,
         maxBytesPerDocument: Int = MarkdownLocalImages.maxBytesPerDocument,
         queue: DispatchQueue = MarkdownImageLoader.readQueue) {
        self.allowedPaths = allowedPaths
        self.maxBytesPerImage = maxBytesPerImage
        self.maxBytesPerDocument = maxBytesPerDocument
        self.queue = queue
    }

    private let cancelLock = NSLock()
    private var cancelled = false

    /// A newer rendering replaced this one: reads still queued are skipped.
    func cancel() {
        cancelLock.lock(); cancelled = true; cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelled
    }

    /// Loads `file` on the loader's queue; `completion` runs there too. When its turn
    /// comes, the read is skipped (`.cancelled`) if the loader was cancelled or
    /// `isWanted` (asked on the queue) says the request was stopped meanwhile.
    func load(_ file: URL, isWanted: @escaping () -> Bool = { true },
              completion: @escaping (Result<Image, Error>) -> Void) {
        queue.async {
            guard !self.isCancelled, isWanted() else {
                completion(.failure(MarkdownLocalImages.LoadError.cancelled))
                return
            }
            completion(Result { try self.loadNow(file) })
        }
    }

    /// Loads `file` synchronously. Only ever call it on the loader's queue (or,
    /// in tests, from one thread).
    func loadNow(_ file: URL) throws -> Image {
        typealias E = MarkdownLocalImages.LoadError
        guard allowedPaths.contains(file.path) else { throw E.notReferenced }
        guard MarkdownLocalImages.hasImageExtension(file.lastPathComponent) else { throw E.notAnImageName }
        let target = try Self.resolveLocally(file.path)
        // A link named pic.png that leads to something else isn't an image.
        guard MarkdownLocalImages.hasImageExtension((target as NSString).lastPathComponent) else {
            throw E.notAnImageName
        }

        // Non-blocking, so a FIFO swapped in since can't hang the read. `target`
        // has no links left in it, so on macOS a link anywhere on the path (a
        // folder swapped for one since the walk checked it) fails the open;
        // Linux has no O_NOFOLLOW_ANY and refuses only a link at the end.
        #if os(macOS)
        let noLinks = O_NOFOLLOW_ANY
        #else
        let noLinks = O_NOFOLLOW
        #endif
        beforeOpen?(target)
        let fd = open(target, O_RDONLY | O_NONBLOCK | noLinks | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? E.notFound : E.unreadable }
        defer { close(fd) }
        // The file opened is on a local volume, whatever happened to the path
        // since the walk checked each folder's.
        guard try Self.isLocal(fd) else { throw E.notLocal }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw E.unreadable }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw E.notRegularFile }
        let id = FileIdentity(device: UInt64(truncatingIfNeeded: st.st_dev),
                              inode: UInt64(truncatingIfNeeded: st.st_ino))
        // Already read: serving the same bytes again reads nothing and costs nothing.
        if let image = cache[id] { return image }

        guard st.st_size <= off_t(maxBytesPerImage) else { throw E.tooLarge }
        guard bytesRead + Int(st.st_size) <= maxBytesPerDocument else { throw E.documentBudgetExceeded }
        diskReads += 1
        var data = Data()
        // Whatever is read counts, image or not, and however the read ends.
        defer { bytesRead += data.count }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw E.unreadable
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if data.count > maxBytesPerImage { throw E.tooLarge }
            // The file grew since fstat.
            if bytesRead + data.count > maxBytesPerDocument { throw E.documentBudgetExceeded }
        }
        guard let mime = MarkdownLocalImages.imageType(of: data) else { throw E.notAnImage }
        let image: Image = (data, mime)
        cache[id] = image
        return image
    }

    /// `path` (absolute, normalized) with every symlink resolved, like realpath,
    /// but without ever looking anything up under an automount folder or inside a
    /// network volume: each folder's volume is checked before anything in it is.
    /// A FIFO, device or socket at the end is refused (`notRegularFile`) here,
    /// from its lstat, so it is never opened.
    static func resolveLocally(_ path: String) throws -> String {
        typealias E = MarkdownLocalImages.LoadError
        var pending = path.split(separator: "/").map(String.init)
        var resolved = ""
        var links = 0
        guard try isLocalFolder("/") else { throw E.notLocal }
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                let parent = (resolved as NSString).deletingLastPathComponent
                resolved = parent == "/" ? "" : parent
                continue
            }
            let candidate = resolved + "/" + part
            guard !MarkdownLocalImages.isAutomountPath(candidate) else { throw E.notLocal }
            var st = stat()
            // Residual: a direct-map automount the user configured outside the
            // folders above (auto_master) is mounted by this lstat of its trigger
            // folder; the statfs below then refuses it, so nothing in it is read.
            guard lstat(candidate, &st) == 0 else { throw errno == ENOENT ? E.notFound : E.unreadable }
            switch st.st_mode & S_IFMT {
            case S_IFLNK:
                links += 1
                guard links <= 40 else { throw E.tooManyLinks }
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlink(candidate, &buffer, buffer.count - 1)
                guard n > 0 else { throw E.unreadable }
                let destination = String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if destination.hasPrefix("/") { resolved = "" }
                pending = destination.split(separator: "/").map(String.init) + pending
            case S_IFDIR:
                resolved = candidate
                guard try isLocalFolder(resolved) else { throw E.notLocal }
            case S_IFREG:
                guard pending.isEmpty else { throw E.notFound }   // a file in the middle of the path
                resolved = candidate
            default:
                // A FIFO, device or socket is never opened: opening one can block
                // or have side effects even if nothing is read.
                guard pending.isEmpty else { throw E.notFound }
                throw E.notRegularFile
            }
        }
        return resolved.isEmpty ? "/" : resolved
    }

    /// Whether the open file `fd` is on a local volume.
    private static func isLocal(_ fd: Int32) throws -> Bool {
        #if canImport(Darwin)
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { throw MarkdownLocalImages.LoadError.unreadable }
        return fs.f_flags & UInt32(MNT_LOCAL) != 0
        #else
        return true
        #endif
    }

    /// Whether the folder at `path` is on a local volume.
    private static func isLocalFolder(_ path: String) throws -> Bool {
        #if canImport(Darwin)
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { throw MarkdownLocalImages.LoadError.unreadable }
        return fs.f_flags & UInt32(MNT_LOCAL) != 0
        #else
        return true
        #endif
    }
}
