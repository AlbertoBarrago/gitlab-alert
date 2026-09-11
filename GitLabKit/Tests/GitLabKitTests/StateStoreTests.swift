import Foundation
import Testing

@testable import GitLabKit

/// A throwaway directory, unique per test. Callers `defer` ``removeTemporaryDirectory``
/// so cleanup happens at a known point rather than whenever ARC gets around to it.
private func makeTemporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("GitLabKitStateStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Best-effort teardown: a leftover directory in `TMPDIR` must not fail a test
/// that already proved what it set out to prove.
private func removeTemporaryDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private func stateFileURL(in directory: URL) -> URL {
    directory.appendingPathComponent("state.json", isDirectory: false)
}

private func makeProfile() -> Profile {
    Profile(
        login: "albz",
        name: "Alberto",
        followers: 12,
        following: 3,
        publicRepoCount: 7,
        url: URL(string: "https://gitlab.com/albz")!
    )
}

private func makeSnapshot(fetchedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> DashboardSnapshot {
    DashboardSnapshot(
        fetchedAt: fetchedAt,
        profile: makeProfile(),
        repositories: [
            RepoSnapshot(
                nameWithOwner: "albz/gitlab-alert",
                stargazerCount: 42,
                forkCount: 5,
                checkState: .success,
                url: URL(string: "https://gitlab.com/albz/gitlab-alert")!
            )
        ],
        rateLimit: RateLimitStatus(remaining: 4_900, limit: 5_000, resetAt: Date(timeIntervalSince1970: 1_700_003_600))
    )
}

private func makeEvent(index: Int, at date: Date) -> ActivityEvent {
    ActivityEvent(
        id: "event-\(index)",
        kind: .star,
        occurredAt: date,
        repository: "albz/gitlab-alert",
        actors: [GLActor(login: "someone-\(index)")]
    )
}

@Suite("FileStateStore")
struct StateStoreTests {

    @Test("round-trips a fully populated state")
    func roundTrip() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = FileStateStore(fileURL: stateFileURL(in: directory))

        let seededAt = Date(timeIntervalSince1970: 1_699_000_000)
        var state = PersistedState()
        state.lastSnapshot = makeSnapshot()
        state.watermarks = [
            "albz/gitlab-alert": RepoWatermark(
                stargazerCount: 42,
                forkCount: 5,
                newestStarredAt: seededAt,
                newestForkedAt: nil,
                lastCheckState: .success,
                firstSeenAt: seededAt
            )
        ]
        state.activityLog = [makeEvent(index: 1, at: seededAt)]
        state.seenEventIDs = ["event-1"]
        state.hasBaseline = true

        try store.save(state)
        #expect(store.load() == state)
    }

    @Test("a missing file loads a fresh state without a baseline")
    func missingFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = FileStateStore(fileURL: stateFileURL(in: directory))

        let loaded = store.load()
        #expect(loaded == PersistedState())
        #expect(loaded.hasBaseline == false)
        #expect(loaded.version == PersistedState.currentVersion)
    }

    @Test("an empty file loads a fresh state")
    func emptyFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        try Data().write(to: stateFileURL(in: directory))
        let store = FileStateStore(fileURL: stateFileURL(in: directory))

        #expect(store.load() == PersistedState())
    }

    @Test("truncated JSON loads a fresh state")
    func truncatedJSON() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = FileStateStore(fileURL: stateFileURL(in: directory))
        try store.save({
            var state = PersistedState()
            state.lastSnapshot = makeSnapshot()
            state.hasBaseline = true
            return state
        }())

        let whole = try Data(contentsOf: stateFileURL(in: directory))
        try whole.prefix(whole.count / 2).write(to: stateFileURL(in: directory))

        let loaded = store.load()
        #expect(loaded.hasBaseline == false)
        #expect(loaded.lastSnapshot == nil)
    }

    @Test("a wrong-schema payload loads a fresh state")
    func wrongSchema() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        try Data(#"{"totally":"unrelated"}"#.utf8).write(to: stateFileURL(in: directory))
        let store = FileStateStore(fileURL: stateFileURL(in: directory))

        #expect(store.load() == PersistedState())
    }

    @Test("a future schema version loads a fresh state instead of misreading it")
    func futureVersion() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = FileStateStore(fileURL: stateFileURL(in: directory))

        var state = PersistedState()
        state.hasBaseline = true
        state.version = PersistedState.currentVersion + 1
        try store.save(state)

        let loaded = store.load()
        #expect(loaded.version == PersistedState.currentVersion)
        #expect(loaded.hasBaseline == false)
    }

    @Test("saving keeps only the 200 newest activity events")
    func activityLogCapping() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = FileStateStore(fileURL: stateFileURL(in: directory))

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var state = PersistedState()
        // Oldest first, so a store that merely truncates the array would keep
        // the wrong end and fail this test.
        state.activityLog = (0..<250).map { makeEvent(index: $0, at: base.addingTimeInterval(Double($0))) }
        state.hasBaseline = true
        try store.save(state)

        let loaded = store.load()
        #expect(loaded.activityLog.count == FileStateStore.maxActivityLogEntries)
        #expect(loaded.activityLog.first?.id == "event-249")
        #expect(loaded.activityLog.last?.id == "event-50")
        #expect(loaded.activityLog.contains { $0.id == "event-0" } == false)
    }

    @Test("seen event ids are capped, keeping the ones the log still shows")
    func seenEventIDCapping() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = FileStateStore(fileURL: stateFileURL(in: directory))

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var state = PersistedState()
        state.activityLog = (0..<10).map { makeEvent(index: $0, at: base.addingTimeInterval(Double($0))) }
        state.seenEventIDs = Set((0..<10).map { "event-\($0)" })
            .union((0..<FileStateStore.maxSeenEventIDs + 500).map { "stale-\($0)" })
        try store.save(state)

        let loaded = store.load()
        #expect(loaded.seenEventIDs.count == FileStateStore.maxSeenEventIDs)
        for event in loaded.activityLog {
            #expect(loaded.seenEventIDs.contains(event.id))
        }
    }

    @Test("collections below the caps are stored untouched")
    func noCappingBelowLimits() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var state = PersistedState()
        state.activityLog = (0..<5).map { makeEvent(index: $0, at: base.addingTimeInterval(-Double($0))) }
        state.seenEventIDs = ["event-0", "event-3"]

        let capped = FileStateStore.capped(state)
        #expect(capped.activityLog == state.activityLog)
        #expect(capped.seenEventIDs == state.seenEventIDs)
    }

    @Test("a failed encode leaves the previous file byte-identical")
    func failedEncodeLeavesPreviousFileIntact() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = FileStateStore(fileURL: stateFileURL(in: directory))

        var good = PersistedState()
        good.lastSnapshot = makeSnapshot()
        good.hasBaseline = true
        try store.save(good)
        let before = try Data(contentsOf: stateFileURL(in: directory))

        // A non-finite date encodes to a non-conforming float, which
        // JSONEncoder rejects: a realistic way to fail mid-save.
        var poisoned = PersistedState()
        poisoned.lastSnapshot = makeSnapshot(fetchedAt: Date(timeIntervalSinceReferenceDate: .infinity))
        poisoned.hasBaseline = true

        #expect(throws: StateStoreError.self) { try store.save(poisoned) }

        #expect(try Data(contentsOf: stateFileURL(in: directory)) == before)
        #expect(store.load() == good)
        // No temp file left behind.
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("the state file is owner-readable only and lives in a private directory")
    func filePermissions() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let nested = directory.appendingPathComponent("Support/GitLabAlert", isDirectory: true)
        let store = FileStateStore(fileURL: nested.appendingPathComponent("state.json", isDirectory: false))

        try store.save(PersistedState())

        let fileMode = try FileManager.default
            .attributesOfItem(atPath: nested.appendingPathComponent("state.json").path)[.posixPermissions] as? NSNumber
        #expect(fileMode?.uint16Value == 0o600)

        let directoryMode = try FileManager.default
            .attributesOfItem(atPath: nested.path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.uint16Value == 0o700)
    }

    @Test("concurrent saves leave a whole, decodable file")
    func concurrentSavesDoNotTearTheFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let url = stateFileURL(in: directory)
        let store = FileStateStore(fileURL: url)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    var state = PersistedState()
                    state.hasBaseline = true
                    state.watermarks = [
                        "albz/repo-\(index)": RepoWatermark(firstSeenAt: Date(timeIntervalSince1970: 1_700_000_000))
                    ]
                    // A save losing the race is fine; a torn file is not.
                    try? store.save(state)
                }
            }
        }

        let loaded = store.load()
        #expect(loaded.hasBaseline)
        #expect(loaded.watermarks.count == 1)
    }

    @Test("the default path is inside Application Support")
    func defaultPath() {
        let path = FileStateStore.defaultFileURL().path
        #expect(path.hasSuffix("/Application Support/GitLabAlert/state.json"))
    }
}
