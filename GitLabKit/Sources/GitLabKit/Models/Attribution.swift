import Foundation

/// A single star, with who and when.
public struct StarRecord: Sendable, Codable, Hashable {
    public var actor: GLActor
    public var starredAt: Date

    public init(actor: GLActor, starredAt: Date) {
        self.actor = actor
        self.starredAt = starredAt
    }
}

/// A single fork, with who, when, and where it landed.
public struct ForkRecord: Sendable, Codable, Hashable {
    public var actor: GLActor
    public var createdAt: Date
    /// The new fork's own `owner/name`.
    public var nameWithOwner: String

    public init(actor: GLActor, createdAt: Date, nameWithOwner: String) {
        self.actor = actor
        self.createdAt = createdAt
        self.nameWithOwner = nameWithOwner
    }
}

/// Who recently starred or forked one repository.
///
/// Fetched via GraphQL — `stargazers(last:)` ordered by `STARRED_AT` and
/// `forks(first:)` ordered by `CREATED_AT` — so several repositories can be
/// asked about in a single request, and the answer is not subject to the
/// five-minute cache that makes the REST events endpoint lag.
public struct RepoAttribution: Sendable, Codable, Hashable {
    public var stars: [StarRecord]
    public var forks: [ForkRecord]

    public init(stars: [StarRecord] = [], forks: [ForkRecord] = []) {
        self.stars = stars
        self.forks = forks
    }

    /// Most recent star timestamp present in this batch.
    public var newestStarredAt: Date? { stars.map(\.starredAt).max() }
    /// Most recent fork timestamp present in this batch.
    public var newestForkedAt: Date? { forks.map(\.createdAt).max() }
}
