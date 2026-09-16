import Foundation
import Testing
@testable import GitLabKit

@Test func verifyTokenUsesTheConfiguredGitLabInstance() async throws {
    let baseURL = try #require(URL(string: "https://gitlab.example.com"))
    let userURL = try #require(URL(string: "https://gitlab.example.com/api/v4/user"))
    let response = HTTPResponse(
        status: 200,
        body: Data("""
        {"username":"alberto","name":"Alberto Barrago","avatar_url":"https://gitlab.example.com/avatar.png","web_url":"https://gitlab.example.com/alberto"}
        """.utf8)
    )
    let http = StubHTTPClient(responses: [response])
    let client = GitLabClient(httpClient: http, tokenStore: StaticTokenStore(token: "glpat-secret"), baseURL: baseURL)

    let profile = try await client.verifyToken()

    #expect(profile.login == "alberto")
    let request = try #require((await http.requests()).first)
    #expect(request.url == userURL)
    #expect(request.header("PRIVATE-TOKEN") == "glpat-secret")
}

@Test func dashboardFetchesEveryProjectPage() async throws {
    let http = PaginatedDashboardHTTPClient()
    let client = GitLabClient(httpClient: http, tokenStore: StaticTokenStore(token: "glpat-secret"))

    let snapshot = try await client.fetchDashboard(
        scope: RepositoryScope(activeWithinDays: nil),
        options: DashboardRequestOptions(pageSize: 25, pipelineConcurrency: 1)
    )

    #expect(snapshot.repositories.map(\.nameWithOwner) == ["alice/one", "alice/two"])
    #expect(await http.projectPages == [1, 2])
    #expect(await http.mergeRequestFilters == Set(["reviewer_username", "assignee_username", "author_username"]))
    #expect(await http.invalidMeFilterCount == 0)
    #expect(await http.issueAssignees == ["alice"])
    #expect(snapshot.reviewRequested.map(\.id) == ["42"])
    #expect(snapshot.reviewRequested.first?.relevance.contains(.reviewRequested) == true)
}

@Test func dashboardDecodesStarsAndForkFlagFromTheFullProjectPayload() async throws {
    let http = ProjectDetailHTTPClient()
    let client = GitLabClient(httpClient: http, tokenStore: StaticTokenStore(token: "glpat-secret"))

    let snapshot = try await client.fetchDashboard(
        scope: RepositoryScope(includeForks: true, activeWithinDays: nil),
        options: DashboardRequestOptions(pageSize: 25, pipelineConcurrency: 1)
    )

    // `simple=true` would strip both fields from the response.
    #expect(await http.projectQuery["simple"] == nil)
    let fork = try #require(snapshot.repositories.first { $0.nameWithOwner == "alice/forked" })
    #expect(fork.isFork)
    #expect(fork.stargazerCount == 7)
    let plain = try #require(snapshot.repositories.first { $0.nameWithOwner == "alice/plain" })
    #expect(!plain.isFork)
    #expect(plain.stargazerCount == 3)
}

@Test func dashboardAppliesTheForkRuleBeforeAskingForPipelines() async throws {
    let http = ProjectDetailHTTPClient()
    let client = GitLabClient(httpClient: http, tokenStore: StaticTokenStore(token: "glpat-secret"))

    let snapshot = try await client.fetchDashboard(
        scope: RepositoryScope(includeForks: false, activeWithinDays: nil),
        options: DashboardRequestOptions(pageSize: 25, pipelineConcurrency: 1)
    )

    #expect(snapshot.repositories.map(\.nameWithOwner) == ["alice/plain"])
    #expect(await http.pipelineProjectIDs == [1])
}

@Test func dashboardHonorsPipelineConcurrencyLimit() async throws {
    let http = PipelineConcurrencyHTTPClient(projectCount: 5)
    let client = GitLabClient(httpClient: http, tokenStore: StaticTokenStore(token: "glpat-secret"))

    _ = try await client.fetchDashboard(
        scope: RepositoryScope(activeWithinDays: nil),
        options: DashboardRequestOptions(pageSize: 25, pipelineConcurrency: 2)
    )

    #expect(await http.maximumConcurrentPipelineRequests == 2)
}

@Test func rateLimitBlocksRequestsUntilTheFloorExpires() async throws {
    let http = StubHTTPClient(responses: [])
    let limits = RateLimitTracker()
    await limits.noteRateLimited(retryAfter: 60, resetAt: nil, secondary: false)
    let client = GitLabClient(httpClient: http, tokenStore: StaticTokenStore(token: "glpat-secret"), rateLimits: limits)
    let request = Task { try await client.verifyToken() }

    try await Task.sleep(for: .milliseconds(20))
    #expect(await http.requestCount == 0)
    request.cancel()
    await #expect(throws: CancellationError.self) { try await request.value }
}

private struct StaticTokenStore: TokenStore {
    let token: String
    func readToken() throws -> String? { token }
    func writeToken(_ token: String) throws {}
    func deleteToken() throws {}
}

private actor PaginatedDashboardHTTPClient: HTTPClient {
    private(set) var projectPages: [Int] = []
    private(set) var mergeRequestFilters: Set<String> = []
    private(set) var invalidMeFilterCount = 0
    private(set) var issueAssignees: [String] = []

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let path = components.path
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        switch path {
        case "/api/v4/user":
            return response(#"{"username":"alice","web_url":"https://gitlab.com/alice"}"#)
        case "/api/v4/merge_requests":
            let filters = ["reviewer_username", "assignee_username", "author_username"]
            mergeRequestFilters.formUnion(filters.filter { query[$0] == "alice" })
            invalidMeFilterCount += filters.filter { query[$0] == "me" }.count
            if query["assignee_username"] == "alice" {
                return response(#"[{"id":42,"iid":2,"title":"Assigned work","references":{"full":"alice/one!2"},"web_url":"https://gitlab.com/alice/one/-/merge_requests/2","created_at":"2026-09-16T12:00:00Z","updated_at":"2026-09-16T12:00:00Z","draft":false,"user_notes_count":0}]"#)
            }
            return response("[]")
        case "/api/v4/issues":
            issueAssignees.append(query["assignee_username"] ?? "")
            return response("[]")
        case "/api/v4/projects":
            let page = Int(query["page"] ?? "") ?? 0
            projectPages.append(page)
            if page == 1 {
                return response(#"[{"id":1,"path_with_namespace":"alice/one","visibility":"public","web_url":"https://gitlab.com/alice/one"}]"#, headers: ["X-Next-Page": "2"])
            }
            return response(#"[{"id":2,"path_with_namespace":"alice/two","visibility":"public","web_url":"https://gitlab.com/alice/two"}]"#)
        case "/api/v4/projects/1/pipelines", "/api/v4/projects/2/pipelines":
            return response("[]")
        default:
            throw GitLabError.transport("Unexpected request: \(path)")
        }
    }
}

private actor PipelineConcurrencyHTTPClient: HTTPClient {
    private let projectCount: Int
    private var currentPipelineRequests = 0
    private(set) var maximumConcurrentPipelineRequests = 0

    init(projectCount: Int) { self.projectCount = projectCount }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let path = try #require(request.url?.path)
        switch path {
        case "/api/v4/user":
            return response(#"{"username":"alice","web_url":"https://gitlab.com/alice"}"#)
        case "/api/v4/merge_requests", "/api/v4/issues":
            return response("[]")
        case "/api/v4/projects":
            let projects = (1...projectCount).map {
                "{\"id\":\($0),\"path_with_namespace\":\"alice/repo\($0)\",\"visibility\":\"public\",\"web_url\":\"https://gitlab.com/alice/repo\($0)\"}"
            }.joined(separator: ",")
            return response("[\(projects)]")
        default:
            guard path.hasPrefix("/api/v4/projects/"), path.hasSuffix("/pipelines") else {
                throw GitLabError.transport("Unexpected request: \(path)")
            }
            currentPipelineRequests += 1
            maximumConcurrentPipelineRequests = max(maximumConcurrentPipelineRequests, currentPipelineRequests)
            try await Task.sleep(for: .milliseconds(10))
            currentPipelineRequests -= 1
            return response("[]")
        }
    }
}

private actor ProjectDetailHTTPClient: HTTPClient {
    private(set) var projectQuery: [String: String] = [:]
    private(set) var pipelineProjectIDs: [Int] = []

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let path = components.path

        switch path {
        case "/api/v4/user":
            return response(#"{"username":"alice","web_url":"https://gitlab.com/alice"}"#)
        case "/api/v4/merge_requests", "/api/v4/issues":
            return response("[]")
        case "/api/v4/projects":
            projectQuery = Dictionary(
                (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                uniquingKeysWith: { current, _ in current }
            )
            let plain = #"{"id":1,"path_with_namespace":"alice/plain","visibility":"public","star_count":3,"forks_count":1,"web_url":"https://gitlab.com/alice/plain"}"#
            let forked = #"{"id":2,"path_with_namespace":"alice/forked","visibility":"public","star_count":7,"forked_from_project":{"id":99},"web_url":"https://gitlab.com/alice/forked"}"#
            return response("[\(plain),\(forked)]")
        default:
            guard path.hasPrefix("/api/v4/projects/"), path.hasSuffix("/pipelines"),
                  let id = Int(path.split(separator: "/")[3]) else {
                throw GitLabError.transport("Unexpected request: \(path)")
            }
            pipelineProjectIDs.append(id)
            return response("[]")
        }
    }
}

private func response(_ body: String, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(status: 200, headers: headers, body: Data(body.utf8))
}
