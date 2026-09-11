import GitLabKit
import SwiftUI

/// The rolled-up CI state of one thing, as a single dot.
///
/// `.unknown` is drawn rather than omitted: a repository with no checks
/// configured is a real, common answer, and a missing dot would let the row
/// above and the row below disagree about where the text starts.
struct CheckStateDot: View {

    let state: CheckState
    var size: CGFloat = 7

    var body: some View {
        shape
            .frame(width: size, height: size)
            .accessibilityLabel(Text(state.dotLabel))
            .help(state.dotLabel)
    }

    @ViewBuilder
    private var shape: some View {
        switch state {
        case .pending, .expected:
            // A ring, not a disc: "running" should not look like "green".
            Circle().strokeBorder(state.dotTint, lineWidth: max(1.5, size * 0.28))
        default:
            Circle().fill(state.dotTint)
        }
    }
}

private extension CheckState {

    var dotTint: Color {
        switch self {
        case .success: return .green
        case .failure, .error: return .red
        case .pending, .expected: return .orange
        case .unknown: return Color.secondary.opacity(0.28)
        }
    }

    var dotLabel: String {
        switch self {
        case .success: return "Checks passing"
        case .failure: return "Checks failing"
        case .error: return "Checks errored"
        case .pending: return "Checks running"
        case .expected: return "Checks expected"
        case .unknown: return "No checks"
        }
    }
}

#Preview("Check states") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(CheckState.allCases, id: \.self) { state in
            HStack(spacing: 8) {
                CheckStateDot(state: state)
                Text(state.rawValue).font(.caption)
            }
        }
    }
    .padding()
    .frame(width: 180)
}
