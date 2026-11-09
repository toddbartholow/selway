import Foundation

/// A count in a sentence ("1 server", "3 servers") that a String Catalog gives
/// plural forms. `format` is looked up at the call site, with
/// `NSLocalizedString` and the English key, so the key is extracted; `one` and
/// `other` are the English forms, used while `format` is still that key (on
/// Linux, in the tests, and for a key the catalog has no forms for).
enum LocalizedCount {
    static func string(_ count: Int, _ format: String, one: String, other: String) -> String {
        String.localizedStringWithFormat(format == other ? (count == 1 ? one : other) : format, count)
    }
}
