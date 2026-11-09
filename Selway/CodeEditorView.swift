import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

// Text/binary detection lives in Core/TextFileDetector.swift; reading and writing
// (encodings, symlinks, external-change snapshots) in Core/TextFileIO.swift.

// MARK: - Open document model

struct OpenDoc: Identifiable, Equatable {
    let id: String
    /// The URL the user opened (may go through symlinks).
    let url: URL
    /// The file actually read and written.
    var resolvedURL: URL
    var format: TextFileFormat
    /// On-disk state at load / last save, to detect changes by other apps.
    var snapshot: TextFileSnapshot
    var modified: Bool = false
    /// An external change the user chose not to reload, so refocusing doesn't ask again.
    var declinedReloadSnapshot: TextFileSnapshot?

    var name: String { url.lastPathComponent }
}

// MARK: - Standalone editor window manager (real macOS window, non-blocking)

@MainActor
final class EditorWindowManager: NSObject, NSWindowDelegate {
    static let shared = EditorWindowManager()

    private var window: NSWindow?
    private var controller: AceEditorController?
    /// Closes requested from alert callbacks run once the callback has returned.
    private let deferredClose = EditorDeferredClose(schedule: EditorWindowCloseScheduling.nextTurn)

    /// Open a file in the editor window — creating the window on first use,
    /// otherwise adding the file as a new tab in the existing window. A file that
    /// is already open (by any path or symlink) just gets its tab selected.
    func open(_ url: URL) {
        if let controller, let window, controller.focusExisting(url) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Read before creating a tab: a file that can't be decoded faithfully is
        // never shown as an (empty or garbled) buffer that could be saved over it.
        let loaded: LoadedTextFile
        do {
            loaded = try TextFileIO.load(url)
        } catch {
            EditorPrompts.showCannotOpen(url, error: error, window: window)
            return
        }

        if let controller, let window {
            controller.open(loaded)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = AceEditorController(files: [loaded])
        self.controller = controller

        let hosting = NSHostingController(rootView: CodeEditorView(controller: controller))
        let window  = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = url.lastPathComponent
        window.setContentSize(NSSize(width: 1040, height: 720))
        window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("SelwayEditorWindow")
        // Its files are tabs inside the window; it never joins a tab group
        // (browser windows tab only with each other).
        window.tabbingMode = .disallowed
        self.window = window
        controller.window = window

        controller.onTitleChange = { [weak window] title in window?.title = title }
        controller.onRequestClose = { [weak self, weak window] in self?.closeEmptyWindow(window) }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Names of documents with unsaved edits (for the quit prompt).
    var unsavedDocumentNames: [String] {
        controller?.docs.filter(\.modified).map(\.name) ?? []
    }

    func isEditorWindow(_ candidate: NSWindow?) -> Bool {
        candidate != nil && candidate === window
    }

    func saveAll(completion: @escaping (Bool) -> Void) {
        guard let controller else { completion(true); return }
        controller.saveAll(completion: completion)
    }

    /// The last tab was closed, its changes already saved or discarded: the window
    /// goes too, so it never shows text that no document backs. Usually called from
    /// the Save / Don't Save alert's callback, where `performClose` is refused
    /// because the alert is still attached; so this closes on the next turn, with
    /// `close()` (nothing is left to ask about), unless a file was opened meanwhile.
    private func closeEmptyWindow(_ window: NSWindow?) {
        deferredClose.request(when: { [weak self, weak window] in
            guard let self, let window, self.window === window else { return false }
            return self.controller?.isEmpty ?? true
        }, { [weak window] in
            window?.close()
        })
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let controller, controller.hasUnsavedChanges else { return true }
        controller.reviewUnsavedChanges { [weak self] proceed in
            // Once the alert has gone (see closeEmptyWindow). close() skips
            // windowShouldClose, so this doesn't ask twice.
            if proceed { self?.deferredClose.request { sender.close() } }
        }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        controller?.checkForExternalChanges()
    }

    func windowWillClose(_ notification: Notification) {
        controller = nil
        window = nil
    }
}

// MARK: - Controller bridging WKWebView (Ace) and SwiftUI

@MainActor
final class AceEditorController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {

    let webView: WKWebView

    @Published var docs: [OpenDoc] = []
    @Published var activeID: String?
    @Published var statusFlash: String?
    @Published var isReady = false

    /// Callbacks owned by the window manager.
    var onTitleChange: ((String) -> Void)?
    var onRequestClose: (() -> Void)?
    /// Host window, for sheets.
    weak var window: NSWindow?

    // Mirrored from @AppStorage by the view.
    var wrap        = false
    var fontSize    = EditorFontSize.defaultSize
    var sublimeKeys = false
    var minimapOn   = true

    private var pendingFiles: [LoadedTextFile]
    private let handlerName = "bridge"
    /// Kept for deinit, which can't touch the main-actor web view.
    private let userContent: WKUserContentController
    /// The only page this web view may show (it has the `bridge` handler attached).
    private let editorPage: URL?
    /// One save per tab at a time; a second request waits for the first.
    private let saves = TextFileSaveQueue<String>()
    private var crashGuard = EditorCrashGuard()
    private var isPromptingExternalChange = false

    init(files: [LoadedTextFile]) {
        self.pendingFiles = files

        let config = WKWebViewConfiguration()
        let ucc    = WKUserContentController()
        config.userContentController = ucc
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        self.userContent = ucc
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.editorPage = Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: "AceEditor")

        super.init()

        ucc.add(WeakScriptMessageProxy(self), name: handlerName)
        webView.navigationDelegate = self
        loadEditorPage()
    }

    deinit {
        let ucc = userContent, name = handlerName
        DispatchQueue.main.async { ucc.removeScriptMessageHandler(forName: name) }
    }

    private func loadEditorPage() {
        guard let html = editorPage else { return }
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    var activeDoc: OpenDoc? { docs.first { $0.id == activeID } }
    var hasUnsavedChanges: Bool { docs.contains(where: \.modified) }
    /// No document is open or waiting to open.
    var isEmpty: Bool { docs.isEmpty && pendingFiles.isEmpty }

    private func doc(_ id: String) -> OpenDoc? { docs.first { $0.id == id } }

    private func update(_ id: String, _ change: (inout OpenDoc) -> Void) {
        guard let idx = docs.firstIndex(where: { $0.id == id }) else { return }
        change(&docs[idx])
    }

    private var currentTitle: String {
        guard let d = activeDoc else {
            return String(localized: "Editor", comment: "Window title when the code editor has no active document")
        }
        return (d.modified ? "• " : "") + d.name
    }

    private func notifyTitle() { onTitleChange?(currentTitle) }

    private var themeForAppearance: String {
        let dark = webView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? "ace/theme/monokai" : "ace/theme/github"
    }

    // MARK: Navigation policy

    private func isEditorPage(_ url: URL?) -> Bool {
        guard let url, url.isFileURL, let page = editorPage else { return false }
        return url.standardizedFileURL.path == page.standardizedFileURL.path
    }

    /// Only the bundled editor page may load in this web view: it has the `bridge`
    /// handler attached, so any other content (a dropped file, a link) could drive it.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        decisionHandler(mainFrame && isEditorPage(navigationAction.request.url) ? .allow : .cancel)
    }

    /// If the web content process dies, every buffer in it is gone. Reload the page
    /// and reopen the files from disk; never let a save run against the empty page.
    /// Files that can no longer be read are named, and a page that keeps crashing
    /// isn't reloaded forever.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let lost = docs.filter(\.modified).map(\.name)
        var reopen: [LoadedTextFile] = []
        var unreadable: [String] = []
        for d in docs {
            do { reopen.append(try TextFileIO.reload(d.resolvedURL, openedAs: d.url, expectedFolder: d.snapshot.folder)) }
            catch { unreadable.append(String(localized: "\(d.name) (\(error.localizedDescription))", comment: "Unreadable editor document name and reason")) }
        }
        docs = []
        activeID = nil
        isReady = false
        saves.failAll()

        var notes: [String] = []
        if !lost.isEmpty {
            notes.append(String(localized: "Unsaved changes in \(lost.joined(separator: ", ")) couldn't be recovered.", comment: "Editor crash alert detail for unsaved documents that could not be recovered"))
        }
        guard crashGuard.shouldReopen(afterCrashAt: Date()) else {
            pendingFiles = []
            notifyTitle()
            notes.append(String(localized: "It stopped \(crashGuard.limit) times in a minute, so Selway closed it instead of reopening your files. Open them again to keep editing.", comment: "Editor crash alert detail after repeated crashes"))
            EditorPrompts.showError(String(localized: "The editor keeps stopping unexpectedly.", comment: "Code editor crash alert title"),
                                    info: notes.joined(separator: "\n\n"), window: window) { [weak self] in
                self?.onRequestClose?()
            }
            return
        }
        // Files queued before the page first became ready are still waiting: keep them.
        pendingFiles.append(contentsOf: reopen)
        loadEditorPage()
        notifyTitle()
        if !reopen.isEmpty { notes.append(String(localized: "The files were reopened from disk.", comment: "Editor crash alert detail after reopening documents")) }
        if !unreadable.isEmpty {
            notes.append(String(localized: "These couldn't be reopened:\n\(unreadable.map { "• \($0)" }.joined(separator: "\n"))", comment: "Editor crash alert detail listing documents that could not be reopened"))
        }
        if !lost.isEmpty || !unreadable.isEmpty {
            EditorPrompts.showError(String(localized: "The editor stopped unexpectedly.", comment: "Code editor crash alert title"),
                                    info: notes.joined(separator: "\n\n"), window: window)
        }
    }

    // MARK: JS → Swift

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, isEditorPage(message.frameInfo.request.url) else { return }
        let body = message.body as? [String: Any] ?? [:]
        guard let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            let queued = pendingFiles
            pendingFiles = []
            for file in queued { openOne(file) }
        case "changed":
            if let id = body["id"] as? String { setModified(id, true) }
        case "save":
            // ⌘S in the page; without an id no document is open.
            if let id = body["id"] as? String { save(id) { _ in } } else { saveActive() }
        case "open":
            presentOpenPanel()
        case "closeTab":
            if let id = body["id"] as? String { requestCloseTab(id) }
        case "minimap":
            if let on = body["on"] as? Bool {
                minimapOn = on
                UserDefaults.standard.set(on, forKey: "selwayEditorMinimap")
            }
        default:
            break
        }
    }

    // MARK: Tabs

    func open(_ file: LoadedTextFile) {
        guard isReady else { pendingFiles.append(file); return }
        openOne(file)
    }

    /// Selects the tab already showing `url` (same file through any path), and
    /// offers to reload it if it changed on disk. False if it isn't open.
    func focusExisting(_ url: URL) -> Bool {
        if pendingFiles.contains(where: { TextFileIO.isSameFile($0.resolvedURL, url) }) { return true }
        guard let existing = docs.first(where: { TextFileIO.isSameFile($0.resolvedURL, url) }) else { return false }
        switchTo(existing.id)
        checkForExternalChange(existing.id, askAgain: true)
        return true
    }

    private func openOne(_ file: LoadedTextFile) {
        if let existing = docs.first(where: { TextFileIO.isSameFile($0.resolvedURL, file.resolvedURL) }) {
            switchTo(existing.id)
            return
        }
        let id = UUID().uuidString
        docs.append(OpenDoc(id: id, url: file.url, resolvedURL: file.resolvedURL,
                            format: file.format, snapshot: file.snapshot))
        activeID = id
        guard let textJSON = jsonLiteral(file.text),
              let nameJSON = jsonLiteral(file.url.lastPathComponent)
        else { return }
        let keymap = sublimeKeys ? "\"ace/keyboard/sublime\"" : "null"
        let js = "Selway.openDoc(\"\(id)\", \(textJSON), \(nameJSON), \"\(themeForAppearance)\", \(wrap), \(keymap), \(fontSize));"
        run(js)
        run("Selway.setMinimap(\(minimapOn));")
        notifyTitle()
        if file.format.hadMixedLineEndings {
            flash(String(localized: "Mixed line endings: saving uses \(file.format.lineEnding.displayName)", comment: "Editor status message for a document with mixed line endings"))
        }
    }

    /// JSON-encodes a string for safe interpolation into JavaScript.
    private func jsonLiteral(_ s: String) -> String? {
        guard let data = try? JSONEncoder().encode(s) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func switchTo(_ id: String) {
        activeID = id
        run("Selway.switchDoc(\"\(id)\");")
        notifyTitle()
    }

    /// Closes a tab, asking first if it has unsaved changes.
    func requestCloseTab(_ id: String) {
        guard let d = doc(id) else { return }
        guard d.modified else { closeTab(id); return }
        if activeID != id { switchTo(id) }
        EditorPrompts.confirmClose(documentName: d.name, window: window) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .save:    self.save(id) { ok in if ok { self.closeTab(id) } }
            case .discard: self.closeTab(id)
            case .cancel:  break
            }
        }
    }

    /// Removes a tab whose changes were saved or discarded. Closing the last one
    /// closes the window (see EditorWindowManager.closeEmptyWindow).
    private func closeTab(_ id: String) {
        guard doc(id) != nil else { return }
        let plan = EditorTabClosePlan.closing(id, tabs: docs.map(\.id), active: activeID)
        run("Selway.closeDoc(\"\(id)\");")
        docs.removeAll { $0.id == id }
        activeID = plan.active
        if let a = plan.active { run("Selway.switchDoc(\"\(a)\");") }
        notifyTitle()
        if plan.closesWindow { onRequestClose?() }
    }

    /// Asks about every modified document before the window closes; `completion(true)`
    /// means it's safe to close (saved or discarded).
    func reviewUnsavedChanges(completion: @escaping (Bool) -> Void) {
        let dirty = docs.filter(\.modified)
        guard !dirty.isEmpty else { completion(true); return }
        EditorPrompts.confirmCloseAll(documentNames: dirty.map(\.name), window: window) { [weak self] choice in
            switch choice {
            case .save:    self?.saveAll(completion: completion) ?? completion(false)
            case .discard: completion(true)
            case .cancel:  completion(false)
            }
        }
    }

    // MARK: Save

    func saveActive() {
        guard let id = activeID else { NSSound.beep(); return }   // no document open
        save(id) { _ in }
    }

    /// Saves modified documents one after another; stops at the first that isn't saved.
    func saveAll(completion: @escaping (Bool) -> Void) {
        let ids = docs.filter(\.modified).map(\.id)
        func next(_ index: Int) {
            guard index < ids.count else { completion(true); return }
            save(ids[index]) { ok in ok ? next(index + 1) : completion(false) }
        }
        next(0)
    }

    /// Saves one document. Writes only when it is modified and its text was actually
    /// retrieved from the editor; `completion(true)` once nothing is left unsaved.
    /// If a save of it is already running (e.g. ⌘S is showing a conflict question),
    /// this waits for that one and then saves whatever is still unsaved.
    func save(_ id: String, completion: @escaping (Bool) -> Void) {
        guard let d = doc(id) else {
            // Never a silent no-op: the user asked to save and nothing will be written.
            EditorPrompts.showError(String(localized: "The document couldn't be saved.", comment: "Text editor save error title"),
                                    info: String(localized: "It's no longer open in the editor. Nothing was written to disk.", comment: "Text editor save error detail"),
                                    window: window)
            completion(false)
            return
        }
        guard d.modified else { completion(true); return }
        let startNow = saves.begin(id) { [weak self] ok in
            guard let self, ok else { completion(false); return }
            // The save waited for succeeded; if its tab was closed afterwards (the
            // conflict sheet was answered with Save, then the tab closed), nothing
            // of it is left unsaved.
            guard self.doc(id) != nil else { completion(true); return }
            self.save(id, completion: completion)
        }
        guard startNow else { return }
        let finish: (Bool) -> Void = { [weak self] ok in
            completion(ok)
            self?.saves.finish(id, ok: ok)
        }

        webView.evaluateJavaScript("Selway.getDocContent(\"\(id)\");") { [weak self] result, error in
            guard let self else { finish(false); return }
            guard error == nil, let reply = EditorDocReply.parse(result) else {
                let reason = error?.localizedDescription ?? String(localized: "The editor didn't return the document's text.", comment: "Text editor save error detail")
                EditorPrompts.showError(String(localized: "“\(d.name)” couldn't be saved.", comment: "Text editor save error title with document name"),
                                        info: String(localized: "\(reason) Nothing was written to disk.", comment: "Text editor save error detail with reason"), window: self.window)
                finish(false)
                return
            }
            self.write(id, text: reply.text, version: reply.version, completion: finish)
        }
    }

    private func write(_ id: String, text: String, version: Int, completion: @escaping (Bool) -> Void) {
        guard let d = doc(id) else { completion(false); return }
        TextFileSaveFlow.save(text: text, to: d.resolvedURL, name: d.name, format: d.format,
                              expected: d.snapshot, window: window) { [weak self] outcome in
            guard let self else { completion(false); return }
            switch outcome {
            case .saved(let snapshot, let format, let resolvedURL):
                self.update(id) {
                    $0.resolvedURL = resolvedURL
                    $0.snapshot = snapshot
                    $0.format = format
                    $0.declinedReloadSnapshot = nil
                }
                self.setModified(id, false)
                // Typing that happened while saving re-marks the tab as modified.
                self.run("Selway.savedVersion(\"\(id)\", \(version));")
                self.flash(String(localized: "Saved \(d.name)", comment: "Editor status message after saving a document"))
                completion(true)
            case .reloadRequested:
                completion(self.reload(id))
            case .cancelled, .failed:
                completion(false)
            }
        }
    }

    // MARK: External changes

    /// Replaces a tab's buffer with the file on disk. False if it couldn't be read.
    @discardableResult
    private func reload(_ id: String) -> Bool {
        guard let d = doc(id) else { return false }
        let loaded: LoadedTextFile
        do {
            loaded = try TextFileIO.reload(d.resolvedURL, openedAs: d.url, expectedFolder: d.snapshot.folder)
        } catch {
            EditorPrompts.showCannotOpen(d.url, error: error, window: window)
            return false
        }
        guard let textJSON = jsonLiteral(loaded.text) else { return false }
        update(id) {
            $0.resolvedURL = loaded.resolvedURL
            $0.format = loaded.format
            $0.snapshot = loaded.snapshot
            $0.declinedReloadSnapshot = nil
        }
        run("Selway.replaceDoc(\"\(id)\", \(textJSON));")
        setModified(id, false)
        flash(String(localized: "Reloaded \(d.name)", comment: "Editor status message after reloading a document"))
        return true
    }

    /// On refocus: offer to reload unmodified tabs whose files changed on disk.
    /// Modified tabs are left alone — saving them asks about the conflict.
    func checkForExternalChanges() {
        for d in docs where !d.modified {
            if externallyChanged(d, askAgain: false) {
                checkForExternalChange(d.id, askAgain: false)
                return   // one question at a time; the next refocus checks the rest
            }
        }
    }

    private func externallyChanged(_ d: OpenDoc, askAgain: Bool) -> Bool {
        guard let now = TextFileIO.snapshot(of: d.resolvedURL), now != d.snapshot else { return false }
        return askAgain || now != d.declinedReloadSnapshot
    }

    private func checkForExternalChange(_ id: String, askAgain: Bool) {
        guard !isPromptingExternalChange, let d = doc(id), !d.modified,
              externallyChanged(d, askAgain: askAgain) else { return }
        isPromptingExternalChange = true
        EditorPrompts.offerReload(documentName: d.name, window: window) { [weak self] reload in
            guard let self else { return }
            self.isPromptingExternalChange = false
            if reload {
                self.reload(id)
            } else {
                self.update(id) { $0.declinedReloadSnapshot = TextFileIO.snapshot(of: $0.resolvedURL) }
            }
        }
    }

    private func setModified(_ id: String, _ value: Bool) {
        guard let idx = docs.firstIndex(where: { $0.id == id }), docs[idx].modified != value else { return }
        docs[idx].modified = value
        notifyTitle()
    }

    // MARK: Open panel

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls where TextFileDetector.isEditableText(url) {
                EditorWindowManager.shared.open(url)
            }
        }
    }

    // MARK: Editor commands (toolbar)

    func setMinimap(_ on: Bool) { minimapOn = on; run("Selway.setMinimap(\(on));") }
    func toggleWrap()        { wrap.toggle(); run("Selway.setWrapAll(\(wrap));") }
    func setFontSize(_ n: Int) { fontSize = EditorFontSize.clamped(n); run("Selway.setFontSize(\(fontSize));") }
    func toggleSublime()     { sublimeKeys.toggle(); run("Selway.setKeymap(\(sublimeKeys ? "\"ace/keyboard/sublime\"" : "null"));") }
    func find()              { run("Selway.find();") }
    func gotoLine()          { run("Selway.gotoLine();") }
    func palette()           { run("Selway.palette();") }
    func settings()          { run("Selway.settings();") }

    private func run(_ js: String) { webView.evaluateJavaScript(js, completionHandler: nil) }

    private func flash(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { statusFlash = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            withAnimation(.easeOut(duration: 0.3)) { self?.statusFlash = nil }
        }
    }
}

/// Breaks the retain cycle WKUserContentController → handler → controller.
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(uc, didReceive: message)
    }
}

// MARK: - NSViewRepresentable host

private struct AceWebView: NSViewRepresentable {
    let controller: AceEditorController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Editor view (hosted inside the standalone window)

struct CodeEditorView: View {
    @ObservedObject var ctrl: AceEditorController

    @AppStorage("selwayEditorWrap")        private var wrap        = false
    // Also changed by View → Make Text Bigger / Smaller while this window is key.
    @AppStorage(EditorFontSize.key)        private var fontSize    = EditorFontSize.defaultSize
    @AppStorage("selwayEditorSublimeKeys") private var sublimeKeys = false
    @AppStorage("selwayEditorMinimap")     private var minimap     = true

    init(controller: AceEditorController) { self.ctrl = controller }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if ctrl.docs.count > 1 { tabBar; Divider() }
            AceWebView(controller: ctrl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear {
            // A hand-edited size out of range is stored clamped, as the editor shows
            // it, so the menu steps from what's on screen.
            let clamped = EditorFontSize.clamped(fontSize)
            if fontSize != clamped { fontSize = clamped }
            ctrl.wrap        = wrap
            ctrl.fontSize    = clamped
            ctrl.sublimeKeys = sublimeKeys
            ctrl.minimapOn   = minimap
        }
        .onChange(of: fontSize) { _, size in
            if ctrl.fontSize != size { ctrl.setFontSize(size) }
        }
        // Settings → Integrations changes these while the editor is open.
        .onChange(of: wrap) { _, on in
            if ctrl.wrap != on { ctrl.toggleWrap() }
        }
        .onChange(of: sublimeKeys) { _, on in
            if ctrl.sublimeKeys != on { ctrl.toggleSublime() }
        }
        .onChange(of: minimap) { _, on in
            if ctrl.minimapOn != on { ctrl.setMinimap(on) }
        }
        .background(
            Button { ctrl.saveActive() } label: { EmptyView() }
                .keyboardShortcut("s", modifiers: .command)
                .hidden()
        )
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.caption)
                .foregroundStyle(Color.accentColor)

            if let flash = ctrl.statusFlash {
                Text(flash).font(.caption).foregroundStyle(.secondary).transition(.opacity)
            }

            Spacer(minLength: 0)

            if let doc = ctrl.activeDoc {
                Text("\(doc.format.encodingName) · \(doc.format.lineEnding.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Saved in the file's original encoding and line endings")
            }

            Button { ctrl.palette() } label: { Image(systemName: "command") }
                .buttonStyle(.borderless).help("Command Palette  ⌘⇧P")
            Button { ctrl.find() } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Find / Replace  ⌘F")
            Button { ctrl.gotoLine() } label: { Image(systemName: "arrow.right.to.line") }
                .buttonStyle(.borderless).help("Go to Line  ⌘L")
            Button { ctrl.presentOpenPanel() } label: { Image(systemName: "doc.badge.plus") }
                .buttonStyle(.borderless).help("Open File in New Tab  ⌘O")
            Button { ctrl.toggleWrap(); wrap = ctrl.wrap } label: {
                Image(systemName: wrap ? "text.alignleft" : "text.append")
            }
            .buttonStyle(.borderless).help(wrap ? "Wrap: on" : "Wrap: off")

            Button { minimap.toggle(); ctrl.setMinimap(minimap) } label: {
                Image(systemName: minimap ? "rectangle.righthalf.inset.filled" : "rectangle.righthalf.inset.filled")
                    .foregroundStyle(minimap ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless).help(minimap ? "Minimap: on  ⌘⇧M" : "Minimap: off  ⌘⇧M")

            Menu {
                Button("Settings…")     { ctrl.settings() }
                Divider()
                Button("Increase Font") { ctrl.setFontSize(fontSize + 1); fontSize = ctrl.fontSize }
                Button("Decrease Font") { ctrl.setFontSize(fontSize - 1); fontSize = ctrl.fontSize }
                Divider()
                Toggle("Sublime Keybindings", isOn: Binding(
                    get: { sublimeKeys },
                    set: { _ in ctrl.toggleSublime(); sublimeKeys = ctrl.sublimeKeys }
                ))
            } label: {
                Image(systemName: "textformat.size")
            }
            .menuStyle(.borderlessButton).frame(width: 34).help("Editor options")

            Button(action: { ctrl.saveActive() }) {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(ctrl.activeDoc?.modified != true)
            .help("Save  ⌘S")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Tab bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(ctrl.docs) { doc in
                    tabChip(doc)
                    Divider().frame(height: 22)
                }
            }
        }
        .background(.bar)
    }

    private func tabChip(_ doc: OpenDoc) -> some View {
        let isActive = doc.id == ctrl.activeID
        return HStack(spacing: 6) {
            Text((doc.modified ? "• " : "") + doc.url.lastPathComponent)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
            Button { ctrl.requestCloseTab(doc.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Close Tab  ⌘W")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { ctrl.switchTo(doc.id) }
    }
}
