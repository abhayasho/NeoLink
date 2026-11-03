//
//  MacSmoothScroll.swift
//
//  NeoLink addition: state for drawing a scroll region at a fractional-line offset with the
//  Metal renderer. A terminal grid only moves by whole lines; the renderer translates the
//  region's cached rows and fills the exposed edge with neighbouring lines, so a host can
//  follow trackpad input pixel by pixel.
//
#if os(macOS) && canImport(MetalKit)
import AppKit
import Metal

public enum SmoothScrollSource {
    /// The local scrollback: neighbouring lines come from the buffer above and below the viewport.
    case scrollback
    /// A full-screen program (an editor or pager) that scrolls its own region. Neighbouring
    /// lines are those the program recently scrolled out of that region.
    case program
}

/// Lines that recently left a program's scroll region, newest adjacent to the region edge.
struct RetainedScrollLines {
    private(set) var top = 0
    private(set) var bottom = -1
    /// `above.last` is the line just above the region's top row.
    private(set) var above: [BufferLine] = []
    /// `below.last` is the line just below the region's bottom row.
    private(set) var below: [BufferLine] = []
    private var buffer: ObjectIdentifier?
    private var size = (rows: 0, cols: 0)
    static let limit = 256

    mutating func record(top: Int, bottom: Int, lines: Int, removed: [BufferLine],
                         buffer: ObjectIdentifier, rows: Int, cols: Int) {
        if top != self.top || bottom != self.bottom || buffer != self.buffer || rows != size.rows || cols != size.cols {
            self = RetainedScrollLines()
            self.top = top; self.bottom = bottom; self.buffer = buffer; size = (rows, cols)
        }
        let height = bottom - top + 1
        guard lines != 0, abs(lines) < height, removed.count == abs(lines) else {
            above.removeAll(); below.removeAll()
            return
        }
        if lines > 0 {
            above.append(contentsOf: removed)
            below.removeLast(min(lines, below.count))
        } else {
            above.removeLast(min(-lines, above.count))
            below.append(contentsOf: removed.reversed())
        }
        if above.count > Self.limit { above.removeFirst(above.count - Self.limit) }
        if below.count > Self.limit { below.removeFirst(below.count - Self.limit) }
    }

    func isValid(buffer: ObjectIdentifier, rows: Int, cols: Int) -> Bool {
        buffer == self.buffer && rows == size.rows && cols == size.cols && bottom >= top
    }

    mutating func discard() { above.removeAll(); below.removeAll() }
}

/// What the renderer needs to draw one frame of a smooth-scrolled region.
struct SmoothScrollPlan {
    enum Neighbour {
        case retained(BufferLine)
        case row(Int)
    }
    /// Visible row range of the region.
    let top: Int
    let bottom: Int
    /// Points; positive draws the region lower.
    let offset: CGFloat
    /// Index 0 is adjacent to the region edge.
    let above: [Neighbour]
    let below: [Neighbour]
}

extension TerminalView {
    /// Compiles the Metal shader library and pipelines that every terminal view shares,
    /// so the first terminal or editor does not compile them on the main thread.
    public static func prepareMetalRenderer() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        MetalTerminalRenderer.prepareSharedResources(device: device, pixelFormat: .bgra8Unorm)
    }

    func installSmoothScrollObservers() {
        terminal.regionScrollObserver = { [weak self] top, bottom, lines, removed in
            guard let self else { return }
            let buffer = self.terminal.displayBuffer
            self.retainedScrollLines.record(top: top, bottom: bottom, lines: lines, removed: removed,
                                            buffer: ObjectIdentifier(buffer), rows: buffer.rows, cols: buffer.cols)
            if self.metalView != nil {
                for row in (buffer.yBase + top)...(buffer.yBase + bottom) where row >= 0 && row < buffer.lines.count {
                    self.metalMovedLines.insert(ObjectIdentifier(buffer.lines[row]))
                }
            }
            self.programScrolled?(lines)
        }
        terminal.screenErasedObserver = { [weak self] in self?.retainedScrollLines.discard() }
        terminal.marginScrollObserver = { [weak self] lines in
            // Rows around the region changed in part; earlier retained lines no longer border it.
            self?.retainedScrollLines.discard()
            self?.programScrolledWithinMargins?(lines)
        }
    }

    /// Lines moved on screen by a viewport scroll keep their cached Metal geometry.
    func noteViewportMoved() {
        guard metalView != nil else { return }
        let buffer = terminal.displayBuffer
        for row in buffer.yDisp..<min(buffer.lines.count, buffer.yDisp + buffer.rows) {
            metalMovedLines.insert(ObjectIdentifier(buffer.lines[row]))
        }
    }

    /// Drops lines retained from earlier program scrolls, for example before a new gesture.
    public func discardRetainedScrollLines() { retainedScrollLines.discard() }

    /// Moves the scrollback viewport toward the top by `lines` (negative: toward the
    /// bottom) and returns the number of lines it actually moved.
    public func scrollViewport(towardTop lines: Int) -> Int {
        let before = terminal.displayBuffer.yDisp
        scrollTo(row: before - lines)
        return before - terminal.displayBuffer.yDisp
    }

    public var isDisplayingAlternateScreen: Bool { terminal.isDisplayBufferAlternate }

    /// Offsets, in points, that neighbouring lines can currently fill for `smoothScrollSource`.
    public var smoothScrollRange: ClosedRange<CGFloat> {
        let height = cellDimension?.height ?? 0
        guard height > 0, isUsingMetalRenderer, metalBufferingMode == .perRowPersistent else { return 0...0 }
        let buffer = terminal.displayBuffer
        switch smoothScrollSource {
        case .scrollback:
            let above = min(buffer.yDisp, buffer.rows)
            let below = min(max(0, buffer.lines.count - buffer.rows - buffer.yDisp), buffer.rows)
            return -CGFloat(below) * height...CGFloat(above) * height
        case .program:
            guard retainedScrollLines.isValid(buffer: ObjectIdentifier(buffer), rows: buffer.rows, cols: buffer.cols) else { return 0...0 }
            return -CGFloat(retainedScrollLines.below.count) * height...CGFloat(retainedScrollLines.above.count) * height
        }
    }

    func smoothScrollPlan() -> SmoothScrollPlan? {
        guard smoothScrollOffset != 0, let height = cellDimension?.height, height > 0 else { return nil }
        let range = smoothScrollRange
        let offset = min(max(smoothScrollOffset, range.lowerBound), range.upperBound)
        guard offset != 0 else { return nil }
        let needed = Int((abs(offset) / height).rounded(.up))
        let buffer = terminal.displayBuffer
        switch smoothScrollSource {
        case .scrollback:
            let above = offset > 0 ? (1...needed).map { SmoothScrollPlan.Neighbour.row(buffer.yDisp - $0) } : []
            let below = offset < 0 ? (0..<needed).map { SmoothScrollPlan.Neighbour.row(buffer.yDisp + buffer.rows + $0) } : []
            return SmoothScrollPlan(top: 0, bottom: buffer.rows - 1, offset: offset, above: above, below: below)
        case .program:
            let retained = retainedScrollLines
            let above = offset > 0 ? retained.above.suffix(needed).reversed().map { SmoothScrollPlan.Neighbour.retained($0) } : []
            let below = offset < 0 ? retained.below.suffix(needed).reversed().map { SmoothScrollPlan.Neighbour.retained($0) } : []
            return SmoothScrollPlan(top: retained.top, bottom: retained.bottom, offset: offset, above: above, below: below)
        }
    }
}
#endif
