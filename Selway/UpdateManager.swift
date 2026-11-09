import AppKit
import Combine
import Sparkle

/// Software updates through Sparkle (https://sparkle-project.org), with its standard UI.
///
/// Sparkle reads `SUFeedURL`, `SUPublicEDKey` and its verification settings from Info.plist
/// (docs/RELEASING.md). It only offers an update whose appcast is signed and whose download
/// carries a valid EdDSA signature for that public key; the private key never ships with the app.
///
/// Installing never bypasses the quit review: Sparkle's "Install and Relaunch" (and an update
/// left to install at quit) asks the app to quit with an ordinary quit event, so
/// `AppDelegate.applicationShouldTerminate` still deals with running file operations and
/// unsaved editors first. If the user cancels that quit, Sparkle's installer keeps waiting and
/// installs only once the app has really exited. `UpdaterPolicy` adds Selway's own rules.
@MainActor
final class UpdateManager: ObservableObject {

    static let shared = UpdateManager()

    private let controller: SPUStandardUpdaterController
    /// Sparkle keeps only a weak reference to its delegate.
    private let policy = UpdaterPolicy()
    private var observers: Set<AnyCancellable> = []

    /// False while Sparkle is busy (a check or an install is already showing).
    @Published private(set) var canCheckForUpdates = false
    /// Mirrors the updater's own setting, so SwiftUI redraws when Sparkle changes it.
    @Published private(set) var automaticallyChecksForUpdates = false

    private init() {
        #if SELWAY_UI_TESTING
        // UI tests never check for updates (UITestHooks).
        let start = !UITestHooks.isActive
        #else
        let start = true
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: start,
                                                  updaterDelegate: policy,
                                                  userDriverDelegate: nil)
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &observers)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }
            .store(in: &observers)
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// Settings → General → Updates. Sparkle stores the choice in its own defaults key.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    /// "Check for Updates…". While a quit is already waiting on running file operations or
    /// unsaved editors this does nothing: Sparkle's window would offer "Install and Relaunch",
    /// and a second quit request in the middle of that review could end the app before the
    /// saves finish.
    func checkForUpdates() {
        guard !UpdaterPolicy.quitIsPending else {
            NSSound.beep()
            return
        }
        controller.checkForUpdates(nil)
    }
}

/// Selway's rules for Sparkle (its SPUUpdaterDelegate). Sparkle calls these on the main thread.
final class UpdaterPolicy: NSObject, SPUUpdaterDelegate {

    /// Where to get an update by hand when Selway can't install it itself.
    static let downloadPage = SelwayLinks.releases.absoluteString

    /// A quit is already waiting on running file operations or unsaved editors. A second quit
    /// request during that review (`.terminateLater`) would make AppKit end the app at once,
    /// cutting off a copy or skipping the saves (see TextFileQuitReview).
    @MainActor static var quitIsPending: Bool {
        UnsavedChangesReview.isQuitting || RunningOperationsReview.isWaiting
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "studio.irq.selway.update", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Why Selway can't replace itself where it runs, by Sparkle's own rule for when it would
    /// ask for an administrator (UpdateInstallLocation); nil when it can.
    static func locationProblem() -> String? {
        UpdateInstallLocation.problem(UpdateInstallLocation.facts(forApp: Bundle.main.bundleURL),
                                      downloadPage: downloadPage)
    }

    /// Called before every update session, including the two resume paths that skip
    /// shouldProceedWithUpdate: an update downloaded by an earlier check, and an installer
    /// already running (SPUUpdater.m, checkForUpdatesWithDriver, Sparkle 2.10.0). Refuses:
    /// - while a quit review is pending (scheduled checks too): their window could offer
    ///   "Install and Relaunch" in the middle of it;
    /// - when Selway can't replace itself without an administrator: Sparkle would ask for an
    ///   admin password and run its installer as root, which an ad-hoc build shouldn't get.
    ///   A manual check shows the message; scheduled checks stay quiet. (Can be relaxed once
    ///   releases are Developer ID–signed.)
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if MainActor.assumeIsolated({ Self.quitIsPending }) {
            throw Self.error("Selway is quitting.")
        }
        if let problem = Self.locationProblem() {
            throw Self.error(problem)
        }
    }

    /// Checked again when a new update is found (the app may have moved since the session began).
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        if let problem = Self.locationProblem() {
            throw Self.error(problem)
        }
    }

    /// Asked every time an install is about to quit the app (Install and Relaunch, and its
    /// retries). While a quit review is pending, or if the app can no longer be replaced
    /// without an administrator, the install is called off instead.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        MainActor.assumeIsolated {
            guard !Self.quitIsPending, Self.locationProblem() == nil else {
                NSSound.beep()
                return false
            }
            return true
        }
    }
}
