import AppKit

/// Applies the pure `MarkdownFormatting` edits (Core/MarkdownFormatting.swift) to an
/// `NSTextView` through AppKit APIs so Undo/Redo stay on the native `NSUndoManager`.
enum MarkdownFormatActions {

    // MARK: - Undo / Redo

    static func undo(_ tv: NSTextView) {
        tv.window?.makeFirstResponder(tv)
        tv.undoManager?.undo()
    }

    static func redo(_ tv: NSTextView) {
        tv.window?.makeFirstResponder(tv)
        tv.undoManager?.redo()
    }

    static func canUndo(_ tv: NSTextView?) -> Bool { tv?.undoManager?.canUndo ?? false }
    static func canRedo(_ tv: NSTextView?) -> Bool { tv?.undoManager?.canRedo ?? false }

    // MARK: - Commands

    static func bold(_ tv: NSTextView)           { apply(tv, MarkdownFormatting.bold) }
    static func italic(_ tv: NSTextView)         { apply(tv, MarkdownFormatting.italic) }
    static func strikethrough(_ tv: NSTextView)  { apply(tv, MarkdownFormatting.strikethrough) }
    static func inlineCode(_ tv: NSTextView)     { apply(tv, MarkdownFormatting.inlineCode) }
    static func codeFence(_ tv: NSTextView)      { apply(tv, MarkdownFormatting.codeFence) }
    static func horizontalRule(_ tv: NSTextView) { apply(tv, MarkdownFormatting.horizontalRule) }
    static func bulletList(_ tv: NSTextView)     { apply(tv, MarkdownFormatting.bulletList) }
    static func numberedList(_ tv: NSTextView)   { apply(tv, MarkdownFormatting.numberedList) }
    static func quote(_ tv: NSTextView)          { apply(tv, MarkdownFormatting.quote) }

    static func heading(_ tv: NSTextView, level: Int) {
        apply(tv) { MarkdownFormatting.heading($0, $1, level: level) }
    }

    static func link(_ tv: NSTextView, url: String = "https://") {
        apply(tv) { MarkdownFormatting.link($0, $1, url: url) }
    }

    // MARK: - Adapter

    private static func apply(_ tv: NSTextView, _ make: (String, NSRange) -> MarkdownEdit) {
        let edit = make(tv.string, tv.selectedRange())
        tv.window?.makeFirstResponder(tv)
        guard tv.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        tv.undoManager?.beginUndoGrouping()
        tv.replaceCharacters(in: edit.range, with: edit.replacement)
        tv.didChangeText()
        tv.undoManager?.endUndoGrouping()
        let length = (tv.string as NSString).length
        let loc = min(edit.selection.location, length)
        tv.setSelectedRange(NSRange(location: loc, length: min(edit.selection.length, length - loc)))
    }
}
