import AppKit
import XCTest
import SwiftTerm
@testable import NeoLink

/// Program output reaches the terminal complete and in order, and the parser gives the same
/// result wherever a read boundary falls.
final class TerminalOutputDeliveryTests: XCTestCase {
    private final class OutputRecorder: @unchecked Sendable {
        let lock = NSLock()
        let received = DispatchSemaphore(value: 0)
        let admitted = DispatchSemaphore(value: 0)
        var events: [(LocalProcess.OutputEvent, Bool)] = []
        func record(_ event: LocalProcess.OutputEvent) {
            lock.lock(); events.append((event, Thread.isMainThread)); lock.unlock()
            if event.stage == .received { received.signal() }
            if event.stage == .admitted { admitted.signal() }
        }
        var snapshot: [(LocalProcess.OutputEvent, Bool)] {
            lock.lock(); defer { lock.unlock() }; return events
        }
    }

    func testOwningDeadlineCanServiceQueuedOutputWithoutDoubleDelivery() {
        let collector = Collector(), recorder = OutputRecorder()
        let process = LocalProcess(delegate: collector)
        process.outputEventHandler = { recorder.record($0) }
        let done = expectation(description: "printf finished")
        collector.terminated = done
        process.startProcess(executable: "/usr/bin/printf", args: ["deadline é 😀"])
        XCTAssertEqual(recorder.admitted.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(collector.received.isEmpty, "The queued main block has not run")
        process.servicePendingOutput()
        XCTAssertEqual(String(decoding: collector.received, as: UTF8.self), "deadline é 😀")
        // The original queue block and further deadline latches must be harmless.
        process.servicePendingOutput()
        wait(for: [done], timeout: 5)
        process.servicePendingOutput()
        XCTAssertEqual(String(decoding: collector.received, as: UTF8.self), "deadline é 😀")
        XCTAssertEqual(recorder.snapshot.filter { $0.0.stage == .delivered }.count,
                       recorder.snapshot.filter { $0.0.stage == .received }.count)
    }

    func testTransportReceiptIsRecordedBeforeMainQueueDeliveryAndRetainsChunkIdentity() {
        let collector = Collector(), recorder = OutputRecorder()
        let process = LocalProcess(delegate: collector)
        process.outputEventHandler = { recorder.record($0) }
        let done = expectation(description: "printf finished")
        collector.terminated = done
        process.startProcess(executable: "/usr/bin/printf", args: ["héllo 😀"])
        // Hold the delivery queue. A main-thread-only receipt probe cannot see
        // this data yet; the PTY reader must already report it independently.
        XCTAssertEqual(recorder.received.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(collector.received.isEmpty)
        wait(for: [done], timeout: 5)
        let deadline = Date(timeIntervalSinceNow: 2)
        while collector.received.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertEqual(String(decoding: collector.received, as: UTF8.self), "héllo 😀")
        let events = recorder.snapshot
        let groups = Dictionary(grouping: events, by: { $0.0.chunk })
        XCTAssertFalse(groups.isEmpty)
        for unsorted in groups.values {
            let group = unsorted.sorted { $0.0.uptimeNanoseconds < $1.0.uptimeNanoseconds }
            XCTAssertEqual(group.map { $0.0.stage }, [.received, .admitted, .delivered, .parsed])
            XCTAssertEqual(Set(group.map { $0.0.bytes }).count, 1)
            XCTAssertFalse(group[0].1)
            XCTAssertTrue(group[2].1)
            XCTAssertTrue(group[3].1)
            XCTAssertEqual(group.map { $0.0.uptimeNanoseconds }, group.map { $0.0.uptimeNanoseconds }.sorted())
        }
    }
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
