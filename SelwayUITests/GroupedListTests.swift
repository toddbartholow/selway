import XCTest

/// The same clicks in List view with Group By on: a sectioned SwiftUI List
/// (GroupedListView) rather than a Table. Every fixture item was just made, so
/// they all fall in one "Today" group, sorted by name.
final class GroupedListTests: SelwayUITestCase {

    private let grouped: [String: Any] = ["selwayGroupBy": "Date Modified"]

    func testClickOnANameSelectsTheFile() throws {
        try launchWithStandardFixture(defaults: grouped)
        waitForStatus("Grouped by Date Modified")
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))
        XCTAssertTrue(row("beta.txt", in: fileList).isSelected, "beta.txt's row isn't highlighted")
    }

    func testDoubleClickOnAFolderNameOpensIt() throws {
        try launchWithStandardFixture(defaults: grouped)
        doubleClick(item(Fixture.folder))
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    func testDoubleClickOnAFolderIconOpensIt() throws {
        try launchWithStandardFixture(defaults: grouped)
        iconPoint(of: Fixture.folder).doubleClick()
        waitForFolder(Fixture.folder, listing: Fixture.innerFile)
    }

    func testCommandClickAddsToTheSelection() throws {
        try launchWithStandardFixture(defaults: grouped)
        click(item("alpha.txt"))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .command) { click(item("gamma.txt")) }
        waitForStatus(Self.selection("alpha.txt", "gamma.txt"))
        XCTAssertFalse(row("beta.txt", in: fileList).isSelected, "⌘-click selected the rows in between")
    }

    func testShiftClickExtendsTheSelection() throws {
        try launchWithStandardFixture(defaults: grouped)
        click(item("alpha.txt"))
        waitForStatus(Self.selection("alpha.txt"))
        XCUIElement.perform(withKeyModifiers: .shift) { click(item("gamma.txt")) }
        waitForStatus(Self.selection("alpha.txt", "beta.txt", "gamma.txt"))
    }

    /// Grouped by Name, Greek and Cyrillic names get a group each after Z, in
    /// alphabetical order, and a name starting with a digit goes under # last.
    func testNameGroupsPutOtherAlphabetsAfterZ() throws {
        let names = ["zebra.txt", "Яблоко.txt", "ωμεγα.txt", "1st.txt"]
        for name in names { try fixture.makeFile(name, size: 10) }
        try launch(defaults: ["selwayGroupBy": "Name"], expecting: names)
        waitForStatus("Grouped by Name")

        // The headers' titles, top to bottom, read from one snapshot of the list.
        let headers = ["Z", "Ω", "Я", "#"]
        var shown: [String] = []
        let arrived = waitUntil(5) {
            guard let list = try? self.fileList.snapshot() else { return false }
            var texts: [XCUIElementSnapshot] = []
            func visit(_ element: XCUIElementSnapshot) {
                if element.elementType == .staticText { texts.append(element) }
                element.children.forEach(visit)
            }
            visit(list)
            shown = texts.sorted { $0.frame.minY < $1.frame.minY }
                .map { $0.label.isEmpty ? (($0.value as? String) ?? "") : $0.label }
                .filter(headers.contains)
            return shown == headers
        }
        XCTAssertTrue(arrived, "the groups are \(shown), not \(headers)")
    }

    /// Kana names get their gojuon row headers in Group by Name.
    func testNameGroupsPutJapaneseKanaInGojuonRows() throws {
        let names = ["zebra.txt", "かな.txt", "あさ.txt", "カメラ写真.txt"]
        for name in names { try fixture.makeFile(name, size: 10) }
        try launch(defaults: ["selwayGroupBy": "Name"], expecting: names)
        waitForStatus("Grouped by Name")

        let headers = ["Z", "あ", "か"]
        var shown: [String] = []
        let arrived = waitUntil(5) {
            guard let list = try? self.fileList.snapshot() else { return false }
            var texts: [XCUIElementSnapshot] = []
            func visit(_ element: XCUIElementSnapshot) {
                if element.elementType == .staticText { texts.append(element) }
                element.children.forEach(visit)
            }
            visit(list)
            shown = texts.sorted { $0.frame.minY < $1.frame.minY }
                .map { $0.label.isEmpty ? (($0.value as? String) ?? "") : $0.label }
                .filter(headers.contains)
            return shown == headers
        }
        XCTAssertTrue(arrived, "the groups are \(shown), not \(headers)")
    }
}
