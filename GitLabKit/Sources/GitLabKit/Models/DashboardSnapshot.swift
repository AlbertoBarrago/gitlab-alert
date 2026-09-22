import Foundation

/// Everything one poll cycle produces. This is the single value the app renders
/// and the single value the diff engine compares against the previous cycle.
public struct DashboardSnapshot: Sendable, Codable, Hashable {
    public var fetchedAt: Date
    public var profile: Profile
    public var reviewRequested: [MergeRequestItem]
    public var authoredMergeRequests: [MergeRequestItem]
    public var assignedIssues: [IssueItem]
    public var inboundIssues: [IssueItem]
    public var repositories: [RepoSnapshot]
    public var pushEvents: [PushEvent]
    public var rateLimit: RateLimitStatus?

    public init(
        fetchedAt: Date,
        profile: Profile,
        reviewRequested: [MergeRequestItem] = [],
        authoredMergeRequests: [MergeRequestItem] = [],
        assignedIssues: [IssueItem] = [],
        inboundIssues: [IssueItem] = [],
        repositories: [RepoSnapshot] = [],
        pushEvents: [PushEvent] = [],
        rateLimit: RateLimitStatus? = nil
    ) {
        self.fetchedAt = fetchedAt
        self.profile = profile
        self.reviewRequested = reviewRequested
        self.authoredMergeRequests = authoredMergeRequests
        self.assignedIssues = assignedIssues
        self.inboundIssues = inboundIssues
        self.repositories = repositories
        self.pushEvents = pushEvents
        self.rateLimit = rateLimit
    }

    /// Hand-written so a state file written before `pushEvents` existed still
    /// decodes. `FileStateStore.load()` discards the whole file on a decoding
    /// error, so a synthesised initializer would silently cost the user their
    /// activity log and baseline on the first launch after an update.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        profile = try container.decode(Profile.self, forKey: .profile)
        reviewRequested = try container.decodeIfPresent([MergeRequestItem].self, forKey: .reviewRequested) ?? []
        authoredMergeRequests = try container.decodeIfPresent([MergeRequestItem].self, forKey: .authoredMergeRequests) ?? []
        assignedIssues = try container.decodeIfPresent([IssueItem].self, forKey: .assignedIssues) ?? []
        inboundIssues = try container.decodeIfPresent([IssueItem].self, forKey: .inboundIssues) ?? []
        repositories = try container.decodeIfPresent([RepoSnapshot].self, forKey: .repositories) ?? []
        pushEvents = try container.decodeIfPresent([PushEvent].self, forKey: .pushEvents) ?? []
        rateLimit = try container.decodeIfPresent(RateLimitStatus.self, forKey: .rateLimit)
    }

    /// Repositories whose default branch is currently red.
    public var brokenRepositories: [RepoSnapshot] {
        repositories.filter { $0.checkState.isBroken }
    }

    /// The number the status item badge shows: things actually waiting on the user.
    public var actionableCount: Int {
        reviewRequested.count + assignedIssues.count + brokenRepositories.count
    }

}

public extension RepoSnapshot {
    /// Identifies one continuous broken state. The scheduler removes this key
    /// after recovery, so a later failure becomes unread again.
    var repositoryAlertID: String {
        "repository-alert|\(nameWithOwner)|\(checkState.rawValue)"
    }
}
