import Foundation

/// Finder-compatible naming for new, pasted, duplicated, extracted and archived
/// items. This is the single implementation the app uses for "pick a free name";
/// keep every caller on it so numbering behaves the same everywhere.
enum FileOpsNaming {

    /// Multi-part extensions kept whole when numbering, so "a.tar.gz" becomes
    /// "a 2.tar.gz" rather than "a.tar 2.gz".
    static let compoundExtensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tar.lz", "tar.lzma", "tar.z"]

    /// Folder extensions that make a package (an app, bundle or document shown
    /// as one item). Numbering goes before these, as in Finder: "Demo 2.app",
    /// "Demo copy.app"; "Demo.app 2" would no longer be a bundle.
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "prefpane",
        "qlgenerator", "mdimporter", "saver", "component", "systemextension",
        "rtfd", "pages", "numbers", "key", "scptd", "pkg", "mpkg",
        "xcodeproj", "xcworkspace", "playground", "xcarchive", "dsym", "docc",
        "photoslibrary", "fcpbundle", "logicx", "band", "workflow",
    ]

    /// Splits `name` into stem and extension (without the dot). Folders have no
    /// extension ("Folder.v2" stays whole) unless it is a package extension
    /// ("Demo.app"); dot-files (".gitignore"), names ending in a dot and
    /// "extensions" containing a space have none either.
    static func split(_ name: String, isDirectory: Bool) -> (stem: String, ext: String) {
        if isDirectory {
            guard let dot = name.lastIndex(of: "."), dot > name.startIndex,
                  packageExtensions.contains(name[name.index(after: dot)...].lowercased())
            else { return (name, "") }
            return (String(name[..<dot]), String(name[name.index(after: dot)...]))
        }
        for compound in compoundExtensions {
            if let r = name.range(of: "." + compound, options: [.caseInsensitive, .anchored, .backwards]),
               r.lowerBound > name.startIndex {
                return (String(name[..<r.lowerBound]), String(name[name.index(after: r.lowerBound)...]))
            }
        }
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return (name, "") }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, !ext.contains(" ") else { return (name, "") }
        return (String(name[..<dot]), String(ext))
    }

    static func join(_ stem: String, _ ext: String) -> String {
        ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// Key for collision checks. Default APFS/HFS+ volumes are case- and
    /// Unicode-normalization-insensitive, so "X.TXT" and "x.txt" (or a composed
    /// and decomposed "café") name the same file.
    static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// First free name: "a.txt", then "a 2.txt", "a 3.txt", … A name that
    /// already ends in a small number continues the series as Finder does:
    /// "x 2.txt" → "x 3.txt", not "x 2 2.txt". (Four-digit endings such as
    /// "Report 2024" are treated as part of the name.)
    static func uniqueName(_ name: String, isDirectory: Bool, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        var (stem, ext) = split(name, isDirectory: isDirectory)
        var n = 2
        if let r = stem.range(of: #" [1-9][0-9]{0,2}$"#, options: .regularExpression),
           r.lowerBound > stem.startIndex,
           let current = Int(stem[stem.index(after: r.lowerBound)...]), current >= 2 {
            n = current + 1
            stem = String(stem[..<r.lowerBound])
        }
        while true {
            let candidate = join("\(stem) \(n)", ext)
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }

    /// Finder's Duplicate naming: "x.txt" → "x copy.txt", then "x copy 2.txt".
    /// Duplicating "x copy.txt" continues the series instead of "x copy copy.txt".
    static func duplicateName(_ name: String, isDirectory: Bool, isTaken: (String) -> Bool) -> String {
        let (stem, ext) = split(name, isDirectory: isDirectory)
        var base = stem
        if let r = stem.range(of: #" copy( [0-9]+)?$"#, options: .regularExpression), r.lowerBound > stem.startIndex {
            base = String(stem[..<r.lowerBound])
        }
        let first = join("\(base) copy", ext)
        if !isTaken(first) { return first }
        var n = 2
        while true {
            let candidate = join("\(base) copy \(n)", ext)
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }

    /// Returns a predicate answering "is this name already used in `directory`?",
    /// comparing case-insensitively against one directory listing and falling
    /// back to an lstat (which also catches dangling symlinks) per candidate.
    static func takenChecker(in directory: URL, fileManager: FileManager = .default) -> (String) -> Bool {
        let listed = Set(((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []).map(collisionKey))
        return { candidate in
            listed.contains(collisionKey(candidate))
                || (try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(candidate).path)) != nil
        }
    }

    /// A free URL in `directory` for an item called `name`.
    static func uniqueURL(in directory: URL, name: String, isDirectory: Bool,
                          fileManager: FileManager = .default) -> URL {
        let taken = takenChecker(in: directory, fileManager: fileManager)
        return directory.appendingPathComponent(uniqueName(name, isDirectory: isDirectory, isTaken: taken),
                                                isDirectory: isDirectory)
    }

    /// A free "… copy" URL next to `url`.
    static func duplicateURL(for url: URL, isDirectory: Bool, fileManager: FileManager = .default) -> URL {
        let dir = url.deletingLastPathComponent()
        let taken = takenChecker(in: dir, fileManager: fileManager)
        return dir.appendingPathComponent(duplicateName(url.lastPathComponent, isDirectory: isDirectory, isTaken: taken),
                                          isDirectory: isDirectory)
    }

    /// Whether `url` is a directory, without following a final symlink (a link to
    /// a folder is named like a file).
    static func isDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }
}
