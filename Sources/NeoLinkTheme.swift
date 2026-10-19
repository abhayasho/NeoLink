import SwiftUI

/// Shared surfaces, typography and interaction colors for the workspace.
enum NeoLinkTheme {
    static let editorBackground = Color(hex: 0x11151D)
    static let sidebarBackground = Color(hex: 0x171C26)
    static let panelBackground = Color(hex: 0x1B222E)
    static let elevated = Color(hex: 0x232D3B)
    static let surface = panelBackground
    static let selectionBlue = Color(hex: 0x263F4A)
    static let listHover = Color.white.opacity(0.055)
    static let rowFill = Color.clear
    static let separator = Color.white.opacity(0.075)
    static let divider = separator
    static let panelBorder = Color.white.opacity(0.09)
    static let textPrimary = Color(hex: 0xE7EDF5)
    static let textSecondary = Color(hex: 0x939FB1)
    static let accent = Color(hex: 0x72DCC5)
    static let success = Color(hex: 0x80CFAC)
    static let warning = Color(hex: 0xE9BD78)
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
            .background(configuration.isPressed ? NeoLinkTheme.selectionBlue : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}
