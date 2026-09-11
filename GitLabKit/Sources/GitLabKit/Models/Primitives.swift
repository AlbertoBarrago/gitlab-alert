import Foundation

/// A GitLab user as it appears attached to some activity (star, fork, MR author).
public struct GLActor: Sendable, Codable, Hashable, Identifiable {
    public var login: String
    public var avatarURL: URL?

    public var id: String { login }

    public init(login: String, avatarURL: URL? = nil) {
        self.login = login
        self.avatarURL = avatarURL
    }
}

/// Rolled-up state of the checks on a commit.
public enum CheckState: String, Sendable, Codable, Hashable, CaseIterable {
    case success
    case failure
    case pending
    case error
    case expected
    case unknown

    /// Whether this state should draw the user's attention.
    public var isBroken: Bool { self == .failure || self == .error }

    /// Maps the GraphQL `StatusState` enum, which is uppercase.
    public init(graphQL raw: String?) {
        switch raw?.uppercased() {
        case "SUCCESS": self = .success
        case "FAILURE": self = .failure
        case "PENDING": self = .pending
        case "ERROR": self = .error
        case "EXPECTED": self = .expected
        default: self = .unknown
        }
    }

    /// Maps GitLab's detailed merge status into the state displayed by the UI.
    public init(gitLabMergeStatus raw: String?) {
        switch raw?.uppercased() {
        case "CI_MUST_PASS", "CHECKING", "PREPARING": self = .pending
        case "BROKEN_STATUS", "CONFLICTING": self = .failure
        case "MERGEABLE": self = .success
        default: self = .unknown
        }
    }

    public init(gitLabPipelineStatus raw: String?) {
        switch raw?.lowercased() {
        case "success": self = .success
        case "failed": self = .failure
        case "canceled": self = .error
        case "created", "waiting_for_resource", "preparing", "pending", "running": self = .pending
        default: self = .unknown
        }
    }
}

/// GraphQL `MergeRequestReviewDecision`, plus a case for "no decision yet".
public enum ReviewDecision: String, Sendable, Codable, Hashable {
    case approved
    case changesRequested
    case reviewRequired
    case none

    public init(graphQL raw: String?) {
        switch raw?.uppercased() {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "REVIEW_REQUIRED": self = .reviewRequired
        default: self = .none
        }
    }
}

/// Why a merge request is in the user's list. A single MR can be relevant for
/// more than one reason, so this is a set rather than a single value.
public struct MergeRequestRelevance: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let authored = MergeRequestRelevance(rawValue: 1 << 0)
    public static let reviewRequested = MergeRequestRelevance(rawValue: 1 << 1)
    public static let assigned = MergeRequestRelevance(rawValue: 1 << 2)
}

/// Remaining GitLab API budget, read from the response headers or `rateLimit`.
public struct RateLimitStatus: Sendable, Codable, Hashable {
    public var remaining: Int
    public var limit: Int
    public var resetAt: Date

    public init(remaining: Int, limit: Int, resetAt: Date) {
        self.remaining = remaining
        self.limit = limit
        self.resetAt = resetAt
    }

    /// Fraction of the budget still available, in `0...1`.
    public var fraction: Double {
        guard limit > 0 else { return 1 }
        return max(0, min(1, Double(remaining) / Double(limit)))
    }

    /// True when we should start widening the poll interval.
    public var isRunningLow: Bool { fraction < 0.15 }
}
