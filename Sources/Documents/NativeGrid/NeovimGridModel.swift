import Foundation

/// One screen cell as Neovim reports it. `text` is a grapheme cluster; an empty string is the
/// right half of the double-width cell before it.
struct GridCell: Equatable, Sendable {
    var text: String
    var hl: Int32
    static let blank = GridCell(text: " ", hl: 0)
}

/// A Neovim highlight definition (`hl_attr_define`). Colours are 0xRRGGBB; nil is "default".
struct GridHighlight: Equatable, Sendable {
    var foreground: UInt32?
    var background: UInt32?
    var special: UInt32?
    var reverse = false
    var italic = false
    var bold = false
    var strikethrough = false
    /// 0 none, 1 underline, 2 undercurl, 3 underdouble, 4 underdotted, 5 underdashed
    var underline: UInt8 = 0

    init() {}
    init(rgb: MsgPackValue) {
        func color(_ key: String) -> UInt32? { rgb[key]?.uint32Value.map { $0 & 0xffffff } }
        func flag(_ key: String) -> Bool { rgb[key]?.boolValue ?? false }
        foreground = color("foreground"); background = color("background"); special = color("special")
        reverse = flag("reverse"); italic = flag("italic"); bold = flag("bold"); strikethrough = flag("strikethrough")
        if flag("underline") { underline = 1 }
        if flag("undercurl") { underline = 2 }
        if flag("underdouble") { underline = 3 }
        if flag("underdotted") { underline = 4 }
        if flag("underdashed") { underline = 5 }
    }
}

struct GridDefaults: Equatable, Sendable {
    var foreground: UInt32 = 0xd8d8d8
    var background: UInt32 = 0x181818
    var special: UInt32 = 0xff0000
}

enum GridCursorShape: Equatable, Sendable { case block, horizontal, vertical }

struct GridModeInfo: Equatable, Sendable {
    var shape: GridCursorShape = .block
    var blinks = false
    var name = ""
}

/// The complete visible screen. Rows are copy-on-write arrays, so snapshots are cheap.
struct GridImage: Equatable, Sendable {
    var cols: Int
    var rows: [[GridCell]]
    var cursorRow = 0
    var cursorColumn = 0

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = Array(repeating: Array(repeating: .blank, count: cols), count: rows)
    }
    var rowCount: Int { rows.count }

    mutating func apply(_ frame: GridFrame) {
        if frame.cols != cols || frame.rowCount != rows.count {
            cols = frame.cols
            rows = Array(repeating: Array(repeating: .blank, count: cols), count: frame.rowCount)
        }
        for (index, cells) in frame.rowUpdates where index >= 0 && index < rows.count && cells.count == cols { rows[index] = cells }
        cursorRow = frame.cursorRow; cursorColumn = frame.cursorColumn
    }
}

/// A full-width scroll of rows `top..<bottom`; `lines` > 0 moves content up.
struct GridScroll: Equatable, Sendable {
    var top: Int
    var bottom: Int
    var lines: Int
}

/// An immutable batch of changes between two Neovim `flush` events. Frames merge: applying
/// a merged frame equals applying its parts in order.
struct GridFrame: Sendable {
    var serial: UInt64 = 0
    var cols: Int
    var rowCount: Int
    /// Rows whose content differs from the previously emitted frame (every row after a resize).
    var rowUpdates: [Int: [GridCell]] = [:]
    /// Full-width scrolls in event order. A hint only: the final rows in `rowUpdates` are authoritative,
    /// but replaying the scrolls first lets the renderer keep and translate the rows that merely moved.
    var scrolls: [GridScroll] = []
    var resized = false
    var highlights: [Int32: GridHighlight] = [:]
    var defaults: GridDefaults?
    var modeInfos: [GridModeInfo]?
    var modeIndex = 0
    var cursorRow = 0
    var cursorColumn = 0
    var busy = false
    /// Increments whenever an existing highlight, or the default colours, change meaning.
    var styleEpoch = 0

    func merging(_ later: GridFrame) -> GridFrame {
        var merged = later
        merged.serial = later.serial
        if later.resized { return merged.withEarlierStyles(self) }
        merged.rowUpdates = rowUpdates.merging(later.rowUpdates) { _, new in new }
        merged.scrolls = scrolls + later.scrolls
        if cols != later.cols || rowCount != later.rowCount { merged.resized = true }
        else { merged.resized = resized }
        return merged.withEarlierStyles(self)
    }

    private func withEarlierStyles(_ earlier: GridFrame) -> GridFrame {
        var result = self
        result.highlights = earlier.highlights.merging(highlights) { _, new in new }
        result.defaults = defaults ?? earlier.defaults
        result.modeInfos = modeInfos ?? earlier.modeInfos
        return result
    }
}

/// Applies Neovim `redraw` events to a grid. Not thread safe: one reader owns it.
/// Only `ext_linegrid` events for the default grid (1) are interpreted.
final class NeovimGridModel {
    private(set) var cols: Int
    private(set) var rowCount: Int
    private var grid: [[GridCell]]
    private var emitted: [[GridCell]]
    private var dirty: Set<Int> = []
    private var scrolls: [GridScroll] = []
    private var resizedSinceFrame = true
    private(set) var highlights: [Int32: GridHighlight] = [:]
    private var changedHighlights: [Int32: GridHighlight] = [:]
    private(set) var defaults = GridDefaults()
    private var defaultsChanged = true
    private var modeInfos: [GridModeInfo] = []
    private var modeInfosChanged = false
    private(set) var modeIndex = 0
    private(set) var cursorRow = 0
    private(set) var cursorColumn = 0
    private(set) var busy = false
    private(set) var styleEpoch = 0
    private var serial: UInt64 = 0
    private var hasChanges = true

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = max(1, cols); self.rowCount = max(1, rows)
        grid = Array(repeating: Array(repeating: .blank, count: self.cols), count: self.rowCount)
        emitted = []
    }

    var image: GridImage {
        var image = GridImage(cols: cols, rows: rowCount)
        image.rows = grid; image.cursorRow = cursorRow; image.cursorColumn = cursorColumn
        return image
    }

    /// Applies one `redraw` notification's parameters: an array of `[name, args...]` events.
    func apply(redraw events: [MsgPackValue]) {
        for event in events {
            guard case .array(let items) = event, let name = items.first?.stringValue else { continue }
            let calls = items.dropFirst()
            switch name {
            case "grid_line": for call in calls { gridLine(call) }
            case "grid_scroll": for call in calls { gridScroll(call) }
            case "grid_cursor_goto":
                for call in calls { if let a = call.arrayValue, a.count >= 3, a[0].intValue == 1, let r = a[1].intValue, let c = a[2].intValue {
                    cursorRow = r; cursorColumn = c; hasChanges = true } }
            case "grid_resize":
                for call in calls { if let a = call.arrayValue, a.count >= 3, a[0].intValue == 1, let w = a[1].intValue, let h = a[2].intValue { resize(cols: w, rows: h) } }
            case "grid_clear":
                for call in calls { if let a = call.arrayValue, a.first?.intValue == 1 { clear() } }
            case "hl_attr_define": for call in calls { defineHighlight(call) }
            case "default_colors_set": for call in calls { setDefaults(call) }
            case "mode_info_set": for call in calls { setModeInfos(call) }
            case "mode_change":
                for call in calls { if let a = call.arrayValue, a.count >= 2, let index = a[1].intValue { modeIndex = index; hasChanges = true } }
            case "busy_start": busy = true; hasChanges = true
            case "busy_stop": busy = false; hasChanges = true
            default: break
            }
        }
    }

    private func resize(cols newCols: Int, rows newRows: Int) {
        guard newCols > 0, newRows > 0, newCols <= 4096, newRows <= 4096 else { return }
        cols = newCols; rowCount = newRows
        grid = Array(repeating: Array(repeating: .blank, count: newCols), count: newRows)
        dirty.removeAll(); scrolls.removeAll(); resizedSinceFrame = true; hasChanges = true
        cursorRow = min(cursorRow, newRows - 1); cursorColumn = min(cursorColumn, newCols - 1)
    }

    private func clear() {
        let blank = Array(repeating: GridCell.blank, count: cols)
        for row in 0..<rowCount { grid[row] = blank; dirty.insert(row) }
        hasChanges = true
    }

    private func gridLine(_ call: MsgPackValue) {
        guard let a = call.arrayValue, a.count >= 4, a[0].intValue == 1, let row = a[1].intValue, var column = a[2].intValue,
              case .array(let cells) = a[3], row >= 0, row < rowCount, column >= 0, column <= cols else { return }
        var line = grid[row]
        grid[row] = []   // keep `line` uniquely referenced while mutating
        var hl: Int32 = 0
        for cell in cells {
            guard case .array(let fields) = cell, let first = fields.first, case .string(let text) = first else { continue }
            if fields.count > 1, let id = fields[1].intValue { hl = Int32(truncatingIfNeeded: id) }
            var repeats = 1
            if fields.count > 2, let count = fields[2].intValue { repeats = count }
            guard repeats > 0 else { continue }
            let value = GridCell(text: text, hl: hl)
            let end = min(cols, column + repeats)
            if column < end { for x in column..<end { line[x] = value } }
            column = end
        }
        grid[row] = line
        dirty.insert(row); hasChanges = true
    }

    private func gridScroll(_ call: MsgPackValue) {
        guard let a = call.arrayValue, a.count >= 6, a[0].intValue == 1, let top = a[1].intValue, let bottom = a[2].intValue,
              let left = a[3].intValue, let right = a[4].intValue, let amount = a[5].intValue,
              top >= 0, bottom <= rowCount, top < bottom, left >= 0, right <= cols, left < right, amount != 0 else { return }
        let full = left == 0 && right == cols
        func copy(_ destination: Int, from source: Int) {
            if full { grid[destination] = grid[source] }
            else {
                var line = grid[destination]
                let origin = grid[source]
                grid[destination] = []
                for x in left..<right { line[x] = origin[x] }
                grid[destination] = line
            }
        }
        if amount > 0 {
            for row in top..<max(top, bottom - amount) { copy(row, from: row + amount) }
        } else {
            for row in stride(from: bottom - 1, through: top - amount, by: -1) { copy(row, from: row + amount) }
        }
        for row in top..<bottom { dirty.insert(row) }
        if full {
            if scrolls.count >= 64 { scrolls.removeAll() }   // bounded; rows are still authoritative
            else { scrolls.append(GridScroll(top: top, bottom: bottom, lines: amount)) }
        }
        hasChanges = true
    }

    private func defineHighlight(_ call: MsgPackValue) {
        guard let a = call.arrayValue, a.count >= 2, let raw = a[0].intValue, let id = Int32(exactly: raw) else { return }
        let highlight = GridHighlight(rgb: a[1])
        if let existing = highlights[id], existing != highlight { styleEpoch += 1 }
        if highlights[id] != highlight { highlights[id] = highlight; changedHighlights[id] = highlight }
        hasChanges = true
    }

    private func setDefaults(_ call: MsgPackValue) {
        guard let a = call.arrayValue, a.count >= 3 else { return }
        var next = defaults
        if let value = a[0].uint32Value { next.foreground = value & 0xffffff }
        if let value = a[1].uint32Value { next.background = value & 0xffffff }
        if let value = a[2].uint32Value { next.special = value & 0xffffff }
        if next != defaults { defaults = next; styleEpoch += 1 }
        defaultsChanged = true; hasChanges = true
    }

    private func setModeInfos(_ call: MsgPackValue) {
        guard let a = call.arrayValue, a.count >= 2, case .array(let modes) = a[1] else { return }
        modeInfos = modes.map { mode in
            var info = GridModeInfo()
            switch mode["cursor_shape"]?.stringValue {
            case "horizontal": info.shape = .horizontal
            case "vertical": info.shape = .vertical
            default: info.shape = .block
            }
            info.blinks = (mode["blinkon"]?.intValue ?? 0) > 0 && (mode["blinkoff"]?.intValue ?? 0) > 0
            info.name = mode["name"]?.stringValue ?? ""
            return info
        }
        modeInfosChanged = true; hasChanges = true
    }

    /// Called at `flush`. Returns nil when nothing visible or stateful changed since the last call.
    func takeFrame() -> GridFrame? {
        guard hasChanges else { return nil }
        var frame = GridFrame(cols: cols, rowCount: rowCount)
        frame.resized = resizedSinceFrame
        if resizedSinceFrame || emitted.count != rowCount || emitted.first?.count != cols {
            for row in 0..<rowCount { frame.rowUpdates[row] = grid[row] }
            frame.resized = true
        } else {
            for row in dirty where emitted[row] != grid[row] { frame.rowUpdates[row] = grid[row] }
        }
        emitted = grid
        if !frame.resized { frame.scrolls = scrolls }
        scrolls.removeAll()
        dirty.removeAll(); resizedSinceFrame = false; hasChanges = false
        frame.highlights = changedHighlights; changedHighlights = [:]
        if defaultsChanged { frame.defaults = defaults; defaultsChanged = false }
        if modeInfosChanged { frame.modeInfos = modeInfos; modeInfosChanged = false }
        frame.modeIndex = modeIndex
        frame.cursorRow = cursorRow; frame.cursorColumn = cursorColumn
        frame.busy = busy
        frame.styleEpoch = styleEpoch
        serial &+= 1; frame.serial = serial
        return frame
    }
}
