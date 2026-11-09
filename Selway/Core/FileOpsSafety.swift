import Foundation

/// Quoting and screening for text that ends up in a shell, an AppleScript
/// source string, or typed into a Terminal window.
enum FileOpsSafety {

    /// True if `s` contains a C0 control (including tab and newline), DEL, or a
    /// C1 control. Typed into Terminal via `do script`, these act as keystrokes
    /// (a newline runs whatever follows; ESC/C1 sequences drive the terminal),
    /// so no amount of shell quoting makes them safe.
    static func containsControlCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    /// Single-quotes `s` for a POSIX shell — safe against $, `, !, spaces, quotes.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes `s` and wraps it in double quotes so it is a single AppleScript
    /// string literal — backslashes first, then quotes.
    static func appleScriptStringLiteral(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A script Selway wrote for one Terminal window, and the line to type
    /// there to run it.
    struct TerminalScript: Equatable {
        /// Private (0700) folder holding only `script`; the script deletes both.
        let directory: URL
        let script: URL
        /// What Terminal's shell is given: the script's path, which contains
        /// only letters, digits and "/._-", so it means the same in any shell.
        let typedCommand: String
    }

    /// Source of a zsh script that changes to `directory`, runs `executable`
    /// with `arguments`, then starts the user's shell there. The folder name is
    /// quoted for zsh (POSIX single quotes; -f skips the user's zsh config and
    /// its quoting options), never for the user's login shell. Refuses (throws
    /// `.unsafePath`) control characters in any part.
    static func terminalScriptSource(cd directory: String, run executable: String,
                                     arguments: [String] = [], removing script: URL? = nil) throws -> String {
        let parts = [directory, executable] + arguments + (script.map { [$0.path] } ?? [])
        if parts.contains(where: containsControlCharacters) { throw FileOpsError.unsafePath }
        var lines = ["#!/bin/zsh -f", "# Written by Selway for one Terminal window; it deletes itself."]
        if let script {
            lines.append("/bin/rm -f -- \(shellQuoted(script.path)); "
                         + "/bin/rmdir -- \(shellQuoted(script.deletingLastPathComponent().path))")
        }
        lines += [
            "cd -- \(shellQuoted(directory)) || exit",
            // A handler (unlike ignoring it) lets Ctrl-C reach the tool without ending the script.
            "trap : INT",
            ([executable] + arguments).map(shellQuoted).joined(separator: " "),
            "trap - INT",
            #"exec "${SHELL:-/bin/zsh}""#,
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes `terminalScriptSource` to a new private folder in `base` (the
    /// user's temporary folder by default) and returns it. The typed line is
    /// only the script's path, so the login shell (fish, tcsh, ...) never parses
    /// the folder name: fish treats \' inside single quotes as an escape and
    /// tcsh expands "!" there, either of which let a folder name break out of
    /// `cd '<folder>'`.
    /// `name` is the script's file name: "run.command" for a terminal app that
    /// runs a script it is asked to open (see TerminalRunMethod).
    static func makeTerminalScript(cd directory: String, run executable: String, arguments: [String] = [],
                                   named name: String = "run",
                                   in base: URL = FileManager.default.temporaryDirectory) throws -> TerminalScript {
        // Screen before creating anything.
        _ = try terminalScriptSource(cd: directory, run: executable, arguments: arguments)
        let root = ModelPaths.realPath(base) ?? base
        var template = Array((root.path + "/selway-terminal-XXXXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else { throw CocoaError(.fileWriteUnknown) }
        let folder = URL(fileURLWithPath: String(cString: made), isDirectory: true)
        let script = folder.appendingPathComponent(name)
        do {
            guard isPortableShellWord(script.path) else { throw FileOpsError.unsafePath }
            let source = try terminalScriptSource(cd: directory, run: executable, arguments: arguments,
                                                  removing: script)
            let fd = open(script.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o700)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: Data(source.utf8))
            try handle.close()
            // open(2) applies the umask; the script must stay owner-only and executable.
            guard chmod(script.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return TerminalScript(directory: folder, script: script, typedCommand: script.path)
    }

    /// Script folders `makeTerminalScript` left in `base` more than `age` ago:
    /// the script removes its folder when it runs, so these never ran (the
    /// terminal app declined, failed or was quit first). Only Selway's own
    /// "selway-terminal-*" folders, and never one followed through a link.
    static func staleTerminalScriptFolders(in base: URL = FileManager.default.temporaryDirectory,
                                           olderThan age: TimeInterval = 24 * 3600, now: Date = Date(),
                                           fileManager fm: FileManager = .default) -> [URL] {
        let root = ModelPaths.realPath(base) ?? base
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { $0.hasPrefix("selway-terminal-") }.sorted().compactMap { name in
            let url = root.appendingPathComponent(name, isDirectory: true)
            guard let a = try? fm.attributesOfItem(atPath: url.path),
                  a[.type] as? FileAttributeType == .typeDirectory,
                  let modified = a[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > age else { return nil }
            return url
        }
    }

    /// Removes `staleTerminalScriptFolders`; returns how many went.
    @discardableResult
    static func removeStaleTerminalScripts(in base: URL = FileManager.default.temporaryDirectory,
                                           olderThan age: TimeInterval = 24 * 3600, now: Date = Date(),
                                           fileManager fm: FileManager = .default) -> Int {
        staleTerminalScriptFolders(in: base, olderThan: age, now: now, fileManager: fm)
            .filter { (try? fm.removeItem(at: $0)) != nil }.count
    }

    /// True if every shell reads `s` as one literal word.
    static func isPortableShellWord(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "/._-".unicodeScalars.contains($0))
        }
    }
}
