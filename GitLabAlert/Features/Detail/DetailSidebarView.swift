import GitLabKit
import SwiftUI

/// The detail window's first column: the dashboard sections, then every watched
/// repository.
///
/// The repository list is filterable rather than merely scrollable because this
/// account watches 178 of them — a plain list is a wall, and the sidebar is
/// where the user goes when they already know which repository they mean.
struct DetailSidebarView: View {
    let model: AppModel
    @Binding var target: DetailTarget?
    @Binding var repositoryQuery: String

    var body: some View {
        List(selection: $target) {
            if model.showProfileHeader, let profile = model.profile {
                profileHeader(profile)
            }

            Section("Dashboard") {
                ForEach(model.sections) { section in
                    sectionRow(section)
                        .tag(DetailTarget.section(section))
                }
                // Last in the group: it summarises the sections above it
                // rather than being another list of work.
                Label("Report", systemImage: "chart.bar")
                    .tag(DetailTarget.report)
                    .accessibilityLabel("Report, recorded activity by project")
            }

            Section {
                if model.repositories.isEmpty {
                    Text(model.snapshot == nil ? "Not loaded yet" : "No repositories in scope")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if filteredRepositories.isEmpty {
                    Text("No repository matches \u{201C}\(repositoryQuery)\u{201D}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredRepositories) { repo in
                        repositoryRow(repo)
                            .tag(DetailTarget.repository(repo.nameWithOwner))
                    }
                }
            } header: {
                repositoriesHeader
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .accessibilityLabel("Sections and repositories")
    }

    // MARK: - Header

    private func profileHeader(_ profile: Profile) -> some View {
        HStack(spacing: 8) {
            DetailAvatarView(actor: GLActor(login: profile.login, avatarURL: profile.avatarURL), size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("@\(profile.login)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        // Not selectable: it is a header, not a destination.
        .selectionDisabled()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signed in as \(profile.displayName), @\(profile.login)")
    }

    private var repositoriesHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Repositories")
                Spacer()
                Text("\(model.repositories.count)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("\(model.repositories.count) watched")
            }
            // A plain field rather than `.searchable`: that modifier belongs to
            // the content column's table, and two search fields in one window
            // would compete for ⌘F.
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter repositories", text: $repositoryQuery)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !repositoryQuery.isEmpty {
                    Button {
                        repositoryQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear repository filter")
                }
            }
            .padding(.bottom, 2)
        }
    }

    // MARK: - Rows

    private func sectionRow(_ section: DashboardSection) -> some View {
        let count = model.count(for: section)
        return Label(section.title, systemImage: section.symbolName)
            .badge(count)
            .accessibilityLabel(
                count > 0
                    ? "\(section.title), \(count)"
                    : "\(section.title), nothing waiting"
            )
    }

    private func repositoryRow(_ repo: RepoSnapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: repo.isPrivate ? "lock" : "shippingbox")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(repo.shortName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if repo.checkState.isBroken {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(repo.nameWithOwner), pipeline \(DetailLabels.name(for: repo.checkState))"
        )
    }

    // MARK: - Filtering

    /// Broken repositories first: in a list this long, the red ones are the
    /// reason the user opened the sidebar at all.
    private var filteredRepositories: [RepoSnapshot] {
        let query = repositoryQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = query.isEmpty
            ? model.repositories
            : model.repositories.filter { $0.nameWithOwner.lowercased().contains(query) }
        return matching.sorted { lhs, rhs in
            if lhs.checkState.isBroken != rhs.checkState.isBroken {
                return lhs.checkState.isBroken
            }
            return lhs.nameWithOwner.localizedCaseInsensitiveCompare(rhs.nameWithOwner) == .orderedAscending
        }
    }
}

#if DEBUG
#Preview("Sidebar") {
    DetailPreviewHarness { model in
        NavigationSplitView {
            DetailSidebarView(
                model: model,
                target: .constant(.section(.reviewRequested)),
                repositoryQuery: .constant("")
            )
        } detail: {
            Text("Content")
        }
        .frame(width: 720, height: 480)
    }
}
#endif
