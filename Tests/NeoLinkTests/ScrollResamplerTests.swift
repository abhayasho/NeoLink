import XCTest
@testable import NeoLink

final class ScrollResamplerTests: XCTestCase {
    /// Events (time, lines) arrive in time order; the display draws every `frame` seconds. Returns the drawn
    /// position (total input minus the undrawn lag) after each frame.
    private func simulate(inputs: [(Double, Double)], frame: Double, until end: Double) -> (drawn: [Double], total: Double, finalLag: Double) {
        var resampler = ScrollResampler()
        var total = 0.0, drawn: [Double] = [], next = 0, index = 0
        while Double(index) * frame <= end {
            let time = Double(index) * frame
            while next < inputs.count, inputs[next].0 <= time { resampler.input(inputs[next].1, at: inputs[next].0); total += inputs[next].1; next += 1 }
            resampler.advance(to: time)
            drawn.append(total - resampler.lag)
            index += 1
        }
        return (drawn, total, resampler.lag)
    }

    private func deltas(_ values: [Double]) -> [Double] { zip(values.dropFirst(), values).map { $0 - $1 } }

    func testSixtyHertzInputOnA120HertzDisplayMovesEveryFrameUniformly() {
        let inputs = (0..<120).map { (Double($0) / 60, 0.4) }   // two seconds of steady input at 60 Hz
        let frame = 1.0 / 120
        let raw = (0..<180).map { index in inputs.filter { $0.0 <= Double(index) * frame + 1e-9 }.reduce(0) { $0 + $1.1 } }
        let rawSteps = Array(deltas(raw).dropFirst(60).prefix(100))
        let steps = Array(deltas(simulate(inputs: inputs, frame: frame, until: 1.5).drawn).dropFirst(60).prefix(100))
        XCTAssertEqual(rawSteps.filter { $0 == 0 }.count, 50, "unfiltered input repeats every other frame")
        XCTAssertEqual(steps.filter { $0 <= 0 }.count, 0, "every display frame moves")
        XCTAssertLessThan(steps.max()! / steps.min()!, 1.15, "steady input is drawn as uniform motion")
    }

    func testJitteredEventTimesStillDrawEvenly() {
        // 60 Hz with up to +/-3 ms of arrival jitter (deterministic pattern).
        let jitter = [0.0, 0.003, -0.002, 0.001, -0.003, 0.002, 0.0, -0.001]
        var inputs: [(Double, Double)] = []
        for index in 0..<120 {
            let time: Double = Double(index) / 60.0 + jitter[index % jitter.count] + 0.004
            inputs.append((time, 0.4))
        }
        inputs.sort { $0.0 < $1.0 }
        let steps = Array(deltas(simulate(inputs: inputs, frame: 1.0 / 120, until: 1.5).drawn).dropFirst(60).prefix(100))
        XCTAssertEqual(steps.filter { $0 <= 0 }.count, 0)
        XCTAssertLessThan(steps.max()! / steps.min()!, 1.7, "alternating arrival delays of 6 ms change the slope of each segment; the raw pattern is 0 and 2x")
    }

    func testDrawnPositionNeverOvershootsOrReversesAndTrailsByAboutOneInputInterval() {
        let inputs = (0..<30).map { (Double($0) / 60, 1.0) }
        let run = simulate(inputs: inputs, frame: 1.0 / 120, until: 1.0)
        XCTAssertTrue(deltas(run.drawn).allSatisfy { $0 >= -1e-9 }, "monotone input is drawn monotonically")
        XCTAssertTrue(run.drawn.allSatisfy { $0 <= run.total + 1e-9 }, "never ahead of the fingers")
        XCTAssertEqual(run.drawn.last!, run.total, accuracy: 1e-6)
        let settled = run.drawn.firstIndex { run.total - $0 < 0.001 }!
        XCTAssertLessThan(Double(settled) / 120 - 29.0 / 60, 0.04, "reaches the last position within the bounded delay after the last event")
    }

    func testReversalFollowsTheFingersWithoutOvershoot() {
        var inputs: [(Double, Double)] = []
        for index in 0..<40 { inputs.append((Double(index) / 60.0, index < 20 ? 0.5 : -0.5)) }
        let run = simulate(inputs: inputs, frame: 1.0 / 120, until: 1.0)
        let peak = run.drawn.max()!
        XCTAssertLessThanOrEqual(peak, 10.0 + 1e-9, "never beyond the farthest input position")
        XCTAssertEqual(run.drawn.last!, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(peak, 9.0)
    }

    func testOneBigEventBecomesAShortGlideAndDelayIsBounded() {
        var resampler = ScrollResampler()
        resampler.input(3, at: 0)
        var frames = 0
        var time = 0.0
        while resampler.advance(to: time) { time += 1.0 / 120; frames += 1; if frames > 60 { break } }
        XCTAssertGreaterThan(frames, 1, "the jump is spread over several frames")
        XCTAssertLessThan(frames, 8)
        XCTAssertLessThanOrEqual(resampler.delay, ScrollResampler.maximumDelay)
        XCTAssertGreaterThanOrEqual(resampler.delay, ScrollResampler.minimumDelay * 0.5)
    }

    func testResetDropsTheUndrawnRemainder() {
        var resampler = ScrollResampler()
        resampler.input(2, at: 0)
        resampler.reset()
        XCTAssertEqual(resampler.lag, 0)
        XCTAssertFalse(resampler.isCatchingUp)
        XCTAssertFalse(resampler.advance(to: 0.01))
    }

    func testInputBeyondAnEndIsForgottenSoReversingDoesNotJump() {
        var resampler = ScrollResampler()
        var total = 0.0, position = 0.0, maximum = 0.0, time = 0.0, largestStep = 0.0, previous = 0.0
        for event in 0..<40 {
            let lines = event < 20 ? 1.0 : -1.0
            let eventTime = Double(event) / 60
            while time <= eventTime { resampler.advance(to: time); time += 1.0 / 120 }
            resampler.input(lines, at: eventTime)
            total += lines; position += lines
            if position > 10 { resampler.absorb(10 - position, at: eventTime); position = 10 }   // the content ends at 10
            maximum = max(maximum, position)
            let drawn = position - resampler.lag
            largestStep = max(largestStep, abs(drawn - previous)); previous = drawn
        }
        XCTAssertLessThanOrEqual(maximum, 10)
        XCTAssertLessThan(largestStep, 2.5, "no jump when the direction reverses after pushing against the end")
        _ = total
    }

    func testInputAtTheDisplayRateTrailsByAFewMillisecondsOnly() {
        var resampler = ScrollResampler()
        for event in 0..<30 { resampler.input(0.5, at: Double(event) / 120) }
        XCTAssertLessThan(resampler.delay, 0.008, "120 Hz input on a 120 Hz display is not delayed by a whole interval")
        let slow = { () -> Double in
            var r = ScrollResampler()
            for event in 0..<30 { r.input(0.5, at: Double(event) / 60) }
            return r.delay
        }()
        XCTAssertGreaterThan(slow, 0.02, "60 Hz input interpolates across a full interval")
    }
}
