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
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            // `.fullSizeContentView` is what lets SwiftUI split the toolbar
            // between the two columns. Without it the title bar is one strip as
            // wide as the window, so the sidebar toggle and the search field
            // share it and collapsing the sidebar slides the search across.
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
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
