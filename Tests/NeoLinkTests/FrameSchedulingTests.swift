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
    func testDrawableConsumesNewestSurfaceStateWithoutWaitingForWindowClock() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let clock = ManualFrameClock()
        var visible = true
        let frames = WindowFrameScheduler(window: window, clockFactory: { _, _, tick in clock.tick = tick; return clock }, visibility: { visible })
        defer { frames.invalidate(); window.close() }
        let surface = NSObject(), other = NSObject(), id = ObjectIdentifier(surface)
        var requests = 0, order: [Int] = [], unrelated = 0
        frames.setDrawableDriver(id) { requests += 1 }
        for value in 0..<100 { frames.enqueue(from: id) { order.append(value) } }
        frames.enqueue(from: ObjectIdentifier(other)) { unrelated += 1 }
        XCTAssertTrue(order.isEmpty)
        XCTAssertEqual(requests, 100)
        frames.prepareDrawable(id) // Metal callback arrives before the CADisplayLink.
        XCTAssertEqual(order, Array(0..<100))
        XCTAssertEqual(unrelated, 0, "A drawable does not advance another surface")
        clock.fire()
        XCTAssertEqual(unrelated, 1)
        XCTAssertEqual(order.count, 100, "The window clock must not apply updates twice")
        frames.enqueue(from: id) { order.append(100) }
        frames.setDrawableDriver(id, wake: nil) // GPU/native toggle cannot lose pending work.
        XCTAssertEqual(order.last, 100)
        frames.setDrawableDriver(id) { requests += 1 }
        frames.enqueue(from: id) { order.append(101) }
        visible = false
        clock.fire() // Occlusion drains state even though no drawable will arrive.
        XCTAssertEqual(order.last, 101)
    }

    @MainActor
    func testSurfaceAnimationAdvancesOnlyWithItsDrawableAndSurvivesFallback() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let clock = ManualFrameClock()
        var visible = true
        let frames = WindowFrameScheduler(window: window, clockFactory: { _, _, tick in clock.tick = tick; return clock }, visibility: { visible })
        defer { frames.invalidate(); window.close() }
        let surface = NSObject(), animation = NSObject(), other = NSObject()
        let id = ObjectIdentifier(surface)
        var updates: [Double] = [], events: [String] = []
        frames.setDrawableDriver(id, wake: {})
        frames.animate(ObjectIdentifier(animation), surface: id) { time in
            events.append("animation"); updates.append(time); return time.isFinite
        }
        frames.enqueue(from: id) { events.append("output") }
        frames.noteInteraction(); clock.fire()
        XCTAssertTrue(updates.isEmpty, "The window clock must not consume a Metal animation early")
        frames.prepareDrawable(ObjectIdentifier(other), at: 7)
        XCTAssertTrue(updates.isEmpty, "Another drawable must not advance this surface")
        frames.prepareDrawable(id, at: 8)
        XCTAssertEqual(events, ["output", "animation"], "Parsed output precedes motion for the same drawable")
        XCTAssertEqual(updates, [8])
        frames.setDrawableDriver(id, wake: nil)
        clock.fire()
        XCTAssertEqual(updates.count, 2, "CoreGraphics fallback must retain the animation")
        visible = false; clock.fire()
        XCTAssertEqual(updates.last, .infinity)
        XCTAssertFalse(frames.hasDrawableAnimation(id))
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
        var tag: UInt64 = 0, presentations = 0
        frames.noteInteraction()
        frames.noteKeyInput(timestamp: time, surface: id)
        time += 0.001
        frames.enqueue(from: id) {
            frames.requestPresentation(id, outputAt: time) {
                presentations += 1; tag = frames.presentationTag
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(presentations, 1, "The echo must not wait for the next display callback")
        XCTAssertNotEqual(tag, 0)
        frames.framePresented(tag: tag, presentedTime: 100.012)
        XCTAssertEqual(frames.presentation.inputLatencies.count, 1)
        XCTAssertEqual(frames.presentation.inputLatencies.first ?? 0, 0.012, accuracy: 0.0001)

        // Prompt submission is independent of VSync; the renderer keeps display sync on.
        frames.requestPresentation(id, outputAt: time) { presentations += 1 }
        frames.noteKeyInput(timestamp: time, surface: id)
        clock.fire()
        XCTAssertEqual(presentations, 2)
    }

    @MainActor
    func testOnlyTheFocusedSurfacesOutputAnswersAKeyPressAndExpiredPressesAreCounted() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let clock = ManualFrameClock()
        var time = 50.0
        let frames = WindowFrameScheduler(window: window, clockFactory: { _, _, tick in clock.tick = tick; return clock },
                                          visibility: { true }, now: { time })
        defer { frames.invalidate() }
        let editor = NSObject(), agent = NSObject()
        let editorID = ObjectIdentifier(editor), agentID = ObjectIdentifier(agent)
        var agentTag: UInt64 = 0, immediate = 0
        frames.noteInteraction()
        frames.noteKeyInput(timestamp: time, surface: editorID)
        // An agent terminal streams output in the same window: it must not answer the key.
        frames.enqueue(from: agentID) {
            frames.requestPresentation(agentID, outputAt: time) { agentTag = frames.presentationTag; immediate += 1 }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(immediate, 0, "Unrelated output does not get an immediate frame")
        clock.fire()
        frames.framePresented(tag: agentTag, presentedTime: time + 0.02)
        XCTAssertEqual(frames.presentation.answeredInputs, 0)
        XCTAssertTrue(frames.presentation.inputLatencies.isEmpty)
        // The editor never answers; after 0.5 s the press is reported as unmatched.
        time += 0.6
        frames.noteKeyInput(timestamp: time, surface: editorID)
        XCTAssertEqual(frames.presentation.unmatchedInputs, 1)
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

/// Drives `SmoothScrollModel` with a program that answers every request at once, one wheel
/// report at a time like Neovim: by scrolling a full-width region, or (with `margins`) a
/// region inside left and right margins.
private struct ScrollSimulation {
    var model = SmoothScrollModel()
    var margins = false
    /// Lines toward the top: of trackpad input, and of the grid once every request applies.
    private(set) var input = 0.0, grid = 0.0
    private(set) var moves: [Int] = []
    /// Where the content is drawn, in the same units as `input`.
    var drawn: Double { grid + model.offset }
    static let range = -50.0...50.0

    mutating func scroll(_ lines: Double, at time: Double, phase: SmoothScrollModel.Phase = .changed) {
        input += lines
        answer(model.input(lines, at: time, phase: phase, range: Self.range), at: time)
    }

    /// One frame of the window clock; returns whether the model keeps animating.
    @discardableResult
    mutating func frame(at time: Double) -> Bool {
        let (active, move) = model.step(at: time, interval: 1.0 / 120, range: Self.range)
        answer(move, at: time)
        return active
    }

    private mutating func answer(_ move: Int, at time: Double) {
        guard move != 0 else { return }
        moves.append(move)
        grid += Double(move)
        for _ in 0..<abs(move) {
            if margins {
                model.gridStepped(move.signum(), at: time + 0.001)
            } else {
                model.gridMoved(move.signum(), at: time + 0.001, range: Self.range)
            }
        }
    }
}

final class SmoothScrollModelTests: XCTestCase {
    private let frame = 1.0 / 120

    func testGridMovesAheadOfTheTrackpadAndTheRendererDrawsTheRemainder() {
        var sim = ScrollSimulation()
        for event in 0..<60 {
            sim.scroll(-0.25, at: 1 + Double(event) * frame) // Toward the bottom, 30 lines per second.
            XCTAssertEqual(sim.drawn, sim.input, accuracy: 1e-9, "The content follows the fingers exactly")
            XCTAssertGreaterThanOrEqual(sim.model.offset, sim.model.lookahead - 1e-9,
                                        "The grid stays a speed-dependent margin ahead (event \(event))")
        }
        XCTAssertTrue(sim.moves.allSatisfy { $0 < 0 }, "Requests go only in the direction of travel")
        XCTAssertGreaterThan(sim.model.lookahead, 1, "30 lines per second keeps more than a line in hand")
    }

    func testLiftGlidesOnInTheDirectionOfTravelAndLandsOnALine() {
        var sim = ScrollSimulation()
        var time = 1.0
        for _ in 0..<30 { sim.scroll(-0.25, at: time); time += frame }
        let lifted = sim.input
        sim.scroll(0, at: time, phase: .ended)
        // Momentum may still follow: nothing moves for the first 30 ms.
        for _ in 0..<3 { time += frame; sim.frame(at: time); XCTAssertEqual(sim.drawn, lifted, accuracy: 1e-9) }
        var previous = sim.drawn, frames = 0
        repeat {
            time += frame; frames += 1
            let active = sim.frame(at: time)
            XCTAssertLessThanOrEqual(sim.drawn, previous + 1e-9, "Never moves back against the gesture")
            XCTAssertGreaterThan(sim.drawn, lifted - 1, "Glides less than a line past the fingers")
            previous = sim.drawn
            if !active { break }
        } while frames < 120
        XCTAssertLessThan(frames, 40, "At rest within a third of a second")
        XCTAssertEqual(sim.model.offset, 0)
        XCTAssertEqual(sim.model.pending, 0)
        XCTAssertEqual(sim.drawn, sim.grid, "Lands on a whole line")
    }

    func testMomentumContinuesTheGestureAndItsEndSettles() {
        var sim = ScrollSimulation()
        var time = 1.0
        for _ in 0..<10 { sim.scroll(0.3, at: time); sim.frame(at: time + 0.004); time += frame }
        sim.scroll(0, at: time, phase: .ended)
        for event in 0..<60 {
            time += frame
            sim.scroll(0.3 * pow(0.95, Double(event)), at: time, phase: .momentum)
            sim.frame(at: time + 0.004)
            XCTAssertFalse(sim.model.settling)
            XCTAssertEqual(sim.drawn, sim.input, accuracy: 1e-9, "Momentum is followed like the fingers")
        }
        time += frame
        sim.scroll(0, at: time, phase: .momentumEnded)
        var previous = sim.drawn, frames = 0
        while sim.frame(at: time) && frames < 120 {
            XCTAssertGreaterThanOrEqual(sim.drawn, previous - 1e-9, "Settles toward the top, the direction of travel")
            previous = sim.drawn; time += frame; frames += 1
        }
        XCTAssertEqual(sim.model.offset, 0)
        XCTAssertEqual(sim.drawn, sim.grid)
    }

    func testDirectionReversalsKeepFollowingTheFingers() {
        var sim = ScrollSimulation()
        var time = 1.0
        for _ in 0..<20 { sim.scroll(-0.4, at: time); time += frame }
        let movesBefore = sim.moves.count
        for _ in 0..<20 {
            sim.scroll(0.4, at: time); time += frame
            XCTAssertEqual(sim.drawn, sim.input, accuracy: 1e-9)
        }
        XCTAssertGreaterThan(sim.moves.count, movesBefore)
        XCTAssertTrue(sim.moves[movesBefore...].allSatisfy { $0 > 0 }, "After the reversal the grid moves the new way")
    }

    func testDirectionReversalResetsVelocityWithoutDeadband() {
        var model = SmoothScrollModel()
        _ = model.input(-0.4, at: 1.0, range: -10...10)
        _ = model.input(-0.4, at: 1.0 + frame, range: -10...10)
        XCTAssertLessThan(model.velocity, 0)
        _ = model.input(0.4, at: 1.0 + 2 * frame, range: -10...10)
        XCTAssertGreaterThan(model.velocity, 0, "Reversal must drop opposing velocity immediately to eliminate deadband")
    }

    func testRequestsAProgramIgnoresExpireAndProgramScrollsOutsideAGestureSnap() {
        var model = SmoothScrollModel()
        // At the top of a file the program never scrolls up and writes nothing.
        let requested = model.input(0.5, at: 1.0, range: 0...0)
        XCTAssertGreaterThan(requested, 0)
        XCTAssertEqual(model.pending, requested)
        var time = 1.2, frames = 0
        while model.step(at: time, interval: frame, range: 0...0).active && frames < 60 { time += frame; frames += 1 }
        XCTAssertEqual(model.pending, 0)
        XCTAssertEqual(model.offset, 0, "Bounded by the lines that can be drawn")
        XCTAssertFalse(model.stepping, "Silence means the request was ignored, not answered by a redraw")
        // A keyboard-driven scroll long after the gesture is shown as is.
        model.gridMoved(3, at: 5.0, range: -3...0)
        XCTAssertEqual(model.offset, 0)
    }

    func testScrollsWithinMarginsAreFollowedInWholeLinesWithoutOverscrolling() {
        var sim = ScrollSimulation()
        sim.margins = true // One window of a side-by-side split.
        var time = 1.0
        for _ in 0..<40 {
            sim.scroll(-0.3, at: time); time += frame
            XCTAssertEqual(sim.model.offset, 0, "A region inside margins is never drawn offset")
        }
        XCTAssertTrue(sim.model.stepping)
        XCTAssertEqual(sim.grid, sim.input, accuracy: 0.5 + 1e-9, "Ends within half a line of the fingers")
        XCTAssertTrue(sim.moves.allSatisfy { $0 < 0 }, "No request against the fingers")
        // The next gesture steps from its start: one line per line of input.
        while sim.frame(at: time), time < 5 { time += frame }
        time += 1
        sim.model.beginGesture()
        let start = (input: sim.input, grid: sim.grid)
        for _ in 0..<40 {
            sim.scroll(-0.3, at: time); time += frame
            XCTAssertEqual(sim.grid - start.grid, sim.input - start.input, accuracy: 0.5 + 1e-9)
        }
        // Once the program answers with a full-width region again, gestures are smooth.
        sim.margins = false
        sim.scroll(-1.5, at: time)
        while sim.frame(at: time), time < 10 { time += frame }
        sim.model.beginGesture()
        XCTAssertFalse(sim.model.stepping)
    }

    func testAProgramThatRedrawsIsFollowedInWholeLines() {
        var model = SmoothScrollModel()
        var input = -0.3, requested = model.input(-0.3, at: 1.0, range: 0...0)
        XCTAssertLessThan(requested, 0)
        model.noteOutput(40_000) // A full-screen redraw, with no region scroll.
        var time = 1.15
        for _ in 0..<30 {
            input -= 0.3
            requested += model.input(-0.3, at: time, range: 0...0)
            XCTAssertEqual(model.offset, 0)
            time += frame
        }
        XCTAssertTrue(model.stepping)
        XCTAssertTrue(model.answersInSteps)
        XCTAssertEqual(Double(requested), input, accuracy: 0.5 + 1e-9, "One line requested per line of input")
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

    @MainActor
    func testScrollsWithinLeftAndRightMarginsAreReportedSeparately() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var fullWidth: [Int] = [], withinMargins: [Int] = []
        view.programScrolled = { fullWidth.append($0) }
        view.programScrolledWithinMargins = { withinMargins.append($0) }
        view.feed(text: "\u{1B}[?1049h\u{1B}[2J\u{1B}[H" + (1...20).map { "line \($0)" }.joined(separator: "\r\n"))
        // Like Neovim scrolling the left window of a vertical split.
        view.feed(text: "\u{1B}[?69h\u{1B}[1;20s\u{1B}[1;10r\u{1B}[1;1H\u{1B}[M")
        view.feed(text: "\u{1B}[1;1H\u{1B}[2L")
        view.feed(text: "\u{1B}[S\u{1B}[T")
        view.feed(text: "\u{1B}[3;1H\u{1B}[M")     // Below the region's top: an edit, not a scroll.
        view.feed(text: "\u{1B}[s\u{1B}[r\u{1B}[?69l\u{1B}[H\u{1B}[M")
        XCTAssertEqual(withinMargins, [1, -2, 1, -1])
        XCTAssertEqual(fullWidth, [1], "Only the full-width scroll after margins are reset")
    }
}
