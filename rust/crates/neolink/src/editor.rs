//! The editor pane: one Neovim shared by every document tab, drawn from its `ext_linegrid` screen.
//!
//! The pane never shows a buffer Neovim has not confirmed: while a selection is unconfirmed the screen
//! as it was when the selection was requested stays up (see `neolink-nvim`'s client for why input needs
//! no such care here: the client holds it).

use crate::frame::{Next, Painter, Shared};
use crate::render::{Instance, Rect};
use crate::text::CellMetrics;
use crate::theme::{self, Rgba};
use neolink_nvim::client::{Client, FileSignature};
use neolink_nvim::grid::{Cell, CursorShape, Screen, Text, Underline};
use std::path::PathBuf;
use std::sync::Arc;

pub struct Editor {
    client: Client,
    grid: (usize, usize),
    next_token: u64,
    /// The newest selection asked of Neovim: `(token, path)`.
    requested: Option<(u64, String)>,
    /// What was on screen when that selection was requested.
    frozen: Option<Screen>,
    /// The requested buffer's screen as Neovim left it, when every rule says it is still what Neovim
    /// will draw: shown at once, replaced by Neovim's own screen when the selection is confirmed.
    speculative: Option<Screen>,
    /// Selections answered from a remembered screen, and selections that had to wait (benchmark).
    pub speculated: u64,
    pub waited: u64,
    /// Pixels of wheel input not yet turned into whole lines (line scrolling).
    wheel: f64,
    /// Pixel scrolling: the view's top in pixels from the top of the buffer, which buffer that is for,
    /// the top line last asked of Neovim, and when the wheel last moved.
    smooth: bool,
    /// Wheel input is applied at the display's cadence, as the terminal's and the explorer's.
    smoother: neolink_core::scroll::ScrollSmoother,
    position: f64,
    position_path: String,
    commanded_top: u64,
    last_wheel: f64,
    /// The shift the last frame drew the text with, and the rows it showed.
    drawn_shift: f32,
    /// Wheel input received, in device pixels (for the benchmark).
    pub received: f64,
    /// The view's top as the last frame drew it, in device pixels from the top of the buffer.
    pub drawn_position: f64,
    scratch: Vec<Instance>,
    /// Generation of the screen the last frame drew.
    drawn_generation: u64,
}

/// Rows Neovim draws beyond what the pane shows, for pixel scrolling.
const EXTRA_ROWS: usize = 4;
/// Lines Neovim's window starts above the visible text: half of the extra rows, so the text can run
/// ahead of Neovim's answer by up to two lines in either direction.
const LEAD: u64 = (EXTRA_ROWS / 2) as u64;

/// Scrolls the window so `...` is its top line, as Ctrl-E and Ctrl-Y do: the cursor comes along when it
/// would leave the window (setting the top line alone is undone by Neovim to keep the cursor in view).
const SCROLL_TO: &str = r#"
local lines = ... - vim.fn.line('w0')
if lines > 0 then vim.cmd('normal! ' .. lines .. '') elseif lines < 0 then vim.cmd('normal! ' .. -lines .. '') end
"#;

fn rmpv_string(text: &str) -> neolink_nvim::rmpv::Value {
    neolink_nvim::rmpv::Value::from(text)
}

fn executable(name: &str) -> Option<PathBuf> {
    let file = if cfg!(windows) { format!("{name}.exe") } else { name.to_string() };
    let mut directories: Vec<PathBuf> = std::env::var_os("PATH").map(|path| std::env::split_paths(&path).collect()).unwrap_or_default();
    // A graphical launch does not inherit the shell's PATH.
    for extra in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "C:\\Program Files\\Neovim\\bin"] {
        directories.push(PathBuf::from(extra));
    }
    directories.into_iter().map(|directory| directory.join(&file)).find(|path| path.is_file())
}

/// `Resources/Editor/neolink.lua`: next to the executable in a packaged app, in the repository otherwise.
fn configuration() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("NEOLINK_EDITOR_CONFIG").map(PathBuf::from) {
        return Some(path);
    }
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
            for candidate in [current.join("Resources/Editor/neolink.lua"), current.join("../Resources/Editor/neolink.lua")] {
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
            directory = current.parent();
        }
    }
    None
}

fn rgba(color: u32) -> Rgba {
    [(color >> 16) as u8, (color >> 8) as u8, color as u8, 0xff]
}

impl Editor {
    /// Starts Neovim. Fails with a message for the user if it is not installed or does not start.
    pub fn start(shared: &Arc<Shared>, columns: usize, rows: usize) -> Result<Editor, String> {
        let nvim = executable("nvim").ok_or("Neovim (nvim) is not installed or not on the PATH.")?;
        let config = configuration().ok_or("The editor configuration (Resources/Editor/neolink.lua) was not found.")?;
        let wake = Arc::downgrade(shared);
        // Pixel scrolling (`NEOLINK_EDITOR_SMOOTH=0` scrolls by lines): Neovim draws two rows more.
        let smooth = std::env::var("NEOLINK_EDITOR_SMOOTH").as_deref() != Ok("0");
        let rows = rows.max(4) + if smooth { EXTRA_ROWS } else { 0 };
        let client = Client::spawn(&nvim, &config, columns.max(20), rows, move || {
            if let Some(shared) = wake.upgrade() {
                shared.invalidate();
            }
        })
        .map_err(|error| format!("Neovim did not start: {error}"))?;
        Ok(Editor { client, grid: (columns.max(20), rows), next_token: 1, requested: None, frozen: None, speculative: None, speculated: 0, waited: 0, wheel: 0.0, smooth, smoother: neolink_core::scroll::ScrollSmoother::new(neolink_core::scroll::Smoothing::Auto), position: 0.0, position_path: String::new(), commanded_top: 0, last_wheel: 0.0, drawn_shift: 0.0, received: 0.0, drawn_position: 0.0, scratch: Vec::new(), drawn_generation: 0 })
    }

    pub fn has_exited(&self) -> bool {
        self.client.has_exited()
    }

    /// Asks Neovim to show `path`. Returns the selection's token.
    pub fn select(&mut self, path: &str) -> u64 {
        if let Some((token, current)) = &self.requested {
            if current == path {
                return *token;
            }
        }
        let token = self.next_token;
        self.next_token += 1;
        // Until Neovim confirms, the pane keeps showing this...
        let current = self.client.screen();
        // ...unless the buffer's screen from its last visit is provably still right (docs/NATIVE_GRID.md):
        // nothing touched it while hidden, Neovim left it in plain insert mode (where `open` returns),
        // the grid and the styles are the same, and the file on disk is the one it was read from.
        self.speculative = if std::env::var("NEOLINK_EDITOR_CACHE").as_deref() == Ok("0") {
            None
        } else {
            self.client.take_left(path).filter(|left| {
                left.plain_insert
                    && left.screen.columns == current.columns
                    && left.screen.rows.len() == current.rows.len()
                    && (left.screen.columns, left.screen.rows.len()) == self.grid
                    && left.screen.style_epoch == current.style_epoch
                    && left.file.is_some()
                    && left.file == FileSignature::of(path)
            })
            .map(|left| left.screen)
        };
        if self.speculative.is_some() {
            self.speculated += 1;
        } else {
            self.waited += 1;
        }
        self.frozen = Some(current);
        let _ = self.client.open(path, None, token);
        self.requested = Some((token, path.to_string()));
        token
    }

    /// Whether the screen now belongs to `path` (its selection is the newest one and is confirmed).
    pub fn shows(&self, path: &str) -> bool {
        let Some((token, requested)) = &self.requested else { return false };
        requested == path && self.client.with_state(|state| state.selection.as_ref().map(|selection| selection.0)) == Some(*token)
    }

    /// Whether the pane can show `path` now: Neovim confirmed it, or its remembered screen is valid.
    pub fn can_show(&self, path: &str) -> bool {
        self.shows(path) || (self.speculative.is_some() && self.requested.as_ref().is_some_and(|requested| requested.1 == path))
    }

    /// The buffer Neovim last confirmed.
    pub fn confirmed_path(&self) -> Option<String> {
        self.client.with_state(|state| state.selection.as_ref().map(|selection| selection.1.clone()))
    }

    /// `rows`: the rows the pane shows. With pixel scrolling Neovim draws two more, which are the slack
    /// the text slides through.
    pub fn resize(&mut self, columns: usize, rows: usize) {
        let grid = (columns.max(20), rows.max(4) + if self.smooth { EXTRA_ROWS } else { 0 });
        if grid != self.grid {
            self.grid = grid;
            let _ = self.client.resize(grid.0, grid.1);
        }
    }

    /// Keys in Neovim's notation.
    pub fn input(&self, keys: &str) {
        let _ = self.client.input(keys);
    }

    pub fn paste(&self, text: &str) {
        let _ = self.client.paste(text);
    }

    /// One of `neolink.lua`'s commands for the buffer shown; errors come back in the reply.
    pub fn command(&self, method: &str, path: &str) {
        let _ = self.client.dispatch(&serde_json::json!({"method": method, "path": path}));
    }

    pub fn action(&self, action: &str) {
        let _ = self.client.dispatch(&serde_json::json!({"method": "action", "action": action}));
    }

    /// The error of the last command, if it failed.
    pub fn last_error(&self) -> Option<String> {
        self.client.with_state(|state| {
            let reply = state.last_reply.as_ref()?;
            if reply["ok"].as_bool() == Some(false) {
                reply["error"].as_str().map(str::to_string)
            } else {
                None
            }
        })
    }

    /// Neovim's filetype for `path`, from its last report (empty until one arrived).
    pub fn filetype(&self, path: &str) -> String {
        self.buffer_field(path, "filetype").and_then(|value| value.as_str().map(str::to_string)).unwrap_or_default()
    }

    /// Diagnostics Neovim reported for `path`.
    pub fn diagnostics(&self, path: &str) -> u64 {
        self.buffer_field(path, "diagnostics").and_then(|value| value.as_u64()).unwrap_or(0)
    }

    /// The language servers attached to `path`'s buffer, as Neovim names them ("" if none).
    pub fn servers(&self, path: &str) -> String {
        self.buffer_field(path, "servers").and_then(|value| value.as_str().map(str::to_string)).unwrap_or_default()
    }

    /// Diagnostics of every open buffer: `(path, count, errors)`.
    pub fn all_diagnostics(&self) -> Vec<(String, u64, u64)> {
        self.client.with_state(|state| {
            let Some(buffers) = state.last_reply.as_ref().and_then(|reply| reply["state"]["buffers"].as_array()) else { return Vec::new() };
            buffers.iter().filter_map(|buffer| Some((buffer["path"].as_str()?.to_string(), buffer["diagnostics"].as_u64().unwrap_or(0), buffer["errors"].as_u64().unwrap_or(0)))).filter(|entry| entry.1 > 0).collect()
        })
    }

    fn buffer_field(&self, path: &str, field: &str) -> Option<serde_json::Value> {
        self.client.with_state(|state| {
            let buffers = state.last_reply.as_ref()?["state"]["buffers"].as_array()?;
            buffers.iter().find(|buffer| buffer["path"].as_str() == Some(path)).map(|buffer| buffer[field].clone())
        })
    }

    /// The mode as the Swift app words it.
    pub fn mode_label(&self) -> &'static str {
        self.client.with_state(|state| {
            let name = state.screen.modes.get(state.screen.mode).map(|mode| mode.name.as_str()).unwrap_or("insert");
            if name.starts_with("insert") {
                "Insert"
            } else if name == "normal" {
                "Normal"
            } else {
                "Visual / Command"
            }
        })
    }

    /// How many of Neovim's replies have been read.
    pub fn replies(&self) -> u64 {
        self.client.with_state(|state| state.replies)
    }

    /// Whether `path` has unsaved changes.
    pub fn is_modified(&self, path: &str) -> bool {
        self.client.with_state(|state| state.modified.contains(path))
    }

    /// The grid row under a point `y` pixels below the top of the pane.
    pub fn row_at(&self, y: f32, cell: CellMetrics) -> usize {
        let rows = self.grid.1.saturating_sub(1);
        if !self.smooth {
            return ((y / cell.height).floor().max(0.0) as usize).min(rows);
        }
        let visible = self.grid.1 - 1 - EXTRA_ROWS;
        if y >= visible as f32 * cell.height {
            // The status line stays at the bottom.
            return rows;
        }
        (((y + self.drawn_shift) / cell.height).floor().max(0.0) as usize).min(rows.saturating_sub(1))
    }

    /// Where `path`'s window is in its buffer: `(top line, lines)`.
    fn view(&self, path: &str) -> (u64, u64) {
        self.client.with_state(|state| {
            // A view that no redraw followed within 50 ms (nothing on screen changed) is current.
            if let Some((view, at)) = state.pending_views.get(path) {
                if at.elapsed().as_secs_f64() > 0.05 {
                    let view = *view;
                    state.views.insert(path.to_string(), view);
                    state.pending_views.remove(path);
                }
            }
            state.views.get(path).copied()
        })
        .unwrap_or((1, u64::MAX / 4))
    }

    /// A wheel report of `delta` device pixels at grid cell `(row, column)`. With pixel scrolling the
    /// view's position moves by exactly that and Neovim is asked for the lines around it; otherwise whole
    /// lines go to Neovim.
    pub fn scroll(&mut self, time: f64, delta: f64, period: f64, cell: CellMetrics, row: usize, column: usize, path: &str) {
        if self.smooth && self.shows(path) {
            // Fingers moving down show earlier lines.
            self.received += delta;
            self.smoother.push(time, -delta, period);
            self.last_wheel = crate::clock::now();
            return;
        }
        self.scroll_now(delta, cell, row, column, path);
    }

    /// Moves the view by `delta` pixels at once and asks Neovim for the lines around it.
    fn scroll_now(&mut self, delta: f64, cell: CellMetrics, row: usize, column: usize, path: &str) {
        if std::env::var_os("NEOLINK_DEBUG_SCROLL").is_some() {
            eprintln!("editor scroll delta {delta:.1} smooth {} shows {} view {:?} position {:.1}", self.smooth, self.shows(path), self.view(path), self.position);
        }
        if self.smooth && self.shows(path) {
            let height = cell.height as f64;
            let (top, total) = self.view(path);
            let visible = (self.grid.1 - 1 - EXTRA_ROWS) as u64;
            if self.position_path != path || (top != self.commanded_top && crate::clock::now() - self.last_wheel > 0.3) {
                // Neovim moved the view itself since the last gesture: start from where it is.
                self.position = (top - 1) as f64 * height + (top - 1).min(LEAD) as f64 * height;
                self.position_path = path.to_string();
            }
            let limit = total.saturating_sub(visible) as f64 * height;
            let wanted = self.position - delta;
            self.position = wanted.clamp(0.0, limit.max(0.0));
            if wanted != self.position {
                // An end of the file: what did not fit is dropped, so reversing answers at once.
                self.smoother.cancel();
            }
            // Neovim's top line is kept one line above the view's, so a line of slack lies either side.
            let target = ((self.position / height).floor() as u64).saturating_sub(LEAD).min(total.saturating_sub(visible + EXTRA_ROWS as u64)) + 1;
            if target != self.commanded_top || top != target {
                self.commanded_top = target;
                let _ = self.client.notify("nvim_exec_lua", vec![rmpv_string(SCROLL_TO), neolink_nvim::rmpv::Value::Array(vec![neolink_nvim::rmpv::Value::from(target)])]);
            }
            self.last_wheel = crate::clock::now();
            return;
        }
        self.wheel += delta;
        let lines = (self.wheel / cell.height as f64).trunc();
        if lines == 0.0 {
            return;
        }
        self.wheel -= lines * cell.height as f64;
        let direction = if lines > 0.0 { "up" } else { "down" };
        for _ in 0..lines.abs() as usize {
            let _ = self.client.input_mouse("wheel", direction, "", row, column);
        }
    }

    pub fn end_scroll_gesture(&mut self) {
        self.wheel = 0.0;
        self.smoother.begin_gesture();
    }

    pub fn mouse(&self, action: &str, row: usize, column: usize) {
        let _ = self.client.input_mouse("left", action, "", row, column);
    }

    /// Generation of the live screen (changes with every published redraw).
    pub fn generation(&self) -> u64 {
        self.client.with_state(|state| state.screen.generation)
    }

    pub fn drawn_generation(&self) -> u64 {
        self.drawn_generation
    }

    /// Draws `path`'s screen into `rect`: Neovim's own once the selection is confirmed, the remembered
    /// one before that if it is valid, otherwise what was on screen before the pending selection.
    pub fn build(&mut self, painter: &mut Painter, rect: Rect, focused: bool, path: &str, display: f64, period: f64) -> Next {
        // This frame's share of the wheel input moves the view, then Neovim is asked for its lines.
        let step = self.smoother.advance(display, period);
        if step != 0.0 && self.smooth && self.shows(path) {
            let cell = painter.text.cell;
            self.scroll_now(-step, cell, 0, 0, path);
        }
        self.draw(painter, rect, focused, path);
        match self.smoother.next_visible_change(display, period, self.position) {
            None => Next::Idle,
            Some(at) if at <= display + 1.5 * period => Next::Soon,
            Some(at) => Next::At(at),
        }
    }

    fn draw(&mut self, painter: &mut Painter, rect: Rect, focused: bool, path: &str) {
        let requested_here = self.requested.as_ref().is_some_and(|requested| requested.1 == path);
        let screen = if self.shows(path) {
            self.frozen = None;
            self.speculative = None;
            self.client.screen()
        } else if let (true, Some(screen)) = (requested_here, &self.speculative) {
            screen.clone()
        } else {
            match &self.frozen {
                Some(screen) => screen.clone(),
                None => return,
            }
        };
        self.drawn_generation = screen.generation;
        let cell = painter.text.cell;
        painter.scene.set_clip(Some(rect));
        let default_background = rgba(screen.defaults.background);
        if default_background != theme::EDITOR_BACKGROUND {
            painter.scene.fill_rect(rect, default_background);
        }
        let shape = screen.cursor_shape();
        // Pixel scrolling: the text rows are drawn shifted up by between zero and two lines (the two
        // extra rows Neovim draws), the status line stays at the bottom.
        let text_rows = screen.rows.len().saturating_sub(1);
        let visible = text_rows.saturating_sub(EXTRA_ROWS);
        let shift = if self.smooth && screen.rows.len() == self.grid.1 && visible > 0 {
            let height = cell.height as f64;
            let (top, total) = self.view(path);
            let scrolling = crate::clock::now() - self.last_wheel < 0.3;
            if self.position_path != path || (!scrolling && top != self.commanded_top) {
                self.position = (top - 1) as f64 * height + (top - 1).min(LEAD) as f64 * height;
                self.position_path = path.to_string();
                self.commanded_top = top;
            }
            self.position = self.position.clamp(0.0, (total.saturating_sub(visible as u64) as f64 * height).max(0.0));
            let mut shift = self.position - (top - 1) as f64 * height;
            if !scrolling {
                // At rest the cursor's line is wholly in view.
                let cursor_top = screen.cursor.0 as f64 * height;
                if screen.cursor.0 < text_rows && cursor_top < shift {
                    self.position -= shift - cursor_top;
                } else if screen.cursor.0 < text_rows && cursor_top + height > shift + visible as f64 * height {
                    self.position += cursor_top + height - shift - visible as f64 * height;
                }
                shift = self.position - (top - 1) as f64 * height;
            }
            (shift.clamp(0.0, EXTRA_ROWS as f64 * height) as f32).round()
        } else {
            0.0
        };
        self.drawn_shift = shift;
        // What this frame shows, as a position in the buffer (the benchmark compares it with the input).
        self.drawn_position = (self.view(path).0 - 1) as f64 * cell.height as f64 + shift as f64;
        let smooth = self.smooth && screen.rows.len() == self.grid.1 && visible > 0;
        let text_clip = Rect::new(rect.x, rect.y, rect.width, if smooth { visible as f32 * cell.height } else { rect.height });
        painter.scene.set_clip(Some(text_clip));
        let mut scratch = std::mem::take(&mut self.scratch);
        for (index, row) in screen.rows.iter().enumerate() {
            let y = if smooth && index == text_rows {
                // The status line.
                painter.scene.set_clip(Some(rect));
                rect.y + visible as f32 * cell.height
            } else {
                rect.y + index as f32 * cell.height - shift
            };
            if y >= rect.bottom() || y + cell.height <= rect.y {
                continue;
            }
            let cursor_column = (screen.cursor.0 == index && !screen.busy).then_some(screen.cursor.1);
            let mut key = RowKey::new(screen.style_epoch ^ (row.len() as u64) << 32);
            for cell_ref in row.iter() {
                key.cell(cell_ref);
            }
            if let Some(column) = cursor_column {
                key.add(0xC0FFEE ^ (column as u64) << 8 ^ (shape as u64) << 40 ^ (focused as u64) << 48);
            }
            let key = key.finish();
            let retained = match painter.rows.get(key) {
                Some(row) => Some(row),
                None => {
                    scratch.clear();
                    build_row(&mut scratch, painter, &screen, row, cell, cursor_column, shape, focused);
                    painter.rows.insert(key, &scratch)
                }
            };
            match retained {
                Some(row) => painter.scene.retained(row, rect.x, y),
                None => painter.scene.translated(&scratch, rect.x, y),
            }
        }
        self.scratch = scratch;
        painter.scene.set_clip(None);
    }
}

fn build_row(out: &mut Vec<Instance>, painter: &mut Painter, screen: &Screen, row: &[Cell], cell: CellMetrics, cursor_column: Option<usize>, shape: CursorShape, focused: bool) {
    let default_foreground = rgba(screen.defaults.foreground);
    let default_background = rgba(screen.defaults.background);
    let resolve = |source: &Cell| {
        let highlight = screen.highlight(source.highlight);
        let mut foreground = highlight.foreground.map(rgba).unwrap_or(default_foreground);
        let mut background = highlight.background.map(rgba);
        if highlight.reverse {
            let swapped = background.unwrap_or(default_background);
            background = Some(foreground);
            foreground = swapped;
        }
        (highlight, foreground, background)
    };
    // Backgrounds first, merged into runs.
    let mut run: Option<(usize, Rgba)> = None;
    for column in 0..=row.len() {
        let background = row.get(column).and_then(|source| resolve(source).2);
        match (run, background) {
            (Some((_, color)), Some(next)) if color == next => {}
            (previous, next) => {
                if let Some((start, color)) = previous {
                    out.push(Instance::fill(start as f32 * cell.width, 0.0, (column - start) as f32 * cell.width, cell.height, color));
                }
                run = next.map(|color| (column, color));
            }
        }
    }
    let thickness = (cell.font_pixels / 14.0).round().max(1.0);
    for (column, source) in row.iter().enumerate() {
        let x = column as f32 * cell.width;
        let (highlight, mut foreground, background) = resolve(source);
        if cursor_column == Some(column) && focused && shape == CursorShape::Block {
            out.push(Instance::fill(x, 0.0, cell.width, cell.height, foreground));
            foreground = background.unwrap_or(default_background);
        }
        match &source.text {
            Text::Char(' ') => {}
            Text::Char(character) => {
                if let Some(glyph) = painter.text.cell_glyph(painter.queue, *character, highlight.bold, highlight.italic) {
                    out.push(Instance::glyph(glyph.sprite, x + glyph.x as f32, cell.baseline + glyph.y as f32, foreground));
                }
            }
            Text::Cluster(cluster) => {
                for glyph in painter.text.cluster_glyphs(painter.queue, cluster, highlight.bold, highlight.italic).iter() {
                    out.push(Instance::glyph(glyph.sprite, x + glyph.x as f32, cell.baseline + glyph.y as f32, foreground));
                }
            }
        }
        if highlight.underline != Underline::None {
            let color = highlight.special.or(screen.defaults.special).map(rgba).unwrap_or(foreground);
            out.push(Instance::fill(x, cell.baseline + 2.0, cell.width, thickness, color));
        }
        if highlight.strikethrough {
            out.push(Instance::fill(x, (cell.baseline * 0.68).round(), cell.width, thickness, foreground));
        }
    }
    if let Some(column) = cursor_column {
        let x = column as f32 * cell.width;
        let bar = (cell.font_pixels / 8.0).round().max(2.0);
        let color = theme::ACCENT;
        match shape {
            CursorShape::Vertical => out.push(Instance::fill(x, 0.0, bar, cell.height, color)),
            CursorShape::Horizontal => out.push(Instance::fill(x, cell.height - bar, cell.width, bar, color)),
            CursorShape::Block if !focused => {
                out.push(Instance::fill(x, 0.0, cell.width, 2.0, color));
                out.push(Instance::fill(x, cell.height - 2.0, cell.width, 2.0, color));
                out.push(Instance::fill(x, 0.0, 2.0, cell.height, color));
                out.push(Instance::fill(x + cell.width - 2.0, 0.0, 2.0, cell.height, color));
            }
            CursorShape::Block => {}
        }
    }
}

/// A hash of everything that decides a row's pixels.
struct RowKey(u64);

impl RowKey {
    fn new(seed: u64) -> RowKey {
        RowKey(0xA24BAED4963EE407 ^ seed)
    }

    #[inline]
    fn add(&mut self, value: u64) {
        self.0 = (self.0.rotate_left(5) ^ value).wrapping_mul(0x517cc1b727220a95);
    }

    fn cell(&mut self, cell: &Cell) {
        match &cell.text {
            Text::Char(character) => self.add(*character as u64 | (cell.highlight as u64) << 32),
            Text::Cluster(cluster) => {
                for byte in cluster.bytes() {
                    self.add(byte as u64 | 0x100);
                }
                self.add(0x1_0000_0000 | (cell.highlight as u64) << 33 | cluster.len() as u64);
            }
        }
    }

    fn finish(&self) -> u64 {
        self.0 ^ (self.0 >> 29)
    }
}
