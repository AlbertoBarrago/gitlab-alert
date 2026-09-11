import AppKit

/// The menu bar mark, drawn in code rather than loaded from an asset.
///
/// There is no asset catalog in this project: the app is assembled by
/// `bin/make-app.sh` from a plain `swift build`, and compiling a catalog would
/// mean depending on `actool`, which is Xcode machinery. Drawing the glyph
/// programmatically is the better trade anyway — it is exact at every size and
/// on every scale factor, and it needs no bundle lookup that could fail at
/// runtime.
///
/// A compact geometric tanuki mark inspired by GitLab's fox logo.
enum MenuBarGlyph {

    /// Point size the menu bar wants. `NSStatusItem` gives roughly 22pt of
    /// height and expects the artwork to sit inside about 18pt.
    static let size = NSSize(width: 18, height: 18)

    /// A template image: AppKit recolours it for light and dark menu bars and
    /// for the selected (highlighted) state, so we must never bake in a colour.
    static func templateImage() -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "GitLab Alert"
        return image
    }

    /// An image with the unread accent dot composited in.
    ///
    /// This one is deliberately **not** a template: `NSStatusBarButton` ignores
    /// `contentTintColor`, so the only way to get an accent-coloured dot into
    /// the menu bar is to draw it ourselves and opt out of templating. The
    /// consequence is that we have to pick the glyph colour by hand, which is
    /// what `foreground` resolves.
    static func imageWithUnreadDot() -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, color: foreground())

            // A small badge above the right ear, separated by a clear halo.
            let diameter = rect.width * 0.24
            let dot = NSRect(
                x: rect.maxX - diameter,
                y: rect.maxY - diameter,
                width: diameter,
                height: diameter
            )
            // Punch a hole first so the dot reads as separate from the mark
            // even when it lands on top of a stroke.
            let halo = dot.insetBy(dx: -1.2, dy: -1.2)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: halo).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "GitLab Alert, new activity"
        return image
    }

    /// The menu bar's own foreground colour, so the non-template variant still
    /// follows appearance changes.
    private static func foreground() -> NSColor {
        NSColor.labelColor
    }

    /// Coordinates use an 18-point canvas; AppKit rasterizes it at the display's
    /// scale. The silhouette remains legible in both monochrome appearances.
    private static func draw(in rect: NSRect, color: NSColor = .black) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = AffineTransform(
            scaleByX: rect.width / 18,
            byY: rect.height / 18
        )
        let placement = NSAffineTransform(transform: transform)
        placement.translateX(by: rect.minX, yBy: rect.minY)
        placement.concat()
        color.setFill()
        color.setStroke()

        // Ears and forehead, kept as one strong silhouette so it remains
        // recognizable at 18pt and works as an AppKit template image.
        let mark = NSBezierPath()
        mark.move(to: NSPoint(x: 2.2, y: 14.8))
        mark.line(to: NSPoint(x: 5.3, y: 4.0))
        mark.line(to: NSPoint(x: 8.0, y: 9.2))
        mark.line(to: NSPoint(x: 9.0, y: 2.0))
        mark.line(to: NSPoint(x: 10.0, y: 9.2))
        mark.line(to: NSPoint(x: 12.7, y: 4.0))
        mark.line(to: NSPoint(x: 15.8, y: 14.8))
        mark.line(to: NSPoint(x: 9.0, y: 16.7))
        mark.close()
        mark.fill()

        // Small cut-outs suggest the two cheek planes of the tanuki mark.
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: 5.7, y: 10.2, width: 1.7, height: 1.2)).fill()
        NSBezierPath(ovalIn: NSRect(x: 10.6, y: 10.2, width: 1.7, height: 1.2)).fill()
    }
}
