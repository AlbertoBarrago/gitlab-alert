import AppKit
import SwiftUI

/// Owns the `NSPopover` and the things AppKit does not give us for free once we
/// stop using `MenuBarExtra`: activation, Escape, animated resizing, and a
/// placement fallback for when the status item's window frame is not usable yet.
@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {

    private let popover = NSPopover()
    private var escapeMonitor: Any?
    private weak var anchor: NSView?
    private var detachedAnchorWindow: NSWindow?
    private var pendingContentHeight: CGFloat?
    private var resizeWorkItem: DispatchWorkItem?

    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onMaximumHeightChange: ((CGFloat) -> Void)?

    /// Starting size. Height grows with content, width stays put: a menu bar
    /// popover that changes width feels broken.
    static let contentWidth: CGFloat = 380
    static let initialHeight: CGFloat = 360
    private var maximumHeight: CGFloat = 600

    init<Content: View>(content: Content) {
        super.init()
        popover.contentSize = NSSize(width: Self.contentWidth, height: Self.initialHeight)
        // `.transient` and never `.semitransient`: the latter's "containing
        // window" is the menu bar, so it would never close on an outside click.
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: content)
    }

    var isShown: Bool { popover.isShown }

    func toggle(relativeTo view: NSView?) {
        if popover.isShown {
            close()
        } else {
            show(relativeTo: view)
        }
    }

    func show(relativeTo view: NSView?) {
        anchor = view
        detachedAnchorWindow = nil
        updateMaximumHeight(relativeTo: view)

        // An accessory app is not frontmost, so without this a search field or
        // any text input inside the popover cannot take keyboard focus.
        // `activate()` rather than the deprecated `activateIgnoringOtherApps`.
        NSApp.activate()

        if let view, isUsable(view) {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else {
            showDetached()
        }

        installEscapeMonitor()
        onOpen?()
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    /// Coalesces SwiftUI's intermediate layout passes into one resize. Without
    /// this, a first dashboard load can visibly step through several heights
    /// while independent views finish measuring.
    func setContentHeight(_ height: CGFloat) {
        let clamped = min(max(height, 160), maximumHeight)
        guard abs((pendingContentHeight ?? popover.contentSize.height) - clamped) > 0.5 else { return }
        pendingContentHeight = clamped
        resizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.applyPendingContentHeight() }
        resizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func applyPendingContentHeight() {
        guard let height = pendingContentHeight else { return }
        pendingContentHeight = nil
        resizeWorkItem = nil
        guard abs(popover.contentSize.height - height) > 0.5 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            popover.contentSize = NSSize(width: Self.contentWidth, height: height)
        }
    }

    private func updateMaximumHeight(relativeTo view: NSView?) {
        guard let screen = view?.window?.screen ?? NSScreen.main else { return }
        // `visibleFrame` already excludes the menu bar and Dock. Keep a small
        // breathing space so the popover never touches the screen edge.
        maximumHeight = max(200, floor(screen.visibleFrame.height - 12))
        onMaximumHeightChange?(maximumHeight)
    }

    /// The status item button's window frame is not trustworthy: it is empty
    /// before the item has been placed and stale while the item is hidden.
    /// Rather than refusing to open, fall back to a detached popover anchored
    /// near the top-right of the active screen, just below the menu bar.
    private func isUsable(_ view: NSView) -> Bool {
        guard let window = view.window else { return false }
        let frame = window.frame
        return frame.width > 1 && frame.height > 1
    }

    private func showDetached() {
        guard let screen = NSScreen.main else { return }
        let thickness = NSStatusBar.system.thickness
        let width = Self.contentWidth
        let rect = NSRect(
            x: screen.visibleFrame.maxX - width - 12,
            y: screen.visibleFrame.maxY - thickness - 4,
            width: width,
            height: 1
        )
        // A one-pixel-tall anchor view in a borderless window is the only way to
        // give NSPopover something to point at when the status item cannot.
        let host = NSWindow(
            contentRect: rect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        host.isOpaque = false
        host.backgroundColor = .clear
        host.level = .statusBar
        host.ignoresMouseEvents = true
        let anchorView = NSView(frame: NSRect(origin: .zero, size: rect.size))
        host.contentView = anchorView
        host.orderFront(nil)
        detachedAnchorWindow = host
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        removeEscapeMonitor()
        detachedAnchorWindow?.orderOut(nil)
        detachedAnchorWindow = nil
        onClose?()
    }

    // MARK: - Escape

    /// `.transient` gives Escape dismissal for free, but that is silently lost
    /// the moment any SwiftUI `.onKeyPress` exists in the content — even one
    /// returning `.ignored`. Owning the key ourselves makes it dependable.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // 53 == Escape
            self?.close()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        escapeMonitor = nil
    }
}
