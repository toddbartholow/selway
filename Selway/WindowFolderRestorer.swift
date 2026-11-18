import AppKit

/// Every browser window's places (WindowFolderSnapshot), kept in the app's
/// restorable state by window identifier (SavedWindowFolders), and the places
/// decoded at launch, for the windows macOS brings back.
///
/// AppKit decodes the app's state before restoring any window, and every
/// restored window appears before `applicationDidFinishLaunching`; each one
/// takes its own places (by its identifier) as its panes start. Windows that
/// appear after launching are new ones, whatever their identifier.
@MainActor
final class WindowFolderRegistry {
    static let shared = WindowFolderRegistry()

    private static let coderKey = "selway.windowFolders"

    /// What each open window saved, encoded with the app's state.
    private var current = SavedWindowFolders()
    /// Decoded at launch. A window that chose to restore while launching takes
    /// its own from here once it's in its NSWindow, which may be after
    /// launching has finished.
    private var restoring = SavedWindowFolders()
    /// Windows appearing now may be ones macOS is bringing back.
    private var isLaunching = true
    /// Quitting: the windows closing now are the ones to bring back.
    private var isTerminating = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        // A closed window isn't brought back, and AppKit gives its identifier
        // to the next window it opens.
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
            [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, !self.isTerminating, let identifier = window?.identifier?.rawValue,
                      self.current.windows.removeValue(forKey: identifier) != nil else { return }
                NSApp.invalidateRestorableState()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isTerminating = true }
        })
    }

    /// macOS is bringing windows back: places were decoded at launch, and
    /// launching hasn't finished.
    var isRestoringWindows: Bool { isLaunching && !restoring.windows.isEmpty }

    /// The places saved for the restored window `identifier`, given out once.
    func take(for identifier: String) -> WindowFolderSnapshot? {
        restoring.take(identifier)
    }

    /// Saves `snapshot` as the places of the window `identifier`.
    func update(_ snapshot: WindowFolderSnapshot, for identifier: String) {
        guard current.windows[identifier] != snapshot else { return }
        current.windows[identifier] = snapshot
        NSApp.invalidateRestorableState()
    }

    /// NSApplicationDelegate `application(_:didDecodeRestorableState:)`.
    func decode(from coder: NSCoder) {
        let data = coder.decodeObject(of: NSData.self, forKey: Self.coderKey) as Data?
        restoring = SavedWindowFolders.decode(data) ?? SavedWindowFolders()
        // A restored window's places stand until it saves its own; one that
        // saved already keeps what it saved.
        current.windows.merge(restoring.windows) { saved, _ in saved }
    }

    /// NSApplicationDelegate `application(_:willEncodeRestorableState:)`.
    func encode(with coder: NSCoder) {
        current = current.keeping(Set(NSApp.windows.compactMap { $0.identifier?.rawValue }))
        if let data = current.encoded() { coder.encode(data as NSData, forKey: Self.coderKey) }
    }

    /// Launching has finished: a window that appears from now on is a new one.
    /// Every restored window has appeared by now (as measured on macOS 26),
    /// but the cutoff is generous, in case one is a little later elsewhere: a
    /// window opened by the user meanwhile comes with a live request, and only
    /// a window with a saved identifier takes anything.
    func launchFinished() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreCutoff) {
            MainActor.assumeIsolated { self.isLaunching = false }
        }
    }

    private static let restoreCutoff: TimeInterval = 5

    #if SELWAY_UI_TESTING
    /// The UI tests' "forget saved windows" launch: no restored window reopens
    /// its places.
    func forgetRestoredWindows() {
        restoring = SavedWindowFolders()
    }
    #endif
}

/// Reopens a restored window's panes on the places it saved
/// (WindowFolderSnapshot), and says what to save for each pane meanwhile.
///
/// A saved folder is checked on a thread of its own before it's shown:
/// AutomountGuard first, so a path under an automount folder is never looked
/// at, then whether it's still a folder. On a share that has stopped
/// answering the check can take minutes, and holds only that thread (windows
/// restored on the same folder share it).
///
/// - A folder that answers within `grace` is shown at once.
/// - Otherwise the pane shows the New windows folder meanwhile. When the
///   check answers, the saved folder takes its place (history included) if the
///   pane is untouched: still on that folder, with no Back or Forward, nothing
///   selected and no search or tag filter.
/// - A folder that's gone, or that the guard refuses, leaves the pane on the
///   New windows folder.
///
/// Until the user takes a pane somewhere else, its saved place is what's saved
/// again: a window reopened at login before its disk has mounted keeps its
/// folder for the next launch.
@MainActor
final class WindowFolderRestorer {
    typealias Place = WindowFolderSnapshot.Place

    /// How long a saved folder's check may take before the New windows folder
    /// stands in.
    static let grace: TimeInterval = 0.35

    /// One pane's saved folder being restored. Main-thread only, like the
    /// restorer; nested types don't take on its isolation by themselves.
    @MainActor private final class Attempt {
        let saved: Place
        /// The pane it's for: a pane made later may get the same
        /// ObjectIdentifier.
        weak var pane: PaneState?
        /// The check's answer: whether the saved folder can be shown.
        var answer: Bool?
        /// The saved folder was shown.
        var restored = false
        /// The New windows folder was asked for.
        var fallbackRequested = false
        /// The New windows folder shown in its place.
        var fallback: URL?

        init(saved: Place, pane: PaneState) {
            self.saved = saved
            self.pane = pane
        }
    }

    /// Panes still being restored, or showing the New windows folder in place
    /// of their saved one, by ObjectIdentifier of their PaneState.
    private var attempts: [ObjectIdentifier: Attempt] = [:]

    /// Folders being checked, with what waits on each answer.
    private static var checking: [String: [(Bool) -> Void]] = [:]

    /// Shows `place` in `pane`, which has started and shows nothing yet.
    func restore(_ place: Place?, in pane: PaneState) {
        switch place {
        case nil:
            pane.showNewWindowFolder()
        case .computer:
            // History included, as for a folder (`show`): a second pane
            // restored with its window may not have a view to react yet.
            if pane.model.location != .computer { pane.model.location = .computer }
            pane.navigation.visit(.computer)
        case .folder(let path):
            let attempt = Attempt(saved: .folder(path: path), pane: pane)
            attempts = attempts.filter { $0.value.pane != nil }
            attempts[ObjectIdentifier(pane)] = attempt
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace) { [weak pane] in
                MainActor.assumeIsolated {
                    guard let pane, attempt.answer == nil else { return }
                    Self.showFallback(in: pane, for: attempt)
                }
            }
            Self.check(path) { [weak pane] canReopen in
                guard let pane else { return }
                Self.answered(canReopen, path: path, in: pane, for: attempt)
            }
        }
    }

    /// A pane started again (its tab back in view, say) that still shows
    /// nothing: it was stopped when its check answered or when the New windows
    /// folder was to stand in, so it gets the answer, or the New windows
    /// folder, now. A pane that wasn't being restored gets the New windows
    /// folder.
    func resumeIfEmpty(_ pane: PaneState) {
        guard pane.isStarted, pane.navigation.history.current == nil else { return }
        guard let attempt = attempt(for: pane), !attempt.restored, case .folder(let path) = attempt.saved else {
            pane.showNewWindowFolder()
            return
        }
        if let answer = attempt.answer {
            Self.answered(answer, path: path, in: pane, for: attempt)
        } else if attempt.fallbackRequested, attempt.fallback == nil {
            // The grace period ended while it was stopped.
            Self.showFallback(in: pane, for: attempt)
        }
    }

    private func attempt(for pane: PaneState) -> Attempt? {
        guard let attempt = attempts[ObjectIdentifier(pane)], attempt.pane === pane else { return nil }
        return attempt
    }

    /// What to save for `pane`: its saved place while that's still to be
    /// shown or the New windows folder stands in for it, else where it is.
    func place(for pane: PaneState) -> Place? {
        let key = ObjectIdentifier(pane)
        if let attempt = attempt(for: pane), !attempt.restored {
            if pane.navigation.history.current == nil { return attempt.saved }
            if let fallback = attempt.fallback, Self.isUntouched(pane, showing: fallback) { return attempt.saved }
        }
        attempts[key] = nil
        switch pane.model.location {
        case .folder(let url): return .folder(path: url.path)
        case .computer:        return .computer
        }
    }

    private static func answered(_ canReopen: Bool, path: String, in pane: PaneState, for attempt: Attempt) {
        attempt.answer = canReopen
        // Its window closed (or the tab moved) meanwhile: a stopped pane
        // watches nothing. One started again picks the answer up
        // (resumeIfEmpty).
        guard pane.isStarted else { return }
        guard canReopen else {
            if attempt.fallback == nil { showFallback(in: pane, for: attempt) }
            return
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if attempt.fallback == nil, pane.navigation.history.current == nil {
            attempt.restored = true
            show(url, in: pane)
        } else if let fallback = attempt.fallback, isUntouched(pane, showing: fallback) {
            attempt.restored = true
            // In its place: Back doesn't lead to a folder the user never chose.
            pane.navigation.restart(at: .folder(url))
            show(url, in: pane)
        }
    }

    /// The New windows folder, looked up off the main thread (a chosen folder
    /// on a share can be slow to answer), shown only while the pane shows
    /// nothing and the saved folder hasn't been shown.
    private static func showFallback(in pane: PaneState, for attempt: Attempt) {
        attempt.fallbackRequested = true
        DispatchQueue.global(qos: .userInitiated).async { [weak pane] in
            let url = NewWindowFolder.initialURL()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let pane, pane.isStarted, !attempt.restored,
                          pane.navigation.history.current == nil else { return }
                    attempt.fallback = url
                    show(url, in: pane)
                }
            }
        }
    }

    /// Shows `url` now, history and listing included, rather than waiting
    /// for the pane's view to react to the change: a second pane restored
    /// with its window may not have a view yet (as in BrowserPanes.showSecond).
    private static func show(_ url: URL, in pane: PaneState) {
        if pane.model.location != .folder(url) { pane.model.location = .folder(url) }
        pane.startShowing(url)
    }

    /// Whether the pane still shows just `folder`, as it was given: no Back or
    /// Forward, nothing selected, no search or tag filter (running or listed).
    private static func isUntouched(_ pane: PaneState, showing folder: URL) -> Bool {
        let history = pane.navigation.history
        return pane.model.location == .folder(folder) && !history.canGoBack && !history.canGoForward
            && pane.model.selectedIDs.isEmpty && !pane.isSearchActive && pane.model.listedSearch == nil
    }

    /// Checks `path` on a thread of its own, unless it's being checked: then
    /// `done` waits on that check's answer. Answers on the main thread.
    private static func check(_ path: String, done: @escaping (Bool) -> Void) {
        if checking[path] != nil {
            checking[path]?.append(done)
            return
        }
        checking[path] = [done]
        let thread = Thread {
            let canReopen = WindowFolderRestoration.canReopen(
                path, isSafe: { AutomountGuard.isSafe($0) },
                isFolder: { FileItem.isBrowsableFolder(URL(fileURLWithPath: $0, isDirectory: true)) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let waiting = checking.removeValue(forKey: path) ?? []
                    waiting.forEach { $0(canReopen) }
                }
            }
        }
        thread.name = "studio.irq.selway.restore-window-folder"
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
