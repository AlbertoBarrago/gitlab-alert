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

                Picker("While the popover is open", selection: model.preferences.binding(\.activePollInterval)) {
                    ForEach(intervalChoices, id: \.self) { interval in
                        Text(Self.label(for: interval)).tag(interval)
                    }
                }
                .accessibilityLabel("Active polling interval")

                Picker("On battery or Low Power Mode", selection: model.preferences.binding(\.batteryPollInterval)) {
                    ForEach(intervalChoices, id: \.self) { interval in
                        Text(Self.label(for: interval)).tag(interval)
                    }
                }
                .accessibilityLabel("Battery polling interval")

                SettingsFootnote(
                    "The app pauses while the Mac sleeps or the network is unavailable. GitLab rate limits "
                    + "can only slow these cadences down, never make them more frequent."
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

            Section("Updates") {
                Toggle("Check for new versions automatically", isOn: model.preferences.binding(\.automaticUpdateChecks))
                SettingsFootnote(
                    "Reads the signed release feed on GitHub every six hours and offers to install a "
                    + "newer version in place. It is the only request that leaves for a host other than "
                    + "your GitLab instance, it carries no token and no identifier, and with this off the "
                    + "app never makes it. Checking from the About panel still works."
                )
            }

            Section("Popover") {
                Toggle("Show the profile header", isOn: model.preferences.binding(\.showProfileHeader))
                SettingsFootnote("Your avatar and name at the top of the popover.")
            }

            Section("GitLab API") {
                Picker("Items per API page", selection: model.preferences.binding(\.apiPageSize)) {
                    Text("25, gentler").tag(25)
                    Text("50").tag(50)
                    Text("100, faster").tag(100)
                }
                .accessibilityLabel("GitLab API page size")

                Picker("Simultaneous pipeline checks", selection: model.preferences.binding(\.pipelineConcurrency)) {
                    ForEach(1...8, id: \.self) { value in
                        Text(value == 1 ? "1 request" : "\(value) requests").tag(value)
                    }
                }
                .accessibilityLabel("Maximum simultaneous pipeline checks")

                Toggle("Track pushes by other people", isOn: model.preferences.binding(\.trackPushEvents))
                    .accessibilityLabel("Track pushes by other people")

                SettingsFootnote(
                    "Smaller pages and lower concurrency reduce load on self-managed GitLab instances. "
                    + "All pages are still fetched, so no repositories or work items are omitted. "
                    + "Tracking pushes costs one extra request per watched repository on every refresh."
                )
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
