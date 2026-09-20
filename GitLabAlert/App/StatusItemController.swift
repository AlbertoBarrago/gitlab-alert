import AppKit
import GitLabKit

/// Everything the status item needs to render, as one value so the controller
/// has no opinions about where the numbers came from.
struct StatusPresentation: Equatable {
    var actionableCount: Int
    var hasUnread: Bool
    var hasError: Bool

    static let empty = StatusPresentation(actionableCount: 0, hasUnread: false, hasError: false)

    /// What VoiceOver reads. Worth writing properly: for some users this is the
    /// only channel the status item has.
    var accessibilityLabel: String {
        if hasError { return "GitLab Alert, not connected" }
        switch actionableCount {
        case 0: return hasUnread ? "GitLab Alert, new activity" : "GitLab Alert, nothing waiting"
        case 1: return "GitLab Alert, 1 item needs attention"
        default: return "GitLab Alert, \(actionableCount) items need attention"
        }
    }
}

/// Owns the `NSStatusItem`: the glyph, the count badge, and the click handling.
@MainActor
final class StatusItemController {

    /// Left click, or right/control click, or option-click — the three gestures
    /// `MenuBarExtra` cannot tell apart.
    var onToggle: (() -> Void)?
    var onForceRefresh: (() -> Void)?
    var onOpenDetail: (() -> Void)?
    var onOpenAbout: (() -> Void)?
    var onOpenRelease: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let statusItem: NSStatusItem
    private var presentation: StatusPresentation = .empty
    /// Set when a newer release exists, which adds one item to the menu.
    var availableUpdateVersion: String?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Gives the user free ⌘-drag reordering that survives relaunch.
        statusItem.autosaveName = "GitLabAlertStatusItem"
        configureButton()
        render()
    }

    var isVisible: Bool {
        get { statusItem.isVisible }
        set { statusItem.isVisible = newValue }
    }

    /// The button the popover anchors to.
    var anchorView: NSView? { statusItem.button }

    func update(_ new: StatusPresentation) {
        guard new != presentation else { return }
        presentation = new
        render()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        // Without this the action only fires on mouse-up for left clicks and we
        // never see the right-click at all.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
    }

    private func render() {
        guard let button = statusItem.button else { return }

        button.image = presentation.hasUnread
            ? MenuBarGlyph.imageWithUnreadDot()
            : MenuBarGlyph.templateImage()

        if presentation.hasError {
            button.attributedTitle = attributedBadge("!", dimmed: true)
        } else if presentation.actionableCount > 0 {
            button.attributedTitle = attributedBadge("\(presentation.actionableCount)", dimmed: false)
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }

        button.setAccessibilityLabel(presentation.accessibilityLabel)
        button.toolTip = presentation.accessibilityLabel
    }

    /// Monospaced digits matter more than they sound: with proportional figures
    /// the item's width changes as the count goes 9 → 10 and everything to the
    /// left of it in the menu bar shifts.
    private func attributedBadge(_ text: String, dimmed: Bool) -> NSAttributedString {
        let size = NSFont.systemFontSize(for: .small)
        return NSAttributedString(
            string: " \(text)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
                .foregroundColor: dimmed ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            ]
        )
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else {
            onToggle?()
            return
        }

        let isSecondary = event.type == .rightMouseUp
            || event.modifierFlags.contains(.control)

        if isSecondary {
            showMenu()
        } else if event.modifierFlags.contains(.option) {
            onForceRefresh?()
        } else {
            onToggle?()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "Refresh Now", action: #selector(menuRefresh), keyEquivalent: "r")
            .target = self
        // "Open GitLab Alert" read as "launch the app", which is already
        // running: the window is what the user is actually asking for.
        menu.addItem(withTitle: "Open Dashboard", action: #selector(menuOpenDetail), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "About", action: #selector(menuOpenAbout), keyEquivalent: "")
            .target = self
        if let availableUpdateVersion {
            menu.addItem(withTitle: "Update to \(availableUpdateVersion)…", action: #selector(menuOpenRelease), keyEquivalent: "")
                .target = self
        }
        menu.addItem(withTitle: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit GitLab Alert", action: #selector(menuQuit), keyEquivalent: "q")
            .target = self

        // Attaching the menu for one click and clearing it immediately keeps the
        // left-click action working; a permanently assigned menu would swallow it.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuRefresh() { onForceRefresh?() }
    @objc private func menuOpenDetail() { onOpenDetail?() }
    @objc private func menuOpenAbout() { onOpenAbout?() }
    @objc private func menuOpenRelease() { onOpenRelease?() }
    @objc private func menuOpenSettings() { onOpenSettings?() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}
