import Cocoa
import FinderSync

class FinderSyncExtension: FIFinderSync {

    /// Which menu `menu(for:)` last built: what Copy Path copies depends on it.
    private var menuKind: FIMenuKind?

    override init() {
        super.init()
        let fm = FileManager.default
        FIFinderSyncController.default().directoryURLs = Set([
            fm.homeDirectoryForCurrentUser,
            fm.urls(for: .desktopDirectory, in: .userDomainMask).first,
            fm.urls(for: .documentDirectory, in: .userDomainMask).first,
            fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
        ].compactMap { $0 })
    }

    // MARK: - Toolbar

    override var toolbarItemName: String {
        String(localized: "Selway", comment: "Finder Sync toolbar item name.")
    }

    override var toolbarItemToolTip: String {
        String(localized: "Selway: Enhanced file management", comment: "Finder Sync toolbar item tooltip.")
    }

    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "folder.badge.plus",
                accessibilityDescription: String(localized: "Selway", comment: "Finder Sync toolbar item name."))
            ?? NSImage(named: NSImage.folderName)!
    }

    // MARK: - Context Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        self.menuKind = menuKind
        let menu = NSMenu(title: "")
        menu.addItem(withTitle: String(localized: "New Folder Here",
                                       comment: "Finder Sync context menu action to create a folder here."),
                      action: #selector(createFolderHere), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Copy Path",
                                       comment: "Finder Sync context menu action to copy the selected path."),
                      action: #selector(copyPath), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Open in Terminal",
                                       comment: "Finder Sync context menu action to open the current folder in Terminal."),
                      action: #selector(openInTerminal), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Open in Selway",
                                       comment: "Finder Sync context menu action to open the current folder in Selway."),
                      action: #selector(openInSelway), keyEquivalent: "")
        return menu
    }

    // The extension is sandboxed with no file-access exceptions, so creating a
    // folder or scripting Terminal from here failed silently. Those actions are
    // forwarded to Selway as selway:// links (built by FileOpsURLScheme,
    // which the app parses strictly), and the app performs them.

    @objc private func createFolderHere() {
        forward(.newFolder, activatingApp: false)
    }

    // The right-clicked items' paths, one per line, as Selway's own Copy Path and
    // Finder's ⌥⌘C copy them; the folder's only when no item was right-clicked
    // (the toolbar button with nothing selected). It copied the folder even with
    // items right-clicked. From a sidebar item or a window's background it is
    // the folder clicked (targetedURL), whatever is selected in the window:
    // the selection there is the window's, not what was right-clicked.
    @objc private func copyPath() {
        let controller = FIFinderSyncController.default()
        let clickedFolder = menuKind == .contextualMenuForSidebar || menuKind == .contextualMenuForContainer
        let selected = clickedFolder ? [] : controller.selectedItemURLs() ?? []
        guard let text = ShellCopyPath.text(selected: selected, folder: controller.targetedURL()) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openInTerminal() {
        forward(.terminal, activatingApp: false)
    }

    @objc private func openInSelway() {
        forward(.open, activatingApp: true)
    }

    private func forward(_ action: FileOpsURLAction, activatingApp: Bool) {
        guard let target = FIFinderSyncController.default().targetedURL(),
              let url = FileOpsURLScheme.url(for: action, path: target.path) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activatingApp
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            if let error {
                NSLog("Selway extension: couldn't forward %@: %@", action.rawValue, error.localizedDescription)
            }
        }
    }
}
