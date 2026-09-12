import GitLabKit
import SwiftUI

/// One switch per kind of event, plus an honest account of the system grant.
///
/// When macOS has denied the app, the switches are replaced rather than
/// disabled: a toggle that cannot produce a banner is worse than no toggle.
@MainActor
struct NotificationSettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            switch model.notificationAuthorization {
            case .denied:
                Section("Notifications") {
                    SettingsAdvisory(
                        level: .warning,
                        message: "macOS is blocking notifications from GitLab Alert, so none of these events can reach you."
                    )
                    Button("Open Notification Settings…") { model.openNotificationSettings() }
                        .accessibilityHint("Opens System Settings, Notifications")
                    SettingsFootnote(
                        "Allow notifications for GitLab Alert there and the per-event switches come back here. "
                        + "The menu bar count and the popover keep working either way."
                    )
                }

            case .notRequested, .granted:
                Section("Notify me about") {
                    ForEach(ActivityKind.allCases, id: \.self) { kind in
                        Toggle(isOn: model.preferences.notificationBinding(for: kind)) {
                            Label(Self.title(for: kind), systemImage: Self.symbolName(for: kind))
                        }
                        .accessibilityLabel(Self.title(for: kind))
                    }
                }

                Section("Permission") {
                    statusRow
                    SettingsFootnote(
                        "macOS asks for permission the first time there is actually something to tell you, "
                        + "not at launch, so a quiet first hour never produces a prompt."
                    )
                    if model.notificationAuthorization == .granted {
                        Button("Open Notification Settings…") { model.openNotificationSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.notificationAuthorization {
        case .granted:
            LabeledContent("Status") {
                Label("Allowed", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Notification permission: allowed")
        case .notRequested:
            LabeledContent("Status") {
                Label("Not asked yet", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Notification permission: not asked yet")
        case .denied:
            EmptyView()
        }
    }

    // MARK: - Human labels

    static func title(for kind: ActivityKind) -> String {
        switch kind {
        case .star: return "Stars on my repositories"
        case .fork: return "Forks of my repositories"
        case .reviewRequested: return "Review requests for me"
        case .checksFailed: return "CI starts failing"
        case .checksRecovered: return "CI goes back to green"
        case .inboundIssue: return "New issues on my repositories"
        case .inboundMergeRequest: return "New merge requests on my repositories"
        }
    }

    /// All of these ship with macOS 14.
    static func symbolName(for kind: ActivityKind) -> String {
        switch kind {
        case .star: return "star"
        case .fork: return "arrow.triangle.branch"
        case .reviewRequested: return "eyeglasses"
        case .checksFailed: return "xmark.octagon"
        case .checksRecovered: return "checkmark.seal"
        case .inboundIssue: return "tray.and.arrow.down"
        case .inboundMergeRequest: return "arrow.triangle.pull"
        }
    }
}

#if DEBUG
#Preview("Notifications") {
    NotificationSettingsView(model: SampleData.populatedModel)
        .frame(width: 560, height: 460)
}
#endif
