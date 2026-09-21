import Foundation
import OSLog

/// One-shot import of the preferences left behind in the App Sandbox container.
///
/// Up to 0.1.7 the app was sandboxed, so `UserDefaults` wrote to
/// `~/Library/Containers/<bundle id>/Data/Library/Preferences/<bundle id>.plist`.
/// Outside the sandbox macOS reads `~/Library/Preferences` instead, so an
/// existing install would come back with every setting at its default: watched
/// projects gone, intervals reset, activity marked unread again.
///
/// Values already present outside the container win, so a second run can never
/// undo a change made after the migration. The Keychain needs nothing: its ACL
/// is bound to the designated requirement, which the stable signing identity
/// keeps constant.
enum SandboxDefaultsMigration {

    /// Set once the container has been read, so a user who deliberately resets a
    /// setting to its default does not get the old value imported again.
    static let markerKey = "migration.sandboxDefaultsImported"

    /// Keys that must not travel: they describe where the app ran, not what the
    /// user chose.
    private static let excluded: Set<String> = [markerKey]

    /// The plist the sandboxed build used to write.
    static func containerDefaultsURL(
        bundleIdentifier: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appending(path: "Library/Containers", directoryHint: .isDirectory)
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "Data/Library/Preferences", directoryHint: .isDirectory)
            .appending(path: "\(bundleIdentifier).plist", directoryHint: .notDirectory)
    }

    /// Imports the container's values and reports how many were taken.
    ///
    /// A missing container is the normal case for a fresh install and is not a
    /// failure: the marker is set either way, so the file is read at most once.
    @discardableResult
    static func run(
        into defaults: UserDefaults,
        from url: URL,
        log: Logger? = nil
    ) -> Int {
        guard !defaults.bool(forKey: markerKey) else { return 0 }
        defer { defaults.set(true, forKey: markerKey) }

        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            log?.info("sandbox defaults migration skipped: no container plist")
            return 0
        }

        guard let stored = NSDictionary(contentsOf: url) as? [String: Any] else {
            // An unreadable plist must not stop launch: the app carries on with
            // defaults, which is exactly what it would have done anyway.
            log?.error("sandbox defaults migration failed: container plist unreadable")
            return 0
        }

        var imported = 0
        for (key, value) in stored where !excluded.contains(key) {
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
            imported += 1
        }
        log?.info("sandbox defaults migration imported keys=\(imported, privacy: .public)")
        return imported
    }

    /// The call the app makes at launch, before anything reads a preference.
    static func runIfNeeded(log: Logger? = nil) {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        run(
            into: .standard,
            from: containerDefaultsURL(bundleIdentifier: bundleIdentifier),
            log: log
        )
    }
}
