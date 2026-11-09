import SwiftUI
import AppKit

// MARK: - Browser text size
//
// macOS doesn't scale SwiftUI's text styles for an app, so the Text Size setting
// (TextSize, Core) is applied by hand: each browser window's root puts the scale
// in the environment, and views size their fonts, icons and fixed frames from it.
// Fonts go through `scaledFont`, which leaves 100% exactly as it was. Nothing
// uses `.scaleEffect`, which blurs and doesn't change layout.

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// The window's text size as a multiplier (1 at 100%).
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

extension Font.TextStyle {
    /// The style's size on this Mac (NSFont.preferredFont) and its weight, so a
    /// scaled style starts from what it draws at 100%.
    fileprivate var macMetrics: (size: CGFloat, weight: Font.Weight) {
        let style: NSFont.TextStyle
        var weight = Font.Weight.regular
        switch self {
        case .largeTitle:  style = .largeTitle
        case .title:       style = .title1
        case .title2:      style = .title2
        case .title3:      style = .title3
        case .headline:    style = .headline; weight = .bold
        case .subheadline: style = .subheadline
        case .callout:     style = .callout
        case .footnote:    style = .footnote
        case .caption:     style = .caption1
        case .caption2:    style = .caption2; weight = .medium
        default:           style = .body
        }
        return (NSFont.preferredFont(forTextStyle: style).pointSize, weight)
    }
}

/// One modifier whatever the scale, so changing it never gives the view a new
/// identity (which would drop a text field's focus and edits).
private struct ScaledFont: ViewModifier {
    @Environment(\.textScale) private var scale
    /// What the view used before text sizes existed, kept at 100%; nil leaves
    /// the font the view gets from its container (a sidebar row's, say).
    let original: Font?
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.transformEnvironment(\.font) { font in
            if scale != 1 {
                font = .system(size: (size * scale).rounded(), weight: weight, design: design)
            } else if let original {
                font = original
            }
        }
    }
}

extension View {
    /// `.font(.system(size:weight:design:))` at the window's text size.
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular,
                    design: Font.Design = .default) -> some View {
        modifier(ScaledFont(original: .system(size: size, weight: weight, design: design),
                            size: size, weight: weight, design: design))
    }

    /// A text style (`.caption`, `.headline`…) at the window's text size.
    func scaledFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
        let metrics = style.macMetrics
        let original = weight.map { Font.system(style).weight($0) } ?? .system(style)
        return modifier(ScaledFont(original: original, size: metrics.size,
                                   weight: weight ?? metrics.weight, design: .default))
    }

    /// Text that has no font of its own (the container's): unchanged at 100%,
    /// otherwise `size` scaled. For lists like the sidebar that set their rows'
    /// font themselves and ignore the window's default.
    func scaledDefaultFont(size: CGFloat = 13, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledFont(original: nil, size: size, weight: weight, design: .default))
    }

    /// Applies a text size setting to a window: the scale for `scaledFont` and
    /// scaled icon sizes, and the default (body) font. `key` is
    /// `UserPreferences.textSizeKey` for browser windows.
    func textSizeRoot(key: String = UserPreferences.textSizeKey) -> some View {
        modifier(TextSizeRoot(key: key))
    }
}

private struct TextSizeRoot: ViewModifier {
    @AppStorage private var stored: Int

    init(key: String) {
        _stored = AppStorage(wrappedValue: TextSize.actual.percent, key)
    }

    // One branch: the window's content keeps its identity, and with it the folder
    // shown, the selection, undo history and running file operations.
    func body(content: Content) -> some View {
        let size = TextSize.fromStorage(stored)
        let scale = CGFloat(size.scale)
        content
            .environment(\.textScale, scale)
            .font(size.isActual ? nil : .system(size: (13 * scale).rounded()))
    }
}

// MARK: - View → Make Text Bigger / Smaller / Actual Text Size

/// The View menu's text size items. They change the key window's setting: the
/// browser text size in browser windows (and Settings), the Markdown window's own
/// size there, and the code editor's font size in the editor, which the other two
/// don't scale. The decision is `TextSizeRouting` (Core, tested).
struct TextSizeCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            TextSizeMenuItems()
        }
    }

    /// ⌘= as well as the ⌘+ the menu shows, as in Safari: on layouts where + is
    /// a shifted key, it saves reaching for Shift. Menus can't hold a hidden
    /// second shortcut, so this watches the keyboard for it instead. It leaves
    /// app-modal alerts and panels alone (the router has no target then).
    @MainActor
    static func installEqualsShortcut() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard modifiers == .command, event.charactersIgnoringModifiers == "=" else { return event }
            return TextSizeRouter.apply(.bigger) ? nil : event
        }
    }
}

private struct TextSizeMenuItems: View {
    // Read in `body`, so the items' enabled state follows each setting and the key window.
    @AppStorage(UserPreferences.textSizeKey) private var browserSize = TextSize.actual.percent
    @AppStorage(UserPreferences.markdownTextSizeKey) private var markdownSize = TextSize.actual.percent
    @AppStorage(EditorFontSize.key) private var editorFontSize = EditorFontSize.defaultSize
    @ObservedObject private var keyWindow = KeyWindowKind.shared

    var body: some View {
        Divider()
        Button("Make Text Bigger") { TextSizeRouter.applyOrBeep(.bigger) }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(!canApply(.bigger))
        Button("Make Text Smaller") { TextSizeRouter.applyOrBeep(.smaller) }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!canApply(.smaller))
        Button("Actual Text Size") { TextSizeRouter.applyOrBeep(.actual) }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(!canApply(.actual))
        Divider()
    }

    private func canApply(_ change: TextSizeChange) -> Bool {
        let target = keyWindow.target
        let stored: Int
        switch target {
        case .browser:    stored = browserSize
        case .markdown:   stored = markdownSize
        case .codeEditor: stored = editorFontSize
        case .none:       return false
        }
        return TextSizeRouting.newValue(change, for: target, stored: stored) != nil
    }
}

@MainActor
enum TextSizeRouter {
    /// The key window's setting; none while an app-modal alert or panel runs.
    static var target: TextSizeTarget {
        NSApp.modalWindow != nil ? .none : KeyWindowKind.shared.target
    }

    /// Stores the change for the key window and announces it. False if there was
    /// nothing to change.
    @discardableResult
    static func apply(_ change: TextSizeChange) -> Bool {
        let target = self.target
        guard let key = target.key else { return false }
        let defaults = UserDefaults.standard
        // As @AppStorage reads it: anything but a whole number counts as missing.
        guard let value = TextSizeRouting.newValue(change, for: target,
                                                   stored: defaults.object(forKey: key) as? Int)
        else { return false }
        defaults.set(value, forKey: key)
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: TextSizeRouting.announcement(for: target, value: value),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        return true
    }

    static func applyOrBeep(_ change: TextSizeChange) {
        if !apply(change) { NSSound.beep() }
    }
}

/// Which kind of window is key, published so the menu items re-evaluate when it
/// changes (the browser's focused values don't change between non-browser windows).
@MainActor
final class KeyWindowKind: ObservableObject {
    static let shared = KeyWindowKind()
    @Published private(set) var target: TextSizeTarget
    private var observers: [NSObjectProtocol] = []

    private init() {
        target = Self.target(of: NSApp.keyWindow)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                               queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { self?.update(Self.target(of: window)) }
            },
            // A closed editor window mustn't leave the items acting on it.
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update(.browser) }
            },
        ]
    }

    private func update(_ new: TextSizeTarget) {
        if target != new { target = new }
    }

    /// A sheet, alert or panel attached to a window counts as that window. The About and
    /// Acknowledgments windows have no text size, and change no other window's.
    private static func target(of window: NSWindow?) -> TextSizeTarget {
        let owner = window?.sheetParent ?? window
        if EditorWindowManager.shared.isEditorWindow(owner) { return .codeEditor }
        if MarkdownWindowManager.shared.isReaderWindow(owner) { return .markdown }
        if AboutWindowController.isAboutOrAcknowledgments(owner) { return .none }
        return .browser
    }
}
