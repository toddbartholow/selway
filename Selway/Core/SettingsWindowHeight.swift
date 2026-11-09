import Foundation

/// The most a Settings tab may be tall. Each tab takes its form's own height
/// up to this, and its form scrolls beyond it.
enum SettingsWindowHeight {
    /// `cap` (a tab's own limit, if it has one), or less on a screen too short
    /// for it (a small or scaled display, leaving `chrome` for the title and
    /// tab bars), but never under `minimum`. Nil when there's neither a cap
    /// nor a screen to go by: the tab takes its form's height.
    static func limit(upTo cap: CGFloat? = nil, minimum: CGFloat = 400,
                      visibleScreenHeight: CGFloat?, chrome: CGFloat = 100) -> CGFloat? {
        let screen = visibleScreenHeight.map { max(minimum, $0 - chrome) }
        switch (cap, screen) {
        case let (cap?, screen?): return min(cap, screen)
        case let (cap?, nil):     return cap
        case let (nil, screen?):  return screen
        case (nil, nil):          return nil
        }
    }
}
