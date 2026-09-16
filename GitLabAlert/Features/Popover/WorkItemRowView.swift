import GitLabKit
import SwiftUI

/// One openable thing under an expanded section.
///
/// Merge requests, issues and red repositories all collapse into a single row
/// type on purpose: the popover then has one hover model, one selection model
/// and one accessibility shape, instead of three that drift apart.
struct WorkItemRowView: View {

    struct Item: Identifiable, Hashable {
        var id: String
        /// Repository short name — the owner is almost always the user.
        var repository: String
        var title: String
        var number: Int?
        var date: Date
        var checkState: CheckState
        var badge: Badge?
        var url: URL
    }

    struct Badge: Hashable {
        enum Tint: Hashable { case neutral, positive, caution, negative }
        var text: String
        var tint: Tint
    }

    let item: Item
    var isSelected: Bool = false
    var isUnread: Bool = false
    /// Lines the text up under the section title above it.
    var indent: CGFloat = 24
    let open: () -> Void
    var markSeen: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                CheckStateDot(state: item.checkState)
                    .padding(.top, 4)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 5) {
                        Text(item.repository)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if let number = item.number {
                            Text("#\(number)")
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }

                        if let badge = item.badge {
                            BadgeLabel(badge: badge)
                        }

                        Spacer(minLength: 4)

                        RelativeDateText(date: item.date)
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, indent)
            .padding(.trailing, isUnread && markSeen != nil ? 38 : 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text("Opens on GitLab"))
        .overlay(alignment: .trailing) {
            if isUnread, let markSeen {
                Button(action: markSeen) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 7)
                .help("Mark as Seen")
                .accessibilityLabel("Mark repository alert as seen")
            }
        }
    }

    private var backgroundFill: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var accessibilityLabel: String {
        var parts = [item.title, item.repository]
        if isUnread { parts.insert("Unread", at: 0) }
        if let number = item.number { parts.append("number \(number)") }
        if let badge = item.badge { parts.append(badge.text) }
        parts.append(RelativeDateText.string(for: item.date, now: Date(), style: .phrase))
        return parts.joined(separator: ", ")
    }
}

/// Why this row is here, in two words: the review state, the draft flag, or the
/// first label on an issue.
private struct BadgeLabel: View {

    let badge: WorkItemRowView.Badge

    var body: some View {
        Text(badge.text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            // Never truncate the reason; let the repository name give way.
            .fixedSize()
    }

    private var tint: Color {
        switch badge.tint {
        case .neutral: return .secondary
        case .positive: return .green
        case .caution: return .orange
        case .negative: return .red
        }
    }
}

// MARK: - Mapping the model types onto the row

extension WorkItemRowView.Item {

    init(mergeRequest pr: MergeRequestItem) {
        self.init(
            id: pr.id,
            repository: Self.shortName(pr.repository),
            title: pr.title,
            number: pr.number,
            date: pr.updatedAt,
            checkState: pr.checkState,
            badge: Self.badge(for: pr),
            url: pr.url
        )
    }

    init(issue: IssueItem) {
        self.init(
            id: issue.id,
            repository: Self.shortName(issue.repository),
            title: issue.title,
            number: issue.number,
            date: issue.updatedAt,
            // Issues carry no rollup of their own; the dot stays neutral rather
            // than borrowing the repository's state and implying something.
            checkState: .unknown,
            badge: issue.labels.first.map { WorkItemRowView.Badge(text: $0, tint: .neutral) },
            url: issue.url
        )
    }

    /// Only ever built from `brokenRepositories`, which is why the title can
    /// state the problem instead of repeating the name.
    init(repository repo: RepoSnapshot) {
        self.init(
            id: repo.id,
            repository: repo.shortName,
            title: repo.checkState == .error ? "Checks errored" : "Checks are failing",
            number: nil,
            date: repo.pushedAt ?? Date(),
            checkState: repo.checkState,
            badge: repo.defaultBranch.map { WorkItemRowView.Badge(text: $0, tint: .neutral) },
            url: repo.url
        )
    }

    private static func shortName(_ nameWithOwner: String) -> String {
        nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner
    }

    private static func badge(for pr: MergeRequestItem) -> WorkItemRowView.Badge? {
        if pr.isDraft { return WorkItemRowView.Badge(text: "Draft", tint: .neutral) }
        switch pr.reviewDecision {
        case .approved: return WorkItemRowView.Badge(text: "Approved", tint: .positive)
        case .changesRequested: return WorkItemRowView.Badge(text: "Changes requested", tint: .negative)
        case .reviewRequired: return WorkItemRowView.Badge(text: "Review required", tint: .caution)
        case ReviewDecision.none: return nil
        }
    }
}

#Preview("Work item rows") {
    VStack(spacing: 1) {
        ForEach(SampleData.reviewRequested.map(WorkItemRowView.Item.init(mergeRequest:))) { item in
            WorkItemRowView(item: item) {}
        }
        ForEach(SampleData.authoredMergeRequests.map(WorkItemRowView.Item.init(mergeRequest:))) { item in
            WorkItemRowView(item: item, isSelected: item.number == 413) {}
        }
        ForEach(SampleData.assignedIssues.map(WorkItemRowView.Item.init(issue:))) { item in
            WorkItemRowView(item: item) {}
        }
        ForEach(SampleData.repositories.filter { $0.checkState.isBroken }.map(WorkItemRowView.Item.init(repository:))) { item in
            WorkItemRowView(item: item) {}
        }
    }
    .padding(8)
    .frame(width: PopoverController.contentWidth)
}
