import Foundation

/// Whether Selway may replace itself where it's running from. Without a Developer ID, Selway
/// doesn't let Sparkle ask for an administrator's password: that would run Sparkle's installer
/// as root on the strength of an ad-hoc build. Users who can't replace the app install updates
/// by hand.
///
/// The rule mirrors Sparkle's own (`SPUSystemNeedsAuthorizationAccessForBundlePath` in
/// SUInstallerLauncher.m, Sparkle 2.10.0): Sparkle installs without authorization only when the
/// app bundle and its folder are both writable *and* a new file can be given the bundle's owner
/// and group (i.e. this user owns the bundle and is in its group). A root process always uses
/// Sparkle's system (authorized) path.
enum UpdateInstallLocation {

    /// What the rule looks at; gathered by `facts(forApp:)`, injectable for tests.
    struct Facts: Equatable {
        var appPath: String
        var readOnlyVolume: Bool
        var folderWritable: Bool
        var bundleWritable: Bool
        /// A new file can be chown'ed to the bundle's owner and group (Sparkle's test).
        var canMatchBundleOwnership: Bool
        var runningAsRoot: Bool
    }

    /// nil when Sparkle would install here without asking for an administrator.
    static func problem(_ facts: Facts, downloadPage: String) -> String? {
        if facts.appPath.contains("/AppTranslocation/") || facts.readOnlyVolume {
            return NSLocalizedString("Selway is running from a disk image or a temporary location, so it can't update itself. Drag it to Applications, open it from there, and try again.", comment: "Update installation location error")
        }
        let folder = (facts.appPath as NSString).deletingLastPathComponent
        if facts.runningAsRoot {
            return String.localizedStringWithFormat(NSLocalizedString("Selway doesn't update itself while running as root. Download the new version from %@ and install it by hand.", comment: "Update installation permission error with download page"), downloadPage)
        }
        if !facts.folderWritable || !facts.bundleWritable {
            return String.localizedStringWithFormat(NSLocalizedString("Selway can't update itself because your account can't replace it in %1$@. Download the new version from %2$@ and ask an administrator to install it, or move Selway to a folder you can write to.", comment: "Update installation permission error with folder and download page"), folder, downloadPage)
        }
        if !facts.canMatchBundleOwnership {
            return String.localizedStringWithFormat(NSLocalizedString("Selway can't update itself because it was installed by another user or an administrator, so replacing it would need an administrator's password. Download the new version from %@ and ask the person who installed it to update it.", comment: "Update installation ownership error with download page"), downloadPage)
        }
        return nil
    }

    /// The facts for the app at `app`, read from the file system now.
    static func facts(forApp app: URL) -> Facts {
        let fm = FileManager.default
        let path = app.path
        let readOnly = (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        var info = stat()
        let found = stat(path, &info) == 0
        return Facts(appPath: path,
                     readOnlyVolume: readOnly,
                     folderWritable: fm.isWritableFile(atPath: app.deletingLastPathComponent().path),
                     bundleWritable: fm.isWritableFile(atPath: path),
                     canMatchBundleOwnership: found && canMatchOwnership(owner: info.st_uid, group: info.st_gid),
                     runningAsRoot: getuid() == 0)
    }

    /// Sparkle's test: create a file in a fresh temporary folder and try to give it `owner` and
    /// `group`. Without privileges that works only for this user's own uid and one of its groups.
    static func canMatchOwnership(owner: uid_t, group: gid_t) -> Bool {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("selway-permission-test-\(UUID().uuidString)",
                                                                  isDirectory: true)
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: false)) != nil else { return false }
        defer { try? fm.removeItem(at: folder) }
        let file = folder.appendingPathComponent("permission_test").path
        guard fm.createFile(atPath: file, contents: Data()) else { return false }
        return chown(file, owner, group) == 0
    }
}
