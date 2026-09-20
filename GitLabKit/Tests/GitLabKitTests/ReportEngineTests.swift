import Foundation
import Testing

@testable import GitLabKit

@Suite("ReportEngine")
struct ReportEngineTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(
        _ kind: ActivityKind,
        _ repository: String,
        at offset: TimeInterval,
        id: String = UUID().uuidString
    ) -> ActivityEvent {
        ActivityEvent(id: id, kind: kind, occurredAt: start.addingTimeInterval(offset), repository: repository)
    }

    private func mergeRequest(_ repository: String, createdAt offset: TimeInterval, title: String = "MR") -> MergeRequestItem {
        MergeRequestItem(
            id: "\(repository)#\(offset)",
            number: 1,
            title: title,
            repository: repository,
            url: URL(string: "https://gitlab.example.com/\(repository)/-/merge_requests/1")!,
            createdAt: start.addingTimeInterval(offset),
            updatedAt: start.addingTimeInterval(offset)
        )
    }

    private func issue(_ repository: String, createdAt offset: TimeInterval, title: String = "Issue") -> IssueItem {
        IssueItem(
            id: "issue-\(repository)#\(offset)",
            number: 2,
            title: title,
            repository: repository,
            url: URL(string: "https://gitlab.example.com/\(repository)/-/issues/2")!,
            createdAt: start.addingTimeInterval(offset),
            updatedAt: start.addingTimeInterval(offset)
        )
    }

    private func snapshot(
        reviews: [MergeRequestItem] = [],
        issues: [IssueItem] = [],
        repositories: [RepoSnapshot] = []
    ) -> DashboardSnapshot {
        DashboardSnapshot(
            fetchedAt: start,
            profile: Profile(login: "alice", name: "Alice", avatarURL: nil, url: URL(string: "https://gitlab.example.com/alice")!),
            reviewRequested: reviews,
            assignedIssues: issues,
            repositories: repositories
        )
    }

    @Test("no data reports nothing rather than zeroes")
    func emptyStateIsEmpty() {
        let report = ReportEngine.make(snapshot: nil, activityLog: [], now: start)
        #expect(report.isEmpty)
        #expect(report.observedFrom == nil)
        #expect(report.meanTimeToRecovery == nil)
        #expect(report.mostBroken == nil)
    }

    @Test("failures and recoveries are counted per project")
    func countsPerProject() {
        let log = [
            event(.checksFailed, "alice/one", at: 0),
            event(.checksRecovered, "alice/one", at: 600),
            event(.checksFailed, "alice/one", at: 1_200),
            event(.checksFailed, "alice/two", at: 300),
            event(.reviewRequested, "alice/two", at: 400),
            event(.inboundIssue, "alice/two", at: 500)
        ]
        let report = ReportEngine.make(snapshot: nil, activityLog: log, now: start)

        let one = try! #require(report.projects.first { $0.repository == "alice/one" })
        #expect(one.failures == 2)
        #expect(one.recoveries == 1)

        let two = try! #require(report.projects.first { $0.repository == "alice/two" })
        #expect(two.failures == 1)
        #expect(two.reviewRequests == 1)
        #expect(two.inboundItems == 1)

        #expect(report.totalFailures == 3)
        #expect(report.totalRecoveries == 1)
        // Most failures first.
        #expect(report.projects.first?.repository == "alice/one")
        #expect(report.mostBroken?.repository == "alice/one")
    }

    @Test("mean time to recovery pairs a failure with the recovery that follows")
    func meanTimeToRecovery() {
        let log = [
            event(.checksFailed, "alice/one", at: 0),
            event(.checksRecovered, "alice/one", at: 600),
            event(.checksFailed, "alice/one", at: 1_000),
            event(.checksRecovered, "alice/one", at: 1_400)
        ]
        let report = ReportEngine.make(snapshot: nil, activityLog: log, now: start)

        #expect(report.projects.first?.meanTimeToRecovery == 500)
        #expect(report.meanTimeToRecovery == 500)
    }

    /// A project that is already red does not start a second outage, or the
    /// mean would be measured from the wrong moment.
    @Test("a second failure while still broken does not restart the clock")
    func consecutiveFailuresMeasureFromTheFirst() {
        let log = [
            event(.checksFailed, "alice/one", at: 0),
            event(.checksFailed, "alice/one", at: 300),
            event(.checksRecovered, "alice/one", at: 900)
        ]
        let report = ReportEngine.make(snapshot: nil, activityLog: log, now: start)
        #expect(report.projects.first?.meanTimeToRecovery == 900)
    }

    @Test("an unresolved failure contributes no recovery time")
    func openOutageIsNotAveraged() {
        let log = [event(.checksFailed, "alice/one", at: 0)]
        let report = ReportEngine.make(snapshot: nil, activityLog: log, now: start.addingTimeInterval(9_000))

        #expect(report.projects.first?.failures == 1)
        #expect(report.projects.first?.meanTimeToRecovery == nil)
        #expect(report.meanTimeToRecovery == nil)
    }

    /// The log is stored newest-first; pairing must not depend on that order.
    @Test("pairing does not depend on the log's order")
    func orderIndependentPairing() {
        let ordered = [
            event(.checksFailed, "alice/one", at: 0, id: "f"),
            event(.checksRecovered, "alice/one", at: 600, id: "r")
        ]
        let forwards = ReportEngine.make(snapshot: nil, activityLog: ordered, now: start)
        let backwards = ReportEngine.make(snapshot: nil, activityLog: ordered.reversed(), now: start)

        #expect(forwards.meanTimeToRecovery == backwards.meanTimeToRecovery)
        #expect(backwards.meanTimeToRecovery == 600)
    }

    @Test("open work and current breakage come from the snapshot")
    func snapshotContributesOpenWork() {
        let snapshot = snapshot(
            reviews: [mergeRequest("alice/one", createdAt: -86_400)],
            issues: [issue("alice/two", createdAt: -172_800)],
            repositories: [
                RepoSnapshot(nameWithOwner: "alice/one", checkState: .failure, url: URL(string: "https://gitlab.example.com/alice/one")!),
                RepoSnapshot(nameWithOwner: "alice/two", checkState: .success, url: URL(string: "https://gitlab.example.com/alice/two")!)
            ]
        )
        let report = ReportEngine.make(snapshot: snapshot, activityLog: [], now: start)

        #expect(report.projects.first { $0.repository == "alice/one" }?.openReviews == 1)
        #expect(report.projects.first { $0.repository == "alice/two" }?.openIssues == 1)
        #expect(report.brokenNow == ["alice/one"])
        #expect(!report.isEmpty)
    }

    @Test("the oldest open item wins across reviews and issues")
    func oldestOpenItemAcrossKinds() {
        let snapshot = snapshot(
            reviews: [mergeRequest("alice/one", createdAt: -86_400, title: "Younger review")],
            issues: [issue("alice/two", createdAt: -864_000, title: "Ancient issue")]
        )
        let report = ReportEngine.make(snapshot: snapshot, activityLog: [], now: start)

        #expect(report.oldestOpenItem?.title == "Ancient issue")
        #expect(report.oldestOpenItem?.kind == .issue)
        #expect(report.oldestOpenItem?.repository == "alice/two")
    }

    @Test("the observed window starts at the oldest event in the log")
    func observedWindowIsStated() {
        let log = [
            event(.checksFailed, "alice/one", at: 5_000),
            event(.reviewRequested, "alice/one", at: 1_000)
        ]
        let report = ReportEngine.make(snapshot: nil, activityLog: log, now: start)
        #expect(report.observedFrom == start.addingTimeInterval(1_000))
    }
}
