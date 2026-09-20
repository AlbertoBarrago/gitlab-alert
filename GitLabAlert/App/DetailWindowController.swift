import AppKit
import SwiftUI

/// The deep dive: a real resizable window, not a modal.
///
/// Modality from a menu bar utility is hostile — it takes the screen hostage for
/// something the user asked to *browse*. This window can be left open on a
/// second display and resized without adding a Dock icon.
@MainActor
final class DetailWindowController: NSWindowController, NSWindowDelegate {

    /// Called when the window closes so `AppDelegate` can release its controller.
    var onClose: (() -> Void)?

    convenience init<Content: View>(content: Content) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            // No `.fullSizeContentView`: this window has an ordinary title bar
            // with a title in it, so extending the content under the bar only
            // hid the sidebar's first row behind it.
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GitLab Alert"
        window.contentMinSize = NSSize(width: 700, height: 420)
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("GitLabAlertDetailWindow")
        window.center()
        self.init(window: window)
        window.delegate = self
    }

    func present() {
        guard let window else { return }
        if !window.isVisible {
            // Only center the first time; after that the autosaved frame wins,
            // so the window comes back where the user left it.
            if window.frameAutosaveName.isEmpty { window.center() }
        }
        NSApp.activate()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
