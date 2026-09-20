import Foundation

/// A dotted version, compared the way releases are ordered rather than the way
/// strings are: `0.1.10` comes after `0.1.9`, which a string comparison gets
/// backwards.
public struct ReleaseVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let components: [Int]
    public let description: String

    /// Accepts `1.2.3` and `v1.2.3`, with any number of components. Anything
    /// that is not a run of dotted integers is refused rather than guessed at:
    /// a version this app cannot parse must never be announced as an update.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let parts = withoutPrefix.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var components: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            components.append(value)
        }
        self.components = components
        self.description = withoutPrefix
    }

    /// Equality follows the ordering rather than the stored text: `1.2` and
    /// `1.2.0` are the same release, so the synthesized `==` — which would
    /// compare the raw strings and disagree with `<` — is replaced.
    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var normalized = components
        while normalized.count > 1, normalized.last == 0 { normalized.removeLast() }
        hasher.combine(normalized)
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        // Missing components read as zero, so 1.2 and 1.2.0 are the same release.
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// What a check found.
public struct ReleaseCheck: Sendable, Hashable {
    public var latest: ReleaseVersion
    public var current: ReleaseVersion
    public var releaseURL: URL
    public var publishedAt: Date?
    public var checkedAt: Date

    public var isUpdateAvailable: Bool { current < latest }

    public init(latest: ReleaseVersion, current: ReleaseVersion, releaseURL: URL, publishedAt: Date? = nil, checkedAt: Date) {
        self.latest = latest
        self.current = current
        self.releaseURL = releaseURL
        self.publishedAt = publishedAt
        self.checkedAt = checkedAt
    }
}

public enum ReleaseCheckError: Error, Sendable, Equatable {
    case transport(String)
    /// The endpoint answered, but not with a release this app can read.
    case unreadable(String)
    case rateLimited
    case unexpectedStatus(Int)
}

/// Asks GitHub which release is the latest one.
///
/// This is the only request the app makes to anything other than the configured
/// GitLab instance, it carries no credential and no identifier, and it happens
/// only while the preference is on. `PRIVACY.md` documents it for exactly that
/// reason.
public struct GitHubReleaseChecker: Sendable {
    public static let defaultRepository = "AlbertoBarrago/gitlab-alert"

    private let http: any HTTPClient
    private let repository: String
    private let userAgent: String

    public init(
        httpClient: any HTTPClient,
        repository: String = GitHubReleaseChecker.defaultRepository,
        userAgent: String = "GitLabAlert/\(GitLabKit.version)"
    ) {
        self.http = httpClient
        self.repository = repository
        self.userAgent = userAgent
    }

    public func check(currentVersion: String, now: Date = Date()) async throws -> ReleaseCheck {
        guard let current = ReleaseVersion(currentVersion) else {
            throw ReleaseCheckError.unreadable("This build's version (\(currentVersion)) is not a dotted version.")
        }
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw ReleaseCheckError.unreadable("The repository name does not form a valid URL.")
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch {
            throw ReleaseCheckError.transport(error.localizedDescription)
        }

        // Unauthenticated calls are rate limited per IP. Being told to slow
        // down is not a failure worth showing the user.
        if response.status == 403 || response.status == 429 {
            throw ReleaseCheckError.rateLimited
        }
        guard response.isSuccess else {
            throw ReleaseCheckError.unexpectedStatus(response.status)
        }

        let payload: LatestReleasePayload
        do {
            payload = try Self.decoder.decode(LatestReleasePayload.self, from: response.body)
        } catch {
            throw ReleaseCheckError.unreadable("The release payload could not be decoded.")
        }
        guard let latest = ReleaseVersion(payload.tagName) else {
            throw ReleaseCheckError.unreadable("Tag \"\(payload.tagName)\" is not a dotted version.")
        }
        guard let releaseURL = URL(string: payload.htmlURL), releaseURL.scheme?.lowercased() == "https" else {
            throw ReleaseCheckError.unreadable("The release URL is missing or not https.")
        }

        return ReleaseCheck(
            latest: latest,
            current: current,
            releaseURL: releaseURL,
            publishedAt: payload.publishedAt,
            checkedAt: now
        )
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private struct LatestReleasePayload: Decodable {
        let tagName: String
        let htmlURL: String
        let publishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
        }
    }
}
