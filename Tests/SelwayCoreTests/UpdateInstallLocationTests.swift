import Foundation
import Testing
@testable import SelwayCore

@Suite struct UpdateInstallLocationTests {

    private let page = "https://github.com/toddbartholow/selway/releases"

    private func facts(path: String = "/Applications/Selway.app", readOnly: Bool = false, folder: Bool = true,
                       bundle: Bool = true, ownership: Bool = true, root: Bool = false) -> UpdateInstallLocation.Facts {
        .init(appPath: path, readOnlyVolume: readOnly, folderWritable: folder, bundleWritable: bundle,
              canMatchBundleOwnership: ownership, runningAsRoot: root)
    }

    @Test func ownWritableInstallHasNoProblem() {
        #expect(UpdateInstallLocation.problem(facts(), downloadPage: page) == nil)
    }

    @Test func diskImageOrTranslocationSaysMoveToApplications() throws {
        for f in [facts(path: "/Volumes/Selway 1.6/Selway.app", readOnly: true),
                  facts(path: "/private/var/folders/x/AppTranslocation/ABC/d/Selway.app")] {
            let message = try #require(UpdateInstallLocation.problem(f, downloadPage: page))
            #expect(message.contains("Drag it to Applications"))
        }
    }

    /// Each of Sparkle's reasons to ask for an administrator, on its own: folder not writable,
    /// bundle not writable, bundle owned by another user or a group this user isn't in, root.
    @Test(arguments: [(false, true, true, false), (true, false, true, false), (true, true, false, false),
                      (true, true, true, true)])
    func anyConditionSparkleWouldEscalateForIsRefused(folder: Bool, bundle: Bool, ownership: Bool, root: Bool) throws {
        let message = try #require(UpdateInstallLocation.problem(facts(folder: folder, bundle: bundle,
                                                                       ownership: ownership, root: root),
                                                                 downloadPage: page))
        #expect(message.contains(page))
        #expect(!message.contains("Drag it to Applications"))
    }

    @Test func standardUserInApplicationsIsToldToAskAnAdministrator() throws {
        let message = try #require(UpdateInstallLocation.problem(facts(folder: false, bundle: false), downloadPage: page))
        #expect(message.contains("administrator") && message.contains("/Applications"))
    }

    // MARK: Real file system

    #if os(macOS)
    /// Sparkle's chown test: this user can give a file its own uid and group, but not root's
    /// uid, nor a group it isn't in (wheel, for a normal account).
    @Test func ownershipTestMatchesWhatTheKernelAllows() throws {
        #expect(UpdateInstallLocation.canMatchOwnership(owner: getuid(), group: getgid()))
        if getuid() != 0 {
            #expect(!UpdateInstallLocation.canMatchOwnership(owner: 0, group: getgid()))
            var groups = [gid_t](repeating: 0, count: 64)
            let count = getgroups(Int32(groups.count), &groups)
            if count >= 0, !groups.prefix(Int(count)).contains(0) {
                #expect(!UpdateInstallLocation.canMatchOwnership(owner: getuid(), group: 0))
            }
        }
    }

    /// A writable folder doesn't help when the bundle itself can't be replaced.
    @Test func writableFolderWithReadOnlyBundleIsRefused() throws {
        let dir = try TempDir(); defer { dir.cleanup() }
        let app = try dir.dir("Apps/SelwayFixture.app")
        _ = try dir.file("Apps/SelwayFixture.app/Contents/Info.plist")
        var f = UpdateInstallLocation.facts(forApp: app)
        #expect(f.folderWritable && f.bundleWritable && f.canMatchBundleOwnership)
        #expect(UpdateInstallLocation.problem(f, downloadPage: page) == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: app.path)
        f = UpdateInstallLocation.facts(forApp: app)
        #expect(f.folderWritable && !f.bundleWritable)
        #expect(UpdateInstallLocation.problem(f, downloadPage: page) != nil)
    }
    #endif
}
