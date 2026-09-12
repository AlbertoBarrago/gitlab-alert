import GitLabKit
import SwiftUI

/// Choosing which of a few hundred repositories the app watches.
///
/// A checkbox list does not survive 178 rows, so this is a search field, a set
/// of quick filters, three sort orders, and one pop-up per row. The rule that
/// decides everything not explicitly pinned or excluded is stated in words and
/// editable in place, because "why is this repository not in the list?" has to
/// be answerable without reading the source.
@MainActor
struct RepositoryPickerView: View {
    let model: AppModel

    /// Above this many pinned repositories the poll starts costing noticeably
    /// more, and the user deserves to be told rather than to find out.
    private static let pinWarningThreshold = 30

    /// The "pushed recently" quick filter's window. Deliberately shorter than
    /// the scope's default 90-day rule: it answers "what am I working on now?".
    private static let recentPushWindowDays = 30.0

    enum SortOrder: String, Hashable, CaseIterable, Identifiable {
        case lastPush
        case stars
        case name

        var id: String { rawValue }

        var title: String {
            switch self {
            case .lastPush: return "Last push"
            case .stars: return "Stars"
            case .name: return "Name"
            }
        }
    }

    /// What the user has said about one repository, as opposed to what the rule
    /// says. Maps exactly onto ``RepositoryScope/pinned`` and ``excluded``.
    enum ScopeDecision: String, Hashable, CaseIterable, Identifiable {
        case rule
        case always
        case never

        var id: String { rawValue }

        var title: String {
            switch self {
            case .rule: return "Follow the rule"
            case .always: return "Always watch"
            case .never: return "Never watch"
            }
        }
    }

    /// Whether a repository is in scope, and why.
    enum ScopeStanding: Hashable {
        case pinned
        case byRule
        case outsideRule
        case excluded

        var isWatched: Bool { self == .pinned || self == .byRule }

        var label: String {
            switch self {
            case .pinned: return "Watching: pinned"
            case .byRule: return "Watching: by rule"
            case .outsideRule: return "Not watching"
            case .excluded: return "Excluded"
            }
        }

        /// All four ship with macOS 14.
        var symbolName: String {
            switch self {
            case .pinned: return "pin.fill"
            case .byRule: return "checkmark.circle.fill"
            case .outsideRule: return "circle"
            case .excluded: return "minus.circle"
            }
        }

        var tint: Color {
            switch self {
            case .pinned, .byRule: return .accentColor
            case .outsideRule, .excluded: return .secondary
            }
        }

        var decision: ScopeDecision {
            switch self {
            case .pinned: return .always
            case .excluded: return .never
            case .byRule, .outsideRule: return .rule
            }
        }
    }

    /// One list row: the repository plus the standing it has under the current
    /// scope, resolved once per pass rather than per row redraw.
    struct Row: Identifiable {
        let repo: RepoSnapshot
        let standing: ScopeStanding

        var id: String { repo.nameWithOwner }
    }

    @State private var query = ""
    /// What the list actually filters on. Updated behind a short delay so a
    /// keystroke does not re-filter and re-sort 178 rows seven times a second.
    @State private var debouncedQuery = ""
    @State private var sort: SortOrder = .lastPush
    @State private var onlyWithStars = false
    @State private var onlyWithOpenIssues = false
    @State private var onlyPushedRecently = false
    @State private var showForks = true
    @State private var showPrivate = true
    @State private var isShowingRuleEditor = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            footer
        }
        .task(id: query) {
            guard debouncedQuery != query else { return }
            if !query.isEmpty {
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
            guard !Task.isCancelled else { return }
            debouncedQuery = query
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            searchField

            Menu {
                Toggle("Has stars", isOn: $onlyWithStars)
                Toggle("Has open issues", isOn: $onlyWithOpenIssues)
                Toggle("Pushed in the last 30 days", isOn: $onlyPushedRecently)
                Divider()
                Toggle("Show forks", isOn: $showForks)
                Toggle("Show private", isOn: $showPrivate)
                Divider()
                Button("Clear filters", action: clearFilters)
                    .disabled(activeFilterCount == 0)
            } label: {
                Label(
                    activeFilterCount == 0 ? "Filter" : "Filter (\(activeFilterCount))",
                    systemImage: activeFilterCount == 0
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("These filters change what this list shows, not what the app watches.")
            .accessibilityLabel("Filter the list")

            Picker("Sort", selection: $sort) {
                ForEach(SortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Sort by")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search repositories", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search repositories by name")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !model.authState.isReady {
            centered(
                symbolName: "key",
                title: "No token yet",
                message: "Add a GitLab token in the Account tab and your repositories will show up here."
            )
        } else if model.repositoryCatalog.isEmpty, model.isLoadingRepositoryCatalog {
            centered(progress: "Loading your repositories…")
        } else if let error = model.repositoryCatalogError, candidates.isEmpty {
            VStack(spacing: 10) {
                centered(
                    symbolName: "exclamationmark.triangle",
                    title: "Could not load your repositories",
                    message: error.userMessage
                )
                Button("Try again") { model.loadRepositoryCatalog(force: true) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            centered(
                symbolName: "magnifyingglass",
                title: "No matches",
                message: "No repository matches the search and filters."
            )
        } else {
            List {
                ForEach(rows) { row in
                    RepositoryScopeRow(
                        row: row,
                        viewerLogin: model.profile?.login,
                        decision: decisionBinding(for: row)
                    )
                }
            }
            .listStyle(.inset)
            .accessibilityLabel("Repositories")
        }
    }

    private func centered(symbolName: String, title: String, message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centered(progress: String) -> some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(progress)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summaryLine)
                    .font(.callout)
                    .fontWeight(.medium)

                if model.isLoadingRepositoryCatalog {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading the full repository list")
                }

                Spacer(minLength: 0)

                Button("Change rule…") { isShowingRuleEditor = true }
                    .popover(isPresented: $isShowingRuleEditor, arrowEdge: .bottom) {
                        ruleEditor
                    }

                if model.repositoryCatalog.isEmpty {
                    Button("Load all repositories") {
                        model.loadRepositoryCatalog()
                    }
                    .disabled(model.isLoadingRepositoryCatalog || !model.authState.isReady)
                } else {
                    Button {
                        model.loadRepositoryCatalog(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isLoadingRepositoryCatalog || !model.authState.isReady)
                    .help("Reload the repository list from GitLab.")
                    .accessibilityLabel("Reload the repository list")
                }
            }

            Text(ruleSentence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if pinnedCount > Self.pinWarningThreshold {
                SettingsAdvisory(
                    level: .warning,
                    message: "\(pinnedCount) repositories are pinned. Pins bypass the activity cutoff, so every "
                        + "poll has to page further through your repository list and diff more repositories. "
                        + "It stays well inside the hourly API budget, but each cycle gets slower."
                )
            }

            if let error = model.repositoryCatalogError, !candidates.isEmpty {
                SettingsAdvisory(level: .warning, message: error.userMessage)
            }

            if !orphanedRules.isEmpty {
                orphanSection
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var orphanSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(orphanedRules.count == 1
                 ? "1 rule points at a repository that is not in this list:"
                 : "\(orphanedRules.count) rules point at repositories that are not in this list:")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(orphanedRules, id: \.self) { name in
                HStack(spacing: 6) {
                    Text(name)
                        .font(.callout)
                    Button("Clear") { clearRules(for: name) }
                        .buttonStyle(.link)
                        .accessibilityLabel("Clear the rule for \(name)")
                }
            }
        }
    }

    // MARK: - Rule editor

    private var ruleEditor: some View {
        Form {
            Section("Watch by default") {
                Toggle("Include private repositories", isOn: scopeBinding(\.includePrivate))
                Toggle("Include forks", isOn: scopeBinding(\.includeForks))
                Picker("Pushed within", selection: scopeBinding(\.activeWithinDays)) {
                    Text("30 days").tag(Optional(30))
                    Text("90 days").tag(Optional(90))
                    Text("6 months").tag(Optional(180))
                    Text("1 year").tag(Optional(365))
                    Text("Any time").tag(Optional<Int>.none)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 330, height: 260)
    }

    // MARK: - Data

    /// The full owned list once it has arrived; until then the repositories the
    /// scope already watches, so the tab is never blank.
    private var candidates: [RepoSnapshot] {
        model.repositoryCatalog.isEmpty ? model.repositories : model.repositoryCatalog
    }

    private var rows: [Row] {
        let scope = model.preferences.repositoryScope
        let now = Date()
        let needle = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let recentCutoff = now.addingTimeInterval(-Self.recentPushWindowDays * 86_400)

        var result: [Row] = []
        result.reserveCapacity(candidates.count)
        for repo in candidates {
            if !needle.isEmpty, !repo.nameWithOwner.localizedCaseInsensitiveContains(needle) { continue }
            if !showForks, repo.isFork { continue }
            if !showPrivate, repo.isPrivate { continue }
            if onlyWithStars, repo.stargazerCount == 0 { continue }
            if onlyWithOpenIssues, repo.openIssueCount == 0 { continue }
            if onlyPushedRecently, (repo.pushedAt ?? .distantPast) < recentCutoff { continue }
            result.append(Row(repo: repo, standing: Self.standing(for: repo, scope: scope, now: now)))
        }
        return Self.sorted(result, by: sort)
    }

    /// Mirrors ``RepositoryScope/filter(_:now:)`` exactly, including the order
    /// of its checks: excluded beats pinned, pinned beats every filter. If that
    /// method changes, this has to change with it or the indicator lies.
    static func standing(for repo: RepoSnapshot, scope: RepositoryScope, now: Date) -> ScopeStanding {
        if scope.excluded.contains(repo.nameWithOwner) { return .excluded }
        if scope.pinned.contains(repo.nameWithOwner) { return .pinned }
        if repo.isPrivate && !scope.includePrivate { return .outsideRule }
        if repo.isFork && !scope.includeForks { return .outsideRule }
        if let days = scope.activeWithinDays {
            guard let pushedAt = repo.pushedAt else { return .outsideRule }
            if pushedAt < now.addingTimeInterval(-Double(days) * 86_400) { return .outsideRule }
        }
        return .byRule
    }

    private static func sorted(_ rows: [Row], by order: SortOrder) -> [Row] {
        switch order {
        case .lastPush:
            return rows.sorted { ($0.repo.pushedAt ?? .distantPast) > ($1.repo.pushedAt ?? .distantPast) }
        case .stars:
            return rows.sorted { lhs, rhs in
                guard lhs.repo.stargazerCount == rhs.repo.stargazerCount else {
                    return lhs.repo.stargazerCount > rhs.repo.stargazerCount
                }
                return lhs.repo.nameWithOwner.localizedCaseInsensitiveCompare(rhs.repo.nameWithOwner) == .orderedAscending
            }
        case .name:
            return rows.sorted {
                $0.repo.nameWithOwner.localizedCaseInsensitiveCompare($1.repo.nameWithOwner) == .orderedAscending
            }
        }
    }

    // MARK: - Summary

    private var watchedCount: Int {
        model.preferences.repositoryScope.filter(candidates).count
    }

    /// `Profile.publicRepoCount` carries `repositories(ownerAffiliations: [OWNER]).totalCount`,
    /// which is every repository the account owns — the honest denominator even
    /// before the full list has loaded.
    private var totalCount: Int {
        max(candidates.count, model.profile?.publicRepoCount ?? 0)
    }

    private var summaryLine: String {
        let repositories = totalCount == 1 ? "repository" : "repositories"
        return "Watching \(watchedCount) of \(totalCount) \(repositories)"
    }

    private var pinnedCount: Int { model.preferences.repositoryScope.pinned.count }

    /// The active rule, in words, generated from the scope rather than
    /// hardcoded, so it cannot drift from what the client actually does.
    private var ruleSentence: String {
        let scope = model.preferences.repositoryScope
        var sentence = "Rule: "
        sentence += scope.includePrivate ? "public and private" : "public"
        sentence += scope.includeForks ? ", including forks" : ", non-fork"
        if let days = scope.activeWithinDays {
            sentence += ", pushed in the last \(days) days"
        } else {
            sentence += ", any age"
        }
        sentence += "."

        var overrides: [String] = []
        if pinnedCount > 0 { overrides.append("\(pinnedCount) pinned") }
        let excluded = scope.excluded.count
        if excluded > 0 { overrides.append("\(excluded) excluded") }
        if !overrides.isEmpty {
            sentence += " Plus " + overrides.joined(separator: " and ") + "."
        }
        return sentence
    }

    /// Pins and exclusions naming something the catalog does not contain — a
    /// repository that was renamed, transferred or deleted. Only meaningful
    /// once the full list is in, otherwise everything looks orphaned.
    private var orphanedRules: [String] {
        guard !model.repositoryCatalog.isEmpty else { return [] }
        let known = Set(candidates.map(\.nameWithOwner))
        let scope = model.preferences.repositoryScope
        return scope.pinned.union(scope.excluded).subtracting(known).sorted()
    }

    private var activeFilterCount: Int {
        var count = 0
        if onlyWithStars { count += 1 }
        if onlyWithOpenIssues { count += 1 }
        if onlyPushedRecently { count += 1 }
        if !showForks { count += 1 }
        if !showPrivate { count += 1 }
        return count
    }

    // MARK: - Mutations

    private func clearFilters() {
        onlyWithStars = false
        onlyWithOpenIssues = false
        onlyPushedRecently = false
        showForks = true
        showPrivate = true
    }

    private func decisionBinding(for row: Row) -> Binding<ScopeDecision> {
        Binding(
            get: { row.standing.decision },
            set: { apply($0, to: row.repo.nameWithOwner) }
        )
    }

    private func apply(_ decision: ScopeDecision, to name: String) {
        var scope = model.preferences.repositoryScope
        scope.pinned.remove(name)
        scope.excluded.remove(name)
        switch decision {
        case .rule: break
        case .always: scope.pinned.insert(name)
        case .never: scope.excluded.insert(name)
        }
        // Every scope change re-seeds the baseline and refreshes, so a no-op
        // write is a wasted round trip.
        guard scope != model.preferences.repositoryScope else { return }
        model.updateScope(scope)
    }

    private func clearRules(for name: String) {
        apply(.rule, to: name)
    }

    private func scopeBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<RepositoryScope, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.preferences.repositoryScope[keyPath: keyPath] },
            set: { newValue in
                var scope = model.preferences.repositoryScope
                guard scope[keyPath: keyPath] != newValue else { return }
                scope[keyPath: keyPath] = newValue
                model.updateScope(scope)
            }
        )
    }
}

// MARK: - Row

/// One repository. Carries no reference to the model: everything it renders is
/// already resolved, which keeps 178 of these cheap.
@MainActor
struct RepositoryScopeRow: View {
    let row: RepositoryPickerView.Row
    let viewerLogin: String?
    @Binding var decision: RepositoryPickerView.ScopeDecision

    private var repo: RepoSnapshot { row.repo }

    /// Owners are only worth showing when they are not the signed-in user —
    /// which happens for a pinned organization repository.
    private var foreignOwner: String? {
        let owner = repo.nameWithOwner.split(separator: "/").first.map(String.init)
        guard let owner, let viewerLogin, owner.caseInsensitiveCompare(viewerLogin) != .orderedSame else { return nil }
        return owner
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.standing.symbolName)
                .foregroundStyle(row.standing.tint)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if let foreignOwner {
                        Text("\(foreignOwner)/")
                            .foregroundStyle(.secondary)
                    }
                    Text(repo.shortName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if repo.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Private")
                    }
                    if repo.isFork {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Fork")
                    }
                }

                HStack(spacing: 10) {
                    metric("star", value: repo.stargazerCount, label: "stars")
                    metric("exclamationmark.circle", value: repo.openIssueCount, label: "open issues")
                    if let pushedAt = repo.pushedAt {
                        Text(pushedAt, format: .relative(presentation: .numeric))
                            .accessibilityLabel("Last push \(pushedAt.formatted(date: .abbreviated, time: .omitted))")
                    } else {
                        Text("never pushed")
                    }
                    Text(row.standing.label)
                        .foregroundStyle(row.standing.isWatched ? Color.accentColor : Color.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Picker("", selection: $decision) {
                ForEach(RepositoryPickerView.ScopeDecision.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 140)
            .accessibilityLabel("Watch rule for \(repo.nameWithOwner)")
        }
        .padding(.vertical, 2)
    }

    private func metric(_ symbolName: String, value: Int, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbolName)
                .accessibilityHidden(true)
            Text(value.formatted())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}

#if DEBUG
#Preview("Repositories") {
    RepositoryPickerView(model: SampleData.populatedModel)
        .frame(width: 560, height: 460)
}
#endif
