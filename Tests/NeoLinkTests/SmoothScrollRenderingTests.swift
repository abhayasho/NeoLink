import AppKit
import Metal
import XCTest
import SwiftTerm
@testable import NeoLink

/// Renders with SwiftTerm's Metal renderer and compares frames pixel by pixel.
final class SmoothScrollRenderingTests: XCTestCase {
    @MainActor
    func testHiddenTerminalDoesNotPrepareRowsOrConsumeFrameTagsDuringNativeResize() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        TerminalView.allowsMetalFrameCapture = true
        defer { TerminalView.allowsMetalFrameCapture = false }
        let (window, view) = makeMetalTerminal()
        let (referenceWindow, reference) = makeMetalTerminal()
        defer { window.close(); referenceWindow.close() }
        try view.setUseMetal(true); try reference.setUseMetal(true)
        let text = "\u{1B}[?25l\u{1B}[2J\u{1B}[H\u{1B}[31;44m界 🦎 native resize\u{1B}[0m\r\n\u{1B}#3DOUBLE TOP\r\n\u{1B}#4DOUBLE BOTTOM"
        view.feed(text: text)
        _ = try capture(view)
        var samples = 0
        view.metalPreparationProfile = { _ in samples += 1 }
        view.metalNextFrameTag = 1024
        view.metalUsesExternalDrawables = true
        view.setFrameSize(.init(width: 490, height: 320))
        view.drawMetalFrameNow()
        XCTAssertEqual(samples, 0, "A native callback without the owner's drawable must not build rows")
        XCTAssertEqual(view.metalNextFrameTag, 1024)
        view.metalUsesExternalDrawables = false
        view.isHidden = true
        for width: CGFloat in [485, 480.5, 475.125, 490] {
            view.setFrameSize(.init(width: width, height: 320))
            view.drawMetalFrameNow()
        }
        XCTAssertEqual(samples, 0, "Native resize must not prepare artwork for a hidden pane")
        XCTAssertEqual(view.metalNextFrameTag, 1024, "Keep unsubmitted tags and dirty state intact")
        view.metalPreparationProfile = nil
        view.isHidden = false
        reference.setFrameSize(view.frame.size)
        reference.feed(text: text)
        let shown = try capture(view), fresh = try capture(reference)
        XCTAssertEqual(shown.dataProvider!.data! as Data, fresh.dataProvider!.data! as Data,
                       "Showing a resized pane must draw current native-resolution content")
    }
    @MainActor
    func testRebuiltRowsReuseConfirmedEmptyGlyphsWithoutChangingPixels() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        TerminalView.allowsMetalFrameCapture = true
        defer { TerminalView.allowsMetalFrameCapture = false }
        let (window, view) = makeMetalTerminal()
        defer { window.close() }
        try view.setUseMetal(true)
        let text = "\u{1B}[?25l\u{1B}[2J\u{1B}[H\u{1B}[31;44m   界 🦎 blank glyphs   \u{1B}[0m\r\n" + String(repeating: " ", count: 40)
        view.feed(text: text)
        let before = try capture(view)
        var samples: [[String: Double]] = []
        view.metalPreparationProfile = { samples.append($0) }
        defer { view.metalPreparationProfile = nil }
        // Redraw identical text with new line generations, retaining the atlas.
        view.feed(text: text)
        let after = try capture(view)
        XCTAssertEqual(before.dataProvider!.data! as Data, after.dataProvider!.data! as Data)
        XCTAssertGreaterThan(samples.reduce(0) { $0 + $1["rowsRebuilt", default: 0] }, 0)
        XCTAssertGreaterThan(samples.reduce(0) { $0 + $1["emptyGlyphHits", default: 0] }, 40)
        XCTAssertEqual(samples.reduce(0) { $0 + $1["glyphRasterizations", default: 0] }, 0,
                       "Blank cells must not repeatedly ask CoreText for their outlines")
    }
    @MainActor
    func testSubColumnResizeMatchesFreshRendererIncludingDoubledHeightClips() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        TerminalView.allowsMetalFrameCapture = true
        defer { TerminalView.allowsMetalFrameCapture = false }
        let (window, view) = makeMetalTerminal()
        let (referenceWindow, reference) = makeMetalTerminal()
        defer { window.close(); referenceWindow.close() }
        window.setContentSize(.init(width: 490, height: 320))
        referenceWindow.setContentSize(.init(width: 490, height: 320))
        try view.setUseMetal(true); try reference.setUseMetal(true)
        let content = "\u{1B}[?25l\u{1B}[2J\u{1B}[Hcolor \u{1B}[31;44m界 🦎 abcdefghijklmnopqrstuvwxyz\u{1B}[0m\r\n\u{1B}#3DOUBLE HEIGHT TOP \r\n\u{1B}#4DOUBLE HEIGHT BOTTOM\r\n\u{1B}#6DOUBLE WIDTH\r\nnormal last row"
        view.feed(text: content)
        _ = try capture(view)
        let columns = view.getTerminal().cols
        for width: CGFloat in [480.125, 480.25, 480.375, 480, 489] {
            view.setFrameSize(.init(width: width, height: 320))
            reference.setFrameSize(.init(width: width, height: 320))
            // A full erase/repaint makes the reference rebuild independently.
            reference.feed(text: content)
            if width < 481 { XCTAssertEqual(view.getTerminal().cols, columns) }
            let reused = try capture(view), fresh = try capture(reference)
            XCTAssertEqual(reused.width, fresh.width)
            XCTAssertEqual(reused.dataProvider!.data! as Data, fresh.dataProvider!.data! as Data,
                           "Sub-column resize must preserve clipping and phase-correct text at width \(width)")
        }
    }

    @MainActor
    func testHostedTerminalSceneCompositesWithoutChangingPixelsOrCommittingTheOwnersBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        TerminalView.allowsMetalFrameCapture = true
        defer { TerminalView.allowsMetalFrameCapture = false }
        let (window, view) = makeMetalTerminal()
        defer { window.close() }
        try view.setUseMetal(true)
        view.feed(text: "\u{1B}[?25l\u{1B}[2J\u{1B}[HHosted terminal 界 🦎\r\n\u{1B}[31;44mColor\u{1B}[0m")
        let before = try capture(view)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: before.width, height: before.height, mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        descriptor.storageMode = .shared
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        var encoded: UInt64 = 0
        view.metalUsesExternalDrawables = true
        view.metalHostTexture = source; view.metalHostCommandBuffer = command
        view.metalHostFrameEncoded = { encoded = $0 }
        view.metalNextFrameTag = 456
        // Suppress queued MTKView redraws while this fixture owns submission.
        view.metalFrameScheduler = { _ in }
        let deadline = Date(timeIntervalSinceNow: 2)
        while encoded == 0, Date() < deadline {
            view.drawMetalFrameNow()
            if encoded == 0 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
        }
        XCTAssertEqual(encoded, 456)
        XCTAssertEqual(command.status, .notEnqueued, "Only the workspace may submit its shared buffer")
        let scene = try NeoGPUScene(device: device, revision: 1, quads: [
            .init(bounds: .init(0, 0, Float(before.width), Float(before.height)), color: .zero, texture: source)])
        try NeoGPURenderer(device: device).encode(scene, into: output, command: command)
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var pixels = [UInt8](repeating: 0, count: before.width * before.height * 4)
        pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: before.width * 4,
            from: MTLRegionMake2D(0, 0, before.width, before.height), mipmapLevel: 0) }
        XCTAssertEqual(Data(pixels), before.dataProvider!.data! as Data,
                       "The custom workspace scene must preserve terminal glyphs, colors and emoji byte for byte")
        view.metalHostTexture = nil; view.metalHostCommandBuffer = nil; view.metalHostFrameEncoded = nil
        view.metalUsesExternalDrawables = false
    }

    @MainActor
    func testDisplayLinkDrawableHandoffMatchesLegacyPixels() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        TerminalView.allowsMetalFrameCapture = true
        defer { TerminalView.allowsMetalFrameCapture = false }
        let (window, view) = makeMetalTerminal()
        defer { window.close() }
        try view.setUseMetal(true)
        view.feed(text: "\u{1B}[?25l\u{1B}[2J\u{1B}[HMetal handoff 界\r\n\u{1B}[31mColor\u{1B}[0m")
        let before = try capture(view)
        let layer = try XCTUnwrap(view.metalDisplayLayer)
        // This fixture owns acquisition; no CAMetalDisplayLink is attached to it.
        view.metalUsesExternalDrawables = true
        view.metalExternalDrawable = try XCTUnwrap(layer.nextDrawable())
        let after = try capture(view)
        view.metalExternalDrawable = nil
        view.metalUsesExternalDrawables = false
        XCTAssertEqual(after.width, before.width)
        XCTAssertGreaterThan(rowsMatching(after, before, offset: 0, rows: 0..<before.height), 0.99,
                             "A supplied drawable must retain all text, color and viewport geometry")
    }

    @MainActor
    func testStaleDrawableAfterResizeIsNotStretchedOrPresented() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        TerminalView.allowsMetalFrameCapture = true
        defer { TerminalView.allowsMetalFrameCapture = false }
        let (window, view) = makeMetalTerminal()
        defer { window.close() }
        try view.setUseMetal(true)
        view.feed(text: "\u{1B}[?25lResize: readable pixels")
        let before = try capture(view)
        let layer = try XCTUnwrap(view.metalDisplayLayer)
        view.metalUsesExternalDrawables = true
        view.metalExternalDrawable = try XCTUnwrap(layer.nextDrawable())
        view.setFrameSize(NSSize(width: view.frame.width + 13, height: view.frame.height + 7))
        view.metalNextFrameTag = 999
        view.drawMetalFrameNow()
        XCTAssertEqual(view.metalNextFrameTag, 999, "An old-size texture must never be submitted with new viewport geometry")
        view.metalExternalDrawable = nil
        view.metalUsesExternalDrawables = false
        view.metalNextFrameTag = 0
        let after = try capture(view)
        XCTAssertEqual(after.width, before.width + Int(13 * window.backingScaleFactor))
        XCTAssertEqual(after.height, before.height + Int(7 * window.backingScaleFactor))
    }

    @MainActor
    func testProgramScrollOffsetShiftsTheRegionAndFillsTheEdgeWithTheRetainedLine() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        TerminalView.allowsMetalFrameCapture = true
        defer { TerminalView.allowsMetalFrameCapture = false }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = TerminalView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        window.orderFrontRegardless()
        try view.setUseMetal(true)
        view.feed(text: "\u{1B}[?1049h\u{1B}[2J\u{1B}[H" + (1...40).map { "\($0) The quick brown fox \(String(repeating: "#", count: $0 % 20))" }.joined(separator: "\r\n"))
        view.feed(text: "\u{1B}[?25l") // Hide the cursor; it is drawn separately.
        let before = try capture(view)

        // The program scrolls its region up one line and draws the newly exposed bottom row.
        view.feed(text: "\u{1B}[H\u{1B}[M\u{1B}[\(view.getTerminal().rows);1Hnew bottom line")
        _ = try capture(view)
        let cell = try XCTUnwrap(view.cellSizeInPixels(source: view.getTerminal())).height
        XCTAssertEqual(view.smoothScrollRange.upperBound, CGFloat(cell) / window.backingScaleFactor,
                       "One retained line can fill the edge above the region")

        // Drawn 3/8 of a line lower than the grid: equal to the first frame scrolled by 5/8 of a line.
        let scale = window.backingScaleFactor
        let shift = (cell * 3) / 8
        view.smoothScrollSource = .program
        view.smoothScrollOffset = CGFloat(shift) / scale
        let mid = try capture(view)
        let up = cell - shift // How far the content moved up relative to `before`.
        XCTAssertGreaterThan(rowsMatching(mid, before, offset: up, rows: 0..<(mid.height - cell * 2)), 0.99)

        view.smoothScrollOffset = 0
        let settled = try capture(view)
        XCTAssertGreaterThan(rowsMatching(settled, before, offset: cell, rows: 0..<(settled.height - cell * 2)), 0.99)
        XCTAssertLessThan(rowsMatching(mid, settled, offset: 0, rows: 0..<(mid.height - cell * 2)), 0.5,
                          "The offset frame differs from the grid as drawn")
    }

    @MainActor
    func testScrollbackOffsetExposesTheBufferLineBelowTheViewport() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        TerminalView.allowsMetalFrameCapture = true
        defer { TerminalView.allowsMetalFrameCapture = false }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = TerminalView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        window.orderFrontRegardless()
        try view.setUseMetal(true)
        view.feed(text: (1...200).map { "\($0) scrollback \(String(repeating: "=", count: $0 % 30))" }.joined(separator: "\r\n"))
        view.feed(text: "\u{1B}[?25l")
        XCTAssertEqual(view.scrollViewport(towardTop: 10), 10)
        let lower = try capture(view) // Ten lines back.
        XCTAssertEqual(view.scrollViewport(towardTop: 1), 1)
        _ = try capture(view)         // Eleven lines back: content one line lower.
        let cell = try XCTUnwrap(view.cellSizeInPixels(source: view.getTerminal())).height
        let shift = cell / 4
        view.smoothScrollSource = .scrollback
        XCTAssertLessThan(view.smoothScrollRange.lowerBound, 0, "Lines below the viewport are available")
        // Drawn a quarter line higher: 3/4 of a line lower than the frame ten lines back.
        view.smoothScrollOffset = -CGFloat(shift) / window.backingScaleFactor
        let mid = try capture(view)
        let down = cell - shift
        let rows = down..<(mid.height - cell)
        XCTAssertGreaterThan(rowsMatching(mid, lower, offset: -down, rows: rows), 0.99)
        // The strip exposed under the last row comes from the buffer line below the viewport.
        let rowsOnScreen = view.getTerminal().rows
        let edge = rowsOnScreen * cell - shift
        XCTAssertLessThanOrEqual(edge + shift, mid.height)
        XCTAssertEqual(rowsMatching(mid, lower, offset: -down, rows: edge..<(edge + shift)), 1)
        view.smoothScrollOffset = 0
    }

    @MainActor
    func testParkedScrollbackFractionDrawsTheSamePixelsAcrossGridBoundariesAndIdleFrames() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        TerminalView.allowsMetalFrameCapture = true
        defer { TerminalView.allowsMetalFrameCapture = false }
        let (window, view) = makeMetalTerminal(), (otherWindow, other) = makeMetalTerminal()
        defer { window.close(); otherWindow.close() }
        try view.setUseMetal(true); try other.setUseMetal(true)
        let content = (1...200).map { "\($0) scrollback \(String(repeating: "#", count: $0 % 30))" }.joined(separator: "\r\n") + "\u{1B}[?25l"
        view.feed(text: content); other.feed(text: content)
        XCTAssertEqual(view.scrollViewport(towardTop: 10), 10)
        XCTAssertEqual(other.scrollViewport(towardTop: 11), 11)
        _ = try capture(view); _ = try capture(other)
        let cell = try XCTUnwrap(view.cellSizeInPixels(source: view.getTerminal())).height
        let quarter = cell / 4, scale = window.backingScaleFactor
        view.smoothScrollSource = .scrollback; other.smoothScrollSource = .scrollback
        view.smoothScrollOffset = CGFloat(quarter) / scale
        other.smoothScrollOffset = -CGFloat(cell - quarter) / scale
        let parked = try capture(view), equivalent = try capture(other)
        let region = 0..<(view.getTerminal().rows * cell - cell)
        XCTAssertGreaterThan(rowsMatching(parked, equivalent, offset: 0, rows: region), 0.99,
                             "Either grid anchor must draw identical text, including the exposed top edge")
        for _ in 0..<3 {
            let idle = try capture(view)
            XCTAssertEqual(rowsMatching(idle, parked, offset: 0, rows: region), 1,
                           "Unrelated frames do not move or re-rasterize the parked text")
        }
    }

    @MainActor
    func testLinesThatEnteredAndLeftTheRegionBetweenFramesAreDrawnAtTheEdge() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        TerminalView.allowsMetalFrameCapture = true
        defer { TerminalView.allowsMetalFrameCapture = false }
        let content = "\u{1B}[?1049h\u{1B}[2J\u{1B}[H" + (1...40).map { "\($0) lazy dog \(String(repeating: "%", count: $0 % 17))" }.joined(separator: "\r\n") + "\u{1B}[?25l"
        // The program scrolls up two lines and writes them; a reversal then scrolls them out
        // again, all before the next frame, so the renderer never drew those two lines.
        let insertTwo = "\u{1B}[H\u{1B}[2L\u{1B}[1;1Hnew first line\u{1B}[2;1Hnew second line"
        let (window, view) = makeMetalTerminal()
        defer { window.close() }
        let (referenceWindow, reference) = makeMetalTerminal()
        defer { referenceWindow.close() }
        try view.setUseMetal(true)
        try reference.setUseMetal(true)
        view.feed(text: content)
        reference.feed(text: content + insertTwo)
        _ = try capture(view)
        let expected = try capture(reference)

        view.feed(text: insertTwo + "\u{1B}[H\u{1B}[2M")
        let cell = try XCTUnwrap(view.cellSizeInPixels(source: view.getTerminal())).height
        let scale = window.backingScaleFactor
        XCTAssertEqual(view.smoothScrollRange.upperBound, CGFloat(2 * cell) / scale, "Both lines are retained")
        view.smoothScrollSource = .program
        // Drawn two lines lower: the screen as it was with the two lines on top.
        view.smoothScrollOffset = CGFloat(2 * cell) / scale
        let whole = try capture(view)
        let region = 0..<(view.getTerminal().rows - 2) * cell
        XCTAssertGreaterThan(rowsMatching(whole, expected, offset: 0, rows: region), 0.99)
        // A line and a half lower: the same screen moved up half a line, the edge included.
        let half = cell / 2
        view.smoothScrollOffset = CGFloat(2 * cell - half) / scale
        let fractional = try capture(view)
        XCTAssertGreaterThan(rowsMatching(fractional, expected, offset: half, rows: 0..<(region.upperBound - half)), 0.99)
        XCTAssertEqual(view.metalLastDrawnScrollOffset, CGFloat(2 * cell - half) / scale, accuracy: 1 / scale)
        view.smoothScrollOffset = 0
    }

    @MainActor
    func testFramesWaitForTheEndOfASynchronizedUpdate() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        _ = NSApplication.shared
        let (window, view) = makeMetalTerminal()
        defer { window.close() }
        try view.setUseMetal(true)
        view.feed(text: "\u{1B}[?1049h\u{1B}[2J\u{1B}[H" + (1...40).map { "line \($0)" }.joined(separator: "\r\n"))
        view.feed(text: "\u{1B}[H\u{1B}[M") // One retained line, so an offset is drawable.
        view.drawMetalFrameNow()
        var scheduled: [() -> Void] = []
        view.metalFrameScheduler = { scheduled.append($0) }
        defer { view.metalFrameScheduler = nil }
        let scale = window.backingScaleFactor
        let cell = CGFloat(try XCTUnwrap(view.cellSizeInPixels(source: view.getTerminal())).height) / scale
        view.smoothScrollSource = .program

        // A redraw requested while a program's update is open is not scheduled.
        view.feed(text: "\u{1B}[?2026h")
        view.smoothScrollOffset = cell / 2
        XCTAssertTrue(scheduled.isEmpty)
        view.feed(text: "\u{1B}[?2026l")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        scheduled.removeAll()

        // A frame requested before an update began does not draw while the update is open.
        view.smoothScrollOffset = cell / 4
        XCTAssertEqual(scheduled.count, 1)
        view.feed(text: "\u{1B}[?2026h\u{1B}[5;1Hhalf-written")
        let before = view.metalLastDrawnScrollOffset
        scheduled.forEach { $0() }; scheduled.removeAll()
        XCTAssertEqual(view.metalLastDrawnScrollOffset, before, "Nothing drawn mid-update")

        // The update's end brings a frame.
        view.feed(text: " update\u{1B}[?2026l")
        let deadline = Date(timeIntervalSinceNow: 1)
        while scheduled.isEmpty && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        XCTAssertFalse(scheduled.isEmpty)
        scheduled.forEach { $0() }
        XCTAssertEqual(view.metalLastDrawnScrollOffset, cell / 4, accuracy: 1 / scale)
        view.smoothScrollOffset = 0
    }

    @MainActor
    private func makeMetalTerminal() -> (NSWindow, TerminalView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TerminalView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        window.orderFrontRegardless()
        return (window, view)
    }

    @MainActor
    private func capture(_ view: TerminalView) throws -> CGImage {
        let done = expectation(description: "frame")
        var image: CGImage?
        view.metalFrameCapture = { image = $0; done.fulfill() }
        view.drawMetalFrameNow()
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(image)
    }

    /// Fraction of pixel rows `y` in `rows` where `image[y]` equals `reference[y + offset]`.
    private func rowsMatching(_ image: CGImage, _ reference: CGImage, offset: Int, rows: Range<Int>) -> Double {
        let a = pixels(image), b = pixels(reference), stride = image.width * 4
        let valid = rows.filter { $0 >= 0 && $0 + offset >= 0 && $0 + offset < reference.height && $0 < image.height }
        guard !valid.isEmpty else { return 0 }
        let equal = valid.filter { y in
            a[(y * stride)..<((y + 1) * stride)] == b[((y + offset) * stride)..<((y + offset + 1) * stride)]
        }.count
        return Double(equal) / Double(valid.count)
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }
}
