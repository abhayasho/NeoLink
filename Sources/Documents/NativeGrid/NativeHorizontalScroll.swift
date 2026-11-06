import AppKit
import SwiftTerm

/// Pixel-smooth horizontal scrolling for the native Neovim client.
///
/// Neovim can only show whole columns, and every column it scrolls rewrites every row of the window (in the
/// renderer that is a full rebuild of the window's rows, about 10 ms on a large editor). Sending one wheel step
/// per column therefore produced a stream of heavy frames that each jumped a whole column. Here, the way the
/// vertical smooth scroll works:
///
/// - Finger input (in columns) is resampled at the display's cadence (`ScrollResampler`).
/// - Neovim is asked, a chunk of columns at a time, to put the window's leftcol ahead of the fingers
///   (`NeoLink.hscroll` in `neolink.lua`), so it redraws once per chunk instead of once per column.
/// - The renderer draws the window's text area translated by the sub-column remainder while the gutter and
///   other windows stay put (`ExternalHorizontalScroll`). The strip a translation exposes is drawn from the
///   rows that showed the previous chunk, which were detached rather than overwritten.
/// - When the gesture and its momentum end, the drawn position glides to a whole column in the direction of
///   travel and Neovim is asked for exactly that column, so at rest the screen is Neovim's own.
///
/// Typing, clicks, vertical scrolling, tab changes and resizes end a session at once on the nearest column.
@MainActor
final class NativeHorizontalScroll {
    static var enabled: Bool { ProcessInfo.processInfo.environment["NEOLINK_HSCROLL"] != "0" }
    static let maximumChunk = 24
    static let idleSettle = 0.08
    static let momentumWait = 0.03
    static let answerTimeout = 0.25
    /// New rows built per frame while retained rows still cover the view (about 1 ms of row preparation).
    static let rowsBuiltPerFrame = 6

    private unowned let presenter: NativeGridPresenter
    private(set) var isActive = false
    private var window: NativeHorizontalAnswer?
    /// Leftcol shown by the terminal's current rows (nil until the first answer of a session).
    private var leftcol: Int?
    /// Rows that showed earlier chunks, newest first: (all visible rows, their leftcol).
    private(set) var retained: [(lines: [BufferLine], leftcol: Int)] = []
    /// Where the fingers want the view, in leftcol units.
    private var position = 0.0
    private var unanchored = 0.0
    private var resampler = ScrollResampler()
    private var outstanding: (token: UInt64, target: Int?, sent: Double)?
    private var token: UInt64 = 0
    private var direction = 0
    private var lastInput = 0.0
    private var lifted = false
    private var settling: Int?
    private var highest: Int?
    private var mouse = (row: 0, column: 0)
    private var animating = false

    // Measurement.
    private(set) var requests = 0
    private(set) var flips = 0
    private(set) var sessions = 0
    var recordsSamples = false
    private(set) var samples: [(time: Double, drawn: Double, leftcol: Int)] = []

    init(presenter: NativeGridPresenter) { self.presenter = presenter }

    private(set) var steps = 0, answers = 0
    var diagnostics: String {
        "active=\(isActive) leftcol=\(leftcol.map(String.init) ?? "nil") position=\(position) drawn=\(drawn) outstanding=\(outstanding.map { "\($0.token)" } ?? "nil") settling=\(settling.map(String.init) ?? "nil") requests=\(requests) answers=\(answers) steps=\(steps) flips=\(flips) animating=\(animating) window=\(window.map { "\($0)" } ?? "nil")"
    }

    /// While a request is unanswered the terminal keeps showing the previous chunk: frames that already show
    /// the new leftcol are applied together with its answer, never before it.
    var holdsPresentation: Bool { outstanding != nil }

    private var cellWidth: Double {
        guard let view = presenter.view, let pixels = view.cellSizeInPixels(source: view.getTerminal()) else { return 8 }
        return Double(pixels.width) / Double(view.window?.backingScaleFactor ?? 2)
    }

    private var chunk: Int {
        guard let window else { return Self.maximumChunk }
        return max(4, min(Self.maximumChunk, (window.width - window.textOffset) / 3))
    }

    /// The position actually drawn: resampled, and never beyond what the current or retained rows cover.
    private var drawn: Double {
        guard let leftcol else { return position }
        let columns = [leftcol] + retained.map(\.leftcol)
        return min(Double(columns.max()!), max(Double(columns.min()!), position - resampler.lag))
    }

    // MARK: Input

    /// Horizontal trackpad input over (row, column); `points` as `scrollingDeltaX`. Returns whether it was used.
    func scroll(points: CGFloat, phase: SmoothScrollModel.Phase, row: Int, column: Int) -> Bool {
        let now = CACurrentMediaTime()
        let columns = -Double(points) / max(1, cellWidth)
        if !isActive {
            guard columns != 0 else { return false }
            begin(row: row, column: column, direction: columns > 0 ? 1 : -1)
        }
        if phase == .ended || phase == .momentumEnded { lifted = true }
        if columns == 0 { startAnimating(); return true }
        lifted = phase == .ended || phase == .momentumEnded
        settling = nil
        lastInput = now
        direction = columns > 0 ? 1 : -1
        guard leftcol != nil else { unanchored += columns; return true }
        move(by: columns, at: now)
        requestIfNeeded(at: now)
        startAnimating()
        return true
    }

    private func move(by columns: Double, at time: Double) {
        var next = max(0, position + columns)
        if let highest { next = min(Double(highest), next) }
        let applied = next - position
        position = next
        resampler.input(applied, at: time)
    }

    private func begin(row: Int, column: Int, direction: Int) {
        isActive = true
        sessions += 1
        mouse = (row, column)
        retained = []; leftcol = nil; window = nil; highest = nil
        resampler.reset(); resampler.framePeriod = framePeriod
        unanchored = 0; settling = nil; lifted = false
        self.direction = direction
        send(amount: direction * chunk, relative: true)
    }

    private var framePeriod: Double {
        1.0 / Double(max(30, WindowFrameScheduler.forWindow(presenter.view?.window)?.targetRate ?? 120))
    }

    private func send(amount: Int, relative: Bool) {
        token &+= 1
        outstanding = (token, relative ? nil : amount, CACurrentMediaTime())
        requests += 1
        presenter.client.horizontalScroll(token: token, row: mouse.row, column: mouse.column, amount: amount, relative: relative)
    }

    private func requestIfNeeded(at time: Double) {
        guard outstanding == nil, settling == nil, let leftcol else { return }
        let ahead = Double(chunk) / 2, current = drawn
        if direction > 0, Double(leftcol) - current < ahead, highest.map({ leftcol < $0 }) ?? true {
            send(amount: Int(current.rounded(.up)) + chunk, relative: false)
        } else if direction < 0, current - Double(leftcol) < ahead, leftcol > 0 {
            send(amount: max(0, Int(current.rounded(.down)) - chunk), relative: false)
        }
    }

    // MARK: Answers (in order with the frames, from the presenter)

    func answer(_ answer: NativeHorizontalAnswer) {
        answers += 1
        guard isActive, let request = outstanding, request.token == answer.token else { return }
        outstanding = nil
        window = answer
        let now = CACurrentMediaTime()
        if leftcol == nil {
            // First answer: the rows on screen show `before`; the fingers have already moved `unanchored`.
            leftcol = answer.before
            position = Double(answer.before)
            resampler.reset()
            move(by: unanchored, at: now)
            unanchored = 0
        }
        if answer.after != leftcol {
            if let rows = presenter.detachDisplayedRows() {
                retained.insert((rows, leftcol!), at: 0)
                if retained.count > 2 { retained.removeLast(retained.count - 2) }
                flips += 1
            } else {
                retained.removeAll()
            }
            leftcol = answer.after
        }
        // Neovim stopped short of a request to the right: that is as far as the view goes.
        let wanted = request.target ?? (answer.before + direction * chunk)
        if direction > 0, answer.after < wanted {
            highest = answer.after
            if position > Double(answer.after) { let excess = Double(answer.after) - position; position = Double(answer.after); resampler.absorb(excess, at: now) }
        }
        presenter.retainHorizontalRows()
        if settling == nil { requestIfNeeded(at: now) }
        startAnimating()
    }

    // MARK: Frames

    /// Tests drive frames themselves (`stepForTesting`); the app uses the window's display-paced scheduler.
    var drivesFramesManually = false
    func stepForTesting() { if isActive { _ = step(at: CACurrentMediaTime()) } }

    private func startAnimating() {
        guard !animating, !drivesFramesManually else { return }
        guard let frames = WindowFrameScheduler.forWindow(presenter.view?.window) else { abort(); return }
        animating = true
        frames.animate(ObjectIdentifier(self)) { [weak self] time in
            guard let self else { return false }
            guard self.isActive else { self.animating = false; return false }
            // No more display frames (occluded, minimized, closing): nothing is being watched, so show
            // Neovim's own screen now instead of leaving a band in place.
            guard time.isFinite else { self.animating = false; self.abort(); return false }
            let keep = self.step(at: CACurrentMediaTime())
            if !keep { self.animating = false }
            return keep
        }
    }

    private func step(at now: Double) -> Bool {
        steps += 1
        _ = resampler.advance(to: now)
        if let request = outstanding, now - request.sent > Self.answerTimeout { abort(); return false }
        guard let leftcol else { return true }
        if settling == nil, (lifted && now - lastInput >= Self.momentumWait) || now - lastInput >= Self.idleSettle {
            beginSettle(at: now)
        }
        if let target = settling {
            if !resampler.isCatchingUp, leftcol == target, outstanding == nil { finish(); return false }
            if outstanding == nil, leftcol != target { send(amount: target, relative: false) }
        } else {
            requestIfNeeded(at: now)
        }
        updateBand()
        if recordsSamples {
            samples.append((now, drawn, leftcol))
            if samples.count > 4000 { samples.removeFirst(samples.count - 4000) }
        }
        return true
    }

    private func beginSettle(at now: Double) {
        guard let leftcol else { return }
        let columns = [leftcol] + retained.map(\.leftcol)
        let current = drawn
        var target = direction > 0 ? Int((current - 0.02).rounded(.up)) : Int((current + 0.02).rounded(.down))
        target = min(columns.max()!, max(columns.min()!, target))
        settling = target
        move(by: Double(target) - position, at: now)
    }

    /// Typing, clicking, vertical scrolling: stop on the nearest column now, and let Neovim confirm it.
    func endNow() {
        guard isActive else { return }
        guard let leftcol else { abort(); return }
        let columns = [leftcol] + retained.map(\.leftcol)
        let target = min(columns.max()!, max(columns.min()!, Int(drawn.rounded())))
        settling = target
        position = Double(target)
        resampler.reset()
        if leftcol == target, outstanding == nil { finish(); return }
        if outstanding == nil { send(amount: target, relative: false) }
        updateBand()
        startAnimating()
    }

    /// Something replaced the screen (resize, tab change): drop the session without asking Neovim for anything.
    func abort() {
        guard isActive else { return }
        finish()
        presenter.drain()
    }

    private func finish() {
        isActive = false
        outstanding = nil
        settling = nil
        retained = []
        leftcol = nil
        presenter.view?.externalHorizontalScroll = nil
        presenter.retainHorizontalRows()
    }

    // MARK: Band

    private func updateBand() {
        guard let view = presenter.view, let leftcol, let window else { presenter.view?.externalHorizontalScroll = nil; return }
        let terminal = view.getTerminal()
        let textStart = max(0, window.column + window.textOffset)
        let textEnd = min(terminal.cols, window.column + window.width)
        let firstRow = max(0, window.row), lastRow = min(terminal.rows - 1, window.row + window.height - 1)
        guard textEnd > textStart, lastRow >= firstRow else { view.externalHorizontalScroll = nil; return }
        let scale = Double(view.window?.backingScaleFactor ?? 2)
        let cell = cellWidth * scale                                   // pixels per column
        let width = Double(textEnd - textStart)
        let current = drawn
        let startPixels = (Double(textStart) * cell).rounded()
        var uncovered: [(Double, Double)] = [(0, width)]               // columns from textStart
        var layers: [ExternalHorizontalScroll.Layer] = []
        // Retained rows first: they already have geometry. Right after a chunk arrives they still cover the view
        // (Neovim is ahead), so the new rows are only drawn where nothing older reaches, and the renderer builds
        // them a few per frame in the meantime instead of all in one frame.
        let sources: [(lines: [BufferLine]?, leftcol: Int)] = retained.map { ($0.lines, $0.leftcol) } + [(nil, leftcol)]
        for source in sources {
            // Whole device pixels: text stays on the pixel grid, and clip edges meet exactly.
            let offsetPixels = ((Double(source.leftcol) - current) * cell).rounded()
            let low = offsetPixels / cell, high = low + width
            var remaining: [(Double, Double)] = []
            for piece in uncovered {
                let from = max(piece.0, low), to = min(piece.1, high)
                if to > from {
                    let lines = source.lines.map { Array($0[firstRow...min(lastRow, $0.count - 1)]) }
                    layers.append(.init(lines: lines, offset: CGFloat(offsetPixels / scale),
                                        clipFrom: CGFloat((startPixels + from * cell) / scale), clipTo: CGFloat((startPixels + to * cell) / scale)))
                }
                if low > piece.0 { remaining.append((piece.0, min(piece.1, low))) }
                if high < piece.1 { remaining.append((max(piece.0, high), piece.1)) }
            }
            uncovered = remaining.filter { $0.1 - $0.0 > 0.001 }
        }
        view.externalHorizontalScroll = ExternalHorizontalScroll(rows: firstRow...lastRow, textStart: textStart, textEnd: textEnd, layers: layers,
                                                                 rebuildBudget: Self.rowsBuiltPerFrame)
    }
}
