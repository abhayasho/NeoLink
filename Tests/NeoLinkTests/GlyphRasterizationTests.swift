import AppKit
import CoreText
import XCTest
@testable import SwiftTerm

final class GlyphRasterizationTests: XCTestCase {
    func testZeroInkIsDistinguishedFromUnavailableRasterization() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 26, weight: .regular) as CTFont
        var character = UniChar(32), glyph = CGGlyph()
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        let rasterizer = CoreTextGlyphRasterizer()
        for x in 0..<4 {
            for y in 0..<4 {
                guard case .empty = rasterizer.rasterizeResult(font: font, glyph: glyph,
                    phase: GlyphRasterPhase(x: UInt8(x), y: UInt8(y))) else {
                    return XCTFail("A space has no ink in any raster phase")
                }
            }
        }
    }
    func testSubpixelPlacementPreservesPositionAndIntegerTranslation() {
        for value in stride(from: -3.0, through: 3.0, by: 0.03125) {
            let point = CGPoint(x: value, y: -value)
            let placement = GlyphRasterPhase.placement(at: point)
            XCTAssertEqual(placement.origin.x, floor(placement.origin.x))
            XCTAssertEqual(placement.origin.y, floor(placement.origin.y))
            XCTAssertEqual(placement.origin.x + placement.phase.offset.x, point.x, accuracy: 0.125)
            XCTAssertEqual(placement.origin.y + placement.phase.offset.y, point.y, accuracy: 0.125)
            XCTAssertEqual(placement.phase, GlyphRasterPhase.placement(at: CGPoint(x: value + 12, y: -value + 17)).phase)
        }
    }

    func testCachedFractionalGlyphMatchesDirectCoreTextCoverage() throws {
        // Compare the cached bitmap placed at an integer pixel with CoreText drawing
        // directly at the intended fractional baseline. A shifted/filtered phase-zero
        // bitmap cannot pass this test: coverage must be rasterized for that phase.
        let font = NSFont.monospacedSystemFont(ofSize: 26, weight: .regular) as CTFont
        var character = UniChar(109), glyph = CGGlyph()
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        let rasterizer = CoreTextGlyphRasterizer()
        for x in 0..<4 {
            for y in 0..<4 {
                let baseline = CGPoint(x: 30 + CGFloat(x) / 4, y: 30 + CGFloat(y) / 4)
                let placement = GlyphRasterPhase.placement(at: baseline)
                let bitmap = try XCTUnwrap(rasterizer.rasterize(font: font, glyph: glyph, phase: placement.phase))
                let direct = try context(width: 96, height: 96)
                var point = baseline, glyphCopy = glyph
                CTFontDrawGlyphs(font, &glyphCopy, &point, 1, direct)
                let composite = try context(width: 96, height: 96)
                let provider = try XCTUnwrap(CGDataProvider(data: Data(bitmap.pixels) as CFData))
                let image = try XCTUnwrap(CGImage(width: bitmap.width, height: bitmap.height,
                    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                composite.interpolationQuality = .none
                composite.draw(image, in: CGRect(x: placement.origin.x + bitmap.bearing.x, y: placement.origin.y + bitmap.bearing.y,
                                                width: CGFloat(bitmap.width), height: CGFloat(bitmap.height)))
                let a = Data(bytes: direct.data!, count: 96 * 96 * 4), b = Data(bytes: composite.data!, count: 96 * 96 * 4)
                let error = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                XCTAssertLessThan(error, 100, "Raster phase \(x),\(y) must preserve native glyph coverage")
            }
        }
    }

    private func context(width: Int, height: Int) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
        context.setAllowsFontSubpixelPositioning(true); context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelQuantization(false); context.setShouldSubpixelQuantizeFonts(false)
        context.setAllowsFontSmoothing(true); context.setShouldSmoothFonts(true)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        return context
    }
}
