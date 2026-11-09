import AppKit
import XCTest

/// Dragging files out of Selway. The drop that matters most, on the Desktop or a
/// Finder window, can't be checked from here without driving the user's own
/// Finder, so the drag goes to a second Selway window instead (as in
/// DropTests), and the test then reads what the drag offered from the drag
/// pasteboard, which is what Finder would have read.
final class DragOutTests: SelwayUITestCase {

    /// Named like the file in the report.
    private static let markdown = "systems-audit-2026-10-09.md"
    /// An old date the drop must keep: a copy written from the file's contents
    /// would be dated now.
    private static let modified = Date(timeIntervalSince1970: 1_600_000_000)

    /// Regression: an icon dragged to the Desktop arrived as "Markdown
    /// Document.md". The drag offered the file's contents typed as Markdown,
    /// ahead of its URL, and Finder wrote them to a new file named after the
    /// type. Now the drag offers the file's URL only, so the receiver gets the
    /// file itself, by name.
    func testDraggingAnIconOutKeepsTheFilesNameAndDates() throws {
        let target = try fixture.makeSibling("DropTarget")
        try fixture.makeStandardContents()
        let source = try fixture.makeFile(Self.markdown, size: 50)
        try FileManager.default.setAttributes([.modificationDate: Self.modified], ofItemAtPath: source.path)
        try launch(defaults: ["selwayViewMode": "icons", "selwayNewWindowCustomFolder": target.path],
                   expecting: Fixture.standardListing + [Self.markdown])

        // File ▸ New Window opens at the "new windows open" folder: DropTarget.
        app.typeKey("n", modifierFlags: .command)
        let targetWindow = app.windows.matching(NSPredicate(format: "title == %@", "DropTarget")).firstMatch
        XCTAssertTrue(targetWindow.waitForExistence(timeout: 10), "no second window on DropTarget")
        let targetList = identified("fileList", in: targetWindow)
        XCTAssertTrue(targetList.waitForExistence(timeout: 10), "the second window has no file list")

        let sourceWindow = app.windows.matching(NSPredicate(format: "title == %@", Fixture.rootName)).firstMatch
        let icon = item(Self.markdown, in: identified("fileList", in: sourceWindow))
        click(icon)                              // brings the source window forward; the target stays visible
        XCTAssertTrue(waitUntil(5) { !targetWindow.frame.intersects(icon.frame) },
                      "the second window covers \(Self.markdown)")

        icon.click(forDuration: 0.8, thenDragTo: targetList)

        let arrived = waitUntil(10) {
            (try? FileManager.default.contentsOfDirectory(atPath: target.path)) == [Self.markdown]
        }
        let found = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
        XCTAssertTrue(arrived, "DropTarget holds \(found), not \(Self.markdown)")
        let dropped = target.appendingPathComponent(Self.markdown)
        let attributes = try FileManager.default.attributesOfItem(atPath: dropped.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, 50)
        XCTAssertEqual(attributes[.modificationDate] as? Date, Self.modified,
                       "the dropped file isn't the original: its modification date changed")

        // What the drag offered: the file's URL, and no Markdown contents a
        // receiver could write out under a made-up name. The drag pasteboard
        // keeps the last drag's types until the next drag starts. (Reading the
        // types needs no permission; if the runner's sandbox hides them, the
        // drop above still checks the name and dates.)
        let types = (NSPasteboard(name: .drag).types ?? []).map(\.rawValue)
        if !types.isEmpty {
            XCTAssertTrue(types.contains("public.file-url"), "the drag offered no file URL: \(types)")
            XCTAssertFalse(types.contains("net.daringfireball.markdown"),
                           "the drag offered the file's contents as Markdown: \(types)")
            XCTAssertFalse(types.contains { $0.contains("promised-file") },
                           "the drag offered a file promise instead of the file: \(types)")
        }
    }

    /// Regression: a drag of an icon with several selected carried only the
    /// icon dragged (one item provider holds one file). Now each selected file
    /// is an item of the drag, as in Finder and the list.
    func testDraggingSelectedIconsCarriesAllOfThem() throws {
        let target = try fixture.makeSibling("DropTarget")
        try fixture.makeStandardContents()
        try launch(defaults: ["selwayViewMode": "icons", "selwayNewWindowCustomFolder": target.path],
                   expecting: Fixture.standardListing)

        app.typeKey("n", modifierFlags: .command)
        let targetWindow = app.windows.matching(NSPredicate(format: "title == %@", "DropTarget")).firstMatch
        XCTAssertTrue(targetWindow.waitForExistence(timeout: 10), "no second window on DropTarget")
        let targetList = identified("fileList", in: targetWindow)
        XCTAssertTrue(targetList.waitForExistence(timeout: 10), "the second window has no file list")

        let sourceWindow = app.windows.matching(NSPredicate(format: "title == %@", Fixture.rootName)).firstMatch
        let sourceList = identified("fileList", in: sourceWindow)
        let alpha = item("alpha.txt", in: sourceList), gamma = item("gamma.txt", in: sourceList)
        click(alpha)                             // brings the source window forward; the target stays visible
        XCTAssertTrue(waitUntil(5) { !targetWindow.frame.intersects(alpha.frame)
                                         && !targetWindow.frame.intersects(gamma.frame) },
                      "the second window covers alpha.txt or gamma.txt")
        click(alpha)
        XCUIElement.perform(withKeyModifiers: .command) { click(gamma) }
        waitForStatus(Self.selection("alpha.txt", "gamma.txt"))

        // From gamma.txt, the second of the two: the drag carries the selection,
        // not only the icon under the pointer.
        middle(of: gamma).click(forDuration: 0.8, thenDragTo: middle(of: targetList))

        let expected = ["alpha.txt", "gamma.txt"]
        let arrived = waitUntil(10) {
            (try? FileManager.default.contentsOfDirectory(atPath: target.path))?.sorted() == expected
        }
        let found = ((try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []).sorted()
        XCTAssertTrue(arrived, "DropTarget holds \(found), not \(expected)")

        // The drag pasteboard keeps the last drag's items until the next drag
        // starts: one file URL per file. (If the runner's sandbox hides it, the
        // drop above has checked both files.)
        let pasteboard = NSPasteboard(name: .drag)
        if let items = pasteboard.pasteboardItems, !items.isEmpty {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            XCTAssertEqual(urls.map(\.lastPathComponent).sorted(), expected,
                           "the drag pasteboard holds \(urls), not one file URL per selected icon")
        }
    }
}
