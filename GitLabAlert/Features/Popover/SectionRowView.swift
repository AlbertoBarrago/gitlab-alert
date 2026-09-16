import SwiftUI

/// One collapsible dashboard section header: glyph, title, and the number that
/// is the whole point of the row.
struct SectionRowView: View {

    let section: DashboardSection
    let count: Int
    let isExpanded: Bool
    let isSelected: Bool
    /// Dimmed when there is nothing underneath, so a busy popover reads at a
    /// glance instead of presenting six equally loud rows.
    var isMuted: Bool = false
    let toggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy(duration: 0.18), value: isExpanded)
                    .frame(width: 10)

                Image(systemName: section.symbolName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 15)

                Text(section.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 6)

                countLabel
            }
            .opacity(isMuted ? 0.55 : 1)
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(isExpanded ? "Collapses this section" : "Expands this section"))
        .accessibilityAddTraits(isExpanded ? [.isButton, .isSelected] : .isButton)
    }

    /// The number rolls rather than snaps, which is the one place in this app
    /// where a star arriving while the popover is open is visible as motion.
    /// The width is reserved so two digits becoming three does not shove the
    /// title sideways.
    private var countLabel: some View {
        Text(count.formatted())
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(count)))
            .foregroundStyle(count == 0 ? Color.secondary.opacity(0.5) : Color.accentColor)
            .opacity(count == 0 ? 0 : 1)
            .frame(minWidth: 24, alignment: .trailing)
            .accessibilityHidden(true)
    }

    private var backgroundFill: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var accessibilityLabel: String {
        count == 0 ? section.title : "\(section.title), \(count)"
    }
}

#Preview("Section rows") {
    VStack(spacing: 1) {
        SectionRowView(section: .reviewRequested, count: 3, isExpanded: true, isSelected: false) {}
        SectionRowView(section: .assignedIssues, count: 12, isExpanded: false, isSelected: true) {}
        SectionRowView(section: .inboundIssues, count: 0, isExpanded: false, isSelected: false, isMuted: true) {}
        SectionRowView(section: .repositories, count: 2, isExpanded: false, isSelected: false) {}
        SectionRowView(section: .activity, count: 148, isExpanded: false, isSelected: false) {}
    }
    .padding(8)
    .frame(width: PopoverController.contentWidth)
}
