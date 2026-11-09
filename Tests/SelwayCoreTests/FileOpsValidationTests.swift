import Foundation
import Testing
@testable import SelwayCore

@Test(arguments: [
    ("", FileOpsNameError.empty),
    ("   ", .empty),
    ("\n", .empty),
    (".", .reserved),
    ("..", .reserved),
    ("a/b", .containsSlash),
    ("../x", .containsSlash),
    ("/", .containsSlash),
    ("a:b", .containsColon),
    (" leading", .surroundingWhitespace),
    ("trailing ", .surroundingWhitespace),
    ("tab\there", .controlCharacter),
    ("line\nbreak", .controlCharacter),
    ("esc\u{1B}[31m", .controlCharacter),
    ("del\u{7F}", .controlCharacter),
    ("c1\u{85}", .controlCharacter),
    ("csi\u{9B}", .controlCharacter),
    ("nul\u{0}", .controlCharacter),
    ("photo\u{202E}gpj.app", .bidiControl),
    (String(repeating: "é", count: 128), .tooLong),
])
func fileOpsRejectsBadNames(name: String, error: FileOpsNameError) {
    #expect(throws: error) { try FileOpsNameValidation.validate(name) }
}

@Test(arguments: ["a.txt", ".gitignore", "...", "a..b", "New Folder", "café", "x copy 2.txt",
                  "R&D = 100% #1 + more", String(repeating: "a", count: 255), "日本語のフォルダ"])
func fileOpsAcceptsGoodNames(name: String) throws {
    try FileOpsNameValidation.validate(name)
}

@Test(arguments: ["", "a/b", "nested/deeper/folder", "..", "bad\nname"])
func fileOpsCreateRefusesInvalidNamesWithoutSideEffects(name: String) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selway-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(throws: FileOpsNameError.self) { try FileOpsCreation.createFolder(in: dir, named: name) }
    #expect(throws: FileOpsNameError.self) { try FileOpsCreation.createFile(in: dir, named: name) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("bad\nname").path))
}

@Test func fileOpsCreateUsesFreeNamesAndNeverTruncates() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("selway-\(UUID())")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let f1 = try FileOpsCreation.createFolder(in: dir, named: "New Folder")
    let f2 = try FileOpsCreation.createFolder(in: dir, named: "new folder")
    #expect(f1.lastPathComponent == "New Folder")
    #expect(f2.lastPathComponent == "new folder 2")

    let existing = dir.appendingPathComponent("notes.txt")
    try Data("keep me".utf8).write(to: existing)
    let created = try FileOpsCreation.createFile(in: dir, named: "notes.txt")
    #expect(created.lastPathComponent == "notes 2.txt")
    #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me")
    #expect(try Data(contentsOf: created).isEmpty)
}

@Test func fileOpsRenameValidatesAndNeverReplaces() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("selway-\(UUID())")
    try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
    try Data("A".utf8).write(to: a)
    try Data("B".utf8).write(to: b)

    #expect(throws: FileOpsNameError.containsSlash) { try FileOpsCreation.rename(a, to: "sub/a.txt") }
    #expect(throws: FileOpsNameError.containsSlash) { try FileOpsCreation.rename(a, to: "../a.txt") }
    #expect(throws: (any Error).self) { try FileOpsCreation.rename(a, to: "b.txt") }
    #expect(try String(contentsOf: b, encoding: .utf8) == "B")

    let renamed = try FileOpsCreation.rename(a, to: "c.txt")
    #expect(renamed.lastPathComponent == "c.txt")
    // Case-only rename works on case-insensitive and case-sensitive volumes alike.
    let recased = try FileOpsCreation.rename(renamed, to: "C.txt")
    #expect(try fm.contentsOfDirectory(atPath: dir.path).contains("C.txt"))
    #expect(try String(contentsOf: recased, encoding: .utf8) == "A")
}
