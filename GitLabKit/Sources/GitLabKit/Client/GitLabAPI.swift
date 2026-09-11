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

public protocol GitLabAPI: Sendable {
    func fetchDashboard(scope: RepositoryScope) async throws -> DashboardSnapshot
    func verifyToken() async throws -> Profile
}
