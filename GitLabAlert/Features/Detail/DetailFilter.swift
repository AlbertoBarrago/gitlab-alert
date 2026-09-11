import Foundation
import GitLabKit

// The detail window's data model: pure values, no SwiftUI, no AppModel.
//
// Everything the window renders is reduced to one row type and filtered by one
// value type. That is deliberate: a `Table` needs a single `RowValue`, and
// keeping the reduction and the filtering out of the views is what makes the
// interesting part (matching, sorting, notification routing) reasonable to read
// and testable without a window on screen.

// MARK: - Target

/// What the sidebar has selected. A section, or one watched repository.
enum DetailTarget: Hashable, Sendable, Identifiable {
    case section(DashboardSection)
    case repository(String)

    var id: String {
        switch self {
        case .section(let section): return "section:\(section.rawValue)"
        case .repository(let name): return "repository:\(name)"
        }
    }

    var title: String {
        switch self {
        case .section(let section): return section.title
        case .repository(let name): return name
        }
    }

    var symbolName: String {
        switch self {
        case .section(let section): return section.symbolName
        case .repository: return "shippingbox"
        }
    }

    /// Which set of columns suits this target. A repository shows everything
    /// about one repository, so it gets the mixed layout.
    var tableStyle: DetailTableStyle {
        switch self {
        case .repository: return .mixed
        case .section(let section):
            switch section {
            case .reviewRequested, .authoredMergeRequests: return .mergeRequests
            case .assignedIssues, .inboundIssues: return .issues
            case .repositories: return .repositories
            case .activity: return .activity
            }
        }
    }
}

/// The column layouts the content column can show. `Table` column lists cannot
/// be built conditionally below macOS 14.4, so each style is its own `Table`.
enum DetailTableStyle: Hashable, Sendable {
    case mergeRequests
    case issues
    case repositories
    case activity
    case mixed
}

// MARK: - Row

/// One line in the content table, whatever it was built from.
///
/// Flat and pre-rendered on purpose: the search haystack and the sort keys are
/// computed once when the row is built, so neither a keystroke nor a sort has
/// to touch a model object or allocate a string per comparison.
struct DetailRow: Identifiable, Hashable, Sendable {

    enum Kind: String, Hashable, Sendable {
        case mergeRequest
        case issue
        case repository
        case activity

        var label: String {
            switch self {
            case .mergeRequest: return "Merge request"
            case .issue: return "Issue"
            case .repository: return "Repository"
            case .activity: return "Activity"
            }
        }

        var symbolName: String {
            switch self {
            case .mergeRequest: return "arrow.triangle.branch"
            case .issue: return "smallcircle.filled.circle"
            case .repository: return "shippingbox"
            case .activity: return "sparkles"
            }
        }
    }

    /// The underlying model's own id — GraphQL node id, `owner/name`, or the
    /// diff engine's derived event id. Kept raw rather than namespaced so a
    /// notification's item id matches a row id directly.
    var id: String
    var kind: Kind
    var repository: String
    var title: String
    /// Second line where the row has one: a fork's new name, who starred.
    var subtitle: String?
    var number: Int?
    var author: GLActor?
    var url: URL?
    var createdAt: Date
    var updatedAt: Date
    var isDraft: Bool
    var isPrivate: Bool
    var reviewDecision: ReviewDecision?
    var checkState: CheckState?
    var labels: [String]
    var commentCount: Int?
    var stargazerCount: Int?
    var forkCount: Int?
    var openIssueCount: Int?
    var openMergeRequestCount: Int?
    var activityKind: ActivityKind?
    var actors: [GLActor]
    var delta: Int?
    var isUnread: Bool

    /// Lowercased, space-joined text the search matches against. Built once.
    let haystack: String

    init(
        id: String,
        kind: Kind,
        repository: String,
        title: String,
        subtitle: String? = nil,
        number: Int? = nil,
        author: GLActor? = nil,
        url: URL? = nil,
        createdAt: Date,
        updatedAt: Date,
        isDraft: Bool = false,
        isPrivate: Bool = false,
        reviewDecision: ReviewDecision? = nil,
        checkState: CheckState? = nil,
        labels: [String] = [],
        commentCount: Int? = nil,
        stargazerCount: Int? = nil,
        forkCount: Int? = nil,
        openIssueCount: Int? = nil,
        openMergeRequestCount: Int? = nil,
        activityKind: ActivityKind? = nil,
        actors: [GLActor] = [],
        delta: Int? = nil,
        isUnread: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.repository = repository
        self.title = title
        self.subtitle = subtitle
        self.number = number
        self.author = author
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDraft = isDraft
        self.isPrivate = isPrivate
        self.reviewDecision = reviewDecision
        self.checkState = checkState
        self.labels = labels
        self.commentCount = commentCount
        self.stargazerCount = stargazerCount
        self.forkCount = forkCount
        self.openIssueCount = openIssueCount
        self.openMergeRequestCount = openMergeRequestCount
        self.activityKind = activityKind
        self.actors = actors
        self.delta = delta
        self.isUnread = isUnread

        var parts: [String] = [repository, title]
        if let subtitle { parts.append(subtitle) }
        if let number { parts.append("#\(number)") }
        if let author { parts.append(author.login) }
        parts.append(contentsOf: actors.map(\.login))
        parts.append(contentsOf: labels)
        if let activityKind { parts.append(DetailLabels.name(for: activityKind)) }
        self.haystack = parts.joined(separator: " ").lowercased()
    }

    // MARK: Display

    var authorLogin: String { author?.login ?? actors.first?.login ?? "" }

    /// The single "state" word a narrow column can show, and the key the state
    /// column sorts on.
    var stateLabel: String {
        switch kind {
        case .mergeRequest:
            if isDraft { return "Draft" }
            return reviewDecision.map(DetailLabels.name(for:)) ?? "Open"
        case .issue:
            return labels.first ?? "Open"
        case .repository:
            return checkState.map(DetailLabels.name(for:)) ?? "Unknown"
        case .activity:
            return activityKind.map(DetailLabels.name(for:)) ?? "Activity"
        }
    }

    /// Spoken description of the whole row, so VoiceOver reads something
    /// meaningful instead of walking six unlabelled cells.
    var accessibilityDescription: String {
        var parts: [String] = [kind.label, title, "in \(repository)"]
        if let number { parts.append("number \(number)") }
        if !authorLogin.isEmpty { parts.append("by \(authorLogin)") }
        parts.append(stateLabel)
        return parts.joined(separator: ", ")
    }
}

/// Display vocabulary for the GitLabKit enums.
///
/// Deliberately a namespace rather than extensions on `ActivityKind`,
/// `CheckState` and `ReviewDecision`: those types belong to GitLabKit, three
/// surfaces of this app render them, and two files adding a `symbolName` to the
/// same enum is a module-wide redeclaration. Each surface names its own.
enum DetailLabels {

    static func name(for kind: ActivityKind) -> String {
        switch kind {
        case .star: return "Star"
        case .fork: return "Fork"
        case .checksFailed: return "Checks failed"
        case .checksRecovered: return "Checks recovered"
        case .reviewRequested: return "Review requested"
        case .inboundIssue: return "New issue"
        case .inboundMergeRequest: return "New merge request"
        }
    }

    /// All of these ship with macOS 14.
    static func symbol(for kind: ActivityKind) -> String {
        switch kind {
        case .star: return "star.fill"
        case .fork: return "tuningfork"
        case .checksFailed: return "xmark.octagon.fill"
        case .checksRecovered: return "checkmark.seal.fill"
        case .reviewRequested: return "eyeglasses"
        case .inboundIssue: return "tray.and.arrow.down.fill"
        case .inboundMergeRequest: return "arrow.triangle.branch"
        }
    }

    static func name(for state: CheckState) -> String {
        switch state {
        case .success: return "Passing"
        case .failure: return "Failing"
        case .error: return "Errored"
        case .pending: return "Running"
        case .expected: return "Expected"
        case .unknown: return "No checks"
        }
    }

    static func name(for decision: ReviewDecision) -> String {
        switch decision {
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .reviewRequired: return "Review required"
        case .none: return "No review"
        }
    }
}

// MARK: - Sorting

/// Sort order for the content table.
///
/// A hand-written comparator rather than `KeyPathComparator` because the sort
/// keys are optional and kind-dependent (a repository has stars, a merge request
/// has a review decision) and because every sort must be total: ties fall back
/// to newest-first and then to the id, so identical data always produces
/// identical row order and the `Table` never reshuffles rows under the cursor.
struct DetailRowComparator: SortComparator, Hashable, Sendable {

    enum Field: String, Hashable, Sendable, CaseIterable {
        case repository
        case title
        case author
        case created
        case updated
        case state
        case kind
        case stars
        case forks
        case openIssues
        case openMergeRequests
        case comments
    }

    var field: Field
    var order: SortOrder = .forward

    init(field: Field, order: SortOrder = .forward) {
        self.field = field
        self.order = order
    }

    func compare(_ lhs: DetailRow, _ rhs: DetailRow) -> ComparisonResult {
        let primary = Self.compareField(field, lhs, rhs)
        let result = primary == .orderedSame ? Self.tieBreak(lhs, rhs) : primary
        return order == .forward ? result : result.reversed
    }

    private static func compareField(_ field: Field, _ lhs: DetailRow, _ rhs: DetailRow) -> ComparisonResult {
        switch field {
        case .repository: return compareText(lhs.repository, rhs.repository)
        case .title: return compareText(lhs.title, rhs.title)
        case .author: return compareText(lhs.authorLogin, rhs.authorLogin)
        case .created: return compareDate(lhs.createdAt, rhs.createdAt)
        case .updated: return compareDate(lhs.updatedAt, rhs.updatedAt)
        case .state: return compareText(lhs.stateLabel, rhs.stateLabel)
        case .kind: return compareText(lhs.kind.label, rhs.kind.label)
        case .stars: return compareNumber(lhs.stargazerCount, rhs.stargazerCount)
        case .forks: return compareNumber(lhs.forkCount, rhs.forkCount)
        case .openIssues: return compareNumber(lhs.openIssueCount, rhs.openIssueCount)
        case .openMergeRequests: return compareNumber(lhs.openMergeRequestCount, rhs.openMergeRequestCount)
        case .comments: return compareNumber(lhs.commentCount, rhs.commentCount)
        }
    }

    /// Newest first, then id: the tie-break that makes the sort stable.
    private static func tieBreak(_ lhs: DetailRow, _ rhs: DetailRow) -> ComparisonResult {
        let byDate = compareDate(rhs.updatedAt, lhs.updatedAt)
        return byDate == .orderedSame ? compareText(lhs.id, rhs.id) : byDate
    }

    private static func compareText(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.localizedCaseInsensitiveCompare(rhs)
    }

    private static func compareDate(_ lhs: Date, _ rhs: Date) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    /// A missing count sorts below a present one rather than as zero: "this row
    /// has no such number" is not the same statement as "this row has none".
    private static func compareNumber(_ lhs: Int?, _ rhs: Int?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case (let l?, let r?):
            if l == r { return .orderedSame }
            return l < r ? .orderedAscending : .orderedDescending
        }
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

// MARK: - Facets

/// The one-click narrowings offered above the table. Which ones are offered
/// depends on the target; the semantics per row kind are defined once, here.
enum DetailFacet: String, Hashable, Sendable, CaseIterable, Identifiable {
    case all
    case attention
    case failing
    case drafts
    case unread

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .attention: return "Needs attention"
        case .failing: return "Failing"
        case .drafts: return "Drafts"
        case .unread: return "Unread"
        }
    }

    func matches(_ row: DetailRow) -> Bool {
        switch self {
        case .all:
            return true
        case .attention:
            switch row.kind {
            case .mergeRequest:
                guard !row.isDraft else { return false }
                return row.reviewDecision != .approved || row.checkState?.isBroken == true
            case .issue:
                // Nobody has replied yet: the maintainer-relevant definition of
                // an issue still waiting on a human.
                return (row.commentCount ?? 0) == 0
            case .repository:
                return row.checkState?.isBroken == true
            case .activity:
                return row.isUnread
            }
        case .failing:
            return row.checkState?.isBroken == true
        case .drafts:
            return row.isDraft
        case .unread:
            return row.isUnread
        }
    }

    /// Facets worth offering for a given layout. `.all` is always first.
    static func available(for style: DetailTableStyle) -> [DetailFacet] {
        switch style {
        case .mergeRequests: return [.all, .attention, .failing, .drafts]
        case .issues: return [.all, .attention]
        case .repositories: return [.all, .failing]
        case .activity: return [.all, .unread]
        case .mixed: return [.all, .attention, .failing]
        }
    }
}

// MARK: - Filter

/// Search text, facet and sort order for the content table — and the pure
/// reduction that turns the full row set into what the table shows.
struct DetailFilter: Hashable, Sendable {
    var searchText: String = ""
    var facet: DetailFacet = .all
    var sort: [DetailRowComparator] = [DetailRowComparator(field: .updated, order: .reverse)]

    /// True when something is hiding rows, so an empty result can be explained
    /// as "nothing matches" rather than "nothing exists".
    var isNarrowing: Bool {
        facet != .all || !searchTokens.isEmpty
    }

    /// Whitespace-split, lowercased query terms. All terms must match, so
    /// "swift ci" narrows instead of widening.
    var searchTokens: [String] {
        searchText
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// Filters and sorts in one pass. Called once per change of rows, facet,
    /// debounced query or sort order — never per row and never per keystroke.
    func apply(to rows: [DetailRow]) -> [DetailRow] {
        let tokens = searchTokens
        let matched = rows.filter { row in
            guard facet.matches(row) else { return false }
            guard !tokens.isEmpty else { return true }
            return tokens.allSatisfy { row.haystack.contains($0) }
        }
        guard !sort.isEmpty else { return matched }
        return matched.sorted(using: sort)
    }
}

// MARK: - Row construction

/// Builds rows for a target out of snapshot values. Pure and `Sendable`-safe:
/// it takes values, never the model.
enum DetailRowFactory {

    static func rows(
        for target: DetailTarget,
        snapshot: DashboardSnapshot?,
        activityLog: [ActivityEvent],
        unreadEventIDs: Set<String>
    ) -> [DetailRow] {
        guard let snapshot else { return [] }
        switch target {
        case .section(let section):
            return rows(for: section, snapshot: snapshot, activityLog: activityLog, unreadEventIDs: unreadEventIDs)
        case .repository(let name):
            return repositoryRows(name: name, snapshot: snapshot, activityLog: activityLog, unreadEventIDs: unreadEventIDs)
        }
    }

    private static func rows(
        for section: DashboardSection,
        snapshot: DashboardSnapshot,
        activityLog: [ActivityEvent],
        unreadEventIDs: Set<String>
    ) -> [DetailRow] {
        switch section {
        case .reviewRequested:
            return snapshot.reviewRequested.map(DetailRow.init(mergeRequest:))
        case .authoredMergeRequests:
            return snapshot.authoredMergeRequests.map(DetailRow.init(mergeRequest:))
        case .assignedIssues:
            return snapshot.assignedIssues.map(DetailRow.init(issue:))
        case .inboundIssues:
            return snapshot.inboundIssues.map(DetailRow.init(issue:))
        case .repositories:
            return snapshot.repositories.map(DetailRow.init(repository:))
        case .activity:
            return activityLog.map { DetailRow(event: $0, isUnread: unreadEventIDs.contains($0.id)) }
        }
    }

    /// Everything the app knows about one repository: its own row first, then
    /// its open work, then its recent activity.
    private static func repositoryRows(
        name: String,
        snapshot: DashboardSnapshot,
        activityLog: [ActivityEvent],
        unreadEventIDs: Set<String>
    ) -> [DetailRow] {
        var rows: [DetailRow] = []
        if let repo = snapshot.repositories.first(where: { $0.nameWithOwner == name }) {
            rows.append(DetailRow(repository: repo))
        }
        let mergeRequests = snapshot.reviewRequested + snapshot.authoredMergeRequests
        var seenMergeRequests = Set<String>()
        for item in mergeRequests where item.repository == name {
            // The same MR can be both authored and review-requested.
            guard seenMergeRequests.insert(item.id).inserted else { continue }
            rows.append(DetailRow(mergeRequest: item))
        }
        let issues = snapshot.assignedIssues + snapshot.inboundIssues
        var seenIssues = Set<String>()
        for item in issues where item.repository == name {
            guard seenIssues.insert(item.id).inserted else { continue }
            rows.append(DetailRow(issue: item))
        }
        for event in activityLog where event.repository == name {
            rows.append(DetailRow(event: event, isUnread: unreadEventIDs.contains(event.id)))
        }
        return rows
    }

    /// Resolves the item a notification click was about to a row id.
    ///
    /// A banner carries an `ActivityEvent` id, and for a CI or review event the
    /// window lands on a section whose rows are repositories or merge requests —
    /// so a direct id hit is the happy path, and the fallback is the event's
    /// repository. Returning `nil` means "select nothing", never "select the
    /// first row": silently selecting the wrong item is worse than none.
    static func resolveRowID(
        pendingItemID: String?,
        rows: [DetailRow],
        activityLog: [ActivityEvent]
    ) -> String? {
        guard let pendingItemID else { return nil }
        if rows.contains(where: { $0.id == pendingItemID }) { return pendingItemID }
        guard let event = activityLog.first(where: { $0.id == pendingItemID }) else { return nil }
        if let byTitle = event.title,
           let row = rows.first(where: { $0.repository == event.repository && $0.title == byTitle }) {
            return row.id
        }
        return rows.first(where: { $0.repository == event.repository })?.id
    }
}

extension DetailRow {

    init(mergeRequest item: MergeRequestItem) {
        self.init(
            id: item.id,
            kind: .mergeRequest,
            repository: item.repository,
            title: item.title,
            number: item.number,
            author: item.author,
            url: item.url,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            isDraft: item.isDraft,
            reviewDecision: item.reviewDecision,
            checkState: item.checkState,
            commentCount: item.commentCount
        )
    }

    init(issue item: IssueItem) {
        self.init(
            id: item.id,
            kind: .issue,
            repository: item.repository,
            title: item.title,
            number: item.number,
            author: item.author,
            url: item.url,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            labels: item.labels,
            commentCount: item.commentCount
        )
    }

    init(repository repo: RepoSnapshot) {
        // A repository has no "created" timestamp in the snapshot; the push
        // date is the only real timestamp we have, so both keys use it and
        // sorting by either stays honest.
        let pushed = repo.pushedAt ?? Date.distantPast
        self.init(
            id: repo.nameWithOwner,
            kind: .repository,
            repository: repo.nameWithOwner,
            title: repo.shortName,
            number: nil,
            url: repo.url,
            createdAt: pushed,
            updatedAt: pushed,
            isPrivate: repo.isPrivate,
            checkState: repo.checkState,
            stargazerCount: repo.stargazerCount,
            forkCount: repo.forkCount,
            openIssueCount: repo.openIssueCount,
            openMergeRequestCount: repo.openMergeRequestCount
        )
    }

    init(event: ActivityEvent, isUnread: Bool) {
        let actorList = event.actors.map(\.login).joined(separator: ", ")
        let headline = event.title ?? Self.headline(for: event)
        self.init(
            id: event.id,
            kind: .activity,
            repository: event.repository,
            title: headline,
            subtitle: actorList.isEmpty ? nil : actorList,
            author: event.actors.first,
            url: event.url,
            createdAt: event.occurredAt,
            updatedAt: event.occurredAt,
            checkState: Self.checkState(for: event.kind),
            activityKind: event.kind,
            actors: event.actors,
            delta: event.delta,
            isUnread: isUnread
        )
    }

    /// What an event says when it carries no title of its own.
    private static func headline(for event: ActivityEvent) -> String {
        switch event.kind {
        case .star:
            return event.delta == 1 ? "New star" : "\(event.delta) new stars"
        case .fork:
            return event.delta == 1 ? "New fork" : "\(event.delta) new forks"
        case .checksFailed:
            return "Checks failed"
        case .checksRecovered:
            return "Checks passing again"
        case .reviewRequested:
            return "Review requested"
        case .inboundIssue:
            return "New issue"
        case .inboundMergeRequest:
            return "New merge request"
        }
    }

    /// Only the CI kinds carry a check state; giving the others one would make
    /// the "Failing" facet lie.
    private static func checkState(for kind: ActivityKind) -> CheckState? {
        switch kind {
        case .checksFailed: return .failure
        case .checksRecovered: return .success
        default: return nil
        }
    }
}
