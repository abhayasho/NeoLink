import AppKit
import SwiftTerm

/// Scrollback is local: its neighbouring lines are already available, so it needs neither
/// predictive requests nor a spring to land on a line. Preserve the fractional position
/// between gestures; the OS supplies trackpad momentum, including its final stop.
struct ScrollbackMotion {
    private(set) var offset = 0.0

    mutating func input(_ lines: Double) -> Int {
        guard lines.isFinite else { return 0 }
        offset += lines
        return Int(min(80, max(-80, offset)).rounded(.towardZero))
    }

    /// How far the last `moved` had to pull the offset back into range (input the content has no room for).
    private(set) var clamped = 0.0

    mutating func moved(_ lines: Int, range: ClosedRange<Double>) {
        let wanted = offset - Double(lines)
        offset = min(range.upperBound, max(range.lowerBound, wanted))
        clamped += offset - wanted
    }

    mutating func takeClamped() -> Double { defer { clamped = 0 }; return clamped }
}

/// Pixel-smooth trackpad scrolling over a grid that only moves by whole lines.
///
/// Units are lines; positive input and moves go toward the top of the content. The grid is
/// asked to move ahead of the input by a margin that grows with speed, so a program has time
/// to answer before the frame needs the next line, and the renderer draws the grid back by the
/// remaining distance. When the gesture and its momentum end, the grid is moved back by whole
/// lines (invisibly, since the offset compensates) and the remaining fraction of a line glides
/// out in the direction of travel with a critically damped spring that starts at the gesture's
/// final speed, so the motion neither stops and restarts nor reverses.
///
/// Some answers cannot be drawn at a fractional offset: a program that scrolls a region
/// within left and right margins (one window of a side-by-side split) or redraws the screen.
/// Then the model steps: the grid follows the input in whole lines, one requested line per
/// line of input, and nothing is drawn offset.
struct SmoothScrollModel {
    enum Phase { case changed, ended, momentum, momentumEnded }

    /// Lines by which the grid is drawn lower than its rows (negative: higher).
    private(set) var offset = 0.0
    /// Whole lines requested from the grid and not yet applied.
    private(set) var pending = 0
    private var pendingSince = 0.0
    private(set) var lastInput = -Double.infinity
    /// Input speed in lines per second toward the top, smoothed over recent events.
    private(set) var velocity = 0.0
    private var liftedAt: Double?
    private(set) var settling = false
    private var settleVelocity = 0.0
    /// Program output (bytes) since the oldest unanswered request.
    private var outputWhilePending = 0
    /// Following the input in whole lines (see the type's description).
    private(set) var stepping = false
    /// While stepping: input not yet requested, measured from where the grid will be once
    /// the pending moves apply.
    private var carry = 0.0
    /// Whether the program's latest answer could only be followed in whole lines; the next
    /// gesture starts stepping, so its first request does not jump ahead of the input.
    private(set) var answersInSteps = false

    static let pendingTimeout = 0.1
    /// After the finger lifts, how long to wait for momentum before settling.
    static let momentumWait = 0.03
    /// Settling without phase information (classic devices) after this much idle time.
    static let idleSettle = 0.08
    /// Spring stiffness for settling: about 0.15 s to come to rest.
    static let omega = 28.0
    /// Output larger than this while a request is pending, without a region scroll, means
    /// the program redrew. Neovim writes about 130 to 860 bytes per scrolled line and nothing
    /// for a request it ignores at either end of a file.
    static let redrawBytes = 2_048

    var isScrolling: Bool { pending != 0 || offset != 0 || settling }

    /// How far ahead of the input the grid should be: 0.35 lines plus 30 ms of travel.
    var lookahead: Double { stepping ? 0 : min(4, 0.35 + abs(velocity) * 0.03) }

    /// Applies trackpad input and returns the whole lines the grid should move (signed).
    mutating func input(_ lines: Double, at time: Double, phase: Phase = .changed, range: ClosedRange<Double>) -> Int {
        expirePending(at: time)
        switch phase {
        case .ended where lines == 0:
            liftedAt = time
            return 0
        case .momentumEnded where lines == 0:
            return beginSettle(at: time, range: range)
        default: break
        }
        settling = false
        liftedAt = phase == .ended ? time : nil
        let interval = time - lastInput
        if lines != 0 {
            let instantaneous = lines / max(interval, 1.0 / 240)
            if (velocity > 0 && lines < 0) || (velocity < 0 && lines > 0) {
                velocity = instantaneous
            } else {
                velocity = interval > 0.05 ? lines * 120 : 0.6 * velocity + 0.4 * instantaneous
            }
        }
        lastInput = time
        if stepping { return followInSteps(lines, at: time) }
        offset += lines
        let margin = lookahead
        let afterPending = offset - Double(pending)
        var move = 0
        if lines > 0, afterPending > -margin { move = Int((afterPending + margin).rounded(.up)) }
        if lines < 0, afterPending < margin { move = -Int((margin - afterPending).rounded(.up)) }
        move = max(-80, min(80, move))
        request(move, at: time)
        clamp(to: range)
        if phase == .momentumEnded { return move + beginSettle(at: time, range: range) }
        return move
    }

    /// The grid's scroll region moved `lines` toward the top and can be drawn offset. Moves the
    /// program made on its own, outside a gesture (for example the cursor leaving the window),
    /// are shown immediately.
    mutating func gridMoved(_ lines: Int, at time: Double, range: ClosedRange<Double>) {
        guard lines != 0 else { return }
        answersInSteps = false
        if stepping { consume(lines, at: time); return }
        if pending == 0, !settling, time - lastInput > 0.15 {
            offset = 0
            return
        }
        offset -= Double(lines)
        consume(lines, at: time)
        clamp(to: range)
    }

    /// The program moved `lines` toward the top in a way that can only be shown in whole lines
    /// (a region within left and right margins). An answer to a request switches to stepping.
    mutating func gridStepped(_ lines: Int, at time: Double) {
        guard lines != 0 else { return }
        answersInSteps = true
        guard pending != 0, pending.signum() == lines.signum() else { return }
        if !stepping { beginStepping() }
        consume(lines, at: time)
    }

    /// The program wrote `bytes` of output; distinguishes an ignored request from a redraw.
    mutating func noteOutput(_ bytes: Int) { if pending != 0 { outputWhilePending += bytes } }

    /// For a grid that applies moves synchronously: whatever was not applied never will be.
    mutating func dropPending() { pending = 0; outputWhilePending = 0 }

    /// One animation frame. Returns whether to keep animating and any whole lines the grid
    /// should move (when settling begins).
    mutating func step(at time: Double, interval: Double, range: ClosedRange<Double>) -> (active: Bool, move: Int) {
        expirePending(at: time)
        if stepping { return (pending != 0, 0) }
        var move = 0
        if !settling {
            let lifted = liftedAt.map { time - $0 >= Self.momentumWait } ?? false
            if lifted || time - lastInput >= Self.idleSettle { move = beginSettle(at: time, range: range) }
        }
        guard settling else { return (offset != 0 || pending != 0 || !isIdle(at: time), move) }
        // Spring on the offset that remains once pending moves apply.
        let target = Double(pending)
        let x0 = offset - target, v0 = settleVelocity, dt = max(0, min(interval, 0.05)), w = Self.omega
        let decay = exp(-w * dt)
        let x = (x0 + (v0 + w * x0) * dt) * decay
        settleVelocity = (v0 - w * (v0 + w * x0) * dt) * decay
        // Stop within subpixel precision without crossing zero (no reversal).
        if abs(x) < 0.002 || x.sign != x0.sign {
            offset = target
            settling = false
            settleVelocity = 0
        } else {
            offset = target + x
        }
        clamp(to: range)
        return (settling || pending != 0, move)
    }

    mutating func reset() { self = SmoothScrollModel() }

    /// Starts a new gesture, stepping from the start if the program last answered in steps.
    mutating func beginGesture() {
        let steps = answersInSteps
        self = SmoothScrollModel()
        answersInSteps = steps
        stepping = steps
    }

    private func isIdle(at time: Double) -> Bool { time - lastInput > 0.3 }

    /// Moves the grid back by the whole lines of the offset; the fraction left glides out
    /// in the direction of travel, starting at the current speed.
    private mutating func beginSettle(at time: Double, range: ClosedRange<Double>) -> Int {
        liftedAt = nil
        guard !settling, !stepping else { return 0 }
        let remaining = offset - Double(pending)
        let whole = Int(remaining.rounded(.towardZero))
        request(whole, at: time)
        let residual = remaining - Double(whole)
        guard residual != 0 || pending != 0 else { velocity = 0; return whole }
        settling = true
        // Toward zero only, and no faster than reaches it without overshooting.
        var v = 0.0
        if residual > 0 { v = min(0, max(velocity, -Self.omega * residual)) }
        if residual < 0 { v = max(0, min(velocity, -Self.omega * residual)) }
        settleVelocity = v
        velocity = 0
        return whole
    }

    /// Requests the whole lines nearest the input, never against the direction it moves.
    private mutating func followInSteps(_ lines: Double, at time: Double) -> Int {
        carry += lines
        var move = Int(carry.rounded())
        if lines == 0 || (move > 0) != (lines > 0) { move = 0 }
        move = max(-80, min(80, move))
        carry -= Double(move)
        request(move, at: time)
        return move
    }

    /// From now on the grid follows in whole lines. It will end where all requests take it;
    /// the input's distance from there carries over, and nothing is drawn offset.
    private mutating func beginStepping() {
        carry = offset - Double(pending)
        offset = 0
        stepping = true
        settling = false
        settleVelocity = 0
    }

    private mutating func request(_ move: Int, at time: Double) {
        guard move != 0 else { return }
        if pending == 0 { pendingSince = time; outputWhilePending = 0 }
        pending += move
    }

    /// Part or all of a request was answered.
    private mutating func consume(_ lines: Int, at time: Double) {
        guard pending != 0, pending.signum() == lines.signum() else { return }
        pending = abs(lines) >= abs(pending) ? 0 : pending - lines
        pendingSince = time
        outputWhilePending = 0
    }

    private mutating func expirePending(at time: Double) {
        guard pending != 0, time - pendingSince > Self.pendingTimeout else { return }
        if !stepping, outputWhilePending >= Self.redrawBytes {
            // The program redrew instead of scrolling a region: assume it moved.
            beginStepping()
            answersInSteps = true
        }
        // Otherwise it ignored the request, for example at the end of the file.
        pending = 0
        outputWhilePending = 0
    }

    /// Lines in flight may move the grid, so the offset may exceed the drawable range by them.
    private mutating func clamp(to range: ClosedRange<Double>) {
        let lower = range.lowerBound + Double(min(0, pending))
        let upper = range.upperBound + Double(max(0, pending))
        let wanted = offset
        offset = min(max(offset, lower), upper)
        clamped += offset - wanted
    }

    /// Input the content had no room for since the last call (so the resampler can forget it).
    private(set) var clamped = 0.0
    mutating func takeClamped() -> Double { defer { clamped = 0 }; return clamped }
}

/// Keeps a trackpad gesture on one axis, in the spirit of Zed's `OngoingScroll`.
///
/// A finger moving "vertically" drifts sideways by a fraction of its motion. In an editor without line
/// wrapping every sideways column makes the program redraw the whole screen, so that drift turned smooth
/// vertical scrolling into a stream of heavy frames and jumps. A gesture locks to its dominant axis on its
/// first event. Mouse wheels (imprecise deltas) are not filtered.
///
/// The editor cannot scroll both ways at once: changing axis ends a sideways session on a whole column and
/// starts a vertical one. A diagonal or wandering finger therefore must not flip the lock event by event
/// (which looked like stuttering in both directions). While the fingers stay down:
/// - the lock changes only on sustained evidence: recent travel along the other axis (a 0.2 s memory) of at
///   least 16 points and 1.9 times the travel along the locked one. One sideways event is not enough, and a
///   45-degree path stays on the axis it started on;
/// - a short gap between events is not a new gesture (a slow finger reports with gaps of 30 ms and more);
///   only a rest of 0.15 s chooses the axis again from the next movement.
/// Momentum keeps the axis of the gesture that produced it. Streams without phases (older devices) choose
/// again after 28 ms, as before.
struct ScrollAxisLock {
    enum Axis { case horizontal, vertical }
    private(set) var axis: Axis?
    private var lastEvent: Double?
    /// Between a gesture's `began` and `ended` phases.
    private var touching = false
    /// Decayed recent travel (points) along the locked axis and across it.
    private var along: CGFloat = 0, across: CGFloat = 0
    /// The axis of the gesture that just ended, for the momentum that follows it.
    private var released: (axis: Axis, time: Double)?
    /// Changes of axis within gestures (measurement).
    private(set) var switches = 0
    static let separation = 0.028
    static let restingSeparation = 0.15
    static let unlockRatio: CGFloat = 1.9
    static let unlockTravel: CGFloat = 16
    static let memory = 0.2

    /// `NEOLINK_AXIS_LOCK=classic` restores the previous rule (one event of 6 points and 1.9 times switches;
    /// any 28 ms gap chooses again) for same-binary comparisons.
    static let usesClassicRule = ProcessInfo.processInfo.environment["NEOLINK_AXIS_LOCK"] == "classic"
    var classic = ScrollAxisLock.usesClassicRule

    private mutating func filterClassic(dx: CGFloat, dy: CGFloat, began: Bool, ended: Bool, at time: Double) -> (dx: CGFloat, dy: CGFloat) {
        if ended {
            let result = apply(dx, dy)
            axis = nil; lastEvent = nil
            return result
        }
        if dx == 0, dy == 0 {
            if began { axis = nil; lastEvent = nil }
            return (0, 0)
        }
        let newGesture = began || lastEvent.map { time - $0 >= Self.separation } ?? true
        if newGesture {
            axis = abs(dx) > abs(dy) ? .horizontal : .vertical
        } else if max(abs(dx), abs(dy)) >= 6 {
            let previous = axis
            if axis == .vertical, abs(dx) > Self.unlockRatio * abs(dy) { axis = .horizontal }
            else if axis == .horizontal, abs(dy) > Self.unlockRatio * abs(dx) { axis = .vertical }
            if axis != previous { switches += 1 }
        }
        lastEvent = time
        return apply(dx, dy)
    }

    mutating func filter(dx: CGFloat, dy: CGFloat, began: Bool, ended: Bool, momentum: Bool = false, at time: Double) -> (dx: CGFloat, dy: CGFloat) {
        if classic { return filterClassic(dx: dx, dy: dy, began: began, ended: ended, at: time) }
        if ended {
            // The end of the finger's contact; whatever this event carries still follows the current lock.
            let result = apply(dx, dy)
            if let axis, !momentum { released = (axis, time) }
            axis = nil; lastEvent = nil; touching = false; along = 0; across = 0
            return result
        }
        if began { touching = true; axis = nil; lastEvent = nil; released = nil; along = 0; across = 0 }
        if dx == 0, dy == 0 { return (0, 0) }
        let gap = lastEvent.map { time - $0 }
        let rested = gap.map { $0 >= (touching ? Self.restingSeparation : Self.separation) } ?? true
        if axis == nil || rested {
            if momentum, let released, time - released.time < 0.25 { axis = released.axis }
            else { axis = abs(dx) > abs(dy) ? .horizontal : .vertical }
            along = 0; across = 0
        } else if !momentum {
            let decay = CGFloat(exp(-(gap ?? 0) / Self.memory))
            along = along * decay + (axis == .vertical ? abs(dy) : abs(dx))
            across = across * decay + (axis == .vertical ? abs(dx) : abs(dy))
            if across >= Self.unlockTravel, across >= Self.unlockRatio * along {
                axis = axis == .vertical ? .horizontal : .vertical
                // Going back needs the same sustained evidence again.
                along = 0; across = 0; switches += 1
            }
        }
        lastEvent = time
        return apply(dx, dy)
    }

    private func apply(_ dx: CGFloat, _ dy: CGFloat) -> (dx: CGFloat, dy: CGFloat) {
        switch axis {
        case .vertical: return (0, dy)
        case .horizontal: return (dx, 0)
        case nil: return (dx, dy)
        }
    }
}

/// Draws trackpad input at the display's cadence instead of the input's.
///
/// Scroll events arrive when the hardware reports them (often about 60 Hz, with jitter and bursts), not
/// when the display refreshes (up to 120 Hz). Applying each event's distance the moment it arrives moves
/// the content in uneven steps and repeats frames in between. The resampler keeps the recent history of the
/// accumulated input and, on every display frame, draws the position it had `delay` seconds ago by linear
/// interpolation. For steady input that is exactly uniform motion. The drawn position is never ahead of the
/// fingers and never overshoots: when the events stop, it simply reaches the last position.
/// `lag` is the part of the input not drawn yet (in lines). Whole-line moves of the grid shift the offset and
/// the input together, so they do not change it.
///
/// The input rate is measured from every event, including events that arrive after the drawn position has
/// caught up (an earlier version measured only while catching up, so after a fast gesture a slower stream kept
/// a delay too short for it and was drawn at its own rate). The delay is a continuous function of that rate,
/// and the delay in use follows it at a bounded speed, so a change of rate (a finger slowing down, the switch
/// to momentum) changes the speed of the drawn content slightly instead of stalling or jerking it.
struct ScrollResampler {
    /// How much the drawn position is allowed to trail (or lead) the input. Selectable in one binary with
    /// `NEOLINK_SCROLL_RESAMPLER=classic|adaptive|predict` for matched comparisons (see `docs/RENDERING.md`).
    /// - `classic`: one input interval plus a fixed 6 ms; the first event of a gesture ramps in.
    /// - `adaptive`: the first event of a gesture is drawn at once, and the jitter margin is the one measured
    ///   from the events' arrival times (2–6 ms) instead of a fixed 6 ms.
    /// - `predict`: `adaptive`, with the delay shortened by up to one display frame; frames that fall after the
    ///   latest event extrapolate it by at most that long, scaled down when the speed is not steady.
    enum Mode: String { case classic, adaptive, predict }
    /// `predict` unless View → Low-Latency Scrolling is off (`classic`); the environment variable overrides both.
    static let preferenceKey = "NeoLink.lowLatencyScrolling"
    static let environmentMode = Mode(rawValue: ProcessInfo.processInfo.environment["NEOLINK_SCROLL_RESAMPLER"] ?? "")
    static var lowLatencyPreference: Bool {
        get { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey); current = environmentMode ?? (newValue ? .predict : .classic) }
    }
    /// The mode of every resampler that was not given one explicitly; changes apply to the next gesture.
    private(set) static var current: Mode = environmentMode ?? (lowLatencyPreference ? .predict : .classic)
    private var chosenMode: Mode?
    var mode: Mode {
        get { chosenMode ?? Self.current }
        set { chosenMode = newValue }
    }

    private(set) var lag = 0.0
    private var history: [(time: Double, position: Double)] = []
    private var total = 0.0
    private var interval = 1.0 / 60
    /// Smoothed absolute deviation of the gaps between events from the measured interval (arrival jitter).
    private var deviation = 0.0015
    /// Time of the latest event; kept when the history is trimmed or reset, so every gap is measured.
    private var lastInput: Double?
    /// The delay in use (see `delaySlew`); nil while the content is at rest.
    private var appliedDelay: Double?
    private var lastAdvance: Double?
    /// `predict`: the position drawn by the previous frame, so a shrinking prediction holds instead of moving back.
    private var lastDrawn: Double?
    /// `predict`: lines currently drawn beyond the latest input (diagnostic; 0 when interpolating).
    private(set) var predictedAhead = 0.0
    /// `predict`: the largest extrapolation drawn so far and how often a frame extrapolated (diagnostics).
    private(set) var predictedAheadMax = 0.0
    private(set) var predictedFrames = 0
    static let jitterMargin = 0.006
    static let minimumJitterMargin = 0.002
    static let minimumDelay = 0.008
    static let maximumDelay = 0.030
    static let epsilon = 0.003
    /// How fast the delay in use may change, in seconds per second. Below 1 the sampled time never moves
    /// backwards, so steady input is never drawn moving back; at 0.5 the drawn speed changes by at most half.
    static let delaySlew = 0.5
    /// `predict`: after this long without an event an extrapolated remainder is eased back to the input.
    static let predictionRelease = 0.06

    /// Seconds between display frames; input at about this rate already moves every frame and needs little help.
    var framePeriod = 1.0 / 120

    /// Slack for events that arrive late: fixed in `classic`, measured otherwise (never above the fixed value).
    var jitterAllowance: Double {
        mode == .classic ? Self.jitterMargin : min(Self.jitterMargin, max(Self.minimumJitterMargin, 0.001 + 2.5 * deviation))
    }
    /// `predict`: the longest time a frame may be drawn past the latest event (one display frame).
    var lookahead: Double { mode == .predict ? min(framePeriod, 0.0085) : 0 }

    /// Input at or faster than the display only needs enough slack for arrival jitter (half an interval plus
    /// 2 ms). Input at half the display's rate or slower trails by one interval plus a jitter margin, so every
    /// refresh falls between two events. In between, the two blend linearly: there is no threshold at which a
    /// small change of rate makes the delay jump. `predict` trails by `lookahead` less and extrapolates instead.
    var delay: Double {
        let fast = 0.5 * interval + 0.002, slow = interval + jitterAllowance
        // `classic` blends over the whole range up to half the display's rate; its fixed 6 ms margin is what
        // keeps rates in between (80 Hz) from holding frames. With a measured margin the full interval is
        // needed as soon as the input is clearly slower than the display.
        let span = mode == .classic ? 1.0 : 0.25
        let blend = min(1, max(0, (interval - framePeriod) / max(framePeriod * span, 0.001)))
        let base = min(Self.maximumDelay, max(Self.minimumDelay * 0.5, fast + (slow - fast) * blend))
        return mode == .predict ? max(Self.minimumJitterMargin, base - lookahead) : base
    }
    /// There is still motion to draw. In `classic` that is an undrawn remainder. The other modes draw level
    /// with (or ahead of) the latest event between events, so "nothing left to draw" there does not mean the
    /// gesture is over: they stay active until the input has been quiet, and a consumer that ends its
    /// animation and resets on inactivity does not turn every event into a new start.
    private(set) var isCatchingUp = false
    /// Measured seconds between input events.
    var inputInterval: Double { interval }

    mutating func input(_ lines: Double, at time: Double) {
        guard lines.isFinite, lines != 0 else { return }
        if let lastInput {
            let gap = time - lastInput
            // Events within 4 ms of each other are one report split in two: not a faster input rate.
            if gap >= 0.004, gap < 0.1 {
                deviation = 0.85 * deviation + 0.15 * min(0.01, abs(gap - interval))
                interval = 0.7 * interval + 0.3 * gap
            } else if gap >= 0.1 { interval = 1.0 / 60; history.removeAll(); lastDrawn = nil }
        }
        lastInput = max(lastInput ?? time, time)
        if history.isEmpty {
            // The gesture starts from rest; so does the delay. `classic` ramps the first event in over one
            // interval; the other modes have nothing earlier to interpolate from and draw it at once.
            if mode == .classic { history.append((time - interval, total)) }
            appliedDelay = nil
        }
        total += lines
        history.append((max(time, history.last?.time ?? time), total))
        advance(to: time)
    }

    /// Position of the drawn content at `now`; returns whether it still trails the input.
    @discardableResult
    mutating func advance(to now: Double) -> Bool {
        guard let last = history.last else { lag = 0; appliedDelay = nil; lastDrawn = nil; predictedAhead = 0; isCatchingUp = false; return false }
        let target = delay
        let elapsed = lastAdvance.map { max(0, now - $0) } ?? 0
        if let applied = appliedDelay, lastAdvance != nil {
            let step = Self.delaySlew * elapsed
            appliedDelay = min(applied + step, max(applied - step, target))
        } else {
            appliedDelay = target
        }
        lastAdvance = max(lastAdvance ?? now, now)
        let at = now - appliedDelay!
        var drawn = last.position
        if at < last.time {
            if at <= history[0].time { drawn = history[0].position }
            else if let upper = history.firstIndex(where: { $0.time >= at }), upper > 0 {
                let a = history[upper - 1], b = history[upper]
                drawn = b.time > a.time ? a.position + (b.position - a.position) * (at - a.time) / (b.time - a.time) : b.position
            }
        } else if mode == .predict {
            drawn = last.position + extrapolation(past: at - last.time)
        }
        if mode == .predict { drawn = settlePrediction(drawn, latest: last, now: now, elapsed: elapsed) }
        // Keep only what a later frame can still need (`predict` also keeps two segments to judge the speed).
        if let keep = history.firstIndex(where: { $0.time >= at }), keep > 1 {
            history.removeFirst(mode == .predict ? max(0, min(keep - 1, history.count - 3)) : keep - 1)
        } else if history.count > 16 { history.removeFirst(history.count - 8) }
        lag = last.position - drawn
        if abs(lag) < Self.epsilon { lag = 0 }
        // Caught up. `classic` forgets the gesture here and ramps the next event in. The other modes keep the
        // latest events while the stream is live, so the next one is interpolated (and its speed known) rather
        // than treated as a new start; they forget once the input has been quiet.
        if lag == 0, at >= last.time, mode == .classic || now - last.time > max(2 * interval, 0.04) {
            history.removeAll(); appliedDelay = nil; lastDrawn = nil; predictedAhead = 0
        }
        isCatchingUp = lag != 0 || (mode != .classic && !history.isEmpty)
        return isCatchingUp
    }

    /// Lines to draw beyond the latest event, `time` seconds after it: its speed over at most `lookahead`.
    /// Steady input (speed and timing within a quarter of the previous segment's) is extrapolated in full, so
    /// the drawn motion stays linear and lands on the same device pixels as interpolation would; scaling it
    /// down by a few percent made alternate frames round to the same pixel at one pixel per frame. Beyond that
    /// the prediction fades, and a reversal or a single segment predicts nothing or half.
    private func extrapolation(past time: Double) -> Double {
        let count = history.count
        guard count >= 2, time > 0 else { return 0 }
        let a = history[count - 2], b = history[count - 1]
        guard b.time - a.time >= 0.004 else { return 0 }
        var speed = (b.position - a.position) / (b.time - a.time)
        func trust(_ variation: Double) -> Double { variation <= 0.25 ? 1 : max(0, 1 - (variation - 0.25) / 0.5) }
        var confidence = 0.5
        if count >= 3, a.time - history[count - 3].time >= 0.004 {
            let first = history[count - 3]
            let earlier = (a.position - first.position) / (a.time - first.time)
            confidence = earlier * speed <= 0 ? 0 : trust(abs(speed - earlier) / max(abs(speed), abs(earlier)))
            // Two segments of steady input: their mean speed is less sensitive to one event's arrival time.
            if confidence == 1 { speed = (b.position - first.position) / (b.time - first.time) }
        }
        // An interval far from the measured one is a late or early report: its speed is less certain.
        confidence *= trust(abs((b.time - a.time) - interval) / max(interval, 0.004))
        return speed * min(time, lookahead) * confidence
    }

    /// A prediction that shrank (the speed changed, or no event came) holds where it was drawn rather than moving
    /// back; it follows a reversal at once, and after `predictionRelease` without input it eases onto the input.
    private mutating func settlePrediction(_ candidate: Double, latest: (time: Double, position: Double), now: Double, elapsed: Double) -> Double {
        let count = history.count
        let sign: Double = count >= 2 && latest.position < history[count - 2].position ? -1 : 1
        func ahead(_ value: Double) -> Double { (value - latest.position) * sign }
        let released = now - latest.time > Self.predictionRelease
        var drawn = candidate
        // No event for a while: the stream stopped, so there is nothing left to predict.
        if released, ahead(drawn) > 0 { drawn = latest.position }
        if let previous = lastDrawn, ahead(previous) > 0, ahead(drawn) < ahead(previous) {
            if released {
                let remaining = ahead(previous) * exp(-elapsed / 0.05)
                drawn = latest.position + sign * max(ahead(drawn), remaining < Self.epsilon ? 0 : remaining)
            } else {
                drawn = previous
            }
        }
        lastDrawn = drawn
        predictedAhead = max(0, ahead(drawn))
        if predictedAhead > 0 { predictedFrames += 1; predictedAheadMax = max(predictedAheadMax, predictedAhead) }
        return drawn
    }

    /// The content could not follow `amount` lines of the latest input (it hit an end): forget them, so a
    /// later reversal starts from where the content actually is.
    mutating func absorb(_ amount: Double, at now: Double) {
        guard amount != 0, !history.isEmpty else { return }
        total += amount
        history[history.count - 1].position += amount
        advance(to: now)
    }

    /// Drops the undrawn remainder. The measured input rate is a property of the device and is kept.
    mutating func reset() { lag = 0; history.removeAll(); total = 0; appliedDelay = nil; lastDrawn = nil; predictedAhead = 0; isCatchingUp = false }
}

/// The time an event's input was sampled, in `CACurrentMediaTime`'s timebase, when it is plausible: interpolating
/// against sampling times instead of arrival times keeps delivery jitter out of the drawn motion.
func scrollInputTime(_ event: NSEvent, now: Double) -> Double {
    let stamp = event.timestamp
    return stamp > 0 && stamp <= now && now - stamp < 0.05 ? stamp : now
}

/// Connects `SmoothScrollModel` to a terminal view, its Metal renderer and the window clock.
@MainActor
final class SmoothScrollDriver {
    private unowned let view: InteractiveTerminalView
    private var model = SmoothScrollModel()
    private var scrollback = ScrollbackMotion()
    private var resampler = ScrollResampler()
    private var movingScrollback = false
    private var scrollbackRow: Int?
    private var source: SmoothScrollSource?
    private var mover: ((Int) -> Int?)?
    private var lastStep: Double?
    private var animating = false
    /// Measurement only: lines of input and of grid movement since the first gesture (toward the top).
    private var traceInput = 0.0, traceGrid = 0.0, traced = false
    /// Measurement only: whole-line requests sent to the program and moves it reported.
    private(set) var requests: [(time: Double, lines: Int)] = [], moves: [(time: Double, lines: Int)] = []
    /// Measurement only: whether the latest gesture followed the program in whole lines.
    var isStepping: Bool { model.stepping }

    init(view: InteractiveTerminalView) {
        self.view = view
        view.viewportScrollWillChange = { [weak self] in
            MainActor.assumeIsolated { self?.viewportWillChange() }
        }
        // Terminal output is parsed on the main queue (LocalProcess's default).
        view.programScrolled = { [weak self] lines in
            MainActor.assumeIsolated { self?.programScrolled(lines, inSteps: false) }
        }
        view.programScrolledWithinMargins = { [weak self] lines in
            MainActor.assumeIsolated { self?.programScrolled(lines, inSteps: true) }
        }
    }

    private var cellHeight: CGFloat {
        let terminal = view.getTerminal()
        let pixels = view.cellSizeInPixels(source: terminal)?.height ?? 16
        return CGFloat(pixels) / max(1, view.window?.backingScaleFactor ?? 1)
    }

    private var range: ClosedRange<Double> {
        let height = Double(cellHeight), points = view.smoothScrollRange
        guard height > 0 else { return 0...0 }
        return Double(points.lowerBound) / height...Double(points.upperBound) / height
    }

    var isAvailable: Bool {
        view.isUsingMetalRenderer && view.metalBufferingMode == .perRowPersistent && view.window != nil
    }

    static func phase(of event: NSEvent) -> SmoothScrollModel.Phase {
        if event.momentumPhase == .ended || event.momentumPhase == .cancelled { return .momentumEnded }
        if event.momentumPhase == .began || event.momentumPhase == .changed { return .momentum }
        if event.phase == .ended || event.phase == .cancelled { return .ended }
        return .changed
    }

    /// Handles a precise vertical scroll. `move` asks the grid to move whole lines toward the
    /// top and returns how many it moved synchronously (`nil` when it will report later).
    func scroll(_ event: NSEvent, source: SmoothScrollSource, deltaY: CGFloat? = nil, move: @escaping (Int) -> Int?) {
        let deltaY = deltaY ?? event.scrollingDeltaY
        let now = CACurrentMediaTime()
        if self.source != source { reset(); self.source = source; view.smoothScrollSource = source }
        let phase = Self.phase(of: event)
        if source == .program, now - model.lastInput > 0.3, !model.isScrolling, deltaY != 0 {
            model.beginGesture()
            view.discardRetainedScrollLines()
        }
        mover = move
        let lines = Double(deltaY * view.scrollSensitivity / max(1, cellHeight))
        traced = true; traceInput += lines
        let sampled = scrollInputTime(event, now: now)
        if source == .scrollback {
            // Apply all input before the next display-paced frame. A parked fraction is a
            // valid viewport, not an animation that should keep the display clock awake.
            resampler.input(lines, at: sampled)
            let request = scrollback.input(lines)
            movingScrollback = true
            let moved = request == 0 ? 0 : (move(request) ?? 0)
            movingScrollback = false
            scrollbackRow = view.getTerminal().buffer.yDisp
            traceGrid += Double(moved)
            scrollback.moved(moved, range: range)
            resampler.absorb(scrollback.takeClamped(), at: now)
            apply()
            startAnimating()
            return
        }
        resampler.input(lines, at: sampled)
        perform(model.input(lines, at: now, phase: phase, range: range), at: now)
        resampler.absorb(model.takeClamped(), at: now)
        apply()
        startAnimating()
    }

    /// Program output arrived (bytes).
    func noteOutput(_ bytes: Int) { if source == .program { model.noteOutput(bytes) } }

    private func perform(_ request: Int, at time: Double) {
        guard request != 0, let mover else { return }
        if source == .program {
            requests.append((time, request))
            if requests.count > 4_000 { requests.removeFirst(requests.count - 4_000) }
        }
        if let moved = mover(request) {
            traceGrid += Double(moved)
            model.gridMoved(moved, at: time, range: range)
            model.dropPending()
        }
    }

    func traceSample(drawnOffset: CGFloat) -> (input: Double, drawn: Double)? {
        guard traced, cellHeight > 0 else { return nil }
        return (traceInput, traceGrid + Double(drawnOffset / cellHeight))
    }

    func reset() {
        model.reset()
        resampler.reset()
        scrollback = ScrollbackMotion()
        scrollbackRow = nil
        lastStep = nil
        if view.smoothScrollOffset != 0 { view.smoothScrollOffset = 0 }
    }

    /// Keyboard navigation, a scrollbar drag, or output following the live prompt owns
    /// its new viewport. Do not carry a previous trackpad fraction into that position.
    func viewportChanged(to row: Int) {
        guard source == .scrollback, !movingScrollback else { return }
        if let scrollbackRow, scrollbackRow != row { reset() }
    }

    func viewportWillChange() {
        if source == .scrollback, !movingScrollback { reset() }
    }

    /// The program moved its content up `lines`: the grid moved toward the bottom.
    private func programScrolled(_ lines: Int, inSteps: Bool) {
        guard source == .program else { return }
        let now = CACurrentMediaTime()
        moves.append((now, -lines))
        if moves.count > 4_000 { moves.removeFirst(moves.count - 4_000) }
        guard model.isScrolling || now - model.lastInput < 0.15 else { return }
        traceGrid -= Double(lines)
        if inSteps {
            model.gridStepped(-lines, at: now)
        } else {
            model.gridMoved(-lines, at: now, range: range)
        }
        apply()
    }

    private func apply() {
        // The program moved on its own (nothing of the gesture left to draw): drop the undrawn remainder too.
        if source == .program, !model.isScrolling { resampler.reset() }
        // A predicted position may lead the model; `smoothScrollPlan` clamps it to the lines that exist.
        let drawn = (source == .scrollback ? scrollback.offset : model.offset) - resampler.lag
        let offset = CGFloat(drawn) * cellHeight
        // Whole device pixels keep glyphs on the pixel grid.
        let scale = view.window?.backingScaleFactor ?? 2
        let snapped = (offset * scale).rounded() / scale
        if view.smoothScrollOffset != snapped { view.smoothScrollOffset = snapped }
    }

    private func startAnimating() {
        guard !animating, let frames = WindowFrameScheduler.forWindow(view.window) else { return }
        animating = true
        resampler.framePeriod = 1.0 / Double(max(30, frames.targetRate))
        frames.animate(ObjectIdentifier(self), surface: ObjectIdentifier(view)) { [weak self] time in
            guard let self else { return false }
            guard time.isFinite else { self.reset(); self.animating = false; return false }
            let interval = self.lastStep.map { min(0.05, time - $0) } ?? 1.0 / Double(frames.targetRate)
            self.lastStep = time
            let catchingUp = self.resampler.advance(to: CACurrentMediaTime())
            if self.source != .program {
                // Local scrollback has no program to wait for: only the undrawn remainder animates.
                self.apply()
                if !catchingUp { self.lastStep = nil; self.animating = false }
                return catchingUp
            }
            let now = CACurrentMediaTime()
            let (modelActive, move) = self.model.step(at: now, interval: interval, range: self.range)
            self.perform(move, at: now)
            self.resampler.absorb(self.model.takeClamped(), at: now)
            self.apply()
            let active = modelActive || catchingUp
            if !active { self.lastStep = nil; self.animating = false }
            return active
        }
    }
}
