import GitLabKit
import SwiftUI

/// The detail window's content column: one wide, sortable, searchable table.
///
/// Rows arrive already filtered and sorted — the view's job is columns, empty
/// states and actions, not data reduction. `Table` column lists cannot be built
/// conditionally before macOS 14.4, so each layout is its own `Table` over the
/// same row type rather than one table with hidden columns.
struct DetailListView: View {
    let model: AppModel
    let target: DetailTarget?
    /// What the table shows: filtered and sorted by ``DetailFilter``.
    let rows: [DetailRow]
    /// How many rows exist before filtering, so "no matches" can be told apart
    /// from "nothing here".
    let unfilteredCount: Int
    @Binding var filter: DetailFilter
    @Binding var searchQuery: String
    @Binding var selection: DetailRow.ID?
    let onRevealRepository: (String) -> Void

    var body: some View {
        content
            .frame(minWidth: 360)
            .searchable(
                text: $searchQuery,
                placement: .toolbar,
                prompt: "Search title, repository, author or label"
            )
            .navigationTitle(target?.title ?? "GitLab Alert")
    }

    @ViewBuilder
    private var content: some View {
        if let target {
            VStack(spacing: 0) {
                header(for: target)
                Divider()
                if let notice = statusNotice {
                    notice
                    Divider()
                }
                table(for: target)
            }
        } else {
            DetailEmptyStateView(
                symbol: "sidebar.left",
                title: "Nothing selected",
                message: "Pick a section or a repository in the sidebar."
            )
        }
    }

    // MARK: - Header

    private func header(for target: DetailTarget) -> some View {
        HStack(spacing: 12) {
            let facets = DetailFacet.available(for: target.tableStyle)
            if facets.count > 1 {
                Picker("Filter", selection: $filter.facet) {
                    ForEach(facets) { facet in
                        Text(facet.title).tag(facet)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Narrow the list")
            }

            Text(countSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel(countSummary)

            Spacer(minLength: 0)

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing")
            }

            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isLoading)
            .help("Refresh now (\u{2318}R)")
            .accessibilityLabel("Refresh now")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var countSummary: String {
        if filter.isNarrowing && unfilteredCount != rows.count {
            return "\(rows.count) of \(unfilteredCount)"
        }
        return rows.count == 1 ? "1 item" : "\(rows.count) items"
    }

    /// Honest markers above the table: stale data because the last refresh
    /// failed, and a rate-limit warning when the budget is actually low.
    @ViewBuilder
    private var statusNotice: (some View)? {
        if let message = staleMessage ?? model.rateLimitWarning {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if staleMessage != nil {
                    Button("Try Again") { model.refresh() }
                        .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
        }
    }

    private var staleMessage: String? {
        guard model.isShowingStaleData, let error = model.lastError else { return nil }
        if let stamp = model.lastFetch {
            return "\(error.userMessage) Last updated \(stamp.formatted(date: .omitted, time: .shortened))."
        }
        return error.userMessage
    }

    // MARK: - Tables

    @ViewBuilder
    private func table(for target: DetailTarget) -> some View {
        if let empty = emptyState(for: target) {
            empty
        } else {
            switch target.tableStyle {
            case .mergeRequests: mergeRequestTable
            case .issues: issueTable
            case .repositories: repositoryTable
            case .activity: activityTable
            case .mixed: mixedTable
            }
        }
    }

    private var mergeRequestTable: some View {
        Table(rows, selection: $selection, sortOrder: $filter.sort) {
            TableColumn("Title", sortUsing: DetailRowComparator(field: .title)) { row in
                titleCell(row)
            }
            .width(min: 200, ideal: 320)

            TableColumn("Repository", sortUsing: DetailRowComparator(field: .repository)) { row in
                repositoryCell(row)
            }
            .width(min: 120, ideal: 180)

            TableColumn("Author", sortUsing: DetailRowComparator(field: .author)) { row in
                authorCell(row)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Review", sortUsing: DetailRowComparator(field: .state)) { row in
                DetailStateBadge(row: row)
            }
            .width(min: 110, ideal: 140)

            TableColumn("Checks", sortUsing: DetailRowComparator(field: .state)) { row in
                DetailCheckBadge(state: row.checkState)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Updated", sortUsing: DetailRowComparator(field: .updated)) { row in
                ageCell(row.updatedAt)
            }
            .width(min: 90, ideal: 110)
        }
        .modifier(DetailTableChrome(rows: rows, open: open, reveal: onRevealRepository))
    }

    private var issueTable: some View {
        Table(rows, selection: $selection, sortOrder: $filter.sort) {
            TableColumn("Title", sortUsing: DetailRowComparator(field: .title)) { row in
                titleCell(row)
            }
            .width(min: 200, ideal: 340)

            TableColumn("Repository", sortUsing: DetailRowComparator(field: .repository)) { row in
                repositoryCell(row)
            }
            .width(min: 120, ideal: 180)

            TableColumn("Author", sortUsing: DetailRowComparator(field: .author)) { row in
                authorCell(row)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Labels", sortUsing: DetailRowComparator(field: .state)) { row in
                labelsCell(row)
            }
            .width(min: 100, ideal: 160)

            TableColumn("Replies", sortUsing: DetailRowComparator(field: .comments)) { row in
                countCell(row.commentCount, symbol: "bubble.left", label: "replies")
            }
            .width(min: 70, ideal: 80)

            TableColumn("Updated", sortUsing: DetailRowComparator(field: .updated)) { row in
                ageCell(row.updatedAt)
            }
            .width(min: 90, ideal: 110)
        }
        .modifier(DetailTableChrome(rows: rows, open: open, reveal: onRevealRepository))
    }

    private var repositoryTable: some View {
        Table(rows, selection: $selection, sortOrder: $filter.sort) {
            TableColumn("Repository", sortUsing: DetailRowComparator(field: .repository)) { row in
                repositoryCell(row)
            }
            .width(min: 160, ideal: 260)

            TableColumn("Checks", sortUsing: DetailRowComparator(field: .state)) { row in
                DetailCheckBadge(state: row.checkState)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Stars", sortUsing: DetailRowComparator(field: .stars)) { row in
                countCell(row.stargazerCount, symbol: "star", label: "stars")
            }
            .width(min: 70, ideal: 90)

            TableColumn("Forks", sortUsing: DetailRowComparator(field: .forks)) { row in
                countCell(row.forkCount, symbol: "tuningfork", label: "forks")
            }
            .width(min: 70, ideal: 90)

            TableColumn("Issues", sortUsing: DetailRowComparator(field: .openIssues)) { row in
                countCell(row.openIssueCount, symbol: "smallcircle.filled.circle", label: "open issues")
            }
            .width(min: 70, ideal: 90)

            TableColumn("MRs", sortUsing: DetailRowComparator(field: .openMergeRequests)) { row in
                countCell(row.openMergeRequestCount, symbol: "arrow.triangle.branch", label: "open merge requests")
            }
            .width(min: 70, ideal: 90)

            TableColumn("Pushed", sortUsing: DetailRowComparator(field: .updated)) { row in
                ageCell(row.updatedAt)
            }
            .width(min: 90, ideal: 110)
        }
        .modifier(DetailTableChrome(rows: rows, open: open, reveal: onRevealRepository))
    }

    private var activityTable: some View {
        Table(rows, selection: $selection, sortOrder: $filter.sort) {
            TableColumn("Event", sortUsing: DetailRowComparator(field: .state)) { row in
                activityCell(row)
            }
            .width(min: 140, ideal: 190)

            TableColumn("Repository", sortUsing: DetailRowComparator(field: .repository)) { row in
                repositoryCell(row)
            }
            .width(min: 130, ideal: 200)

            TableColumn("Detail", sortUsing: DetailRowComparator(field: .title)) { row in
                titleCell(row)
            }
            .width(min: 160, ideal: 280)

            TableColumn("Who", sortUsing: DetailRowComparator(field: .author)) { row in
                authorCell(row)
            }
            .width(min: 110, ideal: 150)

            TableColumn("When", sortUsing: DetailRowComparator(field: .updated)) { row in
                ageCell(row.updatedAt)
            }
            .width(min: 90, ideal: 110)
        }
        .modifier(DetailTableChrome(rows: rows, open: open, reveal: onRevealRepository))
    }

    /// One repository, everything about it: its own row, its open work, its
    /// recent activity. The kind column is what makes the mix readable.
    private var mixedTable: some View {
        Table(rows, selection: $selection, sortOrder: $filter.sort) {
            TableColumn("Kind", sortUsing: DetailRowComparator(field: .kind)) { row in
                kindCell(row)
            }
            .width(min: 110, ideal: 140)

            TableColumn("Title", sortUsing: DetailRowComparator(field: .title)) { row in
                titleCell(row)
            }
            .width(min: 200, ideal: 340)

            TableColumn("Author", sortUsing: DetailRowComparator(field: .author)) { row in
                authorCell(row)
            }
            .width(min: 110, ideal: 150)

            TableColumn("State", sortUsing: DetailRowComparator(field: .state)) { row in
                DetailStateBadge(row: row)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Updated", sortUsing: DetailRowComparator(field: .updated)) { row in
                ageCell(row.updatedAt)
            }
            .width(min: 90, ideal: 110)
        }
        .modifier(DetailTableChrome(rows: rows, open: open, reveal: onRevealRepository))
    }

    // MARK: - Cells

    private func titleCell(_ row: DetailRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if row.isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let number = row.number {
                    Text("#\(number)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if row.isDraft {
                    Text("Draft")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }
            }
            if let subtitle = row.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        // One spoken label per row rather than six unlabelled cells.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityDescription)
    }

    private func repositoryCell(_ row: DetailRow) -> some View {
        HStack(spacing: 5) {
            if row.isPrivate {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(row.repository)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityLabel(row.isPrivate ? "\(row.repository), private" : row.repository)
    }

    private func authorCell(_ row: DetailRow) -> some View {
        HStack(spacing: 5) {
            if let actor = row.author {
                DetailAvatarView(actor: actor, size: 16)
                Text(actor.login)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("\u{2014}")
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityLabel(row.author.map { "Author \($0.login)" } ?? "No author")
    }

    private func labelsCell(_ row: DetailRow) -> some View {
        Group {
            if row.labels.isEmpty {
                Text("\u{2014}").foregroundStyle(.tertiary)
            } else {
                Text(row.labels.joined(separator: ", "))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityLabel(row.labels.isEmpty ? "No labels" : "Labels: \(row.labels.joined(separator: ", "))")
    }

    private func countCell(_ value: Int?, symbol: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(value.map(String.init) ?? "\u{2014}")
                .monospacedDigit()
        }
        .accessibilityLabel(value.map { "\($0) \(label)" } ?? "No \(label)")
    }

    private func ageCell(_ date: Date) -> some View {
        Text(date, format: .relative(presentation: .numeric))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(date.formatted(date: .abbreviated, time: .shortened))
            .accessibilityLabel(date.formatted(date: .abbreviated, time: .shortened))
    }

    private func activityCell(_ row: DetailRow) -> some View {
        HStack(spacing: 5) {
            Image(systemName: row.activityKind.map(DetailLabels.symbol(for:)) ?? "sparkles")
                .foregroundStyle(row.activityKind == .checksFailed ? Color.red : Color.accentColor)
                .accessibilityHidden(true)
            Text(row.activityKind.map(DetailLabels.name(for:)) ?? "Activity")
                .lineLimit(1)
            if let delta = row.delta, delta > 1 {
                Text("\u{00D7}\(delta)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(row.stateLabel)
    }

    private func kindCell(_ row: DetailRow) -> some View {
        Label {
            Text(row.kind == .activity ? (row.activityKind.map(DetailLabels.name(for:)) ?? "Activity") : row.kind.label)
                .lineLimit(1)
        } icon: {
            Image(systemName: row.kind == .activity ? (row.activityKind.map(DetailLabels.symbol(for:)) ?? "sparkles") : row.kind.symbolName)
        }
        .accessibilityLabel(row.kind.label)
    }

    // MARK: - Actions

    private func open(_ ids: Set<DetailRow.ID>) {
        for row in rows where ids.contains(row.id) {
            model.openOnGitLab(row.url)
        }
    }

    // MARK: - Empty states

    /// Never a blank pane: every reason the table has no rows has its own
    /// designed state, and the ones the user can act on carry the action.
    @ViewBuilder
    private func emptyState(for target: DetailTarget) -> (some View)? {
        if rows.isEmpty {
            if case .needsToken = model.authState {
                DetailEmptyStateView(
                    symbol: "key.horizontal",
                    title: "Not connected yet",
                    message: "Add a GitLab personal access token to start watching your repositories.",
                    actionTitle: "Open Settings\u{2026}",
                    action: { model.openSettings() }
                )
            } else if model.snapshot == nil, let error = model.lastError {
                DetailEmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: "Couldn\u{2019}t load your dashboard",
                    message: error.userMessage,
                    actionTitle: "Try Again",
                    action: { model.refresh() }
                )
            } else if model.snapshot == nil {
                DetailEmptyStateView(
                    symbol: "arrow.clockwise",
                    title: "Loading\u{2026}",
                    message: "Fetching your dashboard from GitLab."
                )
            } else if filter.isNarrowing {
                DetailEmptyStateView(
                    symbol: "magnifyingglass",
                    title: "No matches",
                    message: searchQuery.isEmpty
                        ? "Nothing in this section matches the \u{201C}\(filter.facet.title)\u{201D} filter."
                        : "Nothing here matches \u{201C}\(searchQuery)\u{201D}.",
                    actionTitle: "Clear Filters",
                    action: {
                        searchQuery = ""
                        filter.searchText = ""
                        filter.facet = .all
                    }
                )
            } else {
                let state = Self.restingState(for: target)
                DetailEmptyStateView(symbol: state.symbol, title: state.title, message: state.message)
            }
        }
    }

    /// The resting state — nothing waiting — is what a maintainer sees most, so
    /// it reads as good news rather than as an error.
    private static func restingState(for target: DetailTarget) -> (symbol: String, title: String, message: String) {
        switch target {
        case .repository(let name):
            return ("shippingbox", "Nothing open", "\(name) has no open work and no recent activity.")
        case .section(let section):
            switch section {
            case .reviewRequested:
                return ("checkmark.circle", "No reviews waiting", "Nobody is waiting on your review right now.")
            case .authoredMergeRequests:
                return ("arrow.triangle.branch", "No open merge requests", "You have nothing in flight.")
            case .assignedIssues:
                return ("checkmark.circle", "Nothing assigned", "No open issues are assigned to you.")
            case .inboundIssues:
                return ("tray", "No inbound issues", "Nobody has opened an issue on your repositories.")
            case .repositories:
                return ("shippingbox", "No repositories in scope", "Widen the repository scope in Settings to watch more.")
            case .activity:
                return ("sparkles", "No activity yet", "Stars, forks and CI changes will show up here as they happen.")
            }
        }
    }
}

// MARK: - Shared table chrome

/// Row styling and row actions, applied identically to every table: double
/// click opens on GitLab, the context menu offers the same plus jumping to the
/// repository in the sidebar.
private struct DetailTableChrome: ViewModifier {
    let rows: [DetailRow]
    let open: (Set<DetailRow.ID>) -> Void
    let reveal: (String) -> Void

    func body(content: Content) -> some View {
        content
            .tableStyle(.inset)
            .alternatingRowBackgrounds()
            .contextMenu(forSelectionType: DetailRow.ID.self) { ids in
                Button("Open on GitLab") { open(ids) }
                    .disabled(ids.isEmpty)
                if ids.count == 1,
                   let row = rows.first(where: { ids.contains($0.id) }),
                   row.kind != .repository {
                    Button("Show Repository") { reveal(row.repository) }
                }
            } primaryAction: { ids in
                open(ids)
            }
    }
}

// MARK: - Shared components

/// An avatar loaded over https only. Remote avatar URLs are untrusted input, so
/// anything else falls back to the monogram rather than being fetched.
struct DetailAvatarView: View {
    let actor: GLActor
    let size: CGFloat

    private var secureURL: URL? {
        guard let url = actor.avatarURL, url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    var body: some View {
        Group {
            if let secureURL {
                AsyncImage(url: secureURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var monogram: some View {
        ZStack {
            Circle().fill(.quaternary)
            Text(initial)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var initial: String {
        actor.login.first.map { String($0).uppercased() } ?? "?"
    }
}

/// The one-word state of a row, coloured by what it means.
struct DetailStateBadge: View {
    let row: DetailRow

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(row.stateLabel)
                .lineLimit(1)
        }
        .accessibilityLabel(row.stateLabel)
    }

    private var tint: Color {
        switch row.kind {
        case .mergeRequest:
            if row.isDraft { return .secondary }
            switch row.reviewDecision {
            case .approved: return .green
            case .changesRequested: return .orange
            case .reviewRequired: return .accentColor
            default: return .secondary
            }
        case .repository:
            return DetailCheckBadge.tint(for: row.checkState)
        case .activity:
            return row.activityKind == .checksFailed ? .red : .accentColor
        case .issue:
            return .secondary
        }
    }
}

/// CI state. `.unknown` is "this repository has no checks", not a failure —
/// colouring it like one is the bug this view exists to avoid.
struct DetailCheckBadge: View {
    let state: CheckState?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(DetailCheckBadge.tint(for: state))
                .accessibilityHidden(true)
            Text(state.map(DetailLabels.name(for:)) ?? "\u{2014}")
                .lineLimit(1)
                .foregroundStyle(state == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
        .accessibilityLabel(state.map { "Checks \(DetailLabels.name(for: $0))" } ?? "No check information")
    }

    private var symbol: String {
        switch state {
        case .success: return "checkmark.circle.fill"
        case .failure, .error: return "xmark.octagon.fill"
        case .pending, .expected: return "clock"
        case .unknown, .none: return "minus.circle"
        }
    }

    static func tint(for state: CheckState?) -> Color {
        switch state {
        case .success: return .green
        case .failure, .error: return .red
        case .pending, .expected: return .orange
        case .unknown, .none: return .secondary
        }
    }
}

/// The designed alternative to a blank pane.
struct DetailEmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 2)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(message)")
    }
}

#if DEBUG
#Preview("List") {
    DetailPreviewHarness { model in
        DetailListView(
            model: model,
            target: .section(.reviewRequested),
            rows: DetailPreviewFixtures.rows(for: .section(.reviewRequested)),
            unfilteredCount: DetailPreviewFixtures.rows(for: .section(.reviewRequested)).count,
            filter: .constant(DetailFilter()),
            searchQuery: .constant(""),
            selection: .constant(nil),
            onRevealRepository: { _ in }
        )
        .frame(width: 820, height: 460)
    }
}

#Preview("List \u{2014} empty") {
    DetailPreviewHarness { model in
        DetailListView(
            model: model,
            target: .section(.assignedIssues),
            rows: [],
            unfilteredCount: 0,
            filter: .constant(DetailFilter()),
            searchQuery: .constant(""),
            selection: .constant(nil),
            onRevealRepository: { _ in }
        )
        .frame(width: 640, height: 420)
    }
}
#endif
