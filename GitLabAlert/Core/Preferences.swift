import Foundation
import GitLabKit
import SwiftUI
import os

/// One renderable block of the dashboard. The user reorders and hides these, so
/// the enum is both the identity of a section and its persisted key — which is
/// why the raw values must never be renamed once shipped.
public enum DashboardSection: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case reviewRequested
    case authoredMergeRequests
    case assignedIssues
    case inboundIssues
    case repositories
    case activity

    public var id: String { rawValue }

    /// Order a fresh install starts in: what is waiting on the user first, the
    /// ambient repository state last.
    public static let defaultOrder: [DashboardSection] = [
        .reviewRequested,
        .assignedIssues,
        .inboundIssues,
        .authoredMergeRequests,
        .repositories,
        .activity
    ]

    public var title: String {
        switch self {
        case .reviewRequested: return "Needs your attention"
        case .authoredMergeRequests: return "Your merge requests"
        case .assignedIssues: return "Assigned to you"
        case .inboundIssues: return "Inbound issues"
        case .repositories: return "Repositories"
        case .activity: return "Recent activity"
        }
    }

    /// SF Symbol for the section header. All of these ship with macOS 14.
    public var symbolName: String {
        switch self {
        case .reviewRequested: return "eyeglasses"
        case .authoredMergeRequests: return "arrow.triangle.branch"
        case .assignedIssues: return "person.crop.circle.badge.exclamationmark"
        case .inboundIssues: return "tray.and.arrow.down"
        case .repositories: return "shippingbox"
        case .activity: return "sparkles"
        }
    }
}

/// Typed, observable access to everything the app remembers in `UserDefaults`.
///
/// Deliberately not `@AppStorage`: the popover, the detail window and Settings
/// all read the same values, and three property wrappers pointing at the same
/// key give three places where a default, a clamp or a JSON decode can drift.
/// One owner, real accessors, and `binding(_:)` for the SwiftUI call sites.
@MainActor
@Observable
public final class Preferences {
    /// Defaults keys. Namespaced and frozen: renaming one silently resets that
    /// preference for every existing user.
    private enum Key {
        static let basePollInterval = "poll.baseInterval"
        static let activePollInterval = "poll.activeInterval"
        static let batteryPollInterval = "poll.batteryInterval"
        static let apiPageSize = "api.pageSize"
        static let pipelineConcurrency = "api.pipelineConcurrency"
        static let trackPushEvents = "api.trackPushEvents"
        static let showProfileHeader = "ui.showProfileHeader"
        static let sectionOrder = "ui.sectionOrder"
        static let visibleSections = "ui.visibleSections"
        static let notificationsByKind = "notifications.enabledByKind"
        static let statusItemVisible = "ui.statusItemVisible"
        static let launchAtLogin = "app.launchAtLogin"
        static let repositoryScope = "scope.json"
        static let gitLabBaseURL = "account.gitLabBaseURL"
        static let automaticUpdateChecks = "updates.automaticChecks"
    }

    private let defaults: UserDefaults
    private let log = Logger(subsystem: "com.alBz.GitLabAlert", category: "Preferences")

    // Stored privately and exposed through computed properties: the computed
    // getter reads the tracked storage, so Observation still sees the
    // dependency, while the setter keeps clamping and encoding in one place.
    private var storedBasePollInterval: TimeInterval
    private var storedActivePollInterval: TimeInterval
    private var storedBatteryPollInterval: TimeInterval
    private var storedAPIPageSize: Int
    private var storedPipelineConcurrency: Int
    private var storedTrackPushEvents: Bool
    private var storedShowProfileHeader: Bool
    private var storedSectionOrder: [DashboardSection]
    private var storedVisibleSections: Set<DashboardSection>
    private var storedNotificationsByKind: [ActivityKind: Bool]
    private var storedStatusItemVisible: Bool
    private var storedLaunchAtLogin: Bool
    private var storedRepositoryScope: RepositoryScope
    private var storedGitLabBaseURL: String
    private var storedAutomaticUpdateChecks: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let rawInterval = defaults.object(forKey: Key.basePollInterval) as? Double
        storedBasePollInterval = Preferences.clampPollInterval(rawInterval ?? PollScheduler.defaultIdleInterval)
        storedActivePollInterval = Preferences.clampPollInterval(
            defaults.object(forKey: Key.activePollInterval) as? Double ?? PollScheduler.defaultActiveInterval
        )
        storedBatteryPollInterval = Preferences.clampPollInterval(
            defaults.object(forKey: Key.batteryPollInterval) as? Double ?? PollScheduler.defaultBatteryInterval
        )
        storedAPIPageSize = Preferences.clampAPIPageSize(
            defaults.object(forKey: Key.apiPageSize) as? Int ?? DashboardRequestOptions.defaultPageSize
        )
        storedPipelineConcurrency = Preferences.clampPipelineConcurrency(
            defaults.object(forKey: Key.pipelineConcurrency) as? Int ?? DashboardRequestOptions.defaultPipelineConcurrency
        )
        storedTrackPushEvents = defaults.object(forKey: Key.trackPushEvents) as? Bool ?? true
        storedShowProfileHeader = defaults.object(forKey: Key.showProfileHeader) as? Bool ?? true
        storedAutomaticUpdateChecks = defaults.object(forKey: Key.automaticUpdateChecks) as? Bool ?? true
        storedStatusItemVisible = defaults.object(forKey: Key.statusItemVisible) as? Bool ?? true
        storedLaunchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
        storedSectionOrder = Preferences.repairedOrder(defaults.stringArray(forKey: Key.sectionOrder))
        storedVisibleSections = Preferences.repairedVisibility(defaults.stringArray(forKey: Key.visibleSections))
        storedNotificationsByKind = Preferences.repairedNotificationMap(
            defaults.dictionary(forKey: Key.notificationsByKind) as? [String: Bool]
        )
        storedGitLabBaseURL = Preferences.normalizedGitLabBaseURL(
            defaults.string(forKey: Key.gitLabBaseURL) ?? GitLabClient.defaultBaseURL.absoluteString
        )

        // A scope that fails to decode falls back to the shipped default rather
        // than to an empty one: an empty scope would silently stop watching
        // every repository, which looks like the app is broken.
        if let data = defaults.data(forKey: Key.repositoryScope) {
            do {
                storedRepositoryScope = try JSONDecoder().decode(RepositoryScope.self, from: data)
            } catch {
                storedRepositoryScope = .default
                log.error("Stored repository scope is unreadable (\(String(describing: error), privacy: .public)); falling back to the default scope.")
            }
        } else {
            storedRepositoryScope = .default
        }
    }

    // MARK: - Polling

    /// GitLab instance origin. It is applied on the next launch because the
    /// active client owns an immutable, instance-specific transport.
    public var gitLabBaseURL: URL {
        URL(string: storedGitLabBaseURL) ?? GitLabClient.defaultBaseURL
    }

    public var gitLabBaseURLString: String {
        get { storedGitLabBaseURL }
        set {
            let normalized = Preferences.normalizedGitLabBaseURL(newValue)
            storedGitLabBaseURL = normalized
            defaults.set(normalized, forKey: Key.gitLabBaseURL)
        }
    }

    /// Base idle interval in seconds. Always clamped: the scheduler treats this
    /// as a desired value and the rate limiter can only widen it, so a value
    /// under the floor would just mean wasted API budget.
    public var basePollInterval: TimeInterval {
        get { storedBasePollInterval }
        set {
            let clamped = Preferences.clampPollInterval(newValue)
            storedBasePollInterval = clamped
            defaults.set(clamped, forKey: Key.basePollInterval)
        }
    }

    public static func clampPollInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return PollScheduler.defaultIdleInterval }
        return min(max(value, PollScheduler.minimumInterval), PollScheduler.maximumInterval)
    }

    /// How often an open popover is refreshed. This cannot be more aggressive
    /// than the global safety floor enforced by `clampPollInterval`.
    public var activePollInterval: TimeInterval {
        get { storedActivePollInterval }
        set {
            let clamped = Preferences.clampPollInterval(newValue)
            storedActivePollInterval = clamped
            defaults.set(clamped, forKey: Key.activePollInterval)
        }
    }

    /// Desired cadence while on battery or in Low Power Mode. The scheduler
    /// also compares it with the idle interval and chooses the slower value.
    public var batteryPollInterval: TimeInterval {
        get { storedBatteryPollInterval }
        set {
            let clamped = Preferences.clampPollInterval(newValue)
            storedBatteryPollInterval = clamped
            defaults.set(clamped, forKey: Key.batteryPollInterval)
        }
    }

    public var apiPageSize: Int {
        get { storedAPIPageSize }
        set {
            let clamped = Preferences.clampAPIPageSize(newValue)
            storedAPIPageSize = clamped
            defaults.set(clamped, forKey: Key.apiPageSize)
        }
    }

    public var pipelineConcurrency: Int {
        get { storedPipelineConcurrency }
        set {
            let clamped = Preferences.clampPipelineConcurrency(newValue)
            storedPipelineConcurrency = clamped
            defaults.set(clamped, forKey: Key.pipelineConcurrency)
        }
    }

    /// Off means one fewer request per watched repository per cycle. Worth
    /// exposing: on an account watching many projects the events feed is the
    /// most expensive part of a poll.
    public var trackPushEvents: Bool {
        get { storedTrackPushEvents }
        set {
            storedTrackPushEvents = newValue
            defaults.set(newValue, forKey: Key.trackPushEvents)
        }
    }

    public var dashboardRequestOptions: DashboardRequestOptions {
        DashboardRequestOptions(
            pageSize: apiPageSize,
            pipelineConcurrency: pipelineConcurrency,
            includePushEvents: trackPushEvents
        )
    }

    public static func clampAPIPageSize(_ value: Int) -> Int {
        [25, 50, 100].contains(value) ? value : DashboardRequestOptions.defaultPageSize
    }

    public static func clampPipelineConcurrency(_ value: Int) -> Int {
        min(max(value, 1), 8)
    }

    // MARK: - Layout

    /// Whether the app may ask GitHub which release is the latest.
    ///
    /// On by default and switchable off, because it is the one request that
    /// leaves for a host other than the configured GitLab instance. With it off
    /// the app makes no such request at all.
    public var automaticUpdateChecks: Bool {
        get { storedAutomaticUpdateChecks }
        set {
            storedAutomaticUpdateChecks = newValue
            defaults.set(newValue, forKey: Key.automaticUpdateChecks)
        }
    }

    public var showProfileHeader: Bool {
        get { storedShowProfileHeader }
        set {
            storedShowProfileHeader = newValue
            defaults.set(newValue, forKey: Key.showProfileHeader)
        }
    }

    public var statusItemVisible: Bool {
        get { storedStatusItemVisible }
        set {
            storedStatusItemVisible = newValue
            defaults.set(newValue, forKey: Key.statusItemVisible)
        }
    }

    /// Every section, in the user's order. Always contains all cases so a
    /// drag-to-reorder list can bind straight to it.
    public var sectionOrder: [DashboardSection] {
        get { storedSectionOrder }
        set {
            let repaired = Preferences.repairedOrder(newValue.map(\.rawValue))
            storedSectionOrder = repaired
            defaults.set(repaired.map(\.rawValue), forKey: Key.sectionOrder)
        }
    }

    public var visibleSections: Set<DashboardSection> {
        get { storedVisibleSections }
        set {
            storedVisibleSections = newValue
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: Key.visibleSections)
        }
    }

    /// What the popover actually renders, in order.
    public var orderedVisibleSections: [DashboardSection] {
        storedSectionOrder.filter { storedVisibleSections.contains($0) }
    }

    public func isSectionVisible(_ section: DashboardSection) -> Bool {
        storedVisibleSections.contains(section)
    }

    public func setSection(_ section: DashboardSection, visible: Bool) {
        var updated = storedVisibleSections
        if visible { updated.insert(section) } else { updated.remove(section) }
        visibleSections = updated
    }

    /// Moves sections inside `sectionOrder`, matching `List`'s `onMove`.
    public func moveSections(fromOffsets source: IndexSet, toOffset destination: Int) {
        var updated = storedSectionOrder
        updated.move(fromOffsets: source, toOffset: destination)
        sectionOrder = updated
    }

    // MARK: - Notifications

    /// Per-kind mute switches. Unknown keys in the stored map are dropped and a
    /// missing kind falls back to ``ActivityKind/notifiesByDefault``, so adding
    /// an ``ActivityKind`` later does not require a migration.
    public var notificationsByKind: [ActivityKind: Bool] {
        get { storedNotificationsByKind }
        set {
            let repaired = Preferences.repairedNotificationMap(
                Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            )
            storedNotificationsByKind = repaired
            defaults.set(
                Dictionary(uniqueKeysWithValues: repaired.map { ($0.key.rawValue, $0.value) }),
                forKey: Key.notificationsByKind
            )
        }
    }

    public func isNotificationEnabled(_ kind: ActivityKind) -> Bool {
        storedNotificationsByKind[kind] ?? kind.notifiesByDefault
    }

    public func setNotificationEnabled(_ enabled: Bool, for kind: ActivityKind) {
        var updated = storedNotificationsByKind
        updated[kind] = enabled
        notificationsByKind = updated
    }

    public var enabledNotificationKinds: Set<ActivityKind> {
        Set(ActivityKind.allCases.filter { isNotificationEnabled($0) })
    }

    // MARK: - Scope

    public var repositoryScope: RepositoryScope {
        get { storedRepositoryScope }
        set {
            storedRepositoryScope = newValue
            do {
                defaults.set(try JSONEncoder().encode(newValue), forKey: Key.repositoryScope)
            } catch {
                // The in-memory value still took effect; only persistence
                // failed, and the user has to know it will not survive a quit.
                log.error("Could not encode the repository scope (\(String(describing: error), privacy: .public)); the change will not persist.")
            }
        }
    }

    // MARK: - Login item

    /// The user's *intent*. The authority on whether the app actually launches
    /// at login is ``LoginItem/state``; this key only records what was asked
    /// for, so Settings can show a toggle that survives a failed registration.
    public var launchAtLogin: Bool {
        get { storedLaunchAtLogin }
        set {
            storedLaunchAtLogin = newValue
            defaults.set(newValue, forKey: Key.launchAtLogin)
        }
    }

    // MARK: - SwiftUI

    /// Binding onto any writable preference: `prefs.binding(\.showProfileHeader)`.
    public func binding<Value>(_ keyPath: ReferenceWritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0 }
        )
    }

    public func notificationBinding(for kind: ActivityKind) -> Binding<Bool> {
        Binding(
            get: { self.isNotificationEnabled(kind) },
            set: { self.setNotificationEnabled($0, for: kind) }
        )
    }

    public func sectionVisibilityBinding(for section: DashboardSection) -> Binding<Bool> {
        Binding(
            get: { self.isSectionVisible(section) },
            set: { self.setSection(section, visible: $0) }
        )
    }

    // MARK: - Reset

    /// Clears every key this type owns. Used by Settings' "Reset preferences"
    /// and nowhere else — it does not touch the token or the cached snapshot.
    public func resetToDefaults() {
        basePollInterval = PollScheduler.defaultIdleInterval
        activePollInterval = PollScheduler.defaultActiveInterval
        batteryPollInterval = PollScheduler.defaultBatteryInterval
        apiPageSize = DashboardRequestOptions.defaultPageSize
        pipelineConcurrency = DashboardRequestOptions.defaultPipelineConcurrency
        trackPushEvents = true
        showProfileHeader = true
        automaticUpdateChecks = true
        statusItemVisible = true
        launchAtLogin = false
        sectionOrder = DashboardSection.defaultOrder
        visibleSections = Set(DashboardSection.allCases)
        notificationsByKind = [:]
        repositoryScope = .default
        gitLabBaseURLString = GitLabClient.defaultBaseURL.absoluteString
    }

    // MARK: - Repair

    private static func normalizedGitLabBaseURL(_ value: String) -> String {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            var components = URLComponents(string: candidate),
            components.scheme == "https",
            components.host != nil
        else {
            return GitLabClient.defaultBaseURL.absoluteString
        }
        // GitLab's API prefix is rooted at `/api/v4`; installations behind a
        // sub-path are intentionally unsupported until URL construction covers
        // every endpoint consistently.
        components.path = ""
        return components.url?.absoluteString ?? GitLabClient.defaultBaseURL.absoluteString
    }

    /// Unknown raw values are dropped and any case the stored list is missing is
    /// appended in default order, so a build that adds a section shows it.
    private static func repairedOrder(_ raw: [String]?) -> [DashboardSection] {
        let decoded = (raw ?? []).compactMap(DashboardSection.init(rawValue:))
        var seen = Set(decoded)
        var order = decoded
        for section in DashboardSection.defaultOrder where !seen.contains(section) {
            order.append(section)
            seen.insert(section)
        }
        return order
    }

    /// No stored list means "everything visible"; an explicitly empty stored
    /// list is respected, because hiding every section is a legitimate choice.
    private static func repairedVisibility(_ raw: [String]?) -> Set<DashboardSection> {
        guard let raw else { return Set(DashboardSection.allCases) }
        return Set(raw.compactMap(DashboardSection.init(rawValue:)))
    }

    private static func repairedNotificationMap(_ raw: [String: Bool]?) -> [ActivityKind: Bool] {
        guard let raw else { return [:] }
        var map: [ActivityKind: Bool] = [:]
        for (key, value) in raw {
            guard let kind = ActivityKind(rawValue: key) else { continue }
            map[kind] = value
        }
        return map
    }
}
