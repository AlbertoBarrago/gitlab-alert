import SwiftUI

/// The About panel's content.
///
/// Deliberately thin: the app's mark, what this is, who made it, and the two
/// links that matter. Everything that used to sit beside it in Settings —
/// project links, a license section, the issue tracker — was noise around
/// those four lines.
struct AboutView: View {

    let model: AppModel

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

    /// The update state, in the one place a user looks for a version number.
    ///
    /// "Could not check" is never rendered as "up to date": a failed check
    /// knows nothing, and saying otherwise would keep someone on a version with
    /// a fixed bug in it.
    @ViewBuilder
    var updateRow: some View {
        if let update = model.availableUpdate {
            Link(destination: update.releaseURL) {
                Label("Update to \(update.latest.description)", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            Button {
                Task { await model.checkForUpdates() }
            } label: {
                Label(updateStatusTitle, systemImage: updateStatusSymbol)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.isCheckingForUpdates)
        }
    }

    var updateStatusTitle: String {
        if model.isCheckingForUpdates { return "Checking for updates…" }
        if model.updateCheckFailed { return "Could not check — try again" }
        if model.releaseCheck != nil { return "Up to date" }
        return "Check for updates"
    }

    var updateStatusSymbol: String {
        if model.updateCheckFailed { return "exclamationmark.triangle" }
        if model.releaseCheck != nil { return "checkmark.circle" }
        return "arrow.clockwise"
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
