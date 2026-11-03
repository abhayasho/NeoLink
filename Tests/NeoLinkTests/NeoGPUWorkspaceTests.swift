import AppKit
import Metal
import SwiftUI
import XCTest
@testable import NeoLink

@MainActor private final class WorkspaceGPUClient: NeoGPUClient {
    let view: NSView
    let scene: NeoGPUScene
    var hosted = false
    init(view: NSView, scene: NeoGPUScene) { self.view = view; self.scene = scene }
    var gpuInputView: NSView? { view }
    func gpuSetHosted(_ hosted: Bool) { self.hosted = hosted }
    func gpuPrepare(time: Double, command: MTLCommandBuffer) -> NeoGPUNode? { .init(scene: scene, presented: { _ in }) }
}

final class NeoGPUWorkspaceTests: XCTestCase {
    @MainActor
    func testOverlayStaysOutsideSwiftUIOwnedLayerHierarchyOnResize() throws {
        guard #available(macOS 14, *), let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        _ = NSApplication.shared
        NeoGPUResources.shared.prepare(device: device)
        NeoGPUWorkspace.allowsOffscreenTesting = true
        defer { NeoGPUWorkspace.allowsOffscreenTesting = false }
        let window = WorkspaceWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: Text("Native controls"))
        let container = WorkspaceContentController(hosting: hosting, size: .init(width: 300, height: 200))
        window.contentViewController = container
        let root = try XCTUnwrap(NeoGPUWorkspace(window: window, device: device))
        defer { window.frames.invalidate(); window.close() }
        XCTAssertTrue(root.superview === hosting.view.superview)
        XCTAssertTrue(container.view.subviews.last === root)
        container.view.setFrameSize(.init(width: 600, height: 400))
        XCTAssertEqual(root.frame, container.view.bounds)
        XCTAssertEqual(hosting.view.frame, container.view.bounds)
    }

    @MainActor
    func testWorkspaceComposesTwoPanesWithNativeGeometryAndTransparentChrome() throws {
        guard #available(macOS 14, *), let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal display links unavailable") }
        _ = NSApplication.shared
        NeoGPUResources.shared.prepare(device: device)
        NeoGPUWorkspace.allowsOffscreenTesting = true
        defer { NeoGPUWorkspace.allowsOffscreenTesting = false }
        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 96, height: 64), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: .init(x: 0, y: 0, width: 96, height: 64))
        window.contentView = content
        let left = NSView(frame: .init(x: 4, y: 4, width: 20, height: 20))
        let right = NSView(frame: .init(x: 30, y: 8, width: 20, height: 20))
        content.addSubview(left); content.addSubview(right)
        let a = WorkspaceGPUClient(view: left, scene: try NeoGPUScene(device: device, revision: 0, quads: [
            .init(bounds: .init(0, 0, 50, 50), color: .init(1, 0, 0, 1), ink: .solid)]))
        let b = WorkspaceGPUClient(view: right, scene: try NeoGPUScene(device: device, revision: 0, quads: [
            .init(bounds: .init(0, 0, 50, 50), color: .init(0, 1, 0, 1), ink: .solid)]))
        let root = try XCTUnwrap(NeoGPUWorkspace(window: window, device: device))
        window.gpuWorkspace = root
        defer { window.frames.invalidate(); window.close() }
        window.orderFrontRegardless()
        root.register(a); root.register(b)
        XCTAssertTrue(a.hosted && b.hosted)
        XCTAssertNil(root.hitTest(.init(x: 5, y: 5)), "Input stays with native adapters")
        var image: CGImage?
        root.captureNextFrame = { image = $0 }
        let deadline = Date(timeIntervalSinceNow: 3)
        while image == nil, Date() < deadline {
            root.drawOffscreenForTesting()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        let output = try XCTUnwrap(image)
        let scale = window.backingScaleFactor
        func pixel(_ point: NSPoint) -> [UInt8] {
            let bytes = output.dataProvider!.data! as Data
            let x = Int(point.x * scale), y = Int(point.y * scale)
            let offset = y * output.bytesPerRow + x * 4
            return [bytes[offset + 2], bytes[offset + 1], bytes[offset], bytes[offset + 3]]
        }
        let lr = left.convert(left.bounds, to: root), rr = right.convert(right.bounds, to: root)
        XCTAssertEqual(pixel(.init(x: lr.midX, y: lr.midY)), [255, 0, 0, 255])
        XCTAssertEqual(pixel(.init(x: rr.midX, y: rr.midY)), [0, 255, 0, 255])
        XCTAssertEqual(pixel(.init(x: lr.maxX + 1, y: lr.midY)), [0, 0, 0, 0], "Oversized primitives must remain clipped to their pane")
        XCTAssertEqual(pixel(.init(x: 1, y: 1)), [0, 0, 0, 0], "Native chrome must remain visible below transparent regions")
        XCTAssertEqual(root.lastNodeCount, 2)
        root.setSuspended(true)
        XCTAssertFalse(a.hosted || b.hosted, "Native palettes restore independent surfaces")
        XCTAssertTrue(root.isHidden)
        root.setSuspended(false)
        root.register(a); root.register(b)
        XCTAssertTrue(a.hosted && b.hosted)
    }
}
