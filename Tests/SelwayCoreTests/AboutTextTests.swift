import Foundation
import Testing
@testable import SelwayCore

/// The About window's version line, byline and copyright.
@Suite struct AboutTextTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func versionShowsTheVersionAndTheBuild() {
        #expect(AboutText.version("0.5.21", build: "22") == "v0.5.21 (build 22)")
        #expect(AboutText.version(info: ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "7"])
                == "v1.0 (build 7)")
    }

    @Test func versionLeavesOutAMissingBuild() {
        #expect(AboutText.version("0.5.21", build: nil) == "v0.5.21")
        #expect(AboutText.version("0.5.21", build: "  ") == "v0.5.21")
        #expect(AboutText.version(info: ["CFBundleShortVersionString": "2.0"]) == "v2.0")
    }

    @Test func versionWithoutAVersionSaysSo() {
        #expect(AboutText.version(nil, build: "3") == "v? (build 3)")
        #expect(AboutText.version(info: nil) == "v?")
    }

    @Test func versionTrimsWhitespace() {
        #expect(AboutText.version(" 0.5.21\n", build: " 22 ") == "v0.5.21 (build 22)")
    }

    @Test func bylineNamesTheAuthor() {
        #expect(AboutText.byline == "By Todd Bartholow")
    }

    /// The window and Info.plist (which the standard panel and Finder's Get Info read) say
    /// the same thing.
    @Test func copyrightMatchesInfoPlist() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Selway/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["NSHumanReadableCopyright"] as? String == AboutText.copyright)
        #expect(AboutText.copyright.contains(AboutText.author))
    }

    /// Every language's copyright line in InfoPlist.xcstrings names the author and the year,
    /// and the English one is Info.plist's.
    @Test func copyrightTranslationsNameTheAuthor() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Selway/InfoPlist.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let entry = try #require(strings["NSHumanReadableCopyright"] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        var values: [String: String] = [:]
        for (language, value) in localizations {
            let unit = (value as? [String: Any])?["stringUnit"] as? [String: Any]
            values[language] = unit?["value"] as? String
        }
        #expect(values["en"] == AboutText.copyright)
        #expect(Set(values.keys) == ["en", "de", "es", "fr", "it", "ja"])
        for (language, value) in values {
            #expect(value.hasPrefix("© 2026 Todd Bartholow."), "\(language): \(value)")
            #expect(value.contains("MIT"), "\(language): \(value)")
        }
    }
}
