import Foundation
import Testing
@testable import SelwayCore

@Suite struct ShellPathTests {

    @Test func trailingSlashDoesNotChangeIdentity() {
        let withSlash    = URL(fileURLWithPath: "/tmp/selway/Folder/", isDirectory: true)
        let withoutSlash = URL(fileURLWithPath: "/tmp/selway/Folder", isDirectory: false)
        #expect(withSlash != withoutSlash)               // the bug: URL == misses this
        #expect(ShellPath.same(withSlash, withoutSlash))
        #expect(ShellPath.key(withSlash) == "/tmp/selway/Folder")
    }

    @Test func dotSegmentsAreStandardized() {
        let a = URL(fileURLWithPath: "/tmp/selway/a/../b/./c")
        #expect(ShellPath.key(a) == "/tmp/selway/b/c")
        #expect(ShellPath.same(a, URL(fileURLWithPath: "/tmp/selway/b/c/")))
    }

    @Test func rootKey() {
        #expect(ShellPath.key(URL(fileURLWithPath: "/")) == "/")
    }

    @Test func nilHandling() {
        #expect(ShellPath.same(nil, nil))
        #expect(!ShellPath.same(URL(fileURLWithPath: "/a"), nil))
    }

    @Test func symlinksAreNotResolved() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellPathTests-\(UUID().uuidString)")
        let target = base.appendingPathComponent("target")
        let link   = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(!ShellPath.same(link, target))
        #expect(ShellPath.key(link).hasSuffix("/link"))
    }

    @Test func parentCheckIgnoresSlashes() {
        let parent = URL(fileURLWithPath: "/tmp/selway/Folder/", isDirectory: true)
        let child  = URL(fileURLWithPath: "/tmp/selway/Folder/New Folder 2")
        #expect(ShellPath.isParent(parent, of: child))
        #expect(ShellPath.isParent(URL(fileURLWithPath: "/tmp/selway/Folder"),
                                   of: URL(fileURLWithPath: "/tmp/selway/Folder/sub/", isDirectory: true)))
        #expect(!ShellPath.isParent(parent, of: URL(fileURLWithPath: "/tmp/selway/Folder/sub/deeper")))
        #expect(!ShellPath.isParent(parent, of: parent))
        #expect(ShellPath.isParent(URL(fileURLWithPath: "/"), of: URL(fileURLWithPath: "/tmp")))
        #expect(!ShellPath.isParent(URL(fileURLWithPath: "/"), of: URL(fileURLWithPath: "/")))
    }

    @Test func containsAndIndexUsePathIdentity() {
        let columns = [URL(fileURLWithPath: "/a", isDirectory: true),
                       URL(fileURLWithPath: "/a/b/", isDirectory: true)]
        #expect(ShellPath.contains(columns, URL(fileURLWithPath: "/a/b", isDirectory: false)))
        #expect(ShellPath.firstIndex(of: URL(fileURLWithPath: "/a/"), in: columns) == 0)
        #expect(ShellPath.firstIndex(of: URL(fileURLWithPath: "/a/c"), in: columns) == nil)
    }

    @Test func ancestorChain() {
        let chain = ShellPath.ancestorChain(URL(fileURLWithPath: "/Users/me/Docs/", isDirectory: true))
        #expect(chain.map(ShellPath.key) == ["/", "/Users", "/Users/me", "/Users/me/Docs"])
        #expect(ShellPath.ancestorChain(URL(fileURLWithPath: "/")).map(ShellPath.key) == ["/"])
    }

    @Test func nearestExistingAncestor() {
        let existing: Set<String> = ["/", "/Users", "/Users/me"]
        let gone = URL(fileURLWithPath: "/Users/me/Deleted/Sub")
        let found = ShellPath.nearestExistingAncestor(of: gone) { existing.contains($0) }
        #expect(found.map(ShellPath.key) == "/Users/me")
        #expect(ShellPath.nearestExistingAncestor(of: gone) { _ in false } == nil)
    }

    /// Keys never touch the disk: "/private/…" keeps its prefix whether or not
    /// the path exists (standardizedFileURL stripped it only for existing paths).
    @Test func privatePrefixIsKeptRegardlessOfExistence() throws {
        let existing = try #require(ModelPaths.realPath(FileManager.default.temporaryDirectory))
        #expect(ShellPath.key(existing) == existing.path)
        let missing = existing.appendingPathComponent("gone-\(UUID().uuidString)")
        #expect(ShellPath.key(missing) == missing.path)
        #expect(ShellPath.key(URL(fileURLWithPath: "/private/tmp")) == "/private/tmp")
        #expect(ShellPath.key(URL(fileURLWithPath: "/private/var/x/../y/")) == "/private/var/y")
    }

    @Test func typedPathsResolveAgainstTheShownFolder() {
        // Folder without a trailing slash (how a symlinked folder is listed).
        let shown = URL(fileURLWithPath: "/tmp/selway/Folder", isDirectory: false)
        #expect(ShellPath.resolveTyped("sub", relativeTo: shown).path == "/tmp/selway/Folder/sub")
        #expect(ShellPath.resolveTyped("sub/deeper/", relativeTo: shown).path == "/tmp/selway/Folder/sub/deeper")
        #expect(ShellPath.resolveTyped("../other", relativeTo: shown).path == "/tmp/selway/other")
        #expect(ShellPath.resolveTyped("./a/../b", relativeTo: shown).path == "/tmp/selway/Folder/b")
        #expect(ShellPath.resolveTyped("", relativeTo: shown).path == "/tmp/selway/Folder")
        #expect(ShellPath.resolveTyped("/abs/path/", relativeTo: shown).path == "/abs/path")
        #expect(ShellPath.resolveTyped("/abs/../x", relativeTo: shown).path == "/x")
        let withSlash = URL(fileURLWithPath: "/tmp/selway/Folder/", isDirectory: true)
        #expect(ShellPath.resolveTyped("sub", relativeTo: withSlash).path == "/tmp/selway/Folder/sub")
    }
}

@Test func shellPathSameOrInside() {
    let p = { URL(fileURLWithPath: $0) }
    #expect(ShellPath.isSameOrInside(p("/a/b"), p("/a/b/")))
    #expect(ShellPath.isSameOrInside(p("/a/b/c/d"), p("/a/b")))
    #expect(!ShellPath.isSameOrInside(p("/a/bc"), p("/a/b")))
    #expect(!ShellPath.isSameOrInside(p("/a"), p("/a/b")))
    #expect(ShellPath.isSameOrInside(p("/x"), p("/")))
}
