import Foundation

// What the file actions (New Folder, Open, Share) act on, kept free of AppKit
// so it can be tested. Copy Path's text is in ShellCopyPath.swift.

// MARK: - New Folder

/// Where New Folder and New Text File put the new item, as in Finder: the
/// folder being shown, beside the selection, even when the selection is one
/// folder. (Creating it inside the selected folder and then going there took
/// the user somewhere they hadn't asked to go.) Only a request that names its
/// folder, such as the Finder extension's link, creates elsewhere.
enum ShellNewItemTarget {
    static func destination(showing currentFolder: URL, inside folder: URL? = nil) -> URL {
        folder ?? currentFolder
    }

    /// Whether the window selects an item it just created: only when the item is
    /// in the folder shown. Creating never navigates.
    static func selectsCreated(_ item: URL, showing currentFolder: URL) -> Bool {
        ShellPath.isParent(currentFolder, of: item)
    }
}

// MARK: - Share picker anchor

/// Where the Share… picker opens. SwiftUI's context menus don't say where they
/// were opened, and the picker was shown against the window's corner; it now
/// opens at the right-click (or Control-click) that opened the menu, which is on
/// the item. Failing that (a menu opened from the keyboard, a click in another
/// window or outside the content) at the pointer if it's over the content, else
/// in the middle of the content. Points are in the window's coordinates.
enum ShellPopoverAnchor {
    struct Click {
        /// The window's number (NSWindow.windowNumber).
        let window: Int
        let point: CGPoint
        /// Monotonic seconds (ProcessInfo.systemUptime).
        let time: TimeInterval
    }

    /// A click older than this didn't open the menu being used now.
    static let maxAge: TimeInterval = 60

    static func point(lastClick: Click?, window: Int, now: TimeInterval,
                      mouse: CGPoint?, content: CGRect) -> CGPoint {
        // Plain arithmetic: CGRect's helpers come from CoreGraphics, which this
        // target doesn't use (it also builds on Linux).
        func inside(_ p: CGPoint) -> Bool {
            p.x >= content.origin.x && p.x < content.origin.x + content.size.width
                && p.y >= content.origin.y && p.y < content.origin.y + content.size.height
        }
        if let click = lastClick, click.window == window,
           now - click.time >= 0, now - click.time <= maxAge, inside(click.point) {
            return click.point
        }
        if let mouse, inside(mouse) { return mouse }
        return CGPoint(x: content.origin.x + content.size.width / 2,
                       y: content.origin.y + content.size.height / 2)
    }
}

// MARK: - Open

/// Where the folders Open is given go (Settings → General → Double-click a
/// folder to open it in, or ⌘-double-click for new tabs).
enum ShellFolderDestination: Equatable, Sendable {
    /// One folder is shown in this window; several get a window each.
    case here
    /// Each folder in a window of its own.
    case newWindows
    /// Each folder in a new tab of this window.
    case newTabs
}

/// What Open does with the items it's given (a double-click or Return in a
/// list, the context menu's Open), as in Finder: every item, not only the
/// first. One folder is shown in this window (or a new window or tab, as
/// Settings → General says); with several, each opens in a window of its own,
/// or a tab of its own when folders open in tabs, since one window can only
/// show one. Files each open in their app, or Selway's editor or reader.
/// Orders follow the items'.
struct ShellOpenPlan<Item> {
    /// The folder to show in this window.
    let navigate: Item?
    /// Folders to open in new windows.
    let newWindows: [Item]
    /// Folders to open in new tabs of this window.
    let newTabs: [Item]
    /// Files (and packages, which open like files) to open.
    let files: [Item]

    init(_ items: [Item], isFolder: (Item) -> Bool, folders destination: ShellFolderDestination) {
        let folders = items.filter(isFolder)
        switch destination {
        case .here where folders.count == 1:
            navigate = folders[0]
            newWindows = []
            newTabs = []
        case .here, .newWindows:
            navigate = nil
            newWindows = folders
            newTabs = []
        case .newTabs:
            navigate = nil
            newWindows = []
            newTabs = folders
        }
        files = items.filter { !isFolder($0) }
    }

    /// The windows, tabs and apps opening: the folder shown here opens none.
    var openCount: Int { newWindows.count + newTabs.count + files.count }

    /// The most windows, tabs and apps opening `items` can come to while some
    /// of them can't be told apart yet (`isUnknown`: a link the listing didn't
    /// follow is a folder or not only once it's followed), so Open can ask
    /// before following any. Counted as files, each is one window or app
    /// either way, except that one turning out a folder can send the folder
    /// that would be shown here to a window of its own.
    static func mostOpened(_ items: [Item], isFolder: (Item) -> Bool, isUnknown: (Item) -> Bool,
                           folders destination: ShellFolderDestination) -> Int {
        let known = ShellOpenPlan(items, isFolder: { !isUnknown($0) && isFolder($0) }, folders: destination)
        return known.openCount + (known.navigate != nil && items.contains(where: isUnknown) ? 1 : 0)
    }
    var isEmpty: Bool { navigate == nil && openCount == 0 }
    /// Ask before opening this many at once (ShellOpenPlanLimit).
    var needsConfirmation: Bool { openCount > ShellOpenPlanLimit.confirmAbove }
}

/// When Open asks first, as Finder does ("Are you sure you want to open 25
/// items?"). Above 10: more than an everyday multi-open, and few enough that
/// ⌘A and Return in a big folder asks before filling the screen with windows.
enum ShellOpenPlanLimit {
    static let confirmAbove = 10

    static func question(count: Int) -> String {
        String.localizedStringWithFormat(NSLocalizedString("Are you sure you want to open %lld items?", comment: "Confirmation question before opening more than ten items"), count)
    }

    static let detail = NSLocalizedString("Each one opens in a window, tab or app of its own.", comment: "Open many items confirmation detail")
}
