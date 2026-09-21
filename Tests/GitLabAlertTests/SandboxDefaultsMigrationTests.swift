import Foundation
import Testing
@testable import GitLabAlert

/// Leaving the App Sandbox moves where `UserDefaults` reads from, so an install
/// that predates 0.1.8 has its settings in a container the new build no longer
/// looks at. These assertions cover the one thing that must not go wrong: the
/// import runs once, takes what the user chose, and never overwrites a newer
/// value with an older one.
@Suite("SandboxDefaultsMigration")
struct SandboxDefaultsMigrationTests {

    /// A defaults suite of its own per test, so nothing touches the real app's
    /// preferences and the tests do not see each other's writes.
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "com.alBz.GitLabAlert.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func writeContainer(_ contents: [String: Any]) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).plist")
        try (contents as NSDictionary).write(to: url)
        return url
    }

    @Test("values from the container are imported")
    func importsContainerValues() throws {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let url = try writeContainer(["updates.automaticChecks": false, "poll.baseInterval": 900.0])

        let imported = SandboxDefaultsMigration.run(into: defaults, from: url)

        #expect(imported == 2)
        #expect(defaults.bool(forKey: "updates.automaticChecks") == false)
        #expect(defaults.double(forKey: "poll.baseInterval") == 900.0)
    }

    /// The reason values already outside the container win: the migration can
    /// run after the user has already changed something in the new build.
    @Test("a value set outside the container is left alone")
    func doesNotOverwriteExistingValues() throws {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "updates.automaticChecks")
        let url = try writeContainer(["updates.automaticChecks": false])

        let imported = SandboxDefaultsMigration.run(into: defaults, from: url)

        #expect(imported == 0)
        #expect(defaults.bool(forKey: "updates.automaticChecks") == true)
    }

    @Test("the import happens at most once")
    func runsOnlyOnce() throws {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let url = try writeContainer(["poll.baseInterval": 900.0])

        #expect(SandboxDefaultsMigration.run(into: defaults, from: url) == 1)
        // Someone resets the value by hand; a second launch must not bring the
        // container's value back.
        defaults.removeObject(forKey: "poll.baseInterval")
        #expect(SandboxDefaultsMigration.run(into: defaults, from: url) == 0)
        #expect(defaults.object(forKey: "poll.baseInterval") == nil)
    }

    @Test("a fresh install has nothing to import")
    func missingContainerIsNotAFailure() {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).plist")

        #expect(SandboxDefaultsMigration.run(into: defaults, from: url) == 0)
        #expect(defaults.bool(forKey: SandboxDefaultsMigration.markerKey))
    }

    @Test("the marker itself is never imported")
    func excludesTheMarker() throws {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let url = try writeContainer([SandboxDefaultsMigration.markerKey: true, "poll.baseInterval": 900.0])

        #expect(SandboxDefaultsMigration.run(into: defaults, from: url) == 1)
    }

    @Test("the container path is the sandboxed build's plist")
    func buildsTheContainerPath() {
        let url = SandboxDefaultsMigration.containerDefaultsURL(
            bundleIdentifier: "com.alBz.GitLabAlert",
            home: URL(filePath: "/Users/someone")
        )
        #expect(url.path(percentEncoded: false) == "/Users/someone/Library/Containers/com.alBz.GitLabAlert/Data/Library/Preferences/com.alBz.GitLabAlert.plist")
    }
}
