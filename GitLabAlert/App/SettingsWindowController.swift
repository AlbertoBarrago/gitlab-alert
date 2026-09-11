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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GitLab Alert Settings"
        // Resizable upward, but never smaller than the forms need: the
        // repository picker is unusable in a short window.
        window.contentMinSize = NSSize(width: 560, height: 460)
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
