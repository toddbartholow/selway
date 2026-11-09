import Foundation

/// A browser location is either a real folder or the computer overview.
/// Folder identity is lexical and follows `ShellPath.key`, not URL equality.
enum BrowserLocation: Hashable, Sendable {
    case folder(URL)
    case computer

    var folder: URL? {
        guard case .folder(let url) = self else { return nil }
        return url
    }

    static func == (lhs: BrowserLocation, rhs: BrowserLocation) -> Bool {
        switch (lhs, rhs) {
        case let (.folder(a), .folder(b)): return ShellPath.key(a) == ShellPath.key(b)
        case (.computer, .computer): return true
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .folder(let url): hasher.combine(0); hasher.combine(ShellPath.key(url))
        case .computer: hasher.combine(1)
        }
    }

    static func same(_ lhs: BrowserLocation, _ rhs: BrowserLocation) -> Bool { lhs == rhs }

    /// Whether `command` can run here. Copy Path also works on a selected
    /// overview volume; its action checks that one is selected.
    func allows(_ command: LocationCommand, readOnly: Bool = false) -> Bool {
        if case .folder = self {
            if readOnly {
                return [.copyPath, .openInTool, .refresh, .find].contains(command)
            }
            return true
        }
        return command == .copyPath
    }
}

/// The browser commands that act in the folder shown.
enum LocationCommand: CaseIterable, Sendable {
    case newFolder, newTextFile, paste, pasteHere, copyPath, openInTool, refresh, find, transferInto
}
