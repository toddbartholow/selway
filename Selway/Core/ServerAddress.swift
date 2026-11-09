import Foundation

// Go → Connect to Server…: what the user types, checked and put in one form
// before anything is mounted, remembered or shown. Foundation only (it runs on
// Linux CI); the mounting itself is the app's (NetFS).

/// The kinds of server Connect to Server mounts, as Finder does. Nothing else
/// is ever mounted: not `file:`, `vnc:`, `selway:` or a web page's link.
enum ServerScheme: String, CaseIterable, Sendable {
    case smb, afp, nfs
    /// WebDAV.
    case http, https
    /// Mounted read-only by macOS.
    case ftp

    /// The scheme for a name typed: another name for one ("cifs" is SMB,
    /// "webdav" and "webdavs" are WebDAV over HTTP and HTTPS), or nil for a
    /// scheme Selway won't connect to. Finder takes only http(s) for WebDAV;
    /// the other names are accepted and stored as http(s).
    static func named(_ name: String) -> ServerScheme? {
        switch name.lowercased() {
        case "smb", "cifs":      return .smb
        case "afp":              return .afp
        case "nfs":              return .nfs
        case "http", "webdav":   return .http
        case "https", "webdavs": return .https
        case "ftp":              return .ftp
        default:                 return nil
        }
    }

    /// The port used when none is given. An address giving it is the same
    /// address as one that doesn't.
    var defaultPort: Int {
        switch self {
        case .smb:   return 445
        case .afp:   return 548
        case .nfs:   return 2049
        case .http:  return 80
        case .https: return 443
        case .ftp:   return 21
        }
    }

    /// The first part of the path names the share (Finder's "volume"), the
    /// rest a folder on it. An NFS export, a WebDAV or an FTP address is
    /// mounted whole, however deep.
    var pathStartsWithShare: Bool { self == .smb || self == .afp }

    /// SMB and AFP shares and the folders on them match without regard to case.
    var pathIsCaseInsensitive: Bool { self == .smb || self == .afp }

    /// macOS mounts FTP servers read-only.
    var isReadOnly: Bool { self == .ftp }

    /// For the user: "SMB", "WebDAV"…
    var title: String {
        switch self {
        case .smb:   return "SMB"
        case .afp:   return "AFP"
        case .nfs:   return "NFS"
        case .http:  return "WebDAV"
        case .https: return "WebDAV (HTTPS)"
        case .ftp:   return "FTP"
        }
    }
}

/// Why an address can't be connected to; `message` says so to the user.
enum ServerAddressError: Error, Equatable, Sendable {
    case empty
    case tooLong
    /// A scheme Selway doesn't connect to ("file", "vnc", "javascript"…).
    case unsupportedScheme(String)
    /// "smb:server" without the "//".
    case missingSlashes(ServerScheme)
    case missingHost
    case invalidHost
    case invalidPort
    /// A "?" or "#": a query or fragment, which no server address has.
    case queryOrFragment
    /// A "%" not followed by two hex digits.
    case invalidPercentEncoding
    /// Control characters, a backslash in the path, and the like.
    case invalidCharacters
    /// "." or ".." in the path.
    case relativePath
    /// Zero-width, direction or unusual space characters (in a host, anywhere).
    case invisibleCharacters

    var message: String {
        switch self {
        case .empty:
            return NSLocalizedString("Enter a server address, such as smb://server/share.", comment: "Server address validation error")
        case .tooLong:
            return NSLocalizedString("That address is too long.", comment: "Server address validation error")
        case .unsupportedScheme(let scheme):
            return String.localizedStringWithFormat(NSLocalizedString("Selway can’t connect to “%@:” addresses. Use smb, afp, nfs, http or https (WebDAV), or ftp.", comment: "Unsupported server address scheme"), scheme)
        case .missingSlashes(let scheme):
            return String.localizedStringWithFormat(NSLocalizedString("Type “%@://” before the server’s name.", comment: "Server address validation error with scheme"), scheme.rawValue)
        case .missingHost:
            return NSLocalizedString("Enter the server’s name or address after “://”.", comment: "Server address validation error")
        case .invalidHost:
            return NSLocalizedString("That server name isn’t valid.", comment: "Server address validation error")
        case .invalidPort:
            return NSLocalizedString("The port must be a number from 1 to 65535.", comment: "Server address validation error")
        case .queryOrFragment:
            return String.localizedStringWithFormat(NSLocalizedString("A server address can’t contain “?” or “#”. In a name, type them as %1$@ and %2$@.", comment: "Server address validation error"), "%3F", "%23")
        case .invalidPercentEncoding:
            return String.localizedStringWithFormat(NSLocalizedString("A “%1$@” in the address must be followed by two hexadecimal digits. Type a percent sign as %2$@.", comment: "Server address validation error"), "%", "%25")
        case .invalidCharacters:
            return NSLocalizedString("The address contains characters a server address can’t have.", comment: "Server address validation error")
        case .relativePath:
            return NSLocalizedString("The path can’t contain “.” or “..” folders.", comment: "Server address validation error")
        case .invisibleCharacters:
            return NSLocalizedString("The address contains invisible characters, or spaces that aren’t ordinary ones. Type it again by hand.", comment: "Server address validation error")
        }
    }
}

/// A server address, checked and in one form: what Connect to Server mounts,
/// and what Recent Servers and the sidebar's saved servers store.
///
/// - The scheme and host are lowercased; IPv6 hosts are kept without their
///   brackets; the scheme's default port is dropped.
/// - The path is kept decoded ("/My Share/Sub"), with no empty, "." or ".."
///   parts and no trailing slash. It's percent-encoded only in `url`.
/// - **Credentials:** a user name typed is kept, as Finder keeps it (it picks
///   the account in the keychain and the login prompt). A password is never
///   kept: it's dropped while parsing, so it's in no `ServerAddress`, and so
///   never in Recent Servers, saved servers or a log. macOS asks for it, and
///   can keep it in the keychain.
struct ServerAddress: Hashable, Sendable {
    let scheme: ServerScheme
    /// Lowercased. An IPv6 address without brackets ("fe80::1%en0").
    let host: String
    /// nil for the scheme's default port.
    let port: Int?
    /// The account name typed ("alex", "DOMAIN;alex"); never a password.
    let user: String?
    /// Decoded: "" for the server itself, else "/share/folder…".
    let path: String
    /// The address to mount, percent-encoded, without a password.
    let url: URL

    /// The longest address taken.
    static let maxLength = 2048

    /// One parse: the address, and whether a password typed in it was dropped
    /// (the sheet says it isn't used).
    struct Parsed: Equatable, Sendable {
        let address: ServerAddress
        let droppedPassword: Bool
    }

    // MARK: Parsing

    /// Parses what the user typed:
    /// - `smb://host/share`, `afp://`, `nfs://host/path`, `http(s)://` (WebDAV),
    ///   `ftp://`, and the `cifs`, `webdav` and `webdavs` names for them;
    /// - `host/share`, `//host/share` or `\\host\share`, taken as SMB;
    /// - `[fe80::1]:445` and bare IPv6 addresses (`fe80::1`, only without a port).
    /// Whitespace around it is ignored. Anything else is an error saying why.
    static func parse(_ text: String) -> Result<Parsed, ServerAddressError> {
        // Every delimiter is looked for among the Unicode scalars, never the
        // Characters: a "/" or ":" followed by a combining mark is one
        // Character, and must still end what it ends.
        var s = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
        guard !s.isEmpty else { return .failure(.empty) }
        guard s.count <= maxLength else { return .failure(.tooLong) }
        if let control = s.first(where: isControl) {
            // Zero-width and direction marks say so; other controls don't belong anywhere.
            return .failure(control.properties.generalCategory == .format ? .invisibleCharacters : .invalidCharacters)
        }

        // Windows' \\server\share, and //server/share: SMB.
        if s.starts(with: ["\\", "\\"]) {
            s = Array("smb://".unicodeScalars) + s.dropFirst(2).map { $0 == "\\" ? "/" : $0 }
        } else if s.starts(with: ["/", "/"]) {
            s = Array("smb:".unicodeScalars) + s
        }

        let schemeName: String
        let rest: ArraySlice<Unicode.Scalar>
        if let separator = firstRange(of: Array("://".unicodeScalars), in: s[...]) {
            schemeName = string(s[..<separator.lowerBound])
            rest = s[separator.upperBound...]
            guard isSchemeName(schemeName) else { return .failure(.invalidCharacters) }
        } else if let name = schemeWithoutSlashes(s[...]) {
            // "file:/etc", "javascript:alert(1)", "smb:server".
            if let scheme = ServerScheme.named(name) { return .failure(.missingSlashes(scheme)) }
            return .failure(.unsupportedScheme(name.lowercased()))
        } else {
            schemeName = "smb"
            rest = s[...]
        }
        guard let scheme = ServerScheme.named(schemeName) else {
            return .failure(.unsupportedScheme(schemeName.lowercased()))
        }
        guard !rest.contains("?"), !rest.contains("#") else { return .failure(.queryOrFragment) }

        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var authority = rest[..<slash]
        let rawPath = rest[slash...]

        // User info: up to the last "@" (a user name can be an e-mail address).
        var user: String?
        var droppedPassword = false
        if let at = authority.lastIndex(of: "@") {
            let info = authority[..<at]
            authority = authority[(at + 1)...]
            let colon = info.firstIndex(of: ":") ?? info.endIndex
            guard var name = string(info[..<colon]).removingPercentEncoding else {
                return .failure(.invalidPercentEncoding)
            }
            var password = colon < info.endIndex ? Array(info[(colon + 1)...]) : []
            // "user%3Apass": once decoded, what follows the ":" is a password all the same.
            if let decodedColon = name.unicodeScalars.firstIndex(of: ":") {
                password += Array(name.unicodeScalars[name.unicodeScalars.index(after: decodedColon)...])
                name = String(String.UnicodeScalarView(name.unicodeScalars[..<decodedColon]))
            }
            guard !name.unicodeScalars.contains(where: isControl) else { return .failure(.invalidCharacters) }
            guard !startsWithMark(name) else { return .failure(.invalidCharacters) }
            user = name.isEmpty ? nil : name
            droppedPassword = !password.isEmpty
        }

        let host: String
        let port: Int?
        switch hostAndPort(authority) {
        case .failure(let error): return .failure(error)
        case .success(let value): (host, port) = value
        }

        let path: String
        switch normalizedPath(rawPath) {
        case .failure(let error): return .failure(error)
        case .success(let value): path = value
        }

        guard let address = ServerAddress(scheme: scheme, host: host,
                                          port: port == scheme.defaultPort ? nil : port,
                                          user: user, path: path) else {
            return .failure(.invalidCharacters)
        }
        return .success(Parsed(address: address, droppedPassword: droppedPassword))
    }

    /// The address a mounted volume reports for remounting it
    /// (`.volumeURLForRemountingKey`), without its password (an SMB guest
    /// login's comes as "GUEST:"); nil for one Selway wouldn't connect to.
    init?(remountURL: URL) {
        guard case .success(let parsed) = Self.parse(remountURL.absoluteString) else { return nil }
        self = parsed.address
    }

    /// A server found on the network (the sidebar's Network rows): the host
    /// name and port its Bonjour service resolved to, as the system's resolver
    /// gave them, decoded. Stricter than a typed host: a multicast DNS host
    /// name is ASCII, so each label must be ASCII letters, digits and hyphens
    /// (`isResolvedHostName`), and it must end in ".local". That refuses
    /// look-alikes a typed host may have (a Cyrillic "о", "․" U+2024, "．"
    /// U+FF0E, a Braille blank, private-use characters, combining marks),
    /// and an IPv6 or other address with a ":" or a "%", never decoded or
    /// read as a port. It then goes through a typed host's checks too (and,
    /// being ASCII, lowercasing it changes only ASCII letters). Nil
    /// when it fails them, or the port is out of range. No user, no share:
    /// macOS asks which shares to mount.
    init?(scheme: ServerScheme, resolvedHost: String, port: Int) {
        guard (1...65535).contains(port), Self.isResolvedHostName(resolvedHost),
              case .success(let host) = Self.checkedHostName(resolvedHost) else { return nil }
        self.init(scheme: scheme, host: host, port: port == scheme.defaultPort ? nil : port, user: nil, path: "")
    }

    /// A multicast DNS host name: labels of ASCII letters, digits and hyphens
    /// (not at a label's ends), the last one "local", with or without the
    /// root's dot.
    static func isResolvedHostName(_ host: String) -> Bool {
        var labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count > 1, labels.last?.isEmpty == true { labels.removeLast() }
        guard labels.count >= 2, labels.last?.lowercased() == "local" else { return false }
        return labels.allSatisfy { label in
            let scalars = label.unicodeScalars
            guard let first = scalars.first, let last = scalars.last, scalars.count <= 63,
                  first != "-", last != "-" else { return false }
            return scalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0)
                || ("0"..."9").contains($0) || $0 == "-" }
        }
    }

    /// Builds the address from parts already checked; nil if they don't make a
    /// URL (they always should).
    init?(scheme: ServerScheme, host: String, port: Int?, user: String?, path: String) {
        var string = scheme.rawValue + "://"
        if let user {
            string += Self.encode(user, allowed: Self.unreserved) + "@"
        }
        string += Self.urlHost(host)
        if let port { string += ":\(port)" }
        string += Self.encodePath(path)
        guard let url = URL(string: string) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port
        self.user = user
        self.path = path
        self.url = url
    }

    // MARK: Forms of it

    /// The address to show and to put in the field: the path, host and user
    /// readable (spaces, accents), with only what would change how it parses
    /// escaped ("%", "?", "#"). Parsing it gives this address back. Never a
    /// password: there is none to show.
    var displayString: String { formatted(includingUser: true) }

    /// The address for a label or tooltip: `displayString`, with a non-ASCII
    /// host's ASCII form after it, so a lookalike stands out. Not for the
    /// address field: it doesn't parse back.
    var displayAddress: String {
        guard let ascii = Self.asciiHost(host) else { return displayString }
        return "\(displayString) (\(ascii))"
    }

    /// For logs: no user name either.
    var logDescription: String { formatted(includingUser: false) }

    /// The host as written in an address: an IPv6 one in brackets.
    /// A non-ASCII one with its ASCII form after it (`displayHost`).
    var hostForDisplay: String { host.contains(":") ? "[\(host)]" : Self.displayHost(host) }

    /// A host for a label naming a server: a non-ASCII one with its ASCII
    /// form after it, "gооgle.com (xn--ggle-55da.com)", so a lookalike of an
    /// ASCII name stands out. Display only: hosts are parsed, stored, matched
    /// and mounted as typed.
    static func displayHost(_ host: String) -> String {
        asciiHost(host).map { "\(host) (\($0))" } ?? host
    }

    /// The ASCII form a non-ASCII host is looked up by (IDNA): the
    /// ideographic and fullwidth dots are dots, each label is mapped
    /// (NFKC, so fullwidth letters are letters) and lowercased, and one
    /// still not ASCII is punycoded. Nil for an ASCII host, an IPv6 literal,
    /// or a Bonjour service name ("Alex’s Mac._smb._tcp.local"), which isn't
    /// looked up in DNS and whose punycode would only be noise.
    static func asciiHost(_ host: String) -> String? {
        func isASCII<S: StringProtocol>(_ text: S) -> Bool { text.unicodeScalars.allSatisfy(\.isASCII) }
        let lowered = host.lowercased()
        guard !host.contains(":"), !isASCII(host),
              !lowered.hasSuffix("._tcp.local"), !lowered.hasSuffix("._udp.local") else { return nil }
        let dots: Set<Character> = [".", "\u{3002}", "\u{FF0E}", "\u{FF61}"]
        return host.split(omittingEmptySubsequences: false, whereSeparator: dots.contains).map { label in
            let mapped = String(label).precomposedStringWithCompatibilityMapping.lowercased()
            return isASCII(mapped) ? mapped : "xn--" + Punycode.encode(mapped)
        }.joined(separator: ".")
    }

    /// What decides whether two addresses are the same server and share: the
    /// scheme, host, port and path (without regard to case for SMB and AFP),
    /// not the user name.
    var matchKey: String {
        let shownPath = scheme.pathIsCaseInsensitive ? path.lowercased() : path
        return serverMatchKey + shownPath
    }

    /// What decides whether two addresses are the same server, whatever
    /// share or folder: the scheme, host and port.
    var serverMatchKey: String {
        "\(scheme.rawValue)://\(host):\(port ?? scheme.defaultPort)"
    }

    /// An SMB or AFP server with no share named: macOS asks which shares to
    /// mount, so it's never mounted itself. An FTP, WebDAV or NFS address
    /// with no path is mounted whole, like any other.
    var isServerOnly: Bool { scheme.pathStartsWithShare && path.isEmpty }

    /// The path's parts: ["share", "folder"].
    var pathComponents: [String] { ServerAddress.components(path) }

    /// What's mounted: for SMB and AFP the share alone, for the others the
    /// whole address. The server itself when no share is given (macOS then
    /// asks which to mount).
    var mountTarget: ServerAddress {
        guard scheme.pathStartsWithShare, pathComponents.count > 1 else { return self }
        return ServerAddress(scheme: scheme, host: host, port: port, user: user,
                             path: "/" + pathComponents[0]) ?? self
    }

    /// The folder on the mounted share the address goes on to ("Sub/Folder"),
    /// "" for the share itself.
    var folderInShare: String {
        guard scheme.pathStartsWithShare else { return "" }
        return pathComponents.dropFirst().joined(separator: "/")
    }

    /// The share's (or export's) name, nil for just a server.
    var shareName: String? {
        scheme.pathStartsWithShare ? pathComponents.first : pathComponents.last
    }

    /// This address with `folder` (a relative path, "a/b") added to its path.
    func appending(folder: String) -> ServerAddress {
        let parts = ServerAddress.components(folder)
        guard !parts.isEmpty else { return self }
        return ServerAddress(scheme: scheme, host: host, port: port, user: user,
                             path: path + "/" + parts.joined(separator: "/")) ?? self
    }

    private func formatted(includingUser: Bool) -> String {
        var string = scheme.rawValue + "://"
        if includingUser, let user {
            string += Self.escapeForDisplay(user, also: "@:/") + "@"
        }
        string += host.contains(":") ? "[\(Self.escapeForDisplay(host, also: ""))]" : Self.escapeForDisplay(host, also: "")
        if let port { string += ":\(port)" }
        string += pathComponents.map { "/" + Self.escapeForDisplay($0, also: "") }.joined()
        return string
    }
}

// MARK: - Parsing helpers

private extension ServerAddress {
    static let unreserved = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
            || scalar.properties.generalCategory == .format && scalar.value != 0x200D
            || scalar.properties.generalCategory == .lineSeparator
            || scalar.properties.generalCategory == .paragraphSeparator
    }

    /// A scalar that joins the one before it into one Character (a combining
    /// mark, a zero-width joiner): refused at the start of a host, a user
    /// name and each part of a path, where it would hide or change what's
    /// before it ("/" followed by an accent).
    static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return properties.isGraphemeExtend || scalar.value == 0x200D
        }
    }

    static func startsWithMark(_ text: String) -> Bool {
        text.unicodeScalars.first.map(isMark) ?? false
    }

    /// Whether a host name has characters that show as nothing, or as an
    /// ordinary space ("nas\u{200D}.local" reads as "nas.local"):
    /// Default_Ignorable code points (joiners, zero-width spaces, the BOM, soft
    /// hyphens, variation selectors, the Hangul filler) and every space but the
    /// ASCII one. A zero-width joiner or an emoji variation selector inside an
    /// emoji sequence is part of what's drawn, not hidden ("👨‍💻", "❤️"):
    /// those are allowed (`EmojiSequence`), anywhere else they're not.
    static func hasInvisibleCharacters(_ host: String) -> Bool {
        let scalars = Array(host.unicodeScalars)
        return scalars.indices.contains { i in
            let scalar = scalars[i]
            guard scalar.properties.isDefaultIgnorableCodePoint || (scalar.properties.isWhitespace && scalar != " ")
            else { return false }
            return !EmojiSequence.isDrawn(at: i, in: scalars)
        }
    }

    static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    static func firstRange(of needle: [Unicode.Scalar],
                           in haystack: ArraySlice<Unicode.Scalar>) -> Range<Int>? {
        guard needle.count <= haystack.count else { return nil }
        var i = haystack.startIndex
        while i + needle.count <= haystack.endIndex {
            if haystack[i..<(i + needle.count)].elementsEqual(needle) { return i..<(i + needle.count) }
            i += 1
        }
        return nil
    }

    /// RFC 3986: a letter, then letters, digits, "+", "-" or ".".
    static func isSchemeName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first) else {
            return false
        }
        return name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0))
        }
    }

    /// The scheme of "name:rest" typed without "//" ("file:/etc"), or nil when
    /// it's a host and port ("server:445/share") or a bare IPv6 address.
    static func schemeWithoutSlashes(_ s: ArraySlice<Unicode.Scalar>) -> String? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let name = string(s[..<colon])
        guard isSchemeName(name) else { return nil }
        let authority = s[..<(s.firstIndex(of: "/") ?? s.endIndex)]
        if authority.filter({ $0 == ":" }).count >= 2, isIPv6Literal(string(authority)) { return nil }
        let afterColon = authority[(colon + 1)...]
        if !afterColon.isEmpty, afterColon.allSatisfy(isASCIIDigit) { return nil }
        return name
    }

    static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }

    static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIDigit(scalar) || ("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)
    }

    /// An IPv6 address, with an optional zone ("%en0") of ASCII letters,
    /// digits, "-", "_" and ".".
    static func isIPv6Literal(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        let percent = scalars.firstIndex(of: "%") ?? scalars.endIndex
        let address = scalars[..<percent]
        guard address.contains(":"), address.allSatisfy({ isHexDigit($0) || $0 == ":" || $0 == "." }) else {
            return false
        }
        guard percent < scalars.endIndex else { return true }
        let zone = scalars[(percent + 1)...]
        return !zone.isEmpty && zone.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0))
        }
    }

    static func hostAndPort(_ authority: ArraySlice<Unicode.Scalar>) -> Result<(String, Int?), ServerAddressError> {
        var hostText: ArraySlice<Unicode.Scalar>
        var portText: ArraySlice<Unicode.Scalar>?
        if authority.first == "[" {
            guard let close = authority.firstIndex(of: "]") else { return .failure(.invalidHost) }
            hostText = authority[(authority.startIndex + 1)..<close]
            let after = authority[(close + 1)...]
            if !after.isEmpty {
                guard after.first == ":" else { return .failure(.invalidHost) }
                portText = after.dropFirst()
            }
            // The zone ("%en0") comes encoded as "%25en0" in a URL.
            let zoneFree = string(hostText).replacingOccurrences(of: "%25", with: "%")
            guard isIPv6Literal(zoneFree) else { return .failure(.invalidHost) }
            return port(portText).map { (zoneFree.lowercased(), $0) }
        }
        let colons = authority.filter { $0 == ":" }.count
        if colons >= 2 {
            // A bare IPv6 address: no port can follow it.
            let text = string(authority)
            guard isIPv6Literal(text) else { return .failure(.invalidHost) }
            return .success((text.lowercased(), nil))
        }
        hostText = authority
        if let colon = authority.firstIndex(of: ":") {
            hostText = authority[..<colon]
            portText = authority[(colon + 1)...]
        }
        guard !hostText.isEmpty else { return .failure(.missingHost) }
        guard let host = string(hostText).removingPercentEncoding else { return .failure(.invalidPercentEncoding) }
        switch checkedHostName(host) {
        case .failure(let error): return .failure(error)
        case .success(let host):  return port(portText).map { (host, $0) }
        }
    }

    /// A host name (decoded, not an IPv6 address) as an address keeps it:
    /// lowercased, without a root dot; or why it can't be one.
    static func checkedHostName(_ text: String) -> Result<String, ServerAddressError> {
        var host = text
        if hasInvisibleCharacters(host) { return .failure(.invisibleCharacters) }
        // A fully qualified name's root dot; one more left ("pwnfs..") is an
        // empty label, refused below.
        if host.unicodeScalars.count > 1, host.unicodeScalars.last == "." { host.unicodeScalars.removeLast() }
        guard isValidHostName(host) else { return .failure(.invalidHost) }
        return .success(host.lowercased())
    }

    /// A host name or a Bonjour service name ("Alex’s Mac._smb._tcp.local"),
    /// which can have spaces and any letters, but nothing that would end the
    /// host, change what it means, or hide in it. Its labels are split on the
    /// "." scalar, not on Characters (see `parse`): none may be empty or
    /// start with a mark, which would join the "." before it ("a.́b").
    /// Nor may a "." share its Character with anything else: a skin tone or
    /// a Thai or Lao vowel after it, or a Prepend scalar before it, joins it
    /// too without being a mark ("a.\u{1F3FD}b", "a\u{D4E}.b").
    static func isValidHostName(_ host: String) -> Bool {
        let scalars = host.unicodeScalars
        guard let first = scalars.first, let last = scalars.last, scalars.count <= 255,
              first != " ", last != " " else { return false }
        let labels = scalars.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ $0.first.map { !isMark($0) } ?? false }) else { return false }
        guard !host.contains(where: { $0 != "." && $0.unicodeScalars.contains(".") }) else { return false }
        let forbidden = CharacterSet(charactersIn: "/\\@[]?#%:<>\"^`{|}*")
        return !scalars.contains { forbidden.contains($0) || isControl($0) } && !hasInvisibleCharacters(host)
    }

    static func port(_ text: ArraySlice<Unicode.Scalar>?) -> Result<Int?, ServerAddressError> {
        guard let text, !text.isEmpty else { return .success(nil) }
        guard text.count <= 5, text.allSatisfy(isASCIIDigit), let value = Int(string(text)),
              (1...65535).contains(value) else { return .failure(.invalidPort) }
        return .success(value)
    }

    static func normalizedPath(_ raw: ArraySlice<Unicode.Scalar>) -> Result<String, ServerAddressError> {
        var parts: [String] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            guard let decoded = string(part).removingPercentEncoding else { return .failure(.invalidPercentEncoding) }
            let scalars = decoded.unicodeScalars
            guard !scalars.contains(where: isControl), !scalars.contains("\\") else {
                return .failure(.invalidCharacters)
            }
            // "%2F" decoded: a slash inside a name can't be told from a separator.
            guard !scalars.contains("/") else { return .failure(.invalidCharacters) }
            guard !startsWithMark(decoded) else { return .failure(.invalidCharacters) }
            if decoded == "." || decoded == ".." { return .failure(.relativePath) }
            if decoded.isEmpty { continue }
            parts.append(decoded)
        }
        return .success(parts.isEmpty ? "" : "/" + parts.joined(separator: "/"))
    }

    static func encode(_ text: String, allowed: CharacterSet) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func encodePath(_ path: String) -> String {
        components(path).map { "/" + encode($0, allowed: unreserved) }.joined()
    }

    static func urlHost(_ host: String) -> String {
        if host.contains(":") {
            return "[" + host.replacingOccurrences(of: "%", with: "%25") + "]"
        }
        return encode(host, allowed: unreserved)
    }

    /// Escapes only what would change how the text parses back.
    static func escapeForDisplay(_ text: String, also extra: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if "%?#".unicodeScalars.contains(scalar) || extra.unicodeScalars.contains(scalar) {
                out += String(format: "%%%02X", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

extension ServerAddress {
    /// `path`'s parts between "/" scalars (not Characters: see `parse`),
    /// empty ones left out.
    static func components(_ path: String) -> [String] {
        Array(path.unicodeScalars).split(separator: "/").map { string($0) }
    }
}

/// RFC 3492's Punycode encoder, for showing a non-ASCII host's ASCII form
/// (`ServerAddress.asciiHost`). Foundation on Linux has no IDNA.
private enum Punycode {
    static func encode(_ text: String) -> String {
        let points = text.unicodeScalars.map { Int($0.value) }
        var output = String.UnicodeScalarView()
        for point in points where point < 0x80 { output.append(Unicode.Scalar(point)!) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 && handled < points.count { output.append("-") }
        var n = 128
        var delta = 0
        var bias = 72

        while handled < points.count {
            guard let next = points.filter({ $0 >= n }).min() else { return text }
            delta += (next - n) * (handled + 1)
            n = next
            for point in points {
                if point < n { delta += 1 }
                if point == n {
                    var q = delta
                    var k = 36
                    while true {
                        let threshold = k <= bias ? 1 : (k >= bias + 26 ? 26 : k - bias)
                        if q < threshold { break }
                        let code = threshold + (q - threshold) % (36 - threshold)
                        output.append(Unicode.Scalar(digit(code))!)
                        q = (q - threshold) / (36 - threshold)
                        k += 36
                    }
                    output.append(Unicode.Scalar(digit(q))!)
                    bias = adapt(delta, points: handled + 1, first: handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(output)
    }

    private static func adapt(_ initial: Int, points: Int, first: Bool) -> Int {
        var delta = first ? initial / 700 : initial / 2
        delta += delta / points
        var k = 0
        while delta > 455 {
            delta /= 35
            k += 36
        }
        return k + (36 * delta) / (delta + 38)
    }

    private static func digit(_ value: Int) -> UInt32 {
        UInt32(value < 26 ? 97 + value : 22 + value)
    }
}

// MARK: - Mount results

/// What a failed mount (NetFS's status) means to the user. NetFS gives an errno
/// (positive) or an OSStatus (negative); which one varies by protocol: an NFS
/// server that can't be found is ENOENT, an SMB one EHOSTUNREACH.
enum ServerConnectFailure: Equatable, Sendable {
    /// The user cancelled (the login prompt, or Cancel while connecting): nothing to say.
    case cancelled
    /// The share is mounted already: open it where it is.
    case alreadyMounted
    case authentication
    /// The password has to be changed first.
    case passwordExpired
    case serverNotFound
    /// Found, but it refused or didn't answer.
    case serverNotResponding
    case shareNotFound
    case notSupported
    case other(Int32)

    /// nil for success (0).
    static func classify(status: Int32) -> ServerConnectFailure? {
        switch status {
        case 0:                                  return nil
        case -128, 89:                           return .cancelled         // userCanceledErr, ECANCELED
        case 17:                                 return .alreadyMounted    // EEXIST
        case -5045:                              return .passwordExpired   // ENETFSPWDNEEDSCHANGE
        case 80, 81, 13, 1, -5046, -5999, -5997, -6004:
            return .authentication     // EAUTH, ENEEDAUTH, EACCES, EPERM, password policy,
                                       // account restricted, no auth method, guest not allowed
        case 65, 64, 51, 50, 8:                  return .serverNotFound    // EHOSTUNREACH, EHOSTDOWN,
                                                                           // ENETUNREACH, ENETDOWN, EAI_NONAME
        case 60, 61, 54:                         return .serverNotResponding // ETIMEDOUT, ECONNREFUSED, ECONNRESET
        case 2, -5998, -6003:                    return .shareNotFound     // ENOENT, no shares available
        case 45, 43, 102, -5996:                 return .notSupported      // ENOTSUP, EPROTONOSUPPORT,
                                                                           // EOPNOTSUPP, no protocol version
        default:                                 return .other(status)
        }
    }

    /// The message for a failure, nil for the ones that have none (cancelled;
    /// already mounted, which opens the share instead).
    func message(for address: ServerAddress) -> (title: String, detail: String)? {
        let title = String.localizedStringWithFormat(NSLocalizedString("Couldn’t connect to “%@”.", comment: "Server connection alert title with server name"), address.hostForDisplay)
        switch self {
        case .cancelled, .alreadyMounted:
            return nil
        case .authentication:
            return (title, NSLocalizedString("The user name or password wasn’t accepted, or that account can’t use this server.", comment: "Server connection failure"))
        case .passwordExpired:
            return (title, NSLocalizedString("The password for this account has to be changed before it can connect.", comment: "Server connection failure"))
        case .serverNotFound:
            return (title, NSLocalizedString("The server wasn’t found. Check its name or address, and that this Mac is on its network.", comment: "Server connection failure"))
        case .serverNotResponding:
            return (title, String.localizedStringWithFormat(NSLocalizedString("The server didn’t accept the connection. Check that it’s turned on and shares files over %@.", comment: "Server connection failure with protocol name"), address.scheme.title))
        case .shareNotFound:
            let share = address.shareName
            if address.scheme == .nfs {
                let message = share.map { String.localizedStringWithFormat(NSLocalizedString("“%@” wasn’t found on the server, or the server wasn’t found.", comment: "NFS share connection failure with share name"), $0) }
                    ?? NSLocalizedString("The shared folder wasn’t found on the server, or the server wasn’t found.", comment: "NFS share connection failure")
                return (title, message)
            }
            let message = share.map { String.localizedStringWithFormat(NSLocalizedString("“%@” wasn’t found on the server, or you don’t have access to it.", comment: "Share connection failure with share name"), $0) }
                ?? NSLocalizedString("The shared folder wasn’t found on the server, or you don’t have access to it.", comment: "Share connection failure")
            return (title, message)
        case .notSupported:
            return (title, NSLocalizedString("The server doesn’t support a way of connecting this Mac can use.", comment: "Server connection failure"))
        case .other(let status):
            return (title, String.localizedStringWithFormat(NSLocalizedString("Something went wrong while connecting (error %d). Try again in a moment.", comment: "Server connection failure with status code"), status))
        }
    }
}
