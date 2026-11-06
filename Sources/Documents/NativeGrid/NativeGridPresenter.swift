import AppKit
import SwiftTerm

/// Main-actor half of the native client: applies the reader's ordered items to the editor's
/// terminal buffer, drives the selection correlation and the per-buffer snapshot cache, and
/// carries input back to Neovim.
///
/// Frames are written to the existing SwiftTerm buffer, so row caching, glyph phases, paint
/// order, clipping, cursor drawing, accessibility and presentation are the terminal path's.
@MainActor
final class NativeGridPresenter {
    enum Phase: Equatable {
        case live
        /// A validated cached image of the requested buffer is on screen; Neovim's own
        /// confirmation for `token` has not arrived. Frames are tracked but not shown and
        /// typed input waits, so nothing can reach (or display) a different buffer.
        case speculative(token: UInt64)
    }

    weak var view: CodeTerminalView?
    weak var session: NeovimSession?
    let client: NeovimGridClient
    private(set) var phase = Phase.live
    private(set) var mirror = GridImage(cols: 1, rows: 1)
    private var displayed: GridImage?
    private var displayedEpoch = -1
    private var displayedDefaults = -1
    private var pendingScrolls: [GridScroll] = []
    private let styles = GridStyleTable()
    private var modeInfos: [GridModeInfo] = []
    private var modeIndex = 0
    private var busy = false
    private(set) var cache = GridSnapshotCache() { didSet { retainCachedRows() } }
    /// Rows displaced by a speculative install: they still show the previous buffer's image, which the
    /// editor reports (`neolink_leave`) a moment later, and then become that buffer's cached rows.
    private var parked: (lines: [BufferLine], image: GridImage?)?
    private(set) var geometryReuses = 0
    /// Rows Neovim's confirmation had to rewrite after a cached image was shown (0 when the image was exact).
    private(set) var speculationCorrections = 0
    private(set) var confirmedSpeculations = 0
    private var diagnosticsEnabled = true
    private var queuedInput: [String] = []
    private var queuedInputBytes = 0
    private var wakeScheduled = false
    private(set) var requestedSize = (cols: 0, rows: 0)
    private(set) var framesApplied = 0
    private(set) var rowsWritten = 0
    private(set) var speculations = 0
    private(set) var speculationRejections: [String: Int] = [:]
    private(set) var staleFramesHeld = 0
    var onClosed: ((String) -> Void)?

    init(client: NeovimGridClient) {
        self.client = client
        client.onWake = { [weak self] in
            // One main-queue hop per empty→non-empty transition. The display deadline also drains.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.wakeFromReader() } }
        }
    }

    // MARK: Draining

    private func wakeFromReader() { drain() }

    /// Applies everything the reader has published. Idempotent; called from the main queue wake
    /// and from the owning display deadline.
    func drain() {
        let items = client.mailbox.drain()
        for item in items { apply(item) }
        flushIfAllowed()
    }

    private func apply(_ item: NativeGridItem) {
        switch item {
        case .frame(let frame): absorb(frame)
        case .selection(let token, let path): acknowledge(token: token, path: path)
        case .leave(let path, let mode, let popup, let diagnostics): recordLeave(path: path, mode: mode, popupVisible: popup, diagnostics: diagnostics)
        case .touch(let path): cache.invalidate(path: path)
        case .closed(let reason): onClosed?(reason)
        }
    }

    private func absorb(_ frame: GridFrame) {
        framesApplied += 1
        styles.absorb(frame)
        if frame.resized || frame.cols != mirror.cols || frame.rowCount != mirror.rowCount { pendingScrolls.removeAll() }
        else { pendingScrolls.append(contentsOf: frame.scrolls); if pendingScrolls.count > 64 { pendingScrolls.removeAll() } }
        mirror.apply(frame)
        if let infos = frame.modeInfos { modeInfos = infos }
        modeIndex = frame.modeIndex
        busy = frame.busy
    }

    // MARK: Selection and cache

    private func acknowledge(token: UInt64, path: String) {
        cache.remove(path)
        var confirming = false
        if case .speculative(let expected) = phase {
            // An echo for an older selection must neither end the current speculation nor
            // replace the cached image that is on screen with an intermediate buffer.
            guard expected == token else { return }
            phase = .live
            confirming = true
        }
        pendingScrolls.removeAll()
        let writtenBefore = rowsWritten
        flushIfAllowed(force: true)
        if confirming { confirmedSpeculations += 1; speculationCorrections += rowsWritten - writtenBefore }
        let queued = queuedInput
        queuedInput.removeAll(); queuedInputBytes = 0
        session?.nativeSelectionAcknowledged(token)
        for keys in queued { client.input(keys) }
    }

    private func recordLeave(path: String, mode: String, popupVisible: Bool, diagnostics: Bool) {
        diagnosticsEnabled = diagnostics
        defer { parked = nil }
        guard let view else { return }
        let terminal = view.getTerminal()
        guard mode.hasPrefix("i"), !popupVisible, mirror.cols == terminal.cols, mirror.rowCount == terminal.rows else {
            cache.remove(path); return
        }
        var lines: [BufferLine] = []
        if let parked, parked.image?.rows == mirror.rows, parked.image?.cols == mirror.cols {
            lines = parked.lines   // detached when the next buffer's image replaced it
        } else if phase == .live, !isVisible, let shown = displayed, shown.rows == mirror.rows {
            // The screen is hidden and about to be replaced by the next buffer: detach the rows that show
            // this buffer instead of overwriting them, and give the terminal blank rows to draw into.
            let spares = (0..<terminal.rows).map { _ in BufferLine(cols: terminal.cols) }
            var detached: [BufferLine]?
            view.externalGridUpdate { _ in detached = view.externalGridExchange(spares) }
            if let detached { lines = detached; displayed = nil; pendingScrolls.removeAll() }
        }
        cache.store(.init(image: mirror, styleEpoch: styles.epoch, diagnosticsEnabled: diagnostics,
                          signature: FileSignature.current(path: path), lines: lines), for: path)
    }

    private func retainCachedRows() {
        view?.metalRetainedLines = cache.entries.values.flatMap(\.lines)
    }

    /// Shows the cached image of `path` immediately when it is provably what Neovim will draw.
    /// Returns false (and shows nothing) otherwise; the caller then waits for Neovim's flush.
    func speculate(path: String, token: UInt64) -> Bool {
        drain()   // apply pending touch/leave notices first
        guard phase == .live, let view else { return reject("busy") }
        let terminal = view.getTerminal()
        guard let entry = cache.entries[path] else { return reject("none") }
        guard entry.image.cols == terminal.cols, entry.image.rowCount == terminal.rows else { return reject("size") }
        guard entry.styleEpoch == styles.epoch else { return reject("style") }
        guard entry.diagnosticsEnabled == diagnosticsEnabled else { return reject("diagnostics") }
        guard entry.signature == FileSignature.current(path: path), entry.signature != nil else { return reject("file") }
        phase = .speculative(token: token)
        pendingScrolls.removeAll()
        cache.remove(path)   // consumed: its rows are about to be live (or are rewritten below)
        // Always install a separate set of rows for the shown image: the rows currently displayed belong to
        // the buffer being left, and become its cached rows when the editor reports the leave.
        let reuse = entry.lines.count == terminal.rows
        let replacement = reuse ? entry.lines : (0..<terminal.rows).map { _ in BufferLine(cols: terminal.cols) }
        var displaced: [BufferLine]?
        view.externalGridUpdate { _ in displaced = view.externalGridExchange(replacement) }
        if let displaced {
            parked = (displaced, displayed)
            displayed = reuse ? entry.image : nil   // fresh rows are written below
            if reuse { geometryReuses += 1 }
        } else { parked = nil }
        present(entry.image, cursorModeName: "insert", force: true)
        speculations += 1
        return true
    }

    private func reject(_ reason: String) -> Bool {
        speculationRejections[reason, default: 0] += 1
        return false
    }

    /// A tab change that does not involve a Neovim `open` (for example, to a shell) still lets the
    /// editor record exactly what is on screen; the session sends the `leave` command.
    func cancelSpeculation() {
        guard case .speculative = phase else { return }
        phase = .live
        queuedInput.removeAll(); queuedInputBytes = 0
    }

    // MARK: Writing to the terminal

    private var isVisible: Bool {
        guard let view else { return false }
        return !view.isHiddenOrHasHiddenAncestor && view.window?.isVisible == true
    }

    private func flushIfAllowed(force: Bool = false) {
        guard phase == .live, force || isVisible else { return }
        present(mirror, cursorModeName: nil, force: force)
    }

    private func present(_ image: GridImage, cursorModeName: String?, force: Bool) {
        guard let view else { return }
        let terminal = view.getTerminal()
        guard terminal.cols == image.cols, terminal.rows == image.rowCount else { staleFramesHeld += 1; return }
        let sizeChanged = displayed == nil || displayed!.cols != image.cols || displayed!.rowCount != image.rowCount
        let restyle = displayedEpoch != styles.epoch || displayedDefaults != styles.defaultsRevision
        let cursorChanged = displayed.map { $0.cursorRow != image.cursorRow || $0.cursorColumn != image.cursorColumn } ?? true
        if !sizeChanged, !restyle, !cursorChanged, displayed!.rows == image.rows, pendingScrolls.isEmpty { return }
        if displayedDefaults != styles.defaultsRevision {
            view.nativeForegroundColor = NSColor(hex: styles.defaults.foreground)
            view.nativeBackgroundColor = NSColor(hex: styles.defaults.background)
        }
        var shown = sizeChanged ? GridImage(cols: image.cols, rows: image.rowCount) : displayed!
        let info = cursorInfo(named: cursorModeName)
        var written = 0
        let attributes = AttributeCache(styles: styles)
        view.noteExternalOutput()
        view.externalGridUpdate { terminal in
            if !sizeChanged {
                for scroll in pendingScrolls {
                    terminal.externalGridScroll(top: scroll.top, bottom: scroll.bottom, lines: scroll.lines)
                    shown.scroll(scroll)
                }
            }
            pendingScrolls.removeAll()
            for row in 0..<image.rowCount where sizeChanged || restyle || shown.rows[row] != image.rows[row] {
                terminal.externalGridSetRow(row, cells: Self.cells(for: image.rows[row], terminal: terminal, attributes: attributes))
                shown.rows[row] = image.rows[row]
                written += 1
            }
            terminal.externalGridSetCursor(column: image.cursorColumn, row: image.cursorRow)
            terminal.setCursorStyle(info)
            if busy { terminal.hideCursor() } else { terminal.showCursor() }
        }
        shown.cursorRow = image.cursorRow; shown.cursorColumn = image.cursorColumn
        displayed = shown
        displayedEpoch = styles.epoch; displayedDefaults = styles.defaultsRevision
        rowsWritten += written
    }

    private func cursorInfo(named name: String?) -> CursorStyle {
        var info = modeIndex < modeInfos.count ? modeInfos[modeIndex] : GridModeInfo()
        if let name, let match = modeInfos.first(where: { $0.name == name }) { info = match }
        switch (info.shape, info.blinks) {
        case (.block, true): return .blinkBlock
        case (.block, false): return .steadyBlock
        case (.horizontal, true): return .blinkUnderline
        case (.horizontal, false): return .steadyUnderline
        case (.vertical, true): return .blinkBar
        case (.vertical, false): return .steadyBar
        }
    }

    /// Per-write cache of `GridStyleTable` → terminal attribute.
    final class AttributeCache {
        private let styles: GridStyleTable
        private var values: [Int32: Attribute] = [:]
        init(styles: GridStyleTable) { self.styles = styles }
        func attribute(for id: Int32) -> Attribute {
            if let value = values[id] { return value }
            let value = Terminal.externalAttribute(styles.style(for: id))
            values[id] = value
            return value
        }
    }

    static func cells(for row: [GridCell], terminal: Terminal, attributes: AttributeCache) -> [CharData] {
        var output: [CharData] = []
        output.reserveCapacity(row.count)
        var previousWide = false
        for index in 0..<row.count {
            let cell = row[index]
            let attribute = attributes.attribute(for: cell.hl)
            if cell.text.isEmpty {
                output.append(terminal.externalCell(text: "", width: 1, continuation: previousWide, attribute: attribute))
                previousWide = false
            } else {
                let wide = index + 1 < row.count && row[index + 1].text.isEmpty
                output.append(terminal.externalCell(text: cell.text, width: wide ? 2 : 1, continuation: false, attribute: attribute))
                previousWide = wide
            }
        }
        return output
    }

    // MARK: Input and resize

    var acceptsInputImmediately: Bool { phase == .live }

    func send(keys: String) {
        guard !keys.isEmpty else { return }
        if case .speculative = phase {
            guard queuedInputBytes + keys.utf8.count <= 4096 else { return }
            queuedInput.append(keys); queuedInputBytes += keys.utf8.count
        } else {
            client.input(keys)
        }
    }

    func paste(_ text: String) {
        if case .speculative = phase { send(keys: NeovimKeyEncoder.escape(text: text)); return }
        client.paste(text)
    }

    func mouse(button: String, action: String, modifier: String, row: Int, column: Int) {
        if case .speculative = phase { return }   // a pointer event cannot target a buffer that is not confirmed yet
        client.mouse(button: button, action: action, modifier: modifier, row: row, column: column)
    }

    func viewResized(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, (cols, rows) != (requestedSize.cols, requestedSize.rows) else { return }
        requestedSize = (cols, rows)
        cache.removeAll(); parked = nil   // images and rows of another size can never be shown
        client.resize(cols: cols, rows: rows)
    }

    func prepareTerminal(_ view: CodeTerminalView) {
        self.view = view
        view.getTerminal().externalGridEnter()
        retainCachedRows()
    }

    func forget(_ path: String) { cache.remove(path) }

    func shutdown() {
        client.onWake = nil
        client.detach()
    }
}

extension GridImage {
    /// Mirrors `Terminal.externalGridScroll` on the displayed rows; exposed rows are blank.
    mutating func scroll(_ scroll: GridScroll) {
        let top = scroll.top, bottom = min(scroll.bottom, rows.count), lines = scroll.lines
        guard top >= 0, top < bottom, lines != 0 else { return }
        let blank = Array(repeating: GridCell.blank, count: cols)
        let amount = min(abs(lines), bottom - top)
        if lines > 0 {
            for row in top..<(bottom - amount) { rows[row] = rows[row + amount] }
            for row in (bottom - amount)..<bottom { rows[row] = blank }
        } else {
            for row in stride(from: bottom - 1, through: top + amount, by: -1) { rows[row] = rows[row - amount] }
            for row in top..<(top + amount) { rows[row] = blank }
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
