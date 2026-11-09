import Foundation

/// Why a user-typed file or folder name was refused.
enum FileOpsNameError: Error, Equatable, LocalizedError {
    case empty
    case reserved            // "." or ".."
    case containsSlash
    case containsColon
    case surroundingWhitespace
    case controlCharacter
    case bidiControl
    case tooLong

    var errorDescription: String? {
        switch self {
        case .empty:                 return NSLocalizedString("Please enter a name.", comment: "File name validation error")
        case .reserved:              return NSLocalizedString("The names “.” and “..” are reserved by the system. Please choose another name.", comment: "File name validation error")
        case .containsSlash:         return NSLocalizedString("Names can’t contain “/”. Please choose another name.", comment: "File name validation error")
        case .containsColon:         return NSLocalizedString("Names can’t contain “:”. Please choose another name.", comment: "File name validation error")
        case .surroundingWhitespace: return NSLocalizedString("Names can’t start or end with a space. Please choose another name.", comment: "File name validation error")
        case .controlCharacter:      return NSLocalizedString("Names can’t contain control characters such as line breaks or tabs.", comment: "File name validation error")
        case .bidiControl:           return NSLocalizedString("Names can’t contain invisible text-direction characters, which can disguise a file’s real extension.", comment: "File name validation error")
        case .tooLong:               return NSLocalizedString("That name is too long. Please choose a shorter name.", comment: "File name validation error")
        }
    }
}

/// Validation for names typed by the user (rename, New Folder, New File).
/// A name must be a single path component: "a/b" would otherwise create or move
/// into a nested folder and "../x" would escape the current folder.
enum FileOpsNameValidation {

    /// Longest name most macOS volumes accept (NAME_MAX, in UTF-8 bytes).
    static let maxNameBytes = 255

    static func validate(_ name: String) throws {
        if name.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FileOpsNameError.empty
        }
        if name == "." || name == ".." { throw FileOpsNameError.reserved }
        if name.contains("/") { throw FileOpsNameError.containsSlash }
        // Finder shows "/" as ":" and vice versa, so a ":" would surface as a slash.
        if name.contains(":") { throw FileOpsNameError.containsColon }
        if FileOpsSafety.containsControlCharacters(name) { throw FileOpsNameError.controlCharacter }
        if let first = name.unicodeScalars.first, let last = name.unicodeScalars.last,
           CharacterSet.whitespacesAndNewlines.contains(first) || CharacterSet.whitespacesAndNewlines.contains(last) {
            throw FileOpsNameError.surroundingWhitespace
        }
        if name.unicodeScalars.contains(where: isBidiControl) { throw FileOpsNameError.bidiControl }
        if name.utf8.count > maxNameBytes { throw FileOpsNameError.tooLong }
    }

    static func isValid(_ name: String) -> Bool {
        (try? validate(name)) != nil
    }

    /// Embedding/override/isolate controls (U+202A–U+202E, U+2066–U+2069) and the
    /// line/paragraph separators, which can make "photo‮gpj.app" read as a JPEG.
    private static func isBidiControl(_ s: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(s.value) || (0x2066...0x2069).contains(s.value)
            || s.value == 0x2028 || s.value == 0x2029
    }
}
