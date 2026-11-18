import SwiftUI

struct StatusBarView: View {
    private static let capacityReader = DiskCapacityReader()

    let files: [FileItem]
    let selectedIDs: Set<String>
    let currentPath: URL
    /// How the list is arranged and what is being searched, said here because the
    /// toolbar keeps its system size at large text sizes and may tuck items into ».
    var sortField:     SortField   = UserPreferences.defaultSortField
    var sortAscending: Bool        = UserPreferences.defaultSortAscending
    var groupBy:       GroupBy     = .none
    var searchQuery:   String      = ""
    var searchScope:   SearchScope = .thisFolder
    var isSearching = false
    /// A link being followed to open it (ShellOpenResolver): said, with a
    /// spinner, until it's open.
    var openingLinkName: String?

    /// Cached: querying the volume on every render (each selection change) was
    /// a synchronous file-system call on the main thread.
    @State private var freeDiskSpace: String?
    /// Volume holding `currentPath`; free space is polled per volume, so moving
    /// between folders on one disk (or watcher reloads) doesn't start new queries.
    @State private var volume: URL?
    /// A completed file operation starts a fresh capacity read immediately.
    @State private var capacityRefresh = 0

    var body: some View {
        HStack(spacing: 16) {
            Text(itemCountText)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)

            if !selectedIDs.isEmpty {
                Text(selectionText)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                if isSearching || openingLinkName != nil { ProgressView().controlSize(.mini) }
                Text(stateText)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel(stateSpoken)
            }
            // Gives way first when the bar is short of room.
            .layoutPriority(-1)

            Spacer(minLength: 0)

            if let free = freeDiskSpace {
                Text("\(free) available")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("statusBar")
        // Which volume the folder is on: re-checked on navigation only, not on
        // every reload (the old key included the item count, so each watcher
        // reload in a busy folder started another free-space query).
        .task(id: ShellPath.key(currentPath)) {
            let found = await Self.volume(of: currentPath)
            guard !Task.isCancelled, !ShellPath.same(found, volume) else { return }
            freeDiskSpace = nil          // don't show the previous disk's figure
            volume = found
        }
        // Every 30 s while on the same volume. The query runs detached and can't
        // be interrupted, so its result is dropped if the volume changed (or
        // the view went away) meanwhile. The reader coalesces simultaneous reads
        // for the same volume, including reads restarted by file operations.
        .task(id: "\(volume.map(ShellPath.key) ?? ""):\(capacityRefresh)") {
            guard let url = volume else { return }
            var forceRefresh = capacityRefresh > 0
            while !Task.isCancelled {
                let capacity = await Self.capacityReader.read(at: url, forceRefresh: forceRefresh)
                guard !Task.isCancelled else { return }
                forceRefresh = false
                if case let .known(_, free) = capacity {
                    freeDiskSpace = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                } else {
                    freeDiskSpace = nil
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selwayFileOperationDidFinish)) { _ in
            capacityRefresh &+= 1
        }
    }

    private var stateText: String { state(arrow: sortAscending ? "↑" : "↓") }
    /// The sort status in words for VoiceOver, a whole sentence per direction.
    private var stateSpoken: String {
        guard openingLinkName == nil, searchQuery.isEmpty else { return stateText }
        if groupBy == .none {
            return sortAscending
                ? String(localized: "Sorted by \(sortField.displayName) ascending", comment: "Current spoken sort status")
                : String(localized: "Sorted by \(sortField.displayName) descending", comment: "Current spoken sort status")
        }
        return sortAscending
            ? String(localized: "Sorted by \(sortField.displayName) ascending · Grouped by \(groupBy.displayName)", comment: "Current spoken sort and grouping status")
            : String(localized: "Sorted by \(sortField.displayName) descending · Grouped by \(groupBy.displayName)", comment: "Current spoken sort and grouping status")
    }

    private func state(arrow: String) -> String {
        if let openingLinkName {
            return String(localized: "Opening “\(openingLinkName)”…", comment: "Status bar message while opening a link")
        }
        if !searchQuery.isEmpty {
            let scope = searchScope.displayName
            if isSearching {
                return String(localized: "Searching “\(searchQuery)” in \(scope)", comment: "Status bar message while searching")
            }
            return files.isEmpty
                ? String(localized: "No results for “\(searchQuery)” in \(scope)", comment: "Status bar message when a search has no results")
                : String(localized: "\(files.count) found for “\(searchQuery)” in \(scope)",
                         comment: "Number of search results for a query and scope.")
        }
        if groupBy == .none {
            return String(localized: "Sorted by \(sortField.displayName) \(arrow)", comment: "Current sort status")
        }
        return String(localized: "Sorted by \(sortField.displayName) \(arrow) · Grouped by \(groupBy.displayName)",
                      comment: "Current sort and grouping status")
    }

    private var itemCountText: String {
        String(localized: "\(files.count) items", comment: "Number of items in the current folder.")
    }

    private var selectionText: String {
        let sel = files.filter { selectedIDs.contains($0.id) }
        let totalBytes = sel.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size }
        let countStr = String(localized: "\(sel.count) selected", comment: "Number of selected items.")
        guard totalBytes > 0 else { return countStr }
        return String(localized: "\(countStr) — \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))", comment: "Selection count and total file size in the status bar")
    }

    /// Mount point of the volume holding `url`; `url` itself when that can't
    /// be read.
    private static func volume(of url: URL) async -> URL {
        await Task.detached(priority: .utility) { () -> URL in
            (try? url.resourceValues(forKeys: [.volumeURLKey]).volume) ?? url
        }.value
    }

}
