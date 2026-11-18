import Foundation

/// Where a browser window's panes were, saved so a window macOS brings back at
/// launch (Quit and Keep Windows) reopens there.
struct WindowFolderSnapshot: Codable, Equatable, Sendable {
    /// Where a pane was.
    enum Place: Codable, Equatable, Sendable {
        case folder(path: String)
        /// The computer overview (Go > Computer).
        case computer
    }

    /// The first (leading) pane's place; nil when it showed neither (search
    /// results keep their folder, so this is rare).
    var first: Place?
    /// The second pane's place, saved only while it's shown.
    var second: Place?
    var isDual: Bool
}

/// Each browser window's snapshot, by its window's identifier, kept in the
/// app's restorable state. macOS brings each window back with the identifier
/// it had, and decodes the app's state before any window appears, so a
/// restored window can open on its folders at once. (SwiftUI's `SceneStorage`
/// arrives seconds after a restored window first appears on macOS 26.)
struct SavedWindowFolders: Codable, Equatable, Sendable {
    var windows: [String: WindowFolderSnapshot] = [:]

    static func decode(_ data: Data?) -> SavedWindowFolders? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }

    /// Only the windows still open: macOS doesn't bring back a closed window,
    /// and a window opened at the next launch may be given its identifier.
    func keeping(_ identifiers: Set<String>) -> SavedWindowFolders {
        SavedWindowFolders(windows: windows.filter { identifiers.contains($0.key) })
    }

    /// The snapshot saved for `identifier`, given out once.
    mutating func take(_ identifier: String) -> WindowFolderSnapshot? {
        windows.removeValue(forKey: identifier)
    }
}

enum WindowFolderRestoration {
    /// Whether a window that's appearing reopens its saved places: one macOS
    /// is bringing back at launch (saved places were decoded and are still
    /// waiting), with no live router request (an external open, Open in New
    /// Window, a new tab), which always wins.
    static func shouldRestore(hasLiveRequest: Bool, isRestoringWindows: Bool) -> Bool {
        !hasLiveRequest && isRestoringWindows
    }

    /// Whether a saved folder can be shown again: `isSafe` (AutomountGuard)
    /// first, so a path under an automount folder is never looked at, then
    /// `isFolder`.
    static func canReopen(_ path: String, isSafe: (String) -> Bool, isFolder: (String) -> Bool) -> Bool {
        !path.isEmpty && isSafe(path) && isFolder(path)
    }
}
