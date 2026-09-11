import Foundation
import Testing
@testable import GitLabKit

// MARK: - Fixtures

/// Every date in this file is built from explicit components in UTC. `Date()`
/// never appears: a diff engine test that depends on the wall clock is a test
/// that fails once a year at midnight.
private let utc = TimeZone(secondsFromGMT: 0)!

private func at(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 12,
    _ minute: Int = 0,
    _ second: Int = 0
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let components = DateComponents(
        timeZone: utc,
        year: year, month: month, day: day,
        hour: hour, minute: minute, second: second
    )
    guard let date = calendar.date(from: components) else {
        preconditionFailure("invalid fixture date")
    }
    return date
}

private let epoch = at(2026, 1, 1)
private let t0 = at(2026, 3, 10, 8, 0, 0)
private let t1 = at(2026, 3, 10, 9, 0, 0)
private let t2 = at(2026, 3, 10, 10, 0, 0)
private let t3 = at(2026, 3, 10, 11, 0, 0)
private let observation = at(2026, 3, 10, 12, 0, 0)

private let alpha = "octocat/alpha"
private let beta = "octocat/beta"

private func url(_ string: String) -> URL {
    guard let url = URL(string: string) else { preconditionFailure("invalid fixture URL") }
    return url
}

private func makeProfile(login: String = "octocat") -> Profile {
    Profile(login: login, name: "Octo Cat", url: url("https://gitlab.com/\(login)"))
}

private func makeRepo(
    _ nameWithOwner: String,
    stars: Int = 0,
    forks: Int = 0,
    checks: CheckState = .success
) -> RepoSnapshot {
    RepoSnapshot(
        nameWithOwner: nameWithOwner,
        stargazerCount: stars,
        forkCount: forks,
        checkState: checks,
        pushedAt: t0,
        url: url("https://gitlab.com/\(nameWithOwner)")
    )
}

private func makeSnapshot(
    fetchedAt: Date = observation,
    viewer: String = "octocat",
    repositories: [RepoSnapshot] = [],
    reviewRequested: [MergeRequestItem] = [],
    authoredMergeRequests: [MergeRequestItem] = [],
    inboundIssues: [IssueItem] = []
) -> DashboardSnapshot {
    DashboardSnapshot(
        fetchedAt: fetchedAt,
        profile: makeProfile(login: viewer),
        reviewRequested: reviewRequested,
        authoredMergeRequests: authoredMergeRequests,
        inboundIssues: inboundIssues,
        repositories: repositories
    )
}

private func makeWatermark(
    stars: Int = 0,
    forks: Int = 0,
    newestStarredAt: Date? = nil,
    newestForkedAt: Date? = nil,
    checks: CheckState = .success,
    firstSeenAt: Date = epoch
) -> RepoWatermark {
    RepoWatermark(
        stargazerCount: stars,
        forkCount: forks,
        newestStarredAt: newestStarredAt,
        newestForkedAt: newestForkedAt,
        lastCheckState: checks,
        firstSeenAt: firstSeenAt
    )
}

private func star(_ login: String, _ date: Date) -> StarRecord {
    StarRecord(actor: GLActor(login: login), starredAt: date)
}

private func fork(_ login: String, _ date: Date) -> ForkRecord {
    ForkRecord(actor: GLActor(login: login), createdAt: date, nameWithOwner: "\(login)/alpha")
}

private func makePull(
    id: String,
    number: Int = 1,
    repository: String = alpha,
    author: String? = "contributor",
    createdAt: Date = t1,
    updatedAt: Date = t2
) -> MergeRequestItem {
    MergeRequestItem(
        id: id,
        number: number,
        title: "MR \(number)",
        repository: repository,
        author: author.map { GLActor(login: $0) },
        url: url("https://gitlab.com/\(repository)/pull/\(number)"),
        createdAt: createdAt,
        updatedAt: updatedAt
    )
}

private func makeIssue(
    id: String,
    number: Int = 1,
    repository: String = alpha,
    author: String? = "reporter",
    createdAt: Date = t1
) -> IssueItem {
    IssueItem(
        id: id,
        number: number,
        title: "Issue \(number)",
        repository: repository,
        author: author.map { GLActor(login: $0) },
        url: url("https://gitlab.com/\(repository)/issues/\(number)"),
        createdAt: createdAt,
        updatedAt: createdAt,
        isInbound: true
    )
}

@Suite("ActivityDiffEngine")
struct ActivityDiffEngineTests {
    let engine = ActivityDiffEngine()

    // MARK: - changedRepositories

    @Test("changedRepositories reports only count movement on known repositories")
    func changedRepositoriesIsCountOnly() {
        let current = makeSnapshot(repositories: [
            makeRepo(alpha, stars: 11, forks: 2),
            makeRepo(beta, stars: 5, forks: 5),
            makeRepo("octocat/gamma", stars: 900, forks: 1),
            makeRepo("octocat/delta", stars: 3, forks: 9)
        ])
        let watermarks = [
            alpha: makeWatermark(stars: 10, forks: 2),
            beta: makeWatermark(stars: 5, forks: 5),
            // gamma has no watermark: new, to be seeded, never reported.
            "octocat/delta": makeWatermark(stars: 3, forks: 8)
        ]

        let changed = engine.changedRepositories(watermarks: watermarks, current: current)

        #expect(changed == [alpha, "octocat/delta"])
    }

    // MARK: - Seeding

    @Test("baselineOnly seeds every repository and emits nothing")
    func seedRunEmitsZeroEvents() throws {
        let current = makeSnapshot(repositories: [
            makeRepo(alpha, stars: 400, forks: 42, checks: .failure)
        ])

        let result = engine.diff(DiffInput(
            previousSnapshot: nil,
            currentSnapshot: current,
            mode: .baselineOnly,
            now: observation
        ))

        #expect(result.events.isEmpty)
        let mark = try #require(result.watermarks[alpha])
        #expect(mark.stargazerCount == 400)
        #expect(mark.forkCount == 42)
        #expect(mark.lastCheckState == .failure)
        #expect(mark.newestStarredAt == nil)
        #expect(mark.newestForkedAt == nil)
        #expect(mark.firstSeenAt == observation)
    }

    @Test("compare mode without a previous snapshot behaves as a baseline run")
    func missingBaselineSeedsSilently() {
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 400)])

        let result = engine.diff(DiffInput(
            previousSnapshot: nil,
            currentSnapshot: current,
            attribution: [alpha: RepoAttribution(stars: [star("nova", t2)])],
            mode: .compare,
            now: observation
        ))

        #expect(result.events.isEmpty)
        #expect(result.watermarks[alpha]?.stargazerCount == 400)
    }

    @Test("a repository appearing mid-life is seeded silently even with attribution")
    func newRepositoryMidLifeIsSilent() throws {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(repositories: [
            makeRepo(alpha, stars: 10),
            makeRepo(beta, stars: 400, forks: 12)
        ])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10)],
            attribution: [beta: RepoAttribution(
                stars: [star("nova", t2), star("orion", t3)],
                forks: [fork("nova", t2)]
            )],
            now: observation
        ))

        #expect(result.events.isEmpty)
        let mark = try #require(result.watermarks[beta])
        #expect(mark.stargazerCount == 400)
        #expect(mark.forkCount == 12)
        #expect(mark.newestStarredAt == nil)
    }

    @Test("a repository leaving the snapshot drops its watermark instead of leaking it")
    func vanishedRepositoryDropsWatermark() {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10), makeRepo(beta, stars: 3)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10), beta: makeWatermark(stars: 3)],
            now: observation
        ))

        #expect(result.events.isEmpty)
        #expect(result.watermarks.keys.sorted() == [alpha])
        #expect(result.watermarks[beta] == nil)
    }

    // MARK: - Stars

    @Test("one new star with attribution names the actor")
    func plusOneStarNamesActor() throws {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 11)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10, newestStarredAt: t0)],
            attribution: [alpha: RepoAttribution(stars: [star("nova", t1)])],
            now: observation
        ))

        #expect(result.events.count == 1)
        let event = try #require(result.events.first)
        #expect(event.kind == .star)
        #expect(event.delta == 1)
        #expect(event.actors.map(\.login) == ["nova"])
        #expect(event.occurredAt == t1)
        #expect(event.repository == alpha)
        #expect(event.needsAttribution == false)

        let mark = try #require(result.watermarks[alpha])
        #expect(mark.stargazerCount == 11)
        #expect(mark.newestStarredAt == t1)
        #expect(mark.firstSeenAt == epoch)
    }

    @Test("three new stars with full attribution produce three named events, newest first")
    func plusThreeStarsProduceThreeEvents() throws {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 13)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10, newestStarredAt: t0)],
            attribution: [alpha: RepoAttribution(stars: [
                star("nova", t1), star("orion", t2), star("vega", t3)
            ])],
            now: observation
        ))

        #expect(result.events.count == 3)
        #expect(result.events.allSatisfy { $0.kind == .star && $0.delta == 1 })
        #expect(result.events.map { $0.actors.first?.login } == ["vega", "orion", "nova"])
        #expect(result.watermarks[alpha]?.newestStarredAt == t3)
    }

    @Test("count rose with no attribution produces one count-only event")
    func countOnlyStarEvent() throws {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 13)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10, newestStarredAt: t0)],
            now: observation
        ))

        #expect(result.events.count == 1)
        let event = try #require(result.events.first)
        #expect(event.kind == .star)
        #expect(event.delta == 3)
        #expect(event.actors.isEmpty)
        #expect(event.needsAttribution)
        // Rule 12: no record, so the observation time is the timestamp.
        #expect(event.occurredAt == observation)
        // No record was seen, so the timestamp floor cannot move.
        #expect(result.watermarks[alpha]?.newestStarredAt == t0)
        #expect(result.watermarks[alpha]?.stargazerCount == 13)
    }

    @Test("two records for a delta of three produce two named events plus a shortfall event")
    func attributionShortfall() throws {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 13)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10, newestStarredAt: t0)],
            attribution: [alpha: RepoAttribution(stars: [star("nova", t1), star("orion", t2)])],
            now: observation
        ))

        #expect(result.events.count == 3)
        let named = result.events.filter { !$0.actors.isEmpty }
        let countOnly = result.events.filter { $0.actors.isEmpty }
        #expect(named.count == 2)
        #expect(named.map { $0.actors[0].login }.sorted() == ["nova", "orion"])
        #expect(countOnly.count == 1)
        #expect(countOnly.first?.delta == 1)
        #expect(result.events.reduce(0) { $0 + $1.delta } == 3)
        #expect(result.watermarks[alpha]?.newestStarredAt == t2)
    }

    @Test("attribution page longer than the delta only reports the newest records")
    func attributionLongerThanDeltaIsTrimmed() {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 11)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            // No floor yet: every record in the page "qualifies", and only the
            // count keeps this from becoming a burst of historical stars.
            watermarks: [alpha: makeWatermark(stars: 10)],
            attribution: [alpha: RepoAttribution(stars: [
                star("nova", t1), star("orion", t2), star("vega", t3)
            ])],
            now: observation
        ))

        #expect(result.events.count == 1)
        #expect(result.events.first?.actors.map(\.login) == ["vega"])
        #expect(result.watermarks[alpha]?.newestStarredAt == t3)
    }

    @Test("an unstar walks the watermark down and emits nothing")
    func unstarEmitsNothing() throws {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 8)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10, newestStarredAt: t0)],
            now: observation
        ))

        #expect(result.events.isEmpty)
        #expect(result.watermarks[alpha]?.stargazerCount == 8)
    }

    @Test("a negative delta stays silent even when attribution shows a newer star")
    func negativeDeltaIgnoresTimestampEvidence() throws {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 9)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10, newestStarredAt: t0)],
            attribution: [alpha: RepoAttribution(stars: [star("nova", t2)])],
            now: observation
        ))

        #expect(result.events.isEmpty)
        let mark = try #require(result.watermarks[alpha])
        #expect(mark.stargazerCount == 9)
        // The record was seen, so the floor still moves: it must not resurrect
        // on the next cycle when the count goes back up.
        #expect(mark.newestStarredAt == t2)
    }

    @Test("starredAt exactly equal to the watermark emits nothing")
    func equalTimestampEmitsNothing() throws {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10, newestStarredAt: t2)],
            attribution: [alpha: RepoAttribution(stars: [star("nova", t2)])],
            now: observation
        ))

        #expect(result.events.isEmpty)
        #expect(result.watermarks[alpha]?.newestStarredAt == t2)
    }

    @Test("the identical diff run twice emits events only the first time")
    func identicalDiffTwiceEmitsOnce() {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 12)])
        let attribution = [alpha: RepoAttribution(stars: [star("nova", t1), star("orion", t2)])]

        let first = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10, newestStarredAt: t0)],
            attribution: attribution,
            now: observation
        ))
        #expect(first.events.count == 2)

        let second = engine.diff(DiffInput(
            previousSnapshot: current,
            currentSnapshot: current,
            watermarks: first.watermarks,
            attribution: attribution,
            now: observation
        ))
        #expect(second.events.isEmpty)
        #expect(second.watermarks[alpha] == first.watermarks[alpha])
    }

    @Test("star then unstar inside one cycle is reported from the timestamp evidence")
    func starThenUnstarPrefersTimestampEvidence() throws {
        // The count is flat (one star arrived, one older star was withdrawn),
        // so only the record timestamp can see the new star. Documented
        // behaviour: timestamp evidence wins and the star is reported.
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let attribution = [alpha: RepoAttribution(stars: [star("nova", t2)])]

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10, newestStarredAt: t0)],
            attribution: attribution,
            now: observation
        ))

        #expect(result.events.count == 1)
        let event = try #require(result.events.first)
        #expect(event.kind == .star)
        #expect(event.actors.map(\.login) == ["nova"])
        #expect(result.watermarks[alpha]?.newestStarredAt == t2)

        // And it is reported exactly once.
        let again = engine.diff(DiffInput(
            previousSnapshot: current,
            currentSnapshot: current,
            watermarks: result.watermarks,
            attribution: attribution,
            now: observation
        ))
        #expect(again.events.isEmpty)
    }

    @Test("a flat count with no established floor reports nothing but records the floor")
    func flatCountWithoutFloorIsSilent() throws {
        // A freshly seeded repository has counts but no star timestamp. Every
        // record in the page looks new, so reporting here would replay history.
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10)],
            attribution: [alpha: RepoAttribution(stars: [star("nova", t1), star("orion", t2)])],
            now: observation
        ))

        #expect(result.events.isEmpty)
        #expect(result.watermarks[alpha]?.newestStarredAt == t2)
    }

    @Test("a record timestamped in the future still advances the watermark")
    func futureTimestampAdvancesWatermark() throws {
        let skewed = at(2027, 1, 1)
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 11)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10, newestStarredAt: t0)],
            attribution: [alpha: RepoAttribution(stars: [star("nova", skewed)])],
            now: observation
        ))

        #expect(result.events.count == 1)
        #expect(result.events.first?.occurredAt == skewed)
        #expect(result.watermarks[alpha]?.newestStarredAt == skewed)
    }

    @Test("input.now jumping backwards does not resurrect reported events")
    func clockMovingBackwards() {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 11)])
        let attribution = [alpha: RepoAttribution(stars: [star("nova", t1)])]

        let first = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10, newestStarredAt: t0)],
            attribution: attribution,
            now: observation
        ))
        #expect(first.events.count == 1)

        let rewound = engine.diff(DiffInput(
            previousSnapshot: current,
            currentSnapshot: current,
            watermarks: first.watermarks,
            attribution: attribution,
            // Clock corrected backwards by two hours.
            now: at(2026, 3, 10, 10, 0, 0)
        ))
        #expect(rewound.events.isEmpty)
        #expect(rewound.watermarks[alpha]?.newestStarredAt == t1)
    }

    // MARK: - Forks

    @Test("two new forks with attribution produce two named fork events")
    func plusTwoForksNamed() {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, forks: 4)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, forks: 6)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(forks: 4, newestForkedAt: t0)],
            attribution: [alpha: RepoAttribution(forks: [fork("nova", t1), fork("orion", t2)])],
            now: observation
        ))

        #expect(result.events.count == 2)
        #expect(result.events.allSatisfy { $0.kind == .fork })
        #expect(result.events.map { $0.actors[0].login } == ["orion", "nova"])
        #expect(result.watermarks[alpha]?.newestForkedAt == t2)
        #expect(result.watermarks[alpha]?.forkCount == 6)
    }

    @Test("fork count rose without attribution produces one count-only fork event")
    func countOnlyForkEvent() throws {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, forks: 4)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, forks: 6)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(forks: 4, newestForkedAt: t0)],
            now: observation
        ))

        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(event.kind == .fork)
        #expect(event.delta == 2)
        #expect(event.actors.isEmpty)
    }

    @Test("a deleted fork lowers the watermark and emits nothing")
    func deletedForkEmitsNothing() {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, forks: 4)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, forks: 3)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(forks: 4, newestForkedAt: t0)],
            now: observation
        ))

        #expect(result.events.isEmpty)
        #expect(result.watermarks[alpha]?.forkCount == 3)
    }

    // MARK: - CI transitions

    struct CITransition: Sendable, CustomTestStringConvertible {
        let from: CheckState
        let to: CheckState
        let expected: ActivityKind?

        var testDescription: String {
            "\(from.rawValue) -> \(to.rawValue) expects \(expected?.rawValue ?? "nothing")"
        }
    }

    @Test("only settled check-state transitions emit", arguments: [
        CITransition(from: .unknown, to: .failure, expected: nil),
        CITransition(from: .pending, to: .failure, expected: nil),
        CITransition(from: .failure, to: .pending, expected: nil),
        CITransition(from: .success, to: .unknown, expected: nil),
        CITransition(from: .success, to: .pending, expected: nil),
        CITransition(from: .failure, to: .error, expected: nil),
        CITransition(from: .expected, to: .failure, expected: nil),
        CITransition(from: .failure, to: .success, expected: .checksRecovered),
        CITransition(from: .error, to: .success, expected: .checksRecovered),
        CITransition(from: .success, to: .failure, expected: .checksFailed),
        CITransition(from: .success, to: .error, expected: .checksFailed)
    ])
    func checkTransitions(_ transition: CITransition) throws {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10, checks: transition.from)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 10, checks: transition.to)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10, checks: transition.from)],
            now: observation
        ))

        #expect(result.events.map(\.kind) == [transition.expected].compactMap { $0 })
        // The observed state is always recorded, emitted or not.
        #expect(result.watermarks[alpha]?.lastCheckState == transition.to)
    }

    @Test("an unchanged broken state does not re-notify")
    func brokenStateDoesNotRepeat() {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, checks: .failure)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, checks: .failure)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(checks: .failure)],
            now: observation
        ))

        #expect(result.events.isEmpty)
    }

    // MARK: - Work items

    @Test("a review request added is reported, one removed is not")
    func reviewRequestedAddedAndRemoved() throws {
        let repositories = [makeRepo(alpha, stars: 10)]
        let existing = makePull(id: "MR_1", number: 1)
        let arriving = makePull(id: "MR_2", number: 2)
        let watermarks = [alpha: makeWatermark(stars: 10)]

        let added = engine.diff(DiffInput(
            previousSnapshot: makeSnapshot(repositories: repositories, reviewRequested: [existing]),
            currentSnapshot: makeSnapshot(repositories: repositories, reviewRequested: [existing, arriving]),
            watermarks: watermarks,
            now: observation
        ))

        #expect(added.events.count == 1)
        let event = try #require(added.events.first)
        #expect(event.kind == .reviewRequested)
        #expect(event.id == "reviewRequested|\(alpha)|MR_2")
        #expect(event.title == "MR 2")
        #expect(event.url == arriving.url)
        #expect(event.occurredAt == arriving.updatedAt)

        let removed = engine.diff(DiffInput(
            previousSnapshot: makeSnapshot(repositories: repositories, reviewRequested: [existing, arriving]),
            currentSnapshot: makeSnapshot(repositories: repositories, reviewRequested: [existing]),
            watermarks: watermarks,
            now: observation
        ))
        #expect(removed.events.isEmpty)
    }

    @Test("review requests are tracked by id, not by title or position")
    func reviewRequestIdentityIsTheNodeID() {
        let repositories = [makeRepo(alpha, stars: 10)]
        let before = makePull(id: "MR_1", number: 1)
        var renamed = before
        renamed.title = "Renamed and moved"
        let other = makePull(id: "MR_9", number: 9)

        let result = engine.diff(DiffInput(
            previousSnapshot: makeSnapshot(repositories: repositories, reviewRequested: [before, other]),
            currentSnapshot: makeSnapshot(repositories: repositories, reviewRequested: [other, renamed]),
            watermarks: [alpha: makeWatermark(stars: 10)],
            now: observation
        ))

        #expect(result.events.isEmpty)
    }

    @Test("a new inbound issue is reported by id")
    func inboundIssueByID() throws {
        let repositories = [makeRepo(alpha, stars: 10)]
        let existing = makeIssue(id: "I_1", number: 1)
        let arriving = makeIssue(id: "I_2", number: 2, author: "stranger", createdAt: t3)

        let result = engine.diff(DiffInput(
            previousSnapshot: makeSnapshot(repositories: repositories, inboundIssues: [existing]),
            currentSnapshot: makeSnapshot(repositories: repositories, inboundIssues: [existing, arriving]),
            watermarks: [alpha: makeWatermark(stars: 10)],
            now: observation
        ))

        #expect(result.events.count == 1)
        let event = try #require(result.events.first)
        #expect(event.kind == .inboundIssue)
        #expect(event.id == "inboundIssue|\(alpha)|I_2")
        #expect(event.actors.map(\.login) == ["stranger"])
        #expect(event.occurredAt == t3)
    }

    @Test("inbound work items on a repository seeded this cycle stay silent")
    func inboundItemsOnNewlySeededRepositoryAreSilent() {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(
            repositories: [makeRepo(alpha, stars: 10), makeRepo(beta, stars: 400)],
            authoredMergeRequests: [makePull(id: "MR_5", number: 5, repository: beta, author: "stranger")],
            inboundIssues: [makeIssue(id: "I_5", number: 5, repository: beta)]
        )

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10)],
            now: observation
        ))

        #expect(result.events.isEmpty)
    }

    @Test("a merge request opened by someone else on a watched repository is inbound")
    func inboundMergeRequestByID() throws {
        let repositories = [makeRepo(alpha, stars: 10)]
        let mine = makePull(id: "MR_MINE", number: 3, author: "octocat")
        let theirs = makePull(id: "MR_THEIRS", number: 4, author: "stranger", createdAt: t3)

        let result = engine.diff(DiffInput(
            previousSnapshot: makeSnapshot(repositories: repositories, authoredMergeRequests: [mine]),
            currentSnapshot: makeSnapshot(
                repositories: repositories,
                authoredMergeRequests: [mine, theirs]
            ),
            watermarks: [alpha: makeWatermark(stars: 10)],
            now: observation
        ))

        #expect(result.events.count == 1)
        let event = try #require(result.events.first)
        #expect(event.kind == .inboundMergeRequest)
        #expect(event.id == "inboundMergeRequest|\(alpha)|MR_THEIRS")
        #expect(event.actors.map(\.login) == ["stranger"])
        #expect(event.occurredAt == t3)
    }

    @Test("a new review request is not also reported as an inbound merge request")
    func reviewRequestIsNotDoubleReported() {
        let repositories = [makeRepo(alpha, stars: 10)]
        let arriving = makePull(id: "MR_7", number: 7, author: "stranger")

        let result = engine.diff(DiffInput(
            previousSnapshot: makeSnapshot(repositories: repositories),
            currentSnapshot: makeSnapshot(repositories: repositories, reviewRequested: [arriving]),
            watermarks: [alpha: makeWatermark(stars: 10)],
            now: observation
        ))

        #expect(result.events.map(\.kind) == [.reviewRequested])
    }

    @Test("a merge request on an unwatched repository is not inbound")
    func mergeRequestOutsideTheWatchSetIsIgnored() {
        let repositories = [makeRepo(alpha, stars: 10)]
        let foreign = makePull(id: "MR_X", number: 8, repository: "someone/else", author: "stranger")

        let result = engine.diff(DiffInput(
            previousSnapshot: makeSnapshot(repositories: repositories),
            currentSnapshot: makeSnapshot(repositories: repositories, authoredMergeRequests: [foreign]),
            watermarks: [alpha: makeWatermark(stars: 10)],
            now: observation
        ))

        #expect(result.events.isEmpty)
    }

    // MARK: - Collapsing

    @Test("a four hundred star burst collapses into one summary event")
    func burstCollapsesToOneSummary() throws {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 100)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 500)])
        // Attribution pages are bounded, so a burst arrives mostly nameless.
        let records = (0..<30).map { index in
            star("fan\(index)", t1.addingTimeInterval(Double(index)))
        }

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 100, newestStarredAt: t0)],
            attribution: [alpha: RepoAttribution(stars: records)],
            now: observation
        ))

        #expect(result.events.count == 1)
        let event = try #require(result.events.first)
        #expect(event.kind == .star)
        #expect(event.delta == 400)
        #expect(event.actors.count == 30)
        #expect(event.actors.first?.login == "fan29")
        #expect(result.watermarks[alpha]?.stargazerCount == 500)
        #expect(result.watermarks[alpha]?.newestStarredAt == records.map(\.starredAt).max())
    }

    @Test("exactly maxEventsPerRepo events are not collapsed")
    func atTheLimitNothingCollapses() {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 13)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10, newestStarredAt: t0)],
            attribution: [alpha: RepoAttribution(stars: [
                star("a", t1), star("b", t2), star("c", t3)
            ])],
            mode: .compare,
            now: observation,
            maxEventsPerRepo: 3
        ))

        #expect(result.events.count == 3)
    }

    @Test("collapsing is per kind and per repository")
    func collapsingIsScopedPerRepositoryAndKind() {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10), makeRepo(beta, forks: 1)])
        let current = makeSnapshot(repositories: [makeRepo(alpha, stars: 40), makeRepo(beta, forks: 3)])

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [
                alpha: makeWatermark(stars: 10, newestStarredAt: t0),
                beta: makeWatermark(forks: 1, newestForkedAt: t0)
            ],
            attribution: [
                alpha: RepoAttribution(stars: (0..<10).map { star("fan\($0)", t1.addingTimeInterval(Double($0))) }),
                beta: RepoAttribution(forks: [fork("nova", t2), fork("orion", t3)])
            ],
            mode: .compare,
            now: observation,
            maxEventsPerRepo: 5
        ))

        let alphaEvents = result.events.filter { $0.repository == alpha }
        let betaEvents = result.events.filter { $0.repository == beta }
        #expect(alphaEvents.count == 1)
        #expect(alphaEvents.first?.delta == 30)
        #expect(betaEvents.count == 2)
    }

    // MARK: - Identity

    @Test("event ids are deterministic across two runs of the same input")
    func deterministicIDs() {
        let previous = makeSnapshot(
            repositories: [makeRepo(alpha, stars: 10, checks: .success)],
            reviewRequested: []
        )
        let current = makeSnapshot(
            repositories: [makeRepo(alpha, stars: 12, forks: 1, checks: .failure)],
            reviewRequested: [makePull(id: "MR_2", number: 2)],
            inboundIssues: [makeIssue(id: "I_3", number: 3)]
        )
        let input = DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10, newestStarredAt: t0, checks: .success)],
            attribution: [alpha: RepoAttribution(stars: [star("nova", t1)])],
            now: observation
        )

        let first = engine.diff(input)
        let second = engine.diff(input)

        #expect(first == second)
        #expect(first.events.map(\.id) == second.events.map(\.id))
        #expect(Set(first.events.map(\.id)).count == first.events.count)
        #expect(first.events.allSatisfy { $0.id.contains(alpha) })
        #expect(first.events.contains { $0.id == "star|\(alpha)|nova|\(Int64(t1.timeIntervalSince1970 * 1000))" })
    }

    @Test("red then green then red produces two distinct check event ids")
    func repeatedCheckTransitionsGetDistinctIDs() throws {
        let repo = makeRepo(alpha, stars: 10, checks: .success)
        let broken = makeRepo(alpha, stars: 10, checks: .failure)

        let failed = engine.diff(DiffInput(
            previousSnapshot: makeSnapshot(repositories: [repo]),
            currentSnapshot: makeSnapshot(repositories: [broken]),
            watermarks: [alpha: makeWatermark(stars: 10, checks: .success)],
            now: observation
        ))
        let recovered = engine.diff(DiffInput(
            previousSnapshot: makeSnapshot(repositories: [broken]),
            currentSnapshot: makeSnapshot(repositories: [repo]),
            watermarks: failed.watermarks,
            now: observation.addingTimeInterval(600)
        ))
        let failedAgain = engine.diff(DiffInput(
            previousSnapshot: makeSnapshot(repositories: [repo]),
            currentSnapshot: makeSnapshot(repositories: [broken]),
            watermarks: recovered.watermarks,
            now: observation.addingTimeInterval(1200)
        ))

        let firstID = try #require(failed.events.first?.id)
        let secondID = try #require(failedAgain.events.first?.id)
        #expect(recovered.events.map(\.kind) == [.checksRecovered])
        #expect(firstID != secondID)
    }

    @Test("events come out newest first across kinds")
    func eventsAreSortedNewestFirst() {
        let previous = makeSnapshot(repositories: [makeRepo(alpha, stars: 10)])
        let current = makeSnapshot(
            repositories: [makeRepo(alpha, stars: 11, forks: 1)],
            inboundIssues: [makeIssue(id: "I_1", number: 1, createdAt: t3)]
        )

        let result = engine.diff(DiffInput(
            previousSnapshot: previous,
            currentSnapshot: current,
            watermarks: [alpha: makeWatermark(stars: 10, newestStarredAt: t0, newestForkedAt: t0)],
            attribution: [alpha: RepoAttribution(
                stars: [star("nova", t1)],
                forks: [fork("orion", t2)]
            )],
            now: observation
        ))

        #expect(result.events.map(\.kind) == [.inboundIssue, .fork, .star])
        #expect(result.events.map(\.occurredAt) == [t3, t2, t1])
    }
}
