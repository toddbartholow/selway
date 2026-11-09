import Foundation

/// What the app does with a `selway://` request.
enum FileOpsURLDecision: Equatable {
    /// Nothing (missing item, or an action that needs a plain folder).
    case ignore
    /// Show this folder. Never opens a document or launches an app.
    case show(folder: URL)
    /// Run a side-effecting action on a plain folder, asking first when
    /// `confirm` (the request didn't come from Selway's own extension).
    case perform(FileOpsURLAction, folder: URL, confirm: Bool)
}

/// What the app does with a file or folder opened with Selway ("Open
/// With", `open -a`, default folder handler).
enum FileOpsOpenDecision: Equatable {
    /// Browse a plain folder.
    case browse(URL)
    /// Show the folder containing the item. Used for packages (an .app is
    /// never launched from here) and for files Selway doesn't open itself.
    case reveal(item: URL, inFolder: URL)
    /// Open in the Markdown reader.
    case markdown(URL)
    /// Open in the text editor.
    case editText(URL)
}

/// The safety policy for requests that arrive from outside the app. Any web
/// page can fire a `selway://` link, so only showing a location happens
/// without asking; actions with side effects (`hasSideEffects`) run directly
/// only when Selway's own Finder extension sent them.
enum FileOpsURLPolicy {

    /// A path whose look-up would mount something (an automount folder, or a
    /// link into one: `AutomountGuard`) is ignored before anything else here
    /// looks at it.
    static func decide(_ request: FileOpsURLRequest, fromOwnExtension: Bool,
                       fileManager fm: FileManager = .default,
                       fileSystem: AutomountGuard.FileSystem = .live) -> FileOpsURLDecision {
        guard AutomountGuard.isSafe(request.path, fileSystem: fileSystem) else { return .ignore }
        let url = URL(fileURLWithPath: request.path)
        guard (try? fm.attributesOfItem(atPath: url.path)) != nil else { return .ignore }
        guard request.action.hasSideEffects else {
            return .show(folder: nearestBrowsableFolder(from: url))
        }
        guard FileItem.isBrowsableFolder(url) else { return .ignore }
        return .perform(request.action, folder: url, confirm: !fromOwnExtension)
    }

    static func decideOpen(_ url: URL, fileManager fm: FileManager = .default) -> FileOpsOpenDecision? {
        var isDir: ObjCBool = false
        guard !url.path.isEmpty, fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        let url = URL(fileURLWithPath: url.path)
        if isDir.boolValue {
            if FileItem.isBrowsableFolder(url) { return .browse(url) }
            return .reveal(item: url, inFolder: nearestBrowsableFolder(from: url.deletingLastPathComponent()))
        }
        if url.pathExtension.lowercased() == "md" { return .markdown(url) }
        if TextFileDetector.isEditableText(url) { return .editText(url) }
        return .reveal(item: url, inFolder: nearestBrowsableFolder(from: url.deletingLastPathComponent()))
    }

    /// `url` itself if it is a plain folder, else the closest enclosing one
    /// (so an app or document is revealed, never opened).
    static func nearestBrowsableFolder(from url: URL) -> URL {
        var candidate = url
        while !FileItem.isBrowsableFolder(candidate) && candidate.path != "/" {
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }

    // MARK: Folder identity

    /// The folder a link's action was approved for, pinned by what it is on disk rather
    /// than by its path. A confirmation dialog waits on the user, and meanwhile the folder
    /// can be renamed away, replaced, or turned into a symlink to somewhere else; the action
    /// re-checks this just before it runs and is refused if anything changed.
    struct FolderIdentity: Equatable {
        /// The path with every symlink resolved.
        let resolvedPath: String
        let device: UInt64
        let inode: UInt64

        /// Nil when `folder` (after resolving symlinks) isn't an existing directory.
        init?(_ folder: URL, fileManager fm: FileManager = .default) {
            let resolved = folder.resolvingSymlinksInPath().path
            guard let attrs = try? fm.attributesOfItem(atPath: resolved),
                  attrs[.type] as? FileAttributeType == .typeDirectory,
                  let device = (attrs[.systemNumber] as? NSNumber)?.uint64Value,
                  let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
            resolvedPath = resolved
            self.device = device
            self.inode = inode
        }

        /// True while `folder` still resolves to the same path and the same directory.
        func matches(_ folder: URL, fileManager fm: FileManager = .default) -> Bool {
            FolderIdentity(folder, fileManager: fm) == self
        }
    }

    // MARK: Confirmation text

    struct Confirmation: Equatable {
        let question: String
        let detail: String
        let button: String
    }

    /// The question asked before running a link's action. The full path is
    /// shown (a folder name alone can be made to look like any other) with
    /// control characters made visible, so a name can't add lines to the
    /// dialog.
    static func confirmation(for action: FileOpsURLAction, folder: URL) -> Confirmation? {
        let path = displayPath(folder.path)
        let origin = NSLocalizedString("A link asked Selway to do this. Only continue if you started it.", comment: "Security warning for an external Selway link")
        switch action {
        case .open:
            return nil
        case .newFolder:
            return Confirmation(question: NSLocalizedString("Create a new folder in this folder?", comment: "Confirm creating a folder from an external link"),
                                detail: String.localizedStringWithFormat(NSLocalizedString("%1$@\n\n%2$@", comment: "External link confirmation detail with folder path and security warning"), path, origin), button: NSLocalizedString("Create Folder", comment: "Alert button to create a folder"))
        case .terminal:
            return Confirmation(
                question: NSLocalizedString("Open this folder in Terminal?", comment: "Confirm opening a folder in Terminal from an external link"),
                detail: String.localizedStringWithFormat(NSLocalizedString("%1$@\n\n%2$@ A shell opened in a folder you don't trust can run code from it (for example its git hooks or config, read by your shell prompt).", comment: "External link security warning with folder path"), path, origin),
                button: NSLocalizedString("Open Terminal", comment: "Alert button to open a folder in Terminal"))
        }
    }

    /// `path` with control characters (C0, DEL, C1) and bidirectional
    /// formatting characters shown as \u{…} escapes.
    static func displayPath(_ path: String) -> String {
        var out = ""
        for scalar in path.unicodeScalars {
            let v = scalar.value
            let hidden = v < 0x20 || (0x7F...0x9F).contains(v)
                || (0x200E...0x200F).contains(v) || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
            if hidden {
                out += "\\u{" + String(v, radix: 16, uppercase: true) + "}"
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
