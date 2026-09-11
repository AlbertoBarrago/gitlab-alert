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

    public init(lastCheckState: CheckState = .unknown, firstSeenAt: Date) {
        self.lastCheckState = lastCheckState
        self.firstSeenAt = firstSeenAt
    }

    public init(seeding repo: RepoSnapshot, at date: Date) {
        self.init(lastCheckState: repo.checkState, firstSeenAt: date)
    }
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
