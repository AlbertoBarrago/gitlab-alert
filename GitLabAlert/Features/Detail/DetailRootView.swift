import GitLabKit
import SwiftUI

/// The detail window: sidebar, table, inspector.
///
/// This view owns the window's whole interaction state — what is selected, what
/// is typed, what is sorted — and the dataset the table reads. The dataset is
/// rebuilt only when the underlying data or the target changes, and re-filtered
/// only when the debounced query, the facet or the sort changes, so typing in a
/// list of several hundred rows does not rebuild anything.
struct DetailRootView: View {
    let model: AppModel

    @State private var target: DetailTarget?
    @State private var filter = DetailFilter()
    /// What the search field holds right now. Debounced into `filter.searchText`.
    @State private var searchQuery = ""
    @State private var repositoryQuery = ""

    /// The full row set for `target`, rebuilt on data or target changes only.
    @State private var rows: [DetailRow] = []
    /// Bumped with `rows`, so the filter pass has something cheap to key on.
    @State private var rowsVersion = 0
    @State private var visibleRows: [DetailRow] = []
    @State private var selectedRowID: DetailRow.ID?

    /// The item a notification click asked for, held until the rows for its
    /// section exist and it can actually be selected.
    @State private var pendingItemID: String?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            content
        }
        .navigationSplitViewStyle(.balanced)
        // Attached to the split view, not to the detail column: an inspector
        // inside the column joins that column's layout, so showing or hiding it
        // shifts the toolbar along with the rows.
        .inspector(isPresented: showsInspector) {
            DetailInspectorView(model: model, row: selectedRow)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .frame(minWidth: 760, minHeight: 520)
        .task(id: datasetKey) { rebuildRows() }
        .task(id: FilterKey(version: rowsVersion, filter: filter)) { applyFilter() }
        .task(id: searchQuery) { await debounceSearch() }
        .onAppear {
            consumePendingSelection()
            if target == nil { target = defaultTarget }
        }
        // The window is long-lived: a banner clicked while it is already open
        // must retarget it, which is what makes this an `onChange` and not just
        // an `onAppear`.
        .onChange(of: model.pendingSelection) { consumePendingSelection() }
        .onChange(of: target) { resetForNewTarget() }
    }

    // MARK: - Content

    /// What the one content column shows. A row set, a report, or a form: the
    /// window shows a row set or the report; Settings keep a window of their
    /// own, because preferences are not data.
    @ViewBuilder
    private var content: some View {
        switch target {
        case .report:
            ReportView(model: model)
        default:
            DetailListView(
                model: model,
                target: target,
                rows: visibleRows,
                unfilteredCount: rows.count,
                filter: $filter,
                searchQuery: $searchQuery,
                selection: $selectedRowID,
                onRevealRepository: reveal(repository:)
            )
        }
    }

    /// The inspector opens on a selected row and nowhere else: a report has no
    /// rows and a form is not something you inspect, so on those it would be an
    /// empty panel taking a third of the window.
    private var showsInspector: Binding<Bool> {
        Binding(
            get: {
                guard selectedRow != nil else { return false }
                switch target {
                case .section, .repository: return true
                case .report, .none: return false
                }
            },
            set: { isShown in
                if !isShown { selectedRowID = nil }
            }
        )
    }

    // MARK: - Derived

    private var sidebar: some View {
        DetailSidebarView(
            model: model,
            target: $target,
            repositoryQuery: $repositoryQuery
        )
    }

    private var selectedRow: DetailRow? {
        guard let selectedRowID else { return nil }
        return rows.first { $0.id == selectedRowID }
    }

    private var defaultTarget: DetailTarget? {
        model.sections.first.map(DetailTarget.section) ?? model.repositories.first.map { .repository($0.nameWithOwner) }
    }

    /// Everything that can change the row set. `refreshTick` covers a refresh
    /// that lands while the window is open; `fetchedAt` covers the restored
    /// snapshot, which arrives without a tick.
    private var datasetKey: DatasetKey {
        DatasetKey(
            target: target,
            refreshTick: model.refreshTick,
            fetchedAt: model.snapshot?.fetchedAt,
            activityCount: model.activityLog.count,
            unreadCount: model.unreadEventIDs.count + model.seenRepositoryAlertIDs.count
        )
    }

    private struct DatasetKey: Equatable {
        var target: DetailTarget?
        var refreshTick: Int
        var fetchedAt: Date?
        var activityCount: Int
        var unreadCount: Int
    }

    private struct FilterKey: Equatable {
        var version: Int
        var filter: DetailFilter
    }

    // MARK: - Dataset

    private func rebuildRows() {
        guard let target else {
            rows = []
            rowsVersion += 1
            return
        }
        rows = DetailRowFactory.rows(
            for: target,
            snapshot: model.snapshot,
            activityLog: model.activityLog,
            unreadEventIDs: model.unreadEventIDs
        ).map { row in
            var row = row
            if row.kind == .repository,
               let repository = model.repositories.first(where: { $0.nameWithOwner == row.repository }) {
                row.isUnread = model.isRepositoryAlertUnread(repository)
            }
            return row
        }
        rowsVersion += 1
        resolvePendingSelection()
        // A refresh can drop the row that was selected; leaving a stale id
        // selected would leave the inspector empty with no explanation.
        if let selectedRowID, !rows.contains(where: { $0.id == selectedRowID }) {
            self.selectedRowID = nil
        }
    }

    private func applyFilter() {
        visibleRows = filter.apply(to: rows)
    }

    /// 200 ms of quiet before the dataset is touched. Re-typing replaces this
    /// task, so the filter runs once per pause rather than once per keystroke.
    private func debounceSearch() async {
        guard filter.searchText != searchQuery else { return }
        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            return  // Superseded by the next keystroke.
        }
        filter.searchText = searchQuery
    }

    private func resetForNewTarget() {
        // Facets are per-layout, so a facet carried across targets could hide
        // every row with no visible cause.
        filter.facet = .all
        filter.sort = [DetailRowComparator(field: .updated, order: .reverse)]
        selectedRowID = nil
    }

    // MARK: - Actions

    private func reveal(repository: String) {
        target = .repository(repository)
    }

    // MARK: - Notification routing

    /// Takes the selection a notification click left behind and clears it, so
    /// the same banner cannot retarget the window twice.
    private func consumePendingSelection() {
        guard let pending = model.pendingSelection else { return }
        model.pendingSelection = nil

        pendingItemID = pending.itemID
        // Nothing may hide the item the user was sent here to look at.
        searchQuery = ""
        filter.searchText = ""
        filter.facet = .all

        let requested = DetailTarget.section(pending.section)
        if target == requested {
            // Same target: no dataset change is coming, so resolve now.
            resolvePendingSelection()
        } else {
            target = requested
        }
    }

    /// Selects the pending item once its rows exist. Selecting a row is what
    /// scrolls it into view — `Table` brings its selection into view — and it
    /// also fills the inspector, which is the point of arriving from a banner.
    private func resolvePendingSelection() {
        guard pendingItemID != nil else { return }
        if let resolved = DetailRowFactory.resolveRowID(
            pendingItemID: pendingItemID,
            rows: rows,
            activityLog: model.activityLog
        ) {
            selectedRowID = resolved
            pendingItemID = nil
        } else if model.snapshot != nil {
            // The data is loaded and the item is genuinely not in it (closed,
            // or out of scope). Stop waiting rather than hijacking a later
            // refresh's selection.
            pendingItemID = nil
        }
    }
}

#if DEBUG
#Preview("Detail window") {
    DetailPreviewHarness { model in
        DetailRootView(model: model)
            .frame(width: 980, height: 620)
    }
}

#Preview("Detail window \u{2014} no data") {
    DetailPreviewHarness(populated: false) { model in
        DetailRootView(model: model)
            .frame(width: 900, height: 560)
    }
}

/// Hosts a preview-only ``AppModel``.
///
/// The model is built inside `task` rather than in an initializer: `AppModel` is
/// `@MainActor`, and `task` inherits that isolation while a `View` initializer
/// does not.
struct DetailPreviewHarness<Content: View>: View {
    private let populated: Bool
    private let content: (AppModel) -> Content
    @State private var model: AppModel?

    init(populated: Bool = true, @ViewBuilder content: @escaping (AppModel) -> Content) {
        self.populated = populated
        self.content = content
    }

    var body: some View {
        ZStack {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .task {
            if model == nil { model = DetailPreviewFixtures.makeModel(populated: populated) }
        }
    }
}

/// Fixtures for the detail window's previews.
///
/// Local to this feature on purpose: `UI/SampleData.swift` did not exist when
/// this surface was written, and two agents editing one fixture file is a
/// conflict. If that file lands, these can collapse into it.
enum DetailPreviewFixtures {

    static let now = Date(timeIntervalSince1970: 1_760_000_000)

    static let maintainer = GLActor(login: "albz", avatarURL: URL(string: "https://avatars.gitlabusercontent.com/u/1?v=4"))
    static let contributor = GLActor(login: "octocat", avatarURL: URL(string: "https://avatars.gitlabusercontent.com/u/583231?v=4"))
    static let stranger = GLActor(login: "hubot", avatarURL: nil)

    static let profile = Profile(
        login: "albz",
        name: "Alberto",
        avatarURL: URL(string: "https://avatars.gitlabusercontent.com/u/1?v=4"),
        followers: 412,
        following: 89,
        publicRepoCount: 178,
        url: URL(string: "https://gitlab.com/albz")!
    )

    static let snapshot = DashboardSnapshot(
        fetchedAt: now,
        profile: profile,
        reviewRequested: [
            MergeRequestItem(
                id: "MR_1",
                number: 412,
                title: "Fix the watermark comparison so equal timestamps never re-notify",
                repository: "albz/gitlab-alert",
                author: contributor,
                url: URL(string: "https://gitlab.com/albz/gitlab-alert/pull/412")!,
                createdAt: now.addingTimeInterval(-86_400 * 2),
                updatedAt: now.addingTimeInterval(-3_600),
                reviewDecision: .reviewRequired,
                checkState: .failure,
                relevance: .reviewRequested,
                commentCount: 7
            ),
            MergeRequestItem(
                id: "MR_2",
                number: 77,
                title: "Add a Network.framework path monitor to pause polling when offline",
                repository: "albz/dockdock",
                author: stranger,
                url: URL(string: "https://gitlab.com/albz/dockdock/pull/77")!,
                createdAt: now.addingTimeInterval(-86_400 * 9),
                updatedAt: now.addingTimeInterval(-86_400),
                isDraft: true,
                reviewDecision: .none,
                checkState: .pending,
                relevance: .reviewRequested,
                commentCount: 0
            )
        ],
        authoredMergeRequests: [
            MergeRequestItem(
                id: "MR_3",
                number: 118,
                title: "Draw the menu bar glyph in code instead of shipping a PDF",
                repository: "albz/gitlab-alert",
                author: maintainer,
                url: URL(string: "https://gitlab.com/albz/gitlab-alert/pull/118")!,
                createdAt: now.addingTimeInterval(-86_400 * 4),
                updatedAt: now.addingTimeInterval(-7_200),
                reviewDecision: .approved,
                checkState: .success,
                relevance: .authored,
                commentCount: 3
            )
        ],
        assignedIssues: [
            IssueItem(
                id: "IS_1",
                number: 220,
                title: "Popover placement is wrong on a notched display",
                repository: "albz/gitlab-alert",
                author: contributor,
                url: URL(string: "https://gitlab.com/albz/gitlab-alert/issues/220")!,
                createdAt: now.addingTimeInterval(-86_400 * 12),
                updatedAt: now.addingTimeInterval(-86_400 * 3),
                commentCount: 4,
                labels: ["bug", "ui", "needs repro"]
            )
        ],
        inboundIssues: [
            IssueItem(
                id: "IS_2",
                number: 221,
                title: "Feature request: filter the activity feed by repository",
                repository: "albz/gitlab-alert",
                author: stranger,
                url: URL(string: "https://gitlab.com/albz/gitlab-alert/issues/221")!,
                createdAt: now.addingTimeInterval(-3_600 * 5),
                updatedAt: now.addingTimeInterval(-3_600 * 5),
                commentCount: 0,
                labels: ["enhancement"],
                isInbound: true
            )
        ],
        repositories: [
            RepoSnapshot(
                nameWithOwner: "albz/gitlab-alert",
                stargazerCount: 1_284,
                forkCount: 63,
                openIssueCount: 12,
                openMergeRequestCount: 3,
                defaultBranch: "main",
                headOID: "a1b2c3d",
                checkState: .failure,
                pushedAt: now.addingTimeInterval(-1_800),
                url: URL(string: "https://gitlab.com/albz/gitlab-alert")!
            ),
            RepoSnapshot(
                nameWithOwner: "albz/dockdock",
                stargazerCount: 342,
                forkCount: 11,
                openIssueCount: 5,
                openMergeRequestCount: 1,
                defaultBranch: "main",
                checkState: .success,
                pushedAt: now.addingTimeInterval(-86_400 * 2),
                url: URL(string: "https://gitlab.com/albz/dockdock")!
            ),
            RepoSnapshot(
                nameWithOwner: "albz/telemaco",
                isPrivate: true,
                stargazerCount: 9,
                forkCount: 0,
                openIssueCount: 0,
                openMergeRequestCount: 0,
                checkState: .unknown,
                pushedAt: now.addingTimeInterval(-86_400 * 30),
                url: URL(string: "https://gitlab.com/albz/telemaco")!
            )
        ],
        rateLimit: RateLimitStatus(remaining: 4_902, limit: 5_000, resetAt: now.addingTimeInterval(2_400))
    )

    static let activityLog: [ActivityEvent] = [
        ActivityEvent(
            id: "review:albz/gitlab-alert:1",
            kind: .reviewRequested,
            occurredAt: now.addingTimeInterval(-900),
            repository: "albz/gitlab-alert",
            delta: 3,
            actors: [contributor, stranger],
            url: URL(string: "https://gitlab.com/albz/gitlab-alert/stargazers")!
        ),
        ActivityEvent(
            id: "checks:albz/gitlab-alert:a1b2c3d",
            kind: .checksFailed,
            occurredAt: now.addingTimeInterval(-1_700),
            repository: "albz/gitlab-alert",
            title: "CI failed on main",
            url: URL(string: "https://gitlab.com/albz/gitlab-alert/actions")!
        ),
        ActivityEvent(
            id: "inbound:albz/dockdock:1",
            kind: .inboundMergeRequest,
            occurredAt: now.addingTimeInterval(-86_400 * 1.5),
            repository: "albz/dockdock",
            actors: [stranger],
            url: URL(string: "https://gitlab.com/hubot/dockdock")!
        )
    ]

    static let unreadEventIDs: Set<String> = ["review:albz/gitlab-alert:1"]

    static func rows(for target: DetailTarget) -> [DetailRow] {
        DetailRowFactory.rows(
            for: target,
            snapshot: snapshot,
            activityLog: activityLog,
            unreadEventIDs: unreadEventIDs
        )
    }

    static var mergeRequestRow: DetailRow {
        DetailRow(mergeRequest: snapshot.reviewRequested[0])
    }

    @MainActor
    static func makeModel(populated: Bool = true) -> AppModel {
        // A private defaults suite so a preview cannot scribble on the real
        // app's preferences.
        let defaults = UserDefaults(suiteName: "com.alBz.GitLabAlert.previews") ?? .standard
        let model = AppModel(
            preferences: Preferences(defaults: defaults),
            tokenStore: PreviewTokenStore(),
            api: PreviewAPI(),
            apiFactory: { _ in PreviewAPI() }
        )
        if populated {
            model.restore(
                PollOutcome(
                    snapshot: snapshot,
                    freshEvents: [],
                    activityLog: activityLog,
                    rateLimit: snapshot.rateLimit
                )
            )
        }
        return model
    }

    /// Never reached: previews do no I/O. Present only because `AppModel`
    /// requires the collaborators.
    private struct PreviewAPI: GitLabAPI {
        func fetchDashboard(scope: RepositoryScope, options: DashboardRequestOptions) async throws -> DashboardSnapshot { DetailPreviewFixtures.snapshot }
        func verifyToken() async throws -> Profile { DetailPreviewFixtures.profile }
    }

    private struct PreviewTokenStore: TokenStore {
        func readToken() throws -> String? { "preview" }
        func writeToken(_ token: String) throws {}
        func deleteToken() throws {}
    }
}
#endif
