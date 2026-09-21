import AppKit
import Testing
@testable import GitLabAlert

/// The mark used to be positioned by hand-written path coordinates that were
/// not balanced — it ran from y 2.0 to 16.7 on an 18pt canvas and read as stuck
/// to the top of the menu bar. These assertions are the reason that cannot come
/// back silently: they check the placement without rasterizing anything.
@Suite("MenuBarGlyph")
struct MenuBarGlyphTests {

    private let tolerance: CGFloat = 0.001

    @Test("the mark is centred horizontally")
    func markIsCentredHorizontally() {
        let canvas = NSRect(origin: .zero, size: MenuBarGlyph.size)
        #expect(abs(MenuBarGlyph.markFrame(in: canvas).midX - canvas.midX) < tolerance)
    }

    /// Vertically the mark is centred and then nudged down by the measured
    /// optical offset, which is what lines it up with the system icons rather
    /// than with its own canvas.
    @Test("the mark sits one optical offset below the vertical centre")
    func markCarriesTheOpticalOffset() {
        let canvas = NSRect(origin: .zero, size: MenuBarGlyph.size)
        let frame = MenuBarGlyph.markFrame(in: canvas)
        #expect(abs(frame.midY - (canvas.midY - MenuBarGlyph.opticalOffset)) < tolerance)
    }

    @Test("the ink is as tall as markHeight")
    func markUsesTheRequestedHeight() {
        let canvas = NSRect(origin: .zero, size: MenuBarGlyph.size)
        #expect(abs(MenuBarGlyph.markFrame(in: canvas).height - MenuBarGlyph.markHeight) < tolerance)
    }

    @Test("the mark stays inside the canvas")
    func markFitsTheCanvas() {
        let canvas = NSRect(origin: .zero, size: MenuBarGlyph.size)
        let frame = MenuBarGlyph.markFrame(in: canvas)

        #expect(frame.minX >= canvas.minX)
        #expect(frame.minY >= canvas.minY)
        #expect(frame.maxX <= canvas.maxX)
        #expect(frame.maxY <= canvas.maxY)
    }

    /// `NSImage(size:flipped:)` hands the drawing handler whatever rect the
    /// backing store asks for, which is not always the 18pt canvas.
    @Test("placement follows the rect it is drawn into", arguments: [
        NSRect(x: 0, y: 0, width: 36, height: 36),
        NSRect(x: 4, y: 7, width: 18, height: 18),
        NSRect(x: -3, y: 2, width: 22, height: 22)
    ])
    func markFollowsItsRect(rect: NSRect) {
        let scale = rect.height / MenuBarGlyph.size.height
        let frame = MenuBarGlyph.markFrame(in: rect)

        #expect(abs(frame.midX - rect.midX) < tolerance)
        #expect(abs(frame.midY - (rect.midY - MenuBarGlyph.opticalOffset * scale)) < tolerance)
        #expect(abs(frame.height - MenuBarGlyph.markHeight * scale) < tolerance)
    }

    @Test("the silhouette keeps its proportions")
    func aspectRatioIsPreserved() {
        let small = MenuBarGlyph.markFrame(in: NSRect(origin: .zero, size: MenuBarGlyph.size))
        let large = MenuBarGlyph.markFrame(in: NSRect(x: 0, y: 0, width: 72, height: 72))

        #expect(abs(small.width / small.height - large.width / large.height) < tolerance)
        // GitLab's mark is marginally wider than it is tall (its artboard is
        // 22.64 by 22.47). Asserting the ratio, rather than just "wider than
        // tall", is what would catch a silhouette redrawn out of proportion.
        #expect(abs(small.width / small.height - 18.14 / 18.0) < 0.01)
    }

    /// The ears and flanks are mirror images in the original, and an
    /// asymmetric glyph looks broken next to the system icons long before
    /// anyone works out why.
    @Test("the silhouette is symmetric about its vertical axis")
    func silhouetteIsSymmetric() {
        let path = MenuBarGlyph.markPath()
        var points = [NSPoint](repeating: .zero, count: 3)
        var xs: [CGFloat] = []
        for index in 0..<path.elementCount {
            // Every point of every element, not just the first: the eyes are
            // ovals, so their mirrors sit in Bézier control points, and reading
            // only points[0] would compare a control point against a vertex.
            switch path.element(at: index, associatedPoints: &points) {
            case .moveTo, .lineTo: xs.append(points[0].x)
            case .curveTo: xs.append(contentsOf: points.map(\.x))
            case .closePath: break
            @unknown default: break
            }
        }
        let axis = (path.bounds.minX + path.bounds.maxX) / 2
        for x in xs {
            let mirrored = 2 * axis - x
            #expect(xs.contains { abs($0 - mirrored) < 0.02 }, "no mirror for x=\(x)")
        }
    }
}
