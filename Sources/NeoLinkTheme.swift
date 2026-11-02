import SwiftUI

/// Shared surfaces, typography and interaction colors for the workspace.
enum NeoLinkTheme {
    static let editorBackground = Color(hex: 0x171717)
    static let sidebarBackground = Color(hex: 0x181818)
    static let panelBackground = Color(hex: 0x1C1C1C)
    static let elevated = Color(hex: 0x262626)
    static let surface = panelBackground
    static let selection = Color(hex: 0x343434)
    static let listHover = Color.white.opacity(0.055)
    static let rowFill = Color.clear
    static let separator = Color.white.opacity(0.075)
    static let divider = separator
    static let panelBorder = Color.white.opacity(0.09)
    static let textPrimary = Color(hex: 0xD8D8D8)
    static let textSecondary = Color(hex: 0x969696)
    static let accent = Color(hex: 0xC4C4C4)
    static let success = Color(hex: 0xA4B29B)
    static let warning = Color(hex: 0xC6B28E)
    static let error = Color(hex: 0xCC9595)
    static let rowHover = listHover
    static let rowHoverWhite = listHover
    static let background = editorBackground
    static let fontSize: CGFloat = 13
    static let font = Font.system(size: fontSize)

    static func panelFill(cornerRadius: CGFloat = 10) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius).fill(panelBackground)
    }

    static func verticalSeparator() -> some View {
        Rectangle().fill(separator).frame(width: 1)
    }

    static func horizontalSeparator() -> some View {
        Rectangle().fill(separator).frame(height: 1)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}

struct WorkspaceIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(configuration.isPressed ? NeoLinkTheme.accent : NeoLinkTheme.textSecondary)
            .frame(width: 28, height: 28)
            .background(configuration.isPressed ? NeoLinkTheme.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}
