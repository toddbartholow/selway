import Foundation

/// Finder-compatible tag editing: real color tags, several per file, toggled
/// like Finder's Tags menu.
///
/// Works on the stored entries ("Name\nColour", see FileTag) rather than on
/// tag names: reading names and writing them back dropped the colour of every
/// custom or renamed tag on the file ("Project\n2\n0" came back as a colourless
/// "Project"). Entries a change doesn't touch are written back as they were.
enum FileOpsTags {

    /// The file's tags as stored. A file with only a legacy colour label (set
    /// by old apps in its Finder info, with no tags attribute) reads as that
    /// colour's tag, as Finder shows it, so a change keeps the colour.
    static func readEntries(_ url: URL, names: TagColorNames = .english) throws -> [String] {
        #if os(macOS)
        if let entries = try FinderTagStore.readEntries(atPath: url.path) { return entries }
        let label = labelNumber(url)
        return FileTag.validColors.contains(label) ? [FileTag(name: names.name(for: label), color: label).entry] : []
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    static func readTags(_ url: URL, names: TagColorNames = .english) throws -> [FileTag] {
        try readEntries(url, names: names).map(FileTag.init(entry:))
    }

    /// Replaces the file's tags with `entries`, and sets its legacy colour label
    /// to match, as the system does when it writes tags: the colour of the last
    /// coloured tag, or none. Old apps and Spotlight's kMDItemFSLabel read that
    /// label, and a stale one kept a file under a colour it no longer had.
    static func writeEntries(_ entries: [String], to url: URL) throws {
        #if os(macOS)
        try FinderTagStore.writeEntries(entries, atPath: url.path)
        let label = entries.map(FileTag.init(entry:)).last { $0.color != 0 }?.color ?? 0
        if labelNumber(url) != label {
            // The label is the target's, like the tags: on a symlink URL the
            // system would set the link's own label.
            var target = ModelPaths.realPath(url) ?? url
            var values = URLResourceValues()
            values.labelNumber = label
            try target.setResourceValues(values)
        }
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    /// The file's legacy label, read fresh: a listed URL caches the value it
    /// had when the folder was loaded.
    private static func labelNumber(_ url: URL) -> Int {
        #if os(macOS)
        let target = URL(fileURLWithPath: (ModelPaths.realPath(url) ?? url).path)
        return (try? target.resourceValues(forKeys: [.labelNumberKey]))?.labelNumber ?? 0
        #else
        return 0
        #endif
    }

    /// Added to a tag change's message when it left links out
    /// (FileItem.tagTargets): " (2 links skipped)"; empty when none were.
    static func skippedNote(links: Int) -> String {
        switch links {
        case ..<1: return ""
        default:
            return " (" + LocalizedCount.string(
                links,
                NSLocalizedString("%lld links skipped", comment: "Number of symbolic links skipped during a tag change"),
                one: "%lld link skipped",
                other: "%lld links skipped") + ")"
        }
    }

    // MARK: Toggling

    /// Finder's toggle rule: if EVERY file already has the color's tag it is
    /// removed from all; otherwise it is added to those without it.
    ///
    /// A file "has Red" when it carries the standard tag for colour 6 under the
    /// user's name for it or "Red" (TagColorNames.isStandard), so a renamed red
    /// tag ("Urgent\n6") counts, and a custom tag that is only coloured red
    /// ("Project\n6") doesn't.
    static func toggleRemoves(_ color: Int, current: [[String]], names: TagColorNames = .english) -> Bool {
        !current.isEmpty && current.allSatisfy { has(color, in: $0, names: names) }
    }

    static func has(_ color: Int, in entries: [String], names: TagColorNames = .english) -> Bool {
        entries.contains { names.isStandard(FileTag(entry: $0), color: color) }
    }

    /// `entries` with the color's tag removed, or added at the end (under the
    /// user's name for it) if missing. Every other entry is kept as it was, in
    /// order, so a file that already has what's asked comes back unchanged.
    static func applying(_ color: Int, remove: Bool, to entries: [String],
                         names: TagColorNames = .english) -> [String] {
        if remove { return entries.filter { !names.isStandard(FileTag(entry: $0), color: color) } }
        if has(color, in: entries, names: names) { return entries }
        return entries + [FileTag(name: names.name(for: color), color: color).entry]
    }

    // MARK: Files

    /// Toggles a standard color (1...7) on `urls` (see `toggleRemoves`). A file
    /// whose tags can't be read is left alone rather than overwriting tags it
    /// couldn't see, and one that already has what's asked isn't written at all.
    /// nil if `color` isn't a standard color.
    static func toggleColor(_ color: Int, names: TagColorNames = .english, on urls: [URL],
                            token: FileOpsCancellationToken? = nil,
                            progress: FileOpsTransfer.ProgressHandler? = nil) -> (removed: Bool, result: FileOpsBatchResult)? {
        guard FileTag.validColors.contains(color) else { return nil }
        let removes = toggleRemoves(color, current: urls.map { (try? readEntries($0, names: names)) ?? [] },
                                    names: names)
        let result = eachFile(urls, token: token, progress: progress) { url in
            try update(url, names: names) { applying(color, remove: removes, to: $0, names: names) }
        }
        return (removes, result)
    }

    /// Removes every tag (colors and custom) from `urls`, and any legacy label.
    static func clear(_ urls: [URL], token: FileOpsCancellationToken? = nil,
                      progress: FileOpsTransfer.ProgressHandler? = nil) -> FileOpsBatchResult {
        eachFile(urls, token: token, progress: progress) { url in
            // Not read first: tags that can't be read (a damaged attribute) are
            // cleared too. A file with nothing to clear isn't written.
            if (try? readEntries(url))?.isEmpty == true { return }
            try writeEntries([], to: url)
        }
    }

    /// Reads the file's entries, applies `change`, and writes only if that
    /// changed something.
    private static func update(_ url: URL, names: TagColorNames = .english,
                               _ change: ([String]) -> [String]) throws {
        let current = try readEntries(url, names: names)
        let changed = change(current)
        if changed != current { try writeEntries(changed, to: url) }
    }

    private static func eachFile(_ urls: [URL], token: FileOpsCancellationToken?,
                                 progress: FileOpsTransfer.ProgressHandler?,
                                 _ body: (URL) throws -> Void) -> FileOpsBatchResult {
        var result = FileOpsBatchResult()
        for (i, url) in urls.enumerated() {
            if token?.isCancelled == true { result.cancelled = true; break }
            progress?(FileOpsProgress(completed: i, total: urls.count, currentName: url.lastPathComponent))
            do {
                try body(url)
                result.done.append(FileOpsMovedItem(source: url, result: url))
            } catch {
                result.failures.append(FileOpsFailure(url, error))
            }
        }
        progress?(FileOpsProgress(completed: urls.count, total: urls.count, currentName: ""))
        return result
    }
}
