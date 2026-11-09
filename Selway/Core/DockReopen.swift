import Foundation

/// What a click on the Dock icon does while the About or Acknowledgments window is open:
/// what it would do without them. Those two don't count as the app's windows, so with
/// nothing else showing the click restores a minimized window or opens a browser window,
/// rather than just bringing About forward (AppKit counts it as a visible window) or
/// restoring a minimized Acknowledgments.
enum DockReopen {
    /// One of the app's windows, panels left out.
    struct Window: Equatable {
        enum Kind: Equatable {
            case browser
            /// The About or the Acknowledgments window.
            case aboutOrAcknowledgments
            /// Any other: the code editor, a Markdown window, Settings.
            case other
        }

        let kind: Kind
        let isVisible: Bool
        let isMinimized: Bool
    }

    enum Action: Equatable {
        /// What AppKit and SwiftUI do by themselves: nothing when a window shows, else
        /// restore a minimized window or open a browser window.
        case standard
        /// Deminiaturize `windows[index]` and bring it forward.
        case restore(index: Int)
        /// Open a browser window at the New windows folder.
        case openBrowserWindow
        /// Open one by choosing File ▸ New Window: no browser view has appeared yet this
        /// session to hand over SwiftUI's openWindow action.
        case chooseNewWindow
    }

    /// The action for a Dock click, given the app's `windows`, and whether a browser view
    /// has handed over SwiftUI's openWindow action (`canOpenWindows`).
    static func action(for windows: [Window], canOpenWindows: Bool) -> Action {
        let shown = windows.filter { $0.isVisible || $0.isMinimized }
        // Without About or Acknowledgments showing, the standard handling is right.
        guard shown.contains(where: { $0.kind == .aboutOrAcknowledgments }) else { return .standard }
        // Another window shows: the click only brings the app forward.
        if shown.contains(where: { $0.kind != .aboutOrAcknowledgments && $0.isVisible }) { return .standard }
        // Else a minimized browser window comes back, before any other kind.
        if let index = windows.firstIndex(where: { $0.kind == .browser && $0.isMinimized }) {
            return .restore(index: index)
        }
        if let index = windows.firstIndex(where: { $0.kind == .other && $0.isMinimized }) {
            return .restore(index: index)
        }
        return canOpenWindows ? .openBrowserWindow : .chooseNewWindow
    }
}
