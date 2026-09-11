import Foundation
import GitLabKit
import UserNotifications
import os

/// Posting side of notifications, behind a protocol so `PollScheduler` — and
/// anything testable — never imports `UserNotifications`.
protocol Notifying: Sendable {
    func post(_ events: [ActivityEvent]) async
}

/// Where authorization currently stands, so Settings can explain itself instead
/// of showing toggles that silently do nothing.
enum NotificationAuthorization: Sendable, Hashable {
    case notRequested
    case granted
    case denied

    var allowsPosting: Bool { self == .granted }
}

/// Keys carried in `userInfo` so a click can be routed back to the right item.
enum NotificationPayloadKey {
    static let eventID = "eventID"
    static let kind = "kind"
    static let repository = "repository"
    static let url = "url"
}

/// `UNUserNotificationCenter`-backed ``Notifying``.
actor UserNotificationNotifier: Notifying {

    /// Above this many banners in one cycle we post a single summary instead.
    /// The diff engine already collapses bursts per repository; this is the
    /// cross-repository backstop, so a busy morning cannot produce a wall.
    private static let maxBannersPerCycle = 4

    private let center: UNUserNotificationCenter
    private let log = Logger(subsystem: "com.alBz.GitLabAlert", category: "notify")
    private var authorization: NotificationAuthorization = .notRequested
    private let onAuthorizationChange: @Sendable (NotificationAuthorization) async -> Void

    init(
        center: UNUserNotificationCenter = .current(),
        onAuthorizationChange: @escaping @Sendable (NotificationAuthorization) async -> Void = { _ in }
    ) {
        self.center = center
        self.onAuthorizationChange = onAuthorizationChange
    }

    /// Reads the system's current setting without prompting, so the app can show
    /// an accurate state at launch.
    func refreshAuthorizationState() async {
        let settings = await center.notificationSettings()
        let resolved: NotificationAuthorization
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            resolved = .granted
        case .denied:
            resolved = .denied
        case .notDetermined:
            resolved = .notRequested
        @unknown default:
            resolved = .notRequested
        }
        await setAuthorization(resolved)
    }

    func post(_ events: [ActivityEvent]) async {
        guard !events.isEmpty, !Task.isCancelled else { return }

        // Authorization is requested at the first event worth showing, never at
        // launch: a cold permission alert is the fastest way to get denied.
        guard await ensureAuthorized() else {
            log.debug("suppressed \(events.count, privacy: .public) events: not authorized")
            return
        }

        guard !Task.isCancelled else { return }
        if events.count > Self.maxBannersPerCycle {
            await postSummary(for: events)
            return
        }
        for event in events {
            await postOne(event)
        }
    }

    // MARK: - Authorization

    private func ensureAuthorized() async -> Bool {
        switch authorization {
        case .granted:
            return true
        case .denied:
            return false
        case .notRequested:
            break
        }

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await setAuthorization(granted ? .granted : .denied)
            return granted
        } catch {
            // Denial and failure are the same outcome for us: degrade to
            // in-UI-only rather than dropping the events on the floor silently.
            log.error("authorization request failed: \(String(describing: error), privacy: .public)")
            await setAuthorization(.denied)
            return false
        }
    }

    private func setAuthorization(_ value: NotificationAuthorization) async {
        guard authorization != value else { return }
        authorization = value
        await onAuthorizationChange(value)
    }

    // MARK: - Content

    private func postOne(_ event: ActivityEvent) async {
        let content = UNMutableNotificationContent()
        content.title = title(for: event)
        content.body = body(for: event)
        content.sound = nil
        content.categoryIdentifier = event.kind.rawValue
        content.userInfo = [
            NotificationPayloadKey.eventID: event.id,
            NotificationPayloadKey.kind: event.kind.rawValue,
            NotificationPayloadKey.repository: event.repository,
            NotificationPayloadKey.url: event.url?.absoluteString ?? "",
        ]

        await submit(identifier: event.id, content: content)
    }

    private func postSummary(for events: [ActivityEvent]) async {
        let repositories = Set(events.map(\.repository))
        let content = UNMutableNotificationContent()
        content.title = "\(events.count) new GitLab events"
        content.body = repositories.count == 1
            ? "On \(shortName(repositories.first ?? ""))"
            : "Across \(repositories.count) repositories"
        content.sound = nil
        content.userInfo = [
            NotificationPayloadKey.eventID: events.first?.id ?? "",
            NotificationPayloadKey.kind: "summary",
            NotificationPayloadKey.repository: repositories.count == 1 ? (repositories.first ?? "") : "",
        ]
        await submit(identifier: "summary-\(events.first?.id ?? UUID().uuidString)", content: content)
    }

    private func submit(identifier: String, content: UNNotificationContent) async {
        guard !Task.isCancelled else { return }
        // nil trigger delivers immediately.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            log.error("could not post notification: \(String(describing: error), privacy: .public)")
        }
    }

    private func title(for event: ActivityEvent) -> String {
        let repo = shortName(event.repository)
        switch event.kind {
        case .star:
            return event.delta == 1 ? "New star on \(repo)" : "\(event.delta) new stars on \(repo)"
        case .fork:
            return event.delta == 1 ? "New fork of \(repo)" : "\(event.delta) new forks of \(repo)"
        case .checksFailed:
            return "CI failing on \(repo)"
        case .checksRecovered:
            return "CI green again on \(repo)"
        case .reviewRequested:
            return "Review requested on \(repo)"
        case .inboundIssue:
            return "New issue on \(repo)"
        case .inboundMergeRequest:
            return "New merge request on \(repo)"
        }
    }

    private func body(for event: ActivityEvent) -> String {
        // Never invent a name: a count-only event has no attribution yet, and
        // saying "someone" is more honest than guessing.
        let names = event.actors.map(\.login)
        switch event.kind {
        case .star, .fork:
            if names.isEmpty { return event.repository }
            if names.count == 1 { return "by \(names[0])" }
            if names.count == 2 { return "by \(names[0]) and \(names[1])" }
            return "by \(names[0]), \(names[1]) and \(names.count - 2) more"
        case .checksFailed, .checksRecovered:
            return event.repository
        case .reviewRequested, .inboundIssue, .inboundMergeRequest:
            if let title = event.title {
                return names.isEmpty ? title : "\(title) — \(names[0])"
            }
            return event.repository
        }
    }

    private func shortName(_ nameWithOwner: String) -> String {
        nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner
    }
}

/// Receives notification interactions and hands them to the app.
///
/// Must be an `NSObject` to be a `UNUserNotificationCenterDelegate`, and must be
/// installed before `applicationDidFinishLaunching` returns, or a click that
/// launched the app is dropped.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {

    /// Called on the main actor with the event id and, when present, its URL.
    var onOpen: (@MainActor (String, URL?) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show the banner even when the app is frontmost: "frontmost" for a menu
        // bar utility usually means the popover is open, which is exactly when
        // the user wants to see that something arrived.
        [.banner, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let eventID = info[NotificationPayloadKey.eventID] as? String ?? ""
        let urlString = info[NotificationPayloadKey.url] as? String
        let url = urlString.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        await MainActor.run { [onOpen] in
            onOpen?(eventID, url)
        }
    }
}
