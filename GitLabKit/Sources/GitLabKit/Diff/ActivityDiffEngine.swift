import Foundation

/// The concrete ``ActivityDiffing``: two snapshots and a set of watermarks in,
/// events plus the watermarks to persist out.
///
/// Everything here is a pure function of ``DiffInput``. There is no clock, no
/// storage and no actor, because every phantom or missing notification the user
/// will ever see is decided in this file and it has to be reproducible in a
/// test with fixed dates.
public struct ActivityDiffEngine: ActivityDiffing {
    public init() {}

    // MARK: - Cheap change detection

    /// Count-only scan: which repositories are worth spending an attribution
    /// request on. Repositories without a watermark are deliberately skipped —
    /// they are new and get seeded, and seeding never reports.
    public func changedRepositories(
        watermarks: [String: RepoWatermark],
        current: DashboardSnapshot
    ) -> [String] {
        current.repositories.compactMap { repo in
            guard let mark = watermarks[repo.nameWithOwner] else { return nil }
            let moved = repo.stargazerCount != mark.stargazerCount
                || repo.forkCount != mark.forkCount
            return moved ? repo.nameWithOwner : nil
        }
    }

    // MARK: - The diff

    public func diff(_ input: DiffInput) -> DiffResult {
        let current = input.currentSnapshot

        // Rule 1. `previousSnapshot == nil` is how a `PersistedState` without a
        // baseline reaches us (`hasBaseline == false` implies `lastSnapshot == nil`),
        // so it is treated exactly like `.baselineOnly`: seed and stay silent.
        guard input.mode == .compare, let previous = input.previousSnapshot else {
            return DiffResult(events: [], watermarks: seedAll(current, at: input.now))
        }

        var watermarks: [String: RepoWatermark] = [:]
        watermarks.reserveCapacity(current.repositories.count)
        var events: [ActivityEvent] = []
        // Repositories seeded on this very cycle. They must not report anything,
        // including inbound work items: widening the scope in Settings pulls in
        // repositories with a whole history attached.
        var newlySeeded: Set<String> = []

        for repo in current.repositories {
            let key = repo.nameWithOwner

            // Rule 2. First sighting: seed silently, even in `.compare` mode.
            guard var mark = input.watermarks[key] else {
                watermarks[key] = RepoWatermark(seeding: repo, at: input.now)
                newlySeeded.insert(key)
                continue
            }

            let attribution = input.attribution[key]

            // Rules 3, 5, 6.
            let stars = countedEvents(
                repository: key,
                kind: .star,
                delta: repo.stargazerCount - mark.stargazerCount,
                baseline: mark.newestStarredAt,
                records: (attribution?.stars ?? []).map { CountedRecord(actor: $0.actor, at: $0.starredAt) },
                now: input.now
            )
            events.append(contentsOf: stars.events)
            mark.newestStarredAt = later(mark.newestStarredAt, stars.advanceTo)
            mark.stargazerCount = repo.stargazerCount

            // Rule 4. Forks are the same shape on a different field.
            let forks = countedEvents(
                repository: key,
                kind: .fork,
                delta: repo.forkCount - mark.forkCount,
                baseline: mark.newestForkedAt,
                records: (attribution?.forks ?? []).map { CountedRecord(actor: $0.actor, at: $0.createdAt) },
                now: input.now
            )
            events.append(contentsOf: forks.events)
            mark.newestForkedAt = later(mark.newestForkedAt, forks.advanceTo)
            mark.forkCount = repo.forkCount

            // Rule 7.
            if let event = checkTransitionEvent(
                repository: key,
                from: mark.lastCheckState,
                to: repo.checkState,
                now: input.now
            ) {
                events.append(event)
            }
            // Recorded unconditionally, including the states that emit nothing:
            // otherwise a success → pending → success round trip would later be
            // compared against a stale `success` and misread as a transition.
            mark.lastCheckState = repo.checkState

            watermarks[key] = mark
        }

        // Rules 8 and 9.
        events.append(contentsOf: workItemEvents(
            previous: previous,
            current: current,
            newlySeeded: newlySeeded,
            now: input.now
        ))

        // Watermarks for repositories that left the snapshot are not carried
        // over: a repository deleted, renamed or filtered out of the scope must
        // not keep its row alive forever. If it comes back it is seeded again,
        // which is silent, so the worst case is one missed notification and
        // never a burst of phantom ones.
        let collapsed = collapse(events, limit: max(0, input.maxEventsPerRepo), now: input.now)
        return DiffResult(events: sortedNewestFirst(collapsed), watermarks: watermarks)
    }

    // MARK: - Seeding

    private func seedAll(_ snapshot: DashboardSnapshot, at date: Date) -> [String: RepoWatermark] {
        var seeded: [String: RepoWatermark] = [:]
        seeded.reserveCapacity(snapshot.repositories.count)
        for repo in snapshot.repositories {
            seeded[repo.nameWithOwner] = RepoWatermark(seeding: repo, at: date)
        }
        return seeded
    }

    // MARK: - Counted kinds (stars, forks)

    /// A star or a fork reduced to the two fields the counting rules need.
    private struct CountedRecord {
        let actor: GLActor
        let at: Date
    }

    /// Turns one repository's count delta plus whatever attribution we have into
    /// events, and reports how far the timestamp watermark may advance.
    ///
    /// The report size is driven by the **count**, and attribution only supplies
    /// names, because the count is authoritative and always present while the
    /// GraphQL attribution page can be missing, short or stale.
    private func countedEvents(
        repository: String,
        kind: ActivityKind,
        delta: Int,
        baseline: Date?,
        records: [CountedRecord],
        now: Date
    ) -> (events: [ActivityEvent], advanceTo: Date?) {
        // Strictly greater. Equality is the duplicate-notification bug: the
        // newest record we already reported comes back in every later page.
        let qualifying = records
            .filter { record in
                guard let baseline else { return true }
                return record.at > baseline
            }
            .sorted { lhs, rhs in
                if lhs.at != rhs.at { return lhs.at > rhs.at }
                return lhs.actor.login < rhs.actor.login
            }

        // Rule 13. The newest record we *saw*, reported or not, becomes the new
        // floor. A timestamp far in the future still advances it — a skewed
        // server clock costs us at most a missed name, whereas refusing to
        // advance would re-report the same record on every single cycle. And
        // because the floor only ever moves forward and is compared against
        // record timestamps, `now` jumping backwards cannot resurrect anything.
        let advanceTo = qualifying.first?.at

        let reportCount: Int
        if delta > 0 {
            reportCount = delta
        } else if delta == 0, baseline != nil {
            // Rule 6. A star followed by an unstar inside one cycle leaves the
            // count flat, so the count cannot see it. We prefer the timestamp
            // evidence and report it: the star did happen, the user's repository
            // did get noticed, and a record newer than the floor is proof. This
            // needs an established floor — with `baseline == nil` every
            // historical record in the page looks new, and reporting those is
            // the fresh-install burst rule 1 exists to prevent.
            reportCount = qualifying.count
        } else {
            // Rule 5. A negative delta (unstar, deleted fork) walks the counts
            // down and says nothing.
            reportCount = 0
        }

        guard reportCount > 0 else { return ([], advanceTo) }

        let named = Array(qualifying.prefix(reportCount))
        var events = named.map { record in
            ActivityEvent(
                id: namedEventID(kind: kind, repository: repository, login: record.actor.login, at: record.at),
                kind: kind,
                occurredAt: record.at,
                repository: repository,
                delta: 1,
                actors: [record.actor]
            )
        }

        // Attribution missing or short: the shortfall still gets reported, as a
        // single count-only event. The user learns "+3 stars" immediately and
        // the names arrive on a later cycle if they arrive at all.
        let shortfall = reportCount - named.count
        if shortfall > 0 {
            events.append(ActivityEvent(
                id: countOnlyEventID(kind: kind, repository: repository, at: now, delta: shortfall),
                kind: kind,
                // Rule 12. No record, therefore no real timestamp; `input.now`
                // is the only honest answer and it keeps the id deterministic.
                occurredAt: now,
                repository: repository,
                delta: shortfall,
                actors: []
            ))
        }

        return (events, advanceTo)
    }

    // MARK: - CI

    /// Rule 7. Only transitions between *settled* states are reported. A repo
    /// whose checks are queued or whose status GitLab has not answered for is
    /// not a red repo, and treating `.unknown`/`.pending` as signal is exactly
    /// how a naive implementation spams the user on every poll.
    private func checkTransitionEvent(
        repository: String,
        from previous: CheckState,
        to current: CheckState,
        now: Date
    ) -> ActivityEvent? {
        guard isSettled(previous), isSettled(current), previous != current else { return nil }

        let kind: ActivityKind
        if current.isBroken && !previous.isBroken {
            kind = .checksFailed
        } else if previous.isBroken && current == .success {
            kind = .checksRecovered
        } else {
            // `.failure` → `.error` and back: still broken, nothing new to say.
            return nil
        }

        return ActivityEvent(
            id: checkEventID(kind: kind, repository: repository, from: previous, to: current, at: now),
            kind: kind,
            // Rule 12. A rolled-up check state carries no timestamp of its own,
            // so the moment we observed it is the timestamp.
            occurredAt: now,
            repository: repository,
            delta: 1
        )
    }

    /// `.expected` joins `.pending`/`.unknown` here: a required check that has
    /// not reported yet is a promise, not a verdict.
    private func isSettled(_ state: CheckState) -> Bool {
        state == .success || state.isBroken
    }

    // MARK: - Work items

    private func workItemEvents(
        previous: DashboardSnapshot,
        current: DashboardSnapshot,
        newlySeeded: Set<String>,
        now: Date
    ) -> [ActivityEvent] {
        var events: [ActivityEvent] = []

        // Rule 8. Ids only — titles get edited and list positions shuffle on
        // every poll, node ids do not.
        let previousReviewRequests = Set(previous.reviewRequested.map(\.id))
        var reportedAsReviewRequest: Set<String> = []
        for pull in current.reviewRequested where !previousReviewRequests.contains(pull.id) {
            reportedAsReviewRequest.insert(pull.id)
            events.append(ActivityEvent(
                id: workItemEventID(kind: .reviewRequested, repository: pull.repository, nodeID: pull.id),
                kind: .reviewRequested,
                // Rule 12. GitLab does not tell us when the review was
                // requested; `updatedAt` is the closest real timestamp on the
                // item and is never invented.
                occurredAt: pull.updatedAt,
                repository: pull.repository,
                delta: 1,
                actors: pull.author.map { [$0] } ?? [],
                title: pull.title,
                url: pull.url
            ))
        }

        // Rule 9, issues.
        let previousInboundIssues = Set(previous.inboundIssues.map(\.id))
        for issue in current.inboundIssues
        where !previousInboundIssues.contains(issue.id) && !newlySeeded.contains(issue.repository) {
            events.append(ActivityEvent(
                id: workItemEventID(kind: .inboundIssue, repository: issue.repository, nodeID: issue.id),
                kind: .inboundIssue,
                occurredAt: issue.createdAt,
                repository: issue.repository,
                delta: 1,
                actors: issue.author.map { [$0] } ?? [],
                title: issue.title,
                url: issue.url
            ))
        }

        // Rule 9, merge requests. "On a watched repository" means present in the
        // snapshot's repository set, so a MR against someone else's project the
        // user happens to be reviewing is not an inbound contribution.
        let watched = Set(current.repositories.map(\.nameWithOwner))
        let viewer = current.profile.login
        let previouslyKnownPulls = Set(
            (previous.reviewRequested + previous.authoredMergeRequests).map(\.id)
        )
        var handled: Set<String> = reportedAsReviewRequest
        for pull in current.reviewRequested + current.authoredMergeRequests {
            guard !handled.contains(pull.id) else { continue }
            guard let author = pull.author, author.login != viewer else { continue }
            guard watched.contains(pull.repository), !newlySeeded.contains(pull.repository) else { continue }
            guard !previouslyKnownPulls.contains(pull.id) else { continue }
            handled.insert(pull.id)
            events.append(ActivityEvent(
                id: workItemEventID(kind: .inboundMergeRequest, repository: pull.repository, nodeID: pull.id),
                kind: .inboundMergeRequest,
                occurredAt: pull.createdAt,
                repository: pull.repository,
                delta: 1,
                actors: [author],
                title: pull.title,
                url: pull.url
            ))
        }

        return events
    }

    // MARK: - Collapsing

    /// Rule 10. More than `limit` events of one kind on one repository in one
    /// cycle become a single summary event carrying the full count and as many
    /// names as we managed to attribute.
    private func collapse(_ events: [ActivityEvent], limit: Int, now: Date) -> [ActivityEvent] {
        guard !events.isEmpty else { return events }

        // Grouping keeps first-seen order so the output is stable before sorting.
        var order: [String] = []
        var groups: [String: [ActivityEvent]] = [:]
        for event in events {
            let key = "\(event.repository)\u{1}\(event.kind.rawValue)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(event)
        }

        var result: [ActivityEvent] = []
        for key in order {
            guard let group = groups[key], let first = group.first else { continue }
            guard group.count > limit else {
                result.append(contentsOf: group)
                continue
            }

            let total = group.reduce(0) { $0 + $1.delta }
            let occurredAt = group.map(\.occurredAt).max() ?? now
            var seenLogins: Set<String> = []
            var actors: [GLActor] = []
            for event in group.sorted(by: { $0.occurredAt > $1.occurredAt }) {
                for actor in event.actors where !seenLogins.contains(actor.login) {
                    seenLogins.insert(actor.login)
                    actors.append(actor)
                }
            }

            result.append(ActivityEvent(
                id: summaryEventID(kind: first.kind, repository: first.repository, at: occurredAt, delta: total),
                kind: first.kind,
                occurredAt: occurredAt,
                repository: first.repository,
                delta: total,
                actors: actors
            ))
        }
        return result
    }

    // MARK: - Ordering

    /// Rule 12. Newest first, with the id as tie-break so two runs on the same
    /// input produce the same array and not merely the same set.
    private func sortedNewestFirst(_ events: [ActivityEvent]) -> [ActivityEvent] {
        events.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Identity

    /// Rule 11. Ids are derived, never generated: `seenEventIDs` can only
    /// recognise a re-delivered event if the same input yields the same id, so
    /// `UUID()` is not an option. Milliseconds since the epoch are enough
    /// resolution to separate two records from the same actor.
    private func stamp(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }

    private func namedEventID(kind: ActivityKind, repository: String, login: String, at: Date) -> String {
        "\(kind.rawValue)|\(repository)|\(login)|\(stamp(at))"
    }

    private func countOnlyEventID(kind: ActivityKind, repository: String, at: Date, delta: Int) -> String {
        "\(kind.rawValue)|\(repository)|count|\(stamp(at))|\(delta)"
    }

    private func summaryEventID(kind: ActivityKind, repository: String, at: Date, delta: Int) -> String {
        "\(kind.rawValue)|\(repository)|summary|\(stamp(at))|\(delta)"
    }

    private func checkEventID(
        kind: ActivityKind,
        repository: String,
        from previous: CheckState,
        to current: CheckState,
        at: Date
    ) -> String {
        // The observation time is part of the id on purpose: red → green → red
        // is two distinct events the user must see twice.
        "\(kind.rawValue)|\(repository)|\(previous.rawValue)->\(current.rawValue)|\(stamp(at))"
    }

    private func workItemEventID(kind: ActivityKind, repository: String, nodeID: String) -> String {
        "\(kind.rawValue)|\(repository)|\(nodeID)"
    }

    // MARK: - Small helpers

    private func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (let lhs?, let rhs?): return max(lhs, rhs)
        case (let lhs?, nil): return lhs
        case (nil, let rhs?): return rhs
        case (nil, nil): return nil
        }
    }
}
