import GitLabKit
import SwiftUI

/// Overlapping avatars, capped with a "+N" chip: who starred, who forked.
///
/// Each disc is masked by the outline of the one overlapping it from the left,
/// which is what makes the pile read as separated discs. The usual trick —
/// a solid ring in the background colour — cannot work here: the popover's
/// background is vibrant material, so there is no single colour to draw.
struct AvatarStackView: View {

    let actors: [GLActor]
    var size: CGFloat = 20
    /// Faces shown before the rest collapse into the chip.
    var maxVisible: Int = 4
    /// Fraction of a disc hidden behind its left neighbour.
    var overlap: CGFloat = 0.34
    /// Width of the carved gap between two discs.
    var gap: CGFloat = 1.5

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(elements.enumerated()), id: \.element.id) { index, element in
                view(for: element)
                    .frame(width: size, height: size)
                    .mask(cutout(hasLeftNeighbour: index > 0))
                    .offset(x: step * CGFloat(index))
                    // Leftmost on top, so the pile reads left to right.
                    .zIndex(Double(elements.count - index))
            }
        }
        // Offsets do not grow a ZStack, so the width has to be stated or the
        // stack would overlap whatever follows it in the row.
        .frame(width: totalWidth, height: size, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityDescription))
    }

    // MARK: - Elements

    private enum Element: Identifiable {
        case actor(GLActor)
        case overflow(Int)

        var id: String {
            switch self {
            case .actor(let actor): return "actor:\(actor.login)"
            case .overflow(let count): return "overflow:\(count)"
            }
        }
    }

    private var elements: [Element] {
        let shown = actors.prefix(maxVisible).map(Element.actor)
        let hidden = actors.count - shown.count
        return hidden > 0 ? shown + [.overflow(hidden)] : shown
    }

    private var step: CGFloat { size * (1 - overlap) }

    private var totalWidth: CGFloat {
        guard !elements.isEmpty else { return 0 }
        return size + step * CGFloat(elements.count - 1)
    }

    @ViewBuilder
    private func view(for element: Element) -> some View {
        switch element {
        case .actor(let actor):
            AvatarView(login: actor.login, avatarURL: actor.avatarURL, size: size)
        case .overflow(let count):
            ZStack {
                Circle().fill(Color.primary.opacity(0.12))
                Text("+\(count)")
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Punches the left neighbour's outline out of this disc. Inflated by `gap`
    /// so what is left is a hairline of background, not a seam.
    private func cutout(hasLeftNeighbour: Bool) -> some View {
        ZStack {
            Circle()
            if hasLeftNeighbour {
                Circle()
                    .frame(width: size + gap * 2, height: size + gap * 2)
                    .offset(x: -step)
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
    }

    private var accessibilityDescription: String {
        let names = actors.prefix(maxVisible).map(\.login)
        let hidden = actors.count - names.count
        switch (names.count, hidden) {
        case (0, _):
            return "No one yet"
        case (_, 0):
            return names.formatted(.list(type: .and))
        default:
            return "\(names.formatted(.list(type: .and))) and \(hidden) more"
        }
    }
}

#Preview("Avatar stacks") {
    VStack(alignment: .leading, spacing: 14) {
        AvatarStackView(actors: Array(SampleData.actors.prefix(1)))
        AvatarStackView(actors: Array(SampleData.actors.prefix(3)))
        AvatarStackView(actors: SampleData.actors)
        AvatarStackView(actors: SampleData.actors, size: 28, maxVisible: 5)
    }
    .padding()
    .frame(width: 260, alignment: .leading)
}
