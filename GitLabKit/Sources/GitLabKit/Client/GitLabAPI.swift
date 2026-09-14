import Foundation

public struct RepositoryScope: Sendable, Codable, Hashable {
    public var includeOwned: Bool
    public var includePrivate: Bool
    public var includeForks: Bool
    public var activeWithinDays: Int?
    public var pinned: Set<String>
    public var excluded: Set<String>

    public init(includeOwned: Bool = true, includePrivate: Bool = true, includeForks: Bool = false, activeWithinDays: Int? = 90, pinned: Set<String> = [], excluded: Set<String> = []) {
        self.includeOwned = includeOwned
        self.includePrivate = includePrivate
        self.includeForks = includeForks
        self.activeWithinDays = activeWithinDays
        self.pinned = pinned
        self.excluded = excluded
    }

    public static let `default` = RepositoryScope()

    public func filter(_ repositories: [RepoSnapshot], now: Date = Date()) -> [RepoSnapshot] {
        repositories.filter { repository in
            guard !excluded.contains(repository.nameWithOwner) else { return false }
            guard pinned.contains(repository.nameWithOwner) || includePrivate || !repository.isPrivate else { return false }
            guard let days = activeWithinDays, !pinned.contains(repository.nameWithOwner) else { return true }
            return repository.pushedAt.map { $0 >= now.addingTimeInterval(-Double(days) * 86_400) } ?? false
        }
    }
}

/// Per-request cost controls. They are deliberately bounded so a preference
/// cannot turn a dashboard refresh into an unbounded burst of API traffic.
public struct DashboardRequestOptions: Sendable, Hashable {
    public static let defaultPageSize = 25
    public static let defaultPipelineConcurrency = 6

    public var pageSize: Int
    public var pipelineConcurrency: Int

    public init(
        pageSize: Int = DashboardRequestOptions.defaultPageSize,
        pipelineConcurrency: Int = DashboardRequestOptions.defaultPipelineConcurrency
    ) {
        self.pageSize = min(max(pageSize, 25), 100)
        self.pipelineConcurrency = min(max(pipelineConcurrency, 1), 8)
    }
}

public protocol GitLabAPI: Sendable {
    func fetchDashboard(scope: RepositoryScope, options: DashboardRequestOptions) async throws -> DashboardSnapshot
    func verifyToken() async throws -> Profile
}

public extension GitLabAPI {
    func fetchDashboard(scope: RepositoryScope) async throws -> DashboardSnapshot {
        try await fetchDashboard(scope: scope, options: DashboardRequestOptions())
    }
}
