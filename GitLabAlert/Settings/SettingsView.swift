import GitLabKit
import SwiftUI

/// Which pane of Settings is on screen. Window state, not a preference: the
/// window is rebuilt every time it opens, and "where I was last week" is not
/// something the user wants restored here.
enum SettingsTab: String, Hashable, CaseIterable, Identifiable {
    case general
    case account
    case notifications
    case repositories

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .account: return "Account"
        case .notifications: return "Notifications"
        case .repositories: return "Repositories"
        }
    }

    /// All four ship with macOS 14.
    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .account: return "person.crop.circle"
        case .notifications: return "bell.badge"
        case .repositories: return "shippingbox"
        }
    }
}

/// Root of the Settings window.
///
/// Hosted in a plain `NSWindow` by ``SettingsWindowController`` rather than in a
/// SwiftUI `Settings` scene, so the tab selection is owned here — there is no
/// scene graph around this view to own it.
@MainActor
struct SettingsView: View {
    let model: AppModel

    @State private var tab: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $tab) {
                ForEach(SettingsTab.allCases) { item in
                    Label(item.title, systemImage: item.symbolName)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("GitLab Alert")
            .frame(minWidth: 180, idealWidth: 200)
        } detail: {
            selectedPane
                .navigationTitle(tab.title)
                .frame(minWidth: 500)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            // Nothing else in Settings works without a token, so an app that
            // has none opens on the one tab that can fix that. `.verifying` is
            // not a problem state: a stored token is simply being checked.
            switch model.authState {
            case .needsToken, .rejected:
                tab = .account
            case .verifying, .ready:
                break
            }
        }
        .onChange(of: model.authState) { _, state in
            // A token restored at launch is verified asynchronously. If that
            // verification is rejected while Settings is already open, keep
            // the repair path visible instead of leaving the user on General.
            if case .rejected = state {
                tab = .account
            }
        }
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch tab {
        case .general:
            GeneralSettingsView(model: model)
        case .account:
            AccountSettingsView(model: model)
        case .notifications:
            NotificationSettingsView(model: model)
        case .repositories:
            RepositoryPickerView(model: model)
        }
    }
}

// MARK: - Shared bits

/// One line of explanatory text under a control. Settings says what a setting
/// does when the consequence is not guessable from the label.
struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An inline advisory: a state the user has to know about, with an optional
/// escape hatch. Used for a denied notification grant, a login item macOS
/// refused to register, and the poll cost of pinning a lot of repositories.
struct SettingsAdvisory: View {
    enum Level {
        case info
        case warning

        var symbolName: String {
            switch self {
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            }
        }

        var tint: Color {
            switch self {
            case .info: return .secondary
            case .warning: return .orange
            }
        }

        var accessibilityPrefix: String {
            switch self {
            case .info: return "Note"
            case .warning: return "Warning"
            }
        }
    }

    let level: Level
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: level.symbolName)
                .foregroundStyle(level.tint)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(level.accessibilityPrefix): \(message)")
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView(model: SampleData.populatedModel)
}

#Preview("Settings — no token") {
    SettingsView(model: SampleData.needsTokenModel)
}
#endif
