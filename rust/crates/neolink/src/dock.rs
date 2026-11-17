//! A terminal docked to the code: under it, as in an IDE, or beside it as a split. The Swift app has no
//! such panel; it was asked for on top of parity (PLAN.md, section 6c). It follows the app's look: a
//! 28-point bar like the terminal status bar, thin separators, the same terminal renderer.

use std::path::Path;
use std::sync::Arc;

use crate::chrome::Ui;
use crate::frame::{Next, Painter, Shared};
use crate::icons::IconWeight;
use crate::render::Rect;
use crate::term::Terminal;
use crate::text::CellMetrics;
use crate::theme;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Side {
    Bottom,
    Right,
}

pub enum Pressed {
    Nothing,
    Hide,
    /// The panel moved to the other side.
    Moved,
    NewShell,
}

pub struct Dock {
    pub visible: bool,
    pub focused: bool,
    pub side: Side,
    /// Height (bottom) and width (right) in points.
    pub height_points: f32,
    pub width_points: f32,
    terminals: Vec<Terminal>,
    selected: usize,
    next_id: u64,
    rect: Rect,
    terminal_rect: Rect,
    grid: (usize, usize),
    buttons: Vec<(Rect, &'static str)>,
    tabs: Vec<Rect>,
}

impl Dock {
    pub fn new() -> Dock {
        Dock { visible: false, focused: false, side: Side::Bottom, height_points: 220.0, width_points: 420.0, terminals: Vec::new(), selected: 0, next_id: 1 << 41, rect: Rect::default(), terminal_rect: Rect::default(), grid: (80, 12), buttons: Vec::new(), tabs: Vec::new() }
    }

    pub fn rect(&self) -> Rect {
        self.rect
    }

    pub fn contains(&self, x: f32, y: f32) -> bool {
        self.visible && self.rect.contains(x, y)
    }

    /// The edge that is dragged to resize the panel: its top (bottom side) or left (right side).
    pub fn over_edge(&self, x: f32, y: f32, reach: f32) -> bool {
        if !self.visible {
            return false;
        }
        match self.side {
            Side::Bottom => (y - self.rect.y).abs() <= reach && x >= self.rect.x && x < self.rect.right(),
            Side::Right => (x - self.rect.x).abs() <= reach && y >= self.rect.y && y < self.rect.bottom(),
        }
    }

    /// Whether `(x, y)` is over the terminal's text.
    pub fn over_text(&self, x: f32, y: f32) -> bool {
        self.visible && self.terminal_rect.contains(x, y)
    }

    pub fn terminal(&mut self) -> Option<&mut Terminal> {
        self.terminals.get_mut(self.selected)
    }

    pub fn has_terminal(&self) -> bool {
        !self.terminals.is_empty()
    }

    /// Starts another shell in the panel.
    pub fn open_shell(&mut self, shared: &Arc<Shared>, directory: &Path, cell: CellMetrics) -> std::io::Result<()> {
        let id = self.next_id;
        self.next_id += 1;
        let terminal = Terminal::spawn(shared, self.grid.0.max(20), self.grid.1.max(4), cell, Some(directory.to_path_buf()), id)?;
        self.terminals.push(terminal);
        self.selected = self.terminals.len() - 1;
        Ok(())
    }

    /// Shows the panel with the keyboard in it, hides it if it already has the keyboard.
    /// Returns `true` if a shell has to be started.
    pub fn toggle(&mut self) -> bool {
        if self.visible && self.focused {
            self.visible = false;
            self.focused = false;
            return false;
        }
        self.visible = true;
        self.focused = true;
        self.terminals.is_empty()
    }

    pub fn click(&mut self, x: f32, y: f32) -> Pressed {
        if let Some((_, what)) = self.buttons.iter().find(|(rect, _)| rect.contains(x, y)).copied() {
            return match what {
                "hide" => {
                    self.visible = false;
                    self.focused = false;
                    Pressed::Hide
                }
                "side" => {
                    self.side = if self.side == Side::Bottom { Side::Right } else { Side::Bottom };
                    Pressed::Moved
                }
                "new" => Pressed::NewShell,
                "close" => {
                    if self.selected < self.terminals.len() {
                        self.terminals.remove(self.selected).shutdown();
                        self.selected = self.selected.min(self.terminals.len().saturating_sub(1));
                    }
                    if self.terminals.is_empty() {
                        self.visible = false;
                        self.focused = false;
                    }
                    Pressed::Hide
                }
                _ => Pressed::Nothing,
            };
        }
        if let Some(index) = self.tabs.iter().position(|rect| rect.contains(x, y)) {
            self.selected = index;
        }
        self.focused = true;
        Pressed::Nothing
    }

    pub fn control_rect(&self, name: &str) -> Option<Rect> {
        self.buttons.iter().find(|(_, what)| *what == name).map(|(rect, _)| *rect)
    }

    pub fn signature(&self) -> u64 {
        let mut value = (self.visible as u64) | (self.focused as u64) << 1 | ((self.side == Side::Right) as u64) << 2 | (self.selected as u64) << 8 | (self.terminals.len() as u64) << 16 | (self.height_points.to_bits() as u64) << 32 ^ (self.width_points.to_bits() as u64).rotate_left(7);
        if let Some(terminal) = self.terminals.get(self.selected) {
            value ^= terminal.output_generation().wrapping_mul(0x9E3779B97F4A7C15) ^ terminal.scroll().to_bits() ^ terminal.look().rotate_left(21);
        }
        value
    }

    pub fn build(&mut self, painter: &mut Painter, rect: Rect, scale: f32, cell: CellMetrics, window_focused: bool, display: f64, period: f64) -> Next {
        self.rect = rect;
        self.buttons.clear();
        self.tabs.clear();
        let before = self.terminals.len();
        self.terminals.retain(|terminal| !terminal.has_exited());
        if self.terminals.len() != before {
            self.selected = self.selected.min(self.terminals.len().saturating_sub(1));
            if self.terminals.is_empty() {
                // The last shell ended (`exit`): the panel goes with it.
                self.visible = false;
                self.focused = false;
                return Next::Soon;
            }
        }
        let mut ui = Ui { painter, scale };
        let line = ui.px(1.0).max(1.0);
        ui.fill(rect, theme::EDITOR_BACKGROUND);
        match self.side {
            Side::Bottom => ui.painter.scene.fill(rect.x, rect.y - line, rect.width, line, theme::SEPARATOR),
            Side::Right => ui.painter.scene.fill(rect.x - line, rect.y, line, rect.height, theme::SEPARATOR),
        }
        // Bar: one entry per shell, then new shell, move, hide.
        let bar = Rect::new(rect.x, rect.y, rect.width, ui.px(28.0));
        let middle = bar.y + bar.height * 0.5;
        let button = ui.px(24.0);
        let mut right = bar.right() - ui.px(8.0);
        for (symbol, what) in [("xmark", "hide"), (if self.side == Side::Bottom { "rectangle.split.2x1" } else { "rectangle.split.1x2" }, "side"), ("plus", "new")] {
            let area = Rect::new(right - button, middle - button * 0.5, button, button);
            ui.icon(symbol, 11.0, IconWeight::Medium, area.x + button * 0.5, middle, theme::TEXT_SECONDARY);
            self.buttons.push((area, what));
            right -= button + ui.px(4.0);
        }
        let mut x = bar.x + ui.px(12.0);
        ui.painter.scene.set_clip(Some(Rect::new(bar.x, bar.y, (right - bar.x).max(1.0), bar.height)));
        for index in 0..self.terminals.len() {
            let title = self.terminals[index].title();
            let label = if title.is_empty() { "shell".to_string() } else { title };
            let selected = index == self.selected;
            let icon = ui.icon("terminal", 10.0, IconWeight::Regular, x + ui.px(7.0), middle, if selected { theme::TEXT_PRIMARY } else { theme::TEXT_SECONDARY }).max(ui.px(14.0));
            let label = ui.fit_middle(&label, ui.px(140.0), 11.0, 500, false);
            let width = ui.text(&label, x + icon + ui.px(5.0), middle, 11.0, if selected { 500 } else { 400 }, false, if selected { theme::TEXT_PRIMARY } else { theme::TEXT_SECONDARY });
            let tab = Rect::new(x - ui.px(6.0), bar.y, icon + width + ui.px(17.0), bar.height);
            if selected && self.terminals.len() > 1 {
                ui.painter.scene.fill(tab.x, bar.bottom() - ui.px(2.0), tab.width, ui.px(2.0), theme::ACCENT);
            }
            self.tabs.push(tab);
            x += icon + width + ui.px(22.0);
        }
        ui.painter.scene.set_clip(None);
        if self.terminals.len() > 1 {
            let area = Rect::new(right - button, middle - button * 0.5, button, button);
            ui.icon("trash", 10.0, IconWeight::Regular, area.x + button * 0.5, middle, theme::TEXT_SECONDARY);
            self.buttons.push((area, "close"));
        }
        ui.painter.scene.fill(bar.x, bar.bottom(), bar.width, line, theme::SEPARATOR);
        // The terminal, a whole number of cells.
        let area = Rect::new(rect.x + ui.px(8.0), bar.bottom() + line + ui.px(6.0), rect.width - ui.px(8.0), rect.bottom() - bar.bottom() - line - ui.px(6.0));
        let grid = (((area.width / cell.width).floor() as usize).max(2), ((area.height / cell.height).floor() as usize).max(1));
        self.terminal_rect = Rect::new(area.x, area.y, area.width, grid.1 as f32 * cell.height);
        if grid != self.grid {
            self.grid = grid;
            for terminal in &mut self.terminals {
                terminal.resize(grid.0, grid.1, cell);
            }
        }
        let (terminal_rect, focused) = (self.terminal_rect, self.focused && window_focused);
        match self.terminals.get_mut(self.selected) {
            Some(terminal) => terminal.build(painter, terminal_rect, focused, display, period),
            None => Next::Idle,
        }
    }
}
