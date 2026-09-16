import AppKit
import SwiftUI

/// Settings in a plain `NSWindow`.
///
/// Not a SwiftUI `Settings` scene: there is no scene graph here, and the
/// `showSettingsWindow:` selector that used to drive one has already been
/// renamed once across macOS releases. Owning the window is duller and stable.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    var onClose: (() -> Void)?

    convenience init<Content: View>(content: Content) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GitLab Alert Settings"
        // The sidebar keeps the four areas visible at once; the detail pane
        // still needs enough width for the repository picker and its filters.
        window.contentMinSize = NSSize(width: 700, height: 500)
        window.toolbarStyle = .unifiedCompact
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("GitLabAlertSettingsWindow")
        window.center()
        self.init(window: window)
        window.delegate = self
    }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
