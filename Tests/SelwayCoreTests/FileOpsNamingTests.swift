import Foundation
import Testing
@testable import SelwayCore

@Suite struct DefaultNamesTests {
    @Test func translatedNamesMustBeSafeFileNameComponents() {
        #expect(DefaultNames.safeFileName("", fallback: "English") == "English")
        #expect(DefaultNames.safeFileName("folder/name", fallback: "English") == "English")
        #expect(DefaultNames.safeFileName("folder:name", fallback: "English") == "English")
        #expect(DefaultNames.safeFileName(".hidden", fallback: "English") == "English")
        #expect(DefaultNames.safeFileName("Carpeta nueva ", fallback: "English") == "English")
        #expect(DefaultNames.safeFileName("a\u{202E}b", fallback: "English") == "English")
        #expect(DefaultNames.safeFileName(String(repeating: "é", count: 126), suffix: ".zip", fallback: "English") == "English")
        #expect(DefaultNames.safeFileName("Carpeta nueva", fallback: "English") == "Carpeta nueva")
    }

    @Test func defaultNamesAreValidNames() {
        for name in [DefaultNames.newFolder, DefaultNames.untitledTextFile, DefaultNames.archive + ".zip"] {
            #expect(FileOpsNameValidation.isValid(name), "\(name)")
        }
    }
}

private func taken(_ names: [String]) -> (String) -> Bool {
    let keys = Set(names.map(FileOpsNaming.collisionKey))
    return { keys.contains(FileOpsNaming.collisionKey($0)) }
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selway-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test(arguments: [
    // name, isDirectory, stem, ext
    ("a.txt", false, "a", "txt"),
    ("a.tar.gz", false, "a", "tar.gz"),
    ("A.TAR.GZ", false, "A", "TAR.GZ"),
    (".gitignore", false, ".gitignore", ""),
    (".tar.gz", false, ".tar", "gz"),
    ("Folder.v2", true, "Folder.v2", ""),
    ("Demo.app", true, "Demo", "app"),
    ("My.Lib.framework", true, "My.Lib", "framework"),
    ("Notes.RTFD", true, "Notes", "RTFD"),
    (".app", true, ".app", ""),
    ("noext", false, "noext", ""),
    ("trailing.", false, "trailing.", ""),
    ("Report v1.final draft", false, "Report v1.final draft", ""),
])
func fileOpsSplit(name: String, isDirectory: Bool, stem: String, ext: String) {
    let parts = FileOpsNaming.split(name, isDirectory: isDirectory)
    #expect(parts.stem == stem)
    #expect(parts.ext == ext)
}

@Test(arguments: [
    // name, isDirectory, existing, expected
    ("x.txt", false, [String](), "x.txt"),
    ("x.txt", false, ["x.txt"], "x 2.txt"),
    ("x.txt", false, ["x.txt", "x 2.txt"], "x 3.txt"),
    ("x.txt", false, ["X.TXT"], "x 2.txt"),
    ("x.txt", false, ["x.txt", "X 2.TXT"], "x 3.txt"),
    ("a.tar.gz", false, ["a.tar.gz"], "a 2.tar.gz"),
    (".gitignore", false, [".gitignore"], ".gitignore 2"),
    ("Folder.v2", true, ["Folder.v2"], "Folder.v2 2"),
    ("New Folder", true, ["new folder"], "New Folder 2"),
    ("café.txt", false, ["cafe\u{301}.txt"], "café 2.txt"),
    // Continuing a numbered name, as Finder does.
    ("x 2.txt", false, ["x 2.txt"], "x 3.txt"),
    ("x 2.txt", false, ["x 2.txt", "x 3.txt"], "x 4.txt"),
    ("Folder 9", true, ["Folder 9"], "Folder 10"),
    ("x 1.txt", false, ["x 1.txt"], "x 1 2.txt"),
    ("Report 2024.pdf", false, ["Report 2024.pdf"], "Report 2024 2.pdf"),
    ("2.txt", false, ["2.txt"], "2 2.txt"),
    // Packages are numbered before their extension so they stay packages.
    ("Demo.app", true, ["Demo.app"], "Demo 2.app"),
    ("Demo 2.app", true, ["Demo.app", "Demo 2.app"], "Demo 3.app"),
])
func fileOpsUniqueName(name: String, isDirectory: Bool, existing: [String], expected: String) {
    #expect(FileOpsNaming.uniqueName(name, isDirectory: isDirectory, isTaken: taken(existing)) == expected)
}

@Test(arguments: [
    ("x.txt", false, ["x.txt"], "x copy.txt"),
    ("x.txt", false, ["x.txt", "x copy.txt"], "x copy 2.txt"),
    ("x.txt", false, ["x.txt", "x copy.txt", "X COPY 2.TXT"], "x copy 3.txt"),
    ("x copy.txt", false, ["x.txt", "x copy.txt"], "x copy 2.txt"),
    ("x copy 2.txt", false, ["x.txt", "x copy.txt", "x copy 2.txt"], "x copy 3.txt"),
    ("a.tar.gz", false, ["a.tar.gz"], "a copy.tar.gz"),
    (".gitignore", false, [".gitignore"], ".gitignore copy"),
    ("Folder.v2", true, ["Folder.v2"], "Folder.v2 copy"),
    ("Demo.app", true, ["Demo.app"], "Demo copy.app"),
    (" copy", false, [" copy"], " copy copy"),
])
func fileOpsDuplicateName(name: String, isDirectory: Bool, existing: [String], expected: String) {
    #expect(FileOpsNaming.duplicateName(name, isDirectory: isDirectory, isTaken: taken(existing)) == expected)
}

@Test func fileOpsUniqueURLSeesDanglingSymlinksAndCase() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("link.txt").path,
                                               withDestinationPath: "/nonexistent-\(UUID())")
    try Data("x".utf8).write(to: dir.appendingPathComponent("Report.PDF"))

    #expect(FileOpsNaming.uniqueURL(in: dir, name: "link.txt", isDirectory: false).lastPathComponent == "link 2.txt")
    #expect(FileOpsNaming.uniqueURL(in: dir, name: "report.pdf", isDirectory: false).lastPathComponent == "report 2.pdf")
    #expect(FileOpsNaming.uniqueURL(in: dir, name: "free.txt", isDirectory: false).lastPathComponent == "free.txt")
    #expect(FileOpsNaming.duplicateURL(for: dir.appendingPathComponent("Report.PDF"), isDirectory: false)
                .lastPathComponent == "Report copy.PDF")
}
