//! The project tree in the sidebar. The model is `neolink_core::tree`; directories are read on short-lived
//! background threads and never on the main or render thread.

use crate::frame::{Next, Painter, Shared};
use crate::render::Rect;
use crate::term::ScrollPhase;
use crate::theme;
use neolink_core::scroll::{ScrollSmoother, Smoothing};
use neolink_core::tree::{Entry, Row, RowKind, Tree};
use parking_lot::Mutex;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};

pub const WIDTH_POINTS: f32 = 260.0;
const ROW_POINTS: f32 = 24.0;
const HEADER_POINTS: f32 = 30.0;

pub struct Explorer {
    tree: Tree,
    rows: Vec<Row>,
    stale: bool,
    loaded: Arc<Mutex<Vec<(PathBuf, Vec<Entry>)>>>,
    requested: HashSet<PathBuf>,
    shared: Weak<Shared>,
    /// Device pixels scrolled down from the top.
    scroll: f64,
    drawn_scroll: f64,
    smoother: ScrollSmoother,
    hover: Option<usize>,
    pub visible: bool,
    rect: Rect,
    row_height: f32,
    header_height: f32,
    /// Changes whenever the rows do.
    revision: u64,
}

fn read_directory(directory: &Path) -> Vec<Entry> {
    let Ok(reader) = std::fs::read_dir(directory) else { return Vec::new() };
    let mut entries = Vec::new();
    for entry in reader.flatten().take(neolink_core::tree::MAX_ENTRIES) {
        let Some(name) = entry.file_name().to_str().map(str::to_string) else { continue };
        // A symbolic link to a folder is listed as a folder but only read when opened by hand.
        let is_directory = entry.path().is_dir();
        entries.push(Entry { name, is_directory });
    }
    entries
}

impl Explorer {
    pub fn new(root: PathBuf) -> Explorer {
        Explorer {
            tree: Tree::new(root),
            rows: Vec::new(),
            stale: true,
            loaded: Arc::new(Mutex::new(Vec::new())),
            requested: HashSet::new(),
            shared: Weak::new(),
            scroll: 0.0,
            drawn_scroll: 0.0,
            smoother: ScrollSmoother::new(Smoothing::Auto),
            hover: None,
            visible: true,
            rect: Rect::default(),
            row_height: 48.0,
            header_height: 60.0,
            revision: 0,
        }
    }

    pub fn attach(&mut self, shared: &Arc<Shared>) {
        self.shared = Arc::downgrade(shared);
    }

    pub fn root(&self) -> &Path {
        self.tree.root()
    }

    pub fn contains(&self, x: f32, y: f32) -> bool {
        self.visible && self.rect.contains(x, y)
    }

    /// Reads the folders the tree wants, off this thread.
    fn request_listings(&mut self) {
        for directory in self.tree.wanted() {
            if !self.requested.insert(directory.clone()) {
                continue;
            }
            let (loaded, shared) = (self.loaded.clone(), self.shared.clone());
            let spawned = std::thread::Builder::new().name("explorer".into()).spawn(move || {
                let entries = read_directory(&directory);
                loaded.lock().push((directory, entries));
                if let Some(shared) = shared.upgrade() {
                    shared.invalidate();
                }
            });
            if spawned.is_err() {
                break;
            }
        }
    }

    fn refresh_rows(&mut self) {
        let arrived: Vec<_> = std::mem::take(&mut *self.loaded.lock());
        for (directory, entries) in arrived {
            self.requested.remove(&directory);
            self.tree.set_listing(&directory, entries);
            self.stale = true;
        }
        if self.stale {
            self.stale = false;
            self.rows = self.tree.rows();
            self.revision += 1;
            self.request_listings();
        }
    }

    /// Forgets what is known about open folders and reads them again (after file operations, or when
    /// the window is activated).
    pub fn refresh(&mut self) {
        let open: Vec<PathBuf> = std::iter::once(self.tree.root().to_path_buf()).chain(self.rows.iter().filter(|row| matches!(row.kind, RowKind::Folder { expanded: true, .. })).map(|row| row.path.clone())).collect();
        for directory in open {
            self.tree.invalidate(&directory);
        }
        self.stale = true;
    }

    /// Opens the folders above `path` so its row exists.
    pub fn reveal(&mut self, path: &Path) {
        if self.tree.reveal(path) {
            self.stale = true;
        }
    }

    fn row_at(&self, x: f32, y: f32) -> Option<usize> {
        if !self.contains(x, y) || y < self.rect.y + self.header_height {
            return None;
        }
        let index = ((y - self.rect.y - self.header_height) as f64 + self.drawn_scroll) / self.row_height as f64;
        let index = index.floor() as usize;
        (index < self.rows.len()).then_some(index)
    }

    /// A press at `(x, y)`: a folder opens or closes; a file is returned for the caller to open.
    pub fn click(&mut self, x: f32, y: f32) -> Option<PathBuf> {
        let row = self.rows.get(self.row_at(x, y)?)?.clone();
        match row.kind {
            RowKind::File => Some(row.path),
            RowKind::Folder { .. } => {
                self.tree.toggle(&row.path);
                self.stale = true;
                None
            }
        }
    }

    /// Returns `true` if the hover highlight changed.
    pub fn pointer(&mut self, x: f32, y: f32) -> bool {
        let hover = self.row_at(x, y);
        let changed = hover != self.hover;
        self.hover = hover;
        changed
    }

    pub fn scroll_input(&mut self, time: f64, delta: f64, phase: ScrollPhase, period: f64) {
        if phase == ScrollPhase::Began {
            self.smoother.begin_gesture();
        }
        // Fingers moving down bring earlier rows into view.
        self.smoother.push(time, -delta, period);
    }

    /// What decides the sidebar's pixels, apart from the active file.
    pub fn signature(&self) -> u64 {
        self.revision ^ (self.drawn_scroll.to_bits().rotate_left(17)) ^ (self.hover.map_or(u64::MAX, |index| index as u64) << 40) ^ self.visible as u64
    }

    pub fn build(&mut self, painter: &mut Painter, rect: Rect, scale: f32, active: Option<&str>, display: f64, period: f64) -> Next {
        self.rect = rect;
        self.row_height = (ROW_POINTS * scale).round();
        self.header_height = (HEADER_POINTS * scale).round();
        self.refresh_rows();
        let content = self.rows.len() as f64 * self.row_height as f64;
        let limit = (content - (rect.height - self.header_height) as f64).max(0.0);
        let wanted = self.scroll + self.smoother.advance(display, period);
        self.scroll = wanted.clamp(0.0, limit);
        if wanted != self.scroll {
            self.smoother.cancel();
        }
        let scroll = self.scroll.round();
        self.drawn_scroll = scroll;

        let scene = &mut *painter.scene;
        scene.fill_rect(rect, theme::SIDEBAR_BACKGROUND);
        let font_pixels = (12.5 * scale).round();
        let indent = (14.0 * scale).round();
        let list = Rect::new(rect.x, rect.y + self.header_height, rect.width, rect.height - self.header_height);
        scene.set_clip(Some(list));
        let first = (scroll / self.row_height as f64).floor() as usize;
        let count = (list.height / self.row_height).ceil() as usize + 1;
        for index in first..(first + count).min(self.rows.len()) {
            let row = &self.rows[index];
            let y = list.y + index as f32 * self.row_height - scroll as f32;
            let is_active = active.is_some_and(|path| Path::new(path) == row.path);
            if is_active {
                scene.fill(rect.x, y, rect.width, self.row_height, theme::SELECTION);
            } else if self.hover == Some(index) {
                scene.fill(rect.x, y, rect.width, self.row_height, theme::HOVER);
            }
            let x = rect.x + (10.0 * scale).round() + row.depth as f32 * indent;
            let baseline = (y + self.row_height * 0.5 + font_pixels * 0.36).round();
            let (marker, color) = match row.kind {
                RowKind::Folder { expanded: true, .. } => ("\u{25be}", theme::TEXT_PRIMARY),
                RowKind::Folder { expanded: false, .. } => ("\u{25b8}", theme::TEXT_PRIMARY),
                RowKind::File => ("", if is_active { theme::TEXT_PRIMARY } else { theme::TEXT_SECONDARY }),
            };
            if !marker.is_empty() {
                let shaped = painter.text.line(painter.queue, marker, font_pixels, false, true);
                for glyph in &shaped.glyphs {
                    scene.glyph(glyph.sprite, x + glyph.x, baseline + glyph.y, theme::TEXT_SECONDARY);
                }
            }
            let shaped = painter.text.line(painter.queue, &row.label, font_pixels, false, false);
            let text_x = x + (16.0 * scale).round();
            for glyph in &shaped.glyphs {
                scene.glyph(glyph.sprite, text_x + glyph.x, baseline + glyph.y, color);
            }
        }
        scene.set_clip(Some(rect));
        // Header: the project's name.
        let header = Rect::new(rect.x, rect.y, rect.width, self.header_height);
        scene.fill_rect(header, theme::SIDEBAR_BACKGROUND);
        let name = self.tree.root().file_name().and_then(|name| name.to_str()).unwrap_or("/").to_uppercase();
        let shaped = painter.text.line(painter.queue, &name, (11.0 * scale).round(), true, false);
        let baseline = (header.y + header.height * 0.5 + 11.0 * scale * 0.36).round();
        for glyph in &shaped.glyphs {
            scene.glyph(glyph.sprite, rect.x + (12.0 * scale).round() + glyph.x, baseline + glyph.y, theme::TEXT_SECONDARY);
        }
        if self.tree.was_truncated() {
            let note = painter.text.line(painter.queue, "list limited to 5,000 rows", (10.0 * scale).round(), false, false);
            for glyph in &note.glyphs {
                scene.glyph(glyph.sprite, rect.right() - note.width - (10.0 * scale).round() + glyph.x, baseline + glyph.y, theme::TEXT_SECONDARY);
            }
        }
        scene.fill(rect.right() - 1.0, rect.y, 1.0, rect.height, theme::SEPARATOR);
        scene.set_clip(None);
        match self.smoother.next_visible_change(display, period, self.scroll) {
            None => Next::Idle,
            Some(at) if at <= display + 1.5 * period => Next::Soon,
            Some(at) => Next::At(at),
        }
    }

    /// Number of rows (tests, benchmark).
    pub fn row_count(&self) -> usize {
        self.rows.len()
    }

    /// Scroll position in device pixels, as drawn.
    pub fn scroll(&self) -> f64 {
        self.drawn_scroll
    }
}
