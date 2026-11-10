import Metal
import XCTest
@testable import NeoLink

final class NeoGPUSceneTests: XCTestCase {
    private final class Pane {}

    /// Models one explorer-like pane: `presented` records a position sample and takes
    /// ownership (covers native rows); `acknowledged` records only the revision.
    private final class PaneLog {
        var positions: [(time: Double, y: Int)] = [], covering = false, revision = 0, revisionTime = 0.0
        func node(_ pane: Pane, frame: UInt64, y: Int, revision: Int) -> (presented: (Double) -> Void, entry: DeferredPresentations.Entry) {
            ({ [unowned self] time in
                positions.append((time, y)); covering = true
                if revision > self.revision { self.revision = revision; revisionTime = time }
            }, .init(pane: ObjectIdentifier(pane), frame: frame, acknowledge: { [unowned self] time in
                if revision > self.revision { self.revision = revision; revisionTime = time }
            }))
        }
    }

    func testDroppedPaneFrameIsNotAcknowledgedByDrawableThatOmitsThePane() {
        let explorer = Pane(), editor = Pane(), log = PaneLog()
        var deferred = DeferredPresentations()
        let dropped = log.node(explorer, frame: 1, y: 100, revision: 5)
        XCTAssertTrue(deferred.complete(presentedTime: 0, frame: 1, current: true, carried: [ObjectIdentifier(explorer)],
                                        presented: [dropped.presented], acknowledged: [dropped.entry]).isEmpty)
        // Cache miss / native fallback / hidden: the next shown drawable carries only the editor.
        deferred.complete(presentedTime: 2, frame: 2, current: true, carried: [ObjectIdentifier(editor)],
                          presented: [], acknowledged: []).forEach { $0(2) }
        XCTAssertFalse(log.covering, "a drawable without the explorer must not hide native fallback rows")
        XCTAssertEqual(log.revision, 0, "the explorer revision was not shown by a drawable that omitted it")
        XCTAssertTrue(log.positions.isEmpty)
        XCTAssertEqual(deferred.count, 1, "the acknowledgement waits for a drawable that carries the pane")
        // A later drawable that does carry the explorer, at a new position.
        let later = log.node(explorer, frame: 3, y: 140, revision: 5)
        deferred.complete(presentedTime: 3, frame: 3, current: true, carried: [ObjectIdentifier(explorer)],
                          presented: [later.presented], acknowledged: [later.entry]).forEach { $0(3) }
        XCTAssertEqual(log.revision, 5); XCTAssertEqual(log.revisionTime, 3)
        XCTAssertEqual(log.positions.map(\.y), [140], "the dropped position (100) never appeared and is never counted")
        XCTAssertEqual(deferred.count, 0)
    }

    func testReplayNeverReportsTwoPositionsAtOneTimestamp() {
        let explorer = Pane(), log = PaneLog()
        var deferred = DeferredPresentations()
        for (frame, y) in [(UInt64(1), 10), (2, 20)] {
            let node = log.node(explorer, frame: frame, y: y, revision: Int(frame))
            _ = deferred.complete(presentedTime: 0, frame: frame, current: true, carried: [ObjectIdentifier(explorer)],
                                  presented: [node.presented], acknowledged: [node.entry])
        }
        let shown = log.node(explorer, frame: 3, y: 30, revision: 3)
        deferred.complete(presentedTime: 7, frame: 3, current: true, carried: [ObjectIdentifier(explorer)],
                          presented: [shown.presented], acknowledged: [shown.entry]).forEach { $0(7) }
        XCTAssertEqual(log.positions.count, 1, "one presented drawable yields one position sample")
        XCTAssertEqual(log.positions.first?.y, 30)
        XCTAssertEqual(log.revision, 3)
    }

    func testStaleCompletionKeepsNewerAcknowledgementsAndNativeOwnership() {
        let editor = Pane(), log = PaneLog()
        var deferred = DeferredPresentations()
        // Frame 2 (new generation) is dropped before the stale frame 1 completion arrives.
        let newer = log.node(editor, frame: 2, y: 0, revision: 9)
        _ = deferred.complete(presentedTime: 0, frame: 2, current: true, carried: [ObjectIdentifier(editor)],
                              presented: [newer.presented], acknowledged: [newer.entry])
        let stale = log.node(editor, frame: 1, y: 0, revision: 4)
        deferred.complete(presentedTime: 5, frame: 1, current: false, carried: [ObjectIdentifier(editor)],
                          presented: [stale.presented], acknowledged: [stale.entry]).forEach { $0(5) }
        XCTAssertFalse(log.covering, "a stale completion must not take ownership back from native fallback")
        XCTAssertEqual(log.revision, 4, "its own content really was shown")
        XCTAssertEqual(deferred.count, 1, "an older drawable neither satisfies nor discards a newer frame's acknowledgement")
        let next = log.node(editor, frame: 3, y: 0, revision: 9)
        deferred.complete(presentedTime: 6, frame: 3, current: true, carried: [ObjectIdentifier(editor)],
                          presented: [next.presented], acknowledged: [next.entry]).forEach { $0(6) }
        XCTAssertEqual(log.revision, 9); XCTAssertTrue(log.covering)
    }

    func testDroppedEditorAcknowledgementReachesNextDrawableCarryingTheEditor() {
        // The original bug: the only frame encoded for a selection is dropped and later
        // frames repeat the retained texture without a new acknowledgement of their own.
        let editor = Pane()
        var deferred = DeferredPresentations(), acknowledged: [UInt64] = []
        let entry = DeferredPresentations.Entry(pane: ObjectIdentifier(editor), frame: 1) { _ in acknowledged.append(14) }
        _ = deferred.complete(presentedTime: 0, frame: 1, current: true, carried: [ObjectIdentifier(editor)], presented: [], acknowledged: [entry])
        deferred.complete(presentedTime: 1, frame: 2, current: true, carried: [ObjectIdentifier(editor)], presented: [], acknowledged: []).forEach { $0(1) }
        deferred.complete(presentedTime: 2, frame: 3, current: true, carried: [ObjectIdentifier(editor)], presented: [], acknowledged: []).forEach { $0(2) }
        XCTAssertEqual(acknowledged, [14], "acknowledged once, by the next shown drawable carrying the pane")
    }

    func testDeferredAcknowledgementsAreBoundedAndRetireWithTheirPane() {
        let pane = Pane(), other = Pane()
        var deferred = DeferredPresentations(), kept: [Int] = []
        for index in 0..<(DeferredPresentations.limit + 10) {
            deferred.dropped([.init(pane: ObjectIdentifier(pane), frame: UInt64(index)) { _ in kept.append(index) }])
        }
        XCTAssertEqual(deferred.count, DeferredPresentations.limit)
        deferred.dropped([.init(pane: ObjectIdentifier(other), frame: 500) { _ in kept.append(-1) }])
        deferred.retire(ObjectIdentifier(other))
        deferred.presented(frame: 1000, carrying: [ObjectIdentifier(pane), ObjectIdentifier(other)]).forEach { $0(1) }
        XCTAssertEqual(kept.first, 11, "the oldest overflow is discarded")
        XCTAssertFalse(kept.contains(-1), "a pane that left for good is not acknowledged later")
    }

    func testFrameLatencyExperimentAcceptsOnlyDocumentedLeads() {
        XCTAssertEqual(NeoGPUFrameLatency.requested("1"), 1)
        XCTAssertEqual(NeoGPUFrameLatency.requested("2"), 2)
        for value: String? in [nil, "", "0", "3", "1.5", "nan", "inf"] {
            XCTAssertNil(NeoGPUFrameLatency.requested(value))
        }
    }
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
