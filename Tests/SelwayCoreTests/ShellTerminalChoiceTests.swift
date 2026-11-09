import Foundation
import Testing
@testable import SelwayCore

// Which terminal app Open in Terminal, Claude Code and Codex use, and the
// fallback to Terminal when the chosen one is missing.

@Suite struct ShellTerminalChoiceTests {
    private static let apps: [String: URL] = [
        "com.apple.Terminal":     URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
        "com.googlecode.iterm2":  URL(fileURLWithPath: "/Applications/iTerm.app"),
        "com.mitchellh.ghostty":  URL(fileURLWithPath: "/Applications/Ghostty.app"),
        "dev.warp.Warp":          URL(fileURLWithPath: "/Applications/Warp.app"),
    ]

    private func resolve(_ choice: TerminalApp, custom: String? = nil, installed: [String: URL] = apps,
                         existing: Set<String> = []) -> TerminalResolution {
        TerminalChoice.resolve(choice, customPath: custom, locate: { installed[$0] }, isApp: existing.contains)
    }

    @Test func storedChoiceDefaultsToTerminal() {
        #expect(TerminalChoice.fromStorage(nil) == .terminal)
        #expect(TerminalChoice.fromStorage("Hyper") == .terminal)
        #expect(TerminalChoice.fromStorage("ghostty") == .ghostty)
    }

    @Test func installedAppsAreUsed() {
        let iTerm = resolve(.iTerm)
        #expect(iTerm.app == .iTerm && iTerm.name == "iTerm" && !iTerm.fellBack)
        #expect(iTerm.url?.lastPathComponent == "iTerm.app")
        #expect(iTerm.runMethod == .openScript)
        #expect(resolve(.ghostty).url?.lastPathComponent == "Ghostty.app")
        // Warp is found under either of its bundle identifiers.
        #expect(resolve(.warp).url?.lastPathComponent == "Warp.app")
        let terminal = resolve(.terminal)
        #expect(terminal.app == .terminal && !terminal.fellBack && terminal.runMethod == .terminalDoScript)
    }

    @Test(arguments: [TerminalApp.iTerm, .ghostty, .warp])
    func aMissingAppFallsBackToTerminal(_ choice: TerminalApp) {
        let r = resolve(choice, installed: ["com.apple.Terminal": Self.apps["com.apple.Terminal"]!])
        #expect(r.app == .terminal && r.fellBack)
        #expect(r.url?.lastPathComponent == "Terminal.app")
        #expect(r.runMethod == .terminalDoScript)
        #expect(TerminalChoice.fallbackNote(for: choice, customPath: nil, resolution: r)
                == "\(choice.name) isn’t installed, so Selway uses Terminal.")
    }

    @Test func anOtherAppIsUsedWhileItExists() {
        let kitty = "/Applications/kitty.app"
        let r = resolve(.other, custom: kitty, existing: [kitty])
        #expect(r.app == .other && r.name == "kitty" && !r.fellBack)
        #expect(r.url?.path == kitty)
        // Not known to run a script it opens: the tools start in Terminal.
        #expect(r.runMethod == .terminalDoScript && r.runnerName == "Terminal")
        #expect(r.runnerNote != nil)
        #expect(TerminalChoice.fallbackNote(for: .other, customPath: kitty, resolution: r) == nil)
    }

    @Test func aDeletedOrUnchosenOtherAppFallsBackToTerminal() {
        let gone = resolve(.other, custom: "/Applications/Alacritty.app")
        #expect(gone.app == .terminal && gone.fellBack)
        #expect(TerminalChoice.fallbackNote(for: .other, customPath: "/Applications/Alacritty.app", resolution: gone)
                == "Alacritty can’t be found, so Selway uses Terminal. Choose the app again.")
        let none = resolve(.other, custom: "")
        #expect(none.fellBack)
        #expect(TerminalChoice.fallbackNote(for: .other, customPath: "", resolution: none)
                == "No app chosen yet, so Selway uses Terminal.")
    }

    /// Only apps checked to run a script they're asked to open get the tools;
    /// Warp opens folders, but Claude Code and Codex start in Terminal.
    @Test func toolsRunOnlyInAppsThatRunOpenedScripts() {
        #expect(resolve(.iTerm).runMethod == .openScript && resolve(.iTerm).runnerName == "iTerm")
        #expect(resolve(.ghostty).runMethod == .openScript && resolve(.ghostty).runnerNote == nil)
        let warp = resolve(.warp)
        #expect(warp.app == .warp && warp.url?.lastPathComponent == "Warp.app")
        #expect(warp.runMethod == .terminalDoScript && warp.runnerName == "Terminal")
        #expect(warp.runnerNote?.hasPrefix("Claude Code and the Codex command-line tool open in Terminal") == true)
        #expect(resolve(.terminal).runnerNote == nil)
    }

    @Test func staleScriptFoldersAreSweptOnlyWhenOldAndOurs() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let fm = FileManager.default
        let old = try dir.dir("selway-terminal-old12345")
        try Data("x".utf8).write(to: old.appendingPathComponent("run.command"))
        let fresh = try dir.dir("selway-terminal-new12345")
        let other = try dir.dir("someone-else-old")
        let file = try dir.file("selway-terminal-file")
        let dayAgo = Date().addingTimeInterval(-2 * 24 * 3600)
        for url in [old, other, file] { try fm.setAttributes([.modificationDate: dayAgo], ofItemAtPath: url.path) }
        #expect(FileOpsSafety.staleTerminalScriptFolders(in: dir.url).map(\.lastPathComponent) == ["selway-terminal-old12345"])
        #expect(FileOpsSafety.removeStaleTerminalScripts(in: dir.url) == 1)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: fresh.path) && fm.fileExists(atPath: other.path) && fm.fileExists(atPath: file.path))
    }

    @Test func terminalChosenThroughOtherIsStillTerminal() {
        let path = "/System/Applications/Utilities/Terminal.app"
        let r = resolve(.other, custom: path, existing: [path])
        #expect(r.app == .terminal && !r.fellBack && r.runMethod == .terminalDoScript)
        // Ghostty picked with Other… still runs the tools itself.
        let ghostty = resolve(.other, custom: "/Applications/Ghostty.app", existing: ["/Applications/Ghostty.app"])
        #expect(ghostty.app == .ghostty && ghostty.name == "Ghostty" && ghostty.runMethod == .openScript)
    }

    @Test func withoutEvenTerminalThereIsNoURL() {
        let r = resolve(.ghostty, installed: [:])
        #expect(r.app == .terminal && r.url == nil && r.fellBack)
    }

    @Test func appNames() {
        #expect(TerminalChoice.appName(atPath: "/Applications/WezTerm.app") == "WezTerm")
        #expect(TerminalChoice.appName(atPath: "/Applications/WezTerm.app/") == "WezTerm")
        #expect(TerminalChoice.appName(atPath: "/opt/tools/term") == "term")
    }

    /// Apps other than Terminal are handed the script to open, so it needs an
    /// extension they recognise; the path must still be one literal shell word.
    @Test func scriptsCanBeNamedForOpening() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let script = try FileOpsSafety.makeTerminalScript(cd: "/tmp", run: "/bin/pwd", named: "run.command", in: dir.url)
        defer { try? FileManager.default.removeItem(at: script.directory) }
        #expect(script.script.lastPathComponent == "run.command")
        #expect(FileOpsSafety.isPortableShellWord(script.typedCommand))
        let source = try String(contentsOf: script.script, encoding: .utf8)
        #expect(source.contains(FileOpsSafety.shellQuoted(script.script.path)))   // it deletes itself
        #expect(FileManager.default.isExecutableFile(atPath: script.script.path))
    }
}
