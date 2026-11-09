import Foundation

/// App-wide folder watching. Views `retain` the folders they display (the main
/// listing and every visible column) and `release` them when they go away; when
/// a watched folder changes, `.refreshDirectory` is posted with its logical URL,
/// which the list and column views already use to reload. When only files in it
/// changed in place (a download or a log file growing), `.directoryEntriesChanged`
/// is posted instead, with their names, so the listing reads just those again.
enum DirectoryWatcher {
    static let shared = ShellDirectoryWatcher(throttle: 0.4, handler: { changed in
        for url in changed {
            NotificationCenter.default.post(name: .refreshDirectory, object: url)
        }
    }, entriesHandler: { changed in
        for change in changed {
            NotificationCenter.default.post(name: .directoryEntriesChanged, object: change.folder,
                                            userInfo: [namesKey: change.names, realPathKey: change.realPath])
        }
    })

    private static let namesKey = "names"
    private static let realPathKey = "realPath"

    /// The names of the entries a `.directoryEntriesChanged` notification is about.
    static func changedNames(_ notification: Notification) -> Set<String>? {
        notification.userInfo?[namesKey] as? Set<String>
    }

    /// The real path of the folder a `.directoryEntriesChanged` notification is
    /// about, as the watcher resolved it: where Spotlight reports its files
    /// when the folder is reached through a link.
    static func realPath(_ notification: Notification) -> String? {
        notification.userInfo?[realPathKey] as? String
    }
}
