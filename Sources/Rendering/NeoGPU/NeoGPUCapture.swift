import Foundation
import CoreGraphics
@preconcurrency import Metal

/// Opt-in pixel validation. Production frame submission never reads GPU pixels.
enum NeoGPUCapture {
    static func encode(_ texture: MTLTexture, command: MTLCommandBuffer, completion: @escaping (CGImage) -> Void) {
        let stride = (texture.width * 4 + 255) / 256 * 256
        guard let buffer = texture.device.makeBuffer(length: stride * texture.height, options: .storageModeShared),
              let blit = command.makeBlitCommandEncoder() else { return }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: texture.width, height: texture.height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * texture.height)
        blit.endEncoding()
        command.addCompletedHandler { _ in
            let data = Data(bytes: buffer.contents(), count: stride * texture.height)
            guard let provider = CGDataProvider(data: data as CFData), let image = CGImage(width: texture.width, height: texture.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
            DispatchQueue.main.async { completion(image) }
        }
    }
}
