import Foundation

// The Finder extension compiles this file and FileOpsURLScheme.swift, and no
// other Core file, so keep it free of other Core types and of localized text.

/// What Copy Path puts on the pasteboard, as Finder's ⌥⌘C does: the selected
/// items' paths, one per line, in the order given; the folder's path when
/// nothing is selected. Nil when there is neither.
enum ShellCopyPath {
    static func text(selected: [URL], folder: URL?) -> String? {
        let urls = selected.isEmpty ? (folder.map { [$0] } ?? []) : selected
        guard !urls.isEmpty else { return nil }
        return urls.map(\.path).joined(separator: "\n")
    }
}
