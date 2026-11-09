import Foundation

/// A rename that changes, adds or removes a file's extension, which Selway asks
/// about first, as Finder does (Settings → Advanced → Warn before changing an
/// extension). Folders aren't asked about: their "extension" is only part of
/// the name.
enum FileOpsExtensionChange: Equatable, Sendable {
    case changing(from: String, to: String)
    case adding(String)
    case removing(String)

    /// nil when the extension stays the same (ignoring case, as Finder does).
    static func detect(oldName: String, newName: String) -> FileOpsExtensionChange? {
        let old = Self.extension(of: oldName), new = Self.extension(of: newName)
        switch (old, new) {
        case (nil, nil):
            return nil
        case let (nil, n?):
            return .adding(n)
        case let (o?, nil):
            return .removing(o)
        case let (o?, n?):
            return o.caseInsensitiveCompare(n) == .orderedSame ? nil : .changing(from: o, to: n)
        }
    }

    /// The text after the last dot, if it looks like an extension: not the
    /// whole name (".zshrc"), not empty ("notes."), no spaces ("Chapter 1. Intro").
    static func `extension`(of name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, !ext.contains(where: \.isWhitespace) else { return nil }
        return String(ext)
    }

    /// The name with the user's other edits but the old extension kept (the
    /// "Keep" button). Equal to `oldName` when only the extension was touched.
    func keepingOldExtension(newName: String) -> String {
        switch self {
        case .changing(_, let to):
            return String(newName.dropLast(to.count + 1)) + "." + oldExtension
        case .adding(let ext):
            return String(newName.dropLast(ext.count + 1))
        case .removing(let ext):
            // "b." keeps ".txt" as "b.txt", not "b..txt".
            var base = Substring(newName)
            while base.hasSuffix(".") && base.count > 1 { base = base.dropLast() }
            return base + "." + ext
        }
    }

    private var oldExtension: String {
        switch self {
        case .changing(let from, _): return from
        case .removing(let ext):     return ext
        case .adding:                return ""
        }
    }

    var question: String {
        switch self {
        case let .changing(from, to):
            return String.localizedStringWithFormat(NSLocalizedString("Are you sure you want to change the extension from “.%1$@” to “.%2$@”?", comment: "Confirm changing a file extension"), from, to)
        case .adding(let ext):
            return String.localizedStringWithFormat(NSLocalizedString("Are you sure you want to add the extension “.%@” to the end of the name?", comment: "Confirm adding a file extension"), ext)
        case .removing(let ext):
            return String.localizedStringWithFormat(NSLocalizedString("Are you sure you want to remove the extension “.%@”?", comment: "Confirm removing a file extension"), ext)
        }
    }

    static let detail = NSLocalizedString("If you make this change, the file may open in a different app.", comment: "File extension change alert detail")

    /// The default button, which leaves the extension as it was.
    var keepTitle: String {
        switch self {
        case .changing(let from, _): return String.localizedStringWithFormat(NSLocalizedString("Keep .%@", comment: "Alert button to keep an old extension"), from)
        case .adding:                return NSLocalizedString("Don’t Add", comment: "Alert button to cancel adding an extension")
        case .removing:              return String.localizedStringWithFormat(NSLocalizedString("Keep .%@", comment: "Alert button to keep an old extension"), oldExtension)
        }
    }

    var useTitle: String {
        switch self {
        case .changing(_, let to): return String.localizedStringWithFormat(NSLocalizedString("Use .%@", comment: "Alert button to use a new extension"), to)
        case .adding(let ext):     return String.localizedStringWithFormat(NSLocalizedString("Add .%@", comment: "Alert button to add an extension"), ext)
        case .removing:            return NSLocalizedString("Remove", comment: "Alert button to remove an extension")
        }
    }
}
