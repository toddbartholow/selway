import AppKit
import SwiftUI

/// Shared helpers so List / Icons / Columns can drag real files out to Finder,
/// Desktop, upload dialogs, browsers, and other apps — the same pasteboard
/// contract macOS uses for Finder → Finder file drags: the file's URL, so the
/// receiver gets the file itself, with its name, rather than a copy of its
/// contents (ShellFileDrag.itemProvider).
enum FileDragSupport {

    /// An `NSItemProvider` for a drag of existing files. One provider is one
    /// drag item, so it carries the first URL (see ShellFileDrag); list rows
    /// pass one URL each. (What their drags offer other apps is set on the
    /// table by FileListKeys.)
    static func provider(for urls: [URL]) -> NSItemProvider {
        ShellFileDrag.itemProvider(for: urls)
    }

    /// Resolve which URLs should ride along with a drag that starts on `item`.
    /// If the clicked item is part of the current selection, drag the whole
    /// selection; otherwise just that one item (Finder behaviour).
    static func urlsForDrag(item: FileItem, files: [FileItem], selectedIDs: Set<String>) -> [URL] {
        ShellFileDrag.urls(dragging: item, in: files, selection: selectedIDs)
    }

    /// The files a FileMouseView's drag that starts on `item` carries (as
    /// `urlsForDrag`), each with its icon as loaded so far: its thumbnail if
    /// one has been made (icon previews on), as the view shows it, preferably
    /// at the drag image's size, `pixelSide` pixels square.
    @MainActor
    static func dragFiles(for item: FileItem, files: [FileItem], selectedIDs: Set<String>,
                          pixelSide: CGFloat) -> [FileMouseView.DragFile] {
        let urls = urlsForDrag(item: item, files: files, selectedIDs: selectedIDs)
        let byURL = urls.count > 1 ? Dictionary(files.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
                                   : [item.url: item]
        let icons = FileIconLoader.shared
        let previews = UserPreferences.showsIconPreviews()
        return urls.map { url in
            let image = byURL[url].map { thumbnail(of: $0, previews: previews, pixelSide: pixelSide)
                                         ?? icons.cached($0) ?? icons.placeholder(for: $0) }
                ?? NSWorkspace.shared.icon(forFile: url.path)
            return FileMouseView.DragFile(url: url, image: image)
        }
    }

    /// `item`'s thumbnail, if one has been made: at `pixelSide`'s bucket, or
    /// else the largest there is. Squared for the drag's square frame
    /// (FileThumbnailLoader.squared).
    private static func thumbnail(of item: FileItem, previews: Bool, pixelSide: CGFloat) -> NSImage? {
        guard ThumbnailPolicy.allows(item, enabled: previews) else { return nil }
        let key = ThumbnailPolicy.key(for: item, pixelSide: Double(pixelSide))
        let thumbnails = FileThumbnailLoader.shared
        guard let image = thumbnails.cached(key) ?? thumbnails.cachedAtAnySize(key) else { return nil }
        return FileThumbnailLoader.squared(image)
    }
}

// MARK: - Clicks and drag-out on a file
//
// An icon in the grid (IconMouseView) and a row in the column browser
// (FileRowMouseView) each have one of these laid over them, in place of
// SwiftUI's tap gestures and `onDrag`. `onDrag` started a drag as soon as the
// pointer moved a point with the button down, and the drag took the click: a
// hand that moved a point or two while clicking (common on a trackpad) left
// the file unselected. Here, as in Finder:
// - mouse-down selects at once (`onPress`), and the second mouse-down of a
//   double-click on the same file opens (see IconClickRouting and
//   ShellIconClick.PressTracker for why AppKit's click count isn't enough);
// - the press stays a click until the pointer has moved past
//   ShellFileDrag.threshold, then becomes a drag with one dragging item per
//   file it carries (`onDrag`'s one item provider carried only the first);
// - mouse-up after a press that didn't drag ends the click (`onRelease`: a
//   plain click inside a larger selection narrows it then).
//
// Only the left button's clicks are this view's. For anything else hitTest
// gives way to the SwiftUI view beneath, so a right-click or ⌃-click still
// opens its context menu and the scroll wheel still scrolls. Drops find a
// folder's FileDropView by its registered types, not by hitTest, so this view,
// which registers none, doesn't come between them. It is hidden from
// accessibility: the SwiftUI view beneath stands for the file there.

/// Takes a file's left-button clicks and starts its drags (see above).
/// Subclasses say which part of the view is the file and where its icon is.
class FileMouseView: NSView, NSDraggingSource {
    /// A file a drag carries, with the image it shows under the pointer.
    struct DragFile {
        let url: URL
        let image: NSImage
    }

    /// Mouse-down on the file: the event's click count, the keys held and the
    /// event's timestamp. Returns whether the press began a series of clicks
    /// on the file (it selected rather than opened).
    var onPress: (Int, ShellIconClick.Modifiers, TimeInterval) -> Bool = { _, _, _ in false }
    /// Mouse-up after a single press that didn't become a drag.
    var onRelease: () -> Void = {}
    /// The files a drag carries, the pressed one first, for a drag image of
    /// the given side in pixels. Called when the drag starts, not when the
    /// view was drawn, but as given at the mouse-down (`pressed`): SwiftUI may
    /// hand the view another file's in between.
    var dragFiles: (_ pixelSide: CGFloat) -> [DragFile] = { _ in [] }
    /// Whether the folder holding these files is read-only.
    var isReadOnlyLocation = false
    /// The side of the file's icon as shown, for the drag image.
    var iconSide: CGFloat = 16
    /// The window's file operations (the `fileOperations` environment value),
    /// told how a drag ended.
    weak var fileOperations: FileOperationsService?
    /// The files the drag in progress carries, as they were when it started.
    private var draggedFiles: DraggedOutFiles?
    /// Whether the drag in progress was last over another app (or the Dock)
    /// rather than Selway: a drop in Selway does its own work and reloads.
    private var isOutside = false
    /// Whether the drag in progress carries files from a Time Machine backup,
    /// which are read-only: they're copied, never moved or trashed.
    private var carriesReadOnlyFiles = false

    /// The drag image's side in points: the icon's, no wider than the view.
    private var dragImageSide: CGFloat { max(1, min(iconSide, bounds.width)) }

    /// Where the left button went down, in window coordinates, and the
    /// `dragFiles` of that moment, while it is still down and the press may
    /// yet become a drag.
    private var pressed: (at: NSPoint, dragFiles: (_ pixelSide: CGFloat) -> [DragFile])?

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
        IconClickRouting.install()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    /// A click in a window in the background selects (or drags) the file as
    /// well as bringing the window forward, as in Finder.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Which events are this view's

    /// Final, as are the mouse handlers and the drag's operations: subclasses
    /// change only `takesClick(at:)` and `iconFrame(side:)`.
    final override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = IconClickRouting.hitTesting ?? NSApp.currentEvent, Self.takes(event),
              takesClick(at: convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    /// Whether a left click at `point` (in this view's coordinates) is on the
    /// file: all of the view, unless a subclass says otherwise.
    func takesClick(at point: NSPoint) -> Bool { true }

    /// Where the pressed file's icon is in this view, `side` points square:
    /// where its drag image starts. Subclasses place it.
    func iconFrame(side: CGFloat) -> NSRect {
        NSRect(x: 0, y: (bounds.height - side) / 2, width: side, height: side)
    }

    /// The left button's events, except a ⌃-click, which is a right-click to
    /// AppKit and SwiftUI's context menu.
    static func takes(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:                  return !event.modifierFlags.contains(.control)
        case .leftMouseDragged, .leftMouseUp: return true
        default:                              return false
        }
    }

    // MARK: Clicks

    final override func mouseDown(with event: NSEvent) {
        // Only the first press of a series can turn into a drag (or narrow the
        // selection when it comes up): a double-click has opened the item, and
        // may have left the folder. The view's owner counts the series itself
        // (ShellIconClick.PressTracker): AppKit may count a press as a repeat
        // that is the first on this file.
        let beganSeries = onPress(event.clickCount, ShellIconClick.Modifiers(event.modifierFlags), event.timestamp)
        pressed = beganSeries ? (event.locationInWindow, dragFiles) : nil
    }

    final override func mouseDragged(with event: NSEvent) {
        guard let start = pressed?.at, let files = pressed?.dragFiles else { return }
        let now = event.locationInWindow
        guard ShellFileDrag.startsDrag(dx: Double(now.x - start.x), dy: Double(now.y - start.y)) else { return }
        pressed = nil
        guard window != nil else { return }
        let side = dragImageSide
        let carried = files(side * (window?.backingScaleFactor ?? 2))
        let items = draggingItems(carried, side: side)
        guard !items.isEmpty else { return }
        // Which files they are, to find them in the Trash should it take them.
        draggedFiles = DraggedOutFiles(carried.map(\.url))
        carriesReadOnlyFiles = isReadOnlyLocation || carried.contains { TimeMachineBackups.isSnapshotPath($0.url) }
        isOutside = false
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    final override func mouseUp(with event: NSEvent) {
        guard pressed != nil else { return }
        pressed = nil
        onRelease()
    }

    // MARK: Dragging out

    /// One dragging item per file, each offering its file URL and nothing
    /// else, so the receiver gets the file itself, by name (as with
    /// ShellFileDrag.itemProvider). The pressed file's image starts over its
    /// icon, the others' stacked a little behind it.
    private func draggingItems(_ files: [DragFile], side: CGFloat) -> [NSDraggingItem] {
        let icon = iconFrame(side: side)
        return files.enumerated().map { index, file in
            let item = NSDraggingItem(pasteboardWriter: file.url.absoluteURL as NSURL)
            let offset = CGFloat(min(index, 3)) * 4
            item.setDraggingFrame(icon.offsetBy(dx: offset, dy: offset), contents: file.image)
            return item
        }
    }

    // MARK: NSDraggingSource

    /// What a drag of files offers other apps: what Finder's does, so the
    /// receiver chooses. Finder moves on the same volume (⌘ forces a move),
    /// the Dock's Trash deletes, Mail copies.
    static let otherAppsOperations: NSDragOperation = [.copy, .move, .link, .generic, .delete]

    /// Within Selway the drop decides between move and copy (FileOpsDrop).
    /// Other apps choose from `otherAppsOperations`.
    final func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        isOutside = context != .withinApplication
        let operations: NSDragOperation = context == .withinApplication ? [.copy, .move, .generic]
                                                                          : Self.otherAppsOperations
        // Not generic either: for files, Finder and FileOpsDrop take it as a move.
        return carriesReadOnlyFiles ? operations.subtracting([.move, .generic, .delete]) : operations
    }

    /// Another app that moved the files, or the Trash that took them, did the
    /// work: the window refreshes the folders they left, and records a move
    /// to the Trash for Undo (FileOperationsService.draggedOut). A drop in
    /// Selway does its own work, and reloads, after the drag.
    final func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                               operation: NSDragOperation) {
        let files = draggedFiles
        draggedFiles = nil
        let ending = FileOpsDragOut.ending(operation: operation.rawValue)
        guard isOutside, ending != .kept, let files, let service = fileOperations else { return }
        files.read { [weak service] in service?.draggedOut($0, ending: ending) }
    }
}

/// The files a drag carries, as they were when it started (FileOpsCreatedItem):
/// read on a queue of their own, as a drag can carry many files, and needed
/// only if another app moves them or the Trash takes them.
private final class DraggedOutFiles: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "studio.irq.selway.DraggedOutFiles", qos: .userInitiated)
    /// Touched only on `queue`.
    private var items: [FileOpsCreatedItem] = []

    init(_ urls: [URL]) {
        Self.queue.async { self.items = urls.map { FileOpsCreatedItem(recording: $0) } }
    }

    /// Calls `body` on the main queue with the files, once they have been read.
    func read(_ body: @escaping @MainActor ([FileOpsCreatedItem]) -> Void) {
        Self.queue.async {
            let items = self.items
            DispatchQueue.main.async { MainActor.assumeIsolated { body(items) } }
        }
    }
}

private struct FileOperationsKey: EnvironmentKey {
    static let defaultValue: FileOperationsService? = nil
}

extension EnvironmentValues {
    /// The browser window's file operations, for what a drag out of one of its
    /// files leaves to do (FileMouseView).
    var fileOperations: FileOperationsService? {
        get { self[FileOperationsKey.self] }
        set { self[FileOperationsKey.self] = newValue }
    }
}

extension ShellIconClick.Modifiers {
    /// The ⌘ and ⇧ of AppKit's modifier flags.
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.shift)   { insert(.shift) }
    }
}

// MARK: - Rows

/// A FileRowMouseView over a list row (a column's): the whole row is the
/// file's, and its icon is at the row's leading edge.
struct FileRowMouseArea: NSViewRepresentable {
    /// Mouse-down on the row (FileMouseView.onPress).
    let onPress: (_ clickCount: Int, _ modifiers: ShellIconClick.Modifiers, _ time: TimeInterval) -> Bool
    /// Mouse-up after a single press that didn't become a drag.
    let onRelease: () -> Void
    /// The files a drag carries, the pressed one first, for a drag image of
    /// the given side in pixels. Read when the drag starts.
    let dragFiles: (_ pixelSide: CGFloat) -> [FileMouseView.DragFile]
    /// The row's icon at 100%, which the window's text size scales as in
    /// FileIconView, and how far it is from the row's leading edge.
    let iconSize: CGFloat
    let iconInset: CGFloat
    let isReadOnlyLocation: Bool

    func makeNSView(context: Context) -> FileRowMouseView {
        let view = FileRowMouseView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: FileRowMouseView, context: Context) {
        view.onPress   = onPress
        view.onRelease = onRelease
        view.dragFiles = dragFiles
        view.isReadOnlyLocation = isReadOnlyLocation
        view.iconSide  = (iconSize * context.environment.textScale).rounded()
        view.fileOperations = context.environment.fileOperations
        view.iconInset = iconInset
    }
}

/// Takes a list row's left-button clicks and starts its drags (FileMouseView).
final class FileRowMouseView: FileMouseView {
    /// How far the row's icon is from its leading edge.
    var iconInset: CGFloat = 0

    override func iconFrame(side: CGFloat) -> NSRect {
        let x = userInterfaceLayoutDirection == .rightToLeft ? bounds.width - iconInset - side : iconInset
        return NSRect(x: x, y: (bounds.height - side) / 2, width: side, height: side)
    }
}
