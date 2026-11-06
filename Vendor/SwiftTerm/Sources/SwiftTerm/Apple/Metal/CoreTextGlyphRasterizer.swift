#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import CoreText

/// Fractional placement belongs in CoreText's coverage calculation, not in a
/// bilinear resample of an already antialiased bitmap. Four phases per axis keep
/// at most 16 variants per glyph; integer translations reuse the same atlas entry.
struct GlyphRasterPhase: Hashable {
    let x: UInt8
    let y: UInt8
    static let zero = GlyphRasterPhase(x: 0, y: 0)
    var offset: CGPoint { CGPoint(x: CGFloat(x) / 4, y: CGFloat(y) / 4) }

    static func placement(at point: CGPoint) -> (origin: CGPoint, phase: GlyphRasterPhase) {
        let x = floor(point.x * 4 + 0.5) / 4, y = floor(point.y * 4 + 0.5) / 4
        let origin = CGPoint(x: floor(x), y: floor(y))
        return (origin, GlyphRasterPhase(x: UInt8((x - origin.x) * 4), y: UInt8((y - origin.y) * 4)))
    }
}

final class CoreTextGlyphRasterizer {
    var fontSmoothing: Bool = true

    enum Result {
        case bitmap(GlyphBitmap)
        /// Deterministic zero ink bounds (for example a space), not an allocation failure.
        case empty
        case unavailable
    }

    func rasterize(font: CTFont, glyph: CGGlyph, phase: GlyphRasterPhase = .zero) -> GlyphBitmap? {
        if case .bitmap(let bitmap) = rasterizeResult(font: font, glyph: glyph, phase: phase) { return bitmap }
        return nil
    }

    func rasterizeResult(font: CTFont, glyph: CGGlyph, phase: GlyphRasterPhase = .zero) -> Result {
        var glyphVar = glyph
        let rect = CTFontGetBoundingRectsForGlyphs(font, .default, &glyphVar, nil, 1)
        if rect.width <= 0 || rect.height <= 0 {
            return .empty
        }

        let shift = phase.offset
        // Leave a pixel around the ink for antialiasing and italic overhangs.
        let minX = floor(rect.minX + shift.x) - 1
        let minY = floor(rect.minY + shift.y) - 1
        let maxX = ceil(rect.maxX + shift.x) + 1
        let maxY = ceil(rect.maxY + shift.y) + 1
        let width = Int(maxX - minX)
        let height = Int(maxY - minY)
        if width <= 0 || height <= 0 {
            return .unavailable
        }

        let bytesPerPixel = 4
        var pixels = Array(repeating: UInt8(0), count: width * height * bytesPerPixel)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else {
                return false
            }
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                return false
            }
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * bytesPerPixel,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo) else {
                return false
            }

            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
#if os(macOS)
            context.setAllowsFontSmoothing(fontSmoothing)
            context.setShouldSmoothFonts(fontSmoothing)
#else
            context.setAllowsFontSmoothing(false)
            context.setShouldSmoothFonts(false)
#endif

            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

            var positions = [CGPoint(x: -minX + shift.x, y: -minY + shift.y)]
            CTFontDrawGlyphs(font, &glyphVar, &positions, 1, context)
            return true
        }
        if !drew {
            return .unavailable
        }

        var isColor = false
        var idx = 0
        while idx < pixels.count {
            let b = pixels[idx]
            let g = pixels[idx + 1]
            let r = pixels[idx + 2]
            if r != g || g != b {
                isColor = true
                break
            }
            idx += 4
        }

        return .bitmap(GlyphBitmap(width: width,
                           height: height,
                           bearing: CGPoint(x: minX, y: minY),
                           pixels: pixels,
                           isColor: isColor))
    }
}
#endif
