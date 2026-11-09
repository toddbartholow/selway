import SwiftUI
import WebKit
import AppKit

// MARK: - Wrapper so URL works with .sheet(item:)

struct MarkdownFileItem: Identifiable {
    let id  = UUID()
    let url: URL
}

// MARK: - Read / Edit mode

private enum MDMode: String, Hashable {
    case read = "Read"
    case edit = "Edit"
}

// MARK: - Document model (owned by MarkdownWindowManager)

/// The open Markdown file: buffer, dirty state, on-disk format and snapshot.
/// Lives outside the SwiftUI view so the window and the app delegate can ask about
/// unsaved changes and save them before closing or quitting.
@MainActor
final class MarkdownDocument: ObservableObject {
    @Published private(set) var url: URL
    @Published var text: String
    @Published var isModified = false
    /// Files we followed links from, for Back.
    @Published private(set) var navStack: [URL] = []
    /// Remote (http/https) images stay blocked until the user allows them for this file.
    @Published var allowRemoteImages = false
    /// Changes whenever the buffer is replaced from disk (navigation, reload).
    @Published private(set) var revision = UUID()
    @Published private(set) var statusFlash: String?

    private(set) var format: TextFileFormat
    private(set) var snapshot: TextFileSnapshot?
    private(set) var resolvedURL: URL
    private var declinedReloadSnapshot: TextFileSnapshot?
    private var isPromptingExternalChange = false
    /// One save at a time; a save requested meanwhile (quit, close) waits for it.
    private let saves = TextFileSaveQueue<Int>()
    /// Host window, for sheets.
    weak var window: NSWindow?

    init(_ file: LoadedTextFile) {
        url         = file.url
        text        = file.text
        format      = file.format
        snapshot    = file.snapshot
        resolvedURL = file.resolvedURL
    }

    var displayName: String { url.deletingPathExtension().lastPathComponent }
    var fileName: String { url.lastPathComponent }
    /// Relative links and images resolve against the file's folder.
    var baseURL: URL { url.deletingLastPathComponent() }

    private func apply(_ file: LoadedTextFile, sameFile: Bool) {
        url         = file.url
        text        = file.text
        format      = file.format
        snapshot    = file.snapshot
        resolvedURL = file.resolvedURL
        isModified  = false
        declinedReloadSnapshot = nil
        if !sameFile { allowRemoteImages = false }
        revision = UUID()
    }

    // MARK: Save

    /// Writes the buffer if it is modified. `completion(true)` means nothing is left
    /// unsaved; on false the user cancelled or an error was already shown. If a save
    /// is already running (its conflict question is up), this waits for it and then
    /// saves whatever is still unsaved.
    func save(completion: @escaping (Bool) -> Void = { _ in }) {
        guard isModified else { completion(true); return }
        let startNow = saves.begin(0) { [weak self] ok in
            guard let self, ok else { completion(false); return }
            self.save(completion: completion)
        }
        guard startNow else { return }
        let completion: (Bool) -> Void = { [weak self] ok in
            completion(ok)
            self?.saves.finish(0, ok: ok)
        }
        let text = self.text
        TextFileSaveFlow.save(text: text, to: resolvedURL, name: fileName, format: format,
                              expected: snapshot, window: window) { [weak self] outcome in
            guard let self else { completion(false); return }
            switch outcome {
            case .saved(let snapshot, let format, let resolvedURL):
                self.resolvedURL = resolvedURL
                self.snapshot = snapshot
                self.format = format
                self.declinedReloadSnapshot = nil
                if self.text == text { self.isModified = false }
                self.flash("Saved")
                completion(!self.isModified)
            case .reloadRequested:
                completion(self.reload())
            case .cancelled:
                completion(false)
            case .failed:
                self.flash("Save failed")
                completion(false)
            }
        }
    }

    /// Runs `action` only once the buffer is safely on disk.
    func saveIfNeeded(then action: @escaping () -> Void) {
        save { ok in if ok { action() } }
    }

    // MARK: Navigation

    /// Follows a link to another Markdown file, saving this one first. Stays put
    /// (with the error shown) if the save or the load fails.
    func navigate(to dest: URL, onSuccess: @escaping () -> Void = {}) {
        saveIfNeeded { [weak self] in
            guard let self else { return }
            do {
                let file = try TextFileIO.load(dest)
                self.navStack.append(self.url)
                self.apply(file, sameFile: false)
                onSuccess()
            } catch {
                EditorPrompts.showCannotOpen(dest, error: error, window: self.window)
            }
        }
    }

    func goBack() {
        guard let previous = navStack.last else { return }
        saveIfNeeded { [weak self] in
            guard let self else { return }
            do {
                let file = try TextFileIO.load(previous)
                self.navStack.removeLast()
                self.apply(file, sameFile: false)
            } catch {
                EditorPrompts.showCannotOpen(previous, error: error, window: self.window)
            }
        }
    }

    // MARK: External changes

    /// Replaces the buffer with the file on disk. False if it couldn't be read.
    @discardableResult
    func reload() -> Bool {
        do {
            apply(try TextFileIO.reload(resolvedURL, openedAs: url, expectedFolder: snapshot?.folder), sameFile: true)
            flash("Reloaded")
            return true
        } catch {
            EditorPrompts.showCannotOpen(url, error: error, window: window)
            return false
        }
    }

    /// Offers to reload when the file changed on disk and there are no unsaved edits.
    /// With unsaved edits nothing is asked here: saving detects the conflict.
    func checkForExternalChange(askAgain: Bool) {
        guard !isModified, !isPromptingExternalChange,
              let now = TextFileIO.snapshot(of: resolvedURL), now != snapshot,
              askAgain || now != declinedReloadSnapshot else { return }
        isPromptingExternalChange = true
        EditorPrompts.offerReload(documentName: fileName, window: window) { [weak self] reload in
            guard let self else { return }
            self.isPromptingExternalChange = false
            if reload { self.reload() } else { self.declinedReloadSnapshot = now }
        }
    }

    /// Save / Don't Save / Cancel before the document goes away; `completion(true)`
    /// when it's fine to close.
    func reviewBeforeClosing(completion: @escaping (Bool) -> Void) {
        guard isModified else { completion(true); return }
        EditorPrompts.confirmClose(documentName: fileName, window: window) { [weak self] choice in
            switch choice {
            case .save:    self?.save(completion: completion) ?? completion(false)
            case .discard: completion(true)
            case .cancel:  completion(false)
            }
        }
    }

    private func flash(_ message: LocalizedStringResource) {
        withAnimation(.easeOut(duration: 0.2)) { statusFlash = String(localized: message) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            withAnimation(.easeOut(duration: 0.3)) { self?.statusFlash = nil }
        }
    }
}

// MARK: - Full Markdown reader + editor

struct MarkdownReaderView: View {
    @ObservedObject var doc: MarkdownDocument
    /// Closes the hosting window (supplied by MarkdownWindowManager).
    var onClose: () -> Void = {}
    /// Pushes the live document title (with • when dirty) to the window titlebar.
    var onTitleChange: ((String) -> Void)? = nil

    @State private var mode:        MDMode  = .read
    @State private var refreshID:   UUID    = UUID()
    @State private var previewText: String  = ""
    @StateObject private var editorCtrl = MarkdownEditorController()
    @State private var showLinkSheet = false
    @State private var linkURLDraft  = "https://"
    @State private var previewTask: Task<Void, Never>?
    @State private var hasRemoteImages = false
    /// This window's own text size (View → Make Text Bigger / Smaller while it is key).
    @AppStorage(UserPreferences.markdownTextSizeKey) private var textSizeRaw = TextSize.actual.percent

    private var textScale: CGFloat { CGFloat(TextSize.fromStorage(textSizeRaw).scale) }

    init(document: MarkdownDocument,
         onClose: @escaping () -> Void = {},
         onTitleChange: ((String) -> Void)? = nil) {
        self.doc           = document
        self.onClose       = onClose
        self.onTitleChange = onTitleChange
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if mode == .edit {
                formatToolbar
                Divider()
            } else {
                Divider()
            }
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { pushTitle(); previewText = doc.text }
        .onChange(of: doc.revision) { _, _ in
            pushTitle()
            previewTask?.cancel()
            previewText = doc.text
            refreshID = UUID()
        }
        .onChange(of: doc.isModified) { _, _ in pushTitle() }
        .onChange(of: doc.text) { _, newValue in
            previewTask?.cancel()
            previewTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                previewText = newValue
                refreshID = UUID()
            }
        }
        // Unsaved edits are handled by the window (windowShouldClose) and the app
        // (applicationShouldTerminate), which ask Save / Don't Save / Cancel.
        .sheet(isPresented: $showLinkSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Insert link").scaledFont(.headline)
                TextField("https://…", text: $linkURLDraft)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { showLinkSheet = false }
                    Button("Insert") {
                        editorCtrl.run { MarkdownFormatActions.link($0, url: linkURLDraft) }
                        showLinkSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 360 * textScale)
        }
        .textSizeRoot(key: UserPreferences.markdownTextSizeKey)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Toolbar
    // ─────────────────────────────────────────────────────────────

    private var toolbar: some View {
        HStack(spacing: 8) {

            // Back — only appears after the user has followed an internal .md link
            if !doc.navStack.isEmpty {
                Button {
                    doc.goBack()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.backward")
                            .scaledFont(size: 11, weight: .semibold)
                        Text(doc.navStack.last?.deletingPathExtension().lastPathComponent ?? "Back")
                            .scaledFont(size: 12)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.borderless)
                .help("Go back")

                Divider().frame(height: 16 * textScale)
            }

            // File icon + name  (• prefix while there are unsaved changes)
            Image(systemName: "doc.text.fill")
                .scaledFont(.caption)
                .foregroundStyle(Color.accentColor)

            Text((doc.isModified ? "• " : "") + doc.displayName)
                .scaledFont(size: 13, weight: .semibold)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Saved / Save-failed flash message
            if let flash = doc.statusFlash {
                Text(flash)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            // Remote images are blocked by default: loading them tells the server
            // the file was opened. One click allows them for this document.
            if hasRemoteImages && !doc.allowRemoteImages {
                Button {
                    doc.allowRemoteImages = true
                } label: {
                    Label("Load Remote Images", systemImage: "photo")
                        .scaledFont(.caption)
                }
                .buttonStyle(.borderless)
                .help("This document shows images from the internet. Loading them lets those servers see that you opened it.")
            }

            // Read / Edit segmented toggle
            Picker("Mode", selection: $mode) {
                Text("Read").tag(MDMode.read)
                Text("Edit").tag(MDMode.edit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 100 * textScale)
            .onChange(of: mode) { _, newMode in
                // Auto-save when switching back to reader; stay in Edit if it fails.
                if newMode == .read, doc.isModified {
                    doc.save { ok in
                        if ok { refreshID = UUID() } else { mode = .edit }
                    }
                }
            }

            // Save button — only in edit mode, enabled when dirty
            if mode == .edit {
                Button { doc.save() } label: {
                    Image(systemName: "square.and.arrow.down")
                        .scaledFont(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(!doc.isModified)
                .help("Save  ⌘S")
                // Hidden button captures ⌘S keyboard shortcut
                .background(
                    Button { doc.save() } label: { EmptyView() }
                        .keyboardShortcut("s", modifiers: .command)
                        .hidden()
                )
            }

            Divider().frame(height: 16 * textScale)

            // Open this file in Selway's own built-in code editor
            Button {
                doc.saveIfNeeded { EditorWindowManager.shared.open(doc.url) }
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .scaledFont(.caption)
            }
            .buttonStyle(.borderless)
            .help("Open in Selway editor")

            Divider().frame(height: 16 * textScale)

            Button("Done") { doc.saveIfNeeded { onClose() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Format toolbar (edit mode)
    // ─────────────────────────────────────────────────────────────

    // Formatting edits go through the text view, whose delegate marks the document
    // modified only when the text actually changes.
    private var formatToolbar: some View {
        HStack(spacing: 2) {
            formatButton("arrow.uturn.backward", help: "Undo", enabled: editorCtrl.canUndo) {
                editorCtrl.run { MarkdownFormatActions.undo($0) }
            }
            formatButton("arrow.uturn.forward", help: "Redo", enabled: editorCtrl.canRedo) {
                editorCtrl.run { MarkdownFormatActions.redo($0) }
            }
            Divider().frame(height: 16 * textScale).padding(.horizontal, 4)

            formatButton("bold", help: "Bold") {
                editorCtrl.run { MarkdownFormatActions.bold($0) }
            }
            formatButton("italic", help: "Italic") {
                editorCtrl.run { MarkdownFormatActions.italic($0) }
            }
            formatButton("strikethrough", help: "Strikethrough") {
                editorCtrl.run { MarkdownFormatActions.strikethrough($0) }
            }
            formatButton("chevron.left.forwardslash.chevron.right", help: "Inline code") {
                editorCtrl.run { MarkdownFormatActions.inlineCode($0) }
            }
            Divider().frame(height: 16 * textScale).padding(.horizontal, 4)

            formatButton("textformat.size.larger", help: "Heading 1") {
                editorCtrl.run { MarkdownFormatActions.heading($0, level: 1) }
            }
            formatButton("textformat.size", help: "Heading 2") {
                editorCtrl.run { MarkdownFormatActions.heading($0, level: 2) }
            }
            formatButton("textformat.size.smaller", help: "Heading 3") {
                editorCtrl.run { MarkdownFormatActions.heading($0, level: 3) }
            }
            Divider().frame(height: 16 * textScale).padding(.horizontal, 4)

            formatButton("list.bullet", help: "Bullet list") {
                editorCtrl.run { MarkdownFormatActions.bulletList($0) }
            }
            formatButton("list.number", help: "Numbered list") {
                editorCtrl.run { MarkdownFormatActions.numberedList($0) }
            }
            formatButton("text.quote", help: "Quote") {
                editorCtrl.run { MarkdownFormatActions.quote($0) }
            }
            formatButton("curlybraces", help: "Code block") {
                editorCtrl.run { MarkdownFormatActions.codeFence($0) }
            }
            formatButton("link", help: "Link") {
                linkURLDraft = "https://"
                showLinkSheet = true
            }
            formatButton("minus", help: "Horizontal rule") {
                editorCtrl.run { MarkdownFormatActions.horizontalRule($0) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func formatButton(_ systemName: String, help: LocalizedStringKey, enabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .scaledFont(size: 12, weight: .semibold)
                .frame(width: 26 * textScale, height: 22 * textScale)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Content area
    // ─────────────────────────────────────────────────────────────

    @ViewBuilder
    private var contentArea: some View {
        switch mode {
        case .read:
            // Reuse in-memory buffer — avoid a second disk read for the preview.
            // The file's folder is the base URL so relative links and images work.
            MarkdownWebView(source: MarkdownWebSource(markdown: doc.text, title: doc.displayName,
                                                      baseURL: doc.baseURL),
                            allowRemoteImages: doc.allowRemoteImages,
                            refreshID: refreshID,
                            zoom: textScale,
                            onNavigate: { dest in doc.navigate(to: dest) },
                            onRender: { hasRemoteImages = $0 })
        case .edit:
            HSplitView {
                MarkdownEditorView(text: $doc.text, isModified: $doc.isModified, controller: editorCtrl,
                                   fontSize: (14 * textScale).rounded())
                    .frame(minWidth: 280)
                MarkdownWebView(source: MarkdownWebSource(markdown: previewText, title: doc.displayName,
                                                          baseURL: doc.baseURL),
                                allowRemoteImages: doc.allowRemoteImages,
                                refreshID: refreshID,
                                zoom: textScale,
                                onNavigate: { dest in doc.navigate(to: dest) { mode = .read } },
                                onRender: { hasRemoteImages = $0 })
                .frame(minWidth: 240)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Helpers
    // ─────────────────────────────────────────────────────────────

    /// Keep the window titlebar in sync with the current file + dirty state.
    private func pushTitle() {
        onTitleChange?((doc.isModified ? "• " : "") + doc.displayName)
    }
}

// MARK: - Standalone Markdown window (real macOS window: draggable + resizable)

/// Hosts `MarkdownReaderView` in a genuine `NSWindow` — mirroring the code
/// editor — so the reader can be dragged by its titlebar, resized, zoomed and
/// minimised like any native window (instead of a fixed, modal sheet).
@MainActor
final class MarkdownWindowManager: NSObject, NSWindowDelegate {
    static let shared = MarkdownWindowManager()

    private var window: NSWindow?
    private var document: MarkdownDocument?
    /// Closes requested from alert callbacks run once the callback has returned.
    private let deferredClose = EditorDeferredClose(schedule: EditorWindowCloseScheduling.nextTurn)

    /// Open a `.md` file in the reader window, reusing the existing window if any.
    func open(_ url: URL) {
        // The file read and written, not the URL it was opened by (which may be a
        // link since retargeted, or a different spelling), as the code editor does.
        if let window, let document, TextFileIO.isSameFile(document.resolvedURL, url) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            document.checkForExternalChange(askAgain: true)
            return
        }

        // Read first: a file that can't be decoded faithfully is never shown as an
        // editable buffer, and the current document stays if this one fails.
        let file: LoadedTextFile
        do {
            file = try TextFileIO.load(url)
        } catch {
            EditorPrompts.showCannotOpen(url, error: error, window: window)
            return
        }

        guard let document else { show(file); return }
        // Showing another file replaces this one; don't drop its unsaved edits.
        document.reviewBeforeClosing { [weak self] proceed in
            if proceed { self?.show(file) }
        }
    }

    private func show(_ file: LoadedTextFile) {
        let document = MarkdownDocument(file)
        self.document = document

        if let window {
            document.window = window
            window.contentViewController = makeHosting(document)
            window.title = document.displayName
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentViewController: makeHosting(document))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = document.displayName
        window.setContentSize(NSSize(width: 900, height: 680))
        window.minSize = NSSize(width: 560, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("SelwayMarkdownWindow")
        // Never a tab of a browser or editor window (browser windows tab only
        // with each other).
        window.tabbingMode = .disallowed
        self.window = window
        document.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeHosting(_ document: MarkdownDocument) -> NSHostingController<MarkdownReaderView> {
        NSHostingController(rootView: MarkdownReaderView(
            document: document,
            onClose:       { [weak self] in self?.closeAfterDone() },
            onTitleChange: { [weak self] title in self?.window?.title = title }
        ))
    }

    func isReaderWindow(_ candidate: NSWindow?) -> Bool {
        candidate != nil && candidate === window
    }

    /// Names of documents with unsaved edits (for the quit prompt).
    var unsavedDocumentNames: [String] {
        guard let document, document.isModified else { return [] }
        return [document.fileName]
    }

    func saveAll(completion: @escaping (Bool) -> Void) {
        guard let document else { completion(true); return }
        document.save(completion: completion)
    }

    /// Done: the document was saved (or had nothing to save). That is often reported
    /// from inside an alert's callback (a save that asked about a conflict), where
    /// `performClose` is refused because the alert is still attached, so this
    /// closes on the next turn. Edits typed since then still get asked about.
    private func closeAfterDone() {
        guard let window else { return }
        deferredClose.request(when: { [weak self, weak window] in
            window != nil && self?.window === window
        }, { [weak self, weak window] in
            guard let window else { return }
            if self?.document?.isModified == true { window.performClose(nil) } else { window.close() }
        })
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let document, document.isModified else { return true }
        document.reviewBeforeClosing { [weak self] proceed in
            // Once the alert has gone (see closeAfterDone). close() skips
            // windowShouldClose, so this doesn't ask twice.
            if proceed { self?.deferredClose.request { sender.close() } }
        }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        document?.checkForExternalChange(askAgain: false)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        document = nil
    }
}

// MARK: - WKWebView representable

struct MarkdownWebSource: Equatable {
    let markdown: String
    let title: String
    /// Folder of the Markdown file: relative links and images resolve against it.
    let baseURL: URL
}

struct MarkdownWebView: NSViewRepresentable {
    let source:     MarkdownWebSource
    var allowRemoteImages = false
    let refreshID:  UUID          // bump to force a re-render of the same text
    /// The window's text size: WebKit's page zoom, which reflows the text.
    var zoom:       CGFloat = 1
    let onNavigate: (URL) -> Void
    /// Reports whether the document has remote images (blocked or not).
    var onRender:   (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onNavigate: onNavigate, onRender: onRender) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs
        // Local images: a page loaded from a string can't read files, so they come
        // from this handler, which serves only the images the document references.
        config.setURLSchemeHandler(context.coordinator.images, forURLScheme: MarkdownLocalImages.scheme)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.pageZoom = zoom
        wv.navigationDelegate = context.coordinator
        context.coordinator.render(source: source, allowRemoteImages: allowRemoteImages,
                                   refreshID: refreshID, in: wv)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        if wv.pageZoom != zoom { wv.pageZoom = zoom }
        context.coordinator.onNavigate = onNavigate
        context.coordinator.onRender = onRender
        context.coordinator.render(source: source, allowRemoteImages: allowRemoteImages,
                                   refreshID: refreshID, in: wv)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onNavigate: (URL) -> Void
        var onRender: (Bool) -> Void
        let images = MarkdownImageSchemeHandler()
        private var loadedKey: String?
        /// Bumped by every render; a background rendering that finishes after a
        /// newer one started is dropped.
        private var generation = 0
        /// Renders off the main thread, one at a time: a hostile or huge
        /// document must never freeze the app (Edit mode re-renders as you type).
        private static let renderQueue = DispatchQueue(label: "studio.irq.selway.MarkdownRender", qos: .userInitiated)

        init(onNavigate: @escaping (URL) -> Void, onRender: @escaping (Bool) -> Void) {
            self.onNavigate = onNavigate
            self.onRender = onRender
        }

        func render(source: MarkdownWebSource, allowRemoteImages: Bool, refreshID: UUID, in wv: WKWebView) {
            // Hash content so live preview updates when text changes
            let key = "\(source.baseURL.path):\(source.title):\(source.markdown.hashValue):\(allowRemoteImages):\(refreshID)"
            guard key != loadedKey else { return }
            loadedKey = key
            generation += 1
            let token = generation
            let markdown = source.markdown, title = source.title, baseURL = source.baseURL
            Self.renderQueue.async { [weak self, weak wv] in
                let rendered = MarkdownToHTML.renderDocument(markdown, title: title,
                                                             allowRemoteImages: allowRemoteImages,
                                                             imageFolder: baseURL)
                // Also never during the SwiftUI update pass that asked for it.
                DispatchQueue.main.async {
                    guard let self, let wv, token == self.generation else { return }
                    self.images.loader = MarkdownImageLoader(allowedPaths: rendered.localImages)
                    wv.loadHTMLString(rendered.html, baseURL: baseURL)
                    self.onRender(rendered.hasRemoteImages)
                }
            }
        }

        func webView(_ wv: WKWebView, decidePolicyFor nav: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let target = nav.request.url else { decisionHandler(.cancel); return }
            switch nav.navigationType {
            case .linkActivated:
                // In-page anchors (#heading) scroll within the rendered document.
                if target.fragment != nil, let current = wv.url, Self.sameDocument(target, current) {
                    decisionHandler(.allow)
                    return
                }
                decisionHandler(.cancel)
                if target.isFileURL && ["md", "markdown", "mdown"].contains(target.pathExtension.lowercased()) {
                    onNavigate(target)
                } else if let scheme = target.scheme?.lowercased(),
                          ["http", "https", "mailto"].contains(scheme) {
                    NSWorkspace.shared.open(target)
                }
                // Block javascript:, data:, file opens of non-md, etc.
            case .other, .reload:
                // Our own loadHTMLString (and reloads of it) in the main frame.
                decisionHandler(nav.targetFrame?.isMainFrame == true ? .allow : .cancel)
            default:
                decisionHandler(.cancel)
            }
        }

        private static func sameDocument(_ a: URL, _ b: URL) -> Bool {
            func strip(_ u: URL) -> String? {
                var c = URLComponents(url: u, resolvingAgainstBaseURL: true)
                c?.fragment = nil
                return c?.string
            }
            return strip(a) == strip(b)
        }
    }
}

// MARK: - Local images

/// Serves `selwayimg://local/<path>` image requests from a rendered Markdown page
/// through the current rendering's `MarkdownImageLoader`: only files that
/// rendering referenced, only images, each read once, within the per-document
/// byte budget, one read at a time on the loader's serial queue.
final class MarkdownImageSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Replaced by each render (a new allow-list, cache and budget). The old one's
    /// queued reads are skipped: its page is gone.
    var loader = MarkdownImageLoader(allowedPaths: []) {
        didSet { oldValue.cancel() }
    }
    /// Tasks WebKit hasn't stopped; answering a stopped task raises an exception.
    private var running: Set<ObjectIdentifier> = []
    /// Per running task, read on the loader's queue: a stopped task's read is skipped.
    private final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        var isWanted: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    }
    private var tickets: [ObjectIdentifier: Ticket] = [:]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = MarkdownLocalImages.file(forPageURL: url) else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let id = ObjectIdentifier(task)
        running.insert(id)
        let ticket = Ticket()
        tickets[id] = ticket
        loader.load(file, isWanted: { ticket.isWanted }) { result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.tickets[id] = nil
                    guard self.running.remove(id) != nil else { return }
                    switch result {
                    case .success(let image):
                        task.didReceive(URLResponse(url: url, mimeType: image.mimeType,
                                                    expectedContentLength: image.data.count,
                                                    textEncodingName: nil))
                        task.didReceive(image.data)
                        task.didFinish()
                    case .failure:
                        task.didFailWithError(URLError(.fileDoesNotExist))
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        running.remove(id)
        tickets.removeValue(forKey: id)?.stop()
    }
}

// MARK: - In-app Markdown editor (NSTextView-based, Obsidian-styled)

struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text:       String
    @Binding var isModified: Bool
    var controller: MarkdownEditorController
    var fontSize: CGFloat = 14

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isModified: $isModified, controller: controller)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let tv = scrollView.documentView as? NSTextView else { return scrollView }

        tv.delegate                             = context.coordinator
        tv.isEditable                           = true
        tv.isRichText                           = false
        tv.allowsUndo                           = true
        tv.isAutomaticQuoteSubstitutionEnabled  = false
        tv.isAutomaticDashSubstitutionEnabled   = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled    = false
        tv.isAutomaticLinkDetectionEnabled      = false
        tv.isContinuousSpellCheckingEnabled     = false
        tv.font                                 = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.textContainerInset                   = NSSize(width: 36, height: 28)
        tv.isVerticallyResizable                = true
        tv.isHorizontallyResizable              = false
        tv.textContainer?.widthTracksTextView   = true
        tv.insertionPointColor                  = .controlAccentColor

        // Obsidian-inspired background — adapts to macOS dark / light mode
        tv.backgroundColor = Self.editorBackground()

        // Line spacing & paragraph style
        let para = NSMutableParagraphStyle()
        para.lineSpacing        = 5
        para.paragraphSpacing   = 4
        tv.defaultParagraphStyle = para
        tv.typingAttributes = [
            .font:            NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle:  para,
        ]

        tv.string = text
        context.coordinator.textView = tv
        controller.attach(tv, undoManager: context.coordinator.undoManager)
        // Switching to Edit means typing next: take the keyboard once the view is
        // in the window (it isn't yet while it is being made).
        DispatchQueue.main.async { [weak tv] in
            guard let tv, let window = tv.window else { return }
            window.makeFirstResponder(tv)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        context.coordinator.controller = controller
        if controller.textView !== tv { controller.attach(tv, undoManager: context.coordinator.undoManager) }
        if tv.font?.pointSize != fontSize {
            // Plain text: one font for the whole document, and for what's typed next.
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            tv.font = font
            tv.typingAttributes[.font] = font
        }
        // Only update the backing store when the text changed externally
        // (e.g. file reload after navigation) — avoids cursor/scroll reset while typing.
        guard tv.string != text else { return }
        let sel = tv.selectedRange()
        tv.string = text
        // Undo steps recorded against the old text would corrupt the new one.
        context.coordinator.undoManager.removeAllActions()
        controller.refreshUndoState()
        let safeLoc = min(sel.location, (text as NSString).length)
        tv.setSelectedRange(NSRange(location: safeLoc, length: 0))
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if coordinator.controller.textView === scrollView.documentView {
            coordinator.controller.detach()
        }
    }

    /// Dynamic background: Obsidian #1e1e2e in dark mode, near-white in light mode.
    private static func editorBackground() -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.180, alpha: 1)  // #1e1e2e
                : NSColor(srgbRed: 0.980, green: 0.980, blue: 0.984, alpha: 1)  // #fafafa
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text:       String
        @Binding var isModified: Bool
        var controller: MarkdownEditorController
        weak var textView: NSTextView?
        /// This editor's own undo stack. The window's undo manager would outlive the
        /// text view (rebuilt on every switch to Edit mode) and keep stale actions.
        let undoManager = UndoManager()

        private var keyObserver: NSObjectProtocol?

        init(text: Binding<String>, isModified: Binding<Bool>, controller: MarkdownEditorController) {
            self._text       = text
            self._isModified = isModified
            self.controller  = controller
            super.init()
            // Coming back to the window in Edit mode: type into the text again,
            // unless something else in the window (the preview) has the keyboard.
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let tv = self?.textView, let window = tv.window, note.object as? NSWindow === window,
                          window.firstResponder == nil || window.firstResponder === window else { return }
                    window.makeFirstResponder(tv)
                }
            }
        }

        deinit {
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text       = tv.string
            isModified = true
            controller.refreshUndoState()
        }
    }
}

// The Markdown → HTML renderer lives in Core/MarkdownToHTML.swift.
