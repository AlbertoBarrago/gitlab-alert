import Foundation
import Testing
@testable import GitLabKit

// Pushes by other people: the client reads them from GitLab's events feed, and
// the diff engine decides which of them are new. Both halves are covered here
// because the split is the whole design — GitLab timestamps a push, so nothing
// about it can be derived by comparing two snapshots.

// MARK: - Fixtures

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func repo(_ name: String = "team/service", checkState: CheckState = .success) -> RepoSnapshot {
    RepoSnapshot(
        nameWithOwner: name,
        isPrivate: false,
        isFork: false,
        stargazerCount: 0,
        forkCount: 0,
        openIssueCount: 0,
        defaultBranch: "main",
        pushedAt: epoch,
        url: URL(string: "https://gitlab.com/\(name)")!
    )
}

private func push(
    id: String,
    repository: String = "team/service",
    by login: String = "carla",
    commits: Int = 3,
    at offset: TimeInterval
) -> PushEvent {
    PushEvent(
        id: id,
        repository: repository,
        actor: GLActor(login: login),
        ref: "main",
        commitCount: commits,
        occurredAt: epoch.addingTimeInterval(offset),
        url: URL(string: "https://gitlab.com/\(repository)/-/commits/main")
    )
}

private func snapshot(repositories: [RepoSnapshot], pushEvents: [PushEvent] = []) -> DashboardSnapshot {
    DashboardSnapshot(
        fetchedAt: epoch,
        profile: Profile(login: "alice", name: nil, avatarURL: nil, url: URL(string: "https://gitlab.com/alice")!),
        repositories: repositories,
        pushEvents: pushEvents
    )
}

// MARK: - Diff engine

@Suite("Push activity")
struct PushActivityDiffTests {

    @Test("a push newer than the watermark becomes one activity event")
    func reportsFreshPush() throws {
        let current = snapshot(repositories: [repo()], pushEvents: [push(id: "9", at: 600)])
        let result = ActivityDiffEngine().diff(
            DiffInput(
                previousSnapshot: snapshot(repositories: [repo()]),
                currentSnapshot: current,
                watermarks: ["team/service": RepoWatermark(lastCheckState: .success, firstSeenAt: epoch, lastPushEventAt: epoch)],
                now: epoch.addingTimeInterval(900)
            )
        )

        let event = try #require(result.events.first { $0.kind == .pushed })
        #expect(event.id == "push|9")
        #expect(event.delta == 3)
        #expect(event.title == "main")
        #expect(event.actors.map(\.login) == ["carla"])
        #expect(result.watermarks["team/service"]?.lastPushEventAt == epoch.addingTimeInterval(600))
    }

    @Test("a push at or below the watermark is not reported twice")
    func ignoresAlreadyReportedPush() {
        let alreadySeen = epoch.addingTimeInterval(600)
        let result = ActivityDiffEngine().diff(
            DiffInput(
                previousSnapshot: snapshot(repositories: [repo()]),
                currentSnapshot: snapshot(repositories: [repo()], pushEvents: [push(id: "9", at: 600)]),
                watermarks: ["team/service": RepoWatermark(lastCheckState: .success, firstSeenAt: epoch, lastPushEventAt: alreadySeen)],
                now: epoch.addingTimeInterval(900)
            )
        )

        #expect(result.events.isEmpty)
        #expect(result.watermarks["team/service"]?.lastPushEventAt == alreadySeen)
    }

    @Test("a repository seen for the first time stays silent")
    func newlySeededRepositoryReportsNothing() {
        let result = ActivityDiffEngine().diff(
            DiffInput(
                previousSnapshot: snapshot(repositories: []),
                currentSnapshot: snapshot(repositories: [repo()], pushEvents: [push(id: "9", at: 600)]),
                watermarks: [:],
                now: epoch.addingTimeInterval(900)
            )
        )

        #expect(result.events.isEmpty)
        #expect(result.watermarks["team/service"]?.lastPushEventAt == epoch.addingTimeInterval(900))
    }

    @Test("only the watched repository's own pushes are reported")
    func ignoresPushesFromOtherRepositories() {
        let result = ActivityDiffEngine().diff(
            DiffInput(
                previousSnapshot: snapshot(repositories: [repo()]),
                currentSnapshot: snapshot(
                    repositories: [repo()],
                    pushEvents: [push(id: "9", repository: "team/other", at: 600)]
                ),
                watermarks: ["team/service": RepoWatermark(lastCheckState: .success, firstSeenAt: epoch, lastPushEventAt: epoch)],
                now: epoch.addingTimeInterval(900)
            )
        )

        #expect(result.events.isEmpty)
    }

    @Test("the newest push moves the watermark even when several arrive at once")
    func watermarkFollowsTheNewestPush() {
        let result = ActivityDiffEngine().diff(
            DiffInput(
                previousSnapshot: snapshot(repositories: [repo()]),
                currentSnapshot: snapshot(
                    repositories: [repo()],
                    pushEvents: [push(id: "9", at: 600), push(id: "10", at: 1_200), push(id: "11", at: 300)]
                ),
                watermarks: ["team/service": RepoWatermark(lastCheckState: .success, firstSeenAt: epoch, lastPushEventAt: epoch)],
                now: epoch.addingTimeInterval(1_500)
            )
        )

        #expect(result.events.filter { $0.kind == .pushed }.count == 3)
        #expect(result.watermarks["team/service"]?.lastPushEventAt == epoch.addingTimeInterval(1_200))
    }

    @Test("a watermark written before pushes existed falls back to when the repository was first seen")
    func missingPushWatermarkFallsBackToFirstSeen() {
        let result = ActivityDiffEngine().diff(
            DiffInput(
                previousSnapshot: snapshot(repositories: [repo()]),
                currentSnapshot: snapshot(
                    repositories: [repo()],
                    pushEvents: [push(id: "old", at: -600), push(id: "new", at: 600)]
                ),
                watermarks: ["team/service": RepoWatermark(lastCheckState: .success, firstSeenAt: epoch)],
                now: epoch.addingTimeInterval(900)
            )
        )

        #expect(result.events.map(\.id) == ["push|new"])
    }
}

// MARK: - Client

@Suite("Push events over REST")
struct PushEventRESTTests {

    @Test("the events feed is read per project, filtered to pushes, and the user's own pushes are dropped")
    func fetchesAndFiltersPushEvents() async throws {
        let http = PushEventHTTPClient()
        let client = GitLabClient(httpClient: http, tokenStore: StubTokenStore(.token("glpat-secret")))

        let snapshot = try await client.fetchDashboard(
            scope: RepositoryScope(activeWithinDays: nil),
            options: DashboardRequestOptions(pageSize: 25, pipelineConcurrency: 1)
        )

        #expect(snapshot.pushEvents.map(\.id) == ["77"])
        let event = try #require(snapshot.pushEvents.first)
        #expect(event.repository == "alice/one")
        #expect(event.actor.login == "carla")
        #expect(event.ref == "main")
        #expect(event.commitCount == 4)
        #expect(event.url?.absoluteString == "https://gitlab.com/alice/one/-/commits/main")
        #expect(await http.eventQuery["action"] == "pushed")
        #expect(await http.eventQuery["after"] != nil)
    }

    @Test("turning the preference off asks for no events at all")
    func skipsEventsWhenDisabled() async throws {
        let http = PushEventHTTPClient()
        let client = GitLabClient(httpClient: http, tokenStore: StubTokenStore(.token("glpat-secret")))

        let snapshot = try await client.fetchDashboard(
            scope: RepositoryScope(activeWithinDays: nil),
            options: DashboardRequestOptions(pageSize: 25, pipelineConcurrency: 1, includePushEvents: false)
        )

        #expect(snapshot.pushEvents.isEmpty)
        #expect(await http.eventRequestCount == 0)
    }

    @Test("a project whose events are forbidden costs that project's pushes and nothing else")
    func aForbiddenEventsFeedDoesNotFailTheCycle() async throws {
        let http = PushEventHTTPClient(forbidEvents: true)
        let client = GitLabClient(httpClient: http, tokenStore: StubTokenStore(.token("glpat-secret")))

        let snapshot = try await client.fetchDashboard(
            scope: RepositoryScope(activeWithinDays: nil),
            options: DashboardRequestOptions(pageSize: 25, pipelineConcurrency: 1)
        )

        #expect(snapshot.pushEvents.isEmpty)
        #expect(snapshot.repositories.map(\.nameWithOwner) == ["alice/one"])
    }
}

private actor PushEventHTTPClient: HTTPClient {
    private let forbidEvents: Bool
    private(set) var eventQuery: [String: String] = [:]
    private(set) var eventRequestCount = 0

    init(forbidEvents: Bool = false) { self.forbidEvents = forbidEvents }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let path = components.path
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        switch path {
        case "/api/v4/user":
            return pushResponse(#"{"username":"alice","web_url":"https://gitlab.com/alice"}"#)
        case "/api/v4/merge_requests", "/api/v4/issues":
            return pushResponse("[]")
        case "/api/v4/projects":
            return pushResponse(#"[{"id":1,"path_with_namespace":"alice/one","visibility":"public","web_url":"https://gitlab.com/alice/one"}]"#)
        case "/api/v4/projects/1/pipelines":
            return pushResponse("[]")
        case "/api/v4/projects/1/events":
            eventRequestCount += 1
            eventQuery = query
            guard !forbidEvents else { return HTTPResponse(status: 403, body: Data(#"{"message":"403 Forbidden"}"#.utf8)) }
            return pushResponse("""
            [
              {"id":77,"action_name":"pushed to","created_at":"2026-09-20T09:00:00Z","author":{"username":"carla"},"push_data":{"commit_count":4,"ref":"main"}},
              {"id":78,"action_name":"pushed to","created_at":"2026-09-20T10:00:00Z","author":{"username":"alice"},"push_data":{"commit_count":1,"ref":"main"}}
            ]
            """)
        default:
            throw GitLabError.transport("Unexpected request: \(path)")
        }
    }
}


/// Local because the REST suite's own helper is file-private to that file.
private func pushResponse(_ body: String, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(status: 200, headers: headers, body: Data(body.utf8))
}
