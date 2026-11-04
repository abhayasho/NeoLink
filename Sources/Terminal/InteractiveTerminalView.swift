import AppKit
import Combine
import SwiftTerm

/// Accumulate trackpad fractions instead of turning every tiny event into a full line.
struct WheelScrollAccumulator {
    private var x: CGFloat = 0
    private var y: CGFloat = 0

    mutating func consume(x dx: CGFloat, y dy: CGFloat, precise: Bool, cell: CGSize, newGesture: Bool) -> (x: Int, y: Int) {
        if newGesture { x = 0; y = 0 }
        x += precise ? dx / max(1, cell.width) : dx
        y += precise ? dy / max(1, cell.height) : dy
        // Bound a single event so a device spike cannot flood the PTY.
        let stepsX = Int(min(80, max(-80, x)))
        let stepsY = Int(min(80, max(-80, y)))
        x -= CGFloat(stepsX); y -= CGFloat(stepsY)
        x = min(1, max(-1, x)); y = min(1, max(-1, y))
        return (stepsX, stepsY)
    }
}

/// SwiftTerm's macOS wheel handler scrolls history even when a TUI requested mouse input.
/// Forward wheel reports to that application; ordinary shells retain native scrollback.
class InteractiveTerminalView: LocalProcessTerminalView {
    private(set) lazy var rendering = TerminalRendering(view: self)
    var onActivate: (() -> Void)?
    private var wheel = WheelScrollAccumulator()
    private var fontObservation: AnyCancellable?
    private var wheelMonitor: Any?
    private lazy var smoothScroll = SmoothScrollDriver(view: self)
    /// For measurement: lines the input and the last drawn frame moved the content since the
    /// first smooth-scroll gesture, or nil if this terminal never smooth-scrolled.
    func scrollTraceSample() -> (input: Double, drawn: Double)? {
        smoothScroll.traceSample(drawnOffset: metalLastDrawnScrollOffset)
    }

    /// For measurement: lines requested from a full-screen program and lines it scrolled.
    var smoothScrollRequests: (requests: [(time: Double, lines: Int)], moves: [(time: Double, lines: Int)]) {
        (smoothScroll.requests, smoothScroll.moves)
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { smoothScroll.reset() }
        super.setFrameSize(newSize)
    }

    /// Native scrollback scrolls pixel by pixel with a trackpad; other input keeps SwiftTerm's line steps.
    /// Precise vertical scrolling, including the zero-delta events that end a gesture or its momentum.
    private func isSmoothVerticalScroll(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, smoothScroll.isAvailable else { return false }
        if event.scrollingDeltaY == 0 {
            return event.scrollingDeltaX == 0 && SmoothScrollDriver.phase(of: event) != .changed
        }
        return abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
    }

    private func smoothScrollback(_ event: NSEvent) -> Bool {
        guard !isDisplayingAlternateScreen, isSmoothVerticalScroll(event) else { return false }
        smoothScroll.scroll(event, source: .scrollback) { [weak self] lines in self?.scrollViewport(towardTop: lines) ?? 0 }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rendering.attachToWindow()
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if let editor = self as? CodeTerminalView { SelectionTrace.mark(editor.session?.selectionToken ?? 0, "pty.received") }
        rendering.noteOutput()
        smoothScroll.noteOutput(slice.count)
        super.dataReceived(slice: slice)
        if let editor = self as? CodeTerminalView { SelectionTrace.mark(editor.session?.selectionToken ?? 0, "pty.parsed") }
    }

    override func scrolled(source terminal: Terminal, yDisp: Int) {
        smoothScroll.viewportChanged(to: yDisp)
        super.scrolled(source: terminal, yDisp: yDisp)
    }

    func observeTextSize() {
        fontObservation = TextSizePreferences.shared.$pointSize.sink { [weak self] size in
            guard let self, self.font.pointSize != size else { return }
            self.smoothScroll.reset()
            self.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        if wheelMonitor == nil {
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor, let content = window.contentView,
                      let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
                      hit === self || hit.isDescendant(of: self) else { return event }
                if event.type == .leftMouseDown {
                    if window.firstResponder !== self { self.onActivate?() }
                    return event
                }
                return self.forwardWheel(event) || self.smoothScrollback(event) ? nil : event
            }
        }
    }

    deinit { if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) } }

    /// The wheel path for an event already known to target this view (used by the benchmark).
    func deliverWheel(_ event: NSEvent) { if !forwardWheel(event), !smoothScrollback(event) { scrollWheel(with: event) } }

    private func forwardWheel(_ event: NSEvent) -> Bool {
        let terminal = getTerminal()
        guard allowMouseReporting, terminal.mouseMode != .off else {
            return false
        }
        let pixels = cellSizeInPixels(source: terminal) ?? (width: 8, height: 16)
        let scale = window?.backingScaleFactor ?? 1
        let cell = CGSize(width: CGFloat(pixels.width) / scale, height: CGFloat(pixels.height) / scale)
        // Trackpad scrolling in a full-screen program follows the fingers pixel by pixel:
        // the program scrolls whole lines ahead and the renderer draws the remainder.
        let smooth = isDisplayingAlternateScreen && isSmoothVerticalScroll(event)
        let steps = wheel.consume(x: event.scrollingDeltaX, y: smooth ? 0 : event.scrollingDeltaY,
                                  precise: event.hasPreciseScrollingDeltas, cell: cell,
                                  newGesture: event.phase == .began)
        let point = convert(event.locationInWindow, from: nil)
        let topY = isFlipped ? point.y : bounds.height - point.y
        let col = min(max(0, Int(point.x / max(1, cell.width))), max(0, terminal.cols - 1))
        let row = min(max(0, Int(topY / max(1, cell.height))), max(0, terminal.rows - 1))
        func report(_ flag: Int, count: Int) {
            for _ in 0..<abs(count) {
                terminal.sendEvent(buttonFlags: flag, x: col, y: row,
                                   pixelX: max(0, Int(point.x)), pixelY: max(0, Int(topY)))
            }
        }
        if smooth {
            // Later requests (settling) report at the same cell.
            smoothScroll.scroll(event, source: .program) { [weak self] lines in
                guard let terminal = self?.getTerminal() else { return nil }
                for _ in 0..<min(80, abs(lines)) {
                    terminal.sendEvent(buttonFlags: lines > 0 ? 64 : 65, x: col, y: row,
                                       pixelX: max(0, Int(point.x)), pixelY: max(0, Int(topY)))
                }
                return nil
            }
        } else {
            report(steps.y > 0 ? 64 : 65, count: steps.y)
        }
        report(steps.x > 0 ? 66 : 67, count: steps.x)
        return true
    }
}
