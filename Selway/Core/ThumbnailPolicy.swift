import Foundation

// MARK: - Icon previews (Quick Look thumbnails in place of file icons)
//
// Finder shows a preview of a file's contents (an image, a PDF's first page, a
// document's) where Selway showed its type icon. The app draws them with
// QuickLookThumbnailing (FileThumbnailLoader); this is the part that can be
// tested without it: which items get one, and what a thumbnail is cached under.

enum ThumbnailPolicy {
    /// Whether `item` gets a thumbnail when icon previews are on (`enabled`).
    ///
    /// Not for a folder that opens as one (its folder icon is what Finder shows
    /// too), nor an app (its icon is its own picture). A document package (a
    /// .pages or .key file) is a file to the user, and Quick Look has a
    /// thumbnail for it. Not for a link the listing didn't follow
    /// (`isLinkNotFollowed`): reading its contents would follow it, mounting
    /// what it leads into. Not for anything under an automount folder
    /// (/net, /home, /Network: `AutomountPaths`): Quick Look reading a file
    /// there could mount a share. A share mounted elsewhere (under /Volumes)
    /// gets thumbnails as a local disk does.
    static func allows(_ item: FileItem, enabled: Bool) -> Bool {
        guard enabled, !item.isLinkNotFollowed, !item.isBrowsableFolder else { return false }
        if item.isPackage && item.fileExtension == "app" { return false }
        return !AutomountPaths.contains(item.url.path)
    }

    /// The sizes, in pixels, thumbnails are made at: a request is rounded up to
    /// the next one, so dragging the icon-size slider makes a new thumbnail only
    /// when it crosses one, and the views that show the same file at nearly the
    /// same size share it. Half steps between the powers of two: Quick Look's
    /// icon-mode thumbnail is always the whole bucket square, so a request just
    /// past one power of two would otherwise cost four times its pixels.
    static let pixelBuckets = [32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024]

    /// The bucket a thumbnail `pixelSide` pixels square is made at: the
    /// smallest that's at least as big, or the largest for anything bigger.
    static func bucket(forPixelSide pixelSide: Double) -> Int {
        guard pixelSide.isFinite else { return pixelBuckets[pixelBuckets.count - 1] }
        return pixelBuckets.first { Double($0) >= pixelSide } ?? pixelBuckets[pixelBuckets.count - 1]
    }

    /// How long Quick Look's "no thumbnail" for a file is believed. Its
    /// failure is the same for a file it has no generator for and for one it
    /// couldn't read just then (still being written, a generator that timed
    /// out or crashed), so a miss is retried, when the icon is next shown,
    /// after this long.
    static let missLifetime: TimeInterval = 60

    /// Whether a miss recorded at `recorded` still holds at `now`. One from
    /// the future (the clock was set back) doesn't: it is retried.
    static func missHolds(recordedAt recorded: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(recorded)
        return age >= 0 && age < missLifetime
    }

    /// What a thumbnail is cached under.
    struct Key: Hashable, Sendable {
        /// The file as listed: its path, and its contents' modification date
        /// and size (a followed link's target's: `FileItem.contentModified`).
        /// A file changed in place lists with a new date (or size) once the
        /// folder reloads, so its old thumbnail is no longer found.
        let file: String
        let path: String
        /// The pixel bucket (`pixelBuckets`).
        let bucket: Int

        /// The key as one string, for an NSCache.
        var cacheKey: String { file + "\u{0}" + String(bucket) }

        /// The same file at another bucket.
        func atBucket(_ bucket: Int) -> Key { Key(file: file, path: path, bucket: bucket) }
    }

    /// The key for `item` shown `pixelSide` pixels square. The date goes in
    /// exactly as listed (its bits, not a rounded string), so two saves in the
    /// same second still differ.
    static func key(for item: FileItem, pixelSide: Double) -> Key {
        let path = item.url.path
        let date = item.contentModified.timeIntervalSinceReferenceDate
        let file = path + "\u{0}" + String(date.bitPattern) + "\u{0}" + String(item.contentSize)
        return Key(file: file, path: path, bucket: bucket(forPixelSide: pixelSide))
    }
}
