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
        case .single: underline = .single
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
        guard let first = text.first, text != " " else { return makeCharData(attribute: attribute, code: 0, size: Int8(width)) }
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
        updateRange(y)
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
        if lines > 0 { cmdScrollUp([lines], []) } else { cmdScrollDown([-lines]) }
        buffer.scrollTop = savedTop
        buffer.scrollBottom = savedBottom
    }

    public func externalGridSetCursor(column: Int, row: Int) {
        buffer.x = min(max(0, column), cols - 1)
        buffer.y = min(max(0, row), rows - 1)
        updateRange(buffer.y)
    }

    /// The text of one visible row, for tests and accessibility comparisons.
    public func externalGridRowText(_ y: Int) -> String {
        guard y >= 0, y < rows else { return "" }
        return buffer.lines[buffer.yBase + y].translateToString(trimRight: true)
    }
}
