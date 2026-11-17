//! Keyboard events to the bytes a terminal program expects.

use winit::keyboard::{Key, ModifiersState, NamedKey};

fn modifier_parameter(modifiers: ModifiersState) -> u8 {
    1 + modifiers.shift_key() as u8 + 2 * modifiers.alt_key() as u8 + 4 * modifiers.control_key() as u8
}

fn csi_letter(letter: char, modifiers: ModifiersState, application_cursor: bool) -> Vec<u8> {
    let parameter = modifier_parameter(modifiers);
    if parameter > 1 {
        format!("\x1b[1;{parameter}{letter}").into_bytes()
    } else if application_cursor {
        format!("\x1bO{letter}").into_bytes()
    } else {
        format!("\x1b[{letter}").into_bytes()
    }
}

fn csi_tilde(number: u8, modifiers: ModifiersState) -> Vec<u8> {
    let parameter = modifier_parameter(modifiers);
    if parameter > 1 {
        format!("\x1b[{number};{parameter}~").into_bytes()
    } else {
        format!("\x1b[{number}~").into_bytes()
    }
}

/// The control character for Control plus `character`, if there is one.
fn control_code(character: char) -> Option<u8> {
    match character {
        'a'..='z' => Some(character as u8 - b'a' + 1),
        'A'..='Z' => Some(character as u8 - b'A' + 1),
        '@' | ' ' | '2' => Some(0),
        '[' | '3' => Some(0x1b),
        '\\' | '4' => Some(0x1c),
        ']' | '5' => Some(0x1d),
        '^' | '6' => Some(0x1e),
        '_' | '/' | '7' | '-' => Some(0x1f),
        '8' | '?' => Some(0x7f),
        _ => None,
    }
}

/// Encodes a key press. `text` is what the key typed according to the system (composition included).
pub fn encode(key: &Key, text: Option<&str>, modifiers: ModifiersState, application_cursor: bool) -> Option<Vec<u8>> {
    let alt_prefix = |mut bytes: Vec<u8>| {
        if modifiers.alt_key() {
            bytes.insert(0, 0x1b);
        }
        bytes
    };
    match key {
        Key::Named(named) => Some(match named {
            NamedKey::Enter => alt_prefix(vec![b'\r']),
            NamedKey::Backspace => alt_prefix(vec![if modifiers.control_key() { 0x08 } else { 0x7f }]),
            NamedKey::Tab => {
                if modifiers.shift_key() {
                    b"\x1b[Z".to_vec()
                } else {
                    vec![b'\t']
                }
            }
            NamedKey::Escape => vec![0x1b],
            NamedKey::Space => {
                if modifiers.control_key() {
                    vec![0]
                } else {
                    alt_prefix(vec![b' '])
                }
            }
            NamedKey::ArrowUp => csi_letter('A', modifiers, application_cursor),
            NamedKey::ArrowDown => csi_letter('B', modifiers, application_cursor),
            NamedKey::ArrowRight => csi_letter('C', modifiers, application_cursor),
            NamedKey::ArrowLeft => csi_letter('D', modifiers, application_cursor),
            NamedKey::Home => csi_letter('H', modifiers, application_cursor),
            NamedKey::End => csi_letter('F', modifiers, application_cursor),
            NamedKey::Insert => csi_tilde(2, modifiers),
            NamedKey::Delete => csi_tilde(3, modifiers),
            NamedKey::PageUp => csi_tilde(5, modifiers),
            NamedKey::PageDown => csi_tilde(6, modifiers),
            NamedKey::F1 => csi_letter('P', modifiers, true),
            NamedKey::F2 => csi_letter('Q', modifiers, true),
            NamedKey::F3 => csi_letter('R', modifiers, true),
            NamedKey::F4 => csi_letter('S', modifiers, true),
            NamedKey::F5 => csi_tilde(15, modifiers),
            NamedKey::F6 => csi_tilde(17, modifiers),
            NamedKey::F7 => csi_tilde(18, modifiers),
            NamedKey::F8 => csi_tilde(19, modifiers),
            NamedKey::F9 => csi_tilde(20, modifiers),
            NamedKey::F10 => csi_tilde(21, modifiers),
            NamedKey::F11 => csi_tilde(23, modifiers),
            NamedKey::F12 => csi_tilde(24, modifiers),
            _ => return None,
        }),
        Key::Character(characters) => {
            if modifiers.control_key() {
                let mut chars = characters.chars();
                if let (Some(character), None) = (chars.next(), chars.next()) {
                    if let Some(code) = control_code(character) {
                        return Some(alt_prefix(vec![code]));
                    }
                }
            }
            let typed = text.filter(|text| !text.is_empty()).unwrap_or(characters.as_str());
            Some(typed.as_bytes().to_vec())
        }
        _ => text.filter(|text| !text.is_empty()).map(|text| text.as_bytes().to_vec()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use winit::keyboard::SmolStr;

    fn character(c: &str) -> Key {
        Key::Character(SmolStr::new(c))
    }

    #[test]
    fn plain_text_and_composition() {
        assert_eq!(encode(&character("a"), Some("a"), ModifiersState::empty(), false), Some(b"a".to_vec()));
        assert_eq!(encode(&character("e"), Some("é"), ModifiersState::ALT, false), Some("é".as_bytes().to_vec()));
    }

    #[test]
    fn control_characters() {
        assert_eq!(encode(&character("c"), None, ModifiersState::CONTROL, false), Some(vec![3]));
        assert_eq!(encode(&character("u"), Some("\u{15}"), ModifiersState::CONTROL, false), Some(vec![0x15]));
        assert_eq!(encode(&character("["), None, ModifiersState::CONTROL, false), Some(vec![0x1b]));
        assert_eq!(encode(&Key::Named(NamedKey::Space), None, ModifiersState::CONTROL, false), Some(vec![0]));
    }

    #[test]
    fn cursor_keys_follow_the_application_mode_and_modifiers() {
        let up = Key::Named(NamedKey::ArrowUp);
        assert_eq!(encode(&up, None, ModifiersState::empty(), false), Some(b"\x1b[A".to_vec()));
        assert_eq!(encode(&up, None, ModifiersState::empty(), true), Some(b"\x1bOA".to_vec()));
        assert_eq!(encode(&up, None, ModifiersState::SHIFT, true), Some(b"\x1b[1;2A".to_vec()));
        assert_eq!(encode(&Key::Named(NamedKey::Delete), None, ModifiersState::empty(), false), Some(b"\x1b[3~".to_vec()));
        assert_eq!(encode(&Key::Named(NamedKey::PageUp), None, ModifiersState::CONTROL, false), Some(b"\x1b[5;5~".to_vec()));
    }

    #[test]
    fn editing_keys() {
        assert_eq!(encode(&Key::Named(NamedKey::Enter), None, ModifiersState::empty(), false), Some(vec![b'\r']));
        assert_eq!(encode(&Key::Named(NamedKey::Backspace), None, ModifiersState::empty(), false), Some(vec![0x7f]));
        assert_eq!(encode(&Key::Named(NamedKey::Backspace), None, ModifiersState::ALT, false), Some(vec![0x1b, 0x7f]));
        assert_eq!(encode(&Key::Named(NamedKey::Tab), None, ModifiersState::SHIFT, false), Some(b"\x1b[Z".to_vec()));
    }
}
