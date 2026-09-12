import GitLabKit
import SwiftUI

/// Cadence, what the popover shows, and whether the app starts with the Mac.
@MainActor
struct GeneralSettingsView: View {
    let model: AppModel

    /// Presets rather than a text field: the scheduler clamps anything outside
    /// 30 s…15 min anyway, and a free-text seconds field invites values that
    /// silently do not take effect.
    private static let intervalPresets: [TimeInterval] = [30, 60, 120, 300, 600, 900]

    var body: some View {
        Form {
            Section("Polling") {
                Picker("Check GitLab every", selection: model.preferences.binding(\.basePollInterval)) {
                    ForEach(intervalChoices, id: \.self) { interval in
                        Text(Self.label(for: interval)).tag(interval)
                    }
                }
                .accessibilityLabel("Polling interval")

                SettingsFootnote(
                    "This is the idle cadence on AC power. The app polls every minute while the popover "
                    + "is open, backs off to 15 minutes on battery, and pauses while the Mac sleeps or the "
                    + "network is gone. One cycle costs 1 of 5000 API points an hour, so battery is the "
                    + "reason to go slow."
                )

                if let warning = model.rateLimitWarning {
                    SettingsAdvisory(level: .warning, message: warning)
                }
            }

            Section("Menu bar") {
                Toggle("Show the GitLab Alert icon in the menu bar", isOn: model.preferences.binding(\.statusItemVisible))
                SettingsFootnote(
                    "With the icon hidden the app keeps polling and still posts notifications, but there "
                    + "is no way left to open the popover. Launching GitLab Alert again from Applications "
                    + "opens the main window instead."
                )
            }

            Section("Popover") {
                Toggle("Show the profile header", isOn: model.preferences.binding(\.showProfileHeader))
                SettingsFootnote("Your avatar, name, followers and repository count at the top of the popover.")
            }

            Section("Sections") {
                List {
                    ForEach(model.preferences.sectionOrder) { section in
                        HStack(spacing: 6) {
                            Toggle(isOn: model.preferences.sectionVisibilityBinding(for: section)) {
                                Label(section.title, systemImage: section.symbolName)
                            }
                            .accessibilityLabel("Show \(section.title)")

                            Spacer(minLength: 0)

                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .onMove { source, destination in
                        model.preferences.moveSections(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(minHeight: 150)
                .accessibilityLabel("Popover sections, in order")
                .help("Drag a row to reorder the popover.")

                SettingsFootnote("Drag to reorder. Hiding every section is allowed. The popover then shows only the header.")
            }

            Section("Startup") {
                Toggle("Launch GitLab Alert at login", isOn: launchAtLogin)

                if let explanation = model.loginItemState.explanation {
                    // The toggle reflects `LoginItem.state`, not the stored
                    // intent, so a registration macOS refused shows up here
                    // instead of as a switch that flips itself back.
                    SettingsAdvisory(level: .warning, message: explanation)
                    Button("Open Login Items…") { model.openLoginItemSettings() }
                        .accessibilityHint("Opens System Settings, General, Login Items")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Approval and removal both happen outside the app, in System
            // Settings, so the state is re-read every time this pane appears.
            model.refreshLoginItemState()
        }
    }

    // MARK: - Polling

    /// The presets, plus whatever is currently stored if it is not one of them —
    /// otherwise a value carried over from another build would leave the picker
    /// showing nothing.
    private var intervalChoices: [TimeInterval] {
        let current = Preferences.clampPollInterval(model.preferences.basePollInterval)
        guard !Self.intervalPresets.contains(current) else { return Self.intervalPresets }
        return (Self.intervalPresets + [current]).sorted()
    }

    private static func label(for interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 {
            return "\(seconds) seconds"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        let minutePart = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        guard remainder > 0 else { return minutePart }
        return "\(minutePart) \(remainder) s"
    }

    // MARK: - Login item

    /// Reads the real `SMAppService` status and writes through the intent, so
    /// what the switch shows is what macOS is actually doing.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { model.loginItemState.isEnabled },
            set: { model.setLaunchAtLogin($0) }
        )
    }
}

#if DEBUG
#Preview("General") {
    GeneralSettingsView(model: SampleData.populatedModel)
        .frame(width: 560, height: 460)
}
#endif
