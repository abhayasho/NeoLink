import AppKit
import XCTest
import SwiftTerm
@testable import NeoLink

/// Program output reaches the terminal complete and in order, and the parser gives the same
/// result wherever a read boundary falls.
final class TerminalOutputDeliveryTests: XCTestCase {
    private final class Collector: LocalProcessDelegate {
        var received: [UInt8] = []
        var largestSlice = 0
        var terminated: XCTestExpectation?
        func processTerminated(_ source: LocalProcess, exitCode: Int32?) { terminated?.fulfill() }
        func dataReceived(slice: ArraySlice<UInt8>) {
            dispatchPrecondition(condition: .onQueue(.main))
            received.append(contentsOf: slice)
            largestSlice = max(largestSlice, slice.count)
        }
        func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
    }

    func testLargeOutputIsDeliveredCompleteAndInOrderOnTheMainQueue() throws {
        // Multi-byte characters, no newlines (the pty would turn them into CR LF).
        let unit = Array("héllo wörld こんにちは 😀 \u{1B}[31mred\u{1B}[0m ".utf8)
        var expected: [UInt8] = []
        while expected.count < 2 * 1024 * 1024 { expected += unit }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("neolink-delivery-\(UUID().uuidString)")
        try Data(expected).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let collector = Collector()
        let done = expectation(description: "cat finished")
        collector.terminated = done
        let process = LocalProcess(delegate: collector)
        process.startProcess(executable: "/bin/cat", args: [file.path])
        wait(for: [done], timeout: 20)
        // Output read before the exit may still be queued for the main thread.
        let deadline = Date(timeIntervalSinceNow: 5)
        while collector.received.count < expected.count && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertEqual(collector.received.count, expected.count)
        XCTAssertTrue(collector.received == expected, "Every byte arrives, in order")
        // A pty read returns at most 1 KiB on macOS, so no single delivery holds the main
        // thread for long (about 0.1 ms to parse).
        XCTAssertLessThanOrEqual(collector.largestSlice, 128 * 1024)
    }

    @MainActor
    func testScrollNotificationsAreCoalescedPerMainQueueTurn() {
        final class Observer: TerminalViewDelegate {
            var positions: [Double] = []
            func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
            func setTerminalTitle(source: TerminalView, title: String) {}
            func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
            func send(source: TerminalView, data: ArraySlice<UInt8>) {}
            func scrolled(source: TerminalView, position: Double) { positions.append(position) }
            func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        }
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let observer = Observer()
        view.terminalDelegate = observer
        view.feed(text: (1...500).map { "output line \($0)" }.joined(separator: "\r\n"))
        XCTAssertTrue(observer.positions.isEmpty, "Not once per line while parsing")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(observer.positions, [1], "Once, with the final position (the bottom)")
    }

    @MainActor
    func testSlicesSplitInsideCharactersAndEscapeSequencesParseLikeOneFeed() {
        let text = Array("é😀\u{1B}[1;31mbold red\u{1B}[0m こんにちは\r\nnext line ✓".utf8)
        let whole = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        whole.feed(byteArray: text[...])
        let expected = (0..<2).map { whole.getTerminal().getLine(row: $0)?.translateToString(trimRight: true) }
        for split in 1..<text.count {
            let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
            view.feed(byteArray: text[..<split])
            view.feed(byteArray: text[split...])
            let lines = (0..<2).map { view.getTerminal().getLine(row: $0)?.translateToString(trimRight: true) }
            XCTAssertEqual(lines, expected, "Split at byte \(split)")
            XCTAssertEqual(view.getTerminal().getCharData(col: 2, row: 0)?.attribute,
                           whole.getTerminal().getCharData(col: 2, row: 0)?.attribute)
        }
    }
}
