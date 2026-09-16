import Foundation
import GitLabKit

/// Fixtures for `#Preview` blocks.
///
/// Nothing in the shipping code path references this type. It exists so every
/// popover view — including the states that are hard to reach on purpose, like
/// a rejected token or a stale snapshot — can be iterated without a token, a
/// network round trip or a keychain entry.
@MainActor
enum SampleData {

    /// Ages are relative to when the previews first run, so "3h ago" stays
    /// plausible instead of drifting into "2y ago" as the fixture gets older.
    static let now = Date()

    private static func url(_ string: String) -> URL {
        // Literals, checked by the previews themselves: a typo here shows up
        // immediately and cannot reach a build the user runs.
        URL(string: string) ?? URL(fileURLWithPath: "/")
    }

    private static func avatar(_ id: Int) -> URL {
        url("https://avatars.gitlabusercontent.com/u/\(id)?v=4")
    }

    // MARK: - People

    static let actors: [GLActor] = [
        GLActor(login: "octocat", avatarURL: avatar(583_231)),
        GLActor(login: "hubot", avatarURL: avatar(11_642)),
        GLActor(login: "maintainer-bot", avatarURL: nil),
        GLActor(login: "sofia-dev", avatarURL: avatar(9_919)),
        GLActor(login: "kenji", avatarURL: avatar(1_024)),
        GLActor(login: "ramona", avatarURL: nil),
        GLActor(login: "tbergman", avatarURL: avatar(4_242)),
        GLActor(login: "9ine", avatarURL: nil),
    ]

    static let profile = Profile(
        login: "alBz",
        name: "Alberto Barrago",
        avatarURL: avatar(1_907_401),
        followers: 1_284,
        following: 89,
        publicRepoCount: 178,
        url: url("https://gitlab.com/alBz")
    )

    // MARK: - Work items

    static let reviewRequested: [MergeRequestItem] = [
        MergeRequestItem(
            id: "MR_1",
            number: 412,
            title: "Replace the REST events poller with the batched GraphQL attribution query",
            repository: "alBz/telemaco",
            author: actors[0],
            url: url("https://gitlab.com/alBz/telemaco/pull/412"),
            createdAt: now.addingTimeInterval(-9_400),
            updatedAt: now.addingTimeInterval(-2_400),
            reviewDecision: .reviewRequired,
            checkState: .success,
            relevance: [.reviewRequested],
            commentCount: 4
        ),
        MergeRequestItem(
            id: "MR_2",
            number: 88,
            title: "Fix the duplicate notification on watermark equality",
            repository: "alBz/dockdock",
            author: actors[3],
            url: url("https://gitlab.com/alBz/dockdock/pull/88"),
            createdAt: now.addingTimeInterval(-86_000),
            updatedAt: now.addingTimeInterval(-14_000),
            reviewDecision: .changesRequested,
            checkState: .failure,
            relevance: [.reviewRequested],
            commentCount: 11
        ),
        MergeRequestItem(
            id: "MR_3",
            number: 7,
            title: "Docs: document the 1-point dashboard budget",
            repository: "swift-community/grapher",
            author: actors[4],
            url: url("https://gitlab.com/swift-community/grapher/pull/7"),
            createdAt: now.addingTimeInterval(-260_000),
            updatedAt: now.addingTimeInterval(-70_000),
            reviewDecision: .approved,
            checkState: .pending,
            relevance: [.reviewRequested]
        ),
    ]

    static let authoredMergeRequests: [MergeRequestItem] = [
        MergeRequestItem(
            id: "MR_10",
            number: 413,
            title: "Draft: menu bar glyph drawn in code instead of an asset catalog",
            repository: "alBz/telemaco",
            author: nil,
            url: url("https://gitlab.com/alBz/telemaco/pull/413"),
            createdAt: now.addingTimeInterval(-3_200),
            updatedAt: now.addingTimeInterval(-900),
            isDraft: true,
            checkState: .pending,
            relevance: [.authored]
        ),
        MergeRequestItem(
            id: "MR_11",
            number: 91,
            title: "Clamp the poll interval in one place",
            repository: "alBz/dockdock",
            author: nil,
            url: url("https://gitlab.com/alBz/dockdock/pull/91"),
            createdAt: now.addingTimeInterval(-500_000),
            updatedAt: now.addingTimeInterval(-40_000),
            reviewDecision: .approved,
            checkState: .success,
            relevance: [.authored],
            commentCount: 2
        ),
    ]

    static let assignedIssues: [IssueItem] = [
        IssueItem(
            id: "I_1",
            number: 231,
            title: "Popover clips its last row on a notched display",
            repository: "alBz/telemaco",
            author: actors[1],
            url: url("https://gitlab.com/alBz/telemaco/issues/231"),
            createdAt: now.addingTimeInterval(-420_000),
            updatedAt: now.addingTimeInterval(-6_000),
            commentCount: 6,
            labels: ["bug", "macOS"]
        ),
        IssueItem(
            id: "I_2",
            number: 232,
            title: "Login item registration fails outside /Applications",
            repository: "alBz/telemaco",
            author: actors[5],
            url: url("https://gitlab.com/alBz/telemaco/issues/232"),
            createdAt: now.addingTimeInterval(-1_100_000),
            updatedAt: now.addingTimeInterval(-99_000),
            commentCount: 1,
            labels: ["needs repro"]
        ),
    ]

    /// Seven, so the "See all" affordance has something to do.
    static let inboundIssues: [IssueItem] = (0..<7).map { index in
        IssueItem(
            id: "IN_\(index)",
            number: 500 + index,
            title: [
                "Crash on launch when state.json is truncated",
                "Feature request: per-repository mute",
                "Stars counted twice after an unstar",
                "Dark menu bar glyph is one pixel off centre",
                "Add a Homebrew cask",
                "Rate limit warning never disappears",
                "Support GitLab Enterprise hosts",
            ][index],
            repository: index.isMultiple(of: 2) ? "alBz/telemaco" : "alBz/grapher",
            author: actors[index % actors.count],
            url: url("https://gitlab.com/alBz/telemaco/issues/\(500 + index)"),
            createdAt: now.addingTimeInterval(-Double(index + 1) * 30_000),
            updatedAt: now.addingTimeInterval(-Double(index + 1) * 4_000),
            commentCount: index,
            labels: index.isMultiple(of: 3) ? ["triage"] : [],
            isInbound: true
        )
    }

    static let repositories: [RepoSnapshot] = [
        RepoSnapshot(
            nameWithOwner: "alBz/telemaco",
            openIssueCount: 12,
            defaultBranch: "main",
            headOID: "a1b2c3d",
            checkState: .failure,
            pushedAt: now.addingTimeInterval(-5_400),
            url: url("https://gitlab.com/alBz/telemaco")
        ),
        RepoSnapshot(
            nameWithOwner: "alBz/dockdock",
            openIssueCount: 4,
            defaultBranch: "main",
            checkState: .error,
            pushedAt: now.addingTimeInterval(-260_000),
            url: url("https://gitlab.com/alBz/dockdock")
        ),
        RepoSnapshot(
            nameWithOwner: "alBz/grapher",
            defaultBranch: "main",
            checkState: .success,
            pushedAt: now.addingTimeInterval(-90_000),
            url: url("https://gitlab.com/alBz/grapher")
        ),
        RepoSnapshot(
            nameWithOwner: "alBz/notes",
            checkState: .unknown,
            pushedAt: now.addingTimeInterval(-700_000),
            url: url("https://gitlab.com/alBz/notes")
        ),
    ]

    // MARK: - Activity

    static let activity: [ActivityEvent] = [
        ActivityEvent(
            id: "E_checks_failed",
            kind: .checksFailed,
            occurredAt: now.addingTimeInterval(-5_400),
            repository: "alBz/telemaco",
            url: url("https://gitlab.com/alBz/telemaco/commits/main")
        ),
        ActivityEvent(
            id: "E_inbound_issue",
            kind: .inboundIssue,
            occurredAt: now.addingTimeInterval(-30_000),
            repository: "alBz/telemaco",
            actors: [actors[1]],
            title: "Crash on launch when state.json is truncated",
            url: url("https://gitlab.com/alBz/telemaco/issues/500")
        ),
        ActivityEvent(
            id: "E_checks_recovered",
            kind: .checksRecovered,
            occurredAt: now.addingTimeInterval(-96_000),
            repository: "alBz/dockdock"
        ),
    ]

    // MARK: - Snapshots

    static let snapshot = DashboardSnapshot(
        fetchedAt: now.addingTimeInterval(-12),
        profile: profile,
        reviewRequested: reviewRequested,
        authoredMergeRequests: authoredMergeRequests,
        assignedIssues: assignedIssues,
        inboundIssues: inboundIssues,
        repositories: repositories,
        rateLimit: RateLimitStatus(remaining: 4_812, limit: 5_000, resetAt: now.addingTimeInterval(2_100))
    )

    static let emptySnapshot = DashboardSnapshot(
        fetchedAt: now.addingTimeInterval(-8),
        profile: profile,
        repositories: repositories.map { repo in
            var green = repo
            green.checkState = .success
            return green
        },
        rateLimit: RateLimitStatus(remaining: 4_991, limit: 5_000, resetAt: now.addingTimeInterval(3_000))
    )

    static let lowBudgetSnapshot: DashboardSnapshot = {
        var low = snapshot
        low.rateLimit = RateLimitStatus(remaining: 312, limit: 5_000, resetAt: now.addingTimeInterval(600))
        return low
    }()

    // MARK: - Models

    /// Data, unread activity, a healthy budget: the everyday case.
    static var populatedModel: AppModel {
        makeModel(snapshot: snapshot, log: activity, fresh: Array(activity.prefix(3)))
    }

    /// Nothing waiting anywhere — the state the user actually sees most.
    static var restingModel: AppModel {
        makeModel(snapshot: emptySnapshot, log: [], fresh: [])
    }

    /// A fresh install: not an error, not a spinner.
    static var needsTokenModel: AppModel {
        makeModel(token: nil, snapshot: nil, log: [], fresh: [])
    }

    static var rejectedModel: AppModel {
        let model = makeModel(snapshot: nil, log: [], fresh: [])
        model.fail(.badCredentials)
        return model
    }

    /// Real data plus a failed refresh: the screen must not go blank.
    static var staleModel: AppModel {
        let model = populatedModel
        model.fail(.transport("The Internet connection appears to be offline."))
        return model
    }

    /// A failed first load, with nothing cached to fall back on.
    static var failedModel: AppModel {
        let model = makeModel(snapshot: nil, log: [], fresh: [])
        model.fail(.transport("The Internet connection appears to be offline."))
        return model
    }

    static var loadingModel: AppModel {
        makeModel(snapshot: nil, log: [], fresh: [])
    }

    static var lowBudgetModel: AppModel {
        makeModel(snapshot: lowBudgetSnapshot, log: activity, fresh: [])
    }

    // MARK: - Model assembly

    /// Previews get their own defaults domain so iterating on a view cannot
    /// rewrite the real app's preferences.
    private static let previewPreferences = Preferences(
        defaults: UserDefaults(suiteName: "com.alBz.GitLabAlert.previews") ?? .standard
    )

    private static func makeModel(
        token: String? = "preview",
        snapshot: DashboardSnapshot?,
        log: [ActivityEvent],
        fresh: [ActivityEvent]
    ) -> AppModel {
        let apiSnapshot = snapshot ?? emptySnapshot
        let model = AppModel(
            preferences: previewPreferences,
            tokenStore: PreviewTokenStore(token: token),
            api: PreviewGitLabAPI(snapshot: apiSnapshot),
            apiFactory: { _ in PreviewGitLabAPI(snapshot: apiSnapshot) }
        )
        if let snapshot {
            // `apply` is also what promotes `.verifying` to `.ready`, which is
            // why the previews go through it rather than poking state directly.
            model.apply(
                PollOutcome(
                    snapshot: snapshot,
                    freshEvents: fresh,
                    activityLog: log,
                    rateLimit: snapshot.rateLimit
                )
            )
        }
        return model
    }
}

private struct PreviewTokenStore: TokenStore {
    let token: String?
    func readToken() throws -> String? { token }
    func writeToken(_ token: String) throws {}
    func deleteToken() throws {}
}

private struct PreviewGitLabAPI: GitLabAPI {
    let snapshot: DashboardSnapshot
    func fetchDashboard(scope: RepositoryScope, options: DashboardRequestOptions) async throws -> DashboardSnapshot { snapshot }
    func verifyToken() async throws -> Profile { snapshot.profile }
}
