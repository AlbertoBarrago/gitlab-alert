import GitLabKit
import SwiftUI

/// The token pane: paste one, see who it resolved to, remove it.
///
/// The token itself is write-only from the UI's point of view. It goes to the
/// Keychain through ``AppModel/saveToken(_:)`` and is never read back for
/// display — there is deliberately no API to do so — so a stored token shows as
/// a fixed dot mask.
@MainActor
struct AccountSettingsView: View {
    let model: AppModel

    @State private var isConfirmingRemoval = false
    @State private var gitLabBaseURLDraft = ""
    @FocusState private var isEditingGitLabInstance: Bool

    var body: some View {
        Form {
            Section("GitLab instance") {
                TextField(
                    "https://gitlab.example.com",
                    text: $gitLabBaseURLDraft
                )
                    .textContentType(.URL)
                    .focused($isEditingGitLabInstance)
                    .onSubmit(applyGitLabInstanceChange)
                SettingsFootnote("Use the origin of your GitLab.com or self-managed instance. Changing it removes the stored token before you can save one for that instance.")
                if model.isChangingAccount {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Switching GitLab instance…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            switch model.authState {
            case .ready(let login):
                signedInSection(login: login)
            case .verifying:
                Section("Account") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking the token with GitLab…")
                            .foregroundStyle(.secondary)
                    }
                }
            case .needsToken:
                Section("Sign in") {
                    TokenEntryForm(model: model)
                }
                Section("What the token needs") {
                    TokenScopeExplanation(model: model)
                }
            case .rejected(let message):
                Section("Sign in") {
                    SettingsAdvisory(level: .warning, message: Self.settingsFacing(message))
                    TokenEntryForm(model: model)
                }
                Section("What the token needs") {
                    TokenScopeExplanation(model: model)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { gitLabBaseURLDraft = model.preferences.gitLabBaseURLString }
        .onChange(of: isEditingGitLabInstance) { wasEditing, isEditing in
            if wasEditing, !isEditing { applyGitLabInstanceChange() }
        }
        .onChange(of: model.isChangingAccount) { _, isChanging in
            if !isChanging { gitLabBaseURLDraft = model.preferences.gitLabBaseURLString }
        }
    }

    // MARK: - Signed in

    @ViewBuilder
    private func signedInSection(login: String) -> some View {
        Section("Account") {
            LabeledContent("Signed in as") {
                HStack(spacing: 8) {
                    AvatarView(login: login, avatarURL: model.profile?.avatarURL, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(login)
                            .fontWeight(.medium)
                        if let name = model.profile?.name, !name.isEmpty, name != login {
                            Text(name)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .accessibilityLabel("Signed in as \(login)")

            LabeledContent("Token") {
                Text(Self.dotMask)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Stored in the Keychain and hidden")
            }

            SettingsFootnote(
                "Stored in the Keychain for this Mac only, never synced and never shown again. "
                + "Replace it by removing it and pasting a new one."
            )

            Button("Remove token…", role: .destructive) {
                isConfirmingRemoval = true
            }
            .confirmationDialog(
                "Remove the GitLab token?",
                isPresented: $isConfirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove token", role: .destructive) { model.signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("GitLab Alert will stop polling and forget the cached dashboard and activity log. The token itself is not revoked. Do that on GitLab.")
            }
        }

        Section("Scopes") {
            TokenScopeExplanation(model: model)
        }
    }

    /// A fixed-length mask. Not derived from the real token: even its length is
    /// information the UI has no business carrying.
    private static let dotMask = String(repeating: "•", count: 24)

    private func applyGitLabInstanceChange() {
        model.updateGitLabBaseURL(gitLabBaseURLDraft)
        gitLabBaseURLDraft = model.preferences.gitLabBaseURLString
    }

    /// ``GitLabError/userMessage`` is written for the popover, where the fix is
    /// "check it in Settings". Inside Settings that sentence is a dead end, so
    /// the pointer is dropped and the diagnosis kept verbatim.
    static func settingsFacing(_ message: String) -> String {
        message
            .replacingOccurrences(of: " Check it in Settings.", with: "")
            .replacingOccurrences(of: " in Settings", with: "")
    }
}

// MARK: - Token entry

/// The paste-a-token control, shared by the Account pane and first-run
/// onboarding so the two can never drift apart.
@MainActor
struct TokenEntryForm: View {
    let model: AppModel

    /// The draft lives here only until it is handed to the model, and is
    /// cleared on the same runloop turn.
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var isVerifying: Bool { model.authState == .verifying }

    private var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isVerifying && !model.isChangingAccount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("glpat-…", text: $draft)
                .focused($isFocused)
                .onSubmit(save)
                .accessibilityLabel("GitLab personal access token")

            HStack(spacing: 8) {
                Button("Save token", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)

                if isVerifying {
                    ProgressView().controlSize(.small)
                    Text("Checking with GitLab…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { isFocused = true }
    }

    private func save() {
        guard canSave else { return }
        let token = draft
        // Cleared before anything can re-render with it on screen.
        draft = ""
        model.saveToken(token)
    }
}

/// The scope explanation, stated inline because a fine-grained token is the one
/// part of setup the user cannot guess.
@MainActor
struct TokenScopeExplanation: View {
    let model: AppModel

    private var tokenPageURL: URL? {
        model.preferences.gitLabBaseURL.appending(path: "-/user_settings/personal_access_tokens")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A personal access token with the read_api scope is sufficient:")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                scopeRow("read_api", "your profile, merge requests, issues and projects")
            }

            Text("No write scope is requested, ever. GitLab Alert only reads. It cannot change a repository, comment, or merge anything.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.openOnGitLab(tokenPageURL)
            } label: {
                HStack(spacing: 4) {
                    Text("Create a token on GitLab")
                    Image(systemName: "arrow.up.forward.square")
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.link)
            .accessibilityHint("Opens the configured GitLab instance in your browser")
        }
    }

    private func scopeRow(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(name)
                .font(.callout)
                .fontWeight(.medium)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(detail)")
    }
}

#if DEBUG
#Preview("Account signed in") {
    AccountSettingsView(model: SampleData.populatedModel)
        .frame(width: 560, height: 460)
}

#Preview("Account no token") {
    AccountSettingsView(model: SampleData.needsTokenModel)
        .frame(width: 560, height: 460)
}

#Preview("Account rejected token") {
    AccountSettingsView(model: SampleData.rejectedModel)
        .frame(width: 560, height: 460)
}
#endif
