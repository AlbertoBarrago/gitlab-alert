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
/// A small cat mascot inspired by the Octocat: pointed ears, a curled tail,
/// and a compact silhouette that remains legible at menu bar size.
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
    /// scale. Transparent eyes keep the template correct on any background.
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

        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 8, y: 3.5))
        tail.curve(to: NSPoint(x: 1.6, y: 6.2),
                   controlPoint1: NSPoint(x: 3.4, y: 2),
                   controlPoint2: NSPoint(x: 3.5, y: 6.5))
        tail.lineWidth = 1.8
        tail.lineCapStyle = .round
        tail.stroke()

        let body = NSBezierPath(roundedRect: NSRect(x: 7, y: 1.2, width: 5.4, height: 7),
                                xRadius: 2, yRadius: 2)
        body.fill()

        let head = NSBezierPath()
        head.move(to: NSPoint(x: 4, y: 12.5))
        head.curve(to: NSPoint(x: 4.1, y: 16.4),
                   controlPoint1: NSPoint(x: 3.5, y: 14.3),
                   controlPoint2: NSPoint(x: 3.7, y: 15.5))
        head.line(to: NSPoint(x: 7.2, y: 15))
        head.curve(to: NSPoint(x: 12.4, y: 15),
                   controlPoint1: NSPoint(x: 8.9, y: 15.5),
                   controlPoint2: NSPoint(x: 10.7, y: 15.5))
        head.line(to: NSPoint(x: 15.5, y: 16.4))
        head.curve(to: NSPoint(x: 15.6, y: 12.5),
                   controlPoint1: NSPoint(x: 15.9, y: 15.5),
                   controlPoint2: NSPoint(x: 16.1, y: 14.3))
        head.curve(to: NSPoint(x: 9.8, y: 6.3),
                   controlPoint1: NSPoint(x: 17.6, y: 8.6),
                   controlPoint2: NSPoint(x: 14, y: 6.3))
        head.curve(to: NSPoint(x: 4, y: 12.5),
                   controlPoint1: NSPoint(x: 5.6, y: 6.3),
                   controlPoint2: NSPoint(x: 2, y: 8.6))
        head.close()
        head.fill()

        NSGraphicsContext.current?.compositingOperation = .clear
        for x in [6.8, 11.3] {
            NSBezierPath(ovalIn: NSRect(x: x, y: 9.1, width: 1.5, height: 2.4)).fill()
        }
        NSBezierPath(roundedRect: NSRect(x: 9.3, y: 0.6, width: 0.9, height: 2.4),
                     xRadius: 0.45, yRadius: 0.45).fill()
    }
}
