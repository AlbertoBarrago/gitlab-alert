import GitLabKit
import SwiftUI

/// The detail window's inspector: everything about the selected row.
///
/// It carries no width of its own. It is presented by `.inspector`, not as a
/// `NavigationSplitView` column, and a `navigationSplitViewColumnWidth` here
/// travels up to the detail column instead and squeezes the table. The width
/// belongs to the `.inspectorColumnWidth` on the presenting view.
///
/// The table trades completeness for density; this is where the full title, the
/// whole label set and every timestamp live. Text is selectable because the
/// window is a real window — ⌘C on an issue title is a thing maintainers do.
struct DetailInspectorView: View {
    let model: AppModel
    let row: DetailRow?

    var body: some View {
        Group {
            if let row {
                inspector(row)
            } else {
                DetailEmptyStateView(
                    symbol: "sidebar.right",
                    title: "Nothing selected",
                    message: "Select a row to see its full detail."
                )
            }
        }
    }

    private func inspector(_ row: DetailRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heading(row)
                Divider()
                facts(row)
                if !row.labels.isEmpty {
                    labels(row)
                }
                if row.kind == .activity && !row.actors.isEmpty {
                    actors(row)
                }
                openButton(row)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .accessibilityLabel("Detail for \(row.title)")
    }

    // MARK: - Sections

    private func heading(_ row: DetailRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: row.kind == .activity ? (row.activityKind.map(DetailLabels.symbol(for:)) ?? "sparkles") : row.kind.symbolName)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(row.kind == .activity ? (row.activityKind.map(DetailLabels.name(for:)) ?? "Activity") : row.kind.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if row.isDraft {
                    Text("Draft")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if row.isUnread {
                    Text("New")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
            }

            Text(row.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 4) {
                if row.isPrivate {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(row.repository)
                    .foregroundStyle(.secondary)
                if let number = row.number {
                    Text("#\(number)")
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func facts(_ row: DetailRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let author = row.author {
                LabeledContent("Author") {
                    HStack(spacing: 6) {
                        DetailAvatarView(actor: author, size: 20)
                        Text(author.login)
                    }
                }
                .accessibilityLabel("Author \(author.login)")
            }

            switch row.kind {
            case .mergeRequest:
                if let decision = row.reviewDecision {
                    LabeledContent("Review") { DetailStateBadge(row: row) }
                        .accessibilityLabel("Review \(DetailLabels.name(for: decision))")
                }
                LabeledContent("Checks") { DetailCheckBadge(state: row.checkState) }
                if let comments = row.commentCount {
                    LabeledContent("Comments") { Text("\(comments)").monospacedDigit() }
                }
                timestamps(created: row.createdAt, updated: row.updatedAt, updatedLabel: "Updated")
            case .issue:
                if let comments = row.commentCount {
                    LabeledContent("Replies") { Text("\(comments)").monospacedDigit() }
                }
                timestamps(created: row.createdAt, updated: row.updatedAt, updatedLabel: "Updated")
            case .repository:
                LabeledContent("Checks") { DetailCheckBadge(state: row.checkState) }
                if let stars = row.stargazerCount {
                    LabeledContent("Stars") { Text("\(stars)").monospacedDigit() }
                }
                if let forks = row.forkCount {
                    LabeledContent("Forks") { Text("\(forks)").monospacedDigit() }
                }
                if let issues = row.openIssueCount {
                    LabeledContent("Open issues") { Text("\(issues)").monospacedDigit() }
                }
                if let pulls = row.openMergeRequestCount {
                    LabeledContent("Open merge requests") { Text("\(pulls)").monospacedDigit() }
                }
                LabeledContent("Last push") { absolute(row.updatedAt) }
            case .activity:
                if let kind = row.activityKind {
                    LabeledContent("Event") { Text(DetailLabels.name(for: kind)) }
                }
                if let delta = row.delta, delta > 1 {
                    LabeledContent("Count") { Text("\(delta)").monospacedDigit() }
                }
                LabeledContent("Happened") { absolute(row.occurredAt) }
            }
        }
        .font(.callout)
    }

    private func timestamps(created: Date, updated: Date, updatedLabel: String) -> some View {
        Group {
            LabeledContent("Opened") { absolute(created) }
            LabeledContent(updatedLabel) { absolute(updated) }
        }
    }

    private func absolute(_ date: Date) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(date, format: .relative(presentation: .numeric))
            Text(date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(date.formatted(date: .abbreviated, time: .shortened))
    }

    private func labels(_ row: DetailRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Labels")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            DetailWrapLayout(spacing: 5, lineSpacing: 5) {
                ForEach(row.labels, id: \.self) { label in
                    Text(label)
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Labels: \(row.labels.joined(separator: ", "))")
    }

    private func actors(_ row: DetailRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("People")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(row.actors) { actor in
                HStack(spacing: 6) {
                    DetailAvatarView(actor: actor, size: 20)
                    Text(actor.login)
                        .font(.callout)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(actor.login)
            }
        }
    }

    private func openButton(_ row: DetailRow) -> some View {
        Button {
            model.openOnGitLab(row.url)
        } label: {
            Label("Open on GitLab", systemImage: "arrow.up.forward.app")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(row.url == nil)
        .help(row.url == nil ? "This item has no link" : "Open in your browser (\u{2318}\u{21A9})")
        .padding(.top, 2)
    }
}

private extension DetailRow {
    /// Activity rows carry one timestamp; `occurredAt` names it for what it is.
    var occurredAt: Date { updatedAt }
}

/// A minimal wrapping layout for label chips.
///
/// `HStack` would push chips off the edge of a 300pt inspector and `LazyVGrid`
/// would force equal-width columns, which looks wrong for text of wildly
/// different lengths.
struct DetailWrapLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth == .infinity ? width : maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth && !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#if DEBUG
#Preview("Inspector \u{2014} merge request") {
    DetailPreviewHarness { model in
        DetailInspectorView(model: model, row: DetailPreviewFixtures.mergeRequestRow)
            .frame(width: 320, height: 520)
    }
}

#Preview("Inspector \u{2014} empty") {
    DetailPreviewHarness { model in
        DetailInspectorView(model: model, row: nil)
            .frame(width: 320, height: 400)
    }
}
#endif
