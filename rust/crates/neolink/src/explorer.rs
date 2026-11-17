//! The project tree in the sidebar. The model is `neolink_core::tree`; directories are read on short-lived
//! background threads and never on the main or render thread.

use crate::chrome::{faded, Ui};
use crate::frame::{Next, Painter, Shared};
use crate::icons::IconWeight;
use crate::render::Rect;
use crate::term::ScrollPhase;
use crate::theme;
use neolink_core::git::{Decorations, Status};
use neolink_core::scroll::{ScrollSmoother, Smoothing};
use neolink_core::tree::{Entry, Row, RowKind, Tree};
use parking_lot::Mutex;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};

/// The pane's ideal width in the Swift app's split view.
pub const WIDTH_POINTS: f32 = 250.0;
const ROW_POINTS: f32 = 24.0;
/// Header (34) + separator, navigation bar (24), filter field (27) and their spacing.
const HEADER_POINTS: f32 = 34.0 + 1.0 + 4.0 + 24.0 + 6.0 + 27.0 + 6.0;
const FOOTER_POINTS: f32 = 22.0;

/// What a press in the pane did.
pub enum Clicked {
    File(PathBuf),
    /// The pane's close button.
    Close,
    Nothing,
}

/// The icon of a file, as `SemanticFileIcon` chooses it: an abbreviation or a symbol, and its colour.
fn file_look(path: &Path) -> (Option<&'static str>, &'static str, theme::Rgba) {
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or("");
    let extension = path.extension().and_then(|extension| extension.to_str()).unwrap_or("").to_lowercase();
    let abbreviation = if name == "Dockerfile" || name == "Containerfile" {
        Some("\u{25c8}")
    } else {
        match extension.as_str() {
            "swift" => Some("Sw"),
            "py" | "pyi" => Some("Py"),
            "js" | "jsx" => Some("JS"),
            "ts" | "tsx" => Some("TS"),
            "rs" => Some("Rs"),
            "go" => Some("Go"),
            "java" => Some("J"),
            "kt" => Some("Kt"),
            "rb" => Some("Rb"),
            "c" => Some("C"),
            "h" => Some("H"),
            "cpp" => Some("C+"),
            "hpp" => Some("H+"),
            _ => None,
        }
    };
    let symbol = if name == ".editorconfig" || name.starts_with(".git") || name.starts_with(".env") {
        "gearshape"
    } else {
        match extension.as_str() {
            "md" | "mdx" => "text.alignleft",
            "pdf" => "doc.richtext",
            "png" | "jpg" | "jpeg" | "gif" | "svg" | "heic" => "photo",
            "zip" | "gz" | "tar" => "doc.zipper",
            _ => "doc.text",
        }
    };
    let color = match extension.as_str() {
        "swift" | "rs" | "html" => theme::rgb(0xCDA18A),
        "js" | "jsx" | "sh" | "bash" | "zsh" => theme::rgb(0xD6D6A4),
        "py" | "pyi" | "ts" | "tsx" | "go" | "md" | "pdf" => theme::rgb(0xA8CCDF),
        "json" | "jsonc" | "css" | "scss" | "yaml" | "yml" => theme::rgb(0xD6B3D2),
        _ => theme::TEXT_SECONDARY,
    };
    (abbreviation, symbol, color)
}

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
    close_rect: Rect,
    collapse_rect: Rect,
    refresh_rect: Rect,
    git: Decorations,
    git_loaded: Arc<Mutex<Option<Decorations>>>,
    git_running: Arc<std::sync::atomic::AtomicBool>,
}

/// Runs the bounded status query of docs/EXPLORER.md. `None` when git is missing, the folder is not a
/// repository, or the query fails.
fn git_decorations(root: &Path) -> Option<Decorations> {
    let run = |arguments: &[&str]| {
        std::process::Command::new("git")
            .arg("-C")
            .arg(root)
            .args(arguments)
            .env("GIT_OPTIONAL_LOCKS", "0")
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output()
            .ok()
            .filter(|output| output.status.success())
    };
    let top = run(&["rev-parse", "--show-toplevel"])?;
    let top = PathBuf::from(String::from_utf8(top.stdout).ok()?.trim_end());
    let status = run(&["status", "--porcelain=v1", "-z", "--ignored=matching", "--untracked-files=normal"])?;
    if status.stdout.len() > 8 * 1024 * 1024 {
        return None;
    }
    let top = neolink_core::paths::canonical(&top);
    Some(Decorations::new(&top, &neolink_core::git::parse_porcelain(&status.stdout)))
}

fn status_color(status: Status) -> theme::Rgba {
    match status {
        Status::Added | Status::Untracked => theme::rgb(0xA4B29B),
        Status::Modified => theme::rgb(0xA8CCDF),
        Status::Deleted | Status::Conflict => theme::rgb(0xCC9595),
        Status::Renamed => theme::rgb(0xCDA18A),
        Status::Ignored => theme::rgb(0x5E5E5E),
    }
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
            close_rect: Rect::default(),
            collapse_rect: Rect::default(),
            refresh_rect: Rect::default(),
            git: Decorations::default(),
            git_loaded: Arc::new(Mutex::new(None)),
            git_running: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        }
    }

    /// Asks git for the project's status on a background thread (one query at a time).
    fn request_git(&mut self) {
        use std::sync::atomic::Ordering;
        if self.git_running.swap(true, Ordering::AcqRel) {
            return;
        }
        let (root, loaded, running, shared) = (self.tree.root().to_path_buf(), self.git_loaded.clone(), self.git_running.clone(), self.shared.clone());
        let spawned = std::thread::Builder::new().name("explorer git".into()).spawn(move || {
            let decorations = git_decorations(&root).unwrap_or_default();
            *loaded.lock() = Some(decorations);
            running.store(false, Ordering::Release);
            if let Some(shared) = shared.upgrade() {
                shared.invalidate();
            }
        });
        if spawned.is_err() {
            self.git_running.store(false, Ordering::Release);
        }
    }

    pub fn attach(&mut self, shared: &Arc<Shared>) {
        self.shared = Arc::downgrade(shared);
        self.request_git();
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
        if let Some(decorations) = self.git_loaded.lock().take() {
            if decorations != self.git {
                self.git = decorations;
                self.revision += 1;
            }
        }
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

    /// Reads the open folders and the Git status again (after a save, or when the window is activated).
    /// What is shown stays until the new listings arrive.
    pub fn refresh(&mut self) {
        let open: Vec<PathBuf> = std::iter::once(self.tree.root().to_path_buf()).chain(self.rows.iter().filter(|row| matches!(row.kind, RowKind::Folder { expanded: true, loading: false })).map(|row| row.path.clone())).collect();
        for directory in open {
            if !self.requested.insert(directory.clone()) {
                continue;
            }
            let (loaded, shared) = (self.loaded.clone(), self.shared.clone());
            let _ = std::thread::Builder::new().name("explorer".into()).spawn(move || {
                let entries = read_directory(&directory);
                loaded.lock().push((directory, entries));
                if let Some(shared) = shared.upgrade() {
                    shared.invalidate();
                }
            });
        }
        self.request_git();
    }

    /// Opens the folders above `path` so its row exists.
    pub fn reveal(&mut self, path: &Path) {
        if self.tree.reveal(path) {
            self.stale = true;
        }
    }

    fn row_at(&self, x: f32, y: f32) -> Option<usize> {
        if !self.contains(x, y) || y < self.rect.y + self.header_height || y >= self.rect.bottom() - (FOOTER_POINTS * self.row_height / ROW_POINTS) {
            return None;
        }
        let index = ((y - self.rect.y - self.header_height) as f64 + self.drawn_scroll) / self.row_height as f64;
        let index = index.floor() as usize;
        (index < self.rows.len()).then_some(index)
    }

    /// A press at `(x, y)`: a folder opens or closes; a file is returned for the caller to open.
    pub fn click(&mut self, x: f32, y: f32) -> Clicked {
        if self.close_rect.contains(x, y) {
            return Clicked::Close;
        }
        if self.collapse_rect.contains(x, y) {
            self.tree.collapse_all();
            self.stale = true;
            return Clicked::Nothing;
        }
        if self.refresh_rect.contains(x, y) {
            self.refresh();
            return Clicked::Nothing;
        }
        let Some(row) = self.row_at(x, y).and_then(|index| self.rows.get(index)).cloned() else { return Clicked::Nothing };
        match row.kind {
            RowKind::File => Clicked::File(row.path),
            RowKind::Folder { .. } => {
                self.tree.toggle(&row.path);
                self.stale = true;
                Clicked::Nothing
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

    /// Draws the pane as the Swift app's `FileBrowserPane` and explorer cells do (sizes in points there).
    pub fn build(&mut self, painter: &mut Painter, rect: Rect, scale: f32, active: Option<&str>, display: f64, period: f64) -> Next {
        self.rect = rect;
        self.row_height = (ROW_POINTS * scale).round();
        self.header_height = (HEADER_POINTS * scale).round();
        self.refresh_rows();
        let footer_height = (FOOTER_POINTS * scale).round();
        let list = Rect::new(rect.x, rect.y + self.header_height, rect.width, (rect.height - self.header_height - footer_height).max(1.0));
        let content = self.rows.len() as f64 * self.row_height as f64;
        let limit = (content - list.height as f64).max(0.0);
        let wanted = self.scroll + self.smoother.advance(display, period);
        self.scroll = wanted.clamp(0.0, limit);
        if wanted != self.scroll {
            self.smoother.cancel();
        }
        let scroll = self.scroll.round();
        self.drawn_scroll = scroll;

        let mut ui = Ui { painter, scale };
        ui.fill(rect, theme::SIDEBAR_BACKGROUND);
        let line = ui.px(1.0).max(1.0);
        // Header: EXPLORER, LOCAL, close.
        let header = Rect::new(rect.x, rect.y, rect.width, ui.px(34.0));
        let middle = header.y + header.height * 0.5;
        ui.text("E X P L O R E R".replace(' ', "\u{200a}").as_str(), rect.x + ui.px(12.0), middle, 10.0, 500, false, theme::TEXT_PRIMARY);
        let button = ui.px(28.0);
        self.close_rect = Rect::new(rect.right() - ui.px(12.0) - button, middle - button * 0.5, button, button);
        ui.icon("xmark", 12.0, IconWeight::Medium, self.close_rect.x + button * 0.5, middle, theme::TEXT_SECONDARY);
        ui.text_right("LOCAL", self.close_rect.x - ui.px(8.0 + 7.0), middle, 9.0, 600, true, theme::TEXT_SECONDARY);
        ui.painter.scene.fill(rect.x, header.bottom(), rect.width, line, theme::SEPARATOR);
        // Navigation bar: new, folder name, collapse all, refresh, options.
        let inset = ui.px(8.0);
        let bar_top = header.bottom() + line + ui.px(4.0);
        let bar_middle = bar_top + ui.px(12.0);
        let slot = ui.px(22.0);
        ui.icon("plus", 12.0, IconWeight::Regular, rect.x + inset + slot * 0.5, bar_middle, theme::TEXT_SECONDARY);
        let name = self.tree.root().file_name().and_then(|name| name.to_str()).unwrap_or("Macintosh HD").to_string();
        let mut right = rect.right() - inset;
        ui.icon("line.3.horizontal.decrease.circle", 12.0, IconWeight::Regular, right - slot * 0.5, bar_middle, theme::TEXT_SECONDARY);
        right -= slot + ui.px(8.0);
        self.refresh_rect = Rect::new(right - slot, bar_top, slot, ui.px(24.0));
        ui.icon("arrow.clockwise", 12.0, IconWeight::Regular, right - slot * 0.5, bar_middle, theme::TEXT_SECONDARY);
        right -= slot + ui.px(8.0);
        self.collapse_rect = Rect::new(right - slot, bar_top, slot, ui.px(24.0));
        ui.icon("rectangle.compress.vertical", 12.0, IconWeight::Regular, right - slot * 0.5, bar_middle, theme::TEXT_SECONDARY);
        right -= slot + ui.px(8.0);
        let name_x = rect.x + inset + slot + ui.px(8.0);
        let fitted = ui.fit_middle(&name, (right - name_x).max(1.0), 12.0, 600, false);
        ui.text(&fitted, name_x, bar_middle, 12.0, 600, false, theme::TEXT_SECONDARY);
        // Filter field (not editable yet: PLAN.md).
        let field = Rect::new(rect.x + inset, bar_top + ui.px(24.0 + 6.0), rect.width - 2.0 * inset, ui.px(27.0));
        ui.fill(field, theme::white(0.09));
        ui.fill(Rect::new(field.x + line, field.y + line, field.width - 2.0 * line, field.height - 2.0 * line), theme::rgb(0x161616));
        let field_middle = field.y + field.height * 0.5;
        let glass = ui.icon("magnifyingglass", 11.0, IconWeight::Regular, field.x + ui.px(9.0 + 6.0), field_middle, theme::TEXT_SECONDARY);
        ui.text("Filter tree\u{2026}", field.x + ui.px(9.0) + glass.max(ui.px(12.0)) + ui.px(7.0), field_middle, 11.0, 400, false, faded(theme::TEXT_SECONDARY, 0.7));
        ui.text_right(if cfg!(target_os = "macos") { "\u{2318}P" } else { "Ctrl+P" }, field.right() - ui.px(9.0), field_middle, 10.0, 400, false, theme::TEXT_SECONDARY);

        // Rows (`ExplorerCellView`): chevron, icon or abbreviation, name, badge.
        ui.painter.scene.set_clip(Some(list));
        let first = (scroll / self.row_height as f64).floor() as usize;
        let count = (list.height / self.row_height).ceil() as usize + 1;
        for index in first..(first + count).min(self.rows.len()) {
            let row = self.rows[index].clone();
            let y = list.y + index as f32 * self.row_height - scroll as f32;
            let row_middle = y + self.row_height * 0.5;
            let is_active = active.is_some_and(|path| Path::new(path) == row.path);
            if is_active {
                ui.painter.scene.fill(rect.x, y, rect.width, self.row_height, theme::SELECTION);
            } else if self.hover == Some(index) {
                ui.painter.scene.fill(rect.x, y, rect.width, self.row_height, theme::HOVER);
            }
            let status = self.git.status(&row.path);
            let opacity = if status == Some(Status::Ignored) { 0.55 } else { 1.0 };
            let x = rect.x + ui.px(8.0 + row.depth as f32 * 12.0);
            let is_folder = !matches!(row.kind, RowKind::File);
            if let RowKind::Folder { expanded, .. } = row.kind {
                ui.icon(if expanded { "chevron.down" } else { "chevron.right" }, 8.0, IconWeight::Regular, x + ui.px(5.0), row_middle, faded(theme::TEXT_SECONDARY, opacity));
                ui.icon(if expanded { "folder.fill" } else { "folder" }, 12.0, IconWeight::Regular, x + ui.px(15.0 + 8.5), row_middle, faded(theme::TEXT_SECONDARY, opacity));
            } else {
                let (abbreviation, symbol, color) = file_look(&row.path);
                match abbreviation {
                    Some(text) => {
                        let width = ui.measure(text, 8.0, 700, true);
                        ui.text(text, x + ui.px(15.0 + 8.5) - width * 0.5, row_middle, 8.0, 700, true, faded(color, opacity));
                    }
                    None => {
                        ui.icon(symbol, 12.0, IconWeight::Regular, x + ui.px(15.0 + 8.5), row_middle, faded(color, opacity));
                    }
                }
            }
            let mut right = rect.right() - ui.px(8.0);
            let mut name_color = theme::TEXT_PRIMARY;
            if let Some(status) = status {
                name_color = if status == Status::Ignored { theme::TEXT_SECONDARY } else { status_color(status) };
                if status != Status::Ignored {
                    let _ = is_folder;
                    right -= ui.text_right(status.letter(), right, row_middle, 10.0, 500, true, status_color(status)) + ui.px(7.0);
                }
            }
            let name_x = x + ui.px(37.0);
            let label = ui.fit_middle(&row.label, (right - name_x).max(1.0), 12.0, 400, false);
            ui.text(&label, name_x, row_middle, 12.0, 400, false, faded(name_color, opacity));
        }
        ui.painter.scene.set_clip(None);
        // Footer: follow terminal, and how many rows are shown.
        let footer = Rect::new(rect.x, rect.bottom() - footer_height, rect.width, footer_height);
        ui.painter.scene.fill(rect.x + inset, footer.y, rect.width - 2.0 * inset, line, theme::SEPARATOR);
        let footer_middle = footer.y + ui.px(4.0) + (footer.height - ui.px(4.0)) * 0.5;
        let link = ui.icon("link.badge.plus", 10.0, IconWeight::Regular, rect.x + inset + ui.px(7.0), footer_middle, theme::TEXT_SECONDARY);
        ui.text("Follow terminal", rect.x + inset + link.max(ui.px(14.0)) + ui.px(4.0), footer_middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        let summary = if self.tree.was_truncated() { "Tree limit \u{b7} use \u{2318}P".to_string() } else { format!("{} visible", self.rows.len()) };
        ui.text_right(&summary, rect.right() - inset, footer_middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        // The split view's divider.
        ui.painter.scene.fill(rect.right(), rect.y, line, rect.height, theme::SEPARATOR);
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
