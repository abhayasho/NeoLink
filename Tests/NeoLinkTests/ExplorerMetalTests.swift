import AppKit
import Metal
import ImageIO
import XCTest
@testable import NeoLink

final class ExplorerMetalTests: XCTestCase {
    func testGPUCompletionReleasesFrameWithoutAMainQueueHop() {
        let slot = ExplorerFrameSlot()
        XCTAssertTrue(slot.acquire())
        XCTAssertFalse(slot.acquire())
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { slot.release(); completed.signal() }
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(slot.acquire(), "Completion must unblock the next frame while the main thread is occupied")
        slot.release()
    }

    func testVisibleRowsIncludeFractionalEdgesAndClampDuringRootReplacement() {
        XCTAssertEqual(ExplorerMetalView.visibleRows(count: 100, y: 29, height: 240), 1..<12)
        XCTAssertEqual(ExplorerMetalView.visibleRows(count: 0, y: 500, height: 240), 0..<0)
        XCTAssertEqual(ExplorerMetalView.visibleRows(count: 3, y: 500, height: 240), 3..<3)
        XCTAssertEqual(ExplorerMetalView.visibleRows(count: 100, y: -20, height: 240), 0..<10)
    }
    @MainActor
    func testGPUViewportPixelsRetainNativeInputAndFallBackOnShutdown() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        let prepared = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { ExplorerMetalView.prepare(); prepared.signal() }
        XCTAssertEqual(prepared.wait(timeout: .now() + 10), .success)
        ExplorerMetalView.allowsFrameCapture = true
        defer { ExplorerMetalView.allowsFrameCapture = false }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let document = FlippedExplorerDocument(frame: NSRect(x: 0, y: 0, width: 320, height: 24 * 500))
        scroll.documentView = document
        window.contentView!.addSubview(scroll)
        let rows = (0..<500).map { index -> ExplorerRow in
            let url = URL(fileURLWithPath: "/tmp/gpu-explorer/row-\(index).swift")
            return ExplorerRow(id: url, item: LocalFileItem(url: url, isDirectory: false, creationDate: nil, modificationDate: nil, fileSize: nil),
                name: url.lastPathComponent, depth: 0, expanded: false, missing: false, git: .modified,
                diagnostics: ExplorerDiagnostics(errors: 0, warnings: index == 1 ? 2 : 0))
        }
        let surface = try XCTUnwrap(ExplorerMetalView(scroll: scroll))
        var selected = 1
        var hovered: Int?
        surface.scene = { .init(rows: rows, active: nil, selected: selected, hovered: hovered) }
        var covered: [Bool] = []
        surface.coverageChanged = { covered.append($0) }
        scroll.addSubview(surface, positioned: .above, relativeTo: scroll.contentView)
        defer { surface.shutdown(); window.close() }
        window.makeKeyAndOrderFront(nil); window.orderFrontRegardless()
        surface.invalidateScene()
        XCTAssertNil(surface.hitTest(.init(x: 40, y: 40)), "Pointer events continue to the native table")
        let before = try capture(surface)
        XCTAssertEqual(surface.lastDrawnRange.lowerBound, 0)
        if let path = ProcessInfo.processInfo.environment["NEOLINK_TEST_CAPTURE"],
           let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, before, nil); CGImageDestinationFinalize(destination)
        }
        let scale = window.backingScaleFactor
        XCTAssertEqual(pixel(before, x: Int(300 * scale), y: Int(12 * scale)), [20,20,20])
        XCTAssertEqual(pixel(before, x: Int(300 * scale), y: Int(36 * scale)), [35,35,35], "Selection is composed on the GPU")
        // Compare the retained GPU composition against independent per-row encoding,
        // including fractional edges, reversals and decorations. The extra pass must
        // not blur glyphs or change colors by even one byte.
        for position: CGFloat in [5.5, 29, 7, 24 * 20 + 5] {
            scroll.contentView.scroll(to: .init(x: 0, y: position))
            scroll.reflectScrolledClipView(scroll.contentView)
            let composed = try capture(surface, contentChanged: false)
            let builds = surface.compositionBuilds
            _ = try capture(surface, contentChanged: false)
            XCTAssertEqual(surface.compositionBuilds, builds, "Unchanged frames reuse GPU artwork")
            surface.usesCachedComposition = false
            let reference = try capture(surface, contentChanged: false)
            XCTAssertEqual(composed.dataProvider!.data! as Data, reference.dataProvider!.data! as Data,
                           "Retained composition must equal native-resolution row rendering at y=\(position)")
            surface.usesCachedComposition = true
        }
        XCTAssertGreaterThan(surface.compositionReuses, 0)
        XCTAssertTrue(surface.motionSamples.isEmpty, "Normal rendering must not retain benchmark traces")
        selected = 21; hovered = 22
        let decorated = try capture(surface)
        XCTAssertEqual(pixel(decorated, x: Int(300 * scale), y: Int(31 * scale)), [35,35,35])
        XCTAssertEqual(pixel(decorated, x: Int(300 * scale), y: Int(55 * scale)), [33,33,33])
        surface.usesCachedComposition = false
        let decoratedReference = try capture(surface, contentChanged: false)
        XCTAssertEqual(decorated.dataProvider!.data! as Data, decoratedReference.dataProvider!.data! as Data,
                       "Changed selection and hover must invalidate the retained scene")
        surface.usesCachedComposition = true
        scroll.contentView.scroll(to: .init(x: 0, y: 24 * 20 + 5))
        scroll.reflectScrolledClipView(scroll.contentView)
        let after = try capture(surface)
        XCTAssertEqual(surface.frame.origin, scroll.contentView.frame.origin, "The Metal viewport must not inherit the scrolling document transform")
        XCTAssertEqual(surface.lastDrawnRange.lowerBound, 20)
        XCTAssertEqual(after.width, before.width)
        XCTAssertTrue(surface.lastDrawnRange.count >= 10, "Partially exposed edge rows are included")
        XCTAssertLessThanOrEqual(surface.cachedRowCount, ExplorerMetalView.cacheLimit)
        let buildsBeforeResize = surface.compositionBuilds
        surface.drawOffscreenForTesting {
            // Acquire an old drawable, then change backing dimensions as AppKit does
            // when a scrollbar appears. It must be refused, never stretched.
            scroll.setFrameSize(.init(width: 300, height: 240))
            surface.invalidateScene()
        }
        XCTAssertEqual(surface.lastDrawState, "resizing")
        XCTAssertFalse(surface.isCoveringNativeRows)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(surface.isHidden, "A stale drawable must retry without another user gesture")
        let resized = try capture(surface, contentChanged: false)
        XCTAssertEqual(resized.width, Int((surface.bounds.width * scale).rounded()))
        XCTAssertGreaterThan(surface.compositionBuilds, buildsBeforeResize)
        surface.shutdown()
        XCTAssertFalse(surface.isCoveringNativeRows); XCTAssertEqual(covered.last, false)
    }

    @MainActor
    private func capture(_ surface: ExplorerMetalView, contentChanged: Bool = true) throws -> CGImage {
        let captured = expectation(description: "Explorer GPU pixels")
        var image: CGImage?
        surface.captureNextFrame = { image = $0; captured.fulfill() }
        surface.invalidateScene(contentChanged: contentChanged)
        let deadline = Date(timeIntervalSinceNow: 5)
        while image == nil, Date() < deadline {
            surface.drawOffscreenForTesting()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        wait(for: [captured], timeout: 1)
        return try XCTUnwrap(image)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let bytes = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return [bytes[offset + 2], bytes[offset + 1], bytes[offset]]
    }
}

@MainActor
private final class FlippedExplorerDocument: NSView {
    override var isFlipped: Bool { true }
}
