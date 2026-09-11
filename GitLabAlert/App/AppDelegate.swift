import AppKit
import GitLabKit
import Observation
import SwiftUI
import UserNotifications
import os

/// Builds the dependency graph, owns the AppKit surfaces, and forwards the
/// system events the scheduler cannot see for itself.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: "com.alBz.GitLabAlert", category: "app")

    private var preferences: Preferences!
    private var model: AppModel!
    private var scheduler: PollScheduler!
    private var notifier: UserNotificationNotifier!
    private let notificationRouter = NotificationRouter()

    private var statusItem: StatusItemController!
    private var popover: PopoverController!
    private var detailWindow: DetailWindowController?
    private var settingsWindow: SettingsWindowController?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildGraph()
        buildInterface()
        buildMainMenu()
        observeSystemEvents()
        observePresentation()

        // Must be installed before this method returns, or a click that
        // launched the app is dropped on the floor.
        UNUserNotificationCenter.current().delegate = notificationRouter
        notificationRouter.onOpen = { [weak self] eventID, url in
            self?.model.handleNotificationOpen(eventID: eventID, url: url)
        }

        Task { [notifier, model] in
            await notifier?.refreshAuthorizationState()
            await model?.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { [scheduler] in await scheduler?.stop() }
    }

    /// Reopening from Finder brings the detail window forward while the app
    /// remains a menu bar accessory.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showDetailWindow() }
        return true
    }

    // MARK: - Wiring

    private func buildGraph() {
        preferences = Preferences()

        let tokenStore = KeychainTokenStore()
        let stateStore = FileStateStore()
        let client = GitLabClient(
            httpClient: URLSessionHTTPClient(),
            tokenStore: tokenStore,
            baseURL: preferences.gitLabBaseURL
        )

        model = AppModel(
            preferences: preferences,
            tokenStore: tokenStore,
            api: client
        )

        let model = model!
        notifier = UserNotificationNotifier(
            onAuthorizationChange: { value in
                await MainActor.run { model.setNotificationAuthorization(value) }
            }
        )

        let preferences = preferences!
        scheduler = PollScheduler(
            api: client,
            engine: ActivityDiffEngine(),
            store: stateStore,
            notifier: notifier,
            readConfiguration: {
                await MainActor.run {
                    PollScheduler.PollConfiguration(
                        baseInterval: preferences.basePollInterval,
                        scope: preferences.repositoryScope,
                        enabledNotificationKinds: preferences.enabledNotificationKinds
                    )
                }
            },
            onOutcome: { outcome in
                await MainActor.run { model.apply(outcome) }
            },
            onFailure: { error in
                await MainActor.run { model.fail(error) }
            }
        )

        model.attach(scheduler: scheduler)
        model.refreshLoginItemState()
    }

    private func buildInterface() {
        popover = PopoverController(content: PopoverRootView(model: model))
        popover.onOpen = { [weak self] in self?.model.popoverDidOpen() }
        popover.onClose = { [weak self] in self?.model.popoverDidClose() }
        popover.onMaximumHeightChange = { [weak self] height in
            self?.model.setPopoverMaximumHeight(height)
        }

        statusItem = StatusItemController()
        statusItem.isVisible = preferences.statusItemVisible
        statusItem.onToggle = { [weak self] in
            guard let self else { return }
            self.popover.toggle(relativeTo: self.statusItem.anchorView)
        }
        statusItem.onForceRefresh = { [weak self] in self?.model.refresh() }
        statusItem.onOpenDetail = { [weak self] in self?.showDetailWindow() }
        statusItem.onOpenSettings = { [weak self] in self?.showSettingsWindow() }

        model.openDetailWindow = { [weak self] in self?.showDetailWindow() }
        model.openSettingsWindow = { [weak self] in self?.showSettingsWindow() }
        model.closePopover = { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.popover.close()
        }
        // The popover's SwiftUI content is hosted outside the scene graph, so
        // this closure is its only route to the AppKit panel that owns its size.
        model.setPopoverHeight = { [weak self] height in
            self?.popover.setContentHeight(height)
        }
    }

    /// Hosting SwiftUI outside an App scene does not install standard editing
    /// commands. Keep the responder-chain shortcuts, especially paste for PATs,
    /// available while retaining the accessory activation policy.
    private func buildMainMenu() {
        let menu = NSMenu()
        let applicationItem = menu.addItem(withTitle: "GitLab Alert", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "GitLab Alert")
        applicationMenu.addItem(withTitle: "Settings…", action: #selector(showSettingsWindow), keyEquivalent: ",")
            .target = self
        applicationMenu.addItem(withTitle: "Quit GitLab Alert", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            .target = NSApp
        applicationItem.submenu = applicationMenu

        let fileItem = menu.addItem(withTitle: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = menu
    }

    // MARK: - Windows

    private func showDetailWindow() {
        if detailWindow == nil {
            let controller = DetailWindowController(content: DetailRootView(model: model))
            controller.onClose = { [weak self] in
                self?.detailWindow = nil
            }
            detailWindow = controller
        }
        detailWindow?.present()
    }

    @objc private func showSettingsWindow() {
        if settingsWindow == nil {
            let controller = SettingsWindowController(content: SettingsView(model: model))
            controller.onClose = { [weak self] in
                self?.settingsWindow = nil
                self?.statusItem.isVisible = self?.preferences.statusItemVisible ?? true
            }
            settingsWindow = controller
        }
        settingsWindow?.present()
    }

    // MARK: - System events

    /// Sleep, screen sleep and session switching are AppKit notifications, which
    /// is why the scheduler does not watch them itself.
    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        let suspend: [NSNotification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        let resume: [NSNotification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]

        for name in suspend {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { await self.scheduler.setSuspended(true) }
            }
        }
        for name in resume {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { await self.scheduler.setSuspended(false) }
            }
        }
    }

    /// Re-registering inside `onChange` is how `withObservationTracking` is made
    /// continuous: one registration fires exactly once.
    private func observePresentation() {
        withObservationTracking {
            _ = model.actionableCount
            _ = model.hasUnreadActivity
            _ = model.lastError
            _ = preferences.statusItemVisible
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyPresentation()
                self?.observePresentation()
            }
        }
        applyPresentation()
    }

    private func applyPresentation() {
        statusItem.update(
            StatusPresentation(
                actionableCount: model.actionableCount,
                hasUnread: model.hasUnreadActivity,
                hasError: model.lastError != nil && model.snapshot == nil
            )
        )
        statusItem.isVisible = preferences.statusItemVisible
    }
}
