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
    public var rateLimit: RateLimitStatus?

    public init(
        fetchedAt: Date,
        profile: Profile,
        reviewRequested: [MergeRequestItem] = [],
        authoredMergeRequests: [MergeRequestItem] = [],
        assignedIssues: [IssueItem] = [],
        inboundIssues: [IssueItem] = [],
        repositories: [RepoSnapshot] = [],
        rateLimit: RateLimitStatus? = nil
    ) {
        self.fetchedAt = fetchedAt
        self.profile = profile
        self.reviewRequested = reviewRequested
        self.authoredMergeRequests = authoredMergeRequests
        self.assignedIssues = assignedIssues
        self.inboundIssues = inboundIssues
        self.repositories = repositories
        self.rateLimit = rateLimit
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
