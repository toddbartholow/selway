import Foundation
import Testing
@testable import SelwayCore

/// Paths as the policy reports them (parse standardizes: /private/var → /var).
private func std(_ url: URL) -> String { URL(fileURLWithPath: url.path).standardizedFileURL.path }

private func shown(_ d: FileOpsURLDecision) -> String? {
    if case .show(let folder) = d { return std(folder) }
    return nil
}

private func performed(_ d: FileOpsURLDecision) -> (FileOpsURLAction, String, Bool)? {
    if case let .perform(action, folder, confirm) = d { return (action, std(folder), confirm) }
    return nil
}

private func request(_ action: FileOpsURLAction, _ path: String) throws -> FileOpsURLRequest {
    let url = try #require(FileOpsURLScheme.url(for: action, path: path))
    return try #require(FileOpsURLScheme.parse(url))
}

/// `open` on an app only shows the folder it is in; it never opens it.
@Test func fileOpsURLOpenOnAppShowsItsFolder() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let app = try dir.dir("Tool.app/Contents/MacOS")
    _ = app
    let toolApp = dir.url.appendingPathComponent("Tool.app")
    for own in [false, true] {
        let d = FileOpsURLPolicy.decide(try request(.open, toolApp.path), fromOwnExtension: own)
        #expect(shown(d) == std(dir.url))
    }
    // A plain folder inside the bundle is just shown (still nothing launched).
    let inner = toolApp.appendingPathComponent("Contents/MacOS")
    #expect(shown(FileOpsURLPolicy.decide(try request(.open, inner.path), fromOwnExtension: false)) == std(inner))
    // A document shows its folder; a plain folder is shown itself.
    let doc = try dir.file("docs/a.txt")
    #expect(shown(FileOpsURLPolicy.decide(try request(.open, doc.path), fromOwnExtension: false))
            == std(dir.url.appendingPathComponent("docs")))
    #expect(shown(FileOpsURLPolicy.decide(try request(.open, dir.url.path), fromOwnExtension: false)) == std(dir.url))
}

/// Side effects (every action with hasSideEffects) are confirmed unless the
/// request came from Selway's own extension, and need a plain folder.
@Test func fileOpsURLSideEffectsNeedConfirmation() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let folder = try dir.dir("work")
    _ = try dir.dir("Tool.app")
    for action in FileOpsURLAction.allCases where action.hasSideEffects {
        let asked = performed(FileOpsURLPolicy.decide(try request(action, folder.path), fromOwnExtension: false))
        #expect(asked?.0 == action && asked?.1 == std(folder) && asked?.2 == true)
        let direct = performed(FileOpsURLPolicy.decide(try request(action, folder.path), fromOwnExtension: true))
        #expect(direct?.0 == action && direct?.1 == std(folder) && direct?.2 == false)
        #expect(FileOpsURLPolicy.confirmation(for: action, folder: folder) != nil)
        #expect(FileOpsURLPolicy.decide(try request(action, dir.url.appendingPathComponent("Tool.app").path),
                                        fromOwnExtension: true) == .ignore)
        #expect(FileOpsURLPolicy.decide(try request(action, dir.url.appendingPathComponent("missing").path),
                                        fromOwnExtension: true) == .ignore)
    }
    #expect(FileOpsURLPolicy.decide(try request(.open, dir.url.appendingPathComponent("missing").path),
                                    fromOwnExtension: true) == .ignore)
}

@Test func fileOpsURLConfirmationShowsFullEscapedPath() throws {
    let folder = URL(fileURLWithPath: "/Users/x/Evil\nClick Create Folder\u{202E}txt")
    let c = try #require(FileOpsURLPolicy.confirmation(for: .newFolder, folder: folder))
    #expect(c.detail.hasPrefix("/Users/x/Evil\\u{A}Click Create Folder\\u{202E}txt\n"))
    #expect(!c.question.contains("Evil"))
    let t = try #require(FileOpsURLPolicy.confirmation(for: .terminal, folder: URL(fileURLWithPath: "/tmp/repo")))
    #expect(t.detail.contains("/tmp/repo"))
    #expect(t.detail.contains("git hooks"))
    #expect(FileOpsURLPolicy.confirmation(for: .open, folder: folder) == nil)
}

/// Files and folders opened with Selway: an app (or other package) is
/// revealed in its folder, never launched.
@Test func fileOpsOpenWithRevealsPackages() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let app = dir.url.appendingPathComponent("Tool.app")
    try dir.dir("Tool.app/Contents")
    let folder = try dir.dir("plain")
    let md = try dir.file("notes.md")
    let bin = dir.url.appendingPathComponent("blob.bin")
    try Data([0, 1, 2, 0xFF, 0, 0xFE]).write(to: bin)
    guard case let .reveal(item, inFolder)? = FileOpsURLPolicy.decideOpen(app) else {
        Issue.record("an app must be revealed, never opened"); return
    }
    #expect(item.path == app.path && inFolder.path == dir.url.path)
    guard case .browse(let browsed)? = FileOpsURLPolicy.decideOpen(folder) else { Issue.record("browse"); return }
    #expect(browsed.path == folder.path)
    guard case .markdown(let reader)? = FileOpsURLPolicy.decideOpen(md) else { Issue.record("markdown"); return }
    #expect(reader.path == md.path)
    guard case let .reveal(file, parent)? = FileOpsURLPolicy.decideOpen(bin) else { Issue.record("reveal"); return }
    #expect(file.path == bin.path && parent.path == dir.url.path)
    #expect(FileOpsURLPolicy.decideOpen(dir.url.appendingPathComponent("missing")) == nil)
}

@Test func fileOpsURLRoundTripWithTrailingSlash() throws {
    for action in FileOpsURLAction.allCases {
        let url = try #require(FileOpsURLScheme.url(for: action, path: "/Users/x/My Folder/"))
        #expect(url.absoluteString.hasSuffix("My%20Folder/"))
        #expect(FileOpsURLScheme.parse(url) == FileOpsURLRequest(action: action, path: "/Users/x/My Folder"))
    }
    let root = try #require(FileOpsURLScheme.url(for: .open, path: "/"))
    #expect(FileOpsScheme_parsePath(root) == "/")
}

private func FileOpsScheme_parsePath(_ url: URL) -> String? { FileOpsURLScheme.parse(url)?.path }

/// Extract Here is offered only for what Selway extracts itself.
@Test(arguments: [("a.zip", true), ("a.tar.gz", true), ("a.tbz2", true),
                  ("a.pkg", false), ("a.dmg", false), ("a.7z", false), ("a.rar", false), ("a.gz", false)])
func fileOpsIsArchiveOnlyForOwnFormats(name: String, offered: Bool) {
    #expect(FileItem.fixture(name).isArchive == offered)
}

/// A link's action runs only on the folder that was approved: one renamed away, replaced
/// by another folder, or swapped for a symlink while the dialog was up is refused.
@Test func fileOpsURLFolderIdentityNoticesASwap() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let fm = FileManager.default
    let folder = try dir.dir("repo")
    let elsewhere = try dir.dir("elsewhere")
    let approved = try #require(FileOpsURLPolicy.FolderIdentity(folder))
    #expect(approved.matches(folder))
    #expect(approved.matches(URL(fileURLWithPath: folder.path + "/")))

    // Renamed away and replaced by a new, empty folder of the same name.
    try fm.moveItem(at: folder, to: dir.url.appendingPathComponent("repo-old"))
    #expect(!approved.matches(folder))
    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
    #expect(!approved.matches(folder))

    // Replaced by a symlink to another folder.
    try fm.removeItem(at: folder)
    try fm.createSymbolicLink(at: folder, withDestinationURL: elsewhere)
    #expect(!approved.matches(folder))

    // Gone, or a file now.
    try fm.removeItem(at: folder)
    #expect(!approved.matches(folder))
    try dir.file("repo")
    #expect(!approved.matches(folder))
    #expect(FileOpsURLPolicy.FolderIdentity(folder) == nil)

    // A folder reached through a symlink pins the folder it points to.
    let link = try dir.link("link", to: elsewhere.path)
    let viaLink = try #require(FileOpsURLPolicy.FolderIdentity(link))
    #expect(viaLink == FileOpsURLPolicy.FolderIdentity(elsewhere))
    try fm.removeItem(at: link)
    try fm.createSymbolicLink(at: link, withDestinationURL: dir.url.appendingPathComponent("repo-old"))
    #expect(!viaLink.matches(link))
}
