import GitLabKit
import SwiftUI

/// One circular GitLab avatar, with a monogram standing in while it loads and
/// whenever it cannot be loaded at all.
///
/// The fetch itself belongs to ``AvatarLoader``: whether the GitLab credential
/// may travel with the request depends on the configured origin, which is not
/// something a view should be deciding. Without an injected loader the view
/// falls back to the anonymous one, so a missing injection costs an avatar on a
/// private instance rather than leaking a token.
struct AvatarView: View {

    let login: String
    let avatarURL: URL?
    var size: CGFloat = 22
    @Environment(\.avatarLoader) private var loader
    @State private var imageData: Data?

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                // Keeps a light avatar from dissolving into a light popover.
                Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .accessibilityLabel(Text(login))
            .task(id: avatarURL) {
                await loadAvatar()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let imageData, let image = NSImage(data: imageData) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            monogram
        }
    }

    private func loadAvatar() async {
        imageData = await (loader ?? .anonymous).imageData(for: avatarURL)
    }

    // MARK: - Monogram

    private var monogram: some View {
        ZStack {
            LinearGradient(
                colors: [tint.opacity(0.90), tint.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            Text(initial)
                .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var initial: String {
        guard let character = login.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(character).uppercased()
    }

    private static let palette: [Color] = [
        .blue, .purple, .pink, .orange, .teal, .indigo, .green, .cyan
    ]

    /// FNV-1a rather than `hashValue`: Swift's hashing is seeded per process,
    /// so the same login would pick a different colour after every relaunch.
    private var tint: Color {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in login.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return Self.palette[Int(hash % UInt64(Self.palette.count))]
    }
}

#Preview("Avatars") {
    HStack(spacing: 10) {
        AvatarView(login: "octocat", avatarURL: SampleData.actors[0].avatarURL, size: 34)
        AvatarView(login: "hubot", avatarURL: nil, size: 34)
        AvatarView(login: "alBz", avatarURL: nil, size: 22)
        // Refused: not https, so the monogram must win.
        AvatarView(login: "attacker", avatarURL: URL(string: "file:///etc/passwd"), size: 22)
        AvatarView(login: "1password", avatarURL: nil, size: 18)
    }
    .padding()
}
