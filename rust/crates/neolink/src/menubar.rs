//! The macOS menu bar, with the Swift app's menus, titles and key equivalents (`WorkspaceCommands`).
//! A chosen item arrives as a command string: "key:<modifiers>:<character>" runs the same code as the
//! keyboard shortcut, "editor:<action>" and "repl:<program>" are the Code menu's entries.

use muda::accelerator::{Accelerator, Code, Modifiers};
use muda::{Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu};

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

/// An item that acts as the shortcut `modifiers` + `character` ("c" command, "s" shift, "x" control).
fn key(title: &str, modifiers: &str, character: char) -> MenuItem {
    let mut flags = Modifiers::empty();
    for modifier in modifiers.chars() {
        flags |= match modifier {
            'c' => Modifiers::META,
            's' => Modifiers::SHIFT,
            'x' => Modifiers::CONTROL,
            _ => Modifiers::empty(),
        };
    }
    MenuItem::with_id(format!("key:{modifiers}:{character}"), title, true, code(character).map(|code| Accelerator::new(Some(flags), code)))
}

fn plain(id: &str, title: &str) -> MenuItem {
    MenuItem::with_id(id, title, true, None)
}

/// Builds the menu bar and installs it. The returned menu must be kept alive.
pub fn install(on_command: impl Fn(String) + Send + Sync + 'static) -> Option<Menu> {
    let separator = PredefinedMenuItem::separator;
    let menu = Menu::new();
    let app = Submenu::new("NeoLink", true);
    app.append_items(&[
        &PredefinedMenuItem::about(Some("About NeoLink"), None),
        &separator(),
        &PredefinedMenuItem::hide(Some("Hide NeoLink")),
        &PredefinedMenuItem::hide_others(Some("Hide Others")),
        &PredefinedMenuItem::show_all(Some("Show All")),
        &separator(),
        &key("Quit NeoLink", "c", 'q'),
    ])
    .ok()?;
    let file = Submenu::new("File", true);
    file.append_items(&[
        &key("New Local Tab", "c", 't'),
        &key("New SSH Connection\u{2026}", "cs", 'n'),
        &key("Launch Coding Agent\u{2026}", "cx", 'a'),
        &separator(),
        &key("Open File\u{2026}", "c", 'o'),
        &key("Open Project\u{2026}", "cs", 'o'),
        &key("Save File", "c", 's'),
        &key("Quick Open\u{2026}", "c", 'p'),
        &separator(),
        &key("Close Tab", "c", 'w'),
        &key("Close Window", "cs", 'w'),
    ])
    .ok()?;
    let edit = Submenu::new("Edit", true);
    edit.append_items(&[
        &key("Undo", "c", 'z'),
        &key("Redo", "cs", 'z'),
        &separator(),
        &plain("editor:cut", "Cut"),
        &key("Copy", "c", 'c'),
        &key("Paste", "c", 'v'),
        &key("Select All", "c", 'a'),
        &separator(),
        &key("Find\u{2026}", "c", 'f'),
        &key("Find in Files\u{2026}", "cs", 'f'),
    ])
    .ok()?;
    let code_menu = Submenu::new("Code", true);
    for (title, action) in [("Go to Definition", "definition"), ("Find References", "references"), ("Show Documentation", "hover"), ("Rename Symbol\u{2026}", "rename"), ("Code Actions\u{2026}", "codeAction"), ("Format Document", "format"), ("Toggle Fold", "fold"), ("Fold All", "foldAll"), ("Unfold All", "unfoldAll"), ("Toggle Inlay Hints", "inlayHints")] {
        code_menu.append(&plain(&format!("editor:{action}"), title)).ok()?;
    }
    code_menu.append(&separator()).ok()?;
    let repl = Submenu::new("Open REPL", true);
    for (title, program) in [("Python", "python3"), ("JavaScript", "node"), ("Swift", "swift"), ("Ruby", "irb"), ("Lua", "lua")] {
        repl.append(&plain(&format!("repl:{program}"), title)).ok()?;
    }
    code_menu.append(&repl).ok()?;
    let view = Submenu::new("View", true);
    view.append_items(&[
        &key("Increase Text Size", "c", '+'),
        &key("Decrease Text Size", "c", '-'),
        &key("Reset Text Size", "c", '0'),
        &separator(),
        &key("Toggle Connections Sidebar", "cx", 's'),
        &key("Toggle File Browser", "cs", 'e'),
        &key("Toggle Agent Panel", "cx", 'b'),
        &key("Source Control\u{2026}", "cs", 'g'),
        &plain("dock:bottom", "Terminal Under Code  \u{2303}`"),
        &plain("dock:right", "Terminal Beside Code  \u{2303}\u{21e7}`"),
        &separator(),
        &key("Next Tab", "cs", ']'),
        &key("Previous Tab", "cs", '['),
        &separator(),
        &key("Toggle Full Screen", "cx", 'f'),
    ])
    .ok()?;
    let window = Submenu::new("Window", true);
    window.append_items(&[&key("Minimize", "c", 'm'), &PredefinedMenuItem::maximize(Some("Zoom")), &separator(), &PredefinedMenuItem::bring_all_to_front(Some("Bring All to Front"))]).ok()?;
    menu.append_items(&[&app, &file, &edit, &code_menu, &view, &window]).ok()?;
    menu.init_for_nsapp();
    window.set_as_windows_menu_for_nsapp();
    MenuEvent::set_event_handler(Some(move |event: MenuEvent| on_command(event.id.0.clone())));
    Some(menu)
}
