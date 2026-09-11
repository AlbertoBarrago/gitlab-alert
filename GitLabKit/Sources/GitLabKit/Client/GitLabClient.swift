import Foundation
import os

/// GitLab REST client. `baseURL` is the instance origin, so GitLab.com and
/// self-managed installations use the same implementation.
public struct GitLabClient: GitLabAPI {
    public static let defaultBaseURL = URL(string: "https://gitlab.com")!
    private let http: any HTTPClient
    private let tokenStore: any TokenStore
    private let baseURL: URL
    private let clock: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.alBz.GitLabAlert", category: "client")
    public let rateLimits: RateLimitTracker

    public init(
        httpClient: any HTTPClient,
        tokenStore: any TokenStore,
        rateLimits: RateLimitTracker = RateLimitTracker(),
        baseURL: URL = GitLabClient.defaultBaseURL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = httpClient
        self.tokenStore = tokenStore
        self.rateLimits = rateLimits
        self.baseURL = baseURL
        self.clock = clock
    }

    public func fetchDashboard(scope: RepositoryScope) async throws -> DashboardSnapshot {
        async let profile = fetchProfile()
        async let reviewRequested = fetchMergeRequests(query: ["reviewer_username": "me"])
        async let authored = fetchMergeRequests(query: ["author_username": "me"])
        async let assignedIssues = fetchIssues(query: ["assignee_username": "me"])
        async let projects = fetchProjects(scope: scope)

        let resolvedProfile = try await profile
        let review = try await reviewRequested
        let mine = try await authored
        let issues = try await assignedIssues
        let repositories = try await projects

        return DashboardSnapshot(
            fetchedAt: clock(),
            profile: resolvedProfile,
            reviewRequested: merge(review, relevance: .reviewRequested),
            authoredMergeRequests: merge(mine, relevance: .authored),
            assignedIssues: issues,
            repositories: repositories,
            rateLimit: await rateLimits.status
        )
    }

    public func verifyToken() async throws -> Profile { try await fetchProfile() }

    private func fetchProfile() async throws -> Profile {
        let user: UserPayload = try await get("user")
        return Profile(login: user.username, name: user.name, avatarURL: user.avatarURL, url: user.webURL ?? baseURL)
    }

    private func fetchMergeRequests(query: [String: String]) async throws -> [MergeRequestItem] {
        let payload: [MergeRequestPayload] = try await get("merge_requests", query: query.merging(["state": "opened", "scope": "all", "per_page": "100"], uniquingKeysWith: { current, _ in current }))
        return payload.map(\.model)
    }

    private func fetchIssues(query: [String: String]) async throws -> [IssueItem] {
        let payload: [IssuePayload] = try await get("issues", query: query.merging(["state": "opened", "scope": "all", "per_page": "100"], uniquingKeysWith: { current, _ in current }))
        return payload.map(\.model)
    }

    private func fetchProjects(scope: RepositoryScope) async throws -> [RepoSnapshot] {
        guard scope.includeOwned else { return [] }
        let payload: [ProjectPayload] = try await get("projects", query: ["membership": "true", "simple": "true", "order_by": "last_activity_at", "sort": "desc", "per_page": "100"])
        let projects = payload.filter { project in
            guard let snapshot = project.model else { return false }
            return !scope.filter([snapshot], now: clock()).isEmpty
        }
        return try await withThrowingTaskGroup(of: RepoSnapshot.self) { group in
            for project in projects {
                group.addTask { try await project.snapshot(pipelineState: self.fetchLatestPipeline(projectID: project.id)) }
            }
            var snapshots: [RepoSnapshot] = []
            for try await snapshot in group { snapshots.append(snapshot) }
            return snapshots.sorted { $0.nameWithOwner.localizedCaseInsensitiveCompare($1.nameWithOwner) == .orderedAscending }
        }
    }

    private func fetchLatestPipeline(projectID: Int) async throws -> CheckState {
        let pipelines: [PipelinePayload] = try await get("projects/\(projectID)/pipelines", query: ["per_page": "1", "order_by": "updated_at", "sort": "desc"])
        return CheckState(gitLabPipelineStatus: pipelines.first?.status)
    }

    private func merge(_ items: [MergeRequestItem], relevance: MergeRequestRelevance) -> [MergeRequestItem] {
        items.map {
            var item = $0
            item.relevance.insert(relevance)
            return item
        }
    }

    private func get<Payload: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> Payload {
        let token: String
        do {
            guard let stored = try tokenStore.readToken(), !stored.isEmpty else { throw GitLabError.notAuthenticated }
            token = stored
        } catch let error as GitLabError {
            throw error
        } catch {
            throw GitLabError.transport("Token store unavailable: \(error.localizedDescription)")
        }
        guard var components = URLComponents(url: baseURL.appending(path: "/api/v4/\(path)"), resolvingAgainstBaseURL: false) else {
            throw GitLabError.transport("Invalid GitLab instance URL")
        }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw GitLabError.transport("Invalid GitLab request URL") }

        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GitLabAlert/\(GitLabKit.version)", forHTTPHeaderField: "User-Agent")

        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch let error as GitLabError {
            await rateLimits.note(error: error, now: clock())
            logger.error("GitLab request failed path=\(path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        } catch {
            let mapped = GitLabError.transport(error.localizedDescription)
            await rateLimits.note(error: mapped, now: clock())
            logger.error("GitLab request failed path=\(path, privacy: .public) error=\(mapped.localizedDescription, privacy: .public)")
            throw mapped
        }
        logger.info("GitLab request completed path=\(path, privacy: .public) status=\(response.status, privacy: .public)")
        await rateLimits.ingest(headers: RateLimitHeaders(response: response))
        guard response.isSuccess else {
            let error = classify(response)
            await rateLimits.note(error: error, now: clock())
            throw error
        }
        await rateLimits.noteSuccess(now: clock())
        do {
            return try JSONDecoder.gitLab.decode(Payload.self, from: response.body)
        } catch {
            logger.error("Could not decode GitLab response: \(error.localizedDescription, privacy: .public)")
            throw GitLabError.decoding(error.localizedDescription)
        }
    }

    private func classify(_ response: HTTPResponse) -> GitLabError {
        let message = (try? JSONDecoder().decode(APIErrorPayload.self, from: response.body))?.message ?? "Request failed"
        switch response.status {
        case 401: return .badCredentials
        case 403: return .forbidden(message: message)
        case 429: return .rateLimited(retryAfter: Double(response.header("Retry-After") ?? ""), resetAt: nil)
        default: return .http(status: response.status, message: message)
        }
    }
}

private extension JSONDecoder {
    static let gitLab: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try GitLabDate.decode(from: $0) }
        return decoder
    }()
}

private enum GitLabDate {
    static func decode(from container: Decoder) throws -> Date {
        let valueContainer = try container.singleValueContainer()
        let value = try valueContainer.decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        throw DecodingError.dataCorruptedError(in: valueContainer, debugDescription: "Invalid GitLab timestamp: \(value)")
    }
}

private struct APIErrorPayload: Decodable {
    let message: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .message) {
            message = value
        } else if let values = try? container.decode([String].self, forKey: .message) {
            message = values.joined(separator: ", ")
        } else {
            message = nil
        }
    }

    private enum CodingKeys: String, CodingKey { case message }
}
private struct UserPayload: Decodable {
    let username: String; let name: String?; let avatarURL: URL?; let webURL: URL?
    enum CodingKeys: String, CodingKey { case username, name; case avatarURL = "avatar_url"; case webURL = "web_url" }
}
private struct ActorPayload: Decodable {
    let username: String; let avatarURL: URL?
    enum CodingKeys: String, CodingKey { case username; case avatarURL = "avatar_url" }
    var model: GLActor { GLActor(login: username, avatarURL: avatarURL) }
}
private struct MergeRequestPayload: Decodable {
    let id: Int; let iid: Int; let title: String; let references: References; let author: ActorPayload?; let webURL: URL; let createdAt: Date; let updatedAt: Date; let draft: Bool; let detailedMergeStatus: String?; let userNotesCount: Int
    enum CodingKeys: String, CodingKey { case id, iid, title, references, author, draft; case webURL = "web_url"; case createdAt = "created_at"; case updatedAt = "updated_at"; case detailedMergeStatus = "detailed_merge_status"; case userNotesCount = "user_notes_count" }
    struct References: Decodable { let full: String }
    var model: MergeRequestItem { MergeRequestItem(id: String(id), number: iid, title: title, repository: references.full.split(separator: "!").first.map(String.init) ?? "Unknown", author: author?.model, url: webURL, createdAt: createdAt, updatedAt: updatedAt, isDraft: draft, checkState: CheckState(gitLabMergeStatus: detailedMergeStatus), commentCount: userNotesCount) }
}
private struct IssuePayload: Decodable {
    let id: Int; let iid: Int; let title: String; let references: References; let author: ActorPayload?; let webURL: URL; let createdAt: Date; let updatedAt: Date; let userNotesCount: Int; let labels: [String]
    enum CodingKeys: String, CodingKey { case id, iid, title, references, author, labels; case webURL = "web_url"; case createdAt = "created_at"; case updatedAt = "updated_at"; case userNotesCount = "user_notes_count" }
    struct References: Decodable { let full: String }
    var model: IssueItem { IssueItem(id: String(id), number: iid, title: title, repository: references.full.split(separator: "#").first.map(String.init) ?? "Unknown", author: author?.model, url: webURL, createdAt: createdAt, updatedAt: updatedAt, commentCount: userNotesCount, labels: labels) }
}
private struct ProjectPayload: Decodable {
    let id: Int; let pathWithNamespace: String; let visibility: String; let openIssuesCount: Int; let defaultBranch: String?; let lastActivityAt: Date?; let webURL: URL
    enum CodingKeys: String, CodingKey { case id, visibility; case pathWithNamespace = "path_with_namespace"; case openIssuesCount = "open_issues_count"; case defaultBranch = "default_branch"; case lastActivityAt = "last_activity_at"; case webURL = "web_url" }
    var model: RepoSnapshot? { RepoSnapshot(nameWithOwner: pathWithNamespace, isPrivate: visibility != "public", openIssueCount: openIssuesCount, defaultBranch: defaultBranch, pushedAt: lastActivityAt, url: webURL) }
    func snapshot(pipelineState: CheckState) -> RepoSnapshot {
        var snapshot = model!
        snapshot.checkState = pipelineState
        return snapshot
    }
}

private struct PipelinePayload: Decodable { let status: String }

private extension RateLimitTracker {
    func note(error: GitLabError, now: Date) {
        switch error {
        case .rateLimited(let retryAfter, let resetAt):
            noteRateLimited(retryAfter: retryAfter, resetAt: resetAt, secondary: false, now: now)
        case .transport:
            noteTransientFailure(now: now)
        case .http(let status, _) where status >= 500:
            noteTransientFailure(now: now)
        default:
            break
        }
    }
}
