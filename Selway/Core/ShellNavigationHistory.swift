import Foundation

/// A browser window's Back / Forward history (Go → Back ⌘[ and Forward ⌘], and the
/// toolbar's chevrons). Steps are locations: folders, compared by path
/// (BrowserLocation's ==, by ShellPath.key), so another spelling of the folder
/// shown is not a new step; and the computer overview.
struct NavigationHistory: Equatable, Sendable {
    /// Steps kept in each direction; the oldest go first.
    static let limit = 100

    private(set) var current: BrowserLocation?
    /// Nearest last.
    private(set) var backStack: [BrowserLocation] = []
    /// Nearest last.
    private(set) var forwardStack: [BrowserLocation] = []

    init(current: BrowserLocation? = nil) { self.current = current }
    init(current: URL) { self.current = .folder(current) }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// The window now shows `location` by any way but Back / Forward: the place it
    /// leaves goes on the Back list and Forward is cleared, as in Finder. The
    /// place already shown changes nothing.
    mutating func visit(_ location: BrowserLocation) {
        guard current != location else { return }
        if let current {
            backStack.append(current)
            if backStack.count > Self.limit { backStack.removeFirst(backStack.count - Self.limit) }
        }
        forwardStack.removeAll()
        current = location
    }

    mutating func visit(_ url: URL) { visit(.folder(url)) }

    /// The window now shows `location` without taking a step: a folder selected in
    /// the column browser, which Finder doesn't add to Back / Forward either. Real
    /// navigation from there (`visit`) leaves this folder on the Back list.
    mutating func replaceCurrent(_ location: BrowserLocation) { current = location }
    mutating func replaceCurrent(_ url: URL) { replaceCurrent(.folder(url)) }

    /// The window has moved to `location`. Back / Forward have already stepped (this
    /// is then the place shown, and changes nothing); a folder the column browser
    /// selected (`columnSelection`, the one the browser asked for) is shown without
    /// a step; anything else is a new step.
    mutating func arrive(at location: BrowserLocation, columnSelection: BrowserLocation?) {
        if let columnSelection, columnSelection == location {
            replaceCurrent(location)
        } else {
            visit(location)
        }
    }

    mutating func arrive(at url: URL, columnSelection: URL?) {
        arrive(at: .folder(url), columnSelection: columnSelection.map(BrowserLocation.folder))
    }

    /// Enclosing Folder has somewhere to go: a folder, not the root. The computer
    /// overview has no enclosing folder.
    var canGoUp: Bool {
        guard let current, let folder = current.folder else { return false }
        return ShellPath.key(folder) != "/"
    }

    /// The place to show for Back, or nil if there is none. Folders that no longer
    /// exist (`exists` is false) and copies of the place shown are skipped and
    /// dropped; the computer always exists, so `exists` isn't asked about it. The
    /// place left goes on the Forward list.
    mutating func goBack(exists: (BrowserLocation) -> Bool) -> BrowserLocation? {
        var from = backStack, to = forwardStack
        let location = Self.step(from: &from, to: &to, current: current, exists: exists)
        backStack = from
        forwardStack = to
        if let location { current = location }
        return location
    }

    /// Back's mirror image.
    mutating func goForward(exists: (BrowserLocation) -> Bool) -> BrowserLocation? {
        var from = forwardStack, to = backStack
        let location = Self.step(from: &from, to: &to, current: current, exists: exists)
        forwardStack = from
        backStack = to
        if let location { current = location }
        return location
    }

    private static func step(from source: inout [BrowserLocation], to destination: inout [BrowserLocation],
                             current: BrowserLocation?, exists: (BrowserLocation) -> Bool) -> BrowserLocation? {
        while let candidate = source.popLast() {
            guard candidate == .computer || exists(candidate), candidate != current else { continue }
            if let current {
                destination.append(current)
                if destination.count > limit { destination.removeFirst(destination.count - limit) }
            }
            return candidate
        }
        return nil
    }
}
