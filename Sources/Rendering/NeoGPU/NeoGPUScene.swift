import Foundation
@preconcurrency import Metal
import simd

/// A retained, device-pixel scene. Instances stay immutable while the GPU uses
/// them; scrolling changes a small frame uniform, not the instance buffer.
final class NeoGPUScene {
    enum Ink: UInt32 { case solid, surface, mask }

    struct Quad {
        var bounds: SIMD4<Float> // x, y, width, height in backing pixels
        var uv = SIMD4<Float>(0, 0, 1, 1)
        var color = SIMD4<Float>(0, 0, 0, 1)
        var clip: SIMD4<Float>? // min x/y, max x/y, in scene coordinates
        var texture: MTLTexture?
        var ink: Ink = .surface
    }

    // Every member has explicit 16-byte alignment, shared with the Metal struct.
    struct Instance {
        var bounds: SIMD4<Float>
        var uv: SIMD4<Float>
        var color: SIMD4<Float>
        var clip: SIMD4<Float>
        var flags: SIMD4<UInt32>
    }
    struct Batch {
        let first: Int
        var count: Int
        let texture: MTLTexture?
    }
    enum Failure: Error { case tooLarge, invalidGeometry, wrongDevice, allocation }
    static let maximumQuads = 65_536
    let revision: UInt64
    let count: Int
    let buffer: MTLBuffer?
    let batches: [Batch]
    let deviceID: UInt64

    init(device: MTLDevice, revision: UInt64, quads: [Quad]) throws {
        guard quads.count <= Self.maximumQuads else { throw Failure.tooLarge }
        self.revision = revision; deviceID = device.registryID
        var instances: [Instance] = [], batches: [Batch] = []
        instances.reserveCapacity(quads.count)
        for quad in quads {
            let b = quad.bounds
            let clip = quad.clip ?? SIMD4<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude,
                                                 Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
            guard b.allFinite, quad.uv.allFinite, quad.color.allFinite, clip.allFinite,
                  b.z >= 0, b.w >= 0, clip.z >= clip.x, clip.w >= clip.y else { throw Failure.invalidGeometry }
            if let texture = quad.texture, texture.device.registryID != device.registryID { throw Failure.wrongDevice }
            guard b.z > 0, b.w > 0 else { continue }
            if quad.ink != .solid, quad.texture == nil { throw Failure.invalidGeometry }
            let index = instances.count
            instances.append(Instance(bounds: b, uv: quad.uv, color: quad.color, clip: clip,
                                      flags: .init(quad.ink.rawValue, 0, 0, 0)))
            // Batch only adjacent draws: reordering overlapping translucent primitives
            // by texture would change their paint order.
            if let last = batches.last, (last.texture as AnyObject?) === (quad.texture as AnyObject?) {
                batches[batches.count - 1].count += 1
            } else { batches.append(Batch(first: index, count: 1, texture: quad.texture)) }
        }
        count = instances.count; self.batches = batches
        if instances.isEmpty { buffer = nil; return }
        var options: MTLResourceOptions = [.cpuCacheModeWriteCombined]
        options.insert(device.hasUnifiedMemory ? .storageModeShared : .storageModeManaged)
        let length = instances.count * MemoryLayout<Instance>.stride
        guard let buffer = device.makeBuffer(length: length, options: options) else { throw Failure.allocation }
        instances.withUnsafeBytes { bytes in buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: length) }
        if buffer.storageMode == .managed { buffer.didModifyRange(0..<length) }
        buffer.label = "NeoGPU retained scene \(revision)"
        self.buffer = buffer
    }
}

private extension SIMD4 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
}
