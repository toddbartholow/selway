import XCTest

/// Keys taken by hidden buttons: ⌘S in the Markdown reader's Edit mode and in
/// the text editor, and Escape on the error sheet. The buttons have no label
/// (an empty label made an empty key in the String Catalog), so these check
/// that the shortcuts still reach them. Also the reader's Read/Edit switch,
/// which VoiceOver names "Mode".
final class HiddenShortcutTests: SelwayUITestCase {

    /// The window titled `name`, or "• name" while it has unsaved changes.
    private func window(showing name: String) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title == %@ OR title == %@", name, "• " + name)).firstMatch
    }

    private func contents(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: Markdown reader

    func testCommandSSavesInTheMarkdownEditor() throws {
        let note = fixture.root.appendingPathComponent("note.md")
        try Data("# Note\n".utf8).write(to: note)
        try launch(expecting: ["note.md"])

        doubleClick(item("note.md"))
        // The reader's title is the name without its extension.
        let reader = window(showing: "note")
        XCTAssertTrue(reader.waitForExistence(timeout: 10), "a double-click on note.md opened no reader")

        // The Read/Edit switch: a segmented control VoiceOver names "Mode".
        let mode = reader.descendants(matching: .any).matching(Self.named("Mode")).firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 5), "the Read/Edit switch isn't named Mode")
        let edit = mode.descendants(matching: .any).matching(Self.named("Edit")).firstMatch
        XCTAssertTrue(edit.exists, "the Mode switch has no Edit segment")
        click(edit)

        let editor = reader.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Edit mode shows no text view")
        click(editor)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("Saved by Command-S")
        XCTAssertTrue(waitUntil(5) { reader.title.hasPrefix("• ") }, "typing didn't mark the note unsaved")

        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(waitUntil(10) { self.contents(of: note).contains("Saved by Command-S") },
                      "⌘S didn't save note.md; it holds \(contents(of: note).debugDescription)")
        XCTAssertTrue(waitUntil(5) { reader.title == "note" }, "the title still shows unsaved changes")
    }

    // MARK: Text editor

    func testCommandSSavesInTheTextEditor() throws {
        let notes = fixture.root.appendingPathComponent("notes.txt")
        try Data("first line\n".utf8).write(to: notes)
        try launch(expecting: ["notes.txt"])

        doubleClick(item("notes.txt"))
        let editor = window(showing: "notes.txt")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "a double-click on notes.txt opened no editor")
        let web = editor.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10), "the editor window shows no editor")
        XCTAssertTrue(waitUntil(10) {
            web.descendants(matching: .any).matching(Self.named("first line")).firstMatch.exists
        }, "the editor didn't show the file's text")

        click(web)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("Saved by Command-S")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(waitUntil(10) { self.contents(of: notes).contains("Saved by Command-S") },
                      "⌘S didn't save notes.txt; it holds \(contents(of: notes).debugDescription)")
    }

    // MARK: Error sheet

    /// A name with a slash can't be used, so the rename shows the error sheet,
    /// which Escape closes as OK does.
    func testEscapeClosesTheErrorSheet() throws {
        try launchWithStandardFixture()
        click(item("beta.txt"))
        waitForStatus(Self.selection("beta.txt"))
        app.typeKey(.return, modifierFlags: [])
        let field = fileList.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "no rename field appeared")
        XCTAssertTrue(waitUntil(3) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true },
                      "the rename field didn't take the keys")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("a/b.txt")
        app.typeKey(.return, modifierFlags: [])

        let sheet = browserWindow.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "an invalid name showed no error")
        XCTAssertTrue(text("Error", in: sheet).exists, "the sheet isn't the error sheet")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(5) { !sheet.exists }, "Escape didn't close the error sheet")
        XCTAssertTrue(fixture.exists("beta.txt"))
    }
}
