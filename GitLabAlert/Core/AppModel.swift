import AppKit
import Foundation
import GitLabKit
import Observation
import os

/// The single view-facing state. Every view reads this and calls its intents;
/// no view ever constructs a client or touches the network.
@MainActor
@Observable
final class AppModel {

    /// Where authentication stands. `needsToken` is a first-class state, not an
    /// error: a fresh install is not broken, it is unconfigured.
    enum AuthState: Sendable, Hashable {
        case needsToken
        case verifying
        case ready(login: String)
        case rejected(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    /// What the detail window should have selected, set when a notification is
    /// clicked so the window opens on the thing the banner was about.
    struct DetailSelection: Sendable, Hashable {
        var section: DashboardSection
        var itemID: String?
    }

    // MARK: - Observed state

    private(set) var snapshot: DashboardSnapshot?
    private(set) var activityLog: [ActivityEvent] = []
    private(set) var unreadEventIDs: Set<String> = []
    private(set) var isLoading = false
    private(set) var lastError: GitLabError?
    private(set) var lastFetch: Date?
    private(set) var rateLimit: RateLimitStatus?
    private(set) var authState: AuthState = .needsToken
    private(set) var notificationAuthorization: NotificationAuthorization = .notRequested
    private(set) var loginItemState: LoginItem.State = .disabled
    /// Vertical space available below the status item on its current screen.
    /// `PopoverController` owns the AppKit calculation; SwiftUI uses it only to
    /// decide when the dashboard list genuinely needs to scroll.
    private(set) var popoverMaximumHeight: CGFloat = 600

    /// Consumed by the detail window when it opens.
    var pendingSelection: DetailSelection?

    /// Bumped whenever a refresh completes, so a view can animate on change
    /// without diffing the whole snapshot.
    private(set) var refreshTick = 0

    let preferences: Preferences

    // MARK: - Collaborators

    private let tokenStore: any TokenStore
    private let api: any GitLabAPI
    private let loginItem: LoginItem
    private let log = Logger(subsystem: "com.alBz.GitLabAlert", category: "model")
    private weak var scheduler: PollScheduler?
    private var accountTask: Task<Void, Never>?
    private var accountRevision = 0
    private var isChangingAccount = false
    private var catalogTask: Task<Void, Never>?


    /// Set by `AppDelegate`, which owns the windows. The model decides *when* a
    /// surface should open; AppKit decides *how*.
    var openDetailWindow: (() -> Void)?
    var openSettingsWindow: (() -> Void)?
    var closePopover: (() -> Void)?

    /// Set by `AppDelegate` so the popover's SwiftUI content can ask AppKit for
    /// the height it wants. The content is hosted in an `NSHostingView` outside
    /// the scene graph, so it has no other way to reach `PopoverController` —
    /// and if nothing wires this up, the popover simply keeps its fixed height.
    var setPopoverHeight: ((CGFloat) -> Void)?

    init(
        preferences: Preferences,
        tokenStore: any TokenStore,
        api: any GitLabAPI,
        loginItem: LoginItem = LoginItem()
    ) {
        self.preferences = preferences
        self.tokenStore = tokenStore
        self.api = api
        self.loginItem = loginItem
        self.loginItemState = loginItem.state
        self.authState = Self.initialAuthState(tokenStore: tokenStore)
    }

    /// Wired after construction because the scheduler's callbacks point back at
    /// this object.
    func attach(scheduler: PollScheduler) {
        self.scheduler = scheduler
    }

    private static func initialAuthState(tokenStore: any TokenStore) -> AuthState {
        do {
            guard let token = try tokenStore.readToken(), !token.isEmpty else { return .needsToken }
            return .verifying
        } catch let error as KeychainError {
            return .rejected("Could not read the token from Keychain: \(error.message)")
        } catch {
            return .rejected("Could not read the token from Keychain: \(error.localizedDescription)")
        }
    }

    func start() async {
        guard !isChangingAccount, authState == .verifying else { return }
        let revision = accountRevision
        let restored = await scheduler?.restoredOutcome
        guard revision == accountRevision else { return }
        if let restored { restore(restored) }
        await scheduler?.start()
    }

    // MARK: - Derived state for the UI

    /// The number the status item badge shows: things actually waiting on the user.
    var actionableCount: Int { snapshot?.actionableCount ?? 0 }

    var hasUnreadActivity: Bool { !unreadEventIDs.isEmpty }

    var profile: Profile? { snapshot?.profile }

    var showProfileHeader: Bool { preferences.showProfileHeader }

    var sections: [DashboardSection] { preferences.orderedVisibleSections }

    var reviewRequested: [MergeRequestItem] { snapshot?.reviewRequested ?? [] }
    var authoredMergeRequests: [MergeRequestItem] { snapshot?.authoredMergeRequests ?? [] }
    var assignedIssues: [IssueItem] { snapshot?.assignedIssues ?? [] }
    var inboundIssues: [IssueItem] { snapshot?.inboundIssues ?? [] }
    var repositories: [RepoSnapshot] { snapshot?.repositories ?? [] }
    var brokenRepositories: [RepoSnapshot] { snapshot?.brokenRepositories ?? [] }

    func count(for section: DashboardSection) -> Int {
        switch section {
        case .reviewRequested: return reviewRequested.count
        case .authoredMergeRequests: return authoredMergeRequests.count
        case .assignedIssues: return assignedIssues.count
        case .inboundIssues: return inboundIssues.count
        case .repositories: return brokenRepositories.count
        case .activity: return unreadEventIDs.count
        }
    }

    /// True when the app has data on screen that is known to be stale — offline,
    /// or the last refresh failed. The UI shows the data with an honest marker
    /// rather than an empty screen.
    var isShowingStaleData: Bool { lastError != nil && snapshot != nil }

    /// Only worth showing when the budget is actually running low; otherwise it
    /// is noise.
    var rateLimitWarning: String? {
        guard let rateLimit, rateLimit.isRunningLow else { return nil }
        return "\(rateLimit.remaining) of \(rateLimit.limit) API calls left"
    }

    // MARK: - Intents

    func refresh() {
        guard !isChangingAccount, authState.isReady || authState == .verifying else { return }
        isLoading = true
        Task { [weak self] in
            guard let scheduler = self?.scheduler else {
                self?.isLoading = false
                return
            }
            await scheduler.refreshNow()
            self?.isLoading = false
        }
    }

    func popoverDidOpen() {
        markActivitySeen()
        Task { [weak self] in await self?.scheduler?.setPopoverOpen(true) }
    }

    func popoverDidClose() {
        Task { [weak self] in await self?.scheduler?.setPopoverOpen(false) }
    }

    /// Marks the activity the user has now seen, so a relaunch does not replay it.
    func markActivitySeen() {
        let ids = activityLog.map(\.id)
        unreadEventIDs.removeAll()
        Task { [weak self] in await self?.scheduler?.markEventsSeen(ids) }
    }

    /// Verifies and stores a pasted token. Returns nothing: the result lands in
    /// `authState`, which is what the UI is watching.
    func saveToken(_ raw: String) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        let previous = accountTask
        previous?.cancel()
        accountRevision += 1
        let revision = accountRevision
        isChangingAccount = true
        authState = .verifying
        clearAccountData()

        accountTask = Task { [weak self] in
            await previous?.value
            guard let self, revision == self.accountRevision else { return }
            await self.scheduler?.stop()
            guard revision == self.accountRevision else { return }
            await self.scheduler?.clearState()
            guard revision == self.accountRevision else { return }
            do {
                try self.tokenStore.writeToken(token)
                let profile = try await self.api.verifyToken()
                guard revision == self.accountRevision else { return }
                self.authState = .ready(login: profile.login)
                self.isChangingAccount = false
                await self.scheduler?.start()
            } catch {
                guard revision == self.accountRevision else { return }
                self.log.error("token verification failed: \(String(describing: error), privacy: .public)")
                if let keychainError = error as? KeychainError {
                    self.isChangingAccount = false
                    self.authState = .rejected(
                        "Could not save the token in Keychain: \(keychainError.message)"
                    )
                    return
                }
                let failure = (error as? GitLabError) ?? .transport(error.localizedDescription)
                // Only a definitive rejection invalidates credentials. Offline
                // and server failures must not delete a potentially valid token.
                if failure == .badCredentials {
                    do { try self.tokenStore.deleteToken() }
                    catch { self.lastError = .transport("Could not remove the rejected token from Keychain.") }
                }
                self.isChangingAccount = false
                self.authState = .rejected(failure.userMessage)
                if self.lastError == nil { self.lastError = failure }
            }
        }
    }

    func signOut() {
        let previous = accountTask
        previous?.cancel()
        accountRevision += 1
        let revision = accountRevision
        isChangingAccount = true
        authState = .needsToken
        clearAccountData()
        accountTask = Task { [weak self] in
            await previous?.value
            guard let self, revision == self.accountRevision else { return }
            await self.scheduler?.stop()
            guard revision == self.accountRevision else { return }
            await self.scheduler?.clearState()
            guard revision == self.accountRevision else { return }
            do {
                try self.tokenStore.deleteToken()
            } catch {
                let message = "Could not remove the token from Keychain. Try removing it again."
                self.lastError = .transport(message)
                self.authState = .rejected(message)
            }
            self.isChangingAccount = false
        }
    }

    private func clearAccountData() {
        catalogTask?.cancel()
        catalogTask = nil
        repositoryCatalog = []
        repositoryCatalogError = nil
        isLoadingRepositoryCatalog = false
        snapshot = nil
        activityLog = []
        unreadEventIDs = []
        pendingSelection = nil
        lastFetch = nil
        lastError = nil
        rateLimit = nil
        isLoading = false
        refreshTick += 1
    }

    func updateScope(_ scope: RepositoryScope) {
        preferences.repositoryScope = scope
        let revision = accountRevision
        let previous = accountTask
        accountTask = Task { [weak self] in
            await previous?.value
            guard let self, revision == self.accountRevision,
                  self.authState.isReady, !self.isChangingAccount,
                  self.preferences.repositoryScope == scope else { return }
            await self.scheduler?.stop()
            guard revision == self.accountRevision, !self.isChangingAccount else { return }
            await self.scheduler?.resetBaseline()
            guard revision == self.accountRevision, !self.isChangingAccount else { return }
            await self.scheduler?.start()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemState = loginItem.setEnabled(enabled)
        preferences.launchAtLogin = loginItemState.isEnabled
    }

    func openLoginItemSettings() {
        loginItem.openSystemSettings()
    }

    func refreshLoginItemState() {
        loginItemState = loginItem.state
    }

    func openNotificationSettings() {
        // Deep link to the app's own notification pane.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        if let url { NSWorkspace.shared.open(url) }
    }

    /// Opens a URL only when it belongs to the configured GitLab instance.
    /// API-supplied URLs remain untrusted even for self-managed installations.
    func openOnGitLab(_ url: URL?) {
        guard let url else { return }
        guard url.scheme?.lowercased() == "https" else {
            log.error("refused to open a non-https URL")
            return
        }
        guard let host = url.host?.lowercased(),
              host == preferences.gitLabBaseURL.host?.lowercased() else {
            log.error("refused to open a URL outside the configured GitLab instance")
            return
        }
        NSWorkspace.shared.open(url)
        closePopover?()
    }

    func openDetail(section: DashboardSection, itemID: String? = nil) {
        pendingSelection = DetailSelection(section: section, itemID: itemID)
        closePopover?()
        openDetailWindow?()
    }

    func openSettings() {
        closePopover?()
        openSettingsWindow?()
    }

    /// Routes a notification click: find the event, open the detail window on
    /// the matching section, and fall back to the browser when there is nothing
    /// in-app to show.
    func handleNotificationOpen(eventID: String, url: URL?) {
        if let event = activityLog.first(where: { $0.id == eventID }) {
            openDetail(section: .activity, itemID: event.id)
            return
        }
        if url != nil {
            openOnGitLab(url)
        } else {
            openDetailWindow?()
        }
    }

    // MARK: - Inbound from the scheduler

    func apply(_ outcome: PollOutcome) {
        guard !isChangingAccount, authState.isReady || authState == .verifying else { return }
        snapshot = outcome.snapshot
        activityLog = outcome.activityLog
        rateLimit = outcome.rateLimit ?? rateLimit
        lastFetch = outcome.snapshot.fetchedAt
        lastError = nil
        isLoading = false
        refreshTick += 1

        unreadEventIDs.formUnion(outcome.freshEvents.map(\.id))
        unreadEventIDs.formIntersection(outcome.activityLog.map(\.id))

        if case .verifying = authState {
            authState = .ready(login: outcome.snapshot.profile.login)
        }
    }

    /// Restores the last persisted snapshot so the popover has real content
    /// before the first cycle of this launch finishes.
    func restore(_ outcome: PollOutcome) {
        guard !isChangingAccount, authState == .verifying, snapshot == nil else { return }
        snapshot = outcome.snapshot
        activityLog = outcome.activityLog
        unreadEventIDs = Set(outcome.freshEvents.map(\.id))
        rateLimit = outcome.rateLimit
        lastFetch = outcome.snapshot.fetchedAt
    }

    func fail(_ error: GitLabError) {
        guard !isChangingAccount, authState.isReady || authState == .verifying else { return }
        isLoading = false
        lastError = error
        if error == .badCredentials {
            authState = .rejected(error.userMessage)
        } else if error == .notAuthenticated {
            authState = .needsToken
        }
    }

    func setNotificationAuthorization(_ value: NotificationAuthorization) {
        notificationAuthorization = value
    }

    func setPopoverMaximumHeight(_ height: CGFloat) {
        popoverMaximumHeight = max(200, height)
    }

    // MARK: - Repository catalog (Settings)

    /// Every repository the account owns, regardless of the current scope.
    ///
    /// Deliberately separate from `snapshot`: the client applies
    /// `RepositoryScope.filter` before building a snapshot, so `repositories`
    /// can only ever contain what is *already* watched. The Settings repository
    /// picker has to show the ones the rule leaves out too — that is the whole
    /// point of a picker — so it asks for an unfiltered list on demand and the
    /// result is cached for the rest of the launch.
    private(set) var repositoryCatalog: [RepoSnapshot] = []
    private(set) var isLoadingRepositoryCatalog = false
    private(set) var repositoryCatalogError: GitLabError?

    /// A scope whose `filter` is the identity function: nothing private, forked
    /// or old is dropped, so what comes back is the whole candidate list.
    private static let catalogScope = RepositoryScope(
        includeOwned: true,
        includePrivate: true,
        includeForks: true,
        activeWithinDays: nil
    )

    /// Loads the unfiltered repository list for the Settings picker.
    ///
    /// One dashboard round trip plus one pipeline request per repository. The
    /// list is fully paginated and pipeline requests use the same bounded
    /// settings as the poll cycle. It does not touch the scheduler, watermarks
    /// or stored scope.
    func loadRepositoryCatalog(force: Bool = false) {
        guard authState.isReady else { return }
        guard !isLoadingRepositoryCatalog else { return }
        guard force || repositoryCatalog.isEmpty else { return }

        isLoadingRepositoryCatalog = true
        repositoryCatalogError = nil

        let revision = accountRevision
        catalogTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.api.fetchDashboard(
                    scope: Self.catalogScope,
                    options: self.preferences.dashboardRequestOptions
                )
                guard revision == self.accountRevision, !Task.isCancelled else { return }
                self.repositoryCatalog = snapshot.repositories
            } catch let error as GitLabError {
                guard revision == self.accountRevision, !Task.isCancelled else { return }
                self.repositoryCatalogError = error
            } catch {
                guard revision == self.accountRevision, !Task.isCancelled else { return }
                self.repositoryCatalogError = .transport(error.localizedDescription)
                self.log.error("repository catalog load failed: \(String(describing: error), privacy: .public)")
            }
            self.isLoadingRepositoryCatalog = false
        }
    }
}
