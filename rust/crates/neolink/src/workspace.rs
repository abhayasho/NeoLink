//! The window's content: a strip of tabs over the active pane. Panes stay alive when they are not shown;
//! switching is drawing a different pane into the same surface.

use crate::chrome::{faded, Ui};
use crate::editor::Editor;
use crate::icons::IconWeight;
use crate::explorer::Explorer;
use crate::frame::{Built, Content, FrameContext, FrameMarks, Next, Painter, Shared};
use crate::render::Rect;
use crate::term::{ScrollPhase, Terminal};
use crate::text::CellMetrics;
use crate::theme;
use std::sync::{Arc, Weak};

pub const MIN_FONT_POINTS: f32 = 9.0;
pub const MAX_FONT_POINTS: f32 = 32.0;

enum Pane {
    Terminal(Terminal),
    /// A file in the shared editor.
    Document { path: String, title: String },
}

struct Tab {
    id: u64,
    pane: Pane,
}

impl Tab {
    fn terminal(&self) -> Option<&Terminal> {
        match &self.pane {
            Pane::Terminal(terminal) => Some(terminal),
            Pane::Document { .. } => None,
        }
    }

    fn document(&self) -> Option<&str> {
        match &self.pane {
            Pane::Document { path, .. } => Some(path),
            Pane::Terminal(_) => None,
        }
    }
}

pub struct Workspace {
    shared: Weak<Shared>,
    tabs: Vec<Tab>,
    /// The tab the user selected; input goes to it.
    active: usize,
    /// The tab whose pane is drawn. It follows `active` at once for a terminal, and for a document
    /// when Neovim has confirmed that its screen is that document's.
    shown: usize,
    /// `selection` as it was when `shown` last caught up with `active`.
    shown_selection: u64,
    /// One Neovim for every document tab, started with the first one.
    editor: Option<Editor>,
    pub explorer: Explorer,
    sidebar: Rect,
    notice: Option<String>,
    /// The document whose unsaved changes the user has just been warned about.
    close_warned: Option<String>,
    /// A save was sent: refresh the explorer once Neovim has answered it.
    refresh_explorer_soon: bool,
    seen_replies: u64,
    pointer: (f32, f32),
    next_id: u64,
    pub cell: CellMetrics,
    pub font_points: f32,
    applied_font: (f32, f32),
    scale: f32,
    period: f64,
    /// The terminal pane's grid, from the last layout.
    grid: (usize, usize),
    /// The editor's grid: its pane has a toolbar above and a footer below instead of a status bar.
    editor_grid: (usize, usize),
    pane: Rect,
    editor_pane: Rect,
    header: Rect,
    footer: Rect,
    center: Rect,
    status_bar: Rect,
    toolbar: Rect,
    editor_footer: Rect,
    strip: Rect,
    tab_rects: Vec<Rect>,
    close_rects: Vec<Rect>,
    plus_rect: Rect,
    /// Clickable parts of the header: `(where, what)`.
    header_buttons: Vec<(Rect, &'static str)>,
    hover_close: Option<usize>,
    pub focused: bool,
    selection: u64,
    marks: FrameMarks,
    /// Called (on the render thread) when the last tab's program has exited.
    on_empty: Option<Box<dyn Fn() + Send>>,
    hover: Option<usize>,
    /// Signature of the last frame built.
    signature: u64,
}

impl Workspace {
    pub fn new(cell: CellMetrics, font_points: f32, scale: f32, size: (u32, u32), period: f64) -> Workspace {
        let mut workspace = Workspace {
            shared: Weak::new(),
            tabs: Vec::new(),
            active: 0,
            shown: 0,
            shown_selection: 0,
            editor: None,
            explorer: Explorer::new(project_directory()),
            sidebar: Rect::default(),
            notice: None,
            close_warned: None,
            refresh_explorer_soon: false,
            seen_replies: 0,
            pointer: (-1.0, -1.0),
            next_id: 1,
            cell,
            font_points,
            applied_font: (font_points, scale),
            scale,
            period,
            grid: (80, 24),
            editor_grid: (80, 24),
            pane: Rect::default(),
            editor_pane: Rect::default(),
            header: Rect::default(),
            footer: Rect::default(),
            center: Rect::default(),
            status_bar: Rect::default(),
            toolbar: Rect::default(),
            editor_footer: Rect::default(),
            strip: Rect::default(),
            tab_rects: Vec::new(),
            close_rects: Vec::new(),
            plus_rect: Rect::default(),
            header_buttons: Vec::new(),
            hover_close: None,
            focused: true,
            selection: 0,
            marks: FrameMarks::default(),
            on_empty: None,
            hover: None,
            signature: 0,
        };
        workspace.layout(size);
        workspace
    }

    pub fn set_on_empty(&mut self, callback: Box<dyn Fn() + Send>) {
        self.on_empty = Some(callback);
    }

    /// Lays the window out as the Swift app does (`ContentView`, `TabbedTerminalView`, `CodeWorkspaceView`;
    /// sizes in points): a 34 pt header, the explorer pane, the tab strip over the pane, and a 22 pt
    /// footer. A terminal pane has 8 pt of padding at its left and top and a 28 pt status bar below; the
    /// editor has a 30 pt toolbar above and a 22 pt footer below.
    fn layout(&mut self, size: (u32, u32)) -> bool {
        let scale = self.scale;
        let px = |points: f32| (points * scale).round();
        let (width, height) = (size.0 as f32, size.1 as f32);
        let line = px(1.0).max(1.0);
        self.header = Rect::new(0.0, 0.0, width, px(34.0));
        self.footer = Rect::new(0.0, height - px(22.0), width, px(22.0));
        let top = self.header.bottom() + line;
        let bottom = self.footer.y - line;
        let explorer_width = if self.explorer.visible { px(crate::explorer::WIDTH_POINTS).min(width * 0.5) } else { 0.0 };
        self.sidebar = Rect::new(0.0, top, explorer_width, (bottom - top).max(1.0));
        let center_x = if explorer_width > 0.0 { explorer_width + line } else { 0.0 };
        self.center = Rect::new(center_x, top, (width - center_x).max(1.0), (bottom - top).max(1.0));
        self.strip = Rect::new(center_x, top, self.center.width, px(34.0));
        let below = self.strip.bottom() + line;
        self.status_bar = Rect::new(center_x, self.center.bottom() - px(28.0), self.center.width, px(28.0));
        let terminal = Rect::new(center_x + px(8.0), below + px(8.0), (self.center.width - px(8.0)).max(1.0), (self.status_bar.y - below - px(8.0)).max(1.0));
        let grid = (((terminal.width / self.cell.width).floor() as usize).max(2), ((terminal.height / self.cell.height).floor() as usize).max(1));
        // A pane is a whole number of cells tall, so a scrolled row is clipped at a row boundary.
        self.pane = Rect::new(terminal.x, terminal.y, terminal.width, grid.1 as f32 * self.cell.height);
        self.toolbar = Rect::new(center_x, below, self.center.width, px(30.0));
        self.editor_footer = Rect::new(center_x, self.center.bottom() - px(22.0), self.center.width, px(22.0));
        let editor = Rect::new(center_x, self.toolbar.bottom(), self.center.width, (self.editor_footer.y - self.toolbar.bottom()).max(1.0));
        let editor_grid = (((editor.width / self.cell.width).floor() as usize).max(20), ((editor.height / self.cell.height).floor() as usize).max(4));
        self.editor_pane = Rect::new(editor.x, editor.y, editor.width, editor_grid.1 as f32 * self.cell.height);
        let changed = grid != self.grid || editor_grid != self.editor_grid;
        self.grid = grid;
        self.editor_grid = editor_grid;
        changed
    }

    pub fn grid(&self) -> (usize, usize) {
        self.grid
    }

    pub fn tab_count(&self) -> usize {
        self.tabs.len()
    }

    pub fn active_index(&self) -> usize {
        self.active
    }

    /// The window's shared state, for panes that wake the render thread from their own threads.
    pub fn attach(&mut self, shared: &Arc<Shared>) {
        self.shared = Arc::downgrade(shared);
        self.explorer.attach(shared);
    }

    /// Shows a different folder in the explorer.
    pub fn set_project(&mut self, root: std::path::PathBuf) {
        let visible = self.explorer.visible;
        self.explorer = Explorer::new(root);
        self.explorer.visible = visible;
        if let Some(shared) = self.shared.upgrade() {
            self.explorer.attach(&shared);
        }
    }

    pub fn toggle_explorer(&mut self) {
        self.explorer.visible = !self.explorer.visible;
    }

    /// The active tab's terminal, if it is one.
    pub fn active(&mut self) -> Option<&mut Terminal> {
        match self.tabs.get_mut(self.active).map(|tab| &mut tab.pane) {
            Some(Pane::Terminal(terminal)) => Some(terminal),
            _ => None,
        }
    }

    /// Whether the pane on screen is the active tab's.
    pub fn shows_active(&self) -> bool {
        self.shown == self.active && self.shown_selection == self.selection
    }

    pub fn active_is_document(&self) -> bool {
        self.tabs.get(self.active).is_some_and(|tab| tab.document().is_some())
    }

    fn active_document(&self) -> Option<String> {
        self.tabs.get(self.active).and_then(|tab| tab.document()).map(str::to_string)
    }

    pub fn new_tab(&mut self, shared: &Arc<Shared>) -> std::io::Result<()> {
        let directory = std::env::var_os("NEOLINK_START_DIRECTORY").map(std::path::PathBuf::from).or_else(|| Some(self.explorer.root().to_path_buf())).or_else(home_directory);
        let id = self.next_id;
        self.next_id += 1;
        let terminal = Terminal::spawn(shared, self.grid.0, self.grid.1, self.cell, directory, id)?;
        self.tabs.push(Tab { id, pane: Pane::Terminal(terminal) });
        self.select(self.tabs.len() - 1);
        Ok(())
    }

    /// Opens `path` in the editor, in its existing tab if it has one.
    pub fn open_document(&mut self, path: &std::path::Path) {
        let path = neolink_core::paths::canonical(path);
        let Some(path) = path.to_str().map(str::to_string) else { return };
        if let Some(index) = self.tabs.iter().position(|tab| tab.document() == Some(path.as_str())) {
            self.select(index);
            return;
        }
        let title = std::path::Path::new(&path).file_name().and_then(|name| name.to_str()).unwrap_or(&path).to_string();
        let id = self.next_id;
        self.next_id += 1;
        self.tabs.push(Tab { id, pane: Pane::Document { path, title } });
        self.select(self.tabs.len() - 1);
    }

    fn ensure_editor(&mut self) -> bool {
        if self.editor.as_ref().is_some_and(|editor| !editor.has_exited()) {
            return true;
        }
        let Some(shared) = self.shared.upgrade() else { return false };
        match Editor::start(&shared, self.editor_grid.0, self.editor_grid.1) {
            Ok(editor) => {
                self.editor = Some(editor);
                true
            }
            Err(error) => {
                self.notice = Some(error);
                self.editor = None;
                false
            }
        }
    }

    /// Closes a tab. A document with unsaved changes is kept the first time, with a message saying
    /// how to save or discard; asking again discards.
    pub fn close_tab(&mut self, index: usize) {
        if index >= self.tabs.len() {
            return;
        }
        if let Some(path) = self.tabs[index].document().map(str::to_string) {
            let unsaved = self.editor.as_ref().is_some_and(|editor| editor.is_modified(&path));
            if unsaved && self.close_warned.as_deref() != Some(path.as_str()) {
                let name = std::path::Path::new(&path).file_name().and_then(|name| name.to_str()).unwrap_or(&path).to_string();
                let (save, close) = if cfg!(target_os = "macos") { ("Command-S", "Command-W") } else { ("Ctrl-Shift-S", "Ctrl-Shift-W") };
                self.notice = Some(format!("{name} has unsaved changes. {save} saves; {close} again closes without saving."));
                self.close_warned = Some(path);
                return;
            }
        }
        self.close_warned = None;
        let shown_id = self.tabs.get(self.shown).map(|tab| tab.id);
        let removed = self.tabs.remove(index);
        if let (Pane::Document { path, .. }, Some(editor)) = (&removed.pane, &self.editor) {
            editor.command("close", path);
        }
        if self.active > index || self.active >= self.tabs.len() {
            self.active = self.active.saturating_sub(1);
        }
        self.shown = shown_id.and_then(|id| self.tabs.iter().position(|tab| tab.id == id)).unwrap_or(self.active);
        self.reselect();
    }

    pub fn select(&mut self, index: usize) {
        if index < self.tabs.len() && (index != self.active || self.selection == 0) {
            self.active = index;
            self.reselect();
        }
    }

    /// Makes the active tab's pane the one to show (a document asks Neovim for its buffer).
    fn reselect(&mut self) {
        self.selection += 1;
        if let Some(path) = self.active_document() {
            if self.ensure_editor() {
                if let Some(editor) = &mut self.editor {
                    editor.select(&path);
                }
            }
        }
    }

    pub fn select_relative(&mut self, step: isize) {
        if self.tabs.is_empty() {
            return;
        }
        let count = self.tabs.len() as isize;
        self.select((self.active as isize + step).rem_euclid(count) as usize);
    }

    pub fn set_font_points(&mut self, points: f32) {
        self.font_points = points.clamp(MIN_FONT_POINTS, MAX_FONT_POINTS);
    }

    /// Bytes typed into the active terminal. Returns `true` if the view changed (it was scrolled back).
    pub fn write(&mut self, bytes: Vec<u8>) -> bool {
        match self.active() {
            Some(terminal) => terminal.write(bytes),
            None => false,
        }
    }

    /// Keys for the editor, in Neovim's notation (the active tab is a document).
    pub fn editor_input(&mut self, keys: &str) {
        if let Some(editor) = &self.editor {
            editor.input(keys);
        }
    }

    pub fn save_active(&mut self) {
        if let (Some(path), Some(editor)) = (self.active_document(), &self.editor) {
            editor.command("save", &path);
            self.refresh_explorer_soon = true;
        }
    }

    /// The window became active again, or files may have changed: read the open folders and Git again.
    pub fn refresh_explorer(&mut self) {
        self.explorer.refresh();
    }

    pub fn editor_action(&mut self, action: &str) {
        if let (true, Some(editor)) = (self.active_is_document(), &self.editor) {
            editor.action(action);
        }
    }

    pub fn paste(&mut self, text: &str) {
        if self.active_is_document() {
            if let Some(editor) = &self.editor {
                editor.paste(text);
            }
        } else if let Some(terminal) = self.active() {
            terminal.paste(text);
        }
    }

    /// The editor cell under the pointer.
    fn pointer_cell(&self) -> (usize, usize) {
        let row = ((self.pointer.1 - self.editor_pane.y) / self.cell.height).floor().clamp(0.0, self.editor_grid.1.saturating_sub(1) as f32) as usize;
        let column = ((self.pointer.0 - self.editor_pane.x) / self.cell.width).floor().clamp(0.0, self.editor_grid.0.saturating_sub(1) as f32) as usize;
        (row, column)
    }

    /// A scroll event in device pixels over the pane.
    pub fn scroll(&mut self, time: f64, _delta_x: f64, delta_y: f64, phase: ScrollPhase) {
        let (cell, period) = (self.cell, self.period);
        if self.explorer.contains(self.pointer.0, self.pointer.1) {
            self.explorer.scroll_input(time, delta_y, phase, period);
            return;
        }
        if self.active_is_document() {
            let (row, column) = self.pointer_cell();
            if let Some(editor) = &mut self.editor {
                if phase == ScrollPhase::Began {
                    editor.end_scroll_gesture();
                }
                editor.scroll(delta_y, cell, row, column);
            }
        } else if let Some(terminal) = self.active() {
            terminal.scroll_input(time, delta_y, phase, cell, period);
        }
    }

    pub fn scroll_pages(&mut self, pages: f64) {
        let distance = pages * self.grid.1 as f64 * self.cell.height as f64;
        if let Some(terminal) = self.active() {
            terminal.scroll_by(distance);
        }
    }

    /// A press at `(x, y)` device pixels. Returns `true` if it changed anything.
    pub fn click(&mut self, x: f32, y: f32) -> bool {
        if let Some((_, action)) = self.header_buttons.iter().find(|(rect, _)| rect.contains(x, y)).copied() {
            match action {
                "files" => self.toggle_explorer(),
                // Quick Open, Find in Files, Source Control, connections, the agent panel and the
                // agent launcher do not exist in this build yet (PLAN.md).
                _ => self.notice = Some(format!("{} is not available in this build yet.", match action {
                    "quick-open" => "Quick Open",
                    "find" => "Find in Files",
                    "git" => "Source Control",
                    "connections" => "The connections sidebar",
                    "agent-panel" => "The agent panel",
                    "agent" => "The agent launcher",
                    "project" => "The project menu",
                    _ => "This",
                })),
            }
            return true;
        }
        if self.explorer.contains(x, y) {
            match self.explorer.click(x, y) {
                crate::explorer::Clicked::File(file) => self.open_document(&file),
                crate::explorer::Clicked::Close => self.toggle_explorer(),
                crate::explorer::Clicked::Nothing => {}
            }
            return true;
        }
        if let Some(index) = self.close_rects.iter().position(|rect| rect.contains(x, y)) {
            self.close_tab(index);
            return true;
        }
        if self.plus_rect.contains(x, y) {
            if let Some(shared) = self.shared.upgrade() {
                let _ = self.new_tab(&shared);
            }
            return true;
        }
        if let Some(index) = self.tab_rects.iter().position(|rect| rect.contains(x, y)) {
            self.select(index);
            return true;
        }
        if self.editor_pane.contains(x, y) && self.active_is_document() && self.shown == self.active {
            let (row, column) = self.pointer_cell();
            if let Some(editor) = &self.editor {
                editor.mouse("press", row, column);
            }
            return true;
        }
        false
    }

    pub fn release(&mut self, x: f32, y: f32) {
        if self.editor_pane.contains(x, y) && self.active_is_document() && self.shown == self.active {
            let (row, column) = self.pointer_cell();
            if let Some(editor) = &self.editor {
                editor.mouse("release", row, column);
            }
        }
    }

    /// The pointer moved to `(x, y)`. Returns `true` if a hover highlight changed.
    pub fn pointer(&mut self, x: f32, y: f32) -> bool {
        self.pointer = (x, y);
        let hover = self.tab_rects.iter().position(|rect| rect.contains(x, y));
        let hover_close = self.close_rects.iter().position(|rect| rect.contains(x, y));
        let mut changed = hover != self.hover || hover_close != self.hover_close;
        self.hover = hover;
        self.hover_close = hover_close;
        changed |= self.explorer.pointer(x, y);
        changed
    }

    /// The shown pane's scroll position and received input, in lines.
    pub fn scroll_lines(&self) -> (f64, f64) {
        match self.tabs.get(self.shown).and_then(Tab::terminal) {
            Some(terminal) => (terminal.scroll() / self.cell.height as f64, terminal.received / self.cell.height as f64),
            None => (0.0, 0.0),
        }
    }

    /// A counter that moves whenever the active pane's program produced something to draw.
    pub fn output_generation(&self) -> u64 {
        match self.tabs.get(self.active).map(|tab| &tab.pane) {
            Some(Pane::Terminal(terminal)) => terminal.output_generation(),
            Some(Pane::Document { .. }) => self.editor.as_ref().map(Editor::generation).unwrap_or(0),
            None => 0,
        }
    }

    /// `(document selections shown from a remembered screen, selections that waited for Neovim)`.
    pub fn editor_cache_report(&self) -> (u64, u64) {
        self.editor.as_ref().map(|editor| (editor.speculated, editor.waited)).unwrap_or((0, 0))
    }

    pub fn smoothing_report(&self) -> (usize, usize, f64) {
        self.tabs.get(self.active).and_then(Tab::terminal).map(Terminal::smoothing_report).unwrap_or((0, 0, 0.0))
    }

    pub fn scale(&self) -> f32 {
        self.scale
    }

    /// Increases every time a different pane becomes the one shown.
    pub fn selection_generation(&self) -> u64 {
        self.selection
    }

    /// A message for the user (an editor error) along the bottom of the centre. Any key dismisses it.
    fn draw_notice(&mut self, painter: &mut Painter) {
        let Some(notice) = self.notice.clone() else { return };
        let mut ui = Ui { painter, scale: self.scale };
        let height = ui.px(26.0);
        let rect = Rect::new(self.center.x, self.center.bottom() - height - ui.px(28.0), self.center.width, height);
        ui.fill(rect, theme::rgb(0x382626));
        ui.painter.scene.set_clip(Some(rect));
        ui.text(&notice, rect.x + ui.px(12.0), rect.y + rect.height * 0.5, 11.0, 400, false, theme::rgb(0xE1B4B4));
        ui.painter.scene.set_clip(None);
    }

    pub fn dismiss_notice(&mut self) -> bool {
        self.notice.take().is_some()
    }

    /// The header (`ContentView.workspaceHeader`): project name at the left, tools at the right.
    fn draw_header(&mut self, painter: &mut Painter) {
        let mut ui = Ui { painter, scale: self.scale };
        let rect = self.header;
        ui.fill(rect, theme::SIDEBAR_BACKGROUND);
        let middle = rect.y + rect.height * 0.5;
        self.header_buttons.clear();
        let mut x = rect.x + ui.px(10.0);
        let icon_width = ui.icon("folder.badge.gearshape", 13.0, IconWeight::Regular, x + ui.px(9.0), middle, theme::ACCENT).max(ui.px(18.0));
        self.header_buttons.push((Rect::new(x, rect.y, icon_width, rect.height), "project"));
        x += icon_width + ui.px(10.0);
        let name = self.explorer.root().file_name().and_then(|name| name.to_str()).unwrap_or("Workspace").to_string();
        ui.text(&name, x, middle, 12.0, 500, false, theme::TEXT_PRIMARY);
        // Right to left: agent panel, files, connections, source control, find, quick open, Agent.
        let button = ui.px(28.0);
        let gap = ui.px(10.0);
        let mut right = rect.right() - ui.px(10.0);
        let explorer_shown = self.explorer.visible;
        for (symbol, action, lit) in [
            ("sidebar.right", "agent-panel", false),
            ("folder", "files", explorer_shown),
            ("sidebar.left", "connections", false),
            ("arrow.triangle.branch", "git", false),
            ("magnifyingglass", "find", false),
            ("doc.text.magnifyingglass", "quick-open", false),
        ] {
            let area = Rect::new(right - button, middle - button * 0.5, button, button);
            ui.icon(symbol, 12.0, IconWeight::Medium, area.x + button * 0.5, middle, if lit { theme::ACCENT } else { theme::TEXT_SECONDARY });
            self.header_buttons.push((area, action));
            right -= button + gap;
        }
        let label = ui.text_right("Agent", right, middle, 11.0, 500, false, theme::TEXT_PRIMARY);
        let sparkle = ui.icon("sparkles", 11.0, IconWeight::Medium, right - label - ui.px(11.0), middle, theme::TEXT_PRIMARY);
        self.header_buttons.push((Rect::new(right - label - ui.px(11.0) - sparkle, rect.y, label + sparkle + ui.px(16.0), rect.height), "agent"));
        ui.painter.scene.fill(rect.x, rect.bottom(), rect.width, ui.px(1.0).max(1.0), theme::SEPARATOR);
    }

    /// The tab strip (`TabbedTerminalView.tabStrip`, `WorkspaceTabButton`, `TabPresentation`).
    fn draw_strip(&mut self, painter: &mut Painter) {
        let mut ui = Ui { painter, scale: self.scale };
        let strip = self.strip;
        ui.fill(strip, theme::EDITOR_BACKGROUND);
        self.tab_rects.clear();
        self.close_rects.clear();
        let middle = strip.y + strip.height * 0.5;
        let line = ui.px(1.0).max(1.0);
        let mut x = strip.x;
        let plus_width = ui.px(44.0);
        ui.painter.scene.set_clip(Some(Rect::new(strip.x, strip.y, (strip.width - plus_width).max(1.0), strip.height)));
        let tabs: Vec<(String, bool, bool)> = self
            .tabs
            .iter()
            .map(|tab| match &tab.pane {
                Pane::Terminal(terminal) => (terminal.title(), false, false),
                Pane::Document { path, title } => (title.clone(), true, self.editor.as_ref().is_some_and(|editor| editor.is_modified(path))),
            })
            .collect();
        for (index, (title, is_document, modified)) in tabs.iter().enumerate() {
            // Width from the title alone: 96 pt of chrome, between 120 and 320 pt.
            let fitted = ui.fit_middle(title, ui.px(320.0 - 96.0), 12.0, 400, false);
            let width = (ui.measure(&fitted, 12.0, 400, false) + ui.px(96.0)).clamp(ui.px(120.0), ui.px(320.0));
            let rect = Rect::new(x, strip.y, width, strip.height);
            self.tab_rects.push(rect);
            let selected = index == self.shown;
            let hovered = self.hover == Some(index);
            if !selected && hovered {
                ui.fill(rect, theme::HOVER);
            }
            let icon = if *is_document { if title.to_lowercase().ends_with(".pdf") { "doc.richtext" } else { "doc.text" } } else { "terminal" };
            ui.icon(icon, 12.0, IconWeight::Regular, rect.x + ui.px(11.0 + 7.0), middle, if selected { theme::ACCENT } else { theme::TEXT_SECONDARY });
            ui.text(&fitted, rect.x + ui.px(11.0 + 14.0 + 8.0), middle, 12.0, 400, false, if selected { theme::TEXT_PRIMARY } else { theme::TEXT_SECONDARY });
            let close = Rect::new(rect.right() - ui.px(3.0 + 27.0), middle - ui.px(15.0), ui.px(27.0), ui.px(30.0));
            if *modified {
                let dot = ui.px(6.0);
                ui.painter.scene.fill(close.x - dot, middle - dot * 0.5, dot, dot, theme::ACCENT);
            }
            let strong = selected || hovered;
            ui.icon("xmark", 9.0, IconWeight::Semibold, close.x + close.width * 0.5, middle, faded(theme::TEXT_SECONDARY, if strong { 1.0 } else { 0.55 }));
            self.close_rects.push(close);
            ui.painter.scene.fill(rect.right() - line, rect.y, line, rect.height, theme::SEPARATOR);
            if selected {
                ui.painter.scene.fill(rect.x, rect.bottom() - line, rect.width, line, theme::ACCENT);
            }
            x += width;
        }
        ui.painter.scene.set_clip(None);
        // New local terminal.
        self.plus_rect = Rect::new((x + ui.px(5.0)).min(strip.right() - ui.px(39.0)), middle - ui.px(15.0), ui.px(34.0), ui.px(30.0));
        ui.icon("plus", 12.0, IconWeight::Semibold, self.plus_rect.x + self.plus_rect.width * 0.5, middle, theme::TEXT_SECONDARY);
        ui.painter.scene.fill(strip.x, strip.bottom(), strip.width, line, theme::SEPARATOR);
    }

    /// The bar under a terminal (`TerminalStatusBar`).
    fn draw_status_bar(&mut self, painter: &mut Painter, running: bool) {
        let mut ui = Ui { painter, scale: self.scale };
        let rect = self.status_bar;
        let line = ui.px(1.0).max(1.0);
        ui.painter.scene.fill(rect.x, rect.y, rect.width, line, theme::SEPARATOR);
        let middle = rect.y + line + (rect.height - line) * 0.5;
        let dot = ui.px(5.0);
        let x = rect.x + ui.px(12.0);
        ui.painter.scene.fill(x, middle - dot * 0.5, dot, dot, if running { theme::ACCENT } else { theme::TEXT_SECONDARY });
        ui.text(if running { "Local shell" } else { "Session ended" }, x + dot + ui.px(7.0), middle, 10.0, 500, false, theme::TEXT_SECONDARY);
        // The shell's directory is not reported to the app yet: the project folder stands in for it.
        let home = home_directory().unwrap_or_default();
        let root = self.explorer.root();
        let directory = match root.strip_prefix(&home) {
            Ok(rest) if rest.as_os_str().is_empty() => "~".to_string(),
            Ok(rest) => format!("~/{}", rest.display()),
            Err(_) => root.display().to_string(),
        };
        let right = rect.right() - ui.px(12.0);
        let fitted = ui.fit_middle(&directory, rect.width * 0.5, 10.0, 400, true);
        let width = ui.text_right(&fitted, right, middle, 10.0, 400, true, theme::TEXT_SECONDARY);
        ui.icon("folder", 10.0, IconWeight::Regular, right - width - ui.px(7.0 + 6.0), middle, theme::TEXT_SECONDARY);
    }

    /// The editor's toolbar and footer (`CodeToolbar`, `CodeWorkspaceView`).
    fn draw_editor_chrome(&mut self, painter: &mut Painter, path: &str) {
        let (filetype, diagnostics, mode, modified) = match &self.editor {
            Some(editor) => (editor.filetype(path), editor.diagnostics(path), editor.mode_label(), editor.is_modified(path)),
            None => (String::new(), 0, "Insert", false),
        };
        let points = self.font_points;
        let mut ui = Ui { painter, scale: self.scale };
        let bar = self.toolbar;
        ui.fill(bar, theme::EDITOR_BACKGROUND);
        let middle = bar.y + bar.height * 0.5;
        let mut language: String = if filetype.is_empty() { "Text".into() } else { filetype };
        if let Some(first) = language.get_mut(0..1) {
            first.make_ascii_uppercase();
        }
        ui.text(&language, bar.x + ui.px(12.0), middle, 11.0, 500, false, theme::TEXT_SECONDARY);
        let gap = ui.px(8.0);
        let mut right = bar.right() - ui.px(12.0);
        let save = ui.icon("square.and.arrow.down", 11.0, IconWeight::Medium, right - ui.px(7.0), middle, faded(theme::TEXT_SECONDARY, if modified { 1.0 } else { 0.45 }));
        right -= save.max(ui.px(14.0)) + gap;
        let run = ui.icon("play.fill", 11.0, IconWeight::Medium, right - ui.px(6.0), middle, faded(theme::TEXT_SECONDARY, 0.45));
        right -= run.max(ui.px(12.0)) + gap;
        right -= ui.text_right(&format!("{} pt", points as i32), right, middle, 11.0, 500, false, theme::TEXT_SECONDARY) + gap;
        let code = ui.text_right("Code", right, middle, 11.0, 500, false, theme::TEXT_SECONDARY);
        let braces = ui.icon("curlybraces", 11.0, IconWeight::Medium, right - code - ui.px(10.0), middle, theme::TEXT_SECONDARY);
        right -= code + braces + ui.px(6.0) + gap;
        let count = ui.text_right(&diagnostics.to_string(), right, middle, 11.0, 500, false, theme::TEXT_SECONDARY);
        ui.icon("exclamationmark.circle", 11.0, IconWeight::Medium, right - count - ui.px(10.0), middle, theme::TEXT_SECONDARY);
        let footer = self.editor_footer;
        ui.fill(footer, theme::EDITOR_BACKGROUND);
        let middle = footer.y + footer.height * 0.5;
        ui.text(&format!("Neovim \u{b7} {mode}"), footer.x + ui.px(12.0), middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        let hints = if cfg!(target_os = "macos") { "Esc  Normal mode   \u{b7}   i  Insert   \u{b7}   \u{2318}S  Save" } else { "Esc  Normal mode   \u{b7}   i  Insert   \u{b7}   Ctrl+Shift+S  Save" };
        ui.text_right(hints, footer.right() - ui.px(12.0), middle, 10.0, 400, false, theme::TEXT_SECONDARY);
    }

    /// The window's footer (`WorkspaceFooter`).
    fn draw_footer(&mut self, painter: &mut Painter) {
        let document = self.tabs.get(self.shown).and_then(|tab| match &tab.pane {
            Pane::Document { title, .. } => Some(title.clone()),
            Pane::Terminal(_) => None,
        });
        let count = self.tabs.len();
        let mut ui = Ui { painter, scale: self.scale };
        let rect = self.footer;
        let line = ui.px(1.0).max(1.0);
        ui.painter.scene.fill(rect.x, rect.y - line, rect.width, line, theme::SEPARATOR);
        ui.fill(rect, theme::SIDEBAR_BACKGROUND);
        let middle = rect.y + rect.height * 0.5;
        let x = rect.x + ui.px(14.0);
        let icon = ui.icon(if document.is_some() { "doc.text" } else { "terminal" }, 10.0, IconWeight::Medium, x + ui.px(6.0), middle, theme::TEXT_SECONDARY);
        ui.text(document.as_deref().unwrap_or("NeoLink"), x + icon.max(ui.px(12.0)) + ui.px(7.0), middle, 10.0, 500, false, theme::TEXT_SECONDARY);
        let mut right = rect.right() - ui.px(14.0);
        let hint = if cfg!(target_os = "macos") { "\u{2318}T  New tab" } else { "Ctrl+Shift+T  New tab" };
        right -= ui.text_right(hint, right, middle, 10.0, 500, false, theme::TEXT_SECONDARY) + ui.px(7.0);
        ui.painter.scene.fill(right - line, middle - ui.px(5.0), line, ui.px(10.0), theme::SEPARATOR);
        right -= line + ui.px(7.0);
        ui.text_right(&format!("{count} {}", if count == 1 { "tab" } else { "tabs" }), right, middle, 10.0, 500, false, theme::TEXT_SECONDARY);
    }
}

/// A hash of the values a frame is drawn from.
struct Signature(u64);

impl Signature {
    fn new() -> Signature {
        Signature(0xcbf29ce484222325)
    }

    fn add(&mut self, value: u64) -> &mut Signature {
        self.0 = (self.0.rotate_left(5) ^ value).wrapping_mul(0x517cc1b727220a95);
        self
    }

    fn text(&mut self, text: &str) -> &mut Signature {
        for byte in text.bytes() {
            self.add(byte as u64);
        }
        self.add(text.len() as u64)
    }

    fn finish(&self) -> u64 {
        self.0
    }
}

/// The folder the explorer starts in: `NEOLINK_PROJECT`, else the directory the app was started from
/// (a graphical launch starts in `/`, where the home folder is the better guess).
fn project_directory() -> std::path::PathBuf {
    if let Some(path) = std::env::var_os("NEOLINK_PROJECT").map(std::path::PathBuf::from) {
        return neolink_core::paths::canonical(&path);
    }
    match std::env::current_dir() {
        Ok(directory) if directory.parent().is_some() => directory,
        _ => home_directory().unwrap_or_else(|| std::path::PathBuf::from("/")),
    }
}

fn home_directory() -> Option<std::path::PathBuf> {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(std::path::PathBuf::from)
}

impl Content for Workspace {
    fn build(&mut self, painter: &mut Painter, frame: FrameContext) -> Built {
        let text = &mut *painter.text;
        self.period = frame.period;
        self.scale = frame.scale;
        if self.applied_font != (self.font_points, frame.scale) {
            text.set_font_size(self.font_points, frame.scale);
            painter.rows.clear();
            self.applied_font = (self.font_points, frame.scale);
        }
        let cell_changed = self.cell != text.cell;
        self.cell = text.cell;
        if self.layout(frame.size) || cell_changed {
            let (grid, cell) = (self.grid, self.cell);
            for tab in &mut self.tabs {
                if let Pane::Terminal(terminal) = &mut tab.pane {
                    terminal.resize(grid.0, grid.1, cell);
                }
            }
        }
        if let Some(editor) = &mut self.editor {
            editor.resize(self.editor_grid.0, self.editor_grid.1);
        }
        // Programs that ended take their tabs with them.
        let before = self.tabs.len();
        let active_id = self.tabs.get(self.active).map(|tab| tab.id);
        let shown_id = self.tabs.get(self.shown).map(|tab| tab.id);
        self.tabs.retain(|tab| !tab.terminal().is_some_and(Terminal::has_exited));
        if self.tabs.len() != before {
            self.active = active_id.and_then(|id| self.tabs.iter().position(|tab| tab.id == id)).unwrap_or(self.active.min(self.tabs.len().saturating_sub(1)));
            self.shown = shown_id.and_then(|id| self.tabs.iter().position(|tab| tab.id == id)).unwrap_or(self.active);
            self.reselect();
            if self.tabs.is_empty() {
                if let Some(callback) = &self.on_empty {
                    callback();
                }
            }
        }
        // Which pane to show: the active one, unless it is a document Neovim has not confirmed yet.
        let ready = match self.tabs.get(self.active).map(|tab| &tab.pane) {
            Some(Pane::Document { path, .. }) => self.editor.as_ref().is_some_and(|editor| editor.can_show(path)),
            _ => true,
        };
        if ready {
            self.shown = self.active;
            self.shown_selection = self.selection;
        }
        self.shown = self.shown.min(self.tabs.len().saturating_sub(1));
        if let Some(error) = self.editor.as_ref().and_then(Editor::last_error) {
            self.notice = Some(error);
        }
        if self.refresh_explorer_soon {
            let replies = self.editor.as_ref().map(Editor::replies).unwrap_or(0);
            if replies != self.seen_replies {
                self.seen_replies = replies;
                self.refresh_explorer_soon = false;
                self.explorer.refresh();
            }
        } else {
            self.seen_replies = self.editor.as_ref().map(Editor::replies).unwrap_or(0);
        }
        self.draw_header(painter);
        self.draw_strip(painter);
        let (pane, focused, period) = (self.pane, self.focused, frame.period);
        let editor_pane = self.editor_pane;
        let mut chrome: Option<Option<String>> = None;
        let mut output = 0;
        let next = match self.tabs.get_mut(self.shown).map(|tab| &mut tab.pane) {
            Some(Pane::Terminal(terminal)) => {
                let next = terminal.build(painter, pane, focused, frame.display, period);
                output = terminal.output_generation();
                chrome = Some(None);
                next
            }
            Some(Pane::Document { path, .. }) => {
                if let Some(editor) = &mut self.editor {
                    editor.build(painter, editor_pane, focused, path);
                    output = editor.drawn_generation();
                }
                chrome = Some(Some(path.clone()));
                Next::Idle
            }
            None => Next::Idle,
        };
        match chrome {
            Some(None) => self.draw_status_bar(painter, true),
            Some(Some(path)) => self.draw_editor_chrome(painter, &path),
            None => {}
        }
        self.draw_notice(painter);
        self.draw_footer(painter);
        let mut next = next;
        if self.explorer.visible {
            let active_file = self.tabs.get(self.shown).and_then(Tab::document).map(str::to_string);
            let sidebar = self.sidebar;
            let explorer_next = self.explorer.build(painter, sidebar, frame.scale, active_file.as_deref(), frame.display, period);
            next = match (next, explorer_next) {
                (Next::Soon, _) | (_, Next::Soon) => Next::Soon,
                (Next::At(a), Next::At(b)) => Next::At(a.min(b)),
                (Next::At(a), Next::Idle) | (Next::Idle, Next::At(a)) => Next::At(a),
                (Next::Idle, Next::Idle) => Next::Idle,
            };
        }
        let (scroll_lines, input_lines) = self.scroll_lines();
        self.marks = FrameMarks { scroll_lines, input_lines, output, selection: self.shown_selection, instances: 0 };
        // Everything that decides a pixel of this frame. Equal to the last one: nothing to present.
        let mut signature = Signature::new();
        signature.add(frame.size.0 as u64).add(frame.size.1 as u64).add(self.cell.width.to_bits() as u64).add(self.cell.height.to_bits() as u64);
        signature.add(self.shown as u64).add(self.shown_selection).add(self.focused as u64).add(self.hover.map_or(u64::MAX, |index| index as u64));
        signature.add(self.hover_close.map_or(u64::MAX, |index| index as u64)).add(self.font_points.to_bits() as u64);
        if let Some(editor) = &self.editor {
            signature.text(editor.mode_label());
        }
        signature.add(output).text(self.notice.as_deref().unwrap_or(""));
        signature.add(self.explorer.signature());
        for (index, tab) in self.tabs.iter().enumerate() {
            signature.add(tab.id);
            match &tab.pane {
                Pane::Terminal(terminal) => {
                    signature.text(&terminal.title());
                    if index == self.shown {
                        signature.add(terminal.scroll().to_bits());
                    }
                }
                Pane::Document { path, .. } => {
                    signature.text(path).add(self.editor.as_ref().is_some_and(|editor| editor.is_modified(path)) as u64);
                }
            }
        }
        let signature = signature.finish();
        let changed = signature != self.signature;
        self.signature = signature;
        Built { changed, next }
    }

    fn marks(&self) -> FrameMarks {
        self.marks
    }

    fn as_any(&mut self) -> &mut dyn std::any::Any {
        self
    }
}
