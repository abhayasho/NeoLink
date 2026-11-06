import AppKit

/// Converts AppKit key events and typed text into Neovim `nvim_input` notation.
/// Printable text is not handled here: it goes through the text input system (so input
/// methods, dead keys and marked text keep working) and arrives via `escape(text:)`.
enum NeovimKeyEncoder {
    static let specialKeys: [UInt16: String] = [
        36: "CR", 76: "CR", 48: "Tab", 51: "BS", 53: "Esc", 117: "Del",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown", 114: "Insert",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]

    /// The `nvim_input` string for a non-text key event, or nil when it is ordinary text.
    static func encode(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, charactersIgnoringModifiers: String?) -> String? {
        let flags = modifiers.intersection([.shift, .control, .option, .command])
        if flags.contains(.command) { return nil }
        let control = flags.contains(.control), shift = flags.contains(.shift), option = flags.contains(.option)
        var prefix = ""
        if control { prefix += "C-" }
        if option { prefix += "M-" }
        if let name = specialKeys[keyCode] {
            // Shift is part of the key for navigation/function keys, but not for plain Tab/Return/etc.
            let shifted = shift && !["CR", "BS", "Esc", "Del"].contains(name)
            return "<" + (shifted ? "S-" : "") + prefix + name + ">"
        }
        guard control || option, let base = charactersIgnoringModifiers?.unicodeScalars.first, base.value >= 0x20, base.value != 0x7f else { return nil }
        // Option composes characters (å, ©) unless combined with Control: leave those to the input system.
        if option && !control { return nil }
        var name = String(Character(base))
        if name == "<" { name = "lt" }
        if name == " " { name = "Space" }
        if name == "\\" { name = "Bslash" }
        return "<" + (shift && name.count == 1 && !name.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) ? "S-" : "") + prefix + name.lowercased() + ">"
    }

    /// Text inserted by the input system. `<` must be written `<lt>`; control bytes that arrive as
    /// text (for example from `doCommand`) become their key names. Terminal escape sequences are dropped.
    static func escape(text: String) -> String {
        var output = ""
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            switch scalar.value {
            case 0x1b:
                // A lone ESC is the Escape key; ESC followed by more is a terminal control sequence.
                if text.unicodeScalars.count == 1 { output += "<Esc>" } else { return output }
            case 0x0d, 0x0a: output += "<CR>"
            case 0x09: output += "<Tab>"
            case 0x08, 0x7f: output += "<BS>"
            case 0x3c: output += "<lt>"
            case 0x00...0x1f: output += "<C-" + String(UnicodeScalar(scalar.value + 0x60)!) + ">"
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    /// `nvim_input_mouse` modifier string, for example "CS".
    static func mouseModifiers(_ flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.shift) { result += "S" }
        if flags.contains(.control) { result += "C" }
        if flags.contains(.option) { result += "A" }
        return result
    }
}
