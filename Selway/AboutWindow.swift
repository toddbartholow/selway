import SwiftUI
import AppKit

// MARK: - Menu

/// Selway ▸ About Selway opens Selway's own About window in place of the standard panel.
struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(String(localized: "About Selway", comment: "App menu item and window title of Selway's About window")) {
                AboutWindowController.shared.showAbout()
            }
        }
    }
}

// MARK: - Windows

/// The About window and its Acknowledgments window: one of each, brought forward when
/// asked for again, neither restored at the next launch.
@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()

    /// The windows' identifiers. TextSizeCommands and the Dock icon (DockReopen) leave
    /// these windows alone.
    static let aboutIdentifier = NSUserInterfaceItemIdentifier("aboutWindow")
    static let acknowledgmentsIdentifier = NSUserInterfaceItemIdentifier("acknowledgmentsWindow")

    /// Whether `window` is the About or the Acknowledgments window.
    static func isAboutOrAcknowledgments(_ window: NSWindow?) -> Bool {
        guard let identifier = window?.identifier else { return false }
        return identifier == aboutIdentifier || identifier == acknowledgmentsIdentifier
    }

    private var about: NSWindow?
    private var acknowledgments: NSWindow?

    func showAbout() {
        if let about {
            // Closed, or left in another Space, on a display that has since gone: back in
            // the middle of one that's here.
            if !about.isVisible || !about.isOnActiveSpace, !Self.isOnScreen(about.frame) { about.center() }
            bringForward(about)
            return
        }
        let view = AboutView(open: AboutLinks.open, showAcknowledgments: { [weak self] in self?.showAcknowledgments() })
        let hosting = NSHostingController(rootView: view)
        // The window takes the view's size and keeps it: like the standard About panel, it
        // can't be resized, minimized or zoomed.
        hosting.sizingOptions = [.preferredContentSize]
        let window = DismissibleWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "About Selway", comment: "App menu item and window title of Selway's About window")
        window.identifier = Self.aboutIdentifier
        configure(window)
        window.center()
        about = window
        bringForward(window)
    }

    func showAcknowledgments() {
        if let acknowledgments {
            // Closed, or left in another Space, since it was last shown: it opens beside
            // About again, wherever About is now. Minimized, it comes back where the user
            // left it.
            if !acknowledgments.isMiniaturized, !acknowledgments.isVisible || !acknowledgments.isOnActiveSpace {
                place(acknowledgments)
            }
            bringForward(acknowledgments)
            return
        }
        let hosting = NSHostingController(rootView: AcknowledgmentsView(open: AboutLinks.open))
        // The window keeps the size it has: a long license selected scrolls in its pane
        // rather than growing the window, and nothing but contentMinSize limits it.
        hosting.sizingOptions = []
        let window = DismissibleWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = String(localized: "Acknowledgments", comment: "Title of the window listing the third-party software in Selway and its licenses, and the About window button that opens it")
        window.identifier = Self.acknowledgmentsIdentifier
        window.setContentSize(NSSize(width: 760, height: 520))
        window.contentMinSize = NSSize(width: 560, height: 360)
        configure(window)
        window.center()
        place(window)
        acknowledgments = window
        bringForward(window)
    }

    /// Puts the Acknowledgments window beside the About window rather than over it, and
    /// on the screen. With About closed, it stays where it is unless that's off every
    /// screen.
    private func place(_ window: NSWindow) {
        if let about, about.isVisible, let visible = (about.screen ?? NSScreen.main)?.visibleFrame {
            window.setFrame(AboutWindowPlacement.acknowledgmentsFrame(size: window.frame.size, beside: about.frame,
                                                                      in: visible),
                            display: false)
        } else if !Self.isOnScreen(window.frame) {
            window.center()
        }
    }

    /// Whether a window at `frame` can be seen on one of the displays connected now.
    private static func isOnScreen(_ frame: NSRect) -> Bool {
        AboutWindowPlacement.isOnScreen(frame, screens: NSScreen.screens.map(\.visibleFrame))
    }

    private func configure(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        // Never part of a browser window's tab group, and not brought back at launch.
        window.tabbingMode = .disallowed
        window.isRestorable = false
        // Shown over a full-screen browser window, in its Space, instead of taking the
        // user to the desktop. An auxiliary window doesn't go full screen in a Space of its
        // own, so neither does the resizable Acknowledgments window.
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        // Asked for again from another Space, it comes to that one rather than taking the
        // user back to where it was: About brought to a full-screen Space, then its
        // Acknowledgments button, stays there.
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    private func bringForward(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// A window that Escape closes, as ⌘W does.
private final class DismissibleWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit offers a key equivalent nobody took to every window, not just the key one:
        // an Escape typed in a browser window mustn't close this one.
        guard isKeyWindow else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if event.type == .keyDown, modifiers.isEmpty, event.keyCode == 53 {   // Escape
            performClose(nil)
            return true
        }
        if event.type == .keyDown, modifiers == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

// MARK: - Links

/// Opens the About window's links in the browser. Under the UI tests nothing is opened: the
/// address is recorded for the test to read (`lastOpened`, shown as `aboutOpenedURL`).
@MainActor
enum AboutLinks {
    static func open(_ url: URL) {
        #if SELWAY_UI_TESTING
        if UITestHooks.isActive {
            AboutLinkRecord.shared.lastOpened = url.absoluteString
            return
        }
        #endif
        NSWorkspace.shared.open(url)
    }
}

#if SELWAY_UI_TESTING
/// The last link the About or Acknowledgments window would have opened, under the UI tests.
@MainActor
final class AboutLinkRecord: ObservableObject {
    static let shared = AboutLinkRecord()
    @Published var lastOpened = ""
}

/// The recorded link as text the UI tests can read; drawn in clear, so nothing shows.
private struct AboutLinkRecordView: View {
    @ObservedObject private var record = AboutLinkRecord.shared

    var body: some View {
        if UITestHooks.isActive {
            Text(verbatim: record.lastOpened.isEmpty ? "none" : record.lastOpened)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .allowsHitTesting(false)
                .accessibilityIdentifier("aboutOpenedURL")
        }
    }
}
#endif

private extension View {
    /// Under the UI tests, the link the window last "opened" (AboutLinks).
    @ViewBuilder func recordsOpenedLinks() -> some View {
        #if SELWAY_UI_TESTING
        overlay(alignment: .bottomTrailing) { AboutLinkRecordView() }
        #else
        self
        #endif
    }
}

// MARK: - About

/// The About window: icon, name, version, author, links and copyright, centered.
private struct AboutView: View {
    let open: @MainActor (URL) -> Void
    let showAcknowledgments: @MainActor () -> Void

    private var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Selway"
    }

    /// The localized NSHumanReadableCopyright (InfoPlist.xcstrings).
    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? AboutText.copyright
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)

            Text(verbatim: name)
                .font(.title2.weight(.semibold))
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("aboutName")

            Text(verbatim: AboutText.version(info: Bundle.main.infoDictionary))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
                .accessibilityIdentifier("aboutVersion")

            Text(verbatim: AboutText.byline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .accessibilityIdentifier("aboutAuthor")

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    link(Text("Website", comment: "About window button that opens Selway's website"),
                         id: "website", url: SelwayLinks.website)
                    link(Text("GitHub", comment: "Link button in the first-run window and the About window that opens Selway's GitHub page. A brand name, do not translate."),
                         id: "github", url: SelwayLinks.repository)
                    link(Text("Changelog", comment: "About window button that opens the list of changes in each Selway version"),
                         id: "changelog", url: SelwayLinks.changelog)
                }
                HStack(spacing: 8) {
                    link(Text("Report a bug", comment: "About window button that opens a new GitHub issue for Selway"),
                         id: "reportBug", url: SelwayLinks.newIssue)
                    Button {
                        showAcknowledgments()
                    } label: {
                        Text("Acknowledgments", comment: "Title of the window listing the third-party software in Selway and its licenses, and the About window button that opens it")
                    }
                    .help(Text("Lists the software Selway includes and its licenses", comment: "Help tag and accessibility hint for the Acknowledgments button in the About window"))
                    .accessibilityHint(Text("Lists the software Selway includes and its licenses", comment: "Help tag and accessibility hint for the Acknowledgments button in the About window"))
                    .accessibilityIdentifier("aboutAcknowledgments")
                }
            }
            .padding(.top, 18)

            Text(verbatim: copyright)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .accessibilityIdentifier("aboutCopyright")
        }
        .fixedSize()
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .frame(minWidth: 320)
        .recordsOpenedLinks()
    }

    /// A button that opens `url` in the browser; its address is the help tag.
    private func link(_ title: Text, id: String, url: URL) -> some View {
        Button {
            open(url)
        } label: {
            title
        }
        .help(url.absoluteString)
        .accessibilityHint(Text("Opens in your browser", comment: "Accessibility hint for the About window buttons that open a web page"))
        .accessibilityIdentifier("aboutLink-\(id)")
    }
}

// MARK: - Acknowledgments

/// The third-party software in Selway: a list of components beside the one selected, with
/// its copyright and whole license.
private struct AcknowledgmentsView: View {
    let open: @MainActor (URL) -> Void
    @State private var selection: ThirdPartyNotice.ID? = ThirdPartyNotice.all.first?.id
    /// The list has the focus when the window opens, so the arrow keys move through it
    /// without a click first.
    @FocusState private var listFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            List(ThirdPartyNotice.all, selection: $selection) { notice in
                Text(verbatim: notice.name)
                    .accessibilityIdentifier("acknowledgment-\(notice.id)")
            }
            .listStyle(.sidebar)
            .frame(width: 200)
            .focused($listFocused)
            .defaultFocus($listFocused, true)
            .onAppear { listFocused = true }
            .accessibilityIdentifier("acknowledgmentsList")

            Divider()

            if let notice = ThirdPartyNotice.all.first(where: { $0.id == selection }) {
                NoticeDetail(notice: notice, open: open)
                    .id(notice.id)
            } else {
                Text("Selway includes software from these projects, used under the licenses shown.",
                     comment: "Acknowledgments window, shown when no component is selected in its list")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .recordsOpenedLinks()
    }
}

private struct NoticeDetail: View {
    let notice: ThirdPartyNotice
    let open: @MainActor (URL) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: [notice.name, notice.version].compactMap { $0 }.joined(separator: " "))
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("acknowledgmentName")
                Text(verbatim: notice.role.title)
                    .foregroundStyle(.secondary)
                Button(notice.homepage.absoluteString) { open(notice.homepage) }
                    .buttonStyle(.link)
                    // VoiceOver reads "Website, github.com", not the address letter by letter.
                    .accessibilityLabel(Text("Website, \(notice.homepage.host ?? notice.homepage.absoluteString)",
                                             comment: "Acknowledgments window: VoiceOver label of the link to a component's website; the placeholder is the site's address, as in github.com"))
                    .accessibilityHint(Text("Opens in your browser", comment: "Accessibility hint for the About window buttons that open a web page"))
                    .accessibilityIdentifier("acknowledgmentHomepage")
                Text(verbatim: notice.license.title)
                    .font(.callout.weight(.medium))
                    .padding(.top, 6)
                Text(verbatim: notice.copyright)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Divider()
                    .padding(.vertical, 6)
                Text(verbatim: notice.text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("acknowledgmentText")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
