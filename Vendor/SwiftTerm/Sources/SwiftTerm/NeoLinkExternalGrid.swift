//
//  NeoLinkExternalGrid.swift
//
//  NeoLink addition. A host that already owns a cell grid (for example Neovim's own
//  `ext_linegrid` UI events) can write whole rows straight into the active buffer
//  instead of encoding them as escape sequences for the parser. The existing row cache,
//  glyph atlas, cursor, selection and accessibility paths are reused unchanged.
//
//  All members must be called on the thread that owns the terminal (the main thread
//  for a `TerminalView`), exactly like `feed`.
//

import Foundation

/// A resolved cell style from the host. Colours are 0xRRGGBB; nil selects the terminal default.
public struct ExternalGridStyle: Equatable, Hashable {
    public enum Underline: UInt8 { case none = 0, single, double, curly, dotted, dashed }
    public var foreground: UInt32?
    public var background: UInt32?
    public var special: UInt32?
    public var bold = false
    public var italic = false
    public var strikethrough = false
    public var underline: Underline = .none
    public init() {}
    public init(foreground: UInt32?, background: UInt32?, special: UInt32? = nil, bold: Bool = false, italic: Bool = false,
                strikethrough: Bool = false, underline: Underline = .none) {
        self.foreground = foreground; self.background = background; self.special = special
        self.bold = bold; self.italic = italic; self.strikethrough = strikethrough; self.underline = underline
    }
}

extension Terminal {
    private static func externalColor(_ value: UInt32?, fallback: Attribute.Color) -> Attribute.Color {
        guard let value else { return fallback }
        return .trueColor(red: UInt8((value >> 16) & 0xff), green: UInt8((value >> 8) & 0xff), blue: UInt8(value & 0xff))
    }

    /// The cell attribute for a host style. A colour equal to nil uses the terminal's default
    /// foreground/background, which keeps the renderer's default-background fast path.
    public static func externalAttribute(_ style: ExternalGridStyle) -> Attribute {
        var flags: CharacterStyle = []
        if style.bold { flags.insert(.bold) }
        if style.italic { flags.insert(.italic) }
        if style.strikethrough { flags.insert(.crossedOut) }
        let underline: UnderlineStyle
        switch style.underline {
        case .none: underline = .none
        // Plain underline is the SGR 4 style flag, drawn by the same path as the parser's.
        case .single: underline = .none; flags.insert(.underline)
        case .double: underline = .double
        case .curly: underline = .curly
        case .dotted: underline = .dotted
        case .dashed: underline = .dashed
        }
        let underlineColor: Attribute.Color? = (style.underline != .none && style.special != nil)
            ? externalColor(style.special, fallback: .defaultColor) : nil
        return Attribute(fg: externalColor(style.foreground, fallback: .defaultColor),
                         bg: externalColor(style.background, fallback: .defaultColor), style: flags,
                         underlineStyle: underline, underlineColor: underlineColor)
    }

    /// One cell. `text` is a grapheme cluster ("" or " " is an empty cell); `width` is 1 or 2.
    /// The cell after a double-width character must be passed with `continuation: true`.
    public func externalCell(text: String, width: Int, continuation: Bool, attribute: Attribute) -> CharData {
        if continuation { return makeCharData(attribute: attribute, code: 0, size: 0) }
        // A blank cell is a space, as the parser would store it, so copied and accessible text has no NULs.
        guard let first = text.first, text != " " else { return makeCharData(attribute: attribute, scalar: " ", size: 1) }
        if text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first {
            return makeCharData(attribute: attribute, scalar: scalar, size: Int8(width))
        }
        // A multi-scalar cell is one grapheme cluster for Neovim. Keep it whole when Swift agrees.
        return makeCharData(attribute: attribute, char: first, size: Int8(width))
    }

    /// Selects the alternate screen once, hides scrollback and clears it.
    public func externalGridEnter() {
        if !isCurrentBufferAlternate { feed(text: "\u{1b}[?1049h") }
        feed(text: "\u{1b}[?25l")
    }

    /// Replaces one visible row. `cells.count` must equal `cols`.
    public func externalGridSetRow(_ y: Int, cells: [CharData]) {
        guard y >= 0, y < rows, cells.count == cols else { return }
        let line = buffer.lines[buffer.yBase + y]
        for x in 0..<cols { line[x] = cells[x] }
        line.isWrapped = false
        markingExternalRows { updateRange(y) }
    }

    /// Scrolls rows `top..<bottom` by whole lines through the terminal's own region scroll (the
    /// same operation as CSI S / CSI T), so line identity, the renderer's moved-line cache and the
    /// smooth-scroll observers behave exactly as for a program scrolling under the parser.
    /// `lines` > 0 moves content up. Exposed rows are blank until the host writes them.
    public func externalGridScroll(top: Int, bottom: Int, lines: Int) {
        guard lines != 0, top >= 0, bottom <= rows, top < bottom else { return }
        let savedTop = buffer.scrollTop, savedBottom = buffer.scrollBottom
        buffer.scrollTop = top
        buffer.scrollBottom = bottom - 1
        markingExternalRows {
            if lines > 0 { cmdScrollUp([lines], []) } else { cmdScrollDown([-lines]) }
            // The whole region is what a region scroll marks (its moved rows keep their geometry).
            externalUpdateRows?.insert(integersIn: top..<bottom)
        }
        buffer.scrollTop = savedTop
        buffer.scrollBottom = savedBottom
    }

    /// Replaces the visible rows' line objects with `lines` and returns the ones that were displayed.
    /// Line identity is what the Metal renderer's row cache is keyed by, so re-installing lines that were
    /// detached earlier (unchanged since) draws from retained geometry instead of rebuilding every row.
    /// Each line must have exactly `cols` cells. Returns nil, changing nothing, if the request is invalid.
    public func externalGridExchangeRows(_ lines: [BufferLine]) -> [BufferLine]? {
        guard lines.count == rows, buffer.yBase == 0, lines.allSatisfy({ $0.count == cols }) else { return nil }
        var displaced: [BufferLine] = []
        displaced.reserveCapacity(rows)
        for y in 0..<rows { displaced.append(buffer.lines[y]); buffer.lines[y] = lines[y] }
        markingExternalRows { updateRange(startLine: 0, endLine: rows - 1) }
        return displaced
    }

    public func externalGridSetCursor(column: Int, row: Int) {
        buffer.x = min(max(0, column), cols - 1)
        buffer.y = min(max(0, row), rows - 1)
        markingExternalRows { updateRange(buffer.y) }
    }

    /// The text of one visible row, for tests and accessibility comparisons.
    public func externalGridRowText(_ y: Int) -> String {
        guard y >= 0, y < rows else { return "" }
        return buffer.lines[buffer.yBase + y].translateToString(trimRight: true).replacingOccurrences(of: "\u{0}", with: " ")
    }
}

/// NeoLink: a horizontally scrolling band of rows (an editor window's text area) drawn at sub-cell pixel
/// offsets while the cells left and right of the band (a gutter, other windows) stay in place.
///
/// Each layer draws one set of row lines translated by `offset` and clipped to `clipFrom..<clipTo` (points
/// in view coordinates, intersected with the band). A layer whose `lines` is nil draws the buffer's current
/// rows; other layers draw lines the host retained from earlier horizontal positions, so the strip a
/// translation exposes shows real content instead of a gap. Hosts give layers disjoint clips.
public struct ExternalHorizontalScroll {
    public struct Layer {
        public var lines: [BufferLine]?
        public var offset: CGFloat
        public var clipFrom: CGFloat
        public var clipTo: CGFloat
        public init(lines: [BufferLine]?, offset: CGFloat, clipFrom: CGFloat, clipTo: CGFloat) {
            self.lines = lines; self.offset = offset; self.clipFrom = clipFrom; self.clipTo = clipTo
        }
    }
    /// Visible rows (0-based) of the band.
    public var rows: ClosedRange<Int>
    /// Columns [textStart, textEnd) that move.
    public var textStart: Int
    public var textEnd: Int
    public var layers: [Layer]
    /// Rows of the current lines the renderer may rebuild per frame when no layer needs them yet. A chunk of
    /// horizontal scrolling replaces every row; building them a few at a time, while retained layers still
    /// cover the view, keeps a whole-window rebuild out of any single frame. nil builds every row at once.
    public var rebuildBudget: Int?
    public init(rows: ClosedRange<Int>, textStart: Int, textEnd: Int, layers: [Layer], rebuildBudget: Int? = nil) {
        self.rows = rows; self.textStart = textStart; self.textEnd = textEnd; self.layers = layers
        self.rebuildBudget = rebuildBudget
    }
}
