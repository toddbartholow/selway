import Foundation

/// The text of the About window, apart from what the bundle already holds (the app's name
/// and its copyright line, NSHumanReadableCopyright in Info.plist).
enum AboutText {
    /// Selway's author, as the About window credits him.
    static let author = "Todd Bartholow"

    /// The copyright line in English, as Info.plist's NSHumanReadableCopyright has it. The
    /// About window shows the bundle's localized one.
    static let copyright = "© 2026 Todd Bartholow. MIT License."

    /// "v0.5.21 (build 22)" from CFBundleShortVersionString and CFBundleVersion. A missing
    /// or empty build leaves the build out; a missing version reads "?".
    static func version(_ version: String?, build: String?) -> String {
        let version = trimmed(version) ?? "?"
        guard let build = trimmed(build) else {
            return String.localizedStringWithFormat(
                NSLocalizedString("v%@", comment: "About window: Selway's version number, when it has no build number"),
                version)
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("v%1$@ (build %2$@)",
                              comment: "About window: Selway's version (1) and build number (2), as in v0.5.21 (build 22)"),
            version, build)
    }

    /// The version line for a bundle's Info.plist values.
    static func version(info: [String: Any]?) -> String {
        version(info?["CFBundleShortVersionString"] as? String, build: info?["CFBundleVersion"] as? String)
    }

    /// "By Todd Bartholow".
    static var byline: String {
        String.localizedStringWithFormat(
            NSLocalizedString("By %@", comment: "About window: who wrote Selway; the placeholder is the author's name"),
            author)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
