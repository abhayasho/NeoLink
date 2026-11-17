//! The connections sidebar and the connection sheet (the Swift app's `SessionSidebar` and
//! `SessionEditSheet`). Connections are kept in the file the Swift app uses, in its format, so both
//! apps show the same list.

use std::path::PathBuf;

use neolink_core::sessions::{is_valid, new_id, Connection};
use serde_json::{json, Value};
use winit::keyboard::{Key, NamedKey};

use crate::chrome::{faded, Ui};
use crate::frame::Painter;
use crate::icons::IconWeight;
use crate::menu::{Action, Item, Menu};
use crate::render::Rect;
use crate::theme;

pub const WIDTH_POINTS: f32 = 210.0;

/// Where the list is kept. `None` in benchmarks and captures unless a file is named.
fn path() -> Option<PathBuf> {
    if let Some(file) = std::env::var_os("NEOLINK_SESSIONS_FILE") {
        return Some(PathBuf::from(file));
    }
    if std::env::var_os("NEOLINK_BENCHMARK").is_some() || std::env::var_os("NEOLINK_CAPTURE").is_some() || std::env::var("NEOLINK_SETTINGS").as_deref() == Ok("0") {
        return None;
    }
    crate::settings::path().map(|settings| settings.with_file_name("sessions.json"))
}

/// The entries of the file that are not SSH connections (the Swift app's "Local terminal" entry) are
/// kept as they are and written back.
fn load() -> (Vec<Connection>, Vec<Value>) {
    let entries: Vec<Value> = path().and_then(|path| std::fs::read(path).ok()).and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
    let mut connections = Vec::new();
    let mut others = Vec::new();
    for entry in entries {
        match (entry["type"].as_str(), entry["id"].as_str(), entry["name"].as_str(), entry["host"].as_str()) {
            (Some("ssh"), Some(id), Some(name), Some(host)) => connections.push(Connection {
                id: id.to_string(),
                name: name.to_string(),
                host: host.to_string(),
                port: entry["port"].as_u64().filter(|port| (1..=65535).contains(port)).unwrap_or(22) as u16,
                username: entry["username"].as_str().map(str::to_string).unwrap_or_else(user_name),
            }),
            _ => others.push(entry),
        }
    }
    (connections, others)
}

fn save(connections: &[Connection], others: &[Value]) {
    let Some(path) = path() else { return };
    let mut entries: Vec<Value> = others.to_vec();
    entries.extend(connections.iter().map(|connection| json!({"id": connection.id, "name": connection.name, "type": "ssh", "host": connection.host, "port": connection.port, "username": connection.username})));
    let Ok(data) = serde_json::to_vec(&entries) else { return };
    if let Some(directory) = path.parent() {
        let _ = std::fs::create_dir_all(directory);
    }
    let temporary = path.with_extension("json.tmp");
    if std::fs::write(&temporary, data).is_ok() {
        let _ = std::fs::rename(&temporary, &path);
    }
}

pub fn user_name() -> String {
    std::env::var("USER").or_else(|_| std::env::var("USERNAME")).unwrap_or_else(|_| "user".into())
}

fn host_name() -> String {
    let output = std::process::Command::new(if cfg!(target_os = "macos") { "scutil" } else { "hostname" }).args(if cfg!(target_os = "macos") { vec!["--get", "ComputerName"] } else { vec![] }).output();
    output.ok().map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string()).filter(|name| !name.is_empty()).unwrap_or_else(|| if cfg!(target_os = "macos") { "This Mac".into() } else { "This computer".into() })
}

/// The app's icon, from the bundle's resources or the repository.
fn logo_path() -> Option<PathBuf> {
    let mut starts: Vec<PathBuf> = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        starts.push(exe);
    }
    if let Ok(directory) = std::env::current_dir() {
        starts.push(directory.join("x"));
    }
    for start in starts {
        let mut directory = start.parent();
        for _ in 0..8 {
            let Some(current) = directory else { break };
            for candidate in [current.join("Resources/AppIcon.png"), current.join("../Resources/AppIcon.png")] {
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
            directory = current.parent();
        }
    }
    None
}

pub enum Outcome {
    Nothing,
    Close,
    LocalTerminal,
    Open(Connection),
    Menu(Menu),
}

#[derive(Clone, Copy, PartialEq)]
enum Field {
    Name,
    Host,
    User,
    Port,
}

/// The "New connection" / "Edit connection" sheet.
struct Sheet {
    id: Option<String>,
    name: String,
    host: String,
    user: String,
    port: String,
    focus: Field,
    buttons: Vec<(Rect, &'static str)>,
}

pub struct Connections {
    pub visible: bool,
    connections: Vec<Connection>,
    others: Vec<Value>,
    search: String,
    pub search_focused: bool,
    sheet: Option<Sheet>,
    rect: Rect,
    buttons: Vec<(Rect, String)>,
    rows: Vec<(Rect, String)>,
    scroll: f32,
    host: String,
    logo: Option<PathBuf>,
    revision: u64,
    counter: u64,
}

impl Connections {
    pub fn new() -> Connections {
        let (connections, others) = load();
        Connections { visible: false, connections, others, search: String::new(), search_focused: false, sheet: None, rect: Rect::default(), buttons: Vec::new(), rows: Vec::new(), scroll: 0.0, host: host_name(), logo: logo_path(), revision: 0, counter: 0 }
    }

    pub fn contains(&self, x: f32, y: f32) -> bool {
        self.visible && self.rect.contains(x, y)
    }

    pub fn sheet_is_open(&self) -> bool {
        self.sheet.is_some()
    }

    pub fn find(&self, id: &str) -> Option<Connection> {
        self.connections.iter().find(|connection| connection.id == id).cloned()
    }

    /// Opens the sheet for a new connection, or for the one with `id`.
    pub fn edit(&mut self, id: Option<&str>) {
        let existing = id.and_then(|id| self.find(id));
        self.sheet = Some(match existing {
            Some(connection) => Sheet { id: Some(connection.id), name: connection.name, host: connection.host, user: connection.username, port: connection.port.to_string(), focus: Field::Name, buttons: Vec::new() },
            None => Sheet { id: None, name: String::new(), host: String::new(), user: user_name(), port: "22".into(), focus: Field::Name, buttons: Vec::new() },
        });
        self.revision += 1;
    }

    pub fn remove(&mut self, id: &str) {
        self.connections.retain(|connection| connection.id != id);
        save(&self.connections, &self.others);
        self.revision += 1;
    }

    fn sheet_valid(sheet: &Sheet) -> bool {
        !sheet.name.trim().is_empty() && is_valid(&sheet.host, &sheet.user, &sheet.port)
    }

    fn save_sheet(&mut self) {
        let Some(sheet) = self.sheet.take_if(|sheet| Self::sheet_valid(sheet)) else { return };
        self.counter += 1;
        let connection = Connection {
            id: sheet.id.clone().unwrap_or_else(|| new_id(crate::clock::now().to_bits() ^ self.counter << 48 ^ std::process::id() as u64)),
            name: sheet.name.trim().to_string(),
            host: sheet.host.trim().to_string(),
            port: sheet.port.parse().unwrap_or(22),
            username: sheet.user.trim().to_string(),
        };
        match self.connections.iter_mut().find(|existing| existing.id == connection.id) {
            Some(existing) => *existing = connection,
            None => self.connections.push(connection),
        }
        save(&self.connections, &self.others);
        self.revision += 1;
    }

    /// A key for the sheet or the search field. Returns `true` if it was used.
    pub fn key(&mut self, key: &Key, text: Option<&str>) -> bool {
        self.revision += 1;
        if let Some(sheet) = &mut self.sheet {
            let field = match sheet.focus {
                Field::Name => &mut sheet.name,
                Field::Host => &mut sheet.host,
                Field::User => &mut sheet.user,
                Field::Port => &mut sheet.port,
            };
            match key {
                Key::Named(NamedKey::Escape) => self.sheet = None,
                Key::Named(NamedKey::Enter) => self.save_sheet(),
                Key::Named(NamedKey::Backspace) => {
                    field.pop();
                }
                Key::Named(NamedKey::Tab) => {
                    sheet.focus = match sheet.focus {
                        Field::Name => Field::Host,
                        Field::Host => Field::User,
                        Field::User => Field::Port,
                        Field::Port => Field::Name,
                    }
                }
                _ => {
                    if let Some(text) = text.filter(|text| !text.chars().any(char::is_control)) {
                        field.push_str(text);
                    }
                }
            }
            return true;
        }
        if !self.search_focused || !self.visible {
            return false;
        }
        match key {
            Key::Named(NamedKey::Escape) => {
                self.search.clear();
                self.search_focused = false;
            }
            Key::Named(NamedKey::Enter) | Key::Named(NamedKey::Tab) => self.search_focused = false,
            Key::Named(NamedKey::Backspace) => {
                self.search.pop();
            }
            _ => {
                if let Some(text) = text.filter(|text| !text.chars().any(char::is_control)) {
                    self.search.push_str(text);
                }
            }
        }
        true
    }

    /// A press while the sheet is open.
    pub fn click_sheet(&mut self, x: f32, y: f32) {
        self.revision += 1;
        let Some(sheet) = &mut self.sheet else { return };
        let Some((_, what)) = sheet.buttons.iter().rev().find(|(rect, _)| rect.contains(x, y)).copied() else { return };
        match what {
            "name" => sheet.focus = Field::Name,
            "host" => sheet.focus = Field::Host,
            "user" => sheet.focus = Field::User,
            "port" => sheet.focus = Field::Port,
            "cancel" => self.sheet = None,
            "save" => self.save_sheet(),
            _ => {}
        }
    }

    pub fn click(&mut self, x: f32, y: f32, right: bool) -> Outcome {
        self.revision += 1;
        if let Some((rect, id)) = self.rows.iter().find(|(rect, _)| rect.contains(x, y)).cloned() {
            if right {
                let line = 1.0;
                return Outcome::Menu(Menu::new(Rect::new(x, y - line, line, line), vec![Item::entry("Open in new tab", Action::Connection("open", id.clone())), Item::entry("Edit connection\u{2026}", Action::Connection("edit", id.clone())), Item::Separator, Item::entry("Remove connection", Action::Connection("remove", id))]));
            }
            let _ = rect;
            return self.find(&id).map(Outcome::Open).unwrap_or(Outcome::Nothing);
        }
        if right {
            return Outcome::Nothing;
        }
        let pressed = self.buttons.iter().find(|(rect, _)| rect.contains(x, y)).map(|(_, what)| what.clone());
        self.search_focused = pressed.as_deref() == Some("search");
        match pressed.as_deref() {
            Some("local") => Outcome::LocalTerminal,
            Some("new") => {
                self.edit(None);
                Outcome::Nothing
            }
            Some("close") => Outcome::Close,
            Some("clear") => {
                self.search.clear();
                Outcome::Nothing
            }
            _ => Outcome::Nothing,
        }
    }

    pub fn scroll(&mut self, delta: f32) {
        self.scroll -= delta;
        self.revision += 1;
    }

    pub fn control_rect(&self, name: &str) -> Option<Rect> {
        if let Some(sheet) = &self.sheet {
            if let Some((rect, _)) = sheet.buttons.iter().rev().find(|(_, what)| *what == name) {
                return Some(*rect);
            }
        }
        if let Some(index) = name.strip_prefix("row:").and_then(|index| index.parse::<usize>().ok()) {
            return self.rows.get(index).map(|(rect, _)| *rect);
        }
        self.buttons.iter().find(|(_, what)| what == name).map(|(rect, _)| *rect)
    }

    pub fn signature(&self) -> u64 {
        self.revision.wrapping_mul(0x9E3779B97F4A7C15) ^ (self.visible as u64) ^ (self.search_focused as u64) << 1 ^ (self.sheet.is_some() as u64) << 2
    }

    /// Draws the sidebar. `open_hosts`: `user@host:port` of the SSH tab that is shown, if any.
    pub fn build(&mut self, painter: &mut Painter, rect: Rect, scale: f32, shown: Option<&str>) {
        self.rect = rect;
        self.buttons.clear();
        self.rows.clear();
        let logo = self.logo.clone().and_then(|path| painter.text.image(painter.queue, &path, (40.0 * scale).round() as u32));
        let mut ui = Ui { painter, scale };
        let line = ui.px(1.0).max(1.0);
        ui.fill(rect, theme::SIDEBAR_BACKGROUND);
        ui.painter.scene.fill(rect.right(), rect.y, line, rect.height, theme::SEPARATOR);
        // Logo and name.
        let mut y = rect.y + ui.px(20.0);
        let left = rect.x + ui.px(16.0);
        match logo {
            Some(sprite) => ui.painter.scene.glyph(sprite, left, y, [255, 255, 255, 255]),
            None => ui.rounded(Rect::new(left, y, ui.px(40.0), ui.px(40.0)), 9.0, theme::ELEVATED),
        }
        ui.text("NeoLink", left + ui.px(50.0), y + ui.px(12.0), 17.0, 600, false, theme::TEXT_PRIMARY);
        ui.text("Your connections, together", left + ui.px(50.0), y + ui.px(31.0), 10.0, 400, false, theme::TEXT_SECONDARY);
        y += ui.px(40.0 + 24.0);
        // Local terminal.
        let local = Rect::new(rect.x + ui.px(12.0), y, rect.width - ui.px(24.0), ui.px(38.0));
        ui.rounded(local, 8.0, faded(theme::ELEVATED, 0.7));
        let middle = local.y + local.height * 0.5;
        let icon = ui.icon("terminal", 12.0, IconWeight::Regular, local.x + ui.px(11.0 + 8.0), middle, theme::ACCENT).max(ui.px(16.0));
        ui.text("Local terminal", local.x + ui.px(11.0) + icon + ui.px(9.0), middle, 12.0, 500, false, theme::TEXT_PRIMARY);
        ui.text_right("\u{2318}T", local.right() - ui.px(11.0), middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        self.buttons.push((local, "local".into()));
        y = local.bottom() + ui.px(22.0);
        // CONNECTIONS, new, close.
        let header_middle = y + ui.px(14.0);
        ui.text("C O N N E C T I O N S".replace(' ', "\u{200a}").as_str(), rect.x + ui.px(18.0), header_middle, 10.0, 600, false, theme::TEXT_SECONDARY);
        let button = ui.px(28.0);
        let close = Rect::new(rect.right() - ui.px(8.0) - button, y, button, button);
        ui.icon("xmark", 12.0, IconWeight::Medium, close.x + button * 0.5, header_middle, theme::TEXT_SECONDARY);
        self.buttons.push((close, "close".into()));
        let new = Rect::new(close.x - button, y, button, button);
        ui.icon("plus", 12.0, IconWeight::Medium, new.x + button * 0.5, header_middle, theme::TEXT_SECONDARY);
        self.buttons.push((new, "new".into()));
        y += button + ui.px(4.0);
        // Search.
        let field = Rect::new(rect.x + ui.px(12.0), y, rect.width - ui.px(24.0), ui.px(32.0));
        ui.rounded(field, 7.0, faded(theme::EDITOR_BACKGROUND, 0.65));
        let field_middle = field.y + field.height * 0.5;
        let glass = ui.icon("magnifyingglass", 11.0, IconWeight::Regular, field.x + ui.px(9.0 + 6.0), field_middle, theme::TEXT_SECONDARY).max(ui.px(12.0));
        let text_x = field.x + ui.px(9.0) + glass + ui.px(7.0);
        if self.search.is_empty() && !self.search_focused {
            ui.text("Find a connection", text_x, field_middle, 11.0, 400, false, faded(theme::TEXT_SECONDARY, 0.7));
        } else {
            let search = self.search.clone();
            let width = if search.is_empty() { 0.0 } else { ui.text(&search, text_x, field_middle, 11.0, 400, false, theme::TEXT_PRIMARY) };
            if self.search_focused {
                ui.painter.scene.fill(text_x + width + line, field_middle - ui.px(7.0), line.max(2.0), ui.px(14.0), theme::ACCENT);
            }
            if !search.is_empty() {
                let clear = Rect::new(field.right() - ui.px(26.0), field.y, ui.px(26.0), field.height);
                ui.icon("xmark.circle.fill", 11.0, IconWeight::Regular, clear.x + clear.width * 0.5, field_middle, theme::TEXT_SECONDARY);
                self.buttons.push((clear, "clear".into()));
            }
        }
        self.buttons.push((field, "search".into()));
        y = field.bottom() + ui.px(10.0);
        // Footer: this computer.
        let footer_top = rect.bottom() - ui.px(14.0 + 14.0 + 14.0);
        ui.painter.scene.fill(rect.x, footer_top, rect.width, line, theme::SEPARATOR);
        let footer_middle = footer_top + line + ui.px(14.0 + 7.0);
        let laptop = ui.icon("laptopcomputer", 10.0, IconWeight::Regular, rect.x + ui.px(14.0 + 8.0), footer_middle, theme::TEXT_SECONDARY).max(ui.px(16.0));
        let host = ui.fit_middle(&self.host.clone(), rect.width - ui.px(40.0) - laptop, 10.0, 400, false);
        ui.text(&host, rect.x + ui.px(14.0) + laptop + ui.px(8.0), footer_middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        // Rows.
        let list = Rect::new(rect.x, y, rect.width, (footer_top - y).max(1.0));
        let shown_connections: Vec<Connection> = self.connections.iter().filter(|connection| connection.matches(&self.search)).cloned().collect();
        let row_height = ui.px(11.0 + 30.0 + 11.0);
        let spacing = ui.px(4.0);
        self.scroll = self.scroll.clamp(0.0, (shown_connections.len() as f32 * (row_height + spacing) - list.height).max(0.0));
        ui.painter.scene.set_clip(Some(list));
        for (index, connection) in shown_connections.iter().enumerate() {
            let row = Rect::new(rect.x + ui.px(10.0), list.y + index as f32 * (row_height + spacing) - self.scroll.round(), rect.width - ui.px(20.0), row_height);
            if row.bottom() < list.y || row.y > list.bottom() {
                continue;
            }
            let selected = shown == Some(format!("{}:{}", connection.address(), connection.port).as_str());
            if selected {
                ui.rounded(row, 8.0, theme::SELECTION);
            }
            let row_middle = row.y + row.height * 0.5;
            let icon = ui.icon("server.rack", 14.0, IconWeight::Regular, row.x + ui.px(10.0 + 9.0), row_middle, if selected { theme::ACCENT } else { theme::TEXT_SECONDARY }).max(ui.px(18.0));
            let text_x = row.x + ui.px(10.0) + icon + ui.px(10.0);
            let available = row.right() - text_x - ui.px(if selected { 22.0 } else { 10.0 });
            let name = ui.fit_middle(&connection.name, available, 12.0, 500, false);
            ui.text(&name, text_x, row_middle - ui.px(9.0), 12.0, 500, false, theme::TEXT_PRIMARY);
            let address = ui.fit_middle(&connection.address(), available, 10.0, 400, true);
            ui.text(&address, text_x, row_middle + ui.px(9.0), 10.0, 400, true, theme::TEXT_SECONDARY);
            if selected {
                ui.rounded(Rect::new(row.right() - ui.px(10.0 + 5.0), row_middle - ui.px(2.5), ui.px(5.0), ui.px(5.0)), 2.5, theme::ACCENT);
            }
            self.rows.push((Rect::new(row.x, row.y.max(list.y), row.width, (row.bottom().min(list.bottom()) - row.y.max(list.y)).max(0.0)), connection.id.clone()));
        }
        if shown_connections.is_empty() {
            let searching = !self.search.is_empty();
            let (left, mut y) = (rect.x + ui.px(22.0), list.y + ui.px(12.0));
            ui.icon(if searching { "magnifyingglass" } else { "network" }, 20.0, IconWeight::Regular, left + ui.px(11.0), y + ui.px(11.0), theme::TEXT_SECONDARY);
            y += ui.px(22.0 + 8.0);
            ui.text(if searching { "No matching connections" } else { "Add your first connection" }, left, y + ui.px(8.0), 12.0, 500, false, theme::TEXT_SECONDARY);
            y += ui.px(16.0 + 8.0);
            let wrap_width = rect.width - ui.px(44.0);
            for part in crate::agents::wrap(&mut ui, if searching { "Try a different name or hostname." } else { "Save an SSH host to open a terminal and browse its files." }, wrap_width, 11.0) {
                ui.text(&part, left, y + ui.px(7.0), 11.0, 400, false, theme::TEXT_SECONDARY);
                y += ui.px(14.0);
            }
            if !searching {
                y += ui.px(8.0);
                let width = ui.text("Add connection", left, y + ui.px(7.0), 11.0, 500, false, theme::ACCENT);
                self.buttons.push((Rect::new(left, y, width, ui.px(16.0)), "new".into()));
            }
        }
        ui.painter.scene.set_clip(None);
    }

    /// Draws the connection sheet over the window.
    pub fn draw_sheet(&mut self, painter: &mut Painter, scale: f32, window: (f32, f32)) {
        let Some(mut sheet) = self.sheet.take() else { return };
        sheet.buttons.clear();
        let mut ui = Ui { painter, scale };
        ui.fill(Rect::new(0.0, 0.0, window.0, window.1), [0, 0, 0, 90]);
        let (width, pad, gap) = (ui.px(420.0), ui.px(28.0), ui.px(20.0));
        let port_error = !sheet.port.is_empty() && !sheet.port.parse::<u32>().is_ok_and(|port| (1..=65535).contains(&port));
        let height = pad + ui.px(44.0) + gap + 3.0 * (ui.px(14.0 + 7.0 + 22.0) + gap) + if port_error { ui.px(14.0) + gap } else { 0.0 } + ui.px(1.0) + gap + ui.px(22.0) + pad;
        let frame = Rect::new(((window.0 - width) * 0.5).round(), ((window.1 - height) * 0.35).round().max(ui.px(20.0)), width, height);
        ui.shadow(frame, 10.0);
        ui.rounded(frame, 10.0, theme::SIDEBAR_BACKGROUND);
        ui.outline(frame, 10.0, theme::white(0.12));
        let (left, right) = (frame.x + pad, frame.right() - pad);
        let mut y = frame.y + pad;
        ui.icon("network", 24.0, IconWeight::Regular, left + ui.px(14.0), y + ui.px(22.0), theme::ACCENT);
        ui.text(if sheet.id.is_none() { "New connection" } else { "Edit connection" }, left + ui.px(40.0), y + ui.px(12.0), 19.0, 600, false, theme::TEXT_PRIMARY);
        ui.text("Keep a remote workspace one click away.", left + ui.px(40.0), y + ui.px(36.0), 12.0, 400, false, theme::TEXT_SECONDARY);
        y += ui.px(44.0) + gap;
        let line = ui.px(1.0).max(1.0);
        let field = |ui: &mut Ui, sheet: &mut Sheet, title: &str, placeholder: &str, value: String, which: Field, what: &'static str, x: f32, width: f32, y: f32| {
            ui.text(title, x, y + ui.px(7.0), 11.0, 500, false, theme::TEXT_SECONDARY);
            let rect = Rect::new(x, y + ui.px(14.0 + 7.0), width, ui.px(22.0));
            ui.rounded(rect, 5.0, theme::rgb(0x1E1E1E));
            ui.outline(rect, 5.0, if sheet.focus == which { theme::rgb(0x2F6FDB) } else { theme::white(0.12) });
            let middle = rect.y + rect.height * 0.5;
            ui.painter.scene.set_clip(Some(rect));
            let end = if value.is_empty() {
                ui.text(placeholder, rect.x + ui.px(7.0), middle, 13.0, 400, false, faded(theme::TEXT_SECONDARY, 0.7));
                0.0
            } else {
                ui.text(&value, rect.x + ui.px(7.0), middle, 13.0, 400, false, theme::TEXT_PRIMARY) + line
            };
            if sheet.focus == which {
                ui.painter.scene.fill(rect.x + ui.px(7.0) + end, middle - ui.px(8.0), line.max(2.0), ui.px(16.0), theme::ACCENT);
            }
            ui.painter.scene.set_clip(None);
            sheet.buttons.push((rect, what));
        };
        let block = ui.px(14.0 + 7.0 + 22.0) + gap;
        let (name, host, user, port) = (sheet.name.clone(), sheet.host.clone(), sheet.user.clone(), sheet.port.clone());
        field(&mut ui, &mut sheet, "Connection name", "My server", name, Field::Name, "name", left, right - left, y);
        y += block;
        field(&mut ui, &mut sheet, "Hostname", "server.example.com", host, Field::Host, "host", left, right - left, y);
        y += block;
        let port_width = ui.px(90.0);
        let user_width = right - left - port_width - ui.px(12.0);
        field(&mut ui, &mut sheet, "Username", "username", user, Field::User, "user", left, user_width, y);
        field(&mut ui, &mut sheet, "Port", "22", port, Field::Port, "port", right - port_width, port_width, y);
        y += block;
        if port_error {
            ui.text("Enter a port between 1 and 65535.", left, y + ui.px(7.0), 11.0, 400, false, theme::rgb(0xC6B28E));
            y += ui.px(14.0) + gap;
        }
        ui.painter.scene.fill(left, y, right - left, line, theme::SEPARATOR);
        y += line + gap;
        let middle = y + ui.px(11.0);
        let cancel_width = ui.measure("Cancel", 12.0, 500, false) + ui.px(20.0);
        let cancel = Rect::new(left, y, cancel_width, ui.px(22.0));
        ui.rounded(cancel, 5.0, theme::rgb(0x3A3A3A));
        ui.text("Cancel", cancel.x + ui.px(10.0), middle, 12.0, 500, false, theme::TEXT_PRIMARY);
        sheet.buttons.push((cancel, "cancel"));
        let label = if sheet.id.is_none() { "Save connection" } else { "Save changes" };
        let valid = Self::sheet_valid(&sheet);
        let save_width = ui.measure(label, 12.0, 600, false) + ui.px(20.0);
        let save_rect = Rect::new(right - save_width, y, save_width, ui.px(22.0));
        ui.rounded(save_rect, 5.0, if valid { theme::ACCENT } else { theme::rgb(0x333333) });
        ui.text(label, save_rect.x + ui.px(10.0), middle, 12.0, 600, false, if valid { theme::EDITOR_BACKGROUND } else { theme::TEXT_SECONDARY });
        if valid {
            sheet.buttons.push((save_rect, "save"));
        }
        self.sheet = Some(sheet);
    }
}
