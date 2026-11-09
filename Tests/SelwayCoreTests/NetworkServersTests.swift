import Foundation
import Testing
@testable import SelwayCore

@Suite struct NetworkServersTests {
    private func smb(_ name: String) -> NetworkService { NetworkService(name: name) }
    private func names(_ rows: [NetworkServer]) -> [String] { rows.map(\.displayName) }

    // MARK: One row per server

    @Test func aServerSeenTwiceIsListedOnce() {
        // The same service on Wi-Fi and Ethernet.
        let rows = NetworkServers.rows([smb("NAS"), smb("NAS"), smb("Studio")], thisMac: [])
        #expect(names(rows) == ["NAS", "Studio"])
    }

    @Test func namesMatchAsDNSDoesASCIILettersWithoutCase() {
        let rows = NetworkServers.rows([smb("nas"), smb("NAS")], thisMac: [])
        #expect(rows.count == 1)
        // The same one kept whichever order they come in.
        #expect(rows == NetworkServers.rows([smb("NAS"), smb("nas")], thisMac: []))
        #expect(rows[0].service.name == "NAS")
        // "É" and "é" aren't the same name to Bonjour.
        #expect(NetworkServers.rows([smb("É"), smb("é")], thisMac: []).count == 2)
    }

    @Test func namesThatDifferOnlyInEncodingStayTwoRowsThatReadDifferently() {
        // Swift's String takes these as equal; Bonjour doesn't. Merging them
        // would let one hide the other; showing both the same would hide
        // which is which.
        let composed = "Caf\u{E9}", decomposed = "Cafe\u{301}"
        #expect(composed == decomposed)
        let rows = NetworkServers.rows([smb(composed), smb(decomposed)], thisMac: [])
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)).count == 2)
        #expect(Set(names(rows)).count == 2)
        #expect(names(rows).contains("Café (2)"))
    }

    /// Found together, the plainly written one keeps the name: its look-alikes
    /// (a no-break space, an em space) are numbered after it.
    @Test func rowsFoundTogetherThatWouldReadAlikeAreNumberedPlainOneFirst() {
        let rows = NetworkServers.rows([smb("Office\u{A0}NAS"), smb("Office NAS"), smb("Office\u{2003}NAS")],
                                       thisMac: [])
        #expect(names(rows) == ["Office NAS", "Office NAS (2)", "Office NAS (3)"])
        // Stable: the same rows get the same numbers whatever order they're found in.
        let again = NetworkServers.rows([smb("Office\u{2003}NAS"), smb("Office NAS"), smb("Office\u{A0}NAS")],
                                        thisMac: [])
        #expect(again == rows)
        #expect(rows[0].service.name == "Office NAS")
        // Not by id: " NAS" (id "%20nas") sorts before "NAS" but isn't written as it's shown.
        let spaced = NetworkServers.rows([smb(" NAS"), smb("NAS")], thisMac: [])
        #expect(spaced.first { $0.displayName == "NAS" }?.service.name == "NAS")
        #expect(spaced.contains { $0.displayName == "NAS (2)" && $0.service.name == " NAS" })
    }

    @Test func aNumberAnotherRowAlreadyShowsIsSkipped() {
        let rows = NetworkServers.rows([smb("NAS"), smb("NAS\u{A0}"), smb("NAS (2)")], thisMac: [])
        #expect(Set(names(rows)) == ["NAS", "NAS (2)", "NAS (3)"])
    }

    @Test func rowsAreSortedAsFinderSortsNames() {
        let rows = NetworkServers.rows([smb("nas 10"), smb("NAS 9"), smb("Backup"), smb("ábaco")], thisMac: [])
        #expect(names(rows) == ["ábaco", "Backup", "NAS 9", "nas 10"])
    }

    @Test func idsAreASCIIAndStable() {
        #expect(NetworkServers.id(for: "Alex’s iMac") == "alex%E2%80%99s%20imac")
        #expect(NetworkServers.id(for: "NAS-2_x.y~") == "nas-2_x.y~")
        #expect(NetworkServers.id(for: "a/b%c") == "a%2Fb%25c")
    }

    // MARK: Arrival order

    private func list(_ names: [String], _ memory: inout NetworkRowMemory, limit: Int = NetworkServers.maxRows)
        -> NetworkServerList {
        NetworkServers.list(names.map(smb), thisMac: [], memory: &memory, limit: limit)
    }

    private func shown(_ list: NetworkServerList) -> [String: String] {
        Dictionary(uniqueKeysWithValues: list.servers.map { ($0.service.name, $0.displayName) })
    }

    /// The server that arrived first keeps its name; a look-alike that
    /// arrives later is numbered, however its name sorts.
    @Test func theFirstToArriveKeepsTheName() {
        var memory = NetworkRowMemory()
        _ = list(["NAS"], &memory)
        #expect(shown(list(["NAS", " NAS"], &memory)) == ["NAS": "NAS", " NAS": "NAS (2)"])

        // The other way round too: arrival decides, not how it's written.
        memory = NetworkRowMemory()
        _ = list([" NAS"], &memory)
        #expect(shown(list([" NAS", "NAS"], &memory)) == [" NAS": "NAS", "NAS": "NAS (2)"])
    }

    /// A listed row keeps its name while it's listed: others coming and
    /// going don't renumber it, and a plain name freed isn't handed on to it.
    @Test func numbersStayWhileRowsComeAndGo() {
        var memory = NetworkRowMemory()
        _ = list(["NAS"], &memory)
        _ = list(["NAS", " NAS"], &memory)
        #expect(shown(list(["NAS", " NAS", "NAS\u{A0}"], &memory))
                == ["NAS": "NAS", " NAS": "NAS (2)", "NAS\u{A0}": "NAS (3)"])
        #expect(shown(list(["NAS", "NAS\u{A0}"], &memory)) == ["NAS": "NAS", "NAS\u{A0}": "NAS (3)"])
        #expect(shown(list(["NAS\u{A0}"], &memory)) == ["NAS\u{A0}": "NAS (3)"])
        // A newcomer takes the lowest name free.
        #expect(shown(list(["NAS\u{A0}", "NAS\u{2003}"], &memory)) == ["NAS\u{A0}": "NAS (3)", "NAS\u{2003}": "NAS"])
        // One that leaves and comes back arrives anew.
        _ = list(["NAS\u{A0}"], &memory)
        #expect(shown(list(["NAS\u{A0}", "NAS\u{2003}"], &memory))["NAS\u{2003}"] == "NAS")
    }

    /// Joiners and selectors don't tell two names apart: shown, they look alike.
    @Test func joinersAndSelectorsDontMakeNamesDifferent() {
        let rows = NetworkServers.rows([smb("Office 😀\u{200D}😀"), smb("Office 😀😀")], thisMac: [])
        #expect(Set(names(rows)) == ["Office 😀😀", "Office 😀\u{200D}😀 (2)"])
        #expect(rows.first { $0.displayName == "Office 😀😀" }?.service.name == "Office 😀😀")
        let hearts = NetworkServers.rows([smb("❤\u{FE0F} NAS"), smb("❤ NAS")], thisMac: [])
        #expect(hearts.count == 2 && hearts.contains { $0.displayName.hasSuffix(" (2)") })
    }

    @Test func plainlyWrittenNamesAreThoseShownAsTheyAre() {
        for name in ["NAS", "Alex’s iMac", "Café", "Office 😀😀", "❤ Studio", "a-b_c.d"] {
            #expect(NetworkServers.isPlainlyWritten(name), "\(name)")
        }
        // A selector or joiner counts against it: it's what look-alikes differ by.
        for name in [" NAS", "NAS ", "N  AS", "N\u{A0}AS", "Cafe\u{301}", "Office 😀\u{200D}😀", "NA\u{200B}S", "❤️ Studio",
                     "", String(repeating: "x", count: 64)] {
            #expect(!NetworkServers.isPlainlyWritten(name), "\(name)")
        }
    }

    // MARK: Many servers

    @Test func atMostMaxRowsAreListedAndTheRestCounted() {
        let services = (0..<(NetworkServers.maxRows + 50)).map { String(format: "Server %04d", $0) }
        var memory = NetworkRowMemory()
        let first = list(services.reversed(), &memory)
        #expect(first.servers.count == NetworkServers.maxRows)
        #expect(first.hiddenCount == 50)
        #expect(first.moreText == "50 more servers…")
        // Found together: the first ids; sorted by name.
        #expect(first.servers.first?.displayName == "Server 0000")
        #expect(first.servers.last?.displayName == "Server 0199")
        var other = NetworkRowMemory()
        #expect(first == list(services, &other))
    }

    /// Rows listed stay listed; newcomers take free places in arrival order,
    /// so a flood after a server appeared can't push it out, whatever its names.
    @Test func aFloodCantPushOutARowAlreadyListed() {
        var memory = NetworkRowMemory()
        #expect(list(["Zed NAS"], &memory, limit: 3).servers.map(\.displayName) == ["Zed NAS"])
        let flood = (0..<50).map { "A\($0)" }
        let flooded = list(["Zed NAS"] + flood, &memory, limit: 3)
        #expect(flooded.servers.contains { $0.displayName == "Zed NAS" })
        #expect(flooded.servers.count == 3 && flooded.hiddenCount == 48)
        let listedNow = Set(flooded.servers.map(\.displayName))
        // More of it: still listed, and so are the two that took the free places.
        let more = list(["Zed NAS"] + flood + (0..<50).map { "B\($0)" }, &memory, limit: 3)
        #expect(Set(more.servers.map(\.displayName)) == listedNow)
        // It goes: the place goes to the next to have arrived (the A's, before the B's).
        let gone = list(flood + (0..<50).map { "B\($0)" }, &memory, limit: 3)
        #expect(Set(gone.servers.map(\.displayName)).isSuperset(of: listedNow.subtracting(["Zed NAS"])))
        #expect(gone.servers.allSatisfy { $0.displayName.hasPrefix("A") })
    }

    /// Only the rows listed have their names made safe and compared: the
    /// cap comes before that work.
    @Test func onlyListedRowsHaveTheirNamesWorkedOn() {
        var calls = 0
        var memory = NetworkRowMemory()
        let services = (0..<5_000).map { smb("Server \($0)") }
        let result = NetworkServers.list(services, thisMac: [], memory: &memory, limit: 200) { name in
            calls += 1
            return NetworkServers.cleanName(name)
        }
        #expect(result.servers.count == 200 && calls == 200)
    }

    @Test func aShortListHasNoMoreRow() {
        var memory = NetworkRowMemory()
        let short = list(["NAS", "nas"], &memory)
        #expect(short.servers.count == 1 && short.hiddenCount == 0 && short.moreText == nil)
        #expect(NetworkServerList(servers: [], hiddenCount: 1).moreText == "1 more server…")
        // Duplicates and this Mac don't count as hidden.
        memory = NetworkRowMemory()
        let few = NetworkServers.list([smb("A"), smb("a"), smb("B"), smb("Me")], thisMac: ["Me"], memory: &memory,
                                      limit: 1)
        #expect(few.servers.map(\.displayName) == ["A"] && few.hiddenCount == 1)
    }

    /// A saved server is named by the clean name: no number, no quotes.
    @Test func aRowsNameHasNoNumberOrQuotes() {
        let rows = NetworkServers.rows([smb("Searching…"), smb("NAS"), smb(" NAS"), smb("Evil\u{202E}x")],
                                       thisMac: [])
        #expect(rows.first { $0.service.name == "Searching…" }.map { ($0.displayName, $0.name) }! == ("“Searching…”", "Searching…"))
        #expect(rows.first { $0.service.name == " NAS" }.map { ($0.displayName, $0.name) }! == ("NAS (2)", "NAS"))
        #expect(rows.first { $0.service.name == "Evil\u{202E}x" }?.name == "Evil\u{FFFD}x")
    }

    @Test func aNameThatReadsAsTheMoreRowIsQuoted() {
        #expect(NetworkServers.displayName("12 more servers…") == "“12 more servers…”")
        #expect(NetworkServers.displayName("12 more servers...") == "“12 more servers...”")
        #expect(NetworkServers.displayName("12345 more servers") == "“12345 more servers”")
        #expect(NetworkServers.displayName("1 More Server…") == "“1 More Server…”")
        #expect(NetworkServers.displayName("Many more servers…") == "Many more servers…")
    }

    @Test func aFailedSearchIsRetriedLessOftenUpToEveryThirtySeconds() {
        #expect(NetworkRetry.delay(afterFailures: 1) == 2)
        #expect(NetworkRetry.delay(afterFailures: 2) == 4)
        #expect(NetworkRetry.delay(afterFailures: 4) == 16)
        #expect(NetworkRetry.delay(afterFailures: 5) == 30)
        #expect(NetworkRetry.delay(afterFailures: 1_000) == 30)
        #expect(NetworkRetry.delay(afterFailures: 0) == 2)
    }

    // MARK: This Mac

    @Test func thisMacsOwnServiceIsLeftOut() {
        let rows = NetworkServers.rows([smb("Alex’s MacBook"), smb("NAS")], thisMac: ["Alex’s MacBook"])
        #expect(names(rows) == ["NAS"])
        // As DNS compares names.
        #expect(NetworkServers.rows([smb("ALEX’S MACBOOK")], thisMac: ["Alex’s MacBook"]).isEmpty)
        #expect(NetworkServers.rows([smb("Alex’s MacBook 2")], thisMac: ["Alex’s MacBook"]).count == 1)
        #expect(NetworkServers.rows([smb("NAS")], thisMac: []).count == 1)
    }

    // MARK: Showing names

    @Test(arguments: [
        ("Alex’s iMac", "Alex’s iMac"),
        ("NAS", "NAS"),
        ("Café", "Café"),
        ("  Spaced\tOut \n Name  ", "Spaced Out Name"),
        ("Line\u{2028}Break", "Line Break"),
        ("No\u{A0}break", "No break"),
    ])
    func ordinaryNamesAreShownAsTheyAre(raw: String, shown: String) {
        #expect(NetworkServers.displayName(raw) == shown)
    }

    @Test(arguments: [
        // Bidi overrides, isolates and marks: "Evil‮gnp.exe" would read "Evilexe.png".
        ("Evil\u{202E}gnp.exe", "Evil\u{FFFD}gnp.exe"),
        ("a\u{2067}b\u{2069}c", "a\u{FFFD}b\u{FFFD}c"),
        ("NAS\u{200F}", "NAS\u{FFFD}"),
        // Control characters.
        ("Bell\u{7}Name", "Bell\u{FFFD}Name"),
        ("Esc\u{1B}[31mRed", "Esc\u{FFFD}[31mRed"),
        ("C1\u{85}x\u{9B}y", "C1 x\u{FFFD}y"),
        // Invisible characters: zero-width space and joiner, BOM, soft hyphen.
        ("NA\u{200B}S", "NA\u{FFFD}S"),
        ("nas\u{200D}.local", "nas\u{FFFD}.local"),
        ("\u{FEFF}NAS", "\u{FFFD}NAS"),
        ("N\u{AD}AS", "N\u{FFFD}AS"),
        // Characters drawn as blank space: the Braille blank and the Hangul fillers.
        ("NAS\u{2800}", "NAS\u{FFFD}"),
        ("\u{3164}", "\u{FFFD}"),
        ("A\u{FFA0}B", "A\u{FFFD}B"),
        ("A\u{115F}B\u{1160}C", "A\u{FFFD}B\u{FFFD}C"),
        // Private use: drawn as whatever the font puts there (the Apple logo, or nothing).
        ("Studio \u{F8FF}", "Studio \u{FFFD}"),
        ("NAS\u{F0000}", "NAS\u{FFFD}"),
        // Variation selectors and tags outside an emoji.
        ("NAS\u{FE0F}", "NAS\u{FFFD}"),
        ("NAS\u{E0041}\u{E0042}", "NAS\u{FFFD}"),
        // A run of them is one mark.
        ("A\u{200B}\u{200C}\u{202E}B", "A\u{FFFD}B"),
    ])
    func hiddenAndReorderingCharactersAreShownAsReplacementMarks(raw: String, shown: String) {
        #expect(NetworkServers.displayName(raw) == shown)
    }

    @Test(arguments: ["Alex’s 👨‍💻 Mac", "❤️ Studio", "👨🏽‍💻 Lab", "❤️‍🔥 Box", "Keys 1️⃣", "Watch ⌚︎"])
    func emojiSequencesKeepTheirJoinersAndSelectors(name: String) {
        #expect(NetworkServers.displayName(name) == name)
    }

    @Test func aShownNameHasNoInvisibleOrReorderingCharactersLeft() {
        let hostile = "\u{202E}\u{2066}A\u{200B}\u{7}\u{FE0F}\u{200D}B\u{E0001}\u{FFFE}\u{10FFFF}\u{378}\u{2800}\u{E000}"
        let shown = NetworkServers.displayName(hostile)
        let scalars = Array(shown.unicodeScalars)
        for (i, scalar) in scalars.enumerated() {
            let p = scalar.properties
            #expect(p.generalCategory != .control && p.generalCategory != .format && p.generalCategory != .privateUse
                    && p.generalCategory != .unassigned && !p.isNoncharacterCodePoint && scalar != "\u{2800}")
            #expect(!p.isDefaultIgnorableCodePoint || EmojiSequence.isDrawn(at: i, in: scalars))
        }
    }

    @Test func longNamesAreCut() {
        let long = String(repeating: "x", count: 300)
        let shown = NetworkServers.displayName(long)
        #expect(shown.count == NetworkServers.displayLimit)
        #expect(shown.hasSuffix("…"))
        let exact = String(repeating: "y", count: NetworkServers.displayLimit)
        #expect(NetworkServers.displayName(exact) == exact)
    }

    @Test func pilesOfCombiningMarksAreTrimmed() {
        let zalgo = "Z" + String(repeating: "\u{301}", count: 40) + "a"
        #expect(NetworkServers.displayName(zalgo) == "Z" + String(repeating: "\u{301}", count: 4) + "a")
        #expect(NetworkServers.displayName("e\u{301}") == "e\u{301}")
        // Spacing marks (Mc, U+093E) count with the others.
        let mixed = "क" + String(repeating: "\u{93E}\u{301}", count: 5) + "x"
        #expect(NetworkServers.displayName(mixed) == "क" + String(repeating: "\u{93E}\u{301}", count: 2) + "x")
    }

    @Test func aNameWithNothingToShowIsUnnamed() {
        #expect(NetworkServers.displayName("") == NetworkServers.unnamed)
        #expect(NetworkServers.displayName(" \t\n ") == NetworkServers.unnamed)
    }

    @Test func aNameThatReadsAsAPlaceholderIsQuoted() {
        // (A Bonjour name is at most 63 bytes, so only the shorter ones can be copied.)
        for placeholder in NetworkPlaceholder.allCases where placeholder.text.count <= NetworkServers.displayLimit {
            #expect(NetworkServers.displayName(placeholder.text) == "“\(placeholder.text)”")
        }
        #expect(NetworkServers.displayName("no servers FOUND") == "“no servers FOUND”")
        // However it ends: "..." for "…", a full stop, nothing.
        for name in ["Searching", "Searching...", "searching.", "No servers found.", "No servers found …",
                     "Can't search the network", "Can’t search the network."] {
            #expect(NetworkServers.displayName(name) == "“\(name)”", "\(name)")
        }
        #expect(NetworkServers.displayName("Searching NAS") == "Searching NAS")
    }

    @Test func rowsShowSafeNames() {
        let rows = NetworkServers.rows([smb("Evil\u{202E}gnp.exe")], thisMac: [])
        #expect(rows[0].displayName == "Evil\u{FFFD}gnp.exe")
        // The service keeps its real name, for resolving it.
        #expect(rows[0].service.name == "Evil\u{202E}gnp.exe")
    }

    // MARK: Addresses

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test func aResolvedHostBecomesTheAddress() throws {
        let address = try #require(NetworkServers.address(for: smb("Alex’s iMac"), target: bytes("Alexs-iMac.local."),
                                                          port: 445))
        #expect(address.url.absoluteString == "smb://alexs-imac.local")
        #expect(address.isServerOnly)
        #expect(address.user == nil)
    }

    @Test func aServerConnectedToOrSavedBeforeIsKnown() throws {
        let found = try #require(ServerAddress(scheme: .smb, resolvedHost: "NAS.local", port: 445))
        let share = try ServerAddress.parse("smb://someone@nas.local/Media").get().address
        let other = try ServerAddress.parse("smb://studio.local").get().address
        let otherPort = try ServerAddress.parse("smb://nas.local:4455").get().address
        let afp = try ServerAddress.parse("afp://nas.local").get().address
        #expect(NetworkServers.isKnown(found, recents: [other, share], saved: []))
        #expect(NetworkServers.isKnown(found, recents: [], saved: [SavedServer.make(typed: share)]))
        #expect(!NetworkServers.isKnown(found, recents: [other, otherPort, afp], saved: [SavedServer.make(typed: other)]))
        #expect(!NetworkServers.isKnown(found, recents: [], saved: []))
        #expect(found.serverMatchKey == "smb://nas.local:445" && share.serverMatchKey == found.serverMatchKey)
    }

    @Test func anUnusualPortIsKept() throws {
        let address = try #require(NetworkServers.address(for: smb("NAS"), target: bytes("nas.local."), port: 4455))
        #expect(address.url.absoluteString == "smb://nas.local:4455")
        #expect(NetworkServers.address(for: smb("NAS"), target: bytes("nas.local."), port: 0) == nil)
        #expect(NetworkServers.address(for: smb("NAS"), target: bytes("nas.local."), port: 70000) == nil)
    }

    @Test func theServicesNameNeverReachesTheAddress() throws {
        // Whatever the name, the address is the resolved host's.
        for name in ["evil@attacker.example/x", "a:b%2F", "NAS v1.2", "x\u{202E}y"] {
            let address = try #require(NetworkServers.address(for: smb(name), target: bytes("nas.local."), port: 445))
            #expect(address.url.absoluteString == "smb://nas.local")
        }
    }

    @Test(arguments: [
        "attacker.example.com.",     // not a multicast DNS name
        "local.",                    // no host
        "",                          // nothing
        ".",
        "nas..local.",               // an empty label
        #"evil\.example.local."#,    // a dot inside a label
        #"nas\010.local."#,          // a control character
        #"nas\256.local."#,          // not a byte
        #"nas\"#,                    // cut off
        #"my\032nas.local."#,        // a space
        "nas@x.local.",              // what a host name can't have
        "nas%41.local.",
        "nas:445.local.",
        "fe80::1.local.",
        "nas/share.local.",
        "nas_x.local.",
        "-nas.local.",
        "nas\u{200D}.local.",        // invisible
        "\u{202E}nas.local.",        // a control or format character
        "caf\u{E9}.local.",          // not ASCII
        "👨‍💻-lab.local.",
    ])
    func unusableHostsAreRefused(target: String) {
        #expect(NetworkServers.address(for: smb("NAS"), target: bytes(target), port: 445) == nil)
    }

    @Test func invalidUTF8IsRefused() {
        #expect(NetworkServers.hostName(fromTarget: [0x6E, 0xFF, 0x2E] + bytes("local.")) == nil)
    }

    @Test func escapesAreDecoded() {
        #expect(NetworkServers.hostName(fromTarget: bytes(#"my\032nas.local."#)) == "my nas.local")
        #expect(NetworkServers.hostName(fromTarget: bytes(#"my\-nas.LOCAL"#)) == "my-nas.LOCAL")
        #expect(NetworkServers.hostName(fromTarget: bytes("a.b.local.")) == "a.b.local")
        #expect(NetworkServers.address(for: smb("x"), target: bytes(#"my\-nas.LOCAL"#), port: 445)?.host
                == "my-nas.local")
    }

    // MARK: Placeholder

    @Test func thePlaceholderSaysHowTheSearchIsGoing() {
        typealias P = NetworkPlaceholder
        #expect(P.current(state: .searching, serverCount: 0, searchedLong: false) == .searching)
        #expect(P.current(state: .searching, serverCount: 0, searchedLong: true) == .noneFound)
        #expect(P.current(state: .searching, serverCount: 2, searchedLong: false) == nil)
        #expect(P.current(state: .searching, serverCount: 2, searchedLong: true) == nil)
        #expect(P.current(state: .notAllowed, serverCount: 0, searchedLong: false) == .notAllowed)
        #expect(P.current(state: .notAllowed, serverCount: 3, searchedLong: true) == .notAllowed)
        #expect(P.current(state: .unavailable, serverCount: 0, searchedLong: false) == .unavailable)
        #expect(P.current(state: .unavailable, serverCount: 1, searchedLong: false) == nil)
        for placeholder in P.allCases {
            #expect(!placeholder.text.isEmpty && !placeholder.detail.isEmpty)
        }
        #expect(P.notAllowed.text.contains("Privacy & Security") && P.notAllowed.text.contains("Local Network"))
    }

    @Test func theNetworkRowsValueSaysHowTheSearchIsGoing() {
        typealias S = NetworkStatus
        #expect(S.value(isOpen: false, placeholder: nil, serverCount: 3) == "")
        #expect(S.value(isOpen: true, placeholder: .searching, serverCount: 0) == "Searching")
        #expect(S.value(isOpen: true, placeholder: nil, serverCount: 1) == "1 server")
        #expect(S.value(isOpen: true, placeholder: nil, serverCount: 250) == "250 servers")
        #expect(S.value(isOpen: true, placeholder: .noneFound, serverCount: 0) == "No servers found")
        #expect(S.value(isOpen: true, placeholder: .notAllowed, serverCount: 0) == "Local Network access off")
        #expect(S.value(isOpen: true, placeholder: .unavailable, serverCount: 0) == "Can’t search the network")
    }

    @Test func eachOpeningAnnouncesItsOutcomeOnce() {
        var said = NetworkStatus.Said()
        func say(_ p: NetworkPlaceholder?, _ n: Int) -> String? {
            NetworkStatus.announcement(placeholder: p, serverCount: n, said: &said)
        }
        #expect(say(.searching, 0) == nil)
        #expect(say(.noneFound, 0) == "No servers found")
        #expect(say(.noneFound, 0) == nil)
        // Servers turning up after all: said once, not for each one.
        #expect(say(nil, 1) == "1 server found")
        #expect(say(nil, 2) == nil)
        #expect(say(.noneFound, 0) == nil)

        // Found straight away: the rows say so; nothing is announced.
        said = NetworkStatus.Said()
        #expect(say(.searching, 0) == nil)
        #expect(say(nil, 3) == nil)
        #expect(say(nil, 4) == nil)

        said = NetworkStatus.Said()
        #expect(say(.notAllowed, 0) == NetworkPlaceholder.notAllowed.spokenText)
        #expect(say(.unavailable, 0) == nil)
    }

    @Test func spokenTextHasNoMenuArrows() {
        for placeholder in NetworkPlaceholder.allCases {
            #expect(!placeholder.spokenText.contains("›") && !placeholder.spokenText.contains("→"))
            #expect(!placeholder.detail.contains("›") && !placeholder.detail.contains("→"))
        }
        for failure in [NetworkResolveFailure.notFound, .notAllowed, .unusableAddress] {
            let message = failure.message(serverName: "NAS")
            #expect(!message.contains("›") && !message.contains("→"))
        }
        #expect(NetworkPlaceholder.notAllowed.needsAttention && NetworkPlaceholder.unavailable.needsAttention)
        #expect(!NetworkPlaceholder.searching.needsAttention && !NetworkPlaceholder.noneFound.needsAttention)
    }

    @Test func resolveFailuresSaySo() {
        for failure in [NetworkResolveFailure.notFound, .notAllowed, .unusableAddress] {
            #expect(!failure.message(serverName: "NAS").isEmpty)
        }
        #expect(NetworkResolveFailure.notFound.message(serverName: "NAS").contains("“NAS”"))
        // The sheet the message shows in is the one to type an address in.
        #expect(!NetworkResolveFailure.unusableAddress.message(serverName: "NAS").contains("Connect to Server"))
    }

    @Test func onlySMBIsLookedFor() {
        #expect(NetworkService.bonjourType == "_smb._tcp")
    }
}
