import Metal
import XCTest
@testable import NeoLink

final class NeoGPUSceneTests: XCTestCase {
    func testFrameWakeDuringEncodingSurvivesAnUnusedDrawable() {
        var demand = NeoGPUFrameDemand()
        demand.wake(); demand.beginFrame()
        XCTAssertFalse(demand.endFrame(usedDrawable: false), "An already served wake must not keep an idle link alive")
        demand.beginFrame(); demand.wake()
        XCTAssertTrue(demand.endFrame(usedDrawable: false), "Work arriving during a frame must retain its next callback")
        demand.beginFrame()
        XCTAssertTrue(demand.endFrame(usedDrawable: true))
        demand.beginFrame()
        XCTAssertFalse(demand.endFrame(usedDrawable: false))
    }

    func testInstancedPaintOrderClippingAndGPUTranslation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let renderer = try NeoGPURenderer(device: device)
        let scene = try NeoGPUScene(device: device, revision: 1, quads: [
            .init(bounds: .init(0, 0, 16, 16), color: .init(1, 0, 0, 1), ink: .solid),
            .init(bounds: .init(0, 0, 16, 16), color: .init(0, 0, 1, 0.5), clip: .init(4, 4, 8, 8), ink: .solid),
            .init(bounds: .init(6, 6, 2, 2), color: .init(0, 1, 0, 1), ink: .solid)
        ])
        XCTAssertEqual(scene.batches.count, 1, "Adjacent solids form one ordered instance batch")
        let originalBuffer = scene.buffer
        let pixels = try render(renderer, scene, translation: .init(2, 1))
        XCTAssertTrue(scene.buffer === originalBuffer, "Motion must not rewrite or allocate instance geometry")
        check(pixels, x: 0, y: 0, [0, 0, 0])
        check(pixels, x: 2, y: 1, [255, 0, 0])
        check(pixels, x: 5, y: 5, [255, 0, 0], "Clip moves with scene coordinates")
        check(pixels, x: 6, y: 5, [128, 0, 128])
        check(pixels, x: 8, y: 7, [0, 255, 0], "Later instances paint over earlier instances")
        check(pixels, x: 10, y: 5, [255, 0, 0], "Clip's upper edge is exclusive")
    }

    func testTexturedSurfacesAndTintedGlyphMasksShareABatch() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2, height: 1, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let texels: [UInt8] = [0, 0, 255, 255, 0, 128, 0, 128]
        texels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8) }
        let scene = try NeoGPUScene(device: device, revision: 2, quads: [
            .init(bounds: .init(0, 0, 8, 8), color: .init(0, 0, 1, 1), texture: texture),
            .init(bounds: .init(8, 0, 8, 8), color: .init(1, 1, 1, 1), texture: texture, ink: .mask)
        ])
        XCTAssertEqual(scene.batches.count, 1)
        let pixels = try render(NeoGPURenderer(device: device), scene)
        check(pixels, x: 1, y: 1, [255, 0, 0])
        check(pixels, x: 6, y: 1, [0, 128, 127])
        check(pixels, x: 9, y: 1, [255, 255, 255])
        check(pixels, x: 14, y: 1, [128, 128, 128])
    }

    func testRejectsInvalidScenesAndOmitsEmptyPrimitives() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        XCTAssertEqual(MemoryLayout<NeoGPUScene.Instance>.stride, 80)
        XCTAssertThrowsError(try NeoGPUScene(device: device, revision: 0, quads: [
            .init(bounds: .init(.nan, 0, 1, 1), ink: .solid)]))
        XCTAssertThrowsError(try NeoGPUScene(device: device, revision: 0, quads: [
            .init(bounds: .init(0, 0, 1, 1))]), "A surface cannot reference a missing texture")
        let empty = try NeoGPUScene(device: device, revision: 0, quads: [.init(bounds: .zero, ink: .solid)])
        XCTAssertEqual(empty.count, 0); XCTAssertNil(empty.buffer)
    }

    private func render(_ renderer: NeoGPURenderer, _ scene: NeoGPUScene, translation: SIMD2<Float> = .zero) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 20, height: 20, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .renderTarget
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(renderer.device.makeCommandQueue()?.makeCommandBuffer())
        try renderer.encode(scene, into: texture, command: command, translation: translation)
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, String(describing: command.error))
        var pixels = [UInt8](repeating: 0, count: 20 * 20 * 4)
        pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 80, from: MTLRegionMake2D(0, 0, 20, 20), mipmapLevel: 0) }
        return pixels
    }

    private func check(_ pixels: [UInt8], x: Int, y: Int, _ rgb: [Int], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let offset = (y * 20 + x) * 4
        for (component, expected) in zip([2, 1, 0], rgb) {
            XCTAssertLessThanOrEqual(abs(Int(pixels[offset + component]) - expected), 1, message, file: file, line: line)
        }
    }
}
