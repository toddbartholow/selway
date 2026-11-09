import SwiftUI
import AppKit
import UniformTypeIdentifiers
// Quick Look's types predate Swift concurrency: its request object isn't
// marked Sendable, though Quick Look reads and cancels it from any thread
// (FileThumbnailLoader.load).
@preconcurrency import QuickLookThumbnailing

// MARK: - Asynchronous file icons
//
// `NSWorkspace.icon(forFile:)` hits the disk and LaunchServices; calling it on
// the main thread for every row stalls scrolling in big folders. Rows show a
// generic icon for the item's type at once (cheap, cached per type), then swap
// in the real icon loaded in the background through `FileItem.icon`, which fills
// FileItem's own cache. With icon previews on (Settings → Browse), a file Quick
// Look can preview then swaps in a thumbnail of its contents, as in Finder
// (FileThumbnailLoader).

struct FileIconView: View {
    let item: FileItem
    /// Points at 100%; the window's text size scales it.
    let size: CGFloat

    @Environment(\.textScale) private var textScale
    @Environment(\.displayScale) private var displayScale
    /// Settings → Browse → Icon previews. Read here, so turning it off puts the
    /// type icons back at once.
    @AppStorage(UserPreferences.showIconPreviewsKey)
    private var showsPreviews = UserPreferences.defaultShowIconPreviews
    /// The icon loaded, under the item's `iconKey`.
    @State private var loaded: (id: String, image: NSImage)?
    /// The last thumbnail loaded, under its key. Shown while another of the
    /// same path loads (a new size bucket, or the file changed in place), so
    /// the cell doesn't fall back to the icon in between, and while the cache
    /// has dropped it. Let go when the cell leaves the screen (`onDisappear`),
    /// as is the copy `sized` holds: a lazy grid keeps the state of cells
    /// scrolled away, and the thumbnails of a big folder of photos would
    /// otherwise all stay in memory, past the cache's limit. The cache has
    /// them, while it can, for when the cell comes back.
    @State private var thumbnail: (key: ThumbnailPolicy.Key, image: NSImage)?
    @State private var sized = SizedIcon()
    /// Between `onAppear` and `onDisappear`. Off screen, a redraw (the setting
    /// or the text size changed) shows the icon, so `sized` doesn't take a
    /// copy of a thumbnail again for a cell the lazy grid keeps. True to
    /// begin with: a cell is made to be shown, and its first frame shouldn't
    /// be the icon when the thumbnail is cached.
    @State private var onScreen = true

    var body: some View {
        let side = (size * textScale).rounded()
        let key = thumbnailKey(side: side)
        let preview = onScreen ? key.flatMap(currentThumbnail) : nil
        // `fit`, and `image(_:fitting:)`, keep a thumbnail's proportions in the
        // icon's square. A fallback: Quick Look's icon-mode thumbnails are
        // square already (on macOS 26 at least), so they fill it as icons do.
        Image(nsImage: preview.map { sized.image($0, fitting: side) } ?? sized.image(currentImage, side: side))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: side, height: side)
            .accessibilityIdentifier("fileIcon")
            // What VoiceOver reads after the image: "preview" for a thumbnail,
            // nothing for the type icon. The UI tests tell them apart by it.
            .accessibilityValue(preview == nil ? Text(verbatim: "") : Text("preview"))
            // Again when the thumbnail goes (icon previews turned off, or the
            // file changed into one Quick Look can't preview), for the icon
            // that then shows.
            .task(id: IconTaskID(iconKey: item.iconKey, showsPreview: preview != nil)) {
                // Not while a thumbnail shows: the icon loader's few threads
                // go to the cells that show icons.
                guard FileIconLoader.shared.cached(item) == nil, key.flatMap(currentThumbnail) == nil else { return }
                if let image = await FileIconLoader.shared.load(item), !Task.isCancelled {
                    loaded = (item.iconKey, image)
                }
            }
            .task(id: key) {
                guard let key else { return }
                let thumbnails = FileThumbnailLoader.shared
                if let hit = thumbnails.cached(key) {
                    // Held here too, so the cache dropping it while the cell
                    // shows doesn't put the icon back at the next redraw.
                    if thumbnail?.key != key { thumbnail = (key, hit) }
                    return
                }
                guard !thumbnails.isMiss(key) else {
                    // Not kept for when the miss expires: the last thumbnail
                    // is of other contents, or another size of a file Quick
                    // Look can't preview now.
                    if thumbnail != nil && thumbnail?.key != key { thumbnail = nil }
                    return
                }
                switch await thumbnails.load(key, scale: displayScale) {
                case .image(let image):
                    if !Task.isCancelled { thumbnail = (key, image) }
                case .miss:
                    // The file changed into one Quick Look can't preview: the
                    // last thumbnail is no longer it.
                    if !Task.isCancelled { thumbnail = nil }
                case .cancelled:
                    break
                }
            }
            .onAppear { onScreen = true }
            .onDisappear {
                onScreen = false
                thumbnail = nil
                sized.clear()
            }
    }

    /// What the icon's task runs for.
    private struct IconTaskID: Equatable {
        let iconKey: String
        let showsPreview: Bool
    }

    private var currentImage: NSImage {
        if let loaded, loaded.id == item.iconKey { return loaded.image }
        return FileIconLoader.shared.cached(item) ?? FileIconLoader.shared.placeholder(for: item)
    }

    /// The key of the thumbnail this view shows `side` points square, or nil
    /// for none (icon previews off, or an item that keeps its icon).
    private func thumbnailKey(side: CGFloat) -> ThumbnailPolicy.Key? {
        guard ThumbnailPolicy.allows(item, enabled: showsPreviews) else { return nil }
        return ThumbnailPolicy.key(for: item, pixelSide: Double(side * max(displayScale, 1)))
    }

    /// The thumbnail to show for `key`: its own if made, else (unless Quick
    /// Look has none for the file as it is now) the last one this view showed
    /// of the same path, or one of the file at another size.
    private func currentThumbnail(_ key: ThumbnailPolicy.Key) -> NSImage? {
        let thumbnails = FileThumbnailLoader.shared
        if let hit = thumbnails.cached(key) { return hit }
        guard !thumbnails.isMiss(key) else { return nil }
        if let thumbnail, thumbnail.key.path == key.path { return thumbnail.image }
        return thumbnails.cachedAtAnySize(key)
    }
}

/// A copy of an icon whose `size` is the size it is drawn at.
///
/// SwiftUI renders an NSImage at the image's own size (times the screen's
/// scale) and then stretches the result to the frame, so a 32 pt icon in a
/// 128 pt cell was drawn from 64 pixels and blurred. A copy sized to the frame
/// is drawn from the representation that fits, sharp at any size and scale;
/// at 16 pt in the list it gets the icon's own 16 pt artwork rather than the
/// 32 pt one shrunk. The copy shares the original's representations, which
/// IconServices draws on demand, so it costs little, and the cached original
/// is never resized under another view drawing it.
///
/// Kept per view (in `@State`) and reused while the icon and size stay the
/// same: a new NSImage each time the view is drawn would make SwiftUI render
/// it again.
final class SizedIcon {
    private var base: NSImage?
    private var size: NSSize = .zero
    private var copy: NSImage?

    func image(_ base: NSImage, side: CGFloat) -> NSImage {
        image(base, size: NSSize(width: side, height: side))
    }

    /// A thumbnail: sized to fit a `side`-point square keeping its
    /// proportions, so it is drawn from its pixels at the size it's shown, as
    /// an icon is. Quick Look's icon-mode thumbnails are square (on macOS 26 at
    /// least), so this is `image(_:side:)` for them; the fitting is a fallback
    /// for one that isn't.
    func image(_ base: NSImage, fitting side: CGFloat) -> NSImage {
        let own = base.size
        guard own.width > 0, own.height > 0 else { return image(base, side: side) }
        let scale = side / max(own.width, own.height)
        return image(base, size: NSSize(width: max(1, (own.width * scale).rounded()),
                                        height: max(1, (own.height * scale).rounded())))
    }

    private func image(_ base: NSImage, size: NSSize) -> NSImage {
        if let copy, self.base === base, self.size == size { return copy }
        let sized = (base.copy() as? NSImage) ?? base
        if sized !== base { sized.size = size }
        self.base = base
        self.size = size
        copy = sized
        return sized
    }

    /// Forgets the image and its copy (the cell left the screen).
    func clear() {
        base = nil
        copy = nil
        size = .zero
    }
}

/// Thread-safe: its state is two NSCaches and an OperationQueue.
final class FileIconLoader: @unchecked Sendable {
    static let shared = FileIconLoader()

    /// Holds the same NSImage instances FileItem caches, so a row that scrolls
    /// back into view can show its icon synchronously without a disk hit.
    private let ready: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 2000
        return c
    }()
    private let placeholders = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "studio.irq.selway.FileIconLoader"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    /// From either cache, so a row whose icon FileItem still holds shows it at
    /// once rather than the placeholder until a background load returns it.
    /// Keyed by `FileItem.iconKey`, not the id: a link followed and the same
    /// link not followed have different icons.
    func cached(_ item: FileItem) -> NSImage? {
        let key = item.iconKey as NSString
        if let hit = ready.object(forKey: key) { return hit }
        guard let hit = item.cachedIcon else { return nil }
        ready.setObject(hit, forKey: key)
        return hit
    }

    /// Loads the real icon in the background. Returns nil if the calling task
    /// is cancelled first (the row scrolled away) — its queued load is dropped
    /// so fast scrolling doesn't leave thousands of stale loads ahead of the
    /// rows now on screen.
    func load(_ item: FileItem) async -> NSImage? {
        let request = IconRequest<NSImage?>()
        let op = BlockOperation()
        op.addExecutionBlock { [weak op] in
            guard op?.isCancelled == false else { request.finish(nil); return }
            // NSWorkspace's icon lookups are safe off the main thread.
            let image = item.icon
            self.ready.setObject(image, forKey: item.iconKey as NSString)
            request.finish(image)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
                request.attach(cont)
                queue.addOperation(op)
            }
        } onCancel: {
            op.cancel()
            request.finish(nil)
        }
    }

    /// Generic icon for the item's type (folder, app, or file extension). A
    /// link the listing didn't follow is a link, whatever its name says
    /// (a `Tool.app` link isn't shown as an app).
    func placeholder(for item: FileItem) -> NSImage {
        let key: String
        let type: UTType
        if item.isLinkNotFollowed {
            key = "/link"; type = .symbolicLink
        } else if item.isBrowsableFolder {
            key = "/folder"; type = .folder
        } else if item.isPackage && item.fileExtension == "app" {
            key = "/app"; type = .applicationBundle
        } else {
            key = item.fileExtension
            type = UTType(filenameExtension: item.fileExtension) ?? .data
        }
        if let hit = placeholders.object(forKey: key as NSString) { return hit }
        // Left at its own size, like the real icons (see FileItem.icon).
        let image = NSWorkspace.shared.icon(for: type)
        placeholders.setObject(image, forKey: key as NSString)
        return image
    }
}

// MARK: - Icon previews
//
// Finder shows a preview of a file's contents in place of its type icon: an
// image, a PDF's first page, a document's. FileIconView asks for one here as it
// appears, alongside its type icon, and swaps it in when it arrives. Which
// items get one, the key a thumbnail is cached under (the file's path, its
// contents' modification date and size, and a pixel bucket), and how long a
// miss holds are ThumbnailPolicy's (Selway/Core).
//
// Quick Look makes thumbnails on its own queues (and in its own processes for
// third-party generators), so nothing here reads the file on the main thread.
// FileIconView asks from a `.task`, which a lazy grid or list runs only for the
// cells on screen and cancels when one scrolls away. A request cancelled before
// it reaches Quick Look is never handed to it, and one cancelled after is
// cancelled there too (`QLThumbnailGenerator.cancel` does nothing for a request
// it hasn't been given), so fast scrolling doesn't leave a queue of stale work
// ahead of the cells now showing.

/// What `FileThumbnailLoader.load` came back with.
enum ThumbnailResult: Sendable {
    case image(NSImage)
    /// Quick Look has no thumbnail for the file (remembered for a while:
    /// `ThumbnailPolicy.missLifetime`).
    case miss
    /// The calling task, or Quick Look, cancelled the request.
    case cancelled
}

/// Thread-safe: its state is two NSCaches, and Quick Look's generator is
/// thread-safe.
final class FileThumbnailLoader: @unchecked Sendable {
    static let shared = FileThumbnailLoader()

    /// Thumbnails made, by `ThumbnailPolicy.Key.cacheKey`, costed in bytes.
    /// 160 MB holds a few hundred icon-view thumbnails at 2x, or thousands of
    /// list ones; NSCache drops the least used past that.
    private let ready: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 2000
        c.totalCostLimit = 160 * 1024 * 1024
        return c
    }()

    /// When Quick Look last had no thumbnail for a file, by
    /// `ThumbnailPolicy.Key.file` (any size: one it can't make at one size it
    /// can't make at another), so a cell scrolled back into view, or the slider
    /// moved, doesn't ask again for a while. The file's date is in the key, so
    /// a file changed in place is asked about afresh.
    private let misses: NSCache<NSString, NSDate> = {
        let c = NSCache<NSString, NSDate>()
        c.countLimit = 5000
        return c
    }()

    /// The thumbnail at exactly `key`'s bucket, if one has been made.
    func cached(_ key: ThumbnailPolicy.Key) -> NSImage? {
        ready.object(forKey: key.cacheKey as NSString)
    }

    /// A thumbnail of `key`'s file at any bucket, the largest first: what a
    /// cell shows while the one for its new size loads, and a drag's image
    /// when there's none at its own size.
    func cachedAtAnySize(_ key: ThumbnailPolicy.Key) -> NSImage? {
        for bucket in ThumbnailPolicy.pixelBuckets.reversed() {
            if let hit = cached(key.atBucket(bucket)) { return hit }
        }
        return nil
    }

    /// Whether Quick Look had no thumbnail for `key`'s file, recently enough
    /// to believe it (`ThumbnailPolicy.missHolds`). An older miss is forgotten.
    func isMiss(_ key: ThumbnailPolicy.Key, now: Date = Date()) -> Bool {
        let file = key.file as NSString
        guard let recorded = misses.object(forKey: file) else { return false }
        if ThumbnailPolicy.missHolds(recordedAt: recorded as Date, now: now) { return true }
        misses.removeObject(forKey: file)
        return false
    }

    /// Makes the thumbnail for `key` at `scale` (the screen's backing scale):
    /// `key.bucket` pixels square at most, with Finder's decoration (`iconMode`:
    /// a page's edge and shadow for a document, a border for a photo). Only a
    /// real thumbnail: the request asks for no other representation, so where
    /// Quick Look would fall back to the file's icon it fails instead, the miss
    /// is remembered, and the cell keeps the icon it has. If the calling task is
    /// cancelled first (the cell scrolled away), Quick Look's request is
    /// cancelled, or never made.
    ///
    /// Must not run on the main actor: handing a request to Quick Look can
    /// take tens of milliseconds when several are under way. As a nonisolated
    /// async function it runs on the global executor, though FileIconView
    /// calls it from a main-actor task. (Should the project adopt
    /// NonisolatedNonsendingByDefault, which would run it on its caller's
    /// actor, mark it `@concurrent`.)
    func load(_ key: ThumbnailPolicy.Key, scale: CGFloat) async -> ThumbnailResult {
        let scale = max(scale, 1)
        let side = CGFloat(key.bucket) / scale
        // Not Sendable (Quick Look predates Swift concurrency, hence the
        // @preconcurrency import): it's made here, and after that only read,
        // by Quick Look and by `cancel`, which Quick Look allows from any thread.
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: key.path),
                                                   size: CGSize(width: side, height: side),
                                                   scale: scale, representationTypes: .thumbnail)
        request.iconMode = true
        let pending = IconRequest<ThumbnailResult>()
        let generator = QLThumbnailGenerator.shared
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ThumbnailResult, Never>) in
                pending.attach(cont)
                pending.submit {
                    generator.generateBestRepresentation(for: request) { representation, error in
                        pending.finish(self.result(representation, error, key: key, scale: scale))
                    }
                } stop: {
                    generator.cancel(request)
                }
            }
        } onCancel: {
            if pending.cancel(with: .cancelled) { generator.cancel(request) }
        }
    }

    /// Quick Look's answer as a result, cached (or the miss recorded) before
    /// it's handed back, so the view that asked finds it there.
    private func result(_ representation: QLThumbnailRepresentation?, _ error: Error?,
                        key: ThumbnailPolicy.Key, scale: CGFloat) -> ThumbnailResult {
        guard let representation else {
            // Only Quick Look's answer that it has none is a miss: a cancelled
            // request (here or by Quick Look) may succeed next time.
            if (error as? QLThumbnailError)?.code == .requestCancelled { return .cancelled }
            misses.setObject(Date() as NSDate, forKey: key.file as NSString)
            return .miss
        }
        let cgImage = representation.cgImage
        let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale,
                                                           height: CGFloat(cgImage.height) / scale))
        ready.setObject(image, forKey: key.cacheKey as NSString, cost: cgImage.bytesPerRow * cgImage.height)
        return .image(image)
    }

    /// `image` centred in a square as wide as its longer side, drawn when
    /// shown, for a drag, whose image is drawn into the icon's square frame.
    /// A fallback: Quick Look's icon-mode thumbnails are square already (on
    /// macOS 26 at least), and this returns those as they are.
    static func squared(_ image: NSImage) -> NSImage {
        let size = image.size
        let side = max(size.width, size.height)
        guard size.width > 0, size.height > 0, size.width != size.height else { return image }
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let scale = min(rect.width / size.width, rect.height / size.height)
            let fitted = NSSize(width: size.width * scale, height: size.height * scale)
            image.draw(in: NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                                  width: fitted.width, height: fitted.height))
            return true
        }
    }
}

/// Resumes a continuation exactly once, whichever of completion and
/// cancellation comes first, and even if that happens before it is attached.
/// FileIconLoader's icons and FileThumbnailLoader's thumbnails both use it.
private final class IconRequest<Value: Sendable>: @unchecked Sendable {
    /// Never held while the work is handed over (`submit`): Quick Look can
    /// take tens of milliseconds over that, and a cancellation on the main
    /// thread would wait for it.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var finished = false
    private var submitted = false
    private var result: Value?

    func attach(_ cont: CheckedContinuation<Value, Never>) {
        lock.lock()
        if finished, let r = result {
            lock.unlock()
            cont.resume(returning: r)
        } else {
            continuation = cont
            lock.unlock()
        }
    }

    /// Runs `start`, which hands the work to whatever will `finish` it, unless
    /// the request has finished already (cancelled before it got this far).
    /// A `cancel` from then on is told to `stop` the work too. One that lands
    /// while `start` is still handing it over can stop it too early (Quick
    /// Look ignores a cancel for a request it hasn't been given yet), so if
    /// the request has finished by the time `start` returns, `stop` runs again
    /// here. When the work itself finished it that fast, stopping it does
    /// nothing.
    func submit(_ start: () -> Void, stop: () -> Void) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        submitted = true
        lock.unlock()
        start()
        lock.lock()
        let finishedMeanwhile = finished
        lock.unlock()
        if finishedMeanwhile { stop() }
    }

    /// Finishes with `value` (for a cancellation), and returns whether the
    /// work was handed over by `submit`, and so has to be stopped too.
    func cancel(with value: Value) -> Bool {
        finish(value)
        lock.lock()
        defer { lock.unlock() }
        return submitted
    }

    /// Returns whether this call finished the request (false when it was
    /// finished already, by the other side).
    @discardableResult
    func finish(_ value: Value) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        result = value
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
        return true
    }
}
