import XCTest

/// Clicking in Icons view (a LazyVGrid of cells, each with an AppKit view
/// taking its clicks: IconMouseView).
final class IconsViewTests: SelwayUITestCase {

    private let icons: [String: Any] = ["selwayViewMode": "icons"]

    /// `count` files, file-01.txt and on, each as many bytes as its number, so
    /// the status bar's size tells which icons are selected. Waits for the
    /// first few only: the grid is lazy, so icons far below aren't shown yet.
    private func launchWithGridFixture(count: Int = 12) throws -> [String] {
        let names = (1...count).map { String(format: count > 99 ? "file-%03d.txt" : "file-%02d.txt", $0) }
        for (index, name) in names.enumerated() {
            try fixture.makeFile(name, size: index + 1)
        }
        try launch(defaults: icons, expecting: Array(names.prefix(12)), itemCount: count)
        return names
    }

    /// What the status bar says for `count` grid fixture files totalling `bytes`.
    private func selection(_ count: Int, bytes: Int) -> String {
        "\(count) selected — \(bytes) \(bytes == 1 ? "byte" : "bytes")"
    }

    /// How many icons the grid's first row holds.
    private func firstRowCount(_ names: [String]) -> Int {
        let top = item(names[0]).frame.midY
        return names.prefix(30).filter { abs(item($0).frame.midY - top) < 3 }.count
    }

    func testArrowKeysMoveTheSelectionInIconsView() throws {
        try launchWithStandardFixture(defaults: icons)
        click(item("alpha.txt"))
        waitForStatus(Self.selection("alpha.txt"))

        app.typeKey(.rightArrow, modifierFlags: [])
        waitForStatus(Self.selection("beta.txt"), timeout: 3)
        app.typeKey(.leftArrow, modifierFlags: [])
        waitForStatus(Self.selection("alpha.txt"), timeout: 3)
    }

    func testDownSelectsTheIconInTheSameColumnOnTheNextRow() throws {
        let names = try launchWithGridFixture()
        click(item(names[0]))
        waitForStatus(selection(1, bytes: 1))
        // The nearest icon below the first one, in the same column.
        let frames = names.map { item($0).frame }
        let below = try XCTUnwrap(frames.indices.dropFirst().filter {
            frames[$0].minY > frames[0].maxY && abs(frames[$0].midX - frames[0].midX) < 3
        }.min { frames[$0].minY < frames[$1].minY }, "no icon below the first icon in the same column")

        app.typeKey(.downArrow, modifierFlags: [])
        waitForStatus(selection(1, bytes: below + 1), timeout: 3)
    }

    func testShiftRightExtendsTheSelection() throws {
        let names = try launchWithGridFixture()
        click(item(names[0]))
        waitForStatus(selection(1, bytes: 1))
        app.typeKey(.rightArrow, modifierFlags: .shift)
        waitForStatus(selection(2, bytes: 1 + 2), timeout: 3)
    }

    /// ⇧↓ selects the range to the icon below, as a ⇧-click on it does.
    func testShiftDownSelectsTheRangeToTheIconBelow() throws {
        let names = try launchWithGridFixture()
        click(item(names[0]))
        waitForStatus(selection(1, bytes: 1))
        let columns = firstRowCount(names)
        XCTAssertLessThan(columns, names.count, "all the icons fit in one row")

        app.typeKey(.downArrow, modifierFlags: .shift)
        // file-01 through the first icon of the second row.
        waitForStatus(selection(columns + 1, bytes: (columns + 1) * (columns + 2) / 2), timeout: 3)
    }

    /// The arrows start from the icon last moved to while it's selected, else
    /// from the first selected icon, and ⇧ extends from there when the anchor
    /// was deselected.
    func testArrowKeysStartFromTheLeadOrTheFirstSelectedIcon() throws {
        let names = try launchWithGridFixture()
        click(item(names[0]))
        app.typeKey(.rightArrow, modifierFlags: .shift)
        app.typeKey(.rightArrow, modifierFlags: .shift)
        waitForStatus(selection(3, bytes: 1 + 2 + 3), timeout: 3)
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForStatus(selection(1, bytes: 4), timeout: 3)    // from file-03, not file-01

        click(item(names[0]))
        waitForStatus(selection(1, bytes: 1))
        // Different icons, so the two ⌘-clicks aren't a double-click.
        XCUIElement.perform(withKeyModifiers: .command) { click(item(names[2])) }
        waitForStatus(selection(2, bytes: 1 + 3))
        XCUIElement.perform(withKeyModifiers: .command) { click(item(names[0])) }
        waitForStatus(selection(1, bytes: 3))
        app.typeKey(.rightArrow, modifierFlags: .shift)
        waitForStatus(selection(2, bytes: 3 + 4), timeout: 3)
    }

    func testAnArrowWithNothingSelectedSelectsTheFirstIcon() throws {
        let names = try launchWithGridFixture()
        click(item(names[1]))
        waitForStatus(selection(1, bytes: 2))
        // Empty space below the icons clears the selection and keeps the grid focused.
        let last = item(names[names.count - 1])
        XCTAssertGreaterThan(fileList.frame.minY + fileList.frame.height * 0.85, last.frame.maxY + 20,
                             "no empty space below the icons to click")
        fileList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).click()
        XCTAssertTrue(waitUntil(5) { !self.statusText.contains("selected") }, "the selection is still there")

        app.typeKey(.downArrow, modifierFlags: [])
        waitForStatus(selection(1, bytes: 1), timeout: 3)

        // After Select All the arrows still start from the icon last moved to.
        app.typeKey("a", modifierFlags: .command)
        waitForStatus("\(names.count) selected")
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForStatus(selection(1, bytes: 2), timeout: 3)
    }

    /// ⌥ and ⌘ arrows are left to the menus. (⌃ arrows aren't sent: macOS takes
    /// them for Mission Control.)
    func testModifiedArrowsDontMoveTheSelection() throws {
        let names = try launchWithGridFixture()
        click(item(names[0]))
        waitForStatus(selection(1, bytes: 1))
        app.typeKey(.rightArrow, modifierFlags: .option)
        app.typeKey(.rightArrow, modifierFlags: .command)
        app.typeKey(.rightArrow, modifierFlags: [])
        // Had either modified press moved it, this would be file-03 or file-04.
        waitForStatus(selection(1, bytes: 2), timeout: 3)
    }

    func testArrowKeysScrollTheSelectedIconIntoView() throws {
        let names = try launchWithGridFixture(count: 200)
        click(item(names[0]))
        waitForStatus(selection(1, bytes: 1))
        for _ in 0..<25 { app.typeKey(.downArrow, modifierFlags: []) }

        // The size gives the icon selected; it must be on screen in the grid.
        let status = statusText
        let bytes = status.components(separatedBy: "1 selected — ").last?
            .components(separatedBy: " bytes").first.flatMap { Int($0) }
        let selectedIndex = try XCTUnwrap(bytes, "no single selection in “\(status)”") - 1
        XCTAssertGreaterThan(selectedIndex, 12, "↓ didn't move far down the grid")
        let icon = item(names[selectedIndex])
        XCTAssertTrue(waitUntil(5) { icon.exists && self.fileList.frame.contains(icon.frame) },
                      "“\(names[selectedIndex])” is selected but not scrolled into view")
    }

    // MARK: Arrow keys with Group By on

    /// The grouped grid fixture's groups (Group By Name): a-001.txt to a-150.txt
    /// and so on, each group far taller than the window. Each group's size
    /// differs, so its header's count ("150 items") names it.
    private static let groups: [(prefix: String, count: Int)] = [("a", 150), ("b", 140), ("c", 130)]

    /// The grouped grid fixture's files in grid order, each as many bytes as
    /// its place in the grid (from 1), so the status bar's size tells which
    /// icon is selected, as with launchWithGridFixture.
    private func launchWithGroupedGridFixture() throws -> [String] {
        let names = Self.groups.flatMap { group in
            (1...group.count).map { String(format: "%@-%03d.txt", group.prefix, $0) }
        }
        for (index, name) in names.enumerated() {
            try fixture.makeFile(name, size: index + 1)
        }
        try launch(defaults: icons.merging(["selwayGroupBy": "Name"]) { _, new in new },
                   expecting: Array(names.prefix(12)), itemCount: names.count)
        waitForStatus("Grouped by Name")
        return names
    }

    /// The places in the grid of the icons in the first column, every row of
    /// every group in turn: where ↓ goes from the first icon, one per press
    /// (each group starts a new row), and ↑ back.
    private func firstColumn(columns: Int) -> [Int] {
        var column: [Int] = []
        var start = 0
        for group in Self.groups {
            column += stride(from: start, to: start + group.count, by: max(1, columns))
            start += group.count
        }
        return column
    }

    /// Whether `name`'s icon shows in full in the grid: its image and its name
    /// inside the grid, and neither under a group header (the header's count,
    /// padded by the 4 points DateSectionHeader pads it with). From one
    /// snapshot of the grid, so every frame is from the same moment.
    private func iconIsInView(_ name: String) -> Bool {
        guard let grid = try? fileList.snapshot() else { return false }
        var texts: [XCUIElementSnapshot] = [], images: [XCUIElementSnapshot] = []
        func visit(_ element: XCUIElementSnapshot) {
            if element.elementType == .staticText { texts.append(element) }
            if element.elementType == .image, element.identifier == "fileIcon" { images.append(element) }
            element.children.forEach(visit)
        }
        visit(grid)
        func says(_ element: XCUIElementSnapshot, _ string: String) -> Bool {
            element.label == string || element.title == string || element.value as? String == string
        }
        guard let label = texts.first(where: { says($0, name) }),
              let image = images.filter({
                  abs($0.frame.midX - label.frame.midX) < 2 && $0.frame.maxY <= label.frame.minY + 2
              }).max(by: { $0.frame.maxY < $1.frame.maxY }) else { return false }
        let parts = [image.frame, label.frame]
        guard parts.allSatisfy({ grid.frame.contains($0) }) else { return false }
        let headers = texts.filter { text in Self.groups.contains { says(text, "\($0.count) items") } }
            .map { $0.frame.insetBy(dx: 0, dy: -4) }
        return !parts.contains { part in
            headers.contains { $0.minY < part.maxY - 0.5 && $0.maxY > part.minY + 0.5 }
        }
    }

    /// Issue #24: with Group By on, ↓ from a group's last row into the next
    /// group, whose icons are below the window's bottom edge and not laid out
    /// yet, selected the next group's first icon but didn't scroll to it.
    func testDownScrollsToTheNextGroupBelowTheWindow() throws {
        let names = try launchWithGroupedGridFixture()
        click(item(names[0]))
        waitForStatus(selection(1, bytes: 1))
        let column = firstColumn(columns: firstRowCount(names))
        let firstOfB = Self.groups[0].count
        let lastRowOfA = try XCTUnwrap(column.lastIndex { $0 < firstOfB })

        for _ in 0..<lastRowOfA { app.typeKey(.downArrow, modifierFlags: []) }
        waitForStatus(selection(1, bytes: column[lastRowOfA] + 1), timeout: 5)
        XCTAssertTrue(waitUntil(5) { self.iconIsInView(names[column[lastRowOfA]]) },
                      "“\(names[column[lastRowOfA]])”, on group A's last row, is selected but not in view")
        XCTAssertFalse(iconIsInView(names[firstOfB]),
                       "“\(names[firstOfB])” is in view already, so ↓ wouldn't cross into a group below the window")

        // Into group B, then on down it: each icon comes into view.
        for row in lastRowOfA + 1...lastRowOfA + 3 {
            app.typeKey(.downArrow, modifierFlags: [])
            waitForStatus(selection(1, bytes: column[row] + 1), timeout: 3)
            XCTAssertTrue(waitUntil(5) { self.iconIsInView(names[column[row]]) },
                          "“\(names[column[row]])” is selected but not scrolled into view")
        }
    }

    /// Issue #24: ↑ to an icon above the window scrolled it only to the top
    /// edge, under the group header pinned there. It must come to rest below
    /// the header, within a group and across into the group above.
    func testUpKeepsTheIconClearOfThePinnedGroupHeader() throws {
        let names = try launchWithGroupedGridFixture()
        click(item(names[0]))
        waitForStatus(selection(1, bytes: 1))
        let column = firstColumn(columns: firstRowCount(names))
        let firstRowOfB = try XCTUnwrap(column.firstIndex { $0 >= Self.groups[0].count })
        let lastOfA = names[column[firstRowOfB - 1]]

        // Down into group B until group A's last row has scrolled off the top.
        var row = 0
        while row < firstRowOfB || iconIsInView(lastOfA) {
            XCTAssertLessThan(row + 1, column.count, "“\(lastOfA)” never scrolled out of view")
            app.typeKey(.downArrow, modifierFlags: [])
            row += 1
            waitForStatus(selection(1, bytes: column[row] + 1), timeout: 3)
        }
        XCTAssertGreaterThan(row, firstRowOfB, "group B's first row reached the top without ↓ scrolling past it")

        // Up to group B's first row (the last presses scroll, under B's
        // header), then into group A (its header pinned at the top by then).
        while row > firstRowOfB - 3 {
            app.typeKey(.upArrow, modifierFlags: [])
            row -= 1
            waitForStatus(selection(1, bytes: column[row] + 1), timeout: 3)
            XCTAssertTrue(waitUntil(5) { self.iconIsInView(names[column[row]]) },
                          "“\(names[column[row]])” is selected but under the group header or out of view")
        }
    }

    /// The frames of the icons' images in the grid, from one snapshot.
    private func iconImageFrames() -> [CGRect] {
        guard let grid = try? fileList.snapshot() else { return [] }
        var frames: [CGRect] = []
        func visit(_ element: XCUIElementSnapshot) {
            if element.elementType == .image, element.identifier == "fileIcon" { frames.append(element.frame) }
            element.children.forEach(visit)
        }
        visit(grid)
        return frames
    }

    /// How many icons the status bar says are selected (0 for none).
    private var selectedCount: Int {
        let words = statusText.components(separatedBy: .whitespaces)
        guard let index = words.firstIndex(of: "selected"), index > 0 else { return 0 }
        return Int(words[index - 1]) ?? 0
    }

    /// One grid with a Section per group (issue #24) keeps the pinned header
    /// empty space over the icons, as in Finder: a click on it clears the
    /// selection rather than selecting the icon beneath, a drag from it draws
    /// a rubber band rather than dragging that icon, and a right-click opens
    /// the folder's menu, not the icon's.
    func testAPinnedGroupHeaderOverTheIconsIsEmptySpace() throws {
        let names = try launchWithGroupedGridFixture()
        click(item(names[0]))
        waitForStatus(selection(1, bytes: 1))
        let column = firstColumn(columns: firstRowCount(names))

        // Down until the first row has scrolled off: group A's header is pinned.
        var row = 0
        while iconIsInView(names[0]) {
            XCTAssertLessThan(row, 30, "↓ never scrolled the first row out of view")
            app.typeKey(.downArrow, modifierFlags: [])
            row += 1
            waitForStatus(selection(1, bytes: column[row] + 1), timeout: 3)
        }
        let header = text("\(Self.groups[0].count) items", in: fileList)
        XCTAssertTrue(header.waitForExistence(timeout: 5), "group A's header isn't shown")

        // A point on the header with an icon's image beneath it. Scroll a little
        // until a row lies under the header.
        var point: CGPoint?
        for attempt in 0..<6 where point == nil {
            if attempt > 0 { fileList.scroll(byDeltaX: 0, deltaY: attempt.isMultiple(of: 2) ? 25 : -40) }
            let y = header.frame.midY
            point = iconImageFrames().first { $0.minY < y - 2 && $0.maxY > y + 2 }.map { CGPoint(x: $0.midX, y: y) }
        }
        let onHeader = try XCTUnwrap(point, "no icon lies under group A's pinned header")
        let target = windowPoint(x: onHeader.x, y: onHeader.y)

        // A click there clears the selection, selecting nothing.
        target.click()
        XCTAssertTrue(waitUntil(5) { !self.statusText.contains("selected") },
                      "a click on the pinned header left or made a selection; the status bar says “\(statusText)”")

        // A drag from there down across the icons draws a band that selects them.
        let bottom = fileList.frame.maxY
        let below = iconImageFrames().first { $0.minY > onHeader.y + 150 && $0.maxY < bottom && $0.midX > onHeader.x + 20 }
        let end = try XCTUnwrap(below, "no icon two rows below the header, right of it, to drag to")
        target.click(forDuration: 0.1, thenDragTo: windowPoint(x: end.midX, y: end.midY))
        XCTAssertTrue(waitUntil(5) { self.selectedCount >= 2 },
                      "a drag from the pinned header didn't draw a band; the status bar says “\(statusText)”")

        // A right-click there opens the folder's menu.
        target.rightClick()
        let refresh = app.menuItems["Refresh"].firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 5), "a right-click on the pinned header opened no folder menu")
        XCTAssertFalse(app.menuItems["Get Info"].exists, "a right-click on the pinned header opened an icon's menu")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testClickSelectsAFile() throws {
        try launchWithStandardFixture(defaults: icons)
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))
    }

    /// A click on one icon of a larger selection keeps the selection for the
    /// double-click interval (so a double-click there opens all of it), then
    /// selects only that icon, as in Finder.
    func testClickInsideTheSelectionNarrowsItAfterAMoment() throws {
        try launchWithStandardFixture(defaults: icons)
        click(item("alpha.txt"))                 // focuses the grid
        waitForStatus(Self.selection("alpha.txt"))
        app.typeKey("a", modifierFlags: .command)
        waitForStatus("4 selected")
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"), timeout: 5)
    }

    /// Review of #41: Select All during the wait before a click inside the
    /// selection narrows it (everything already selected, so the grid saw no
    /// change), or a context menu opened during it, was undone by the
    /// narrowing. Both now drop the narrowing.
    func testSelectAllOrAMenuDuringTheWaitKeepsTheSelection() throws {
        let wait: TimeInterval = 3
        try launchWithStandardFixture(defaults: icons.merging(["selwayUITestNarrowingWait": wait]) { $1 })
        func keepsSaying(_ status: String) -> Bool {
            !waitUntil(wait + 1.5) { !self.statusText.contains(status) }
        }
        click(item("alpha.txt"))                 // focuses the grid
        waitForStatus(Self.selection("alpha.txt"))
        app.typeKey("a", modifierFlags: .command)
        waitForStatus("4 selected")
        click(item("beta.txt"))
        app.typeKey("a", modifierFlags: .command)
        XCTAssertTrue(keepsSaying("4 selected"), "Select All didn't keep everything selected; " +
                      "the status bar says “\(statusText)”")

        click(item("beta.txt"))
        item("beta.txt").rightClick()
        let getInfo = app.menuItems["Get Info"].firstMatch
        XCTAssertTrue(getInfo.waitForExistence(timeout: 5), "a right-click on beta.txt opened no item menu")
        XCTAssertTrue(keepsSaying("4 selected"), "the selection narrowed under the open menu; " +
                      "the status bar says “\(statusText)”")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { !getInfo.exists }, "the menu stayed open")
    }

    /// Regression: about one click in three or four on an icon didn't select it.
    /// The hand moves the pointer a point or two while clicking, and any movement
    /// with the button down started a drag of the icon (SwiftUI's onDrag), which
    /// took the click. A press that moves less than a few points is a click, as
    /// in Finder. (A click on empty space never lost its click; checked here too.)
    func testAClickThatMovesALittleStillSelects() throws {
        try launchWithStandardFixture(defaults: icons)
        for (name, move) in [("beta.txt", CGVector(dx: 2, dy: 1)), ("gamma.txt", CGVector(dx: -1, dy: 2)),
                             ("alpha.txt", CGVector(dx: 3, dy: 0))] {
            XCTAssertTrue(item(name).waitForExistence(timeout: 10), "“\(name)” isn't listed")
            let start = middle(of: item(name))
            start.click(forDuration: 0.05, thenDragTo: start.withOffset(move))
            waitForStatus(Self.selection(name), timeout: 5)
        }
        let empty = fileList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        empty.click(forDuration: 0.05, thenDragTo: empty.withOffset(CGVector(dx: 2, dy: 1)))
        XCTAssertTrue(waitUntil(5) { !self.statusText.contains("selected") },
                      "a click on empty space that moved a little didn't clear the selection; " +
                      "the status bar says “\(statusText)”")
    }

    /// ⌘-click adds an icon to the selection or takes it out; ⇧-click adds the
    /// icons from the last one clicked, as in Finder (and the list).
    func testCommandClickTogglesAndShiftClickExtends() throws {
        try launchWithStandardFixture(defaults: icons)
        click(item("alpha.txt"))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .command) { click(item("gamma.txt")) }
        waitForStatus(Self.selection("alpha.txt", "gamma.txt"))
        XCUIElement.perform(withKeyModifiers: .command) { click(item("alpha.txt")) }
        waitForStatus(Self.selection("gamma.txt"))

        click(item("alpha.txt"))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .shift) { click(item("gamma.txt")) }
        waitForStatus(Self.selection("alpha.txt", "beta.txt", "gamma.txt"))
    }

    /// Regression (#43): a ⌘-press on a selected icon took it out of the
    /// selection at once, so a ⌘-drag from it (⌘ makes the drop a move)
    /// carried that icon alone. Finder keeps the selection for a ⌘-drag; the
    /// icon now leaves it only when the button comes up without a drag. A
    /// ⌘-click still adds an icon at once and takes a selected one out.
    func testCommandDraggingASelectedIconMovesTheWholeSelection() throws {
        try launchWithStandardFixture(defaults: icons)
        click(item("alpha.txt"))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .command) { click(item("beta.txt")) }
        waitForStatus(Self.selection("alpha.txt", "beta.txt"))
        XCUIElement.perform(withKeyModifiers: .command) { click(item("gamma.txt")) }
        waitForStatus(Self.selection("alpha.txt", "beta.txt", "gamma.txt"))
        // A ⌘-click (another icon in between, so it is no double-click) takes beta.txt out.
        XCUIElement.perform(withKeyModifiers: .command) { click(item("beta.txt")) }
        waitForStatus(Self.selection("alpha.txt", "gamma.txt"))

        let target = middle(of: item(Fixture.folder))
        let gamma = middle(of: item("gamma.txt"))
        XCUIElement.perform(withKeyModifiers: .command) { gamma.click(forDuration: 0.8, thenDragTo: target) }

        let subfolder = fixture.root.appendingPathComponent(Fixture.folder, isDirectory: true)
        let expected = [Fixture.innerFile, "alpha.txt", "gamma.txt"].sorted()
        func contents(_ url: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
        }
        let moved = waitUntil(10) { contents(subfolder) == expected }
        XCTAssertTrue(moved, "\(Fixture.folder) holds \(contents(subfolder)), not \(expected): " +
                             "the ⌘-drag lost the selection")
        XCTAssertEqual(contents(fixture.root), [Fixture.folder, "beta.txt"].sorted(),
                       "the ⌘-drag copied the files instead of moving them, or moved beta.txt too")
    }

    /// Regression: a click on empty space left the selection as it was. Finder
    /// clears it.
    func testClickOnEmptySpaceClearsTheSelection() throws {
        try launchWithStandardFixture(defaults: icons)
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))

        // Below the one row of icons the standard folder fills.
        let last = item("gamma.txt")
        let empty = fileList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        XCTAssertGreaterThan(fileList.frame.minY + fileList.frame.height * 0.85, last.frame.maxY + 20,
                             "no empty space below the icons to click")
        empty.click()
        XCTAssertTrue(waitUntil(5) { !self.statusText.contains("selected") },
                      "the selection is still there; the status bar says “\(statusText)”")
        waitForStatus("\(Fixture.standardListing.count) items")

        // Clicking an icon again still selects it.
        click(item("alpha.txt"))
        waitForStatus(Self.selection("alpha.txt"))
    }

    /// The gap between two icons is empty space too.
    func testClickBetweenIconsClearsTheSelection() throws {
        try launchWithStandardFixture(defaults: icons)
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))

        // Halfway between the two images. Cells are the same width with their
        // icon centred, so that is the middle of the gap between the cells.
        guard let beta = icon(of: "beta.txt"), let gamma = icon(of: "gamma.txt") else {
            throw XCTSkip("the icons aren't exposed as images, so the gap between the cells can't be found")
        }
        XCTAssertLessThan(beta.frame.maxX, gamma.frame.minX, "beta.txt and gamma.txt aren't side by side")
        windowPoint(x: (beta.frame.maxX + gamma.frame.minX) / 2, y: beta.frame.midY).click()
        XCTAssertTrue(waitUntil(5) { !self.statusText.contains("selected") },
                      "the selection is still there; the status bar says “\(statusText)”")
    }

    /// Finder's rubber band: a drag from empty space draws a rectangle that
    /// selects the icons it touches, in place of the selection there was.
    func testDraggingFromEmptySpaceAcrossTwoIconsSelectsThem() throws {
        try launchWithStandardFixture(defaults: icons)
        click(item("alpha.txt"))
        waitForStatus(Self.selection("alpha.txt"))

        // From the empty space below beta.txt up and across to the middle of
        // gamma.txt's name: the band touches those two cells and not alpha's.
        let (start, end) = try band(from: "beta.txt", to: "gamma.txt")
        start.click(forDuration: 0.1, thenDragTo: end)
        waitForStatus(Self.selection("beta.txt", "gamma.txt"))
    }

    /// With ⌘ held, the band flips the icons it touches against the selection
    /// it started with, as in Finder.
    func testCommandDragTogglesTheIconsTheBandTouches() throws {
        try launchWithStandardFixture(defaults: icons)
        click(item("alpha.txt"))
        waitForStatus(Self.selection("alpha.txt"))

        let (start, end) = try band(from: "beta.txt", to: "gamma.txt")
        XCUIElement.perform(withKeyModifiers: .command) { start.click(forDuration: 0.1, thenDragTo: end) }
        waitForStatus(Self.selection("alpha.txt", "beta.txt", "gamma.txt"))

        let (below, gamma) = try band(from: "gamma.txt", to: "gamma.txt")
        XCUIElement.perform(withKeyModifiers: .command) {
            below.click(forDuration: 0.1, thenDragTo: gamma.withOffset(CGVector(dx: 6, dy: 0)))
        }
        waitForStatus(Self.selection("alpha.txt", "beta.txt"))
    }

    /// Regression: a cell takes its column's whole width, and the whole cell
    /// was the icon's, so a drag from the blank space beside a short name
    /// selected that icon (or dragged it) instead of drawing a band. As in
    /// Finder, only the image and the name are the icon.
    func testABandFromBesideAnIconsNameSelectsTheIconsItCrosses() throws {
        try launchWithStandardFixture(defaults: icons)
        click(item("alpha.txt"))
        waitForStatus(Self.selection("alpha.txt"))

        // From beside beta.txt's name, in its column, across to gamma.txt's:
        // the band crosses both names and touches nothing of alpha.txt's.
        let start = try besideName(of: "beta.txt")
        start.click(forDuration: 0.1, thenDragTo: middle(of: item("gamma.txt")))
        waitForStatus(Self.selection("beta.txt", "gamma.txt"))
    }

    /// The blank space beside a short name is empty space for a click too:
    /// it clears the selection, as in Finder.
    func testClickBesideAnIconsNameClearsTheSelection() throws {
        try launchWithStandardFixture(defaults: icons)
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))

        try besideName(of: "beta.txt").click()
        XCTAssertTrue(waitUntil(5) { !self.statusText.contains("selected") },
                      "a click beside beta.txt's name left the selection; the status bar says “\(statusText)”")
    }

    /// Issue #33: a folder took a drop anywhere in its cell, the blank space
    /// beside a short name included. As in Finder, only its picture and name
    /// take one; beside them the drop goes into the folder shown. The files
    /// come from a second window (as in DropTests), on the same volume, so
    /// each drop moves its file.
    func testADropBesideAFoldersNameGoesToTheFolderShown() throws {
        let source = try fixture.makeSibling("DragSource")
        try fixture.makeFile("beside.txt", size: 5, in: source)
        try fixture.makeFile("onto.txt", size: 6, in: source)
        // A name far narrower than its icon, so there is blank space beside it.
        let box = try fixture.makeFolder("box")
        try fixture.makeStandardContents()
        try launch(defaults: icons.merging(["selwayNewWindowCustomFolder": source.path]) { _, new in new },
                   expecting: ["box"] + Fixture.standardListing)

        // File ▸ New Window opens at the "new windows open" folder: DragSource.
        app.typeKey("n", modifierFlags: .command)
        let sourceWindow = app.windows.matching(NSPredicate(format: "title == %@", "DragSource")).firstMatch
        XCTAssertTrue(sourceWindow.waitForExistence(timeout: 10), "no second window on DragSource")
        let sourceList = identified("fileList", in: sourceWindow)
        let targetWindow = app.windows.matching(NSPredicate(format: "title == %@", Fixture.rootName)).firstMatch
        let targetList = identified("fileList", in: targetWindow)
        let beside = item("beside.txt", in: sourceList), onto = item("onto.txt", in: sourceList)
        XCTAssertTrue(beside.waitForExistence(timeout: 10) && onto.waitForExistence(timeout: 10),
                      "the second window doesn't list the files to drag")
        click(beside)                            // brings the source window forward; the target stays visible
        let folderName = item("box", in: targetList)
        XCTAssertTrue(waitUntil(5) { !sourceWindow.frame.intersects(folderName.frame) },
                      "the second window covers the folder “box”")

        // Beside the folder's name: into the folder shown, not into “box”.
        let besideBox = try besideName(of: "box", in: targetList)
        middle(of: beside).click(forDuration: 0.8, thenDragTo: besideBox)
        XCTAssertTrue(waitUntil(10) { self.fixture.exists("beside.txt") },
                      "a drop beside “box”'s name didn't land in \(Fixture.rootName)")
        XCTAssertFalse(fixture.exists("beside.txt", in: box), "a drop beside “box”'s name went into “box”")

        // On the folder's name: into “box”. A drag from the source window right
        // after the first drop sometimes didn't start (1 full run in 4), so the
        // source window is clicked forward first, as in DropTests.
        click(onto)
        middle(of: onto).click(forDuration: 0.8, thenDragTo: middle(of: folderName))
        XCTAssertTrue(waitUntil(10) { self.fixture.exists("onto.txt", in: box) },
                      "a drop on “box”'s name didn't land in “box”")
        XCTAssertFalse(fixture.exists("onto.txt"), "a drop on “box”'s name went into \(Fixture.rootName)")
    }

    /// A drag from a window in the background starts, as in Finder, each time:
    /// pressed with the window behind (not clicked forward first), right after
    /// a drop into the window in front. It sometimes didn't (#53).
    func testADragFromAWindowInTheBackgroundStarts() throws {
        let source = try fixture.makeSibling("DragSource")
        let names = ["first.txt", "second.txt", "third.txt"]
        for (index, name) in names.enumerated() { try fixture.makeFile(name, size: index + 1, in: source) }
        let box = try fixture.makeFolder("box")
        try fixture.makeStandardContents()
        try launch(defaults: icons.merging(["selwayNewWindowCustomFolder": source.path]) { _, new in new },
                   expecting: ["box"] + Fixture.standardListing)

        // File ▸ New Window opens on DragSource, beside the first window.
        app.typeKey("n", modifierFlags: .command)
        let sourceWindow = app.windows.matching(NSPredicate(format: "title == %@", "DragSource")).firstMatch
        XCTAssertTrue(sourceWindow.waitForExistence(timeout: 10), "no second window on DragSource")
        let sourceList = identified("fileList", in: sourceWindow)
        let targetWindow = app.windows.matching(NSPredicate(format: "title == %@", Fixture.rootName)).firstMatch
        let folderName = item("box", in: identified("fileList", in: targetWindow))
        XCTAssertTrue(folderName.waitForExistence(timeout: 10), "the first window doesn't list “box”")

        for name in names {
            let file = item(name, in: sourceList)
            XCTAssertTrue(file.waitForExistence(timeout: 10), "DragSource doesn't list \(name)")
            XCTAssertFalse(sourceWindow.frame.intersects(folderName.frame), "the second window covers “box”")
            XCTAssertFalse(targetWindow.frame.intersects(file.frame), "the first window covers \(name)")
            // The window with “box” in front (each time: the press that began
            // the last drag made the other window key), the one with the file behind.
            click(folderName)
            XCTAssertTrue(waitUntil(5) { self.app.windows.firstMatch.title == Fixture.rootName },
                          "the window with “box” didn't come forward")
            middle(of: file).click(forDuration: 0.8, thenDragTo: middle(of: folderName))
            XCTAssertTrue(waitUntil(10) { self.fixture.exists(name, in: box) },
                          "a drag of \(name) from the window in the background didn't start")
        }
    }

    /// A click on a file in a window in the background selects it, and the
    /// window, now in front, takes the arrow keys (#53).
    func testArrowKeysGoToAWindowClickedInTheBackgroundInIconsView() throws {
        let (source, target) = try twoWindows()
        click(item("box", in: identified("fileList", in: target)))     // the other window in front
        XCTAssertTrue(waitUntil(5) { self.app.windows.firstMatch.title == Fixture.rootName },
                      "the first window didn't come forward")
        click(item("first.txt", in: identified("fileList", in: source)))
        waitForStatus(Self.oneSelected(bytes: 100), in: source)
        XCTAssertEqual(app.windows.firstMatch.title, "DragSource", "the window clicked didn't come forward")
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForStatus(Self.oneSelected(bytes: 200), in: source, timeout: 3)
    }

    func testArrowKeysGoToAWindowClickedInTheBackgroundInColumnsView() throws {
        let (source, target) = try twoWindows()
        // Columns view in both windows (the view mode is shared), then the
        // first window in front.
        // As viewModeSegment finds it, in the second window's toolbar.
        let picker = identified("viewModePicker", in: source)
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "no view mode picker in DragSource's toolbar")
        let named = picker.radioButtons.matching(Self.named("Columns")).firstMatch
        click(named.exists ? named : picker.radioButtons.element(boundBy: 2))
        let sourceColumn = identified("columnPane", in: source)
        XCTAssertTrue(text("first.txt", in: sourceColumn).waitForExistence(timeout: 10),
                      "DragSource's Columns view doesn't list first.txt")
        click(text("box", in: identified("columnPane", in: target)))     // shows “box” in a column
        XCTAssertTrue(waitUntil(5) { self.app.windows.firstMatch.title == "box" },
                      "the first window didn't come forward")

        click(text("first.txt", in: sourceColumn))
        waitForStatus(Self.oneSelected(bytes: 100), in: source)
        app.typeKey(.downArrow, modifierFlags: [])
        waitForStatus(Self.oneSelected(bytes: 200), in: source, timeout: 3)
    }

    /// The fixture's root (with “box”) in Icons view and, beside it, a second
    /// window on DragSource, with first.txt (100 bytes) and second.txt (200).
    private func twoWindows() throws -> (source: XCUIElement, target: XCUIElement) {
        let source = try fixture.makeSibling("DragSource")
        try fixture.makeFile("first.txt", size: 100, in: source)
        try fixture.makeFile("second.txt", size: 200, in: source)
        try fixture.makeFolder("box")
        try fixture.makeStandardContents()
        try launch(defaults: icons.merging(["selwayNewWindowCustomFolder": source.path]) { _, new in new },
                   expecting: ["box"] + Fixture.standardListing)
        app.typeKey("n", modifierFlags: .command)
        let sourceWindow = app.windows.matching(NSPredicate(format: "title == %@", "DragSource")).firstMatch
        XCTAssertTrue(sourceWindow.waitForExistence(timeout: 10), "no second window on DragSource")
        XCTAssertTrue(item("first.txt", in: identified("fileList", in: sourceWindow)).waitForExistence(timeout: 10),
                      "DragSource doesn't list first.txt")
        let targetWindow = app.windows.matching(NSPredicate(format: "title == %@", Fixture.rootName)).firstMatch
        return (sourceWindow, targetWindow)
    }

    /// What `window`'s status bar says, as `waitForStatus` reads the first window's.
    private func waitForStatus(_ fragment: String, in window: XCUIElement, timeout: TimeInterval = 10,
                               file: StaticString = #filePath, line: UInt = #line) {
        let bar = identified("statusBar", in: window)
        func said() -> String { bar.exists ? [bar.label, bar.value as? String ?? ""].joined(separator: " ") : "" }
        XCTAssertTrue(waitUntil(timeout) { said().contains(fragment) },
                      "\(window.title)'s status bar never said “\(fragment)”; it says “\(said())”",
                      file: file, line: line)
    }

    /// One selected file of `bytes` bytes (under 1 KB), as the status bar says it.
    private static func oneSelected(bytes: Int) -> String {
        "1 selected \u{2014} \(bytes) bytes"
    }

    /// A point in `name`'s cell, level with its name and a point inside the
    /// image's left edge: blank, as the name is narrower than the image (a
    /// 64 pt icon over “beta.txt” leaves about 10 points each side).
    private func besideName(of name: String, in list: XCUIElement? = nil) throws -> XCUICoordinate {
        let list = list ?? fileList
        guard let image = icon(of: name, in: list) else {
            throw XCTSkip("the icons aren't exposed as images, so the blank part of the cell can't be found")
        }
        let label = item(name, in: list)
        let x = image.frame.minX + 1
        // Clear of the name's highlight, which pads it by 4 points.
        guard x < label.frame.minX - 6 else {
            throw XCTSkip("“\(name)” is as wide as its icon at this text size; there is no blank space beside it")
        }
        return list.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x - list.frame.minX, dy: label.frame.midY - list.frame.minY))
    }

    /// A band from the empty space below `first`'s name (the standard folder
    /// fills one row) to the middle of `last`'s name.
    private func band(from first: String, to last: String) throws -> (XCUICoordinate, XCUICoordinate) {
        let from = item(first), to = item(last)
        XCTAssertTrue(from.waitForExistence(timeout: 10) && to.waitForExistence(timeout: 10), "the icons aren't listed")
        let startY = from.frame.maxY + 40
        guard fileList.frame.maxY > startY + 20 else {
            throw XCTSkip("no empty space below the icons to start a band from")
        }
        return (windowPoint(x: from.frame.midX, y: startY), windowPoint(x: to.frame.midX, y: to.frame.midY))
    }

    /// The icon image above `name`, if the grid exposes it.
    private func icon(of name: String, in list: XCUIElement? = nil) -> XCUIElement? {
        let list = list ?? fileList
        let label = item(name, in: list)
        guard label.waitForExistence(timeout: 10) else { return nil }
        return list.images.matching(identifier: "fileIcon").allElementsBoundByIndex.first {
            abs($0.frame.midX - label.frame.midX) < 2 && $0.frame.maxY <= label.frame.minY + 2
        }
    }

    /// Regression: a click on one icon and then, quickly, on a folder opened a
    /// folder. macOS counts clicks within the double-click interval as one
    /// series wherever they land, and the window sent the second click to the
    /// icon clicked first (see IconClickRouting). Finder selects the folder.
    ///
    /// The clicks go as close together as XCUITest allows, which is usually
    /// more than the double-click interval apart (each click waits for the app
    /// to go idle), and XCUITest gives each click its own click count, so this
    /// may not repeat the series a hand makes; the offscreen probe and
    /// ShellIconClickTests cover that. It does check that the second click
    /// selects the folder and leaves the window where it was.
    func testAQuickClickOnAnotherIconSelectsItWithoutOpening() throws {
        try launchWithStandardFixture(defaults: icons)
        let beta = middle(of: item("beta.txt")), folder = middle(of: item(Fixture.folder))
        let started = Date()
        beta.click()
        folder.click()
        let gap = Date().timeIntervalSince(started)
        XCTContext.runActivity(named: "both clicks within \(String(format: "%.2f", gap)) s") { _ in }
        waitForStatus("1 selected")
        XCTAssertFalse(waitUntil(2) { self.shownFolderName == Fixture.folder },
                       "a click on “\(Fixture.folder)” after one on beta.txt opened it")
        XCTAssertTrue(item("alpha.txt").exists, "the window no longer lists the fixture's files")
    }

    func testDoubleClickOpensAFolder() throws {
        try launchWithStandardFixture(defaults: icons)
        doubleClick(item(Fixture.folder))
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }
}
