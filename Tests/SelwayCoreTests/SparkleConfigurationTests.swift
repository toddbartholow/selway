import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import SelwayCore

/// The app's Sparkle settings (Selway/Info.plist) and how they line up with the release
/// scripts and the Xcode project. Plain file reads, so they run everywhere `swift test` does.
@Suite struct SparkleConfigurationTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Selway/Info.plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The first capture group of `pattern` in `text`, if it matches.
    private func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    @Test func feedIsHTTPSOnThePublicRepositoryPagesSite() throws {
        let feed = try #require(try infoPlist()["SUFeedURL"] as? String)
        let url = try #require(URL(string: feed))
        #expect(url.scheme == "https")
        #expect(url.host == "toddbartholow.github.io")
        #expect(url.path == "/selway/appcast.xml")
        #expect(url.query == nil && url.fragment == nil && url.user == nil)
    }

    /// release-common.sh derives the feed (and download URLs) from SELWAY_RELEASES_REPO; the
    /// app must point at the same place.
    @Test func feedMatchesTheReleaseScriptsRepository() throws {
        let script = try text("scripts/lib/release-common.sh")
        let repo = try #require(capture(#"SELWAY_RELEASES_REPO="\$\{SELWAY_RELEASES_REPO:-([^}]+)\}""#, in: script))
        let parts = repo.split(separator: "/").map(String.init)
        try #require(parts.count == 2)
        let expected = "https://\(parts[0].lowercased()).github.io/\(parts[1])/appcast.xml"
        #expect(try infoPlist()["SUFeedURL"] as? String == expected)
    }

    @Test func publicEdKeyIsA32ByteEd25519Key() throws {
        let key = try #require(try infoPlist()["SUPublicEDKey"] as? String)
        let raw = try #require(Data(base64Encoded: key))
        #expect(raw.count == 32)
        #if canImport(CryptoKit)
        #expect((try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil)
        #endif
    }

    @Test func strictVerificationIsOn() throws {
        let info = try infoPlist()
        #expect(info["SURequireSignedFeed"] as? Bool == true)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        // No fallback after feed-signature failures (Sparkle's default is 20 days). It must be a
        // number: Sparkle reads it as a double, and a string would be ignored.
        #expect(info["SUSignedFeedFailureExpirationInterval"] as? Int == 0)
        #expect(!(info["SUSignedFeedFailureExpirationInterval"] is String))
        // Not sandboxed: Sparkle's XPC helpers stay off (Sparkle's guidance for such apps).
        #expect(info["SUEnableInstallerLauncherService"] == nil)
        #expect(info["SUEnableDownloaderService"] == nil)
        #expect(info["SUEnableJavaScript"] == nil)
        // The custom updater's keys are gone.
        #expect(info.keys.filter { $0.hasPrefix("SelwayUpdate") }.isEmpty)
    }

    /// Sparkle compares CFBundleVersion, so it must come from one positive-integer
    /// CURRENT_PROJECT_VERSION shared by every target and configuration.
    @Test func buildNumberIsOnePositiveInteger() throws {
        #expect(try infoPlist()["CFBundleVersion"] as? String == "$(CURRENT_PROJECT_VERSION)")
        let project = try text("Selway.xcodeproj/project.pbxproj")
        let regex = try NSRegularExpression(pattern: #"CURRENT_PROJECT_VERSION = ([^;]+);"#)
        let values = Set(regex.matches(in: project, range: NSRange(project.startIndex..., in: project)).compactMap {
            Range($0.range(at: 1), in: project).map { String(project[$0]) }
        })
        #expect(values.count == 1, "\(values)")
        let build = try #require(values.first.flatMap { Int($0) })
        #expect(build > 0)
    }

    /// Sparkle is linked into the app target only, at one exact version; the SwiftPM test
    /// package (which also builds on Linux) never depends on it.
    @Test func sparkleIsPinnedForTheAppOnly() throws {
        #expect(try !text("Package.swift").localizedCaseInsensitiveContains("sparkle"))
        let project = try text("Selway.xcodeproj/project.pbxproj")
        let pinned = try #require(capture(#"kind = exactVersion;\s*version = ([0-9.]+);"#, in: project))
        let resolved = try text("Selway.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        #expect(resolved.contains("github.com/sparkle-project/Sparkle"))
        #expect(capture(#""version" : "([0-9.]+)""#, in: resolved) == pinned)
        #expect(pinned.hasPrefix("2."))
    }

    /// Ad-hoc signatures have no Team ID, so with library validation on, dyld refuses the
    /// ad-hoc-signed Sparkle.framework and the app dies at launch. Ad-hoc builds (the Debug
    /// configuration, and release-common.sh without a Developer ID) turn it off; Developer
    /// ID builds keep it.
    @Test func adHocBuildsTurnOffLibraryValidationOnly() throws {
        let key = "com.apple.security.cs.disable-library-validation"
        #expect(try !text("Selway/Selway.entitlements").contains(key))

        let configurations = try text("Selway.xcodeproj/project.pbxproj")
            .components(separatedBy: "isa = XCBuildConfiguration;")
            .filter { $0.contains("RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION") }
        #expect(configurations.count == 1)
        let debug = try #require(configurations.first)
        #expect(debug.contains("RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION = YES;"))
        #expect(debug.contains("PRODUCT_BUNDLE_IDENTIFIER = studio.irq.selway;"))
        #expect(debug.contains("name = Debug;"))

        let script = try text("scripts/lib/release-common.sh")
        #expect(script.components(separatedBy: "Add :\(key) bool true").count == 2)
        let adHoc = try #require(capture(#"if ! selway_is_developer_id; then\n((?:.*\n)*?)    fi\n"#, in: script))
        #expect(adHoc.contains("Add :\(key) bool true"))
    }
}
