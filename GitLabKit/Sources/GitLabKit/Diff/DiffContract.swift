import Foundation

public enum DiffMode: Sendable, Hashable { case baselineOnly, compare }

public struct DiffInput: Sendable {
    public var previousSnapshot: DashboardSnapshot?
    public var currentSnapshot: DashboardSnapshot
    public var watermarks: [String: RepoWatermark]
    public var mode: DiffMode
    public var now: Date

    public init(previousSnapshot: DashboardSnapshot?, currentSnapshot: DashboardSnapshot, watermarks: [String: RepoWatermark] = [:], mode: DiffMode = .compare, now: Date = Date()) {
        self.previousSnapshot = previousSnapshot
        self.currentSnapshot = currentSnapshot
        self.watermarks = watermarks
        self.mode = mode
        self.now = now
    }
}

public struct DiffResult: Sendable, Hashable {
    public var events: [ActivityEvent]
    public var watermarks: [String: RepoWatermark]
    public init(events: [ActivityEvent] = [], watermarks: [String: RepoWatermark] = [:]) { self.events = events; self.watermarks = watermarks }
}

public protocol ActivityDiffing: Sendable { func diff(_ input: DiffInput) -> DiffResult }
