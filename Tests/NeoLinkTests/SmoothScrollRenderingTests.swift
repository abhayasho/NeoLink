import AppKit
import Metal
import XCTest
import SwiftTerm
@testable import NeoLink

/// Renders with SwiftTerm's Metal renderer and compares frames pixel by pixel.
final class SmoothScrollRenderingTests: XCTestCase {
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
