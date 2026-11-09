import Foundation

/// The terminal app Open in Terminal, Claude Code and the Codex CLI use
/// (Settings → Integrations).
enum TerminalApp: String, CaseIterable, Sendable {
    case terminal, iTerm, ghostty, warp
    /// An app the user picked with an open panel (`TerminalChoice.customPathKey`).
    case other

    /// The apps offered by name, in the picker's order.
    static let builtIn: [TerminalApp] = [.terminal, .iTerm, .ghostty, .warp]

    var name: String {
        switch self {
        case .terminal: return "Terminal"
        case .iTerm:    return "iTerm"
        case .ghostty:  return "Ghostty"
        case .warp:     return "Warp"
        case .other:    return NSLocalizedString("Other", comment: "Terminal app choice for a custom app")
        }
    }

    /// Bundle identifiers to look the app up by, in order.
    var bundleIDs: [String] {
        switch self {
        case .terminal: return ["com.apple.Terminal"]
        case .iTerm:    return ["com.googlecode.iterm2"]
        case .ghostty:  return ["com.mitchellh.ghostty"]
        case .warp:     return ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        case .other:    return []
        }
    }
}

/// How a tool that needs a command line (Claude Code, the Codex CLI) is started.
enum TerminalRunMethod: Equatable, Sendable {
    /// Terminal's AppleScript `do script`, typing only the private script's path.
    case terminalDoScript
    /// The private script, named `*.command`, opened with the app, which runs it
    /// in a new window or tab. Only apps checked to do that: iTerm and Ghostty.
    case openScript
}

/// The app that will actually be used, and why.
struct TerminalResolution: Equatable, Sendable {
    let app: TerminalApp
    /// nil only when not even Terminal was found.
    let url: URL?
    /// What to call it in menus, help and errors ("iTerm", "Kitty").
    let name: String
    /// The chosen app is missing, so this is Terminal instead.
    let fellBack: Bool

    /// Warp and other apps may open a script without running it (the tool
    /// would never start), so those run the tools in Terminal; only folders
    /// open in them.
    var runMethod: TerminalRunMethod {
        switch app {
        case .iTerm, .ghostty:          return .openScript
        case .terminal, .warp, .other:  return .terminalDoScript
        }
    }

    /// The app Claude Code and the Codex CLI open in.
    var runnerName: String { runMethod == .openScript ? name : TerminalApp.terminal.name }

    /// Settings → Integrations says so when the tools don't open in the chosen app.
    var runnerNote: String? {
        guard runMethod == .terminalDoScript, app != .terminal else { return nil }
        return NSLocalizedString("Claude Code and the Codex command-line tool open in Terminal: Selway can start them only in Terminal, iTerm and Ghostty.",
                                comment: "Settings note explaining which terminal apps can run command-line tools")
    }
}

enum TerminalChoice {
    static let key           = "selwayTerminalApp"
    static let customPathKey = "selwayTerminalCustomPath"
    static let defaultApp: TerminalApp = .terminal

    static func fromStorage(_ raw: String?) -> TerminalApp {
        raw.flatMap(TerminalApp.init(rawValue:)) ?? defaultApp
    }

    /// The display name of an app at `path` ("Kitty" for /Applications/Kitty.app).
    static func appName(atPath path: String) -> String {
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// The app to use for `choice`. A chosen app that isn't installed (or an
    /// Other app that has been deleted, or never chosen) falls back to Terminal.
    /// `locate` finds an app by bundle identifier; `isApp` says whether a path
    /// is an app bundle that exists.
    static func resolve(_ choice: TerminalApp, customPath: String?,
                        locate: (String) -> URL?, isApp: (String) -> Bool) -> TerminalResolution {
        switch choice {
        case .terminal:
            break
        case .other:
            if let path = customPath, !path.isEmpty, isApp(path) {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                // Picking Terminal, iTerm or Ghostty through Other… is still that
                // app, with what Selway knows it can do.
                if let known = builtIn(at: url, locate: locate) {
                    return TerminalResolution(app: known, url: url, name: known.name, fellBack: false)
                }
                return TerminalResolution(app: .other, url: url, name: appName(atPath: path), fellBack: false)
            }
        default:
            if let url = choice.bundleIDs.lazy.compactMap(locate).first {
                return TerminalResolution(app: choice, url: url, name: choice.name, fellBack: false)
            }
        }
        let terminal = TerminalApp.terminal.bundleIDs.lazy.compactMap(locate).first
        return TerminalResolution(app: .terminal, url: terminal, name: TerminalApp.terminal.name,
                                  fellBack: choice != .terminal)
    }

    private static func builtIn(at url: URL, locate: (String) -> URL?) -> TerminalApp? {
        TerminalApp.builtIn.first { app in app.bundleIDs.contains { locate($0).map { ShellPath.same($0, url) } ?? false } }
    }

    /// What Settings says under the picker; nil when the choice is in use.
    static func fallbackNote(for choice: TerminalApp, customPath: String?, resolution: TerminalResolution) -> String? {
        guard resolution.fellBack else { return nil }
        switch choice {
        case .other:
            if let path = customPath, !path.isEmpty {
                return String.localizedStringWithFormat(NSLocalizedString("%@ can’t be found, so Selway uses Terminal. Choose the app again.", comment: "Terminal settings status with application name"), appName(atPath: path))
            }
            return NSLocalizedString("No app chosen yet, so Selway uses Terminal.", comment: "Terminal settings status")
        default:
            return String.localizedStringWithFormat(NSLocalizedString("%@ isn’t installed, so Selway uses Terminal.", comment: "Terminal settings status with application name"), choice.name)
        }
    }
}
