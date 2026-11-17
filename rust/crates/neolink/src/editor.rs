//! The editor pane: one Neovim shared by every document tab, drawn from its `ext_linegrid` screen.
//!
//! The pane never shows a buffer Neovim has not confirmed: while a selection is unconfirmed the screen
//! as it was when the selection was requested stays up (see `neolink-nvim`'s client for why input needs
//! no such care here: the client holds it).

use crate::frame::{Painter, Shared};
use crate::render::{Instance, Rect};
use crate::text::CellMetrics;
use crate::theme::{self, Rgba};
use neolink_nvim::client::Client;
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
    /// Pixels of wheel input not yet turned into whole lines.
    wheel: f64,
    scratch: Vec<Instance>,
    /// Generation of the screen the last frame drew.
    drawn_generation: u64,
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
        let client = Client::spawn(&nvim, &config, columns.max(20), rows.max(4), move || {
            if let Some(shared) = wake.upgrade() {
                shared.invalidate();
            }
        })
        .map_err(|error| format!("Neovim did not start: {error}"))?;
        Ok(Editor { client, grid: (columns.max(20), rows.max(4)), next_token: 1, requested: None, frozen: None, wheel: 0.0, scratch: Vec::new(), drawn_generation: 0 })
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
        // Until Neovim confirms, the pane keeps showing this.
        self.frozen = Some(self.client.screen());
        let _ = self.client.open(path, None, token);
        self.requested = Some((token, path.to_string()));
        token
    }

    /// Whether the screen now belongs to `path` (its selection is the newest one and is confirmed).
    pub fn shows(&self, path: &str) -> bool {
        let Some((token, requested)) = &self.requested else { return false };
        requested == path && self.client.with_state(|state| state.selection.as_ref().map(|selection| selection.0)) == Some(*token)
    }

    /// The buffer Neovim last confirmed.
    pub fn confirmed_path(&self) -> Option<String> {
        self.client.with_state(|state| state.selection.as_ref().map(|selection| selection.1.clone()))
    }

    pub fn resize(&mut self, columns: usize, rows: usize) {
        let grid = (columns.max(20), rows.max(4));
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

    /// Whether Neovim reported unsaved changes in `path` in its last reply.
    pub fn is_modified(&self, path: &str) -> bool {
        self.client.with_state(|state| {
            state
                .last_reply
                .as_ref()
                .and_then(|reply| reply["state"]["buffers"].as_array().cloned())
                .map(|buffers| buffers.iter().any(|buffer| buffer["path"].as_str() == Some(path) && buffer["modified"].as_bool() == Some(true)))
                .unwrap_or(false)
        })
    }

    /// A wheel report of `delta` device pixels at grid cell `(row, column)`: whole lines go to Neovim.
    pub fn scroll(&mut self, delta: f64, cell: CellMetrics, row: usize, column: usize) {
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

    /// Draws the screen into `rect`: the live one when `live`, otherwise the one kept from before the
    /// pending selection.
    pub fn build(&mut self, painter: &mut Painter, rect: Rect, focused: bool, live: bool) {
        let screen = if live {
            self.frozen = None;
            self.client.screen()
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
        let mut scratch = std::mem::take(&mut self.scratch);
        for (index, row) in screen.rows.iter().enumerate() {
            let y = rect.y + index as f32 * cell.height;
            if y >= rect.bottom() {
                break;
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
