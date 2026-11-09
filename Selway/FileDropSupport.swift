import AppKit
import SwiftUI

// Files dropped into Selway from Finder, the Desktop, other apps or another
// Selway window. What a drop does (move or copy, or nothing) is decided by
// FileOpsDrop (Core) and run by FileOperationsService.drop, which is Paste's
// transfer: progress, free names, errors, Undo and selecting the result.
//
// The drop targets are AppKit views, not SwiftUI's onDrop / dropDestination:
// - AppKit finds a drop target by the types a view registered for, never by
//   hitTest, so these views return nil from hitTest and every click still
//   goes to the table, list or grid beneath them, which keep their own
//   selection, double-click and drag-out (see ListView.tableView).
// - Only AppKit says what the drag's source allows and whether the drag
//   started in Selway, and lets the drop pick the operation (and so the
//   cursor's badge) from them and the keys held.
//
// Each view has a drop area behind it for the folder it shows, and each
// folder row or icon a drop target of its own. AppKit gives a drag to the
// deepest registered view under the pointer, so a folder takes it and a
// file row or empty space leaves it to the area behind. A folder icon's
// target is its picture and name only (IconDropView), as for its clicks.
//
// A drag that carries no files but file promises (a Mail attachment, a photo
// from Photos, an image from Safari) is a drop too: the source writes the
// files, and FileOperationsService.receivePromises lands them (FileOpsPromiseDrop).

/// What a drop brings into a folder.
enum FileDrop {
    /// Files that exist, to move or copy (FileOpsDrop).
    case files([URL], FileOpsTransfer.Mode)
    /// File promises, which their source writes.
    case promises([NSFilePromiseReceiver])
}

/// An invisible drop target for files: drops go into `folder`.
final class FileDropView: NSView {
    /// Where a drop goes; nil refuses every drop (search results).
    var folder: URL?
    /// Draws its own highlight while a drop would be accepted (a folder row
    /// or icon). The drop area behind a whole view is covered by the view, so
    /// SwiftUI draws its highlight instead, through `onTargeted`.
    var drawsHighlight = false
    /// Scrolls the list under the pointer near its edges (see `autoscroll`).
    var autoscrolls = false
    var onTargeted: ((Bool) -> Void)?
    var perform: ((_ drop: FileDrop, _ folder: URL) -> Void)?

    private var isTargeted = false
    /// The folder as read for the current drag (by sequence number).
    private var destination: (sequence: Int, folder: URL, value: FileOpsDrop.Destination)?
    /// Whether the files dragged are read-only, worked out once per drag.
    private var readOnlySource: (sequence: Int, value: Bool)?

    init() {
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { false }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if autoscrolls { autoscroll(sender) }
        return update(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setTargeted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setTargeted(false) }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { setTargeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setTargeted(false)
        guard let folder, let perform, case .drop(let mode) = decision(sender) else { return false }
        let urls = DraggedFiles.items(sender).map(\.url)
        guard !urls.isEmpty else {
            // Promises are asked for now, while the drag is still the
            // source's to answer; they are written in the background.
            let promises = DraggedFiles.promises(sender)
            guard !promises.isEmpty else { return false }
            perform(.promises(promises), folder)
            return true
        }
        // After the drag is done with: the source may be a row of a list in
        // this window, still in its drag session, and the drop reloads it.
        DispatchQueue.main.async { perform(.files(urls, mode), folder) }
        return true
    }

    // MARK: Deciding

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard case .drop(let mode) = decision(sender) else {
            setTargeted(false)
            return []
        }
        setTargeted(true)
        // The source's own word for a move, where it has one, so it hears
        // back what it allowed: Finder with ⌘ held allows only "generic".
        let mask = sender.draggingSourceOperationMask
        switch mode {
        case .copy: return .copy
        case .move: return !mask.contains(.move) && mask.contains(.generic) ? .generic : .move
        }
    }

    private func decision(_ sender: NSDraggingInfo) -> FileOpsDrop.Decision {
        guard let folder, !TimeMachineBackups.isSnapshotPath(folder) else { return .refuse(.notAllowed) }
        let items = DraggedFiles.items(sender)
        var allowed = FileOpsDrop.allowed(sourceOperationMask: sender.draggingSourceOperationMask.rawValue,
                                          fromThisApp: sender.draggingSource != nil)
        // Files from a Time Machine backup, or from a backup disk's root, are
        // read-only: copied, never moved. Asked of the drag, not its source's
        // mask, which a drag from Selway doesn't go by (FileOpsDrop.allowed).
        if isReadOnly(items, sequence: sender.draggingSequenceNumber) { allowed.remove(.move) }
        guard !items.isEmpty else {
            return FileOpsDrop.decidePromises(count: DraggedFiles.promiseCount(sender),
                                              modifiers: DraggedFiles.modifiers, allowed: allowed)
        }
        let sequence = sender.draggingSequenceNumber
        if destination?.sequence != sequence || destination?.folder != folder {
            destination = (sequence, folder, FileOpsDrop.Destination(reading: folder))
        }
        guard let dest = destination?.value else { return .refuse(.notAllowed) }
        return FileOpsDrop.decide(items, into: dest, modifiers: DraggedFiles.modifiers, allowed: allowed)
    }

    private func isReadOnly(_ items: [FileOpsDrop.Item], sequence: Int) -> Bool {
        if let readOnlySource, readOnlySource.sequence == sequence { return readOnlySource.value }
        let backups = TimeMachineBackups.live
        let parents = Set(items.map { ShellPath.key($0.url.deletingLastPathComponent()) })
        let value = items.contains { TimeMachineBackups.isSnapshotPath($0.url) }
            || parents.contains { backups.isDestinationRoot(URL(fileURLWithPath: $0, isDirectory: true)) }
        readOnlySource = (sequence, value)
        return value
    }

    private func setTargeted(_ targeted: Bool) {
        guard targeted != isTargeted else { return }
        isTargeted = targeted
        if drawsHighlight { needsDisplay = true }
        onTargeted?(targeted)
    }

    // MARK: Highlight

    override func draw(_ dirtyRect: NSRect) {
        guard drawsHighlight, isTargeted else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        path.fill()
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    // MARK: Autoscroll

    /// Scrolls the list or grid under the pointer while a drag hovers near
    /// its top or bottom edge, so a folder further down can be reached.
    /// AppKit does that for drop targets inside a scroll view (the folder
    /// rows), but this view sits behind the list, not in it.
    private func autoscroll(_ sender: NSDraggingInfo) {
        guard let frameView = window?.contentView?.superview,
              let hit = frameView.hitTest(frameView.convert(sender.draggingLocation, from: nil)),
              let scrollView = (hit as? NSScrollView) ?? hit.enclosingScrollView else { return }
        let clip = scrollView.contentView
        let point = clip.convert(sender.draggingLocation, from: nil)
        let visible = clip.bounds
        // The part of the list not under its header or the title bar.
        let insets = scrollView.contentInsets
        let top    = clip.isFlipped ? visible.minY + insets.top : visible.maxY - insets.top
        let bottom = clip.isFlipped ? visible.maxY - insets.bottom : visible.minY + insets.bottom
        let fromTop    = clip.isFlipped ? point.y - top : top - point.y
        let fromBottom = clip.isFlipped ? bottom - point.y : point.y - bottom
        let edge: CGFloat = 24
        // Faster the closer to (or further past) the edge, up to a row a step.
        let step: CGFloat
        if fromTop < edge {
            step = -min(edge, edge - fromTop) / 2
        } else if fromBottom < edge {
            step = min(edge, edge - fromBottom) / 2
        } else {
            return
        }
        var origin = visible.origin
        origin.y += clip.isFlipped ? step : -step
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: visible.size)).origin
        guard target != visible.origin else { return }
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
    }
}

/// A folder icon's drop target in the grid: only its picture and name take a
/// drop, as only they take its clicks (IconHitParts, ShellIconHitArea), and a
/// drop beside a short name falls to the drop area behind the grid, the
/// folder shown, as in Finder. AppKit picks a drop target by the frames of
/// the views registered for the drag, so each part gets a FileDropView of its
/// own, and this view, behind them, draws one highlight around both while
/// either would take the drop.
final class IconDropView: NSView {
    /// Where a drop goes.
    var folder: URL? {
        didSet { targets.forEach { $0.folder = folder } }
    }
    var perform: ((_ drop: FileDrop, _ folder: URL) -> Void)? {
        didSet { targets.forEach { $0.perform = perform } }
    }
    /// The picture and the name, in this view's coordinates (y down); none
    /// before SwiftUI has placed them.
    var parts: [CGRect] = [] {
        didSet { if parts != oldValue { placeTargets() } }
    }

    private var targets: [FileDropView] = []
    /// The targets a drag is over, and would drop into (one at a time, but
    /// the pointer leaves one just as it enters the other).
    private var targeted = Set<ObjectIdentifier>()

    init() {
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        placeTargets()
    }

    /// The parts, or the whole cell until they are known (as IconMouseView).
    private var frames: [CGRect] { parts.isEmpty ? [bounds] : parts }

    private func placeTargets() {
        let frames = self.frames
        while targets.count < frames.count {
            let target = FileDropView()
            target.folder  = folder
            target.perform = perform
            let id = ObjectIdentifier(target)
            target.onTargeted = { [weak self] in self?.setTargeted($0, id) }
            addSubview(target)
            targets.append(target)
        }
        while targets.count > frames.count {
            let target = targets.removeLast()
            targeted.remove(ObjectIdentifier(target))
            target.removeFromSuperview()
        }
        for (target, frame) in zip(targets, frames) where target.frame != frame { target.frame = frame }
        needsDisplay = true
    }

    private func setTargeted(_ isTargeted: Bool, _ id: ObjectIdentifier) {
        let was = !targeted.isEmpty
        if isTargeted { targeted.insert(id) } else { targeted.remove(id) }
        if was != !targeted.isEmpty { needsDisplay = true }
    }

    /// FileDropView's highlight, around the picture and around the name, just
    /// outside them so its edge clears the name's text.
    override func draw(_ dirtyRect: NSRect) {
        guard !targeted.isEmpty else { return }
        for frame in frames {
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            path.fill()
            path.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }
}

/// The files of the drag in progress, read from its pasteboard once per drag
/// (by sequence number) however many folders it hovers over.
@MainActor
private enum DraggedFiles {
    private static var current: (sequence: Int, items: [FileOpsDrop.Item])?

    /// File URLs only: a web link or text is no file to drop.
    static func items(_ sender: NSDraggingInfo) -> [FileOpsDrop.Item] {
        let sequence = sender.draggingSequenceNumber
        if let current, current.sequence == sequence { return current.items }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let items = urls.map { FileOpsDrop.Item(reading: $0) }
        current = (sequence, items)
        return items
    }

    /// How many files the drag promises (counted once per drag), for a drag
    /// with no file URLs.
    private static var promised: (sequence: Int, count: Int)?

    static func promiseCount(_ sender: NSDraggingInfo) -> Int {
        let sequence = sender.draggingSequenceNumber
        if let promised, promised.sequence == sequence { return promised.count }
        let count = promises(sender).count
        promised = (sequence, count)
        return count
    }

    /// The drag's file promises, read afresh for the drop.
    static func promises(_ sender: NSDraggingInfo) -> [NSFilePromiseReceiver] {
        sender.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
    }

    /// The keys held right now; AppKit sends an update when they change.
    static var modifiers: FileOpsDrop.Modifiers {
        let flags = NSEvent.modifierFlags
        var modifiers: FileOpsDrop.Modifiers = []
        if flags.contains(.option)  { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}

extension FileOperationsService {
    /// Runs a FileDropView's drop into `folder`.
    func drop(_ drop: FileDrop, into folder: URL, reload: @escaping () -> Void) {
        switch drop {
        case .files(let urls, let mode): self.drop(urls, into: folder, mode: mode, reload: reload)
        case .promises(let promises):    receivePromises(promises, into: folder, reload: reload)
        }
    }
}

// MARK: - SwiftUI

/// A FileDropView in a SwiftUI view.
struct FileDropTarget: NSViewRepresentable {
    let folder: URL?
    let fileOps: FileOperationsService
    let reload: () -> Void
    var drawsHighlight = false
    var autoscrolls = false
    var onTargeted: ((Bool) -> Void)?

    func makeNSView(context: Context) -> FileDropView {
        let view = FileDropView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: FileDropView, context: Context) {
        view.folder         = folder
        view.drawsHighlight = drawsHighlight
        view.autoscrolls    = autoscrolls
        view.onTargeted     = onTargeted
        let fileOps = fileOps, reload = reload
        view.perform = { drop, folder in fileOps.drop(drop, into: folder, reload: reload) }
    }
}

/// An IconDropView in a SwiftUI view.
private struct IconDropTarget: NSViewRepresentable {
    let folder: URL
    let parts: [CGRect]
    let fileOps: FileOperationsService
    let reload: () -> Void

    func makeNSView(context: Context) -> IconDropView {
        let view = IconDropView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: IconDropView, context: Context) {
        view.folder = folder
        view.parts  = parts
        let fileOps = fileOps, reload = reload
        view.perform = { drop, folder in fileOps.drop(drop, into: folder, reload: reload) }
    }
}

/// The drop area behind a whole list, grid or column: drops on empty space
/// or on a file go into `folder`, with a frame around the view while one
/// would be accepted.
private struct FileDropArea: ViewModifier {
    let folder: URL?
    let fileOps: FileOperationsService
    let reload: () -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background(FileDropTarget(folder: folder, fileOps: fileOps, reload: reload,
                                       autoscrolls: true, onTargeted: { isTargeted = $0 }))
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    /// Drops on empty space in this view, or on a file in it, go into
    /// `folder`; nil refuses them (search results show no one folder).
    func fileDropArea(_ folder: URL?, fileOps: FileOperationsService,
                      reload: @escaping () -> Void) -> some View {
        modifier(FileDropArea(folder: folder, fileOps: fileOps, reload: reload))
    }

    /// Drops on this row or icon go into `folder`, highlighting it while one
    /// would be accepted. Pass nil for a file: the drop area behind the view
    /// takes those. `verticalOutset` grows the target and its highlight past
    /// the content (a table row is taller than its text).
    func folderDropTarget(_ folder: URL?, fileOps: FileOperationsService, verticalOutset: CGFloat = 0,
                          reload: @escaping () -> Void) -> some View {
        background {
            if let folder {
                FileDropTarget(folder: folder, fileOps: fileOps, reload: reload, drawsHighlight: true)
                    .padding(.vertical, -verticalOutset)
            }
        }
    }

    /// Drops on an icon's picture or name (the parts it marks with
    /// `iconHitPart`) go into `folder`, highlighting them while one would be
    /// accepted; drops on the rest of its cell go to the drop area behind the
    /// grid (IconDropView). Pass nil for a file.
    func iconDropTarget(_ folder: URL?, fileOps: FileOperationsService,
                        reload: @escaping () -> Void) -> some View {
        backgroundPreferenceValue(IconHitParts.self) { parts in
            if let folder {
                GeometryReader { cell in
                    IconDropTarget(folder: folder, parts: parts.map { cell[$0] }, fileOps: fileOps, reload: reload)
                }
            }
        }
    }
}

// MARK: - UI tests

#if SELWAY_UI_TESTING
/// UI tests only (UITestHooks.promisedFiles): a small floating panel whose one
/// view, dragged, offers a file promise per name, as Mail offers an
/// attachment, so DropTests can drop promises without another app. Each
/// promise writes a short text file of its name; a name after "fail:" fails
/// with a write error instead, for the drop to report.
@MainActor
enum UITestPromiseSource {
    private static var panel: NSPanel?

    static func show(_ names: [String]) {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 90),
                            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Promise Source"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.contentView = PromiseSourceView(names: names)
        // The bottom right corner, clear of a lone browser window's list.
        if let area = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 20, y: area.minY + 20))
        }
        panel.orderFront(nil)
        self.panel = panel
    }
}

/// The promise source panel's view (UITestPromiseSource).
private final class PromiseSourceView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    private let names: [String]
    /// The press in progress has started its drag.
    private var dragged = false

    init(names: [String]) {
        self.names = names
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Promised files")
        setAccessibilityIdentifier("promiseSource")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) { dragged = false }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged else { return }
        dragged = true
        let image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        let items = names.enumerated().map { index, name in
            let provider = NSFilePromiseProvider(fileType: "public.plain-text", delegate: self)
            provider.userInfo = name
            let item = NSDraggingItem(pasteboardWriter: provider)
            item.setDraggingFrame(NSRect(x: 8 + CGFloat(index) * 4, y: 8, width: 32, height: 32), contents: image)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        let name = provider.userInfo as? String ?? "promised.txt"
        return name.hasPrefix("fail:") ? String(name.dropFirst(5)) : name
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        if (provider.userInfo as? String ?? "").hasPrefix("fail:") {
            completionHandler(CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]))
            return
        }
        do {
            try Data("promised\n".utf8).write(to: url, options: .withoutOverwriting)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
#endif
