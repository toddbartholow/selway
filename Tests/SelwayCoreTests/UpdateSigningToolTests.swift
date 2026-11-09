import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import SelwayCore

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

#if os(macOS) && canImport(CryptoKit)
/// scripts/update-key.sh with throwaway key files (never the Keychain). Each tool run compiles
/// the script, so these only run when asked: `SELWAY_RUN_TOOL_TESTS=1 ./scripts/test.sh
/// --filter UpdateSigningTool` (or `./scripts/test.sh --app`). The Sparkle round trips also
/// need Sparkle's tools (SELWAY_SPARKLE_BIN, which `./scripts/test.sh --app` sets) and mount
/// fixture disk images read-only (hidden, nothing opened).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SELWAY_RUN_TOOL_TESTS"] == "1"))
final class UpdateSigningToolTests {

    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("selway-tool-\(UUID().uuidString)", isDirectory: true)
    private let tool = repoRoot.appendingPathComponent("scripts/update-key.sh")

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func runTool(_ arguments: [String], keyFile: URL, input: Data? = nil) -> TestTool.Result {
        var env = ProcessInfo.processInfo.environment
        env["SELWAY_UPDATE_PRIVATE_KEY_FILE"] = keyFile.path
        return TestTool.run(tool.path, arguments, environment: env, input: input)
    }

    private func writeKey(_ key: Curve25519.Signing.PrivateKey, mode: Int) throws -> URL {
        let url = root.appendingPathComponent("key-\(mode)-\(UUID().uuidString)")
        try Data((key.rawRepresentation.base64EncodedString() + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    private static var sparkleBin: URL? {
        guard let path = ProcessInfo.processInfo.environment["SELWAY_SPARKLE_BIN"], !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path + "/sign_update") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    @Test func generateWritesAPrivateKeyFileAndPrintsItsPublicKey() throws {
        let keyFile = root.appendingPathComponent("generated.key")
        let generate = runTool(["generate"], keyFile: keyFile)
        #expect(generate.status == 0, "\(generate.text)")
        let mode = try FileManager.default.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let seed = try #require(Data(base64Encoded: try String(contentsOf: keyFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        #expect(generate.output.contains("SUPublicEDKey"))
        #expect(generate.output.contains(publicKey))
        #expect(runTool(["public-key"], keyFile: keyFile).output.trimmingCharacters(in: .whitespacesAndNewlines) == publicKey)
        // Never replaces an existing key.
        #expect(runTool(["generate"], keyFile: keyFile).status != 0)
        #expect(try String(contentsOf: keyFile, encoding: .utf8).contains(seed.base64EncodedString()))
    }

    /// export-private-key writes into a pipe (for `| generate_appcast --ed-key-file -`) and
    /// refuses a file, so a stray `>` can't leave the key on disk. (A terminal is refused the
    /// same way; that needs a pty, so it isn't run here.)
    @Test func exportWritesTheKeyOnlyIntoAPipe() throws {
        let key = Curve25519.Signing.PrivateKey()
        let keyFile = try writeKey(key, mode: 0o600)
        let piped = runTool(["export-private-key"], keyFile: keyFile)
        #expect(piped.status == 0, "\(piped.text)")
        #expect(piped.output == key.rawRepresentation.base64EncodedString() + "\n")

        let file = root.appendingPathComponent("exported.txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        let p = Process()
        p.executableURL = tool
        p.arguments = ["export-private-key"]
        var env = ProcessInfo.processInfo.environment
        env["SELWAY_UPDATE_PRIVATE_KEY_FILE"] = keyFile.path
        p.environment = env
        p.standardOutput = handle
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        try handle.close()
        #expect(p.terminationStatus != 0)
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test func refusesAKeyFileOthersCanRead() throws {
        let keyFile = try writeKey(Curve25519.Signing.PrivateKey(), mode: 0o644)
        for command in ["public-key", "export-private-key"] {
            let result = runTool([command], keyFile: keyFile)
            #expect(result.status != 0)
            #expect(result.text.contains("readable by other users"), "\(result.text)")
            #expect(result.output.isEmpty)
        }
    }

    @Test func refusesAKeyFileInsideTheRepositoryWhateverTheCase() throws {
        let path = repoRoot.path.uppercased() + "/NOT-A-KEY-\(UUID().uuidString)"
        let result = runTool(["generate"], keyFile: URL(fileURLWithPath: path))
        #expect(result.status != 0)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // MARK: Sparkle compatibility

    /// The stored key format is what Sparkle's sign_update reads with `--ed-key-file -`, and its
    /// signatures verify with the public key update-key.sh prints (the SUPublicEDKey value).
    @Test(.enabled(if: sparkleBin != nil))
    func sparkleSignsWithTheExportedKey() throws {
        let bin = try #require(Self.sparkleBin)
        let key = Curve25519.Signing.PrivateKey()
        let keyFile = try writeKey(key, mode: 0o600)
        let file = root.appendingPathComponent("payload.bin")
        try Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: file)

        let exported = runTool(["export-private-key"], keyFile: keyFile)
        let sign = TestTool.run(bin.appendingPathComponent("sign_update").path,
                                ["--ed-key-file", "-", "-p", file.path], input: Data(exported.output.utf8))
        #expect(sign.status == 0, "\(sign.text)")
        let signature = try #require(Data(base64Encoded: sign.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        let publicKey = runTool(["public-key"], keyFile: keyFile).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: try #require(Data(base64Encoded: publicKey)))
        #expect(verifier.isValidSignature(signature, for: try Data(contentsOf: file)))
    }

    /// A small ad-hoc–signed app (`/usr/bin/true` as its binary) that Sparkle can read. Its
    /// name and bundle ID are never the real app's, and nothing ever launches it.
    private func makeFixtureApp(at url: URL, version: String, build: String, publicKey: String) throws {
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "studio.irq.selway.tests.update-fixture", "CFBundleName": "SelwayUpdateFixture",
            "CFBundleExecutable": "SelwayUpdateFixture", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version, "CFBundleVersion": build, "LSMinimumSystemVersion": "14.0",
            "SUFeedURL": "https://toddbartholow.github.io/selway/appcast.xml",
            "SUPublicEDKey": publicKey, "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("SelwayUpdateFixture").path)
        let sign = TestTool.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
        try #require(sign.status == 0, "\(sign.text)")
    }

    private func makeDMG(version: String, build: String, publicKey: String, in folder: URL) throws -> URL {
        let src = root.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        try makeFixtureApp(at: src.appendingPathComponent("SelwayUpdateFixture.app"), version: version, build: build,
                           publicKey: publicKey)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dmg = folder.appendingPathComponent("Selway-\(version).dmg")
        let r = TestTool.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", src.path, "-format", "UDZO",
                                                  "-volname", "SelwayFixture", dmg.path])
        try #require(r.status == 0, "\(r.text)")
        return dmg
    }

    /// Runs `selway_sparkle_appcast` the way release.sh does: the existing appcast is the
    /// committed feed `feed` (SELWAY_APPCAST, never the repository's own docs/appcast.xml), and
    /// the verified new feed is written back to it. generate_appcast's cache goes to a temporary
    /// home (CFFIXED_USER_HOME), never the real one. The library is this checkout's, so the
    /// comparison with origin/main is switched off: the tests never fetch the real remote
    /// (committedFeedMustMatchOriginMain covers that check).
    private func runAppcastStep(dmg: URL, app: URL, archives: URL, out: URL, bin: URL, keyFile: URL,
                                notes: URL? = nil, feed: URL) throws -> TestTool.Result {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env["SELWAY_UPDATE_PRIVATE_KEY_FILE"] = keyFile.path
        env["SELWAY_RELEASE_NOTES"] = notes?.path ?? ""
        env["SELWAY_APPCAST"] = feed.path
        env["SELWAY_SKIP_FEED_ORIGIN_CHECK"] = "1"
        env["CFFIXED_USER_HOME"] = root.appendingPathComponent("home").path
        return TestTool.run("/bin/bash", ["-c", #"""
            set -euo pipefail
            source "$1/scripts/lib/release-common.sh"
            existing=$(selway_existing_appcast "$4")
            selway_sparkle_appcast "$2" "$3" "$4" "$5" "$6" "$existing"
            selway_write_feed "$6/appcast.xml"
            """#, "test", repoRoot.path, dmg.path, app.path, archives.path, bin.path, out.path], environment: env)
    }

    /// Every file under `folder` with its contents, to show a failed run changed nothing.
    private func snapshot(_ folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let names = FileManager.default.subpaths(atPath: folder.path) ?? []
        for name in names {
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                result[name] = try Data(contentsOf: url)
            }
        }
        return result
    }

    /// release-common.sh's selway_sparkle_appcast end to end with a throwaway key: Sparkle's
    /// generate_appcast gets the key through the pipe and signs the DMG and a delta, the older
    /// release is kept exactly as published (its own download URL included), sign_update signs
    /// the feed, and update-key.sh verify-appcast accepts the result with the public key alone.
    /// The verified feed also replaces the committed feed (docs/appcast.xml in a release).
    /// Then the refusals: same build or version, a tampered or unsigned existing feed, a
    /// committed feed that differs from the archives copy or is missing, and a wrong key, each
    /// leaving the archives folder and the committed feed byte-for-byte as they were.
    @Test(.enabled(if: sparkleBin != nil))
    func generatedAppcastIsSignedAndVerifies() throws {
        let bin = try #require(Self.sparkleBin)
        let key = Curve25519.Signing.PrivateKey()
        let keyFile = try writeKey(key, mode: 0o600)
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let archives = root.appendingPathComponent("archives", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        let notes = root.appendingPathComponent("notes-1.1.md")
        try Data("## Selway 1.1\n\n- Fixture release notes.\n".utf8).write(to: notes)
        // The committed feed, as docs/appcast.xml is in a checkout; absent before the first release.
        let committed = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: committed, withIntermediateDirectories: true)
        let committedFeed = committed.appendingPathComponent("appcast.xml")

        func release(_ version: String, build: String, notes: URL? = nil, keyFile: URL? = nil,
                     appcast: URL? = nil) throws -> TestTool.Result {
            let dmgFolder = root.appendingPathComponent("dmg-\(build)-\(UUID().uuidString)", isDirectory: true)
            let dmg = try makeDMG(version: version, build: build, publicKey: publicKey, in: dmgFolder)
            let app = root.appendingPathComponent("app-\(UUID().uuidString)/SelwayUpdateFixture.app")
            try makeFixtureApp(at: app, version: version, build: build, publicKey: publicKey)
            return try runAppcastStep(dmg: dmg, app: app, archives: archives, out: out, bin: bin,
                                      keyFile: keyFile ?? self.writeKey(key, mode: 0o600), notes: notes,
                                      feed: appcast ?? committedFeed)
        }
        _ = keyFile

        #expect(!FileManager.default.fileExists(atPath: committedFeed.path))
        let first = try release("1.0", build: "1")
        #expect(first.status == 0, "\(first.text)")
        let firstFeed = try String(contentsOf: out.appendingPathComponent("appcast.xml"), encoding: .utf8)
        #expect(try String(contentsOf: committedFeed, encoding: .utf8) == firstFeed)
        let second = try release("1.1", build: "2", notes: notes)
        #expect(second.status == 0, "\(second.text)")
        // generate_appcast's cache went to the temporary home.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("home/Library/Caches/Sparkle_generate_appcast").path))

        let appcast = try String(contentsOf: out.appendingPathComponent("appcast.xml"), encoding: .utf8)
        #expect(appcast.contains("<!-- sparkle-signatures:"))
        #expect(appcast.contains("https://github.com/toddbartholow/selway/releases/download/v1.1/Selway-1.1.dmg"))
        #expect(appcast.contains("https://github.com/toddbartholow/selway/releases/download/v1.0/Selway-1.0.dmg"))
        #expect(!appcast.contains("v1.1/Selway-1.0.dmg"), "the older release must keep its own URL")
        #expect(appcast.contains("Fixture release notes."))
        #expect(try String(contentsOf: archives.appendingPathComponent("appcast.xml"), encoding: .utf8) == appcast)
        #expect(try String(contentsOf: committedFeed, encoding: .utf8) == appcast)
        #expect(try FileManager.default.contentsOfDirectory(atPath: committed.path) == ["appcast.xml"])
        let delta = out.appendingPathComponent("SelwayUpdateFixture2-1.delta")
        #expect(FileManager.default.fileExists(atPath: delta.path))
        #expect(appcast.contains("releases/download/v1.1/SelwayUpdateFixture2-1.delta"))
        // The 1.0 item is the published one, unchanged.
        let oldItem = try #require(firstFeed.range(of: "<item>").flatMap { start in
            firstFeed.range(of: "</item>", range: start.upperBound..<firstFeed.endIndex).map { firstFeed[start.lowerBound..<$0.upperBound] }
        })
        #expect(appcast.contains(oldItem))

        // The verifier accepts what Sparkle produced, and nothing else.
        let previous = root.appendingPathComponent("previous.xml")
        try Data(firstFeed.utf8).write(to: previous)
        let dmg = archives.appendingPathComponent("Selway-1.1.dmg")
        let url = "https://github.com/toddbartholow/selway/releases/download/v1.1/Selway-1.1.dmg"
        let feed = out.appendingPathComponent("appcast.xml").path
        let verify = runTool(["verify-appcast", feed, publicKey, dmg.path, url, "2", previous.path], keyFile: keyFile)
        #expect(verify.status == 0, "\(verify.text)")
        #expect(verify.output.contains("1 delta(s)") && verify.output.contains("1 earlier item(s) unchanged"), "\(verify.output)")
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(runTool(["verify-appcast", feed, otherKey, dmg.path, url, "2", previous.path], keyFile: keyFile).status != 0)
        #expect(runTool(["verify-appcast", feed, publicKey, dmg.path, url, "3", previous.path], keyFile: keyFile).status != 0)
        // Without the previous feed, the 1.0 item is unexpected.
        #expect(runTool(["verify-appcast", feed, publicKey, dmg.path, url, "2", ""], keyFile: keyFile).status != 0)
        // The previous feed has to carry its own valid signature too.
        let unsignedPrevious = root.appendingPathComponent("unsigned-previous.xml")
        try Data((firstFeed.components(separatedBy: "<!-- sparkle-signatures:").first ?? firstFeed).utf8).write(to: unsignedPrevious)
        let previousUnsigned = runTool(["verify-appcast", feed, publicKey, dmg.path, url, "2", unsignedPrevious.path], keyFile: keyFile)
        #expect(previousUnsigned.status != 0 && previousUnsigned.text.contains("isn't signed"), "\(previousUnsigned.text)")
        let edited = root.appendingPathComponent("edited.xml")
        // Same length, so the signature check (not the length check) has to catch it.
        try Data(appcast.replacingOccurrences(of: "Fixture release notes.", with: "Fixture release notez.").utf8)
            .write(to: edited)
        let tampered = runTool(["verify-appcast", edited.path, publicKey, dmg.path, url, "2", previous.path], keyFile: keyFile)
        #expect(tampered.status != 0 && tampered.text.contains("feed signature"), "\(tampered.text)")
        let unsigned = root.appendingPathComponent("unsigned.xml")
        let body = appcast.components(separatedBy: "<!-- sparkle-signatures:").first ?? appcast
        try Data(body.utf8).write(to: unsigned)
        #expect(runTool(["verify-appcast", unsigned.path, publicKey, dmg.path, url, "2", previous.path], keyFile: keyFile).status != 0)

        // A validly signed feed with an extra (older) item slipped in, or an earlier item
        // edited, isn't "the previous feed plus one item".
        let injected = root.appendingPathComponent("injected.xml")
        let extra = "<item><title>0.9</title><sparkle:version>0</sparkle:version><enclosure url=\"https://evil.invalid/x.dmg\" length=\"1\" type=\"application/octet-stream\"/></item>\n        "
        try Data(signFeed(body.replacingOccurrences(of: "<item>", with: extra + "<item>", options: [], range: body.range(of: "<item>")), key: key).utf8)
            .write(to: injected)
        let injectedResult = runTool(["verify-appcast", injected.path, publicKey, dmg.path, url, "2", previous.path], keyFile: keyFile)
        #expect(injectedResult.status != 0 && injectedResult.text.contains("aren't exactly"), "\(injectedResult.text)")
        let editedOld = root.appendingPathComponent("edited-old.xml")
        try Data(signFeed(body.replacingOccurrences(of: "v1.0/Selway-1.0.dmg", with: "v1.0/Selway-1.0x.dmg"), key: key).utf8)
            .write(to: editedOld)
        #expect(runTool(["verify-appcast", editedOld.path, publicKey, dmg.path, url, "2", previous.path], keyFile: keyFile).text.contains("aren't exactly"))

        // Refusals, each leaving the archives folder exactly as it was.
        let before = try snapshot(archives)
        let again = try release("1.1.1", build: "2")
        #expect(again.status != 0)
        #expect(again.text.contains("isn't newer than build 2"), "\(again.text)")
        let sameVersion = try release("1.1", build: "3")
        #expect(sameVersion.status != 0)
        #expect(sameVersion.text.contains("already in"), "\(sameVersion.text)")
        let wrongKey = try release("1.2", build: "3", keyFile: try writeKey(Curve25519.Signing.PrivateKey(), mode: 0o600))
        #expect(wrongKey.status != 0)
        #expect(wrongKey.text.contains("nothing changed"), "\(wrongKey.text)")
        let differentPublished = root.appendingPathComponent("published.xml")
        try Data(firstFeed.utf8).write(to: differentPublished)
        let stale = try release("1.2", build: "3", appcast: differentPublished)
        #expect(stale.status != 0 && stale.text.contains("differs from"), "\(stale.text)")
        #expect(try snapshot(archives) == before)
        #expect(try String(contentsOf: out.appendingPathComponent("appcast.xml"), encoding: .utf8) == appcast)
        #expect(try String(contentsOf: committedFeed, encoding: .utf8) == appcast)
        #expect(try String(contentsOf: differentPublished, encoding: .utf8) == firstFeed)

        // A committed feed missing while the archives hold the last release's feed means the
        // checkout is behind (or that feed was never committed).
        let missingFeed = committed.appendingPathComponent("missing-appcast.xml")
        let uncommitted = try release("1.2", build: "3", appcast: missingFeed)
        #expect(uncommitted.status != 0 && uncommitted.text.contains("doesn't. Commit that feed"), "\(uncommitted.text)")
        #expect(!FileManager.default.fileExists(atPath: missingFeed.path))
        #expect(try snapshot(archives) == before)

        // A tampered or unsigned existing feed is never extended and re-signed (committed and
        // archives copies alike, so the check that they match doesn't stop it first).
        let archived = archives.appendingPathComponent("appcast.xml")
        let tamperedFeed = Data(appcast.replacingOccurrences(of: "Fixture release notes.", with: "Fixture release notez.").utf8)
        try tamperedFeed.write(to: archived)
        try tamperedFeed.write(to: committedFeed)
        let tamperedBefore = try snapshot(archives)
        let tamperedExisting = try release("1.2", build: "3")
        #expect(tamperedExisting.status != 0 && tamperedExisting.text.contains("isn't signed with SUPublicEDKey"), "\(tamperedExisting.text)")
        #expect(try Data(contentsOf: committedFeed) == tamperedFeed)
        #expect(try snapshot(archives) == tamperedBefore)
        try Data(body.utf8).write(to: archived)
        try Data(body.utf8).write(to: committedFeed)
        let unsignedBefore = try snapshot(archives)
        let unsignedExisting = try release("1.2", build: "3")
        #expect(unsignedExisting.status != 0 && unsignedExisting.text.contains("isn't signed"), "\(unsignedExisting.text)")
        #expect(try Data(contentsOf: committedFeed) == Data(body.utf8))
        #expect(try snapshot(archives) == unsignedBefore)

        // Replay: an old, validly signed feed (it lists 1.0 but not 1.1) offered once the
        // archives copy is gone would drop a published release; so would having no feed at all.
        try FileManager.default.removeItem(at: archived)
        try FileManager.default.removeItem(at: committedFeed)
        let replayBefore = try snapshot(archives)
        let replay = try release("1.2", build: "3", appcast: differentPublished)
        #expect(replay.status != 0 && replay.text.contains("doesn't list every release"), "\(replay.text)")
        let noFeed = try release("1.2", build: "3")
        #expect(noFeed.status != 0 && noFeed.text.contains("holds earlier releases"), "\(noFeed.text)")
        #expect(try snapshot(archives) == replayBefore)
        #expect(!FileManager.default.fileExists(atPath: committedFeed.path))

        // With the published feed back in both places, the next release goes through and
        // extends the committed feed.
        try Data(appcast.utf8).write(to: archived)
        try Data(appcast.utf8).write(to: committedFeed)
        let third = try release("1.2", build: "3")
        #expect(third.status == 0, "\(third.text)")
        let thirdFeed = try String(contentsOf: committedFeed, encoding: .utf8)
        #expect(thirdFeed == (try String(contentsOf: out.appendingPathComponent("appcast.xml"), encoding: .utf8)))
        #expect(thirdFeed.contains("releases/download/v1.2/Selway-1.2.dmg") && thirdFeed.contains(oldItem))
        // No temporary .appcast.* file left next to the committed feed.
        #expect(try FileManager.default.contentsOfDirectory(atPath: committed.path) == ["appcast.xml"])
    }

    // MARK: Appcast parsing (keyless commands)

    /// A feed with a DTD is refused by every command that reads one, even when it's validly
    /// signed: an entity could otherwise pull a local file into a URL that then gets signed.
    @Test func appcastsWithADTDAreRefused() throws {
        let key = Curve25519.Signing.PrivateKey()
        let keyFile = try writeKey(key, mode: 0o600)
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let secret = root.appendingPathComponent("secret.txt")
        try Data("TOPSECRET".utf8).write(to: secret)
        // A clean one-item feed, so merging fails only because of the DTD in PREVIOUS.
        let generated = root.appendingPathComponent("generated.xml")
        try Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Selway</title>
            <item><title>1.1</title><sparkle:version>2</sparkle:version></item></channel></rss>
            """.utf8).write(to: generated)
        #expect(runTool(["merge-appcast", generated.path, "", "2", root.appendingPathComponent("ok.xml").path],
                        keyFile: keyFile).status == 0)
        let variants = [
            "<!DOCTYPE rss [<!ENTITY x SYSTEM \"file://\(secret.path)\">]>",
            "<!doctype rss SYSTEM \"file://\(root.path)/evil.dtd\">",
            "<!DOCTYPE rss [<!ENTITY x \"inline\">]>",
        ]
        for (index, doctype) in variants.enumerated() {
            let body = """
                <?xml version="1.0" encoding="utf-8"?>
                \(doctype)
                <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Selway</title>
                <item><title>1.0</title><sparkle:version>1</sparkle:version><sparkle:shortVersionString>1.0</sparkle:shortVersionString>
                <enclosure url="https://example.invalid/&x;/Selway-1.0.dmg" length="1" type="application/octet-stream"/></item>
                </channel></rss>

                """
            let feed = root.appendingPathComponent("dtd-\(index).xml")
            try Data(signFeed(body, key: key).utf8).write(to: feed)
            let dmg = root.appendingPathComponent("Selway-1.0.dmg")
            try Data("x".utf8).write(to: dmg)
            // Every reading command for the first variant; the others through verify-feed
            // (each tool run compiles the script, so this keeps the test short).
            let commands: [[String]] = [["verify-feed", feed.path, publicKey],
                              ["check-appcast-versions", feed.path, "2", "1.1"],
                              ["merge-appcast", feed.path, "", "1", root.appendingPathComponent("merged.xml").path],
                              ["merge-appcast", generated.path, feed.path, "2", root.appendingPathComponent("merged.xml").path],
                              ["verify-appcast", feed.path, publicKey, dmg.path, "https://example.invalid/Selway-1.0.dmg", "1", ""]]
            for arguments in index == 0 ? commands : [] {
                let result = runTool(arguments, keyFile: keyFile)
                #expect(result.status != 0, "\(arguments[0]) accepted \(doctype)")
                #expect(!result.text.contains("TOPSECRET"))
            }
            let viaFeed = runTool(["verify-feed", feed.path, publicKey], keyFile: keyFile)
            #expect(viaFeed.status != 0 && viaFeed.text.contains("DTD") && !viaFeed.text.contains("TOPSECRET"), "\(viaFeed.text)")
        }
        // UTF-16 can't be used to hide a DOCTYPE from the check.
        let utf16 = root.appendingPathComponent("utf16.xml")
        let text = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE rss [<!ENTITY x SYSTEM \"file://\(secret.path)\">]><rss><channel/></rss>"
        try #require(text.data(using: .utf16)).write(to: utf16)
        #expect(runTool(["check-appcast-versions", utf16.path, "2", "1.1"], keyFile: keyFile).status != 0)
    }

    /// Build numbers are read as XML, so quoting, CDATA, spacing or character references can't
    /// hide a newer (or non-integer) build from the check. (The pen-test variants.)
    @Test(arguments: [
        #"<sparkle:version><![CDATA[999]]></sparkle:version>"#,
        #"<enclosure url='https://evil.invalid/a.dmg' length='1' sparkle:version='999'/>"#,
        #"<sparkle:version >999</sparkle:version >"#,
        #"<sparkle:version>&#57;99</sparkle:version>"#,
        #"<s:version xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle">999</s:version>"#,
    ])
    func hiddenNewerBuildsAreFound(evil: String) throws {
        let keyFile = try writeKey(Curve25519.Signing.PrivateKey(), mode: 0o600)
        let feed = root.appendingPathComponent("feed-\(UUID().uuidString).xml")
        try Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Selway</title>
            <item><title>1.0</title><sparkle:version>20</sparkle:version><sparkle:shortVersionString>1.0</sparkle:shortVersionString></item>
            <item><title>evil</title>\(evil)</item>
            </channel></rss>
            """.utf8).write(to: feed)
        let result = runTool(["check-appcast-versions", feed.path, "21", "1.1"], keyFile: keyFile)
        #expect(result.status != 0)
        #expect(result.text.contains("isn't newer than build 999"), "\(result.text)")
    }

    @Test func buildNumbersInTheAppcastMustBeIntegersBelowTheNewOne() throws {
        let keyFile = try writeKey(Curve25519.Signing.PrivateKey(), mode: 0o600)
        func feed(_ items: String) throws -> URL {
            let url = root.appendingPathComponent("feed-\(UUID().uuidString).xml")
            try Data("""
                <?xml version="1.0" encoding="utf-8"?>
                <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Selway</title>\(items)</channel></rss>
                """.utf8).write(to: url)
            return url
        }
        let good = try feed("""
            <item><sparkle:version>9</sparkle:version><sparkle:shortVersionString>1.2</sparkle:shortVersionString></item>
            <item><enclosure url="https://example.invalid/b.dmg" sparkle:version="12" length="1"/></item>
            """)
        let ok = runTool(["check-appcast-versions", good.path, "13", "1.3"], keyFile: keyFile)
        #expect(ok.status == 0, "\(ok.text)")
        #expect(runTool(["check-appcast-versions", good.path, "12", "1.3"], keyFile: keyFile).text.contains("isn't newer than build 12"))
        #expect(runTool(["check-appcast-versions", good.path, "13", "1.2"], keyFile: keyFile).text.contains("already in"))
        for bad in ["<item><sparkle:version>1.2</sparkle:version></item>", "<item><sparkle:version> 3</sparkle:version></item>",
                    "<item><title>no build</title></item>"] {
            let result = runTool(["check-appcast-versions", try feed(bad).path, "99", "9.0"], keyFile: keyFile)
            #expect(result.status != 0, "accepted \(bad)")
        }
    }
}

/// An appcast signed the way Sparkle's sign_update does it (content, then the signature block).
private func signFeed(_ content: String, key: Curve25519.Signing.PrivateKey) -> String {
    let data = Data(content.utf8)
    let signature = (try? key.signature(for: data))?.base64EncodedString() ?? ""
    return content + "<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(data.count)\n-->\n"
}
#endif

#if os(macOS)
/// release-common.sh with stand-ins for update-key.sh, generate_appcast and sign_update (no key,
/// no Keychain, no disk image).
private struct StubbedReleaseTools {
    let dir: TempDir
    let root: URL
    let bin: URL
    let app: URL
    let dmg: URL
    let out: URL
    let archives: URL

    init(verifyFails: Bool = true) throws {
        dir = try TempDir()
        root = dir.url.appendingPathComponent("root")
        let lib = try dir.dir("root/scripts/lib")
        try FileManager.default.copyItem(at: repoRoot.appendingPathComponent("scripts/lib/release-common.sh"),
                                         to: lib.appendingPathComponent("release-common.sh"))
        let fakeTool = root.appendingPathComponent("scripts/update-key.sh")
        try Data("""
            #!/bin/bash
            case "$1" in
                export-private-key) echo STUB-PRIVATE-KEY-DO-NOT-PRINT ;;
                merge-appcast) cp "$2" "$5" ;;
                verify-appcast) exit \(verifyFails ? 1 : 0) ;;
                verify-feed|check-appcast-versions|check-archives-covered) exit 0 ;;
                *) exit 2 ;;
            esac

            """.utf8).write(to: fakeTool)
        bin = try dir.dir("bin")
        let fakeGenerate = bin.appendingPathComponent("generate_appcast")
        try Data("#!/bin/bash\ncat >/dev/null\nfor last; do :; done\necho '<rss/>' > \"$last/appcast.xml\"\nmkdir -p \"$last/old_updates\"\n".utf8)
            .write(to: fakeGenerate)
        try Data("#!/bin/bash\ncat >/dev/null\nexit 0\n".utf8).write(to: bin.appendingPathComponent("sign_update"))
        for file in [fakeTool, fakeGenerate, bin.appendingPathComponent("sign_update")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let contents = try dir.dir("App.app/Contents")
        app = dir.url.appendingPathComponent("App.app")
        let plist: [String: Any] = ["SUPublicEDKey": "AAAA", "CFBundleShortVersionString": "1.6", "CFBundleVersion": "7"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        dmg = try dir.file("dmg/Selway-1.6.dmg", bytes: 5)
        out = try dir.dir("out")
        archives = try dir.dir("archives")
        try Data("older".utf8).write(to: archives.appendingPathComponent("Selway-1.5.dmg"))
        existing = try dir.file("published/appcast.xml", bytes: 3)
    }

    /// The published feed the step extends (the stand-in tools accept it).
    let existing: URL

    static let appcastStep = #"source "$1/scripts/lib/release-common.sh"; selway_sparkle_appcast "$2" "$3" "$4" "$5" "$6" "$7""#

    func run(_ script: String = StubbedReleaseTools.appcastStep, shellOptions: [String] = [],
             archives: URL? = nil, extraEnvironment: [String: String] = [:]) -> TestTool.Result {
        var env = ProcessInfo.processInfo.environment
        env["SELWAY_APPCAST"] = ""
        env["SELWAY_RELEASE_NOTES"] = ""
        env.merge(extraEnvironment) { $1 }
        return TestTool.run("/bin/bash", shellOptions + ["-c", script, "test", root.path, dmg.path, app.path,
                                                         (archives ?? self.archives).path, bin.path, out.path,
                                                         existing.path], environment: env)
    }

    func contents(_ folder: URL) -> [String] {
        (FileManager.default.subpaths(atPath: folder.path) ?? []).sorted()
    }
}

/// An appcast that doesn't verify against the app's SUPublicEDKey is not copied to the output
/// folder (where it could be published), and the archives folder is left exactly as it was.
@Test func unverifiedAppcastChangesNothing() throws {
    let tools = try StubbedReleaseTools()
    defer { tools.dir.cleanup() }
    let before = tools.contents(tools.archives)
    let result = tools.run()
    #expect(result.status != 0)
    #expect(result.text.contains("doesn't verify"), "\(result.text)")
    #expect(tools.contents(tools.out).isEmpty)
    #expect(tools.contents(tools.archives) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: tools.dir.url.path).allSatisfy { !$0.hasPrefix(".sparkle-work") })
}

/// With every step passing, the scratch copy replaces the archives folder.
@Test func verifiedAppcastReplacesTheArchives() throws {
    let tools = try StubbedReleaseTools(verifyFails: false)
    defer { tools.dir.cleanup() }
    let result = tools.run()
    #expect(result.status == 0, "\(result.text)")
    #expect(Set(tools.contents(tools.archives)).isSuperset(of: ["Selway-1.5.dmg", "Selway-1.6.dmg", "appcast.xml"]))
    #expect(tools.contents(tools.out) == ["appcast.xml"])
}

/// The signing key is held in a shell variable for a moment; with xtrace on, bash would print
/// it, so the step refuses to run at all.
@Test(arguments: [["-x"], []])
func appcastStepRefusesXtrace(options: [String]) throws {
    let tools = try StubbedReleaseTools(verifyFails: false)
    defer { tools.dir.cleanup() }
    let script = options.isEmpty ? "set -x; " + StubbedReleaseTools.appcastStep : StubbedReleaseTools.appcastStep
    let result = tools.run(script, shellOptions: options)
    #expect(result.status != 0)
    #expect(result.text.contains("xtrace"), "\(result.text)")
    #expect(!result.text.contains("STUB-PRIVATE-KEY"))
}

/// A symlinked archives folder stays a symlink across releases; its target gets the files, and
/// the scratch folder is made next to the target (its volume), not next to the link.
@Test func symlinkedArchivesFolderStaysALink() throws {
    let tools = try StubbedReleaseTools(verifyFails: false)
    defer { tools.dir.cleanup() }
    let target = try tools.dir.dir("elsewhere/real-archives")
    try FileManager.default.copyItem(at: tools.archives.appendingPathComponent("Selway-1.5.dmg"),
                                     to: target.appendingPathComponent("Selway-1.5.dmg"))
    let link = tools.dir.url.appendingPathComponent("archives-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let first = tools.run(archives: link)
    #expect(first.status == 0, "\(first.text)")
    // A second release (the stand-ins don't care about versions).
    let second = tools.run(archives: link)
    #expect(second.status == 0, "\(second.text)")
    let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
    #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
    #expect(Set(tools.contents(target)).isSuperset(of: ["Selway-1.5.dmg", "Selway-1.6.dmg", "appcast.xml"]))
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        .allSatisfy { !$0.hasPrefix(".sparkle-work") })
}

/// An interrupted step (here: TERM in the middle of generate_appcast) removes its scratch copy
/// and leaves the archives folder as it was; an EXIT trap set before the step still runs,
/// on failure and after success alike.
@Test func interruptedOrFailedStepCleansUpAndKeepsEarlierTraps() throws {
    let tools = try StubbedReleaseTools(verifyFails: false)
    defer { tools.dir.cleanup() }
    let before = tools.contents(tools.archives)
    let slowGenerate = tools.bin.appendingPathComponent("generate_appcast")
    let original = try Data(contentsOf: slowGenerate)
    try Data("#!/bin/bash\ncat >/dev/null\nkill -TERM $PPID\nsleep 5\n".utf8).write(to: slowGenerate)
    let interrupted = tools.run()
    #expect(interrupted.status == 143, "\(interrupted.text)")
    #expect(tools.contents(tools.archives) == before)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: tools.dir.url.path).filter { $0.hasPrefix(".sparkle-work") }
    #expect(leftovers.isEmpty, "\(leftovers)")

    try original.write(to: slowGenerate)
    let chained = "trap 'echo EARLIER-EXIT-TRAP' EXIT; " + StubbedReleaseTools.appcastStep + "; echo STEP-DONE"
    let success = tools.run(chained)
    #expect(success.status == 0, "\(success.text)")
    #expect(success.output.contains("STEP-DONE") && success.output.components(separatedBy: "EARLIER-EXIT-TRAP").count == 2,
            "\(success.output)")
    let failing = try StubbedReleaseTools(verifyFails: true)
    defer { failing.dir.cleanup() }
    let failure = failing.run(chained)
    #expect(failure.status != 0 && failure.output.contains("EARLIER-EXIT-TRAP") && !failure.output.contains("STEP-DONE"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: failing.dir.url.path).allSatisfy { !$0.hasPrefix(".sparkle-work") })
}

/// The committed Team ID record: once present it forbids ad-hoc releases and other Team IDs even
/// with no archives folder (no DMGs to look at); release.sh writes it after the first
/// Developer ID release and refuses a mismatch later.
@Test func committedTeamRecordIsEnforcedWithoutTheArchives() throws {
    let tools = try StubbedReleaseTools()
    defer { tools.dir.cleanup() }
    let empty = try tools.dir.dir("empty-archives")
    let record = tools.dir.url.appendingPathComponent("release/team-id")
    func run(_ script: String, identity: String) -> TestTool.Result {
        var env = ProcessInfo.processInfo.environment
        env["SELWAY_TEAM_ID_FILE"] = record.path
        env["SELWAY_SIGN_IDENTITY"] = identity
        return TestTool.run("/bin/bash", ["-c", #"source "$1/scripts/lib/release-common.sh"; "# + script,
                                          "test", tools.root.path, empty.path], environment: env)
    }
    let developerID = "Developer ID Application: X (ABCDE12345)"
    // No record, no DMGs: anything goes; recording creates the file.
    #expect(run(#"selway_check_team_continuity "$2" 1.6"#, identity: "-").status == 0)
    let recorded = run(#"selway_record_team ABCDE12345"#, identity: developerID)
    #expect(recorded.status == 0 && recorded.output.contains("Commit it"), "\(recorded.text)")
    #expect(try String(contentsOf: record, encoding: .utf8) == "ABCDE12345\n")
    #expect(run(#"selway_record_team ABCDE12345"#, identity: developerID).status == 0)
    #expect(run(#"selway_record_team OTHER12345"#, identity: developerID).text.contains("records Team ID ABCDE12345"))
    // With the record: ad-hoc and other identities are refused before building and after signing.
    #expect(run(#"selway_check_team_continuity "$2" 1.6"#, identity: "-").text.contains("ad-hoc release can't follow"))
    #expect(run(#"selway_check_team_continuity "$2" 1.6"#, identity: "Developer ID Application: X (OTHER12345)")
        .text.contains("isn't for Team ID ABCDE12345"))
    #expect(run(#"selway_check_team_continuity "$2" 1.6 OTHER12345"#, identity: developerID).text.contains("earlier ones by ABCDE12345"))
    #expect(run(#"selway_check_team_continuity "$2" 1.6"#, identity: developerID).status == 0)
    #expect(run(#"selway_check_team_continuity "$2" 1.6 ABCDE12345"#, identity: developerID).status == 0)
    try Data("not a team\n".utf8).write(to: record)
    #expect(run(#"selway_check_team_continuity "$2" 1.6"#, identity: developerID).status != 0)
}

/// With no feed to extend, earlier DMGs in the archives folder mean a feed went missing: refuse.
@Test func earlierReleasesWithoutAFeedAreRefused() throws {
    let tools = try StubbedReleaseTools(verifyFails: false)
    defer { tools.dir.cleanup() }
    let result = TestTool.run("/bin/bash", ["-c", #"source "$1/scripts/lib/release-common.sh"; selway_check_archives_covered "$2" "" 1.6"#,
                                            "test", tools.root.path, tools.archives.path])
    #expect(result.status != 0 && result.text.contains("holds earlier releases"), "\(result.text)")
    try FileManager.default.removeItem(at: tools.archives.appendingPathComponent("Selway-1.5.dmg"))
    try Data("x".utf8).write(to: tools.archives.appendingPathComponent("Selway-1.6.dmg"))   // this release's own: fine
    #expect(TestTool.run("/bin/bash", ["-c", #"source "$1/scripts/lib/release-common.sh"; selway_check_archives_covered "$2" "" 1.6"#,
                                       "test", tools.root.path, tools.archives.path]).status == 0)
}

/// In a git checkout the committed feed must be origin/main's docs/appcast.xml, fetched first, so
/// a checkout that is behind the last release is caught even with a new, empty archives folder
/// (which the comparison with the archives copy can't do). The remote is a bare repository in the
/// temporary folder, never the network. Outside a git checkout (every other test's temporary
/// root) the comparison is skipped.
@Test func committedFeedMustMatchOriginMain() throws {
    let tools = try StubbedReleaseTools()
    defer { tools.dir.cleanup() }
    let freshArchives = try tools.dir.dir("fresh-archives")
    let feed = tools.root.appendingPathComponent("docs/appcast.xml")
    try FileManager.default.createDirectory(at: feed.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("published feed 1\n".utf8).write(to: feed)
    // Git without the user's or the system's settings (hooks, commit signing).
    var gitEnv = ProcessInfo.processInfo.environment
    gitEnv["GIT_CONFIG_GLOBAL"] = "/dev/null"
    gitEnv["GIT_CONFIG_NOSYSTEM"] = "1"
    for role in ["AUTHOR", "COMMITTER"] {
        gitEnv["GIT_\(role)_NAME"] = "Fixture"
        gitEnv["GIT_\(role)_EMAIL"] = "fixture@example.invalid"
    }
    gitEnv.removeValue(forKey: "SELWAY_SKIP_FEED_ORIGIN_CHECK")
    gitEnv.removeValue(forKey: "SELWAY_APPCAST")
    func git(_ script: String) throws {
        let result = TestTool.run("/bin/bash", ["-c", "set -euo pipefail; cd \"$1\"; " + script, "git", tools.dir.url.path],
                                  environment: gitEnv)
        try #require(result.status == 0, "\(result.text)")
    }
    func existing(_ extra: [String: String] = [:]) -> TestTool.Result {
        TestTool.run("/bin/bash", ["-c", #"source "$1/scripts/lib/release-common.sh"; selway_existing_appcast "$2""#,
                                   "test", tools.root.path, freshArchives.path],
                     environment: gitEnv.merging(extra) { $1 })
    }

    // Not a git checkout: nothing to compare with.
    let plain = existing()
    #expect(plain.status == 0 && plain.output == feed.path + "\n", "\(plain.text)")

    // A checkout whose origin/main has no feed yet (before the first release): no comparison,
    // with or without a local feed.
    try git("""
        git init -q --bare -b main origin.git
        cd root
        git init -q -b main
        git remote add origin "$1/origin.git"
        git add scripts
        git commit -q -m base
        git push -q origin main
        """)
    let firstRelease = existing()
    #expect(firstRelease.status == 0 && firstRelease.output == feed.path + "\n", "\(firstRelease.text)")
    try FileManager.default.removeItem(at: feed)
    let noFeed = existing()
    #expect(noFeed.status == 0 && noFeed.output.isEmpty, "\(noFeed.text)")

    // The feed merged on origin/main and the same feed here: fine.
    try Data("published feed 1\n".utf8).write(to: feed)
    try git("cd root; git add docs/appcast.xml; git commit -q -m 'Release 1'; git push -q origin main")
    let current = existing()
    #expect(current.status == 0 && current.output == feed.path + "\n", "\(current.text)")

    // Another checkout releases and merges a newer feed. This one is now behind; the fetch finds out.
    try git("""
        git clone -q "$1/origin.git" other
        cd other
        printf 'published feed 2\\n' > docs/appcast.xml
        git commit -q -am 'Release 2'
        git push -q origin main
        """)
    let behind = existing()
    #expect(behind.status != 0 && behind.text.contains("differs from docs/appcast.xml on origin/main"), "\(behind.text)")
    #expect(behind.output.isEmpty)
    #expect(try String(contentsOf: feed, encoding: .utf8) == "published feed 1\n")
    // A linked worktree is a checkout too, though its .git is a file rather than a folder.
    try git("cd root; git worktree add -q --detach ../wt HEAD")
    let worktree = TestTool.run("/bin/bash", ["-c", #"source "$1/scripts/lib/release-common.sh"; selway_existing_appcast "$2""#,
                                              "test", tools.dir.url.appendingPathComponent("wt").path, freshArchives.path],
                                environment: gitEnv)
    #expect(worktree.status != 0 && worktree.text.contains("differs from docs/appcast.xml on origin/main"), "\(worktree.text)")
    // A local branch named origin/main can't stand in for the fetched refs/remotes/origin/main.
    try git("cd root; git branch origin/main HEAD")
    let shadowed = existing()
    #expect(shadowed.status != 0 && shadowed.text.contains("differs from docs/appcast.xml on origin/main"), "\(shadowed.text)")
    try git("cd root; git branch -D -q origin/main")
    // The override skips only this comparison, and says so.
    let overridden = existing(["SELWAY_SKIP_FEED_ORIGIN_CHECK": "1"])
    #expect(overridden.status == 0 && overridden.output == feed.path + "\n", "\(overridden.text)")
    #expect(overridden.errors.contains("SELWAY_SKIP_FEED_ORIGIN_CHECK=1"), "\(overridden.text)")
    // SELWAY_APPCAST is what gets compared: one holding origin/main's feed passes.
    let upToDate = try tools.dir.file("elsewhere/appcast.xml")
    try Data("published feed 2\n".utf8).write(to: upToDate)
    let elsewhere = existing(["SELWAY_APPCAST": upToDate.path])
    #expect(elsewhere.status == 0 && elsewhere.output == upToDate.path + "\n", "\(elsewhere.text)")

    // No local feed while origin/main has one: behind as well.
    try FileManager.default.removeItem(at: feed)
    let missing = existing()
    #expect(missing.status != 0 && missing.text.contains("doesn't exist. This checkout is behind"), "\(missing.text)")
    #expect(!FileManager.default.fileExists(atPath: feed.path))

    // A remote that can't be fetched stops the release instead of skipping the check.
    try git(#"cd root; git remote set-url origin "$1/no-such-remote.git""#)
    let unreachable = existing()
    #expect(unreachable.status != 0 && unreachable.text.contains("couldn't fetch origin"), "\(unreachable.text)")
}

/// The committed feed defaults to docs/appcast.xml in the checkout the library is in, whether
/// SELWAY_APPCAST is unset or empty.
@Test func feedFileDefaultsToTheCheckoutsDocsFolder() throws {
    let tools = try StubbedReleaseTools()
    defer { tools.dir.cleanup() }
    func feedFile(_ appcast: String?) -> TestTool.Result {
        var env = ProcessInfo.processInfo.environment
        env["SELWAY_APPCAST"] = appcast
        return TestTool.run("/bin/bash", ["-c", #"source "$1/scripts/lib/release-common.sh"; selway_feed_file"#,
                                          "test", tools.root.path], environment: env)
    }
    let expected = tools.root.appendingPathComponent("docs/appcast.xml").path + "\n"
    let unset = feedFile(nil)
    #expect(unset.status == 0 && unset.output == expected, "\(unset.text)")
    #expect(feedFile("").output == expected)
    #expect(feedFile("/elsewhere/feed.xml").output == "/elsewhere/feed.xml\n")
}

/// selway_write_feed into a folder it can't write to fails loudly and leaves the old feed, and
/// nothing else, in that folder.
@Test func writeFeedFailureKeepsTheOldFeed() throws {
    let dir = try TempDir()
    let folder = try dir.dir("docs")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        dir.cleanup()
    }
    let feed = folder.appendingPathComponent("appcast.xml")
    try Data("old feed\n".utf8).write(to: feed)
    let new = try dir.file("out/appcast.xml")
    try Data("new feed\n".utf8).write(to: new)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    // Root can write anywhere; there is nothing to test then.
    guard getuid() != 0 else { return }
    var env = ProcessInfo.processInfo.environment
    env["SELWAY_APPCAST"] = feed.path
    let result = TestTool.run("/bin/bash", ["-c", #"source "$1/scripts/lib/release-common.sh"; selway_write_feed "$2""#,
                                            "test", repoRoot.path, new.path], environment: env)
    #expect(result.status != 0)
    #expect(result.text.contains("couldn't write next to \(feed.path)"), "\(result.text)")
    #expect(try Data(contentsOf: feed) == Data("old feed\n".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["appcast.xml"])
    #expect(try Data(contentsOf: new) == Data("new feed\n".utf8))
}

/// release.sh writes the committed feed only after selway_sparkle_appcast has verified the new
/// one, so a feed that fails verification never replaces it.
@Test func releaseScriptVerifiesTheFeedBeforeWritingIt() throws {
    let script = try String(contentsOf: repoRoot.appendingPathComponent("release.sh"), encoding: .utf8)
    let lines = script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    let verify = lines.indices.filter { lines[$0].hasPrefix("selway_sparkle_appcast ") }
    let write = lines.indices.filter { lines[$0].hasPrefix("selway_write_feed ") }
    #expect(verify.count == 1 && write.count == 1, "verify: \(verify), write: \(write)")
    if let verifyLine = verify.first, let writeLine = write.first {
        #expect(verifyLine < writeLine)
    }
}

/// Once a release carried a Developer ID signature, ad-hoc releases (or another Team ID) can't
/// follow. codesign is stubbed to report a Team ID for the earlier DMG.
@Test func developerIDReleasesCantBeFollowedByAdHocOnes() throws {
    let tools = try StubbedReleaseTools()
    defer { tools.dir.cleanup() }
    let stubs = try tools.dir.dir("stub-path")
    try Data("#!/bin/bash\nfor last; do :; done\ncase \"$last\" in *Selway-1.5.dmg) echo 'TeamIdentifier=ABCDE12345' >&2 ;; *) echo 'code object is not signed at all' >&2; exit 1 ;; esac\n".utf8)
        .write(to: stubs.appendingPathComponent("codesign"))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubs.appendingPathComponent("codesign").path)
    func check(identity: String, team: String) -> TestTool.Result {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = stubs.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["SELWAY_SIGN_IDENTITY"] = identity
        return TestTool.run("/bin/bash", ["-c", #"source "$1/scripts/lib/release-common.sh"; selway_check_team_continuity "$2" 1.6 "$3""#,
                                          "test", tools.root.path, tools.archives.path, team], environment: env)
    }
    #expect(check(identity: "-", team: "").text.contains("ad-hoc release can't follow"))
    #expect(check(identity: "Developer ID Application: X (OTHER12345)", team: "OTHER12345").text.contains("earlier ones by ABCDE12345"))
    #expect(check(identity: "Developer ID Application: X (ABCDE12345)", team: "ABCDE12345").status == 0)
    try FileManager.default.removeItem(at: tools.archives.appendingPathComponent("Selway-1.5.dmg"))
    #expect(check(identity: "-", team: "").status == 0)
}

/// release.sh stops in preflight: on a SELWAY_APPCAST whose folder doesn't exist (a `die`
/// inside a command substitution used to be ignored), and on a Developer ID build that skips
/// notarization, since everything release.sh makes goes into the appcast.
@Test func releaseScriptStopsEarlyOnBadSettings() throws {
    let dir = try TempDir(); defer { dir.cleanup() }
    var env = ProcessInfo.processInfo.environment
    env["SELWAY_OUT_DIR"] = dir.url.appendingPathComponent("out").path
    env["SELWAY_PREBUILT_APP"] = dir.url.appendingPathComponent("Missing.app").path
    env["SELWAY_SKIP_TESTS"] = "1"
    // Never fetch the checkout's real remote, whatever order the preflight checks run in.
    env["SELWAY_SKIP_FEED_ORIGIN_CHECK"] = "1"
    env["SELWAY_APPCAST"] = dir.url.appendingPathComponent("nonexistent/appcast.xml").path
    let missing = TestTool.run(repoRoot.appendingPathComponent("release.sh").path, [], environment: env)
    #expect(missing.status != 0)
    #expect(missing.text.contains("SELWAY_APPCAST's folder doesn't exist"), "\(missing.text)")
    #expect(!missing.text.contains("Feed:") && !missing.text.contains("Building"))

    // A feed in the temporary folder: release.sh must stop before reading or writing any feed,
    // but if it ever got that far it mustn't be the checkout's own docs/appcast.xml.
    env["SELWAY_APPCAST"] = dir.url.appendingPathComponent("appcast.xml").path
    env["SELWAY_SIGN_IDENTITY"] = "Developer ID Application: Nobody (TEAM000000)"
    env["SELWAY_SKIP_NOTARIZE"] = "1"
    let unnotarized = TestTool.run(repoRoot.appendingPathComponent("release.sh").path, [], environment: env)
    #expect(unnotarized.status != 0)
    #expect(unnotarized.text.contains("SELWAY_SKIP_NOTARIZE=1 with a Developer ID identity"), "\(unnotarized.text)")
}

/// The build-number format rule, without an appcast (no tool run needed).
@Test func buildNumberMustBeAPositiveInteger() throws {
    func check(_ build: String) -> TestTool.Result {
        TestTool.run("/bin/bash", ["-c", #"source "$1/scripts/lib/release-common.sh"; selway_check_build_number "$2""#,
                                   "test", repoRoot.path, build])
    }
    #expect(check("13").status == 0)
    for bad in ["0", "01", "1.0", "-3", "", "2a", "1234567890"] {
        #expect(check(bad).status != 0, "accepted build '\(bad)'")
    }
}
#endif
