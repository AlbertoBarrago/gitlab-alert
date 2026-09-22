import GitLabKit
import SwiftUI

/// One derived event: "3 new stars on telemaco", with the faces of who did it.
///
/// This is the row no other GitLab client has, because GitLab itself never
/// notifies about stars or forks — the event is ours, computed from counter
/// deltas, and the attribution arrives a beat later. So the row is built in two
/// stages on purpose: the count is complete and correct on its own, and the
/// avatars slide in when `ActivityEvent.actors` fills. While
/// `needsAttribution` is true there is no placeholder face and no grey circle
/// pretending to be a person; the sentence simply stands by itself.
struct ActivityRowView: View {

    let event: ActivityEvent
    var isUnread: Bool = false
    var isSelected: Bool = false
    var indent: CGFloat = 8
    let open: () -> Void
    var markSeen: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 7) {
                unreadMark

                kindGlyph

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        phrase
                            .font(.system(size: 12.5))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        Spacer(minLength: 4)

                        RelativeDateText(date: event.occurredAt)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if let title = event.title, !title.isEmpty {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    if !event.actors.isEmpty {
                        AvatarStackView(actors: event.actors, size: 19)
                            .padding(.top, 1)
                            .transition(
                                .opacity.combined(with: .scale(scale: 0.82, anchor: .leading))
                            )
                    }
                }
            }
            .padding(.leading, indent)
            .padding(.trailing, isUnread && markSeen != nil ? 38 : 8)
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
        // Feedback, not decoration: the only thing this animates is the moment
        // attribution lands and the faces appear.
        .animation(.smooth(duration: 0.3), value: event.actors.count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(event.url == nil ? "Opens the activity list" : "Opens on GitLab"))
        .overlay(alignment: .trailing) {
            if isUnread, let markSeen {
                Button(action: markSeen) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 7)
                .help("Mark as Seen")
                .accessibilityLabel("Mark as Seen")
            }
        }
    }

    // MARK: - Pieces

    /// Kept in the layout at zero opacity so read and unread rows start their
    /// text at the same x.
    private var unreadMark: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 5, height: 5)
            .padding(.top, 8)
            .opacity(isUnread ? 1 : 0)
            .accessibilityHidden(true)
    }

    private var kindGlyph: some View {
        ZStack {
            Circle()
                .fill(event.kind.tint.opacity(0.16))
            Image(systemName: event.kind.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(event.kind.tint)
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private var backgroundFill: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    // MARK: - Phrasing

    /// Built by concatenating `Text` so the repository and the count can be
    /// emphasised inside one wrapping paragraph.
    private var phrase: Text {
        let repo = Text(shortRepository).fontWeight(.semibold)

        switch event.kind {
        case .checksFailed:
            return Text("Checks failed on ") + repo
        case .checksRecovered:
            return Text("Checks are green again on ") + repo
        case .reviewRequested:
            return Text("Review requested on ") + repo
        case .inboundIssue:
            return Text("New issue on ") + repo
        case .inboundMergeRequest:
            return Text("New merge request on ") + repo
        case .pushed:
            return Text("\(commitPhrase) pushed to ") + repo
        }
    }

    /// "1 commit" or "4 commits": `delta` is the push's commit count.
    private var commitPhrase: String {
        event.delta == 1 ? "1 commit" : "\(event.delta) commits"
    }

    private var shortRepository: String {
        event.repository.split(separator: "/").last.map(String.init) ?? event.repository
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if isUnread { parts.append("Unread") }
        parts.append(spokenPhrase)
        if let title = event.title, !title.isEmpty { parts.append(title) }
        if !event.actors.isEmpty {
            parts.append(Array(event.actors.prefix(3).map(\.login)).formatted(.list(type: .and)))
        }
        parts.append(RelativeDateText.string(for: event.occurredAt, now: Date(), style: .phrase))
        return parts.joined(separator: ", ")
    }

    /// VoiceOver cannot read a concatenated `Text`, so the same sentence exists
    /// once more as a plain string.
    private var spokenPhrase: String {
        switch event.kind {
        case .checksFailed:
            return "Checks failed on \(shortRepository)"
        case .checksRecovered:
            return "Checks are green again on \(shortRepository)"
        case .reviewRequested:
            return "Review requested on \(shortRepository)"
        case .inboundIssue:
            return "New issue on \(shortRepository)"
        case .inboundMergeRequest:
            return "New merge request on \(shortRepository)"
        case .pushed:
            return "\(commitPhrase) pushed to \(shortRepository)"
        }
    }
}

private extension ActivityKind {

    /// All of these ship with macOS 14.
    var symbolName: String {
        switch self {
        case .checksFailed: return "xmark"
        case .checksRecovered: return "checkmark"
        case .reviewRequested: return "eyeglasses"
        case .inboundIssue: return "exclamationmark.bubble.fill"
        case .inboundMergeRequest: return "arrow.triangle.pull"
        case .pushed: return "arrow.up"
        }
    }

    var tint: Color {
        switch self {
        case .checksFailed: return .red
        case .checksRecovered: return .green
        case .reviewRequested: return .blue
        case .inboundIssue: return .orange
        case .inboundMergeRequest: return .teal
        case .pushed: return .purple
        }
    }
}

#Preview("Activity rows") {
    VStack(spacing: 1) {
        ForEach(SampleData.activity) { event in
            ActivityRowView(
                event: event,
                isUnread: event.id == "E_stars_burst" || event.id == "E_stars_pending",
                isSelected: event.id == "E_fork"
            ) {}
        }
    }
    .padding(8)
    .frame(width: PopoverController.contentWidth)
}

#Preview("Attribution arriving") {
    AttributionDemo()
        .frame(width: PopoverController.contentWidth)
}

/// Shows the two-stage row: the count first, the faces when they land.
private struct AttributionDemo: View {

    @State private var attributed = false

    private var event: ActivityEvent {
        var event = SampleData.activity[1]
        if attributed { event.actors = Array(SampleData.actors.prefix(2)) }
        return event
    }

    var body: some View {
        VStack(spacing: 10) {
            ActivityRowView(event: event, isUnread: true) {}
            Button(attributed ? "Forget who" : "Attribution arrives") {
                attributed.toggle()
            }
            .font(.caption)
        }
        .padding(8)
    }
}
