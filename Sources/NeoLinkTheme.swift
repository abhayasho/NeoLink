import SwiftUI

/// Cursor IDE–style dark theme: charcoal grays, white/light gray text, subtle blue selection.
enum NeoLinkTheme {
    // Cursor / VS Code Dark+ style
    /// Main editor and content area background. #1e1e1e
    static let editorBackground = Color(red: 0x1e / 255.0, green: 0x1e / 255.0, blue: 0x1e / 255.0)
    /// Sidebar (saved sessions, etc.). #252526
    static let sidebarBackground = Color(red: 0x25 / 255.0, green: 0x25 / 255.0, blue: 0x26 / 255.0)
    /// File/panel background. #252526
    static let panelBackground = Color(red: 0x25 / 255.0, green: 0x25 / 255.0, blue: 0x26 / 255.0)
    /// Selection / active item (Cursor blue). #094771
    static let selectionBlue = Color(red: 0x09 / 255.0, green: 0x47 / 255.0, blue: 0x71 / 255.0)
    /// Hover background for list rows. #2a2d2e
    static let listHover = Color(red: 0x2a / 255.0, green: 0x2d / 255.0, blue: 0x2e / 255.0)
    /// Inactive list row
    static let rowFill = Color.white.opacity(0.04)
    /// Section separator (1pt line between panels). Cursor uses #3c3c3c.
    static let separator = Color(red: 0x3c / 255.0, green: 0x3c / 255.0, blue: 0x3c / 255.0)
    /// Legacy; use separator for section lines.
    static let divider = separator
    static let panelBorder = Color.white.opacity(0.08)
    /// Primary text. #d4d4d4
    static let textPrimary = Color(red: 0xd4 / 255.0, green: 0xd4 / 255.0, blue: 0xd4 / 255.0)
    /// Secondary / dimmed text. #858585
    static let textSecondary = Color(red: 0x85 / 255.0, green: 0x85 / 255.0, blue: 0x85 / 255.0)
    /// Accent for buttons/links (use selection blue, not purple).
    static let accent = selectionBlue
    /// Row hover (subtle gray like Cursor).
    static let rowHover = listHover
    static let rowHoverWhite = listHover

    /// Single-color main background (no gradient).
    static let background = editorBackground

    static func panelFill(cornerRadius: CGFloat = 10) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(panelBackground)
    }

    /// Cursor-style 1pt vertical line (e.g. between sidebar and content).
    static func verticalSeparator() -> some View {
        Rectangle()
            .fill(separator)
            .frame(width: 1)
    }

    /// Cursor-style 1pt horizontal line (e.g. below tab bar).
    static func horizontalSeparator() -> some View {
        Rectangle()
            .fill(separator)
            .frame(height: 1)
    }
}

// MARK: - Cursor-style typography (VS Code / Cursor default: monospace, 13–14pt)
extension NeoLinkTheme {
    /// Editor/list font size (Cursor default 14; 13 for tighter UI).
    static let fontSize: CGFloat = 13
    /// Monospaced font matching Cursor/VS Code editor.
    static let font = Font.system(size: fontSize, weight: .regular, design: .monospaced)
}
