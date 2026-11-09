import Foundation

/// How VoiceOver reads a file's tags (TagDotsView).
enum FileTagAccessibility {
    /// The tags element's value: the names in order, "Red, Work".
    static func value(_ names: [String]) -> String {
        names.joined(separator: ", ")
    }
}
