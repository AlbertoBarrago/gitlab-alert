import Foundation

public enum ActivityKind: String, Sendable, Codable, Hashable, CaseIterable {
    case checksFailed
    case checksRecovered
    case reviewRequested
    case inboundIssue
    case inboundMergeRequest
    case pushed

    public var isMutable: Bool { true }

    public static var allCases: [ActivityKind] {
        [.checksFailed, .checksRecovered, .reviewRequested, .inboundIssue, .inboundMergeRequest, .pushed]
    }

    /// Whether a fresh install notifies about this kind. Pushes are the one
    /// high-volume kind: on an active team they would arrive several times an
    /// hour, so they stay in the activity list and off the banners until the
    /// user asks for them.
    public var notifiesByDefault: Bool { self != .pushed }
}

public struct ActivityEvent: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var kind: ActivityKind
    public var occurredAt: Date
    public var repository: String
    /// How many underlying changes the row stands for. Only `.pushed` uses a
    /// value other than 1: it carries the push's commit count.
    public var delta: Int
    public var actors: [GLActor]
    public var title: String?
    public var url: URL?

    public init(id: String, kind: ActivityKind, occurredAt: Date, repository: String, delta: Int = 1, actors: [GLActor] = [], title: String? = nil, url: URL? = nil) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.repository = repository
        self.delta = delta
        self.actors = actors
        self.title = title
        self.url = url
    }
}

public extension ActivityEvent {
    /// The activity row one GitLab push becomes. `delta` carries the commit
    /// count, and `title` the ref, so the row can say "3 commits to main"
    /// without the view knowing anything about GitLab's payload shape.
    init(push: PushEvent) {
        self.init(
            id: "push|\(push.id)",
            kind: .pushed,
            occurredAt: push.occurredAt,
            repository: push.repository,
            delta: max(push.commitCount, 1),
            actors: [push.actor],
            title: push.ref,
            url: push.url
        )
    }
}
