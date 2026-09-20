import GitLabKit
import SwiftUI

/// The report: where the breakage and the work concentrate.
///
/// Everything on screen is computed by ``ReportEngine`` from the snapshot and
/// the activity log the app already holds, so opening this costs no API budget
/// and stores nothing new. The window it covers is stated at the top rather
/// than implied: the activity log is capped, so these are not lifetime totals
/// and a reader must not mistake them for one.
///
/// The layout assumes the narrow middle column of the detail window, not a full
/// window: tiles wrap two by two and each project is a row of its own with its
/// numbers spelled out underneath, because a six-column table in 350 points
/// turns every heading into a vertical column of letters.
struct ReportView: View {
    let model: AppModel

    private var report: ActivityReport {
        ReportEngine.make(snapshot: model.snapshot, activityLog: model.activityLog)
    }

    var body: some View {
        let report = report

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                window(report)
                summary(report)
                if let oldest = report.oldestOpenItem {
                    oldestItem(oldest)
                }
                projects(report)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .navigationTitle("Report")
    }

    // MARK: - Window

    private func window(_ report: ActivityReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Observed activity")
                .font(.headline)
            Text(windowDescription(report))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func windowDescription(_ report: ActivityReport) -> String {
        guard let from = report.observedFrom else {
            return "Nothing recorded yet. The numbers below come from the last refresh."
        }
        return "Since \(from.formatted(date: .abbreviated, time: .shortened)), from what this Mac saw while the app was running."
    }

    // MARK: - Summary

    private func summary(_ report: ActivityReport) -> some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                tile("Went red", value: "\(report.totalFailures)")
                tile("Recovered", value: "\(report.totalRecoveries)")
            }
            GridRow {
                tile("Mean recovery", value: report.meanTimeToRecovery.map(Self.duration) ?? "—")
                tile("Red now", value: "\(report.brokenNow.count)", isAlarming: !report.brokenNow.isEmpty)
            }
        }
    }

    private func tile(_ title: String, value: String, isAlarming: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isAlarming ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    // MARK: - Oldest open item

    private func oldestItem(_ item: ReportOpenItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Open the longest")
                .font(.headline)
            Button {
                model.openOnGitLab(item.url)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.kind == .review ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("\(item.repository) · opened \(item.openedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open on GitLab")
        }
    }

    // MARK: - Per project

    @ViewBuilder
    private func projects(_ report: ActivityReport) -> some View {
        if !report.projects.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("By project")
                    .font(.headline)

                VStack(spacing: 0) {
                    ForEach(Array(report.projects.enumerated()), id: \.element.id) { index, project in
                        if index > 0 { Divider() }
                        projectRow(project)
                    }
                }
            }
        }
    }

    private func projectRow(_ project: ProjectReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if project.isBroken {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Text(project.repository)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            Text(Self.projectSummary(project))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.repository). \(Self.projectSummary(project))\(project.isBroken ? ". Red now" : "")")
    }

    /// One sentence instead of six columns: at this width a table cannot show
    /// its headings, and a number without its heading is noise.
    private static func projectSummary(_ project: ProjectReport) -> String {
        var parts: [String] = []
        if project.failures > 0 { parts.append("\(project.failures) red") }
        if project.recoveries > 0 { parts.append("\(project.recoveries) recovered") }
        if let mean = project.meanTimeToRecovery { parts.append("~\(duration(mean)) to recover") }
        if project.openReviews > 0 { parts.append("\(project.openReviews) review\(project.openReviews == 1 ? "" : "s")") }
        if project.openIssues > 0 { parts.append("\(project.openIssues) issue\(project.openIssues == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing recorded" : parts.joined(separator: " · ")
    }

    // MARK: - Formatting

    /// Compact and rounded: the point is the order of magnitude, not the second.
    private static func duration(_ interval: TimeInterval) -> String {
        Duration.seconds(interval).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)
        )
    }
}
