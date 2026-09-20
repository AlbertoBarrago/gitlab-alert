import AppKit
import SwiftUI

/// The About panel, in a window of our own.
///
/// Not `NSApplication.orderFrontStandardAboutPanel`: that one is an Info.plist
/// dump with no room for the two links this app actually wants to show. Not a
/// Settings pane either — About is not a setting, and burying it behind the
/// sidebar made it something the user had to go looking for.
///
/// It floats above the other windows and sizes itself to its content, because
/// it is a panel the user reads once and dismisses, not a workspace.
@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {

    /// Called when the panel closes so `AppDelegate` can release its controller.
    var onClose: (() -> Void)?

    convenience init<Content: View>(content: Content) {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = "About"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(hosting.view.fittingSize)
        self.init(window: window)
        window.delegate = self
    }

    func present() {
        window?.center()
        // An accessory app is not active when the status item menu is used, so
        // without this the panel would open behind whatever has focus.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
