import AppKit
import XCTest

@testable import Sissy

/// Every glyph the app names is a symbol the catalogue holds and draws.
///
/// Both fail silently in the app, where `Image(_:)` draws nothing for a name
/// the catalogue cannot serve. A symbol whose weight masters cannot
/// interpolate is one AppKit does not serve at all, which is how half the
/// first generation of these came out, and a template whose drawing lost its
/// paths is served and draws nothing.
final class GlyphTests: XCTestCase {
    private static let side = 32

    func testEveryGlyphIsInTheCatalogue() {
        for glyph in Glyph.allCases {
            XCTAssertNotNil(
                NSImage(symbolName: glyph.rawValue, bundle: .main, variableValue: 0),
                "\(glyph.rawValue) is not in the asset catalogue. Run scripts/generate-glyphs.py.")
        }
    }

    func testEveryGlyphLeavesInk() throws {
        for glyph in Glyph.allCases {
            let image = try XCTUnwrap(NSImage(symbolName: glyph.rawValue, bundle: .main, variableValue: 0))
            XCTAssertGreaterThan(Self.inkedPixels(image), 0, "\(glyph.rawValue) renders blank")
        }
    }

    private static func inkedPixels(_ image: NSImage) -> Int {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for x in 0..<side {
            for y in 0..<side where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                inked += 1
            }
        }
        return inked
    }
}
