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
        // Taller than wide, as the ears make it: a swapped axis would show here.
        #expect(small.width < small.height)
    }
}
