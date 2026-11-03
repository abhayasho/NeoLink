import Foundation
@preconcurrency import Metal

/// NeoLink's scene renderer. It encodes into the owner's command buffer, so
/// offscreen composition and on-screen presentation share one GPU submission.
/// Input, document models and accessibility are adapters outside this core.
final class NeoGPURenderer {
    let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let transparent: MTLTexture
    enum Failure: Error { case shader, texture, wrongDevice, encoder }

    init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.shaders, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "neogpu_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "neogpu_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        td.storageMode = .shared; td.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: td) else { throw Failure.texture }
        var pixel: UInt32 = 0
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        transparent = texture
    }

    func encode(_ scene: NeoGPUScene, into target: MTLTexture, command: MTLCommandBuffer,
                translation: SIMD2<Float> = .zero,
                clear: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)) throws {
        guard scene.deviceID == device.registryID, target.device.registryID == device.registryID,
              command.commandQueue.device.registryID == device.registryID else { throw Failure.wrongDevice }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clear
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.encoder }
        encode(scene, encoder: encoder, viewport: SIMD2(Float(target.width), Float(target.height)), translation: translation)
        encoder.endEncoding()
    }

    func encode(_ scene: NeoGPUScene, encoder: MTLRenderCommandEncoder, viewport: SIMD2<Float>,
                translation: SIMD2<Float> = .zero) {
        encoder.label = "NeoGPU scene"
        encoder.setRenderPipelineState(pipeline)
        var frame = SIMD4<Float>(viewport.x, viewport.y, translation.x, translation.y)
        encoder.setVertexBytes(&frame, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        if let buffer = scene.buffer {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            for batch in scene.batches {
                encoder.setVertexBufferOffset(batch.first * MemoryLayout<NeoGPUScene.Instance>.stride, index: 0)
                encoder.setFragmentTexture(batch.texture ?? transparent, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: batch.count)
            }
        }
    }

    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    struct Instance { float4 bounds; float4 uv; float4 color; float4 clip; uint4 flags; };
    struct Vertex { float4 position [[position]]; float2 uv; float4 color; float4 clip; uint kind [[flat]]; };
    vertex Vertex neogpu_vertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                constant Instance *instances [[buffer(0)]], constant float4 &frame [[buffer(1)]]) {
        constexpr float2 corners[] = { {0,0}, {1,0}, {0,1}, {1,0}, {1,1}, {0,1} };
        Instance q = instances[instanceID]; float2 corner = corners[vertexID];
        float2 p = q.bounds.xy + corner * q.bounds.zw + frame.zw;
        Vertex out;
        out.position = float4(p.x / frame.x * 2 - 1, 1 - p.y / frame.y * 2, 0, 1);
        out.uv = mix(q.uv.xy, q.uv.zw, corner); out.color = q.color;
        out.clip = q.clip + float4(frame.zw, frame.zw); out.kind = q.flags.x;
        return out;
    }
    fragment float4 neogpu_fragment(Vertex in [[stage_in]], texture2d<float> texture [[texture(0)]]) {
        if (in.position.x < in.clip.x || in.position.y < in.clip.y ||
            in.position.x >= in.clip.z || in.position.y >= in.clip.w) discard_fragment();
        if (in.kind == 0) return float4(in.color.rgb * in.color.a, in.color.a);
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
        float4 ink = texture.sample(s, in.uv);
        if (in.kind == 2) return float4(in.color.rgb * in.color.a, in.color.a) * ink.a;
        return ink + in.color * (1 - ink.a);
    }
    """
}
