import Foundation

/// How the diff engine should treat the comparison it is about to run.
public enum DiffMode: Sendable, Hashable {
    /// First run for this scope: record watermarks, emit nothing. This is what
    /// stops a fresh install from firing one notification per historical star.
    case baselineOnly
    /// Normal operation: compare against the watermarks and report.
    case compare
}

/// Everything the diff needs, gathered by the caller.
public struct DiffInput: Sendable {
    public var previousSnapshot: DashboardSnapshot?
    public var currentSnapshot: DashboardSnapshot
    public var watermarks: [String: RepoWatermark]
    /// Attribution for the changed repositories, keyed by `owner/name`. May be
    /// empty: the engine must still produce correct count-only events.
    public var attribution: [String: RepoAttribution]
    public var mode: DiffMode
    public var now: Date
    /// Above this many events for one repository in one cycle, collapse to a
    /// single summary event — a repo hitting the front page should not produce
    /// four hundred notifications.
    public var maxEventsPerRepo: Int

    public init(
        previousSnapshot: DashboardSnapshot?,
        currentSnapshot: DashboardSnapshot,
        watermarks: [String: RepoWatermark] = [:],
        attribution: [String: RepoAttribution] = [:],
        mode: DiffMode = .compare,
        now: Date = Date(),
        maxEventsPerRepo: Int = 5
    ) {
        self.previousSnapshot = previousSnapshot
        self.currentSnapshot = currentSnapshot
        self.watermarks = watermarks
        self.attribution = attribution
        self.mode = mode
        self.now = now
        self.maxEventsPerRepo = maxEventsPerRepo
    }
}

/// What one diff produced: the events to show and notify, and the watermarks to
/// persist. Returning both together is deliberate — a torn write between
/// "event recorded" and "watermark advanced" is exactly the duplicate
/// notification bug, so they are one value and one save.
public struct DiffResult: Sendable, Hashable {
    public var events: [ActivityEvent]
    public var watermarks: [String: RepoWatermark]

    public init(events: [ActivityEvent] = [], watermarks: [String: RepoWatermark] = [:]) {
        self.events = events
        self.watermarks = watermarks
    }
}

/// The pure function at the heart of the app: snapshots in, events out.
///
/// No networking, no notifications, no clock of its own — which is exactly why
/// it is the part that gets thorough unit tests.
public protocol ActivityDiffing: Sendable {
    /// Which repositories moved, so the caller knows what to ask attribution
    /// for. Cheap, count-only, no allocation of events.
    func changedRepositories(
        watermarks: [String: RepoWatermark],
        current: DashboardSnapshot
    ) -> [String]

    func diff(_ input: DiffInput) -> DiffResult
}
