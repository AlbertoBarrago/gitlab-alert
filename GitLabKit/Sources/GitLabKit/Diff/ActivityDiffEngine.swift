import Foundation

public struct ActivityDiffEngine: ActivityDiffing {
    public init() {}

    public func diff(_ input: DiffInput) -> DiffResult {
        let current = input.currentSnapshot
        guard input.mode == .compare, let previous = input.previousSnapshot else {
            return DiffResult(watermarks: seeded(current.repositories, at: input.now))
        }

        var watermarks: [String: RepoWatermark] = [:]
        var events: [ActivityEvent] = []
        var newlySeeded = Set<String>()

        for repository in current.repositories {
            guard var watermark = input.watermarks[repository.nameWithOwner] else {
                watermarks[repository.nameWithOwner] = RepoWatermark(seeding: repository, at: input.now)
                newlySeeded.insert(repository.nameWithOwner)
                continue
            }
            if let event = pipelineTransition(repository: repository, previous: watermark.lastCheckState, current: repository.checkState, at: input.now) {
                events.append(event)
            }
            watermark.lastCheckState = repository.checkState

            let pushes = pushEvents(for: repository.nameWithOwner, in: current, after: watermark.pushCutoff)
            events.append(contentsOf: pushes.map(ActivityEvent.init(push:)))
            if let newest = pushes.map(\.occurredAt).max() {
                watermark.lastPushEventAt = newest
            }

            watermarks[repository.nameWithOwner] = watermark
        }

        events.append(contentsOf: workItemEvents(previous: previous, current: current, newlySeeded: newlySeeded, at: input.now))
        return DiffResult(events: events.sorted { $0.occurredAt > $1.occurredAt }, watermarks: watermarks)
    }

    /// Pushes are not diffed against the previous snapshot: GitLab already
    /// timestamped them, so the watermark is the only thing that decides what
    /// is new. The client has already dropped the user's own pushes.
    private func pushEvents(for repository: String, in snapshot: DashboardSnapshot, after cutoff: Date) -> [PushEvent] {
        snapshot.pushEvents.filter { $0.repository == repository && $0.occurredAt > cutoff }
    }

    private func seeded(_ repositories: [RepoSnapshot], at date: Date) -> [String: RepoWatermark] {
        Dictionary(uniqueKeysWithValues: repositories.map { ($0.nameWithOwner, RepoWatermark(seeding: $0, at: date)) })
    }

    private func pipelineTransition(repository: RepoSnapshot, previous: CheckState, current: CheckState, at date: Date) -> ActivityEvent? {
        guard previous != current else { return nil }
        if current.isBroken && !previous.isBroken {
            return ActivityEvent(id: "pipeline-failed|\(repository.nameWithOwner)|\(Int64(date.timeIntervalSince1970))", kind: .checksFailed, occurredAt: date, repository: repository.nameWithOwner, url: repository.url)
        }
        if previous.isBroken && current == .success {
            return ActivityEvent(id: "pipeline-recovered|\(repository.nameWithOwner)|\(Int64(date.timeIntervalSince1970))", kind: .checksRecovered, occurredAt: date, repository: repository.nameWithOwner, url: repository.url)
        }
        return nil
    }

    private func workItemEvents(previous: DashboardSnapshot, current: DashboardSnapshot, newlySeeded: Set<String>, at date: Date) -> [ActivityEvent] {
        let existingReviews = Set(previous.reviewRequested.map(\.id))
        let existingIssues = Set(previous.assignedIssues.map(\.id))
        return current.reviewRequested.compactMap { item in
            guard !existingReviews.contains(item.id), !newlySeeded.contains(item.repository) else { return nil }
            return ActivityEvent(id: "review|\(item.id)", kind: .reviewRequested, occurredAt: item.updatedAt, repository: item.repository, actors: item.author.map { [$0] } ?? [], title: item.title, url: item.url)
        } + current.assignedIssues.compactMap { item in
            guard !existingIssues.contains(item.id), !newlySeeded.contains(item.repository) else { return nil }
            return ActivityEvent(id: "issue|\(item.id)", kind: .inboundIssue, occurredAt: item.updatedAt, repository: item.repository, actors: item.author.map { [$0] } ?? [], title: item.title, url: item.url)
        }
    }
}
