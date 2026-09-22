import Foundation

/// What one project contributed to the observed window.
///
/// Every number here is a count of things the app actually saw. It is not a
/// view of the project's whole CI history: the app only records transitions it
/// witnessed while running, and only for projects in scope. `failures` is "how
/// many times this went red while the app was watching", never "how many
/// pipelines failed" — the app never sees a run that did not change the state.
public struct ProjectReport: Sendable, Hashable, Identifiable {
    public var repository: String
    /// Times the pipeline went from healthy to broken.
    public var failures: Int
    /// Times it came back.
    public var recoveries: Int
    /// Mean of failure → recovery, over the pairs that closed inside the
    /// window. A failure still unresolved contributes nothing rather than a
    /// guess.
    public var meanTimeToRecovery: TimeInterval?
    /// Review requests that arrived during the window.
    public var reviewRequests: Int
    /// Issues and merge requests opened by other people on this project.
    public var inboundItems: Int
    /// Open right now, from the last snapshot.
    public var openReviews: Int
    public var openIssues: Int
    /// Pushes by other people, from the activity log.
    public var pushes: Int
    /// Whether the last snapshot has it red.
    public var isBroken: Bool
    public var lastFailureAt: Date?

    public var id: String { repository }

    /// Everything the log holds for this project, which is what "busiest"
    /// means below.
    public var events: Int { failures + recoveries + reviewRequests + inboundItems + pushes }

    public init(
        repository: String,
        failures: Int = 0,
        recoveries: Int = 0,
        meanTimeToRecovery: TimeInterval? = nil,
        reviewRequests: Int = 0,
        inboundItems: Int = 0,
        openReviews: Int = 0,
        openIssues: Int = 0,
        pushes: Int = 0,
        isBroken: Bool = false,
        lastFailureAt: Date? = nil
    ) {
        self.repository = repository
        self.failures = failures
        self.recoveries = recoveries
        self.meanTimeToRecovery = meanTimeToRecovery
        self.reviewRequests = reviewRequests
        self.inboundItems = inboundItems
        self.openReviews = openReviews
        self.openIssues = openIssues
        self.pushes = pushes
        self.isBroken = isBroken
        self.lastFailureAt = lastFailureAt
    }
}

/// An item that has been open the longest, with enough to render a row.
public struct ReportOpenItem: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case review
        case issue
    }

    public var kind: Kind
    public var title: String
    public var repository: String
    public var openedAt: Date
    public var url: URL

    public init(kind: Kind, title: String, repository: String, openedAt: Date, url: URL) {
        self.kind = kind
        self.title = title
        self.repository = repository
        self.openedAt = openedAt
        self.url = url
    }
}

/// The report itself: where the work and the breakage concentrate.
public struct ActivityReport: Sendable, Hashable {
    public var generatedAt: Date
    /// Oldest event still in the log. The log is capped, so this is the real
    /// horizon of every count below — stating it is the difference between a
    /// number and a misleading number.
    public var observedFrom: Date?
    /// Sorted: most failures first, then busiest, then by name.
    public var projects: [ProjectReport]
    public var totalFailures: Int
    public var totalRecoveries: Int
    public var meanTimeToRecovery: TimeInterval?
    /// Red right now, from the last snapshot.
    public var brokenNow: [String]
    public var oldestOpenItem: ReportOpenItem?

    public var isEmpty: Bool { projects.isEmpty && oldestOpenItem == nil }

    /// The project that went red most often, and only when something did.
    public var mostBroken: ProjectReport? {
        projects.first { $0.failures > 0 }
    }

    /// The project with the most recorded activity of any kind.
    public var busiest: ProjectReport? {
        projects.max { $0.events < $1.events }.flatMap { $0.events > 0 ? $0 : nil }
    }

    public init(
        generatedAt: Date,
        observedFrom: Date? = nil,
        projects: [ProjectReport] = [],
        totalFailures: Int = 0,
        totalRecoveries: Int = 0,
        meanTimeToRecovery: TimeInterval? = nil,
        brokenNow: [String] = [],
        oldestOpenItem: ReportOpenItem? = nil
    ) {
        self.generatedAt = generatedAt
        self.observedFrom = observedFrom
        self.projects = projects
        self.totalFailures = totalFailures
        self.totalRecoveries = totalRecoveries
        self.meanTimeToRecovery = meanTimeToRecovery
        self.brokenNow = brokenNow
        self.oldestOpenItem = oldestOpenItem
    }
}

/// Builds ``ActivityReport`` from state the app already holds.
///
/// Pure and synchronous on purpose: it reads the last snapshot and the activity
/// log, and makes no request of its own. Everything it reports was already
/// fetched for the dashboard, so opening the report costs nothing in API budget
/// and adds nothing to what the app stores.
public enum ReportEngine {

    public static func make(
        snapshot: DashboardSnapshot?,
        activityLog: [ActivityEvent],
        now: Date = Date()
    ) -> ActivityReport {
        var reports: [String: ProjectReport] = [:]

        func mutate(_ repository: String, _ body: (inout ProjectReport) -> Void) {
            var report = reports[repository] ?? ProjectReport(repository: repository)
            body(&report)
            reports[repository] = report
        }

        for event in activityLog {
            mutate(event.repository) { report in
                switch event.kind {
                case .checksFailed:
                    report.failures += 1
                    report.lastFailureAt = max(report.lastFailureAt ?? event.occurredAt, event.occurredAt)
                case .checksRecovered:
                    report.recoveries += 1
                case .reviewRequested:
                    report.reviewRequests += 1
                case .inboundIssue, .inboundMergeRequest:
                    report.inboundItems += 1
                case .pushed:
                    report.pushes += 1
                }
            }
        }

        for (repository, mean) in meanTimesToRecovery(activityLog) {
            mutate(repository) { $0.meanTimeToRecovery = mean }
        }

        if let snapshot {
            for item in snapshot.reviewRequested {
                mutate(item.repository) { $0.openReviews += 1 }
            }
            for item in snapshot.assignedIssues + snapshot.inboundIssues {
                mutate(item.repository) { $0.openIssues += 1 }
            }
            for repository in snapshot.repositories where repository.checkState.isBroken {
                mutate(repository.nameWithOwner) { $0.isBroken = true }
            }
        }

        let projects = reports.values.sorted { left, right in
            if left.failures != right.failures { return left.failures > right.failures }
            if left.events != right.events { return left.events > right.events }
            return left.repository.localizedCaseInsensitiveCompare(right.repository) == .orderedAscending
        }

        let closed = closedRecoveryIntervals(activityLog)

        return ActivityReport(
            generatedAt: now,
            observedFrom: activityLog.map(\.occurredAt).min(),
            projects: projects,
            totalFailures: projects.reduce(0) { $0 + $1.failures },
            totalRecoveries: projects.reduce(0) { $0 + $1.recoveries },
            meanTimeToRecovery: closed.isEmpty ? nil : closed.reduce(0, +) / Double(closed.count),
            brokenNow: projects.filter(\.isBroken).map(\.repository),
            oldestOpenItem: oldestOpenItem(in: snapshot)
        )
    }

    // MARK: - Recovery pairing

    /// Pairs each failure with the first recovery that follows it on the same
    /// project. Two failures in a row count once: the project was already red,
    /// so the second is not a new outage.
    private static func closedRecoveryIntervals(_ log: [ActivityEvent]) -> [TimeInterval] {
        intervalsByRepository(log).values.flatMap { $0 }
    }

    private static func meanTimesToRecovery(_ log: [ActivityEvent]) -> [String: TimeInterval] {
        intervalsByRepository(log).compactMapValues { intervals in
            intervals.isEmpty ? nil : intervals.reduce(0, +) / Double(intervals.count)
        }
    }

    private static func intervalsByRepository(_ log: [ActivityEvent]) -> [String: [TimeInterval]] {
        var intervals: [String: [TimeInterval]] = [:]
        var brokenSince: [String: Date] = [:]

        // The log is newest-first; recovery only means something after the
        // failure it closes.
        for event in log.sorted(by: { $0.occurredAt < $1.occurredAt }) {
            switch event.kind {
            case .checksFailed:
                if brokenSince[event.repository] == nil {
                    brokenSince[event.repository] = event.occurredAt
                }
            case .checksRecovered:
                guard let since = brokenSince.removeValue(forKey: event.repository) else { continue }
                intervals[event.repository, default: []].append(event.occurredAt.timeIntervalSince(since))
            default:
                continue
            }
        }
        return intervals
    }

    // MARK: - Oldest open item

    private static func oldestOpenItem(in snapshot: DashboardSnapshot?) -> ReportOpenItem? {
        guard let snapshot else { return nil }

        let reviews = snapshot.reviewRequested.map {
            ReportOpenItem(kind: .review, title: $0.title, repository: $0.repository, openedAt: $0.createdAt, url: $0.url)
        }
        let issues = (snapshot.assignedIssues + snapshot.inboundIssues).map {
            ReportOpenItem(kind: .issue, title: $0.title, repository: $0.repository, openedAt: $0.createdAt, url: $0.url)
        }
        return (reviews + issues).min { $0.openedAt < $1.openedAt }
    }
}
