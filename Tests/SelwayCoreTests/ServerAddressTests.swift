import Foundation
import Testing
@testable import SelwayCore

@Suite struct ServerAddressTests {
    private func address(_ text: String) throws -> ServerAddress {
        try ServerAddress.parse(text).get().address
    }

    private func error(_ text: String) -> ServerAddressError? {
        if case .failure(let error) = ServerAddress.parse(text) { return error }
        return nil
    }

    // MARK: What's accepted, and in what form

    @Test func anSMBAddressIsKeptAsTyped() throws {
        let a = try address("smb://nas/Documents")
        #expect(a.scheme == .smb && a.host == "nas" && a.port == nil && a.user == nil)
        #expect(a.path == "/Documents")
        #expect(a.url.absoluteString == "smb://nas/Documents")
        #expect(a.displayString == "smb://nas/Documents")
    }

    @Test func displayHostShowsPunycodeWithoutChangingAsciiHosts() throws {
        #expect(ServerAddress.displayHost("nas.local") == "nas.local")
        #expect(ServerAddress.displayHost("bücher.example") == "bücher.example (xn--bcher-kva.example)")
        #expect(ServerAddress.displayHost("münchen") == "münchen (xn--mnchen-3ya)")
        #expect(ServerAddress.displayHost("пример") == "пример (xn--e1afmkfd)")
        #expect(ServerAddress.displayHost("gооgle.com") == "gооgle.com (xn--ggle-55da.com)")
        #expect(ServerAddress.displayHost("Bücher.Example") == "Bücher.Example (xn--bcher-kva.example)")
        // What it's looked up as: fullwidth and ideographic dots are dots,
        // fullwidth letters are letters.
        #expect(ServerAddress.displayHost("google\u{FF0E}com") == "google\u{FF0E}com (google.com)")
        #expect(ServerAddress.displayHost("gооgle\u{3002}com") == "gооgle\u{3002}com (xn--ggle-55da.com)")
        #expect(ServerAddress.displayHost("\u{FF47}oogle.com") == "\u{FF47}oogle.com (google.com)")
        // A Bonjour service name isn't looked up in DNS.
        #expect(ServerAddress.displayHost("alex\u{2019}s mac._smb._tcp.local") == "alex\u{2019}s mac._smb._tcp.local")
        #expect(ServerAddress.displayHost("fe80::1") == "fe80::1")
    }

    @Test func displayAddressAddsTheASCIIHostAndChangesNothingElse() throws {
        #expect(try address("smb://bücher.example:1445/share").displayAddress
                == "smb://bücher.example:1445/share (xn--bcher-kva.example)")
        #expect(try address("smb://[fe80::1]:1445/share").displayAddress == "smb://[fe80::1]:1445/share")
        #expect(try address("smb://nas.local/share").displayAddress == "smb://nas.local/share")
        #expect(try address("smb://person@bücher.example/share").displayAddress
                == "smb://person@bücher.example/share (xn--bcher-kva.example)")
        #expect(try address("smb://bücher.example/share").displayString == "smb://bücher.example/share")
        #expect(try address("smb://person@bücher.example/share").logDescription
                == "smb://bücher.example/share")
    }

    @Test func noSchemeMeansSMB() throws {
        #expect(try address("nas/Documents").url.absoluteString == "smb://nas/Documents")
        #expect(try address("nas").url.absoluteString == "smb://nas")
        #expect(try address("//nas/Documents").url.absoluteString == "smb://nas/Documents")
        #expect(try address(#"\\nas\Documents\Sub"#).url.absoluteString == "smb://nas/Documents/Sub")
        #expect(try address("192.0.2.35").url.absoluteString == "smb://192.0.2.35")
        #expect(try address("nas:4455/share").url.absoluteString == "smb://nas:4455/share")
    }

    @Test(arguments: [
        ("afp://mac/Share", "afp://mac/Share"),
        ("nfs://192.0.2.35/srv/nfs/Backups", "nfs://192.0.2.35/srv/nfs/Backups"),
        ("http://dav.example.com/files", "http://dav.example.com/files"),
        ("https://dav.example.com/remote.php/dav", "https://dav.example.com/remote.php/dav"),
        ("ftp://ftp.example.com/pub", "ftp://ftp.example.com/pub"),
        ("cifs://nas/share", "smb://nas/share"),
        ("webdav://dav.example.com/x", "http://dav.example.com/x"),
        ("webdavs://dav.example.com/x", "https://dav.example.com/x"),
    ])
    func everyAllowedSchemeAndAlias(typed: String, url: String) throws {
        #expect(try address(typed).url.absoluteString == url)
    }

    @Test func schemeAndHostAreLowercasedButNotTheShare() throws {
        let a = try address("SMB://NAS.Local/Media")
        #expect(a.url.absoluteString == "smb://nas.local/Media")
        #expect(try address("HTTPS://Dav.Example.COM/Files").url.absoluteString == "https://dav.example.com/Files")
    }

    @Test func whitespaceAroundIsIgnored() throws {
        #expect(try address("  smb://nas/share \n").url.absoluteString == "smb://nas/share")
        #expect(try address("\tnas/share\t").url.absoluteString == "smb://nas/share")
    }

    @Test func aDefaultPortIsDroppedAndOthersKept() throws {
        #expect(try address("smb://nas:445/share").port == nil)
        #expect(try address("afp://mac:548/x").port == nil)
        #expect(try address("https://dav:443/x").port == nil)
        #expect(try address("http://dav:80/x").port == nil)
        #expect(try address("ftp://f:21").port == nil)
        #expect(try address("nfs://n:2049/e").port == nil)
        let custom = try address("smb://nas:1445/share")
        #expect(custom.port == 1445 && custom.url.absoluteString == "smb://nas:1445/share")
        #expect(try address("smb://nas:445/share") == address("smb://nas/share"))
    }

    @Test func extraSlashesAndATrailingSlashGo() throws {
        #expect(try address("smb://nas//share///sub/").path == "/share/sub")
        #expect(try address("smb://nas/").path == "")
        #expect(try address("smb://nas/share/") == address("smb://nas/share"))
    }

    @Test func aShareWithSpacesIsEncodedOnlyInTheURL() throws {
        let a = try address("smb://nas/My Share/Sub Folder")
        #expect(a.path == "/My Share/Sub Folder")
        #expect(a.url.absoluteString == "smb://nas/My%20Share/Sub%20Folder")
        #expect(a.displayString == "smb://nas/My Share/Sub Folder")
        // Typed encoded, it's the same address.
        #expect(try address("smb://nas/My%20Share/Sub%20Folder") == a)
    }

    @Test func nonASCIIAndReservedCharactersInNamesAreEncoded() throws {
        let a = try address("smb://nas/Café & Co/R+D;x=1")
        #expect(a.path == "/Café & Co/R+D;x=1")
        #expect(a.url.absoluteString == "smb://nas/Caf%C3%A9%20%26%20Co/R%2BD%3Bx%3D1")
        #expect(URL(string: a.url.absoluteString) != nil)
    }

    @Test func aPercentSignInANameSurvivesTheField() throws {
        let a = try address("smb://nas/100%25 done")
        #expect(a.path == "/100% done")
        #expect(a.displayString == "smb://nas/100%25 done")
        #expect(try address(a.displayString) == a)
    }

    @Test func questionMarksAndHashesInNamesAreTypedEncoded() throws {
        let a = try address("smb://nas/What%3F/No%23")
        #expect(a.path == "/What?/No#")
        #expect(a.displayString == "smb://nas/What%3F/No%23")
        #expect(try address(a.displayString) == a)
    }

    @Test(arguments: [
        "smb://nas/share", "smb://alex@nas:1445/My Share/Sub", "nfs://198.51.100.2/srv/nfs/Backups",
        "smb://[fe80::1%25en0]/share", "afp://Alex’s Mac._afpovertcp._tcp.local/Home",
        "https://dav.example.com/remote.php/dav/files/alex", "smb://DOMAIN;alex@server/x",
        "smb://a%40b.com@nas/share", "smb://nas/100%25/%3F%23",
    ])
    func theDisplayFormParsesBackToTheSameAddress(typed: String) throws {
        let a = try address(typed)
        #expect(try address(a.displayString) == a)
        #expect(try address(a.url.absoluteString) == a)
    }

    // MARK: IPv6 and Bonjour names

    @Test func bracketedIPv6WithAndWithoutAPort() throws {
        let a = try address("smb://[FE80::1]/share")
        #expect(a.host == "fe80::1" && a.port == nil)
        #expect(a.url.absoluteString == "smb://[fe80::1]/share")
        let b = try address("smb://[2001:db8::5]:1445/share")
        #expect(b.host == "2001:db8::5" && b.port == 1445)
        #expect(b.url.absoluteString == "smb://[2001:db8::5]:1445/share")
    }

    @Test func anIPv6ZoneIsKept() throws {
        let a = try address("smb://[fe80::1%25en0]/share")
        #expect(a.host == "fe80::1%en0")
        #expect(a.url.absoluteString == "smb://[fe80::1%25en0]/share")
    }

    @Test func aBareIPv6AddressIsTakenAsTheHost() throws {
        let a = try address("fe80::1")
        #expect(a.scheme == .smb && a.host == "fe80::1" && a.path == "")
        #expect(try address("2001:db8::5/share").path == "/share")
        #expect(try address("smb://2001:db8::5/share").host == "2001:db8::5")
    }

    @Test func aBonjourServiceNameWithSpacesIsAHost() throws {
        let a = try address("smb://Alex’s MacBook._smb._tcp.local/Documents")
        #expect(a.host == "alex’s macbook._smb._tcp.local")
        #expect(a.url.absoluteString.hasPrefix("smb://alex%E2%80%99s%20macbook._smb._tcp.local/"))
    }

    @Test func aFullyQualifiedNamesRootDotGoes() throws {
        #expect(try address("smb://nas.example.com./share").host == "nas.example.com")
    }

    // MARK: Credentials

    /// A password in the address is never kept: not in the address, its URL,
    /// its display or log forms. The user name is, as Finder keeps it.
    @Test func aPasswordIsDroppedAndTheUserNameKept() throws {
        let parsed = try ServerAddress.parse("smb://alex:hunter2@nas/share").get()
        #expect(parsed.droppedPassword)
        let a = parsed.address
        #expect(a.user == "alex")
        #expect(a.url.absoluteString == "smb://alex@nas/share")
        #expect(a.displayString == "smb://alex@nas/share")
        #expect(a.logDescription == "smb://nas/share")
        for text in [a.url.absoluteString, a.displayString, a.logDescription, a.matchKey, "\(a)"] {
            #expect(!text.contains("hunter2"))
        }
        #expect(a.url.password == nil)
    }

    @Test func anEmptyPasswordIsDroppedQuietly() throws {
        // An SMB guest mount's remount URL: "smb://GUEST:@host/share".
        let parsed = try ServerAddress.parse("smb://GUEST:@NAS._smb._tcp.local/Documents").get()
        #expect(!parsed.droppedPassword)
        #expect(parsed.address.url.absoluteString == "smb://GUEST@nas._smb._tcp.local/Documents")
    }

    @Test func passwordsWithAwkwardCharactersAreDroppedWhole() throws {
        let parsed = try ServerAddress.parse("smb://alex:p%40ss:w0rd@nas/share").get()
        #expect(parsed.droppedPassword && parsed.address.user == "alex" && parsed.address.host == "nas")
        #expect(!parsed.address.url.absoluteString.contains("w0rd"))
        // "@" in the password, unencoded: the host is after the last "@".
        let raw = try ServerAddress.parse("smb://alex:p@ss@nas/share").get()
        #expect(raw.address.host == "nas" && raw.address.user == "alex")
        #expect(!raw.address.url.absoluteString.contains("ss@"))
    }

    @Test func aUserNameCanBeAnEmailAddressOrHaveADomain() throws {
        let email = try address("smb://alex@example.com@nas/share")
        #expect(email.user == "alex@example.com")
        #expect(email.url.absoluteString == "smb://alex%40example.com@nas/share")
        #expect(try address("smb://WORKGROUP;alex@nas/share").user == "WORKGROUP;alex")
        #expect(try address("smb://@nas/share").user == nil)
    }

    @Test func theRemountURLOfAMountedShareLosesItsPassword() throws {
        let url = try #require(URL(string: "smb://GUEST:secret@NAS._smb._tcp.local/Documents"))
        let a = try #require(ServerAddress(remountURL: url))
        #expect(a.url.absoluteString == "smb://GUEST@nas._smb._tcp.local/Documents")
        #expect(ServerAddress(remountURL: URL(fileURLWithPath: "/Volumes/x")) == nil)
        #expect(ServerAddress(remountURL: try #require(URL(string: "vnc://host"))) == nil)
    }

    // MARK: What's refused

    @Test(arguments: [
        ("file:///etc/passwd", "file"), ("file:/etc", "file"), ("FILE://localhost/x", "file"),
        ("vnc://mac.local", "vnc"), ("selway://open?path=/tmp", "selway"),
        ("javascript:alert(1)", "javascript"), ("data:text/html,x", "data"),
        ("ssh://host", "ssh"), ("sftp://host/x", "sftp"), ("mailto:a@b.c", "mailto"),
        ("x-apple.systempreferences:com.apple", "x-apple.systempreferences"), ("telnet://h", "telnet"),
        ("afp+ssh://host", "afp+ssh"), ("smb2://host/x", "smb2"),
    ])
    func otherSchemesAreRefused(typed: String, scheme: String) {
        #expect(error(typed) == .unsupportedScheme(scheme))
    }

    @Test func emptyAndBlankAreRefused() {
        #expect(error("") == .empty)
        #expect(error("   \n\t ") == .empty)
    }

    @Test func aMissingHostIsRefused() {
        #expect(error("smb://") == .missingHost)
        #expect(error("smb:///share") == .missingHost)
        #expect(error("smb://user@/share") == .missingHost)
        #expect(error("smb://n@s@/x") == .missingHost)
        #expect(error("smb://:445/share") == .missingHost)
        #expect(error("/Volumes/share") == .missingHost)
        #expect(error("/") == .missingHost)
    }

    @Test func aSchemeWithoutSlashesSaysSo() {
        #expect(error("smb:nas/share") == .missingSlashes(.smb))
        #expect(error("smb:/nas/share") == .missingSlashes(.smb))
        #expect(error("https:dav") == .missingSlashes(.https))
    }

    @Test(arguments: ["smb://nas:0/x", "smb://nas:65536/x", "smb://nas:abc/x", "smb://nas:-1/x",
                      "smb://nas:123456/x", "smb://[::1]:x/s", "smb://nas:4 45/x"])
    func badPortsAreRefused(typed: String) {
        #expect(error(typed) == .invalidPort)
    }

    @Test func queriesAndFragmentsAreRefused() {
        #expect(error("smb://nas/share?x=1") == .queryOrFragment)
        #expect(error("https://dav/x#top") == .queryOrFragment)
        #expect(error("nas/share?") == .queryOrFragment)
    }

    @Test func badPercentEscapesAreRefused() {
        #expect(error("smb://nas/100%") == .invalidPercentEncoding)
        #expect(error("smb://nas/%zz") == .invalidPercentEncoding)
        #expect(error("smb://na%zzs/x") == .invalidPercentEncoding)
        #expect(error("smb://us%zzer@nas/x") == .invalidPercentEncoding)
    }

    @Test func controlCharactersAreRefusedTypedOrEncoded() {
        #expect(error("smb://nas/sh\u{0}are") == .invalidCharacters)
        #expect(error("smb://nas/a%00b") == .invalidCharacters)
        #expect(error("smb://nas/a%0Ab") == .invalidCharacters)
        #expect(error("smb://nas/a\u{7}b") == .invalidCharacters)
        #expect(error("smb://us%0Aer@nas/x") == .invalidCharacters)
        // A right-to-left override would make the address read differently.
        #expect(error("smb://nas/\u{202E}gpj.exe") == .invisibleCharacters)
        #expect(error("smb://nas/line\u{2028}break") == .invalidCharacters)
    }

    @Test func pathTraversalIsRefused() {
        #expect(error("smb://nas/share/../other") == .relativePath)
        #expect(error("smb://nas/./share") == .relativePath)
        #expect(error("smb://nas/share/%2E%2E/x") == .relativePath)
        #expect(error("smb://nas/a%2Fb") == .invalidCharacters)
        #expect(error("smb://nas/a%5Cb") == .invalidCharacters)
    }

    @Test(arguments: ["smb://na me /x", "smb://.nas/x", "smb://nas..local/x", "smb://n<a>s/x", "smb://n|s/x",
                      "smb://[fe80::1/x", "smb://[nothex::zz]/x", "smb://[fe80::1]x/s", "smb://n*s/x",
                      "smb://nas%2Fevil/x", "smb://nas%40evil/x", "smb://[]/x"])
    func badHostsAreRefused(typed: String) {
        #expect(error(typed) != nil)
    }

    @Test func aBareIPv6WithAPortLikeEndIsStillAHost() throws {
        // "fe80::1:445" is an IPv6 address (the last group is 445), not a port.
        #expect(try address("fe80::1:445").host == "fe80::1:445")
        #expect(error("fe80::zz") != nil)
    }

    @Test func tooLongIsRefused() {
        #expect(error("smb://nas/" + String(repeating: "a", count: ServerAddress.maxLength)) == .tooLong)
    }

    @Test func garbageIsRefusedWithoutCrashing() {
        let samples = ["://", ":", "::", ":::", "@", "@@", "[", "]", "[]", "%", "%%", "smb://@", "smb://[",
                       "smb://]", "smb://:", "smb://nas:", "\\\\", "\\\\\\", "////", "?", "#", "😀",
                       "smb://😀/x", String(repeating: ":", count: 300), "smb://" + String(repeating: "@", count: 50)]
        for sample in samples {
            switch ServerAddress.parse(sample) {
            case .failure: break
            case .success(let parsed):
                // Whatever's accepted is a well-formed, allowed address.
                #expect(ServerScheme.allCases.contains(parsed.address.scheme))
                #expect(!parsed.address.host.isEmpty)
                #expect(URL(string: parsed.address.url.absoluteString) != nil)
            }
        }
    }

    @Test func everyErrorHasAMessage() {
        let errors: [ServerAddressError] = [.empty, .tooLong, .unsupportedScheme("file"), .missingSlashes(.smb),
                                            .missingHost, .invalidHost, .invalidPort, .queryOrFragment,
                                            .invalidPercentEncoding, .invalidCharacters, .relativePath]
        for e in errors { #expect(!e.message.isEmpty) }
        #expect(ServerAddressError.unsupportedScheme("file").message.contains("“file:”"))
    }

    // MARK: Delimiters are scalars, not Characters (review regressions)

    /// ":" followed by a combining mark is one Character, but still starts
    /// the password, which is dropped.
    @Test func aColonBeforeACombiningMarkStillStartsThePassword() throws {
        let parsed = try ServerAddress.parse("smb://user:\u{301}secret@nas/share").get()
        #expect(parsed.address.user == "user")
        #expect(parsed.droppedPassword)
        #expect(!parsed.address.url.absoluteString.contains("secret"))
        #expect(!parsed.address.displayString.contains("secret"))
    }

    /// An encoded ":" in the user info is a password all the same.
    @Test func anEncodedColonInTheUserInfoStartsThePassword() throws {
        let parsed = try ServerAddress.parse("smb://user%3Apass@nas/share").get()
        #expect(parsed.address.user == "user" && parsed.droppedPassword)
        #expect(!parsed.address.url.absoluteString.contains("pass"))
        let empty = try ServerAddress.parse("smb://user%3A@nas/share").get()
        #expect(empty.address.user == "user" && !empty.droppedPassword)
    }

    @Test(arguments: ["smb://nas/a%2F%CC%81..%2F%CC%81../x", "smb://nas/share/a%5C%CC%81b",
                      "smb://nas/a/\u{301}b", "smb://nas/share/%CC%81", "smb://nas/%E2%80%8D..",
                      "smb://\u{301}user@nas/share", "smb://%CC%81user@nas/share",
                      "smb://\u{301}nas/share", "smb://%CC%81nas/share", "smb://\u{20DD}nas/x"])
    func encodedSeparatorsAndLeadingMarksAreRefused(typed: String) {
        #expect(error(typed) != nil)
    }

    @Test func aSlashBeforeACombiningMarkStillEndsTheHost() throws {
        // Without the scalar split, "nas/́share" was one host-and-path Character run.
        #expect(error("smb://nas/\u{301}share") == .invalidCharacters)
        let a = try address("smb://nas/caf\u{E9}/e\u{301}")
        #expect(a.host == "nas" && a.pathComponents == ["caf\u{E9}", "e\u{301}"])
    }

    @Test func pathComponentsSplitOnScalars() {
        // A Prepend character (U+0600) before "/" makes one Character of the two.
        #expect(ServerAddress.components("/a\u{600}/b") == ["a\u{600}", "b"])
        #expect(ServerAddress.components("//x///y/") == ["x", "y"])
    }

    // MARK: Invisible characters in hosts

    @Test(arguments: ["smb://nas\u{200D}.local/share", "smb://nas\u{200C}.local/x", "smb://nas\u{200B}/x",
                      "smb://\u{FEFF}nas/x", "smb://n\u{AD}as/x", "smb://nas\u{FE0F}/x", "smb://nas\u{3164}/x",
                      "smb://nas\u{A0}box/x", "smb://nas\u{2003}box/x", "smb://nas%E2%80%8D.local/x",
                      "smb://nas%C2%A0box/x", "smb://nas\u{2060}/x", "smb://nas\u{180E}/x"])
    func invisibleCharactersInHostsAreRefused(typed: String) {
        #expect(error(typed) == .invisibleCharacters)
    }

    /// Mac computer names, which Bonjour names are made from, can have emoji:
    /// the joiner and variation selector inside one are part of it.
    @Test(arguments: [
        ("smb://Alex’s 👨‍💻 Mac._smb._tcp.local/x", "alex’s 👨‍💻 mac._smb._tcp.local"),
        ("smb://Alex's ❤️ Mac._smb._tcp.local/x", "alex's ❤️ mac._smb._tcp.local"),
        // © is drawn as text unless VS16 asks for the emoji: accepted, like ❤️.
        ("smb://nas©️.local/x", "nas©️.local"),
        ("smb://❤️‍🔥.local/x", "❤️‍🔥.local"),
        ("smb://👨🏽‍💻-lab.local/x", "👨🏽‍💻-lab.local"),
        ("smb://keys1️⃣.local/x", "keys1️⃣.local"),
        ("smb://Alex%E2%80%99s%20%F0%9F%91%A8%E2%80%8D%F0%9F%92%BB%20Mac._smb._tcp.local/x",
         "alex’s 👨‍💻 mac._smb._tcp.local"),
    ])
    func emojiSequencesInHostsAreAccepted(typed: String, host: String) throws {
        let a = try address(typed)
        #expect(a.host == host)
        // And the address it makes reads back the same.
        #expect(try address(a.url.absoluteString) == a)
        #expect(try address(a.displayString) == a)
    }

    /// Outside an emoji sequence a joiner or a variation selector still hides,
    /// and so does one that would change nothing drawn.
    @Test(arguments: ["smb://nas\u{200D}.local/x", "smb://👨\u{200D}.local/x", "smb://\u{200D}👨.local/x",
                      "smb://a\u{FE0F}b.local/x", "smb://nas1\u{FE0F}.local/x", "smb://👨\u{200D}x.local/x",
                      "smb://👨\u{FE00}.local/x", "smb://nas%E2%80%8D.local/x", "smb://👨\u{200B}💻.local/x",
                      "smb://nas😀\u{FE0F}.local/x", "smb://nas😀\u{FE0E}.local/x", "smb://nas™\u{200D}©.local/x",
                      "smb://🇺\u{200D}🇸.local/x", "smb://🏽\u{200D}🏽.local/x", "smb://nas©\u{FE0E}.local/x"])
    func joinersAndSelectorsOutsideEmojiAreStillRefused(typed: String) {
        #expect(error(typed) == .invisibleCharacters)
    }

    /// Hosts are lowercased as before this branch, every letter: Recent
    /// Servers and saved servers stored that way go on matching.
    @Test func hostsAreLowercasedSoNonASCIICaseStillMatches() throws {
        #expect(try address("smb://Ölserver.LOCAL/x").host == "ölserver.local")
        #expect(try address("smb://Ölserver.local/x").matchKey == address("smb://ölserver.local/x").matchKey)
        #expect(try address("smb://Ölserver.local").serverMatchKey == address("smb://ölserver.local/Share").serverMatchKey)
        #expect(try address("smb://ÉCOLE-Nas/x").host == "école-nas")
    }

    @Test func aResolvedHostIsCheckedAsATypedOneIs() throws {
        let a = try #require(ServerAddress(scheme: .smb, resolvedHost: "Alexs-iMac.local", port: 445))
        #expect(a.url.absoluteString == "smb://alexs-imac.local" && a.port == nil && a.path.isEmpty)
        #expect(ServerAddress(scheme: .smb, resolvedHost: "nas.local.", port: 445)?.host == "nas.local")
        #expect(ServerAddress(scheme: .afp, resolvedHost: "nas.local", port: 5480)?.url.absoluteString
                == "afp://nas.local:5480")
        for bad in ["", "nas..local", "n%41s.local", "nas:445", "fe80::1", "[fe80::1]", "a/b", "u@nas", "nas\u{7}",
                    "nas\u{200D}.local", "\u{202E}nas", " nas", "nas#x", "nas", "nas.example.com", "local"] {
            #expect(ServerAddress(scheme: .smb, resolvedHost: bad, port: 445) == nil, "\(bad)")
        }
        #expect(ServerAddress(scheme: .smb, resolvedHost: "nas.local", port: 0) == nil)
        #expect(ServerAddress(scheme: .smb, resolvedHost: "nas.local", port: 65536) == nil)
    }

    /// A resolved host is a multicast DNS name: ASCII letters, digits and
    /// hyphens. Look-alikes a typed host may contain are refused.
    @Test(arguments: [
        "nas.l\u{43E}cal",         // Cyrillic о
        "n\u{430}s.local",          // Cyrillic а
        "nas\u{2024}x.local",       // one dot leader, looks like "."
        "nas\u{FF0E}x.local",       // fullwidth full stop
        "nas\u{2800}.local",        // Braille blank
        "nas\u{F8FF}.local",        // private use
        "nas\u{301}.local",         // a combining mark
        "Ölserver.local",
        "café.local",
        "👨‍💻-lab.local",
        "my nas.local",
        "nas_1.local",
        "-nas.local",
        "nas-.local",
    ])
    func resolvedHostsAreASCIIOnly(host: String) {
        #expect(ServerAddress(scheme: .smb, resolvedHost: host, port: 445) == nil)
        #expect(!ServerAddress.isResolvedHostName(host))
    }

    @Test func ordinarySpacesAndLettersInBonjourNamesStillWork() throws {
        #expect(try address("smb://Alex’s Mac._smb._tcp.local/x").host == "alex’s mac._smb._tcp.local")
        #expect(try address("smb://café.local/x").host == "café.local")
        #expect(!ServerAddressError.invisibleCharacters.message.isEmpty)
    }

    // MARK: IPv6 zones and root dots

    @Test func ipv6ZonesAreLettersDigitsAndAFewMarks() throws {
        #expect(try address("smb://[fe80::1%25en0]/x").host == "fe80::1%en0")
        #expect(try address("smb://[fe80::1%25bridge-100_a.b]/x").host == "fe80::1%bridge-100_a.b")
        for bad in ["smb://[fe80::1%25]/x", "smb://[fe80::1%25en%200]/x", "smb://[fe80::1%25é]/x",
                    "smb://[fe80::1%25a/b]/x", "fe80::1%en0\u{301}", "smb://[fe80::1%25%00]/x"] {
            #expect(error(bad) != nil, "\(bad)")
        }
    }

    @Test func onlyOneRootDotIsTaken() throws {
        #expect(try address("smb://nas.example.com./share").host == "nas.example.com")
        #expect(error("smb://pwnfs%2E%2E/x") == .invalidHost)
        #expect(error("smb://pwnfs../x") == .invalidHost)
        #expect(error("smb://./x") == .invalidHost)
    }

    /// Each label is checked as scalars: a combining mark after a "." makes
    /// one Character of the two, which hid an empty label ("a..́b") or one
    /// starting with the mark ("a.́.b") from a check made per Character.
    @Test(arguments: ["smb://a..\u{301}b/share", "smb://a.\u{301}.b/x", "smb://a.\u{301}b/x",
                      "smb://a.%CC%81b/x", "smb://a..b/x", "smb://.a/x", "smb://a.b../x",
                      // Not marks, but each joins the "." into one Character:
                      // a skin tone, a Thai or Lao vowel (SpacingMark), a Prepend scalar.
                      "smb://a.\u{1F3FD}b/x", "smb://a.\u{E33}b/x", "smb://a.\u{EB3}b/x",
                      "smb://a\u{D4E}.b/x"])
    func emptyLabelsAndLabelsStartingWithAMarkAreRefused(typed: String) {
        #expect(error(typed) == .invalidHost)
    }

    @Test func labelsWithAMarkInsideThemAreKept() throws {
        #expect(try address("smb://cafe\u{301}.local/x").host == "cafe\u{301}.local")
        #expect(try address("smb://a.e\u{301}.b./x").host == "a.e\u{301}.b")
    }

    // MARK: Servers with no share

    @Test func onlySMBAndAFPHaveServerOnlyAddresses() throws {
        #expect(try address("smb://nas").isServerOnly)
        #expect(try address("afp://mac").isServerOnly)
        #expect(!(try address("smb://nas/share").isServerOnly))
        for whole in ["ftp://ftp.example.com", "https://dav.example.com", "nfs://host/", "http://dav"] {
            #expect(!(try address(whole).isServerOnly), "\(whole)")
        }
    }

    // MARK: Shares, folders and matching

    @Test func anSMBAddressSplitsIntoShareAndFolder() throws {
        let a = try address("smb://nas/Media/Movies/2026")
        #expect(a.mountTarget.url.absoluteString == "smb://nas/Media")
        #expect(a.folderInShare == "Movies/2026")
        #expect(a.shareName == "Media")
        #expect(try address("smb://nas").mountTarget.path == "")
        #expect(try address("smb://nas").shareName == nil)
    }

    @Test func otherSchemesMountTheWholePath() throws {
        let nfs = try address("nfs://198.51.100.2/srv/nfs/Backups")
        #expect(nfs.mountTarget == nfs && nfs.folderInShare == "" && nfs.shareName == "Backups")
        let dav = try address("https://dav/remote.php/dav")
        #expect(dav.mountTarget == dav && dav.folderInShare == "")
    }

    @Test func theMountTargetKeepsTheUser() throws {
        #expect(try address("smb://alex@nas/share/sub").mountTarget.url.absoluteString == "smb://alex@nas/share")
    }

    @Test func matchingIgnoresTheUserTheDefaultPortAndForSMBCase() throws {
        #expect(try address("smb://alex@NAS/Share").matchKey == address("smb://GUEST@nas:445/share").matchKey)
        #expect(try address("cifs://nas/share").matchKey == address("smb://nas/SHARE").matchKey)
        #expect(try address("smb://nas:1445/share").matchKey != address("smb://nas/share").matchKey)
        #expect(try address("afp://nas/share").matchKey != address("smb://nas/share").matchKey)
        // NFS and WebDAV paths are case-sensitive.
        #expect(try address("nfs://n/Export").matchKey != address("nfs://n/export").matchKey)
        #expect(try address("https://d/Dav").matchKey != address("https://d/dav").matchKey)
    }

    @Test func appendingAFolder() throws {
        let share = try address("smb://nas/share")
        #expect(share.appending(folder: "a/b c").url.absoluteString == "smb://nas/share/a/b%20c")
        #expect(share.appending(folder: "") == share)
    }

    @Test func ftpIsReadOnly() {
        #expect(ServerScheme.ftp.isReadOnly)
        #expect(ServerScheme.allCases.filter(\.isReadOnly) == [.ftp])
        #expect(ServerScheme.allCases.map(\.rawValue) == ["smb", "afp", "nfs", "http", "https", "ftp"])
    }

    // MARK: Mount results

    @Test func mountStatusesAreClassified() {
        #expect(ServerConnectFailure.classify(status: 0) == nil)
        #expect(ServerConnectFailure.classify(status: -128) == .cancelled)
        #expect(ServerConnectFailure.classify(status: 89) == .cancelled)
        #expect(ServerConnectFailure.classify(status: 17) == .alreadyMounted)
        #expect(ServerConnectFailure.classify(status: 80) == .authentication)
        #expect(ServerConnectFailure.classify(status: -6004) == .authentication)
        #expect(ServerConnectFailure.classify(status: -5045) == .passwordExpired)
        // Seen on this Mac: an unknown .invalid host over SMB, AFP; a refused port.
        #expect(ServerConnectFailure.classify(status: 65) == .serverNotFound)
        #expect(ServerConnectFailure.classify(status: 64) == .serverNotFound)
        #expect(ServerConnectFailure.classify(status: 61) == .serverNotResponding)
        #expect(ServerConnectFailure.classify(status: 60) == .serverNotResponding)
        // NFS reports an unknown host as ENOENT.
        #expect(ServerConnectFailure.classify(status: 2) == .shareNotFound)
        #expect(ServerConnectFailure.classify(status: -5998) == .shareNotFound)
        #expect(ServerConnectFailure.classify(status: 45) == .notSupported)
        #expect(ServerConnectFailure.classify(status: 5) == .other(5))
        #expect(ServerConnectFailure.classify(status: -6600) == .other(-6600))
    }

    @Test func mountFailureMessagesNameTheServerNotTheCredentials() throws {
        let a = try address("smb://alex:secret@nas/Media")
        #expect(ServerConnectFailure.cancelled.message(for: a) == nil)
        #expect(ServerConnectFailure.alreadyMounted.message(for: a) == nil)
        let failures: [ServerConnectFailure] = [.authentication, .passwordExpired, .serverNotFound,
                                                .serverNotResponding, .shareNotFound, .notSupported, .other(5)]
        for failure in failures {
            let message = try #require(failure.message(for: a))
            #expect(message.title == "Couldn’t connect to “nas”.")
            #expect(!message.detail.isEmpty)
            #expect(!(message.title + message.detail).contains("secret"))
            #expect(!(message.title + message.detail).contains("alex"))
        }
        #expect(ServerConnectFailure.shareNotFound.message(for: a)?.detail.contains("“Media”") == true)
        let v6 = try address("smb://[fe80::1]/x")
        #expect(ServerConnectFailure.serverNotFound.message(for: v6)?.title == "Couldn’t connect to “[fe80::1]”.")
    }
}
