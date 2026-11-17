//! The remote file browser (the Swift app's SFTP browser), shown in place of the project tree while an
//! SSH tab is selected. It drives the system's `sftp` in batch mode over the connection the tab's `ssh`
//! opened (OpenSSH connection sharing), so whatever signed the tab in (a key, an agent, a password
//! typed in the terminal) serves the browser too. Transfers are `sftp`'s own, streamed to and from disk.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Weak};

use neolink_core::sessions::Connection;
use neolink_core::sftp::{join, parent, parse_listing, quote, size_label, valid_name, RemoteEntry};
use parking_lot::Mutex;
use winit::keyboard::{Key, NamedKey};

use crate::chrome::{faded, Ui};
use crate::frame::{Painter, Shared};
use crate::icons::IconWeight;
use crate::menu::{Action, Item, Menu};
use crate::render::Rect;
use crate::theme;

/// The socket both the tab's `ssh` and the browser's `sftp` use for one connection.
pub fn control_path(connection: &Connection) -> PathBuf {
    let directory = std::env::temp_dir().join(format!("neolink-ssh-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&directory);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700));
    }
    // Short: socket paths are limited to about a hundred bytes.
    let mut hash = 0xcbf29ce484222325u64;
    for byte in format!("{}:{}", connection.address(), connection.port).bytes() {
        hash = (hash ^ byte as u64).wrapping_mul(0x100000001b3);
    }
    directory.join(format!("{hash:016x}"))
}

/// Options that make `ssh` share its connection (for the tab) or use the shared one (for `sftp`).
pub fn sharing_options(connection: &Connection) -> Vec<String> {
    if cfg!(windows) {
        // OpenSSH for Windows has no connection sharing.
        return Vec::new();
    }
    vec!["-o".into(), "ControlMaster=auto".into(), "-o".into(), format!("ControlPath={}", control_path(connection).display()), "-o".into(), "ControlPersist=600".into()]
}

/// Extra `ssh`/`sftp` options for tests against a private server (`NEOLINK_SSH_OPTIONS`, split at spaces).
fn extra_options() -> Vec<String> {
    std::env::var("NEOLINK_SSH_OPTIONS").map(|options| options.split_whitespace().map(str::to_string).collect()).unwrap_or_default()
}

/// Runs `commands` (one per line) through `sftp`. Returns its output, or what it said went wrong.
fn batch(connection: &Connection, commands: &str) -> Result<String, String> {
    use std::io::Write;
    let mut command = std::process::Command::new("sftp");
    command.args(["-q", "-b", "-", "-P", &connection.port.to_string(), "-o", "BatchMode=yes"]).args(sharing_options(connection)).args(extra_options()).arg(format!("{}@{}", connection.username, connection.host));
    let mut child = command.stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped()).spawn().map_err(|error| format!("sftp could not be started: {error}"))?;
    if let Some(mut input) = child.stdin.take() {
        let _ = input.write_all(commands.as_bytes());
    }
    let output = child.wait_with_output().map_err(|error| error.to_string())?;
    let text = String::from_utf8_lossy(&output.stdout).into_owned();
    if output.status.success() {
        return Ok(text);
    }
    let errors = String::from_utf8_lossy(&output.stderr);
    let message = errors.lines().filter(|line| !line.trim().is_empty() && !line.contains("BSM audit")).last().unwrap_or("The remote file operation failed.").trim().to_string();
    Err(if message.contains("Permission denied (") || message.contains("Connection closed") { format!("{message} Sign in from this connection's terminal tab first; the browser uses that connection.") } else { message })
}

enum Command {
    List(String),
    /// Commands to run, then list this directory again.
    Run { commands: String, then: String, done: Option<String> },
    /// Download a file to a temporary place and report it for opening.
    Fetch { remote: String, local: PathBuf },
}

#[derive(Default)]
struct State {
    path: String,
    entries: Vec<RemoteEntry>,
    loading: bool,
    error: Option<String>,
    notice: Option<String>,
    /// A downloaded file waiting to be opened as a read-only tab.
    fetched: Option<PathBuf>,
    revision: u64,
}

pub enum Outcome {
    Nothing,
    Menu(Menu),
    /// Ask for local files to upload, or a folder to download into (`true`).
    Choose(bool),
    Disconnect,
}

#[derive(Clone, PartialEq)]
enum Prompt {
    NewFile,
    NewFolder,
    Rename(String),
}

pub struct RemoteBrowser {
    pub connection: Connection,
    state: Arc<Mutex<State>>,
    commands: Sender<Command>,
    prompt: Option<(Prompt, String)>,
    selected: Option<String>,
    /// The entry a download was asked for, until the folder to put it in is chosen.
    pending_download: Option<String>,
    scroll: f32,
    rect: Rect,
    list: Rect,
    rows: Vec<Rect>,
    buttons: Vec<(Rect, &'static str)>,
}

impl RemoteBrowser {
    pub fn new(connection: Connection, shared: Weak<Shared>) -> RemoteBrowser {
        let state = Arc::new(Mutex::new(State { loading: true, ..State::default() }));
        let (commands, incoming) = channel::<Command>();
        let (worker_state, worker_connection) = (state.clone(), connection.clone());
        let _ = std::thread::Builder::new().name("sftp".into()).spawn(move || {
            let publish = |change: &mut dyn FnMut(&mut State)| {
                let mut state = worker_state.lock();
                change(&mut state);
                state.revision += 1;
                drop(state);
                if let Some(shared) = shared.upgrade() {
                    shared.invalidate();
                }
            };
            let list = |path: &str| {
                publish(&mut |state| state.loading = true);
                // An empty path asks where the session starts.
                let result = if path.is_empty() {
                    batch(&worker_connection, "pwd\n").map(|output| output.lines().find_map(|line| line.strip_prefix("Remote working directory: ").map(str::to_string)).unwrap_or_else(|| "/".into())).and_then(|home| batch(&worker_connection, &format!("cd {}\nls -lan\n", quote(&home))).map(|output| (home, output)))
                } else {
                    // Listed from inside the folder, so the names come without their path.
                    batch(&worker_connection, &format!("cd {}\nls -lan\n", quote(path))).map(|output| (path.to_string(), output))
                };
                publish(&mut |state| {
                    state.loading = false;
                    match &result {
                        Ok((path, output)) => {
                            state.path = path.clone();
                            state.entries = parse_listing(output);
                            state.error = None;
                        }
                        Err(error) => state.error = Some(error.clone()),
                    }
                });
            };
            list("");
            while let Ok(command) = incoming.recv() {
                match command {
                    Command::List(path) => list(&path),
                    Command::Run { commands, then, done } => {
                        publish(&mut |state| {
                            state.loading = true;
                            state.notice = None;
                        });
                        let result = batch(&worker_connection, &commands);
                        publish(&mut |state| match &result {
                            Ok(_) => state.notice = done.clone(),
                            Err(error) => state.error = Some(error.clone()),
                        });
                        if result.is_ok() {
                            list(&then);
                        } else {
                            publish(&mut |state| state.loading = false);
                        }
                    }
                    Command::Fetch { remote, local } => {
                        publish(&mut |state| state.loading = true);
                        let result = batch(&worker_connection, &format!("get {} {}\n", quote(&remote), quote(&local.to_string_lossy())));
                        publish(&mut |state| {
                            state.loading = false;
                            match &result {
                                Ok(_) => state.fetched = Some(local.clone()),
                                Err(error) => state.error = Some(error.clone()),
                            }
                        });
                    }
                }
            }
        });
        RemoteBrowser { connection, state, commands, prompt: None, selected: None, pending_download: None, scroll: 0.0, rect: Rect::default(), list: Rect::default(), rows: Vec::new(), buttons: Vec::new() }
    }

    pub fn contains(&self, x: f32, y: f32) -> bool {
        self.rect.contains(x, y)
    }

    pub fn prompting(&self) -> bool {
        self.prompt.is_some()
    }

    fn path(&self) -> String {
        self.state.lock().path.clone()
    }

    fn refresh(&self) {
        let _ = self.commands.send(Command::List(self.path()));
    }

    /// A downloaded file to open as a read-only tab, once.
    pub fn take_fetched(&mut self) -> Option<PathBuf> {
        self.state.lock().fetched.take()
    }

    /// Uploads local files and folders into the shown directory.
    pub fn upload(&mut self, files: &[PathBuf]) {
        let directory = self.path();
        let mut commands = String::new();
        for file in files {
            let Some(name) = file.file_name().map(|name| name.to_string_lossy().into_owned()) else { continue };
            commands.push_str(&format!("put {}{} {}\n", if file.is_dir() { "-r " } else { "" }, quote(&file.to_string_lossy()), quote(&join(&directory, &name))));
        }
        if !commands.is_empty() {
            let _ = self.commands.send(Command::Run { commands, then: directory, done: Some(format!("Uploaded {} {}.", files.len(), if files.len() == 1 { "item" } else { "items" })) });
        }
    }

    /// Downloads the entry chosen earlier into the local `folder`.
    pub fn download_into(&mut self, folder: &Path) {
        let Some(name) = self.pending_download.take() else { return };
        let directory = self.path();
        let is_directory = self.state.lock().entries.iter().any(|entry| entry.name == name && entry.is_directory);
        let commands = format!("get {}{} {}\n", if is_directory { "-r " } else { "" }, quote(&join(&directory, &name)), quote(&folder.join(&name).to_string_lossy()));
        let _ = self.commands.send(Command::Run { commands, then: directory, done: Some(format!("Downloaded {name} to {}.", folder.display())) });
    }

    /// A choice from a row's menu.
    pub fn perform(&mut self, what: &str, name: &str) -> Outcome {
        let directory = self.path();
        match what {
            "open" => self.activate(name),
            "download" => {
                self.pending_download = Some(name.to_string());
                return Outcome::Choose(true);
            }
            "rename" => self.prompt = Some((Prompt::Rename(name.to_string()), name.to_string())),
            "delete" => {
                let is_directory = self.state.lock().entries.iter().any(|entry| entry.name == name && entry.is_directory);
                let commands = format!("{} {}\n", if is_directory { "rmdir" } else { "rm" }, quote(&join(&directory, name)));
                let _ = self.commands.send(Command::Run { commands, then: directory, done: None });
            }
            "new-file" => self.prompt = Some((Prompt::NewFile, String::new())),
            "new-folder" => self.prompt = Some((Prompt::NewFolder, String::new())),
            "upload" => return Outcome::Choose(false),
            _ => {}
        }
        Outcome::Nothing
    }

    /// Opens a folder, or downloads a file for a read-only tab.
    fn activate(&mut self, name: &str) {
        let directory = self.path();
        let entry = self.state.lock().entries.iter().find(|entry| entry.name == name).cloned();
        let Some(entry) = entry else { return };
        if entry.is_directory || entry.is_link {
            self.scroll = 0.0;
            let _ = self.commands.send(Command::List(join(&directory, name)));
        } else if entry.size > 8 * 1024 * 1024 {
            self.state.lock().error = Some("Remote previews are limited to 8 MB. Download the file instead.".into());
        } else {
            // A place of its own per host and folder, so names never collide.
            let mut hash = 0xcbf29ce484222325u64;
            for byte in format!("{}:{}{directory}", self.connection.address(), self.connection.port).bytes() {
                hash = (hash ^ byte as u64).wrapping_mul(0x100000001b3);
            }
            let folder = std::env::temp_dir().join(format!("neolink-remote-{}", std::process::id())).join(format!("{hash:016x}"));
            let _ = std::fs::create_dir_all(&folder);
            let _ = self.commands.send(Command::Fetch { remote: join(&directory, name), local: folder.join(name) });
        }
    }

    fn submit_prompt(&mut self) {
        let Some((prompt, name)) = self.prompt.take_if(|(_, name)| valid_name(name)) else { return };
        let directory = self.path();
        let target = quote(&join(&directory, name.trim()));
        let commands = match &prompt {
            Prompt::NewFolder => format!("mkdir {target}\n"),
            Prompt::NewFile => {
                // An empty local file is put in place; nothing existing is replaced.
                if self.state.lock().entries.iter().any(|entry| entry.name == name.trim()) {
                    self.state.lock().error = Some("An item with that name already exists. Choose another name.".into());
                    return;
                }
                let empty = std::env::temp_dir().join(format!("neolink-empty-{}", std::process::id()));
                let _ = std::fs::write(&empty, b"");
                format!("put {} {target}\n", quote(&empty.to_string_lossy()))
            }
            Prompt::Rename(old) => {
                if self.state.lock().entries.iter().any(|entry| entry.name == name.trim()) {
                    self.state.lock().error = Some("An item with that name already exists. Choose another name.".into());
                    return;
                }
                format!("rename {} {target}\n", quote(&join(&directory, old)))
            }
        };
        let _ = self.commands.send(Command::Run { commands, then: directory, done: None });
    }

    /// A key while a name is being asked for. Returns `true` if it was used.
    pub fn key(&mut self, key: &Key, text: Option<&str>) -> bool {
        let Some((_, name)) = &mut self.prompt else { return false };
        match key {
            Key::Named(NamedKey::Escape) => self.prompt = None,
            Key::Named(NamedKey::Enter) => self.submit_prompt(),
            Key::Named(NamedKey::Backspace) => {
                name.pop();
            }
            _ => {
                if let Some(text) = text.filter(|text| !text.chars().any(char::is_control)) {
                    name.push_str(text);
                }
            }
        }
        self.state.lock().revision += 1;
        true
    }

    pub fn click(&mut self, x: f32, y: f32, right: bool) -> Outcome {
        self.state.lock().revision += 1;
        let entries = self.state.lock().entries.clone();
        let row = self.rows.iter().position(|rect| rect.contains(x, y)).and_then(|index| entries.get(index).cloned());
        if right {
            let line = 1.0;
            let anchor = Rect::new(x, y - line, line, line);
            let entry = |label: &str, what: &'static str, name: &str| Item::entry(label, Action::Remote(what, name.to_string()));
            return Outcome::Menu(Menu::new(
                anchor,
                match &row {
                    Some(row) => {
                        self.selected = Some(row.name.clone());
                        vec![entry(if row.is_directory { "Open Folder" } else { "Open Read-Only in Tab" }, "open", &row.name), entry("Download\u{2026}", "download", &row.name), Item::Separator, entry("Rename\u{2026}", "rename", &row.name), entry("Delete", "delete", &row.name)]
                    }
                    None => vec![entry("New File\u{2026}", "new-file", ""), entry("New Folder\u{2026}", "new-folder", ""), Item::Separator, entry("Upload\u{2026}", "upload", "")],
                },
            ));
        }
        if let Some((rect, what)) = self.buttons.iter().find(|(rect, _)| rect.contains(x, y)).copied() {
            match what {
                "up" => {
                    self.scroll = 0.0;
                    let _ = self.commands.send(Command::List(parent(&self.path())));
                }
                "refresh" => self.refresh(),
                "new" => return Outcome::Menu(Menu::new(rect, vec![Item::entry("New File\u{2026}", Action::Remote("new-file", String::new())), Item::entry("New Folder\u{2026}", Action::Remote("new-folder", String::new())), Item::Separator, Item::entry("Upload\u{2026}", Action::Remote("upload", String::new()))])),
                "disconnect" => return Outcome::Disconnect,
                "dismiss" => {
                    let mut state = self.state.lock();
                    state.error = None;
                    state.notice = None;
                }
                _ => {}
            }
            return Outcome::Nothing;
        }
        if let Some(row) = row {
            self.selected = Some(row.name.clone());
            self.activate(&row.name);
        }
        Outcome::Nothing
    }

    pub fn scroll(&mut self, delta: f32) {
        self.scroll -= delta;
        self.state.lock().revision += 1;
    }

    pub fn control_rect(&self, name: &str) -> Option<Rect> {
        if let Some(index) = name.strip_prefix("row:").and_then(|index| index.parse::<usize>().ok()) {
            return self.rows.get(index).copied();
        }
        if name == "list" {
            return Some(Rect::new(self.list.x, self.list.bottom() - 40.0, self.list.width, 40.0));
        }
        self.buttons.iter().find(|(_, what)| *what == name).map(|(rect, _)| *rect)
    }

    pub fn signature(&self) -> u64 {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        (self.state.lock().revision, &self.selected, self.scroll.to_bits(), self.prompt.as_ref().map(|prompt| &prompt.1)).hash(&mut hasher);
        hasher.finish()
    }

    pub fn build(&mut self, painter: &mut Painter, rect: Rect, scale: f32) {
        self.rect = rect;
        self.buttons.clear();
        self.rows.clear();
        let state = self.state.lock();
        let mut ui = Ui { painter, scale };
        let line = ui.px(1.0).max(1.0);
        ui.fill(rect, theme::SIDEBAR_BACKGROUND);
        ui.painter.scene.fill(rect.right(), rect.y, line, rect.height, theme::SEPARATOR);
        // Header: EXPLORER, SFTP, disconnect.
        let header = Rect::new(rect.x, rect.y, rect.width, ui.px(34.0));
        let middle = header.y + header.height * 0.5;
        ui.text("E X P L O R E R".replace(' ', "\u{200a}").as_str(), rect.x + ui.px(12.0), middle, 10.0, 500, false, theme::TEXT_PRIMARY);
        let button = ui.px(28.0);
        let disconnect = Rect::new(rect.right() - ui.px(12.0) - button, middle - button * 0.5, button, button);
        ui.icon("xmark.circle", 12.0, IconWeight::Medium, disconnect.x + button * 0.5, middle, theme::TEXT_SECONDARY);
        self.buttons.push((disconnect, "disconnect"));
        ui.text_right("SFTP", disconnect.x - ui.px(8.0 + 7.0), middle, 9.0, 600, true, theme::TEXT_SECONDARY);
        ui.painter.scene.fill(rect.x, header.bottom(), rect.width, line, theme::SEPARATOR);
        // Connection line and path bar.
        let inset = ui.px(8.0);
        let mut y = header.bottom() + line + ui.px(6.0);
        let address = format!("{}:{}", self.connection.address(), self.connection.port);
        let server = ui.icon("server.rack", 11.0, IconWeight::Regular, rect.x + inset + ui.px(8.0), y + ui.px(9.0), theme::ACCENT).max(ui.px(16.0));
        let address = ui.fit_middle(&address, rect.width - 2.0 * inset - server - ui.px(8.0), 11.0, 500, true);
        ui.text(&address, rect.x + inset + server + ui.px(6.0), y + ui.px(9.0), 11.0, 500, true, theme::TEXT_PRIMARY);
        y += ui.px(18.0 + 6.0);
        let bar_middle = y + ui.px(12.0);
        let slot = ui.px(22.0);
        let up = Rect::new(rect.x + inset, y, slot, ui.px(24.0));
        ui.icon("arrow.up", 11.0, IconWeight::Medium, up.x + slot * 0.5, bar_middle, if state.path == "/" { faded(theme::TEXT_SECONDARY, 0.4) } else { theme::TEXT_SECONDARY });
        self.buttons.push((up, "up"));
        let mut right = rect.right() - inset;
        for (symbol, what) in [("plus", "new"), ("arrow.clockwise", "refresh")] {
            let area = Rect::new(right - slot, y, slot, ui.px(24.0));
            ui.icon(symbol, 12.0, IconWeight::Regular, area.x + slot * 0.5, bar_middle, theme::TEXT_SECONDARY);
            self.buttons.push((area, what));
            right -= slot + ui.px(6.0);
        }
        let path_x = up.right() + ui.px(6.0);
        let path = if state.path.is_empty() { "Connecting\u{2026}".to_string() } else { state.path.clone() };
        let path = ui.fit_middle(&path, (right - path_x).max(1.0), 11.0, 400, true);
        ui.text(&path, path_x, bar_middle, 11.0, 400, true, theme::TEXT_SECONDARY);
        y += ui.px(24.0 + 6.0);
        // A name being asked for.
        if let Some((prompt, name)) = &self.prompt {
            let field = Rect::new(rect.x + inset, y, rect.width - 2.0 * inset, ui.px(27.0));
            ui.rounded(field, 4.0, theme::rgb(0x161616));
            ui.outline(field, 4.0, theme::rgb(0x2F6FDB));
            let field_middle = field.y + field.height * 0.5;
            let end = if name.is_empty() {
                ui.text(match prompt {
                    Prompt::NewFile => "New file name",
                    Prompt::NewFolder => "New folder name",
                    Prompt::Rename(_) => "New name",
                }, field.x + ui.px(8.0), field_middle, 11.0, 400, false, faded(theme::TEXT_SECONDARY, 0.7));
                0.0
            } else {
                ui.text(name, field.x + ui.px(8.0), field_middle, 11.0, 400, false, theme::TEXT_PRIMARY) + line
            };
            ui.painter.scene.fill(field.x + ui.px(8.0) + end, field_middle - ui.px(7.0), line.max(2.0), ui.px(14.0), theme::ACCENT);
            y += ui.px(27.0 + 6.0);
        }
        // An error or a note, dismissed by pressing it.
        if let Some((text, color)) = state.error.as_ref().map(|text| (text, theme::rgb(0xC6B28E))).or(state.notice.as_ref().map(|text| (text, theme::TEXT_SECONDARY))) {
            let wrap_width = rect.width - 2.0 * inset - ui.px(16.0);
            let wrapped = crate::agents::wrap(&mut ui, text, wrap_width, 10.0);
            let height = wrapped.len().min(5) as f32 * ui.px(13.0) + ui.px(12.0);
            let card = Rect::new(rect.x + inset, y, rect.width - 2.0 * inset, height);
            ui.rounded(card, 7.0, faded(color, 0.1));
            for (index, part) in wrapped.iter().take(5).enumerate() {
                ui.text(part, card.x + ui.px(8.0), card.y + ui.px(6.0 + 6.5) + index as f32 * ui.px(13.0), 10.0, 400, false, color);
            }
            self.buttons.push((card, "dismiss"));
            y += height + ui.px(6.0);
        }
        // Rows.
        let footer_height = ui.px(28.0);
        let list = Rect::new(rect.x, y, rect.width, (rect.bottom() - footer_height - y).max(1.0));
        self.list = list;
        let row_height = ui.px(24.0);
        self.scroll = self.scroll.clamp(0.0, (state.entries.len() as f32 * row_height - list.height).max(0.0));
        ui.painter.scene.set_clip(Some(list));
        for (index, entry) in state.entries.iter().enumerate() {
            let row = Rect::new(rect.x, list.y + index as f32 * row_height - self.scroll.round(), rect.width, row_height);
            self.rows.push(Rect::new(row.x, row.y.max(list.y), row.width, (row.bottom().min(list.bottom()) - row.y.max(list.y)).max(0.0)));
            if row.bottom() < list.y || row.y > list.bottom() {
                continue;
            }
            if self.selected.as_deref() == Some(entry.name.as_str()) {
                ui.fill(row, theme::SELECTION);
            }
            let row_middle = row.y + row.height * 0.5;
            let symbol = if entry.is_directory { "folder" } else if entry.is_link { "arrow.turn.down.right" } else { "doc" };
            ui.icon(symbol, 12.0, IconWeight::Regular, row.x + ui.px(8.0 + 15.0 + 8.5), row_middle, theme::TEXT_SECONDARY);
            let mut right = row.right() - ui.px(8.0);
            if !entry.is_directory {
                right -= ui.text_right(&size_label(entry.size), right, row_middle, 10.0, 400, true, theme::TEXT_SECONDARY) + ui.px(8.0);
            }
            let name_x = row.x + ui.px(8.0 + 37.0);
            let name = ui.fit_middle(&entry.name, (right - name_x).max(1.0), 12.0, 400, false);
            ui.text(&name, name_x, row_middle, 12.0, 400, false, theme::TEXT_PRIMARY);
        }
        if state.entries.is_empty() && !state.loading && state.error.is_none() {
            ui.text("This folder is empty", rect.x + ui.px(16.0), list.y + ui.px(18.0), 12.0, 400, false, theme::TEXT_SECONDARY);
        }
        ui.painter.scene.set_clip(None);
        // Footer.
        let footer = Rect::new(rect.x, rect.bottom() - footer_height, rect.width, footer_height);
        ui.painter.scene.fill(rect.x + inset, footer.y, rect.width - 2.0 * inset, line, theme::SEPARATOR);
        let footer_middle = footer.y + ui.px(4.0) + (footer.height - ui.px(4.0)) * 0.5;
        ui.text(if state.loading { "Working\u{2026}" } else { "Remote files \u{b7} previews are read-only" }, rect.x + inset, footer_middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        ui.text_right(&format!("{} items", state.entries.len()), rect.right() - inset, footer_middle, 10.0, 400, false, theme::TEXT_SECONDARY);
    }
}
