import Foundation
import ServiceManagement
import os

/// Thin wrapper over `SMAppService.mainApp`.
///
/// Registration is only reliable for an app living in `/Applications`, which is
/// exactly where `bin/make-app.sh` installs it. From a build directory this will
/// fail or register something that does not launch, so the failure is surfaced
/// honestly rather than swallowed — Settings shows what happened instead of a
/// toggle that silently flips back.
@MainActor
final class LoginItem {

    enum State: Sendable, Hashable {
        case enabled
        case disabled
        /// macOS wants the user to approve it in System Settings → Login Items.
        case requiresApproval
        case notFound
        case failed(String)

        var isEnabled: Bool { self == .enabled }

        /// What to tell the user, or nil when there is nothing to explain.
        var explanation: String? {
            switch self {
            case .enabled, .disabled:
                return nil
            case .requiresApproval:
                return "Approve GitLab Alert in System Settings → General → Login Items."
            case .notFound:
                return "macOS can't find the installed app. Run bin/make-app.sh so it lives in /Applications."
            case .failed(let message):
                return message
            }
        }
    }

    private let service = SMAppService.mainApp
    private let log = Logger(subsystem: "com.alBz.GitLabAlert", category: "loginitem")

    var state: State {
        switch service.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .disabled
        }
    }

    /// Returns the state after the attempt, so the caller can reflect reality
    /// rather than what was asked for.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> State {
        do {
            if enabled {
                // Registering while already registered throws, and that is not
                // an error worth reporting.
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            return state
        } catch {
            log.error("login item change failed: \(String(describing: error), privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// Opens the pane where the user can approve or remove the login item.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
