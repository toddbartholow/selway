import Foundation

// The sidebar's Network row (under Locations): the file servers advertised
// over Bonjour, one row each. The browsing and resolving are the app's
// (Network.framework and dns_sd, NetworkBrowser.swift); what's decided about
// what they find is here, so it can be tested on Linux.
//
// Everything a service says about itself is untrusted: any device on the
// network can advertise any name. A name is only ever shown through
// `displayName`, and never goes into an address: a click resolves the service
// and connects to the host it resolves to (`address(for:target:port:)`).

/// One SMB service as the browser reported it. Only SMB is looked for: macOS
/// has deprecated AFP (an afp:// address typed in Connect to Server still
/// works).
struct NetworkService: Hashable, Sendable {
    /// The Bonjour service type (also in Info.plist's NSBonjourServices).
    static let bonjourType = "_smb._tcp"

    /// The instance name as advertised ("Alex’s iMac"), unescaped: any text
    /// at all. Passed back to the resolver as it came; shown only through
    /// NetworkServers.displayName.
    let name: String
    /// "local.".
    var domain = "local."
}

/// A Network row: a server advertised under one name.
struct NetworkServer: Hashable, Sendable, Identifiable {
    /// From the name (NetworkServers.id): the row's identity.
    let id: String
    /// The name made safe (NetworkServers.cleanName), without the row's
    /// numbering or quotes: what a saved server is called.
    let name: String
    /// The name, made safe to show (NetworkServers.displayName), with " (2)"
    /// and so on when another row's would look the same. VoiceOver reads
    /// this too.
    let displayName: String
    /// What a click looks up and connects to.
    let service: NetworkService
}

/// The rows under Network: the servers listed, and how many more were found
/// than are listed (NetworkServers.maxRows).
struct NetworkServerList: Equatable, Sendable {
    var servers: [NetworkServer] = []
    var hiddenCount = 0

    /// The dimmed row after the servers when some aren't listed.
    var moreText: String? {
        guard hiddenCount > 0 else { return nil }
        return LocalizedCount.string(hiddenCount, NSLocalizedString("%lld more servers…", comment: "Number of network servers not listed"),
                                     one: "%lld more server…", other: "%lld more servers…")
    }
}

/// What a search's earlier reports decided about its rows (NetworkServers.list):
/// when each server arrived, and what each listed row is called. Kept by the
/// search while it runs, emptied when it stops.
struct NetworkRowMemory: Equatable, Sendable {
    struct Shown: Equatable, Sendable {
        /// The clean name it was made from.
        var name: String
        /// As shown: maybe quoted, maybe numbered.
        var shown: String
    }

    struct Arrival: Equatable, Sendable {
        /// Which report it arrived in (1, 2…).
        var report: Int
        /// Its place in the order of arrival.
        var order: Int
    }

    /// When the servers here arrived, by id.
    var arrival: [String: Arrival] = [:]
    var nextArrival = 0
    var reports = 0
    /// The rows listed, by id.
    var shown: [String: Shown] = [:]
}

/// How the search is going, for the Network row's placeholder.
enum NetworkBrowseState: Equatable, Sendable {
    /// Started, or running (servers or not).
    case searching
    /// Local Network access is off for Selway (Privacy & Security), or hasn't
    /// been answered yet: nothing can be found.
    case notAllowed
    /// The search failed or is waiting for something other than permission
    /// (no network).
    case unavailable
}

/// The dimmed row under Network when it has no servers to list.
enum NetworkPlaceholder: Equatable, Sendable, CaseIterable {
    case searching, noneFound, notAllowed, unavailable

    /// How long a search runs with nothing found before "No servers found".
    static let searchingFor: TimeInterval = 3

    /// The placeholder for a search in `state` that has found `serverCount`
    /// servers, and has been running `searchedLong` (`searchingFor` or more);
    /// nil when the servers are listed instead.
    static func current(state: NetworkBrowseState, serverCount: Int, searchedLong: Bool) -> NetworkPlaceholder? {
        switch state {
        case .notAllowed:  return .notAllowed
        case .unavailable: return serverCount == 0 ? .unavailable : nil
        case .searching:
            guard serverCount == 0 else { return nil }
            return searchedLong ? .noneFound : .searching
        }
    }

    var text: String {
        switch self {
        case .searching:
            return NSLocalizedString("Searching…", comment: "Sidebar status while Selway searches for network servers")
        case .noneFound:
            return NSLocalizedString("No servers found", comment: "Sidebar status after a network server search finds no servers")
        case .notAllowed:
            return NSLocalizedString("Allow Selway in System Settings › Privacy & Security › Local Network",
                                     comment: "Sidebar status prompting the user to allow local network access")
        case .unavailable:
            return NSLocalizedString("Can’t search the network", comment: "Sidebar status when network search is unavailable")
        }
    }

    /// `text` for VoiceOver: a menu path's "›" read out as words.
    var spokenText: String {
        switch self {
        case .notAllowed:
            return NSLocalizedString("Allow Selway in System Settings, then Privacy & Security, then Local Network",
                                     comment: "VoiceOver version of the local network access prompt")
        default:           return text
        }
    }

    /// What needs doing (Local Network access off) or is wrong (no network),
    /// rather than a search going as it should: shown in the primary colour.
    var needsAttention: Bool { self == .notAllowed || self == .unavailable }

    /// The tooltip, and VoiceOver's hint.
    var detail: String {
        switch self {
        case .searching:
            return NSLocalizedString("Looking for file servers on your network.", comment: "Tooltip for the network search status")
        case .noneFound:
            return NSLocalizedString("No file servers on your network are sharing over SMB. Servers appear here as they come online.",
                                     comment: "Tooltip when no network servers are found")
        case .notAllowed:
            return NSLocalizedString("Selway can’t look for servers until you allow it: in System Settings, open Privacy & Security, then Local Network, and turn on Selway.",
                                     comment: "Tooltip explaining how to allow local network access")
        case .unavailable:
            return NSLocalizedString("Selway keeps trying. Check that this Mac is connected to a network.",
                                     comment: "Tooltip when the network is unavailable")
        }
    }
}

/// Why a server found on the network couldn't be connected to.
enum NetworkResolveFailure: Error, Equatable, Sendable {
    /// It didn't answer in time, or it's gone.
    case notFound
    /// Local Network access is off for Selway.
    case notAllowed
    /// It answered with a host name Selway won't connect to (not on the local
    /// network, or not a valid name).
    case unusableAddress

    func message(serverName: String) -> String {
        switch self {
        case .notFound:
            return String.localizedStringWithFormat(NSLocalizedString("Couldn’t find “%@” on the network. It may have been turned off or left the network.", comment: "Network server resolution error with server name"), serverName)
        case .notAllowed:
            return NSLocalizedString("Selway isn’t allowed to look for servers on your network. Allow it in System Settings, then Privacy & Security, then Local Network.", comment: "Network server resolution permission error")
        case .unusableAddress:
            return String.localizedStringWithFormat(NSLocalizedString("“%@” gave an address Selway won’t connect to. Type its address above instead.", comment: "Network server resolution error with server name"), serverName)
        }
    }
}

/// What the Network row tells VoiceOver about its search: its value, and the
/// one announcement each opening gets.
enum NetworkStatus {
    /// The Network row's value while it's open ("" while closed): "Searching",
    /// "3 servers", "No servers found", "Local Network access off",
    /// "Can’t search the network". `serverCount` counts the ones not listed too.
    static func value(isOpen: Bool, placeholder: NetworkPlaceholder?, serverCount: Int) -> String {
        guard isOpen else { return "" }
        switch placeholder {
        case .searching?:
            return NSLocalizedString("Searching", comment: "VoiceOver value while the Network sidebar row is searching")
        case .noneFound?:
            return NSLocalizedString("No servers found", comment: "VoiceOver value when no network servers were found")
        case .notAllowed?:
            return NSLocalizedString("Local Network access off", comment: "VoiceOver value when local network access is disabled")
        case .unavailable?:
            return NSLocalizedString("Can’t search the network", comment: "VoiceOver value when network search is unavailable")
        case nil:
            return LocalizedCount.string(serverCount, NSLocalizedString("%lld servers", comment: "Number of network servers, VoiceOver's value for the Network row"),
                                         one: "%lld server", other: "%lld servers")
        }
    }

    /// What's been said since Network was opened.
    struct Said: Equatable, Sendable {
        var outcome = false
        var serversAfterWaiting = false
    }

    /// What to announce now, if anything: once per opening, when the search
    /// comes to an outcome (none found, Local Network access off, can't
    /// search); and once more if servers then appear after all. Servers found
    /// straight away aren't announced (the rows and the row's value say so),
    /// nor is each server.
    static func announcement(placeholder: NetworkPlaceholder?, serverCount: Int, said: inout Said) -> String? {
        if let placeholder, placeholder != .searching {
            guard !said.outcome else { return nil }
            said.outcome = true
            return placeholder.spokenText
        }
        guard placeholder == nil, serverCount > 0, said.outcome, !said.serversAfterWaiting else { return nil }
        said.serversAfterWaiting = true
        return LocalizedCount.string(serverCount, NSLocalizedString("%lld servers found", comment: "Number of network servers found, announced to VoiceOver"),
                                     one: "%lld server found", other: "%lld servers found")
    }
}

/// When to start a search again after it failed: soon at first, then less
/// often, never less often than every `maxDelay` seconds.
enum NetworkRetry {
    static let firstDelay: TimeInterval = 2
    static let maxDelay: TimeInterval = 30

    /// The wait before the next try after `failures` failures in a row (1 or more).
    static func delay(afterFailures failures: Int) -> TimeInterval {
        let doublings = min(max(failures - 1, 0), 10)
        return min(firstDelay * Double(1 << doublings), maxDelay)
    }
}

enum NetworkServers {
    /// The most servers listed. A network advertising more (thousands, from
    /// a device flooding it) gets a "more servers" row instead, and costs
    /// only the cheap part of the work (`list`).
    static let maxRows = 200

    /// The most characters of a name shown. A Bonjour name is at most 63
    /// bytes, so only a name that isn't one is ever cut.
    static let displayLimit = 63
    /// Shown for a name with nothing to show.
    static let unnamed = NSLocalizedString("Unnamed server", comment: "Fallback display name for a network server without a name")

    // MARK: Rows

    /// The rows for the services found, all of them, as one search's first
    /// report would list them (`list`, with nothing remembered).
    static func rows(_ services: [NetworkService], thisMac: [String]) -> [NetworkServer] {
        var memory = NetworkRowMemory()
        return list(services, thisMac: thisMac, memory: &memory, limit: .max).servers
    }

    /// The rows for the services found: one per name (the same service seen
    /// twice is one row), none for this Mac's own (`thisMac`: its computer
    /// name, which it advertises its file sharing under), at most `limit`,
    /// sorted by name as Finder sorts, with the rest counted.
    ///
    /// `memory` is what earlier reports of the same search decided (the
    /// search keeps it, and starts again with an empty one). It keeps both
    /// decisions a device on the network could otherwise steer by choosing
    /// its name:
    /// - **which rows are listed** when there are more than `limit`: those
    ///   listed stay listed, and newcomers fill free places in the order they
    ///   arrived, so a flood after a server appeared can't push it out;
    /// - **which row keeps a name** others would look the same as: the one
    ///   that arrived first. Later ones get " (2)", " (3)"…, the lowest
    ///   number free. A row keeps its name while it's listed: one coming or
    ///   going never renumbers another (and a plain name freed by a row
    ///   leaving isn't handed on).
    /// Services in the same report arrive in the order of their ids; of those
    /// listed, the ones most plainly written (`isPlainlyWritten`: no spaces,
    /// joiners or selectors that showing them drops or changes, composed
    /// letters) are named first: so when Network opens on "NAS" and " NAS"
    /// at once, "NAS" is the plain one.
    ///
    /// Only the cheap work (each name's id) is done for every service;
    /// making names safe to show (`makeName`, NetworkServers.cleanName unless
    /// a test counts its calls), numbering and sorting them is done for the
    /// rows listed.
    static func list(_ services: [NetworkService], thisMac: [String], memory: inout NetworkRowMemory,
                     limit: Int = maxRows, makeName: (String) -> String = cleanName) -> NetworkServerList {
        let mine = Set(thisMac.map(id(for:)))
        var byID: [String: NetworkService] = [:]
        byID.reserveCapacity(services.count)
        for service in services {
            let key = id(for: service.name)
            guard !mine.contains(key) else { continue }
            // Two spellings of one name (as DNS compares them): keep one, the same one each time.
            if let kept = byID[key], !Array(service.name.utf8).lexicographicallyPrecedes(Array(kept.name.utf8)) {
                continue
            }
            byID[key] = service
        }

        // Arrival: gone ids forgotten, new ones numbered in (this report's, by id).
        memory.arrival = memory.arrival.filter { byID[$0.key] != nil }
        let newcomers = byID.keys.filter { memory.arrival[$0] == nil }.sorted()
        if !newcomers.isEmpty { memory.reports += 1 }
        for id in newcomers {
            memory.arrival[id] = NetworkRowMemory.Arrival(report: memory.reports, order: memory.nextArrival)
            memory.nextArrival += 1
        }
        let arrival = memory.arrival.mapValues(\.order)
        let report = memory.arrival.mapValues(\.report)
        let byArrival = { (a: String, b: String) in arrival[a]! < arrival[b]! }

        // Listed: those listed before (still here), then newcomers by arrival.
        let capacity = max(limit, 0)
        var listed = memory.shown.keys.filter { byID[$0] != nil }.sorted(by: byArrival)
        listed = Array(listed.prefix(capacity))
        if listed.count < capacity {
            let kept = Set(listed)
            // Sorted by the arrival number alone (an Int), not looked up per comparison.
            let waiting = byID.keys.compactMap { id in kept.contains(id) ? nil : (arrival[id]!, id) }
                .sorted { $0.0 < $1.0 }
            listed += waiting.prefix(capacity - listed.count).map(\.1)
        }

        // Names: kept while listed under the same name; the rest given one in arrival order.
        var shown: [String: NetworkRowMemory.Shown] = [:]
        var taken = Set<String>()
        var unnamed: [(id: String, name: String)] = []
        for id in listed {
            let name = makeName(byID[id]!.name)
            if let before = memory.shown[id], before.name == name, !taken.contains(lookalikeKey(before.shown)) {
                shown[id] = before
                taken.insert(lookalikeKey(before.shown))
            } else {
                unnamed.append((id, name))
            }
        }
        // In arrival order, but of those that arrived in the same report, the
        // plainly written first (worked out only for these: at most `limit`).
        let ranked = unnamed.map { (entry: $0, report: report[$0.id]!, plain: isPlainlyWritten(byID[$0.id]!.name)) }
            .sorted { a, b in
                if a.report != b.report { return a.report < b.report }
                if a.plain != b.plain { return a.plain }
                return byArrival(a.entry.id, b.entry.id)
            }
        for entry in ranked.map(\.entry) {
            var candidate = quotedIfPlaceholder(entry.name)
            var n = 2
            while taken.contains(lookalikeKey(candidate)) {
                candidate = quotedIfPlaceholder(entry.name) + " (\(n))"
                n += 1
            }
            taken.insert(lookalikeKey(candidate))
            shown[entry.id] = NetworkRowMemory.Shown(name: entry.name, shown: candidate)
        }
        memory.shown = shown

        let servers = listed.map { id in
            NetworkServer(id: id, name: shown[id]!.name, displayName: shown[id]!.shown, service: byID[id]!)
        }
        .sorted { a, b in
            switch a.displayName.localizedStandardCompare(b.displayName) {
            case .orderedAscending:  return true
            case .orderedDescending: return false
            case .orderedSame:       return a.id < b.id
            }
        }
        return NetworkServerList(servers: servers, hiddenCount: byID.count - listed.count)
    }

    /// What two shown names are compared by, to tell whether they'd look
    /// the same: the text without zero-width joiners and variation selectors
    /// (which `cleanName` keeps in emoji: "Office 😀‍😀" against "Office 😀😀"),
    /// as Swift compares text (composed and decomposed letters alike).
    /// Spaces are already one kind by then. Look-alike letters from other
    /// scripts (a Cyrillic "о") aren't caught.
    static func lookalikeKey(_ shown: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in shown.unicodeScalars where scalar != EmojiSequence.zeroWidthJoiner
            && scalar != EmojiSequence.emojiSelector && scalar != EmojiSequence.textSelector {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Whether a name is written as it's shown: nothing in it that showing
    /// it drops or changes (spaces of other kinds or at the ends, joiners,
    /// selectors, hidden characters), with letters composed. The one of two
    /// look-alikes arriving together that keeps the plain name.
    static func isPlainlyWritten(_ name: String) -> Bool {
        // Most names are printable ASCII: plain unless spaced oddly or too long.
        let bytes = name.utf8
        if bytes.allSatisfy({ (0x20...0x7E).contains($0) }) {
            return !bytes.isEmpty && bytes.count <= displayLimit && bytes.first != 0x20 && bytes.last != 0x20
                && !name.contains("  ")
        }
        // Otherwise a scan of its scalars for anything `cleanName` would drop
        // or change, or `lookalikeKey` ignore; normalized only if it might
        // not be composed (marks, singletons, Hangul jamo).
        let scalars = Array(name.unicodeScalars)
        // (Never more characters than scalars: counted only when it could matter.)
        guard let first = scalars.first, first != " ", scalars.last != " ",
              scalars.count <= displayLimit || name.count <= displayLimit else {
            return false
        }
        var previousSpace = false, marks = 0, mayDecompose = false
        for scalar in scalars {
            if scalar == " " {
                if previousSpace { return false }
                previousSpace = true
                marks = 0
                continue
            }
            previousSpace = false
            if scalar.properties.isWhitespace || scalar == EmojiSequence.zeroWidthJoiner
                || scalar == EmojiSequence.emojiSelector || scalar == EmojiSequence.textSelector || isHidden(scalar) {
                return false
            }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                marks += 1
                if marks > maxMarks { return false }
                mayDecompose = true
            default:
                marks = 0
            }
            if scalar.properties.isFullCompositionExclusion || (0x1100...0x11FF).contains(scalar.value) {
                mayDecompose = true
            }
        }
        return !mayDecompose
            || Array(name.precomposedStringWithCanonicalMapping.unicodeScalars) == scalars
    }

    /// A name's identity: two services are the same server when their names
    /// are, as DNS compares them (ASCII letters without regard to case,
    /// everything else exactly). Kept as ASCII (every other byte
    /// percent-encoded), so names that differ only in how they're encoded
    /// ("é" as one scalar or two), which Swift's strings would take as equal,
    /// stay two rows rather than one hiding the other.
    static func id(for name: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(name.utf8.count)
        for byte in name.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                out.append(byte + 32)
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                out.append(byte)
            default:
                out += [UInt8(ascii: "%"), hex[Int(byte >> 4)], hex[Int(byte & 0xF)]]
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Showing a name

    /// `name` made safe to show in a row (and to VoiceOver):
    /// - control, format and other invisible characters (bidi overrides and
    ///   marks, zero-width spaces and joiners, the BOM, variation selectors,
    ///   tag characters, unassigned code points), characters that draw as
    ///   blank space (the Braille blank, Hangul fillers) and private-use
    ///   characters (drawn as whatever a font puts there) each become one
    ///   "�", so a name can't reorder itself or hide a difference from
    ///   another; a joiner or variation selector inside an emoji ("👨‍💻",
    ///   "❤️") stays (EmojiSequence);
    /// - tabs, line breaks and other spaces become one ordinary space, and
    ///   spaces at the ends go;
    /// - at most a few combining marks (spacing or not) are kept on one letter;
    /// - more than `displayLimit` characters are cut, ending in "…";
    /// - a name that reads as one of the rows Network shows when it has no
    ///   servers ("Searching…") is put in quotes.
    /// Letters, punctuation (Alex’s), symbols and emoji are kept as they are.
    /// A row adds " (2)" and so on when its name would look like another's
    /// (`list`).
    static func displayName(_ name: String) -> String {
        quotedIfPlaceholder(cleanName(name))
    }

    /// `displayName` without the quotes: the name made safe, as a saved
    /// server is named (Save Server in Sidebar).
    static func cleanName(_ name: String) -> String {
        let scalars = Array(name.unicodeScalars)
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        var lastWasReplacement = false
        var marks = 0
        for (index, scalar) in scalars.enumerated() {
            let properties = scalar.properties
            if properties.isWhitespace {
                pendingSpace = !out.isEmpty
                marks = 0
                continue
            }
            if isHidden(scalar) && !EmojiSequence.isDrawn(at: index, in: scalars) {
                if !lastWasReplacement {
                    if pendingSpace { out.append(" ") }
                    out.append("\u{FFFD}")
                }
                pendingSpace = false
                lastWasReplacement = true
                marks = 0
                continue
            }
            switch properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                marks += 1
                // A pile of marks draws over the rows around it.
                if marks > maxMarks { continue }
            default:
                marks = 0
            }
            if pendingSpace { out.append(" ") }
            pendingSpace = false
            lastWasReplacement = false
            out.append(scalar)
        }
        var shown = String(out)
        guard !shown.isEmpty else { return unnamed }
        if shown.count > displayLimit {
            shown = String(shown.prefix(displayLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return shown
    }

    /// `name` in quotes if it reads as one of Network's own rows.
    static func quotedIfPlaceholder(_ name: String) -> String {
        looksLikePlaceholder(name) ? "“" + name + "”" : name
    }

    /// The most combining marks kept on one character.
    private static let maxMarks = 4

    /// Characters drawn as blank space without being spaces.
    private static let blanks: Set<UInt32> = [0x2800, 0x3164, 0xFFA0, 0x115F, 0x1160]

    /// Shows as nothing, as blank space, as whatever a font chooses, or
    /// changes how what's around it is shown.
    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        switch properties.generalCategory {
        case .control, .format, .unassigned, .surrogate, .lineSeparator, .paragraphSeparator, .privateUse:
            return true
        default:
            return properties.isDefaultIgnorableCodePoint || properties.isNoncharacterCodePoint
                || blanks.contains(scalar.value)
        }
    }

    /// A name that reads as one of the dimmed rows Network shows instead of
    /// servers, or after them ("12 more servers…"), whatever the case, the
    /// apostrophe, or how it ends ("Searching...", "Searching", "No servers
    /// found.").
    static func looksLikePlaceholder(_ name: String) -> Bool {
        let key = placeholderKey(name)
        if NetworkPlaceholder.allCases.contains(where: { placeholderKey($0.text) == key }) { return true }
        for suffix in [" more servers", " more server"] where key.hasSuffix(suffix) {
            let count = key.dropLast(suffix.count)
            if !count.isEmpty && count.allSatisfy(\.isNumber) { return true }
        }
        return false
    }

    /// `text` lowercased, "..." as "…", "'" as "’", without trailing dots,
    /// ellipses and spaces.
    private static func placeholderKey(_ text: String) -> String {
        var key = text.lowercased().replacingOccurrences(of: "...", with: "…")
            .replacingOccurrences(of: "'", with: "’")
        while let last = key.last, last == "." || last == "…" || last.isWhitespace { key.removeLast() }
        return key.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Connecting

    /// Whether `address` (a found server's) is a server the user has
    /// connected to or saved before: one in Recent Servers or the saved
    /// servers with the same scheme, host and port, whatever share. Those
    /// connect as soon as they're found; any other waits for the user to
    /// check the address and click Connect.
    static func isKnown(_ address: ServerAddress, recents: [ServerAddress], saved: [SavedServer]) -> Bool {
        let key = address.serverMatchKey
        return recents.contains { $0.serverMatchKey == key } || saved.contains { $0.address.serverMatchKey == key }
    }

    /// The address to connect to for `service`, from what it resolved to: the
    /// host name (`target`, DNSServiceResolve's hosttarget, as its bytes) and
    /// the port. Nil when the host isn't one to connect to (see `hostName`
    /// and ServerAddress.init(scheme:resolvedHost:port:)).
    ///
    /// Why the resolved host, and not the service's name in the address
    /// ("smb://Alex’s iMac._smb._tcp.local", which NetFS also takes):
    /// - the name is whatever a device chose to advertise. In an address it
    ///   would have to be escaped exactly as NetFS unescapes it, and a name
    ///   with a dot in it ("NAS v1.2") makes "<name>._smb._tcp.local"
    ///   ambiguous (DNS writes that dot as "\.", which a URL can't say);
    /// - Bonjour matches names without regard to case only for ASCII
    ///   letters, so any change of case outside them makes a name that isn't
    ///   advertised;
    /// - resolving at the click asks the network for the service as it is
    ///   now, by its exact name, type and domain as separate values, so
    ///   nothing in the name is parsed. What comes back is a host name, held
    ///   to the rules for one (ASCII labels ending in ".local").
    /// The connection sheet shows that host, so what's connected to is what
    /// the user sees, whatever the row's name says.
    static func address(for service: NetworkService, target: [UInt8], port: Int) -> ServerAddress? {
        guard let host = hostName(fromTarget: target) else { return nil }
        return ServerAddress(scheme: .smb, resolvedHost: host, port: port)
    }

    /// A resolved service's host name ("Alexs-iMac.local."), as the resolver
    /// writes it (DNS presentation form: "\." for a dot inside a label,
    /// "\DDD" for other bytes), decoded: "Alexs-iMac.local". Nil for one
    /// that has a dot or a control character inside a label, is empty, isn't
    /// UTF-8, or doesn't end in ".local".
    ///
    /// What ".local" guarantees: the name is one only multicast DNS answers,
    /// never a DNS name looked up beyond the network (a device can't send a
    /// click to "attacker.example.com"). It doesn't keep the connection on
    /// the local network: any device on it can answer for "x.local" with any
    /// address, as it could advertise any service.
    static func hostName(fromTarget bytes: [UInt8]) -> String? {
        var labels: [[UInt8]] = [[]]
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == UInt8(ascii: "\\") {
                let digits = bytes[(i + 1)...].prefix(3)
                if digits.count == 3, digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) {
                    let value = digits.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
                    guard value <= 255 else { return nil }
                    labels[labels.count - 1].append(UInt8(value))
                    i += 4
                } else {
                    guard i + 1 < bytes.count else { return nil }
                    labels[labels.count - 1].append(bytes[i + 1])
                    i += 2
                }
                continue
            }
            if byte == UInt8(ascii: ".") {
                labels.append([])
            } else {
                labels[labels.count - 1].append(byte)
            }
            i += 1
        }
        // The root's dot.
        if labels.count > 1, labels.last?.isEmpty == true { labels.removeLast() }
        guard labels.count >= 2, !labels.contains(where: \.isEmpty) else { return nil }
        var names: [String] = []
        for label in labels {
            guard !label.contains(UInt8(ascii: ".")), !label.contains(where: { $0 < 0x20 || $0 == 0x7F }),
                  let name = String(bytes: label, encoding: .utf8) else { return nil }
            names.append(name)
        }
        guard names.last?.lowercased() == "local" else { return nil }
        return names.joined(separator: ".")
    }
}
