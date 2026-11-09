import Testing
@testable import SelwayCore

@Suite struct FileTagAccessibilityTests {
    @Test func joinsTagNamesForVoiceOver() {
        #expect(FileTagAccessibility.value(["Red", "Work"]) == "Red, Work")
    }

    @Test func hasAnEmptyValueWithoutTags() {
        #expect(FileTagAccessibility.value([]).isEmpty)
    }

    /// A dot is always read: by its tag's name, or, from a legacy colour label
    /// with no tag names beside it, by the colour's.
    @Test func everyDotHasANameToRead() {
        #expect(FileItem.fixture("a", tags: ["Red", "Work"], labelNumber: 2).spokenTagNames == ["Red", "Work"])
        #expect(FileItem.fixture("b", labelNumber: 6).spokenTagNames == ["Red"])
        #expect(FileItem.fixture("c").spokenTagNames.isEmpty)
    }
}
