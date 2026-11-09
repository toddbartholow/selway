import Foundation
import Testing
@testable import SelwayCore

struct ShellWatchChangesTests {

    @Test func entriesAreCollectedByFolder() {
        var changes = ShellWatchChanges()
        changes.entryChanged("a.log", in: "/f")
        changes.entryChanged("b.log", in: "/f")
        changes.entryChanged("a.log", in: "/f")
        changes.entryChanged("c.txt", in: "/g")
        #expect(changes.entries == ["/f": ["a.log", "b.log"], "/g": ["c.txt"]])
        #expect(changes.folders.isEmpty)
    }

    /// A folder reloaded whole reads its entries anyway, whichever came first.
    @Test func aFolderChangeTakesInItsEntries() {
        var changes = ShellWatchChanges()
        changes.entryChanged("a.log", in: "/f")
        changes.folderChanged("/f")
        changes.entryChanged("b.log", in: "/f")
        changes.entryChanged("c.txt", in: "/g")
        #expect(changes.folders == ["/f"])
        #expect(changes.entries == ["/g": ["c.txt"]])
    }

    /// Hundreds of files written at once (an unzip, a build) cost less as one listing.
    @Test func tooManyEntriesReloadTheFolder() {
        var changes = ShellWatchChanges()
        for i in 0..<ShellWatchChanges.maxEntries { changes.entryChanged("f\(i)", in: "/f") }
        #expect(changes.folders.isEmpty)
        #expect(changes.entries["/f"]?.count == ShellWatchChanges.maxEntries)
        changes.entryChanged("one-more", in: "/f")
        #expect(changes.folders == ["/f"])
        #expect(changes.entries.isEmpty)
    }

    @Test func takeEmptiesTheBatch() {
        var changes = ShellWatchChanges()
        changes.folderChanged("/f")
        changes.entryChanged("a", in: "/g")
        let taken = changes.take()
        #expect(taken.folders == ["/f"])
        #expect(taken.entries == ["/g": ["a"]])
        #expect(changes.isEmpty)
        #expect(changes == ShellWatchChanges())
    }

    @Test func removeForgetsAFolder() {
        var changes = ShellWatchChanges()
        changes.folderChanged("/f")
        changes.entryChanged("a", in: "/g")
        changes.remove("/f")
        changes.remove("/g")
        #expect(changes.isEmpty)
    }

    // MARK: Event paths

    @Test func splitsAPathIntoFolderAndName() {
        #expect(ShellEventPath.split("/private/tmp/a.log")! == ("/private/tmp", "a.log"))
        #expect(ShellEventPath.split("/a.log")! == ("/", "a.log"))
        #expect(ShellEventPath.split("/private/tmp/sub/")! == ("/private/tmp", "sub"))
        #expect(ShellEventPath.split("/") == nil)
        #expect(ShellEventPath.split("") == nil)
        #expect(ShellEventPath.split("relative/a.log") == nil)
    }

    @Test func splitKeepsNonASCIINames() {
        #expect(ShellEventPath.split("/Users/me/Café/naïve.txt")! == ("/Users/me/Café", "naïve.txt"))
        #expect(ShellEventPath.split("//") == nil)
    }

    @Test func sameOrInsideIsByWholeComponents() {
        #expect(ShellEventPath.isSameOrInside("/a/b", "/a/b"))
        #expect(ShellEventPath.isSameOrInside("/a/b/c", "/a/b"))
        #expect(!ShellEventPath.isSameOrInside("/a/bc", "/a/b"))
        #expect(!ShellEventPath.isSameOrInside("/a", "/a/b"))
        #expect(ShellEventPath.isSameOrInside("/anything", "/"))
    }

    // MARK: Event folders

    @Test func eventFoldersPassOnlyEntriesDirectlyInside() {
        let folders = ShellEventFolders(["/Users/me/Downloads", "/private/tmp"])
        #expect(folders.holdsEntry("/Users/me/Downloads/a.dmg"))
        #expect(folders.holdsEntry("/private/tmp/x/"))                    // a trailing slash
        #expect(!folders.holdsEntry("/Users/me/Downloads/sub/a.dmg"))     // deeper
        #expect(!folders.holdsEntry("/Users/me/Downloads"))               // the folder itself
        #expect(!folders.holdsEntry("/Users/me/Downloadz/a.dmg"))         // same length, other folder
        #expect(!folders.holdsEntry("/Users/me/a.dmg"))
        #expect(!folders.holdsEntry("/"))
        #expect(!folders.holdsEntry(""))
        #expect(!folders.holdsEntry("relative/a"))
    }

    @Test func eventFoldersHandleTheRoot() {
        let root = ShellEventFolders(["/"])
        #expect(root.holdsEntry("/Users"))
        #expect(root.holdsEntry("/tmp/"))
        #expect(!root.holdsEntry("/Users/me"))
        #expect(!root.holdsEntry("/"))
    }

    /// A parent spelled with other bytes for the same characters (é composed or
    /// decomposed) is left to the String comparison, which treats them as equal.
    @Test func eventFoldersLetNonASCIIParentsThrough() {
        let composed = "/Users/me/Caf\u{E9}", decomposed = "/Users/me/Cafe\u{301}"
        let folders = ShellEventFolders([composed])
        #expect(folders.holdsEntry(composed + "/a.txt"))
        #expect(folders.holdsEntry(decomposed + "/a.txt"))
        #expect(ShellEventPath.split(decomposed + "/a.txt")?.folder == composed)
        #expect(!folders.holdsEntry("/Users/me/Plain/a.txt"))
    }
}
