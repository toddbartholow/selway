import SwiftUI
import AppKit

// MARK: - Browser window registry
//
// Knows which NSWindows are Selway browser windows so that:
//  • an external "open this folder" request (Open With, `open -a`, default folder
//    handler, the Finder extension) navigates exactly ONE window — the key one, or
//    the most recently used — instead of every window (or none when no window is
//    listening), and opens a new window when none exists;
//  • "Open in New Window" opens a Selway window rather than handing the folder
//    to whatever app is the system folder handler, and "Open in New Tab" (File ▸
//    New Tab, the tab bar's +) opens one as a tab of the window asking;
//  • Edit-menu routing can tell a browser window from a sheet, the Quick Look
//    panel or an editor window.

@MainActor
final class BrowserWindowRouter {
    static let shared = BrowserWindowRouter()

    /// Scene id of the browser `WindowGroup` (see SelwayApp).
    static let windowGroupID = "browser"

    /// Browser windows tab only with each other (Window ▸ Merge All Windows, the
    /// system's "Prefer tabs" setting); the editor and Markdown windows never
    /// join them (they disallow tabbing).
    static let tabbingIdentifier = "studio.irq.selway.browser"

    /// A pane of a browser window: the folder it shows, and how to take it
    /// somewhere else.
    struct Target {
        let location: BrowserLocation
        var folder: URL? { location.folder }
        let navigate: (URL) -> Void
    }

    private struct Entry {
        weak var window: NSWindow?
        /// The window's panes as they are when called, the active one first:
        /// what wants "the window's folder" (an external open) takes the first.
        let targets: () -> [Target]
        var lastActive: Date
    }

    /// A window requested with `openWindow`, waiting for its view to appear.
    private struct PendingWindow {
        /// Its first location; nil for the New windows folder (Settings → General).
        let location: BrowserLocation?
        /// The window it joins as a tab; nil for a window of its own.
        let tabHost: WeakWindow?
        let goesAfterHost: Bool
        let selectsWhenJoined: Bool
        let forcesSinglePane: Bool
    }

    struct InitialRequest {
        let location: BrowserLocation?
        let forcesSinglePane: Bool
    }

    private var entries: [UUID: Entry] = [:]
    /// Windows requested with `openWindow`, each under the id it's opened with.
    private var pendingNewWindows = WindowRequests<PendingWindow>()
    /// Browser views that appeared for a tab request, with the window to join
    /// once their own window is known.
    private struct TabJoinRequest {
        let host: WeakWindow
        let goesAfterHost: Bool
        let selectsWhenJoined: Bool
    }
    private var tabHosts: [UUID: TabJoinRequest] = [:]
    /// What the tab bar's + button calls in each browser window (TabResponder).
    private var tabResponders: [ObjectIdentifier: TabResponder] = [:]
    /// External opens that arrived before any browser existed (cold launch).
    /// The first window takes the first; the rest get windows of their own.
    private var coldLaunchURLs: [URL] = []
    /// Opens arriving back to back are one multi-item request: further folders
    /// get their own windows, repeats of one already delivered are dropped
    /// (several files from one folder all reveal that folder).
    private var batch = ShellOpenBatch()
    private var coldLaunchFallbackAttempts = 0
    /// Captured from a browser view's environment; usable after that window closes.
    var openWindow: OpenWindowAction?

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .navigateToPath, object: nil, queue: .main) { note in
            guard let url = note.object as? URL else { return }
            MainActor.assumeIsolated { BrowserWindowRouter.shared.handleExternalOpen(url) }
        }
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { BrowserWindowRouter.shared.windowBecameKey(window) }
        }
    }

    // MARK: Registration (called by ContentView)

    /// `window` is the view's last known window (it may already be attached,
    /// e.g. when onAppear runs again for a view that never left its window).
    /// `targets` gives the window's panes, the active one first (Entry).
    func register(_ id: UUID, window: NSWindow?, targets: @escaping () -> [Target]) {
        entries[id] = Entry(window: window ?? entries[id]?.window, targets: targets, lastActive: Date())
    }

    /// Records the window once the view is in one. If this arrives before
    /// `register`, `register` picks the window up from the caller's holder.
    func attach(_ id: UUID, window: NSWindow?) {
        if let window { adopt(window) }
        guard var entry = entries[id] else { return }
        entry.window = window
        entries[id] = entry
        joinTabIfRequested(id)
    }

    /// Called as soon as the view is in a window, inside a SwiftUI update. The
    /// window takes the browsers' tabbing identifier now, before macOS's own
    /// tabbing ("Prefer tabs") looks at it. A window opening as a tab stays
    /// transparent until it has joined its tab group (joinTabIfRequested), so it
    /// never flashes up as a window of its own; if the join never comes (the view
    /// left its window first, say), it shows again shortly after.
    func windowWillAttach(_ id: UUID, window: NSWindow?) {
        guard let window else { return }
        window.tabbingIdentifier = Self.tabbingIdentifier
        guard let host = tabHosts[id]?.host.window, host !== window else { return }
        window.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak window] in
            window?.alphaValue = 1
        }
    }

    func unregister(_ id: UUID) {
        if tabHosts[id] != nil { entries[id]?.window?.alphaValue = 1 }
        entries[id] = nil
        tabHosts[id] = nil
    }

    /// Marks `window` as a browser window for tabbing, and gives it the tab bar's
    /// + button (SwiftUI's windows don't answer `newWindowForTab:`, so AppKit
    /// shows none): a responder at the end of the window's responder chain. At
    /// the end, its own next responder stays nil: `nextResponder` isn't retained,
    /// so pointing it at SwiftUI's objects could outlive them.
    private func adopt(_ window: NSWindow) {
        window.tabbingIdentifier = Self.tabbingIdentifier
        tabResponders = tabResponders.filter { $0.value.window != nil }
        let key = ObjectIdentifier(window)
        let responder = tabResponders[key] ?? TabResponder(window: window)
        tabResponders[key] = responder
        // SwiftUI may change the chain after the window; add this again if it's gone.
        var last: NSResponder = window
        while let next = last.nextResponder {
            if next === responder { return }
            last = next
        }
        responder.nextResponder = nil
        last.nextResponder = responder
    }

    /// `volume` has gone: every pane of every window showing a folder on it
    /// goes home (SidebarVolumes.moves(afterUnmounting:)), active or not.
    /// Links in the folders' paths are read, except on `servers` (the mount
    /// points of connected servers).
    func moveWindows(offVolume volume: URL, servers: [URL]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let readLink = { (path: String) in try? FileManager.default.destinationOfSymbolicLink(atPath: path) }
        for entry in entries.values {
            let moves = SidebarVolumes.moves(afterUnmounting: volume, panes: entry.targets(), folder: \.folder,
                                             home: home, servers: servers, readLink: readLink)
            for (target, destination) in moves { target.navigate(destination) }
        }
    }

    func isBrowserWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return entries.values.contains { $0.window === window }
    }

    // MARK: New windows and tabs

    /// Opens a new browser window showing `url`.
    func openNewWindow(at url: URL) {
        guard let openWindow else {
            // No browser has appeared yet (cold launch); the first one picks this up.
            AppDelegate.pendingNavigationURL = url
            return
        }
        open(PendingWindow(location: .folder(url), tabHost: nil, goesAfterHost: false,
                           selectsWhenJoined: true, forcesSinglePane: false), with: openWindow)
    }

    /// Opens a new tab showing `url`, or the New windows folder (Settings →
    /// General) when nil, as Finder's File ▸ New Tab does. The tab joins `host`,
    /// or else the key browser window, at the end of its tabs, and becomes the
    /// selected one. With no browser window to join, it opens as a window.
    func openNewTab(at url: URL?, in host: NSWindow? = nil) {
        guard let openWindow else {
            // Before any browser has appeared: the first window shows the folder.
            if let url { AppDelegate.pendingNavigationURL = url }
            return
        }
        // A tab asked for while the last one is still on its way (⌘T pressed
        // quickly) joins the same window: the new one isn't known as a browser yet.
        let joining = [host, NSApp.keyWindow, NSApp.mainWindow].lazy.compactMap { $0 }
            .first { self.isBrowserWindow($0) }
            ?? pendingNewWindows.last { $0.tabHost?.window != nil }?.tabHost?.window
            ?? tabHosts.values.lazy.compactMap { $0.host.window }.first
        let holder = joining.map { window -> WeakWindow in
            let h = WeakWindow()
            h.window = window
            return h
        }
        open(PendingWindow(location: url.map(BrowserLocation.folder), tabHost: holder, goesAfterHost: false,
                           selectsWhenJoined: true, forcesSinglePane: false), with: openWindow)
    }

    /// Opens a single-pane tab immediately after `host`, without selecting it.
    /// Used when a pane leaves a dual-pane window.
    func openNewTab(at location: BrowserLocation, after host: NSWindow) {
        guard let openWindow else { return }
        let holder = WeakWindow()
        holder.window = host
        open(PendingWindow(location: location, tabHost: holder, goesAfterHost: true,
                           selectsWhenJoined: false, forcesSinglePane: true), with: openWindow)
    }

    /// Opens a browser window for `request`, under an id of its own that the
    /// window hands back (takeInitialRequest).
    private func open(_ request: PendingWindow, with openWindow: OpenWindowAction) {
        let id = pendingNewWindows.add(request)
        #if SELWAY_UI_TESTING
        // A window that's slow to come (UITestHooks.windowOpenDelay), so a test
        // can open another first.
        if let delay = UITestHooks.windowOpenDelay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { openWindow(id: Self.windowGroupID, value: id) }
            return
        }
        #endif
        openWindow(id: Self.windowGroupID, value: id)
    }

    /// The tab directly after `window`, in AppKit's tab order.
    func tabToRight(of window: NSWindow) -> NSWindow? {
        guard let tabs = window.tabbedWindows,
              let index = tabs.firstIndex(where: { $0 === window }),
              let rightIndex = TabArrangement.tabToRightIndex(count: tabs.count, current: index) else { return nil }
        return tabs[rightIndex]
    }

    func activeLocation(in window: NSWindow) -> BrowserLocation? {
        entries.values.first { $0.window === window }?.targets().first?.location
    }

    func closeTab(_ window: NSWindow) { window.close() }

    /// The folder a newly appearing browser window `id` should start in, if any
    /// (nil also for a new window or tab that shows the New windows folder).
    /// `requestID` is the id the window was opened with: nil for one the
    /// router didn't ask for (File ▸ New Window, the Dock), and one filed in
    /// an earlier session for a restored window. Either takes no other
    /// window's request. A window asked for as a tab joins its tab group once
    /// it's in its window.
    func takeInitialRequest(for id: UUID, requestID: UUID?) -> InitialRequest {
        if let pending = pendingNewWindows.take(requestID) {
            if let host = pending.tabHost {
                tabHosts[id] = TabJoinRequest(host: host, goesAfterHost: pending.goesAfterHost,
                                              selectsWhenJoined: pending.selectsWhenJoined)
                joinTabIfRequested(id)
            }
            return InitialRequest(location: pending.location, forcesSinglePane: pending.forcesSinglePane)
        }
        if !coldLaunchURLs.isEmpty {
            AppDelegate.pendingNavigationURL = nil
            let first = coldLaunchURLs.removeFirst()
            let rest = coldLaunchURLs
            coldLaunchURLs = []
            // Called from the first window's onAppear, so openWindow is set now.
            DispatchQueue.main.async { rest.forEach { self.openNewWindow(at: $0) } }
            return InitialRequest(location: .folder(first), forcesSinglePane: false)
        }
        if let url = AppDelegate.pendingNavigationURL {
            AppDelegate.pendingNavigationURL = nil
            return InitialRequest(location: .folder(url), forcesSinglePane: false)
        }
        return InitialRequest(location: nil, forcesSinglePane: false)
    }

    /// Adds the window of `id` to its requested tab group and restores the
    /// requested selection. Runs once both are known: the request (in onAppear)
    /// and the window (attach), whichever comes second.
    private func joinTabIfRequested(_ id: UUID) {
        guard let request = tabHosts[id], let window = entries[id]?.window else { return }
        tabHosts[id] = nil
        defer { window.alphaValue = 1 }
        guard let hostWindow = request.host.window, hostWindow !== window,
              hostWindow.isVisible || hostWindow.tabbedWindows != nil else {
            // The host closed meanwhile: a window of its own.
            window.makeKeyAndOrderFront(nil)
            return
        }
        if hostWindow.tabbedWindows?.contains(where: { $0 === window }) == true {
            // AppKit tabbed it already ("Prefer tabs" set to Always, or in full
            // screen), at the end: one that goes after its host moves there.
            guard request.goesAfterHost else { window.makeKeyAndOrderFront(nil); return }
            hostWindow.tabGroup?.removeWindow(window)
        }
        let insertionPoint = request.goesAfterHost ? hostWindow : (hostWindow.tabbedWindows?.last ?? hostWindow)
        insertionPoint.addTabbedWindow(window, ordered: .above)
        (request.selectsWhenJoined ? window : hostWindow).makeKeyAndOrderFront(nil)
    }

    // MARK: External opens

    private func handleExternalOpen(_ url: URL) {
        AppDelegate.pendingNavigationURL = nil
        let placement = batch.place(url)
        if placement == .duplicate { return }
        if placement == .overLimit {
            NSLog("Selway: ignored %@: too many folders opened at once.", url.path)
            return
        }
        guard let entry = bestEntry() else {
            // No browser window: open one. Before any browser has appeared (cold
            // launch) there is no openWindow action yet; queue the folder for the
            // first window instead.
            if openWindow != nil {
                openNewWindow(at: url)
            } else {
                coldLaunchURLs.append(url)
                scheduleColdLaunchFallback()
            }
            return
        }
        // Several folders opened at once (Open With on a multi-selection) arrive
        // back to back: the first navigates the target window, the rest open new
        // windows instead of overwriting each other.
        if placement == .additional {
            openNewWindow(at: url)
            return
        }
        // The window's folder: its active pane's.
        entry.targets().first?.navigate(url)
        if let window = entry.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func bestEntry() -> Entry? {
        let live = entries.values.filter { $0.window != nil }
        if let key = NSApp.keyWindow, let e = live.first(where: { $0.window === key }) { return e }
        if let main = NSApp.mainWindow, let e = live.first(where: { $0.window === main }) { return e }
        if let recent = live.max(by: { $0.lastActive < $1.lastActive }) { return recent }
        // Registered but the window reference isn't attached yet (first appear).
        return entries.values.max(by: { $0.lastActive < $1.lastActive })
    }

    private func windowBecameKey(_ window: NSWindow?) {
        guard let window else { return }
        var isBrowser = false
        for (id, entry) in entries where entry.window === window {
            entries[id]?.lastActive = Date()
            isBrowser = true
        }
        // The shown folder may have been moved or deleted along with a parent
        // while the user was elsewhere; its own watch gets no event for that.
        if isBrowser { DirectoryWatcher.shared.revalidate() }
    }

    // MARK: Cold-launch fail-safe

    /// Folders queued for the first window would wait forever if SwiftUI never
    /// opens one (e.g. launched only to open a folder with window restoration
    /// off). If none has registered shortly after, ask for a window the way
    /// File ▸ New Window does; its onAppear takes the queued folders.
    private func scheduleColdLaunchFallback() {
        guard coldLaunchFallbackAttempts < 3 else { return }
        coldLaunchFallbackAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.coldLaunchURLs.isEmpty else { return }
                if self.entries.isEmpty && self.openWindow == nil {
                    Self.requestNewBrowserWindow()
                }
                self.scheduleColdLaunchFallback()     // check again; bounded
            }
        }
    }

    /// Opens a browser window at the New windows folder by choosing File ▸ New
    /// Window, for when no SwiftUI view has appeared yet to provide an `openWindow`
    /// action: a Dock click with only the About window open, say. Only for that;
    /// with `openWindow` set, `openNewTab(at:)` opens windows.
    static func chooseNewWindow() {
        requestNewBrowserWindow()
    }

    /// Triggers the WindowGroup's own New Window command (⌘N) from AppKit,
    /// for when no SwiftUI view exists yet to provide an `openWindow` action.
    private static func requestNewBrowserWindow() {
        func find(in menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.keyEquivalent == "n", item.keyEquivalentModifierMask == .command {
                    return (menu, index)
                }
                if let sub = item.submenu, let hit = find(in: sub) { return hit }
            }
            return nil
        }
        if let main = NSApp.mainMenu, let (menu, index) = find(in: main) {
            menu.performActionForItem(at: index)
        } else {
            NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
        }
    }
}

// MARK: - Window access

/// Weak NSWindow holder that can live in `@State` without retaining the window.
final class WeakWindow {
    weak var window: NSWindow?
}

/// Whether a browser view's onAppear has run, held in `@State` without being
/// observed: onAppear runs again for the same window when SwiftUI takes the
/// view out of its window and puts it back (as a tab can move), and the second
/// time must not start the window over.
final class BrowserLifecycle {
    var hasAppeared = false
}

/// Weak NSView holder, likewise.
final class WeakView {
    weak var view: NSView?
}

/// Hands over an AppKit view occupying the same frame as the SwiftUI view it
/// backs (`.background(ViewReader { … })`), for finding AppKit views in that area.
struct ViewReader: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = _PassThroughView()
        onView(v)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}
}

final class _PassThroughView: NSView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Reports the NSWindow hosting this view (and later changes of it).
/// `immediately`, if given, hears of it first, inside the SwiftUI update that
/// put the view in the window: for changes to the window that can't wait.
struct WindowReader: NSViewRepresentable {
    var immediately: ((NSWindow?) -> Void)?
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> _WindowReaderView {
        let v = _WindowReaderView()
        v.immediately = immediately
        v.onChange = onChange
        return v
    }

    func updateNSView(_ v: _WindowReaderView, context: Context) {
        v.immediately = immediately
        v.onChange = onChange
    }
}

final class _WindowReaderView: NSView {
    var immediately: ((NSWindow?) -> Void)?
    var onChange: ((NSWindow?) -> Void)?

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let window = self.window
        immediately?(window)
        // Defer: this runs inside a SwiftUI update.
        DispatchQueue.main.async { [weak self] in self?.onChange?(window) }
    }
}

// MARK: - The tab bar's + button

/// Sits after a browser window in its responder chain to answer
/// `newWindowForTab:`, which the tab bar's + button sends: a new tab showing
/// the New windows folder, as File ▸ New Tab opens.
final class TabResponder: NSResponder {
    weak var window: NSWindow?

    init(window: NSWindow) {
        self.window = window
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func newWindowForTab(_ sender: Any?) {
        MainActor.assumeIsolated {
            BrowserWindowRouter.shared.openNewTab(at: nil, in: window)
        }
    }
}


// MARK: - The tab to the right

/// Whether a browser window has a tab directly to its right, kept up to date as
/// tabs are added, closed, reordered or dragged to other windows: Window ▸
/// Merge Tab into Dual Pane's enabled state. The menu can't work it out when
/// it's shown, since a change in tab order changes none of the values it reads.
@MainActor
@Observable
final class TabNeighborWatch {
    private(set) var hasTabToRight = false
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private weak var group: NSWindowTabGroup?
    @ObservationIgnored private var groupObservation: NSKeyValueObservation?
    @ObservationIgnored private var keyObserver: NSObjectProtocol?

    /// Follows `window` (once it's known; again when SwiftUI hands it over anew).
    func watch(_ window: NSWindow?) {
        guard window !== self.window else { return }
        self.window = window
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = window.map {
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                   object: $0, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    /// Reads the tab order again, and follows the window's tab group: a tab
    /// dragged to another window has a new one. `windows` is key-value
    /// observable; the order is read once AppKit has finished the change.
    private func refresh() {
        let current = window?.tabGroup
        if current !== group {
            group = current
            groupObservation = current?.observe(\.windows, options: []) { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
            }
        }
        let has = window.map { BrowserWindowRouter.shared.tabToRight(of: $0) != nil } ?? false
        if has != hasTabToRight { hasTabToRight = has }
    }
}
