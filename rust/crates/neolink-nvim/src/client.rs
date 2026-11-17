//! A running Neovim (`nvim --embed`) with NeoLink attached as its `ext_linegrid` UI.
//!
//! One channel carries everything: our requests, Neovim's answers, its `redraw` events and the
//! `neolink_*` notices of `Resources/Editor/neolink.lua`. Neovim writes them in order, so when the
//! `neolink_selection` notice for a buffer has been read, every screen published since belongs to that
//! buffer. That ordering is the display half of the correct-buffer guarantee.
//!
//! Input is the other half, and ordering does not give it: `nvim_input` is handled the moment it is
//! read, while an `open` request waits for Neovim's main loop, so keys sent right after an `open` can be
//! typed into the buffer being left. Against a real Neovim they usually were, and sometimes were not:
//! it is a race, which is worse than either rule. Input sent while a selection is unconfirmed is
//! therefore held here and released when Neovim confirms it; held input is then written before the next
//! queued switch, an order in which arrival and Neovim's input-first rule agree.

use crate::grid::{GridModel, Screen};
use crate::rpc::{self, Decoder, Message};
use rmpv::Value;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// A file's identity on disk: unchanged means nobody rewrote it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileSignature {
    length: u64,
    modified: Option<std::time::SystemTime>,
    inode: u64,
}

impl FileSignature {
    pub fn of(path: &str) -> Option<FileSignature> {
        let metadata = std::fs::metadata(path).ok()?;
        #[cfg(unix)]
        let inode = std::os::unix::fs::MetadataExt::ino(&metadata);
        #[cfg(not(unix))]
        let inode = 0;
        Some(FileSignature { length: metadata.len(), modified: metadata.modified().ok(), inode })
    }
}

/// The screen of a buffer at the moment Neovim left it (`neolink_leave`, sent after a redraw, so the
/// screen read before the notice is exactly that buffer's).
#[derive(Clone, Debug)]
pub struct Left {
    pub screen: Screen,
    /// Neovim was in insert mode with no popup menu: the state `open` returns to.
    pub plain_insert: bool,
    pub diagnostics: bool,
    pub file: Option<FileSignature>,
}

/// Buffers remembered at most.
pub const LEFT_LIMIT: usize = 8;

/// What the reader thread has learned, shared with whoever draws.
pub struct State {
    /// Screens of buffers that were left and not touched since, newest last. An entry is taken when
    /// its buffer is selected again, so it is never older than the buffer's last visit.
    pub left: Vec<(String, Left)>,
    pub screen: Screen,
    /// The newest selection Neovim confirmed: `(token, path, screen generation at that moment)`.
    pub selection: Option<(u64, String, u64)>,
    /// Buffers changed while they were not shown (`neolink_touch`; an empty path means all of them).
    pub touched: Vec<String>,
    /// The last reply of `NeoLink.dispatch`, decoded (`ok`, `error`, `state`).
    pub last_reply: Option<serde_json::Value>,
    /// Requests whose reply has been read (for tests and the benchmark).
    pub replies: u64,
    /// Files with unsaved changes, as Neovim reports them when they change (`neolink_modified`).
    pub modified: std::collections::HashSet<String>,
}

type Reply = Result<Value, Value>;

/// Something queued behind an unconfirmed buffer switch.
enum Queued {
    Input(Vec<u8>),
    /// A further switch: `(token, request id, encoded request)`.
    Switch(u64, u64, Vec<u8>),
}

/// Serialises buffer switches. Neovim types pending input before it runs a queued request, and runs
/// queued requests back to back, so the only arrangement in which input reliably lands in the buffer
/// it was typed for is: one switch in flight, and everything sent after it (input and further switches)
/// kept here, in order, until that switch is confirmed.
#[derive(Default)]
struct Gate {
    /// The switch in flight: `(token, request id)`.
    in_flight: Option<(u64, u64)>,
    queue: std::collections::VecDeque<Queued>,
}

struct Inner {
    gate: Mutex<Gate>,
    stdin: Mutex<ChildStdin>,
    next_id: AtomicU64,
    pending: Mutex<HashMap<u64, Sender<Reply>>>,
    state: Mutex<State>,
    exited: AtomicBool,
    on_change: Box<dyn Fn() + Send + Sync>,
}

pub struct Client {
    inner: Arc<Inner>,
    child: Mutex<Child>,
}

#[derive(Debug)]
pub enum ClientError {
    Io(std::io::Error),
    /// Neovim answered with an error.
    Neovim(String),
    Timeout,
    Exited,
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClientError::Io(error) => write!(formatter, "{error}"),
            ClientError::Neovim(message) => write!(formatter, "{message}"),
            ClientError::Timeout => write!(formatter, "Neovim did not answer in time"),
            ClientError::Exited => write!(formatter, "Neovim has exited"),
        }
    }
}

impl From<std::io::Error> for ClientError {
    fn from(error: std::io::Error) -> Self {
        ClientError::Io(error)
    }
}

const MODIFIED_NOTICE: &str = r#"
local channel = ...
vim.api.nvim_create_autocmd({'BufModifiedSet', 'BufWritePost', 'BufReadPost', 'BufDelete'}, {callback = function(event)
  local name = vim.api.nvim_buf_get_name(event.buf)
  if name ~= '' then
    local modified = event.event ~= 'BufDelete' and vim.fn.getbufvar(event.buf, '&modified') == 1
    pcall(vim.rpcnotify, channel, 'neolink_modified', name, modified)
  end
end})
return true
"#;

/// Escapes text for `nvim_input`, where `<` starts a key name.
pub fn literal_keys(text: &str) -> String {
    text.replace('<', "<lt>")
}

impl Client {
    /// Starts `nvim` with `config` (NeoLink's `neolink.lua`) and attaches a `columns` x `rows` UI.
    /// `on_change` is called from the reader thread whenever the shared state changed.
    pub fn spawn(nvim: &Path, config: &Path, columns: usize, rows: usize, on_change: impl Fn() + Send + Sync + 'static) -> Result<Client, ClientError> {
        let mut child = Command::new(nvim)
            .args(["--embed", "--noplugin", "-u"])
            .arg(config)
            .args(["-i", "NONE"])
            .env_remove("NEOLINK_STATUS_FILE")
            .env_remove("NEOLINK_CONTROL_SOCKET")
            .env_remove("NVIM")
            .env_remove("NVIM_LISTEN_ADDRESS")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdin = child.stdin.take().expect("piped stdin");
        let mut stdout = child.stdout.take().expect("piped stdout");
        let model = GridModel::new(columns, rows);
        let inner = Arc::new(Inner {
            gate: Mutex::new(Gate::default()),
            stdin: Mutex::new(stdin),
            next_id: AtomicU64::new(1),
            pending: Mutex::new(HashMap::new()),
            state: Mutex::new(State { left: Vec::new(), screen: model.screen().clone(), selection: None, touched: Vec::new(), last_reply: None, replies: 0, modified: Default::default() }),
            exited: AtomicBool::new(false),
            on_change: Box::new(on_change),
        });
        let reader = inner.clone();
        std::thread::Builder::new()
            .name("neovim reader".into())
            .spawn(move || {
                let mut model = model;
                let mut decoder = Decoder::default();
                let mut buffer = vec![0u8; 256 * 1024];
                'read: loop {
                    let count = match stdout.read(&mut buffer) {
                        Ok(0) | Err(_) => break,
                        Ok(count) => count,
                    };
                    decoder.push(&buffer[..count]);
                    let mut changed = false;
                    loop {
                        match decoder.next() {
                            Ok(Some(message)) => changed |= reader.handle(message, &mut model),
                            Ok(None) => break,
                            Err(_) => break 'read,
                        }
                    }
                    if changed {
                        (reader.on_change)();
                    }
                }
                reader.exited.store(true, Ordering::Release);
                reader.pending.lock().unwrap().clear();
                (reader.on_change)();
            })
            .map_err(ClientError::Io)?;
        let client = Client { inner, child: Mutex::new(child) };
        // Our channel id, so the editor configuration can address its notices to this UI.
        let info = client.call("nvim_get_api_info", vec![], Duration::from_secs(10))?;
        let channel = info.as_array().and_then(|items| items.first()).and_then(Value::as_u64).ok_or_else(|| ClientError::Neovim("no channel id".into()))?;
        // An embedded Neovim sources its configuration only once a UI is attached.
        let options = Value::Map(vec![(Value::from("rgb"), Value::from(true)), (Value::from("ext_linegrid"), Value::from(true))]);
        client.call("nvim_ui_attach", vec![Value::from(columns as u64), Value::from(rows as u64), options], Duration::from_secs(10))?;
        let attached = client.call(
            "nvim_exec_lua",
            vec![Value::from("if not NeoLink then return false end return NeoLink.attach_ui(...)"), Value::Array(vec![Value::from(channel)])],
            Duration::from_secs(10),
        )?;
        if attached.as_bool() != Some(true) {
            return Err(ClientError::Neovim("the editor configuration did not load (NeoLink is not defined)".into()));
        }
        // Tell this UI when a file gains or loses unsaved changes. (`getbufvar`, not `vim.bo`: reading a
        // hidden buffer's option through `vim.bo` redraws the whole screen; see AGENTS.md.)
        client.call("nvim_exec_lua", vec![Value::from(MODIFIED_NOTICE), Value::Array(vec![Value::from(channel)])], Duration::from_secs(10))?;
        Ok(client)
    }

    fn send(&self, bytes: &[u8]) -> Result<(), ClientError> {
        if self.inner.exited.load(Ordering::Acquire) {
            return Err(ClientError::Exited);
        }
        let mut stdin = self.inner.stdin.lock().unwrap();
        stdin.write_all(bytes)?;
        stdin.flush()?;
        Ok(())
    }

    /// Sends a request; the reply arrives on the returned channel (dropped if Neovim exits).
    pub fn request(&self, method: &str, params: Vec<Value>) -> Result<Receiver<Reply>, ClientError> {
        let id = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = channel();
        self.inner.pending.lock().unwrap().insert(id, sender);
        if let Err(error) = self.send(&rpc::request(id, method, params)) {
            self.inner.pending.lock().unwrap().remove(&id);
            return Err(error);
        }
        Ok(receiver)
    }

    /// Sends a request and waits for its reply. Not for the main thread of an interactive app.
    pub fn call(&self, method: &str, params: Vec<Value>, timeout: Duration) -> Result<Value, ClientError> {
        match self.request(method, params)?.recv_timeout(timeout) {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(error)) => Err(ClientError::Neovim(describe(&error))),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => Err(ClientError::Timeout),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => Err(ClientError::Exited),
        }
    }

    /// Sends without asking for a reply (resizes).
    pub fn notify(&self, method: &str, params: Vec<Value>) -> Result<(), ClientError> {
        self.send(&rpc::notification(method, params))
    }

    /// Sends user input, or holds it while a buffer switch is unconfirmed.
    fn user_input(&self, method: &str, params: Vec<Value>) -> Result<(), ClientError> {
        let bytes = rpc::notification(method, params);
        let mut gate = self.inner.gate.lock().unwrap();
        if gate.in_flight.is_some() {
            if gate.queue.len() < 8192 {
                gate.queue.push_back(Queued::Input(bytes));
            }
            return Ok(());
        }
        // Still under the gate's lock, so a switch cannot begin between the check and the write.
        self.send(&bytes)
    }

    /// Makes `path` the buffer shown, with `token` identifying this selection. Input sent from now on
    /// is typed into that buffer, never the one being left. The screen belongs to the buffer once
    /// [`State::selection`] carries `token`.
    pub fn open(&self, path: &str, line: Option<u64>, token: u64) -> Result<Receiver<Reply>, ClientError> {
        // A JSON null would reach Lua as `vim.NIL`, which the editor's `open` cannot compare: leave an
        // absent line out.
        let mut command = serde_json::json!({"method": "open", "path": path, "selection": token});
        if let Some(line) = line {
            command["line"] = serde_json::json!(line);
        }
        let mut gate = self.inner.gate.lock().unwrap();
        let id = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = channel();
        self.inner.pending.lock().unwrap().insert(id, sender);
        let params = vec![Value::from("return NeoLink.dispatch(...)"), Value::Array(vec![Value::from(command.to_string())])];
        let bytes = rpc::request(id, "nvim_exec_lua", params);
        if gate.in_flight.is_some() {
            gate.queue.push_back(Queued::Switch(token, id, bytes));
            return Ok(receiver);
        }
        gate.in_flight = Some((token, id));
        if let Err(error) = self.send(&bytes) {
            self.inner.pending.lock().unwrap().remove(&id);
            gate.in_flight = None;
            return Err(error);
        }
        Ok(receiver)
    }

    /// Keys in Neovim's notation (`<CR>`, `<C-w>`, text with `<` written `<lt>`).
    pub fn input(&self, keys: &str) -> Result<(), ClientError> {
        self.user_input("nvim_input", vec![Value::from(keys)])
    }

    /// `button`: left/right/middle/wheel; `action`: press/drag/release, or up/down/left/right for the wheel.
    pub fn input_mouse(&self, button: &str, action: &str, modifier: &str, row: usize, column: usize) -> Result<(), ClientError> {
        self.user_input("nvim_input_mouse", vec![Value::from(button), Value::from(action), Value::from(modifier), Value::from(0), Value::from(row as u64), Value::from(column as u64)])
    }

    pub fn paste(&self, text: &str) -> Result<(), ClientError> {
        self.user_input("nvim_paste", vec![Value::from(text), Value::from(true), Value::from(-1)])
    }

    pub fn resize(&self, columns: usize, rows: usize) -> Result<(), ClientError> {
        self.notify("nvim_ui_try_resize", vec![Value::from(columns as u64), Value::from(rows as u64)])
    }

    /// Runs one command of `neolink.lua` (`{"method": "open" | "save" | "close" | "leave" | "action", ...}`).
    /// The reply (`ok`, `error`, `state`) is stored in the shared state when it arrives, and sent on the
    /// returned channel.
    pub fn dispatch(&self, command: &serde_json::Value) -> Result<Receiver<Reply>, ClientError> {
        self.request("nvim_exec_lua", vec![Value::from("return NeoLink.dispatch(...)"), Value::Array(vec![Value::from(command.to_string())])])
    }

    /// Like [`dispatch`](Self::dispatch), waiting for the decoded reply.
    pub fn dispatch_wait(&self, command: &serde_json::Value, timeout: Duration) -> Result<serde_json::Value, ClientError> {
        let reply = match self.dispatch(command)?.recv_timeout(timeout) {
            Ok(Ok(value)) => value,
            Ok(Err(error)) => return Err(ClientError::Neovim(describe(&error))),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => return Err(ClientError::Timeout),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return Err(ClientError::Exited),
        };
        let decoded: serde_json::Value = reply.as_str().and_then(|text| serde_json::from_str(text).ok()).ok_or_else(|| ClientError::Neovim("unreadable reply".into()))?;
        if decoded["ok"].as_bool() == Some(true) {
            Ok(decoded)
        } else {
            Err(ClientError::Neovim(decoded["error"].as_str().unwrap_or("the editor refused the command").to_string()))
        }
    }

    /// Takes the screen remembered for `path` when it was last left, if nothing has touched the buffer
    /// since. The caller still has to check that it fits (size, styles, the file on disk).
    pub fn take_left(&self, path: &str) -> Option<Left> {
        let mut state = self.inner.state.lock().unwrap();
        let index = state.left.iter().position(|entry| entry.0 == path)?;
        Some(state.left.remove(index).1)
    }

    /// Reads the shared state.
    pub fn with_state<R>(&self, body: impl FnOnce(&mut State) -> R) -> R {
        body(&mut self.inner.state.lock().unwrap())
    }

    pub fn screen(&self) -> Screen {
        self.inner.state.lock().unwrap().screen.clone()
    }

    pub fn has_exited(&self) -> bool {
        self.inner.exited.load(Ordering::Acquire)
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.notify("nvim_command", vec![Value::from("qa!")]);
        let mut child = self.child.lock().unwrap();
        for _ in 0..50 {
            if matches!(child.try_wait(), Ok(Some(_))) {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = child.kill();
        let _ = child.wait();
    }
}

fn describe(error: &Value) -> String {
    match error {
        Value::Array(items) => items.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "),
        other => other.as_str().map(str::to_string).unwrap_or_else(|| other.to_string()),
    }
}

impl Inner {
    /// The switch identified by `token` or answered by request `id` is over: send what was held.
    fn release(&self, token: Option<u64>, id: Option<u64>) {
        let mut gate = self.gate.lock().unwrap();
        let Some((flying_token, flying_id)) = gate.in_flight else { return };
        if token != Some(flying_token) && id != Some(flying_id) {
            return;
        }
        gate.in_flight = None;
        // What was typed after that switch goes out now; the next switch follows it and stops the
        // queue again.
        let Ok(mut stdin) = self.stdin.lock() else { return };
        while let Some(queued) = gate.queue.pop_front() {
            match queued {
                Queued::Input(bytes) => {
                    if stdin.write_all(&bytes).is_err() {
                        break;
                    }
                }
                Queued::Switch(token, id, bytes) => {
                    if stdin.write_all(&bytes).is_ok() {
                        gate.in_flight = Some((token, id));
                    }
                    break;
                }
            }
        }
        let _ = stdin.flush();
    }

    /// Returns `true` if the shared state changed.
    fn handle(&self, message: Message, model: &mut GridModel) -> bool {
        match message {
            Message::Notification { method, params } => match method.as_str() {
                "redraw" => {
                    if model.apply(&params) == 0 {
                        return false;
                    }
                    self.state.lock().unwrap().screen = model.screen().clone();
                    true
                }
                "neolink_selection" => {
                    let token = params.first().and_then(Value::as_u64).unwrap_or(0);
                    let path = params.get(1).and_then(Value::as_str).unwrap_or("").to_string();
                    {
                        let mut state = self.state.lock().unwrap();
                        let generation = state.screen.generation;
                        state.selection = Some((token, path, generation));
                    }
                    self.release(Some(token), None);
                    true
                }
                "neolink_modified" => {
                    let path = params.first().and_then(Value::as_str).unwrap_or("").to_string();
                    let modified = params.get(1).and_then(Value::as_bool).unwrap_or(false);
                    let mut state = self.state.lock().unwrap();
                    if modified {
                        state.modified.insert(path)
                    } else {
                        state.modified.remove(&path)
                    }
                }
                "neolink_leave" => {
                    let path = params.first().and_then(Value::as_str).unwrap_or("").to_string();
                    let mode = params.get(1).and_then(Value::as_str).unwrap_or("");
                    let popup = params.get(2).and_then(Value::as_bool).unwrap_or(true);
                    let diagnostics = params.get(3).and_then(Value::as_bool).unwrap_or(true);
                    if path.is_empty() {
                        return false;
                    }
                    let file = FileSignature::of(&path);
                    let mut state = self.state.lock().unwrap();
                    let left = Left { screen: state.screen.clone(), plain_insert: mode == "i" && !popup, diagnostics, file };
                    state.left.retain(|entry| entry.0 != path);
                    state.left.push((path, left));
                    if state.left.len() > LEFT_LIMIT {
                        state.left.remove(0);
                    }
                    false
                }
                "neolink_touch" => {
                    // A hidden buffer changed (or, with an empty path, something that affects every
                    // screen did): what was remembered of it is no longer what Neovim would draw.
                    let path = params.first().and_then(Value::as_str).unwrap_or("").to_string();
                    let mut state = self.state.lock().unwrap();
                    if path.is_empty() {
                        state.left.clear();
                    } else {
                        state.left.retain(|entry| entry.0 != path);
                    }
                    state.touched.push(path);
                    if state.touched.len() > 256 {
                        state.touched.remove(0);
                    }
                    false
                }
                _ => false,
            },
            Message::Response { id, error, result } => {
                {
                    let mut state = self.state.lock().unwrap();
                    state.replies += 1;
                    if let Some(decoded) = result.as_str().filter(|text| text.starts_with('{')).and_then(|text| serde_json::from_str::<serde_json::Value>(text).ok()) {
                        state.last_reply = Some(decoded);
                    }
                }
                // An open that failed is answered without a selection notice.
                self.release(None, Some(id));
                if let Some(sender) = self.pending.lock().unwrap().remove(&id) {
                    let _ = sender.send(match error {
                        Some(error) => Err(error),
                        None => Ok(result),
                    });
                }
                true
            }
            Message::Request { id, .. } => {
                // Nothing is registered for Neovim to call; say so instead of leaving it waiting.
                let reply = rpc::response(id, Some(Value::from("not supported")), Value::Nil);
                if let Ok(mut stdin) = self.stdin.lock() {
                    let _ = stdin.write_all(&reply).and_then(|_| stdin.flush());
                }
                false
            }
        }
    }
}
