//! The window's content: a strip of tabs over the active pane. Panes stay alive when they are not shown;
//! switching is drawing a different pane into the same surface.

use crate::editor::Editor;
use crate::frame::{Built, Content, FrameContext, FrameMarks, Next, Painter, Shared};
use crate::render::{Rect, Scene};
use crate::term::{ScrollPhase, Terminal};
use crate::text::{CellMetrics, TextSystem};
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
    notice: Option<String>,
    pointer: (f32, f32),
    next_id: u64,
    pub cell: CellMetrics,
    pub font_points: f32,
    applied_font: (f32, f32),
    scale: f32,
    period: f64,
    /// The pane's grid, from the last layout.
    grid: (usize, usize),
    pane: Rect,
    strip: Rect,
    tab_rects: Vec<Rect>,
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
            notice: None,
            pointer: (-1.0, -1.0),
            next_id: 1,
            cell,
            font_points,
            applied_font: (font_points, scale),
            scale,
            period,
            grid: (80, 24),
            pane: Rect::default(),
            strip: Rect::default(),
            tab_rects: Vec::new(),
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

    fn layout(&mut self, size: (u32, u32)) -> bool {
        let scale = self.scale;
        let strip_height = (30.0 * scale).round();
        let padding_x = (6.0 * scale).round();
        let padding_top = (4.0 * scale).round();
        self.strip = Rect::new(0.0, 0.0, size.0 as f32, strip_height);
        self.pane = Rect::new(padding_x, strip_height + padding_top, (size.0 as f32 - 2.0 * padding_x).max(1.0), (size.1 as f32 - strip_height - padding_top).max(1.0));
        let grid = (((self.pane.width / self.cell.width).floor() as usize).max(2), ((self.pane.height / self.cell.height).floor() as usize).max(1));
        let changed = grid != self.grid;
        self.grid = grid;
        // The pane is a whole number of cells tall, so a scrolled row is clipped at a row boundary.
        self.pane.height = grid.1 as f32 * self.cell.height;
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
        let directory = std::env::var_os("NEOLINK_START_DIRECTORY").map(std::path::PathBuf::from).or_else(home_directory);
        let id = self.next_id;
        self.next_id += 1;
        let terminal = Terminal::spawn(shared, self.grid.0, self.grid.1, self.cell, directory, id)?;
        self.tabs.push(Tab { id, pane: Pane::Terminal(terminal) });
        self.select(self.tabs.len() - 1);
        Ok(())
    }

    /// Opens `path` in the editor, in its existing tab if it has one.
    pub fn open_document(&mut self, path: &std::path::Path) {
        let path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
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
        match Editor::start(&shared, self.grid.0, self.grid.1) {
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

    pub fn close_tab(&mut self, index: usize) {
        if index >= self.tabs.len() {
            return;
        }
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
        }
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

    fn pointer_cell(&self) -> (usize, usize) {
        let row = ((self.pointer.1 - self.pane.y) / self.cell.height).floor().clamp(0.0, self.grid.1.saturating_sub(1) as f32) as usize;
        let column = ((self.pointer.0 - self.pane.x) / self.cell.width).floor().clamp(0.0, self.grid.0.saturating_sub(1) as f32) as usize;
        (row, column)
    }

    /// A scroll event in device pixels over the pane.
    pub fn scroll(&mut self, time: f64, _delta_x: f64, delta_y: f64, phase: ScrollPhase) {
        let (cell, period) = (self.cell, self.period);
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
        if let Some(index) = self.tab_rects.iter().position(|rect| rect.contains(x, y)) {
            self.select(index);
            return true;
        }
        if self.pane.contains(x, y) && self.active_is_document() && self.shown == self.active {
            let (row, column) = self.pointer_cell();
            if let Some(editor) = &self.editor {
                editor.mouse("press", row, column);
            }
            return true;
        }
        false
    }

    pub fn release(&mut self, x: f32, y: f32) {
        if self.pane.contains(x, y) && self.active_is_document() && self.shown == self.active {
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
        let changed = hover != self.hover;
        self.hover = hover;
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

    /// A message for the user (an editor error) along the bottom of the pane. Any key dismisses it.
    fn draw_notice(&mut self, painter: &mut Painter) {
        let Some(notice) = self.notice.clone() else { return };
        let scale = self.scale;
        let height = (26.0 * scale).round();
        let rect = Rect::new(0.0, self.pane.bottom() - height, self.strip.width, height);
        painter.scene.fill_rect(rect, theme::rgb(0x382626));
        let font_pixels = (12.0 * scale).round();
        let line = painter.text.line(painter.queue, &notice, font_pixels, false, false);
        let baseline = (rect.y + rect.height * 0.5 + font_pixels * 0.36).round();
        painter.scene.set_clip(Some(rect));
        for glyph in &line.glyphs {
            painter.scene.glyph(glyph.sprite, (10.0 * scale).round() + glyph.x, baseline + glyph.y, theme::rgb(0xE1B4B4));
        }
        painter.scene.set_clip(None);
    }

    pub fn dismiss_notice(&mut self) -> bool {
        self.notice.take().is_some()
    }

    fn draw_strip(&mut self, scene: &mut Scene, text: &mut TextSystem, queue: &wgpu::Queue) {
        let scale = self.scale;
        scene.fill_rect(self.strip, theme::SIDEBAR_BACKGROUND);
        self.tab_rects.clear();
        let count = self.tabs.len().max(1) as f32;
        let width = ((220.0 * scale).min(self.strip.width / count)).floor();
        let font_pixels = (12.0 * scale).round();
        for (index, tab) in self.tabs.iter().enumerate() {
            let rect = Rect::new(index as f32 * width, 0.0, width, self.strip.height);
            self.tab_rects.push(rect);
            let active = index == self.shown;
            if active {
                scene.fill_rect(rect, theme::EDITOR_BACKGROUND);
            } else if self.hover == Some(index) {
                scene.fill_rect(rect, theme::HOVER);
            }
            scene.fill(rect.right() - 1.0, 0.0, 1.0, rect.height, theme::SEPARATOR);
            let title = match &tab.pane {
                Pane::Terminal(terminal) => terminal.title(),
                Pane::Document { path, title } => {
                    if self.editor.as_ref().is_some_and(|editor| editor.is_modified(path)) {
                        format!("{title} \u{2022}")
                    } else {
                        title.clone()
                    }
                }
            };
            let line = text.line(queue, &title, font_pixels, false, false);
            let inset = (12.0 * scale).round();
            scene.set_clip(Some(Rect::new(rect.x + inset, rect.y, rect.width - 2.0 * inset, rect.height)));
            let baseline = (rect.height * 0.5 + font_pixels * 0.36).round();
            let color = if active { theme::TEXT_PRIMARY } else { theme::TEXT_SECONDARY };
            for glyph in &line.glyphs {
                scene.glyph(glyph.sprite, rect.x + inset + glyph.x, baseline + glyph.y, color);
            }
            scene.set_clip(None);
        }
        scene.fill(0.0, self.strip.height - 1.0, self.strip.width, 1.0, theme::SEPARATOR);
        if let Some(rect) = self.tab_rects.get(self.shown).copied() {
            // The active tab is open toward its pane.
            scene.fill(rect.x, rect.bottom() - 1.0, rect.width - 1.0, 1.0, theme::EDITOR_BACKGROUND);
        }
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
            editor.resize(self.grid.0, self.grid.1);
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
            Some(Pane::Document { path, .. }) => self.editor.as_ref().is_some_and(|editor| editor.shows(path)),
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
        self.draw_strip(painter.scene, painter.text, painter.queue);
        let (pane, focused, period) = (self.pane, self.focused, frame.period);
        let live = self.shown == self.active;
        let mut output = 0;
        let next = match self.tabs.get_mut(self.shown).map(|tab| &mut tab.pane) {
            Some(Pane::Terminal(terminal)) => {
                let next = terminal.build(painter, pane, focused, frame.display, period);
                output = terminal.output_generation();
                next
            }
            Some(Pane::Document { .. }) => {
                if let Some(editor) = &mut self.editor {
                    editor.build(painter, pane, focused, live);
                    output = editor.drawn_generation();
                }
                Next::Idle
            }
            None => Next::Idle,
        };
        self.draw_notice(painter);
        let (scroll_lines, input_lines) = self.scroll_lines();
        self.marks = FrameMarks { scroll_lines, input_lines, output, selection: self.shown_selection, instances: 0 };
        // Everything that decides a pixel of this frame. Equal to the last one: nothing to present.
        let mut signature = Signature::new();
        signature.add(frame.size.0 as u64).add(frame.size.1 as u64).add(self.cell.width.to_bits() as u64).add(self.cell.height.to_bits() as u64);
        signature.add(self.shown as u64).add(self.shown_selection).add(self.focused as u64).add(self.hover.map_or(u64::MAX, |index| index as u64));
        signature.add(output).text(self.notice.as_deref().unwrap_or(""));
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
