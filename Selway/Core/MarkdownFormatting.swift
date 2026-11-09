import Foundation

/// One text replacement produced by a formatting command. Ranges are UTF-16
/// (NSString / NSTextView) offsets, so emoji and other multi-unit characters
/// can't skew selections.
struct MarkdownEdit: Equatable {
    /// Range of the original text to replace.
    var range: NSRange
    var replacement: String
    /// Selection to set afterwards, in the edited text.
    var selection: NSRange

    func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

/// Markdown source formatting as pure functions of (text, selection) → edit.
/// `MarkdownFormatActions` applies the edits to an NSTextView so undo stays native.
enum MarkdownFormatting {

    // MARK: - Inline wrap

    static func bold(_ text: String, _ sel: NSRange) -> MarkdownEdit          { wrap(text, sel, marker: "**") }
    static func italic(_ text: String, _ sel: NSRange) -> MarkdownEdit        { wrap(text, sel, marker: "*") }
    static func strikethrough(_ text: String, _ sel: NSRange) -> MarkdownEdit { wrap(text, sel, marker: "~~") }
    static func inlineCode(_ text: String, _ sel: NSRange) -> MarkdownEdit    { wrap(text, sel, marker: "`") }

    /// Toggles `marker` around the selection: removes it when the selection is
    /// already wrapped (markers inside or just outside it), otherwise adds it.
    /// With no selection, inserts a marker pair and puts the caret between them.
    static func wrap(_ text: String, _ sel: NSRange, marker: String) -> MarkdownEdit {
        let ns = text as NSString
        let sel = clamp(sel, ns.length)
        let m = marker.utf16.count
        let selected = ns.substring(with: sel)

        // Markers inside the selection: "**x**" selected.
        if sel.length >= 2 * m,
           hasMarker(run: leadingRun(of: marker, in: selected as NSString), marker: marker),
           hasMarker(run: trailingRun(of: marker, in: selected as NSString), marker: marker) {
            let inner = (selected as NSString).substring(with: NSRange(location: m, length: sel.length - 2 * m))
            return MarkdownEdit(range: sel, replacement: inner,
                                selection: NSRange(location: sel.location, length: inner.utf16.count))
        }

        // Markers just outside the selection: "x" selected in "**x**", or caret in "**|**".
        if sel.location >= m, sel.location + sel.length + m <= ns.length {
            let before = ns.substring(to: sel.location) as NSString
            let after  = ns.substring(from: sel.location + sel.length) as NSString
            if hasMarker(run: trailingRun(of: marker, in: before), marker: marker),
               hasMarker(run: leadingRun(of: marker, in: after), marker: marker) {
                let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
                return MarkdownEdit(range: outer, replacement: selected,
                                    selection: NSRange(location: sel.location - m, length: sel.length))
            }
        }

        return MarkdownEdit(range: sel, replacement: marker + selected + marker,
                            selection: NSRange(location: sel.location + m, length: sel.length))
    }

    /// Run counts of the marker's character; "*" vs "**" share a character, so a
    /// run of 3 ("***x***") carries both italic and bold.
    private static func hasMarker(run n: Int, marker: String) -> Bool {
        switch marker {
        case "*", "_":   return n == 1 || n >= 3
        case "**", "__": return n >= 2
        default:         return n >= marker.utf16.count
        }
    }

    private static func leadingRun(of marker: String, in s: NSString) -> Int {
        guard let ch = marker.utf16.first else { return 0 }
        var n = 0
        while n < s.length && s.character(at: n) == ch { n += 1 }
        return n
    }

    private static func trailingRun(of marker: String, in s: NSString) -> Int {
        guard let ch = marker.utf16.first else { return 0 }
        var n = 0
        while n < s.length && s.character(at: s.length - 1 - n) == ch { n += 1 }
        return n
    }

    // MARK: - Link / code fence / rule

    /// Wraps the selection (or placeholder text) as `[text](url)` and selects the URL.
    static func link(_ text: String, _ sel: NSRange, url: String) -> MarkdownEdit {
        let ns = text as NSString
        let sel = clamp(sel, ns.length)
        let label = sel.length > 0 ? ns.substring(with: sel) : "link text"
        let replacement = "[\(label)](\(url))"
        let urlStart = sel.location + 1 + label.utf16.count + 2
        return MarkdownEdit(range: sel, replacement: replacement,
                            selection: NSRange(location: urlStart, length: url.utf16.count))
    }

    /// Puts the selection in a fenced code block on its own lines.
    static func codeFence(_ text: String, _ sel: NSRange) -> MarkdownEdit {
        let ns = text as NSString
        var sel = clamp(sel, ns.length)
        let nl = newline(for: text)
        // Leave a selected trailing line break outside the fence.
        let selected = ns.substring(with: sel)
        let trimmedBody = trimTrailingLineBreak(selected)
        sel.length = trimmedBody.utf16.count

        let needBefore = sel.location > 0 && !isLineBreak(ns.character(at: sel.location - 1))
        let end = sel.location + sel.length
        let needAfter = end < ns.length && !isLineBreak(ns.character(at: end))
        let lead = needBefore ? nl : ""
        let tail = needAfter ? nl : ""

        if trimmedBody.isEmpty {
            let replacement = lead + "```" + nl + nl + "```" + tail
            let caret = sel.location + lead.utf16.count + 3 + nl.utf16.count
            return MarkdownEdit(range: sel, replacement: replacement, selection: NSRange(location: caret, length: 0))
        }
        let replacement = lead + "```" + nl + trimmedBody + nl + "```" + tail
        let bodyStart = sel.location + lead.utf16.count + 3 + nl.utf16.count
        return MarkdownEdit(range: sel, replacement: replacement,
                            selection: NSRange(location: bodyStart, length: trimmedBody.utf16.count))
    }

    /// Inserts `---` on its own line. A blank line is kept above it so it can't turn
    /// the previous paragraph into a setext heading.
    static func horizontalRule(_ text: String, _ sel: NSRange) -> MarkdownEdit {
        let ns = text as NSString
        let sel = clamp(sel, ns.length)
        let nl = newline(for: text)
        let loc = sel.location
        let end = sel.location + sel.length

        var lead = ""
        if loc > 0 {
            if !isLineBreak(ns.character(at: loc - 1)) {
                lead = nl + nl
            } else {
                // Start of a line: is the previous line blank?
                let prevLine = ns.lineRange(for: NSRange(location: loc - 1, length: 0))
                let prevContent = ns.substring(with: prevLine).trimmingCharacters(in: .whitespacesAndNewlines)
                if !prevContent.isEmpty { lead = nl }
            }
        }
        let trail = (end < ns.length && isLineBreak(ns.character(at: end))) ? "" : nl
        let replacement = lead + "---" + trail
        return MarkdownEdit(range: sel, replacement: replacement,
                            selection: NSRange(location: loc + replacement.utf16.count, length: 0))
    }

    // MARK: - Line prefixes

    /// Sets the selected lines to heading `level`; if they already all are, removes it.
    static func heading(_ text: String, _ sel: NSRange, level: Int) -> MarkdownEdit {
        let level = max(1, min(6, level))
        return transformLines(text, sel) { lines in
            let parsed = lines.map { line -> (indent: String, level: Int, tail: String) in
                let (indent, rest) = splitIndent(line)
                let (h, tail) = parseHeading(rest)
                return (indent, h, tail)
            }
            let allAtLevel = parsed.allSatisfy { $0.level == level }
            return parsed.map { p in
                (p.indent + (allAtLevel ? "" : String(repeating: "#", count: level) + " "), p.tail)
            }
        }
    }

    static func bulletList(_ text: String, _ sel: NSRange) -> MarkdownEdit {
        transformLines(text, sel) { lines in
            let parsed = lines.map { line -> (indent: String, marker: ListMarker, tail: String) in
                let (indent, rest) = splitIndent(line)
                let (marker, tail) = parseListMarker(rest)
                return (indent, marker, tail)
            }
            let allBullets = parsed.allSatisfy { $0.marker == .bullet }
            return parsed.map { p in (p.indent + (allBullets ? "" : "- "), p.tail) }
        }
    }

    /// Numbers the non-blank selected lines 1, 2, 3… (blank lines don't use up a number).
    static func numberedList(_ text: String, _ sel: NSRange) -> MarkdownEdit {
        transformLines(text, sel) { lines in
            let parsed = lines.map { line -> (indent: String, marker: ListMarker, tail: String) in
                let (indent, rest) = splitIndent(line)
                let (marker, tail) = parseListMarker(rest)
                return (indent, marker, tail)
            }
            let allNumbered = parsed.allSatisfy { $0.marker == .number }
            var n = 0
            return parsed.map { p in
                if allNumbered { return (p.indent, p.tail) }
                n += 1
                return (p.indent + "\(n). ", p.tail)
            }
        }
    }

    static func quote(_ text: String, _ sel: NSRange) -> MarkdownEdit {
        transformLines(text, sel) { lines in
            let allQuoted = lines.allSatisfy { $0.hasPrefix(">") }
            return lines.map { line in
                guard allQuoted else { return ("> ", line) }
                return ("", line.hasPrefix("> ") ? String(line.dropFirst(2)) : String(line.dropFirst()))
            }
        }
    }

    // MARK: - Line machinery

    /// Applies `transform` to the non-blank lines the selection touches, keeping each
    /// line's own terminator (LF, CRLF or CR). `transform` returns, per line, the new
    /// prefix and the unchanged tail, so the caret can follow the text it was in.
    private static func transformLines(_ text: String, _ sel: NSRange,
                                       _ transform: ([String]) -> [(prefix: String, tail: String)]) -> MarkdownEdit {
        let ns = text as NSString
        let sel = clamp(sel, ns.length)

        // Lines covered by the selection; a selection ending at the very start of a
        // line doesn't include that line.
        var span = sel
        if span.length > 0, isLineBreak(ns.character(at: span.location + span.length - 1)) {
            span.length -= 1
            if span.length > 0, ns.character(at: span.location + span.length - 1) == 0x0D,
               ns.character(at: span.location + span.length) == 0x0A { span.length -= 1 }
        }
        let block = ns.lineRange(for: span)

        // Split into (content, terminator).
        var lines: [(content: String, start: Int, terminator: String)] = []
        var pos = block.location
        repeat {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: pos, length: 0))
            lines.append((ns.substring(with: NSRange(location: start, length: contentsEnd - start)),
                          start,
                          ns.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))))
            pos = end
        } while pos < block.location + block.length

        let isBlank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        let single = lines.count == 1
        // A lone blank line still gets the prefix, so you can start a heading or list.
        let targets = lines.indices.filter { single || !isBlank(lines[$0].content) }
        let results = transform(targets.map { lines[$0].content })

        var newContents = lines.map { $0.content }
        var plans: [Int: (prefix: String, tail: String)] = [:]
        for (k, idx) in targets.enumerated() {
            newContents[idx] = results[k].prefix + results[k].tail
            plans[idx] = results[k]
        }
        let replacement = zip(newContents, lines).map { $0 + $1.terminator }.joined()

        let selection: NSRange
        if single, sel.length == 0, let plan = plans[0] {
            let line = lines[0]
            let oldPrefix = line.content.utf16.count - plan.tail.utf16.count
            let newPrefix = plan.prefix.utf16.count
            let caretInLine = sel.location - line.start
            selection = NSRange(location: block.location + max(newPrefix, caretInLine - oldPrefix + newPrefix),
                                length: 0)
        } else {
            let lastTerminator = lines.last?.terminator.utf16.count ?? 0
            selection = NSRange(location: block.location,
                                length: replacement.utf16.count - lastTerminator)
        }
        return MarkdownEdit(range: block, replacement: replacement, selection: selection)
    }

    private enum ListMarker { case none, bullet, number }

    private static func splitIndent(_ line: String) -> (String, String) {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        return (String(indent), String(line.dropFirst(indent.count)))
    }

    /// `## Title` → (2, "Title"); anything else → (0, line).
    private static func parseHeading(_ s: String) -> (Int, String) {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return (0, s) }
        let rest = s.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return (0, s) }
        return (hashes, String(rest.drop { $0 == " " || $0 == "\t" }))
    }

    private static func parseListMarker(_ s: String) -> (ListMarker, String) {
        if let first = s.first, "-*+".contains(first) {
            let rest = s.dropFirst()
            if rest.isEmpty { return (.bullet, "") }
            if rest.first == " " { return (.bullet, String(rest.dropFirst())) }
        }
        if let r = s.range(of: #"^\d+[.)]( |$)"#, options: .regularExpression) {
            return (.number, String(s[r.upperBound...]))
        }
        return (.none, s)
    }

    // MARK: - Helpers

    private static func clamp(_ r: NSRange, _ length: Int) -> NSRange {
        let loc = min(max(0, r.location), length)
        return NSRange(location: loc, length: min(max(0, r.length), length - loc))
    }

    private static func isLineBreak(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }

    /// CRLF if the document uses it, else LF.
    private static func newline(for text: String) -> String {
        text.contains("\r\n") ? "\r\n" : "\n"
    }

    private static func trimTrailingLineBreak(_ s: String) -> String {
        let ns = s as NSString
        var len = ns.length
        if len > 0, ns.character(at: len - 1) == 0x0A {
            len -= 1
            if len > 0, ns.character(at: len - 1) == 0x0D { len -= 1 }
        } else if len > 0, ns.character(at: len - 1) == 0x0D {
            len -= 1
        }
        return ns.substring(to: len)
    }
}
