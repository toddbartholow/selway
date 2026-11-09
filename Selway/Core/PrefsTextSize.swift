import Foundation

/// How big a window draws text, icons and rows (View → Make Text Bigger / Smaller,
/// Settings → General). A fixed set of steps, stored as a whole percentage: the
/// browser windows under `UserPreferences.textSizeKey`, the Markdown window under
/// `markdownTextSizeKey`. The code editor has a point size instead (EditorFontSize).
struct TextSize: Hashable, Comparable, Sendable {
    /// Up to 200%, so text can be doubled (WCAG 1.4.4).
    static let steps = [100, 115, 130, 150, 175, 200]
    static let actual = TextSize(percent: 100)
    static let all = steps.map(TextSize.init(percent:))

    let percent: Int

    /// The step nearest `percent` (the smaller one on a tie). Values past either end
    /// clamp to it, so a hand-edited or out-of-date stored value still gives a valid size.
    init(percent: Int) {
        // Clamped first so the distance can't overflow for a wild stored value.
        let p = min(max(percent, Self.steps[0]), Self.steps[Self.steps.count - 1])
        self.percent = Self.steps.min { abs($0 - p) < abs($1 - p) } ?? p
    }

    /// Multiplier for point sizes: 1 at 100%.
    var scale: Double { Double(percent) / 100 }
    var isActual: Bool { self == .actual }
    var label: String { "\(percent)%" }

    var bigger: TextSize? {
        Self.steps.first { $0 > percent }.map(TextSize.init(percent:))
    }

    var smaller: TextSize? {
        Self.steps.last { $0 < percent }.map(TextSize.init(percent:))
    }

    var canGoBigger: Bool { bigger != nil }
    var canGoSmaller: Bool { smaller != nil }

    static func < (a: TextSize, b: TextSize) -> Bool { a.percent < b.percent }

    static func fromStorage(_ raw: Int) -> TextSize { TextSize(percent: raw) }
}

/// The code editor's font size in points: its own setting, stepped one point at a
/// time, which the browser text size doesn't scale.
enum EditorFontSize {
    static let key         = "selwayEditorFontSize"
    static let defaultSize = 14
    static let range       = 8...36

    static func clamped(_ size: Int) -> Int {
        min(max(size, range.lowerBound), range.upperBound)
    }
}

enum TextSizeChange: Sendable {
    case bigger, smaller, actual
}

/// Which setting View → Make Text Bigger / Smaller / Actual Text Size change: the
/// key window's. `none` while nothing that has one is in front (an app-modal alert).
enum TextSizeTarget: Sendable {
    case browser, codeEditor, markdown, none

    var key: String? {
        switch self {
        case .browser:    return UserPreferences.textSizeKey
        case .codeEditor: return EditorFontSize.key
        case .markdown:   return UserPreferences.markdownTextSizeKey
        case .none:       return nil
        }
    }
}

enum TextSizeRouting {
    /// The value to store under `target.key` after `change`, given what is stored
    /// there now (nil when missing or not a whole number, which counts as the
    /// default); nil when the change does nothing (already at that end, or already
    /// actual size), so the menu item is disabled.
    static func newValue(_ change: TextSizeChange, for target: TextSizeTarget, stored: Int?) -> Int? {
        switch target {
        case .browser, .markdown:
            let size = TextSize.fromStorage(stored ?? TextSize.actual.percent)
            let next: TextSize?
            switch change {
            case .bigger:  next = size.bigger
            case .smaller: next = size.smaller
            case .actual:  next = size.isActual ? nil : .actual
            }
            return next?.percent
        case .codeEditor:
            let current = EditorFontSize.clamped(stored ?? EditorFontSize.defaultSize)
            let next: Int
            switch change {
            case .bigger:  next = EditorFontSize.clamped(current + 1)
            case .smaller: next = EditorFontSize.clamped(current - 1)
            case .actual:  next = EditorFontSize.defaultSize
            }
            return next == current ? nil : next
        case .none:
            return nil
        }
    }

    /// What VoiceOver says after a change.
    static func announcement(for target: TextSizeTarget, value: Int) -> String {
        switch target {
        case .codeEditor:
            return String.localizedStringWithFormat(NSLocalizedString("Editor font size %lld points", comment: "VoiceOver announcement after changing the code editor font size"), value)
        case .markdown:
            return String.localizedStringWithFormat(NSLocalizedString("Markdown text size %lld%%", comment: "VoiceOver announcement after changing Markdown text size"), value)
        case .browser, .none:
            return String.localizedStringWithFormat(NSLocalizedString("Text size %lld%%", comment: "VoiceOver announcement after changing browser text size"), value)
        }
    }
}
