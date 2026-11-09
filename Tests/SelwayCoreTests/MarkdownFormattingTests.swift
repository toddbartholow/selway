import Foundation
import Testing
@testable import SelwayCore

// Cases are written with the selection marked as «…» (an empty «» is the caret),
// both for the input and for the expected text + selection after the edit.

private func parse(_ marked: String) -> (String, NSRange) {
    let ns = marked as NSString
    let open = ns.range(of: "«").location
    let close = ns.range(of: "»").location
    precondition(open != NSNotFound && close != NSNotFound && open < close, "missing «» in \(marked)")
    let text = marked.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
    return (text, NSRange(location: open, length: close - open - 1))
}

private func mark(_ text: String, _ sel: NSRange) -> String {
    let ns = NSMutableString(string: text)
    ns.insert("»", at: sel.location + sel.length)
    ns.insert("«", at: sel.location)
    return ns as String
}

private func run(_ op: (String, NSRange) -> MarkdownEdit, _ marked: String) -> String {
    let (text, sel) = parse(marked)
    let edit = op(text, sel)
    return mark(edit.applied(to: text), edit.selection)
}

private typealias Op = (String, NSRange) -> MarkdownEdit

// MARK: - Inline wrap

@Test(arguments: [
    ("«»",              "**«»**"),
    ("a «x» b",         "a **«x»** b"),
    ("«**x**»",         "«x»"),
    ("**«x»**",         "«x»"),
    ("**«»**",          "«»"),
    ("«***x***»",       "«*x*»"),
    ("«x **y** z»",     "**«x **y** z»**"),
    ("🙂«🙂»🙂",           "🙂**«🙂»**🙂"),
])
func boldToggles(input: String, expected: String) {
    #expect(run(MarkdownFormatting.bold, input) == expected)
}

@Test(arguments: [
    ("«x»",       "*«x»*"),
    ("«*x*»",     "«x»"),
    ("*«x»*",     "«x»"),
    ("«**x**»",   "*«**x**»*"),   // bold isn't italic: wrap, don't strip one star
    ("**«x»**",   "***«x»***"),
    ("«***x***»", "«**x**»"),
])
func italicDistinguishesBold(input: String, expected: String) {
    #expect(run(MarkdownFormatting.italic, input) == expected)
}

@Test func strikeAndCodeToggle() {
    #expect(run(MarkdownFormatting.strikethrough, "«x»") == "~~«x»~~")
    #expect(run(MarkdownFormatting.strikethrough, "«~~x~~»") == "«x»")
    #expect(run(MarkdownFormatting.inlineCode, "a«»b") == "a`«»`b")
    #expect(run(MarkdownFormatting.inlineCode, "`«x»`") == "«x»")
}

// MARK: - Link

@Test(arguments: [
    ("«»",               "[link text](«https://»)"),
    ("see «docs»",       "see [docs](«https://»)"),
    ("👍 «hi» 👍",          "👍 [hi](«https://») 👍"),
    ("«👩‍💻 team»",         "[👩‍💻 team](«https://»)"),
])
func linkSelectsURLByUTF16(input: String, expected: String) {
    #expect(run({ MarkdownFormatting.link($0, $1, url: "https://") }, input) == expected)
}

// MARK: - Headings

@Test(arguments: [
    (2, "# Title«»",          "## Title«»"),
    (2, "## Title«»",         "Title«»"),
    (1, "## Ti«»tle",         "# Ti«»tle"),
    (3, "Ti«»tle",            "### Ti«»tle"),
    (1, "«»",                 "# «»"),
    (2, "«# A\n### B»",       "«## A\n## B»"),
    (2, "«## A\n## B»",       "«A\nB»"),
    (1, "#hashtag«»",         "# #hashtag«»"),
    (1, "a\r\nb«»\r\nc",      "a\r\n# b«»\r\nc"),
])
func headingSwitchesLevel(level: Int, input: String, expected: String) {
    #expect(run({ MarkdownFormatting.heading($0, $1, level: level) }, input) == expected)
}

// MARK: - Lists and quotes

@Test(arguments: [
    ("«a\n\nb»",            "«1. a\n\n2. b»"),
    ("«a\nb\nc»",           "«1. a\n2. b\n3. c»"),
    ("«1. a\n2. b»",        "«a\nb»"),
    ("«- a\n- b»",          "«1. a\n2. b»"),
    ("«a\r\nb\r\n»c",       "«1. a\r\n2. b»\r\nc"),
    ("x«»",                 "1. x«»"),
])
func numberedListSkipsBlankLines(input: String, expected: String) {
    #expect(run(MarkdownFormatting.numberedList, input) == expected)
}

@Test(arguments: [
    ("«a\nb»",              "«- a\n- b»"),
    ("«- a\n* b»",          "«a\nb»"),
    ("«1. a\n2) b»",        "«- a\n- b»"),
    ("  in«»dented",        "  - in«»dented"),
    ("«a\r\nb»",            "«- a\r\n- b»"),
])
func bulletList(input: String, expected: String) {
    #expect(run(MarkdownFormatting.bulletList, input) == expected)
}

@Test(arguments: [
    ("«a\nb»",              "«> a\n> b»"),
    ("«> a\n>b»",           "«a\nb»"),
    ("«a\n\nb»",            "«> a\n\n> b»"),
])
func quoteToggles(input: String, expected: String) {
    #expect(run(MarkdownFormatting.quote, input) == expected)
}

// MARK: - Horizontal rule

@Test(arguments: [
    ("«»",               "---\n«»"),
    ("«»Hello",          "---\n«»Hello"),
    ("Hello«»",          "Hello\n\n---\n«»"),
    ("Hello\n«»",        "Hello\n\n---\n«»"),
    ("Hello\n\n«»",      "Hello\n\n---\n«»"),
    ("a\n«»\nb",         "a\n\n---«»\nb"),
    ("a\r\nb«»",         "a\r\nb\r\n\r\n---\r\n«»"),
])
func horizontalRuleStaysARule(input: String, expected: String) {
    #expect(run(MarkdownFormatting.horizontalRule, input) == expected)
}

// MARK: - Code fence

@Test(arguments: [
    ("«»",               "```\n«»\n```"),
    ("«a\nb\n»c",        "```\n«a\nb»\n```\nc"),
    ("say «x» now",      "say \n```\n«x»\n```\n now"),
    ("«a\r\nb»",         "```\r\n«a\r\nb»\r\n```"),
])
func codeFenceOnOwnLines(input: String, expected: String) {
    #expect(run(MarkdownFormatting.codeFence, input) == expected)
}

// MARK: - Robustness

@Test func outOfRangeSelectionIsClamped() {
    let edit = MarkdownFormatting.bold("abc", NSRange(location: 10, length: 5))
    #expect(edit.applied(to: "abc") == "abc****")
}
