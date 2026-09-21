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
    /// The proportions come from GitLab's own mark, converted from its 24-unit
    /// artboard: the muzzle is a single point at the bottom centre, the two
    /// ears rise to the top, and between them the central plane stops lower, at
    /// the shoulder line. The previous path had all of this upside down — a
    /// peak at the top, a wide base, and two oval cut-outs that read as eyes —
    /// which is why it looked like a robot face rather than a fox.
    ///
    /// Monochrome at 18pt cannot carry the five shaded planes of the real logo,
    /// so this is the outline alone. The shoulder "elbows" at the left and
    /// right extremes are kept: they are small, but they are what makes the
    /// profile read as the tanuki instead of a plain arrowhead. The artboard
    /// stays a hair wider than tall, as the original is, rather than being
    /// squared off for convenience.
    static func markPath() -> NSBezierPath {
        let path = NSBezierPath()
        // Muzzle, bottom centre.
        path.move(to: NSPoint(x: 9.07, y: 0.00))
        // Up the left flank, through the elbow, to the shoulder line.
        path.line(to: NSPoint(x: 0.00, y: 6.96))
        path.line(to: NSPoint(x: 0.30, y: 11.21))
        // Left ear.
        path.line(to: NSPoint(x: 3.21, y: 18.00))
        path.line(to: NSPoint(x: 5.42, y: 11.21))
        // The central plane's flat top, lower than the ears.
        path.line(to: NSPoint(x: 12.72, y: 11.21))
        // Right ear, mirrored.
        path.line(to: NSPoint(x: 14.93, y: 18.00))
        path.line(to: NSPoint(x: 17.84, y: 11.21))
        // Down the right flank.
        path.line(to: NSPoint(x: 18.14, y: 6.96))
        path.close()

        // Two eyes, which the official mark does not have: cut out of the
        // central plane, mirrored about the axis, and high enough on the muzzle
        // that the taper below them still reads as a snout. Holes rather than
        // strokes, so the template image keeps working in both menu bar
        // appearances — hence the even-odd winding rule.
        // Sized and placed for the menu bar, not for the artwork: at 1.7pt the
        // holes closed up once the 18pt canvas was scaled down into the bar, so
        // they are wider and further apart than they would be on a large
        // rendering. The height was settled by looking at the bar itself; much
        // below 7.0 and they reach the taper of the muzzle, where at 18pt the
        // outer edge starts eating into them.
        let eyeDiameter: CGFloat = 2.2
        for centreX in [9.07 - 2.45, 9.07 + 2.45] {
            path.appendOval(in: NSRect(
                x: centreX - eyeDiameter / 2,
                y: 7.5 - eyeDiameter / 2,
                width: eyeDiameter,
                height: eyeDiameter
            ))
        }
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
