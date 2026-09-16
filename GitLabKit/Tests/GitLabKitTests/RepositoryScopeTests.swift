import Foundation
import Testing
@testable import GitLabKit

private func repo(
    _ name: String,
    isPrivate: Bool = false,
    isFork: Bool = false,
    pushedAt: Date? = Date()
) -> RepoSnapshot {
    RepoSnapshot(
        nameWithOwner: name,
        isPrivate: isPrivate,
        isFork: isFork,
        pushedAt: pushedAt,
        url: URL(string: "https://gitlab.com/\(name)")!
    )
}

@Test func scopeDropsForksUnlessTheRuleIncludesThem() {
    let repositories = [repo("alice/plain"), repo("alice/forked", isFork: true)]

    let excluding = RepositoryScope(includeForks: false).filter(repositories)
    #expect(excluding.map(\.nameWithOwner) == ["alice/plain"])

    let including = RepositoryScope(includeForks: true).filter(repositories)
    #expect(including.map(\.nameWithOwner) == ["alice/plain", "alice/forked"])
}

@Test func scopeDropsPrivateRepositoriesUnlessTheRuleIncludesThem() {
    let repositories = [repo("alice/open"), repo("alice/closed", isPrivate: true)]

    #expect(RepositoryScope(includePrivate: false).filter(repositories).map(\.nameWithOwner) == ["alice/open"])
    #expect(RepositoryScope(includePrivate: true).filter(repositories).count == 2)
}

@Test func pinBeatsEveryFilterAndExclusionBeatsThePin() {
    let stale = repo("alice/legacy", isPrivate: true, isFork: true, pushedAt: .distantPast)

    let pinned = RepositoryScope(includePrivate: false, includeForks: false, activeWithinDays: 30, pinned: ["alice/legacy"])
    #expect(pinned.filter([stale]).count == 1)

    let both = RepositoryScope(pinned: ["alice/legacy"], excluded: ["alice/legacy"])
    #expect(both.filter([stale]).isEmpty)
}

@Test func activityCutoffDropsStaleAndNeverPushedRepositories() {
    let now = Date()
    let repositories = [
        repo("alice/fresh", pushedAt: now.addingTimeInterval(-86_400)),
        repo("alice/stale", pushedAt: now.addingTimeInterval(-120 * 86_400)),
        repo("alice/empty", pushedAt: nil)
    ]

    let bounded = RepositoryScope(activeWithinDays: 90).filter(repositories, now: now)
    #expect(bounded.map(\.nameWithOwner) == ["alice/fresh"])

    let unbounded = RepositoryScope(activeWithinDays: nil).filter(repositories, now: now)
    #expect(unbounded.count == 3)
}
