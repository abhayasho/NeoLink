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

/// One element of the window for assistive technology (see `Workspace::accessibility`).
#[derive(Clone, Debug, PartialEq)]
pub struct AccessItem {
    /// Stable while the element exists (its node id is derived from it).
    pub key: String,
    pub parent: Option<String>,
    pub role: accesskit::Role,
    pub label: String,
    pub value: Option<String>,
    /// Window pixels.
    pub rect: Rect,
    pub selected: Option<bool>,
    pub expanded: Option<bool>,
    pub level: Option<usize>,
    pub read_only: bool,
    pub focused: bool,
    /// Where a press activates it.
    pub press: Option<(f32, f32)>,
}

impl AccessItem {
    fn new(key: &str, parent: Option<&str>, role: accesskit::Role, label: &str, rect: Rect) -> AccessItem {
        AccessItem { key: key.to_string(), parent: parent.map(str::to_string), role, label: label.to_string(), value: None, rect, selected: None, expanded: None, level: None, read_only: false, focused: false, press: None }
    }
}

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

/// The Performance Monitor (`PerformanceMonitor.swift`): counters sampled twice a second.
struct Monitor {
    sampled_at: f64,
    frames: u64,
    skipped: u64,
    warm: u64,
    render_cpu: f64,
    main_cpu: f64,
    lines: Vec<String>,
    close: Rect,
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
    /// Native text editors for documents while Neovim is unavailable (the Swift app's fallback).
    native: std::collections::HashMap<String, crate::native::NativeEditor>,
    /// Neovim could not start (or `NEOLINK_NO_NVIM=1`): documents open in the native editor.
    native_only: bool,
    /// View > Pixel-Smooth Sideways Scrolling.
    pixel_sideways: bool,
    pub explorer: Explorer,
    sidebar: Rect,
    notice: Option<String>,
    /// The text of the last notice that only informs (drawn neutral, not as an error).
    info: Option<String>,
    /// The notice's close button.
    notice_close: Rect,
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
    pub benchmark_horizontal: bool,
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
    /// The agent panel at the right, the launcher sheet, and the remembered custom agent.
    agent: crate::agents::AgentPanel,
    launcher: Option<crate::agents::Launcher>,
    custom_agent: (String, String),
    agent_rect: Rect,
    dragging_agent: bool,
    /// Saved SSH connections, at the far left.
    connections: crate::connections::Connections,
    connections_rect: Rect,
    /// The terminal docked under or beside the code.
    dock: crate::dock::Dock,
    dock_rect: Rect,
    dragging_dock: bool,
    /// The system's file panel was asked for: 0 a folder for the launcher, 1 a project folder, 2 a
    /// folder to download a remote item into, 3 files to upload.
    folder_request: Option<u8>,
    /// Remote file browsers by `user@host:port`, shown in place of the project tree while an SSH tab of
    /// that connection is selected.
    remotes: std::collections::HashMap<String, crate::remote::RemoteBrowser>,
    remote_shown: Option<String>,
    /// Recent projects, newest first, and the sheet that manages them.
    recent: Vec<std::path::PathBuf>,
    recent_sheet: Option<Vec<(Rect, String)>>,
    explorer_options: Option<(bool, bool, bool, bool, bool)>,
    /// How far the tab strip is scrolled, its content width, and the tab to bring into view.
    strip_scroll: f32,
    strip_content: f32,
    strip_reveal: Option<u64>,
    /// The help text for what the pointer rests on, since when, and whether it is showing.
    tip: Option<(String, f64)>,
    tip_shown: bool,
    tip_changed: bool,
    /// What the held mouse button was pressed in (1 the shown terminal, 2 the docked one, 3 the
    /// editor), and the last press for counting double and triple clicks.
    pressed_in: u8,
    /// Where the shown PDF's native view goes, toolbar commands for it, its page counter, and the
    /// callback that tells the main thread (which owns the views) to look.
    pdf_request: crate::pdf::PdfRequest,
    pdf_commands: Vec<crate::pdf::PdfCommand>,
    pub pdf_label: String,
    on_layout: Option<Box<dyn Fn() + Send>>,
    pdf_buttons: Vec<(Rect, crate::pdf::PdfCommand)>,
    /// The Performance Monitor (View menu) while it is open.
    monitor: Option<Monitor>,
    /// What draws the window, for View > Renderer Information.
    pub renderer_information: String,
    /// The terminal's find bar while it is open: the text, and whether it was found.
    find: Option<(String, bool)>,
    /// The shown terminal's working directory as the status bar spells it.
    shown_directory: String,
    /// The language servers of the shown document.
    shown_servers: String,
    last_press: (f64, f32, f32, u8),
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
    /// Quitting was asked for and waits on the "Save changes?" answers.
    quitting: bool,
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
            native: std::collections::HashMap::new(),
            pixel_sideways: false,
            native_only: std::env::var("NEOLINK_NO_NVIM").is_ok_and(|value| value == "1"),
            explorer: Explorer::new(project_directory()),
            sidebar: Rect::default(),
            notice: None,
            info: None,
            notice_close: Rect::default(),
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
            benchmark_horizontal: false,
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
            agent: crate::agents::AgentPanel::new(),
            launcher: None,
            custom_agent: ("My agent".into(), String::new()),
            agent_rect: Rect::default(),
            dragging_agent: false,
            connections: crate::connections::Connections::new(),
            connections_rect: Rect::default(),
            dock: crate::dock::Dock::new(),
            dock_rect: Rect::default(),
            dragging_dock: false,
            folder_request: None,
            remotes: Default::default(),
            remote_shown: None,
            recent: Vec::new(),
            recent_sheet: None,
            explorer_options: None,
            strip_scroll: 0.0,
            strip_content: 0.0,
            strip_reveal: None,
            tip: None,
            tip_shown: false,
            tip_changed: false,
            pressed_in: 0,
            find: None,
            renderer_information: String::new(),
            monitor: None,
            pdf_request: Default::default(),
            pdf_commands: Vec::new(),
            pdf_label: String::new(),
            on_layout: None,
            pdf_buttons: Vec::new(),
            shown_directory: String::new(),
            shown_servers: String::new(),
            last_press: (0.0, 0.0, 0.0, 0),
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
            quitting: false,
            hover: None,
            signature: 0,
        };
        workspace.layout(size);
        workspace
    }

    pub fn set_on_layout(&mut self, callback: Box<dyn Fn() + Send>) {
        self.on_layout = Some(callback);
    }

    /// For the main thread: where the PDF view goes, and the commands waiting for it.
    pub fn take_pdf_work(&mut self) -> (crate::pdf::PdfRequest, Vec<crate::pdf::PdfCommand>) {
        (self.pdf_request.clone(), std::mem::take(&mut self.pdf_commands))
    }

    /// The PDF tab's bars (`DocumentTabView`): the path and page controls above, the page below.
    fn draw_pdf_chrome(&mut self, painter: &mut Painter, path: &str) {
        let mut ui = Ui { painter, scale: self.scale };
        let line = ui.px(1.0).max(1.0);
        let bar = self.toolbar;
        ui.fill(bar, theme::EDITOR_BACKGROUND);
        ui.painter.scene.fill(bar.x, bar.bottom() - line, bar.width, line, theme::SEPARATOR);
        let middle = bar.y + bar.height * 0.5;
        self.pdf_buttons.clear();
        let mut right = bar.right() - ui.px(14.0);
        use crate::pdf::PdfCommand;
        let fit = ui.text_right("Fit", right, middle, 11.0, 400, false, theme::TEXT_PRIMARY);
        self.pdf_buttons.push((Rect::new(right - fit - ui.px(5.0), bar.y, fit + ui.px(10.0), bar.height), PdfCommand::Fit));
        right -= fit + ui.px(10.0);
        for (symbol, command) in [("plus.magnifyingglass", PdfCommand::ZoomIn), ("minus.magnifyingglass", PdfCommand::ZoomOut), ("chevron.down", PdfCommand::NextPage), ("chevron.up", PdfCommand::PreviousPage)] {
            let width = ui.icon(symbol, 11.0, IconWeight::Regular, right - ui.px(8.0), middle, theme::TEXT_PRIMARY).max(ui.px(16.0));
            self.pdf_buttons.push((Rect::new(right - width - ui.px(5.0), bar.y, width + ui.px(10.0), bar.height), command));
            right -= width + ui.px(10.0);
        }
        let home = home_directory().unwrap_or_default();
        let shown = match std::path::Path::new(path).strip_prefix(&home) {
            Ok(rest) => format!("~/{}", rest.display()),
            Err(_) => path.to_string(),
        };
        let fitted = ui.fit_middle(&shown, (right - bar.x - ui.px(24.0)).max(1.0), 11.0, 400, true);
        ui.text(&fitted, bar.x + ui.px(14.0), middle, 11.0, 400, true, theme::TEXT_SECONDARY);
        let footer = self.editor_footer;
        ui.fill(footer, theme::EDITOR_BACKGROUND);
        ui.painter.scene.fill(footer.x, footer.y, footer.width, line, theme::SEPARATOR);
        let label = if self.pdf_label.is_empty() { "PDF".to_string() } else { self.pdf_label.clone() };
        ui.text(&label, footer.x + ui.px(14.0), footer.y + footer.height * 0.5, 10.0, 500, false, theme::TEXT_SECONDARY);
        self.toolbar_buttons.clear();
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
        // The connections sidebar, then the file browser (`ContentView`'s split view).
        let connections_width = if self.connections.visible { px(crate::connections::WIDTH_POINTS).min(width * 0.3) } else { 0.0 };
        self.connections_rect = Rect::new(0.0, top, connections_width, (bottom - top).max(1.0));
        let explorer_x = if connections_width > 0.0 { connections_width + line } else { 0.0 };
        self.sidebar = Rect::new(explorer_x, top, explorer_width, (bottom - top).max(1.0));
        let center_x = if explorer_width > 0.0 { explorer_x + explorer_width + line } else { explorer_x };
        // The agent panel takes its width from the right (`ContentView`: 240 to 480 points).
        let agent_width = if self.agent.visible { px(self.agent.width_points).min((width - center_x) * 0.6) } else { 0.0 };
        self.agent_rect = Rect::new(width - agent_width, top, agent_width, (bottom - top).max(1.0));
        let center_right = if agent_width > 0.0 { width - agent_width - line } else { width };
        self.center = Rect::new(center_x, top, (center_right - center_x).max(1.0), (bottom - top).max(1.0));
        // The docked terminal takes its share of the centre: under the code, or beside it.
        if self.dock.visible {
            use crate::dock::Side;
            match self.dock.side {
                Side::Bottom => {
                    let height = px(self.dock.height_points).min(self.center.height - px(120.0)).max(px(80.0));
                    self.dock_rect = Rect::new(self.center.x, self.center.bottom() - height, self.center.width, height);
                    self.center.height = (self.center.height - height - line).max(1.0);
                }
                Side::Right => {
                    let width = px(self.dock.width_points).min(self.center.width - px(240.0)).max(px(160.0));
                    self.dock_rect = Rect::new(self.center.right() - width, self.center.y, width, self.center.height);
                    self.center.width = (self.center.width - width - line).max(1.0);
                }
            }
        }
        self.strip = Rect::new(center_x, top, self.center.width, px(34.0));
        let below = self.strip.bottom() + line;
        self.status_bar = Rect::new(center_x, self.center.bottom() - px(28.0), self.center.width, px(28.0));
        let terminal = Rect::new(center_x + px(8.0), below + px(8.0), (self.center.width - px(8.0)).max(1.0), (self.status_bar.y - below - px(8.0)).max(1.0));
        let grid = (((terminal.width / self.cell.width).floor() as usize).max(2), ((terminal.height / self.cell.height).floor() as usize).max(1));
        // A pane is a whole number of cells tall, so a scrolled row is clipped at a row boundary.
        self.pane = Rect::new(terminal.x, terminal.y, terminal.width, grid.1 as f32 * self.cell.height);
        self.toolbar = Rect::new(center_x, below, self.center.width, px(30.0));
        self.editor_footer = Rect::new(center_x, self.center.bottom() - px(22.0), self.center.width, px(22.0));
        // A small margin keeps Neovim's fold and sign columns off the sidebar's edge.
        let inset = px(6.0).round();
        let editor = Rect::new(center_x + inset, self.toolbar.bottom(), (self.center.width - inset).max(1.0), (self.editor_footer.y - self.toolbar.bottom()).max(1.0));
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
        let options = (self.explorer.visible, self.explorer.compact(), self.explorer.show_hidden(), self.explorer.hide_ignored, self.explorer.reveal_active);
        self.recent.retain(|path| path != &root);
        self.recent.insert(0, root.clone());
        self.recent.truncate(12);
        let (list, sort) = (self.explorer.folder_list, self.explorer.sort);
        self.explorer = Explorer::new(root);
        self.explorer_options = Some(options);
        self.apply_explorer_options();
        self.explorer.set_sort(sort);
        self.explorer.set_folder_list(list);
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
        // On macOS a PDF gets a tab with Apple's PDF view (`pdf.rs`); elsewhere there is no embedded
        // viewer yet, so the system's viewer opens it rather than the editor showing its bytes.
        if cfg!(not(target_os = "macos")) && path.extension().and_then(|extension| extension.to_str()).is_some_and(|extension| extension.eq_ignore_ascii_case("pdf")) {
            let (program, arguments): (&str, Vec<&std::ffi::OsStr>) = if cfg!(target_os = "macos") { ("open", vec![path.as_os_str()]) } else if cfg!(windows) { ("cmd", vec![std::ffi::OsStr::new("/C"), std::ffi::OsStr::new("start"), std::ffi::OsStr::new(""), path.as_os_str()]) } else { ("xdg-open", vec![path.as_os_str()]) };
            let _ = std::process::Command::new(program).args(arguments).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).spawn();
            self.notice = Some("PDF tabs are macOS-only in this build; the file was opened in the default viewer.".into());
            return;
        }
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
        if self.native_only {
            return false;
        }
        let Some(shared) = self.shared.upgrade() else { return false };
        match Editor::start(&shared, self.editor_grid.0, self.editor_grid.1) {
            Ok(editor) => {
                self.editor = Some(editor);
                true
            }
            Err(error) => {
                // Said once; documents then open in the native editor without asking Neovim again.
                self.notice = Some(format!("{error} Files open in the built-in text editor instead."));
                self.editor = None;
                self.native_only = true;
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
            if self.doc_modified(&path) {
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
        if let (Pane::Document { path, .. }, Some(editor)) = (&removed.pane, &mut self.editor) {
            editor.command("close", path);
        }
        if let Pane::Document { path, .. } = &removed.pane {
            if !self.tabs.iter().any(|tab| tab.document() == Some(path.as_str())) {
                self.native.remove(path);
            }
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
        self.strip_reveal = self.tabs.get(self.active).map(|tab| tab.id);
        if let Some(path) = self.active_document() {
            // `onChange(of: activeFileURL)`: the tree follows the active file while the option is on.
            if self.explorer.reveal_active {
                self.explorer.reveal(std::path::Path::new(&path));
            }
            if !crate::pdf::is_pdf(&path) {
                if self.ensure_editor() {
                    if let Some(editor) = &mut self.editor {
                        editor.select(&path);
                    }
                } else if !self.native.contains_key(&path) {
                    match crate::native::NativeEditor::open(&path, self.cell) {
                        Ok(editor) => {
                            if editor.read_only {
                                self.notice = Some("This file opens read-only: it is larger than 8 MiB or not UTF-8 text.".into());
                            }
                            self.native.insert(path, editor);
                        }
                        Err(error) => self.notice = Some(error),
                    }
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
    /// The terminal that typed bytes go to: the agent panel's when it has the keyboard, else the
    /// active tab's.
    pub fn keyboard_terminal(&mut self) -> Option<&mut Terminal> {
        if self.dock.focused && self.dock.visible {
            return self.dock.terminal();
        }
        if self.agent.focused && self.agent.visible {
            return self.agent.terminal();
        }
        self.active()
    }

    /// Key presses are the editor's (Neovim notation) rather than a terminal's.
    pub fn keys_go_to_editor(&self) -> bool {
        self.active_is_document() && !self.active_document().is_some_and(|path| crate::pdf::is_pdf(&path)) && !(self.agent.focused && self.agent.visible) && !(self.dock.focused && self.dock.visible)
    }

    /// Shows the docked terminal under (`below`) or beside the code with the keyboard in it; if it
    /// is already there with the keyboard, hides it.
    pub fn toggle_dock(&mut self, below: bool) {
        use crate::dock::Side;
        let side = if below { Side::Bottom } else { Side::Right };
        if self.dock.visible && self.dock.side != side {
            self.dock.side = side;
            self.dock.focused = true;
        } else {
            self.dock.side = side;
            if self.dock.toggle() {
                self.dock_shell();
            }
        }
        if self.dock.focused {
            self.agent.focused = false;
            self.explorer.focused = false;
            self.explorer.filter_focused = false;
        }
    }

    fn dock_shell(&mut self) {
        let Some(shared) = self.shared.upgrade() else { return };
        let directory = self.active_document().and_then(|path| std::path::Path::new(&path).parent().map(std::path::Path::to_path_buf)).filter(|_| false).unwrap_or_else(|| self.explorer.root().to_path_buf());
        if let Err(error) = self.dock.open_shell(&shared, &directory, self.cell) {
            self.notice = Some(format!("Could not start a shell: {error}"));
            self.dock.visible = false;
            self.dock.focused = false;
        }
    }

    pub fn toggle_connections(&mut self) {
        self.connections.visible = !self.connections.visible;
        if !self.connections.visible {
            self.connections.search_focused = false;
        }
    }

    /// Opens the "New connection" sheet (Shift-Command-N).
    pub fn new_connection(&mut self) {
        self.menu = None;
        self.connections.visible = true;
        self.connections.edit(None);
    }

    /// Opens an SSH session to a saved connection in a new tab, using the system's `ssh`: it asks for
    /// passwords and host-key confirmations in the terminal itself.
    fn open_connection(&mut self, connection: &neolink_core::sessions::Connection) {
        let Some(shared) = self.shared.upgrade() else { return };
        let id = self.next_id;
        self.next_id += 1;
        // The tab's ssh shares its connection, so the file browser needs no sign-in of its own.
        let mut arguments = crate::remote::sharing_options(connection);
        arguments.extend(std::env::var("NEOLINK_SSH_OPTIONS").map(|options| options.split_whitespace().map(str::to_string).collect::<Vec<_>>()).unwrap_or_default());
        arguments.extend(connection.ssh_arguments());
        match Terminal::spawn_program(&shared, self.grid.0, self.grid.1, self.cell, home_directory(), id, Some(("ssh".to_string(), arguments))) {
            Ok(mut terminal) => {
                terminal.fallback_title = connection.name.clone();
                if let Some(password) = crate::connections::saved_password(connection) {
                    // OpenSSH's prompts for this user and host (password and keyboard-interactive).
                    let prompts = vec![format!("{}@{}'s password:", connection.username, connection.host), format!("({}@{}) Password:", connection.username, connection.host)];
                    terminal.auto_password = Some((prompts, password, crate::clock::now() + 60.0));
                }
                let address = format!("{}:{}", connection.address(), connection.port);
                self.remotes.entry(address.clone()).or_insert_with(|| crate::remote::RemoteBrowser::new(connection.clone(), self.shared.clone()));
                terminal.remote = Some(address);
                self.tabs.push(Tab { id, pane: Pane::Terminal(terminal) });
                self.select(self.tabs.len() - 1);
            }
            Err(error) => self.notice = Some(format!("Could not start ssh: {error}")),
        }
    }

    fn remote_browser(&mut self) -> Option<&mut crate::remote::RemoteBrowser> {
        let address = self.remote_shown.clone()?;
        self.remotes.get_mut(&address)
    }

    fn remote_outcome(&mut self, outcome: crate::remote::Outcome) {
        use crate::remote::Outcome;
        match outcome {
            Outcome::Nothing => {}
            Outcome::Menu(menu) => self.menu = Some(menu),
            Outcome::Choose(folder) => self.folder_request = Some(if folder { 2 } else { 3 }),
            Outcome::Disconnect => {
                if let Some(address) = self.remote_shown.take() {
                    self.remotes.remove(&address);
                }
            }
        }
    }

    /// One of the remote browser's row actions, by name.
    pub fn remote_action(&mut self, what: &'static str, name: &str) {
        self.perform(Action::Remote(what, name.to_string()));
    }

    /// Files chosen for upload, or the folder chosen for a download.
    pub fn remote_chosen(&mut self, paths: Vec<std::path::PathBuf>, download: bool) {
        if let Some(browser) = self.remote_browser() {
            match (download, paths.first()) {
                (true, Some(folder)) => browser.download_into(folder),
                (false, Some(_)) => browser.upload(&paths),
                _ => {}
            }
        }
    }

    fn connections_outcome(&mut self, outcome: crate::connections::Outcome) {
        use crate::connections::Outcome;
        match outcome {
            Outcome::Nothing => {}
            Outcome::Close => self.toggle_connections(),
            Outcome::LocalTerminal => {
                if let Some(shared) = self.shared.upgrade() {
                    let _ = self.new_tab(&shared);
                }
            }
            Outcome::Open(connection) => self.open_connection(&connection),
            Outcome::Menu(menu) => self.menu = Some(menu),
        }
    }

    /// Sends the prompt of the shown conversation, with the active file as its context.
    pub fn submit_prompt(&mut self) -> bool {
        if !self.agent.composing() {
            return false;
        }
        let context = self.active_document();
        self.agent.submit(context.as_deref());
        true
    }

    pub fn toggle_agent_panel(&mut self) {
        self.agent.visible = !self.agent.visible;
        if !self.agent.visible {
            self.agent.focused = false;
        }
    }

    /// Opens the "Coding agent" sheet.
    pub fn open_launcher(&mut self) {
        self.menu = None;
        self.launcher = Some(crate::agents::Launcher::new(Some(self.explorer.root().to_path_buf()), self.custom_agent.0.clone(), self.custom_agent.1.clone()));
    }

    /// "Choose Folder..." was pressed in the launcher (the caller shows the system's panel).
    pub fn take_folder_request(&mut self) -> Option<u8> {
        self.folder_request.take()
    }

    /// What is remembered between runs (the window itself is the caller's).
    pub fn settings(&self, mut settings: crate::settings::Settings) -> crate::settings::Settings {
        settings.font_points = self.font_points;
        settings.pixel_sideways = self.pixel_sideways;
        settings.explorer_visible = self.explorer.visible;
        settings.connections_visible = self.connections.visible;
        settings.explorer_points = self.explorer_points;
        settings.compact_folders = self.explorer.compact();
        settings.folder_list = self.explorer.folder_list;
        settings.folder_sort = self.explorer.sort;
        settings.show_hidden = self.explorer.show_hidden();
        settings.hide_ignored = self.explorer.hide_ignored;
        settings.reveal_active = self.explorer.reveal_active;
        settings.agent_visible = self.agent.visible;
        settings.agent_points = self.agent.width_points;
        settings.dock_right = self.dock.side == crate::dock::Side::Right;
        settings.dock_height = self.dock.height_points;
        settings.dock_width = self.dock.width_points;
        settings.custom_agent_name = self.custom_agent.0.clone();
        settings.custom_agent_executable = self.custom_agent.1.clone();
        settings.project = Some(self.explorer.root().to_path_buf());
        settings.recent_projects = self.recent.clone();
        settings
    }

    /// Applies remembered settings to a new workspace (the project is opened by the caller).
    pub fn apply_settings(&mut self, settings: &crate::settings::Settings) {
        self.pixel_sideways = settings.pixel_sideways;
        self.font_points = settings.font_points.clamp(MIN_FONT_POINTS, MAX_FONT_POINTS);
        self.explorer_points = settings.explorer_points.clamp(200.0, 400.0);
        self.agent.visible = settings.agent_visible;
        self.connections.visible = settings.connections_visible;
        self.agent.width_points = settings.agent_points.clamp(240.0, 480.0);
        self.dock.side = if settings.dock_right { crate::dock::Side::Right } else { crate::dock::Side::Bottom };
        self.dock.height_points = settings.dock_height.clamp(80.0, 900.0);
        self.dock.width_points = settings.dock_width.clamp(160.0, 1600.0);
        self.custom_agent = (settings.custom_agent_name.clone(), settings.custom_agent_executable.clone());
        self.recent = settings.recent_projects.iter().filter(|path| path.is_dir()).take(12).cloned().collect();
        self.explorer_options = Some((settings.explorer_visible, settings.compact_folders, settings.show_hidden, settings.hide_ignored, settings.reveal_active));
        self.apply_explorer_options();
        self.explorer.set_sort(settings.folder_sort);
        self.explorer.set_folder_list(settings.folder_list);
    }

    fn apply_explorer_options(&mut self) {
        if let Some((visible, compact, hidden, hide_ignored, reveal)) = self.explorer_options {
            self.explorer.visible = visible;
            if self.explorer.compact() != compact {
                self.explorer.toggle_compact();
            }
            if self.explorer.show_hidden() != hidden {
                self.explorer.toggle_hidden();
            }
            self.explorer.hide_ignored = hide_ignored;
            self.explorer.reveal_active = reveal;
        }
    }

    fn draw_recent(&mut self, painter: &mut Painter) {
        if self.recent_sheet.is_none() {
            return;
        }
        let mut buttons: Vec<(Rect, String)> = Vec::new();
        let recent = self.recent.clone();
        let mut ui = Ui { painter, scale: self.scale };
        ui.fill(Rect::new(0.0, 0.0, self.window.0, self.window.1), [0, 0, 0, 90]);
        let (width, height, pad) = (ui.px(510.0), ui.px(360.0), ui.px(22.0));
        let sheet = Rect::new(((self.window.0 - width) * 0.5).round(), ((self.window.1 - height) * 0.35).round().max(ui.px(20.0)), width, height);
        ui.shadow(sheet, 10.0);
        ui.rounded(sheet, 10.0, theme::SIDEBAR_BACKGROUND);
        ui.outline(sheet, 10.0, theme::white(0.12));
        let (left, right) = (sheet.x + pad, sheet.right() - pad);
        let mut y = sheet.y + pad;
        ui.text("Recent Projects", left, y + ui.px(11.0), 18.0, 600, false, theme::TEXT_PRIMARY);
        y += ui.px(22.0 + 14.0);
        ui.text("Remove shortcuts without deleting folders or closing your current project.", left, y + ui.px(8.0), 12.0, 400, false, theme::TEXT_SECONDARY);
        y += ui.px(16.0 + 14.0);
        let bottom = sheet.bottom() - pad - ui.px(22.0 + 14.0);
        let list = Rect::new(left, y, right - left, bottom - y);
        if recent.is_empty() {
            let middle = list.y + list.height * 0.5;
            ui.icon("folder", 24.0, IconWeight::Regular, list.x + list.width * 0.5, middle - ui.px(14.0), theme::TEXT_SECONDARY);
            let label = "No recent projects";
            let label_width = ui.measure(label, 13.0, 400, false);
            ui.text(label, list.x + (list.width - label_width) * 0.5, middle + ui.px(16.0), 13.0, 400, false, theme::TEXT_SECONDARY);
        } else {
            ui.rounded(list, 6.0, theme::EDITOR_BACKGROUND);
            ui.painter.scene.set_clip(Some(list));
            let row_height = ui.px(10.0 + 32.0 + 10.0);
            let line = ui.px(1.0).max(1.0);
            for (index, folder) in recent.iter().enumerate() {
                let row = Rect::new(list.x, list.y + index as f32 * (row_height + line), list.width, row_height);
                let middle = row.y + row.height * 0.5;
                let icon = ui.icon("folder", 12.0, IconWeight::Regular, row.x + ui.px(10.0 + 8.0), middle, theme::TEXT_SECONDARY).max(ui.px(16.0));
                let text_x = row.x + ui.px(10.0) + icon + ui.px(10.0);
                let name = folder.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
                ui.text(&name, text_x, middle - ui.px(9.0), 12.0, 500, false, theme::TEXT_PRIMARY);
                let path = ui.fit_middle(&folder.display().to_string(), row.right() - text_x - ui.px(44.0), 11.0, 400, false);
                ui.text(&path, text_x, middle + ui.px(9.0), 11.0, 400, false, theme::TEXT_SECONDARY);
                let remove = Rect::new(row.right() - ui.px(10.0 + 22.0), middle - ui.px(11.0), ui.px(22.0), ui.px(22.0));
                ui.icon("xmark", 10.0, IconWeight::Regular, remove.x + remove.width * 0.5, middle, theme::TEXT_SECONDARY);
                buttons.push((remove, format!("forget:{index}")));
                ui.painter.scene.fill(row.x, row.bottom(), row.width, line, theme::SEPARATOR);
            }
            ui.painter.scene.set_clip(None);
        }
        let button_y = sheet.bottom() - pad - ui.px(22.0);
        let clear_width = ui.measure("Clear Recent Projects", 12.0, 500, false) + ui.px(20.0);
        let clear = Rect::new(left, button_y, clear_width, ui.px(22.0));
        ui.rounded(clear, 5.0, theme::rgb(0x3A3A3A));
        ui.text("Clear Recent Projects", clear.x + ui.px(10.0), button_y + ui.px(11.0), 12.0, 500, false, if recent.is_empty() { faded(theme::TEXT_SECONDARY, 0.6) } else { theme::TEXT_PRIMARY });
        if !recent.is_empty() {
            buttons.push((clear, "clear".into()));
        }
        let done_width = ui.measure("Done", 12.0, 500, false) + ui.px(24.0);
        let done = Rect::new(right - done_width, button_y, done_width, ui.px(22.0));
        ui.rounded(done, 5.0, theme::rgb(0x2F6FDB));
        ui.text("Done", done.x + ui.px(12.0), button_y + ui.px(11.0), 12.0, 500, false, theme::rgb(0xFFFFFF));
        buttons.push((done, "done".into()));
        self.recent_sheet = Some(buttons);
    }

    fn click_recent(&mut self, x: f32, y: f32) {
        let Some(buttons) = &self.recent_sheet else { return };
        let Some((_, what)) = buttons.iter().find(|(rect, _)| rect.contains(x, y)).cloned() else { return };
        match what.as_str() {
            "done" => self.recent_sheet = None,
            "clear" => self.recent.clear(),
            other => {
                if let Some(index) = other.strip_prefix("forget:").and_then(|index| index.parse::<usize>().ok()) {
                    if index < self.recent.len() {
                        self.recent.remove(index);
                    }
                }
            }
        }
    }

    pub fn set_launcher_directory(&mut self, directory: std::path::PathBuf) {
        if let Some(launcher) = &mut self.launcher {
            launcher.directory = Some(directory);
        }
    }

    fn agent_outcome(&mut self, outcome: Option<crate::agents::Outcome>) {
        use crate::agents::Outcome;
        let Some(outcome) = outcome else {
            // The sheet closes; the custom agent's name and program are remembered.
            if let Some(launcher) = self.launcher.take() {
                self.custom_agent = launcher.remembered();
            }
            return;
        };
        match outcome {
            Outcome::Nothing => {}
            Outcome::OpenLauncher => self.open_launcher(),
            Outcome::Hide => self.toggle_agent_panel(),
            Outcome::Menu(menu) => self.menu = Some(menu),
            Outcome::ChooseFolder => self.folder_request = Some(0),
            Outcome::Launch { agent, directory, docked } => {
                if !directory.is_dir() {
                    if let Some(launcher) = &mut self.launcher {
                        launcher.error = Some("The project folder no longer exists.".into());
                    }
                    return;
                }
                let Some(shared) = self.shared.upgrade() else { return };
                let result = if docked {
                    self.agent.launch(&shared, &agent, &directory, self.cell).map_err(|error| error.to_string())
                } else {
                    let before = self.tabs.len();
                    self.open_terminal_in(directory.clone());
                    if self.tabs.len() > before {
                        let resolved = crate::agents::executable(&agent.executable);
                        self.write(agent.launch_command(&directory.to_string_lossy(), resolved.as_deref()).replace('\n', "\r").into_bytes());
                        Ok(())
                    } else {
                        Err("Could not start a shell.".to_string())
                    }
                };
                match result {
                    Ok(()) => self.agent_outcome(None),
                    Err(error) => {
                        if let Some(launcher) = &mut self.launcher {
                            launcher.error = Some(error);
                        }
                    }
                }
            }
            Outcome::Connect { agent, directory, mcp } => {
                let servers = match neolink_acp::parse_mcp(&mcp) {
                    Ok(servers) => servers,
                    Err(error) => {
                        if let Some(launcher) = &mut self.launcher {
                            launcher.error = Some(error);
                        }
                        return;
                    }
                };
                if !directory.is_dir() {
                    if let Some(launcher) = &mut self.launcher {
                        launcher.error = Some("The project folder no longer exists.".into());
                    }
                    return;
                }
                let Some(shared) = self.shared.upgrade() else { return };
                self.agent.connect(&shared, &agent, &neolink_core::paths::canonical(&directory), servers);
                self.agent_outcome(None);
            }
            Outcome::ShowGit => self.open_git(),
            Outcome::Submit => {
                self.submit_prompt();
            }
        }
    }

    pub fn write(&mut self, bytes: Vec<u8>) -> bool {
        match self.keyboard_terminal() {
            Some(terminal) => terminal.write(bytes),
            None => false,
        }
    }

    /// Keys for the editor, in Neovim's notation (the active tab is a document).
    pub fn editor_input(&mut self, keys: &str) {
        if let Some(editor) = self.native_editor() {
            // Injected text: literal characters.
            editor.insert(&keys.replace("<lt>", "<").replace("<CR>", "\n"));
            return;
        }
        if let Some(editor) = &mut self.editor {
            editor.input(keys);
        }
    }

    pub fn save_active(&mut self) {
        if let Some(path) = self.active_document().filter(|path| self.native.contains_key(path)) {
            self.save_native(&path);
            return;
        }
        if let (Some(path), Some(editor)) = (self.active_document().filter(|path| !crate::pdf::is_pdf(path)), &mut self.editor) {
            editor.command("save", &path);
            self.refresh_explorer_soon = true;
        }
    }

    /// The window became active again, or files may have changed: read the open folders and Git again.
    pub fn refresh_explorer(&mut self) {
        self.explorer.refresh();
    }

    pub fn editor_action(&mut self, action: &str) {
        if let Some(editor) = self.native_editor() {
            match action {
                "undo" => editor.undo(),
                "redo" => editor.redo(),
                "selectAll" => editor.select_all(),
                "copy" => {
                    if let Some(text) = editor.selected_text() {
                        if let Ok(mut clipboard) = arboard::Clipboard::new() {
                            let _ = clipboard.set_text(text);
                        }
                    }
                }
                _ => {}
            }
            return;
        }
        if let (true, Some(editor)) = (self.active_is_document(), &mut self.editor) {
            editor.action(action);
        }
    }

    pub fn paste(&mut self, text: &str) {
        if self.dock.focused && self.dock.visible {
            if let Some(terminal) = self.dock.terminal() {
                terminal.paste(text);
            }
            return;
        }
        if self.agent.focused && self.agent.visible {
            if let Some(terminal) = self.agent.terminal() {
                terminal.paste(text);
            }
            return;
        }
        if let Some(editor) = self.native_editor() {
            editor.insert(text);
        } else if self.active_is_document() {
            if let Some(editor) = &mut self.editor {
                editor.paste(text);
            }
        } else if let Some(terminal) = self.active() {
            terminal.paste(text);
        }
    }

    /// The editor cell under the pointer.
    fn pointer_cell(&self) -> (usize, usize) {
        let row = match &self.editor {
            Some(editor) => editor.row_at(self.pointer.1 - self.editor_pane.y, self.cell),
            None => 0,
        };
        let column = ((self.pointer.0 - self.editor_pane.x) / self.cell.width).floor().clamp(0.0, self.editor_grid.0.saturating_sub(1) as f32) as usize;
        (row, column)
    }

    /// A scroll event over whatever is under the pointer; the deltas are device pixels.
    pub fn scroll(&mut self, time: f64, _delta_x: f64, delta_y: f64, phase: ScrollPhase) {
        if let Some(git) = &mut self.git {
            git.scroll(self.pointer.0, self.pointer.1, _delta_x as f32, delta_y as f32);
            return;
        }
        if self.scroll_search(delta_y as f32) {
            return;
        }
        let (cell, period) = (self.cell, self.period);
        self.tip = None;
        if self.connections.contains(self.pointer.0, self.pointer.1) {
            self.connections.scroll(delta_y as f32);
            return;
        }
        if self.explorer.visible && self.sidebar.contains(self.pointer.0, self.pointer.1) {
            if let Some(browser) = self.remote_browser() {
                browser.scroll(delta_y as f32);
                return;
            }
        }
        if self.strip.contains(self.pointer.0, self.pointer.1) {
            // Either axis moves the tabs sideways.
            let delta = if _delta_x.abs() > delta_y.abs() { _delta_x } else { delta_y };
            self.strip_scroll -= delta as f32;
            return;
        }
        if self.dock.contains(self.pointer.0, self.pointer.1) {
            if let Some(terminal) = self.dock.terminal() {
                terminal.scroll_input(time, delta_y, phase, cell, period);
            }
            return;
        }
        if self.agent.contains(self.pointer.0, self.pointer.1) {
            if self.agent.scroll_conversation(delta_y as f32) {
                return;
            }
            if let Some(terminal) = self.agent.terminal() {
                terminal.scroll_input(time, delta_y, phase, cell, period);
            }
            return;
        }
        if self.explorer.contains(self.pointer.0, self.pointer.1) {
            self.explorer.scroll_input(time, delta_y, phase, period);
            return;
        }
        if let Some(editor) = self.native_editor() {
            editor.scroll_input(time, delta_y, phase == ScrollPhase::Began, period);
        } else if self.active_is_document() {
            let (row, column) = self.pointer_cell();
            let path = self.active_document().unwrap_or_default();
            if let Some(editor) = &mut self.editor {
                if phase == ScrollPhase::Began {
                    editor.end_scroll_gesture();
                }
                editor.pixel_sideways = self.pixel_sideways;
                editor.scroll_both(time, _delta_x, delta_y, phase, self.scale as f64, period, cell, row, column, &path);
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
        if let Some(part) = name.strip_prefix("remote:") {
            return self.remote_shown.as_ref().and_then(|address| self.remotes.get(address))?.control_rect(part).map(middle);
        }
        if let Some(part) = name.strip_prefix("connections:") {
            return self.connections.control_rect(part).map(middle);
        }
        if name == "editor" {
            return Some(middle(self.editor_pane));
        }
        if let Some(part) = name.strip_prefix("launcher:") {
            return self.launcher.as_ref()?.control_rect(part).map(middle);
        }
        if let Some(part) = name.strip_prefix("dock:") {
            return self.dock.control_rect(part).map(middle);
        }
        if let Some(part) = name.strip_prefix("agent:") {
            return self.agent.control_rect(part).map(middle);
        }
        if let Some(part) = name.strip_prefix("git:") {
            return self.git.as_ref()?.control_rect(part).map(middle);
        }
        if let Some(index) = name.strip_prefix("tab:").and_then(|index| index.parse::<usize>().ok()) {
            return self.tab_rects.get(index).copied().map(middle);
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
        if self.menu.is_none() && self.remote_browser().is_some_and(|browser| browser.prompting()) {
            if let Some(browser) = self.remote_browser() {
                browser.key(key, text);
            }
            return true;
        }
        if (self.connections.sheet_is_open() || self.connections.search_focused) && self.menu.is_none() && self.connections.key(key, text) {
            return true;
        }
        if self.recent_sheet.is_some() {
            if matches!(key, Key::Named(NamedKey::Escape | NamedKey::Enter)) {
                self.recent_sheet = None;
            }
            return true;
        }
        if let (Some((query, _)), true) = (&mut self.find, self.menu.is_none()) {
            match key {
                Key::Named(NamedKey::Escape) => self.find = None,
                Key::Named(NamedKey::Enter) => self.find_in_terminal(false),
                Key::Named(NamedKey::Backspace) => {
                    query.pop();
                    self.find_in_terminal(true);
                }
                _ => {
                    if let Some(text) = text.filter(|text| !text.chars().any(char::is_control)) {
                        query.push_str(text);
                        self.find_in_terminal(true);
                    }
                }
            }
            return true;
        }
        if self.launcher.is_some() {
            let outcome = self.launcher.as_mut().and_then(|launcher| launcher.key(key, text));
            self.agent_outcome(outcome);
            return true;
        }
        if self.agent.composing() && self.menu.is_none() && self.git.is_none() && self.search.is_none() && self.creation.is_none() && self.closing.is_none() {
            self.agent.key(key, text);
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

    /// Says that a part of the Swift app is not in this build yet.
    /// Shows a one-line message over the workspace.
    pub fn notify(&mut self, message: String) {
        self.notice = Some(message);
    }

    pub fn unavailable(&mut self, what: &str) {
        self.notice = Some(format!("{what} is not available in this build yet."));
    }

    /// A new local tab running `program` (the Code menu's "Open REPL").
    pub fn open_repl(&mut self, program: &str) {
        let directory = self.explorer.root().to_path_buf();
        self.open_terminal_in(directory);
        self.write(format!("{program}\r").into_bytes());
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
        self.tabs.iter().filter_map(|tab| tab.document()).any(|path| self.doc_modified(path))
    }

    /// What is on screen for assistive technology (VoiceOver, Narrator): the toolbar and tab buttons
    /// with the same names as their help tags, the file tree, and the text of the terminal or editor
    /// shown, in window pixels. Built only while a screen reader is listening.
    pub fn accessibility(&mut self) -> Vec<AccessItem> {
        use accesskit::Role;
        let mut items = Vec::new();
        let middle = |rect: Rect| (rect.x + rect.width * 0.5, rect.y + rect.height * 0.5);
        let union = |rects: &mut dyn Iterator<Item = Rect>| {
            rects.fold(None, |sum: Option<Rect>, rect| {
                Some(match sum {
                    None => rect,
                    Some(sum) => {
                        let (x, y) = (sum.x.min(rect.x), sum.y.min(rect.y));
                        Rect::new(x, y, sum.right().max(rect.right()) - x, sum.bottom().max(rect.bottom()) - y)
                    }
                })
            })
        };
        // Toolbar buttons, named as their help tags (without the shortcut, which VoiceOver reads badly).
        let label_of = |this: &Workspace, rect: Rect, fallback: &str| {
            let (x, y) = middle(rect);
            this.tip_at(x, y).map(|tip| tip.split(" (").next().unwrap_or(&tip).to_string()).unwrap_or_else(|| fallback.replace('-', " "))
        };
        if let Some(rect) = union(&mut self.header_buttons.iter().map(|(rect, _)| *rect)) {
            items.push(AccessItem::new("toolbar", None, Role::Toolbar, "Toolbar", rect));
            for (rect, action) in self.header_buttons.clone() {
                let mut item = AccessItem::new(&format!("header:{action}"), Some("toolbar"), Role::Button, &label_of(self, rect, action), rect);
                item.press = Some(middle(rect));
                items.push(item);
            }
        }
        // Tabs.
        if let Some(rect) = union(&mut self.tab_rects.iter().copied().chain(std::iter::once(self.plus_rect))) {
            items.push(AccessItem::new("tabs", None, Role::TabList, "Tabs", rect));
            for (index, rect) in self.tab_rects.clone().into_iter().enumerate() {
                let Some(tab) = self.tabs.get(index) else { break };
                let (title, modified) = match &tab.pane {
                    Pane::Document { path, title } => (title.clone(), self.doc_modified(path)),
                    Pane::Terminal(terminal) => (terminal.title(), false),
                };
                let mut item = AccessItem::new(&format!("tab:{}", tab.id), Some("tabs"), Role::Tab, &if modified { format!("{title}, edited") } else { title.clone() }, rect);
                item.selected = Some(index == self.active);
                item.press = Some(middle(rect));
                items.push(item);
                if let Some(close) = self.close_rects.get(index).copied() {
                    let mut item = AccessItem::new(&format!("close:{}", tab.id), Some("tabs"), Role::Button, &format!("Close {title}"), close);
                    item.press = Some(middle(close));
                    items.push(item);
                }
            }
            let mut item = AccessItem::new("new-tab", Some("tabs"), Role::Button, "New terminal tab", self.plus_rect);
            item.press = Some(middle(self.plus_rect));
            items.push(item);
        }
        // The file tree.
        if self.explorer.visible {
            items.push(AccessItem::new("explorer", None, Role::Group, "Explorer", self.sidebar));
            for name in ["explorer-new", "explorer-collapse", "explorer-refresh", "explorer-options", "explorer-filter"] {
                if let Some(rect) = self.explorer.control_rect(name) {
                    let role = if name == "explorer-filter" { Role::SearchInput } else { Role::Button };
                    let mut item = AccessItem::new(name, Some("explorer"), role, &label_of(self, rect, name), rect);
                    item.press = Some(middle(rect));
                    items.push(item);
                }
            }
            items.push(AccessItem::new("files", Some("explorer"), Role::Tree, "Files", self.sidebar));
            let selected = self.explorer.selected.clone();
            for (rect, row) in self.explorer.visible_rows() {
                let mut item = AccessItem::new(&format!("row:{}", row.path.display()), Some("files"), Role::TreeItem, &row.label, rect);
                item.level = Some(row.depth + 1);
                item.selected = Some(selected.as_ref() == Some(&row.path));
                if let neolink_core::tree::RowKind::Folder { expanded, .. } = row.kind {
                    item.expanded = Some(expanded);
                }
                item.press = Some(middle(rect));
                items.push(item);
            }
        }
        // What the active tab shows, and the editor's buttons.
        let keyboard_in_content = !(self.dock.focused && self.dock.visible) && !(self.agent.focused && self.agent.visible);
        let (pane, editor_pane) = (self.pane, self.editor_pane);
        let active = self.active;
        let content = match self.tabs.get_mut(active).map(|tab| (tab.id, &mut tab.pane)) {
            Some((id, Pane::Terminal(terminal))) => Some(AccessItem { value: Some(terminal.screen_text()), ..AccessItem::new(&format!("content:{id}"), None, Role::Terminal, &terminal.title(), pane) }),
            Some((id, Pane::Document { path, title })) if crate::pdf::is_pdf(path) => Some(AccessItem::new(&format!("content:{id}"), None, Role::Document, &format!("{title}, PDF {}", self.pdf_label), editor_pane)),
            Some((id, Pane::Document { path, title })) => {
                let (path, title) = (path.clone(), title.clone());
                let mut item = AccessItem::new(&format!("content:{id}"), None, Role::MultilineTextInput, &title, editor_pane);
                if let Some(native) = self.native.get(&path) {
                    item.value = Some(native.visible_text());
                    item.read_only = native.read_only;
                } else if let Some(editor) = self.editor.as_ref().filter(|editor| editor.shows(&path)) {
                    item.value = Some(editor.screen_text());
                }
                Some(item)
            }
            None => None,
        };
        if let Some(mut content) = content {
            content.focused = keyboard_in_content;
            content.press = Some(middle(content.rect));
            let document = content.role != Role::Terminal;
            items.push(content);
            if document {
                for (rect, what) in self.toolbar_buttons.clone() {
                    let mut item = AccessItem::new(&format!("editor:{what}"), None, Role::Button, &label_of(self, rect, what), rect);
                    item.press = Some(middle(rect));
                    items.push(item);
                }
            }
        }
        if self.dock.visible {
            let rect = self.dock.rect();
            let focused = self.dock.focused;
            let value = self.dock.terminal().map(|terminal| terminal.screen_text());
            items.push(AccessItem { value, focused, press: Some(middle(rect)), ..AccessItem::new("dock", None, Role::Terminal, "Terminal panel", rect) });
        }
        if self.agent.visible {
            let rect = self.agent.rect();
            let focused = self.agent.focused;
            let value = self.agent.terminal().map(|terminal| terminal.screen_text());
            items.push(AccessItem { value, focused, press: Some(middle(rect)), ..AccessItem::new("agent", None, Role::Pane, "Agent", rect) });
        }
        // A notice is read out when it appears.
        if let Some(notice) = &self.notice {
            items.push(AccessItem::new("notice", None, Role::Alert, notice, self.header));
        }
        items
    }

    /// View > Pixel-Smooth Sideways Scrolling.
    pub fn toggle_pixel_sideways(&mut self) {
        self.pixel_sideways = !self.pixel_sideways;
        self.inform(if self.pixel_sideways { "Pixel-smooth sideways scrolling is on (preview).".into() } else { "Sideways scrolling moves by whole columns.".into() });
    }

    /// The document has changes that are not on disk (in Neovim or the native editor).
    fn doc_modified(&self, path: &str) -> bool {
        self.editor.as_ref().is_some_and(|editor| editor.is_modified(path)) || self.native.get(path).is_some_and(|editor| editor.is_modified())
    }

    /// The native editor showing the active document, if that is how it is open.
    pub fn native_editor(&mut self) -> Option<&mut crate::native::NativeEditor> {
        if !self.active_is_document() || (self.agent.focused && self.agent.visible) || (self.dock.focused && self.dock.visible) {
            return None;
        }
        let path = self.active_document()?;
        self.native.get_mut(&path)
    }

    /// A key for the native editor. Returns `true` if it used the key.
    pub fn native_key(&mut self, key: &winit::keyboard::Key, text: Option<&str>, modifiers: winit::keyboard::ModifiersState) -> bool {
        // Elsewhere than macOS the app's shortcuts need Control-Shift (a terminal owns Control-letters),
        // but a text editor has no such conflict: the usual Control-letters edit, save and find.
        if !cfg!(target_os = "macos") && modifiers.control_key() && !modifiers.alt_key() && self.native_editor().is_some() {
            if let winit::keyboard::Key::Character(character) = key {
                match character.to_lowercase().as_str() {
                    "z" if modifiers.shift_key() => self.editor_action("redo"),
                    "z" => self.editor_action("undo"),
                    "y" => self.editor_action("redo"),
                    "c" => self.editor_action("copy"),
                    "x" => self.cut(),
                    "a" => self.editor_action("selectAll"),
                    "s" => self.save_active(),
                    "f" => self.find(),
                    "v" => {
                        if let Some(text) = arboard::Clipboard::new().ok().and_then(|mut clipboard| clipboard.get_text().ok()) {
                            self.paste(&text);
                        }
                    }
                    _ => return false,
                }
                return true;
            }
        }
        match self.native_editor() {
            Some(editor) => {
                editor.key(key, text, modifiers);
                true
            }
            None => false,
        }
    }

    /// Cut (the native editor; Neovim cuts by its own means).
    pub fn cut(&mut self) {
        if let Some(text) = self.native_editor().and_then(|editor| editor.cut()) {
            if let Ok(mut clipboard) = arboard::Clipboard::new() {
                let _ = clipboard.set_text(text);
            }
        } else if self.keys_go_to_editor() {
            self.editor_action("cut");
        }
    }

    fn save_native(&mut self, path: &str) {
        if let Some(editor) = self.native.get_mut(path) {
            if let Err(error) = editor.save() {
                self.notice = Some(error);
            }
            self.refresh_explorer_soon = true;
        }
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
                if let (Some(line), Some(editor)) = (line, &mut self.editor) {
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
        let directory = self.explorer.current_folder().to_path_buf();
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
        if self.connections.contains(x, y) {
            let outcome = self.connections.click(x, y, true);
            let opened = matches!(outcome, crate::connections::Outcome::Menu(_));
            self.connections_outcome(outcome);
            return opened;
        }
        if self.explorer.visible && self.sidebar.contains(x, y) && self.remote_browser().is_some() {
            let outcome = self.remote_browser().map(|browser| browser.click(x, y, true));
            if let Some(outcome) = outcome {
                self.remote_outcome(outcome);
            }
            return true;
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

    /// The help text for what is under `(x, y)`, as the Swift app's `.help(...)` texts.
    fn tip_at(&self, x: f32, y: f32) -> Option<String> {
        if self.menu.is_some() || self.creation.is_some() || self.search.is_some() || self.git.is_some() || self.closing.is_some() || self.launcher.is_some() || self.recent_sheet.is_some() {
            return None;
        }
        if let Some((_, action)) = self.header_buttons.iter().find(|(rect, _)| rect.contains(x, y)) {
            return Some(
                match *action {
                    "project" => "Open project and remember folder access",
                    "agent" => "Launch a coding agent (\u{2303}\u{2318}A)",
                    "quick-open" => "Quick Open (\u{2318}P)",
                    "find" => "Find in Files (\u{21e7}\u{2318}F)",
                    "git" => "Source Control (\u{21e7}\u{2318}G)",
                    "connections" => "Toggle connections sidebar (\u{2303}\u{2318}S)",
                    "files" => "Toggle file browser (\u{21e7}\u{2318}E)",
                    "agent-panel" => "Toggle agent panel (\u{2303}\u{2318}B)",
                    _ => return None,
                }
                .to_string(),
            );
        }
        if self.close_rects.iter().any(|rect| rect.contains(x, y)) {
            return Some("Close tab".into());
        }
        if let Some(index) = self.tab_rects.iter().position(|rect| rect.contains(x, y)) {
            return self.tabs.get(index).map(|tab| match &tab.pane {
                Pane::Document { path, .. } => path.clone(),
                Pane::Terminal(terminal) => terminal.title(),
            });
        }
        if self.plus_rect.contains(x, y) {
            return Some("New local terminal (\u{2318}T)".into());
        }
        if self.shown == self.active && self.active_is_document() {
            if let Some((_, what)) = self.toolbar_buttons.iter().find(|(rect, _)| rect.contains(x, y)) {
                return Some(
                    match *what {
                        "save" => "Save file (\u{2318}S)",
                        "run" => "Save and run file in a terminal",
                        "diagnostics" => "Show diagnostics",
                        "size" => "Text size",
                        "code" => "Code actions",
                        "servers" => return Some(format!("Code intelligence: {}", self.shown_servers)),
                        _ => return None,
                    }
                    .to_string(),
                );
            }
        }
        for (name, text) in [("explorer-new", "Create file or folder"), ("explorer-collapse", "Collapse all folders"), ("explorer-refresh", "Refresh files"), ("explorer-options", "File browser options"), ("explorer-filter", "Filter loaded branches. Use \u{2318}P to search the entire project.")] {
            if self.explorer.visible && self.explorer.control_rect(name).is_some_and(|rect| rect.contains(x, y)) {
                return Some(text.into());
            }
        }
        None
    }

    fn draw_tip(&mut self, painter: &mut Painter, display: f64) -> Option<f64> {
        const DELAY: f64 = 0.8;
        self.tip_shown = false;
        let (text, since) = self.tip.clone()?;
        let now = display.max(crate::clock::now());
        if now < since + DELAY {
            return Some(since + DELAY);
        }
        self.tip_shown = true;
        let mut ui = Ui { painter, scale: self.scale };
        let text = ui.fit_middle(&text, ui.px(520.0), 11.0, 400, false);
        let width = ui.measure(&text, 11.0, 400, false) + ui.px(14.0);
        let height = ui.px(22.0);
        let x = (self.pointer.0 + ui.px(8.0)).min(self.window.0 - width - ui.px(6.0)).max(ui.px(6.0));
        let mut y = self.pointer.1 + ui.px(20.0);
        if y + height > self.window.1 - ui.px(4.0) {
            y = self.pointer.1 - height - ui.px(8.0);
        }
        let rect = Rect::new(x.round(), y.round(), width, height);
        ui.shadow(rect, 5.0);
        ui.rounded(rect, 5.0, theme::rgb(0x2C2C2C));
        ui.outline(rect, 5.0, theme::white(0.14));
        ui.text(&text, rect.x + ui.px(7.0), rect.y + height * 0.5, 11.0, 400, false, theme::TEXT_PRIMARY);
        None
    }

    /// Which pointer the window should show at `(x, y)`: `true` for the column-resize arrows.
    /// The pointer should be the row-resize arrows (the top edge of the terminal under the code).
    pub fn wants_row_resize_cursor(&self, x: f32, y: f32) -> bool {
        let modal = self.menu.is_some() || self.creation.is_some() || self.search.is_some() || self.git.is_some() || self.closing.is_some() || self.launcher.is_some();
        self.dock.side == crate::dock::Side::Bottom && (self.dragging_dock || (!modal && self.dock.over_edge(x, y, 3.0 * self.scale)))
    }

    pub fn wants_resize_cursor(&self, x: f32, y: f32) -> bool {
        let modal = self.menu.is_some() || self.creation.is_some() || self.search.is_some() || self.git.is_some() || self.closing.is_some() || self.launcher.is_some();
        if self.dock.side == crate::dock::Side::Right && (self.dragging_dock || (!modal && self.dock.over_edge(x, y, 3.0 * self.scale))) {
            return true;
        }
        self.dragging_divider || self.dragging_agent || self.over_divider(x, y) || self.over_agent_divider(x, y)
    }

    fn over_agent_divider(&self, x: f32, y: f32) -> bool {
        let reach = 3.0 * self.scale;
        self.agent.visible && self.menu.is_none() && self.creation.is_none() && self.search.is_none() && self.git.is_none() && self.closing.is_none() && self.launcher.is_none() && (x - self.agent.left_edge()).abs() <= reach && y >= self.agent_rect.y && y < self.agent_rect.bottom()
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
                if let Some(editor) = &mut self.editor {
                    editor.command("save", &closing.path);
                }
                self.save_native(&closing.path);
                if self.native.get(&closing.path).is_some_and(|editor| editor.is_modified()) {
                    // Not saved (changed on disk): keep the tab and say why.
                    self.quitting = false;
                    return;
                }
                self.force_close(index);
            }
            "discard" => self.force_close(index),
            _ => {
                // Cancel also cancels quitting.
                self.quitting = false;
                return;
            }
        }
        if self.quitting && self.request_quit() {
            if let Some(callback) = &self.on_empty {
                callback();
            }
        }
    }

    /// Asks to quit. Returns `true` if nothing is unsaved; otherwise the first unsaved document asks
    /// what to do with it, and the app quits after the last answer (`TabsController.confirmClose`).
    pub fn request_quit(&mut self) -> bool {
        let unsaved = self.tabs.iter().filter_map(|tab| tab.document()).find(|path| self.doc_modified(path)).map(str::to_string);
        match unsaved {
            Some(path) => {
                self.quitting = true;
                self.menu = None;
                if let Some(index) = self.tabs.iter().position(|tab| tab.document() == Some(path.as_str())) {
                    self.select(index);
                }
                self.closing = Some(Closing { path, buttons: Vec::new() });
                false
            }
            None => true,
        }
    }

    /// Whether a press at `(x, y)` is on empty header space, which drags the window.
    pub fn wants_window_drag(&self, x: f32, y: f32) -> bool {
        let modal = self.menu.is_some() || self.creation.is_some() || self.search.is_some() || self.git.is_some() || self.closing.is_some() || self.launcher.is_some() || self.recent_sheet.is_some() || self.connections.sheet_is_open();
        !modal && self.header.contains(x, y) && !self.header_buttons.iter().any(|(rect, _)| rect.contains(x, y))
    }

    fn perform(&mut self, action: Action) {
        match action {
            Action::Editor(name) => self.editor_action(name),
            Action::TextSize(points) => self.set_font_points(points),
            Action::TextSizeBy(delta) => self.set_font_points(self.font_points + delta),
            Action::ToggleCompact => self.explorer.toggle_compact(),
            Action::FolderList(on) => self.explorer.set_folder_list(on),
            Action::SortBy(index) => self.explorer.set_sort(index),
            Action::Navigate(folder) => self.explorer.navigate(&folder),
            Action::ShowInFinder(folder) => self.file_action("show", folder, true),
            Action::ToggleFollow => self.explorer.follow_terminal = !self.explorer.follow_terminal,
            Action::ToggleHidden => self.explorer.toggle_hidden(),
            Action::ToggleHideIgnored => {
                self.explorer.hide_ignored = !self.explorer.hide_ignored;
                self.explorer.mark_stale();
            }
            Action::ToggleReveal => self.explorer.reveal_active = !self.explorer.reveal_active,
            Action::OpenProject => self.folder_request = Some(1),
            Action::Project(path) => {
                if path.is_dir() {
                    self.set_project(path);
                } else {
                    self.recent.retain(|recent| recent != &path);
                    self.notice = Some("That folder no longer exists; it was removed from the recent projects.".into());
                }
            }
            Action::ManageRecent => self.recent_sheet = Some(Vec::new()),
            Action::ClearRecent => self.recent.clear(),
            Action::NewFile => self.begin_create(false),
            Action::NewFolder => self.begin_create(true),
            Action::File(what, path, is_directory) => self.file_action(what, path, is_directory),
            Action::Remote(what, name) => {
                let outcome = self.remote_browser().map(|browser| browser.perform(what, &name));
                if let Some(outcome) = outcome {
                    self.remote_outcome(outcome);
                }
            }
            Action::Connection(what, id) => match what {
                "open" => {
                    if let Some(connection) = self.connections.find(&id) {
                        self.open_connection(&connection);
                    }
                }
                "edit" => self.connections.edit(Some(&id)),
                "remove" => self.connections.remove_with_password(&id),
                _ => {}
            },
            Action::AgentSession(id) => self.agent.select(id),
            Action::AgentMode(mode) => self.agent.set_mode(&mode),
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
        if self.notice.is_some() && self.notice_close.contains(x, y) {
            self.notice = None;
            return true;
        }
        if self.monitor.as_ref().is_some_and(|monitor| monitor.close.contains(x, y)) {
            self.monitor = None;
            return true;
        }
        self.tip = None;
        self.find = None;
        // Presses close together in time and place count up: word, then line.
        let now = crate::clock::now();
        let near = (x - self.last_press.1).abs() < 4.0 * self.scale && (y - self.last_press.2).abs() < 4.0 * self.scale;
        let clicks = if now - self.last_press.0 < 0.4 && near { self.last_press.3 % 3 + 1 } else { 1 };
        self.last_press = (now, x, y, clicks);
        if let Some(menu) = self.menu.take() {
            if let Some(action) = menu.action_at(x, y) {
                self.perform(action);
            } else if menu.contains(x, y) {
                self.menu = Some(menu);
            }
            return true;
        }
        if self.connections.sheet_is_open() {
            self.connections.click_sheet(x, y);
            return true;
        }
        if self.recent_sheet.is_some() {
            self.click_recent(x, y);
            return true;
        }
        if self.launcher.is_some() {
            let outcome = self.launcher.as_mut().and_then(|launcher| launcher.click(x, y));
            self.agent_outcome(outcome);
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
        if self.connections.contains(x, y) {
            self.explorer.focused = false;
            self.explorer.filter_focused = false;
            self.agent.focused = false;
            self.dock.focused = false;
            let outcome = self.connections.click(x, y, false);
            self.connections_outcome(outcome);
            return true;
        }
        self.connections.search_focused = false;
        if self.explorer.visible && self.sidebar.contains(x, y) && self.remote_browser().is_some() {
            let outcome = self.remote_browser().map(|browser| browser.click(x, y, false));
            if let Some(outcome) = outcome {
                self.remote_outcome(outcome);
            }
            return true;
        }
        if self.over_divider(x, y) {
            self.dragging_divider = true;
            return true;
        }
        if self.over_agent_divider(x, y) {
            self.dragging_agent = true;
            return true;
        }
        if self.dock.over_edge(x, y, 3.0 * self.scale) {
            self.dragging_dock = true;
            return true;
        }
        if self.dock.over_text(x, y) && self.menu.is_none() {
            let cell = self.cell;
            self.dock.focused = true;
            self.agent.focused = false;
            self.explorer.focused = false;
            self.explorer.filter_focused = false;
            if let Some(terminal) = self.dock.terminal() {
                terminal.mouse_down(x, y, cell, clicks);
                self.pressed_in = 2;
            }
            return true;
        }
        if self.dock.contains(x, y) {
            if let crate::dock::Pressed::NewShell = self.dock.click(x, y) {
                self.dock_shell();
            }
            if self.dock.focused {
                self.agent.focused = false;
                self.explorer.focused = false;
                self.explorer.filter_focused = false;
            }
            return true;
        }
        self.dock.focused = false;
        if self.agent.contains(x, y) {
            self.dock.focused = false;
            let outcome = self.agent.click(x, y);
            self.explorer.focused = false;
            self.explorer.filter_focused = false;
            self.agent_outcome(Some(outcome));
            return true;
        }
        self.agent.focused = false;
        if !self.explorer.contains(x, y) {
            self.explorer.filter_focused = false;
            self.explorer.focused = false;
        }
        if self.shown == self.active && self.active_document().is_some_and(|path| crate::pdf::is_pdf(&path)) {
            if let Some((_, command)) = self.pdf_buttons.iter().find(|(rect, _)| rect.contains(x, y)).copied() {
                self.pdf_commands.push(command);
                if let Some(callback) = &self.on_layout {
                    callback();
                }
                return true;
            }
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
                            Item::note(&if self.shown_servers.is_empty() { "No language server for this file".to_string() } else { format!("Language servers: {}", self.shown_servers) }),
                        ]));
                    }
                    _ => {}
                }
                return true;
            }
        }
        if let Some((_, action)) = self.header_buttons.iter().find(|(rect, _)| rect.contains(x, y)).copied() {
            match action {
                "project" => {
                    let rect = self.header_buttons.iter().find(|(_, name)| *name == "project").map(|(rect, _)| *rect).unwrap_or_default();
                    let mut items = vec![Item::entry("Open Project\u{2026}", Action::OpenProject)];
                    if !self.recent.is_empty() {
                        items.push(Item::Separator);
                        for folder in &self.recent {
                            let name = folder.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_else(|| folder.display().to_string());
                            items.push(Item::toggle(&name, Action::Project(folder.clone()), folder == self.explorer.root()));
                        }
                        items.push(Item::Separator);
                        items.push(Item::entry("Manage Recent Projects\u{2026}", Action::ManageRecent));
                        items.push(Item::entry("Clear Recent Projects", Action::ClearRecent));
                    }
                    self.menu = Some(Menu::new(rect, items));
                }
                "files" => self.toggle_explorer(),
                "agent-panel" => self.toggle_agent_panel(),
                "connections" => self.toggle_connections(),
                "agent" => self.open_launcher(),
                "quick-open" => self.open_search(false),
                "find" => self.open_search(true),
                "git" => self.open_git(),
                // Quick Open, Find in Files, Source Control, connections, the agent panel and the
                // agent launcher do not exist in this build yet (PLAN.md).
                _ => self.notice = Some(format!("{} is not available in this build yet.", match action {
                    _ => "This",
                })),
            }
            return true;
        }
        if self.explorer.contains(x, y) {
            match self.explorer.click(x, y) {
                crate::explorer::Clicked::File(file) => self.open_document(&file),
                crate::explorer::Clicked::Close => self.toggle_explorer(),
                crate::explorer::Clicked::Missing => self.open_git(),
                crate::explorer::Clicked::FolderMenu(rect) => {
                    // `LocalFileBrowserView`'s folder menu: parent, home, the enclosing folders, Finder.
                    let current = self.explorer.current_folder().to_path_buf();
                    let list = self.explorer.folder_list;
                    let mut items = Vec::new();
                    if list {
                        items.push(match current.parent() {
                            Some(parent) => Item::entry("Parent Folder", Action::Navigate(parent.to_path_buf())),
                            None => Item::note("Parent Folder"),
                        });
                        if let Some(home) = home_directory() {
                            items.push(Item::entry("Home", Action::Navigate(home)));
                        }
                        items.push(Item::Separator);
                        for ancestor in current.ancestors().skip(1) {
                            items.push(Item::entry(&ancestor.display().to_string(), Action::Navigate(ancestor.to_path_buf())));
                        }
                        items.push(Item::Separator);
                    } else {
                        items.push(Item::entry("Show as Folder List", Action::FolderList(true)));
                        items.push(Item::Separator);
                    }
                    items.push(Item::entry(if cfg!(target_os = "macos") { "Show in Finder" } else { "Show in File Manager" }, Action::ShowInFinder(current)));
                    self.menu = Some(Menu::new(rect, items));
                }
                crate::explorer::Clicked::NewMenu(rect) => self.menu = Some(Menu::new(rect, vec![Item::entry("New File\u{2026}", Action::NewFile), Item::entry("New Folder\u{2026}", Action::NewFolder)])),
                crate::explorer::Clicked::OptionsMenu(rect) => {
                    let tree = !self.explorer.folder_list;
                    let option = |label: &str, action: Action, checked: bool| Item::Entry { label: label.to_string(), action, checked, enabled: tree };
                    let mut items = vec![
                        Item::toggle("Project Tree", Action::FolderList(false), tree),
                        Item::toggle("Folder List", Action::FolderList(true), !tree),
                        Item::Separator,
                        option("Compact Folders", Action::ToggleCompact, self.explorer.compact()),
                        option("Reveal Active File", Action::ToggleReveal, self.explorer.reveal_active),
                        option("Hide Git-Ignored Files", Action::ToggleHideIgnored, self.explorer.hide_ignored),
                        Item::Separator,
                        Item::toggle("Follow Terminal", Action::ToggleFollow, self.explorer.follow_terminal),
                        Item::toggle("Show Hidden Files", Action::ToggleHidden, self.explorer.show_hidden()),
                        Item::Separator,
                        Item::note("Sort by"),
                    ];
                    for (index, label) in crate::explorer::Explorer::SORT_ORDERS.iter().enumerate() {
                        items.push(Item::Entry { label: format!("   {label}"), action: Action::SortBy(index), checked: !tree && self.explorer.sort == index, enabled: !tree });
                    }
                    self.menu = Some(Menu::new(rect, items))
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
            let pane = self.editor_pane;
            if let Some(editor) = self.active_document().and_then(|path| self.native.get_mut(&path)) {
                if pane.contains(x, y) {
                    editor.mouse(x, y, clicks, false, false);
                }
            } else if let Some(editor) = &mut self.editor {
                editor.mouse("press", row, column);
            }
            self.pressed_in = 3;
            return true;
        }
        if self.pane.contains(x, y) && !self.active_is_document() && self.shown == self.active {
            let cell = self.cell;
            if let Some(terminal) = self.active() {
                terminal.mouse_down(x, y, cell, clicks);
                self.pressed_in = 1;
            }
            return true;
        }
        false
    }

    /// A file dragged in from another program and dropped at the pointer: over the explorer it is
    /// copied into the folder under it (never replacing anything), elsewhere it is opened.
    pub fn drop_file(&mut self, path: &std::path::Path) {
        let (x, y) = self.pointer;
        if self.explorer.visible && self.sidebar.contains(x, y) && self.remote_browser().is_some() {
            // Dropped on the remote browser: uploaded into the folder it shows.
            if let Some(browser) = self.remote_browser() {
                browser.upload(&[path.to_path_buf()]);
            }
            return;
        }
        if self.explorer.contains(x, y) {
            let target = self.explorer.drop_target(x, y);
            match neolink_core::files::copy_into(path, &target) {
                Ok(_) => self.explorer.refresh(),
                Err(error) => self.notice = Some(error),
            }
        } else if path.is_dir() {
            self.set_project(neolink_core::paths::canonical(path));
        } else {
            self.open_document(path);
        }
    }

    /// View > Performance Monitor: opens or closes the panel.
    pub fn toggle_monitor(&mut self) {
        self.monitor = match self.monitor.take() {
            Some(_) => None,
            None => {
                let shared = self.shared.upgrade();
                let read = |shared: &Arc<Shared>| (shared.frames.load(std::sync::atomic::Ordering::Relaxed), shared.skipped.load(std::sync::atomic::Ordering::Relaxed), shared.warm_frames.load(std::sync::atomic::Ordering::Relaxed), shared.render_cpu(), shared.main_cpu());
                let (frames, skipped, warm, render_cpu, main_cpu) = shared.as_ref().map(read).unwrap_or_default();
                Some(Monitor { sampled_at: crate::clock::now(), frames, skipped, warm, render_cpu, main_cpu, lines: vec!["Sampling\u{2026}".into()], close: Rect::default() })
            }
        };
    }

    /// Samples the counters every half second and draws the panel. Returns when to sample next.
    fn draw_monitor(&mut self, painter: &mut Painter, display: f64) -> Option<f64> {
        use std::sync::atomic::Ordering;
        let shared = self.shared.upgrade()?;
        // Judged at this frame's display time, which is what the frame loop schedules by.
        let now = display.max(crate::clock::now());
        let period = self.period;
        let monitor = self.monitor.as_mut()?;
        let elapsed = now - monitor.sampled_at;
        if elapsed >= 0.5 {
            let (frames, skipped, warm) = (shared.frames.load(Ordering::Relaxed), shared.skipped.load(Ordering::Relaxed), shared.warm_frames.load(Ordering::Relaxed));
            let (render_cpu, main_cpu) = (shared.render_cpu(), shared.main_cpu());
            let rate = |now: u64, then: u64| now.saturating_sub(then) as f64 / elapsed;
            let displayed: Vec<f64> = shared.displayed.lock().iter().copied().collect();
            let mut intervals: Vec<f64> = displayed.windows(2).map(|pair| (pair[1] - pair[0]) * 1000.0).filter(|interval| *interval > 0.0 && *interval < 1000.0).collect();
            intervals.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
            let percentile = |p: f64| intervals.get(((intervals.len() as f64 - 1.0) * p).round() as usize).copied().unwrap_or(0.0);
            let cost = f64::from_bits(shared.build_cost.load(Ordering::Relaxed));
            monitor.lines = vec![
                format!("Display: {:.0} Hz ({:.2} ms a refresh)", 1.0 / period.max(0.001), period * 1000.0),
                format!("Presented frames: {:.1}/s, of which {:.1}/s kept the display warm", rate(frames, monitor.frames), rate(warm, monitor.warm)),
                format!("Frames built but unchanged (not presented): {:.1}/s", rate(skipped, monitor.skipped)),
                if intervals.is_empty() { "Presented intervals: none yet".to_string() } else { format!("Presented intervals (last {}): p50 {:.1} ms \u{b7} p95 {:.1} ms \u{b7} max {:.1} ms", intervals.len(), percentile(0.5), percentile(0.95), intervals.last().copied().unwrap_or(0.0)) },
                format!("Last frame built in {cost:.2} ms"),
                format!("CPU: render thread {:.1}% \u{b7} main thread {:.1}% of one core", (render_cpu - monitor.render_cpu) / elapsed * 100.0, (main_cpu - monitor.main_cpu) / elapsed * 100.0),
            ];
            *monitor = Monitor { sampled_at: now, frames, skipped, warm, render_cpu, main_cpu, lines: std::mem::take(&mut monitor.lines), close: monitor.close };
        }
        let next = monitor.sampled_at + 0.5;
        let lines = monitor.lines.clone();
        let mut ui = Ui { painter, scale: self.scale };
        let (width, row, pad) = (ui.px(540.0).min(self.center.width - ui.px(24.0)), ui.px(16.0), ui.px(14.0));
        // The numbers in monospace, then what they mean in ordinary text wrapped to the panel.
        const NOTE: &str = "Frames are presented only when something changed; an idle window presents nothing. Keep-warm frames follow input for a few seconds so the display stays at full rate. This panel itself causes two frames a second.";
        let note = crate::agents::wrap(&mut ui, NOTE, width - pad * 2.0, 11.0);
        let note_row = ui.px(15.0);
        let height = pad * 2.0 + ui.px(22.0) + lines.len() as f32 * row + ui.px(8.0) + note.len() as f32 * note_row;
        let panel = Rect::new(self.center.right() - width - ui.px(12.0), self.center.y + ui.px(44.0), width, height);
        ui.shadow(panel, 8.0);
        ui.rounded(panel, 8.0, theme::rgb(0x202020));
        ui.outline(panel, 8.0, theme::white(0.12));
        ui.text("Performance", panel.x + pad, panel.y + pad + ui.px(8.0), 12.0, 600, false, theme::TEXT_PRIMARY);
        let close = Rect::new(panel.right() - pad - ui.px(16.0), panel.y + pad, ui.px(16.0), ui.px(16.0));
        ui.icon("xmark", 10.0, IconWeight::Semibold, close.x + close.width * 0.5, close.y + close.height * 0.5, theme::TEXT_SECONDARY);
        let mut y = panel.y + pad + ui.px(22.0);
        ui.painter.scene.set_clip(Some(Rect::new(panel.x + pad, panel.y, (panel.width - pad * 2.0).max(1.0), panel.height)));
        for line in &lines {
            ui.text(line, panel.x + pad, y + row * 0.5, 11.0, 400, true, theme::TEXT_PRIMARY);
            y += row;
        }
        y += ui.px(8.0);
        for line in &note {
            ui.text(line, panel.x + pad, y + note_row * 0.5, 11.0, 400, false, theme::TEXT_SECONDARY);
            y += note_row;
        }
        ui.painter.scene.set_clip(None);
        if let Some(monitor) = &mut self.monitor {
            monitor.close = close;
        }
        Some(next)
    }

    pub fn show_renderer_information(&mut self) {
        self.inform(self.renderer_information.clone());
    }

    /// Command-F: Neovim's search in the editor, the find bar in a terminal.
    pub fn find(&mut self) {
        if self.native_editor().is_some() {
            self.find = Some((String::new(), true));
        } else if self.keys_go_to_editor() {
            self.editor_action("find");
        } else if self.keyboard_terminal().is_some() {
            self.find = Some((String::new(), true));
        }
    }

    fn find_in_terminal(&mut self, restart: bool) {
        let Some((query, _)) = self.find.clone() else { return };
        let cell = self.cell;
        let found = match self.native_editor() {
            Some(editor) => editor.find(&query, restart),
            None => self.keyboard_terminal().map(|terminal| terminal.find(&query, restart, cell)).unwrap_or(false),
        };
        if let Some(find) = &mut self.find {
            find.1 = found;
        }
    }

    fn draw_find(&mut self, painter: &mut Painter) {
        let Some((query, found)) = self.find.clone() else { return };
        let pane = if self.dock.focused && self.dock.visible { self.dock_rect } else if self.agent.focused && self.agent.visible { self.agent_rect } else { self.pane };
        let mut ui = Ui { painter, scale: self.scale };
        let width = ui.px(260.0).min(pane.width - ui.px(16.0));
        let bar = Rect::new(pane.right() - width - ui.px(12.0), pane.y + ui.px(6.0), width, ui.px(28.0));
        ui.shadow(bar, 6.0);
        ui.rounded(bar, 6.0, theme::rgb(0x262626));
        ui.outline(bar, 6.0, if found { theme::rgb(0x2F6FDB) } else { theme::rgb(0xCC9595) });
        let middle = bar.y + bar.height * 0.5;
        let glass = ui.icon("magnifyingglass", 11.0, IconWeight::Regular, bar.x + ui.px(9.0 + 6.0), middle, theme::TEXT_SECONDARY).max(ui.px(12.0));
        let text_x = bar.x + ui.px(9.0) + glass + ui.px(7.0);
        let line = ui.px(1.0).max(1.0);
        let in_file = self.active_document().is_some_and(|path| self.native.contains_key(&path)) && !(self.dock.focused && self.dock.visible) && !(self.agent.focused && self.agent.visible);
        let hint = if !found { "No matches" } else if in_file { "\u{21a9} next \u{b7} esc" } else { "\u{21a9} previous \u{b7} esc" };
        let hint_width = ui.text_right(hint, bar.right() - ui.px(9.0), middle, 10.0, 400, false, if found { theme::TEXT_SECONDARY } else { theme::rgb(0xCC9595) });
        ui.painter.scene.set_clip(Some(Rect::new(text_x, bar.y, (bar.right() - ui.px(15.0) - hint_width - text_x).max(1.0), bar.height)));
        let end = if query.is_empty() {
            ui.text(if in_file { "Find in file" } else { "Find in terminal" }, text_x, middle, 12.0, 400, false, faded(theme::TEXT_SECONDARY, 0.7));
            0.0
        } else {
            ui.text(&query, text_x, middle, 12.0, 400, false, theme::TEXT_PRIMARY) + line
        };
        ui.painter.scene.fill(text_x + end, middle - ui.px(7.0), line.max(2.0), ui.px(14.0), theme::ACCENT);
        ui.painter.scene.set_clip(None);
    }

    /// Copies the selection of the terminal that has the keyboard. Returns `false` if the keyboard is
    /// in the editor (which copies by its own means).
    pub fn copy(&mut self) -> bool {
        if self.keys_go_to_editor() {
            self.editor_action("copy");
            return false;
        }
        if let Some(text) = self.keyboard_terminal().and_then(|terminal| terminal.selected_text()) {
            if let Ok(mut clipboard) = arboard::Clipboard::new() {
                let _ = clipboard.set_text(text);
            }
        }
        true
    }

    pub fn select_all(&mut self) {
        if self.keys_go_to_editor() {
            self.editor_action("selectAll");
        } else if let Some(terminal) = self.keyboard_terminal() {
            terminal.select_all();
        }
    }

    pub fn release(&mut self, x: f32, y: f32) {
        if std::mem::take(&mut self.dragging_divider) | std::mem::take(&mut self.dragging_agent) | std::mem::take(&mut self.dragging_dock) {
            return;
        }
        let cell = self.cell;
        match std::mem::take(&mut self.pressed_in) {
            1 => {
                if let Some(terminal) = self.active() {
                    terminal.mouse_up(x, y, cell);
                }
                return;
            }
            2 => {
                if let Some(terminal) = self.dock.terminal() {
                    terminal.mouse_up(x, y, cell);
                }
                return;
            }
            _ => {}
        }
        if self.editor_pane.contains(x, y) && self.active_is_document() && self.shown == self.active {
            let (row, column) = self.pointer_cell();
            if let Some(editor) = &mut self.editor {
                editor.mouse("release", row, column);
            }
        }
    }

    /// The pointer moved to `(x, y)`. Returns `true` if a hover highlight changed.
    pub fn pointer(&mut self, x: f32, y: f32) -> bool {
        self.pointer = (x, y);
        // The help text follows what the pointer rests on; moving to something else starts over.
        let tip = self.tip_at(x, y);
        let was_shown = self.tip_shown;
        if tip.as_deref() != self.tip.as_ref().map(|tip| tip.0.as_str()) {
            self.tip = tip.map(|text| (text, crate::clock::now()));
            if was_shown || self.tip.is_some() {
                self.tip_changed = true;
            }
        }
        // A held button drags the selection (or, in the editor, Neovim's).
        let cell = self.cell;
        match self.pressed_in {
            1 => {
                if let Some(terminal) = self.active() {
                    terminal.mouse_drag(x, y, cell);
                }
                return true;
            }
            2 => {
                if let Some(terminal) = self.dock.terminal() {
                    terminal.mouse_drag(x, y, cell);
                }
                return true;
            }
            3 => {
                let (row, column) = self.pointer_cell();
                if let Some(editor) = self.active_document().and_then(|path| self.native.get_mut(&path)) {
                    editor.mouse(x, y, 0, true, false);
                    return true;
                }
                if let Some(editor) = &mut self.editor {
                    editor.mouse("drag", row, column);
                }
                return false;
            }
            _ => {}
        }
        if self.dragging_dock {
            use crate::dock::Side;
            let changed;
            match self.dock.side {
                Side::Bottom => {
                    let points = ((self.dock_rect.bottom() - y) / self.scale).clamp(80.0, 900.0).round();
                    changed = points != self.dock.height_points;
                    self.dock.height_points = points;
                }
                Side::Right => {
                    let points = ((self.dock_rect.right() - x) / self.scale).clamp(160.0, 1600.0).round();
                    changed = points != self.dock.width_points;
                    self.dock.width_points = points;
                }
            }
            return changed;
        }
        if self.dragging_agent {
            let points = ((self.window.0 - x) / self.scale).clamp(240.0, 480.0).round();
            let changed = points != self.agent.width_points;
            self.agent.width_points = points;
            return changed;
        }
        if self.dragging_divider {
            // `ContentView`: the file browser is 200 to 400 points wide.
            let points = ((x - self.sidebar.x) / self.scale).clamp(200.0, 400.0).round();
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
        changed | std::mem::take(&mut self.tip_changed)
    }

    /// The shown pane's scroll position and received input, in lines.
    pub fn scroll_lines(&self) -> (f64, f64) {
        match self.tabs.get(self.shown).and_then(Tab::terminal) {
            Some(terminal) => ((terminal.scroll() + terminal.program_position(self.cell.height as f64)) / self.cell.height as f64, terminal.received / self.cell.height as f64),
            // A document: fingers moving down show earlier lines, so the position counts downwards.
            None => match (&self.editor, self.active_is_document()) {
                (Some(editor), true) if self.benchmark_horizontal => (-editor.horizontal_position(&self.active_document().unwrap_or_default(), self.cell) / self.cell.width as f64, editor.received_x / self.cell.width as f64),
                (Some(editor), true) => (-editor.drawn_position / self.cell.height as f64, editor.received / self.cell.height as f64),
                _ => (0.0, 0.0),
            },
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
        let Some(notice) = self.notice.clone() else {
            self.notice_close = Rect::default();
            return;
        };
        // Information is neutral; a problem is red with a warning mark. Both close with x (or any key).
        let informs = self.info.as_deref() == Some(notice.as_str());
        let mut ui = Ui { painter, scale: self.scale };
        let height = ui.px(28.0);
        let rect = Rect::new(self.center.x, self.center.bottom() - height - ui.px(28.0), self.center.width, height);
        let middle = rect.y + rect.height * 0.5;
        ui.fill(rect, if informs { theme::rgb(0x25272B) } else { theme::rgb(0x382626) });
        ui.painter.scene.fill(rect.x, rect.y, rect.width, ui.px(1.0).max(1.0), if informs { theme::white(0.08) } else { theme::rgb(0x5A3434) });
        let mut x = rect.x + ui.px(12.0);
        if !informs {
            let mark = ui.icon("exclamationmark.circle", 11.0, IconWeight::Medium, x + ui.px(6.0), middle, theme::rgb(0xE1B4B4)).max(ui.px(12.0));
            x += mark + ui.px(7.0);
        }
        let close = Rect::new(rect.right() - ui.px(28.0), rect.y, ui.px(28.0), rect.height);
        ui.icon("xmark", 9.0, IconWeight::Semibold, close.x + close.width * 0.5, middle, theme::TEXT_SECONDARY);
        ui.painter.scene.set_clip(Some(Rect::new(x, rect.y, (close.x - x - ui.px(4.0)).max(1.0), rect.height)));
        ui.text(&notice, x, middle, 11.0, 400, false, if informs { theme::TEXT_PRIMARY } else { theme::rgb(0xE1B4B4) });
        ui.painter.scene.set_clip(None);
        self.notice_close = close;
    }

    pub fn dismiss_notice(&mut self) -> bool {
        self.notice.take().is_some()
    }

    /// A notice that only informs (not a problem).
    fn inform(&mut self, text: String) {
        self.info = Some(text.clone());
        self.notice = Some(text);
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
        let agent_shown = self.agent.visible;
        let connections_shown = self.connections.visible;
        for (symbol, action, lit) in [
            ("sidebar.right", "agent-panel", agent_shown),
            ("folder", "files", explorer_shown),
            ("sidebar.left", "connections", connections_shown),
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
        let plus_width = ui.px(44.0);
        let viewport = (strip.width - plus_width).max(1.0);
        ui.painter.scene.set_clip(Some(Rect::new(strip.x, strip.y, viewport, strip.height)));
        let tabs: Vec<(String, bool, bool)> = self
            .tabs
            .iter()
            .map(|tab| match &tab.pane {
                Pane::Terminal(terminal) => (terminal.title(), false, false),
                Pane::Document { path, title } => (title.clone(), true, self.doc_modified(path)),
            })
            .collect();
        // Files with the same name show the folder that tells them apart (`TabPresentation`).
        let titles: Vec<String> = tabs.iter().map(|tab| tab.0.clone()).collect();
        let paths: Vec<Option<String>> = self.tabs.iter().map(|tab| tab.document().map(str::to_string)).collect();
        let contexts = neolink_core::tabs::contexts(&titles, &paths);
        // Widths from names and paths alone: 96 pt of chrome, between 120 and 320 pt.
        let mut layout: Vec<(String, String, f32, f32)> = Vec::new();
        for (index, (title, _, _)) in tabs.iter().enumerate() {
            let context = ui.fit_middle(&contexts[index], ui.px(100.0), 11.0, 400, false);
            let context_width = if context.is_empty() { 0.0 } else { ui.measure(&context, 11.0, 400, false).min(ui.px(100.0)) + ui.px(8.0) };
            let fitted = ui.fit_middle(title, (ui.px(320.0 - 96.0) - context_width).max(ui.px(100.0)), 12.0, 400, false);
            let width = (ui.measure(&fitted, 12.0, 400, false) + ui.px(96.0) + context_width).clamp(ui.px(120.0), ui.px(320.0));
            layout.push((fitted, context, context_width, width));
        }
        let content: f32 = layout.iter().map(|tab| tab.3).sum();
        self.strip_content = content;
        // A newly selected tab comes into view by the nearest edge; scrolling stays inside the tabs.
        if let Some(id) = self.strip_reveal.take() {
            if let Some(index) = self.tabs.iter().position(|tab| tab.id == id) {
                let start: f32 = layout[..index].iter().map(|tab| tab.3).sum();
                self.strip_scroll = neolink_core::tabs::reveal(self.strip_scroll, viewport, start, start + layout[index].3);
            }
        }
        self.strip_scroll = self.strip_scroll.clamp(0.0, (content - viewport).max(0.0)).round();
        let mut x = strip.x - self.strip_scroll;
        for (index, (title, is_document, modified)) in tabs.iter().enumerate() {
            let (fitted, context, _, width) = &layout[index];
            let width = *width;
            let rect = Rect::new(x, strip.y, width, strip.height);
            // Only the part inside the viewport takes clicks.
            let visible_left = rect.x.max(strip.x);
            let visible_right = rect.right().min(strip.x + viewport);
            self.tab_rects.push(Rect::new(visible_left, rect.y, (visible_right - visible_left).max(0.0), rect.height));
            let selected = index == self.shown;
            let hovered = self.hover == Some(index);
            if !selected && hovered {
                ui.fill(rect, theme::HOVER);
            }
            let icon = if *is_document { if title.to_lowercase().ends_with(".pdf") { "doc.richtext" } else { "doc.text" } } else { "terminal" };
            ui.icon(icon, 12.0, IconWeight::Regular, rect.x + ui.px(11.0 + 7.0), middle, if selected { theme::ACCENT } else { theme::TEXT_SECONDARY });
            let title_width = ui.text(fitted, rect.x + ui.px(11.0 + 14.0 + 8.0), middle, 12.0, 400, false, if selected { theme::TEXT_PRIMARY } else { theme::TEXT_SECONDARY });
            if !context.is_empty() {
                ui.text(context, rect.x + ui.px(11.0 + 14.0 + 8.0) + title_width + ui.px(8.0), middle, 11.0, 400, false, theme::TEXT_SECONDARY);
            }
            let close = Rect::new(rect.right() - ui.px(3.0 + 27.0), middle - ui.px(15.0), ui.px(27.0), ui.px(30.0));
            if *modified {
                // A round dot, as the Swift app's `Circle()` (a square read as a stray glyph).
                let dot = ui.px(6.0);
                ui.rounded(Rect::new(close.x - dot, middle - dot * 0.5, dot, dot), 3.0, theme::ACCENT);
            }
            let strong = selected || hovered;
            ui.icon("xmark", 9.0, IconWeight::Semibold, close.x + close.width * 0.5, middle, faded(theme::TEXT_SECONDARY, if strong { 1.0 } else { 0.55 }));
            self.close_rects.push(if close.x >= strip.x && close.right() <= strip.x + viewport { close } else { Rect::default() });
            ui.painter.scene.fill(rect.right() - line, rect.y, line, rect.height, theme::SEPARATOR);
            if selected {
                ui.painter.scene.fill(rect.x, rect.bottom() - line, rect.width, line, theme::ACCENT);
            }
            x += width;
        }
        let x = (strip.x + content - self.strip_scroll).min(strip.x + viewport);
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
        let remote = self.tabs.get(self.shown).and_then(Tab::terminal).and_then(|terminal| terminal.remote.clone());
        ui.text(if !running { "Session ended" } else if remote.is_some() { "SSH" } else { "Local shell" }, x + dot + ui.px(7.0), middle, 10.0, 500, false, theme::TEXT_SECONDARY);
        if let Some(remote) = remote {
            // A remote session shows where it is connected, not a local folder.
            let right = rect.right() - ui.px(12.0);
            let fitted = ui.fit_middle(&remote, rect.width * 0.5, 10.0, 400, true);
            let width = ui.text_right(&fitted, right, middle, 10.0, 400, true, theme::TEXT_SECONDARY);
            ui.icon("network", 10.0, IconWeight::Regular, right - width - ui.px(7.0 + 6.0), middle, theme::TEXT_SECONDARY);
            return;
        }
        let directory = self.shown_directory.clone();
        let right = rect.right() - ui.px(12.0);
        let fitted = ui.fit_middle(&directory, rect.width * 0.5, 10.0, 400, true);
        let width = ui.text_right(&fitted, right, middle, 10.0, 400, true, theme::TEXT_SECONDARY);
        ui.icon("folder", 10.0, IconWeight::Regular, right - width - ui.px(7.0 + 6.0), middle, theme::TEXT_SECONDARY);
    }

    /// The editor's toolbar and footer (`CodeToolbar`, `CodeWorkspaceView`).
    fn draw_editor_chrome(&mut self, painter: &mut Painter, path: &str) {
        let (filetype, diagnostics, mode, modified, servers) = match (&self.editor, self.native.get(path)) {
            (_, Some(native)) => (String::new(), 0, if native.read_only { "Read Only" } else { "Insert" }, native.is_modified(), String::new()),
            (Some(editor), None) => (editor.filetype(path), editor.diagnostics(path), editor.mode_label(), editor.is_modified(path), editor.servers(path)),
            (None, None) => (String::new(), 0, "Insert", false, String::new()),
        };
        self.shown_servers = servers.clone();
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
        right -= count + mark + ui.px(6.0) + gap;
        if !servers.is_empty() {
            // Code intelligence is attached to this file.
            let bolt = ui.icon("bolt.fill", 10.0, IconWeight::Medium, right - ui.px(5.0), middle, theme::ACCENT).max(ui.px(10.0));
            buttons.push((area(right - bolt, right), "servers"));
        }
        let footer = self.editor_footer;
        ui.fill(footer, theme::EDITOR_BACKGROUND);
        let middle = footer.y + footer.height * 0.5;
        let (status, hints) = match self.native.get(path) {
            // The built-in editor (Neovim is not installed): no modes.
            Some(native) => (
                format!("Text Editor \u{b7} {}{}", native.cursor_label(), if native.read_only { " \u{b7} Read Only" } else { "" }),
                if cfg!(target_os = "macos") { "\u{2318}F  Find   \u{b7}   \u{2318}Z  Undo   \u{b7}   \u{2318}S  Save" } else { "Ctrl+F  Find   \u{b7}   Ctrl+Z  Undo   \u{b7}   Ctrl+S  Save" },
            ),
            None => (format!("Neovim \u{b7} {mode}"), if cfg!(target_os = "macos") { "Esc  Normal mode   \u{b7}   i  Insert   \u{b7}   \u{2318}S  Save" } else { "Esc  Normal mode   \u{b7}   i  Insert   \u{b7}   Ctrl+Shift+S  Save" }),
        };
        ui.text(&status, footer.x + ui.px(12.0), middle, 10.0, 400, false, theme::TEXT_SECONDARY);
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
            self.explorer.forget_drawing();
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
            Some(Pane::Document { path, .. }) => crate::pdf::is_pdf(path) || self.native.contains_key(path) || self.editor.as_ref().is_some_and(|editor| editor.can_show(path)),
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
        // The shown shell's working directory, for the status bar (the project folder until it is known).
        {
            let home = home_directory().unwrap_or_default();
            let root = self.explorer.root().to_path_buf();
            let directory = self.tabs.get_mut(self.shown).and_then(|tab| match &mut tab.pane {
                Pane::Terminal(terminal) => terminal.directory().map(std::path::Path::to_path_buf),
                _ => None,
            });
            // "Follow terminal": the tree shows where the shown shell is (the project stays the project).
            if let (true, Some(directory)) = (self.explorer.follow_terminal, &directory) {
                if directory != self.explorer.root() && directory.is_dir() {
                    let options = (self.explorer.visible, self.explorer.compact(), self.explorer.show_hidden(), self.explorer.hide_ignored, self.explorer.reveal_active);
                    self.explorer = Explorer::new(directory.clone());
                    self.explorer.follow_terminal = true;
                    self.explorer_options = Some(options);
                    self.apply_explorer_options();
                    if let Some(shared) = self.shared.upgrade() {
                        self.explorer.attach(&shared);
                    }
                }
            }
            let directory = directory.unwrap_or(root);
            self.shown_directory = match directory.strip_prefix(&home) {
                Ok(rest) if rest.as_os_str().is_empty() => "~".to_string(),
                Ok(rest) => format!("~/{}", rest.display()),
                Err(_) => directory.display().to_string(),
            };
        }
        if let Some(editor) = &self.editor {
            self.explorer.set_diagnostics(editor.all_diagnostics().into_iter().map(|(path, count, errors)| (std::path::PathBuf::from(path), count, errors)).collect());
        }
        // An agent finished a turn: files and Git state may have changed.
        if self.agent.take_finished_turn() {
            self.explorer.refresh();
        }
        self.draw_header(painter);
        self.draw_strip(painter);
        let (pane, focused, period) = (self.pane, self.focused && !(self.agent.focused && self.agent.visible) && !(self.dock.focused && self.dock.visible), frame.period);
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
            Some(Pane::Document { path, .. }) if crate::pdf::is_pdf(path) => {
                // The PDF itself is a native view over this pane; only its bars are drawn here.
                chrome = Some(Some(path.clone()));
                Next::Idle
            }
            Some(Pane::Document { path, .. }) if self.native.contains_key(path.as_str()) => {
                let editor = self.native.get_mut(path.as_str()).expect("checked");
                painter.scene.fill_rect(editor_pane, theme::EDITOR_BACKGROUND);
                let next = editor.build(painter, editor_pane, focused, frame.display, period);
                output = editor.revision();
                chrome = Some(Some(path.clone()));
                next
            }
            Some(Pane::Document { path, .. }) => {
                let mut next = Next::Idle;
                if let Some(editor) = &mut self.editor {
                    next = editor.build(painter, editor_pane, focused, path, frame.display, period);
                    output = editor.drawn_generation();
                }
                chrome = Some(Some(path.clone()));
                next
            }
            None => Next::Idle,
        };
        match chrome {
            Some(None) => self.draw_status_bar(painter, true),
            Some(Some(path)) if crate::pdf::is_pdf(&path) => self.draw_pdf_chrome(painter, &path),
            Some(Some(path)) => self.draw_editor_chrome(painter, &path),
            None => {}
        }
        self.draw_notice(painter);
        self.draw_footer(painter);
        self.window = (frame.size.0 as f32, frame.size.1 as f32);
        let mut next = next;
        // While an SSH tab is shown, its remote files take the project tree's place.
        self.remote_shown = self.tabs.get(self.shown).and_then(Tab::terminal).and_then(|terminal| terminal.remote.clone()).filter(|address| self.remotes.contains_key(address));
        let fetched = self.remote_browser().and_then(|browser| browser.take_fetched());
        if let Some(file) = fetched {
            // A remote file opens as a read-only preview of its downloaded copy.
            self.open_document(&file);
            if let Some(editor) = &mut self.editor {
                editor.input("<C-o>:setlocal readonly nomodifiable<CR>");
            }
        }
        if self.explorer.visible && self.remote_shown.is_some() {
            let (sidebar, scale) = (self.sidebar, frame.scale);
            if let Some(browser) = self.remote_browser() {
                browser.build(painter, sidebar, scale);
            }
        } else if self.explorer.visible {
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
        if self.connections.visible {
            let rect = self.connections_rect;
            let shown = self.tabs.get(self.shown).and_then(Tab::terminal).and_then(|terminal| terminal.remote.clone());
            self.connections.build(painter, rect, frame.scale, shown.as_deref());
        }
        if self.dock.visible {
            let (rect, cell, window_focused) = (self.dock_rect, self.cell, self.focused);
            let dock_next = self.dock.build(painter, rect, frame.scale, cell, window_focused, frame.display, period);
            next = match (next, dock_next) {
                (Next::Soon, _) | (_, Next::Soon) => Next::Soon,
                (Next::At(a), Next::At(b)) => Next::At(a.min(b)),
                (Next::At(a), Next::Idle) | (Next::Idle, Next::At(a)) => Next::At(a),
                (Next::Idle, Next::Idle) => Next::Idle,
            };
        }
        if self.agent.visible {
            let (rect, cell, window_focused) = (self.agent_rect, self.cell, self.focused);
            let context = self.active_document();
            let agent_next = self.agent.build(painter, rect, frame.scale, cell, window_focused, context.as_deref(), frame.display, period);
            next = match (next, agent_next) {
                (Next::Soon, _) | (_, Next::Soon) => Next::Soon,
                (Next::At(a), Next::At(b)) => Next::At(a.min(b)),
                (Next::At(a), Next::Idle) | (Next::Idle, Next::At(a)) => Next::At(a),
                (Next::Idle, Next::Idle) => Next::Idle,
            };
        }
        self.draw_find(painter);
        if let Some(at) = self.draw_monitor(painter, frame.display) {
            next = match next {
                Next::Idle => Next::At(at),
                Next::At(other) => Next::At(other.min(at)),
                Next::Soon => Next::Soon,
            };
        }
        // A modal sheet dims what it covers, so it reads as in front of the workspace.
        if self.creation.is_some() || self.closing.is_some() || self.recent_sheet.is_some() || self.launcher.is_some() || self.git.is_some() || self.connections.sheet_is_open() {
            painter.scene.set_clip(None);
            painter.scene.fill(0.0, 0.0, self.window.0, self.window.1, [0, 0, 0, 90]);
        }
        self.draw_creation(painter);
        self.draw_closing(painter);
        self.draw_recent(painter);
        self.connections.draw_sheet(painter, frame.scale, self.window);
        if let Some(error) = self.connections.take_error() {
            self.notice = Some(error);
        }
        if let Some(mut launcher) = self.launcher.take() {
            let mut ui = Ui { painter, scale: self.scale };
            launcher.draw(&mut ui, self.window);
            self.launcher = Some(launcher);
        }
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
        if let Some(at) = self.draw_tip(painter, frame.display) {
            next = match next {
                Next::Idle => Next::At(at),
                Next::At(other) => Next::At(other.min(at)),
                Next::Soon => Next::Soon,
            };
        }
        // Where the shown PDF's native view goes: over the document pane, unless something drawn by the
        // app (a menu, a sheet) covers the window, which a native view would hide.
        let covered = self.menu.is_some() || self.creation.is_some() || self.search.is_some() || self.git.is_some() || self.closing.is_some() || self.launcher.is_some() || self.recent_sheet.is_some() || self.connections.sheet_is_open();
        let shown_pdf = self.tabs.get(self.shown).and_then(Tab::document).filter(|path| crate::pdf::is_pdf(path)).map(str::to_string);
        let request = crate::pdf::PdfRequest {
            shown: shown_pdf.filter(|_| !covered).map(|path| {
                let scale = self.scale as f64;
                let top = self.toolbar.bottom() as f64;
                let area = [self.center.x as f64 / scale, top / scale, self.center.width as f64 / scale, (self.editor_footer.y as f64 - top) / scale];
                (path, area)
            }),
            open: self.tabs.iter().filter_map(Tab::document).filter(|path| crate::pdf::is_pdf(path)).map(str::to_string).collect(),
        };
        if request != self.pdf_request {
            self.pdf_request = request;
            if let Some(callback) = &self.on_layout {
                callback();
            }
        }
        let (scroll_lines, input_lines) = self.scroll_lines();
        self.marks = FrameMarks { scroll_lines, input_lines, output, selection: self.shown_selection, instances: 0 };
        // Everything that decides a pixel of this frame. Equal to the last one: nothing to present.
        let mut signature = Signature::new();
        signature.add(frame.size.0 as u64).add(frame.size.1 as u64).add(self.cell.width.to_bits() as u64).add(self.cell.height.to_bits() as u64);
        signature.add(self.shown as u64).add(self.shown_selection).add(self.focused as u64).add(self.hover.map_or(u64::MAX, |index| index as u64));
        signature.add(self.hover_close.map_or(u64::MAX, |index| index as u64)).add(self.font_points.to_bits() as u64);
        signature.add(self.tabs.get(self.shown).and_then(Tab::terminal).map_or(0, Terminal::look)).text(&self.shown_directory);
        if let Some(editor) = &self.editor {
            // A scroll within one line changes no cell, only where the text is drawn.
            signature.text(editor.mode_label()).add(editor.drawn_position.to_bits()).add(editor.horizontal_signature());
        }
        signature.add(output).text(self.notice.as_deref().unwrap_or(""));
        signature.add(self.explorer.signature());
        if let Some(monitor) = &self.monitor {
            signature.add(monitor.sampled_at.to_bits());
        }
        signature.add(self.strip_scroll.to_bits() as u64).add(self.connections.signature()).text(&self.pdf_label);
        if let Some((query, found)) = &self.find {
            signature.add(0x46494E44 + *found as u64).text(query);
        }
        if let Some(browser) = self.remote_shown.as_ref().and_then(|address| self.remotes.get(address)) {
            signature.add(0x53465450).add(browser.signature());
        }
        if let Some((text, since)) = &self.tip {
            // The same text before and after its delay is a different picture.
            signature.add((frame.display.max(crate::clock::now()) >= since + 0.8) as u64 + 3).text(text).add(self.pointer.0.to_bits() as u64);
        }
        signature.add(self.recent.len() as u64 ^ (self.recent_sheet.is_some() as u64) << 20);
        signature.add(self.explorer_points.to_bits() as u64).add(self.agent.signature()).add(self.dock.signature());
        if let Some(launcher) = &self.launcher {
            signature.add(0x4C41554E).add(launcher.signature());
        }
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
                        signature.add(terminal.scroll().to_bits()).add(terminal.program_position(self.cell.height as f64).to_bits());
                    }
                }
                Pane::Document { path, .. } => {
                    signature.text(path).add(self.doc_modified(path) as u64);
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
