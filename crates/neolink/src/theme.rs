//! Colours of the Swift app's theme (`Sources/NeoLinkTheme.swift`, `TerminalAppearance.swift`).

pub type Rgba = [u8; 4];

pub const fn rgb(hex: u32) -> Rgba {
    [(hex >> 16) as u8, (hex >> 8) as u8, hex as u8, 0xff]
}

pub const fn white(alpha: f32) -> Rgba {
    [0xff, 0xff, 0xff, (alpha * 255.0) as u8]
}

pub const EDITOR_BACKGROUND: Rgba = rgb(0x181818);
pub const SIDEBAR_BACKGROUND: Rgba = rgb(0x141414);
pub const ELEVATED: Rgba = rgb(0x1F1F1F);
pub const SELECTION: Rgba = rgb(0x232323);
pub const SEPARATOR: Rgba = white(0.075);
pub const HOVER: Rgba = white(0.055);
pub const TEXT_PRIMARY: Rgba = rgb(0xD8D8D8);
pub const TEXT_SECONDARY: Rgba = rgb(0x969696);
pub const ACCENT: Rgba = rgb(0xC4C4C4);
pub const TERMINAL_SELECTION: Rgba = rgb(0x3A3F4A);
/// The one strong color: default buttons, focus rings, the highlighted menu item.
pub const PRIMARY: Rgba = rgb(0x2F6FDB);

/// ANSI colours 0-15: recognisable meanings without bright primaries.
pub const ANSI: [u32; 16] = [
    0x242424, 0xC48D8D, 0xA4B29B, 0xD6D6A4, 0xA8CCDF, 0xD6B3D2, 0x96B3AF, 0xC8C8C8,
    0x777777, 0xD5A3A3, 0xB6C2AD, 0xD7C4A2, 0xA9BDCE, 0xC7B4CA, 0xABC6C2, 0xE5E5E5,
];

/// The xterm 256-colour table entry for `index`.
pub fn indexed(index: u8) -> Rgba {
    match index {
        0..=15 => rgb(ANSI[index as usize]),
        16..=231 => {
            let value = index - 16;
            let level = |v: u8| if v == 0 { 0 } else { 55 + 40 * v };
            [level(value / 36), level((value / 6) % 6), level(value % 6), 0xff]
        }
        _ => {
            let gray = 8 + 10 * (index - 232);
            [gray, gray, gray, 0xff]
        }
    }
}

pub fn background_clear() -> [f64; 3] {
    [EDITOR_BACKGROUND[0] as f64 / 255.0, EDITOR_BACKGROUND[1] as f64 / 255.0, EDITOR_BACKGROUND[2] as f64 / 255.0]
}
