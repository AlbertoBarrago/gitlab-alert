import Foundation

public protocol TokenStore: Sendable {
    func readToken() throws -> String?
    func writeToken(_ token: String) throws
    func deleteToken() throws
}

/// The last pipeline state observed for one project. New projects seed silently.
public struct RepoWatermark: Sendable, Codable, Hashable {
    public var lastCheckState: CheckState
    public var firstSeenAt: Date
    /// Timestamp of the newest push already turned into an activity event.
    /// Optional on purpose: a watermark written before this field existed
    /// decodes with `nil`, which means "no push reported yet" and makes the
    /// first cycle after an update report only pushes newer than `firstSeenAt`.
    public var lastPushEventAt: Date?

    public init(lastCheckState: CheckState = .unknown, firstSeenAt: Date, lastPushEventAt: Date? = nil) {
        self.lastCheckState = lastCheckState
        self.firstSeenAt = firstSeenAt
        self.lastPushEventAt = lastPushEventAt
    }

    public init(seeding repo: RepoSnapshot, at date: Date) {
        self.init(lastCheckState: repo.checkState, firstSeenAt: date, lastPushEventAt: date)
    }

    /// The instant a push must beat to be reported.
    var pushCutoff: Date { lastPushEventAt ?? firstSeenAt }
}

public struct PersistedState: Sendable, Codable, Hashable {
    public static let currentVersion = 2
    public var version: Int
    public var lastSnapshot: DashboardSnapshot?
    public var watermarks: [String: RepoWatermark]
    public var activityLog: [ActivityEvent]
    public var seenEventIDs: Set<String>
    public var hasBaseline: Bool

    public init(version: Int = PersistedState.currentVersion, lastSnapshot: DashboardSnapshot? = nil, watermarks: [String: RepoWatermark] = [:], activityLog: [ActivityEvent] = [], seenEventIDs: Set<String> = [], hasBaseline: Bool = false) {
        self.version = version
        self.lastSnapshot = lastSnapshot
        self.watermarks = watermarks
        self.activityLog = activityLog
        self.seenEventIDs = seenEventIDs
        self.hasBaseline = hasBaseline
    }
}

public protocol StateStore: Sendable {
    func load() -> PersistedState
    func save(_ state: PersistedState) throws
}
