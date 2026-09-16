import Foundation
import GitLabKit
import Network
import os

/// The clock the scheduler runs on, injected so cadence and backoff can be
/// tested without real time passing.
protocol PollClock: Sendable {
    func now() -> Date
    func sleep(for seconds: TimeInterval) async throws
}

struct SystemPollClock: PollClock {
    func now() -> Date { Date() }
    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// One completed poll cycle, handed to whoever is rendering.
struct PollOutcome: Sendable {
    var snapshot: DashboardSnapshot
    /// Events detected this cycle that the user has not seen before. Empty on a
    /// baseline run, by design.
    var freshEvents: [ActivityEvent]
    /// The whole capped activity log, newest first.
    var activityLog: [ActivityEvent]
    var rateLimit: RateLimitStatus?
}

/// Owns cadence, backoff, single-flight and power/network gating.
///
/// Deliberately does not import AppKit: sleep/wake and lock notifications are
/// AppKit concerns, so `AppDelegate` calls ``setSuspended(_:)`` and the
/// scheduler stays testable and platform-light.
actor PollScheduler {

    // Cadence bounds. `Preferences` clamps the user's chosen interval to these.
    static let minimumInterval: TimeInterval = 30
    static let maximumInterval: TimeInterval = 900

    /// Idle on AC power: the default the app ships with.
    static let defaultIdleInterval: TimeInterval = 300
    /// While the popover is open, or right after an explicit refresh.
    static let defaultActiveInterval: TimeInterval = 60
    /// On battery or in Low Power Mode. Deliberately lazy: a menu bar utility
    /// has no business costing battery life.
    static let defaultBatteryInterval: TimeInterval = 900

    private var api: any GitLabAPI
    private let engine: any ActivityDiffing
    private let store: any StateStore
    private let notifier: any Notifying
    private let clock: any PollClock
    private let log = Logger(subsystem: "com.alBz.GitLabAlert", category: "poll")

    /// Read on every cycle rather than captured once, so changing the scope or
    /// the interval in Settings takes effect on the next tick.
    private let readConfiguration: @Sendable () async -> PollConfiguration

    /// Delivered on the main actor by the caller's closure.
    private let onOutcome: @Sendable (PollOutcome) async -> Void
    private let onFailure: @Sendable (GitLabError) async -> Void

    private var state: PersistedState
    private var runLoop: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var sleepContinuation: CheckedContinuation<Void, Never>?
    private var generation = 0
    private var stopped = false
    private var suspended = false
    private var networkAvailable = true
    private var popoverOpen = false
    private var pathMonitor: NWPathMonitor?

    /// Snapshot of everything the scheduler needs from `Preferences`, read fresh
    /// each cycle. A plain value so it can cross the actor boundary.
    struct PollConfiguration: Sendable {
        var baseInterval: TimeInterval
        var activeInterval: TimeInterval
        var batteryInterval: TimeInterval
        var scope: RepositoryScope
        var enabledNotificationKinds: Set<ActivityKind>
        var requestOptions: DashboardRequestOptions

        init(
            baseInterval: TimeInterval = PollScheduler.defaultIdleInterval,
            activeInterval: TimeInterval = PollScheduler.defaultActiveInterval,
            batteryInterval: TimeInterval = PollScheduler.defaultBatteryInterval,
            scope: RepositoryScope = .default,
            enabledNotificationKinds: Set<ActivityKind> = Set(ActivityKind.allCases),
            requestOptions: DashboardRequestOptions = DashboardRequestOptions()
        ) {
            self.baseInterval = baseInterval
            self.activeInterval = activeInterval
            self.batteryInterval = batteryInterval
            self.scope = scope
            self.enabledNotificationKinds = enabledNotificationKinds
            self.requestOptions = requestOptions
        }
    }

    init(
        api: any GitLabAPI,
        engine: any ActivityDiffing = ActivityDiffEngine(),
        store: any StateStore,
        notifier: any Notifying,
        clock: any PollClock = SystemPollClock(),
        readConfiguration: @escaping @Sendable () async -> PollConfiguration,
        onOutcome: @escaping @Sendable (PollOutcome) async -> Void,
        onFailure: @escaping @Sendable (GitLabError) async -> Void
    ) {
        self.api = api
        self.engine = engine
        self.store = store
        self.notifier = notifier
        self.clock = clock
        self.readConfiguration = readConfiguration
        self.onOutcome = onOutcome
        self.onFailure = onFailure
        self.state = store.load()
    }

    /// The persisted activity log, so the UI can render history before the first
    /// cycle of this launch completes.
    var restoredOutcome: PollOutcome? {
        guard let snapshot = state.lastSnapshot else { return nil }
        return PollOutcome(
            snapshot: snapshot,
            freshEvents: state.activityLog.filter { !state.seenEventIDs.contains($0.id) },
            activityLog: state.activityLog,
            rateLimit: snapshot.rateLimit
        )
    }

    func start() {
        guard runLoop == nil else { return }
        stopped = false
        startNetworkMonitor()
        runLoop = Task { [weak self] in
            await self?.loop()
        }
    }

    func stop() async {
        stopped = true
        generation += 1
        let loop = runLoop
        let cycle = inFlight
        loop?.cancel()
        cycle?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        wakeUp()
        // Drain callbacks before credentials can be changed. Cancellation alone
        // cannot guarantee that a transport has stopped returning results.
        await cycle?.value
        await loop?.value
        runLoop = nil
        inFlight = nil
    }

    /// Rebinds polling to another GitLab instance after the current cycle has
    /// been stopped and its persisted state cleared by the account owner.
    func replaceAPI(_ api: any GitLabAPI) {
        generation += 1
        inFlight?.cancel()
        self.api = api
    }

    /// Refresh now. Joins an in-flight cycle rather than starting a second one:
    /// two concurrent cycles would diff against the same watermarks and could
    /// report the same star twice.
    func refreshNow() async {
        await runCycle()
    }

    /// Called when the popover opens or closes. Opening tightens the cadence and
    /// triggers an immediate refresh; the user is looking at it.
    func setPopoverOpen(_ open: Bool) {
        popoverOpen = open
        if open { wakeUp() }
    }

    /// Sleep, screen lock and session switch come from AppKit, which this type
    /// does not import. `AppDelegate` forwards them here.
    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        log.debug("scheduler \(value ? "suspended" : "resumed", privacy: .public)")
        if !value { wakeUp() }
    }

    /// Forget the baseline so the next cycle re-seeds silently. Used after the
    /// token changes or the repository scope widens, so the user is not flooded
    /// with notifications about history.
    func resetBaseline() {
        generation += 1
        inFlight?.cancel()
        state.hasBaseline = false
        state.watermarks = [:]
        persist()
    }

    /// Clear everything derived. Called on sign-out; the token itself is the
    /// Keychain's business, not ours.
    func clearState() {
        generation += 1
        inFlight?.cancel()
        state = PersistedState()
        persist()
    }

    func markEventsSeen(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        state.seenEventIDs.formUnion(ids)
        persist()
    }

    // MARK: - The loop

    private func loop() async {
        while !Task.isCancelled {
            if !suspended && networkAvailable {
                await runCycle()
            }
            guard !Task.isCancelled else { return }
            let interval = await nextInterval()
            log.debug("next poll in \(Int(interval), privacy: .public)s")
            guard !Task.isCancelled else { return }
            await nap(interval)
        }
    }

    private func nextInterval() async -> TimeInterval {
        let configuration = await readConfiguration()

        var desired: TimeInterval
        if popoverOpen {
            desired = configuration.activeInterval
        } else if isOnBattery() {
            desired = max(configuration.baseInterval, configuration.batteryInterval)
        } else {
            desired = configuration.baseInterval
        }
        desired = min(max(desired, PollScheduler.minimumInterval), PollScheduler.maximumInterval)

        // The rate limiter has the last word: it knows about Retry-After, a
        // pending reset time, and a budget running low.
        if let tracker = (api as? GitLabClient)?.rateLimits {
            return await tracker.recommendedInterval(desired: desired, now: clock.now())
        }
        return desired
    }

    private func runCycle() async {
        guard !stopped, !suspended, networkAvailable, !Task.isCancelled else { return }
        if let inFlight {
            await inFlight.value
            return
        }
        let revision = generation
        let task = Task { await self.performCycle(generation: revision) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func performCycle(generation revision: Int) async {
        let configuration = await readConfiguration()
        let now = clock.now()
        let started = DispatchTime.now().uptimeNanoseconds
        guard revision == generation, !Task.isCancelled else { return }

        log.info("poll started baseline=\(self.state.hasBaseline, privacy: .public) watchedWatermarks=\(self.state.watermarks.count, privacy: .public)")

        do {
            let snapshot = try await api.fetchDashboard(
                scope: configuration.scope,
                options: configuration.requestOptions
            )

            guard revision == generation, !Task.isCancelled else { return }
            if let previous = state.lastSnapshot,
               previous.profile.login != snapshot.profile.login {
                state = PersistedState()
            }

            guard revision == generation, !Task.isCancelled else { return }
            let result = engine.diff(
                DiffInput(
                    previousSnapshot: state.lastSnapshot,
                    currentSnapshot: snapshot,
                    watermarks: state.watermarks,
                    mode: state.hasBaseline ? .compare : .baselineOnly,
                    now: now
                )
            )

            let existingIDs = Set(state.activityLog.map(\.id))
            let fresh = result.events.filter {
                !state.seenEventIDs.contains($0.id) && !existingIDs.contains($0.id)
            }

            // One write for events and watermarks together. A torn write here is
            // exactly the duplicate-notification bug — see ADR 0007.
            var nextState = state
            nextState.watermarks = result.watermarks
            nextState.lastSnapshot = snapshot
            nextState.hasBaseline = true
            nextState.activityLog = Array((fresh + state.activityLog)
                .prefix(FileStateStore.maxActivityLogEntries))
            // Do not announce an event that cannot be remembered on restart.
            try store.save(nextState)
            state = nextState

            let notifiable = fresh.filter { configuration.enabledNotificationKinds.contains($0.kind) }
            if !notifiable.isEmpty {
                await notifier.post(notifiable)
            }

            guard revision == generation, !Task.isCancelled else { return }
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            log.info("poll completed durationMs=\(elapsed, privacy: .public) repositories=\(snapshot.repositories.count, privacy: .public) freshEvents=\(fresh.count, privacy: .public) notified=\(notifiable.count, privacy: .public)")
            await onOutcome(
                PollOutcome(
                    snapshot: snapshot,
                    freshEvents: fresh,
                    activityLog: state.activityLog,
                    rateLimit: snapshot.rateLimit
                )
            )
        } catch let error as GitLabError {
            guard revision == generation, !Task.isCancelled else { return }
            log.error("poll failed: \(error.userMessage, privacy: .public)")
            await onFailure(error)
        } catch is CancellationError {
            // Shutting down: not a failure, and not the user's problem.
        } catch {
            guard revision == generation, !Task.isCancelled else { return }
            log.error("poll failed unexpectedly: \(String(describing: error), privacy: .public)")
            await onFailure(.transport(error.localizedDescription))
        }
    }

    private func persist() {
        do {
            try store.save(state)
        } catch {
            // Losing the state file means the next launch re-seeds silently,
            // which is the safe direction. Still worth saying out loud.
            log.error("could not persist state: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Waiting

    /// Sleeps, but interruptibly: `wakeUp()` cuts the nap short so an explicit
    /// refresh or a resume does not wait out a fifteen-minute interval.
    private func nap(_ seconds: TimeInterval) async {
        let timer = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: seconds)
                try Task.checkCancellation()
                await self?.wakeUp()
            } catch { }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if Task.isCancelled {
                continuation.resume()
            } else {
                sleepContinuation = continuation
            }
        }
        timer.cancel()
    }

    private func wakeUp() {
        guard let continuation = sleepContinuation else { return }
        sleepContinuation = nil
        continuation.resume()
    }

    // MARK: - Power and network

    private func isOnBattery() -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        return PowerSource.isOnBattery()
    }

    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.setNetworkAvailable(path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "com.alBz.GitLabAlert.network"))
        pathMonitor = monitor
    }

    private func setNetworkAvailable(_ available: Bool) {
        guard networkAvailable != available else { return }
        networkAvailable = available
        log.debug("network \(available ? "available" : "unavailable", privacy: .public)")
        // Coming back online should refresh promptly; going offline must not
        // spin retries, which is why the loop checks this before each cycle.
        if available { wakeUp() }
    }
}
