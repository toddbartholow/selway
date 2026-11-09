import SwiftUI
import AppKit
import Observation

/// The capacity reads and results for one pane. The reader is the app's:
/// panes and tabs showing the computer share one read per volume, so a share
/// that doesn't answer holds one thread, not one per pane.
@Observable
@MainActor
final class DiskOverviewState {
    private static let reader = DiskCapacityReader()
    private(set) var capacities: [String: DiskCapacityState] = [:]
    private(set) var volumes: [SidebarVolume] = []

    func update(volumes: [SidebarVolume], refresh: Bool = false) {
        let previousIDs = self.volumes.map { ShellPath.key($0.url) }
        let currentIDs = volumes.map { ShellPath.key($0.url) }
        if self.volumes != volumes { self.volumes = volumes }
        let currentSet = Set(currentIDs)
        if capacities.keys.contains(where: { !currentSet.contains($0) }) {
            capacities = capacities.filter { currentSet.contains($0.key) }
        }
        guard refresh || previousIDs != currentIDs else { return }

        for volume in volumes {
            let id = ShellPath.key(volume.url)
            if !refresh, capacities[id] != nil { continue }
            if capacities[id] == nil { capacities[id] = .reading }
            Task { [weak self] in
                let result = await Self.reader.read(at: volume.url)
                guard let self, self.volumes.contains(where: { ShellPath.key($0.url) == id }),
                      self.capacities[id] != result else { return }
                self.capacities[id] = result
            }
        }
    }

    func volumeURL(for id: String?) -> URL? { volume(for: id)?.url }

    func volume(for id: String?) -> SidebarVolume? {
        guard let id else { return nil }
        return volumes.first { ShellPath.key($0.url) == id }
    }
}

/// How wide the List rows' fixed columns are, and whether they fit the pane.
private struct ListRowColumns {
    let bar: CGFloat
    let capacity: CGFloat
    let warning: CGFloat
    let fit: Bool
}

/// What the overview's layout takes from its width. A resize redraws the view
/// only when it changes one of these.
private struct OverviewLayout: Equatable {
    let columnMinimum: CGFloat
    let listRowsFit: Bool
}

/// The widths the List rows' space and warning columns need for the texts
/// shown, measured in the fonts the rows draw them in.
private struct MeasuredListColumns {
    let capacity: CGFloat
    let warning: CGFloat
}

/// Measures the column texts again only when they or the Text Size change.
@MainActor
private final class DiskOverviewMeasurementCache {
    private var key: [String] = []
    private var scale: CGFloat = 0
    private var columns = MeasuredListColumns(capacity: 0, warning: 0)

    func measure(entries: [DiskOverviewEntry], textScale: CGFloat) -> MeasuredListColumns {
        let texts = entries.flatMap { [$0.capacityText, $0.lowSpaceLabel ?? ""] }
        guard texts != key || scale != textScale else { return columns }
        key = texts
        scale = textScale

        // As `capacityText(_:style:)` and `warning(_:)` draw them: the caption
        // style with monospaced digits, and an 11 pt semibold label whose icon
        // and spacing come before the text.
        let captionSize = NSFont.preferredFont(forTextStyle: .caption1).pointSize
        let capacityFont = NSFont.monospacedDigitSystemFont(
            ofSize: textScale == 1 ? captionSize : (captionSize * textScale).rounded(), weight: .regular)
        let warningSize = textScale == 1 ? 11 : (11 * textScale).rounded()
        let warningFont = NSFont.systemFont(ofSize: warningSize, weight: .semibold)
        let warnings = entries.compactMap(\.lowSpaceLabel)
        let icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: warningSize, weight: .semibold))?.size.width ?? warningSize
        columns = MeasuredListColumns(
            capacity: ceil(maximumWidth(of: entries.map(\.capacityText), font: capacityFont)) + 2,
            warning: warnings.isEmpty ? 0 : ceil(maximumWidth(of: warnings, font: warningFont) + icon + 6) + 2
        )
        return columns
    }

    private func maximumWidth(of strings: [String], font: NSFont) -> CGFloat {
        strings.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    }
}

/// Widths kept outside the view's state, so a change to them doesn't redraw
/// the overview: the grid's, which only the arrow keys read; the content's;
/// and the width a List row needs on one line, which each body pass updates.
@MainActor
private final class DiskOverviewActions {
    var gridWidth: CGFloat = 0
    var contentWidth: CGFloat = 0
    var listRowWidthNeeded: CGFloat = 0
    /// The layout the last body pass drew, which a new width is compared with.
    var drawnLayout: OverviewLayout?
}

/// The computer location's mounted volumes and their available space.
struct DiskOverviewView: View {
    let pane: PaneState
    let isActivePane: @MainActor () -> Bool
    @ObservedObject var favorites: FavoritesService
    let fileOps: FileOperationsService
    let isList: Bool
    @ObservedObject private var ejector = VolumeEjector.shared
    @Environment(\.textScale) private var textScale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @FocusState private var overviewFocused: Bool
    @State private var actions = DiskOverviewActions()
    /// Bumped when a resize changes the layout, to redraw the view.
    @State private var layoutChanges = 0
    @State private var measurementCache = DiskOverviewMeasurementCache()
    @State private var viewportHeight: CGFloat = 0

    private var scale: CGFloat { min(textScale, 1.5) }
    private let columnSpacing: CGFloat = 14
    private func columns(minimum: CGFloat) -> [GridItem] {
        [GridItem(.adaptive(minimum: minimum, maximum: 360 * scale),
                  spacing: columnSpacing, alignment: .top)]
    }
    /// The selection follows the window, as the icon grid's does. Not keyboard
    /// focus: SwiftUI clears the overview's focus as a click on it finishes
    /// (the keys still reach it), so a clicked tile would draw as unfocused.
    private var overviewIsEmphasized: Bool { controlActiveState != .inactive && isActivePane() }

    /// The layout for a content width (less any scroll bar; zero until measured).
    private func layout(forWidth width: CGFloat) -> OverviewLayout {
        OverviewLayout(columnMinimum: width > 0 ? min(230 * scale, max(1, width - 32)) : 230 * scale,
                       listRowsFit: width == 0 || width >= actions.listRowWidthNeeded)
    }

    var body: some View {
        let overview = DiskOverview(volumes: favorites.volumes, capacities: pane.diskOverview.capacities)
        let measuredColumns = measureListColumns(overview)
        // Read so a resize that changes the layout redraws the view; the
        // layout itself comes from the current width, so a change of texts
        // or Text Size without a resize is right too.
        let _ = layoutChanges
        let current = layout(forWidth: actions.contentWidth)
        let _ = (actions.drawnLayout = current)
        let rowColumns = isList
            ? ListRowColumns(bar: 140 * scale, capacity: measuredColumns.capacity,
                             warning: measuredColumns.warning, fit: current.listRowsFit)
            : nil
        let emphasized = overviewIsEmphasized
        ScrollViewReader { scrollProxy in
            ScrollView {
                if overview.groups.isEmpty {
                    ContentUnavailableView("No Drives", systemImage: "externaldrive")
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(overview.groups, id: \.kind) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(group.title)
                                    .scaledFont(size: 11, weight: .semibold)
                                    .foregroundStyle(.secondary)
                                    .accessibilityAddTraits(.isHeader)
                                if isList {
                                    VStack(spacing: 8) {
                                        ForEach(group.entries) { entry in item(entry, columns: rowColumns, emphasized: emphasized) }
                                    }
                                } else {
                                    LazyVGrid(columns: columns(minimum: current.columnMinimum), alignment: .leading, spacing: 14) {
                                        ForEach(group.entries) { entry in item(entry, columns: nil, emphasized: emphasized) }
                                    }
                                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                                        actions.gridWidth = $0
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    // Fills the visible area so a click below the last tile lands
                    // here; the scroll view covers anything behind it.
                    .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .topLeading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        actions.contentWidth = width
                        // Against what was drawn: texts or Text Size may have
                        // changed it since the last resize.
                        if actions.drawnLayout != layout(forWidth: width) { layoutChanges &+= 1 }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        pane.model.overviewSelection = nil
                        overviewFocused = true
                    }
                }
            }
            // Less any safe area the scroll view insets its content by, as IconsView.
            .onGeometryChange(for: CGFloat.self) { proxy in
                max(0, proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom)
            } action: { viewportHeight = $0 }
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityIdentifier("diskOverview")
            .accessibilityLabel(BrowserLocation.computerName)
            .focusable()
            .focusEffectDisabled()
            .focused($overviewFocused)
            .onAppear { DispatchQueue.main.async { focusIfNeeded() } }
            .onChange(of: pane.model.listFocusRequest) { _, _ in
                if pane.model.location.folder == nil { overviewFocused = true }
            }
            .onKeyPress(phases: .down) { press in
                guard press.shellItemKey == .open, !TextInputFocus.isActive, isActivePane(),
                      pane.model.location.folder == nil else { return .ignored }
                DispatchQueue.main.async { pane.openSelection() }
                return .handled
            }
            .onKeyPress(keys: [.rightArrow, .leftArrow, .downArrow, .upArrow], phases: [.down, .repeat]) { press in
                guard !TextInputFocus.isActive, isActivePane(),
                      pane.model.location.folder == nil else { return .ignored }
                guard !press.modifiers.contains(.command), !press.modifiers.contains(.option),
                      !press.modifiers.contains(.control), !press.modifiers.contains(.shift) else { return .ignored }
                let direction: IconGridNavigation.Direction
                switch press.key {
                case .rightArrow: direction = layoutDirection == .rightToLeft ? .left : .right
                case .leftArrow: direction = layoutDirection == .rightToLeft ? .right : .left
                case .downArrow: direction = .down
                case .upArrow: direction = .up
                default: return .ignored
                }
                let entries = overview.groups.flatMap(\.entries)
                let current = pane.model.overviewSelection.flatMap { id in entries.firstIndex { $0.id == id } }
                guard let destination = DiskOverviewNavigation.destination(
                    sectionCounts: overview.groups.map { $0.entries.count },
                    columns: IconGridNavigation.columnCount(width: actions.gridWidth,
                                                            minimum: layout(forWidth: actions.contentWidth).columnMinimum,
                                                            spacing: columnSpacing),
                    leadIndex: current, direction: direction, isList: isList),
                      entries.indices.contains(destination) else { return .ignored }
                let entry = entries[destination]
                pane.model.overviewSelection = entry.id
                withTransaction(Transaction(animation: nil)) { scrollProxy.scrollTo(entry.id, anchor: nil) }
                // Not on every repeat of a held key.
                if press.phase == .down {
                    NSAccessibility.post(element: pane.window ?? NSApp as Any, notification: .announcementRequested,
                                         userInfo: [.announcement: entry.accessibilitySentence,
                                                    .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
                return .handled
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshIfVisible()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                guard let window = note.object as? NSWindow, window === pane.window,
                      window.occlusionState.contains(.visible) else { return }
                refreshIfVisible()
            }
            .task {
                refreshIfVisible()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard pane.model.location.folder == nil else { return }
                    refreshIfVisible()
                }
            }
            .onChange(of: favorites.volumes) { _, volumes in
                // Hidden, don't read space, but don't keep a gone volume selected
                // for File ▸ Open or Eject either.
                guard isWindowVisible else {
                    if let id = pane.model.overviewSelection,
                       !volumes.contains(where: { ShellPath.key($0.url) == id }) {
                        pane.model.overviewSelection = nil
                    }
                    return
                }
                pane.diskOverview.update(volumes: volumes)
                reconcileSelection()
            }
        }
    }

    private func focusIfNeeded() {
        guard isActivePane(), pane.keyboardFocusIsUnclaimed else { return }
        overviewFocused = true
    }

    private func refreshIfVisible() {
        guard pane.model.location.folder == nil, isWindowVisible else { return }
        pane.diskOverview.update(volumes: favorites.volumes, refresh: true)
        reconcileSelection()
    }

    private var isWindowVisible: Bool {
        pane.window?.occlusionState.contains(.visible) == true
    }

    private func reconcileSelection() {
        if pane.diskOverview.volumeURL(for: pane.model.overviewSelection) == nil {
            pane.model.overviewSelection = nil
        }
    }

    /// A tile, or a List-mode row laid out in `columns`.
    private func item(_ entry: DiskOverviewEntry, columns: ListRowColumns?, emphasized: Bool) -> some View {
        let selected = pane.model.overviewSelection == entry.id
        let compact = columns != nil
        return Button {
            pane.model.overviewSelection = entry.id
            overviewFocused = true
        } label: {
            Group {
                if let columns {
                    listRow(entry, columns: columns)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(nsImage: favorites.icon(for: entry.volume))
                                .resizable().frame(width: 48 * scale, height: 48 * scale)
                                .accessibilityHidden(true)
                            title(entry)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 48 * scale)
                        usageBar(entry, width: nil)
                        capacityLines(entry, style: .subheadline)
                    }
                }
            }
            .padding(compact ? 10 : 14)
            .frame(maxWidth: compact ? .infinity : 360 * scale, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .fill(selected ? selectedFill(emphasized: emphasized) : Color(nsColor: .quaternarySystemFill))
            }
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .strokeBorder(selected ? selectedStroke(emphasized: emphasized) : Color(nsColor: .separatorColor),
                                  lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous))
        }
        .buttonStyle(DiskTileButtonStyle())
        .id(entry.id)
        .simultaneousGesture(TapGesture(count: 2).onEnded { open(entry) })
        .contextMenu { contextMenu(for: entry) }
        // The button stays the element (no .accessibilityElement wrapper), so
        // it keeps its role and reports the value.
        .accessibilityLabel(Text(entry.accessibilityLabel))
        .accessibilityValue(Text(entry.accessibilityValue))
        .accessibilityIdentifier("diskTile-\(entry.name)-\(emphasized ? "emphasized" : "unemphasized")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Open") { open(entry) }
        .accessibilityActions {
            if entry.volume.canEject {
                Button("Eject “\(entry.name)”") { ejector.eject(entry.volume) }
            }
            Button("Get Info") { showGetInfoInFinder([entry.volume.url]) }
            Button("Copy Path") {
                if let path = ShellCopyPath.text(selected: [entry.volume.url], folder: nil) { fileOps.copyPath(path) }
            }
        }
    }

    /// One row of fixed columns that line up from row to row, or, when the pane
    /// is too narrow for them at its Text Size, the bar and space under the name.
    @ViewBuilder private func listRow(_ entry: DiskOverviewEntry, columns: ListRowColumns) -> some View {
        let icon = Image(nsImage: favorites.icon(for: entry.volume)).resizable()
            .frame(width: 20 * scale, height: 20 * scale).accessibilityHidden(true)
        if columns.fit {
            HStack(alignment: .center, spacing: 12) {
                icon
                rowTitle(entry)
                usageBar(entry, width: columns.bar)
                HStack(spacing: 4) {
                    capacityText(entry, style: .caption).frame(width: columns.capacity, alignment: .trailing)
                    if columns.warning > 0 {
                        warning(entry).frame(width: columns.warning, alignment: .leading)
                    }
                }
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 6) {
                    rowTitle(entry)
                    usageBar(entry, width: nil)
                    capacityLines(entry, style: .caption)
                }
            }
        }
    }

    private func rowTitle(_ entry: DiskOverviewEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.name).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                .scaledFont(size: 13, weight: .semibold).help(entry.name)
            if let serverName = entry.serverName {
                Text(serverName).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// The List rows' columns. The space column grows with the Text Size, as
    /// its text does; the warning column is there only when a disk needs it.
    /// The List rows' space and warning columns, sized for the texts shown (the
    /// warning column is there only when a disk needs it). Also records the
    /// width a row needs on one line: the icon, a name at least 100 wide, the
    /// columns, their gaps, and the row's and overview's padding.
    private func measureListColumns(_ overview: DiskOverview) -> MeasuredListColumns {
        let measured = measurementCache.measure(entries: overview.groups.flatMap(\.entries), textScale: textScale)
        actions.listRowWidthNeeded = 20 * scale + 100 * textScale + 140 * scale + measured.capacity
            + measured.warning + 12 * 3 + (measured.warning > 0 ? 4 : 0) + 20 + 32
        return measured
    }

    @ViewBuilder private func usageBar(_ entry: DiskOverviewEntry, width: CGFloat?) -> some View {
        if let usage = entry.usage {
            Gauge(value: usage.usedFraction) { EmptyView() }
                .gaugeStyle(.linearCapacity).tint(entry.isLowSpace ? .red : .accentColor)
                // The gauge would take the click from the tile's button.
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(width: width, height: 8)
        } else {
            Color.clear.frame(width: width, height: 8).accessibilityHidden(true)
        }
    }

    private func selectedFill(emphasized: Bool) -> Color {
        Color(nsColor: emphasized ? .selectedContentBackgroundColor
                                  : .unemphasizedSelectedContentBackgroundColor)
            .opacity(emphasized ? 0.22 : 1)
    }

    private func selectedStroke(emphasized: Bool) -> Color {
        colorSchemeContrast == .increased ? .primary
            : Color(nsColor: emphasized ? .selectedContentBackgroundColor
                                        : .unemphasizedSelectedContentBackgroundColor)
    }

    private func open(_ entry: DiskOverviewEntry) {
        pane.model.rememberedOverviewSelection = entry.id
        DispatchQueue.main.async { pane.go(to: .folder(entry.volume.url)) }
    }

    private func title(_ entry: DiskOverviewEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.name).scaledFont(size: 13, weight: .semibold)
                .lineLimit(1).truncationMode(.middle).help(entry.name)
            if let serverName = entry.serverName {
                Text(serverName).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// The space, with the warning beside it, or on its own line rather than
    /// cut off the numbers.
    private func capacityLines(_ entry: DiskOverviewEntry, style: Font.TextStyle) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                capacityText(entry, style: style)
                warning(entry)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                capacityText(entry, style: style)
                warning(entry)
            }
        }
    }

    private func capacityText(_ entry: DiskOverviewEntry, style: Font.TextStyle) -> some View {
        Text(entry.capacityText).scaledFont(style)
            .foregroundStyle(.secondary).lineLimit(1).layoutPriority(1).monospacedDigit()
    }

    @ViewBuilder private func warning(_ entry: DiskOverviewEntry) -> some View {
        // Red on the symbol only: red caption text is too faint to read.
        if let warning = entry.lowSpaceLabel {
            // Not a Label: its icon spacing is the system's, and the column is
            // measured with this 6 pt (DiskOverviewMeasurementCache).
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(warning)
            }
            .scaledFont(size: 11, weight: .semibold)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: DiskOverviewEntry) -> some View {
        Button("Open") { open(entry) }
        if entry.volume.canEject {
            Button("Eject “\(entry.name)”") { ejector.eject(entry.volume) }
                .disabled(ejector.isEjecting(entry.volume))
        }
        Button("Get Info") { showGetInfoInFinder([entry.volume.url]) }
        Button("Copy Path") {
            if let path = ShellCopyPath.text(selected: [entry.volume.url], folder: nil) {
                fileOps.copyPath(path)
            }
        }
    }
}

/// Tiles don't dim while pressed because selection, not press state, marks them.
private struct DiskTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
