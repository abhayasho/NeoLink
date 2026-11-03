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

    mutating func moved(_ lines: Int, range: ClosedRange<Double>) {
        offset = min(range.upperBound, max(range.lowerBound, offset - Double(lines)))
    }
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
            velocity = interval > 0.05 ? lines * 120 : 0.6 * velocity + 0.4 * instantaneous
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
        // Stop within half a device pixel, without crossing zero (no reversal).
        if abs(x) < 0.015 || x.sign != x0.sign {
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
        offset = min(max(offset, lower), upper)
    }
}

/// Connects `SmoothScrollModel` to a terminal view, its Metal renderer and the window clock.
@MainActor
final class SmoothScrollDriver {
    private unowned let view: InteractiveTerminalView
    private var model = SmoothScrollModel()
    private var scrollback = ScrollbackMotion()
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
    func scroll(_ event: NSEvent, source: SmoothScrollSource, move: @escaping (Int) -> Int?) {
        let now = CACurrentMediaTime()
        if self.source != source { reset(); self.source = source; view.smoothScrollSource = source }
        let phase = Self.phase(of: event)
        if source == .program, now - model.lastInput > 0.3, !model.isScrolling, event.scrollingDeltaY != 0 {
            model.beginGesture()
            view.discardRetainedScrollLines()
        }
        mover = move
        let lines = Double(event.scrollingDeltaY * view.scrollSensitivity / max(1, cellHeight))
        traced = true; traceInput += lines
        if source == .scrollback {
            // Apply all input before the next display-paced frame. A parked fraction is a
            // valid viewport, not an animation that should keep the display clock awake.
            let request = scrollback.input(lines)
            movingScrollback = true
            let moved = request == 0 ? 0 : (move(request) ?? 0)
            movingScrollback = false
            scrollbackRow = view.getTerminal().buffer.yDisp
            traceGrid += Double(moved)
            scrollback.moved(moved, range: range)
            apply()
            return
        }
        perform(model.input(lines, at: now, phase: phase, range: range), at: now)
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
        let offset = CGFloat(source == .scrollback ? scrollback.offset : model.offset) * cellHeight
        // Whole device pixels keep glyphs on the pixel grid.
        let scale = view.window?.backingScaleFactor ?? 2
        let snapped = (offset * scale).rounded() / scale
        if view.smoothScrollOffset != snapped { view.smoothScrollOffset = snapped }
    }

    private func startAnimating() {
        guard !animating, let frames = WindowFrameScheduler.forWindow(view.window) else { return }
        animating = true
        frames.animate(ObjectIdentifier(self)) { [weak self] time in
            guard let self else { return false }
            guard self.source == .program else { self.animating = false; return false }
            guard time.isFinite else { self.reset(); self.animating = false; return false }
            let interval = self.lastStep.map { min(0.05, time - $0) } ?? 1.0 / Double(frames.targetRate)
            self.lastStep = time
            let now = CACurrentMediaTime()
            let (active, move) = self.model.step(at: now, interval: interval, range: self.range)
            self.perform(move, at: now)
            self.apply()
            if !active { self.lastStep = nil; self.animating = false }
            return active
        }
    }
}
