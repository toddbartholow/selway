import Foundation

// MARK: - Swift Markdown → HTML renderer

/// Renders Markdown for the reader's WKWebView (which runs with JavaScript off).
///
/// Safety model: every character of the source is HTML-escaped exactly once.
/// Code spans, links, images, escapes and line breaks are cut out of the raw text
/// first and replaced by opaque slot tokens; the remaining text is escaped and
/// emphasis is applied; then the slots are substituted in a single pass. No pass
/// ever rewrites HTML that an earlier pass generated, so Markdown syntax hidden in
/// a URL or alt text can't break out of an attribute.
enum MarkdownToHTML {

    struct Rendered: Equatable {
        let html: String
        /// The document references http(s) images (shown only if allowed).
        let hasRemoteImages: Bool
        /// Paths of the local images the page loads (through `MarkdownLocalImages`):
        /// the only files the reader's image handler may serve for it.
        var localImages: Set<String> = []
    }

    static func render(_ markdown: String, title: String, allowRemoteImages: Bool = false,
                       imageFolder: URL? = nil, language: String? = nil) -> String {
        renderDocument(markdown, title: title, allowRemoteImages: allowRemoteImages,
                       imageFolder: imageFolder, language: language).html
    }

    /// `imageFolder`: the document's folder. Local images are resolved against it
    /// and loaded from `MarkdownLocalImages.scheme` URLs, the only local source the
    /// page's Content-Security-Policy allows. Without it, local image references
    /// are left as written (and the page won't load them).
    static func renderDocument(_ markdown: String, title: String, allowRemoteImages: Bool = false,
                               imageFolder: URL? = nil,
                               language: String? = nil) -> Rendered {
        var ctx = Context(allowRemoteImages: allowRemoteImages, imageFolder: imageFolder)
        let body = parseBlocks(stripSlotMarkers(markdown), ctx: &ctx)
        return Rendered(html: htmlTemplate(title: title, body: body,
                                           allowRemoteImages: allowRemoteImages, language: language),
                        hasRemoteImages: ctx.sawRemoteImage, localImages: ctx.localImages)
    }

    /// Just the body HTML (no template) — used by tests.
    static func renderBody(_ markdown: String, allowRemoteImages: Bool = false, imageFolder: URL? = nil) -> String {
        var ctx = Context(allowRemoteImages: allowRemoteImages, imageFolder: imageFolder)
        return parseBlocks(stripSlotMarkers(markdown), ctx: &ctx)
    }

    private struct Context {
        let allowRemoteImages: Bool
        let imageFolder: URL?
        var sawRemoteImage = false
        var localImages: Set<String> = []
        /// Heading ids handed out so far, and the last suffix used per base id.
        var usedIDs: Set<String> = []
        var suffixes: [String: Int] = [:]

        /// GitHub-style unique heading id: the slug, then `slug-1`, `slug-2`, … for
        /// repeats (skipping any id an earlier heading already has). An empty slug
        /// becomes "section".
        mutating func headingID(for text: String) -> String {
            let base = MarkdownToHTML.anchor(text).isEmpty ? "section" : MarkdownToHTML.anchor(text)
            var candidate = base
            var n = suffixes[base, default: 0]
            while usedIDs.contains(candidate) {
                n += 1
                candidate = "\(base)-\(n)"
            }
            suffixes[base] = n
            usedIDs.insert(candidate)
            return candidate
        }
    }

    private static let slotOpen: Character  = "\u{FFFE}"
    private static let slotClose: Character = "\u{FFFF}"

    /// Slot markers are Unicode noncharacters; drop any in the source so a document
    /// can't forge a slot reference.
    private static func stripSlotMarkers(_ s: String) -> String {
        guard s.contains(slotOpen) || s.contains(slotClose) else { return s }
        return String(s.map { $0 == slotOpen || $0 == slotClose ? "\u{FFFD}" : $0 })
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Block-level parser
    // ─────────────────────────────────────────────────────────────────────

    /// Blockquotes nest this deep; further `>` markers are shown as text. Each level
    /// is one more recursion of `parseBlocks` (and one more pass over its lines): the
    /// reader renders on a GCD queue with a small stack, where a line of ~1,500 `>`
    /// crashed the app.
    static let maxBlockquoteDepth = 32

    private static func parseBlocks(_ md: String, ctx: inout Context, depth: Int = 0) -> String {
        let lines = md.components(separatedBy: "\n")
        let quotesAllowed = depth < maxBlockquoteDepth
        var out   = ""
        var i     = 0

        while i < lines.count {
            let line = lines[i]
            let trim = line.trimmingCharacters(in: .whitespaces)

            if trim.isEmpty { i += 1; continue }

            // Fenced code block
            let fenceSeq: String? = line.hasPrefix("```") ? "```"
                                  : line.hasPrefix("~~~") ? "~~~" : nil
            if let fence = fenceSeq {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix(fence) {
                    body.append(escapeHTML(lines[i])); i += 1
                }
                if i < lines.count { i += 1 }
                let cls = lang.isEmpty ? "" : " class=\"language-\(escapeHTML(lang))\""
                out += "<pre><code\(cls)>\(body.joined(separator: "\n"))</code></pre>\n"
                continue
            }

            // ATX heading
            if let (lvl, txt) = atxHeading(trim) {
                out += "<h\(lvl) id=\"\(ctx.headingID(for: txt))\">\(parseInline(txt, ctx: &ctx))</h\(lvl)>\n"
                i += 1; continue
            }

            // Horizontal rule
            if isHR(trim) { out += "<hr>\n"; i += 1; continue }

            // Blockquote
            if quotesAllowed, line.hasPrefix(">") {
                var bqLines: [String] = []
                while i < lines.count &&
                      (lines[i].hasPrefix(">") ||
                       lines[i].trimmingCharacters(in: .whitespaces).isEmpty) {
                    let l = lines[i]
                    if l.hasPrefix("> ")     { bqLines.append(String(l.dropFirst(2))) }
                    else if l.hasPrefix(">") { bqLines.append(String(l.dropFirst())) }
                    else                     { bqLines.append("") }
                    i += 1
                }
                out += "<blockquote>\(parseBlocks(bqLines.joined(separator: "\n"), ctx: &ctx, depth: depth + 1))</blockquote>\n"
                continue
            }

            // Unordered list
            if isULItem(line) {
                out += "<ul>\n"
                while i < lines.count && isULItem(lines[i]) {
                    out += "  <li>\(parseInline(String(lines[i].dropFirst(2)), ctx: &ctx))</li>\n"; i += 1
                }
                out += "</ul>\n"; continue
            }

            // Ordered list
            if isOLItem(line) {
                out += "<ol>\n"
                while i < lines.count && isOLItem(lines[i]) {
                    let content = lines[i].replacingOccurrences(
                        of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
                    out += "  <li>\(parseInline(content, ctx: &ctx))</li>\n"; i += 1
                }
                out += "</ol>\n"; continue
            }

            // Table
            if trim.contains("|"), i + 1 < lines.count, isSepRow(lines[i + 1]) {
                let headers = tableRow(line); i += 2
                out += "<table>\n<thead>\n<tr>"
                for h in headers { out += "<th>\(parseInline(h, ctx: &ctx))</th>" }
                out += "</tr>\n</thead>\n<tbody>\n"
                while i < lines.count, lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    out += "<tr>"
                    for c in tableRow(lines[i]) { out += "<td>\(parseInline(c, ctx: &ctx))</td>" }
                    out += "</tr>\n"; i += 1
                }
                out += "</tbody>\n</table>\n"; continue
            }

            // Paragraph
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i]; let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if atxHeading(t) != nil || isHR(t) { break }
                if l.hasPrefix("```") || l.hasPrefix("~~~") { break }
                // Past the quote cap a ">" line is text: breaking here would never advance.
                if isULItem(l) || isOLItem(l) || (quotesAllowed && l.hasPrefix(">")) { break }
                if i + 1 < lines.count {
                    let nxt = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if !nxt.isEmpty && nxt.allSatisfy({ $0 == "=" }) {
                        out += "<h1 id=\"\(ctx.headingID(for: t))\">\(parseInline(t, ctx: &ctx))</h1>\n"
                        i += 2; paraLines = []; break
                    }
                    if !nxt.isEmpty && nxt.count >= 2 && nxt.allSatisfy({ $0 == "-" }) {
                        out += "<h2 id=\"\(ctx.headingID(for: t))\">\(parseInline(t, ctx: &ctx))</h2>\n"
                        i += 2; paraLines = []; break
                    }
                }
                paraLines.append(l); i += 1
            }
            if !paraLines.isEmpty {
                out += "<p>\(parseInline(paraLines.joined(separator: "\n"), ctx: &ctx))</p>\n"
            }
        }
        return out
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Inline formatter
    // ─────────────────────────────────────────────────────────────────────

    /// Emphasis rules, compiled once (they used to be compiled for every inline run,
    /// e.g. every table cell). Underscore content can't contain the delimiter run
    /// itself: with a lazy `.+?`, every `__` opener whose closers were all followed by
    /// a letter (" __a __a …") scanned to the end of the line, which was quadratic.
    /// Each opener now stops at the next run, so the scan is linear.
    private static let emphasisRules: [(NSRegularExpression, String)] = [
        (#"\*\*\*(.+?)\*\*\*"#,                                 "<strong><em>$1</em></strong>"),
        (#"(?<![A-Za-z0-9])___([^_\n]+(?:__?[^_\n]+)*)___(?![A-Za-z0-9])"#, "<strong><em>$1</em></strong>"),
        (#"\*\*(.+?)\*\*"#,                                     "<strong>$1</strong>"),
        (#"(?<![A-Za-z0-9])__([^_\n]+(?:_[^_\n]+)*)__(?![A-Za-z0-9])"#, "<strong>$1</strong>"),
        (#"\*([^*\n]+)\*"#,                                     "<em>$1</em>"),
        (#"(?<![A-Za-z0-9])_([^_\n]+)_(?![A-Za-z0-9])"#,        "<em>$1</em>"),
        (#"~~(.+?)~~"#,                                         "<del>$1</del>"),
    ].compactMap { pattern, template in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }

    private static func parseInline(_ raw: String, ctx: inout Context, allowLinks: Bool = true) -> String {
        let c = Array(raw)
        // Bracket, paren and `>` positions are found once per run, so every `[` or
        // `<` is a lookup instead of a scan to the end (which made unmatched ones
        // quadratic: 32k `[` took seconds).
        let marks = InlineMarks(c)
        var backtickRuns = BacktickRuns(c)
        var slots: [String] = []
        var s = ""
        func slot(_ html: String) {
            s.append(slotOpen); s += String(slots.count); s.append(slotClose)
            slots.append(html)
        }

        var i = 0
        while i < c.count {
            let ch = c[i]

            // Backslash escape of ASCII punctuation, or a backslash hard break.
            if ch == "\\", i + 1 < c.count {
                if c[i + 1] == "\n" { slot("<br>\n"); i += 2; continue }
                if isASCIIPunctuation(c[i + 1]) { slot(escapeHTML(String(c[i + 1]))); i += 2; continue }
            }

            // Hard line break: two or more spaces before a newline. Other runs of
            // spaces are copied whole (checking each space again was quadratic).
            if ch == " " {
                var j = i
                while j < c.count && c[j] == " " { j += 1 }
                if j - i >= 2, j < c.count, c[j] == "\n" { slot("<br>\n"); i = j + 1; continue }
                s += String(repeating: " ", count: j - i); i = j; continue
            }

            // Code span: a run of N backticks closed by a run of exactly N.
            if ch == "`" {
                var n = 0
                while i + n < c.count && c[i + n] == "`" { n += 1 }
                if let close = backtickRuns.closing(from: i + n, length: n) {
                    let inner = String(c[(i + n)..<close]).trimmingCharacters(in: .whitespaces)
                    slot("<code>\(escapeHTML(inner))</code>")
                    i = close + n; continue
                }
                s += String(repeating: "`", count: n); i += n; continue
            }

            // Image: ![alt](dest)
            if ch == "!", i + 1 < c.count, c[i + 1] == "[", let link = parseLink(c, at: i + 1, marks: marks) {
                slot(imageHTML(alt: link.text, dest: link.dest, ctx: &ctx))
                i = link.end; continue
            }

            // Link: [text](dest) — link text may contain code, emphasis and images,
            // but not further links.
            if ch == "[", allowLinks, let link = parseLink(c, at: i, marks: marks) {
                let inner = parseInline(link.text, ctx: &ctx, allowLinks: false)
                if let safe = sanitizedURL(link.dest) {
                    slot("<a href=\"\(escapeHTML(safe))\">\(inner)</a>")
                } else {
                    slot(inner)
                }
                i = link.end; continue
            }

            // Autolink: <https://…>
            if ch == "<", allowLinks, let auto = parseAutolink(c, at: i, marks: marks) {
                slot("<a href=\"\(escapeHTML(auto.url))\">\(escapeHTML(auto.url))</a>")
                i = auto.end; continue
            }

            s.append(ch); i += 1
        }

        // Escape everything that isn't a slot; slot markers and digits are untouched.
        s = escapeHTML(s)

        // Emphasis only ever wraps already-escaped text and opaque slot tokens.
        for (re, tmpl) in emphasisRules {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: tmpl)
        }

        return substituteSlots(s, slots)
    }

    /// Replaces every slot token in one left-to-right pass.
    private static func substituteSlots(_ s: String, _ slots: [String]) -> String {
        guard !slots.isEmpty else { return s }
        var out = ""
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if ch == slotOpen, let close = s[idx...].firstIndex(of: slotClose),
               let n = Int(s[s.index(after: idx)..<close]), slots.indices.contains(n) {
                out += slots[n]
                idx = s.index(after: close)
                continue
            }
            out.append(ch)
            idx = s.index(after: idx)
        }
        return out
    }

    private static func imageHTML(alt: String, dest: String, ctx: inout Context) -> String {
        let altHTML = escapeHTML(plainText(alt))
        guard var safe = sanitizedURL(dest) else { return altHTML }
        if isRemote(safe) {
            ctx.sawRemoteImage = true
            guard ctx.allowRemoteImages else {
                let label = altHTML.isEmpty
                    ? escapeHTML(NSLocalizedString("image", comment: "Fallback alternate text for a remote image without a label"))
                    : altHTML
                let title = escapeHTML(NSLocalizedString("Remote image blocked", comment: "Tooltip for a blocked remote image in a Markdown document"))
                return "<span class=\"selway-remote-img\" title=\"\(title)\">\(label)</span>"
            }
            if safe.hasPrefix("//") { safe = "https:" + safe }
        } else if let folder = ctx.imageFolder {
            // A file: served by the reader from its own scheme (see MarkdownLocalImages).
            guard let file = MarkdownLocalImages.resolve(safe, relativeTo: folder),
                  ctx.localImages.contains(file.path)
                    || ctx.localImages.count < MarkdownLocalImages.maxImagesPerDocument
            else { return altHTML }
            ctx.localImages.insert(file.path)
            safe = MarkdownLocalImages.pageURL(for: file)
        }
        return "<img src=\"\(escapeHTML(safe))\" alt=\"\(altHTML)\">"
    }

    /// Alt text is plain text: drop image/link syntax, keep the readable parts.
    private static func plainText(_ s: String) -> String {
        s.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    }

    // MARK: Inline scanning helpers

    private struct LinkMatch { let text: String; let dest: String; let end: Int }

    /// Where each `[` and `(` closes (with nesting, honouring backslash escapes) and
    /// where the next `>`, `<` and whitespace are, computed in one pass per inline run.
    private struct InlineMarks {
        /// For an opening `[` or `(`: the index of its matching closer, else -1.
        var closer: [Int]
        /// Smallest index ≥ i holding `>` / `<` / whitespace (c.count when none).
        var nextGT: [Int]
        var nextLT: [Int]
        var nextSpace: [Int]

        init(_ c: [Character]) {
            closer = [Int](repeating: -1, count: c.count)
            var brackets: [Int] = [], parens: [Int] = []
            var j = 0
            while j < c.count {
                switch c[j] {
                case "\\": j += 2; continue
                case "[": brackets.append(j)
                case "]": if let open = brackets.popLast() { closer[open] = j }
                case "(": parens.append(j)
                case ")": if let open = parens.popLast() { closer[open] = j }
                default: break
                }
                j += 1
            }
            nextGT = [Int](repeating: c.count, count: c.count + 1)
            nextLT = nextGT
            nextSpace = nextGT
            for k in stride(from: c.count - 1, through: 0, by: -1) {
                nextGT[k] = c[k] == ">" ? k : nextGT[k + 1]
                nextLT[k] = c[k] == "<" ? k : nextLT[k + 1]
                nextSpace[k] = c[k].isWhitespace ? k : nextSpace[k + 1]
            }
        }
    }

    /// Parses `[text](dest "optional title")` starting at the `[` at `start`.
    private static func parseLink(_ c: [Character], at start: Int, marks: InlineMarks) -> LinkMatch? {
        guard start < c.count, c[start] == "[" else { return nil }
        let cb = marks.closer[start]
        guard cb >= 0, cb + 1 < c.count, c[cb + 1] == "(" else { return nil }
        let cp = marks.closer[cb + 1]
        guard cp >= 0 else { return nil }

        let inside = String(c[(cb + 2)..<cp]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dest = linkDestination(inside) else { return nil }
        return LinkMatch(text: String(c[(start + 1)..<cb]), dest: dest, end: cp + 1)
    }

    /// Splits `dest "title"` / `<dest with spaces> 'title'`; nil if malformed.
    private static func linkDestination(_ inside: String) -> String? {
        var dest: String
        var rest: Substring
        if inside.hasPrefix("<") {
            guard let close = inside.firstIndex(of: ">") else { return nil }
            dest = String(inside[inside.index(after: inside.startIndex)..<close])
            if dest.contains("\n") || dest.contains("<") { return nil }
            rest = inside[inside.index(after: close)...]
        } else {
            let end = inside.firstIndex(where: { $0.isWhitespace }) ?? inside.endIndex
            dest = String(inside[..<end])
            rest = inside[end...]
        }
        let title = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            let quoted = title.count >= 2 && (
                (title.first == "\"" && title.last == "\"") ||
                (title.first == "'" && title.last == "'") ||
                (title.first == "(" && title.last == ")"))
            guard quoted else { return nil }
        }
        // Process backslash escapes inside the destination.
        dest = dest.replacingOccurrences(of: #"\\([!-/:-@\[-`{-~])"#, with: "$1", options: .regularExpression)
        return dest
    }

    private static func parseAutolink(_ c: [Character], at start: Int, marks: InlineMarks) -> (url: String, end: Int)? {
        let close = marks.nextGT[start]
        guard close < c.count, close > start + 1,
              marks.nextLT[start + 1] > close, marks.nextSpace[start + 1] > close else { return nil }
        let body = String(c[(start + 1)..<close])
        guard !body.isEmpty, !body.contains(where: { $0.isWhitespace || $0 == "<" }),
              let scheme = urlScheme(body), ["http", "https", "mailto"].contains(scheme),
              let safe = sanitizedURL(body) else { return nil }
        return (safe, close + 1)
    }

    /// The backtick runs of one inline run, indexed by length, so the closer of a code
    /// span is a lookup: scanning ahead for it from every opener was quadratic when no
    /// run closes (runs of all-different lengths). A closer is the next maximal run of
    /// exactly the opener's length; backslashes don't escape inside code spans.
    private struct BacktickRuns {
        private var starts: [Int: [Int]] = [:]
        /// Per length, the first start not yet passed: lookups only move forward.
        private var cursor: [Int: Int] = [:]

        init(_ c: [Character]) {
            var j = 0
            while j < c.count {
                guard c[j] == "`" else { j += 1; continue }
                var m = 0
                while j + m < c.count && c[j + m] == "`" { m += 1 }
                starts[m, default: []].append(j)
                j += m
            }
        }

        /// Start of the first run of exactly `n` backticks at or after `from`.
        /// `from` never decreases between calls (the inline scan only moves right).
        mutating func closing(from: Int, length n: Int) -> Int? {
            guard let list = starts[n] else { return nil }
            var k = cursor[n] ?? 0
            while k < list.count && list[k] < from { k += 1 }
            cursor[n] = k
            return k < list.count ? list[k] : nil
        }
    }

    private static func isASCIIPunctuation(_ ch: Character) -> Bool {
        guard let a = ch.asciiValue else { return false }
        return (0x21...0x2F).contains(a) || (0x3A...0x40).contains(a)
            || (0x5B...0x60).contains(a) || (0x7B...0x7E).contains(a)
    }

    // MARK: URL policy

    /// The scheme of a URL-ish string (lowercased), or nil for relative references.
    static func urlScheme(_ s: String) -> String? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let candidate = s[..<colon]
        guard let first = candidate.first, first.isASCII, first.isLetter,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        return candidate.lowercased()
    }

    /// Allow http(s), mailto, file, fragments and relative paths. Everything else —
    /// `javascript:`, `data:`, `vbscript:`, unknown schemes, and anything with
    /// control characters or whitespace a browser might strip — is dropped.
    static func sanitizedURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "%20")
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.unicodeScalars.contains(where: {
            $0.value < 0x20 || $0.value == 0x7F || CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { return nil }
        if trimmed.hasPrefix("#") { return trimmed }
        if let scheme = urlScheme(trimmed) {
            return ["http", "https", "mailto", "file"].contains(scheme) ? trimmed : nil
        }
        // A colon before any / ? # that isn't a valid scheme (e.g. "java script:")
        // could still be read as a scheme by something; refuse it.
        let head = trimmed.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if head.contains(":") { return nil }
        return trimmed
    }

    static func isRemote(_ url: String) -> Bool {
        if url.hasPrefix("//") { return true }
        guard let scheme = urlScheme(url) else { return false }
        return scheme == "http" || scheme == "https"
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Helpers
    // ─────────────────────────────────────────────────────────────────────

    static func anchor(_ txt: String) -> String {
        txt.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
    }
    private static func atxHeading(_ s: String) -> (Int, String)? {
        var lvl = 0
        for c in s { if c == "#" { lvl += 1 } else { break } }
        guard lvl >= 1, lvl <= 6 else { return nil }
        let rest = String(s.dropFirst(lvl)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : (lvl, rest)
    }
    private static func isHR(_ s: String) -> Bool {
        let c = s.filter { !$0.isWhitespace }
        guard c.count >= 3, let ch = c.first else { return false }
        return (ch == "-" || ch == "*" || ch == "_") && c.allSatisfy { $0 == ch }
    }
    private static func isULItem(_ l: String) -> Bool { l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("+ ") }
    private static func isOLItem(_ l: String) -> Bool { l.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil }
    private static func isSepRow(_ l: String) -> Bool {
        let s = l.trimmingCharacters(in: .whitespaces)
        return s.contains("|") && s.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }
    private static func tableRow(_ l: String) -> [String] {
        var s = l.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s = String(s.dropFirst()) }
        if s.hasSuffix("|") { s = String(s.dropLast()) }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&",  with: "&amp;")
         .replacingOccurrences(of: "<",  with: "&lt;")
         .replacingOccurrences(of: ">",  with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'",  with: "&#39;")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: HTML template  (Obsidian-inspired dark/light)
    // ─────────────────────────────────────────────────────────────────────

    /// Content Security Policy for rendered documents: no scripts, frames, fonts or
    /// fetches; images only from the reader's local-image scheme unless the user
    /// allowed remote ones for this document (remote images reveal to a server that
    /// the file was opened). Never `file:`: local images go through
    /// `MarkdownLocalImages`, which serves only images the document references.
    static func contentSecurityPolicy(allowRemoteImages: Bool) -> String {
        let local = MarkdownLocalImages.scheme + ":"
        let img = allowRemoteImages ? "\(local) http: https:" : local
        return "default-src 'none'; style-src 'unsafe-inline'; img-src \(img); form-action 'none'"
    }

    private static func htmlTemplate(title: String, body: String, allowRemoteImages: Bool,
                                     language: String?) -> String {
        let language = htmlLanguageTag(language ?? currentLocaleLanguageTag())
        let remoteImageLabel = NSLocalizedString("Remote image: ", comment: "Label shown before a blocked remote image in a Markdown document")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return """
        <!DOCTYPE html>
        <html lang="\(escapeHTML(language))">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(allowRemoteImages: allowRemoteImages))">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeHTML(title))</title>
        <style>
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

        :root {
            --bg:      #ffffff;
            --surface: #f6f8fa;
            --border:  #d0d7de;
            --text:    #1f2328;
            --muted:   #57606a;
            --accent:  #0969da;
            --code-fg: #0550ae;
            --code-bg: #f0f2f5;
            --pre-bg:  #f6f8fa;
            --bq-bar:  #0969da;
            --bq-bg:   #ddf4ff;
            --th-bg:   #f0f2f5;
            --del-fg:  #cf222e;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg:      #1e1e2e;
                --surface: #181825;
                --border:  #45475a;
                --text:    #cdd6f4;
                --muted:   #a6adc8;
                --accent:  #89b4fa;
                --code-fg: #a6e3a1;
                --code-bg: #313244;
                --pre-bg:  #181825;
                --bq-bar:  #89b4fa;
                --bq-bg:   rgba(137,180,250,0.08);
                --th-bg:   #181825;
                --del-fg:  #f38ba8;
            }
        }

        html, body { background: var(--bg); color: var(--text);
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            font-size: 16px; line-height: 1.75; }
        body { max-width: 820px; margin: 0 auto; padding: 36px 36px 80px; }
        ::selection { background: rgba(137,180,250,0.35); }

        h1,h2,h3,h4,h5,h6 { font-weight: 650; line-height: 1.3; margin: 1.6em 0 0.5em; }
        h1:first-child,h2:first-child { margin-top: 0; }
        h1 { font-size:2em;   border-bottom: 2px solid var(--border); padding-bottom:.3em; }
        h2 { font-size:1.5em; border-bottom: 1px solid var(--border); padding-bottom:.2em; }
        h3 { font-size:1.25em; } h4 { font-size:1.05em; }
        h5 { font-size:.95em; } h6 { font-size:.875em; color:var(--muted); }

        p { margin:.75em 0; }
        a { color:var(--accent); text-decoration:none; } a:hover { text-decoration:underline; }
        strong { font-weight:700; } em { font-style:italic; }
        del { color:var(--del-fg); text-decoration:line-through; }

        code { font-family:"SF Mono",ui-monospace,"Cascadia Code",Consolas,monospace;
               font-size:.85em; background:var(--code-bg); color:var(--code-fg);
               padding:.15em .4em; border-radius:4px; border:1px solid var(--border); }
        pre { background:var(--pre-bg); border:1px solid var(--border); border-radius:8px;
              padding:18px 20px; overflow-x:auto; margin:1.1em 0; }
        pre code { background:transparent; border:none; padding:0; color:var(--text);
                   font-size:.875em; line-height:1.65; }

        blockquote { border-left:4px solid var(--bq-bar); background:var(--bq-bg);
                     margin:1em 0; padding:10px 18px; border-radius:0 8px 8px 0; }
        blockquote p { margin:0; color:var(--muted); }

        ul,ol { padding-left:1.8em; margin:.75em 0; } li { margin:.3em 0; }
        li > ul, li > ol { margin:.2em 0; }
        hr { border:none; border-top:1px solid var(--border); margin:2em 0; }

        table { border-collapse:collapse; width:100%; margin:1em 0; font-size:.9em;
                display:block; overflow-x:auto; }
        th,td { border:1px solid var(--border); padding:8px 14px; text-align:left; }
        th { background:var(--th-bg); font-weight:650; white-space:nowrap; }
        tr:nth-child(even) td { background:var(--surface); }

        /* Inline, as in Markdown: an image in a sentence stays in the sentence. */
        img { max-width:100%; height:auto; border-radius:8px; vertical-align:middle; }
        .selway-remote-img { display:inline-block; padding:.1em .5em; border:1px dashed var(--border);
                         border-radius:4px; color:var(--muted); font-size:.85em; }
        .selway-remote-img::before { content:"\(remoteImageLabel)"; }
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    private static func currentLocaleLanguageTag() -> String {
        let identifier = Locale.current.identifier
        let baseIdentifier = identifier.split(separator: "@", maxSplits: 1).first?
            .split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        return htmlLanguageTag(baseIdentifier.replacingOccurrences(of: "_", with: "-"))
    }

    private static func htmlLanguageTag(_ language: String) -> String {
        guard !language.isEmpty,
              language.caseInsensitiveCompare("und") != .orderedSame else { return "en" }
        return language
    }
}
