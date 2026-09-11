import Foundation

/// What kind of change the diff engine detected between two snapshots.
public enum ActivityKind: String, Sendable, Codable, Hashable, CaseIterable {
    case star
    case fork
    case checksFailed
    case checksRecovered
    case reviewRequested
    case inboundIssue
    case inboundMergeRequest

    /// Whether this kind can be individually muted in Settings.
    public var isMutable: Bool { true }
}

/// One detected change, ready to be both rendered in the popover and turned
/// into a user notification.
///
/// The shape is deliberately flat rather than an enum with payloads: it stays
/// trivially `Codable` for the on-disk activity log, and the UI can render any
/// event with one row type.
public struct ActivityEvent: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var kind: ActivityKind
    public var occurredAt: Date
    /// `owner/name` the event happened on.
    public var repository: String
    /// How many stars/forks arrived. Always `1` for the non-counting kinds.
    public var delta: Int
    /// Who did it. Empty until REST event enrichment catches up — the count is
    /// known immediately, the attribution can lag by minutes.
    public var actors: [GLActor]
    /// MR/issue title, when the event refers to one.
    public var title: String?
    public var url: URL?

    public init(
        id: String,
        kind: ActivityKind,
        occurredAt: Date,
        repository: String,
        delta: Int = 1,
        actors: [GLActor] = [],
        title: String? = nil,
        url: URL? = nil
    ) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.repository = repository
        self.delta = delta
        self.actors = actors
        self.title = title
        self.url = url
    }

    /// True when we still owe this event an author lookup.
    public var needsAttribution: Bool {
        (kind == .star || kind == .fork) && actors.isEmpty
    }
}
