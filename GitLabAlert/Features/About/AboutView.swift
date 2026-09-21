import SwiftUI

/// The About panel's content.
///
/// Deliberately thin: the app's mark, what this is, who made it, and the two
/// links that matter. Everything that used to sit beside it in Settings —
/// project links, a license section, the issue tracker — was noise around
/// those four lines.
struct AboutView: View {

    let model: AppModel
    let updateController: UpdateController

    private static let repositoryURL = URL(string: "https://github.com/AlbertoBarrago/gitlab-alert")!
    private static let authorURL = URL(string: "https://github.com/AlbertoBarrago")!
    private static let coffeeURL = URL(string: "https://buymeacoffee.com/albz")!

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)

                VStack(spacing: 3) {
                    Text("GitLab Alert")
                        .font(.title2.weight(.semibold))
                    Text("Version \(version) · MIT (modified)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Link("Created by Alberto Barrago", destination: Self.authorURL)
                    .font(.callout)
            }
            .padding(.bottom, 22)

            VStack(spacing: 8) {
                updateRow
                AboutLink(title: "Star it on GitHub", systemImage: "star", destination: Self.repositoryURL)
                AboutLink(title: "Buy me a coffee", systemImage: "cup.and.saucer", destination: Self.coffeeURL)
            }
        }
        .padding(24)
        .frame(width: 300)
    }
}

// MARK: - Updates

private extension AboutView {

    /// One command, not a status line: Sparkle runs the check and reports the
    /// outcome itself, including "you're up to date", so mirroring its state
    /// here would be a second, slower copy of the same answer.
    var updateRow: some View {
        Button {
            updateController.checkForUpdates()
        } label: {
            Label("Check for Updates…", systemImage: "arrow.down.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!updateController.canCheckForUpdates)
    }
}

/// One full-width link row, so the two calls to action carry the same weight.
private struct AboutLink: View {
    let title: String
    let systemImage: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}
