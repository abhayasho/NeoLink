//! The window's content: a strip of tabs over the active pane. Panes stay alive when they are not shown;
//! switching is drawing a different pane into the same surface.

use crate::chrome::{faded, Ui};
use crate::editor::Editor;
use crate::icons::IconWeight;
use crate::menu::{Action, Item, Menu};
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

/// The sheet that asks for a new item's name, or a new name for an existing one
/// (`LocalFileBrowserView`'s creation and rename sheets).
struct Creation {
    directory: std::path::PathBuf,
    is_directory: bool,
    /// The item being renamed, if this is the rename sheet.
    rename: Option<std::path::PathBuf>,
    name: String,
    cancel: Rect,
    create: Rect,
}

use neolink_core::files::valid_name;

/// The "Save changes?" alert shown before a document with unsaved changes closes.
struct Closing {
    path: String,
    /// Close the window once this document is dealt with.
    buttons: Vec<(Rect, &'static str)>,
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
    menu: Option<Menu>,
    /// The "New File" / "New Folder" sheet, while it is open.
    creation: Option<Creation>,
    closing: Option<Closing>,
    /// A file or folder copied in the explorer ("Copy", then "Paste Here").
    copied: Option<std::path::PathBuf>,
    /// The explorer's width in points, and whether its edge is being dragged.
    explorer_points: f32,
    dragging_divider: bool,
    /// Quick Open or Find in Files, while it is open.
    search: Option<crate::search::SearchSheet>,
    /// Source Control, while it is open; and how many repository snapshots the explorer has seen.
    git: Option<crate::gitview::GitSheet>,
    git_seen: u64,
    /// Clickable parts of the editor toolbar: `(where, what)`.
    toolbar_buttons: Vec<(Rect, &'static str)>,
    window: (f32, f32),
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
            menu: None,
            creation: None,
            closing: None,
            copied: None,
            explorer_points: crate::explorer::WIDTH_POINTS,
            dragging_divider: false,
            search: None,
            git: None,
            git_seen: 0,
            toolbar_buttons: Vec::new(),
            window: (size.0 as f32, size.1 as f32),
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
        let explorer_width = if self.explorer.visible { px(self.explorer_points).min(width * 0.5) } else { 0.0 };
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

    /// Closes a tab; a document with unsaved changes asks first.
    pub fn close_tab(&mut self, index: usize) {
        if index >= self.tabs.len() {
            return;
        }
        if let Some(path) = self.tabs[index].document().map(str::to_string) {
            if self.editor.as_ref().is_some_and(|editor| editor.is_modified(&path)) {
                self.select(index);
                self.closing = Some(Closing { path, buttons: Vec::new() });
                return;
            }
        }
        self.force_close(index);
    }

    fn force_close(&mut self, index: usize) {
        if index >= self.tabs.len() {
            return;
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

    /// Selects the tab after (`step` 1) or before (-1) the active one, wrapping round.
    pub fn step_tab(&mut self, step: isize) {
        let count = self.tabs.len() as isize;
        if count > 1 {
            self.select((self.active as isize + step).rem_euclid(count) as usize);
        }
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
            // `onChange(of: activeFileURL)`: the tree follows the active file while the option is on.
            if self.explorer.reveal_active {
                self.explorer.reveal(std::path::Path::new(&path));
            }
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
        if let Some(git) = &mut self.git {
            git.scroll(self.pointer.0, self.pointer.1, _delta_x as f32 * self.scale, delta_y as f32 * self.scale);
            return;
        }
        if self.scroll_search((delta_y as f32) * self.scale) {
            return;
        }
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

    /// The middle of a named control, for synthetic presses (see `bench::Injected::Control`).
    pub fn control_point(&self, name: &str) -> Option<(f32, f32)> {
        let middle = |rect: Rect| (rect.x + rect.width * 0.5, rect.y + rect.height * 0.5);
        if let Some(index) = name.strip_prefix("menu:") {
            return self.menu.as_ref()?.item_rect(index.parse().ok()?).map(middle);
        }
        if let Some(creation) = &self.creation {
            match name {
                "sheet-create" => return Some(middle(creation.create)),
                "sheet-cancel" => return Some(middle(creation.cancel)),
                _ => {}
            }
        }
        if let (Some(part), Some(closing)) = (name.strip_prefix("closing:"), &self.closing) {
            return closing.buttons.iter().find(|(_, what)| *what == part).map(|(rect, _)| middle(*rect));
        }
        if let Some(part) = name.strip_prefix("git:") {
            return self.git.as_ref()?.control_rect(part).map(middle);
        }
        if let Some((rect, _)) = self.header_buttons.iter().find(|(_, action)| *action == name) {
            return Some(middle(*rect));
        }
        if let Some(rect) = self.explorer.control_rect(name) {
            return Some(middle(rect));
        }
        self.toolbar_buttons.iter().find(|(_, what)| *what == name).map(|(rect, _)| middle(*rect))
    }

    /// A key for the chrome (an open menu, the filter field). Returns `true` if it was used.
    pub fn key_for_chrome(&mut self, key: &winit::keyboard::Key, text: Option<&str>) -> bool {
        use winit::keyboard::{Key, NamedKey};
        if self.menu.is_some() {
            if matches!(key, Key::Named(NamedKey::Escape)) {
                self.menu = None;
            }
            return true;
        }
        if self.closing.is_some() {
            match key {
                Key::Named(NamedKey::Escape) => self.answer_closing("cancel"),
                Key::Named(NamedKey::Enter) => self.answer_closing("save"),
                _ => {}
            }
            return true;
        }
        if self.git.is_some() {
            let unsaved = self.any_unsaved();
            let outcome = self.git.as_mut().map(|git| git.key(key, text, unsaved));
            if let Some(outcome) = outcome {
                self.git_outcome(outcome);
            }
            return true;
        }
        if let Some(search) = &mut self.search {
            let outcome = search.key(key, text);
            self.search_outcome(outcome);
            return true;
        }
        if let Some(creation) = &mut self.creation {
            match key {
                Key::Named(NamedKey::Escape) => self.creation = None,
                Key::Named(NamedKey::Enter) => self.create_item(),
                Key::Named(NamedKey::Backspace) => {
                    creation.name.pop();
                }
                _ => {
                    if let Some(text) = text.filter(|text| !text.chars().any(char::is_control)) {
                        creation.name.push_str(text);
                    }
                }
            }
            return true;
        }
        if self.explorer.filter_key(key, text) {
            return true;
        }
        match self.explorer.key(key) {
            Some(crate::explorer::Clicked::File(file)) => {
                self.open_document(&file);
                true
            }
            Some(_) => true,
            None => false,
        }
    }

    /// Opens Source Control for the project.
    pub fn open_git(&mut self) {
        self.menu = None;
        self.search = None;
        self.git = Some(crate::gitview::GitSheet::new(self.explorer.root(), self.shared.clone()));
        self.git_seen = 0;
    }

    /// Some document has changes that are not on disk.
    fn any_unsaved(&self) -> bool {
        let Some(editor) = &self.editor else { return false };
        self.tabs.iter().filter_map(|tab| tab.document()).any(|path| editor.is_modified(path))
    }

    fn git_outcome(&mut self, outcome: crate::gitview::Outcome) {
        match outcome {
            crate::gitview::Outcome::Stay => {}
            crate::gitview::Outcome::Close => {
                self.git = None;
                self.explorer.refresh();
            }
            crate::gitview::Outcome::Open(path) => {
                self.git = None;
                self.explorer.refresh();
                self.open_document(&path);
            }
            crate::gitview::Outcome::Menu(menu) => self.menu = Some(menu),
        }
    }

    /// Opens Quick Open (`contents` false) or Find in Files.
    pub fn open_search(&mut self, contents: bool) {
        self.menu = None;
        self.search = Some(crate::search::SearchSheet::new(self.explorer.root(), contents, self.shared.clone()));
    }

    pub fn search_is_open(&self) -> bool {
        self.search.is_some()
    }

    /// Scrolls the search results. Returns `false` if no search is open.
    pub fn scroll_search(&mut self, delta: f32) -> bool {
        match &mut self.search {
            Some(search) => {
                search.scroll(delta);
                true
            }
            None => false,
        }
    }

    fn search_outcome(&mut self, outcome: crate::search::Outcome) {
        match outcome {
            crate::search::Outcome::Stay => {}
            crate::search::Outcome::Close => self.search = None,
            crate::search::Outcome::Open(path, line) => {
                self.search = None;
                self.open_document(&path);
                if let (Some(line), Some(editor)) = (line, &self.editor) {
                    // Typed after the switch is confirmed (the client holds input until then).
                    editor.input(&format!("<C-o>{line}G<C-o>zz"));
                }
            }
        }
    }

    /// Puts the keyboard in the explorer's filter field (Cmd-P).
    pub fn focus_filter(&mut self) {
        self.explorer.visible = true;
        self.explorer.filter_focused = true;
    }

    /// Creates what the sheet names; a new file is opened, as in the Swift app.
    fn create_item(&mut self) {
        let Some(creation) = self.creation.take_if(|creation| valid_name(&creation.name)) else { return };
        if let Some(source) = &creation.rename {
            match neolink_core::files::rename(source, &creation.name) {
                Ok(_) => self.explorer.refresh(),
                Err(error) => self.notice = Some(error),
            }
            return;
        }
        match neolink_core::files::create(&creation.directory, &creation.name, creation.is_directory) {
            Ok(path) => {
                self.explorer.refresh();
                if !creation.is_directory {
                    self.open_document(&path);
                }
            }
            Err(error) => self.notice = Some(error),
        }
    }

    fn draw_creation(&mut self, painter: &mut Painter) {
        let Some(mut creation) = self.creation.take() else { return };
        let mut ui = Ui { painter, scale: self.scale };
        ui.fill(Rect::new(0.0, 0.0, self.window.0, self.window.1), [0, 0, 0, 90]);
        let renaming = creation.rename.is_some();
        let (width, height, pad) = if renaming { (ui.px(340.0), ui.px(140.0), ui.px(24.0)) } else { (ui.px(360.0), ui.px(168.0), ui.px(24.0)) };
        let sheet = Rect::new(((self.window.0 - width) * 0.5).round(), ui.px(34.0), width, height);
        let line = ui.px(1.0).max(1.0);
        ui.shadow(sheet, 10.0);
        ui.rounded(sheet, 10.0, theme::rgb(0x262626));
        ui.outline(sheet, 10.0, theme::white(0.14));
        let left = sheet.x + pad;
        let mut y = sheet.y + pad + ui.px(9.0);
        if renaming {
            ui.text("Rename item", left, y, 13.0, 600, false, theme::TEXT_PRIMARY);
            y += ui.px(26.0);
        } else {
            let icon = ui.icon(if creation.is_directory { "folder.badge.plus" } else { "doc.badge.plus" }, 13.0, IconWeight::Semibold, left + ui.px(9.0), y, theme::TEXT_PRIMARY).max(ui.px(18.0));
            ui.text(if creation.is_directory { "New Folder" } else { "New File" }, left + icon + ui.px(6.0), y, 13.0, 600, false, theme::TEXT_PRIMARY);
            y += ui.px(28.0);
            let directory = creation.directory.display().to_string();
            let shown = ui.fit_middle(&directory, width - 2.0 * pad, 10.0, 400, false);
            ui.text(&shown, left, y, 10.0, 400, false, theme::TEXT_SECONDARY);
            y += ui.px(16.0);
        }
        let field = Rect::new(left, y, width - 2.0 * pad, ui.px(22.0));
        ui.rounded(field, 5.0, theme::rgb(0x1A1A1A));
        ui.outline(field, 5.0, theme::rgb(0x2F6FDB));
        let middle = field.y + field.height * 0.5;
        if creation.name.is_empty() {
            ui.text(if renaming { "Name" } else if creation.is_directory { "Folder name" } else { "File name, e.g. main.py" }, field.x + ui.px(6.0), middle, 12.0, 400, false, faded(theme::TEXT_SECONDARY, 0.7));
            ui.painter.scene.fill(field.x + ui.px(5.0), middle - ui.px(7.0), line.max(2.0), ui.px(14.0), theme::ACCENT);
        } else {
            let end = ui.text(&creation.name, field.x + ui.px(6.0), middle, 12.0, 400, false, theme::TEXT_PRIMARY);
            ui.painter.scene.fill(field.x + ui.px(6.0) + end + line, middle - ui.px(7.0), line.max(2.0), ui.px(14.0), theme::ACCENT);
        }
        let button_y = sheet.bottom() - pad - ui.px(22.0);
        let valid = valid_name(&creation.name);
        let confirm = if renaming { "Rename" } else { "Create" };
        let create_width = ui.measure(confirm, 12.0, 500, false) + ui.px(24.0);
        creation.create = Rect::new(sheet.right() - pad - create_width, button_y, create_width, ui.px(22.0));
        ui.rounded(creation.create, 5.0, if valid { theme::rgb(0x2F6FDB) } else { theme::rgb(0x333333) });
        ui.text(confirm, creation.create.x + ui.px(12.0), button_y + ui.px(11.0), 12.0, 500, false, if valid { theme::rgb(0xFFFFFF) } else { theme::TEXT_SECONDARY });
        let cancel_width = ui.measure("Cancel", 12.0, 500, false) + ui.px(24.0);
        creation.cancel = Rect::new(creation.create.x - ui.px(8.0) - cancel_width, button_y, cancel_width, ui.px(22.0));
        ui.rounded(creation.cancel, 5.0, theme::rgb(0x3A3A3A));
        ui.text("Cancel", creation.cancel.x + ui.px(12.0), button_y + ui.px(11.0), 12.0, 500, false, theme::TEXT_PRIMARY);
        self.creation = Some(creation);
    }

    fn begin_create(&mut self, is_directory: bool) {
        let directory = self.explorer.root().to_path_buf();
        self.begin_create_in(directory, is_directory);
    }

    fn begin_create_in(&mut self, directory: std::path::PathBuf, is_directory: bool) {
        self.creation = Some(Creation { directory, is_directory, rename: None, name: String::new(), cancel: Rect::default(), create: Rect::default() });
    }

    /// Opens a local shell tab in `directory`.
    fn open_terminal_in(&mut self, directory: std::path::PathBuf) {
        let Some(shared) = self.shared.upgrade() else { return };
        let id = self.next_id;
        self.next_id += 1;
        match Terminal::spawn(&shared, self.grid.0, self.grid.1, self.cell, Some(directory), id) {
            Ok(terminal) => {
                self.tabs.push(Tab { id, pane: Pane::Terminal(terminal) });
                self.select(self.tabs.len() - 1);
            }
            Err(error) => self.notice = Some(format!("Could not start a shell: {error}")),
        }
    }

    /// One choice from an explorer row's context menu (`LocalFileBrowserView.contextMenu`).
    fn file_action(&mut self, what: &str, path: std::path::PathBuf, is_directory: bool) {
        let folder = if is_directory { path.clone() } else { path.parent().map(std::path::Path::to_path_buf).unwrap_or_default() };
        let copy_text = |text: String| {
            if let Ok(mut clipboard) = arboard::Clipboard::new() {
                let _ = clipboard.set_text(text);
            }
        };
        let launch = |program: &str, arguments: &[&std::ffi::OsStr]| {
            let _ = std::process::Command::new(program).args(arguments).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).spawn();
        };
        match what {
            "open" if is_directory => self.explorer.toggle(&path),
            "open" => self.open_document(&path),
            "new-file" => self.begin_create_in(folder, false),
            "new-folder" => self.begin_create_in(folder, true),
            "default-app" => {
                if cfg!(target_os = "macos") {
                    launch("open", &[path.as_os_str()]);
                } else if cfg!(windows) {
                    launch("cmd", &[std::ffi::OsStr::new("/C"), std::ffi::OsStr::new("start"), std::ffi::OsStr::new(""), path.as_os_str()]);
                } else {
                    launch("xdg-open", &[path.as_os_str()]);
                }
            }
            "show" => {
                if cfg!(target_os = "macos") {
                    launch("open", &[std::ffi::OsStr::new("-R"), path.as_os_str()]);
                } else if cfg!(windows) {
                    let mut argument = std::ffi::OsString::from("/select,");
                    argument.push(path.as_os_str());
                    launch("explorer", &[argument.as_os_str()]);
                } else {
                    launch("xdg-open", &[folder.as_os_str()]);
                }
            }
            "terminal" => self.open_terminal_in(folder),
            "reveal" => {
                if let Some(active) = self.active_document() {
                    self.explorer.reveal(std::path::Path::new(&active));
                }
            }
            "copy-path" => copy_text(path.display().to_string()),
            "copy-relative" => copy_text(path.strip_prefix(self.explorer.root()).unwrap_or(&path).display().to_string().replace('\\', "/")),
            "copy" => self.copied = Some(path),
            "paste" => {
                if let Some(source) = self.copied.clone() {
                    match neolink_core::files::copy_into(&source, &folder) {
                        Ok(_) => self.explorer.refresh(),
                        Err(error) => self.notice = Some(error),
                    }
                }
            }
            "rename" => {
                let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
                self.creation = Some(Creation { directory: folder, is_directory, rename: Some(path), name, cancel: Rect::default(), create: Rect::default() });
            }
            "trash" => match trash::delete(&path) {
                Ok(()) => self.explorer.refresh(),
                Err(error) => self.notice = Some(format!("Could not move to the Trash: {error}")),
            },
            _ => {}
        }
    }

    /// A secondary click at `(x, y)`. Returns `true` if it opened a menu.
    pub fn right_click(&mut self, x: f32, y: f32) -> bool {
        if self.menu.is_some() || self.creation.is_some() || self.closing.is_some() || self.search.is_some() || self.git.is_some() {
            return false;
        }
        let Some((path, is_directory)) = self.explorer.row_under(x, y) else { return false };
        self.explorer.selected = Some(path.clone());
        self.explorer.focused = true;
        let entry = |label: &str, what: &'static str| Item::entry(label, Action::File(what, path.clone(), is_directory));
        let mut items = vec![entry(if is_directory { "Browse This Folder" } else { "Open in Tab" }, "open")];
        if is_directory {
            items.push(entry("New File Here\u{2026}", "new-file"));
            items.push(entry("New Folder Here\u{2026}", "new-folder"));
        } else {
            items.push(entry("Open in Default App", "default-app"));
        }
        items.push(entry(if cfg!(target_os = "macos") { "Show in Finder" } else { "Show in File Manager" }, "show"));
        items.push(entry("Open in Integrated Terminal", "terminal"));
        items.push(if self.active_document().is_some() { entry("Reveal Active File", "reveal") } else { Item::note("Reveal Active File") });
        items.push(Item::Separator);
        items.push(entry("Copy Path", "copy-path"));
        items.push(entry("Copy Relative Path", "copy-relative"));
        items.push(Item::Separator);
        items.push(entry("Copy", "copy"));
        if self.copied.is_some() {
            items.push(entry("Paste Here", "paste"));
        }
        items.push(entry("Rename\u{2026}", "rename"));
        items.push(Item::Separator);
        items.push(entry(if cfg!(target_os = "macos") { "Move to Trash" } else { "Move to Recycle Bin" }, "trash"));
        let line = self.scale.max(1.0);
        self.menu = Some(Menu::new(Rect::new(x, y - line, line, line), items));
        true
    }

    /// Which pointer the window should show at `(x, y)`: `true` for the column-resize arrows.
    pub fn wants_resize_cursor(&self, x: f32, y: f32) -> bool {
        self.dragging_divider || self.over_divider(x, y)
    }

    fn over_divider(&self, x: f32, y: f32) -> bool {
        let reach = 3.0 * self.scale;
        self.explorer.visible && self.menu.is_none() && self.creation.is_none() && self.search.is_none() && self.git.is_none() && self.closing.is_none() && (x - self.sidebar.right()).abs() <= reach && y >= self.sidebar.y && y < self.sidebar.bottom()
    }

    /// Asks before closing a document with unsaved changes (`TabsController.confirmClose`).
    fn draw_closing(&mut self, painter: &mut Painter) {
        let Some(mut closing) = self.closing.take() else { return };
        let mut ui = Ui { painter, scale: self.scale };
        ui.fill(Rect::new(0.0, 0.0, self.window.0, self.window.1), [0, 0, 0, 90]);
        let (width, height, pad) = (ui.px(260.0), ui.px(202.0), ui.px(16.0));
        let alert = Rect::new(((self.window.0 - width) * 0.5).round(), ((self.window.1 - height) * 0.4).round(), width, height);
        ui.shadow(alert, 12.0);
        ui.rounded(alert, 12.0, theme::rgb(0x262626));
        ui.outline(alert, 12.0, theme::white(0.14));
        let name = std::path::Path::new(&closing.path).file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
        let title = format!("Save changes to \u{201c}{name}\u{201d}?");
        let title = ui.fit_middle(&title, width - 2.0 * pad, 13.0, 700, false);
        let title_width = ui.measure(&title, 13.0, 700, false);
        ui.text(&title, alert.x + (width - title_width) * 0.5, alert.y + pad + ui.px(10.0), 13.0, 700, false, theme::TEXT_PRIMARY);
        for (index, text) in ["Your changes will be lost if you close", "without saving."].into_iter().enumerate() {
            let text_width = ui.measure(text, 11.0, 400, false);
            ui.text(text, alert.x + (width - text_width) * 0.5, alert.y + pad + ui.px(36.0 + index as f32 * 15.0), 11.0, 400, false, theme::TEXT_PRIMARY);
        }
        closing.buttons.clear();
        let mut y = alert.y + pad + ui.px(72.0);
        for (label, what, prominent) in [("Save", "save", true), ("Cancel", "cancel", false), ("Don\u{2019}t Save", "discard", false)] {
            let button = Rect::new(alert.x + pad, y, width - 2.0 * pad, ui.px(28.0));
            ui.rounded(button, 6.0, if prominent { theme::rgb(0x2F6FDB) } else { theme::rgb(0x3A3A3A) });
            let label_width = ui.measure(label, 13.0, 500, false);
            ui.text(label, button.x + (button.width - label_width) * 0.5, button.y + button.height * 0.5, 13.0, 500, false, if prominent { theme::rgb(0xFFFFFF) } else { theme::TEXT_PRIMARY });
            closing.buttons.push((button, what));
            y += ui.px(28.0 + 8.0);
        }
        self.closing = Some(closing);
    }

    /// Answers the "Save changes?" alert.
    fn answer_closing(&mut self, what: &str) {
        let Some(closing) = self.closing.take() else { return };
        let Some(index) = self.tabs.iter().position(|tab| tab.document() == Some(closing.path.as_str())) else { return };
        match what {
            "save" => {
                if let Some(editor) = &self.editor {
                    editor.command("save", &closing.path);
                }
                self.force_close(index);
            }
            "discard" => self.force_close(index),
            _ => {}
        }
    }

    fn perform(&mut self, action: Action) {
        match action {
            Action::Editor(name) => self.editor_action(name),
            Action::TextSize(points) => self.set_font_points(points),
            Action::TextSizeBy(delta) => self.set_font_points(self.font_points + delta),
            Action::ToggleCompact => self.explorer.toggle_compact(),
            Action::ToggleHidden => self.explorer.toggle_hidden(),
            Action::ToggleHideIgnored => {
                self.explorer.hide_ignored = !self.explorer.hide_ignored;
                self.explorer.mark_stale();
            }
            Action::ToggleReveal => self.explorer.reveal_active = !self.explorer.reveal_active,
            Action::NewFile => self.begin_create(false),
            Action::NewFolder => self.begin_create(true),
            Action::File(what, path, is_directory) => self.file_action(what, path, is_directory),
            Action::GitCreateBranch | Action::GitSwitch(_) | Action::GitStash(_) => {
                let unsaved = self.any_unsaved();
                if let Some(git) = &mut self.git {
                    git.perform(&action, unsaved);
                }
            }
            Action::Nothing => {}
        }
    }

    /// Saves the active document and runs it in a new terminal, as the Swift app's Run button does.
    pub fn run_active(&mut self) {
        let Some(path) = self.active_document() else { return };
        let file = std::path::Path::new(&path);
        let runner = match file.extension().and_then(|extension| extension.to_str()).unwrap_or("").to_lowercase().as_str() {
            "py" => "python3",
            "js" | "mjs" => "node",
            "swift" => "swift",
            "sh" => "bash",
            "rb" => "ruby",
            "lua" => "lua",
            "go" => "go",
            _ => {
                self.notice = Some("There is no runner for this kind of file.".into());
                return;
            }
        };
        self.save_active();
        let quote = |text: &str| format!("'{}'", text.replace('\'', "'\\''"));
        let directory = file.parent().map(|parent| parent.display().to_string()).unwrap_or_default();
        let go = if runner == "go" { " run " } else { " " };
        let command = format!("cd -- {} && {}{}{}\r", quote(&directory), quote(runner), go, quote(&path));
        if let Some(shared) = self.shared.upgrade() {
            if self.new_tab(&shared).is_ok() {
                self.write(command.into_bytes());
            }
        }
    }

    /// A press at `(x, y)` device pixels. Returns `true` if it changed anything.
    pub fn click(&mut self, x: f32, y: f32) -> bool {
        if let Some(menu) = self.menu.take() {
            if let Some(action) = menu.action_at(x, y) {
                self.perform(action);
            } else if menu.contains(x, y) {
                self.menu = Some(menu);
            }
            return true;
        }
        if let Some(closing) = &self.closing {
            if let Some((_, what)) = closing.buttons.iter().find(|(rect, _)| rect.contains(x, y)).copied() {
                self.answer_closing(what);
            }
            return true;
        }
        if self.git.is_some() {
            let unsaved = self.any_unsaved();
            let outcome = self.git.as_mut().map(|git| git.click(x, y, unsaved));
            if let Some(outcome) = outcome {
                self.git_outcome(outcome);
            }
            return true;
        }
        if let Some(search) = &mut self.search {
            let outcome = search.click(x, y);
            self.search_outcome(outcome);
            return true;
        }
        if let Some(creation) = &self.creation {
            if creation.cancel.contains(x, y) {
                self.creation = None;
            } else if creation.create.contains(x, y) {
                self.create_item();
            }
            return true;
        }
        if self.over_divider(x, y) {
            self.dragging_divider = true;
            return true;
        }
        if !self.explorer.contains(x, y) {
            self.explorer.filter_focused = false;
            self.explorer.focused = false;
        }
        if self.shown == self.active && self.active_is_document() {
            if let Some((rect, what)) = self.toolbar_buttons.iter().find(|(rect, _)| rect.contains(x, y)).copied() {
                match what {
                    "save" => self.save_active(),
                    "run" => self.run_active(),
                    "diagnostics" => self.editor_action("diagnostics"),
                    "size" => {
                        let mut items = vec![Item::entry("Increase Text Size  \u{2318}+", Action::TextSizeBy(1.0)), Item::entry("Decrease Text Size  \u{2318}\u{2212}", Action::TextSizeBy(-1.0)), Item::Separator, Item::entry("Reset to 13 pt  \u{2318}0", Action::TextSize(13.0)), Item::Separator];
                        items.extend([10.0, 12.0, 13.0, 14.0, 16.0, 18.0, 20.0, 24.0].map(|size: f32| Item::toggle(&format!("{} pt", size as i32), Action::TextSize(size), size == self.font_points)));
                        self.menu = Some(Menu::new(rect, items));
                    }
                    "code" => {
                        self.menu = Some(Menu::new(rect, vec![
                            Item::entry("Go to Definition", Action::Editor("definition")),
                            Item::entry("Find References", Action::Editor("references")),
                            Item::entry("Show Documentation", Action::Editor("hover")),
                            Item::entry("Rename Symbol\u{2026}", Action::Editor("rename")),
                            Item::entry("Code Actions\u{2026}", Action::Editor("codeAction")),
                            Item::entry("Format Document", Action::Editor("format")),
                            Item::Separator,
                            Item::entry("Toggle Fold", Action::Editor("fold")),
                            Item::entry("Fold All", Action::Editor("foldAll")),
                            Item::entry("Unfold All", Action::Editor("unfoldAll")),
                            Item::entry("Toggle Inlay Hints", Action::Editor("inlayHints")),
                            Item::Separator,
                            Item::note("No language server for this file"),
                        ]));
                    }
                    _ => {}
                }
                return true;
            }
        }
        if let Some((_, action)) = self.header_buttons.iter().find(|(rect, _)| rect.contains(x, y)).copied() {
            match action {
                "files" => self.toggle_explorer(),
                "quick-open" => self.open_search(false),
                "find" => self.open_search(true),
                "git" => self.open_git(),
                // Quick Open, Find in Files, Source Control, connections, the agent panel and the
                // agent launcher do not exist in this build yet (PLAN.md).
                _ => self.notice = Some(format!("{} is not available in this build yet.", match action {
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
                crate::explorer::Clicked::NewMenu(rect) => self.menu = Some(Menu::new(rect, vec![Item::entry("New File\u{2026}", Action::NewFile), Item::entry("New Folder\u{2026}", Action::NewFolder)])),
                crate::explorer::Clicked::OptionsMenu(rect) => {
                    self.menu = Some(Menu::new(rect, vec![
                        Item::toggle("Project Tree", Action::Nothing, true),
                        Item::note("Folder List"),
                        Item::Separator,
                        Item::toggle("Compact Folders", Action::ToggleCompact, self.explorer.compact()),
                        Item::toggle("Reveal Active File", Action::ToggleReveal, self.explorer.reveal_active),
                        Item::toggle("Hide Git-Ignored Files", Action::ToggleHideIgnored, self.explorer.hide_ignored),
                        Item::Separator,
                        Item::note("Follow Terminal"),
                        Item::toggle("Show Hidden Files", Action::ToggleHidden, self.explorer.show_hidden()),
                    ]))
                }
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
        if std::mem::take(&mut self.dragging_divider) {
            return;
        }
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
        if self.dragging_divider {
            // `ContentView`: the file browser is 200 to 400 points wide.
            let points = (x / self.scale).clamp(200.0, 400.0).round();
            let changed = points != self.explorer_points;
            self.explorer_points = points;
            return changed;
        }
        if let Some(search) = &mut self.search {
            return search.pointer(x, y);
        }
        if self.git.is_some() && self.menu.is_none() {
            return false;
        }
        if let Some(menu) = &mut self.menu {
            return menu.pointer(x, y);
        }
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
        let runnable = matches!(std::path::Path::new(path).extension().and_then(|extension| extension.to_str()).unwrap_or(""), "py" | "js" | "mjs" | "swift" | "sh" | "rb" | "lua" | "go");
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
        let mut buttons: Vec<(Rect, &'static str)> = Vec::new();
        let area = |left: f32, right: f32| Rect::new(left - gap * 0.5, bar.y, right - left + gap, bar.height);
        let save = ui.icon("square.and.arrow.down", 11.0, IconWeight::Medium, right - ui.px(7.0), middle, faded(theme::TEXT_SECONDARY, if modified { 1.0 } else { 0.45 })).max(ui.px(14.0));
        buttons.push((area(right - save, right), "save"));
        right -= save + gap;
        let run = ui.icon("play.fill", 11.0, IconWeight::Medium, right - ui.px(6.0), middle, faded(theme::TEXT_SECONDARY, if runnable { 1.0 } else { 0.45 })).max(ui.px(12.0));
        buttons.push((area(right - run, right), "run"));
        right -= run + gap;
        let size = ui.text_right(&format!("{} pt", points as i32), right, middle, 11.0, 500, false, theme::TEXT_SECONDARY);
        buttons.push((area(right - size, right), "size"));
        right -= size + gap;
        let code = ui.text_right("Code", right, middle, 11.0, 500, false, theme::TEXT_SECONDARY);
        let braces = ui.icon("curlybraces", 11.0, IconWeight::Medium, right - code - ui.px(10.0), middle, theme::TEXT_SECONDARY);
        buttons.push((area(right - code - braces - ui.px(6.0), right), "code"));
        right -= code + braces + ui.px(6.0) + gap;
        let count = ui.text_right(&diagnostics.to_string(), right, middle, 11.0, 500, false, theme::TEXT_SECONDARY);
        let mark = ui.icon("exclamationmark.circle", 11.0, IconWeight::Medium, right - count - ui.px(10.0), middle, theme::TEXT_SECONDARY);
        buttons.push((area(right - count - mark - ui.px(6.0), right), "diagnostics"));
        let footer = self.editor_footer;
        ui.fill(footer, theme::EDITOR_BACKGROUND);
        let middle = footer.y + footer.height * 0.5;
        ui.text(&format!("Neovim \u{b7} {mode}"), footer.x + ui.px(12.0), middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        let hints = if cfg!(target_os = "macos") { "Esc  Normal mode   \u{b7}   i  Insert   \u{b7}   \u{2318}S  Save" } else { "Esc  Normal mode   \u{b7}   i  Insert   \u{b7}   Ctrl+Shift+S  Save" };
        ui.text_right(hints, footer.right() - ui.px(12.0), middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        self.toolbar_buttons = buttons;
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
        self.window = (frame.size.0 as f32, frame.size.1 as f32);
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
        self.draw_creation(painter);
        self.draw_closing(painter);
        if let Some(mut git) = self.git.take() {
            // The explorer's decorations follow what the review changes.
            if git.mutations() != self.git_seen {
                self.git_seen = git.mutations();
                self.explorer.refresh();
            }
            let cell_height = self.cell.height;
            let mut ui = Ui { painter, scale: self.scale };
            git.draw(&mut ui, self.window, cell_height);
            self.git = Some(git);
        }
        if let Some(mut search) = self.search.take() {
            let mut ui = Ui { painter, scale: self.scale };
            search.draw(&mut ui, self.window);
            self.search = Some(search);
        }
        if let Some(mut menu) = self.menu.take() {
            let mut ui = Ui { painter, scale: self.scale };
            menu.draw(&mut ui, self.window);
            self.menu = Some(menu);
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
        signature.add(self.explorer_points.to_bits() as u64);
        if let Some(closing) = &self.closing {
            signature.add(0x434C4F53).text(&closing.path);
        }
        if let Some(creation) = &self.creation {
            signature.add(creation.rename.is_some() as u64 + 7);
        }
        if let Some(git) = &self.git {
            signature.add(0x474954).add(git.signature());
        }
        if let Some(search) = &self.search {
            signature.add(0x53454152).add(search.signature());
        }
        if let Some(creation) = &self.creation {
            signature.add(0x4E4557 ^ creation.is_directory as u64);
            for byte in creation.name.bytes() {
                signature.add(byte as u64);
            }
        }
        if let Some(menu) = &self.menu {
            signature.add(0x4D454E55 ^ menu.items.len() as u64).add(menu.hover.map_or(u64::MAX, |index| index as u64)).add(menu.anchor.x.to_bits() as u64);
        }
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
