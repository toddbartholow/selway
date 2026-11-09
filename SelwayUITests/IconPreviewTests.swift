import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Icon previews: Quick Look thumbnails of files' contents in place of their
/// type icons, as in Finder, in every view; off in Settings → Browse. A file's
/// icon (`fileIcon`) has the value "preview" while it shows a thumbnail, and
/// none while it shows the type icon (FileIconView).
///
/// The standard defaults turn icon previews off (SelwayUITestCase), so every
/// launch here says whether they're on.
final class IconPreviewTests: SelwayUITestCase {

    private static let picture = "picture.png"
    private static let document = "document.pdf"
    private static let folder = "Folder"
    /// What the fixture lists, in order (folders on top, then by name).
    private static let listing = [folder, document, picture]

    /// The first thumbnail of a test can wait for Quick Look to start up.
    private static let firstWait: TimeInterval = 30

    private static let iconsOn: [String: Any] = ["selwayViewMode": "icons", "selwayShowIconPreviews": true]

    /// A folder, a PNG and a one-page PDF, each something Quick Look can make
    /// a thumbnail of except the folder.
    private func makePreviewFixture() throws {
        try fixture.makeFolder(Self.folder)
        try Self.writePNG(to: fixture.root.appendingPathComponent(Self.picture))
        try Self.writePDF(to: fixture.root.appendingPathComponent(Self.document))
    }

    // MARK: Views

    func testIconsViewShowsThumbnailsOfAPictureAndAPDF() throws {
        try makePreviewFixture()
        try launch(defaults: Self.iconsOn, expecting: Self.listing)

        waitForIcon(of: Self.picture, preview: true, timeout: Self.firstWait, in: gridIcon)
        waitForIcon(of: Self.document, preview: true, in: gridIcon)
        assertIcon(of: Self.folder, preview: false, in: gridIcon)
    }

    func testListViewShowsThumbnails() throws {
        try makePreviewFixture()
        try launch(defaults: ["selwayShowIconPreviews": true], expecting: Self.listing)

        waitForIcon(of: Self.picture, preview: true, timeout: Self.firstWait, in: listIcon)
        waitForIcon(of: Self.document, preview: true, in: listIcon)
        assertIcon(of: Self.folder, preview: false, in: listIcon)
    }

    /// Launched in List view and switched, as ColumnsMouseTests does: the
    /// launch waits for the file list, which Columns view doesn't have.
    func testColumnsViewShowsThumbnails() throws {
        try makePreviewFixture()
        try launch(defaults: ["selwayShowIconPreviews": true], expecting: Self.listing)
        click(viewModeSegment("Columns"))
        XCTAssertTrue(text(Self.picture, in: columnPane).waitForExistence(timeout: 10),
                      "Columns view doesn't list \(Self.picture)")

        waitForIcon(of: Self.picture, preview: true, timeout: Self.firstWait, in: columnIcon)
        waitForIcon(of: Self.document, preview: true, in: columnIcon)
        assertIcon(of: Self.folder, preview: false, in: columnIcon)
    }

    // MARK: The setting

    /// Off at launch, the picture keeps its icon; Settings → Browse → Icon
    /// previews turns thumbnails on and off again without a relaunch.
    func testTheSettingTurnsPreviewsOffAndOnLive() throws {
        try makePreviewFixture()
        // A first launch with previews on gets Quick Look going and its
        // thumbnail of the picture made, so with previews on, one would come
        // within the short wait below.
        try launch(defaults: Self.iconsOn, expecting: Self.listing)
        waitForIcon(of: Self.picture, preview: true, timeout: Self.firstWait, in: gridIcon)
        app.terminate()
        try launch(defaults: ["selwayViewMode": "icons", "selwayShowIconPreviews": false],
                   expecting: Self.listing)

        let appeared = waitUntil(3) { self.gridIcon(Self.picture).map(Self.showsPreview) ?? false }
        XCTAssertFalse(appeared, "a thumbnail showed with icon previews off")
        assertIcon(of: Self.picture, preview: false, in: gridIcon)

        let settings = openSettings(tab: "Browse")
        let toggle = settings.descendants(matching: .any).matching(identifier: "settingsShowIconPreviews").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no Icon previews switch in Settings → Browse")
        XCTAssertFalse(Self.isOn(toggle), "the Icon previews switch is on")
        toggle.click()
        waitForIcon(of: Self.picture, preview: true, in: gridIcon)
        waitForIcon(of: Self.document, preview: true, in: gridIcon)

        toggle.click()
        waitForIcon(of: Self.picture, preview: false, in: gridIcon)
        waitForIcon(of: Self.document, preview: false, in: gridIcon)
        app.typeKey("w", modifierFlags: .command)
    }

    // MARK: Files that change

    /// A picture overwritten with bytes that aren't an image goes back to its
    /// type icon once the folder shows the change.
    func testAPictureOverwrittenWithOtherBytesGoesBackToItsIcon() throws {
        try makePreviewFixture()
        try launch(defaults: Self.iconsOn, expecting: Self.listing)
        waitForIcon(of: Self.picture, preview: true, timeout: Self.firstWait, in: gridIcon)

        let url = fixture.root.appendingPathComponent(Self.picture)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        try Data(repeating: UInt8(ascii: "x"), count: size + 17).write(to: url)

        waitForIcon(of: Self.picture, preview: false, timeout: Self.firstWait, in: gridIcon)
    }

    /// A PNG Quick Look can't read keeps its icon; written over with a good
    /// one, it gets a thumbnail: the miss remembered for the broken file
    /// doesn't hold for the new one.
    func testABrokenPictureGetsAThumbnailOnceFixed() throws {
        let broken = "broken.png"
        try makePreviewFixture()
        let url = try fixture.makeFile(broken, size: 333)
        try launch(defaults: Self.iconsOn, expecting: [Self.folder, broken, Self.document, Self.picture])

        // Once the good picture's thumbnail is here, Quick Look has been
        // asked about the broken one too.
        waitForIcon(of: Self.picture, preview: true, timeout: Self.firstWait, in: gridIcon)
        let appeared = waitUntil(3) { self.gridIcon(broken).map(Self.showsPreview) ?? false }
        XCTAssertFalse(appeared, "a PNG Quick Look can't read showed a thumbnail")
        assertIcon(of: broken, preview: false, in: gridIcon)

        try Self.writePNG(to: url)
        waitForIcon(of: broken, preview: true, timeout: Self.firstWait, in: gridIcon)
    }

    // MARK: Clicks and drags

    /// With previews on, a click on a thumbnail selects its file, a
    /// double-click on a folder opens it, and a thumbnail dragged to another
    /// window delivers its file (the drag image is the thumbnail).
    func testThumbnailsTakeClicksAndDrags() throws {
        let target = try fixture.makeSibling("DropTarget")
        try makePreviewFixture()
        try fixture.makeFile("inside.txt", size: 5, in: fixture.root.appendingPathComponent(Self.folder))
        try launch(defaults: Self.iconsOn.merging(["selwayNewWindowCustomFolder": target.path]) { _, new in new },
                   expecting: Self.listing)
        waitForIcon(of: Self.picture, preview: true, timeout: Self.firstWait, in: gridIcon)

        let picture = try XCTUnwrap(gridIcon(Self.picture), "no icon element for \(Self.picture)")
        middle(of: picture).click()
        waitForStatus("1 selected")

        // File ▸ New Window opens at the "new windows open" folder: DropTarget.
        app.typeKey("n", modifierFlags: .command)
        let targetWindow = app.windows.matching(NSPredicate(format: "title == %@", "DropTarget")).firstMatch
        XCTAssertTrue(targetWindow.waitForExistence(timeout: 10), "no second window on DropTarget")
        let targetList = identified("fileList", in: targetWindow)
        XCTAssertTrue(targetList.waitForExistence(timeout: 10), "the second window has no file list")

        let sourceWindow = app.windows.matching(NSPredicate(format: "title == %@", Fixture.rootName)).firstMatch
        let sourceList = identified("fileList", in: sourceWindow)
        click(item(Self.picture, in: sourceList))  // brings the source window forward; the target stays visible
        let thumbnail = try XCTUnwrap(gridIcon(Self.picture, in: sourceList), "no icon element for \(Self.picture)")
        XCTAssertTrue(Self.showsPreview(thumbnail), "\(Self.picture)'s icon has \(Self.describe(thumbnail))")
        XCTAssertTrue(waitUntil(5) { !targetWindow.frame.intersects(thumbnail.frame) },
                      "the second window covers \(Self.picture)")

        middle(of: thumbnail).click(forDuration: 0.8, thenDragTo: middle(of: targetList))
        let arrived = waitUntil(10) {
            (try? FileManager.default.contentsOfDirectory(atPath: target.path)) == [Self.picture]
        }
        let found = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
        XCTAssertTrue(arrived, "DropTarget holds \(found), not \(Self.picture)")

        doubleClick(item(Self.folder, in: sourceList))
        waitForFolder(Self.folder, listing: "inside.txt")
    }

    // MARK: Finding icons

    private var columnPane: XCUIElement { identified("columnPane") }

    /// Whether `icon` says it shows a thumbnail.
    private static func showsPreview(_ icon: XCUIElement) -> Bool {
        icon.value as? String == "preview"
    }

    /// What `icon`'s value is, for a failure message.
    private static func describe(_ icon: XCUIElement) -> String {
        guard let value = icon.value else { return "no value" }
        return "the value “\(value)”"
    }

    /// Waits until `name`'s icon, found by `find`, shows a thumbnail
    /// (`preview`) or the type icon.
    private func waitForIcon(of name: String, preview: Bool, timeout: TimeInterval = 10,
                             in find: @escaping (String) -> XCUIElement?,
                             file: StaticString = #filePath, line: UInt = #line) {
        let shown = waitUntil(timeout) { find(name).map { Self.showsPreview($0) == preview } ?? false }
        guard !shown else { return }
        guard let icon = find(name) else {
            XCTFail("no icon element for “\(name)”", file: file, line: line)
            return
        }
        XCTFail("“\(name)”'s icon has \(Self.describe(icon)), not \(preview ? "a thumbnail" : "the type icon")",
                file: file, line: line)
    }

    /// Checks, without waiting, that `name`'s icon shows a thumbnail
    /// (`preview`) or the type icon.
    private func assertIcon(of name: String, preview: Bool, in find: (String) -> XCUIElement?,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let icon = find(name) else {
            XCTFail("no icon element for “\(name)”", file: file, line: line)
            return
        }
        XCTAssertEqual(Self.showsPreview(icon), preview,
                       "“\(name)”'s icon has \(Self.describe(icon)), not \(preview ? "a thumbnail" : "the type icon")",
                       file: file, line: line)
    }

    /// The icon image above `name` in the grid: of the images centred over
    /// its name, the lowest one above it (as IconsViewTests' `iconIsInView`).
    private func gridIcon(_ name: String) -> XCUIElement? {
        gridIcon(name, in: fileList)
    }

    /// `gridIcon` in `list`, one window's grid when there are two.
    private func gridIcon(_ name: String, in list: XCUIElement) -> XCUIElement? {
        let label = item(name, in: list)
        guard label.exists else { return nil }
        let frame = label.frame
        return list.images.matching(identifier: "fileIcon").allElementsBoundByIndex
            .filter { abs($0.frame.midX - frame.midX) < 2 && $0.frame.maxY <= frame.minY + 2 }
            .max { $0.frame.maxY < $1.frame.maxY }
    }

    /// The icon in `name`'s list row.
    private func listIcon(_ name: String) -> XCUIElement? {
        let icon = row(name, in: fileList).images.matching(identifier: "fileIcon").firstMatch
        return icon.exists ? icon : nil
    }

    /// The icon left of `name` in Columns view's first column: of the images
    /// level with the name, the nearest one before it.
    private func columnIcon(_ name: String) -> XCUIElement? {
        let label = text(name, in: columnPane)
        guard label.exists else { return nil }
        let frame = label.frame
        return columnPane.images.matching(identifier: "fileIcon").allElementsBoundByIndex
            .filter { abs($0.frame.midY - frame.midY) < 3 && $0.frame.maxX <= frame.minX + 2 }
            .max { $0.frame.maxX < $1.frame.maxX }
    }

    // MARK: Fixture files

    /// A 300 × 200 PNG, red with a blue square, so its thumbnail isn't blank.
    private static func writePNG(to url: URL) throws {
        let width = 300, height = 200
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 100, y: 50, width: 100, height: 100))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A one-page PDF with a filled square on it.
    private static func writePDF(to url: URL) throws {
        var page = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let context = CGContext(url as CFURL, mediaBox: &page, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        context.setFillColor(red: 0.1, green: 0.6, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 50, y: 150, width: 200, height: 200))
        context.endPDFPage()
        context.closePDF()
    }
}
