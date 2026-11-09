// Selway update-key tool. Run it through scripts/update-key.sh.
//
// Selway updates through Sparkle. Sparkle checks every update (the appcast feed, embedded
// release notes, each DMG and delta) against the Ed25519 public key in SUPublicEDKey in
// Selway/Info.plist. This tool holds the private half and hands it to Sparkle's own
// generate_appcast and sign_update over a pipe (`--ed-key-file -`, see release-common.sh), so
// the key is never written to disk for a release. Its keyless commands check feeds against the
// public key alone, build the final feed from the previous one plus generate_appcast's new item
// (merge-appcast), and parse appcasts with every DTD refused and external entities off.
//
// The private key never goes in a git checkout. It lives in the login Keychain (generic
// password, service "Selway Update Signing", account "ed25519") with an access list that
// trusts no application, so every read asks you first; or, when SELWAY_UPDATE_PRIVATE_KEY_FILE is
// set, in that file (base64 32-byte seed, mode 600, owned by you), which must be outside any
// git working tree. The stored form (base64 of the 32-byte seed) is the format Sparkle's
// tools read with --ed-key-file.
import CryptoKit
import Foundation
import Security

let service = "Selway Update Signing"
let account = "ed25519"
let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .resolvingSymlinksInPath().path

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("update-key: \(message)\n".utf8))
    exit(1)
}

func usage() -> Never {
    fail("""
    usage:
      update-key.sh generate             create a key pair (Keychain, or SELWAY_UPDATE_PRIVATE_KEY_FILE) and print the public key
      update-key.sh public-key           print the public key (the SUPublicEDKey value)
      update-key.sh export-private-key   write the private key to standard output for Sparkle's tools
                                         (`... | generate_appcast --ed-key-file -`); only into a pipe,
                                         never to a terminal or a file
      update-key.sh verify-feed APPCAST PUBKEY
                                         check that an existing appcast is signed with PUBKEY (and has no DTD)
      update-key.sh check-appcast-versions APPCAST BUILD VERSION
                                         check that every build in APPCAST is an integer below BUILD and
                                         that VERSION isn't in it yet
      update-key.sh check-archives-covered APPCAST ARCHIVES_DIR EXCLUDE
                                         check that every Selway-*.dmg in ARCHIVES_DIR (but EXCLUDE) is
                                         the download of an item in APPCAST
      update-key.sh merge-appcast GENERATED PREVIOUS BUILD OUT
                                         put generate_appcast's single new item in front of PREVIOUS's
                                         items (kept as they are; PREVIOUS "" = first release) and write
                                         the unsigned feed to OUT
      update-key.sh verify-appcast APPCAST PUBKEY DMG URL BUILD PREVIOUS
                                         check a finished appcast with the public key alone: both feeds'
                                         signatures, the builds, PREVIOUS's items unchanged, and valid
                                         signatures for DMG (item URL) and its deltas (found beside DMG)
      update-key.sh backup PATH          copy the private key to PATH (mode 600, outside any checkout)
      update-key.sh import PATH          store a backed-up key file in the Keychain (no app trusted)
      update-key.sh acl-check            show that a new Keychain item would trust no app (adds nothing)
    """)
}

// MARK: - Paths

struct FileIdentity: Equatable {
    let device: dev_t, inode: ino_t
    init?(_ path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Refuses key paths inside this repository (or any of its worktrees) or any other git
/// checkout, so a key can't be committed by accident. Compares by file identity, so case
/// differences on a case-insensitive volume and symlinks don't get around it.
func requireOutsideRepo(_ path: String) {
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path
    guard FileIdentity(parent) != nil else { fail("\(parent) doesn't exist.") }
    // 1. Any ancestor of the key's folder that is this repository's root.
    if let root = FileIdentity(repoRoot) {
        var dir = URL(fileURLWithPath: parent)
        while true {
            if FileIdentity(dir.path) == root {
                fail("\(path) is inside the repository (\(repoRoot)). Keep the private key outside it.")
            }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { break }
            dir = up
        }
    }
    // 2. Inside any git work tree or git directory (sibling worktrees of this repo included).
    let git = "/usr/bin/git"
    if FileManager.default.isExecutableFile(atPath: git) {
        let tree = run(git, ["-C", parent, "rev-parse", "--is-inside-work-tree", "--is-inside-git-dir"])
        if tree.status == 0, tree.output.contains("true") {
            let common = run(git, ["-C", parent, "rev-parse", "--path-format=absolute", "--git-common-dir"]).output
            fail("\(path) is inside a git checkout (\(common.isEmpty ? parent : common)). Keep the private key outside every checkout.")
        }
    }
}

/// The key file must belong to you and be readable by no one else, like an SSH key.
func requirePrivateKeyFile(_ path: String) {
    var info = stat()
    guard lstat(path, &info) == 0 else { fail("can't read \(path)") }
    guard (info.st_mode & S_IFMT) == S_IFREG else { fail("\(path) isn't a regular file") }
    guard info.st_uid == getuid() else { fail("\(path) isn't owned by you; refusing to use it.") }
    let mode = info.st_mode & 0o777
    guard mode & 0o077 == 0 else {
        fail("\(path) is readable by other users (mode \(String(mode, radix: 8))). Run: chmod 600 '\(path)'")
    }
}

/// Creates the file exclusively with mode 600 from the start, so the key is never
/// readable by others, even briefly, and an existing file is never replaced.
func writeSecretFile(_ seed: Data, to path: String) {
    requireOutsideRepo(path)
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
        fail(errno == EEXIST ? "\(path) already exists; not overwriting it." : "couldn't create \(path) (errno \(errno))")
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
        try handle.write(contentsOf: Data((seed.base64EncodedString() + "\n").utf8))
        try handle.close()
    } catch {
        fail("couldn't write \(path): \(error.localizedDescription)")
    }
}

// MARK: - Key storage

var keyFile: String? {
    guard let path = ProcessInfo.processInfo.environment["SELWAY_UPDATE_PRIVATE_KEY_FILE"], !path.isEmpty else { return nil }
    return path
}

func readSeedFile(_ path: String) -> Data {
    requireOutsideRepo(path)
    requirePrivateKeyFile(path)
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("couldn't read a base64 key from \(path)")
    }
    return data
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    let seed: Data
    if let path = keyFile {
        seed = readSeedFile(path)
    } else {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let decoded = Data(base64Encoded: String(decoding: data, as: UTF8.self)) else {
            fail("no signing key in the Keychain (\(service)); run `scripts/update-key.sh generate` or set SELWAY_UPDATE_PRIVATE_KEY_FILE. (status \(status))")
        }
        seed = decoded
    }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
        fail("the stored private key isn't a 32-byte Ed25519 seed")
    }
    return key
}

/// An access object that trusts no application: macOS asks before any program (including
/// this tool, which runs inside the shared `swift` interpreter) reads the key.
func restrictedAccess() -> SecAccess {
    var access: SecAccess?
    let status = SecAccessCreate(service as CFString, [] as CFArray, &access)
    guard status == errSecSuccess, let access else { fail("couldn't create the Keychain access list (status \(status))") }
    return access
}

/// True when every ACL entry that authorizes decrypting lists no trusted application.
func trustsNoApplication(_ access: SecAccess) -> Bool {
    var list: CFArray?
    guard SecAccessCopyACLList(access, &list) == errSecSuccess, let acls = list as? [SecACL], !acls.isEmpty else { return false }
    var checked = 0
    for acl in acls {
        let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
        guard authorizations.contains(kSecACLAuthorizationDecrypt as String)
                || authorizations.contains(kSecACLAuthorizationAny as String) else { continue }
        var apps: CFArray?
        var description: CFString?
        var prompt = SecKeychainPromptSelector()
        guard SecACLCopyContents(acl, &apps, &description, &prompt) == errSecSuccess else { return false }
        // nil means "any application"; an empty list means "none, always ask".
        guard let apps = apps as? [Any], apps.isEmpty else { return false }
        checked += 1
    }
    return checked > 0
}

func storeInKeychain(_ seed: Data) {
    let access = restrictedAccess()
    guard trustsNoApplication(access) else { fail("refusing to store the key: the access list would trust an application") }
    let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: account,
                                     kSecAttrLabel as String: service,
                                     kSecAttrDescription as String: "Selway update EdDSA private key",
                                     kSecAttrAccess as String: access,
                                     kSecValueData as String: Data(seed.base64EncodedString().utf8)]
    let status = SecItemAdd(attributes as CFDictionary, nil)
    if status == errSecDuplicateItem {
        fail("a key already exists in the Keychain (\(service)). Existing users only accept updates signed with it, so it isn't replaced; delete it in Keychain Access first if you really mean to rotate or re-import.")
    }
    guard status == errSecSuccess else { fail("couldn't add the key to the Keychain (status \(status))") }
}

// MARK: - Reading appcasts safely

func publicKey(fromBase64 text: String) -> Curve25519.Signing.PublicKey {
    guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) else {
        fail("the public key isn't a base64 32-byte Ed25519 key")
    }
    return key
}

func readFile(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
    return data
}

/// A signed appcast split the way Sparkle does it (SPUExtractAppcastContent): the signed
/// content is everything before the last "<!-- sparkle-signatures:" block, which carries the
/// signature and the content length.
struct SignedFeed {
    let content: Data
    let signature: Data?
    let length: Int?
    let isSigned: Bool
}

func splitFeed(_ appcast: Data) -> SignedFeed {
    let prefix = Data("<!-- sparkle-signatures:\n".utf8)
    guard let start = appcast.range(of: prefix, options: .backwards),
          let end = appcast.range(of: Data("-->".utf8), in: start.upperBound..<appcast.endIndex) else {
        return SignedFeed(content: appcast, signature: nil, length: nil, isSigned: false)
    }
    var signature: Data?
    var length: Int?
    for line in String(decoding: appcast.subdata(in: start.upperBound..<end.lowerBound), as: UTF8.self)
        .split(whereSeparator: \.isNewline) {
        let text = String(line)
        if text.hasPrefix("edSignature:") {
            signature = Data(base64Encoded: text.dropFirst("edSignature:".count).trimmingCharacters(in: .whitespaces))
        } else if text.hasPrefix("length:") {
            length = Int(text.dropFirst("length:".count).trimmingCharacters(in: .whitespaces))
        }
    }
    return SignedFeed(content: appcast.subdata(in: appcast.startIndex..<start.lowerBound),
                      signature: signature, length: length, isSigned: true)
}

func checkFeedSignature(_ appcast: Data, publicKey: Curve25519.Signing.PublicKey, name: String) {
    let feed = splitFeed(appcast)
    guard feed.isSigned else {
        fail("\(name) isn't signed (no sparkle-signatures block). Is SURequireSignedFeed set in the app?")
    }
    guard let signature = feed.signature, let length = feed.length else { fail("\(name)'s signature block is incomplete") }
    guard length == feed.content.count else {
        fail("\(name)'s signed length (\(length)) isn't its content length (\(feed.content.count))")
    }
    guard publicKey.isValidSignature(signature, for: feed.content) else {
        fail("\(name)'s feed signature doesn't verify with this public key (edited, or signed with a different key?)")
    }
}

/// Parses an appcast without any DTD processing. Appcasts never need a DTD, so any
/// <!DOCTYPE> or <!ENTITY> is refused outright (no external or internal entities can pull
/// in local files), external entities are never loaded, and only UTF-8 is accepted (another
/// encoding could hide a declaration from the byte check).
func parseAppcast(_ data: Data, name: String) -> XMLDocument {
    guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
        fail("\(name) isn't UTF-8 text")
    }
    if data.starts(with: [0xEF, 0xBB, 0xBF]) == false, let first = text.first, first != "<", !first.isWhitespace {
        fail("\(name) doesn't start like an XML document")
    }
    let lowered = text.lowercased()
    if lowered.contains("<!doctype") || lowered.contains("<!entity") || lowered.contains("<!element")
        || lowered.contains("<!attlist") || lowered.contains("<!notation") {
        fail("\(name) contains a DTD declaration (<!DOCTYPE>, <!ENTITY>, …). Appcasts never need one; refusing it.")
    }
    if let declaration = lowered.range(of: "<?xml"), let close = lowered.range(of: "?>", range: declaration.upperBound..<lowered.endIndex) {
        let header = lowered[declaration.upperBound..<close.lowerBound]
        if header.contains("encoding"), !(header.contains("\"utf-8\"") || header.contains("'utf-8'")) {
            fail("\(name) declares an encoding other than UTF-8")
        }
    }
    guard let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever, .nodePreserveCDATA, .nodePreserveWhitespace]) else {
        fail("\(name) isn't well-formed XML")
    }
    guard document.dtd == nil, document.rootElement()?.name == "rss",
          let channels = try? document.nodes(forXPath: "/rss/channel"), channels.count == 1 else {
        fail("\(name) isn't an RSS appcast with one channel")
    }
    return document
}

func items(_ document: XMLDocument) -> [XMLElement] {
    (try? document.nodes(forXPath: "/rss/channel/item")) as? [XMLElement] ?? []
}

func isSparkle(_ node: XMLNode, _ localName: String) -> Bool {
    (node.localName == localName && node.uri == sparkleNamespace) || node.name == "sparkle:" + localName
}

/// Every sparkle:<localName> value anywhere in `element`, as elements or attributes, however
/// it is written (prefix, quoting, CDATA, character references), so none can hide from a check.
func sparkleValues(_ localName: String, in element: XMLElement) -> [String] {
    var values: [String] = []
    func walk(_ node: XMLElement) {
        if isSparkle(node, localName) { values.append(node.stringValue ?? "") }
        for attribute in node.attributes ?? [] where isSparkle(attribute, localName) {
            values.append(attribute.stringValue ?? "")
        }
        for case let child as XMLElement in node.children ?? [] { walk(child) }
    }
    walk(element)
    return values
}

func isBuildNumber(_ text: String) -> Bool {
    !text.isEmpty && text.count <= 9 && text.allSatisfy { $0.isASCII && $0.isNumber }
}

/// Each item's build numbers: every one must be a plain integer, and each item needs one.
func itemBuilds(_ items: [XMLElement], name: String) -> [[Int]] {
    items.enumerated().map { index, item in
        let values = sparkleValues("version", in: item)
        guard !values.isEmpty else { fail("item \(index + 1) of \(name) has no sparkle:version") }
        return values.map { value in
            guard isBuildNumber(value), let number = Int(value) else {
                fail("item \(index + 1) of \(name) has a build number that isn't a plain integer: '\(value)'")
            }
            return number
        }
    }
}

/// The existing feed may only hold builds below the new one, and not the new marketing version.
func checkAppcastVersions(path: String, build: String, version: String) {
    guard isBuildNumber(build), let newBuild = Int(build), newBuild > 0 else { fail("'\(build)' isn't a positive integer build number") }
    let name = URL(fileURLWithPath: path).lastPathComponent
    let document = parseAppcast(splitFeed(readFile(path)).content, name: name)
    let list = items(document)
    let newest = itemBuilds(list, name: name).joined().max() ?? 0
    guard newest < newBuild else {
        fail("build \(build) isn't newer than build \(newest) in \(path). Raise CURRENT_PROJECT_VERSION in Selway.xcodeproj (every target) above \(newest).")
    }
    for item in list where sparkleValues("shortVersionString", in: item).contains(version) {
        fail("version \(version) is already in \(path). Raise MARKETING_VERSION.")
    }
    print("    Build number: \(build) (newest in the appcast: \(newest))")
}

/// Checks one enclosure's sparkle:edSignature and length against the file it names.
func checkEnclosure(_ enclosure: XMLElement, file: URL, publicKey: Curve25519.Signing.PublicKey) {
    let name = file.lastPathComponent
    guard let base64 = enclosure.attribute(forLocalName: "edSignature", uri: sparkleNamespace)?.stringValue,
          let signature = Data(base64Encoded: base64) else {
        fail("the appcast entry for \(name) has no EdDSA signature (did generate_appcast warn that the key doesn't match SUPublicEDKey?)")
    }
    let data = readFile(file.path)
    guard enclosure.attribute(forName: "length")?.stringValue == String(data.count) else {
        fail("the appcast entry for \(name) gives the wrong length")
    }
    guard publicKey.isValidSignature(signature, for: data) else {
        fail("the appcast signature for \(name) doesn't verify with this public key")
    }
}

func canonical(_ item: XMLElement) -> String {
    item.canonicalXMLStringPreservingComments(true)
}

/// generate_appcast's output (one new item) added in front of the previous feed's items,
/// which are kept exactly as they were. Writes the unsigned result; sign it with sign_update.
///
/// Nothing is ever pruned, so the feed grows by one item per release (about 1 KB plus any
/// embedded release notes). To cap it, keep only the newest N previous items here, relax
/// verify-appcast's "earlier items unchanged" check to "the first N of PREVIOUS's items,
/// unchanged", and either remove the pruned releases' DMGs from the archives folder or relax
/// check-archives-covered, which requires every DMG there to have an item.
func mergeAppcast(generatedPath: String, previousPath: String, build: String, outPath: String) {
    let generated = parseAppcast(splitFeed(readFile(generatedPath)).content, name: "generate_appcast's output")
    let newItems = items(generated)
    guard newItems.count == 1, sparkleValues("version", in: newItems[0]) == [build] else {
        fail("generate_appcast's output should hold exactly one item, for build \(build)")
    }
    var document = generated
    if !previousPath.isEmpty {
        let previousName = URL(fileURLWithPath: previousPath).lastPathComponent
        let previous = parseAppcast(splitFeed(readFile(previousPath)).content, name: previousName)
        guard let channel = (try? previous.nodes(forXPath: "/rss/channel"))?.first as? XMLElement else {
            fail("\(previousName) has no channel")
        }
        guard let item = newItems[0].copy() as? XMLElement else { fail("couldn't copy the new item") }
        item.detach()
        let firstItem = (channel.children ?? []).firstIndex { ($0 as? XMLElement)?.name == "item" }
        channel.insertChild(item, at: firstItem ?? channel.childCount)
        document = previous
    }
    document.characterEncoding = "UTF-8"
    do {
        try document.xmlData(options: [.nodePreserveCDATA, .nodePreserveWhitespace]).write(to: URL(fileURLWithPath: outPath))
    } catch {
        fail("couldn't write \(outPath): \(error.localizedDescription)")
    }
    print("Added build \(build) to \(previousPath.isEmpty ? "a new feed" : "the \(items(document).count - 1) earlier item(s)").")
}

/// The finished feed, checked with the public key alone: its signature; no DTD; every item has
/// integer builds, the new item is the only one with BUILD and all others are older; the
/// earlier items are exactly PREVIOUS's (nothing added, dropped, reordered or edited); and the
/// new DMG and its deltas match their signatures.
func verifyAppcast(path: String, publicKeyText: String, dmg: String, url: String, build: String, previousPath: String) {
    let key = publicKey(fromBase64: publicKeyText)
    let data = readFile(path)
    let name = URL(fileURLWithPath: path).lastPathComponent
    checkFeedSignature(data, publicKey: key, name: name)
    let document = parseAppcast(splitFeed(data).content, name: name)
    guard isBuildNumber(build), let newBuild = Int(build) else { fail("'\(build)' isn't an integer build number") }

    let list = items(document)
    let builds = itemBuilds(list, name: name)
    let matches = list.indices.filter { index in
        list[index].elements(forName: "enclosure").contains { $0.attribute(forName: "url")?.stringValue == url }
    }
    guard matches.count == 1, let newIndex = matches.first,
          let enclosure = list[newIndex].elements(forName: "enclosure").first(where: { $0.attribute(forName: "url")?.stringValue == url }) else {
        fail("\(name) should have exactly one item downloading \(url) (found \(matches.count))")
    }
    guard builds[newIndex] == [newBuild] else {
        fail("the item for \(url) has build \(builds[newIndex]), not \(build)")
    }
    for (index, numbers) in builds.enumerated() where index != newIndex {
        guard numbers.allSatisfy({ $0 < newBuild }) else {
            fail("item \(index + 1) of \(name) has build \(numbers.max() ?? 0), not older than \(build)")
        }
    }
    let earlier = list.enumerated().filter { $0.offset != newIndex }.map { canonical($0.element) }
    if previousPath.isEmpty {
        guard earlier.isEmpty else { fail("\(name) has \(earlier.count) item(s) besides the new one, but there was no previous feed") }
    } else {
        let previousData = readFile(previousPath)
        let previousName = URL(fileURLWithPath: previousPath).lastPathComponent
        checkFeedSignature(previousData, publicKey: key, name: previousName)
        let previous = parseAppcast(splitFeed(previousData).content, name: previousName)
        guard earlier == items(previous).map(canonical) else {
            fail("the earlier items in \(name) aren't exactly those of the previous feed (added, dropped, reordered or edited)")
        }
    }

    let dmgURL = URL(fileURLWithPath: dmg)
    guard dmgURL.lastPathComponent == URL(string: url)?.lastPathComponent else {
        fail("\(url) doesn't name \(dmgURL.lastPathComponent)")
    }
    checkEnclosure(enclosure, file: dmgURL, publicKey: key)

    // Deltas from older builds: published from the same release, signed with the same key.
    let folder = dmgURL.deletingLastPathComponent()
    let releaseFolder = url.prefix(upTo: url.lastIndex(of: "/").map { url.index(after: $0) } ?? url.endIndex)
    var deltas = 0
    for list in list[newIndex].elements(forLocalName: "deltas", uri: sparkleNamespace) {
        for delta in list.elements(forName: "enclosure") {
            guard let deltaURL = delta.attribute(forName: "url")?.stringValue,
                  deltaURL.hasPrefix(releaseFolder), let file = URL(string: deltaURL)?.lastPathComponent,
                  !file.isEmpty, !file.contains("/") else {
                fail("a delta of the item for \(url) isn't published beside it")
            }
            checkEnclosure(delta, file: folder.appendingPathComponent(file), publicKey: key)
            deltas += 1
        }
    }
    print("OK: \(name) is signed with this key; build \(build) (\(dmgURL.lastPathComponent)) and \(deltas) delta(s) verify; \(earlier.count) earlier item(s) unchanged")
}

/// Every earlier release DMG kept in the archives folder (Selway-*.dmg at its top level, except
/// `exclude`, the release being made) must be the download of an item in the feed: otherwise
/// the feed is older than what was released, e.g. an old signed feed replayed after the
/// archives copy went missing, and extending it would drop published releases.
func checkArchivesCovered(path: String, archives: String, exclude: String) {
    let name = URL(fileURLWithPath: path).lastPathComponent
    let document = parseAppcast(splitFeed(readFile(path)).content, name: name)
    let listed = Set(enclosureFiles(items(document)))
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: archives)) ?? []
    let dmgs = entries.filter { $0.hasPrefix("Selway-") && $0.hasSuffix(".dmg") && $0 != exclude }.sorted()
    let missing = dmgs.filter { !listed.contains($0) }
    guard missing.isEmpty else {
        fail("\(name) has no item for \(missing.joined(separator: ", ")) in \(archives): it is older than what was released")
    }
    print("OK: \(name) lists all \(dmgs.count) earlier release(s) in the archives folder")
}

/// The file names of the full downloads (not deltas) of `items`.
func enclosureFiles(_ items: [XMLElement]) -> [String] {
    items.flatMap { item in
        item.elements(forName: "enclosure").compactMap { enclosure in
            enclosure.attribute(forName: "url")?.stringValue.flatMap { URL(string: $0)?.lastPathComponent }
        }
    }
}

/// An existing feed a release builds on: signed with this key, and no DTD.
func verifyFeed(path: String, publicKeyText: String) {
    let data = readFile(path)
    let name = URL(fileURLWithPath: path).lastPathComponent
    checkFeedSignature(data, publicKey: publicKey(fromBase64: publicKeyText), name: name)
    let document = parseAppcast(splitFeed(data).content, name: name)
    _ = itemBuilds(items(document), name: name)
    print("OK: \(path) is signed with SUPublicEDKey (\(items(document).count) item(s))")
}

/// Standard output must be a pipe (another program reading it), so the key isn't shown in a
/// terminal or saved to a file by a stray redirect.
func requirePipeForStandardOutput() {
    guard isatty(STDOUT_FILENO) == 0 else {
        fail("refusing to print the private key to a terminal. Pipe it into Sparkle's tool: update-key.sh export-private-key | generate_appcast --ed-key-file - …")
    }
    var info = stat()
    guard fstat(STDOUT_FILENO, &info) == 0, (info.st_mode & S_IFMT) == S_IFIFO || (info.st_mode & S_IFMT) == S_IFSOCK else {
        fail("refusing to write the private key anywhere but into a pipe (standard output is a file or device). Use `backup` for a deliberate copy.")
    }
}

// MARK: - Commands

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "generate":
    guard args.count == 1 else { usage() }
    let key = Curve25519.Signing.PrivateKey()
    if let path = keyFile {
        writeSecretFile(key.rawRepresentation, to: path)
        print("Private key written to \(path) (mode 600). Back it up somewhere safe.")
    } else {
        storeInKeychain(key.rawRepresentation)
        print("Private key stored in the login Keychain as \"\(service)\". macOS asks before any app reads it.")
        print("Back it up: scripts/update-key.sh backup /path/outside/any/checkout (then store that file offline).")
    }
    print("")
    print("Public key — set this as SUPublicEDKey in Selway/Info.plist:")
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "public-key":
    guard args.count == 1 else { usage() }
    print(loadPrivateKey().publicKey.rawRepresentation.base64EncodedString())

case "export-private-key":
    guard args.count == 1 else { usage() }
    requirePipeForStandardOutput()
    let seed = loadPrivateKey().rawRepresentation.base64EncodedString()
    FileHandle.standardOutput.write(Data((seed + "\n").utf8))

case "verify-feed":
    guard args.count == 3 else { usage() }
    verifyFeed(path: args[1], publicKeyText: args[2])

case "check-appcast-versions":
    guard args.count == 4 else { usage() }
    checkAppcastVersions(path: args[1], build: args[2], version: args[3])

case "check-archives-covered":
    guard args.count == 4 else { usage() }
    checkArchivesCovered(path: args[1], archives: args[2], exclude: args[3])

case "merge-appcast":
    guard args.count == 5 else { usage() }
    mergeAppcast(generatedPath: args[1], previousPath: args[2], build: args[3], outPath: args[4])

case "verify-appcast":
    guard args.count == 7 else { usage() }
    verifyAppcast(path: args[1], publicKeyText: args[2], dmg: args[3], url: args[4], build: args[5], previousPath: args[6])

case "backup":
    guard args.count == 2 else { usage() }
    writeSecretFile(loadPrivateKey().rawRepresentation, to: args[1])
    print("Private key copied to \(args[1]) (mode 600). Keep it offline; anyone with it can ship updates.")

case "import":
    guard args.count == 2 else { usage() }
    let seed = readSeedFile(args[1])
    guard (try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)) != nil else { fail("\(args[1]) isn't a 32-byte Ed25519 seed") }
    storeInKeychain(seed)
    print("Imported into the login Keychain as \"\(service)\"; macOS asks before any app reads it.")

case "acl-check":
    // Builds the access list `generate` would use and inspects it. Nothing is added to any keychain.
    guard trustsNoApplication(restrictedAccess()) else { fail("the access list would trust an application") }
    print("OK: a new key item would trust no application (every read asks first).")

default:
    usage()
}
