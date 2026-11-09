import Foundation
import Testing
@testable import SelwayCore

@Suite struct FileOpsExtensionChangeTests {
    private typealias C = FileOpsExtensionChange

    @Test func detectsChangesAddsAndRemovals() {
        #expect(C.detect(oldName: "notes.txt", newName: "ideas.txt") == nil)
        #expect(C.detect(oldName: "notes.txt", newName: "notes.TXT") == nil)    // case only
        #expect(C.detect(oldName: "notes.txt", newName: "notes.md") == .changing(from: "txt", to: "md"))
        #expect(C.detect(oldName: "notes", newName: "notes.md") == .adding("md"))
        #expect(C.detect(oldName: "notes.txt", newName: "notes") == .removing("txt"))
        #expect(C.detect(oldName: "a.tar.gz", newName: "a.tar.bz2") == .changing(from: "gz", to: "bz2"))
    }

    @Test func dotsThatArentExtensions() {
        #expect(C.extension(of: ".zshrc") == nil)
        #expect(C.extension(of: "notes.") == nil)
        #expect(C.extension(of: "Chapter 1. Intro") == nil)
        #expect(C.detect(oldName: ".zshrc", newName: ".bashrc") == nil)
        #expect(C.detect(oldName: "Chapter 1", newName: "Chapter 1. Intro") == nil)
    }

    @Test func keepingTheOldExtensionKeepsTheOtherEdits() {
        let change = C.changing(from: "txt", to: "md")
        #expect(change.keepingOldExtension(newName: "ideas.md") == "ideas.txt")
        #expect(C.adding("md").keepingOldExtension(newName: "notes 2.md") == "notes 2")
        #expect(C.removing("txt").keepingOldExtension(newName: "draft") == "draft.txt")
        // A trailing dot isn't an extension: keeping ".txt" gives "b.txt", not "b..txt".
        #expect(C.detect(oldName: "a.txt", newName: "b.") == .removing("txt"))
        #expect(C.removing("txt").keepingOldExtension(newName: "b.") == "b.txt")
        #expect(C.removing("txt").keepingOldExtension(newName: "b..") == "b.txt")
    }

    @Test func wording() {
        let change = C.changing(from: "txt", to: "md")
        #expect(change.question == "Are you sure you want to change the extension from “.txt” to “.md”?")
        #expect(change.keepTitle == "Keep .txt" && change.useTitle == "Use .md")
        #expect(C.adding("md").keepTitle == "Don’t Add" && C.adding("md").useTitle == "Add .md")
        #expect(C.removing("txt").keepTitle == "Keep .txt" && C.removing("txt").useTitle == "Remove")
    }
}
