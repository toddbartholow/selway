import Foundation
import Testing
@testable import SelwayCore

@Test(arguments: [
    "/Users/x/R&D",
    "/Users/x/a=b",
    "/Users/x/1+1",
    "/Users/x/100%",
    "/Users/x/%41",
    "/Users/x/#hash",
    "/Users/x/My Folder",
    "/Users/x/café",
    "/Users/x/cafe\u{301}",
    "/Users/x/q?x=1&y=2;z",
    "/Users/x/emoji 📁",
    "/",
])
func fileOpsURLRoundTrip(path: String) throws {
    for action in FileOpsURLAction.allCases {
        let url = try #require(FileOpsURLScheme.url(for: action, path: path))
        let request = try #require(FileOpsURLScheme.parse(url))
        #expect(request.action == action)
        #expect(request.path == path)
    }
}

@Test func fileOpsURLParseStandardizesPath() throws {
    let url = try #require(URL(string: "selway://open?path=/Users/x/../y/./z"))
    #expect(FileOpsURLScheme.parse(url)?.path == "/Users/y/z")
}

@Test(arguments: [
    "selway://launch?path=/Applications/Calculator.app",   // unknown action
    "selway://open?path=relative/path",                     // not absolute
    "selway://open",                                        // no path
    "selway://open?path=",                                  // empty path
    "selway://open?path=/a&path=/b",                        // ambiguous
    "selway://open?path=/Users/x/R&D",                      // old, broken encoding
    "selway://open?path=/a&x=1",                            // extra item
    "selway://open?file=/a",                                // wrong item name
    "selway://open/extra?path=/a",                          // URL path
    "selway://open?path=/a#frag",                           // fragment
    "selway://user@open?path=/a",                           // user info
    "selway://open:99?path=/a",                             // port
    "selway://open?path=/a%00b",                            // NUL
    "https://open?path=/a",                                     // other scheme
    "selway:open?path=/a",                                  // no host
])
func fileOpsURLRejects(string: String) throws {
    let url = try #require(URL(string: string))
    #expect(FileOpsURLScheme.parse(url) == nil)
}

@Test func fileOpsURLActionsWithSideEffects() {
    #expect(!FileOpsURLAction.open.hasSideEffects)
    #expect(FileOpsURLAction.newFolder.hasSideEffects)
    #expect(FileOpsURLAction.terminal.hasSideEffects)
}

@Test func fileOpsURLRefusesRelativeBuild() {
    #expect(FileOpsURLScheme.url(for: .open, path: "relative") == nil)
}

// MARK: - Terminal command screening

@Test(arguments: [
    "/Users/x/line\nbreak",
    "/Users/x/carriage\rreturn",
    "/Users/x/tab\tname",
    "/Users/x/esc\u{1B}]0;title\u{07}",
    "/Users/x/del\u{7F}",
    "/Users/x/csi\u{9B}2J",
    "/Users/x/nel\u{85}",
])
func fileOpsTerminalRefusesControlCharacters(path: String) throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    #expect(throws: FileOpsError.unsafePath) {
        try FileOpsSafety.makeTerminalScript(cd: path, run: "/bin/pwd", in: dir.url)
    }
    #expect(throws: FileOpsError.unsafePath) {
        try FileOpsSafety.makeTerminalScript(cd: "/ok", run: path, in: dir.url)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).isEmpty)
}

@Test func fileOpsTerminalScriptQuotesForZsh() throws {
    let source = try FileOpsSafety.terminalScriptSource(cd: "/Users/x/it's $HOME `id` \"q\" \\",
                                                        run: "/usr/local/bin/claude", arguments: ["."])
    #expect(source.hasPrefix("#!/bin/zsh -f\n"))
    #expect(source.contains(#"cd -- '/Users/x/it'\''s $HOME `id` "q" \' || exit"#))
    #expect(source.contains("'/usr/local/bin/claude' '.'\n"))
    #expect(FileOpsSafety.appleScriptStringLiteral(#"a"b\c"#) == #""a\"b\\c""#)
}

#if os(macOS)
/// The line typed into Terminal is just the path of a private script, so the
/// user's login shell (fish, tcsh, ...) never parses the folder name: fish
/// treats \' inside single quotes as an escape and tcsh expands ! there, so a
/// folder like "a\" or "x!y" used to break out of `cd '<folder>'`. The script
/// itself runs under zsh, whose quoting the script is written for.
@Test func fileOpsTerminalScriptKeepsFolderNameAwayFromLoginShell() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let hostile = #"a\'; touch PWNED #!x $(touch PWNED2) \"#
    let folder = try dir.dir(hostile)
    let base = try dir.dir("tmp")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
    let shells = ["/bin/sh", "/bin/zsh", "/bin/tcsh", "/bin/bash"]
        .filter { FileManager.default.isExecutableFile(atPath: $0) }
    for shell in shells {
        let script = try FileOpsSafety.makeTerminalScript(cd: folder.path, run: "/bin/pwd", in: base)
        #expect(script.typedCommand.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) },
                "typed: \(script.typedCommand)")
        #expect(script.typedCommand == script.script.path)
        let attrs = try FileManager.default.attributesOfItem(atPath: script.directory.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: script.script.path)
        #expect((fileAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-c", script.typedCommand]
        p.currentDirectoryURL = dir.url
        // The script ends by starting the user's shell in the folder; stand-in.
        p.environment = ["SHELL": "/usr/bin/true", "PATH": "/usr/bin:/bin"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(shell)")
        #expect(printed == folder.path + "\n", "\(shell) printed \(printed)")
        #expect(!FileManager.default.fileExists(atPath: script.directory.path), "script removes itself")
    }
    for name in ["PWNED", "PWNED2"] {
        #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent(name).path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
}
#endif
