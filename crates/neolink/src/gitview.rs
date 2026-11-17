//! Source Control (the Swift app's `GitChangesView`): changed files, a coloured diff, stage / unstage,
//! commit, branches and stashes. Git runs on its own thread; nothing here forces, discards or pushes.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Weak};

use neolink_core::git::{parse_changes, plausible_branch_name, valid_object_id, Change};
use parking_lot::Mutex;
use winit::keyboard::{Key, NamedKey};

use crate::chrome::{faded, Ui};
use crate::frame::Shared;
use crate::icons::IconWeight;
use crate::menu::{Action, Item, Menu};
use crate::render::Rect;
use crate::theme;

#[derive(Clone, Debug, PartialEq)]
pub struct Stash {
    pub id: String,
    pub title: String,
}

#[derive(Clone, Default)]
struct Snapshot {
    root: PathBuf,
    branch: String,
    changes: Vec<Change>,
    branches: Vec<String>,
    stashes: Vec<Stash>,
}

#[derive(Default)]
struct State {
    snapshot: Option<Snapshot>,
    /// The diff, and which request it answers.
    patch: String,
    patch_for: u64,
    error: Option<String>,
    loading: bool,
    mutating: bool,
    /// Counts snapshots, so the view can tell a new one from the one it laid out.
    snapshots: u64,
    revision: u64,
    committed: u64,
}

enum Command {
    Reload,
    Diff { request: u64, root: PathBuf, change: Option<Change>, staged: bool, stash: Option<String> },
    Stage(PathBuf, Change),
    Unstage(PathBuf, Change),
    Commit(PathBuf, String),
    Switch { root: PathBuf, name: String, create: bool },
    /// A mutation refused before it started.
    Refuse(String),
}

/// What the sheet asks of the workspace.
pub enum Outcome {
    Stay,
    Close,
    Open(PathBuf),
    Menu(Menu),
}

const TOO_LARGE: &str = "This Git result exceeds the preview limit. Review it in a terminal.";

fn git(directory: &Path, arguments: &[&str], accepts_difference: bool) -> Result<String, String> {
    let program = if cfg!(target_os = "macos") { "/usr/bin/git" } else { "git" };
    let output = std::process::Command::new(program).args(["--no-pager", "--literal-pathspecs", "-C"]).arg(directory).args(arguments).stdin(std::process::Stdio::null()).output().map_err(|error| format!("Git could not be started: {error}"))?;
    if output.stdout.len() > 1024 * 1024 {
        return Err(TOO_LARGE.into());
    }
    let code = output.status.code().unwrap_or(-1);
    if code == 0 || (accepts_difference && code == 1) {
        return Ok(String::from_utf8_lossy(&output.stdout).into_owned());
    }
    let text = if output.stdout.is_empty() { String::from_utf8_lossy(&output.stderr).trim().to_string() } else { String::from_utf8_lossy(&output.stdout).trim().to_string() };
    Err(if text.is_empty() { format!("Git failed with exit code {code}.") } else { text })
}

fn snapshot(directory: &Path) -> Result<Snapshot, String> {
    let root = PathBuf::from(git(directory, &["rev-parse", "--show-toplevel"], false)?.trim_end_matches(['\n', '\r']));
    let changes = parse_changes(git(&root, &["status", "--porcelain=v1", "-z", "--untracked-files=all"], false)?.as_bytes());
    let branch = git(&root, &["rev-parse", "--abbrev-ref", "HEAD"], false).map(|name| name.trim().to_string()).unwrap_or_else(|_| "No commits yet".into());
    let branches = git(&root, &["for-each-ref", "--format=%(refname:short)", "refs/heads/"], false)?.lines().map(str::to_string).collect();
    let listed = git(&root, &["stash", "list", "-z", "--format=%H%x00%gs"], false)?;
    let fields: Vec<&str> = listed.split('\0').collect();
    let mut stashes = Vec::new();
    for pair in fields.chunks(2) {
        if let [hash, title] = pair {
            let hash = hash.trim_matches(['\n', '\r']);
            if valid_object_id(hash) {
                stashes.push(Stash { id: hash.to_string(), title: title.to_string() });
            }
        }
    }
    Ok(Snapshot { root, branch, changes, branches, stashes })
}

fn paths(change: &Change, include_original: bool) -> Result<Vec<&str>, String> {
    if !change.has_safe_paths() {
        return Err("Invalid repository-relative path.".into());
    }
    let mut values = vec![change.path.as_str()];
    if include_original {
        values.extend(change.original.as_deref());
    }
    Ok(values)
}

fn stage(root: &Path, change: &Change) -> Result<(), String> {
    let mut arguments = vec!["add", "-A", "--"];
    arguments.extend(paths(change, matches!(change.worktree, 'R' | 'C'))?);
    git(root, &arguments, false).map(|_| ())
}

fn unstage(root: &Path, change: &Change) -> Result<(), String> {
    let values = paths(change, matches!(change.index, 'R' | 'C'))?;
    // Before the first commit there is no HEAD to restore from; `--cached` removes only index entries.
    let mut arguments = if git(root, &["rev-parse", "--verify", "HEAD"], false).is_ok() { vec!["restore", "--staged", "--source=HEAD", "--"] } else { vec!["rm", "--cached", "-f", "--"] };
    arguments.extend(values);
    git(root, &arguments, false).map(|_| ())
}

fn commit(root: &Path, message: &str) -> Result<(), String> {
    if message.trim().is_empty() || message.contains('\0') || message.len() > 64 * 1024 {
        return Err("Enter a commit message smaller than 64 KB.".into());
    }
    let directory = std::env::temp_dir().join(format!("NeoLink-commit-{}-{}", std::process::id(), crate::clock::now().to_bits()));
    std::fs::create_dir(&directory).map_err(|error| error.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700));
    }
    let file = directory.join("message");
    let result = std::fs::write(&file, message).map_err(|error| error.to_string()).and_then(|_| git(root, &["commit", "--file", &file.to_string_lossy()], false).map(|_| ()));
    let _ = std::fs::remove_dir_all(&directory);
    result
}

fn switch_branch(root: &Path, name: &str, create: bool) -> Result<(), String> {
    if !plausible_branch_name(name) {
        return Err("Enter a valid local branch name.".into());
    }
    git(root, &["check-ref-format", "--branch", name], false)?;
    // Never force, discard changes, or implicitly create a tracking branch.
    let arguments: Vec<&str> = if create { vec!["switch", "--no-guess", "-c", name] } else { vec!["switch", "--no-guess", name] };
    git(root, &arguments, false).map(|_| ())
}

fn diff(root: &Path, change: &Change, staged: bool) -> Result<String, String> {
    let mut arguments = vec!["diff", "--no-ext-diff", "--no-textconv", "--no-color"];
    let absolute = root.join(&change.path).to_string_lossy().into_owned();
    let null = if cfg!(windows) { "NUL" } else { "/dev/null" };
    if change.untracked() {
        arguments.extend(["--no-index", "--", null, absolute.as_str()]);
    } else {
        if staged {
            arguments.push("--cached");
        }
        arguments.push("--");
        arguments.push(&change.path);
        arguments.extend(change.original.as_deref());
    }
    git(root, &arguments, change.untracked())
}

#[derive(Clone, Copy, PartialEq)]
enum Focus {
    Commit,
    Branch,
}

pub struct GitSheet {
    directory: PathBuf,
    state: Arc<Mutex<State>>,
    commands: Sender<Command>,
    selected: Option<String>,
    selected_stash: Option<String>,
    staged: bool,
    commit_message: String,
    branch_name: String,
    focus: Focus,
    seen_snapshot: u64,
    seen_commit: u64,
    diff_request: u64,
    list_scroll: f32,
    diff_scroll: (f32, f32),
    frame: Rect,
    list: Rect,
    preview: Rect,
    rows: Vec<Rect>,
    buttons: Vec<(Rect, &'static str)>,
}

impl GitSheet {
    pub fn new(directory: &Path, shared: Weak<Shared>) -> GitSheet {
        let state = Arc::new(Mutex::new(State { loading: true, ..State::default() }));
        let (commands, incoming) = channel::<Command>();
        let (worker_state, worker_directory) = (state.clone(), directory.to_path_buf());
        let _ = std::thread::Builder::new().name("git".into()).spawn(move || {
            let publish = |change: &mut dyn FnMut(&mut State)| {
                let mut state = worker_state.lock();
                change(&mut state);
                state.revision += 1;
                drop(state);
                if let Some(shared) = shared.upgrade() {
                    shared.invalidate();
                }
            };
            let reload = |publish: &dyn Fn(&mut dyn FnMut(&mut State))| {
                publish(&mut |state| state.loading = true);
                let result = snapshot(&worker_directory);
                publish(&mut |state| {
                    state.loading = false;
                    state.mutating = false;
                    match &result {
                        Ok(snapshot) => {
                            state.snapshot = Some(snapshot.clone());
                            state.snapshots += 1;
                        }
                        Err(error) => state.error = Some(error.clone()),
                    }
                });
            };
            reload(&publish);
            while let Ok(command) = incoming.recv() {
                let mutation: Result<(), String> = match command {
                    Command::Reload => {
                        publish(&mut |state| state.error = None);
                        reload(&publish);
                        continue;
                    }
                    Command::Diff { request, root, change, staged, stash } => {
                        let text = match (&stash, &change) {
                            (Some(id), _) if valid_object_id(id) => git(&root, &["stash", "show", "--patch", "--include-untracked", "--no-ext-diff", "--no-textconv", "--no-color", id], false),
                            (Some(_), _) => Err("Invalid stash identity.".into()),
                            (None, Some(change)) => diff(&root, change, staged),
                            (None, None) => Ok(String::new()),
                        };
                        publish(&mut |state| {
                            state.patch_for = request;
                            state.patch = match &text {
                                Ok(text) if text.is_empty() && (stash.is_some() || change.is_some()) => "No textual changes in this view.".into(),
                                Ok(text) => text.clone(),
                                Err(error) => error.clone(),
                            };
                        });
                        continue;
                    }
                    Command::Refuse(reason) => Err(reason),
                    Command::Stage(root, change) => stage(&root, &change),
                    Command::Unstage(root, change) => unstage(&root, &change),
                    Command::Commit(root, message) => {
                        let result = commit(&root, &message);
                        if result.is_ok() {
                            publish(&mut |state| state.committed += 1);
                        }
                        result
                    }
                    Command::Switch { root, name, create } => switch_branch(&root, &name, create),
                };
                publish(&mut |state| state.error = mutation.as_ref().err().cloned());
                reload(&publish);
            }
        });
        GitSheet {
            directory: directory.to_path_buf(),
            state,
            commands,
            selected: None,
            selected_stash: None,
            staged: false,
            commit_message: String::new(),
            branch_name: String::new(),
            focus: Focus::Commit,
            seen_snapshot: 0,
            seen_commit: 0,
            diff_request: 0,
            list_scroll: 0.0,
            diff_scroll: (0.0, 0.0),
            frame: Rect::default(),
            list: Rect::default(),
            preview: Rect::default(),
            rows: Vec::new(),
            buttons: Vec::new(),
        }
    }

    /// Where a named part is, for synthetic presses: a button's name, or "row:<n>".
    pub fn control_rect(&self, name: &str) -> Option<Rect> {
        if let Some(index) = name.strip_prefix("row:") {
            return self.rows.get(index.parse::<usize>().ok()?).copied();
        }
        self.buttons.iter().rev().find(|(_, what)| *what == name).map(|(rect, _)| *rect)
    }

    /// The repository changed under the explorer too.
    pub fn mutations(&self) -> u64 {
        self.state.lock().snapshots
    }

    fn selected_change(&self) -> Option<Change> {
        let state = self.state.lock();
        let snapshot = state.snapshot.as_ref()?;
        snapshot.changes.iter().find(|change| Some(&change.path) == self.selected.as_ref()).cloned()
    }

    fn root(&self) -> Option<PathBuf> {
        self.state.lock().snapshot.as_ref().map(|snapshot| snapshot.root.clone())
    }

    fn busy(&self) -> bool {
        let state = self.state.lock();
        state.loading || state.mutating
    }

    fn request_diff(&mut self) {
        let Some(root) = self.root() else { return };
        self.diff_request += 1;
        self.diff_scroll = (0.0, 0.0);
        self.state.lock().patch.clear();
        let _ = self.commands.send(Command::Diff { request: self.diff_request, root, change: self.selected_change(), staged: self.staged, stash: self.selected_stash.clone() });
    }

    /// Starts a change to the repository. `unsaved`: an editor buffer has unsaved changes.
    fn mutate(&mut self, unsaved: bool, command: impl FnOnce(PathBuf) -> Command) {
        if self.busy() {
            return;
        }
        let Some(root) = self.root() else { return };
        {
            let mut state = self.state.lock();
            state.mutating = true;
            state.error = None;
        }
        let command = if unsaved { Command::Refuse("Save or close unsaved editor files before changing Git state.".into()) } else { command(root) };
        let _ = self.commands.send(command);
    }

    /// A choice from the branch or stash menu.
    pub fn perform(&mut self, action: &Action, unsaved: bool) {
        match action {
            Action::GitCreateBranch => {
                self.branch_name.clear();
                self.focus = Focus::Branch;
            }
            Action::GitSwitch(name) => {
                let name = name.clone();
                self.mutate(unsaved, |root| Command::Switch { root, name, create: false });
            }
            Action::GitStash(stash) => {
                self.selected_stash = stash.clone();
                self.request_diff();
            }
            _ => {}
        }
    }

    pub fn key(&mut self, key: &Key, text: Option<&str>, unsaved: bool) -> Outcome {
        let field = match self.focus {
            Focus::Commit => &mut self.commit_message,
            Focus::Branch => &mut self.branch_name,
        };
        match key {
            Key::Named(NamedKey::Escape) => {
                if self.focus == Focus::Branch {
                    self.focus = Focus::Commit;
                } else if !self.state.lock().mutating {
                    return Outcome::Close;
                }
            }
            Key::Named(NamedKey::Enter) => {
                if self.focus == Focus::Branch {
                    self.create_branch(unsaved);
                }
            }
            Key::Named(NamedKey::Backspace) => {
                field.pop();
            }
            Key::Named(NamedKey::ArrowDown) | Key::Named(NamedKey::ArrowUp) => self.move_selection(matches!(key, Key::Named(NamedKey::ArrowDown))),
            _ => {
                if let Some(text) = text.filter(|text| !text.chars().any(char::is_control)) {
                    field.push_str(text);
                }
            }
        }
        Outcome::Stay
    }

    fn move_selection(&mut self, down: bool) {
        let paths: Vec<String> = self.state.lock().snapshot.as_ref().map(|snapshot| snapshot.changes.iter().map(|change| change.path.clone()).collect()).unwrap_or_default();
        if paths.is_empty() {
            return;
        }
        let current = paths.iter().position(|path| Some(path) == self.selected.as_ref()).unwrap_or(0);
        let next = if down { (current + 1).min(paths.len() - 1) } else { current.saturating_sub(1) };
        self.select(paths[next].clone());
    }

    fn select(&mut self, path: String) {
        self.selected_stash = None;
        self.selected = Some(path);
        self.staged = self.selected_change().is_some_and(|change| change.staged() && !change.unstaged());
        self.request_diff();
    }

    fn create_branch(&mut self, unsaved: bool) {
        let name = self.branch_name.clone();
        self.focus = Focus::Commit;
        self.mutate(unsaved, |root| Command::Switch { root, name, create: true });
    }

    pub fn click(&mut self, x: f32, y: f32, unsaved: bool) -> Outcome {
        let Some((rect, what)) = self.buttons.iter().rev().find(|(rect, _)| rect.contains(x, y)).copied() else {
            if self.focus == Focus::Branch {
                return Outcome::Stay;
            }
            if self.list.contains(x, y) {
                if let Some(index) = self.rows.iter().position(|row| row.contains(x, y)) {
                    let path = self.state.lock().snapshot.as_ref().and_then(|snapshot| snapshot.changes.get(index).map(|change| change.path.clone()));
                    let mutating = self.state.lock().mutating;
                    if let (Some(path), false) = (path, mutating) {
                        self.select(path);
                    }
                }
            }
            return Outcome::Stay;
        };
        let change = self.selected_change();
        match what {
            "done" => {
                if !self.state.lock().mutating {
                    return Outcome::Close;
                }
            }
            "refresh" => {
                if !self.busy() {
                    let _ = self.commands.send(Command::Reload);
                }
            }
            "branches" => {
                let state = self.state.lock();
                if let (Some(snapshot), false) = (&state.snapshot, state.loading || state.mutating) {
                    let mut items = vec![Item::entry("Create Branch\u{2026}", Action::GitCreateBranch), Item::Separator];
                    items.extend(snapshot.branches.iter().map(|branch| Item::Entry { label: branch.clone(), action: Action::GitSwitch(branch.clone()), checked: *branch == snapshot.branch, enabled: *branch != snapshot.branch }));
                    return Outcome::Menu(Menu::new(rect, items));
                }
            }
            "stashes" => {
                let state = self.state.lock();
                if let Some(snapshot) = &state.snapshot {
                    let mut items = vec![Item::entry("Working Tree", Action::GitStash(None))];
                    items.extend(snapshot.stashes.iter().map(|stash| Item::entry(&stash.title, Action::GitStash(Some(stash.id.clone())))));
                    return Outcome::Menu(Menu::new(rect, items));
                }
            }
            "working-tree" => {
                self.selected_stash = None;
                self.request_diff();
            }
            "show-working" | "show-staged" => {
                self.staged = what == "show-staged";
                self.request_diff();
            }
            "stage" => {
                if let Some(change) = change {
                    self.mutate(unsaved, |root| Command::Stage(root, change));
                }
            }
            "unstage" => {
                if let Some(change) = change {
                    self.mutate(unsaved, |root| Command::Unstage(root, change));
                }
            }
            "open" => {
                if let (Some(change), Some(root)) = (change, self.root()) {
                    if change.index != 'D' && change.worktree != 'D' && !self.state.lock().mutating {
                        return Outcome::Open(root.join(&change.path));
                    }
                }
            }
            "commit" => {
                let message = self.commit_message.clone();
                self.mutate(unsaved, |root| Command::Commit(root, message));
            }
            "branch-cancel" => self.focus = Focus::Commit,
            "branch-create" => self.create_branch(unsaved),
            _ => {}
        }
        Outcome::Stay
    }

    /// A wheel report of `(dx, dy)` pixels at the pointer.
    pub fn scroll(&mut self, x: f32, y: f32, dx: f32, dy: f32) {
        if self.list.contains(x, y) {
            self.list_scroll -= dy;
        } else if self.preview.contains(x, y) {
            if dx.abs() > dy.abs() {
                self.diff_scroll.0 -= dx;
            } else {
                self.diff_scroll.1 -= dy;
            }
        }
    }

    pub fn signature(&self) -> u64 {
        let mut value = self.state.lock().revision.wrapping_mul(0x9E3779B97F4A7C15);
        let mut add = |part: u64| value = (value.rotate_left(9) ^ part).wrapping_mul(0x100000001B3);
        for text in [&self.commit_message, &self.branch_name, self.selected.as_ref().unwrap_or(&String::new()), self.selected_stash.as_ref().unwrap_or(&String::new())] {
            add(text.len() as u64);
            text.bytes().for_each(|byte| add(byte as u64));
        }
        add(self.staged as u64 | ((self.focus == Focus::Branch) as u64) << 1);
        add(self.list_scroll.to_bits() as u64);
        add(self.diff_scroll.0.to_bits() as u64);
        add(self.diff_scroll.1.to_bits() as u64);
        value
    }

    fn button(&mut self, ui: &mut Ui, label: &str, right: f32, middle: f32, what: &'static str, enabled: bool, prominent: bool) -> f32 {
        let width = ui.measure(label, 11.0, 500, false) + ui.px(18.0);
        let rect = Rect::new(right - width, middle - ui.px(10.0), width, ui.px(20.0));
        ui.rounded(rect, 5.0, if prominent && enabled { theme::rgb(0x2F6FDB) } else { theme::rgb(0x343434) });
        ui.text(label, rect.x + ui.px(9.0), middle, 11.0, 500, false, if !enabled { faded(theme::TEXT_SECONDARY, 0.6) } else if prominent { theme::rgb(0xFFFFFF) } else { theme::TEXT_PRIMARY });
        if enabled {
            self.buttons.push((rect, what));
        }
        width
    }

    pub fn draw(&mut self, ui: &mut Ui, window: (f32, f32), cell_height: f32) {
        // A new snapshot: keep the selection if the file is still changed, else take the first.
        let (snapshots, committed) = {
            let state = self.state.lock();
            (state.snapshots, state.committed)
        };
        if committed != self.seen_commit {
            self.seen_commit = committed;
            self.commit_message.clear();
        }
        if snapshots != self.seen_snapshot {
            self.seen_snapshot = snapshots;
            let (first, still, stash_exists) = {
                let state = self.state.lock();
                let snapshot = state.snapshot.as_ref();
                (
                    snapshot.and_then(|snapshot| snapshot.changes.first().map(|change| change.path.clone())),
                    snapshot.is_some_and(|snapshot| snapshot.changes.iter().any(|change| Some(&change.path) == self.selected.as_ref())),
                    snapshot.is_some_and(|snapshot| snapshot.stashes.iter().any(|stash| Some(&stash.id) == self.selected_stash.as_ref())),
                )
            };
            if !still {
                self.selected = first;
            }
            if !stash_exists {
                self.selected_stash = None;
            }
            self.staged = self.selected_change().is_some_and(|change| change.staged() && !change.unstaged());
            self.request_diff();
        }
        let state_handle = self.state.clone();
        let state = state_handle.lock();
        let busy = state.loading || state.mutating;
        self.buttons.clear();
        ui.fill(Rect::new(0.0, 0.0, window.0, window.1), [0, 0, 0, 90]);
        let width = ui.px(880.0).min(window.0 - ui.px(40.0));
        let height = ui.px(640.0).min(window.1 - ui.px(60.0));
        let frame = Rect::new(((window.0 - width) * 0.5).round(), ((window.1 - height) * 0.5).round().max(ui.px(30.0)), width, height);
        self.frame = frame;
        let line = ui.px(1.0).max(1.0);
        ui.shadow(frame, 10.0);
        ui.rounded(frame, 10.0, theme::EDITOR_BACKGROUND);
        ui.outline(frame, 10.0, theme::white(0.12));
        // Header.
        let pad = ui.px(14.0);
        let header_middle = frame.y + pad + ui.px(11.0);
        let mut x = frame.x + pad;
        x += ui.icon("arrow.triangle.branch", 13.0, IconWeight::Semibold, x + ui.px(8.0), header_middle, theme::TEXT_PRIMARY).max(ui.px(16.0)) + ui.px(6.0);
        x += ui.text("Source Control", x, header_middle, 13.0, 600, false, theme::TEXT_PRIMARY) + ui.px(10.0);
        let branch = state.snapshot.as_ref().map(|snapshot| snapshot.branch.clone()).unwrap_or_else(|| "Branch".into());
        let branch_width = ui.measure(&branch, 12.0, 400, false) + ui.px(30.0);
        let branch_rect = Rect::new(x, header_middle - ui.px(11.0), branch_width, ui.px(22.0));
        ui.rounded(branch_rect, 5.0, theme::rgb(0x343434));
        ui.text(&branch, x + ui.px(9.0), header_middle, 12.0, 400, false, if busy || state.snapshot.is_none() { theme::TEXT_SECONDARY } else { theme::TEXT_PRIMARY });
        ui.icon("chevron.down", 8.0, IconWeight::Semibold, branch_rect.right() - ui.px(11.0), header_middle, theme::TEXT_SECONDARY);
        self.buttons.push((branch_rect, "branches"));
        let mut right = frame.right() - pad;
        let has_stashes = state.snapshot.as_ref().is_some_and(|snapshot| !snapshot.stashes.is_empty());
        let mutating = state.mutating;
        let snapshot = state.snapshot.clone();
        let (patch, patch_current, error, loading) = (state.patch.clone(), state.patch_for == self.diff_request, state.error.clone(), state.loading);
        drop(state);
        right -= self.button(ui, "Done", right, header_middle, "done", !mutating, false) + ui.px(8.0);
        let refresh = Rect::new(right - ui.px(26.0), header_middle - ui.px(10.0), ui.px(26.0), ui.px(20.0));
        ui.rounded(refresh, 5.0, theme::rgb(0x343434));
        ui.icon("arrow.clockwise", 11.0, IconWeight::Medium, refresh.x + refresh.width * 0.5, header_middle, if busy { faded(theme::TEXT_SECONDARY, 0.6) } else { theme::TEXT_PRIMARY });
        self.buttons.push((refresh, "refresh"));
        right = refresh.x - ui.px(8.0);
        if has_stashes {
            self.button(ui, "Stashes", right, header_middle, "stashes", !busy, false);
        }
        let mut top = frame.y + pad * 2.0 + ui.px(22.0);
        ui.painter.scene.fill(frame.x, top, frame.width, line, theme::SEPARATOR);
        top += line;
        if let Some(error) = &error {
            ui.painter.scene.set_clip(Some(Rect::new(frame.x, top, frame.width, ui.px(34.0))));
            ui.text(error.lines().next().unwrap_or(""), frame.x + ui.px(10.0), top + ui.px(17.0), 11.0, 400, false, theme::rgb(0xC6B28E));
            ui.painter.scene.set_clip(None);
            top += ui.px(34.0);
        }
        // Bottom: commit row and note.
        let note_middle = frame.bottom() - ui.px(12.0 + 6.0);
        ui.text(if mutating { "Updating repository\u{2026}" } else { "Commits use staged files and your Git identity. Save editor changes before Git operations." }, frame.x + ui.px(12.0), note_middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        if busy {
            ui.text_right(if loading { "Loading\u{2026}" } else { "Working\u{2026}" }, frame.right() - ui.px(12.0), note_middle, 10.0, 400, false, theme::TEXT_SECONDARY);
        }
        let commit_top = note_middle - ui.px(6.0 + 12.0 + 40.0);
        let staged_count = snapshot.as_ref().map(|snapshot| snapshot.changes.iter().filter(|change| change.staged()).count()).unwrap_or(0);
        let label = format!("Commit {staged_count} staged {}", if staged_count == 1 { "file" } else { "files" });
        let can_commit = !busy && staged_count > 0 && !self.commit_message.trim().is_empty();
        let commit_width = self.button(ui, &label, frame.right() - ui.px(12.0), commit_top + ui.px(11.0), "commit", can_commit, true);
        let field = Rect::new(frame.x + ui.px(12.0), commit_top, frame.width - ui.px(24.0 + 12.0) - commit_width, ui.px(40.0));
        ui.rounded(field, 5.0, theme::rgb(0x1E1E1E));
        ui.outline(field, 5.0, if self.focus == Focus::Commit { theme::rgb(0x2F6FDB) } else { theme::white(0.12) });
        ui.painter.scene.set_clip(Some(field));
        let text_middle = field.y + ui.px(12.0);
        let caret = if self.commit_message.is_empty() {
            ui.text("Commit message", field.x + ui.px(7.0), text_middle, 13.0, 400, false, faded(theme::TEXT_SECONDARY, 0.7));
            0.0
        } else {
            ui.text(&self.commit_message, field.x + ui.px(7.0), text_middle, 13.0, 400, false, theme::TEXT_PRIMARY) + line
        };
        if self.focus == Focus::Commit {
            ui.painter.scene.fill(field.x + ui.px(7.0) + caret, text_middle - ui.px(8.0), line.max(2.0), ui.px(16.0), theme::ACCENT);
        }
        ui.painter.scene.set_clip(None);
        let body_bottom = commit_top - ui.px(12.0) - line;
        ui.painter.scene.fill(frame.x, body_bottom, frame.width, line, theme::SEPARATOR);
        // File list.
        let list = Rect::new(frame.x, top, ui.px(220.0), body_bottom - top);
        self.list = list;
        ui.painter.scene.fill(list.right(), top, line, list.height, theme::SEPARATOR);
        self.rows.clear();
        let row_height = ui.px(8.0 + 16.0 + 8.0);
        let changes = snapshot.as_ref().map(|snapshot| snapshot.changes.as_slice()).unwrap_or(&[]);
        self.list_scroll = self.list_scroll.clamp(0.0, (changes.len() as f32 * row_height - list.height).max(0.0));
        ui.painter.scene.set_clip(Some(list));
        for (index, change) in changes.iter().enumerate() {
            let row = Rect::new(list.x, list.y + index as f32 * row_height - self.list_scroll.round(), list.width, row_height);
            self.rows.push(row);
            if row.bottom() < list.y || row.y > list.bottom() {
                continue;
            }
            if self.selected_stash.is_none() && self.selected.as_deref() == Some(change.path.as_str()) {
                ui.fill(row, theme::SELECTION);
            }
            let middle = row.y + row.height * 0.5;
            // Git's two status letters, as the explorer shows them: "U" for untracked, colored by kind.
            let code: String = if change.index == '?' { "U".into() } else { format!("{}{}", change.index, change.worktree).trim().to_string() };
            let letter = code.chars().find(|character| *character != ' ').unwrap_or(' ');
            let code_color = match letter {
                'U' if change.index == '?' => theme::rgb(0xA4B29B),
                'A' => theme::rgb(0xA4B29B),
                'D' => theme::rgb(0xCC9595),
                'R' | 'C' => theme::rgb(0xA8CCDF),
                'U' => theme::rgb(0xD6B3D2),
                _ => theme::rgb(0xD7C4A2),
            };
            let code_width = ui.text_right(&code, row.right() - ui.px(10.0), middle, 11.0, 600, true, code_color);
            crate::explorer::draw_file_icon(ui, std::path::Path::new(&change.path), row.x + ui.px(8.0 + 8.0), middle, 1.0);
            let text_x = row.x + ui.px(8.0 + 16.0 + 6.0);
            let available = row.right() - ui.px(10.0) - code_width - ui.px(8.0) - text_x;
            let (folder, name) = change.path.rsplit_once('/').unwrap_or(("", change.path.as_str()));
            let name = ui.fit_middle(name, available, 12.0, 400, false);
            let name_width = ui.text(&name, text_x, middle, 12.0, 400, false, theme::TEXT_PRIMARY);
            let folder_room = available - name_width - ui.px(6.0);
            if !folder.is_empty() && folder_room > ui.px(20.0) {
                let folder = ui.fit_middle(folder, folder_room, 11.0, 400, false);
                ui.text(&folder, text_x + name_width + ui.px(6.0), middle, 11.0, 400, false, theme::TEXT_SECONDARY);
            }
        }
        if snapshot.as_ref().is_some_and(|snapshot| snapshot.changes.is_empty()) {
            ui.text("Working tree clean", list.x + ui.px(12.0), list.y + ui.px(22.0), 13.0, 400, false, theme::TEXT_SECONDARY);
        }
        ui.painter.scene.set_clip(None);
        // Diff controls.
        let controls = Rect::new(list.right() + line, top, frame.right() - list.right() - line, ui.px(10.0 + 20.0 + 10.0));
        let controls_middle = controls.y + controls.height * 0.5;
        let mut right = controls.right() - ui.px(10.0);
        let stash = snapshot.as_ref().and_then(|snapshot| snapshot.stashes.iter().find(|stash| Some(&stash.id) == self.selected_stash.as_ref()).cloned());
        let selected = changes.iter().find(|change| Some(&change.path) == self.selected.as_ref()).cloned();
        let title = if let Some(stash) = &stash {
            right -= self.button(ui, "Working Tree", right, controls_middle, "working-tree", true, false) + ui.px(8.0);
            stash.title.clone()
        } else if let Some(change) = &selected {
            let can_open = !mutating && change.index != 'D' && change.worktree != 'D';
            right -= self.button(ui, "Open", right, controls_middle, "open", can_open, false) + ui.px(8.0);
            if change.staged() {
                right -= self.button(ui, "Unstage", right, controls_middle, "unstage", !busy, false) + ui.px(8.0);
            }
            if change.unstaged() {
                right -= self.button(ui, "Stage", right, controls_middle, "stage", !busy, false) + ui.px(8.0);
            }
            if change.staged() && change.unstaged() {
                // The segmented "Working tree | Staged" picker.
                let picker = Rect::new(right - ui.px(160.0), controls_middle - ui.px(10.0), ui.px(160.0), ui.px(20.0));
                ui.rounded(picker, 5.0, theme::rgb(0x2A2A2A));
                let half = picker.width * 0.5;
                let lit = Rect::new(picker.x + if self.staged { half } else { 0.0 } + line, picker.y + line, half - 2.0 * line, picker.height - 2.0 * line);
                ui.rounded(lit, 4.0, theme::rgb(0x4A4A4A));
                for (index, (label, what)) in [("Working tree", "show-working"), ("Staged", "show-staged")].into_iter().enumerate() {
                    let part = Rect::new(picker.x + index as f32 * half, picker.y, half, picker.height);
                    let label_width = ui.measure(label, 11.0, 500, false);
                    ui.text(label, part.x + (half - label_width) * 0.5, controls_middle, 11.0, 500, false, theme::TEXT_PRIMARY);
                    self.buttons.push((part, what));
                }
                right = picker.x - ui.px(8.0);
            }
            change.path.clone()
        } else {
            "Select a changed file".into()
        };
        let title = ui.fit_middle(&title, right - controls.x - ui.px(20.0), 11.0, 400, false);
        ui.text(&title, controls.x + ui.px(10.0), controls_middle, 11.0, 400, false, theme::TEXT_PRIMARY);
        // Diff.
        let preview = Rect::new(controls.x, controls.bottom(), controls.width, body_bottom - controls.bottom());
        self.preview = preview;
        let line_height = cell_height.max(1.0);
        let inset = ui.px(10.0);
        // From the first change block on: git's header lines (diff --git, index, ---/+++) say nothing
        // the title does not. A patch without blocks (a binary or mode change) is shown whole.
        let lines: Vec<&str> = if patch_current {
            let all: Vec<&str> = patch.split('\n').collect();
            match all.iter().position(|text| text.starts_with("@@")) {
                Some(first) if self.selected_stash.is_none() => all[first..].to_vec(),
                _ => all,
            }
        } else {
            Vec::new()
        };
        self.diff_scroll.1 = self.diff_scroll.1.clamp(0.0, (lines.len() as f32 * line_height + 2.0 * inset - preview.height).max(0.0));
        self.diff_scroll.0 = self.diff_scroll.0.clamp(0.0, ui.px(4000.0));
        ui.painter.scene.set_clip(Some(preview));
        let first = ((self.diff_scroll.1 - inset) / line_height).floor().max(0.0) as usize;
        let shown = (preview.height / line_height).ceil() as usize + 2;
        let points = ui.painter.text.cell.font_pixels / ui.scale;
        for (index, text) in lines.iter().enumerate().skip(first).take(shown) {
            let y = preview.y + inset + index as f32 * line_height - self.diff_scroll.1.round();
            let (color, band) = if text.starts_with('+') && !text.starts_with("+++") {
                (theme::rgb(0xB9C6AF), Some([110, 170, 100, 36]))
            } else if text.starts_with('-') && !text.starts_with("---") {
                (theme::rgb(0xD9A9A9), Some([210, 100, 100, 36]))
            } else if text.starts_with("@@") {
                (theme::TEXT_SECONDARY, Some([255, 255, 255, 10]))
            } else {
                (theme::TEXT_PRIMARY, None)
            };
            // Added and removed lines are tinted across the whole width, as in any diff view.
            if let Some(band) = band {
                ui.painter.scene.fill(preview.x, y, preview.width, line_height, band);
            }
            let shown_text: String = text.chars().take(600).map(|character| if character == '\t' { ' ' } else { character }).collect();
            if !shown_text.is_empty() {
                ui.text(&shown_text, preview.x + inset - self.diff_scroll.0.round(), y + line_height * 0.5, points, 400, true, color);
            }
        }
        ui.painter.scene.set_clip(None);
        let content = lines.len() as f32 * line_height + 2.0 * inset;
        if content > preview.height {
            let thumb = (preview.height * preview.height / content).max(ui.px(24.0));
            let travel = (preview.height - thumb) * self.diff_scroll.1 / (content - preview.height);
            ui.rounded(Rect::new(preview.right() - ui.px(7.0), preview.y + travel, ui.px(4.0), thumb), 2.0, theme::white(0.16));
        }
        // The "Create and switch branch" prompt.
        if self.focus == Focus::Branch {
            ui.rounded(frame, 10.0, [0, 0, 0, 110]);
            let (width, height) = (ui.px(300.0), ui.px(168.0));
            let alert = Rect::new(frame.x + (frame.width - width) * 0.5, frame.y + (frame.height - height) * 0.5, width, height);
            ui.shadow(alert, 12.0);
            ui.rounded(alert, 12.0, theme::rgb(0x262626));
            ui.outline(alert, 12.0, theme::white(0.14));
            let pad = ui.px(16.0);
            let title = "Create and switch branch";
            let title_width = ui.measure(title, 13.0, 600, false);
            ui.text(title, alert.x + (alert.width - title_width) * 0.5, alert.y + pad + ui.px(8.0), 13.0, 600, false, theme::TEXT_PRIMARY);
            for (index, text) in ["Creates a local branch from the current commit.", "Existing branches are never overwritten."].into_iter().enumerate() {
                let text_width = ui.measure(text, 10.0, 400, false);
                ui.text(text, alert.x + (alert.width - text_width) * 0.5, alert.y + pad + ui.px(32.0 + index as f32 * 14.0), 10.0, 400, false, theme::TEXT_SECONDARY);
            }
            let field = Rect::new(alert.x + pad, alert.y + pad + ui.px(62.0), alert.width - 2.0 * pad, ui.px(22.0));
            ui.rounded(field, 5.0, theme::rgb(0x1A1A1A));
            ui.outline(field, 5.0, theme::rgb(0x2F6FDB));
            let middle = field.y + field.height * 0.5;
            let caret = if self.branch_name.is_empty() {
                ui.text("Branch name", field.x + ui.px(6.0), middle, 12.0, 400, false, faded(theme::TEXT_SECONDARY, 0.7));
                0.0
            } else {
                ui.text(&self.branch_name, field.x + ui.px(6.0), middle, 12.0, 400, false, theme::TEXT_PRIMARY) + line
            };
            ui.painter.scene.fill(field.x + ui.px(6.0) + caret, middle - ui.px(7.0), line.max(2.0), ui.px(14.0), theme::ACCENT);
            let button_middle = alert.bottom() - pad - ui.px(10.0);
            let create = self.button(ui, "Create Branch", alert.right() - pad, button_middle, "branch-create", plausible_branch_name(&self.branch_name), true);
            self.button(ui, "Cancel", alert.right() - pad - create - ui.px(8.0), button_middle, "branch-cancel", true, false);
        }
        let _ = &self.directory;
    }
}
