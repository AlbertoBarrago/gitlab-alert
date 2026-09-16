import Foundation
import GitLabKit
import Security
import Testing
@testable import GitLabAlert

// Synchronous store protocols require a lock; every mutable value is accessed
// under that lock, including reads made from the scheduler actor.
private final class MemoryStore: StateStore, TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state = PersistedState()
    private var token: String? = "test-token"
    var rejectDeletion = false // Configured before the store is shared.
    var rejectWriting = false
    var rejectSaving = false

    func load() -> PersistedState { lock.withLock { state } }
    func save(_ value: PersistedState) throws {
        if rejectSaving { throw GitLabError.transport("Disk full") }
        lock.withLock { state = value }
    }
    func readToken() throws -> String? { lock.withLock { token } }
    func writeToken(_ value: String) throws {
        if rejectWriting {
            throw KeychainError.addFailed(status: errSecMissingEntitlement, message: "Missing entitlement")
        }
        lock.withLock { token = value }
    }
    func deleteToken() throws {
        if rejectDeletion { throw GitLabError.transport("Keychain locked") }
        lock.withLock { token = nil }
    }
}

private actor ControlledAPI: GitLabAPI {
    private(set) var dashboardCalls = 0
    private(set) var verificationCalls = 0
    private var dashboards: [CheckedContinuation<DashboardSnapshot, any Error>] = []
    private var verifications: [CheckedContinuation<Profile, any Error>] = []
    private var subsequentDashboard: DashboardSnapshot?

    func completeSubsequentDashboards(with value: DashboardSnapshot) { subsequentDashboard = value }

    func fetchDashboard(scope: RepositoryScope, options: DashboardRequestOptions) async throws -> DashboardSnapshot {
        dashboardCalls += 1
        if dashboardCalls > 1, let subsequentDashboard { return subsequentDashboard }
        return try await withCheckedThrowingContinuation { dashboards.append($0) }
    }
    func verifyToken() async throws -> Profile {
        verificationCalls += 1
        return try await withCheckedThrowingContinuation { verifications.append($0) }
    }
    func finishDashboard(_ snapshot: DashboardSnapshot) { dashboards.removeFirst().resume(returning: snapshot) }
    func finishVerification(_ result: Result<Profile, GitLabError>) {
        verifications.removeFirst().resume(with: result.mapError { $0 as any Error })
    }
}

private actor Recorder: Notifying {
    private(set) var outcomes: [PollOutcome] = []
    private(set) var failures: [GitLabError] = []
    private(set) var events: [ActivityEvent] = []
    func post(_ events: [ActivityEvent]) async { self.events += events }
    func record(_ outcome: PollOutcome) { outcomes.append(outcome) }
    func record(_ failure: GitLabError) { failures.append(failure) }
}

private func snapshot(login: String = "alice") -> DashboardSnapshot {
    DashboardSnapshot(fetchedAt: Date(), profile: Profile(login: login, url: URL(string: "https://gitlab.com/\(login)")!))
}

private struct WaitExpired: Error {}

@MainActor
private func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<2_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw WaitExpired()
}

private func scheduler(api: ControlledAPI, store: MemoryStore, recorder: Recorder) -> PollScheduler {
    PollScheduler(api: api, store: store, notifier: recorder,
                  readConfiguration: { .init() },
                  onOutcome: { await recorder.record($0) },
                  onFailure: { await recorder.record($0) })
}

@MainActor
private func model(api: ControlledAPI, store: MemoryStore) -> AppModel {
    let defaults = UserDefaults(suiteName: "GitLabAlertTests.\(UUID().uuidString)")!
    return AppModel(
        preferences: Preferences(defaults: defaults),
        tokenStore: store,
        api: api,
        apiFactory: { _ in api }
    )
}

@Suite("App lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct LifecycleTests {
    @Test func performancePreferencesPersistAndRejectUnsafeValues() {
        let suiteName = "GitLabAlertTests.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let preferences = Preferences(defaults: defaults)

        preferences.activePollInterval = 120
        preferences.batteryPollInterval = 600
        preferences.apiPageSize = 50
        preferences.pipelineConcurrency = 3

        let restored = Preferences(defaults: defaults)
        #expect(restored.activePollInterval == 120)
        #expect(restored.batteryPollInterval == 600)
        #expect(restored.dashboardRequestOptions == DashboardRequestOptions(pageSize: 50, pipelineConcurrency: 3))

        restored.apiPageSize = 26
        restored.pipelineConcurrency = 99
        #expect(restored.apiPageSize == DashboardRequestOptions.defaultPageSize)
        #expect(restored.pipelineConcurrency == 8)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    @Test func automaticPollJoinsAnExistingManualRefresh() async throws {
        let api = ControlledAPI(), store = MemoryStore(), recorder = Recorder()
        await api.completeSubsequentDashboards(with: snapshot())
        let poller = scheduler(api: api, store: store, recorder: recorder)
        let manual = Task { await poller.refreshNow() }
        try await eventually { await api.dashboardCalls == 1 }
        await poller.start()
        for _ in 0..<100 { await Task.yield() }
        await api.finishDashboard(snapshot())
        await manual.value
        await poller.stop()
        #expect(await api.dashboardCalls == 1)
        #expect(await recorder.outcomes.count == 1)
    }

    @Test func simultaneousRefreshesShareOneRequest() async throws {
        let api = ControlledAPI(), store = MemoryStore(), recorder = Recorder()
        let poller = scheduler(api: api, store: store, recorder: recorder)
        let first = Task { await poller.refreshNow() }
        try await eventually { await api.dashboardCalls == 1 }
        let second = Task { await poller.refreshNow() }
        // Let the second caller join while the transport remains suspended.
        for _ in 0..<50 { await Task.yield() }
        #expect(await api.dashboardCalls == 1)
        await api.finishDashboard(snapshot())
        await first.value
        await second.value
        #expect(await recorder.outcomes.count == 1)
    }

    @Test func stoppedCycleCannotRestoreClearedState() async throws {
        let api = ControlledAPI(), store = MemoryStore(), recorder = Recorder()
        let poller = scheduler(api: api, store: store, recorder: recorder)
        let request = Task { await poller.refreshNow() }
        try await eventually { await api.dashboardCalls == 1 }
        await poller.clearState()
        // The fake deliberately ignores cancellation, as a late network result can.
        await api.finishDashboard(snapshot())
        await request.value
        #expect(store.load().lastSnapshot == nil)
        #expect(await recorder.outcomes.isEmpty)
        #expect(await recorder.events.isEmpty)
    }

    @Test func failedPersistenceDoesNotPublishOrAdvanceBaseline() async throws {
        let api = ControlledAPI(), store = MemoryStore(), recorder = Recorder()
        store.rejectSaving = true
        let poller = scheduler(api: api, store: store, recorder: recorder)
        let request = Task { await poller.refreshNow() }
        try await eventually { await api.dashboardCalls == 1 }
        await api.finishDashboard(snapshot())
        await request.value
        #expect(await recorder.outcomes.isEmpty)
        #expect(await recorder.failures.count == 1)
        #expect(await poller.restoredOutcome == nil)
    }

    @Test func replacingAccountClearsHistoryBeforeVerifying() async throws {
        let api = ControlledAPI(), store = MemoryStore(), recorder = Recorder()
        let event = ActivityEvent(id: "old", kind: .star, occurredAt: Date(), repository: "alice/repo")
        try store.save(PersistedState(lastSnapshot: snapshot(), activityLog: [event], hasBaseline: true))
        let poller = scheduler(api: api, store: store, recorder: recorder)
        let app = model(api: api, store: store)
        app.attach(scheduler: poller)
        app.restore(try #require(await poller.restoredOutcome))
        app.saveToken("bob-token")
        try await eventually { await api.verificationCalls == 1 }
        #expect(app.activityLog.isEmpty)
        #expect(app.snapshot == nil)
        #expect(store.load().activityLog.isEmpty)
        #expect(!store.load().hasBaseline)
        await api.finishVerification(.success(snapshot(login: "bob").profile))
        try await eventually { await api.dashboardCalls == 1 }
        await api.finishDashboard(snapshot(login: "bob"))
        try await eventually { await recorder.outcomes.count == 1 }
        await poller.stop()
        #expect(store.load().lastSnapshot?.profile.login == "bob")
        #expect(store.load().activityLog.isEmpty)
        #expect(await recorder.events.isEmpty)
    }

    @Test func activityStaysUnreadUntilExplicitlyMarkedSeen() async throws {
        let api = ControlledAPI(), store = MemoryStore(), recorder = Recorder()
        let event = ActivityEvent(id: "unread", kind: .star, occurredAt: Date(), repository: "alice/repo")
        try store.save(PersistedState(lastSnapshot: snapshot(), activityLog: [event], hasBaseline: true))
        let poller = scheduler(api: api, store: store, recorder: recorder)
        let app = model(api: api, store: store)
        app.attach(scheduler: poller)
        app.restore(try #require(await poller.restoredOutcome))
        #expect(app.hasUnreadActivity)
        app.popoverDidOpen()
        try await Task.sleep(for: .milliseconds(10))
        #expect(!store.load().seenEventIDs.contains(event.id))
        #expect(app.hasUnreadActivity)

        app.markActivitySeen([event.id])
        try await eventually { store.load().seenEventIDs.contains(event.id) }
        #expect(!app.hasUnreadActivity)
        #expect(await poller.restoredOutcome?.freshEvents.isEmpty == true)
    }

    @Test func brokenRepositoryStaysUnreadUntilExplicitlyMarkedSeen() async throws {
        let api = ControlledAPI(), store = MemoryStore(), recorder = Recorder()
        let repository = RepoSnapshot(
            nameWithOwner: "alice/repo",
            checkState: .failure,
            url: URL(string: "https://gitlab.com/alice/repo")!
        )
        var storedSnapshot = snapshot()
        storedSnapshot.repositories = [repository]
        try store.save(PersistedState(lastSnapshot: storedSnapshot, hasBaseline: true))
        let poller = scheduler(api: api, store: store, recorder: recorder)
        let app = model(api: api, store: store)
        app.attach(scheduler: poller)
        app.restore(try #require(await poller.restoredOutcome))

        #expect(app.isRepositoryAlertUnread(repository))
        app.markRepositoryAlertsSeen([repository])
        try await eventually { store.load().seenEventIDs.contains(repository.repositoryAlertID) }
        #expect(!app.isRepositoryAlertUnread(repository))
    }

    @Test func missingTokenDoesNotRestoreAnotherAccountsSnapshot() async throws {
        let api = ControlledAPI(), store = MemoryStore(), recorder = Recorder()
        try store.deleteToken()
        try store.save(PersistedState(lastSnapshot: snapshot()))
        let poller = scheduler(api: api, store: store, recorder: recorder)
        let app = model(api: api, store: store)
        app.attach(scheduler: poller)
        await app.start()
        #expect(app.authState == .needsToken)
        #expect(app.snapshot == nil)
        #expect(await api.dashboardCalls == 0)
    }

    @Test func stopWakesSleepingLoop() async throws {
        let api = ControlledAPI(), store = MemoryStore(), recorder = Recorder()
        let poller = scheduler(api: api, store: store, recorder: recorder)
        await poller.start()
        try await eventually { await api.dashboardCalls == 1 }
        await api.finishDashboard(snapshot())
        try await eventually { await recorder.outcomes.count == 1 }
        await poller.stop()
        await poller.refreshNow()
        #expect(await api.dashboardCalls == 1)
    }

    @Test func signingOutDuringVerificationCannotSignBackIn() async throws {
        let api = ControlledAPI(), store = MemoryStore()
        let app = model(api: api, store: store)
        app.saveToken("replacement")
        try await eventually { await api.verificationCalls == 1 }
        app.signOut()
        await api.finishVerification(.success(snapshot().profile))
        try await eventually { (try? store.readToken()) == nil }
        #expect(app.authState == .needsToken)
        #expect(app.snapshot == nil)
        #expect(app.repositoryCatalog.isEmpty)
    }

    @Test func lateCatalogResponseIsDiscardedAfterSignOut() async throws {
        let api = ControlledAPI(), store = MemoryStore()
        let app = model(api: api, store: store)
        app.apply(PollOutcome(snapshot: snapshot(), freshEvents: [], activityLog: [], rateLimit: nil))
        app.loadRepositoryCatalog()
        try await eventually { await api.dashboardCalls == 1 }
        app.signOut()
        var old = snapshot()
        old.repositories = [RepoSnapshot(nameWithOwner: "alice/private", url: URL(string: "https://gitlab.com/alice/private")!)]
        await api.finishDashboard(old)
        try await eventually { (try? store.readToken()) == nil }
        #expect(app.repositoryCatalog.isEmpty)
        #expect(!app.isLoadingRepositoryCatalog)
    }

    @Test func transientVerificationFailureKeepsToken() async throws {
        let api = ControlledAPI(), store = MemoryStore()
        let app = model(api: api, store: store)
        app.saveToken("replacement")
        try await eventually { await api.verificationCalls == 1 }
        await api.finishVerification(.failure(.transport("Offline")))
        try await eventually { app.lastError != nil }
        #expect(try store.readToken() == "replacement")
    }

    @Test func keychainWriteFailureShowsItsRealCause() async throws {
        let api = ControlledAPI(), store = MemoryStore()
        store.rejectWriting = true
        let app = model(api: api, store: store)
        app.saveToken("replacement")
        try await eventually {
            if case .rejected = app.authState { return true }
            return false
        }
        #expect(app.authState == .rejected("Could not save the token in Keychain: Missing entitlement"))
        #expect(await api.verificationCalls == 0)
    }

    @Test func rejectedTokenIsRemoved() async throws {
        let api = ControlledAPI(), store = MemoryStore()
        let app = model(api: api, store: store)
        app.saveToken("invalid")
        try await eventually { await api.verificationCalls == 1 }
        await api.finishVerification(.failure(.badCredentials))
        try await eventually { app.lastError == .badCredentials }
        #expect(try store.readToken() == nil)
    }

    @Test func changingGitLabInstanceUsesANewClientBeforeAcceptingAToken() async throws {
        let oldAPI = ControlledAPI(), newAPI = ControlledAPI(), store = MemoryStore()
        let defaults = UserDefaults(suiteName: "GitLabAlertTests.\(UUID().uuidString)")!
        let app = AppModel(
            preferences: Preferences(defaults: defaults),
            tokenStore: store,
            api: oldAPI,
            apiFactory: { url in url.host == "gitlab.example.com" ? newAPI : oldAPI }
        )

        app.updateGitLabBaseURL("https://gitlab.example.com")
        try await eventually { !app.isChangingAccount }
        #expect(app.preferences.gitLabBaseURL.host == "gitlab.example.com")
        #expect(try store.readToken() == nil)

        app.saveToken("replacement")
        try await eventually { await newAPI.verificationCalls == 1 }
        #expect(await oldAPI.verificationCalls == 0)
        await newAPI.finishVerification(.success(snapshot(login: "bob").profile))
    }

    @Test func failedKeychainDeletionIsVisible() async throws {
        let api = ControlledAPI(), store = MemoryStore()
        store.rejectDeletion = true
        let app = model(api: api, store: store)
        app.signOut()
        try await eventually { app.lastError != nil }
        #expect(try store.readToken() != nil)
        if case .rejected = app.authState { } else { Issue.record("Expected a visible Keychain error") }
    }

    @Test(arguments: ActivityKind.allCases)
    func notificationSelectsItsExactEvent(kind: ActivityKind) {
        let app = model(api: ControlledAPI(), store: MemoryStore())
        let event = ActivityEvent(id: "event", kind: kind, occurredAt: Date(), repository: "alice/repo")
        app.apply(PollOutcome(snapshot: snapshot(), freshEvents: [event], activityLog: [event], rateLimit: nil))
        app.handleNotificationOpen(eventID: event.id, url: nil)
        #expect(app.pendingSelection == .init(section: .activity, itemID: event.id))
        let rows = DetailRowFactory.rows(for: .section(.activity), snapshot: app.snapshot,
                                        activityLog: app.activityLog, unreadEventIDs: app.unreadEventIDs)
        #expect(DetailRowFactory.resolveRowID(pendingItemID: event.id, rows: rows, activityLog: app.activityLog) == event.id)
    }
}
