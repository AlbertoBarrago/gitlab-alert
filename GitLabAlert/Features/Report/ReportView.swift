import GitLabKit
import SwiftUI

/// The report: where the breakage and the work concentrate.
///
/// Everything on screen is computed by ``ReportEngine`` from the snapshot and
/// the activity log the app already holds, so opening this costs no API budget
/// and stores nothing new. The window it covers is stated at the top rather
/// than implied: the activity log is capped, so these are not lifetime totals
/// and a reader must not mistake them for one.
struct ReportView: View {
    let model: AppModel

    private var report: ActivityReport {
        ReportEngine.make(snapshot: model.snapshot, activityLog: model.activityLog)
    }

    var body: some View {
        let report = report

        Group {
            if report.isEmpty {
                DetailEmptyStateView(
                    symbol: "chart.bar",
                    title: "Nothing to report yet",
                    message: "The report is built from what the app has seen while running. Leave it a few refreshes."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        window(report)
                        summary(report)
                        if let oldest = report.oldestOpenItem {
                            oldestItem(oldest)
                        }
                        projects(report)
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Report")
    }

    // MARK: - Window

    @ViewBuilder
    private func window(_ report: ActivityReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Observed activity")
                .font(.headline)
            if let from = report.observedFrom {
                Text("Since \(from.formatted(date: .abbreviated, time: .shortened)), from the events this Mac recorded while the app was running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No activity recorded yet. Open work below comes from the last refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Summary

    private func summary(_ report: ActivityReport) -> some View {
        HStack(alignment: .top, spacing: 12) {
            tile("Went red", value: "\(report.totalFailures)", detail: report.mostBroken.map { "most often \($0.repository)" })
            tile("Recovered", value: "\(report.totalRecoveries)", detail: nil)
            tile(
                "Mean recovery",
                value: report.meanTimeToRecovery.map(Self.duration) ?? "—",
                detail: report.meanTimeToRecovery == nil ? "no closed outage yet" : nil
            )
            tile(
                "Red now",
                value: "\(report.brokenNow.count)",
                detail: report.brokenNow.first,
                isAlarming: !report.brokenNow.isEmpty
            )
        }
    }

    private func tile(_ title: String, value: String, detail: String?, isAlarming: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isAlarming ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            Text(detail ?? " ")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Oldest open item

    private func oldestItem(_ item: ReportOpenItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Open the longest")
                .font(.headline)
            Button {
                model.openOnGitLab(item.url)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: item.kind == .review ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .lineLimit(1)
                        Text("\(item.repository) · opened \(item.openedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Per project

    private func projects(_ report: ActivityReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By project")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Project").gridColumnAlignment(.leading)
                    Text("Red").gridColumnAlignment(.trailing)
                    Text("Recovered").gridColumnAlignment(.trailing)
                    Text("Mean recovery").gridColumnAlignment(.trailing)
                    Text("Reviews").gridColumnAlignment(.trailing)
                    Text("Issues").gridColumnAlignment(.trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider().gridCellUnsizedAxes(.horizontal)

                ForEach(report.projects) { project in
                    GridRow {
                        HStack(spacing: 6) {
                            if project.isBroken {
                                Circle().fill(.red).frame(width: 6, height: 6)
                                    .accessibilityLabel("Currently red")
                            }
                            Text(project.repository).lineLimit(1)
                        }
                        Text("\(project.failures)").monospacedDigit()
                        Text("\(project.recoveries)").monospacedDigit()
                        Text(project.meanTimeToRecovery.map(Self.duration) ?? "—").monospacedDigit()
                        Text("\(project.openReviews)").monospacedDigit()
                        Text("\(project.openIssues)").monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: - Formatting

    /// Compact and rounded: the point is the order of magnitude, not the second.
    private static func duration(_ interval: TimeInterval) -> String {
        Duration.seconds(interval).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)
        )
    }
}
