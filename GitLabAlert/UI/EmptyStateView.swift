import SwiftUI

/// "Nothing here" said in a real sentence.
///
/// The resting state is what this app shows most of the time, so it is a
/// designed state rather than a blank one. The glyph is deliberately tenuous:
/// it should register as calm, not as a warning.
struct EmptyStateView: View {

    enum Style {
        /// Centred, for when the whole dashboard is quiet.
        case hero
        /// One line, for a single expanded section that has nothing in it.
        case inline
    }

    let symbolName: String
    let message: String
    var detail: String?
    var style: Style = .inline

    var body: some View {
        switch style {
        case .hero:
            VStack(spacing: 7) {
                Image(systemName: symbolName)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .padding(.horizontal, 16)
            .accessibilityElement(children: .combine)

        case .inline:
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .accessibilityElement(children: .combine)
        }
    }
}

#Preview("Empty states") {
    VStack(alignment: .leading, spacing: 0) {
        EmptyStateView(
            symbolName: "checkmark.circle",
            message: "Nothing waiting on you",
            detail: "12 repositories watched · 1.4K stars",
            style: .hero
        )
        Divider()
        EmptyStateView(symbolName: "eyeglasses", message: "No reviews waiting on you")
            .padding(.leading, 24)
        EmptyStateView(symbolName: "shippingbox", message: "All checks are green")
            .padding(.leading, 24)
    }
    .padding(8)
    .frame(width: PopoverController.contentWidth)
}
