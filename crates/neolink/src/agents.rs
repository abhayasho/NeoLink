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

enum Kind {
    Terminal(Terminal),
    Conversation(Box<Conversation>),
}

struct Session {
    id: u64,
    title: String,
    kind: Kind,
}

/// A native (ACP) conversation as the panel shows it (`ACPConversationView`).
struct Conversation {
    session: neolink_acp::Session,
    draft: String,
    include_file: bool,
    plan_open: bool,
    open_tools: std::collections::HashSet<String>,
    /// Pixels scrolled up from the end; 0 follows new text.
    from_end: f32,
    /// Wrapped lines by (text, width, points, monospace), so only changed text is laid out again.
    wrapped: std::collections::HashMap<(u64, u32, u32, bool), std::rc::Rc<Vec<String>>>,
    buttons: Vec<(Rect, String)>,
    list: Rect,
    composer: Rect,
    seen_turns: u64,
}

// The wrapped-line cache is only touched while the workspace is locked.
unsafe impl Send for Conversation {}

/// Breaks `text` at spaces (and inside words too long for a line) so no line is wider than `width`.
/// Word widths are measured one by one, so text that grows only costs its new words.
fn wrap_text(ui: &mut Ui, text: &str, width: f32, points: f32, monospace: bool) -> Vec<String> {
    let space = ui.measure(" ", points, 400, monospace).max(1.0);
    let mut lines = Vec::new();
    for paragraph in text.split('\n') {
        // Indentation is kept (tool input is pretty-printed JSON).
        let indent: String = paragraph.chars().take_while(|character| *character == ' ').take(24).collect();
        let paragraph = &paragraph[paragraph.len() - paragraph.trim_start_matches(' ').len()..];
        let mut line = indent.clone();
        let mut used = indent.len() as f32 * space;
        let mut first = true;
        for word in paragraph.split(' ') {
            let mut word = word.to_string();
            let mut word_width = if word.is_empty() { 0.0 } else { ui.measure(&word, points, 400, monospace) };
            // A word wider than a line is cut into pieces that fit.
            while word_width > width && word.chars().count() > 1 {
                if !first {
                    lines.push(std::mem::take(&mut line));
                    used = 0.0;
                    first = true;
                }
                let count = ((word.chars().count() as f32 * width / word_width).floor() as usize).max(1);
                let head: String = word.chars().take(count).collect();
                word = word.chars().skip(count).collect();
                lines.push(head);
                word_width = if word.is_empty() { 0.0 } else { ui.measure(&word, points, 400, monospace) };
            }
            if !first && used + space + word_width > width {
                lines.push(std::mem::take(&mut line));
                used = 0.0;
                first = true;
            }
            if !first {
                line.push(' ');
                used += space;
            }
            first = false;
            line.push_str(&word);
            used += word_width;
        }
        lines.push(line);
    }
    lines
}

impl Conversation {
    fn lines(&mut self, ui: &mut Ui, text: &str, width: f32, points: f32, monospace: bool) -> std::rc::Rc<Vec<String>> {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        text.hash(&mut hasher);
        let key = (hasher.finish(), width.to_bits(), points.to_bits(), monospace);
        if let Some(lines) = self.wrapped.get(&key) {
            return lines.clone();
        }
        if self.wrapped.len() > 600 {
            self.wrapped.clear();
        }
        let lines = std::rc::Rc::new(wrap_text(ui, text, width, points, monospace));
        self.wrapped.insert(key, lines.clone());
        lines
    }

    fn key(&mut self, key: &Key, text: Option<&str>) {
        match key {
            Key::Named(NamedKey::Enter) => self.draft.push('\n'),
            Key::Named(NamedKey::Backspace) => {
                self.draft.pop();
            }
            _ => {
                if let Some(text) = text.filter(|text| !text.chars().any(char::is_control)) {
                    self.draft.push_str(text);
                }
            }
        }
    }

    fn submit(&mut self, context: Option<&str>) {
        let state = self.session.state();
        if state.is_busy || !state.is_ready || self.draft.trim().is_empty() {
            return;
        }
        if self.session.send(&self.draft, context.filter(|_| self.include_file)) {
            self.draft.clear();
            self.from_end = 0.0;
        }
    }

    /// Draws the conversation in `rect`. `context`: the active document, if any.
    fn draw(&mut self, ui: &mut Ui, rect: Rect, context: Option<&str>, focused: bool) {
        let state = self.session.state();
        let streaming = self.session.streaming_message();
        self.buttons.clear();
        let line = ui.px(1.0).max(1.0);
        // Status row: status, mode, Source Control.
        let top_middle = rect.y + ui.px(10.0 + 7.0);
        let git = Rect::new(rect.right() - ui.px(10.0 + 18.0), top_middle - ui.px(9.0), ui.px(18.0), ui.px(18.0));
        ui.icon("arrow.triangle.branch", 10.0, IconWeight::Regular, git.x + git.width * 0.5, top_middle, theme::TEXT_SECONDARY);
        self.buttons.push((git, "git".into()));
        let mut right = git.x - ui.px(8.0);
        if !state.modes.is_empty() {
            let name = state.modes.iter().find(|mode| mode.id == state.current_mode).map(|mode| mode.name.clone()).unwrap_or_else(|| "Mode".into());
            let width = ui.text_right(&name, right - ui.px(10.0), top_middle, 10.0, 400, false, if state.is_busy { faded(theme::TEXT_SECONDARY, 0.6) } else { theme::TEXT_SECONDARY });
            ui.icon("chevron.down", 7.0, IconWeight::Semibold, right - ui.px(4.0), top_middle, theme::TEXT_SECONDARY);
            if !state.is_busy {
                self.buttons.push((Rect::new(right - width - ui.px(12.0), top_middle - ui.px(9.0), width + ui.px(12.0), ui.px(18.0)), "modes".into()));
            }
            right -= width + ui.px(20.0);
        }
        let status = ui.fit_middle(&state.status, right - rect.x - ui.px(14.0), 10.0, 400, false);
        ui.text(&status, rect.x + ui.px(10.0), top_middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        // Composer at the bottom.
        let has_context = context.is_some();
        let composer_height = ui.px(10.0 + 64.0 + 8.0 + if has_context { 14.0 + 8.0 } else { 0.0 } + 20.0 + 10.0);
        let composer = Rect::new(rect.x, rect.bottom() - composer_height, rect.width, composer_height);
        self.composer = composer;
        ui.fill(composer, theme::ELEVATED);
        ui.painter.scene.fill(rect.x, composer.y - line, rect.width, line, theme::SEPARATOR);
        let editor = Rect::new(composer.x + ui.px(10.0), composer.y + ui.px(10.0), composer.width - ui.px(20.0), ui.px(64.0));
        let row = ui.px(16.0);
        let draft_lines = wrap_text(ui, &self.draft, editor.width - ui.px(10.0), 12.0, false);
        ui.painter.scene.set_clip(Some(editor));
        let overflow = (draft_lines.len() as f32 * row - editor.height).max(0.0);
        let mut caret = (editor.x + ui.px(5.0), editor.y);
        for (index, text) in draft_lines.iter().enumerate() {
            let y = editor.y + index as f32 * row - overflow;
            let width = if text.is_empty() { 0.0 } else { ui.text(text, editor.x + ui.px(5.0), y + row * 0.5, 12.0, 400, false, theme::TEXT_PRIMARY) };
            caret = (editor.x + ui.px(5.0) + width + if text.is_empty() { 0.0 } else { line }, y);
        }
        if focused {
            ui.painter.scene.fill(caret.0, caret.1 + ui.px(1.0), line.max(2.0), row - ui.px(2.0), theme::ACCENT);
        }
        ui.painter.scene.set_clip(None);
        let mut y = editor.bottom() + ui.px(8.0);
        if let Some(path) = context {
            let name = Path::new(path).file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
            let label = format!("Include path: {name}");
            let box_rect = Rect::new(composer.x + ui.px(10.0), y + ui.px(1.0), ui.px(12.0), ui.px(12.0));
            ui.rounded(box_rect, 3.0, if self.include_file { theme::ACCENT } else { theme::rgb(0x3A3A3A) });
            if self.include_file {
                ui.icon("checkmark", 8.0, IconWeight::Semibold, box_rect.x + box_rect.width * 0.5, box_rect.y + box_rect.height * 0.5, theme::EDITOR_BACKGROUND);
            }
            let label = ui.fit_middle(&label, composer.width - ui.px(40.0), 10.0, 400, false);
            let width = ui.text(&label, box_rect.right() + ui.px(6.0), y + ui.px(7.0), 10.0, 400, false, theme::TEXT_PRIMARY);
            self.buttons.push((Rect::new(box_rect.x, y, width + ui.px(20.0), ui.px(14.0)), "include".into()));
            y += ui.px(14.0 + 8.0);
        }
        let row_middle = y + ui.px(10.0);
        let (label, what, enabled) = if state.is_busy { ("Stop", "stop", state.is_ready) } else { ("Send", "send", state.is_ready && !self.draft.trim().is_empty()) };
        let button_width = ui.measure(label, 11.0, 500, false) + ui.px(18.0);
        let button = Rect::new(composer.right() - ui.px(10.0) - button_width, y, button_width, ui.px(20.0));
        ui.rounded(button, 5.0, theme::rgb(0x3A3A3A));
        ui.text(label, button.x + ui.px(9.0), row_middle, 11.0, 500, false, if enabled { theme::TEXT_PRIMARY } else { faded(theme::TEXT_SECONDARY, 0.6) });
        if enabled {
            self.buttons.push((button, what.into()));
        }
        let folder = self.session.directory().file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
        let note = ui.fit_middle(&format!("ACP \u{b7} {folder}"), button.x - composer.x - ui.px(24.0), 10.0, 400, false);
        ui.text(&note, composer.x + ui.px(10.0), row_middle, 10.0, 400, false, theme::TEXT_SECONDARY);

        // The conversation: laid out top to bottom, drawn from the end.
        let list = Rect::new(rect.x, rect.y + ui.px(10.0 + 14.0 + 10.0), rect.width, composer.y - line - rect.y - ui.px(34.0));
        self.list = list;
        let (pad, gap) = (ui.px(12.0), ui.px(16.0));
        let inner = (list.width - 2.0 * pad).max(ui.px(40.0));
        let left = list.x + pad;
        // Blocks: (height, draw).
        enum Block {
            Text { lines: std::rc::Rc<Vec<String>>, points: f32, monospace: bool, color: theme::Rgba, row: f32, weight: u16 },
            Space(f32),
            Disclosure { label: String, sub: Option<String>, open: bool, what: String },
            Button { label: String, what: String, enabled: bool },
            Card(f32),
            Icon(&'static str, String),
        }
        let mut blocks: Vec<Block> = Vec::new();
        let text_block = |this: &mut Conversation, ui: &mut Ui, text: &str, width: f32, points: f32, monospace: bool, color: theme::Rgba| Block::Text { lines: this.lines(ui, text, width, points, monospace), points, monospace, color, row: ui.px((points * 1.35).round()), weight: 400 };
        if state.messages.is_empty() {
            blocks.push(Block::Space(ui.px(16.0)));
            blocks.push(text_block(self, ui, "Ask about your project or describe a change.", inner, 13.0, false, theme::TEXT_SECONDARY));
            blocks.push(Block::Space(gap));
        }
        // Messages and tool calls in the order they happened: each tool after the messages that came
        // before it (they were all drawn after every message, so a reply's last words sat above the
        // tool calls that preceded them).
        let tool_block = |this: &mut Conversation, ui: &mut Ui, blocks: &mut Vec<Block>, tool: &neolink_acp::Tool| {
            let open = this.open_tools.contains(&tool.id);
            blocks.push(Block::Disclosure { label: tool.title.clone(), sub: Some(tool.status.clone()), open, what: format!("tool:{}", tool.id) });
            if open {
                blocks.push(text_block(this, ui, &tool.details, inner - ui.px(16.0), 10.0, true, theme::TEXT_PRIMARY));
            }
            blocks.push(Block::Space(gap));
        };
        let mut previous_role: Option<&str> = None;
        for (index, message) in state.messages.iter().enumerate() {
            for tool in state.tools.iter().filter(|tool| tool.after_message == index) {
                tool_block(self, ui, &mut blocks, tool);
            }
            // One reply reads as one: its name is not repeated after a tool call.
            if previous_role != Some(message.role.as_str()) {
                blocks.push(Block::Text { lines: std::rc::Rc::new(vec![message.role.clone()]), points: 10.0, monospace: false, color: theme::TEXT_SECONDARY, row: ui.px(13.0), weight: 600 });
                blocks.push(Block::Space(ui.px(6.0)));
            }
            previous_role = Some(message.role.as_str());
            if Some(message.id) == streaming {
                // While text streams in, each paragraph is wrapped on its own, so a chunk lays out only
                // the last paragraph.
                for paragraph in message.text.split("\n\n") {
                    blocks.push(text_block(self, ui, paragraph, inner, 12.0, false, theme::TEXT_PRIMARY));
                    blocks.push(Block::Space(ui.px(16.0)));
                }
                blocks.pop();
            } else {
                blocks.push(text_block(self, ui, &message.text, inner, 12.0, false, theme::TEXT_PRIMARY));
            }
            blocks.push(Block::Space(gap));
        }
        if !state.plan.is_empty() {
            blocks.push(Block::Disclosure { label: "Plan".into(), sub: None, open: self.plan_open, what: "plan".into() });
            if self.plan_open {
                for entry in &state.plan {
                    blocks.push(text_block(self, ui, entry, inner - ui.px(16.0), 11.0, false, theme::TEXT_PRIMARY));
                }
            }
            blocks.push(Block::Space(gap));
        }
        for tool in state.tools.iter().filter(|tool| tool.after_message >= state.messages.len()) {
            tool_block(self, ui, &mut blocks, tool);
        }
        if let Some(error) = &state.error {
            blocks.push(text_block(self, ui, error, inner, 11.0, false, theme::rgb(0xC6B28E)));
            blocks.push(Block::Space(gap));
        }
        if !state.is_ready {
            for method in &state.auth_methods {
                blocks.push(Block::Button { label: format!("Sign in \u{b7} {}", method.name), what: format!("auth:{}", method.id), enabled: !state.is_busy });
                blocks.push(Block::Space(ui.px(8.0)));
            }
        }
        if let Some(permission) = state.permissions.first() {
            let card_inner = inner - ui.px(24.0);
            let mut card: Vec<Block> = vec![Block::Space(ui.px(12.0)), Block::Icon("hand.raised", "Permission needed".into()), Block::Space(ui.px(8.0))];
            card.push(text_block(self, ui, &permission.title, card_inner, 12.0, false, theme::TEXT_PRIMARY));
            card.push(Block::Space(ui.px(8.0)));
            // The details are shown in a 72-point box, from their start.
            let details = self.lines(ui, &permission.details, card_inner, 10.0, true);
            let shown: Vec<String> = details.iter().take(5).cloned().collect();
            card.push(Block::Text { lines: std::rc::Rc::new(shown), points: 10.0, monospace: true, color: theme::TEXT_PRIMARY, row: ui.px(14.0), weight: 400 });
            card.push(Block::Space(ui.px(8.0)));
            for option in &permission.options {
                card.push(Block::Button { label: option.name.clone(), what: format!("permit:{}:{}", permission.id, option.id), enabled: true });
                card.push(Block::Space(ui.px(8.0)));
            }
            card.push(Block::Button { label: "Cancel request".into(), what: format!("deny:{}", permission.id), enabled: true });
            card.push(Block::Space(ui.px(12.0)));
            let height: f32 = card.iter().map(|block| block_height(ui, block)).sum();
            blocks.push(Block::Card(height));
            blocks.extend(card);
        }
        fn block_height(ui: &Ui, block: &Block) -> f32 {
            match block {
                Block::Text { lines, row, .. } => lines.len() as f32 * row,
                Block::Space(height) => *height,
                Block::Disclosure { sub, .. } => ui.px(if sub.is_some() { 34.0 } else { 18.0 }),
                Block::Button { .. } => ui.px(22.0),
                Block::Card(_) => 0.0,
                Block::Icon(..) => ui.px(16.0),
            }
        }
        let content: f32 = pad + blocks.iter().map(|block| block_height(ui, block)).sum::<f32>() + pad;
        let limit = (content - list.height).max(0.0);
        self.from_end = self.from_end.clamp(0.0, limit);
        let mut y = list.y + pad - (limit - self.from_end).round();
        ui.painter.scene.set_clip(Some(list));
        let mut inset = 0.0f32;
        let mut card_end = f32::MIN;
        for block in &blocks {
            let height = block_height(ui, block);
            if y > card_end {
                inset = 0.0;
            }
            let x = left + inset;
            if y + height >= list.y && y <= list.bottom() || matches!(block, Block::Card(_)) {
                match block {
                    Block::Text { lines, points, monospace, color, row, weight } => {
                        for (index, text) in lines.iter().enumerate() {
                            let line_y = y + index as f32 * row;
                            if !text.is_empty() && line_y + row >= list.y && line_y <= list.bottom() {
                                ui.text(text, x, line_y + row * 0.5, *points, *weight, *monospace, *color);
                            }
                        }
                    }
                    Block::Space(_) => {}
                    Block::Disclosure { label, sub, open, what } => {
                        ui.icon(if *open { "chevron.down" } else { "chevron.right" }, 8.0, IconWeight::Semibold, x + ui.px(5.0), y + ui.px(9.0), theme::TEXT_SECONDARY);
                        let label = ui.fit_middle(label, inner - ui.px(20.0), 11.0, 400, false);
                        ui.text(&label, x + ui.px(16.0), y + ui.px(9.0), 11.0, 400, false, theme::TEXT_PRIMARY);
                        if let Some(sub) = sub {
                            ui.text(sub, x + ui.px(16.0), y + ui.px(18.0 + 3.0 + 6.0), 11.0, 400, false, theme::TEXT_SECONDARY);
                        }
                        self.buttons.push((Rect::new(list.x, y.max(list.y), list.width, (height - (list.y - y).max(0.0)).max(0.0)), what.clone()));
                    }
                    Block::Button { label, what, enabled } => {
                        let width = (ui.measure(label, 12.0, 400, false) + ui.px(20.0)).min(inner - 2.0 * inset);
                        let button = Rect::new(x, y, width, height);
                        ui.rounded(button, 5.0, theme::rgb(0x3A3A3A));
                        let label = ui.fit_middle(label, width - ui.px(16.0), 12.0, 400, false);
                        ui.text(&label, button.x + ui.px(10.0), y + height * 0.5, 12.0, 400, false, if *enabled { theme::TEXT_PRIMARY } else { faded(theme::TEXT_SECONDARY, 0.6) });
                        if *enabled && y >= list.y && y + height <= list.bottom() {
                            self.buttons.push((button, what.clone()));
                        }
                    }
                    Block::Card(card_height) => {
                        ui.rounded(Rect::new(left, y, inner, *card_height), 6.0, theme::ELEVATED);
                        inset = ui.px(12.0);
                        card_end = y + card_height - 1.0;
                    }
                    Block::Icon(symbol, label) => {
                        let icon = ui.icon(symbol, 11.0, IconWeight::Semibold, x + ui.px(7.0), y + ui.px(8.0), theme::TEXT_PRIMARY).max(ui.px(14.0));
                        ui.text(label, x + icon + ui.px(5.0), y + ui.px(8.0), 11.0, 600, false, theme::TEXT_PRIMARY);
                    }
                }
            }
            y += height;
        }
        ui.painter.scene.set_clip(None);
        if content > list.height {
            let thumb = (list.height * list.height / content).max(ui.px(24.0));
            let travel = (list.height - thumb) * (limit - self.from_end) / limit.max(1.0);
            ui.rounded(Rect::new(list.right() - ui.px(6.0), list.y + travel, ui.px(4.0), thumb), 2.0, theme::white(0.16));
        }
    }
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
    /// Open Source Control for the conversation's project.
    ShowGit,
    /// Send the prompt (the workspace supplies the context file).
    Submit,
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
    /// The focused field's text is selected: the next key replaces it (as text fields do on focus).
    selected_all: bool,
    pub error: Option<String>,
    claude_found: bool,
    buttons: Vec<(Rect, &'static str)>,
    frame: Rect,
}

impl Launcher {
    pub fn new(directory: Option<PathBuf>, custom_name: String, custom_executable: String) -> Launcher {
        Launcher { directory, acp: false, custom: false, continue_session: false, docked: true, mcp_open: false, name: custom_name, executable: custom_executable, arguments: String::new(), mcp: String::new(), focus: None, selected_all: false, error: None, claude_found: executable("claude").is_some(), buttons: Vec::new(), frame: Rect::default() }
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
        // A field entered with its text selected: typing or Backspace replaces all of it (the agent name
        // is prefilled with "My agent", and typing used to append to it).
        let replacing = std::mem::take(&mut self.selected_all);
        let field = match field {
            Some(field) if replacing && (matches!(key, Key::Named(NamedKey::Backspace)) || text.is_some_and(|text| !text.is_empty() && !text.chars().any(char::is_control))) => {
                field.clear();
                if matches!(key, Key::Named(NamedKey::Backspace)) {
                    return Some(Outcome::Nothing);
                }
                Some(field)
            }
            field => field,
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
                self.selected_all = true;
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
                self.selected_all = true;
            }
            "continue" => self.continue_session = !self.continue_session,
            "docked" => self.docked = !self.docked,
            "mcp-toggle" => {
                self.mcp_open = !self.mcp_open;
                self.focus = self.mcp_open.then_some(Field::Mcp);
            }
            "field-name" | "field-executable" | "field-arguments" | "field-mcp" => {
                let field = match what {
                    "field-name" => Field::Name,
                    "field-executable" => Field::Executable,
                    "field-arguments" => Field::Arguments,
                    _ => Field::Mcp,
                };
                // Clicking into another field selects its text; clicking the focused one again does not.
                self.selected_all = self.focus != Some(field);
                self.focus = Some(field);
            }
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
        self.selected_all.hash(&mut hasher);
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
            let selected = focused && self.selected_all;
            for (index, text) in value.split('\n').enumerate() {
                let y = rect.y + if multiline { ui.px(4.0) } else { (rect.height - row) * 0.5 } + index as f32 * row;
                if selected && !text.is_empty() {
                    let width = ui.measure(text, points, 400, monospace);
                    ui.rounded(Rect::new(rect.x + ui.px(6.0), y + ui.px(1.0), width + ui.px(2.0), row - ui.px(2.0)), 3.0, theme::TERMINAL_SELECTION);
                }
                let width = if text.is_empty() { 0.0 } else { ui.text(text, rect.x + ui.px(7.0), y + row * 0.5, points, 400, monospace, theme::TEXT_PRIMARY) + line };
                caret = (rect.x + ui.px(7.0) + width, y);
            }
        }
        if focused && !(self.selected_all && !value.is_empty()) {
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
        // Underlined, with the arrow that says it opens in the browser: the accent is a gray here,
        // so color alone does not set a link apart from text.
        let width = ui.text(&format!("{label} \u{2197}"), x, y + ui.px(8.0), 13.0, 400, false, theme::TEXT_PRIMARY);
        let line = ui.px(1.0).max(1.0).round();
        ui.painter.scene.fill(x, (y + ui.px(17.0)).round(), width, line, theme::white(0.35));
        self.buttons.push((Rect::new(x, y, width, ui.px(18.0)), what));
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
    pub fn rect(&self) -> Rect {
        self.rect
    }

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
        match self.sessions.get_mut(self.selected).map(|session| &mut session.kind) {
            Some(Kind::Terminal(terminal)) => Some(terminal),
            _ => None,
        }
    }

    fn conversation(&mut self) -> Option<&mut Conversation> {
        match self.sessions.get_mut(self.selected).map(|session| &mut session.kind) {
            Some(Kind::Conversation(conversation)) => Some(conversation),
            _ => None,
        }
    }

    /// The shown session is a conversation whose prompt field has the keyboard.
    pub fn composing(&self) -> bool {
        self.visible && self.focused && matches!(self.sessions.get(self.selected).map(|session| &session.kind), Some(Kind::Conversation(_)))
    }

    /// A key for the prompt field.
    pub fn key(&mut self, key: &Key, text: Option<&str>) {
        if let Some(conversation) = self.conversation() {
            conversation.key(key, text);
        }
    }

    /// Command-Return in the prompt field: send.
    pub fn submit(&mut self, context: Option<&str>) {
        if let Some(conversation) = self.conversation() {
            conversation.submit(context);
        }
    }

    pub fn set_mode(&mut self, mode: &str) {
        if let Some(conversation) = self.conversation() {
            conversation.session.set_mode(mode);
        }
    }

    /// Scrolls the shown conversation by `delta` pixels. Returns `false` if a terminal is shown.
    pub fn scroll_conversation(&mut self, delta: f32) -> bool {
        match self.conversation() {
            Some(conversation) => {
                conversation.from_end += delta;
                true
            }
            None => false,
        }
    }

    /// Whether a conversation finished a turn since the last call (saved files may have changed).
    pub fn take_finished_turn(&mut self) -> bool {
        let mut finished = false;
        for session in &mut self.sessions {
            if let Kind::Conversation(conversation) = &mut session.kind {
                let turns = conversation.session.state().turns_finished;
                finished |= turns != conversation.seen_turns;
                conversation.seen_turns = turns;
            }
        }
        finished
    }

    /// Starts a native conversation with `agent`.
    pub fn connect(&mut self, shared: &Arc<Shared>, agent: &CodingAgent, directory: &Path, mcp: Vec<serde_json::Value>) {
        let id = self.next_id;
        self.next_id += 1;
        let wake = Arc::downgrade(shared);
        let session = neolink_acp::Session::new(agent.clone(), directory, mcp, move || {
            if let Some(shared) = wake.upgrade() {
                shared.invalidate();
            }
        });
        session.connect(executable(&agent.executable).as_deref());
        let conversation = Conversation { session, draft: String::new(), include_file: false, plan_open: false, open_tools: Default::default(), from_end: 0.0, wrapped: Default::default(), buttons: Vec::new(), list: Rect::default(), composer: Rect::default(), seen_turns: 0 };
        self.sessions.push(Session { id, title: format!("{} \u{b7} ACP", agent.name), kind: Kind::Conversation(Box::new(conversation)) });
        self.selected = self.sessions.len() - 1;
        self.visible = true;
        self.focused = true;
    }

    /// Starts `agent` in a shell in the panel.
    pub fn launch(&mut self, shared: &Arc<Shared>, agent: &CodingAgent, directory: &Path, cell: CellMetrics) -> std::io::Result<()> {
        let id = self.next_id;
        self.next_id += 1;
        let mut terminal = Terminal::spawn(shared, self.grid.0.max(20), self.grid.1.max(5), cell, Some(directory.to_path_buf()), id)?;
        let resolved = executable(&agent.executable);
        terminal.write(agent.launch_command(&directory.to_string_lossy(), resolved.as_deref()).replace('\n', "\r").into_bytes());
        self.sessions.push(Session { id, title: agent.name.clone(), kind: Kind::Terminal(terminal) });
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
            match self.sessions.remove(self.selected).kind {
                Kind::Terminal(terminal) => terminal.shutdown(),
                Kind::Conversation(conversation) => conversation.session.close(),
            }
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
        if let Some(conversation) = self.conversation() {
            let pressed = conversation.buttons.iter().rev().find(|(rect, _)| rect.contains(x, y)).map(|(rect, what)| (*rect, what.clone()));
            let in_composer = conversation.composer.contains(x, y);
            let mut outcome = Outcome::Nothing;
            if let Some((rect, what)) = pressed {
                match what.as_str() {
                    "git" => outcome = Outcome::ShowGit,
                    "modes" => {
                        let state = conversation.session.state();
                        outcome = Outcome::Menu(Menu::new(rect, state.modes.iter().map(|mode| Item::toggle(&mode.name, Action::AgentMode(mode.id.clone()), mode.id == state.current_mode)).collect()));
                    }
                    "include" => conversation.include_file = !conversation.include_file,
                    "send" => outcome = Outcome::Submit,
                    "stop" => conversation.session.cancel(),
                    "plan" => conversation.plan_open = !conversation.plan_open,
                    other => {
                        if let Some(tool) = other.strip_prefix("tool:") {
                            if !conversation.open_tools.remove(tool) {
                                conversation.open_tools.insert(tool.to_string());
                            }
                        } else if let Some(method) = other.strip_prefix("auth:") {
                            conversation.session.authenticate(method);
                        } else if let Some(rest) = other.strip_prefix("permit:") {
                            if let Some((id, option)) = rest.split_once(':') {
                                conversation.session.answer(id.parse().unwrap_or(0), Some(option));
                            }
                        } else if let Some(id) = other.strip_prefix("deny:") {
                            conversation.session.answer(id.parse().unwrap_or(0), None);
                        }
                    }
                }
            }
            self.focused = in_composer || self.focused;
            return outcome;
        }
        self.focused = self.terminal_rect.contains(x, y) && !self.sessions.is_empty();
        Outcome::Nothing
    }

    pub fn control_rect(&self, name: &str) -> Option<Rect> {
        if let Some(Kind::Conversation(conversation)) = self.sessions.get(self.selected).map(|session| &session.kind) {
            if name == "composer" {
                return Some(conversation.composer);
            }
            // "permit" and "deny" stand for the first such button.
            if let Some((rect, _)) = conversation.buttons.iter().find(|(_, what)| what == name || what.split(':').next() == Some(name)) {
                return Some(*rect);
            }
        }
        self.buttons.iter().find(|(_, what)| *what == name).map(|(rect, _)| *rect)
    }

    pub fn signature(&self) -> u64 {
        let mut value = (self.visible as u64) | (self.focused as u64) << 1 | (self.selected as u64) << 8 | (self.sessions.len() as u64) << 24 | (self.width_points.to_bits() as u64) << 32;
        match self.sessions.get(self.selected).map(|session| &session.kind) {
            Some(Kind::Terminal(terminal)) => value ^= terminal.output_generation().wrapping_mul(0x9E3779B97F4A7C15) ^ terminal.scroll().to_bits() ^ terminal.look().rotate_left(21),
            Some(Kind::Conversation(conversation)) => {
                use std::hash::{Hash, Hasher};
                let mut hasher = std::collections::hash_map::DefaultHasher::new();
                (conversation.session.revision(), &conversation.draft, conversation.include_file, conversation.plan_open, conversation.open_tools.len(), conversation.from_end.to_bits()).hash(&mut hasher);
                value ^= hasher.finish();
            }
            None => {}
        }
        value
    }

    /// Draws the panel in `rect`. Sessions whose program ended are removed.
    #[allow(clippy::too_many_arguments)]
    pub fn build(&mut self, painter: &mut Painter, rect: Rect, scale: f32, cell: CellMetrics, window_focused: bool, context: Option<&str>, display: f64, period: f64) -> Next {
        self.rect = rect;
        self.buttons.clear();
        let before = self.sessions.len();
        self.sessions.retain(|session| !matches!(&session.kind, Kind::Terminal(terminal) if terminal.has_exited()));
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
        let conversing = matches!(self.sessions[self.selected].kind, Kind::Conversation(_));
        ui.text(if conversing { "Agent conversation" } else { "Project terminal" }, rect.x + ui.px(10.0), footer_middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        let count = self.sessions.len();
        ui.text_right(&format!("{count} {}", if count == 1 { "session" } else { "sessions" }), rect.right() - ui.px(10.0), footer_middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        // The terminal, a whole number of cells.
        let area = Rect::new(rect.x + ui.px(8.0), row.bottom() + ui.px(4.0), rect.width - ui.px(8.0), footer.y - row.bottom() - ui.px(4.0));
        let grid = (((area.width / cell.width).floor() as usize).max(2), ((area.height / cell.height).floor() as usize).max(1));
        self.terminal_rect = Rect::new(area.x, area.y, area.width, grid.1 as f32 * cell.height);
        if grid != self.grid {
            self.grid = grid;
            for session in &mut self.sessions {
                if let Kind::Terminal(terminal) = &mut session.kind {
                    terminal.resize(grid.0, grid.1, cell);
                }
            }
        }
        let (terminal_rect, focused) = (self.terminal_rect, self.focused && window_focused);
        match &mut self.sessions[self.selected].kind {
            Kind::Terminal(terminal) => terminal.build(painter, terminal_rect, focused, display, period),
            Kind::Conversation(conversation) => {
                let area = Rect::new(rect.x, row.bottom(), rect.width, footer.y - row.bottom());
                let mut ui = Ui { painter, scale };
                conversation.draw(&mut ui, area, context, focused);
                Next::Idle
            }
        }
    }
}
