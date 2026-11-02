import AppKit
import SwiftTerm

/// Pixel-smooth trackpad scrolling over a grid that only moves by whole lines.
///
/// Units are lines; positive input and moves go toward the top of the content. The grid
/// is asked to move ahead of the input (rounding away from zero), and the renderer draws
/// it back by the remaining fraction, so the visible position follows the trackpad. When
/// input stops, the fraction eases out in the direction of travel.
struct SmoothScrollModel {
    /// Lines by which the grid is drawn lower than its rows (negative: higher).
    private(set) var offset = 0.0
    /// Whole lines requested from the grid and not yet applied.
    private(set) var pending = 0
    private var pendingSince = 0.0
    private(set) var lastInput = -Double.infinity
    static let idleDelay = 0.05
    static let pendingTimeout = 0.08
    static let easing = 0.035

    var isScrolling: Bool { pending != 0 || offset != 0 }

    /// Applies trackpad input and returns the whole lines the grid should move (signed).
    mutating func input(_ lines: Double, at time: Double, range: ClosedRange<Double>) -> Int {
        expirePending(at: time)
        offset += lines
        lastInput = time
        let afterPending = offset - Double(pending)
        var move = 0
        if lines > 0, afterPending > 0 { move = Int(afterPending.rounded(.up)) }
        if lines < 0, afterPending < 0 { move = Int(afterPending.rounded(.down)) }
        if move != 0 {
            if pending == 0 { pendingSince = time }
            pending += move
        }
        clamp(to: range)
        return move
    }

    /// The grid moved `lines` toward the top. Moves the program made on its own, outside a
    /// gesture (for example the cursor leaving the window), are shown immediately.
    mutating func gridMoved(_ lines: Int, at time: Double, range: ClosedRange<Double>) {
        guard lines != 0 else { return }
        if pending == 0, time - lastInput > 0.15 {
            offset = 0
            return
        }
        offset -= Double(lines)
        if pending != 0, pending.signum() == lines.signum() {
            pending = abs(lines) >= abs(pending) ? 0 : pending - lines
            pendingSince = time
        }
        clamp(to: range)
    }

    /// For a grid that applies moves synchronously: whatever was not applied never will be.
    mutating func dropPending() { pending = 0 }

    /// One animation frame. Returns false once at rest.
    mutating func step(at time: Double, interval: Double, range: ClosedRange<Double>) -> Bool {
        expirePending(at: time)
        guard time - lastInput >= Self.idleDelay, pending == 0 else { return true }
        offset *= exp(-max(0, interval) / Self.easing)
        if abs(offset) < 0.01 { offset = 0 }
        clamp(to: range)
        return offset != 0
    }

    mutating func reset() { self = SmoothScrollModel() }

    private mutating func expirePending(at time: Double) {
        if pending != 0, time - pendingSince > Self.pendingTimeout { pending = 0 }
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
    private var source: SmoothScrollSource?
    private var lastStep: Double?
    private var animating = false

    init(view: InteractiveTerminalView) {
        self.view = view
        view.programScrolled = { [weak self] lines in
            // Terminal output is parsed on the main queue (LocalProcess's default).
            MainActor.assumeIsolated { self?.programScrolled(lines) }
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

    /// Handles a precise vertical scroll. `move` asks the grid to move whole lines toward the
    /// top and returns how many it moved synchronously (`nil` when it will report later).
    func scroll(_ event: NSEvent, source: SmoothScrollSource, move: (Int) -> Int?) {
        let now = CACurrentMediaTime()
        if self.source != source { reset(); self.source = source; view.smoothScrollSource = source }
        if now - model.lastInput > 0.3, !model.isScrolling {
            model.reset()
            if source == .program { view.discardRetainedScrollLines() }
        }
        let lines = Double(event.scrollingDeltaY * view.scrollSensitivity / max(1, cellHeight))
        let request = model.input(lines, at: now, range: range)
        if request != 0, let moved = move(request) {
            model.gridMoved(moved, at: now, range: range)
            model.dropPending()
        }
        apply()
        startAnimating()
    }

    func reset() {
        model.reset()
        lastStep = nil
        if view.smoothScrollOffset != 0 { view.smoothScrollOffset = 0 }
    }

    private func programScrolled(_ lines: Int) {
        guard source == .program, model.isScrolling || CACurrentMediaTime() - model.lastInput < 0.15 else { return }
        // The program moved its content up `lines`: the grid moved toward the bottom.
        model.gridMoved(-lines, at: CACurrentMediaTime(), range: range)
        apply()
    }

    private func apply() {
        let offset = CGFloat(model.offset) * cellHeight
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
            guard time.isFinite else { self.reset(); self.animating = false; return false }
            let interval = self.lastStep.map { min(0.05, time - $0) } ?? 1.0 / Double(frames.targetRate)
            self.lastStep = time
            let active = self.model.step(at: CACurrentMediaTime(), interval: interval, range: self.range)
            self.apply()
            if !active { self.lastStep = nil; self.animating = false }
            return active
        }
    }
}
