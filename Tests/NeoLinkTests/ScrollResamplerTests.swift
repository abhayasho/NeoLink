import XCTest
@testable import NeoLink

final class ScrollResamplerTests: XCTestCase {
    /// Events (time, lines) arrive in time order; the display draws every `frame` seconds. Returns the drawn
    /// position (total input minus the undrawn lag) after each frame.
    private func simulate(inputs: [(Double, Double)], frame: Double, until end: Double,
                          mode: ScrollResampler.Mode = .classic) -> (drawn: [Double], total: Double, finalLag: Double) {
        var resampler = ScrollResampler()
        resampler.mode = mode
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
        resampler.mode = .classic
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
        resampler.mode = .classic
        resampler.input(2, at: 0)
        resampler.reset()
        XCTAssertEqual(resampler.lag, 0)
        XCTAssertFalse(resampler.isCatchingUp)
        XCTAssertFalse(resampler.advance(to: 0.01))
    }

    func testInputBeyondAnEndIsForgottenSoReversingDoesNotJump() {
        var resampler = ScrollResampler()
        resampler.mode = .classic
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
        resampler.mode = .classic
        for event in 0..<30 { resampler.input(0.5, at: Double(event) / 120) }
        XCTAssertLessThan(resampler.delay, 0.008, "120 Hz input on a 120 Hz display is not delayed by a whole interval")
        let slow = { () -> Double in
            var r = ScrollResampler(); r.mode = .classic
            for event in 0..<30 { r.input(0.5, at: Double(event) / 60) }
            return r.delay
        }()
        XCTAssertGreaterThan(slow, 0.02, "60 Hz input interpolates across a full interval")
    }

    /// A fast gesture (120 Hz) followed at once by a slower stream (60 Hz: a slowing finger, or momentum). The
    /// slower stream must still move every display frame: its rate is measured even though the drawn position
    /// catches up between its events at first.
    func testAfterAFastGestureASlowerStreamStillMovesEveryFrame() {
        var inputs: [(Double, Double)] = []
        for index in 0..<60 { inputs.append((Double(index) / 120, 0.25)) }
        for index in 0..<90 { inputs.append((0.5 + Double(index) / 60, 0.5)) }
        let steps = deltas(simulate(inputs: inputs, frame: 1.0 / 120, until: 1.9).drawn)
        let slow = Array(steps[(Int(0.65 * 120))..<(Int(1.9 * 120) - 12)])
        XCTAssertEqual(slow.filter { $0 <= 1e-9 }.count, 0, "every refresh moves once the slower rate is measured")
        XCTAssertLessThan(slow.max()! / slow.min()!, 1.3)
    }

    /// Input between the display's rate and half of it (here 80 Hz with arrival jitter) used to flip between two
    /// delays and hold frames. The delay is continuous in the rate, so it is drawn without a held frame.
    func testInputBetweenTheDisplayRateAndHalfOfItIsDrawnWithoutHolds() {
        let jitter = [0.0, 0.001, -0.001, 0.0005, -0.0005]
        var inputs: [(Double, Double)] = []
        for index in 0..<160 {
            let time: Double = Double(index) / 80 + 0.002 + jitter[index % jitter.count]
            inputs.append((time, 0.3))
        }
        let steps = Array(deltas(simulate(inputs: inputs, frame: 1.0 / 120, until: 1.9).drawn).dropFirst(40).prefix(170))
        XCTAssertEqual(steps.filter { $0 <= 1e-9 }.count, 0)
        XCTAssertLessThan(steps.max()! / steps.min()!, 2.0)
    }

    func testTheDelayIsAContinuousFunctionOfTheInputRate() {
        var previous: Double?
        for tenth in 41...300 {   // gaps under 4 ms are one report split in two, not a rate
            var resampler = ScrollResampler()
        resampler.mode = .classic
            let gap = Double(tenth) / 10_000
            for event in 0..<80 { resampler.input(0.1, at: Double(event) * gap) }
            if let previous { XCTAssertLessThan(abs(resampler.delay - previous), 0.0005, "no jump at \(gap * 1000) ms") }
            previous = resampler.delay
        }
    }

    /// The switch from a fast to a slow stream at the same speed (finger to momentum) changes the delay. The first
    /// long gap cannot be known in advance (the drawn content reaches the last event and waits, as before); after
    /// it, the content moves forward every frame while the delay grows, at no less than about half its speed.
    func testAChangeOfRateNeverDrawsBackwardsAndRecoversAtOnce() {
        var inputs: [(Double, Double)] = []
        for index in 0..<60 { inputs.append((Double(index) / 120, 0.2)) }
        for index in 0..<60 { inputs.append((59.0 / 120 + Double(index + 1) / 60, 0.4)) }
        let steps = deltas(simulate(inputs: inputs, frame: 1.0 / 120, until: 1.4).drawn)
        XCTAssertTrue(steps.allSatisfy { $0 >= -1e-9 }, "never backwards")
        let afterSecondSlowEvent = Int((59.0 / 120 + 2.0 / 60) * 120) + 1
        let slow = Array(steps[afterSecondSlowEvent..<(Int(1.4 * 120) - 20)])
        XCTAssertTrue(slow.allSatisfy { $0 > 0 }, "forward every frame")
        XCTAssertGreaterThan(slow.min()!, 0.2 * 0.45, "at least about half the input's speed per frame")
    }

    // MARK: Low-latency modes (`adaptive`, `predict`)

    /// Total input delivered by each frame time (what "no delay at all" would draw).
    private func raw(_ inputs: [(Double, Double)], frame: Double, count: Int) -> [Double] {
        (0..<count).map { index in inputs.filter { $0.0 <= Double(index) * frame + 1e-9 }.reduce(0) { $0 + $1.1 } }
    }

    func testTheFirstEventOfAGestureIsDrawnAtOnceOutsideClassic() {
        for mode in [ScrollResampler.Mode.adaptive, .predict] {
            var resampler = ScrollResampler()
            resampler.mode = mode
            resampler.input(0.25, at: 10)
            XCTAssertEqual(resampler.lag, 0, "\(mode): nothing earlier to interpolate from")
        }
        var classic = ScrollResampler()
        classic.mode = .classic
        classic.input(0.25, at: 10)
        XCTAssertEqual(classic.lag, 0.25, accuracy: 1e-9, "classic ramps the first event in")
    }

    func testAdaptiveMarginFollowsMeasuredJitterAndNeverExceedsTheFixedOne() {
        var clean = ScrollResampler(), noisy = ScrollResampler()
        clean.mode = .adaptive; noisy.mode = .adaptive
        let jitter = [0.0, 0.004, -0.004, 0.003, -0.003, 0.004, -0.002, 0.002]
        for index in 0..<120 {
            clean.input(0.3, at: Double(index) / 60)
            noisy.input(0.3, at: Double(index) / 60 + 0.005 + jitter[index % jitter.count])
        }
        XCTAssertEqual(clean.jitterAllowance, ScrollResampler.minimumJitterMargin, accuracy: 0.0005)
        XCTAssertGreaterThan(noisy.jitterAllowance, 0.0045)
        XCTAssertLessThanOrEqual(noisy.jitterAllowance, ScrollResampler.jitterMargin)
        XCTAssertLessThan(clean.delay, 1.0 / 60 + 0.003, "clean 60 Hz input trails by an interval plus about 2 ms, not 6")
    }

    func testAdaptiveAndPredictStillMoveEveryFrameAtSixtyAndEightyHertz() {
        for mode in [ScrollResampler.Mode.adaptive, .predict] {
            for rate in [60.0, 80.0] {
                let inputs = (0..<Int(2 * rate)).map { (Double($0) / rate, 0.4) }
                let steps = Array(deltas(simulate(inputs: inputs, frame: 1.0 / 120, until: 1.5, mode: mode).drawn).dropFirst(80).prefix(90))
                XCTAssertEqual(steps.filter { $0 <= 0 }.count, 0, "\(mode) at \(rate) Hz: every display frame moves")
                XCTAssertLessThan(steps.max()! / steps.min()!, 1.6, "\(mode) at \(rate) Hz: no alternating holds")
            }
        }
    }

    func testPredictTrailsSteadySixtyHertzInputByLessThanAdaptiveAndClassic() {
        let inputs = (0..<120).map { (Double($0) / 60, 0.4) }
        let frame = 1.0 / 120
        func trail(_ mode: ScrollResampler.Mode) -> Double {
            let drawn = simulate(inputs: inputs, frame: frame, until: 1.5, mode: mode).drawn
            // Continuous finger position: 0.4 lines per 1/60 s, starting one interval before the first event.
            let speed: Double = 0.4 * 60
            var sum: Double = 0
            for index in 120..<170 {
                let finger: Double = speed * (Double(index) * frame + 1.0 / 60)
                sum += finger - drawn[index]
            }
            return sum / 50 / speed   // seconds behind the finger
        }
        let classic = trail(.classic), adaptive = trail(.adaptive), predict = trail(.predict)
        XCTAssertLessThan(adaptive, classic - 0.003)
        XCTAssertLessThan(predict, adaptive - 0.006)
        XCTAssertGreaterThan(predict, 0.008, "prediction is bounded: it does not pretend the interval is not there")
    }

    func testPredictionIsBoundedToOneDisplayFrameOfTravelAndNeverMovesBackOnSteadyInput() {
        let rate = 60.0, perEvent = 0.4, frame = 1.0 / 120
        let inputs = (0..<90).map { (Double($0) / rate, perEvent) }
        let drawn = simulate(inputs: inputs, frame: frame, until: 1.4, mode: .predict).drawn
        let delivered = raw(inputs, frame: frame, count: drawn.count)
        let ahead = zip(drawn, delivered).map { $0 - $1 }.max()!
        XCTAssertLessThanOrEqual(ahead, perEvent * rate * frame + 1e-6, "at most one display frame of travel past the latest event")
        XCTAssertTrue(deltas(Array(drawn.prefix(175))).allSatisfy { $0 >= -1e-9 }, "never backwards while the input keeps moving")
    }

    func testAfterAnAbruptStopThePredictedRemainderHoldsThenEasesOntoTheInput() {
        let rate = 60.0, perEvent = 0.4, frame = 1.0 / 120
        let inputs = (0..<60).map { (Double($0) / rate, perEvent) }   // stops dead at full speed
        let run = simulate(inputs: inputs, frame: frame, until: 2.0, mode: .predict)
        let stop = Int((59.0 / rate) / frame)
        let after = Array(run.drawn[stop...])
        XCTAssertLessThanOrEqual(after.max()! - run.total, perEvent * rate * frame + 1e-6)
        let steps = deltas(after)
        XCTAssertLessThanOrEqual(-steps.min()!, 0.05, "the correction is eased, never one jump back")
        XCTAssertEqual(run.drawn.last!, run.total, accuracy: 1e-6, "ends exactly on the input")
        XCTAssertEqual(run.finalLag, 0)
    }

    func testAReversalIsFollowedAtOnceAndTheOvershootIsBounded() {
        var inputs: [(Double, Double)] = []
        for index in 0..<60 { inputs.append((Double(index) / 60.0, index < 30 ? 0.4 : -0.4)) }
        let frame = 1.0 / 120
        let run = simulate(inputs: inputs, frame: frame, until: 1.6, mode: .predict)
        let peakInput = 30 * 0.4
        XCTAssertLessThanOrEqual(run.drawn.max()! - peakInput, 0.4 * 60 * frame + 1e-6, "overshoot at the turn is at most one frame of travel")
        let turn = Int((30.0 / 60) / frame)
        // Within three frames of the first reversed event the content is moving the new way.
        XCTAssertLessThan(run.drawn[turn + 3], run.drawn[turn], "the reversal is not held back by the old prediction")
        XCTAssertEqual(run.drawn.last!, 0, accuracy: 1e-6)
    }

    func testUnsteadySpeedPredictsLessThanSteadySpeed() {
        func ahead(_ deltas: [Double]) -> Double {
            var resampler = ScrollResampler()
            resampler.mode = .predict
            var maximum = 0.0
            for (index, delta) in deltas.enumerated() {
                let time = Double(index) / 60
                resampler.input(delta, at: time)
                for sub in 1...2 { resampler.advance(to: time + Double(sub) / 120 - 0.0005); maximum = max(maximum, resampler.predictedAhead) }
            }
            return maximum
        }
        let steady = ahead(Array(repeating: 0.4, count: 40))
        let erratic = ahead((0..<40).map { $0 % 2 == 0 ? 0.1 : 0.7 })
        XCTAssertGreaterThan(steady, 0.05)
        XCTAssertLessThan(erratic, steady * 0.6, "a speed that keeps changing is trusted less")
    }

    func testAbsorbedInputAtAnEndDoesNotLeaveAPredictionPastIt() {
        var resampler = ScrollResampler()
        resampler.mode = .predict
        var total = 0.0
        for index in 0..<30 {
            let time = Double(index) / 60
            resampler.input(0.4, at: time); total += 0.4
            // The content has room for 6 lines only.
            if total > 6 { let excess = 6 - total; total = 6; resampler.absorb(excess, at: time) }
            resampler.advance(to: time + 1.0 / 120)
        }
        for frame in 0..<60 { resampler.advance(to: 0.5 + Double(frame) / 120) }
        XCTAssertEqual(resampler.lag, 0, "the drawn position rests on the end")
    }

    func testALiveGestureStaysActiveBetweenEventsSoConsumersDoNotRestartIt() {
        // Consumers end their animation and reset when `advance` reports nothing left. At a reversal the
        // prediction is zero and the drawn position equals the input: that must not look like the end.
        for mode in [ScrollResampler.Mode.adaptive, .predict] {
            var resampler = ScrollResampler()
            resampler.mode = mode
            var ended = 0
            for index in 0..<60 {
                let time = Double(index) / 60
                resampler.input(index < 30 ? 0.4 : -0.4, at: time)
                for sub in 1...2 where !resampler.advance(to: time + Double(sub) / 120 - 0.001) { ended += 1 }
            }
            XCTAssertEqual(ended, 0, "\(mode)")
            var frames = 0
            while resampler.advance(to: 1.0 + Double(frames) / 120), frames < 200 { frames += 1 }
            XCTAssertLessThan(frames, 40, "\(mode): it ends within a few frames of the input going quiet")
            XCTAssertEqual(resampler.lag, 0)
        }
    }
}
