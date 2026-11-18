//! The macOS menu bar, built from `commands::menus` (the Swift app's menus, titles and key
//! equivalents). A chosen item arrives as its command id (see `commands`).

use muda::accelerator::{Accelerator, Code, Modifiers};
use muda::{CheckMenuItem, Menu, MenuEvent, MenuItem, MenuItemKind, PredefinedMenuItem, Submenu};

use crate::commands::{self, Command, Entry};

fn code(character: char) -> Option<Code> {
    Some(match character {
        'a' => Code::KeyA,
        'c' => Code::KeyC,
        'b' => Code::KeyB,
        'e' => Code::KeyE,
        'f' => Code::KeyF,
        'g' => Code::KeyG,
        'm' => Code::KeyM,
        'n' => Code::KeyN,
        'o' => Code::KeyO,
        'p' => Code::KeyP,
        's' => Code::KeyS,
        't' => Code::KeyT,
        'v' => Code::KeyV,
        'w' => Code::KeyW,
        'z' => Code::KeyZ,
        ']' => Code::BracketRight,
        '[' => Code::BracketLeft,
        '+' | '=' => Code::Equal,
        '-' => Code::Minus,
        '0' => Code::Digit0,
        _ => return None,
    })
}

/// An item that acts as the shortcut `flags` + `character` ("c" command, "s" shift, "x" control).
fn item(command: &Command, checked: bool) -> MenuItemKind {
    let accelerator = command.keys.and_then(|(flags, character)| {
        let mut modifiers = Modifiers::empty();
        for flag in flags.chars() {
            modifiers |= match flag {
                'c' => Modifiers::META,
                's' => Modifiers::SHIFT,
                'x' => Modifiers::CONTROL,
                _ => Modifiers::empty(),
            };
        }
        code(character).map(|code| Accelerator::new(Some(modifiers), code))
    });
    // The terminal panel's keys are not key equivalents; the title names them.
    let title = match command.id.as_str() {
        "dock:bottom" => format!("{}  \u{2303}`", command.title),
        "dock:right" => format!("{}  \u{2303}\u{21e7}`", command.title),
        _ => command.title.to_string(),
    };
    if command.checkable {
        MenuItemKind::Check(CheckMenuItem::with_id(command.id.as_str(), title, true, checked, accelerator))
    } else {
        MenuItemKind::MenuItem(MenuItem::with_id(command.id.as_str(), title, true, accelerator))
    }
}

fn append(submenu: &Submenu, entries: &[Entry], pixel_sideways: bool) -> Option<()> {
    for entry in entries {
        match entry {
            Entry::Command(command) => match item(command, command.id == "view:hscroll" && pixel_sideways) {
                MenuItemKind::Check(check) => submenu.append(&check).ok()?,
                MenuItemKind::MenuItem(plain) => submenu.append(&plain).ok()?,
                _ => {}
            },
            Entry::Separator => submenu.append(&PredefinedMenuItem::separator()).ok()?,
            Entry::Submenu(title, entries) => {
                let inner = Submenu::new(*title, true);
                append(&inner, entries, pixel_sideways)?;
                submenu.append(&inner).ok()?;
            }
        }
    }
    Some(())
}

/// Builds the menu bar and installs it. The returned menu must be kept alive.
pub fn install(pixel_sideways: bool, on_command: impl Fn(String) + Send + Sync + 'static) -> Option<Menu> {
    let separator = PredefinedMenuItem::separator;
    let menu = Menu::new();
    let app = Submenu::new("NeoLink", true);
    let quit = item(&Command { id: "key:c:q".into(), title: "Quit NeoLink", keys: Some(("c", 'q')), in_palette: true, checkable: false }, false);
    let MenuItemKind::MenuItem(quit) = quit else { return None };
    app.append_items(&[
        &PredefinedMenuItem::about(Some("About NeoLink"), None),
        &plain("help:updates", "Check for Updates\u{2026}"),
        &separator(),
        &PredefinedMenuItem::hide(Some("Hide NeoLink")),
        &PredefinedMenuItem::hide_others(Some("Hide Others")),
        &PredefinedMenuItem::show_all(Some("Show All")),
        &separator(),
        &quit,
    ])
    .ok()?;
    menu.append(&app).ok()?;
    for described in commands::menus() {
        let submenu = Submenu::new(described.title, true);
        append(&submenu, &described.entries, pixel_sideways)?;
        match described.title {
            "Window" => {
                submenu.append_items(&[&PredefinedMenuItem::maximize(Some("Zoom")), &separator(), &PredefinedMenuItem::bring_all_to_front(Some("Bring All to Front"))]).ok()?;
                submenu.set_as_windows_menu_for_nsapp();
            }
            "Help" => submenu.set_as_help_menu_for_nsapp(),
            _ => {}
        }
        menu.append(&submenu).ok()?;
    }
    menu.init_for_nsapp();
    MenuEvent::set_event_handler(Some(move |event: MenuEvent| on_command(event.id.0.clone())));
    Some(menu)
}

fn plain(id: &str, title: &str) -> MenuItem {
    MenuItem::with_id(id, title, true, None)
}
