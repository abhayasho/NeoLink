//! Every command the app offers, once: the macOS menu bar is built from these menus and the command
//! palette lists the same commands on every system (Windows has no menu bar). A command's id is what
//! `App::menu_command` runs: "key:<flags>:<character>" acts as that shortcut ("c" the command chord,
//! "s" its Shift variant, "x" its Control variant), the others name an action.

/// A command: its id, title and shortcut (`flags`, `character`).
#[derive(Clone, Debug)]
pub struct Command {
    pub id: String,
    pub title: &'static str,
    pub keys: Option<(&'static str, char)>,
    /// Listed in the palette (editing commands such as Copy act on what the palette took focus from).
    pub in_palette: bool,
    /// A menu item with a check mark (its state comes from the app; only the macOS menu bar shows it).
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    pub checkable: bool,
}

pub enum Entry {
    Command(Command),
    Separator,
    Submenu(&'static str, Vec<Entry>),
}

pub struct Menu {
    pub title: &'static str,
    pub entries: Vec<Entry>,
}

fn key(title: &'static str, flags: &'static str, character: char) -> Entry {
    Entry::Command(Command { id: format!("key:{flags}:{character}"), title, keys: Some((flags, character)), in_palette: true, checkable: false })
}

fn action(id: &str, title: &'static str) -> Entry {
    Entry::Command(Command { id: id.to_string(), title, keys: None, in_palette: true, checkable: false })
}

/// Kept out of the palette.
fn menu_only(entry: Entry) -> Entry {
    match entry {
        Entry::Command(command) => Entry::Command(Command { in_palette: false, ..command }),
        other => other,
    }
}

/// The menus after the application menu, in menu bar order.
pub fn menus() -> Vec<Menu> {
    let code_actions = [
        ("Go to Definition", "definition"),
        ("Find References", "references"),
        ("Show Documentation", "hover"),
        ("Rename Symbol\u{2026}", "rename"),
        ("Code Actions\u{2026}", "codeAction"),
        ("Format Document", "format"),
        ("Toggle Fold", "fold"),
        ("Fold All", "foldAll"),
        ("Unfold All", "unfoldAll"),
        ("Toggle Inlay Hints", "inlayHints"),
    ];
    let mut code: Vec<Entry> = code_actions.iter().map(|(title, name)| action(&format!("editor:{name}"), title)).collect();
    code.push(Entry::Separator);
    code.push(Entry::Submenu(
        "Open REPL",
        [("Python", "python3"), ("JavaScript", "node"), ("Swift", "swift"), ("Ruby", "irb"), ("Lua", "lua")].iter().map(|(title, program)| action(&format!("repl:{program}"), title)).collect(),
    ));
    vec![
        Menu {
            title: "File",
            entries: vec![
                key("New Local Tab", "c", 't'),
                key("New SSH Connection\u{2026}", "cs", 'n'),
                key("Launch Coding Agent\u{2026}", "cx", 'a'),
                Entry::Separator,
                key("Open File\u{2026}", "c", 'o'),
                key("Open Project\u{2026}", "cs", 'o'),
                key("Save File", "c", 's'),
                key("Quick Open\u{2026}", "c", 'p'),
                Entry::Separator,
                key("Close Tab", "c", 'w'),
                key("Close Window", "cs", 'w'),
            ],
        },
        Menu {
            title: "Edit",
            entries: vec![
                menu_only(key("Undo", "c", 'z')),
                menu_only(key("Redo", "cs", 'z')),
                Entry::Separator,
                menu_only(action("editor:cut", "Cut")),
                menu_only(key("Copy", "c", 'c')),
                menu_only(key("Paste", "c", 'v')),
                menu_only(key("Select All", "c", 'a')),
                Entry::Separator,
                key("Find\u{2026}", "c", 'f'),
                key("Find in Files\u{2026}", "cs", 'f'),
            ],
        },
        Menu { title: "Code", entries: code },
        Menu {
            title: "View",
            entries: vec![
                key("Command Palette\u{2026}", "cs", 'p'),
                Entry::Separator,
                key("Increase Text Size", "c", '+'),
                key("Decrease Text Size", "c", '-'),
                key("Reset Text Size", "c", '0'),
                Entry::Separator,
                action("view:renderer", "Renderer Information\u{2026}"),
                action("view:monitor", "Performance Monitor\u{2026}"),
                Entry::Command(Command { id: "view:hscroll".into(), title: "Pixel-Smooth Sideways Scrolling (Preview)", keys: None, in_palette: true, checkable: true }),
                Entry::Separator,
                key("Toggle Connections Sidebar", "cx", 's'),
                key("Toggle File Browser", "cs", 'e'),
                key("Toggle Agent Panel", "cx", 'b'),
                key("Source Control\u{2026}", "cs", 'g'),
                action("dock:bottom", "Terminal Under Code"),
                action("dock:right", "Terminal Beside Code"),
                Entry::Separator,
                key("Next Tab", "cs", ']'),
                key("Previous Tab", "cs", '['),
                Entry::Separator,
                key("Toggle Full Screen", "cx", 'f'),
            ],
        },
        Menu { title: "Window", entries: vec![key("Minimize", "c", 'm')] },
        Menu {
            title: "Help",
            entries: vec![
                action("help:updates", "Check for Updates\u{2026}"),
                action("help:releases", "Release Notes"),
                action("help:issue", "Report an Issue\u{2026}"),
                Entry::Separator,
                action("help:crashes", "Show Crash Reports"),
            ],
        },
    ]
}

/// A shortcut as this system writes it: "⇧⌘P" on macOS, "Ctrl+Shift+P" elsewhere. `None` for one
/// that has no key elsewhere (Control variants: Control alone belongs to the terminal there).
pub fn shortcut_label(flags: &str, character: char) -> Option<String> {
    let key = match character {
        '+' => "+".to_string(),
        '-' => "\u{2212}".to_string(),
        other => other.to_ascii_uppercase().to_string(),
    };
    if cfg!(target_os = "macos") {
        let mut label = String::new();
        if flags.contains('x') {
            label.push('\u{2303}');
        }
        if flags.contains('s') {
            label.push('\u{21e7}');
        }
        label.push('\u{2318}');
        Some(label + &key)
    } else if flags.contains('x') {
        None
    } else {
        Some(format!("Ctrl+Shift+{}{}", if flags.contains('s') { "Alt+" } else { "" }, key))
    }
}

/// What the palette lists: "Menu: Title", the id and the shortcut label.
#[derive(Clone, Debug)]
pub struct PaletteEntry {
    pub label: String,
    pub id: String,
    pub shortcut: Option<String>,
}

pub fn palette() -> Vec<PaletteEntry> {
    fn collect(prefix: &str, entries: &[Entry], into: &mut Vec<PaletteEntry>) {
        for entry in entries {
            match entry {
                Entry::Command(command) if command.in_palette => {
                    let title = command.title.trim_end_matches('\u{2026}');
                    into.push(PaletteEntry { label: format!("{prefix}: {title}"), id: command.id.clone(), shortcut: command.keys.and_then(|(flags, character)| shortcut_label(flags, character)) });
                }
                Entry::Submenu(title, entries) => collect(&format!("{prefix}: {title}"), entries, into),
                _ => {}
            }
        }
    }
    let mut entries = Vec::new();
    for menu in menus() {
        collect(menu.title, &menu.entries, &mut entries);
    }
    // The terminal panel's own shortcuts (Control-` is not a menu key equivalent).
    for entry in entries.iter_mut() {
        entry.shortcut = match entry.id.as_str() {
            "dock:bottom" => Some(if cfg!(target_os = "macos") { "\u{2303}`".into() } else { "Ctrl+`".into() }),
            "dock:right" => Some(if cfg!(target_os = "macos") { "\u{2303}\u{21e7}`".into() } else { "Ctrl+Shift+`".into() }),
            _ => entry.shortcut.take(),
        };
    }
    entries.push(PaletteEntry { label: "NeoLink: Quit".into(), id: "key:c:q".into(), shortcut: shortcut_label("c", 'q') });
    entries
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn palette_lists_menu_commands_with_their_shortcuts() {
        let entries = palette();
        let find = |label: &str| entries.iter().find(|entry| entry.label == label).unwrap_or_else(|| panic!("{label} is listed"));
        assert_eq!(find("View: Toggle File Browser").id, "key:cs:e");
        assert_eq!(find("Code: Open REPL: Python").id, "repl:python3");
        assert_eq!(find("Help: Check for Updates").id, "help:updates");
        assert!(entries.iter().all(|entry| entry.label != "Edit: Copy"), "editing commands stay in the menu");
        let mut ids: Vec<&str> = entries.iter().map(|entry| entry.id.as_str()).collect();
        ids.sort();
        let count = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), count, "each command is listed once");
        if cfg!(target_os = "macos") {
            assert_eq!(find("View: Command Palette").shortcut.as_deref(), Some("\u{21e7}\u{2318}P"));
            assert_eq!(find("File: Launch Coding Agent").shortcut.as_deref(), Some("\u{2303}\u{2318}A"));
        } else {
            assert_eq!(find("View: Command Palette").shortcut.as_deref(), Some("Ctrl+Shift+Alt+P"));
            assert_eq!(find("File: Launch Coding Agent").shortcut, None);
        }
    }
}
