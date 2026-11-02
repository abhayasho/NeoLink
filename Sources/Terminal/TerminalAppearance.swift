import AppKit
import SwiftUI
import SwiftTerm

enum TerminalAppearance {
    static func apply(to view: TerminalView) {
        view.nativeBackgroundColor = NSColor(NeoLinkTheme.editorBackground)
        view.nativeForegroundColor = NSColor(NeoLinkTheme.textPrimary)
        view.caretColor = NSColor(NeoLinkTheme.accent)
        view.caretTextColor = NSColor(NeoLinkTheme.editorBackground)
        view.selectedTextBackgroundColor = NSColor(NeoLinkTheme.selection)

        // Keep ANSI meanings recognizable without bright primary colors.
        let palette: [UInt32] = [
            0x242424, 0xC48D8D, 0xA4B29B, 0xC6B28E,
            0x93A9BC, 0xB5A0B8, 0x96B3AF, 0xC8C8C8,
            0x777777, 0xD5A3A3, 0xB6C2AD, 0xD7C4A2,
            0xA9BDCE, 0xC7B4CA, 0xABC6C2, 0xE5E5E5
        ]
        view.installColors(palette.map { hex in
            SwiftTerm.Color(
                red: UInt16((hex >> 16) & 0xff) * 257,
                green: UInt16((hex >> 8) & 0xff) * 257,
                blue: UInt16(hex & 0xff) * 257
            )
        })
    }
}
