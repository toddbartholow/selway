import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - On-disk state used to detect external changes

/// A file system object's device and inode.
struct FileIdentity: Hashable, Sendable {
    var device: UInt64
    var inode: UInt64
}

/// Who may use a file: its permission bits, group and extended ACL (macOS).
struct FilePermissions: Equatable, Sendable {
    var mode: UInt32
    var group: UInt32
    var acl: String?
}

/// What a file looked like when an editor last read or wrote it. Any difference
/// (another app saved, replaced or deleted it) means the buffer is out of date.
struct TextFileSnapshot: Equatable, Sendable {
    var modificationDate: Date?
    var size: UInt64
    /// Inode and device: atomic saves by other apps replace the inode even when
    /// the date and size happen to match.
    var fileNumber: UInt64?
    var deviceNumber: UInt64?
    /// The owner: with the inode, tells the file that was loaded from one created
    /// at the name since (some file systems reuse a freed inode number at once).
    var owner: UInt32? = nil
    /// The folder the file is in. A save only ever writes into this folder: if
    /// another folder (or a link to one) now sits at its path, the save is refused.
    var folder: FileIdentity? = nil
    /// The permissions the file had when it was loaded or saved. Not compared: a
    /// new file put at the name (the original was deleted, or replaced by one
    /// that isn't the user's) gets these, never wider ones.
    var permissions: FilePermissions? = nil

    static func == (a: TextFileSnapshot, b: TextFileSnapshot) -> Bool {
        a.modificationDate == b.modificationDate && a.size == b.size
            && a.fileNumber == b.fileNumber && a.deviceNumber == b.deviceNumber
            && a.owner == b.owner && a.folder == b.folder
    }
}

/// A file read for editing, plus everything needed to write it back safely.
struct LoadedTextFile {
    /// The URL the user opened (may be a symlink).
    let url: URL
    /// The file actually read and written: symlinks resolved, canonical path.
    /// Saves go here, never to wherever `url` happens to point later.
    let resolvedURL: URL
    var text: String
    var format: TextFileFormat
    var snapshot: TextFileSnapshot
}

/// The result of a save: the new snapshot, and the path the file is at now. That
/// path differs from the one saved to only when the file or a folder above it was
/// renamed in a way that kept it the same file (a case-only rename on a
/// case-insensitive volume); editors adopt it as their `resolvedURL`.
struct SavedTextFile {
    var snapshot: TextFileSnapshot
    var resolvedURL: URL
}

enum TextFileIOError: LocalizedError, Equatable {
    case binary
    case undecodable
    case tooLarge(UInt64)
    case notRegularFile
    case unencodable(encodingName: String)
    case changedOnDisk
    case notWritable
    /// The path that was opened now leads somewhere else (it, or a folder above it,
    /// was replaced by a symlink). Never followed: the destination is in `to`.
    case redirected(to: String)
    /// The folder at this path is no longer the one the file was opened in (it was
    /// replaced by another folder). Nothing is written into the new one.
    case folderReplaced(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .binary:
            return NSLocalizedString("It looks like a binary file, so it can't be edited as text.", comment: "Text editor error")
        case .undecodable:
            return NSLocalizedString("Its text encoding couldn't be detected, so editing it could corrupt it.", comment: "Text editor error")
        case .tooLarge(let size):
            let mb = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            return String.localizedStringWithFormat(NSLocalizedString("It is too large to edit (%@).", comment: "Text editor error with file size"), mb)
        case .notRegularFile:
            return NSLocalizedString("It isn't a regular file.", comment: "Text editor error")
        case .unencodable(let name):
            return String.localizedStringWithFormat(NSLocalizedString("It contains characters that can't be saved as %@.", comment: "Text editor encoding error"), name)
        case .changedOnDisk:
            return NSLocalizedString("The file was changed by another application.", comment: "Text editor save error")
        case .notWritable:
            return NSLocalizedString("You don't have permission to write to it.", comment: "Text editor save error")
        case .redirected(let path):
            return String.localizedStringWithFormat(NSLocalizedString("Since you opened it, it was replaced by a link to “%@”. Selway doesn't follow that link, so nothing was read from or written to it.", comment: "Text editor safety error with link destination"), path)
        case .folderReplaced(let path):
            return String.localizedStringWithFormat(NSLocalizedString("Since you opened it, the folder “%@” was replaced by a different folder. Selway didn't write into it.", comment: "Text editor safety error with folder path"), path)
        case .io(let message):
            return message
        }
    }
}

/// Test-only hooks into `TextFileIO.load` and `save`, to reproduce races and
/// failures deterministically. Production callers never pass them.
struct TextFileIOHooks {
    enum Checkpoint: CaseIterable, Sendable {
        /// load: after the path was resolved, before anything is opened.
        /// save: after the folder and the file were opened and checked.
        case afterPathCheck
        /// save: the private scratch folder was just made, not yet opened.
        case scratchFolderCreated
        /// save: just before the new bytes are written.
        case beforeWrite
        /// save: the private temporary copy was just created, empty.
        case temporaryCreated
        /// save: after the bytes were written, before metadata is applied.
        case beforeMetadata
    }
    var checkpoint: ((Checkpoint) -> Void)? = nil
    /// Called before each write of the file's bytes with the number already
    /// written; returning an errno makes that write fail with it.
    var failWrite: ((Int) -> Int32?)? = nil
    /// Stands in for `geteuid()` when deciding whose file it is (tests can't chown).
    var effectiveUser: uid_t? = nil
    /// Stands in for the volume's free space.
    var freeSpace: UInt64? = nil
    /// Make recreating behave as on volumes without `RENAME_EXCL` / hard links.
    var exclusiveRenameUnsupported = false
    var hardLinksUnsupported = false
}

// MARK: - Load / save

/// Every read and write goes through a descriptor for the file's folder, opened
/// without following links and checked against the folder the file was loaded
/// from, then through `openat`/`renameat` relative to it. Renaming a folder on the
/// path (or swapping it for a link) after the check can't redirect anything: the
/// descriptor still refers to the folder that was checked.
enum TextFileIO {

    /// Larger files would stall the editors; open them with another app instead.
    static let maxEditableSize: UInt64 = 64 * 1024 * 1024

    /// The file a URL ultimately points at: every symlink resolved (the final one
    /// too, even when its target doesn't exist) and the canonical path (e.g.
    /// /private/var, not /var), so one file maps to one editor tab and a save can
    /// tell when the path it was given now leads somewhere else.
    static func resolved(_ url: URL) -> URL {
        URL(fileURLWithPath: resolvedPath(url.standardizedFileURL.path, depth: 0))
    }

    private static func resolvedPath(_ path: String, depth: Int) -> String {
        if let real = realpath(path, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        // Missing, or a dangling link: resolve the folder, then follow the last
        // component by hand (bounded, so a link loop can't spin).
        guard depth < 32, path != "/" else { return path }
        let ns = path as NSString
        let parent = resolvedPath(ns.deletingLastPathComponent, depth: depth + 1)
        let joined = (parent as NSString).appendingPathComponent(ns.lastPathComponent)
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: joined) {
            let absolute = dest.hasPrefix("/") ? dest : (parent as NSString).appendingPathComponent(dest)
            return resolvedPath((absolute as NSString).standardizingPath, depth: depth + 1)
        }
        return joined
    }

    static func isRegularFile(_ url: URL) -> Bool {
        fileInfo(resolved(url))?.isRegular ?? false
    }

    /// Current on-disk state of the file `url` resolves to, or nil when it doesn't
    /// exist (a dangling symlink counts as missing).
    static func snapshot(of url: URL) -> TextFileSnapshot? {
        let target = resolved(url)
        var st = stat()
        guard lstat(target.path, &st) == 0 else { return nil }
        var dir = stat()
        let folder = lstat(target.deletingLastPathComponent().path, &dir) == 0 ? identity(dir) : nil
        return snapshot(st, folder: folder)
    }

    /// True when two URLs name the same file (through symlinks, or hard links).
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        if resolved(a).path == resolved(b).path { return true }
        guard let sa = snapshot(of: a), let sb = snapshot(of: b),
              let fa = sa.fileNumber, let fb = sb.fileNumber else { return false }
        return fa == fb && sa.deviceNumber == sb.deviceNumber
    }

    /// Reads a file for editing. Throws instead of returning an empty or lossy buffer,
    /// because saving such a buffer would destroy the file.
    static func load(_ url: URL, hooks: TextFileIOHooks = .init()) throws -> LoadedTextFile {
        let target = resolved(url)
        hooks.checkpoint?(.afterPathCheck)
        let location: Location
        do { location = try locate(target, expectedFolder: nil) }
        catch is FolderMissing { throw TextFileIOError.io(NSLocalizedString("The file couldn't be found.", comment: "Text editor file access error")) }
        return try read(location, openedAs: url)
    }

    /// Reads a document again from `file`, the `resolvedURL` of an earlier load.
    /// Like `save`, refuses (`.redirected`) when that path now leads elsewhere, and
    /// (`.folderReplaced`) when its folder is no longer `expectedFolder`, the one in
    /// the document's snapshot; opening the file again with `load` trusts the new
    /// folder. A case-only rename of the file or a folder above it is followed (the
    /// result's `resolvedURL` has the new spelling).
    static func reload(_ file: URL, openedAs url: URL, expectedFolder: FileIdentity?) throws -> LoadedTextFile {
        let location: Location
        do { location = try locate(URL(fileURLWithPath: file.path), expectedFolder: expectedFolder) }
        catch is FolderMissing { throw TextFileIOError.io(NSLocalizedString("The file couldn't be found.", comment: "Text editor file access error")) }
        return try read(location, openedAs: url)
    }

    /// Whether the file differs from the snapshot taken when it was loaded or saved.
    static func hasChanged(_ url: URL, since snapshot: TextFileSnapshot?) -> Bool {
        self.snapshot(of: url) != snapshot
    }

    /// Writes `text` in `format` to `file`, the `resolvedURL` captured when the
    /// document was loaded. See `saveDocument`.
    @discardableResult
    static func save(_ text: String, format: TextFileFormat, to file: URL,
                     expected: TextFileSnapshot?, force: Bool = false,
                     hooks: TextFileIOHooks = .init()) throws -> TextFileSnapshot {
        try saveDocument(text, format: format, to: file, expected: expected, force: force, hooks: hooks).snapshot
    }

    /// Writes `text` in `format` to `file`, the `resolvedURL` captured when the
    /// document was loaded.
    ///
    /// The write goes into the folder the file was loaded from and nowhere else: if
    /// that path now leads elsewhere (it or a folder above it became a symlink) this
    /// throws `.redirected`, and if another folder now sits there `.folderReplaced`,
    /// even with `force`. A case-only rename of the file or a folder (same folder,
    /// same file) is followed; the result carries the new path.
    ///
    /// The file keeps its identity where possible: owner, group, mode, ACL, flags,
    /// hard links, creation date, tags and other extended attributes (including
    /// quarantine). A file that can't be swapped without losing some of that (other
    /// links to it, someone else's file, a folder that refuses the swap) is
    /// rewritten in place instead.
    ///
    /// - Parameter expected: the snapshot from load/last save. If the file no longer
    ///   matches it, throws `.changedOnDisk` (pass `force: true` to overwrite anyway).
    static func saveDocument(_ text: String, format: TextFileFormat, to file: URL,
                             expected: TextFileSnapshot?, force: Bool = false,
                             hooks: TextFileIOHooks = .init()) throws -> SavedTextFile {
        // Not standardizedFileURL: that strips /private, so the canonical path from
        // load would no longer match its own resolution.
        let target = URL(fileURLWithPath: file.path)
        let location: Location
        do {
            location = try locate(target, expectedFolder: expected?.folder)
        } catch is FolderMissing {
            // The folder was moved or deleted: there is nothing to save into.
            if !force && expected != nil { throw TextFileIOError.changedOnDisk }
            throw TextFileIOError.io(String.localizedStringWithFormat(NSLocalizedString("The folder “%@” no longer exists.", comment: "Text editor save error with folder path"), target.deletingLastPathComponent().path))
        }
        let dirfd = location.folder.fd

        // What is at the name now, never following a link.
        var st = stat()
        let exists: Bool
        if fstatat(dirfd, location.name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            if (st.st_mode & S_IFMT) == S_IFLNK { throw redirected(location.path) }
            exists = true
        } else if errno == ENOENT {
            exists = false
        } else {
            throw TextFileIOError.io(posixError("stat").localizedDescription)
        }
        let current = exists ? snapshot(st, folder: location.folderIdentity) : nil
        if !force && current != expected { throw TextFileIOError.changedOnDisk }

        let data: Data
        do { data = try TextFileCodec.encode(text, as: format) }
        catch { throw TextFileIOError.unencodable(encodingName: format.encodingName) }

        var file: Descriptor?
        if exists {
            guard (st.st_mode & S_IFMT) == S_IFREG else { throw TextFileIOError.notRegularFile }
            // An atomic rename would quietly replace a read-only file; respect its mode.
            let fd = openat(dirfd, location.name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else {
                switch errno {
                case EACCES, EPERM, EROFS: throw TextFileIOError.notWritable
                case ELOOP:                throw redirected(location.path)
                case ENOENT:               throw TextFileIOError.changedOnDisk
                default:                   throw TextFileIOError.io(posixError("open").localizedDescription)
                }
            }
            file = Descriptor(fd)
            var opened = stat()
            // Replaced between the check and the open: the check no longer applies.
            guard fstat(fd, &opened) == 0, identity(opened) == identity(st) else {
                throw TextFileIOError.changedOnDisk
            }
            st = opened
        }
        hooks.checkpoint?(.afterPathCheck)

        let written: stat
        do {
            hooks.checkpoint?(.beforeWrite)
            if let file {
                // Whether this is the file that was loaded, or one that took its
                // place and is being overwritten (force) after a conflict.
                let loaded = expected.map { $0.fileNumber == identity(st).inode
                                            && $0.deviceNumber == identity(st).device
                                            && $0.owner == UInt32(st.st_uid) } ?? false
                written = try writeExisting(location, file: file.fd, info: st, data: data,
                                            encoding: format.encoding, isLoadedFile: loaded,
                                            loadedPermissions: expected?.permissions, hooks: hooks)
            } else {
                // Moved or deleted and the user chose to save: create it again.
                written = try create(location, data: data, replacing: false,
                                     permissions: expected?.permissions, hooks: hooks)
            }
        } catch let error as TextFileIOError {
            throw error
        } catch {
            throw TextFileIOError.io(error.localizedDescription)
        }
        file = nil   // close it first: some file systems set the date on close

        var after = stat()
        guard fstatat(dirfd, location.name, &after, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw TextFileIOError.io(NSLocalizedString("The file disappeared after saving.", comment: "Text editor save error"))
        }
        // Something else already at the name: describe what was written, so the
        // next check sees the difference.
        let saved = identity(after) == identity(written) ? after : written
        // What the saved file now allows, for the next save to keep.
        var permissions = expected?.permissions
        let check = openat(dirfd, location.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if check >= 0 {
            var st = stat()
            if fstat(check, &st) == 0, identity(st) == identity(saved) { permissions = self.permissions(check, st) }
            close(check)
        }
        return SavedTextFile(snapshot: snapshot(saved, folder: location.folderIdentity, permissions: permissions),
                             resolvedURL: URL(fileURLWithPath: location.path))
    }

    // MARK: Finding the file

    /// An open descriptor, closed when the last reference goes away.
    private final class Descriptor {
        let fd: Int32
        init(_ fd: Int32) { self.fd = fd }
        deinit { close(fd) }
    }

    /// The folder a file is in, opened, and the file's name in it.
    private struct Location {
        let folder: Descriptor
        let folderPath: String
        let folderIdentity: FileIdentity
        let name: String
        var path: String { (folderPath as NSString).appendingPathComponent(name) }
    }

    private struct FolderMissing: Error {}

    #if canImport(Darwin)
    /// Fails (ELOOP) if any component of the path is a symlink, not just the last.
    private static let noLinksOnPath = O_NOFOLLOW_ANY
    #else
    private static let noLinksOnPath = O_NOFOLLOW
    #endif

    /// Opens the folder at `path` without following a link anywhere on the path.
    private static func openFolder(_ path: String) throws -> (Descriptor, FileIdentity) {
        var fd = open(path, O_RDONLY | O_DIRECTORY | noLinksOnPath | O_CLOEXEC)
        #if canImport(Darwin)
        // A folder the user may enter but not list: a search-only descriptor will do.
        if fd < 0 && errno == EACCES { fd = open(path, O_SEARCH | noLinksOnPath | O_CLOEXEC) }
        #endif
        guard fd >= 0 else {
            switch errno {
            case ELOOP:           throw redirected(path)
            case ENOENT, ENOTDIR: throw FolderMissing()
            default:              throw TextFileIOError.io(posixError("open “\(path)”").localizedDescription)
            }
        }
        let folder = Descriptor(fd)
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw TextFileIOError.io(posixError("stat").localizedDescription) }
        return (folder, identity(st))
    }

    /// Opens the folder of `target` (a canonical path from an earlier load), checks
    /// it is `expectedFolder` when that is known, and returns it with the file's name.
    ///
    /// When `target` now resolves to a different path, that path is used only if it
    /// leads to the same folder and the same directory entry, which is what a
    /// case-only rename on a case-insensitive volume looks like. Anything else (a
    /// link swapped in for the file or a folder) is `.redirected`.
    private static func locate(_ target: URL, expectedFolder: FileIdentity?) throws -> Location {
        let now = resolved(target)
        let folderPath = now.deletingLastPathComponent().path
        let opened: (Descriptor, FileIdentity)
        do { opened = try openFolder(folderPath) }
        catch TextFileIOError.redirected { throw redirected(target.path) }
        let (folder, id) = opened
        let name = now.lastPathComponent

        if now.path != target.path {
            // The same folder as the one at the old spelling (or the one loaded from)?
            let reference: FileIdentity
            if let expectedFolder {
                reference = expectedFolder
            } else {
                do { reference = try openFolder(target.deletingLastPathComponent().path).1 }
                catch { throw TextFileIOError.redirected(to: now.path) }
            }
            guard reference == id else { throw TextFileIOError.redirected(to: now.path) }
            // The same entry under both names (and never a link at the old one)?
            if name != target.lastPathComponent {
                var old = stat(), new = stat()
                guard fstatat(folder.fd, target.lastPathComponent, &old, AT_SYMLINK_NOFOLLOW) == 0,
                      fstatat(folder.fd, name, &new, AT_SYMLINK_NOFOLLOW) == 0,
                      (old.st_mode & S_IFMT) != S_IFLNK, identity(old) == identity(new) else {
                    throw TextFileIOError.redirected(to: now.path)
                }
            }
        }
        if let expectedFolder, expectedFolder != id {
            throw TextFileIOError.folderReplaced(folderPath)
        }
        return Location(folder: folder, folderPath: folderPath, folderIdentity: id, name: name)
    }

    private static func redirected(_ path: String) -> TextFileIOError {
        .redirected(to: resolved(URL(fileURLWithPath: path)).path)
    }

    // MARK: Reading

    private static func read(_ location: Location, openedAs url: URL) throws -> LoadedTextFile {
        // Never open what isn't a regular file: opening a serial device (a link
        // x.txt -> /dev/cu.*) can reset the board on it. Checked again on the
        // descriptor below, since the name can change in between.
        var pre = stat()
        if fstatat(location.folder.fd, location.name, &pre, AT_SYMLINK_NOFOLLOW) == 0,
           (pre.st_mode & S_IFMT) != S_IFREG {
            if (pre.st_mode & S_IFMT) == S_IFLNK { throw redirected(location.path) }
            throw TextFileIOError.notRegularFile
        }
        // Non-blocking: opening a FIFO must not hang (it is refused below).
        let fd = openat(location.folder.fd, location.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ENOENT: throw TextFileIOError.io(NSLocalizedString("The file couldn't be found.", comment: "Text editor file access error"))
            case ELOOP:  throw redirected(location.path)
            default:     throw TextFileIOError.io(posixError("open").localizedDescription)
            }
        }
        let file = Descriptor(fd)
        // Snapshot before reading: if the file changes mid-read, the next save sees
        // a mismatch and asks instead of silently overwriting.
        var st = stat()
        guard fstat(file.fd, &st) == 0 else { throw TextFileIOError.io(posixError("stat").localizedDescription) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw TextFileIOError.notRegularFile }
        let size = UInt64(max(0, st.st_size))
        guard size <= maxEditableSize else { throw TextFileIOError.tooLarge(size) }
        let data = try readAll(file.fd, limit: Int(maxEditableSize))
        do {
            let (text, format) = try TextFileCodec.decode(data)
            return LoadedTextFile(url: url, resolvedURL: URL(fileURLWithPath: location.path), text: text,
                                  format: format, snapshot: snapshot(st, folder: location.folderIdentity,
                                                                     permissions: permissions(file.fd, st)))
        } catch TextFileCodecError.binary {
            throw TextFileIOError.binary
        } catch {
            throw TextFileIOError.undecodable
        }
    }

    /// Reads `fd` from its start to its end; more than `limit` bytes is `.tooLarge`.
    private static func readAll(_ fd: Int32, limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var offset: off_t = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, offset) }
            if n < 0 {
                if errno == EINTR { continue }
                throw TextFileIOError.io(posixError("read").localizedDescription)
            }
            if n == 0 { return data }
            data.append(contentsOf: buffer[0..<n])
            offset += off_t(n)
            if data.count > limit { throw TextFileIOError.tooLarge(UInt64(data.count)) }
        }
    }

    // MARK: Writing

    /// Thrown before swapping when the replacement can't be given the original's
    /// owner and group (e.g. its group is one the user doesn't belong to).
    private struct CannotKeepOwnership: Error {}

    /// The scratch folder couldn't be made private on a volume that ignores ownership
    /// (FAT and exFAT, often reported as rwxrwxrwx, without ACLs): there is no private
    /// place to stage a copy, so the file is rewritten in place instead.
    private struct NoPrivateScratch: Error {}

    private static func shouldWriteInPlace(after error: Error) -> Bool {
        error is CannotKeepOwnership || error is NoPrivateScratch || isPermissionDenied(error)
    }

    /// True for a volume that ignores ownership (MNT_IGNORE_OWNERSHIP): its owners and
    /// modes are made up, so they can't make anything private.
    static func ignoresOwnership(_ fd: Int32) -> Bool {
        #if canImport(Darwin)
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { return false }
        return fs.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0
        #else
        return false
        #endif
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EACCES) || ns.code == Int(EPERM) { return true }
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionDenied(underlying) }
        return false
    }

    /// What a new file takes from the file it replaces.
    private enum MetadataToCopy { case nothing, quarantineOnly, all }

    /// Whether a file with `permissions` lets no one do anything that `loaded`
    /// doesn't: no mode bits beyond the loaded ones, group bits only for the same
    /// group, and no ACL unless it is the loaded one.
    private static func isNoMoreOpen(_ permissions: FilePermissions, than loaded: FilePermissions?) -> Bool {
        guard let loaded else { return false }
        let mode = permissions.mode & 0o777
        guard mode & ~(loaded.mode & 0o777) == 0 else { return false }
        if mode & 0o070 != 0, permissions.group != loaded.group { return false }
        return permissions.acl == nil || permissions.acl == loaded.acl
    }

    /// Saves over the open, checked file `fd` (whose `stat` is `info`). Returns the
    /// `stat` of the file now holding the text.
    private static func writeExisting(_ location: Location, file fd: Int32, info: stat, data: Data,
                                      encoding: String.Encoding, isLoadedFile: Bool,
                                      loadedPermissions: FilePermissions?,
                                      hooks: TextFileIOHooks) throws -> stat {
        guard isLoadedFile else {
            // Not the file that was loaded (Overwrite after a conflict): whoever put it
            // there may have linked it to another of the user's files, may own it and
            // read what is written into it, or may have given it wider permissions.
            // Put a new file at the name, with the loaded file's permissions, and
            // leave that one alone. When it is the user's own, single-link file no
            // more open than the loaded one (the ordinary case: another app saved
            // atomically) the new file keeps what it carries besides permissions:
            // tags, quarantine, other extended attributes, the hidden flag and the
            // creation date. One of the user's files that is more open (moved there
            // by someone who can write the folder) gives only its quarantine, which
            // only restricts; a planted hard link or someone else's file, nothing.
            let usersOwn = info.st_nlink == 1 && info.st_uid == (hooks.effectiveUser ?? geteuid())
            let metadata: MetadataToCopy = !usersOwn ? .nothing
                : isNoMoreOpen(permissions(fd, info), than: loadedPermissions) ? .all : .quarantineOnly
            return try create(location, data: data, replacing: true, permissions: loadedPermissions,
                              metadataFrom: metadata == .nothing ? nil : (fd, info, encoding, metadata),
                              hooks: hooks)
        }
        // A swap gives the path a new inode: other hard links would keep the old text
        // (while the editor treats them as the same file), and someone else's file
        // would become ours. Overwrite those in place.
        if info.st_nlink > 1 || info.st_uid != (hooks.effectiveUser ?? geteuid()) {
            return try writeInPlace(fd, info: info, data: data, encoding: encoding, hooks: hooks)
        }
        do {
            return try replace(location, original: fd, info: info, data: data, encoding: encoding, hooks: hooks)
        } catch let error where shouldWriteInPlace(after: error) {
            // The folder refuses the swap (no write access, a deny-delete ACL) or the
            // group can't be kept, but the file itself is open for writing.
            return try writeInPlace(fd, info: info, data: data, encoding: encoding, hooks: hooks)
        }
    }

    /// Overwrites the bytes of the open, checked file. The new bytes are written
    /// before the file is cut to length, and if writing fails the original bytes are
    /// put back, so a full disk doesn't leave the file truncated.
    private static func writeInPlace(_ fd: Int32, info: stat, data: Data, encoding: String.Encoding,
                                     hooks: TextFileIOHooks) throws -> stat {
        let originalSize = Int(info.st_size)
        let backup: Data? = originalSize <= Int(maxEditableSize)
            ? (try? readAll(fd, limit: Int(maxEditableSize))) : nil
        // Copy-on-write volumes need new blocks for every byte overwritten, and
        // putting the original back after a failure needs as many again: refuse up
        // front unless there is room for both.
        let needed = UInt64(data.count) + UInt64(backup?.count ?? originalSize)
        if let free = hooks.freeSpace ?? freeSpace(fd), free < needed {
            let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: needed), countStyle: .file)
            throw TextFileIOError.io(String.localizedStringWithFormat(NSLocalizedString("There isn't enough free space on the disk to save it safely. Saving it in place needs %@ free: room for the new text and for putting the original back if writing fails.", comment: "Text editor save error with required disk space"), size))
        }
        do {
            try writeAll(fd, data, hooks: hooks)
            guard ftruncate(fd, off_t(data.count)) == 0 else { throw posixError("truncate") }
            guard fsync(fd) == 0 else { throw posixError("fsync") }
        } catch {
            if let backup {
                try? writeAll(fd, backup, hooks: TextFileIOHooks())
                _ = ftruncate(fd, off_t(backup.count))
                _ = fsync(fd)
            }
            throw error
        }
        hooks.checkpoint?(.beforeMetadata)
        #if canImport(Darwin)
        // Same inode, so everything else stays; only the recorded encoding may change.
        if let value = fxattr(fd, textEncodingAttribute) {
            let wanted = Data(textEncodingValue(original: String(decoding: value, as: UTF8.self),
                                                saved: encoding).utf8)
            if value != wanted { _ = setFxattr(fd, textEncodingAttribute, wanted) }
        }
        #endif
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw posixError("fstat") }
        return st
    }

    /// Free bytes on the volume holding `fd`, if known.
    private static func freeSpace(_ fd: Int32) -> UInt64? {
        #if canImport(Darwin)
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { return nil }
        return UInt64(fs.f_bavail) &* UInt64(fs.f_bsize)
        #else
        var fs = statvfs()
        guard fstatvfs(fd, &fs) == 0 else { return nil }
        return UInt64(fs.f_bavail) &* UInt64(fs.f_frsize)
        #endif
    }

    /// Writes `data` at the start of `fd`, retrying short writes.
    private static func writeAll(_ fd: Int32, _ data: Data, hooks: TextFileIOHooks) throws {
        let chunk = 64 * 1024
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < buf.count {
                if let injected = hooks.failWrite?(offset) {
                    errno = injected
                    throw posixError("write")
                }
                let n = pwrite(fd, base + offset, min(chunk, buf.count - offset), off_t(offset))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write")
                }
                offset += n
            }
        }
    }

    /// A hidden name for the scratch folder of a save of `name`, at most 81 bytes,
    /// so even a 255-byte name gets one the file system accepts.
    static func temporaryName(for name: String) -> String {
        var stem = String.UnicodeScalarView()
        var bytes = 0
        for scalar in name.unicodeScalars {
            let size = String(scalar).utf8.count
            guard bytes + size <= 32 else { break }
            stem.append(scalar)
            bytes += size
        }
        return ".\(String(stem)).selwaysave-\(UUID().uuidString)"
    }

    /// Runs `body` with a new, empty temporary file that only the user can reach:
    /// it is created inside a scratch folder made for this save in the file's
    /// folder (mode 700, no ACL, checked to be ours), so it inherits nothing from
    /// the file's folder and nobody else can look it up, even with a descriptor
    /// for the scratch folder opened before its ACL was cleared. `body` gets the
    /// scratch folder, the file's name in it and its descriptor, and sets `moved`
    /// once the file was renamed or linked out. Otherwise it is emptied and
    /// removed; the scratch folder is removed either way.
    private static func withPrivateTemporary<T>(
        _ location: Location, hooks: TextFileIOHooks,
        _ body: (_ scratch: Int32, _ name: String, _ fd: Int32, _ moved: inout Bool) throws -> T
    ) throws -> T {
        let dirfd = location.folder.fd
        let scratchName = temporaryName(for: location.name)
        guard mkdirat(dirfd, scratchName, 0o700) == 0 else { throw posixError("create a temporary folder") }
        hooks.checkpoint?(.scratchFolderCreated)
        let sfd = openat(dirfd, scratchName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sfd >= 0 else {
            let error = posixError("open the temporary folder")
            _ = unlinkat(dirfd, scratchName, AT_REMOVEDIR)
            throw error
        }
        let scratch = Descriptor(sfd)
        var sst = stat()
        // Not the folder just made (someone who can write the folder renamed another
        // in, perhaps one of the user's own): leave it alone, its ACL and mode too.
        // mkdirat(0700) gives no permission bits beyond the owner's, whatever the
        // umask (setgid comes from the parent on Linux), and the folder can only have
        // ACL entries inherited from its parent.
        #if canImport(Darwin)
        let onlyInheritedACL = hasOnlyInheritedACLEntries(scratch.fd)
        #else
        let onlyInheritedACL = true
        #endif
        let statted = fstat(scratch.fd, &sst) == 0
        guard statted, sst.st_uid == geteuid(), (sst.st_mode & S_IFMT) == S_IFDIR,
              sst.st_mode & 0o7777 & ~0o2700 == 0, onlyInheritedACL else {
            if statted, (sst.st_mode & S_IFMT) == S_IFDIR, ignoresOwnership(scratch.fd) {
                // Made-up owners and modes, not a replaced folder: remove it (if the
                // name still holds it; only an empty folder goes) and write in place.
                var now = stat()
                if fstatat(dirfd, scratchName, &now, AT_SYMLINK_NOFOLLOW) == 0, identity(now) == identity(sst) {
                    _ = unlinkat(dirfd, scratchName, AT_REMOVEDIR)
                }
                throw NoPrivateScratch()
            }
            throw TextFileIOError.io(NSLocalizedString("The temporary folder for saving was replaced, so nothing was written.", comment: "Text editor save safety error"))
        }
        let scratchIdentity = identity(sst)
        defer {
            // Only if the name still holds this folder: if it was renamed away, whatever
            // was put at the name instead isn't ours to remove.
            var now = stat()
            if fstatat(dirfd, scratchName, &now, AT_SYMLINK_NOFOLLOW) == 0, identity(now) == scratchIdentity {
                _ = unlinkat(dirfd, scratchName, AT_REMOVEDIR)
            }
            _ = scratch
        }
        #if canImport(Darwin)
        // The folder's inheritable ACL entries were just added to it.
        guard clearACL(scratch.fd), !hasACLEntries(scratch.fd) else {
            if ignoresOwnership(scratch.fd) { throw NoPrivateScratch() }
            throw posixError("make the temporary folder private")
        }
        #endif
        guard fchmod(scratch.fd, 0o700) == 0, fstat(scratch.fd, &sst) == 0, sst.st_uid == geteuid(),
              identity(sst) == scratchIdentity, sst.st_mode & 0o7777 == 0o700 else {
            if ignoresOwnership(scratch.fd) { throw NoPrivateScratch() }
            throw posixError("make the temporary folder private")
        }

        let tempName = "text"
        let tfd = openat(scratch.fd, tempName, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard tfd >= 0 else { throw posixError("create a temporary copy") }
        let temp = Descriptor(tfd)
        var moved = false
        defer {
            if moved { _ = unlinkat(scratch.fd, tempName, 0) }   // a hard link may remain
            else { discardTemporary(temp.fd, named: tempName, in: scratch.fd) }
        }
        #if canImport(Darwin)
        guard clearACL(temp.fd) else { throw posixError("make the temporary copy private") }
        #endif
        hooks.checkpoint?(.temporaryCreated)
        return try body(scratch.fd, tempName, temp.fd, &moved)
    }

    /// Writes a private temporary copy, gives it the original's owner, group, mode,
    /// extended attributes, flags, creation date and ACL, then renames it over the
    /// original. The temporary copy is removed whatever happens: it holds the text.
    private static func replace(_ location: Location, original: Int32, info: stat, data: Data,
                                encoding: String.Encoding, hooks: TextFileIOHooks) throws -> stat {
        let dirfd = location.folder.fd
        return try withPrivateTemporary(location, hooks: hooks) { scratch, tempName, tfd, moved in
            guard fchown(tfd, info.st_uid, info.st_gid) == 0 else { throw CannotKeepOwnership() }
            try writeAll(tfd, data, hooks: hooks)
            hooks.checkpoint?(.beforeMetadata)
            #if canImport(Darwin)
            copyExtendedAttributes(from: original, to: tfd, savedEncoding: encoding)
            #endif
            // Owner bits only until the ACL (which may deny others) is in place.
            guard fchmod(tfd, info.st_mode & 0o700) == 0 else { throw posixError("chmod") }
            #if canImport(Darwin)
            let flags = info.st_flags & UInt32(UF_HIDDEN)
            if flags != 0 { _ = fchflags(tfd, flags) }
            setCreationDate(tfd, info.st_birthtimespec)
            // After the steps above: an ACL may deny the owner what they need.
            copyACL(from: original, to: tfd)
            #endif
            guard fchmod(tfd, info.st_mode & 0o7777) == 0 else { throw posixError("chmod") }
            guard fsync(tfd) == 0 else { throw posixError("fsync") }
            guard renameat(scratch, tempName, dirfd, location.name) == 0 else { throw posixError("rename") }
            moved = true
            var st = stat()
            guard fstat(tfd, &st) == 0 else { throw posixError("fstat") }
            return st
        }
    }

    /// Puts a new file holding `data` at the name, written privately (mode 600, no
    /// ACL) and given `permissions` (the loaded file's; none known: it stays
    /// private) only once it is in place. With `replacing`, whatever is at the name
    /// is replaced (unlinked, never written into); otherwise (recreating a file
    /// that was moved or deleted) a file that appeared at the name meanwhile is
    /// never replaced: that is `.changedOnDisk`. `metadataFrom` is an open file
    /// (and its `stat`) whose extended attributes, hidden flag and creation date
    /// (or only its quarantine) the new file gets; never its owner, group, mode or
    /// ACL.
    private static func create(_ location: Location, data: Data, replacing: Bool,
                               permissions: FilePermissions?,
                               metadataFrom donor: (fd: Int32, info: stat, encoding: String.Encoding,
                                                    what: MetadataToCopy)? = nil,
                               hooks: TextFileIOHooks) throws -> stat {
        let dirfd = location.folder.fd
        let name = location.name
        do {
            return try createStaged(location, data: data, replacing: replacing, permissions: permissions,
                                    metadataFrom: donor, hooks: hooks)
        } catch is NoPrivateScratch where !replacing {
            // A volume that ignores ownership (FAT, exFAT) has no private place to stage
            // the text, nor any privacy to keep or hard links to fear: create the file
            // directly, never over anything already at the name.
            let fd = openat(dirfd, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw posixError("create the file") }
            let file = Descriptor(fd)
            do {
                try writeAll(file.fd, data, hooks: hooks)
                guard fsync(file.fd) == 0 else { throw posixError("fsync") }
            } catch {
                _ = unlinkat(dirfd, name, 0)
                throw error
            }
            var st = stat()
            guard fstat(file.fd, &st) == 0 else { throw posixError("fstat") }
            return st
        } catch is NoPrivateScratch {
            throw TextFileIOError.io(NSLocalizedString("This disk (FAT or exFAT) has no private place to prepare the save, so the file that is there now was left alone.", comment: "Text editor save error on FAT or exFAT volume"))
        }
    }

    private static func createStaged(_ location: Location, data: Data, replacing: Bool,
                                     permissions: FilePermissions?,
                                     metadataFrom donor: (fd: Int32, info: stat, encoding: String.Encoding,
                                                          what: MetadataToCopy)?,
                                     hooks: TextFileIOHooks) throws -> stat {
        let dirfd = location.folder.fd
        let name = location.name
        return try withPrivateTemporary(location, hooks: hooks) { scratch, tempName, tfd, moved in
            try writeAll(tfd, data, hooks: hooks)
            hooks.checkpoint?(.beforeMetadata)
            #if canImport(Darwin)
            if let donor, donor.what == .all {
                copyExtendedAttributes(from: donor.fd, to: tfd, savedEncoding: donor.encoding)
                let flags = donor.info.st_flags & UInt32(UF_HIDDEN)
                if flags != 0 { _ = fchflags(tfd, flags) }
                setCreationDate(tfd, donor.info.st_birthtimespec)
            } else if let donor, donor.what == .quarantineOnly,
                      let quarantine = fxattr(donor.fd, quarantineAttribute) {
                _ = setFxattr(tfd, quarantineAttribute, quarantine)
            }
            #endif
            guard fsync(tfd) == 0 else { throw posixError("fsync") }
            try install(from: scratch, tempName, to: dirfd, name, replacing: replacing, moved: &moved, hooks: hooks)
            apply(permissions, to: tfd)
            var st = stat()
            guard fstat(tfd, &st) == 0 else { throw posixError("fstat") }
            return st
        }
    }

    /// Moves the temporary copy to `name` in `dirfd`. Unless `replacing`, never
    /// replaces anything there: an exclusive rename, else a hard link, else (no
    /// hard links either, e.g. exFAT) an empty private placeholder claimed with
    /// O_EXCL and then renamed over. The text is never written outside the
    /// scratch folder.
    private static func install(from scratch: Int32, _ tempName: String, to dirfd: Int32, _ name: String,
                                replacing: Bool, moved: inout Bool, hooks: TextFileIOHooks) throws {
        if replacing {
            guard renameat(scratch, tempName, dirfd, name) == 0 else { throw posixError("rename") }
            moved = true
            return
        }
        #if canImport(Darwin)
        if !hooks.exclusiveRenameUnsupported {
            if renameatx_np(scratch, tempName, dirfd, name, UInt32(RENAME_EXCL)) == 0 { moved = true; return }
            if errno == EEXIST { throw TextFileIOError.changedOnDisk }
            guard errno == ENOTSUP || errno == EINVAL else { throw posixError("rename") }
        }
        #endif
        if !hooks.hardLinksUnsupported {
            if linkat(scratch, tempName, dirfd, name, 0) == 0 {
                // Drop the scratch link now, before the loaded ACL (which may deny
                // deleting the file) is applied: left behind, it would keep a second
                // link to the text and make every later save write in place.
                _ = unlinkat(scratch, tempName, 0)
                moved = true
                return
            }
            if errno == EEXIST { throw TextFileIOError.changedOnDisk }
        }
        let placeholder = openat(dirfd, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard placeholder >= 0 else {
            if errno == EEXIST { throw TextFileIOError.changedOnDisk }
            throw posixError("create the file")
        }
        var claimed = stat()
        let statted = fstat(placeholder, &claimed) == 0
        close(placeholder)
        var now = stat()
        guard statted, fstatat(dirfd, name, &now, AT_SYMLINK_NOFOLLOW) == 0, identity(now) == identity(claimed) else {
            throw TextFileIOError.changedOnDisk
        }
        guard renameat(scratch, tempName, dirfd, name) == 0 else {
            let error = posixError("rename")
            if fstatat(dirfd, name, &now, AT_SYMLINK_NOFOLLOW) == 0, identity(now) == identity(claimed) {
                _ = unlinkat(dirfd, name, 0)
            }
            throw error
        }
        moved = true
    }

    /// Gives a new file the loaded file's group, ACL and mode (in that order, so
    /// it is never wider than intended on the way). A group the user can't set is
    /// dropped along with the group's permission bits.
    private static func apply(_ permissions: FilePermissions?, to fd: Int32) {
        guard let permissions else { return }
        var mode = mode_t(permissions.mode & 0o777)
        if fchown(fd, uid_t.max, gid_t(permissions.group)) != 0 { mode &= ~mode_t(0o070) }
        #if canImport(Darwin)
        if let text = permissions.acl, let acl = acl_from_text(text) {
            _ = acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED)
            acl_free(UnsafeMutableRawPointer(acl))
        }
        #endif
        _ = fchmod(fd, mode)
    }

    /// Empties and removes a temporary copy that wasn't renamed into place. Its ACL
    /// (copied from the original) may deny deleting it, so that goes first.
    private static func discardTemporary(_ fd: Int32, named name: String, in dirfd: Int32) {
        _ = ftruncate(fd, 0)
        #if canImport(Darwin)
        clearACL(fd)
        #endif
        _ = unlinkat(dirfd, name, 0)
    }

    // MARK: POSIX helpers

    struct FileInfo {
        var owner: uid_t
        var group: gid_t
        var permissions: mode_t
        var isRegular: Bool
        var linkCount: Int
        var inode: UInt64
        var device: UInt64
    }

    /// `lstat` of exactly this path.
    static func fileInfo(_ url: URL) -> FileInfo? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let id = identity(st)
        return FileInfo(owner: st.st_uid, group: st.st_gid,
                        permissions: st.st_mode & 0o7777,
                        isRegular: (st.st_mode & S_IFMT) == S_IFREG,
                        linkCount: Int(st.st_nlink),
                        inode: id.inode, device: id.device)
    }

    private static func identity(_ st: stat) -> FileIdentity {
        FileIdentity(device: UInt64(truncatingIfNeeded: st.st_dev), inode: UInt64(truncatingIfNeeded: st.st_ino))
    }

    /// The permissions of the open file `fd` (whose `stat` is `st`).
    private static func permissions(_ fd: Int32, _ st: stat) -> FilePermissions {
        var acl: String?
        #if canImport(Darwin)
        if hasACLEntries(fd), let value = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            if let text = acl_to_text(value, nil) {
                acl = String(cString: text)
                acl_free(text)
            }
            acl_free(UnsafeMutableRawPointer(value))
        }
        #endif
        return FilePermissions(mode: UInt32(st.st_mode & 0o7777), group: UInt32(st.st_gid), acl: acl)
    }

    private static func snapshot(_ st: stat, folder: FileIdentity?,
                                 permissions: FilePermissions? = nil) -> TextFileSnapshot {
        #if canImport(Darwin)
        let mtime = st.st_mtimespec
        #else
        let mtime = st.st_mtim
        #endif
        let id = identity(st)
        return TextFileSnapshot(
            modificationDate: Date(timeIntervalSince1970: TimeInterval(mtime.tv_sec)
                                   + TimeInterval(mtime.tv_nsec) / 1_000_000_000),
            size: UInt64(max(0, st.st_size)),
            fileNumber: id.inode,
            deviceNumber: id.device,
            owner: UInt32(st.st_uid),
            folder: folder,
            permissions: permissions)
    }

    private static func posixError(_ what: String) -> Error {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(code)))"])
    }

    #if canImport(Darwin)
    // MARK: Extended attributes, ACLs, creation date (macOS)

    static let quarantineAttribute = "com.apple.quarantine"
    static let textEncodingAttribute = "com.apple.TextEncoding"

    /// The `com.apple.TextEncoding` value to keep after saving in `saved`.
    /// The original stays unless the file was converted to a Unicode encoding (Save
    /// as UTF-8): a guessed legacy encoding (Latin-1 vs. MacRoman) shouldn't
    /// overwrite what the creating app recorded.
    static func textEncodingValue(original: String, saved: String.Encoding) -> String {
        let parts = original.split(separator: ";", maxSplits: 1)
        if parts.count == 2, let cf = UInt32(parts[1].trimmingCharacters(in: .whitespaces)),
           CFStringConvertEncodingToNSStringEncoding(cf) == saved.rawValue {
            return original
        }
        let unicode: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian,
                                          .utf32, .utf32LittleEndian, .utf32BigEndian]
        guard unicode.contains(saved) else { return original }
        let cf = CFStringConvertNSStringEncodingToEncoding(saved.rawValue)
        guard let iana = CFStringConvertEncodingToIANACharSetName(cf) as String? else { return original }
        return "\(iana.lowercased());\(cf)"
    }

    /// Copies every extended attribute (quarantine, Finder info and tags, custom
    /// ones) from `src` to `dst`, with the text encoding updated for `savedEncoding`,
    /// and drops any that `dst` got and `src` doesn't have. Protected attributes the
    /// system won't let us set or remove stay as they are.
    private static func copyExtendedAttributes(from src: Int32, to dst: Int32, savedEncoding: String.Encoding) {
        let names = xattrNames(src)
        for name in names {
            guard var value = fxattr(src, name) else { continue }
            if name == textEncodingAttribute {
                value = Data(textEncodingValue(original: String(decoding: value, as: UTF8.self),
                                               saved: savedEncoding).utf8)
            }
            _ = setFxattr(dst, name, value)
        }
        for name in xattrNames(dst) where !names.contains(name) { _ = fremovexattr(dst, name, 0) }
    }

    private static func xattrNames(_ fd: Int32) -> [String] {
        let size = flistxattr(fd, nil, 0, 0)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let got = flistxattr(fd, &buffer, size, 0)
        guard got > 0 else { return [] }
        return buffer[0..<got].split(separator: 0).map { chars in
            String(decoding: chars.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    private static func fxattr(_ fd: Int32, _ name: String) -> Data? {
        let size = fgetxattr(fd, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        var data = Data(count: size)
        let got = data.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, size, 0, 0) }
        guard got >= 0 else { return nil }
        return data.prefix(got)
    }

    private static func setFxattr(_ fd: Int32, _ name: String, _ value: Data) -> Bool {
        value.withUnsafeBytes { fsetxattr(fd, name, $0.baseAddress, value.count, 0, 0) } == 0
    }

    /// Gives `dst` exactly `src`'s extended ACL (none if it has none).
    private static func copyACL(from src: Int32, to dst: Int32) {
        guard let acl = acl_get_fd_np(src, ACL_TYPE_EXTENDED) else { clearACL(dst); return }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        _ = acl_set_fd_np(dst, acl, ACL_TYPE_EXTENDED)
    }

    /// Whether the open item has any extended ACL entries.
    private static func hasACLEntries(_ fd: Int32) -> Bool {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0
    }

    /// True when the open item has no extended ACL entries other than ones inherited
    /// from its parent (what a folder just made by mkdir can have).
    private static func hasOnlyInheritedACLEntries(_ fd: Int32) -> Bool {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return true }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0 {
            which = ACL_NEXT_ENTRY.rawValue
            var flags: acl_flagset_t?
            guard let entry, acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags) == 0, let flags,
                  acl_get_flag_np(flags, ACL_ENTRY_INHERITED) == 1 else { return false }
        }
        return true
    }

    /// Removes every extended ACL entry; false if there were some and they stayed.
    @discardableResult
    private static func clearACL(_ fd: Int32) -> Bool {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return true }
        acl_free(UnsafeMutableRawPointer(acl))
        guard let empty = acl_init(0) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        return acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED) == 0
    }

    private static func setCreationDate(_ fd: Int32, _ date: timespec) {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var value = date
        _ = fsetattrlist(fd, &list, &value, MemoryLayout<timespec>.size, 0)
    }

    // Path-based helpers for tests and diagnostics. Saves never use them.

    static func xattr(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read >= 0 else { return nil }
        return data.prefix(read)
    }

    @discardableResult
    static func setXattr(_ path: String, _ name: String, _ value: Data) -> Bool {
        value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) } == 0
    }

    static func aclText(_ path: String) -> String? {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(text) }
        return String(cString: text)
    }

    /// Clears an extended ACL (no-op when there is none or the item is gone).
    static func removeACL(_ path: String) {
        guard aclText(path) != nil, let empty = acl_init(0) else { return }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        _ = acl_set_link_np(path, ACL_TYPE_EXTENDED, empty)
    }
    #endif
}
