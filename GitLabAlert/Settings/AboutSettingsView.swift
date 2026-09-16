import SwiftUI

/// Project identity and support routes belong in Settings so the menu-bar app
/// has a discoverable place for them without adding a separate window.
struct AboutSettingsView: View {
    private static let repositoryURL = URL(string: "https://github.com/AlbertoBarrago/gitlab-alert")!
    private static let issuesURL = URL(string: "https://github.com/AlbertoBarrago/gitlab-alert/issues")!

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("GitLab Alert")
                        .font(.title2.weight(.semibold))
                    Text("A menu bar view of the GitLab work that needs your attention.")
                        .foregroundStyle(.secondary)
                    Text("Version \(version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section("Project") {
                Link("View the repository on GitHub", destination: Self.repositoryURL)
                Link("Report an issue", destination: Self.issuesURL)
            }

            Section("A tiny favor") {
                Link(destination: Self.repositoryURL) {
                    Label("Star GitLab Alert on GitHub", systemImage: "star")
                }
                SettingsFootnote("GitLab Alert is yours for free. If it earns a place in your menu bar, leave it a star.")
            }

            Section("License") {
                LabeledContent("License", value: "MIT")
                SettingsFootnote("GitLab Alert is released under the MIT license.")
            }
        }
        .formStyle(.grouped)
    }
}

#Preview("About") {
    AboutSettingsView()
        .frame(width: 560, height: 460)
}
