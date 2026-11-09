import Foundation
import Testing

// The code editor's web page (Selway/AceEditor). Its JavaScript document model
// is tested in Node by Tests/EditorPage/selway-editor.test.js, run here when node is
// installed; the page's Content-Security-Policy is checked everywhere.

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let aceFolder = repoRoot.appendingPathComponent("Selway/AceEditor")

private func nodePath() -> String? {
    let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    return dirs.map { "\($0)/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

@Test func editorPageHasStrictCSPAndNoInlineScript() throws {
    let html = try String(contentsOf: aceFolder.appendingPathComponent("editor.html"), encoding: .utf8)
    let cspLine = try #require(html.components(separatedBy: "\n")
        .first { $0.contains("http-equiv=\"Content-Security-Policy\"") })
    for directive in ["default-src 'none'", "script-src 'self';", "connect-src 'none'",
                      "frame-src 'none'", "object-src 'none'", "base-uri 'none'"] {
        #expect(cspLine.contains(directive), "missing \(directive)")
    }
    #expect(!cspLine.contains("unsafe-eval"))
    let scriptSrc = cspLine.components(separatedBy: "script-src").last?.components(separatedBy: ";").first ?? ""
    #expect(!scriptSrc.contains("unsafe-inline"))

    // Every <script> loads a bundled file; none carries inline code.
    let scripts = html.components(separatedBy: "<script").dropFirst()
    #expect(!scripts.isEmpty)
    for tag in scripts {
        let open = tag.prefix { $0 != ">" }
        #expect(open.contains("src=\""), "inline <script\(open)>")
        let afterOpen = tag.drop { $0 != ">" }.dropFirst()
        #expect(afterOpen.hasPrefix("</script>"), "script with inline body")
        let src = open.components(separatedBy: "src=\"").last?.prefix { $0 != "\"" } ?? ""
        #expect(FileManager.default.fileExists(atPath: aceFolder.appendingPathComponent(String(src)).path),
                "\(src) is bundled")
    }
}

@Test(.enabled(if: nodePath() != nil, "needs node"))
func editorPageScriptModel() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: nodePath()!)
    process.arguments = [repoRoot.appendingPathComponent("Tests/EditorPage/selway-editor.test.js").path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(output)")
}
