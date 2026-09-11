import Foundation

/// Every failure the data layer can surface. Deliberately exhaustive and
/// `Equatable` so the UI can switch on it and tests can assert on it — no
/// stringly-typed error handling, no silent catches.
public enum GitLabError: Error, Sendable, Equatable {
    /// No token stored yet: the app should show onboarding, not an error.
    case notAuthenticated
    /// Token rejected (401): revoked, expired, or mistyped.
    case badCredentials
    /// Primary or secondary rate limit hit.
    case rateLimited(retryAfter: TimeInterval?, resetAt: Date?)
    /// 403 that is not a rate limit — usually a missing scope.
    case forbidden(message: String)
    /// Any other non-2xx response.
    case http(status: Int, message: String)
    /// The GraphQL endpoint answered 200 with an `errors` array.
    case graphQL(messages: [String])
    /// The payload did not match the expected shape.
    case decoding(String)
    /// URLSession-level failure: offline, DNS, TLS.
    case transport(String)

    /// Whether retrying the same request later could plausibly succeed.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .transport:
            return true
        case .http(let status, _):
            return status >= 500
        case .notAuthenticated, .badCredentials, .forbidden, .graphQL, .decoding:
            return false
        }
    }

    /// Short, human-readable line for the popover's error state.
    public var userMessage: String {
        switch self {
        case .notAuthenticated:
            return "Add a GitLab token in Settings to get started."
        case .badCredentials:
            return "GitLab rejected the token. Check it in Settings."
        case .rateLimited:
            return "Rate limited by GitLab. Backing off."
        case .forbidden(let message):
            return "Access denied: \(message)"
        case .http(let status, _) where status >= 500:
            return "GitLab is temporarily unavailable (\(status)). Try again shortly."
        case .http(let status, let message):
            return "GitLab returned \(status): \(message)"
        case .graphQL(let messages):
            return messages.first ?? "GitLab returned a GraphQL error."
        case .decoding:
            return "Unexpected response from GitLab."
        case .transport:
            return "Can't reach GitLab. Showing the last known data."
        }
    }
}
