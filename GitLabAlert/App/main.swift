import AppKit

// A plain AppKit entry point rather than a SwiftUI `@main App`.
//
// The popover's content lives in an NSHostingView outside the scene graph,
// where `@Environment(\.openWindow)` and `SettingsLink` are undefined, and
// `MenuBarExtra` cannot render a glyph beside a count, be presented
// programmatically, or react to a Settings toggle. See docs/adr/0001.
//
// `.accessory` is set here rather than in `applicationDidFinishLaunching` so no
// Dock icon ever flashes during launch.
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
