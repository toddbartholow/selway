import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum FileOpsArchiveKind: Equatable {
    case zip
    case tar   // plain or compressed; bsdtar detects the compression itself
}

/// Compress and Extract Here, built on the system's `zip`, `ditto` and `tar`.
///
/// Safety rules:
/// - Item names are never parsed as options: each is passed as `./name` after
///   `--`. (A planted file named "-TT" makes `zip` run the next file name as a
///   test command, e.g. `python3` on the archive itself.)
/// - Output is built in a private staging folder and moved into place with a
///   free name, so nothing next to the archive is ever overwritten.
/// - `ditto` and bsdtar refuse to write outside the destination ("../" entries,
///   absolute paths, writing through symlinks); staging also contains anything
///   that slips through, since it is deleted afterwards.
/// - The archive's quarantine flag is copied onto everything extracted, so an
///   app inside a downloaded archive still goes through Gatekeeper. It replaces
///   any quarantine value stored inside the archive: an attacker can store one
///   with the "user approved" bit set. Neither ditto nor bsdtar is allowed to
///   restore stored extended attributes at all.
/// - A symlink to an archive is resolved first, and everything (format,
///   quarantine, the tool's input) uses the real file: the link has no
///   quarantine of its own. If the quarantine can't be read, nothing is
///   extracted (only "there is none" counts as unquarantined).
/// - Staging is made writable again before it is deleted, so read-only items
///   from the archive (0444 files, 0555 or 0111 folders) never get stuck in
///   the temporary folder.
enum FileOpsArchive {

    static let zipTool   = "/usr/bin/zip"
    static let dittoTool = "/usr/bin/ditto"
    static let tarTool   = "/usr/bin/tar"

    private static let tarSuffixes = [".tar", ".tgz", ".tbz", ".tbz2", ".txz", ".tzst",
                                      ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst",
                                      ".tar.lz", ".tar.lzma", ".tar.z"]

    /// What Selway can extract itself. Plain ".gz"/".bz2"/".xz" files that
    /// aren't tarballs, and formats like .7z/.rar/.dmg, return nil: the caller
    /// hands those to their default app.
    static func kind(forName name: String) -> FileOpsArchiveKind? {
        let lower = name.lowercased()
        if lower.hasSuffix(".zip") { return .zip }
        if tarSuffixes.contains(where: { lower.hasSuffix($0) }) { return .tar }
        return nil
    }

    /// Folder name for a multi-item archive: "a.tar.gz" → "a", "a.zip" → "a".
    static func extractedFolderName(forArchiveNamed name: String) -> String {
        let stem = FileOpsNaming.split(name, isDirectory: false).stem
        return stem.isEmpty ? DefaultNames.archive : stem
    }

    /// Finder's naming: one item → "<name>.zip" (keeping its extension, so
    /// "a.txt" and "a.pdf" don't collide), several → "Archive.zip".
    static func archiveName(for items: [URL]) -> String {
        items.count == 1 ? items[0].lastPathComponent + ".zip" : DefaultNames.archive + ".zip"
    }

    // MARK: Compress

    /// Zips `items` into a new archive next to the first item and returns its URL.
    /// Items may come from different folders; each is stored under its own name,
    /// and two items with the same name are refused rather than one replacing
    /// the other inside the archive.
    @discardableResult
    static func compress(_ items: [URL], fileManager fm: FileManager = .default,
                         token: FileOpsCancellationToken? = nil) throws -> URL {
        var unique: [URL] = []
        var seenPaths = Set<String>()
        for item in items where seenPaths.insert(item.absoluteURL.standardizedFileURL.path).inserted {
            unique.append(item.absoluteURL.standardizedFileURL)
        }
        guard let first = unique.first else { throw FileOpsError.notFound("") }

        var groups: [(parent: URL, names: [String])] = []
        var seenNames = Set<String>()
        for item in unique {
            let name = item.lastPathComponent
            guard seenNames.insert(FileOpsNaming.collisionKey(name)).inserted else {
                throw FileOpsError.duplicateNames(name)
            }
            let parent = item.deletingLastPathComponent()
            if let i = groups.firstIndex(where: { $0.parent.path == parent.path }) {
                groups[i].names.append(name)
            } else {
                groups.append((parent, [name]))
            }
        }

        let outputDir = first.deletingLastPathComponent()
        let staging = try makeStagingDirectory(near: outputDir, fileManager: fm)
        defer { removeStaging(staging, fileManager: fm) }
        let temp = staging.appendingPathComponent("Archive.zip")
        for group in groups {
            try FileOpsProcess.run(zipTool, zipArguments(archive: temp, names: group.names),
                                   in: group.parent, token: token)
        }
        return try moveIntoPlace(temp, directory: outputDir, name: archiveName(for: unique),
                                 isDirectory: false, fileManager: fm)
    }

    /// zip's argv for adding `names` (in the working directory) to `archive`.
    /// -y stores symlinks as links (as Finder does) instead of archiving
    /// whatever they point at, e.g. a link to the home folder. -nw keeps "*",
    /// "?" and "[" in names literal: Info-ZIP's own wildcard matching must
    /// never turn one selected name into other files. Names go after "--" as
    /// "./name" so none is read as an option.
    static func zipArguments(archive: URL, names: [String]) -> [String] {
        ["-r", "-y", "-q", "-nw", archive.path, "--"] + names.map { "./" + $0 }
    }

    // MARK: Extract

    /// Extracts `archive` next to itself and returns the new item. A single
    /// top-level item is placed directly (with a free name); several are put in
    /// a new folder named after the archive — like Archive Utility.
    ///
    /// `stagingIn` (tests) puts the private staging folder inside that folder
    /// instead of the system's temporary items; `markQuarantine` replaces the
    /// xattr writer (tests).
    @discardableResult
    static func extract(_ archive: URL, fileManager fm: FileManager = .default,
                        token: FileOpsCancellationToken? = nil,
                        stagingIn: URL? = nil,
                        markQuarantine: (Data, URL) -> Bool = FileOpsQuarantine.set) throws -> URL {
        let archive = archive.absoluteURL.standardizedFileURL
        // The item the user picked decides where the output goes and its name;
        // the file it resolves to is what gets read.
        guard let source = ModelPaths.realPath(archive) else {
            throw FileOpsError.notFound(archive.lastPathComponent)
        }
        guard let kind = kind(forName: source.lastPathComponent) else {
            throw FileOpsError.unsupportedArchive(archive.lastPathComponent)
        }
        let quarantine = try FileOpsQuarantine.read(source)
        let parent  = archive.deletingLastPathComponent()
        let staging: URL
        if let stagingIn {
            staging = stagingIn.appendingPathComponent("selway-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        } else {
            staging = try makeStagingDirectory(near: parent, fileManager: fm)
        }
        defer { removeStaging(staging, fileManager: fm) }
        let root = staging.appendingPathComponent("contents", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)

        switch kind {
        case .zip:
            try FileOpsProcess.run(dittoTool, dittoExtractOptions + ["-x", "-k", source.path, root.path],
                                   token: token)
            // With --norsrc the AppleDouble data comes out as a plain folder.
            let appleDouble = root.appendingPathComponent("__MACOSX")
            if (try? fm.attributesOfItem(atPath: appleDouble.path)) != nil {
                FileOpsPermissions.makeTreeWritable(appleDouble, fileManager: fm)
                try fm.removeItem(at: appleDouble)
            }
        case .tar:
            try FileOpsProcess.run(tarTool, tarExtractOptions + ["-x", "-f", source.path, "-C", root.path],
                                   token: token)
        }
        if let quarantine {
            try FileOpsQuarantine.propagate(quarantine, to: root, fileManager: fm, set: markQuarantine)
        }

        // Every entry, "._…" files included (FileManager would hide them).
        let entries = try FileOpsDirectory.entries(atPath: root.path).map { root.appendingPathComponent($0) }
        if entries.count == 1, let only = entries.first {
            return try moveIntoPlace(only, directory: parent, name: only.lastPathComponent,
                                     isDirectory: FileOpsNaming.isDirectory(only, fileManager: fm),
                                     fileManager: fm)
        }
        return try moveIntoPlace(root, directory: parent,
                                 name: extractedFolderName(forArchiveNamed: archive.lastPathComponent),
                                 isDirectory: true, fileManager: fm)
    }

    /// ditto restores resource forks, extended attributes (a stored
    /// com.apple.quarantine among them) and ACLs from a zip's __MACOSX folder
    /// unless told not to; --norsrc makes it extract that folder as plain files
    /// instead, which `extract` deletes. The archive's own quarantine is set
    /// afterwards, as for tar.
    static let dittoExtractOptions = ["--norsrc", "--noextattr", "--noqtn", "--noacl"]

    /// Never restore extended attributes (or ACLs / file flags) stored in a
    /// tarball: a stored com.apple.quarantine would otherwise land after
    /// bsdtar's own propagation, and an immutable flag would pin the staging
    /// folder. Only the non-macOS fallback (GNU tar) lacks --no-mac-metadata.
    static var tarExtractOptions: [String] {
        #if os(macOS)
        return ["--no-xattrs", "--no-mac-metadata", "--no-acls", "--no-fflags"]
        #else
        return ["--no-xattrs", "--no-acls"]
        #endif
    }

    // MARK: Helpers

    /// Deletes a staging folder even when the archive left read-only items in
    /// it: a 0555 or 0111 folder can't have its children removed, which would
    /// strand the whole tree in the temporary folder.
    static func removeStaging(_ staging: URL, fileManager fm: FileManager) {
        if (try? fm.removeItem(at: staging)) != nil { return }
        FileOpsPermissions.makeTreeWritable(staging, fileManager: fm)
        try? fm.removeItem(at: staging)
    }

    /// A private, empty folder on the same volume as `directory` when possible,
    /// so the final move is a cheap rename.
    static func makeStagingDirectory(near directory: URL, fileManager fm: FileManager) throws -> URL {
        if let dir = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: directory, create: true) {
            return dir
        }
        let dir = fm.temporaryDirectory.appendingPathComponent("selway-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Moves `item` into `directory` under a free variant of `name`, never
    /// replacing an existing item (it retries with the next free name if one
    /// appears in between).
    static func moveIntoPlace(_ item: URL, directory: URL, name: String, isDirectory: Bool,
                              fileManager fm: FileManager) throws -> URL {
        var lastError: Error?
        for _ in 0..<8 {
            let dest = FileOpsNaming.uniqueURL(in: directory, name: name, isDirectory: isDirectory, fileManager: fm)
            do {
                try FileOpsTransfer.moveWithoutReplacing(item, to: dest, fileManager: fm)
                return dest
            } catch let e as CocoaError where e.code == .fileWriteFileExists {
                lastError = e
            } catch FileOpsError.movedButOriginalRemains {
                return dest   // the leftover is in staging, which is deleted anyway
            }
        }
        throw lastError ?? CocoaError(.fileWriteFileExists)
    }
}

/// Reads and copies the `com.apple.quarantine` extended attribute.
enum FileOpsQuarantine {
    static let attributeName = "com.apple.quarantine"

    /// The item's quarantine value, or nil when it has none (or can't have
    /// one: the volume doesn't support extended attributes). Any other failure
    /// throws `quarantineUnreadable`, so a caller never mistakes "couldn't
    /// tell" for "not quarantined". Doesn't follow a symlink at `url`.
    static func read(_ url: URL) throws -> Data? {
        #if canImport(Darwin)
        let unreadable = FileOpsError.quarantineUnreadable(url.lastPathComponent)
        func absent(_ err: Int32) -> Bool { err == ENOATTR || err == ENOTSUP }
        let size = getxattr(url.path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 { if absent(errno) { return nil }; throw unreadable }
        guard size > 0 else { throw unreadable }   // an empty value isn't a valid one
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, attributeName, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read > 0 else { throw unreadable }   // changed or removed in between
        return data.prefix(read)
        #else
        return nil
        #endif
    }

    /// `read`, with any failure reported as nil (tests and display only).
    static func value(of url: URL) -> Data? {
        (try? read(url)) ?? nil
    }

    @discardableResult
    static func set(_ value: Data, on url: URL) -> Bool {
        #if canImport(Darwin)
        return value.withUnsafeBytes {
            setxattr(url.path, attributeName, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) == 0
        }
        #else
        return false
        #endif
    }

    /// Gives `root` and everything under it the archive's quarantine value (see
    /// `propagate(_:to:)`); does nothing only when the archive truly has none.
    /// Throws `quarantineUnreadable` when it can't be read.
    static func propagate(from archive: URL, to root: URL, fileManager fm: FileManager,
                          set: (Data, URL) -> Bool = FileOpsQuarantine.set) throws {
        guard let q = try read(archive) else { return }
        try propagate(q, to: root, fileManager: fm, set: set)
    }

    /// Gives `root` and everything under it the quarantine value `q`,
    /// replacing any value the archive itself carried in (an attacker can store
    /// one with the "user approved" bit set). Symlinks are skipped (Gatekeeper
    /// checks the item they point to). Items without owner write permission get
    /// it just long enough to set the attribute, and folders without read or
    /// search permission are opened just long enough to be walked; every mode
    /// is restored. Throws if any item couldn't be marked or walked.
    static func propagate(_ q: Data, to root: URL, fileManager fm: FileManager,
                          set: (Data, URL) -> Bool = FileOpsQuarantine.set) throws {
        var failures = 0
        func visit(_ url: URL) {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { failures += 1; return }
            let type = attrs[.type] as? FileAttributeType
            if type == .typeSymbolicLink { return }
            let isDir = type == .typeDirectory
            let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            // Owner needs write to set an xattr, and read + search to list a folder.
            let needed = isDir ? 0o700 : 0o200
            let opened = mode & needed != needed
            if opened {
                guard (try? fm.setAttributes([.posixPermissions: mode | needed], ofItemAtPath: url.path)) != nil
                else { failures += 1; return }
            }
            defer {
                if opened {
                    if (try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)) == nil { failures += 1 }
                }
            }
            if !set(q, url) { failures += 1 }
            if isDir {
                // Not FileManager's listing: it hides files named "._…".
                guard let children = try? FileOpsDirectory.entries(atPath: url.path) else { failures += 1; return }
                for name in children { visit(url.appendingPathComponent(name)) }
            }
        }
        visit(root)
        if failures > 0 { throw FileOpsError.quarantineFailed(failures) }
    }
}

/// Permission repair for trees Selway created itself (extraction staging).
enum FileOpsPermissions {
    /// Adds owner read/write (and search, for folders) to `root` and everything
    /// under it, without following symlinks, so the tree can be deleted.
    static func makeTreeWritable(_ root: URL, fileManager fm: FileManager) {
        guard let attrs = try? fm.attributesOfItem(atPath: root.path),
              attrs[.type] as? FileAttributeType != .typeSymbolicLink else { return }
        let isDir = attrs[.type] as? FileAttributeType == .typeDirectory
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let needed = isDir ? 0o700 : 0o600
        if mode & needed != needed {
            try? fm.setAttributes([.posixPermissions: mode | needed], ofItemAtPath: root.path)
        }
        guard isDir, let children = try? FileOpsDirectory.entries(atPath: root.path) else { return }
        for name in children { makeTreeWritable(root.appendingPathComponent(name), fileManager: fm) }
    }
}

/// Directory listing for tree walks that must see every entry.
enum FileOpsDirectory {
    /// Every name in the folder at `path`, except "." and "..". Unlike FileManager's
    /// listings and enumerators on Darwin, which leave out regular files whose names
    /// start with "._" (AppleDouble names, even orphans), nothing is filtered. The
    /// folder is opened without following a link at `path` (a link throws). Throws
    /// if the folder can't be read to the end, or holds a name that isn't UTF-8 (it
    /// couldn't be addressed by path), so a walk built on it fails closed.
    static func entries(atPath path: String) throws -> [String] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard let dir = fdopendir(fd) else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { closedir(dir) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return names
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String? in
                let bytes = Array(raw.prefix(while: { $0 != 0 }))
                let decoded = String(decoding: bytes, as: UTF8.self)
                return Array(decoded.utf8) == bytes ? decoded : nil   // nil: not valid UTF-8
            }
            guard let name else { throw POSIXError(.EILSEQ) }
            if name != "." && name != ".." { names.append(name) }
        }
    }
}
