//! The agent panel at the right of the window and the launcher sheet (the Swift app's `AgentPanelView`
//! and `AgentLauncherView`): terminal agents run in a shell in the panel or in a tab.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use neolink_core::agent::CodingAgent;
use winit::keyboard::{Key, NamedKey};

use crate::chrome::{faded, Ui};
use crate::frame::{Next, Painter, Shared};
use crate::icons::IconWeight;
use crate::menu::{Action, Item, Menu};
use crate::render::Rect;
use crate::term::Terminal;
use crate::text::CellMetrics;
use crate::theme;

/// `CommandRunner.executable`: a full path as given, or a bare name looked up in the usual places.
pub fn executable(name: &str) -> Option<String> {
    let home = std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")).unwrap_or_default();
    let name = match name.strip_prefix("~/") {
        Some(rest) => format!("{home}/{rest}"),
        None => name.to_string(),
    };
    let is_executable = |path: &Path| {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            path.metadata().is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        }
        #[cfg(not(unix))]
        {
            path.is_file()
        }
    };
    if Path::new(&name).is_absolute() {
        return is_executable(Path::new(&name)).then_some(name);
    }
    if name.contains('/') || name.contains('\\') {
        return None;
    }
    let mut directories: Vec<PathBuf> = [format!("{home}/.local/bin"), format!("{home}/.npm-global/bin"), "/opt/homebrew/bin".into(), "/usr/local/bin".into(), "/usr/bin".into(), "/bin".into()].into_iter().map(PathBuf::from).collect();
    directories.extend(std::env::var_os("PATH").map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>()).unwrap_or_default());
    let names: Vec<String> = if cfg!(windows) { vec![format!("{name}.exe"), format!("{name}.cmd"), name.clone()] } else { vec![name.clone()] };
    directories.iter().filter(|directory| directory.is_absolute()).flat_map(|directory| names.iter().map(move |name| directory.join(name))).find(|candidate| is_executable(candidate)).map(|path| path.to_string_lossy().into_owned())
}

struct Session {
    id: u64,
    title: String,
    terminal: Terminal,
}

/// What the panel or launcher asks of the workspace.
pub enum Outcome {
    Nothing,
    OpenLauncher,
    Hide,
    Menu(Menu),
    /// Start a terminal agent: in the panel (`docked`) or in a tab.
    Launch { agent: CodingAgent, directory: PathBuf, docked: bool },
    /// Connect a native (ACP) conversation.
    Connect { agent: CodingAgent, directory: PathBuf, mcp: String },
    ChooseFolder,
}

#[derive(Clone, Copy, PartialEq)]
enum Field {
    Name,
    Executable,
    Arguments,
    Mcp,
}

/// The launcher sheet's state.
pub struct Launcher {
    pub directory: Option<PathBuf>,
    acp: bool,
    custom: bool,
    continue_session: bool,
    docked: bool,
    mcp_open: bool,
    name: String,
    executable: String,
    arguments: String,
    mcp: String,
    focus: Option<Field>,
    pub error: Option<String>,
    claude_found: bool,
    buttons: Vec<(Rect, &'static str)>,
    frame: Rect,
}

impl Launcher {
    pub fn new(directory: Option<PathBuf>, custom_name: String, custom_executable: String) -> Launcher {
        Launcher { directory, acp: false, custom: false, continue_session: false, docked: true, mcp_open: false, name: custom_name, executable: custom_executable, arguments: String::new(), mcp: String::new(), focus: None, error: None, claude_found: executable("claude").is_some(), buttons: Vec::new(), frame: Rect::default() }
    }

    /// The custom agent's name and executable, which are remembered between launches.
    pub fn remembered(&self) -> (String, String) {
        (self.name.clone(), self.executable.clone())
    }

    fn agent(&self) -> CodingAgent {
        if !self.custom {
            return if self.acp { CodingAgent::claude_acp() } else { CodingAgent::claude(self.continue_session) };
        }
        CodingAgent { name: self.name.trim().to_string(), executable: self.executable.trim().to_string(), arguments: self.arguments.lines().filter(|line| !line.is_empty()).map(str::to_string).collect() }
    }

    fn can_launch(&self) -> bool {
        self.directory.is_some() && self.agent().is_valid()
    }

    fn launch(&self) -> Outcome {
        let Some(directory) = self.directory.clone().filter(|_| self.can_launch()) else { return Outcome::Nothing };
        if self.acp {
            Outcome::Connect { agent: self.agent(), directory, mcp: self.mcp.clone() }
        } else {
            Outcome::Launch { agent: self.agent(), directory, docked: self.docked }
        }
    }

    /// Returns `None` to close the sheet.
    pub fn key(&mut self, key: &Key, text: Option<&str>) -> Option<Outcome> {
        let multiline = matches!(self.focus, Some(Field::Arguments | Field::Mcp));
        let field = match self.focus {
            Some(Field::Name) => Some(&mut self.name),
            Some(Field::Executable) => Some(&mut self.executable),
            Some(Field::Arguments) => Some(&mut self.arguments),
            Some(Field::Mcp) => Some(&mut self.mcp),
            None => None,
        };
        match key {
            Key::Named(NamedKey::Escape) => return None,
            Key::Named(NamedKey::Enter) if multiline => {
                if let Some(field) = field {
                    field.push('\n');
                }
            }
            Key::Named(NamedKey::Enter) => return Some(self.launch()),
            Key::Named(NamedKey::Backspace) => {
                if let Some(field) = field {
                    field.pop();
                }
            }
            Key::Named(NamedKey::Tab) => {
                self.focus = match (self.focus, self.custom) {
                    (Some(Field::Name), true) => Some(Field::Executable),
                    (Some(Field::Executable), true) => Some(Field::Arguments),
                    (_, true) => Some(Field::Name),
                    _ => None,
                }
            }
            _ => {
                if let (Some(field), Some(text)) = (field, text.filter(|text| !text.chars().any(char::is_control))) {
                    field.push_str(text);
                }
            }
        }
        Some(Outcome::Nothing)
    }

    /// Returns `None` to close the sheet.
    pub fn click(&mut self, x: f32, y: f32) -> Option<Outcome> {
        let Some((_, what)) = self.buttons.iter().rev().find(|(rect, _)| rect.contains(x, y)).copied() else {
            if self.frame.contains(x, y) {
                self.focus = None;
            }
            return Some(Outcome::Nothing);
        };
        self.error = None;
        match what {
            "terminal" => self.acp = false,
            "acp" => self.acp = true,
            "claude" => {
                self.custom = false;
                self.focus = None;
            }
            "custom" => {
                self.custom = true;
                self.focus = Some(Field::Name);
            }
            "continue" => self.continue_session = !self.continue_session,
            "docked" => self.docked = !self.docked,
            "mcp-toggle" => {
                self.mcp_open = !self.mcp_open;
                self.focus = self.mcp_open.then_some(Field::Mcp);
            }
            "field-name" => self.focus = Some(Field::Name),
            "field-executable" => self.focus = Some(Field::Executable),
            "field-arguments" => self.focus = Some(Field::Arguments),
            "field-mcp" => self.focus = Some(Field::Mcp),
            "choose" => return Some(Outcome::ChooseFolder),
            "cancel" => return None,
            "launch" => return Some(self.launch()),
            "link-acp" => open_link("https://github.com/agentclientprotocol/claude-agent-acp"),
            "link-claude" => open_link("https://code.claude.com/docs/en/quickstart"),
            _ => {}
        }
        Some(Outcome::Nothing)
    }

    pub fn control_rect(&self, name: &str) -> Option<Rect> {
        self.buttons.iter().rev().find(|(_, what)| *what == name).map(|(rect, _)| *rect)
    }

    pub fn signature(&self) -> u64 {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        (&self.directory, self.acp, self.custom, self.continue_session, self.docked, self.mcp_open, &self.name, &self.executable, &self.arguments, &self.mcp, self.focus.map(|field| field as u8), &self.error).hash(&mut hasher);
        hasher.finish()
    }

    pub fn draw(&mut self, ui: &mut Ui, window: (f32, f32)) {
        self.buttons.clear();
        ui.fill(Rect::new(0.0, 0.0, window.0, window.1), [0, 0, 0, 90]);
        let (width, pad, gap) = (ui.px(460.0), ui.px(24.0), ui.px(18.0));
        // Laid out twice: once to learn the height, once to draw.
        let mut frame = Rect::new(((window.0 - width) * 0.5).round(), ui.px(40.0), width, ui.px(400.0));
        for pass in 0..2 {
            let drawing = pass == 1;
            if drawing {
                self.frame = frame;
                ui.shadow(frame, 10.0);
                ui.rounded(frame, 10.0, theme::SIDEBAR_BACKGROUND);
                ui.outline(frame, 10.0, theme::white(0.12));
            }
            let (left, right) = (frame.x + pad, frame.right() - pad);
            let inner = right - left;
            let line = ui.px(1.0).max(1.0);
            let mut y = frame.y + pad;
            let caption = |ui: &mut Ui, text: &str, y: &mut f32, color: theme::Rgba| {
                for part in wrap(ui, text, inner, 11.0) {
                    if drawing {
                        ui.text(&part, left, *y + ui.px(7.0), 11.0, 400, false, color);
                    }
                    *y += ui.px(14.0);
                }
            };
            // Title.
            if drawing {
                let icon = ui.icon("sparkles", 17.0, IconWeight::Semibold, left + ui.px(11.0), y + ui.px(12.0), theme::TEXT_PRIMARY).max(ui.px(22.0));
                ui.text("Coding agent", left + icon + ui.px(6.0), y + ui.px(12.0), 19.0, 600, false, theme::TEXT_PRIMARY);
            }
            y += ui.px(24.0) + gap;
            // Interface.
            self.segmented(ui, drawing, Rect::new(left, y, inner, ui.px(22.0)), [("Terminal", "terminal"), ("Native conversation (ACP)", "acp")], self.acp as usize);
            y += ui.px(22.0) + gap;
            caption(ui, if self.acp { "Connect an installed ACP adapter. The agent manages models and authentication." } else { "Run an agent in its own project terminal." }, &mut y, theme::TEXT_SECONDARY);
            y += gap;
            self.segmented(ui, drawing, Rect::new(left, y, inner, ui.px(22.0)), [("Claude Code", "claude"), ("Custom CLI", "custom")], self.custom as usize);
            y += ui.px(22.0) + gap;
            if self.custom {
                let name = self.name.clone();
                self.field(ui, drawing, Rect::new(left, y, inner, ui.px(22.0)), &name, "Agent name", Field::Name, "field-name", false);
                y += ui.px(22.0) + gap;
                let executable = self.executable.clone();
                self.field(ui, drawing, Rect::new(left, y, inner, ui.px(22.0)), &executable, "Executable name or full path", Field::Executable, "field-executable", false);
                y += ui.px(22.0) + gap;
                caption(ui, "Arguments \u{b7} one per line", &mut y, theme::TEXT_SECONDARY);
                y += ui.px(6.0);
                let arguments = self.arguments.clone();
                self.field(ui, drawing, Rect::new(left, y, inner, ui.px(70.0)), &arguments, "", Field::Arguments, "field-arguments", true);
                y += ui.px(70.0 + 6.0);
                caption(ui, "Each line is passed literally. Arguments are not saved.", &mut y, theme::TEXT_SECONDARY);
                y += gap;
            } else {
                if !self.acp {
                    self.toggle(ui, drawing, left, y, "Continue the last conversation in this project", self.continue_session, "continue");
                    y += ui.px(18.0) + gap;
                }
                if self.acp {
                    caption(ui, "Requires the claude-agent-acp adapter. A regular claude executable belongs in Terminal mode.", &mut y, theme::TEXT_SECONDARY);
                    y += gap;
                    self.link(ui, drawing, left, y, "ACP adapter setup", "link-acp");
                    y += ui.px(16.0) + gap;
                } else if !self.claude_found {
                    caption(ui, "Claude Code was not found in common install locations. Your shell\u{2019}s PATH is also checked when you launch.", &mut y, theme::rgb(0xC6B28E));
                    y += gap;
                }
                self.link(ui, drawing, left, y, "Claude Code setup guide", "link-claude");
                y += ui.px(16.0) + gap;
            }
            if drawing {
                ui.painter.scene.fill(left, y, inner, line, theme::SEPARATOR);
            }
            y += line + gap;
            if !self.acp {
                self.toggle(ui, drawing, left, y, "Open alongside the editor", self.docked, "docked");
                y += ui.px(18.0) + gap;
            } else {
                if drawing {
                    ui.icon(if self.mcp_open { "chevron.down" } else { "chevron.right" }, 8.0, IconWeight::Semibold, left + ui.px(5.0), y + ui.px(7.0), theme::TEXT_SECONDARY);
                    ui.text("MCP servers \u{b7} optional", left + ui.px(16.0), y + ui.px(7.0), 11.0, 400, false, theme::TEXT_PRIMARY);
                    self.buttons.push((Rect::new(left, y, inner, ui.px(14.0)), "mcp-toggle"));
                }
                y += ui.px(14.0);
                if self.mcp_open {
                    y += ui.px(6.0);
                    caption(ui, "JSON array of stdio servers: name, absolute command, args, env. Sent to this agent when connecting; not saved.", &mut y, theme::TEXT_SECONDARY);
                    y += ui.px(6.0);
                    let mcp = self.mcp.clone();
                    self.field(ui, drawing, Rect::new(left, y, inner, ui.px(70.0)), &mcp, "", Field::Mcp, "field-mcp", true);
                    y += ui.px(70.0);
                }
                y += gap;
            }
            // Project folder.
            let choose_width = ui.measure("Choose Folder\u{2026}", 12.0, 500, false) + ui.px(20.0);
            if drawing {
                ui.text("Project folder", left, y + ui.px(7.0), 11.0, 400, false, theme::TEXT_SECONDARY);
                let path = self.directory.as_ref().map(|directory| directory.display().to_string()).unwrap_or_else(|| "Choose a folder to work in".into());
                let path = ui.fit_middle(&path, inner - choose_width - ui.px(12.0), 13.0, 400, false);
                ui.text(&path, left, y + ui.px(14.0 + 4.0 + 8.0), 13.0, 400, false, theme::TEXT_PRIMARY);
                let choose = Rect::new(right - choose_width, y + ui.px(6.0), choose_width, ui.px(22.0));
                ui.rounded(choose, 5.0, theme::rgb(0x3A3A3A));
                ui.text("Choose Folder\u{2026}", choose.x + ui.px(10.0), choose.y + choose.height * 0.5, 12.0, 500, false, theme::TEXT_PRIMARY);
                self.buttons.push((choose, "choose"));
            }
            y += ui.px(14.0 + 4.0 + 17.0) + gap;
            caption(
                ui,
                if self.acp { "The adapter runs with your account\u{2019}s access. Save edits before requesting changes. Tool permissions appear in the conversation; authentication and provider settings belong to the adapter." } else { "Agents use files saved on disk. Save your edits before requesting changes. Sign in and approve actions in the agent\u{2019}s terminal." },
                &mut y,
                theme::TEXT_SECONDARY,
            );
            y += gap;
            if let Some(error) = self.error.clone() {
                caption(ui, &error, &mut y, theme::rgb(0xC6B28E));
                y += gap;
            }
            // Buttons.
            if drawing {
                let middle = y + ui.px(11.0);
                let cancel_width = ui.measure("Cancel", 12.0, 500, false) + ui.px(20.0);
                let cancel = Rect::new(left, y, cancel_width, ui.px(22.0));
                ui.rounded(cancel, 5.0, theme::rgb(0x3A3A3A));
                ui.text("Cancel", cancel.x + ui.px(10.0), middle, 12.0, 500, false, theme::TEXT_PRIMARY);
                self.buttons.push((cancel, "cancel"));
                let label = if self.acp { "Connect Agent" } else if self.docked { "Launch in Panel" } else { "Launch in Tab" };
                let enabled = self.can_launch();
                let launch_width = ui.measure(label, 12.0, 600, false) + ui.px(20.0);
                let launch = Rect::new(right - launch_width, y, launch_width, ui.px(22.0));
                // `.tint(accent)` with the label in the editor background colour.
                ui.rounded(launch, 5.0, if enabled { theme::ACCENT } else { theme::rgb(0x333333) });
                ui.text(label, launch.x + ui.px(10.0), middle, 12.0, 600, false, if enabled { theme::EDITOR_BACKGROUND } else { theme::TEXT_SECONDARY });
                if enabled {
                    self.buttons.push((launch, "launch"));
                }
            }
            y += ui.px(22.0) + pad;
            frame.height = y - frame.y;
            frame.y = ((window.1 - frame.height) * 0.4).round().max(ui.px(20.0));
        }
    }

    fn segmented(&mut self, ui: &mut Ui, drawing: bool, rect: Rect, parts: [(&str, &'static str); 2], selected: usize) {
        if !drawing {
            return;
        }
        let line = ui.px(1.0).max(1.0);
        ui.rounded(rect, 6.0, theme::rgb(0x242424));
        let half = rect.width * 0.5;
        ui.rounded(Rect::new(rect.x + selected as f32 * half + line, rect.y + line, half - 2.0 * line, rect.height - 2.0 * line), 5.0, theme::rgb(0x4A4A4A));
        for (index, (label, what)) in parts.into_iter().enumerate() {
            let part = Rect::new(rect.x + index as f32 * half, rect.y, half, rect.height);
            let width = ui.measure(label, 12.0, 500, false);
            ui.text(label, part.x + (half - width) * 0.5, rect.y + rect.height * 0.5, 12.0, 500, false, theme::TEXT_PRIMARY);
            self.buttons.push((part, what));
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn field(&mut self, ui: &mut Ui, drawing: bool, rect: Rect, value: &str, placeholder: &str, field: Field, what: &'static str, multiline: bool) {
        if !drawing {
            return;
        }
        let focused = self.focus == Some(field);
        ui.rounded(rect, 5.0, theme::rgb(0x1E1E1E));
        ui.outline(rect, 5.0, if focused { theme::rgb(0x2F6FDB) } else { theme::white(0.12) });
        self.buttons.push((rect, what));
        let line = ui.px(1.0).max(1.0);
        let (points, monospace) = if multiline { (12.0, true) } else { (13.0, false) };
        ui.painter.scene.set_clip(Some(rect));
        let row = ui.px(16.0);
        let mut caret = (rect.x + ui.px(7.0), rect.y + if multiline { ui.px(4.0) } else { (rect.height - row) * 0.5 });
        if value.is_empty() {
            ui.text(placeholder, caret.0, caret.1 + row * 0.5, points, 400, monospace, faded(theme::TEXT_SECONDARY, 0.7));
        } else {
            for (index, text) in value.split('\n').enumerate() {
                let y = rect.y + if multiline { ui.px(4.0) } else { (rect.height - row) * 0.5 } + index as f32 * row;
                let width = if text.is_empty() { 0.0 } else { ui.text(text, rect.x + ui.px(7.0), y + row * 0.5, points, 400, monospace, theme::TEXT_PRIMARY) + line };
                caret = (rect.x + ui.px(7.0) + width, y);
            }
        }
        if focused {
            ui.painter.scene.fill(caret.0, caret.1 + ui.px(1.0), line.max(2.0), row - ui.px(2.0), theme::ACCENT);
        }
        ui.painter.scene.set_clip(None);
    }

    fn toggle(&mut self, ui: &mut Ui, drawing: bool, x: f32, y: f32, label: &str, on: bool, what: &'static str) {
        if !drawing {
            return;
        }
        let width = ui.measure(label, 13.0, 400, false);
        ui.text(label, x, y + ui.px(9.0), 13.0, 400, false, theme::TEXT_PRIMARY);
        // A small switch after the label.
        let switch = Rect::new(x + width + ui.px(10.0), y + ui.px(1.0), ui.px(28.0), ui.px(16.0));
        ui.rounded(switch, 8.0, if on { theme::ACCENT } else { theme::rgb(0x3A3A3A) });
        let knob = ui.px(12.0);
        ui.rounded(Rect::new(if on { switch.right() - knob - ui.px(2.0) } else { switch.x + ui.px(2.0) }, switch.y + ui.px(2.0), knob, knob), 6.0, if on { theme::EDITOR_BACKGROUND } else { theme::rgb(0xD0D0D0) });
        self.buttons.push((Rect::new(x, y, width + ui.px(42.0), ui.px(18.0)), what));
    }

    fn link(&mut self, ui: &mut Ui, drawing: bool, x: f32, y: f32, label: &str, what: &'static str) {
        if !drawing {
            return;
        }
        let width = ui.text(label, x, y + ui.px(8.0), 13.0, 400, false, theme::ACCENT);
        self.buttons.push((Rect::new(x, y, width, ui.px(16.0)), what));
    }
}

fn open_link(url: &str) {
    let (program, arguments): (&str, Vec<&str>) = if cfg!(target_os = "macos") { ("open", vec![url]) } else if cfg!(windows) { ("cmd", vec!["/C", "start", "", url]) } else { ("xdg-open", vec![url]) };
    let _ = std::process::Command::new(program).args(arguments).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).spawn();
}

/// Breaks `text` into lines at most `width` pixels wide.
pub fn wrap(ui: &mut Ui, text: &str, width: f32, points: f32) -> Vec<String> {
    let mut lines = Vec::new();
    let mut current = String::new();
    for word in text.split_whitespace() {
        let candidate = if current.is_empty() { word.to_string() } else { format!("{current} {word}") };
        if !current.is_empty() && ui.measure(&candidate, points, 400, false) > width {
            lines.push(std::mem::take(&mut current));
            current = word.to_string();
        } else {
            current = candidate;
        }
    }
    if !current.is_empty() {
        lines.push(current);
    }
    lines
}

pub const WIDTH_POINTS: f32 = 300.0;

pub struct AgentPanel {
    pub visible: bool,
    /// Whether the panel's terminal has the keyboard.
    pub focused: bool,
    pub width_points: f32,
    sessions: Vec<Session>,
    selected: usize,
    next_id: u64,
    rect: Rect,
    terminal_rect: Rect,
    grid: (usize, usize),
    buttons: Vec<(Rect, &'static str)>,
}

impl AgentPanel {
    pub fn new() -> AgentPanel {
        AgentPanel { visible: false, focused: false, width_points: WIDTH_POINTS, sessions: Vec::new(), selected: 0, next_id: 1 << 40, rect: Rect::default(), terminal_rect: Rect::default(), grid: (40, 20), buttons: Vec::new() }
    }

    pub fn contains(&self, x: f32, y: f32) -> bool {
        self.visible && self.rect.contains(x, y)
    }

    pub fn left_edge(&self) -> f32 {
        self.rect.x
    }

    pub fn session_count(&self) -> usize {
        self.sessions.len()
    }

    pub fn terminal(&mut self) -> Option<&mut Terminal> {
        self.sessions.get_mut(self.selected).map(|session| &mut session.terminal)
    }

    /// Starts `agent` in a shell in the panel.
    pub fn launch(&mut self, shared: &Arc<Shared>, agent: &CodingAgent, directory: &Path, cell: CellMetrics) -> std::io::Result<()> {
        let id = self.next_id;
        self.next_id += 1;
        let mut terminal = Terminal::spawn(shared, self.grid.0.max(20), self.grid.1.max(5), cell, Some(directory.to_path_buf()), id)?;
        let resolved = executable(&agent.executable);
        terminal.write(agent.launch_command(&directory.to_string_lossy(), resolved.as_deref()).replace('\n', "\r").into_bytes());
        self.sessions.push(Session { id, title: agent.name.clone(), terminal });
        self.selected = self.sessions.len() - 1;
        self.visible = true;
        self.focused = true;
        Ok(())
    }

    pub fn select(&mut self, id: u64) {
        if let Some(index) = self.sessions.iter().position(|session| session.id == id) {
            self.selected = index;
        }
    }

    fn close_selected(&mut self) {
        if self.selected < self.sessions.len() {
            let session = self.sessions.remove(self.selected);
            session.terminal.shutdown();
            self.selected = self.selected.min(self.sessions.len().saturating_sub(1));
        }
        if self.sessions.is_empty() {
            self.focused = false;
        }
    }

    pub fn click(&mut self, x: f32, y: f32) -> Outcome {
        if let Some((rect, what)) = self.buttons.iter().find(|(rect, _)| rect.contains(x, y)).copied() {
            return match what {
                "new" => Outcome::OpenLauncher,
                "hide" => Outcome::Hide,
                "close" => {
                    self.close_selected();
                    Outcome::Nothing
                }
                "picker" => Outcome::Menu(Menu::new(rect, self.sessions.iter().enumerate().map(|(index, session)| Item::toggle(&session.title, Action::AgentSession(session.id), index == self.selected)).collect())),
                _ => Outcome::Nothing,
            };
        }
        self.focused = self.terminal_rect.contains(x, y) && !self.sessions.is_empty();
        Outcome::Nothing
    }

    pub fn control_rect(&self, name: &str) -> Option<Rect> {
        self.buttons.iter().find(|(_, what)| *what == name).map(|(rect, _)| *rect)
    }

    pub fn signature(&self) -> u64 {
        let mut value = (self.visible as u64) | (self.focused as u64) << 1 | (self.selected as u64) << 8 | (self.sessions.len() as u64) << 24 | (self.width_points.to_bits() as u64) << 32;
        if let Some(session) = self.sessions.get(self.selected) {
            value ^= session.terminal.output_generation().wrapping_mul(0x9E3779B97F4A7C15) ^ session.terminal.scroll().to_bits();
        }
        value
    }

    /// Draws the panel in `rect`. Sessions whose program ended are removed.
    pub fn build(&mut self, painter: &mut Painter, rect: Rect, scale: f32, cell: CellMetrics, window_focused: bool, display: f64, period: f64) -> Next {
        self.rect = rect;
        self.buttons.clear();
        let before = self.sessions.len();
        self.sessions.retain(|session| !session.terminal.has_exited());
        if self.sessions.len() != before {
            self.selected = self.selected.min(self.sessions.len().saturating_sub(1));
        }
        let mut ui = Ui { painter, scale };
        let line = ui.px(1.0).max(1.0);
        ui.fill(rect, theme::EDITOR_BACKGROUND);
        ui.painter.scene.fill(rect.x - line, rect.y, line, rect.height, theme::SEPARATOR);
        // Header: Agent, new session, hide.
        let header = Rect::new(rect.x, rect.y, rect.width, ui.px(34.0));
        let middle = header.y + header.height * 0.5;
        let bubble = ui.icon("bubble.left", 12.0, IconWeight::Regular, rect.x + ui.px(10.0 + 8.0), middle, theme::TEXT_SECONDARY).max(ui.px(16.0));
        ui.text("Agent", rect.x + ui.px(10.0) + bubble + ui.px(8.0), middle, 12.0, 500, false, theme::TEXT_PRIMARY);
        let button = ui.px(28.0);
        let hide = Rect::new(rect.right() - ui.px(10.0) - button, middle - button * 0.5, button, button);
        ui.icon("sidebar.right", 12.0, IconWeight::Medium, hide.x + button * 0.5, middle, theme::TEXT_SECONDARY);
        self.buttons.push((hide, "hide"));
        let new = Rect::new(hide.x - ui.px(8.0) - button, hide.y, button, button);
        ui.icon("plus", 12.0, IconWeight::Medium, new.x + button * 0.5, middle, theme::TEXT_SECONDARY);
        self.buttons.push((new, "new"));
        ui.painter.scene.fill(rect.x, header.bottom(), rect.width, line, theme::SEPARATOR);
        let top = header.bottom() + line;
        if self.sessions.is_empty() {
            // The empty state.
            let (left, inner) = (rect.x + ui.px(16.0), rect.width - ui.px(32.0));
            let mut y = top + ui.px(16.0);
            ui.text("Work alongside your code", left, y + ui.px(8.0), 13.0, 500, false, theme::TEXT_PRIMARY);
            y += ui.px(16.0 + 12.0);
            for part in wrap(&mut ui, "Start a native ACP conversation or an agent terminal in your project. Keep the editor open while it works.", inner, 12.0) {
                ui.text(&part, left, y + ui.px(8.0), 12.0, 400, false, theme::TEXT_SECONDARY);
                y += ui.px(16.0);
            }
            y += ui.px(12.0);
            let start = Rect::new(left, y, inner, ui.px(36.0));
            ui.rounded(start, 5.0, theme::ELEVATED);
            let start_middle = start.y + start.height * 0.5;
            let plus = ui.icon("plus", 12.0, IconWeight::Regular, start.x + ui.px(10.0 + 6.0), start_middle, theme::TEXT_PRIMARY).max(ui.px(12.0));
            ui.text("New agent session", start.x + ui.px(10.0) + plus + ui.px(8.0), start_middle, 12.0, 400, false, theme::TEXT_PRIMARY);
            ui.text_right("\u{2303}\u{2318}A", start.right() - ui.px(10.0), start_middle, 12.0, 400, false, theme::TEXT_SECONDARY);
            self.buttons.push((start, "new"));
            self.terminal_rect = Rect::default();
            self.focused = false;
            return Next::Idle;
        }
        // Session row: picker, close.
        let row = Rect::new(rect.x, top, rect.width, ui.px(32.0));
        let row_middle = row.y + row.height * 0.5;
        let close = Rect::new(rect.right() - ui.px(10.0 + 20.0), row_middle - ui.px(10.0), ui.px(20.0), ui.px(20.0));
        ui.icon("xmark", 11.0, IconWeight::Regular, close.x + close.width * 0.5, row_middle, theme::TEXT_SECONDARY);
        self.buttons.push((close, "close"));
        let title = self.sessions[self.selected].title.clone();
        let picker_width = (ui.measure(&title, 13.0, 400, false) + ui.px(34.0)).min(close.x - rect.x - ui.px(20.0));
        let picker = Rect::new(rect.x + ui.px(10.0), row_middle - ui.px(11.0), picker_width, ui.px(22.0));
        ui.rounded(picker, 5.0, theme::rgb(0x343434));
        let fitted = ui.fit_middle(&title, picker.width - ui.px(30.0), 13.0, 400, false);
        ui.text(&fitted, picker.x + ui.px(9.0), row_middle, 13.0, 400, false, theme::TEXT_PRIMARY);
        ui.icon("chevron.up.chevron.down", 9.0, IconWeight::Semibold, picker.right() - ui.px(11.0), row_middle, theme::TEXT_SECONDARY);
        self.buttons.push((picker, "picker"));
        // Footer.
        let footer = Rect::new(rect.x, rect.bottom() - ui.px(22.0), rect.width, ui.px(22.0));
        let footer_middle = footer.y + footer.height * 0.5;
        ui.text("Project terminal", rect.x + ui.px(10.0), footer_middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        let count = self.sessions.len();
        ui.text_right(&format!("{count} {}", if count == 1 { "session" } else { "sessions" }), rect.right() - ui.px(10.0), footer_middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        // The terminal, a whole number of cells.
        let area = Rect::new(rect.x + ui.px(8.0), row.bottom() + ui.px(4.0), rect.width - ui.px(8.0), footer.y - row.bottom() - ui.px(4.0));
        let grid = (((area.width / cell.width).floor() as usize).max(2), ((area.height / cell.height).floor() as usize).max(1));
        self.terminal_rect = Rect::new(area.x, area.y, area.width, grid.1 as f32 * cell.height);
        if grid != self.grid {
            self.grid = grid;
            for session in &mut self.sessions {
                session.terminal.resize(grid.0, grid.1, cell);
            }
        }
        let (terminal_rect, focused) = (self.terminal_rect, self.focused && window_focused);
        self.sessions[self.selected].terminal.build(painter, terminal_rect, focused, display, period)
    }
}
