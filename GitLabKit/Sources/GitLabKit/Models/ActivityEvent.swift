import Foundation

public enum ActivityKind: String, Sendable, Codable, Hashable, CaseIterable {
    case checksFailed
    case checksRecovered
    case reviewRequested
    case inboundIssue
    case inboundMergeRequest

    public var isMutable: Bool { true }

    public static var allCases: [ActivityKind] {
        [.checksFailed, .checksRecovered, .reviewRequested, .inboundIssue, .inboundMergeRequest]
    }
}

public struct ActivityEvent: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var kind: ActivityKind
    public var occurredAt: Date
    public var repository: String
    /// Reserved for grouped activity rows. Current GitLab events always use 1.
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
