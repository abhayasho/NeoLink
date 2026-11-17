//! The window's content: a strip of tabs over the active pane. Panes stay alive when they are not shown;
//! switching is drawing a different pane into the same surface.

use crate::frame::{Built, Content, FrameContext, FrameMarks, Next, Painter, Shared};
use crate::render::{Rect, Scene};
use crate::term::{ScrollPhase, Terminal};
use crate::text::{CellMetrics, TextSystem};
use crate::theme;
use std::sync::Arc;

pub const MIN_FONT_POINTS: f32 = 9.0;
pub const MAX_FONT_POINTS: f32 = 32.0;

struct Tab {
    id: u64,
    terminal: Terminal,
}

pub struct Workspace {
    tabs: Vec<Tab>,
    active: usize,
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
            tabs: Vec::new(),
            active: 0,
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

    pub fn active(&mut self) -> Option<&mut Terminal> {
        self.tabs.get_mut(self.active).map(|tab| &mut tab.terminal)
    }

    pub fn new_tab(&mut self, shared: &Arc<Shared>) -> std::io::Result<()> {
        let directory = std::env::var_os("NEOLINK_START_DIRECTORY").map(std::path::PathBuf::from).or_else(home_directory);
        let id = self.next_id;
        self.next_id += 1;
        let terminal = Terminal::spawn(shared, self.grid.0, self.grid.1, self.cell, directory, id)?;
        self.tabs.push(Tab { id, terminal });
        self.active = self.tabs.len() - 1;
        self.selection += 1;
        Ok(())
    }

    pub fn close_tab(&mut self, index: usize) {
        if index >= self.tabs.len() {
            return;
        }
        self.tabs.remove(index);
        if self.active > index || self.active >= self.tabs.len() {
            self.active = self.active.saturating_sub(1);
        }
        self.selection += 1;
    }

    pub fn select(&mut self, index: usize) {
        if index < self.tabs.len() && index != self.active {
            self.active = index;
            self.selection += 1;
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

    /// Bytes typed into the active pane. Returns `true` if the view changed (it was scrolled back).
    pub fn write(&mut self, bytes: Vec<u8>) -> bool {
        match self.active() {
            Some(terminal) => terminal.write(bytes),
            None => false,
        }
    }

    pub fn paste(&mut self, text: &str) {
        if let Some(terminal) = self.active() {
            terminal.paste(text);
        }
    }

    /// A scroll event in device pixels over the pane.
    pub fn scroll(&mut self, time: f64, _delta_x: f64, delta_y: f64, phase: ScrollPhase) {
        let (cell, period) = (self.cell, self.period);
        if let Some(terminal) = self.active() {
            terminal.scroll_input(time, delta_y, phase, cell, period);
        }
    }

    pub fn scroll_pages(&mut self, pages: f64) {
        let distance = pages * self.grid.1 as f64 * self.cell.height as f64;
        if let Some(terminal) = self.active() {
            terminal.scroll_by(distance);
        }
    }

    /// A click at `(x, y)` device pixels. Returns `true` if it changed anything.
    pub fn click(&mut self, x: f32, y: f32) -> bool {
        if let Some(index) = self.tab_rects.iter().position(|rect| rect.contains(x, y)) {
            self.select(index);
            return true;
        }
        false
    }

    /// The pointer moved to `(x, y)`. Returns `true` if a hover highlight changed.
    pub fn pointer(&mut self, x: f32, y: f32) -> bool {
        let hover = self.tab_rects.iter().position(|rect| rect.contains(x, y));
        let changed = hover != self.hover;
        self.hover = hover;
        changed
    }

    /// The active pane's scroll position and received input, in lines.
    pub fn scroll_lines(&self) -> (f64, f64) {
        match self.tabs.get(self.active) {
            Some(tab) => (tab.terminal.scroll() / self.cell.height as f64, tab.terminal.received / self.cell.height as f64),
            None => (0.0, 0.0),
        }
    }

    pub fn output_generation(&self) -> u64 {
        self.tabs.get(self.active).map(|tab| tab.terminal.output_generation()).unwrap_or(0)
    }

    pub fn smoothing_report(&self) -> (usize, usize, f64) {
        self.tabs.get(self.active).map(|tab| tab.terminal.smoothing_report()).unwrap_or((0, 0, 0.0))
    }

    pub fn scale(&self) -> f32 {
        self.scale
    }

    /// Increases every time a different pane becomes the one shown.
    pub fn selection_generation(&self) -> u64 {
        self.selection
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
            let active = index == self.active;
            if active {
                scene.fill_rect(rect, theme::EDITOR_BACKGROUND);
            } else if self.hover == Some(index) {
                scene.fill_rect(rect, theme::HOVER);
            }
            scene.fill(rect.right() - 1.0, 0.0, 1.0, rect.height, theme::SEPARATOR);
            let title = tab.terminal.title();
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
        if let Some(rect) = self.tab_rects.get(self.active).copied() {
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
                tab.terminal.resize(grid.0, grid.1, cell);
            }
        }
        // Programs that ended take their tabs with them.
        let before = self.tabs.len();
        let active_id = self.tabs.get(self.active).map(|tab| tab.id);
        self.tabs.retain(|tab| !tab.terminal.has_exited());
        if self.tabs.len() != before {
            self.active = active_id.and_then(|id| self.tabs.iter().position(|tab| tab.id == id)).unwrap_or(self.active.min(self.tabs.len().saturating_sub(1)));
            self.selection += 1;
            if self.tabs.is_empty() {
                if let Some(callback) = &self.on_empty {
                    callback();
                }
            }
        }
        self.draw_strip(painter.scene, painter.text, painter.queue);
        let (pane, focused, period) = (self.pane, self.focused, frame.period);
        let next = match self.tabs.get_mut(self.active) {
            Some(tab) => tab.terminal.build(painter, pane, focused, frame.display, period),
            None => Next::Idle,
        };
        let (scroll_lines, input_lines) = self.scroll_lines();
        self.marks = FrameMarks { scroll_lines, input_lines, output: self.output_generation(), selection: self.selection, instances: 0 };
        // Everything that decides a pixel of this frame. Equal to the last one: nothing to present.
        let mut signature = Signature::new();
        signature.add(frame.size.0 as u64).add(frame.size.1 as u64).add(self.cell.width.to_bits() as u64).add(self.cell.height.to_bits() as u64);
        signature.add(self.active as u64).add(self.selection).add(self.focused as u64).add(self.hover.map_or(u64::MAX, |index| index as u64));
        for (index, tab) in self.tabs.iter().enumerate() {
            signature.add(tab.id).text(&tab.terminal.title());
            if index == self.active {
                signature.add(tab.terminal.output_generation()).add(tab.terminal.scroll().to_bits());
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
