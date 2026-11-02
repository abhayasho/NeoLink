import AppKit
import XCTest
import SwiftTerm
@testable import NeoLink

@MainActor
private final class ManualFrameClock: FrameClock {
    var tick: (() -> Void)?
    var running = false
    var starts = 0
    func start() { running = true; starts += 1 }
    func stop() { running = false }
    func invalidate() { running = false; tick = nil }
    func fire() { if running { tick?() } }
}

final class FrameSchedulingTests: XCTestCase {
    func testTargetRespectsSlowerDisplaysAndCapsHighRefreshAt120() {
        XCTAssertEqual(WindowFrameScheduler.rate(for: 60), 60)
        XCTAssertEqual(WindowFrameScheduler.rate(for: 120), 120)
        XCTAssertEqual(WindowFrameScheduler.rate(for: 144), 120)
        XCTAssertEqual(WindowFrameScheduler.rate(for: 0), 1)
    }

    @MainActor
    func testFrameCoalescesPresentationAfterAllStateUpdatesAndStopsAtIdle() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let clock = ManualFrameClock()
        var time = 10.0
        let frames = WindowFrameScheduler(window: window, clockFactory: { _, _, tick in clock.tick = tick; return clock }, visibility: { true }, now: { time })
        defer { frames.invalidate(); window.close() }
        var updates = 0, presentations = 0
        let surface = NSObject(), id = ObjectIdentifier(surface)
        frames.register(id, sample: { nil })
        frames.noteInteraction()
        for _ in 0..<100 {
            frames.enqueue {
                updates += 1
                frames.requestPresentation(id) { XCTAssertEqual(updates, 100); presentations += 1 }
            }
        }
        XCTAssertEqual(clock.starts, 1)
        XCTAssertEqual(updates, 0)
        clock.fire()
        XCTAssertEqual(updates, 100)
        XCTAssertEqual(presentations, 1, "A burst must submit one drawable per surface, after the newest state")
        time += 1.0 / 120
        clock.fire()
        XCTAssertEqual(presentations, 1, "An unchanged surface is not presented again; a repeat would queue ahead of the next real frame")
        time += 1.1
        clock.fire()
        XCTAssertFalse(clock.running)
        XCTAssertFalse(frames.isRunning)
        frames.enqueue { updates += 1 }
        XCTAssertTrue(clock.running)
        clock.fire()
        XCTAssertEqual(updates, 101)
        frames.unregister(id)
    }

    @MainActor
    func testBackgroundAndUnavailableClocksDrainWorkWithoutAnimationLoop() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let clock = ManualFrameClock()
        var visible = false, updates = 0
        let frames = WindowFrameScheduler(window: window, clockFactory: { _, _, tick in clock.tick = tick; return clock }, visibility: { visible })
        defer { frames.invalidate() }
        frames.enqueue { updates += 1 }
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(updates, 1)
        XCTAssertFalse(clock.running)
        visible = true
        frames.noteInteraction()
        XCTAssertTrue(clock.running)
        visible = false
        frames.enqueue { updates += 1 }
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(updates, 2)
        XCTAssertFalse(clock.running)

        let unavailable = WindowFrameScheduler(window: window, clockFactory: { _, _, _ in nil }, visibility: { true })
        defer { unavailable.invalidate() }
        unavailable.enqueue { updates += 1 }
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(updates, 3)
        XCTAssertFalse(unavailable.isRunning)
    }

    func testFrameStatisticsExcludeIdleGapsAndReportLateIntervals() {
        var timing = FrameTiming()
        for i in 0..<120 { timing.record(timestamp: Double(i) / 120, work: 0.002) }
        XCTAssertEqual(timing.cadence, 120, accuracy: 0.01)
        XCTAssertEqual(timing.p95WorkMilliseconds, 2, accuracy: 0.01)
        XCTAssertEqual(timing.lateIntervals(target: 120), 0)
        timing.pause()
        timing.record(timestamp: 10, work: 0.001)
        XCTAssertEqual(timing.cadence, 120, accuracy: 0.01)
        timing.record(timestamp: 10.03, work: 0.001)
        XCTAssertEqual(timing.lateIntervals(target: 120), 1)
    }
}

final class InputLatencySchedulingTests: XCTestCase {
    @MainActor
    func testOutputAnsweringAKeyPressIsPresentedWithoutWaitingForTheClock() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let clock = ManualFrameClock()
        var time = 100.0
        let frames = WindowFrameScheduler(window: window, clockFactory: { _, _, tick in clock.tick = tick; return clock },
                                          visibility: { true }, now: { time })
        defer { frames.invalidate() }
        let surface = NSObject(), id = ObjectIdentifier(surface)
        var tag: UInt64 = 0, bypass = false, presentations = 0
        frames.noteInteraction()
        frames.noteKeyInput(timestamp: time)
        time += 0.001
        frames.enqueue {
            frames.requestPresentation(id, outputAt: time) {
                presentations += 1; tag = frames.presentationTag; bypass = frames.presentationMayBypassVsync
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(presentations, 1, "The echo must not wait for the next display callback")
        XCTAssertNotEqual(tag, 0)
        XCTAssertTrue(bypass, "A sparse frame answering a key press may skip the vsync wait")
        frames.framePresented(tag: tag, presentedTime: 100.012)
        XCTAssertEqual(frames.presentation.inputLatencies.count, 1)
        XCTAssertEqual(frames.presentation.inputLatencies.first ?? 0, 0.012, accuracy: 0.0001)

        // A second frame within 1.5 refresh intervals keeps vsync, so neither is dropped.
        frames.requestPresentation(id, outputAt: time) { bypass = frames.presentationMayBypassVsync }
        frames.noteKeyInput(timestamp: time)
        clock.fire()
        XCTAssertFalse(bypass)
    }

    @MainActor
    func testAnimationsStepEveryFrameAndKeepTheClockRunningUntilTheyFinish() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let clock = ManualFrameClock()
        var time = 10.0
        let frames = WindowFrameScheduler(window: window, clockFactory: { _, _, tick in clock.tick = tick; return clock },
                                          visibility: { true }, now: { time })
        defer { frames.invalidate() }
        var steps = 0
        frames.animate(ObjectIdentifier(self)) { _ in steps += 1; return steps < 3 }
        for _ in 0..<5 { time += 0.2; clock.fire() }
        XCTAssertEqual(steps, 3)
        XCTAssertFalse(clock.running, "The clock stops once the animation ends and nothing else is pending")
    }
}

final class SmoothScrollModelTests: XCTestCase {
    func testGridMovesAheadOfTheTrackpadAndTheRendererDrawsTheRemainder() {
        var model = SmoothScrollModel()
        // Scrolling down (toward the bottom) by 0.3 lines asks the grid for one whole line.
        XCTAssertEqual(model.input(-0.3, at: 1.0, range: 0...0), -1)
        XCTAssertEqual(model.offset, -0.3, accuracy: 1e-9)
        // The program scrolled; one retained line is now available above the region.
        model.gridMoved(-1, at: 1.002, range: 0...1)
        XCTAssertEqual(model.offset, 0.7, accuracy: 1e-9, "Drawn 0.7 lines lower than the moved grid: 0.3 lines below the start")
        XCTAssertEqual(model.pending, 0)
        XCTAssertEqual(model.input(-0.5, at: 1.010, range: 0...1), 0, "Still inside the requested line")
        XCTAssertEqual(model.input(-0.4, at: 1.020, range: 0...1), -1)
    }

    func testOffsetEasesOutAfterInputStops() {
        var model = SmoothScrollModel()
        _ = model.input(0.4, at: 1.0, range: -1...0)
        model.gridMoved(1, at: 1.001, range: -1...0)
        XCTAssertEqual(model.offset, -0.6, accuracy: 1e-9)
        XCTAssertTrue(model.step(at: 1.02, interval: 1.0 / 120, range: -1...0), "No easing while input continues")
        XCTAssertEqual(model.offset, -0.6, accuracy: 1e-9)
        var time = 1.06, frames = 0
        while model.step(at: time, interval: 1.0 / 120, range: -1...0) { time += 1.0 / 120; frames += 1 }
        XCTAssertEqual(model.offset, 0)
        XCTAssertLessThan(frames, 30, "Settles within a quarter second at 120 Hz")
    }

    func testRequestsAProgramIgnoresExpireAndProgramScrollsOutsideAGestureSnap() {
        var model = SmoothScrollModel()
        // At the top of a file the program never scrolls up; the offset stays bounded.
        XCTAssertEqual(model.input(0.5, at: 1.0, range: 0...0), 1)
        XCTAssertLessThanOrEqual(model.offset, 1)
        _ = model.step(at: 1.2, interval: 1.0 / 120, range: 0...0)
        XCTAssertEqual(model.pending, 0)
        XCTAssertEqual(model.offset, 0)
        // A keyboard-driven scroll long after the gesture is shown as is.
        model.gridMoved(3, at: 5.0, range: -3...0)
        XCTAssertEqual(model.offset, 0)
    }
}

final class ProgramScrollObservationTests: XCTestCase {
    @MainActor
    func testFullScreenRegionScrollsAreReportedInLines() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var reported: [Int] = []
        view.programScrolled = { reported.append($0) }
        view.feed(text: "\u{1B}[?1049h\u{1B}[2J\u{1B}[H" + (1...20).map { "line \($0)" }.joined(separator: "\r\n"))
        view.feed(text: "\u{1B}[H\u{1B}[M")        // Delete one line at the top: content moves up.
        view.feed(text: "\u{1B}[H\u{1B}[2L")       // Insert two lines at the top: content moves down.
        view.feed(text: "\u{1B}[3S\u{1B}[T")       // Scroll up three, down one.
        view.feed(text: "\u{1B}[5;1H\u{1B}[M")     // Deleting below the top edits text; not a scroll.
        XCTAssertEqual(reported, [1, -2, 3, -1])
    }
}
