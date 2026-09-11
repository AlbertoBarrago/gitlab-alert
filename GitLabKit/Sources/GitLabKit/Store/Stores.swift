import Foundation

/// Where the GitLab token lives. The only implementation writes to the
/// Keychain; the protocol exists so tests never touch the real keychain.
public protocol TokenStore: Sendable {
    func readToken() throws -> String?
    func writeToken(_ token: String) throws
    func deleteToken() throws
}

/// Per-repository high-water mark: what we had last time we looked.
///
/// Counts alone cannot carry the whole story — a star followed by an unstar
/// leaves the count unchanged, and a re-run with the same data must not
/// re-notify. So we keep both the counts and the newest timestamp we have
/// already reported, and the rule is: notify only when a record's timestamp is
/// **strictly greater** than the watermark. Equality is the duplicate-notification bug.
public struct RepoWatermark: Sendable, Codable, Hashable {
    public var stargazerCount: Int
    public var forkCount: Int
    public var newestStarredAt: Date?
    public var newestForkedAt: Date?
    public var lastCheckState: CheckState
    /// When this repository entered the watch set. A repository is never
    /// notified about on the cycle it is first seen.
    public var firstSeenAt: Date

    public init(
        stargazerCount: Int = 0,
        forkCount: Int = 0,
        newestStarredAt: Date? = nil,
        newestForkedAt: Date? = nil,
        lastCheckState: CheckState = .unknown,
        firstSeenAt: Date
    ) {
        self.stargazerCount = stargazerCount
        self.forkCount = forkCount
        self.newestStarredAt = newestStarredAt
        self.newestForkedAt = newestForkedAt
        self.lastCheckState = lastCheckState
        self.firstSeenAt = firstSeenAt
    }

    /// Builds the initial watermark for a newly discovered repository.
    public init(seeding repo: RepoSnapshot, at date: Date) {
        self.init(
            stargazerCount: repo.stargazerCount,
            forkCount: repo.forkCount,
            newestStarredAt: nil,
            newestForkedAt: nil,
            lastCheckState: repo.checkState,
            firstSeenAt: date
        )
    }
}

/// Everything the app has to remember between launches so that a restart does
/// not re-notify about events the user already saw.
public struct PersistedState: Sendable, Codable, Hashable {
    /// Schema version: bump on any breaking change and migrate, never crash.
    public static let currentVersion = 1
    public var version: Int
    /// Last successful snapshot: the diff baseline, and the offline view.
    public var lastSnapshot: DashboardSnapshot?
    /// Per-repository watermarks, keyed by `owner/name`.
    public var watermarks: [String: RepoWatermark]
    /// Recent events, newest first, capped by the store.
    public var activityLog: [ActivityEvent]
    /// Event ids the user has already seen in the popover.
    public var seenEventIDs: Set<String>
    /// False until the first successful poll established a baseline. While it
    /// is false, the diff engine emits nothing.
    public var hasBaseline: Bool

    public init(
        version: Int = PersistedState.currentVersion,
        lastSnapshot: DashboardSnapshot? = nil,
        watermarks: [String: RepoWatermark] = [:],
        activityLog: [ActivityEvent] = [],
        seenEventIDs: Set<String> = [],
        hasBaseline: Bool = false
    ) {
        self.version = version
        self.lastSnapshot = lastSnapshot
        self.watermarks = watermarks
        self.activityLog = activityLog
        self.seenEventIDs = seenEventIDs
        self.hasBaseline = hasBaseline
    }
}

/// Persistence for ``PersistedState``.
///
/// `load()` must never throw: on a corrupt, truncated or future-schema file it
/// returns an empty state so the app still launches — with `hasBaseline` false,
/// which means the next poll re-seeds silently instead of notifying about
/// everything at once.
public protocol StateStore: Sendable {
    func load() -> PersistedState
    func save(_ state: PersistedState) throws
}
