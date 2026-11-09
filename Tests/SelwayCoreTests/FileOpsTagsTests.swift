import Foundation
import Testing
@testable import SelwayCore

// MARK: - Stored entries

@Test func fileTagParsesStoredEntries() {
    #expect(FileTag(entry: "Project\n2\n0") == FileTag(name: "Project", color: 2))
    #expect(FileTag(entry: "Red\n6") == FileTag(name: "Red", color: 6))
    #expect(FileTag(entry: "Work") == FileTag(name: "Work", color: 0))
    #expect(FileTag(entry: "Work\n0") == FileTag(name: "Work", color: 0))
    // Colours Finder doesn't have, and junk, are no colour.
    #expect(FileTag(entry: "Odd\n9").color == 0)
    #expect(FileTag(entry: "Odd\nx\n1").color == 0)
    #expect(FileTag(name: "Red", color: 6).entry == "Red\n6")
    #expect(FileTag(name: "Work", color: 0).entry == "Work")
}

@Test func fileTagDisplayColorUsesTheStoredColour() {
    #expect(FileTag(entry: "Project\n2\n0").displayColor == 2)
    #expect(FileTag(entry: "Urgent\n6").displayColor == 6)
    // A colourless "Red" (older apps wrote these) still draws red.
    #expect(FileTag(entry: "Red").displayColor == 6)
    #expect(FileTag(entry: "Work").displayColor == 0)
}

@Test func fileTagDistinctKeepsFirstNameAndFirstColour() {
    let tags = [FileTag(name: "work", color: 0), FileTag(name: "Work", color: 4),
                FileTag(name: "Home", color: 2), FileTag(name: "", color: 1)]
    #expect(FileTag.distinct(tags) == [FileTag(name: "work", color: 4), FileTag(name: "Home", color: 2)])
}

// MARK: - The user's colour names

private let renamed = TagColorNames(fileLabels: ["None", "Gray", "Green", "Purple", "Blue", "Yellow", "Urgent", "Orange"])

@Test func tagColorNamesFollowTheUsersNames() {
    #expect(renamed.name(for: 6) == "Urgent")
    #expect(renamed.name(for: 4) == "Blue")
    #expect(renamed.color(named: "urgent") == 6)
    #expect(renamed.color(named: "Red") == 6)          // the English name still counts
    #expect(renamed.color(named: "Project") == nil)
    // Missing or blank names fall back to English.
    #expect(TagColorNames(fileLabels: []).name(for: 7) == "Orange")
    #expect(TagColorNames(fileLabels: ["None", " "]).name(for: 1) == "Gray")
    #expect(renamed.standardTags.map(\.name) == ["Urgent", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
}

@Test func standardTagIsTheColoursOwnTagNotAnyTagOfThatColour() {
    #expect(renamed.isStandard(FileTag(entry: "Urgent\n6\n0"), color: 6))
    #expect(renamed.isStandard(FileTag(entry: "Red\n6"), color: 6))
    #expect(renamed.isStandard(FileTag(entry: "red"), color: 6))
    // A custom tag coloured red is a different tag.
    #expect(!renamed.isStandard(FileTag(entry: "Project\n6"), color: 6))
    // Red's name with another colour isn't Red.
    #expect(!renamed.isStandard(FileTag(entry: "Red\n4"), color: 6))
    #expect(!TagColorNames.english.isStandard(FileTag(entry: "Urgent\n6"), color: 6))
}

// MARK: - Toggle rules

@Test func fileOpsTagsToggleRule() {
    // Only one of two files has Red: add it to both.
    #expect(!FileOpsTags.toggleRemoves(6, current: [["Red\n6"], ["Work"]]))
    // Both have it (any case, with or without colour): remove from both.
    #expect(FileOpsTags.toggleRemoves(6, current: [["red", "Work"], ["Red\n6\n0"]]))
    #expect(!FileOpsTags.toggleRemoves(6, current: []))
    #expect(FileOpsTags.applying(6, remove: false, to: ["Work"]) == ["Work", "Red\n6"])
    #expect(FileOpsTags.applying(6, remove: false, to: ["Work", "red"]) == ["Work", "red"])
    #expect(FileOpsTags.applying(6, remove: true, to: ["Red\n6\n0", "Work", "Blue\n4"]) == ["Work", "Blue\n4"])
    // Adding uses the user's name for the colour.
    #expect(FileOpsTags.applying(6, remove: false, to: [], names: renamed) == ["Urgent\n6"])
}

// MARK: - The Mac-wide scan

/// Spotlight gives tag names only; each name's colour comes from the tags
/// stored on the first of its files that still has it.
@Test func tagScanFindsEachNamesColour() {
    let stored = ["/a": ["Project\n2\n0", "Work"], "/b": ["work\n4", "Home\n3"], "/gone": nil] as [String: [String]?]
    let hits = [TagScan.Hit(names: ["Project", "Work"], path: "/a"),
                TagScan.Hit(names: ["Home"], path: "/gone"),
                TagScan.Hit(names: ["WORK", "Home"], path: "/b")]
    let tags = TagScan.tags(from: hits) { stored[$0] ?? nil }
    #expect(tags == [FileTag(name: "Project", color: 2), FileTag(name: "Work", color: 4), FileTag(name: "Home", color: 3)])
}

#if os(macOS)
// MARK: - On real files

private func raw(_ url: URL) -> [String]? { try? FinderTagStore.readEntries(atPath: url.path) }
private func rawBytes(_ url: URL) -> Data? {
    let name = FinderTagStore.attributeName
    let n = getxattr(url.path, name, nil, 0, 0, 0)
    guard n >= 0 else { return nil }
    var d = Data(count: n)
    _ = d.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, n, 0, 0) }
    return d
}
/// The system's view of the file, read fresh.
private func label(_ url: URL) -> Int? {
    try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.labelNumberKey]).labelNumber
}
private func systemTagNames(_ url: URL) -> [String] {
    (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []) ?? []
}

/// Toggling Red on two files where only one has it adds it to both; toggling
/// again removes it from both; Clear Tags empties them.
@Test func fileOpsTagsToggleOnFiles() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let a = try dir.file("a.txt"), b = try dir.file("b.txt")
    try FileOpsTags.writeEntries(["Red\n6", "Work"], to: a)
    try FileOpsTags.writeEntries(["Work"], to: b)

    let added = try #require(FileOpsTags.toggleColor(6, on: [a, b]))
    #expect(!added.removed && added.result.failures.isEmpty)
    #expect(raw(a) == ["Red\n6", "Work"])
    #expect(raw(b) == ["Work", "Red\n6"])
    #expect(label(a) == 6 && label(b) == 6)
    #expect(systemTagNames(b) == ["Work", "Red"])

    let removed = try #require(FileOpsTags.toggleColor(6, on: [a, b]))
    #expect(removed.removed)
    #expect(raw(a) == ["Work"] && raw(b) == ["Work"])
    #expect(label(a) == 0)
    #expect(FileOpsTags.toggleColor(0, on: [a]) == nil)
}

/// The data loss this fixes: a custom tag's colour survived a toggle only as a
/// colourless name ("Project\n2\n0" came back as "Project\n0").
@Test func customColouredTagsSurviveAToggle() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let a = try dir.file("a.txt")
    try FinderTagStore.writeEntries(["Project\n2\n0", "Home\n4"], atPath: a.path)

    #expect(FileOpsTags.toggleColor(6, on: [a])?.removed == false)
    #expect(raw(a) == ["Project\n2\n0", "Home\n4", "Red\n6"])
    #expect(label(a) == 6)

    #expect(FileOpsTags.toggleColor(6, on: [a])?.removed == true)
    #expect(raw(a) == ["Project\n2\n0", "Home\n4"])
    #expect(label(a) == 4)
}

/// A renamed colour tag keeps its colour and is what the colour toggles; a
/// custom tag that's only coloured red is left alone.
@Test func renamedColourTagsSurviveAndAreToggledByColour() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let a = try dir.file("a.txt"), b = try dir.file("b.txt")
    try FinderTagStore.writeEntries(["Urgent\n6\n0", "Project\n2\n0"], atPath: a.path)
    try FinderTagStore.writeEntries(["Urgent\n6\n0"], atPath: b.path)

    // Blue leaves Urgent as it was.
    #expect(FileOpsTags.toggleColor(4, names: renamed, on: [a])?.removed == false)
    #expect(raw(a) == ["Urgent\n6\n0", "Project\n2\n0", "Blue\n4"])

    // Both files have the red tag (as the user calls it), so Red removes it.
    #expect(FileOpsTags.toggleColor(6, names: renamed, on: [a, b])?.removed == true)
    #expect(raw(a) == ["Project\n2\n0", "Blue\n4"])
    #expect(raw(b) == nil)   // no tags left: the attribute goes
    #expect(label(b) == 0)

    // Adding it back uses the user's name.
    #expect(FileOpsTags.toggleColor(6, names: renamed, on: [b])?.removed == false)
    #expect(raw(b) == ["Urgent\n6"])

    // "Project" in red is its own tag: Red is added beside it, not taken for it.
    let c = try dir.file("c.txt")
    try FinderTagStore.writeEntries(["Project\n6\n0"], atPath: c.path)
    #expect(FileOpsTags.toggleColor(6, names: renamed, on: [c])?.removed == false)
    #expect(raw(c) == ["Project\n6\n0", "Urgent\n6"])
}

/// A file that already has what's asked isn't written: its entries keep their
/// exact bytes, including fields Selway doesn't know.
@Test func toggleWithNothingToChangeLeavesTheBytesAlone() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let a = try dir.file("a.txt"), b = try dir.file("b.txt")
    let entries = ["Red\n6\n0\nextra", "Project\n2\n0"]
    let xml = try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
    #expect(xml.withUnsafeBytes { setxattr(a.path, FinderTagStore.attributeName, $0.baseAddress, xml.count, 0, 0) } == 0)

    let result = try #require(FileOpsTags.toggleColor(6, on: [a, b]))
    #expect(!result.removed && result.result.failures.isEmpty)
    #expect(rawBytes(a) == xml)
    #expect(raw(b) == ["Red\n6"])
}

@Test func clearEmptiesTheTags() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let a = try dir.file("a.txt"), b = try dir.file("b.txt")
    try FileOpsTags.writeEntries(["Project\n2\n0", "Red\n6"], to: a)
    #expect(label(a) == 6)

    #expect(FileOpsTags.clear([a, b]).failures.isEmpty)
    #expect(raw(a) == nil && raw(b) == nil)
    #expect(label(a) == 0)
    #expect(systemTagNames(a).isEmpty)
    #expect(try FileOpsTags.readTags(a).isEmpty)
}

/// A file with only a legacy colour label reads as that colour's tag, and a
/// change keeps it as a real tag.
@Test func legacyLabelBecomesATagOnChange() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    var a = try dir.file("a.txt")
    var values = URLResourceValues(); values.labelNumber = 4
    try a.setResourceValues(values)
    #expect(raw(a) == nil)
    #expect(try FileOpsTags.readTags(a) == [FileTag(name: "Blue", color: 4)])

    #expect(FileOpsTags.toggleColor(6, on: [a])?.removed == false)
    #expect(raw(a) == ["Blue\n4", "Red\n6"])
    #expect(label(a) == 6)

    // Clearing a label-only file removes the label.
    let b = try dir.file("b.txt")
    var bb = b; try bb.setResourceValues(values)
    #expect(FileOpsTags.clear([b]).failures.isEmpty)
    #expect(label(b) == 0)
}

/// A damaged attribute isn't overwritten by a toggle (its tags couldn't be
/// read), but Clear Tags still clears it.
@Test func unreadableTagsAreLeftAloneButCanBeCleared() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let a = try dir.file("a.txt")
    let junk = Data("not a plist".utf8)
    _ = junk.withUnsafeBytes { setxattr(a.path, FinderTagStore.attributeName, $0.baseAddress, junk.count, 0, 0) }

    #expect(FileOpsTags.toggleColor(6, on: [a])?.result.failures.count == 1)
    #expect(rawBytes(a) == junk)
    #expect(FileOpsTags.clear([a]).failures.isEmpty)
    #expect(rawBytes(a) == nil)
}

/// Listing reads each tag's stored colour.
@Test func loadedItemsCarryTagColours() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    let a = try dir.file("a.txt")
    try FileOpsTags.writeEntries(["Project\n2\n0", "Urgent\n6", "Work"], to: a)
    let item = try #require(FileItem.load(from: a))
    #expect(item.tags == [FileTag(name: "Project", color: 2), FileTag(name: "Urgent", color: 6),
                          FileTag(name: "Work", color: 0)])
    #expect(item.tagNames == ["Project", "Urgent", "Work"])
    #expect(item.tagColorNumbers == [2, 6])
    #expect(item.hasColorTag(6, names: renamed) && !item.hasColorTag(6))
}
#endif
