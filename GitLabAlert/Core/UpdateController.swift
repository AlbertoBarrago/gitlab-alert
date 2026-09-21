import Foundation
import Observation
import Sparkle
import os

/// In-app updates, as the rest of the app sees them: a flag saying whether a
/// check can start, and a call that starts one.
///
/// Sparkle does the work — it reads the EdDSA-signed appcast attached to each
/// GitHub release, downloads the archive, verifies the signature and the
/// signing identity, and replaces the bundle. Wrapping it keeps `SPUUpdater`
/// out of the views, which only need those two things, and keeps the KVO
/// bridging in one place.
///
/// The feed URL and the public key live in Info.plist (`SUFeedURL`,
/// `SUPublicEDKey`), because that is where Sparkle reads them.
@MainActor
@Observable
final class UpdateController {

    private let log = Logger(subsystem: "com.alBz.GitLabAlert", category: "updates")

    /// False while a check is already running, so the UI can disable the
    /// command instead of queueing a second one.
    private(set) var canCheckForUpdates: Bool

    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    /// - Parameter automaticChecks: the user's preference, applied to the
    ///   updater. Sparkle persists its own copy, so the preference is pushed in
    ///   at launch and on every change rather than read by Sparkle directly:
    ///   one setting, one place the user changes it.
    init(automaticChecks: Bool) {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        canCheckForUpdates = controller.updater.canCheckForUpdates
        automaticallyChecksForUpdates = automaticChecks

        // `canCheckForUpdates` is KVO-compliant and flips while a check runs.
        // Sparkle posts it on the main thread, which is where this class lives.
        observation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// Mirrors the app's own preference into Sparkle.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            guard controller.updater.automaticallyChecksForUpdates != newValue else { return }
            controller.updater.automaticallyChecksForUpdates = newValue
            log.info("automatic update checks set enabled=\(newValue, privacy: .public)")
        }
    }

    /// Asking explicitly is consent: this runs even with automatic checks off,
    /// and reports "you are up to date" rather than staying silent.
    func checkForUpdates() {
        log.info("manual update check requested")
        controller.updater.checkForUpdates()
    }
}
