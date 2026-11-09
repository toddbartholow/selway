import Foundation

/// Localized names used when Selway creates an item with no name supplied. The app
/// reads the English from Selway/Localizable.xcstrings, which holds it as these keys'
/// "en" value; the `value:` here is only used without the catalog (Linux, tests), so
/// change both together.
enum DefaultNames {
    static let newFolder = safeFileName(
        NSLocalizedString("default name: New Folder", value: "New Folder",
                         comment: "Name Selway gives a new folder (New Folder, ⌥⌘N). It's a file name: no / or :, and it can't start with a dot."),
        fallback: "New Folder")
    static let untitledTextFile = safeFileName(
        NSLocalizedString("default name: untitled", value: "untitled",
                         comment: "Name Selway gives a new text file, before its .txt extension. It's a file name: no / or :, and it can't start with a dot."),
        suffix: ".txt", fallback: "untitled") + ".txt"
    static let archive = safeFileName(
        NSLocalizedString("default name: Archive", value: "Archive",
                         comment: "Name of the ZIP file made by compressing several items, before .zip, and of the folder an archive with no usable name extracts to. It's a file name: no / or :, and it can't start with a dot."),
        suffix: ".zip", fallback: "Archive")

    /// A translated default must be a name the user could have typed (with `suffix`,
    /// the extension added to it) and must not make a hidden item.
    static func safeFileName(_ candidate: String, suffix: String = "", fallback: String) -> String {
        guard !candidate.hasPrefix("."), FileOpsNameValidation.isValid(candidate + suffix) else { return fallback }
        return candidate
    }
}

/// New Folder / New File / Rename with validated, single-component names.
enum FileOpsCreation {

    /// Creates a folder called `name` (or "name 2", …) inside `directory`.
    /// Only ever creates one level: "a/b" is refused, not turned into two folders.
    static func createFolder(in directory: URL, named name: String,
                             fileManager fm: FileManager = .default) throws -> URL {
        try FileOpsNameValidation.validate(name)
        guard FileOpsNaming.isDirectory(directory.resolvingSymlinksInPath(), fileManager: fm) else {
            throw FileOpsError.notAFolder(directory.lastPathComponent)
        }
        var lastError: Error?
        for _ in 0..<8 {
            let target = FileOpsNaming.uniqueURL(in: directory, name: name, isDirectory: true, fileManager: fm)
            do {
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
                return target
            } catch let e as CocoaError where e.code == .fileWriteFileExists {
                lastError = e   // someone took the name in between; pick the next one
            }
        }
        throw lastError ?? CocoaError(.fileWriteFileExists)
    }

    /// Creates an empty file called `name` (or "name 2.ext", …) in `directory`,
    /// never truncating an existing file.
    static func createFile(in directory: URL, named name: String,
                           fileManager fm: FileManager = .default) throws -> URL {
        try FileOpsNameValidation.validate(name)
        guard FileOpsNaming.isDirectory(directory.resolvingSymlinksInPath(), fileManager: fm) else {
            throw FileOpsError.notAFolder(directory.lastPathComponent)
        }
        var lastError: Error?
        for _ in 0..<8 {
            let target = FileOpsNaming.uniqueURL(in: directory, name: name, isDirectory: false, fileManager: fm)
            do {
                try Data().write(to: target, options: .withoutOverwriting)
                return target
            } catch let e as CocoaError where e.code == .fileWriteFileExists {
                lastError = e
            }
        }
        throw lastError ?? CocoaError(.fileWriteFileExists)
    }

    /// Renames `url` in place to `newName`, refusing names that aren't a single
    /// component and never replacing another item. Returns the new URL.
    static func rename(_ url: URL, to newName: String, fileManager fm: FileManager = .default) throws -> URL {
        try FileOpsNameValidation.validate(newName)
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileOpsTransfer.moveWithoutReplacing(url, to: target, fileManager: fm)
        return target
    }
}
