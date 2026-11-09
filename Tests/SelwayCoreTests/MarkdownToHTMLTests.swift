import Foundation
import Testing
@testable import SelwayCore

// MARK: - Helpers

/// Every tag the renderer may emit, in its exact attribute shape. If user input
/// could smuggle an attribute (onerror=, style=, …) or a tag, some tag in the
/// output would fail to match.
private let allowedTag = try! NSRegularExpression(pattern: #"""
^<(?:/?(?:p|strong|em|del|code|pre|ul|ol|li|blockquote|table|thead|tbody|tr|th|td|a|span)|hr|br|h[1-6] id="[a-z0-9-]*"|/h[1-6]|code class="language-[^"<>]*"|a href="[^"<>]*"|img src="[^"<>]*" alt="[^"<>]*"|span class="selway-remote-img" title="Remote image blocked")>$
"""#)

private func disallowedTags(in html: String) -> [String] {
    let tagRe = try! NSRegularExpression(pattern: "<[^>]*>")
    let ns = html as NSString
    return tagRe.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
        let tag = ns.substring(with: m.range)
        let ok = allowedTag.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) != nil
        return ok ? nil : tag
    }
}

private func body(_ md: String, allowRemote: Bool = false, imageFolder: URL? = nil) -> String {
    MarkdownToHTML.renderBody(md, allowRemoteImages: allowRemote, imageFolder: imageFolder)
}

// MARK: - Escaping and injection

private let hostileInputs: [String] = [
    "<script>alert(1)</script>",
    "<img src=x onerror=alert(1)>",
    "**<b onclick=alert(1)>x</b>**",
    "![x](http://a/[y](http://b\" onerror=\"alert(1)))",
    "![a\" onerror=\"alert(1)](pic.png)",
    "[a](x.md\" onmouseover=\"alert(1))",
    "[![x](a.png \"t\")](\" onclick=\"alert(1))",
    "![x](a.png\"onerror=alert(1)//)",
    "[x](<a.md\" onclick=\"y>)",
    "`code` <i>![a](b.png)</i> [l](u.md)",
    "<https://x.com/\"onmouseover=alert(1)>",
    "| a | b |\n|---|---|\n| <script> | ![i](\"x.png) |",
    "# Heading <svg onload=alert(1)>",
    "```js\" onclick=\"x\n<script>\n```",
    "> quote <iframe src=//evil>",
    "\u{FFFE}0\u{FFFF}[a](b.md)",
]

@Test(arguments: hostileInputs)
func rendererEmitsOnlyAllowlistedTags(md: String) {
    for allow in [false, true] {
        for folder in [nil, URL(fileURLWithPath: "/Users/me/Notes")] {
            let html = body(md, allowRemote: allow, imageFolder: folder)
            #expect(disallowedTags(in: html).isEmpty, "\(html)")
            #expect(!html.lowercased().contains("<script"))
        }
    }
}

@Test func scriptTagsAreEscaped() {
    #expect(body("<script>alert('x')</script>") ==
            "<p>&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;</p>\n")
}

@Test func codeSpansAreEscapedAndOpaque() {
    #expect(body("`<b>` and `[a](b.md)`") ==
            "<p><code>&lt;b&gt;</code> and <code>[a](b.md)</code></p>\n")
    #expect(body("``a ` b``") == "<p><code>a ` b</code></p>\n")
}

@Test func imageNestedInImageURLCannotInjectAttributes() {
    let html = body("![x](http://a/[y](http://b\" onerror=\"alert(1)))", allowRemote: true)
    #expect(!html.contains("\" onerror"))
    #expect(!html.contains("onerror=\""))
    #expect(disallowedTags(in: html).isEmpty)
}

// MARK: - URL policy

@Test(arguments: [
    "javascript:alert(1)",
    "JaVaScRiPt:alert(1)",
    " javascript:alert(1)",
    "java\tscript:alert(1)",
    "data:text/html,<script>alert(1)</script>",
    "DATA:image/svg+xml;base64,AAAA",
    "vbscript:msgbox",
    "java script:alert(1)",
    "x-unknown:thing",
])
func dangerousLinksAreDropped(url: String) {
    let html = body("[click](\(url))")
    #expect(!html.contains("<a "), "\(html)")
    #expect(html.contains("click"))
    let img = body("![pic](\(url))", allowRemote: true)
    #expect(!img.contains("<img"), "\(img)")
}

@Test(arguments: [
    ("[a](https://x.com/?q=1&r=2)",  "<a href=\"https://x.com/?q=1&amp;r=2\">a</a>"),
    ("[a](notes.md)",                "<a href=\"notes.md\">a</a>"),
    ("[a](../up/notes.md#part)",     "<a href=\"../up/notes.md#part\">a</a>"),
    ("[a](#section)",                "<a href=\"#section\">a</a>"),
    ("[a](mailto:me@example.com)",   "<a href=\"mailto:me@example.com\">a</a>"),
    ("[a](https://x.com \"Title\")", "<a href=\"https://x.com\">a</a>"),
    ("[a](<my file.md>)",            "<a href=\"my%20file.md\">a</a>"),
    ("[a](https://en.wikipedia.org/wiki/Foo_(bar))",
     "<a href=\"https://en.wikipedia.org/wiki/Foo_(bar)\">a</a>"),
    ("<https://x.com/a?b=1&c=2>",    "<a href=\"https://x.com/a?b=1&amp;c=2\">https://x.com/a?b=1&amp;c=2</a>"),
])
func linksAreEscapedExactlyOnce(md: String, expected: String) {
    #expect(body(md) == "<p>\(expected)</p>\n")
}

@Test func ampersandInImageURLIsEscapedOnce() {
    #expect(body("![a](pic.png?w=1&h=2)") == "<p><img src=\"pic.png?w=1&amp;h=2\" alt=\"a\"></p>\n")
}

@Test func imageInsideLinkRenders() {
    #expect(body("[![badge](ci.svg)](https://ci.example.com)") ==
            "<p><a href=\"https://ci.example.com\"><img src=\"ci.svg\" alt=\"badge\"></a></p>\n")
}

@Test func linkTextKeepsEmphasis() {
    #expect(body("[**bold** `c`](a.md)") ==
            "<p><a href=\"a.md\"><strong>bold</strong> <code>c</code></a></p>\n")
}

// MARK: - Remote images

@Test func remoteImagesAreBlockedByDefault() {
    let doc = MarkdownToHTML.renderDocument("![logo](https://example.com/logo.png)", title: "t")
    #expect(doc.hasRemoteImages)
    #expect(!doc.html.contains("<img"))
    #expect(doc.html.contains("selway-remote-img"))
    #expect(doc.html.contains("img-src selwayimg:;"))
    #expect(!doc.html.contains("http: https:"))
    #expect(!doc.html.contains("file:"), "the page may load no file: URLs")
}

@Test func remoteImagesLoadWhenAllowed() {
    let doc = MarkdownToHTML.renderDocument("![logo](//cdn.example.com/a.png)", title: "t", allowRemoteImages: true)
    #expect(doc.hasRemoteImages)
    #expect(doc.html.contains("<img src=\"https://cdn.example.com/a.png\" alt=\"logo\">"))
    #expect(doc.html.contains("img-src selwayimg: http: https:;"))
}

@Test func localImagesAreNotRemote() {
    let doc = MarkdownToHTML.renderDocument("![a](img/a.png) ![b](file:///tmp/b.png)", title: "t")
    #expect(!doc.hasRemoteImages)
    #expect(doc.html.contains("<img src=\"img/a.png\" alt=\"a\">"))
}

// MARK: - Local images

/// WebKit gives a page loaded from an HTML string no file access, so relative
/// images showed as broken ones. They load from the reader's selwayimg: scheme, which
/// serves only the files listed in `localImages`.
@Test func localImagesLoadFromTheReadersSchemeRelativeToTheDocument() {
    let folder = URL(fileURLWithPath: "/Users/me/Notes")
    let md = "![pic](Docs/pic.png) ![up](../img/a%20b.png) ![abs](file:///tmp/c.png) ![r](https://x.com/y.png)"
    let doc = MarkdownToHTML.renderDocument(md, title: "t", imageFolder: folder)
    #expect(doc.html.contains("<img src=\"selwayimg://local/Users/me/Notes/Docs/pic.png\" alt=\"pic\">"))
    #expect(doc.html.contains("<img src=\"selwayimg://local/Users/me/img/a%20b.png\" alt=\"up\">"))
    #expect(doc.html.contains("<img src=\"selwayimg://local/tmp/c.png\" alt=\"abs\">"))
    #expect(doc.localImages == ["/Users/me/Notes/Docs/pic.png", "/Users/me/img/a b.png", "/tmp/c.png"])
    #expect(doc.hasRemoteImages, "remote images are still only counted, and blocked")
    #expect(doc.html.contains("selway-remote-img"))
    #expect(doc.html.contains("img-src selwayimg:;"))
    #expect(!doc.html.contains("file:"))
}

/// A document can reference at most `maxImagesPerDocument` distinct local files;
/// later ones show their alt text. Repeats of one reference don't count again.
@Test func localImagesPerDocumentAreCapped() {
    let folder = URL(fileURLWithPath: "/n")
    let cap = MarkdownLocalImages.maxImagesPerDocument
    let many = (0..<(cap + 50)).map { "![alt\($0)](p\($0).png)" }.joined(separator: "\n\n")
    let doc = MarkdownToHTML.renderDocument(many, title: "t", imageFolder: folder)
    #expect(doc.localImages.count == cap)
    #expect(doc.html.components(separatedBy: "<img ").count - 1 == cap)
    #expect(doc.html.contains("<p>alt\(cap + 49)</p>"))

    let repeated = Array(repeating: "![same](same.png)", count: cap + 50).joined(separator: " ")
    let again = MarkdownToHTML.renderDocument(repeated, title: "t", imageFolder: folder)
    #expect(again.localImages == ["/n/same.png"])
    #expect(again.html.components(separatedBy: "<img ").count - 1 == cap + 50)
}

@Test func unresolvableLocalImagesShowTheirAltText() {
    let doc = MarkdownToHTML.renderDocument("![a map](file://server/share/m.png)", title: "t",
                                            imageFolder: URL(fileURLWithPath: "/Users/me"))
    #expect(!doc.html.contains("<img"))
    #expect(doc.html.contains("a map"))
    #expect(doc.localImages.isEmpty)
}

/// `![pic](Docs/pic.png).` rendered the image on its own line and the "." on the
/// next: the stylesheet made every image a block.
@Test func imagesStayInlineInTheirSentence() throws {
    let folder = URL(fileURLWithPath: "/n")
    #expect(body("See ![pic](Docs/pic.png).", imageFolder: folder) ==
            "<p>See <img src=\"selwayimg://local/n/Docs/pic.png\" alt=\"pic\">.</p>\n")
    let html = MarkdownToHTML.render("x", title: "t")
    let imgRule = try #require(html.components(separatedBy: "\n")
        .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("img {") })
    #expect(!imgRule.replacingOccurrences(of: " ", with: "").contains("display:block"), "\(imgRule)")
}

@Test func templateHasStrictCSP() {
    let html = MarkdownToHTML.render("x", title: "<T>")
    #expect(html.contains("http-equiv=\"Content-Security-Policy\""))
    #expect(html.contains("default-src 'none'"))
    #expect(html.contains("<title>&lt;T&gt;</title>"))
}

@Test func templateUsesTheDocumentLanguage() {
    let french = MarkdownToHTML.render("x", title: "t", language: "fr-CA")
    #expect(french.contains("<html lang=\"fr-CA\">"))

    let fallback = MarkdownToHTML.render("x", title: "t", language: "und")
    #expect(fallback.contains("<html lang=\"en\">"))
}

// MARK: - Formatting

@Test(arguments: [
    ("a & b",               "<p>a &amp; b</p>\n"),
    ("snake_case_name",     "<p>snake_case_name</p>\n"),
    ("_it_ and *it*",       "<p><em>it</em> and <em>it</em></p>\n"),
    ("**b** __b__ ~~d~~",   "<p><strong>b</strong> <strong>b</strong> <del>d</del></p>\n"),
    ("__a _b_ c__",         "<p><strong>a <em>b</em> c</strong></p>\n"),
    ("___a__b___ x",        "<p><strong><em>a__b</em></strong> x</p>\n"),
    ("\\*not em\\*",        "<p>*not em*</p>\n"),
    ("line one  \nline two", "<p>line one<br>\nline two</p>\n"),
    ("# Title *x*",         "<h1 id=\"title-x\">Title <em>x</em></h1>\n"),
    ("[not a link] (x)",    "<p>[not a link] (x)</p>\n"),
])
func inlineFormatting(md: String, expected: String) {
    #expect(body(md) == expected)
}

@Test func forgedSlotMarkersAreNeutralised() {
    let html = body("\u{FFFE}0\u{FFFF} `x`")
    #expect(html == "<p>\u{FFFD}0\u{FFFD} <code>x</code></p>\n")
}

// MARK: - Block golden output

@Test func unorderedAndOrderedLists() {
    #expect(body("- one\n* two *em*\n+ three\n\n1. first\n2. `second`\n") == """
    <ul>
      <li>one</li>
      <li>two <em>em</em></li>
      <li>three</li>
    </ul>
    <ol>
      <li>first</li>
      <li><code>second</code></li>
    </ol>

    """)
}

@Test func tablesRenderHeaderAndRows() {
    #expect(body("| Name | Size |\n|:-----|-----:|\n| a.txt | **1 KB** |\n| b | 2 |\n\nafter") == """
    <table>
    <thead>
    <tr><th>Name</th><th>Size</th></tr>
    </thead>
    <tbody>
    <tr><td>a.txt</td><td><strong>1 KB</strong></td></tr>
    <tr><td>b</td><td>2</td></tr>
    </tbody>
    </table>
    <p>after</p>

    """)
}

@Test func fencedCodeIsVerbatimAndEscaped() {
    #expect(body("```swift\nlet a = \"<b>\" && *x*\n\n# not a heading\n```\ntext") == """
    <pre><code class="language-swift">let a = &quot;&lt;b&gt;&quot; &amp;&amp; *x*

    # not a heading</code></pre>
    <p>text</p>

    """)
    // Tildes work too, and an unclosed fence runs to the end of the document.
    #expect(body("~~~\n[a](b)\n") == "<pre><code>[a](b)\n</code></pre>\n")
}

/// Heading ids follow GitHub: slug, then -1, -2 … for repeats, across ATX and
/// setext headings and inside block quotes, never reusing an id already taken.
@Test func duplicateHeadingIdsAreUnique() {
    let md = "# Intro\n## Intro\nIntro\n---\n> ### Intro\n# Intro 1\n# Intro-1\n# !!!\n# ???"
    #expect(body(md) == """
    <h1 id="intro">Intro</h1>
    <h2 id="intro-1">Intro</h2>
    <h2 id="intro-2">Intro</h2>
    <blockquote><h3 id="intro-3">Intro</h3>
    </blockquote>
    <h1 id="intro-1-1">Intro 1</h1>
    <h1 id="intro-1-2">Intro-1</h1>
    <h1 id="section">!!!</h1>
    <h1 id="section-1">???</h1>

    """)
}

@Test func setextHeadingsGetIds() {
    #expect(body("Title\n=====\nSub *x*\n---") == "<h1 id=\"title\">Title</h1>\n<h2 id=\"sub-x\">Sub <em>x</em></h2>\n")
}

// MARK: - Performance on hostile input

/// Unmatched `[`, `(`, `<` and long space runs used to rescan to the end of the
/// paragraph from every position (32k `[` took ~4.5 s, on the main thread, 300 ms
/// after each keystroke). Each case now takes milliseconds; the bound is generous so
/// a slow CI machine doesn't flake, yet far below the old quadratic times.
@Test func hostileInlineInputRendersQuickly() {
    let n = 32_000
    let cases = [
        String(repeating: "[", count: n),
        String(repeating: "![", count: n / 2),
        "[a](" + String(repeating: "(", count: n),
        String(repeating: "<", count: n) + ">",
        String(repeating: " ", count: n) + "x",
        String(repeating: "[", count: n / 2) + String(repeating: "]", count: n / 2),
        // Emphasis openers that never close: each `__`/`___` used to scan to the end
        // of the line looking for a closer not followed by a letter (32k: ~45 s).
        String(repeating: " __a", count: n),
        String(repeating: " ___a", count: n),
        String(repeating: " _a", count: n),
        String(repeating: " ***a", count: n),
        String(repeating: " **a", count: n),
        String(repeating: " *a", count: n),
        String(repeating: " ~~a", count: n),
        "***" + String(repeating: " **a", count: n),
        "~~" + String(repeating: " ~a", count: n),
    ]
    for md in cases {
        let start = Date()
        _ = MarkdownToHTML.renderBody(md)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.5, "\(md.prefix(8))… took \(elapsed) s")
    }
}

/// Each leading ">" was one more level of recursion; the reader renders on a GCD
/// queue (~512 KB of stack), where ~1,500 levels crashed the app. Nesting is capped,
/// so deep input renders, on a background queue, quickly and without crashing.
@Test func deeplyNestedBlockquotesRenderOnABackgroundQueue() {
    let cases = [
        String(repeating: ">", count: 100_000) + " x",
        String(repeating: "> ", count: 50_000) + "x",
        String(repeating: ">", count: 2_000) + " a\n" + String(repeating: ">", count: 2_000) + " b",
        String(repeating: "- >", count: 20_000) + " x",
        (0..<5_000).map { String(repeating: ">", count: $0 % 64) + " line" }.joined(separator: "\n"),
    ]
    for md in cases {
        let done = DispatchSemaphore(value: 0)
        let start = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = MarkdownToHTML.renderBody(md)
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 20) == .success, "\(md.prefix(8))… didn't finish")
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5, "\(md.prefix(8))… took \(elapsed) s")
    }
}

/// Quotes up to the cap still nest; deeper markers are shown as text.
@Test func blockquoteNestingIsCapped() {
    #expect(body("> > a") == "<blockquote><blockquote><p>a</p>\n</blockquote>\n</blockquote>\n")
    let deep = body(String(repeating: ">", count: MarkdownToHTML.maxBlockquoteDepth + 3) + " x")
    #expect(deep.components(separatedBy: "<blockquote>").count - 1 == MarkdownToHTML.maxBlockquoteDepth)
    #expect(deep.contains("&gt;&gt;&gt; x"))
}

/// Code-span runs of all-different lengths never close, and each used to scan to
/// the end of the paragraph for a run of its length (2,400 runs, 2.9 MB: seconds,
/// minutes at the 64 MB cap) while later renders waited on the serial queue. The
/// closing run is now looked up in an index built once per inline run: linear in the
/// input (~1.6 s for these 2.9 MB in a debug build; the old scan took ~145 s), so the
/// bound is generous for slow CI machines.
@Test func distinctLengthBacktickRunsRenderQuickly() {
    let md = (1...2_400).map { String(repeating: "`", count: $0) + "a" }.joined()
    let start = Date()
    let html = MarkdownToHTML.renderBody(md)
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 10, "took \(elapsed) s")
    #expect(!html.contains("<code>"))
}

/// The closing run is the next run of exactly the opener's length, longer and
/// shorter runs in between included in the span; a backslash doesn't escape inside.
@Test(arguments: [
    ("`a``b`",          "<p><code>a``b</code></p>\n"),
    ("``a`b``",         "<p><code>a`b</code></p>\n"),
    ("x ```a``b``` `c`", "<p>x <code>a``b</code> <code>c</code></p>\n"),
    ("`a\\`b`",          "<p><code>a\\</code>b`</p>\n"),
    ("``a` `b",         "<p>``a<code></code>b</p>\n"),
    ("\\``a`",           "<p>`<code>a</code></p>\n"),
])
func codeSpanClosingRuns(md: String, expected: String) {
    #expect(body(md) == expected)
}

@Test func linkMatchingStillHonoursNestingAndEscapes() {
    #expect(body("[a [b] c](x.md)") == "<p><a href=\"x.md\">a [b] c</a></p>\n")
    #expect(body("[a](x_(1).md)") == "<p><a href=\"x_(1).md\">a</a></p>\n")
    #expect(body("[a\\]](x.md)") == "<p><a href=\"x.md\">a]</a></p>\n")
    #expect(body("[[a](x.md)") == "<p>[<a href=\"x.md\">a</a></p>\n")
    #expect(body("<https://a.b/c> <not a link> <x") ==
            "<p><a href=\"https://a.b/c\">https://a.b/c</a> &lt;not a link&gt; &lt;x</p>\n")
}
