import GitLabKit
import SwiftUI

/// First run: what the app does, where the token goes, what it is allowed to do.
///
/// The same flow as the Account pane, and literally the same controls
/// (``TokenEntryForm``, ``TokenScopeExplanation``) — onboarding that drifts from
/// Settings is how a token field ends up explaining two different sets of
/// scopes. Sized to be shown inside the popover's no-token state; the width is
/// left to the container.
@MainActor
struct OnboardingView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text("GitLab Alert keeps the merge requests waiting on you, your open issues and failed pipelines in the menu bar. It polls GitLab in the background and tells you only when something actually changed.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if case .rejected(let message) = model.authState {
                SettingsAdvisory(level: .warning, message: AccountSettingsView.settingsFacing(message))
            }

            if case .ready(let login) = model.authState {
                HStack(spacing: 8) {
                    AvatarView(login: login, avatarURL: model.profile?.avatarURL, size: 24)
                    Text("Signed in as \(login).")
                        .font(.callout)
                    Spacer(minLength: 0)
                }
                .accessibilityLabel("Signed in as \(login)")
            } else {
                Divider()
                TokenEntryForm(model: model)
                Divider()
                TokenScopeExplanation(model: model)
            }

            HStack {
                Spacer(minLength: 0)
                Button("Open Settings…") { model.openSettings() }
                    .buttonStyle(.link)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: MenuBarGlyph.templateImage())
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Welcome to GitLab Alert")
                    .font(.headline)
                Text("One token and you are set up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#if DEBUG
#Preview("Onboarding") {
    OnboardingView(model: SampleData.needsTokenModel)
        .frame(width: 380)
}
#endif
