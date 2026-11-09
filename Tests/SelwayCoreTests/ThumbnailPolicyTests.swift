import Foundation
import Testing
@testable import SelwayCore

@Suite struct ThumbnailPolicyTests {
    private typealias T = ThumbnailPolicy

    // MARK: Which items get one

    @Test func filesAndDocumentPackagesGetThumbnails() {
        #expect(T.allows(.fixture("photo.png", parent: "/Users/me/Pictures"), enabled: true))
        #expect(T.allows(.fixture("report.pdf", parent: "/Volumes/Share/Docs"), enabled: true))
        #expect(T.allows(.fixture("Talk.key", package: true), enabled: true))
        #expect(T.allows(.fixture("Letter.pages", package: true), enabled: true))
    }

    @Test func nothingGetsOneWithPreviewsOff() {
        #expect(!T.allows(.fixture("photo.png"), enabled: false))
        #expect(!T.allows(.fixture("Talk.key", package: true), enabled: false))
    }

    @Test func foldersAndAppsKeepTheirIcons() {
        #expect(!T.allows(.fixture("Photos", folder: true), enabled: true))
        #expect(!T.allows(.fixture("Safari.app", package: true), enabled: true))
        // An app's extension in any case is still an app (FileItem lowercases it).
        #expect(!T.allows(.fixture("Tool.APP", package: true), enabled: true))
    }

    @Test func aLinkTheListingDidntFollowKeepsItsIcon() {
        var link = FileItem.fixture("server.png")
        link.isLinkNotFollowed = true
        #expect(!T.allows(link, enabled: true))
    }

    @Test func nothingUnderAnAutomountFolderGetsOne() {
        #expect(!T.allows(.fixture("photo.png", parent: "/net/host/export"), enabled: true))
        #expect(!T.allows(.fixture("photo.png", parent: "/Network/Servers/host"), enabled: true))
        #expect(!T.allows(.fixture("photo.png", parent: "/System/Volumes/Data/net/host"), enabled: true))
        #expect(!T.allows(.fixture("photo.png", parent: "/NET/host"), enabled: true))
        #if os(macOS)
        #expect(!T.allows(.fixture("photo.png", parent: "/home/me"), enabled: true))
        #endif
        // A name that only starts like one is fine.
        #expect(T.allows(.fixture("photo.png", parent: "/network-backup"), enabled: true))
        #expect(T.allows(.fixture("photo.png", parent: "/Users/me/net"), enabled: true))
    }

    // MARK: Buckets

    @Test func aRequestRoundsUpToTheNextBucket() {
        #expect(T.bucket(forPixelSide: 1) == 32)
        #expect(T.bucket(forPixelSide: 32) == 32)
        #expect(T.bucket(forPixelSide: 33) == 48)
        #expect(T.bucket(forPixelSide: 36) == 48)       // 18 pt at 2x
        #expect(T.bucket(forPixelSide: 72) == 96)       // 36 pt at 2x (the column preview)
        #expect(T.bucket(forPixelSide: 128) == 128)     // 64 pt at 2x
        #expect(T.bucket(forPixelSide: 129) == 192)
        #expect(T.bucket(forPixelSide: 257) == 384)
        #expect(T.bucket(forPixelSide: 512) == 512)
        #expect(T.bucket(forPixelSide: 600) == 768)
        #expect(T.bucket(forPixelSide: 1000) == 1024)
    }

    /// No bucket is more than half again the one below it, so a thumbnail
    /// never has more than (3/2)^2 times the pixels asked for.
    @Test func bucketsAreAtMostHalfAgainApart() {
        #expect(T.pixelBuckets == T.pixelBuckets.sorted())
        for (small, big) in zip(T.pixelBuckets, T.pixelBuckets.dropFirst()) {
            #expect(big * 2 <= small * 3, "\(small) to \(big)")
        }
    }

    @Test func bucketsStopAtTheLargest() {
        #expect(T.bucket(forPixelSide: 1025) == 1024)
        #expect(T.bucket(forPixelSide: 5000) == 1024)
        #expect(T.bucket(forPixelSide: .infinity) == 1024)
        #expect(T.bucket(forPixelSide: .nan) == 1024)
        #expect(T.bucket(forPixelSide: 0) == 32)
        #expect(T.bucket(forPixelSide: -4) == 32)
    }

    @Test func slidingWithinABucketKeepsTheKey() {
        let item = FileItem.fixture("photo.png")
        // 104 to 128 pt at 2x is 208 to 256 pixels: one bucket.
        let keys = Set(stride(from: 104.0, through: 128, by: 8).map { T.key(for: item, pixelSide: $0 * 2) })
        #expect(keys.count == 1)
        #expect(T.key(for: item, pixelSide: 96 * 2) != T.key(for: item, pixelSide: 104 * 2))
    }

    // MARK: Misses

    @Test func aMissHoldsForAMinuteThenIsRetried() {
        let recorded = TestClock.now
        #expect(T.missHolds(recordedAt: recorded, now: recorded))
        #expect(T.missHolds(recordedAt: recorded, now: recorded.addingTimeInterval(59)))
        #expect(!T.missHolds(recordedAt: recorded, now: recorded.addingTimeInterval(60)))
        #expect(!T.missHolds(recordedAt: recorded, now: recorded.addingTimeInterval(3600)))
    }

    @Test func aMissFromTheFutureIsRetried() {
        #expect(!T.missHolds(recordedAt: TestClock.now, now: TestClock.now.addingTimeInterval(-1)))
    }

    // MARK: Keys

    @Test func aFileChangedInPlaceGetsANewKey() {
        let before = FileItem.fixture("photo.png", size: 100, modified: TestClock.now)
        let later = FileItem.fixture("photo.png", size: 100, modified: TestClock.now.addingTimeInterval(1))
        let subSecond = FileItem.fixture("photo.png", size: 100, modified: TestClock.now.addingTimeInterval(0.001))
        let resized = FileItem.fixture("photo.png", size: 120, modified: TestClock.now)
        let key = T.key(for: before, pixelSide: 128)
        #expect(T.key(for: before, pixelSide: 128) == key)
        #expect(T.key(for: later, pixelSide: 128).file != key.file)
        #expect(T.key(for: subSecond, pixelSide: 128).file != key.file)
        #expect(T.key(for: resized, pixelSide: 128).file != key.file)
    }

    @Test func keysForOtherFilesAndSizesDiffer() {
        let a = T.key(for: .fixture("a.png"), pixelSide: 128)
        let b = T.key(for: .fixture("b.png"), pixelSide: 128)
        #expect(a.file != b.file)
        #expect(a.cacheKey != b.cacheKey)
        let big = a.atBucket(512)
        #expect(big.file == a.file && big.path == a.path)
        #expect(big.cacheKey != a.cacheKey)
        #expect(a.path == "/fixture/a.png")
    }

    // MARK: The setting

    @Test func previewsAreOnUntilTurnedOff() {
        let d = TestDefaults(); defer { d.cleanup() }
        #expect(UserPreferences.showsIconPreviews(d.defaults))
        d.defaults.set(false, forKey: UserPreferences.showIconPreviewsKey)
        #expect(!UserPreferences.showsIconPreviews(d.defaults))
        d.defaults.set(true, forKey: UserPreferences.showIconPreviewsKey)
        #expect(UserPreferences.showsIconPreviews(d.defaults))
    }
}
