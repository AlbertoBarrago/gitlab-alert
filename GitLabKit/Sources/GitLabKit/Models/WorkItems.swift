import Foundation

/// An open merge request relevant to the user.
public struct MergeRequestItem: Sendable, Codable, Hashable, Identifiable {
    /// GraphQL node id: stable across refetches, safe as a diffing key.
    public var id: String
    public var number: Int
    public var title: String
    /// `owner/name`, the form used everywhere in the UI.
    public var repository: String
    public var author: GLActor?
    public var url: URL

    public var createdAt: Date
    public var updatedAt: Date
    public var isDraft: Bool
    public var reviewDecision: ReviewDecision
    public var checkState: CheckState
    public var relevance: MergeRequestRelevance
    public var commentCount: Int

    public init(
        id: String,
        number: Int,
        title: String,
        repository: String,
        author: GLActor? = nil,
        url: URL,
        createdAt: Date,
        updatedAt: Date,
        isDraft: Bool = false,
        reviewDecision: ReviewDecision = .none,
        checkState: CheckState = .unknown,
        relevance: MergeRequestRelevance = [],
        commentCount: Int = 0
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.repository = repository
        self.author = author
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.checkState = checkState
        self.relevance = relevance
        self.commentCount = commentCount
    }
}

/// An open issue relevant to the user.
public struct IssueItem: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var number: Int
    public var title: String
    public var repository: String
    public var author: GLActor?
    public var url: URL
    public var createdAt: Date
    public var updatedAt: Date
    public var commentCount: Int
    public var labels: [String]
    /// True when the issue lives on a repository the user owns but was opened
    /// by someone else — the case that matters most to a maintainer.
    public var isInbound: Bool

    public init(
        id: String,
        number: Int,
        title: String,
        repository: String,
        author: GLActor? = nil,
        url: URL,
        createdAt: Date,
        updatedAt: Date,
        commentCount: Int = 0,
        labels: [String] = [],
        isInbound: Bool = false
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.repository = repository
        self.author = author
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.commentCount = commentCount
        self.labels = labels
        self.isInbound = isInbound
    }
}

/// Project data rendered in the dashboard.
public struct RepoSnapshot: Sendable, Codable, Hashable, Identifiable {
    /// `owner/name` doubles as the identity.
    public var nameWithOwner: String
    public var isPrivate: Bool
    public var openIssueCount: Int
    public var defaultBranch: String?
    public var headOID: String?
    public var checkState: CheckState
    public var pushedAt: Date?
    public var url: URL
    public var isFork: Bool
    public var stargazerCount: Int
    public var forkCount: Int
    // Kept only for decoding snapshots from the first prototype. The GitLab
    // project payload carries no equivalent, so nothing fills this.
    public var openMergeRequestCount: Int

    public var id: String { nameWithOwner }

    /// `name` without the owner prefix, for compact UI rows.
    public var shortName: String {
        nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner
    }

    public init(
        nameWithOwner: String,
        isPrivate: Bool = false,
        isFork: Bool = false,
        stargazerCount: Int = 0,
        forkCount: Int = 0,
        openIssueCount: Int = 0,
        openMergeRequestCount: Int = 0,
        defaultBranch: String? = nil,
        headOID: String? = nil,
        checkState: CheckState = .unknown,
        pushedAt: Date? = nil,
        url: URL
    ) {
        self.nameWithOwner = nameWithOwner
        self.isPrivate = isPrivate
        self.isFork = isFork
        self.stargazerCount = stargazerCount
        self.forkCount = forkCount
        self.openIssueCount = openIssueCount
        self.openMergeRequestCount = openMergeRequestCount
        self.defaultBranch = defaultBranch
        self.headOID = headOID
        self.checkState = checkState
        self.pushedAt = pushedAt
        self.url = url
    }
}
