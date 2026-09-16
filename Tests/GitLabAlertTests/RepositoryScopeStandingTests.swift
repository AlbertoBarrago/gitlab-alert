import Foundation
import GitLabKit
import Testing
@testable import GitLabAlert

/// ``RepositoryPickerView/standing(for:scope:now:)`` restates the rule that
/// ``RepositoryScope/filter(_:now:)`` enforces, so the picker can say why a
/// repository is in or out. The two are only useful while they agree: this
/// walks every combination of rule and repository shape and checks that the
/// label the list shows matches what the client will actually poll.
@MainActor
@Test func standingAgreesWithTheScopeFilterOnEveryCombination() {
    let now = Date()
    let url = URL(string: "https://gitlab.com/alice/repo")!
    var checked = 0

    for isPrivate in [true, false] {
        for isFork in [true, false] {
            for pushedAt in [now, now.addingTimeInterval(-200 * 86_400), nil] as [Date?] {
                let repo = RepoSnapshot(
                    nameWithOwner: "alice/repo",
                    isPrivate: isPrivate,
                    isFork: isFork,
                    pushedAt: pushedAt,
                    url: url
                )

                for includePrivate in [true, false] {
                    for includeForks in [true, false] {
                        for days in [90, nil] as [Int?] {
                            for pinned in [true, false] {
                                for excluded in [true, false] {
                                    let scope = RepositoryScope(
                                        includePrivate: includePrivate,
                                        includeForks: includeForks,
                                        activeWithinDays: days,
                                        pinned: pinned ? ["alice/repo"] : [],
                                        excluded: excluded ? ["alice/repo"] : []
                                    )
                                    let standing = RepositoryPickerView.standing(for: repo, scope: scope, now: now)
                                    let watched = !scope.filter([repo], now: now).isEmpty
                                    #expect(
                                        standing.isWatched == watched,
                                        "\(standing) disagrees with the filter for \(scope)"
                                    )
                                    checked += 1
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    #expect(checked == 384)
}
