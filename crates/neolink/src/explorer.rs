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
    /// A deleted file's placeholder: its deletion is reviewed in Source Control.
    Missing,
    /// The folder name in the navigation bar: its menu (parent, home, enclosing folders).
    FolderMenu(Rect),
    /// The "new" and "options" menus, with the control they hang from.
    NewMenu(Rect),
    OptionsMenu(Rect),
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

/// Draws a file's icon (as the explorer shows it) centred at `(center_x, middle)`.
pub fn draw_file_icon(ui: &mut Ui, path: &Path, center_x: f32, middle: f32, opacity: f32) {
    let (abbreviation, symbol, color) = file_look(path);
    match abbreviation {
        Some(text) => {
            let width = ui.measure(text, 8.0, 700, true);
            ui.text(text, center_x - width * 0.5, middle, 8.0, 700, true, faded(color, opacity));
        }
        None => {
            ui.icon(symbol, 12.0, IconWeight::Regular, center_x, middle, faded(color, opacity));
        }
    }
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
    plus_rect: Rect,
    options_rect: Rect,
    filter_rect: Rect,
    /// Text of the filter field, and whether it has the keyboard.
    pub filter: String,
    pub filter_focused: bool,
    /// Explorer options (the Swift app's defaults).
    pub hide_ignored: bool,
    pub reveal_active: bool,
    /// The row the keyboard acts on, and whether the tree has the keyboard.
    pub selected: Option<PathBuf>,
    pub focused: bool,
    /// The tree shows the shown terminal's working directory instead of the project.
    pub follow_terminal: bool,
    follow_rect: Rect,
    /// Folder List mode: the project's tree is put aside and one folder is shown flat.
    pub folder_list: bool,
    project_tree: Option<Tree>,
    /// Folder List order (the Swift app's `FileSortOrder`, by index).
    pub sort: usize,
    name_rect: Rect,
    /// Watches the shown folder for changes made by other programs; set when something changed.
    watcher: Option<notify::RecommendedWatcher>,
    changed_on_disk: Arc<std::sync::atomic::AtomicBool>,
    /// Rows that stand for files deleted from the working tree.
    missing: std::collections::HashSet<PathBuf>,
    /// Diagnostics of open files: `(path, count, errors)`.
    diagnostics: Vec<(PathBuf, u64, u64)>,
    /// The pane as last drawn, and what it was drawn from: an unchanged pane is replayed.
    drawn: Option<(u64, Vec<(Option<Rect>, Vec<crate::render::Instance>)>)>,
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
            smoother: ScrollSmoother::new(Smoothing::from_environment()),
            hover: None,
            visible: std::env::var("NEOLINK_EXPLORER").as_deref() != Ok("0"),
            rect: Rect::default(),
            row_height: 48.0,
            header_height: 60.0,
            revision: 0,
            close_rect: Rect::default(),
            collapse_rect: Rect::default(),
            refresh_rect: Rect::default(),
            plus_rect: Rect::default(),
            options_rect: Rect::default(),
            filter_rect: Rect::default(),
            filter: String::new(),
            filter_focused: false,
            hide_ignored: false,
            reveal_active: true,
            selected: None,
            focused: false,
            follow_terminal: false,
            follow_rect: Rect::default(),
            missing: Default::default(),
            watcher: None,
            changed_on_disk: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            folder_list: false,
            project_tree: None,
            sort: 0,
            name_rect: Rect::default(),
            diagnostics: Vec::new(),
            drawn: None,
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
        self.watch();
    }

    /// Watches the shown folder (recursively; FSEvents on macOS, ReadDirectoryChangesW on Windows).
    /// Bursts of changes (a build, a checkout) are coalesced: the tree and Git are read again once
    /// things have been quiet for 150 ms.
    fn watch(&mut self) {
        use notify::{RecursiveMode, Watcher};
        self.watcher = None;
        let root = self.tree.root().to_path_buf();
        let (sender, receiver) = std::sync::mpsc::channel::<()>();
        let git = root.join(".git");
        let handler = move |event: notify::Result<notify::Event>| {
            let Ok(event) = event else { return };
            // Inside .git only what changes the status matters (the index, HEAD, branches).
            let relevant = event.paths.iter().any(|path| match path.strip_prefix(&git) {
                Ok(inside) => inside.starts_with("index") || inside.starts_with("HEAD") || inside.starts_with("refs"),
                Err(_) => true,
            });
            if relevant {
                let _ = sender.send(());
            }
        };
        let Ok(mut watcher) = notify::recommended_watcher(handler) else { return };
        if watcher.watch(&root, RecursiveMode::Recursive).is_err() {
            return;
        }
        self.watcher = Some(watcher);
        let (flag, shared) = (self.changed_on_disk.clone(), self.shared.clone());
        let _ = std::thread::Builder::new().name("explorer watch".into()).spawn(move || {
            while receiver.recv().is_ok() {
                // Wait for quiet.
                while receiver.recv_timeout(std::time::Duration::from_millis(150)).is_ok() {}
                flag.store(true, std::sync::atomic::Ordering::Release);
                match shared.upgrade() {
                    Some(shared) => shared.invalidate(),
                    None => return,
                }
            }
        });
    }

    /// The project's folder (also in Folder List mode, where another folder may be shown).
    pub fn root(&self) -> &Path {
        self.project_tree.as_ref().unwrap_or(&self.tree).root()
    }

    /// The folder the explorer shows at its top.
    pub fn current_folder(&self) -> &Path {
        self.tree.root()
    }

    /// Switches between the project tree and Folder List.
    pub fn set_folder_list(&mut self, on: bool) {
        if on == self.folder_list {
            return;
        }
        self.folder_list = on;
        if on {
            let folder = self.tree.root().to_path_buf();
            let mut list = Tree::new(folder);
            list.show_hidden = self.tree.show_hidden;
            list.compact = false;
            self.project_tree = Some(std::mem::replace(&mut self.tree, list));
        } else if let Some(mut tree) = self.project_tree.take() {
            tree.show_hidden = self.tree.show_hidden;
            self.tree = tree;
        }
        self.requested.clear();
        self.scroll = 0.0;
        self.smoother.cancel();
        self.stale = true;
        self.revision += 1;
    }

    /// Folder List: shows `folder`.
    pub fn navigate(&mut self, folder: &Path) {
        if !self.folder_list || !folder.is_dir() {
            return;
        }
        let mut list = Tree::new(folder.to_path_buf());
        list.show_hidden = self.tree.show_hidden;
        list.compact = false;
        self.tree = list;
        self.requested.clear();
        if self.watcher.is_some() {
            self.watch();
        }
        self.filter.clear();
        self.scroll = 0.0;
        self.smoother.cancel();
        self.stale = true;
        self.revision += 1;
    }

    /// Folder List: the order of the Swift app's "Sort by" entries.
    pub const SORT_ORDERS: [&'static str; 8] = ["Name (A\u{2013}Z)", "Name (Z\u{2013}A)", "Date modified (newest)", "Date modified (oldest)", "Date added (newest)", "Date added (oldest)", "Size (largest first)", "Size (smallest first)"];

    pub fn set_sort(&mut self, sort: usize) {
        self.sort = sort.min(Self::SORT_ORDERS.len() - 1);
        self.stale = true;
    }

    /// Folder List rows in the chosen order (folders first, as the Swift list).
    fn sorted(&self, mut rows: Vec<Row>) -> Vec<Row> {
        if !self.folder_list || self.sort == 0 {
            return rows;
        }
        let key = |row: &Row| -> (u64, std::time::SystemTime, std::time::SystemTime) {
            let metadata = std::fs::metadata(&row.path).ok();
            let modified = metadata.as_ref().and_then(|metadata| metadata.modified().ok()).unwrap_or(std::time::UNIX_EPOCH);
            let created = metadata.as_ref().and_then(|metadata| metadata.created().ok()).unwrap_or(modified);
            (metadata.map_or(0, |metadata| metadata.len()), modified, created)
        };
        let mut keyed: Vec<(Row, (u64, std::time::SystemTime, std::time::SystemTime))> = rows.drain(..).map(|row| {
            let key = key(&row);
            (row, key)
        }).collect();
        let sort = self.sort;
        keyed.sort_by(|(a, ka), (b, kb)| {
            let folders = matches!(b.kind, RowKind::Folder { .. }).cmp(&matches!(a.kind, RowKind::Folder { .. }));
            folders.then_with(|| match sort {
                1 => b.label.to_lowercase().cmp(&a.label.to_lowercase()),
                2 => kb.1.cmp(&ka.1),
                3 => ka.1.cmp(&kb.1),
                4 => kb.2.cmp(&ka.2),
                5 => ka.2.cmp(&kb.2),
                6 => kb.0.cmp(&ka.0),
                7 => ka.0.cmp(&kb.0),
                _ => a.label.to_lowercase().cmp(&b.label.to_lowercase()),
            })
        });
        keyed.into_iter().map(|(row, _)| row).collect()
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
        // Other programs changed files: read the open folders and Git again (not while scrolling,
        // where it would wait for the gesture to end).
        if !self.smoother.is_active() && self.changed_on_disk.swap(false, std::sync::atomic::Ordering::AcqRel) {
            self.refresh();
        }
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
            let rows = self.tree.rows();
            let rows = if self.folder_list { rows } else { self.with_deleted(rows) };
            let rows = self.sorted(rows);
            let rows = self.filtered(rows);
            self.scroll = neolink_core::tree::reanchored_scroll(&self.rows, &rows, self.scroll, self.row_height as f64);
            self.rows = rows;
            self.revision += 1;
            self.request_listings();
        }
    }

    /// Applies the filter text and the "hide ignored" option to the tree's rows: a row stays if its
    /// name matches, or if something beneath it does (loaded branches only, as in the Swift app).
    /// Adds a row for each file Git says was deleted, under its folder if that folder is open
    /// (docs/EXPLORER.md: deleted files stay visible as placeholders).
    fn with_deleted(&mut self, mut rows: Vec<Row>) -> Vec<Row> {
        self.missing.clear();
        let root = self.tree.root().to_path_buf();
        for path in self.git.deleted() {
            if path.exists() || rows.iter().any(|row| row.path == path) {
                continue;
            }
            let Some(parent) = path.parent() else { continue };
            let label = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
            let (at, depth) = if parent == root {
                (rows.len(), 0)
            } else {
                let Some(index) = rows.iter().position(|row| row.path == parent && matches!(row.kind, RowKind::Folder { expanded: true, .. })) else { continue };
                let depth = rows[index].depth;
                // After everything inside the folder.
                (rows[index + 1..].iter().position(|row| row.depth <= depth).map_or(rows.len(), |offset| index + 1 + offset), depth + 1)
            };
            rows.insert(at, Row { path: path.to_path_buf(), label, depth, kind: RowKind::File });
            self.missing.insert(path.to_path_buf());
        }
        rows
    }

    fn filtered(&self, rows: Vec<Row>) -> Vec<Row> {
        let needle = self.filter.trim().to_lowercase();
        let hide_ignored = self.hide_ignored;
        if needle.is_empty() && !hide_ignored {
            return rows;
        }
        let visible: Vec<bool> = rows.iter().map(|row| !(hide_ignored && self.git.status(&row.path) == Some(Status::Ignored))).collect();
        let mut keep = vec![false; rows.len()];
        for index in (0..rows.len()).rev() {
            if !visible[index] {
                continue;
            }
            let matches = needle.is_empty() || rows[index].label.to_lowercase().contains(&needle);
            let has_kept_child = rows.get(index + 1).is_some_and(|next| next.depth > rows[index].depth) && (index + 1..rows.len()).take_while(|later| rows[*later].depth > rows[index].depth).any(|later| keep[later]);
            keep[index] = matches || (!needle.is_empty() && has_kept_child);
        }
        // Hidden (ignored) folders take their contents with them.
        let mut result = Vec::new();
        let mut hidden_depth: Option<usize> = None;
        for (index, row) in rows.into_iter().enumerate() {
            if let Some(depth) = hidden_depth {
                if row.depth > depth {
                    continue;
                }
                hidden_depth = None;
            }
            if !visible[index] {
                hidden_depth = Some(row.depth);
                continue;
            }
            if keep[index] {
                result.push(row);
            }
        }
        result
    }

    /// The rows in view with their frames (for screen readers).
    pub fn visible_rows(&self) -> Vec<(Rect, &neolink_core::tree::Row)> {
        if !self.visible || self.row_height <= 0.0 {
            return Vec::new();
        }
        let top = self.rect.y + self.header_height;
        let bottom = self.rect.bottom() - FOOTER_POINTS * self.row_height / ROW_POINTS;
        let first = (self.drawn_scroll / self.row_height as f64).floor().max(0.0) as usize;
        let count = ((bottom - top) / self.row_height).ceil().max(0.0) as usize + 1;
        (first..(first + count).min(self.rows.len()))
            .map(|index| (Rect::new(self.rect.x, top + index as f32 * self.row_height - self.drawn_scroll as f32, self.rect.width, self.row_height), &self.rows[index]))
            .collect()
    }

    pub fn control_rect(&self, name: &str) -> Option<Rect> {
        if let Some(index) = name.strip_prefix("explorer-row:") {
            let index: usize = index.parse().ok()?;
            let y = self.rect.y + self.header_height + index as f32 * self.row_height - self.drawn_scroll as f32;
            return (index < self.rows.len()).then(|| Rect::new(self.rect.x, y, self.rect.width, self.row_height));
        }
        match name {
            "explorer-options" => Some(self.options_rect),
            "explorer-new" => Some(self.plus_rect),
            "explorer-filter" => Some(self.filter_rect),
            "explorer-refresh" => Some(self.refresh_rect),
            "explorer-follow" => Some(self.follow_rect),
            "explorer-name" => Some(self.name_rect),
            "explorer-collapse" => Some(self.collapse_rect),
            _ => None,
        }
    }

    /// The rows need recomputing (the filter or an option changed).
    pub fn mark_stale(&mut self) {
        self.stale = true;
    }

    pub fn compact(&self) -> bool {
        self.tree.compact
    }

    pub fn show_hidden(&self) -> bool {
        self.tree.show_hidden
    }

    pub fn toggle_compact(&mut self) {
        self.tree.compact = !self.tree.compact;
        self.stale = true;
    }

    pub fn toggle_hidden(&mut self) {
        self.tree.show_hidden = !self.tree.show_hidden;
        self.stale = true;
    }

    /// A key while the filter field has the keyboard. Returns `true` if it was used.
    pub fn filter_key(&mut self, key: &winit::keyboard::Key, text: Option<&str>) -> bool {
        use winit::keyboard::{Key, NamedKey};
        if !self.filter_focused {
            return false;
        }
        match key {
            Key::Named(NamedKey::Escape) => {
                self.filter.clear();
                self.filter_focused = false;
            }
            Key::Named(NamedKey::Enter) | Key::Named(NamedKey::Tab) => self.filter_focused = false,
            Key::Named(NamedKey::Backspace) => {
                self.filter.pop();
            }
            _ => match text {
                Some(text) if !text.chars().any(char::is_control) => self.filter.push_str(text),
                _ => return true,
            },
        }
        self.scroll = 0.0;
        self.stale = true;
        true
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
        if self.follow_rect.contains(x, y) {
            self.follow_terminal = !self.follow_terminal;
            self.revision += 1;
            return Clicked::Nothing;
        }
        self.filter_focused = self.filter_rect.contains(x, y);
        if self.filter_focused {
            return Clicked::Nothing;
        }
        if self.plus_rect.contains(x, y) {
            return Clicked::NewMenu(self.plus_rect);
        }
        if self.name_rect.contains(x, y) {
            return Clicked::FolderMenu(self.name_rect);
        }
        if self.options_rect.contains(x, y) {
            return Clicked::OptionsMenu(self.options_rect);
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
        let Some(row) = self.row_at(x, y).and_then(|index| self.rows.get(index)).cloned() else {
            self.focused = false;
            return Clicked::Nothing;
        };
        self.selected = Some(row.path.clone());
        self.focused = true;
        if self.missing.contains(&row.path) {
            return Clicked::Missing;
        }
        match row.kind {
            RowKind::File => Clicked::File(row.path),
            RowKind::Folder { .. } if self.folder_list => {
                self.navigate(&row.path);
                Clicked::Nothing
            }
            RowKind::Folder { .. } => {
                self.tree.toggle(&row.path);
                self.stale = true;
                Clicked::Nothing
            }
        }
    }

    /// Diagnostics to count on files and the folders above them.
    pub fn set_diagnostics(&mut self, diagnostics: Vec<(PathBuf, u64, u64)>) {
        if diagnostics != self.diagnostics {
            self.diagnostics = diagnostics;
            self.revision += 1;
        }
    }

    /// The folder a dropped file goes to: the folder row under `(x, y)`, the folder of a file row, or
    /// the tree's root.
    pub fn drop_target(&self, x: f32, y: f32) -> PathBuf {
        match self.row_under(x, y) {
            Some((path, true)) => path,
            Some((path, false)) => path.parent().map(Path::to_path_buf).unwrap_or_else(|| self.tree.root().to_path_buf()),
            None => self.tree.root().to_path_buf(),
        }
    }

    /// The row under `(x, y)`: its path and whether it is a folder.
    pub fn row_under(&self, x: f32, y: f32) -> Option<(PathBuf, bool)> {
        let row = self.rows.get(self.row_at(x, y)?)?;
        Some((row.path.clone(), matches!(row.kind, RowKind::Folder { .. })))
    }

    /// A key while the tree has the keyboard (`ExplorerTableView.keyDown`): arrows move and open or
    /// close, Return activates. `None` if the key is not the tree's.
    pub fn key(&mut self, key: &winit::keyboard::Key) -> Option<Clicked> {
        use winit::keyboard::{Key, NamedKey};
        if !self.focused || !self.visible || self.rows.is_empty() {
            return None;
        }
        let current = self.selected.as_ref().and_then(|path| self.rows.iter().position(|row| &row.path == path));
        let mut result = Clicked::Nothing;
        let mut target = current;
        match key {
            Key::Named(NamedKey::ArrowDown) => target = Some(current.map_or(0, |index| (index + 1).min(self.rows.len() - 1))),
            Key::Named(NamedKey::ArrowUp) => target = Some(current.map_or(0, |index| index.saturating_sub(1))),
            Key::Named(NamedKey::ArrowLeft) if self.folder_list => {
                if let Some(parent) = self.tree.root().parent().map(Path::to_path_buf) {
                    self.navigate(&parent);
                }
                return Some(Clicked::Nothing);
            }
            Key::Named(NamedKey::Enter) | Key::Named(NamedKey::ArrowRight) if self.folder_list => {
                let row = self.rows.get(current?)?.clone();
                match row.kind {
                    RowKind::File if matches!(key, Key::Named(NamedKey::Enter)) => result = Clicked::File(row.path),
                    RowKind::Folder { .. } => {
                        self.navigate(&row.path);
                        return Some(Clicked::Nothing);
                    }
                    _ => {}
                }
            }
            Key::Named(NamedKey::Enter) => {
                let row = self.rows.get(current?)?.clone();
                match row.kind {
                    RowKind::File => result = Clicked::File(row.path),
                    RowKind::Folder { .. } => {
                        self.tree.toggle(&row.path);
                        self.stale = true;
                    }
                }
            }
            Key::Named(NamedKey::ArrowRight) | Key::Named(NamedKey::ArrowLeft) => {
                let row = self.rows.get(current?)?.clone();
                let right = matches!(key, Key::Named(NamedKey::ArrowRight));
                match row.kind {
                    RowKind::Folder { expanded, .. } if expanded != right => {
                        self.tree.toggle(&row.path);
                        self.stale = true;
                    }
                    RowKind::Folder { .. } if right => target = Some((current? + 1).min(self.rows.len() - 1)),
                    _ if !right => {
                        // To the enclosing folder's row.
                        target = (0..current?).rev().find(|index| self.rows[*index].depth < row.depth).or(current);
                    }
                    _ => {}
                }
            }
            Key::Named(NamedKey::Escape) => self.focused = false,
            _ => return None,
        }
        if let Some(index) = target {
            self.selected = Some(self.rows[index].path.clone());
            // Keep the row in view.
            let (top, height) = (index as f64 * self.row_height as f64, self.row_height as f64);
            let visible = (self.rect.height - self.header_height - FOOTER_POINTS * self.row_height / ROW_POINTS) as f64;
            if top < self.scroll {
                self.scroll = top;
            } else if top + height > self.scroll + visible {
                self.scroll = top + height - visible;
            }
            self.smoother.cancel();
        }
        self.revision += 1;
        Some(result)
    }

    /// Opens or closes a folder.
    pub fn toggle(&mut self, path: &Path) {
        self.tree.toggle(path);
        self.stale = true;
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
        self.revision ^ (self.filter.len() as u64).rotate_left(50) ^ ((self.filter_focused as u64) << 58) ^ (self.drawn_scroll.to_bits().rotate_left(17)) ^ (self.hover.map_or(u64::MAX, |index| index as u64) << 40) ^ self.visible as u64 ^ ((self.focused as u64) << 59) ^ ((self.folder_list as u64) << 60) ^ (self.sort as u64).rotate_left(44)
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

        // Nothing that decides the pane's pixels changed: draw the same instances again.
        let key = {
            use std::hash::{Hash, Hasher};
            let mut hasher = std::collections::hash_map::DefaultHasher::new();
            (self.signature(), rect.x.to_bits(), rect.y.to_bits(), rect.width.to_bits(), rect.height.to_bits(), scale.to_bits(), active, &self.selected, self.rows.len()).hash(&mut hasher);
            hasher.finish()
        };
        if let Some((drawn_key, saved)) = &self.drawn {
            if *drawn_key == key {
                painter.scene.replay(saved);
                return self.next_frame(display, period);
            }
        }
        let mark = painter.scene.mark();

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
        self.plus_rect = Rect::new(rect.x + inset, bar_top, slot, ui.px(24.0));
        ui.icon("plus", 12.0, IconWeight::Regular, rect.x + inset + slot * 0.5, bar_middle, theme::TEXT_SECONDARY);
        let name = self.tree.root().file_name().and_then(|name| name.to_str()).unwrap_or("Macintosh HD").to_string();
        let mut right = rect.right() - inset;
        self.options_rect = Rect::new(right - slot, bar_top, slot, ui.px(24.0));
        ui.icon("line.3.horizontal.decrease.circle", 12.0, IconWeight::Regular, right - slot * 0.5, bar_middle, theme::TEXT_SECONDARY);
        right -= slot + ui.px(8.0);
        self.refresh_rect = Rect::new(right - slot, bar_top, slot, ui.px(24.0));
        ui.icon("arrow.clockwise", 12.0, IconWeight::Regular, right - slot * 0.5, bar_middle, theme::TEXT_SECONDARY);
        right -= slot + ui.px(8.0);
        self.collapse_rect = Rect::new(right - slot, bar_top, slot, ui.px(24.0));
        ui.icon("rectangle.compress.vertical", 12.0, IconWeight::Regular, right - slot * 0.5, bar_middle, theme::TEXT_SECONDARY);
        right -= slot + ui.px(8.0);
        let name_x = rect.x + inset + slot + ui.px(8.0);
        let fitted = ui.fit_middle(&name, (right - name_x - ui.px(14.0)).max(1.0), 12.0, 600, false);
        let name_width = ui.text(&fitted, name_x, bar_middle, 12.0, 600, false, theme::TEXT_SECONDARY);
        ui.icon("chevron.down", 7.0, IconWeight::Semibold, name_x + name_width + ui.px(7.0), bar_middle, theme::TEXT_SECONDARY);
        self.name_rect = Rect::new(name_x - ui.px(4.0), bar_top, name_width + ui.px(18.0), ui.px(24.0));
        // Filter field (not editable yet: PLAN.md).
        let field = Rect::new(rect.x + inset, bar_top + ui.px(24.0 + 6.0), rect.width - 2.0 * inset, ui.px(27.0));
        ui.rounded(field, 4.0, theme::rgb(0x161616));
        ui.outline(field, 4.0, theme::white(0.09));
        let field_middle = field.y + field.height * 0.5;
        let glass = ui.icon("magnifyingglass", 11.0, IconWeight::Regular, field.x + ui.px(9.0 + 6.0), field_middle, theme::TEXT_SECONDARY);
        self.filter_rect = field;
        let text_x = field.x + ui.px(9.0) + glass.max(ui.px(12.0)) + ui.px(7.0);
        if self.filter.is_empty() && !self.filter_focused {
            ui.text(if self.folder_list { "Filter files\u{2026}" } else { "Filter tree\u{2026}" }, text_x, field_middle, 11.0, 400, false, faded(theme::TEXT_SECONDARY, 0.7));
        } else {
            let filter = self.filter.clone();
            let width = ui.text(&filter, text_x, field_middle, 11.0, 400, false, theme::TEXT_PRIMARY);
            if self.filter_focused {
                ui.painter.scene.fill(text_x + width + line, field_middle - ui.px(7.0), line.max(2.0), ui.px(14.0), theme::ACCENT);
            }
        }
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
            if is_active || (self.focused && self.selected.as_deref() == Some(row.path.as_path())) {
                ui.painter.scene.fill(rect.x, y, rect.width, self.row_height, theme::SELECTION);
            } else if self.hover == Some(index) {
                ui.painter.scene.fill(rect.x, y, rect.width, self.row_height, theme::HOVER);
            }
            let status = self.git.status(&row.path);
            let opacity = if status == Some(Status::Ignored) { 0.55 } else { 1.0 };
            let x = rect.x + ui.px(8.0 + row.depth as f32 * 12.0);
            // Indent guides: a faint line under each enclosing folder's chevron, so nested rows read
            // as belonging to their folder.
            if !self.folder_list {
                let line = ui.px(1.0).max(1.0).round();
                for level in 0..row.depth {
                    let guide = (rect.x + ui.px(8.0 + level as f32 * 12.0 + 5.0)).round();
                    ui.painter.scene.fill(guide, y, line, self.row_height, theme::white(0.06));
                }
            }
            let is_folder = !matches!(row.kind, RowKind::File);
            if let RowKind::Folder { expanded, .. } = row.kind {
                if !self.folder_list {
                    ui.icon(if expanded { "chevron.down" } else { "chevron.right" }, 8.0, IconWeight::Regular, x + ui.px(5.0), row_middle, faded(theme::TEXT_SECONDARY, opacity));
                }
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
            // Diagnostics of this file, or of everything open beneath this folder.
            let (mut found, mut errors) = (0u64, 0u64);
            for (path, count, error_count) in &self.diagnostics {
                if *path == row.path || (is_folder && path.starts_with(&row.path)) {
                    found += count;
                    errors += error_count;
                }
            }
            if found > 0 {
                let color = if errors > 0 { theme::rgb(0xCC9595) } else { theme::rgb(0xC6B28E) };
                right -= ui.text_right(&found.to_string(), right, row_middle, 10.0, 500, true, color) + ui.px(7.0);
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
        let follow_color = if self.follow_terminal { theme::ACCENT } else { theme::TEXT_SECONDARY };
        let link = ui.icon(if self.follow_terminal { "link" } else { "link.badge.plus" }, 10.0, IconWeight::Regular, rect.x + inset + ui.px(7.0), footer_middle, follow_color);
        let follow_width = ui.text(if self.follow_terminal { "Following terminal" } else { "Follow terminal" }, rect.x + inset + link.max(ui.px(14.0)) + ui.px(4.0), footer_middle, 10.0, 400, false, follow_color);
        self.follow_rect = Rect::new(rect.x + inset, footer.y, link.max(ui.px(14.0)) + ui.px(8.0) + follow_width, footer.height);
        let summary = if self.folder_list {
            format!("{} items", self.rows.len())
        } else if self.tree.was_truncated() {
            "Tree limit \u{b7} use \u{2318}P".to_string()
        } else {
            format!("{} visible", self.rows.len())
        };
        ui.text_right(&summary, rect.right() - inset, footer_middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        // The split view's divider.
        ui.painter.scene.fill(rect.right(), rect.y, line, rect.height, theme::SEPARATOR);
        self.drawn = Some((key, painter.scene.capture(mark)));
        self.next_frame(display, period)
    }

    /// The sprites the drawn pane refers to are gone (the text size changed).
    pub fn forget_drawing(&mut self) {
        self.drawn = None;
    }

    fn next_frame(&self, display: f64, period: f64) -> Next {
        match self.smoother.next_visible_change(display, period, self.scroll) {
            None => Next::Idle,
            Some(at) if at <= display + 1.5 * period => Next::Soon,
            Some(at) => Next::At(at),
        }
    }

}
