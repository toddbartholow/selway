import Foundation

/// Validates a name typed for a new or renamed item before it is appended to a
/// folder URL. A "/" in the name turns `dir.appendingPathComponent(name)` into a
/// path elsewhere — renaming to "../x" would silently move the file out of the
/// folder — so names must be a single path component.
enum ShellFileName {

    enum Problem: Error, Equatable {
        case empty
        case containsSlash
        case containsNull
        case reserved      // "." or ".."
        case tooLong       // over 255 UTF-8 bytes (APFS / HFS+ limit)
    }

    /// Returns the trimmed name, or the reason it can't be used.
    static func validate(_ raw: String) -> Result<String, Problem> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty                 { return .failure(.empty) }
        if name.contains("/")           { return .failure(.containsSlash) }
        if name.contains("\u{0}")       { return .failure(.containsNull) }
        if name == "." || name == ".."  { return .failure(.reserved) }
        if name.utf8.count > 255        { return .failure(.tooLong) }
        return .success(name)
    }

    enum RenameDecision: Equatable {
        /// Leave the item alone (the field still holds its name).
        case unchanged
        case rename(to: String)
        case invalid(Problem)
    }

    /// What renaming an item named `currentName` to the typed `raw` text means. The
    /// untouched text is compared first: trimming it would turn "notes.txt " (a
    /// name with a trailing space) into a rename to "notes.txt" when the user only
    /// pressed Return, or an error if that name is taken. Text that only differs
    /// from the name by surrounding whitespace is no change either.
    static func renameDecision(_ raw: String, currentName: String) -> RenameDecision {
        if raw == currentName { return .unchanged }
        switch validate(raw) {
        case .success(let name): return name == currentName ? .unchanged : .rename(to: name)
        case .failure(let problem): return .invalid(problem)
        }
    }

    static func message(for problem: Problem, name: String) -> String {
        switch problem {
        case .empty:
            return NSLocalizedString("Please enter a name.", comment: "Validation error when a new file or folder name is empty")
        case .containsSlash:
            return String.localizedStringWithFormat(NSLocalizedString("The name “%1$@” can’t be used because it contains “/”.", comment: "Validation error with a name containing a slash"), name)
        case .containsNull:
            return NSLocalizedString("The name contains a character that isn’t allowed.", comment: "Validation error when a file or folder name contains a null character")
        case .reserved:
            return String.localizedStringWithFormat(NSLocalizedString("The name “%1$@” is reserved by the system.", comment: "Validation error with a reserved file or folder name"), name)
        case .tooLong:
            return NSLocalizedString("The name is too long. Use a shorter name.", comment: "Validation error when a file or folder name is too long")
        }
    }
}
