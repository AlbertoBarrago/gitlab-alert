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

    /// Height of the ink itself, inside ``size``.
    ///
    /// The mark is scaled to this and centred, rather than trusting the path's
    /// hand-written coordinates to be balanced: they were not — the silhouette
    /// ran from y 2.0 to 16.7, so it sat a third of a point high, which reads
    /// as "stuck to the top" in a 22pt menu bar. Changing this constant is the
    /// only thing needed to make the mark bigger or smaller.
    static let markHeight: CGFloat = 15.4

    /// How far below the canvas centre the ink sits, in points.
    ///
    /// Measured, not guessed: with the mark centred geometrically, a screenshot
    /// of the menu bar put its ink centre 1.1pt above the centre of the system
    /// icons beside it. `NSStatusItem` scales the artwork down into the bar —
    /// 16pt of ink measured 14pt on screen — so the nudge is stated in canvas
    /// points, 1.1 / 0.875, and ``markHeight`` leaves just enough room for it.
    static let opticalOffset: CGFloat = 1.26

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

            // The badge belongs to the status item, not to the mark, so it
            // stays pinned to the canvas corner: anchoring it to the silhouette
            // would push its halo outside the image as the mark grows.
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

    /// Where the ink lands inside `rect`: scaled to ``markHeight`` and centred
    /// on both axes. Exposed so the geometry can be asserted without
    /// rasterizing anything.
    static func markFrame(in rect: NSRect) -> NSRect {
        let bounds = markPath().bounds
        let scale = (markHeight / size.height) * (rect.height / bounds.height)
        let width = bounds.width * scale
        let height = bounds.height * scale
        let nudge = opticalOffset * (rect.height / size.height)
        return NSRect(
            x: rect.minX + (rect.width - width) / 2,
            y: rect.minY + (rect.height - height) / 2 - nudge,
            width: width,
            height: height
        )
    }

    /// The silhouette, in its own 18-point design space.
    ///
    /// One path with the even-odd winding rule rather than a fill followed by
    /// two `.clear` punches: the cheeks have to travel with the mark when it is
    /// scaled and centred, and a single path is the only way they cannot drift
    /// apart from it.
    private static func markPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 2.2, y: 14.8))
        path.line(to: NSPoint(x: 5.3, y: 4.0))
        path.line(to: NSPoint(x: 8.0, y: 9.2))
        path.line(to: NSPoint(x: 9.0, y: 2.0))
        path.line(to: NSPoint(x: 10.0, y: 9.2))
        path.line(to: NSPoint(x: 12.7, y: 4.0))
        path.line(to: NSPoint(x: 15.8, y: 14.8))
        path.line(to: NSPoint(x: 9.0, y: 16.7))
        path.close()

        // Small cut-outs suggest the two cheek planes of the tanuki mark.
        path.appendOval(in: NSRect(x: 5.7, y: 10.2, width: 1.7, height: 1.2))
        path.appendOval(in: NSRect(x: 10.6, y: 10.2, width: 1.7, height: 1.2))
        path.windingRule = .evenOdd
        return path
    }

    /// Fills the mark into `rect`, scaled and centred by ``markFrame(in:)``.
    /// The silhouette remains legible in both monochrome appearances.
    private static func draw(in rect: NSRect, color: NSColor = .black) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let path = markPath()
        let bounds = path.bounds
        let frame = markFrame(in: rect)
        let scale = frame.height / bounds.height

        // Written as one matrix rather than composed from translate/scale
        // calls: the composition order of `AffineTransform`'s mutating helpers
        // is easy to get backwards, and this states the mapping outright —
        // every point moves to (point - bounds.origin) * scale + frame.origin.
        path.transform(using: AffineTransform(
            m11: scale,
            m12: 0,
            m21: 0,
            m22: scale,
            tX: frame.minX - bounds.minX * scale,
            tY: frame.minY - bounds.minY * scale
        ))

        color.setFill()
        path.fill()
    }
}
