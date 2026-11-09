import Foundation

// What a file dragged out of Selway carries, kept free of AppKit so it can be
// tested. The views attach it through FileDragSupport.

enum ShellFileDrag {

    /// The files a drag that starts on `clicked` carries, the clicked item
    /// first: the whole selection when the item is part of it (Finder's rule,
    /// as for the context menu), otherwise only the item. The rest keep the
    /// display order of `files`.
    static func urls(dragging clicked: FileItem, in files: [FileItem], selection: Set<String>) -> [URL] {
        let targets = ShellSelection.contextTargets(clicked: clicked, in: files, selection: selection) { $0.id }
        let others = targets.filter { $0.id != clicked.id }.map(\.url)
        return dedupe([clicked.url] + others)
    }

    /// How far, in points, the pointer moves with the button down before a
    /// press on an icon becomes a drag. Up to that it stays a click: a hand
    /// that moves a point or two while clicking still selects. Finder and
    /// AppKit's own views wait for a few points too.
    static let threshold: Double = 4

    /// Whether a press that has moved by (`dx`, `dy`) points is a drag yet.
    static func startsDrag(dx: Double, dy: Double) -> Bool {
        dx * dx + dy * dy > threshold * threshold
    }

    /// `urls` without repeats (by path), first occurrence kept.
    static func dedupe(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    #if canImport(Darwin)
    /// An item provider for one existing file that hands over the file itself:
    /// its file URL (public.file-url, and public.url), named after the file.
    ///
    /// Not `NSItemProvider(contentsOf:)`. That one registers the file's
    /// contents under its type (net.daringfireball.markdown for a .md file)
    /// ahead of the URL, and Finder takes the first type it understands: it
    /// wrote the contents to a new file named after the type, so
    /// `systems-audit-2026-10-09.md` dropped on the Desktop became
    /// `Markdown Document.md`, with none of the original's dates or tags. With
    /// only the URL on offer, Finder copies (or moves) the real file, as it
    /// does a drag from one of its own windows.
    static func itemProvider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        // For a receiver that writes a copy from the provider rather than
        // reading the URL: the copy is named after the file, extension and all.
        provider.suggestedName = url.lastPathComponent
        return provider
    }

    /// An item provider for a drag of `urls`. One provider is one item on the
    /// drag pasteboard, and an item holds one file URL, so it carries the first
    /// file only: the clicked one, as `urls(dragging:in:selection:)` orders
    /// them. Lists, which drag every selected row as an item of its own, give
    /// each row its own provider instead, and the icon grid an AppKit dragging
    /// item per file (IconMouseView). (An extra NSFilenamesPboardType list
    /// on the one item never reached a receiver: that's not a type an item can
    /// hold, and the pasteboard derives the list from the item's file URL.)
    static func itemProvider(for urls: [URL]) -> NSItemProvider {
        guard let first = dedupe(urls).first else { return NSItemProvider() }
        return itemProvider(for: first)
    }
    #endif
}
