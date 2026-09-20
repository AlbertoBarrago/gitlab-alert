import GitLabKit
import SwiftUI

/// Who you are signed in as. Context, not the main event: one quiet line of
/// identity above the thing the user actually opened the popover for.
struct ProfileHeaderView: View {

    let profile: Profile
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                AvatarView(login: profile.login, avatarURL: profile.avatarURL, size: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Color.primary.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text("\(profile.displayName), @\(profile.login), \(subtitle)"))
        .accessibilityHint(Text("Opens your GitLab profile"))
    }

    /// Just the handle. GitLab's `/user` payload carries no follower counts —
    /// `Profile` keeps the fields only to decode old snapshots — so showing
    /// them meant a permanent "0 followers · 0 following".
    private var subtitle: String {
        "@\(profile.login)"
    }
}

private extension Int {
    /// "1.2K" rather than "1,284": the header is a glance, and the exact
    /// follower count is not why anyone opened this popover.
    var compactCount: String {
        formatted(.number.notation(.compactName))
    }
}

#Preview("Profile header") {
    VStack(spacing: 0) {
        ProfileHeaderView(profile: SampleData.profile) {}
        Divider()
        ProfileHeaderView(
            profile: Profile(
                login: "nameless-dev",
                avatarURL: nil,
                followers: 3,
                following: 0,
                url: URL(string: "https://gitlab.com/nameless-dev") ?? SampleData.profile.url
            )
        ) {}
    }
    .frame(width: PopoverController.contentWidth)
}
