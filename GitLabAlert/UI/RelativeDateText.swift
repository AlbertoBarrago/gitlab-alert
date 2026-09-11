import SwiftUI

/// A relative age — "3h" in a dense row, "4 minutes ago" in the footer — that
/// can keep itself current without the surrounding view re-rendering.
///
/// The strings are built by hand rather than delegated to
/// `RelativeDateTimeFormatter`. Two reasons: the compact form the rows need
/// ("3h", "2d") has no formatter equivalent at any `unitsStyle`, and a
/// formatter's output width varies with the locale, which would let a row
/// reflow as its age crosses a unit boundary. Every user-facing string in this
/// app is an English literal already, so nothing is lost.
struct RelativeDateText: View {

    enum Style {
        /// "now", "12s", "5m", "3h", "2d", "6w", "4mo", "2y" — for dense rows.
        case compact
        /// "just now", "12 seconds ago", "5 minutes ago" — for the footer.
        case phrase
    }

    let date: Date
    var style: Style = .compact
    /// Whether the label advances as time passes. Only worth paying for on the
    /// one label the user actually watches tick: the footer's "updated …".
    var isLive: Bool = false

    var body: some View {
        if isLive {
            // The schedule is fixed when the view is built, so the cadence is
            // chosen from the age at that moment. `lastFetch` changes on every
            // poll cycle, which re-evaluates this body and re-picks it.
            TimelineView(.periodic(from: date, by: Self.cadence(since: date))) { context in
                label(now: context.date)
            }
        } else {
            label(now: Date())
        }
    }

    private func label(now: Date) -> some View {
        Text(Self.string(for: date, now: now, style: style))
            .monospacedDigit()
            // "3h" is unreadable aloud, so VoiceOver always gets the phrase.
            .accessibilityLabel(Text(Self.string(for: date, now: now, style: .phrase)))
    }

    private static func cadence(since date: Date) -> TimeInterval {
        Date().timeIntervalSince(date) < 120 ? 1 : 30
    }

    // MARK: - Formatting

    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 3_600
    private static let day: TimeInterval = 86_400
    private static let week: TimeInterval = 604_800
    private static let month: TimeInterval = 2_592_000
    private static let year: TimeInterval = 31_536_000

    static func string(for date: Date, now: Date, style: Style) -> String {
        // A future timestamp means clock skew between us and GitLab, not a
        // countdown: clamp it to zero rather than rendering "in 3 seconds".
        let seconds = max(0, now.timeIntervalSince(date))

        switch style {
        case .compact:
            if seconds < 5 { return "now" }
            if seconds < minute { return "\(Int(seconds))s" }
            if seconds < hour { return "\(Int(seconds / minute))m" }
            if seconds < day { return "\(Int(seconds / hour))h" }
            if seconds < week { return "\(Int(seconds / day))d" }
            if seconds < month { return "\(Int(seconds / week))w" }
            if seconds < year { return "\(Int(seconds / month))mo" }
            return "\(Int(seconds / year))y"

        case .phrase:
            if seconds < 5 { return "just now" }
            if seconds < minute { return ago(Int(seconds), "second") }
            if seconds < hour { return ago(Int(seconds / minute), "minute") }
            if seconds < day { return ago(Int(seconds / hour), "hour") }
            if seconds < week { return ago(Int(seconds / day), "day") }
            if seconds < month { return ago(Int(seconds / week), "week") }
            if seconds < year { return ago(Int(seconds / month), "month") }
            return ago(Int(seconds / year), "year")
        }
    }

    private static func ago(_ count: Int, _ unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s") ago"
    }
}

#Preview("Relative ages") {
    let now = Date()
    return VStack(alignment: .leading, spacing: 6) {
        ForEach([3.0, 42.0, 380.0, 9_000.0, 300_000.0, 4_000_000.0], id: \.self) { offset in
            HStack(spacing: 12) {
                RelativeDateText(date: now.addingTimeInterval(-offset))
                    .frame(width: 40, alignment: .leading)
                RelativeDateText(date: now.addingTimeInterval(-offset), style: .phrase)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }
    .padding()
    .frame(width: 240)
}
