import GitLabKit
import SwiftUI

/// The bottom strip: how fresh the data is, and the two things the user can do
/// about it.
struct PopoverFooterView: View {

    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let warning = model.rateLimitWarning {
                // Only ever rendered when the model says the budget is actually
                // low; the remaining count is noise the rest of the time.
                Label(warning, systemImage: "speedometer")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                freshness

                Spacer(minLength: 8)

                IconButton(
                    systemImage: "arrow.clockwise",
                    label: "Refresh",
                    shortcutHint: "⌘R",
                    isBusy: model.isLoading,
                    action: { model.refresh() }
                )

                IconButton(
                    systemImage: "gearshape",
                    label: "Settings",
                    shortcutHint: "⌘,",
                    action: { model.openSettings() }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// A failed refresh never blanks the popover, so it has to be legible here
    /// instead: the age stays, with an honest marker in front of it.
    @ViewBuilder
    private var freshness: some View {
        HStack(spacing: 4) {
            if model.isShowingStaleData {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }

            if let lastFetch = model.lastFetch {
                HStack(spacing: 3) {
                    Text(model.isShowingStaleData ? "couldn't refresh · updated" : "updated")
                    RelativeDateText(date: lastFetch, isLive: true)
                    Text("ago")
                }
            } else {
                Text("not updated yet")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(model.lastError?.userMessage ?? "How fresh this data is")
        .accessibilityElement(children: .combine)
    }
}

/// A 22×22 borderless glyph button: the only chrome the footer has.
private struct IconButton: View {

    let systemImage: String
    let label: String
    let shortcutHint: String
    var isBusy: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // The spinner replaces the glyph rather than spinning it: a
                // rotating icon reads as decoration, a progress indicator as
                // "a request is in flight".
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .opacity(isBusy ? 0 : 1)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
            .frame(width: 22, height: 22)
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering && !isBusy ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { isHovering = $0 }
        .help("\(label) (\(shortcutHint))")
        .accessibilityLabel(Text(label))
    }
}

#Preview("Footer states") {
    VStack(spacing: 0) {
        Divider()
        PopoverFooterView(model: SampleData.populatedModel)
        Divider()
        PopoverFooterView(model: SampleData.staleModel)
        Divider()
        PopoverFooterView(model: SampleData.lowBudgetModel)
        Divider()
        PopoverFooterView(model: SampleData.loadingModel)
        Divider()
    }
    .frame(width: PopoverController.contentWidth)
}
