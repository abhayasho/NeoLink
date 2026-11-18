//! A client for the Agent Client Protocol (newline-delimited JSON-RPC over an agent's stdin and stdout),
//! with the rules of the Swift app's `ACPTransport` and `ACPSession`: bounded messages and previews, one
//! conversation per process, file and terminal capabilities not offered, permissions answered by the user.
//!
//! Nothing here waits on the caller's thread: requests carry a continuation that runs on the reader
//! thread when the answer (or its deadline) arrives, and `on_change` is called after every change of
//! the published state.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use neolink_core::agent::CodingAgent;
use parking_lot::Mutex;
use serde_json::{json, Value};

/// Largest protocol message accepted or sent.
pub const MESSAGE_LIMIT: usize = 8 * 1024 * 1024;

/// Splits a byte stream into JSON lines. Lines that are not JSON objects are an error, as is a line
/// over the limit.
#[derive(Default)]
pub struct LineFramer {
    buffer: Vec<u8>,
}

impl LineFramer {
    pub fn append(&mut self, chunk: &[u8]) -> Result<Vec<Value>, String> {
        let mut messages = Vec::new();
        self.buffer.extend_from_slice(chunk);
        while let Some(end) = self.buffer.iter().position(|byte| *byte == b'\n') {
            let line: Vec<u8> = self.buffer.drain(..=end).collect();
            let line = &line[..line.len() - 1];
            if line.len() > MESSAGE_LIMIT {
                return Err("Agent message exceeds the 8 MB limit.".into());
            }
            if line.iter().all(u8::is_ascii_whitespace) {
                continue;
            }
            match serde_json::from_slice::<Value>(line) {
                Ok(value) if value.is_object() => messages.push(value),
                _ => return Err("The agent sent a malformed protocol message.".into()),
            }
        }
        if self.buffer.len() > MESSAGE_LIMIT {
            return Err("Agent message exceeds the 8 MB limit.".into());
        }
        Ok(messages)
    }

    pub fn has_partial_message(&self) -> bool {
        !self.buffer.iter().all(u8::is_ascii_whitespace)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Message {
    pub id: u64,
    pub role: String,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Choice {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug)]
pub struct Permission {
    pub id: u64,
    request: Value,
    pub title: String,
    pub details: String,
    pub options: Vec<Choice>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Tool {
    pub id: String,
    pub title: String,
    pub status: String,
    pub details: String,
    /// How many messages there were when the agent first reported it: the view places it after them,
    /// where it happened (a later update of its status does not move it).
    pub after_message: usize,
}

/// What the conversation view shows.
#[derive(Clone, Default)]
pub struct State {
    pub messages: Vec<Message>,
    pub tools: Vec<Tool>,
    pub permissions: Vec<Permission>,
    pub plan: Vec<String>,
    pub modes: Vec<Choice>,
    pub current_mode: String,
    pub auth_methods: Vec<Choice>,
    pub status: String,
    pub is_busy: bool,
    pub is_ready: bool,
    pub error: Option<String>,
    /// Counts changes.
    pub revision: u64,
    /// Counts finished turns (the explorer and Git decorations refresh then).
    pub turns_finished: u64,
}

type Continuation = Box<dyn FnOnce(&mut Inner, Result<Value, String>) + Send>;

struct Inner {
    state: State,
    agent: CodingAgent,
    directory: PathBuf,
    mcp_servers: Vec<Value>,
    child: Option<Child>,
    input: Option<ChildStdin>,
    next_request: u64,
    pending: HashMap<u64, (Instant, Continuation)>,
    session_id: Option<String>,
    /// Identifies the turn in progress; a late answer to an older turn changes nothing.
    turn: u64,
    response_message: Option<u64>,
    response_message_id: Option<String>,
    received: usize,
    cancelling: bool,
    cancel_deadline: Option<(Instant, u64)>,
    closed: bool,
    next_id: u64,
    stderr_tail: String,
    /// Identifies the running process: a reader of an earlier one changes nothing.
    process: u64,
}

fn bounded(text: &str, limit: usize) -> String {
    if text.chars().count() > limit {
        format!("{}\n[Preview truncated]", text.chars().take(limit).collect::<String>())
    } else {
        text.to_string()
    }
}

fn pretty(value: &Value) -> String {
    serde_json::to_string_pretty(value).unwrap_or_default()
}

/// A tool call's details: its input, diffs and text, or the whole update if there is nothing else.
fn details(value: &Value) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let Some(input) = value.get("rawInput").filter(|input| input.is_object() || input.is_array()) {
        parts.push(pretty(input));
    }
    for content in value.get("content").and_then(Value::as_array).into_iter().flatten() {
        if content["type"] == "diff" {
            parts.push(format!("{}\nBefore:\n{}\nAfter:\n{}", content["path"].as_str().unwrap_or("File"), content["oldText"].as_str().unwrap_or(""), content["newText"].as_str().unwrap_or("")));
        } else if let Some(text) = content["content"]["text"].as_str() {
            parts.push(text.to_string());
        }
    }
    if parts.is_empty() {
        parts.push(pretty(value));
    }
    bounded(&parts.join("\n"), 16 * 1024)
}

/// Checks the launcher's "MCP servers" text: a JSON array of up to 16 stdio servers.
pub fn parse_mcp(text: &str) -> Result<Vec<Value>, String> {
    if text.trim().is_empty() {
        return Ok(Vec::new());
    }
    let entries = serde_json::from_str::<Value>(text).ok().filter(|_| text.len() <= 64 * 1024).and_then(|value| value.as_array().cloned()).filter(|entries| entries.len() <= 16 && entries.iter().all(Value::is_object)).ok_or("MCP configuration must be an array of up to 16 stdio servers.")?;
    let mut names = std::collections::HashSet::new();
    let mut servers = Vec::new();
    for entry in &entries {
        let name = entry["name"].as_str().filter(|name| !name.is_empty() && names.insert(name.to_string()));
        let command = entry["command"].as_str().filter(|command| (command.starts_with('/') || Path::new(command).is_absolute()) && !command.contains('\0'));
        let arguments = entry["args"].as_array().filter(|arguments| arguments.iter().all(|argument| argument.as_str().is_some_and(|text| !text.contains('\0'))));
        let (Some(name), Some(command), Some(arguments)) = (name, command, arguments) else {
            return Err("Each MCP server needs a unique name, an absolute command path, and an args array.".into());
        };
        let environment = match entry.get("env") {
            None => Vec::new(),
            Some(Value::Array(values)) if values.iter().all(|value| value.as_object().is_some_and(|object| object.values().all(Value::is_string))) => values.clone(),
            Some(_) => return Err("MCP env must be an array of name and value entries.".into()),
        };
        let valid = environment.iter().all(|value| match (value["name"].as_str(), value["value"].as_str()) {
            (Some(key), Some(content)) => !key.is_empty() && !key.contains('=') && !key.contains('\0') && !content.contains('\0'),
            _ => false,
        });
        if !valid {
            return Err("MCP environment entries require valid name and value strings.".into());
        }
        servers.push(json!({"name": name, "command": command, "args": arguments, "env": environment}));
    }
    Ok(servers)
}

/// One agent process and its conversation. Cloning shares the session.
#[derive(Clone)]
pub struct Session {
    inner: Arc<Mutex<Inner>>,
    on_change: Arc<dyn Fn() + Send + Sync>,
}

impl Inner {
    fn changed(&mut self) {
        self.state.revision += 1;
    }

    fn send(&mut self, message: Value) {
        let Ok(mut data) = serde_json::to_vec(&message) else { return };
        if data.len() > MESSAGE_LIMIT {
            return;
        }
        data.push(b'\n');
        if let Some(input) = &mut self.input {
            let _ = input.write_all(&data).and_then(|_| input.flush());
        }
    }

    fn request(&mut self, method: &str, params: Value, timeout: f64, continuation: Continuation) {
        let id = self.next_request;
        self.next_request += 1;
        self.pending.insert(id, (Instant::now() + Duration::from_secs_f64(timeout), continuation));
        self.send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
    }

    fn append_message(&mut self, role: &str, text: &str) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        self.state.messages.push(Message { id, role: role.to_string(), text: text.chars().take(128 * 1024).collect() });
        while self.state.messages.len() > 200 || self.state.messages.iter().map(|message| message.text.len()).sum::<usize>() > 2 * 1024 * 1024 {
            self.state.messages.remove(0);
            // Tool calls keep their place relative to the messages that remain.
            for tool in &mut self.state.tools {
                tool.after_message = tool.after_message.saturating_sub(1);
            }
        }
        id
    }

    fn answer(&mut self, permission: u64, option: Option<&str>) {
        let Some(index) = self.state.permissions.iter().position(|candidate| candidate.id == permission) else { return };
        if option.is_some_and(|option| !self.state.permissions[index].options.iter().any(|choice| choice.id == option)) {
            return;
        }
        let permission = self.state.permissions.remove(index);
        let outcome = match option {
            Some(option) => json!({"outcome": "selected", "optionId": option}),
            None => json!({"outcome": "cancelled"}),
        };
        self.send(json!({"jsonrpc": "2.0", "id": permission.request, "result": {"outcome": outcome}}));
        if self.state.is_busy && !self.cancelling {
            self.state.status = if self.state.permissions.is_empty() { "Working\u{2026}".into() } else { "Permission needed".into() };
        }
    }

    fn cancel_permissions(&mut self) {
        for id in self.state.permissions.iter().map(|permission| permission.id).collect::<Vec<_>>() {
            self.answer(id, None);
        }
    }

    fn new_session(&mut self) {
        let params = json!({"cwd": self.directory.to_string_lossy(), "mcpServers": self.mcp_servers});
        self.state.is_busy = true;
        self.request(
            "session/new",
            params,
            60.0,
            Box::new(|inner, result| {
                inner.state.is_busy = false;
                if inner.closed {
                    return;
                }
                let session = result.and_then(|result| match result["sessionId"].as_str().filter(|id| !id.is_empty()) {
                    Some(id) => Ok((id.to_string(), result.clone())),
                    None => Err("Agent did not provide a session ID.".to_string()),
                });
                match session {
                    Ok((id, result)) => {
                        inner.session_id = Some(id);
                        if let Some(modes) = result.get("modes").filter(|modes| modes.is_object()) {
                            inner.state.current_mode = modes["currentModeId"].as_str().unwrap_or("").to_string();
                            inner.state.modes = modes["availableModes"].as_array().into_iter().flatten().filter_map(|mode| Some(Choice { id: mode["id"].as_str()?.to_string(), name: mode["name"].as_str().or(mode["id"].as_str())?.to_string() })).collect();
                        }
                        inner.state.is_ready = true;
                        inner.state.status = "Ready".into();
                        inner.state.error = None;
                    }
                    Err(error) => {
                        inner.state.error = Some(error);
                        inner.state.status = if inner.state.status == "Signing in\u{2026}" { "Sign-in failed".into() } else { "Connection needs attention".into() };
                    }
                }
            }),
        );
    }

    fn cancel(&mut self) {
        let Some(session) = self.session_id.clone().filter(|_| self.state.is_busy && !self.cancelling) else { return };
        self.cancelling = true;
        self.state.status = "Stopping\u{2026}".into();
        self.cancel_permissions();
        self.send(json!({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": session}}));
        // An agent that does not stop within ten seconds is disconnected.
        self.cancel_deadline = Some((Instant::now() + Duration::from_secs(10), self.turn));
    }

    fn stop_process(&mut self) {
        self.input = None;
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    fn finish(&mut self, message: &str) {
        let error = if self.stderr_tail.trim().is_empty() { message.to_string() } else { format!("{message}\n{}", self.stderr_tail.trim()) };
        for (_, (_, continuation)) in std::mem::take(&mut self.pending) {
            continuation(self, Err(message.to_string()));
        }
        self.stop_process();
        if self.closed {
            return;
        }
        self.state.is_ready = false;
        self.state.is_busy = false;
        self.state.permissions.clear();
        self.state.status = "Disconnected".into();
        self.state.error = Some(error);
    }

    fn receive(&mut self, message: Value) {
        // An answer to one of our requests.
        if message.get("method").is_none() {
            let Some(id) = message["id"].as_u64() else { return };
            let Some((_, continuation)) = self.pending.remove(&id) else { return };
            let result = match message.get("error") {
                Some(error) => Err(error["message"].as_str().unwrap_or("The agent reported an error.").to_string()),
                None => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
            };
            continuation(self, result);
            return;
        }
        let method = message["method"].as_str().unwrap_or("");
        let params = &message["params"];
        let ours = params["sessionId"].as_str().is_some() && params["sessionId"].as_str() == self.session_id.as_deref();
        if let Some(request) = message.get("id") {
            if method != "session/request_permission" || !ours {
                self.send(json!({"jsonrpc": "2.0", "id": request, "error": {"code": -32601, "message": "Client method not supported"}}));
                return;
            }
            if !self.state.is_busy || self.cancelling || self.state.permissions.len() >= 16 {
                self.send(json!({"jsonrpc": "2.0", "id": request, "result": {"outcome": {"outcome": "cancelled"}}}));
                return;
            }
            let tool = &params["toolCall"];
            let previous = self.state.tools.iter().find(|candidate| Some(candidate.id.as_str()) == tool["toolCallId"].as_str()).cloned();
            let mut seen = std::collections::HashSet::new();
            let options = params["options"].as_array().into_iter().flatten().take(16).filter_map(|option| {
                let id = option["optionId"].as_str().filter(|id| seen.insert(id.to_string()))?;
                let name = option["name"].as_str().filter(|name| name.chars().count() <= 1024)?;
                Some(Choice { id: id.to_string(), name: name.to_string() })
            }).collect();
            let has_details = tool.get("content").is_some() || tool.get("rawInput").is_some() || tool.get("rawOutput").is_some();
            let id = self.next_id;
            self.next_id += 1;
            self.state.permissions.push(Permission {
                id,
                request: request.clone(),
                title: bounded(tool["title"].as_str().or(previous.as_ref().map(|tool| tool.title.as_str())).unwrap_or("Agent requests permission"), 1024),
                details: match (&previous, has_details) {
                    (Some(previous), false) => previous.details.clone(),
                    _ => details(tool),
                },
                options,
            });
            self.state.status = "Permission needed".into();
            return;
        }
        if method != "session/update" || !ours {
            return;
        }
        let update = &params["update"];
        match update["sessionUpdate"].as_str().unwrap_or("") {
            "agent_message_chunk" => {
                let Some(text) = update["content"]["text"].as_str().filter(|_| update["content"]["type"] == "text") else { return };
                self.received += text.len();
                if self.received > 512 * 1024 {
                    self.state.error = Some("This response exceeded the display limit. The turn was stopped.".into());
                    self.cancel();
                    return;
                }
                let next = update["messageId"].as_str().map(str::to_string);
                if self.response_message.is_none() || (next.is_some() && self.response_message_id != next) {
                    let name = self.agent.name.clone();
                    self.response_message = Some(self.append_message(&name, ""));
                }
                self.response_message_id = next;
                if let Some(message) = self.state.messages.iter_mut().find(|message| Some(message.id) == self.response_message) {
                    message.text.push_str(text);
                }
            }
            "tool_call" | "tool_call_update" => {
                let Some(id) = update["toolCallId"].as_str() else { return };
                self.response_message = None;
                let has_details = update.get("content").is_some() || update.get("rawInput").is_some() || update.get("rawOutput").is_some();
                if let Some(tool) = self.state.tools.iter_mut().find(|tool| tool.id == id) {
                    if let Some(title) = update["title"].as_str() {
                        tool.title = bounded(title, 1024);
                    }
                    if let Some(status) = update["status"].as_str() {
                        tool.status = bounded(status, 128);
                    }
                    if has_details {
                        tool.details = details(update);
                    }
                } else {
                    let after_message = self.state.messages.len();
                    self.state.tools.push(Tool { id: id.to_string(), title: bounded(update["title"].as_str().unwrap_or("Tool"), 1024), status: bounded(update["status"].as_str().unwrap_or("pending"), 128), details: details(update), after_message });
                    if self.state.tools.len() > 200 {
                        self.state.tools.remove(0);
                    }
                }
            }
            "plan" => {
                self.state.plan = update["entries"].as_array().into_iter().flatten().take(100).map(|entry| bounded(&format!("{} \u{b7} {}", entry["status"].as_str().unwrap_or("pending"), entry["content"].as_str().unwrap_or("")), 2048)).collect();
            }
            "current_mode_update" => {
                if let Some(mode) = update["currentModeId"].as_str() {
                    self.state.current_mode = mode.to_string();
                }
            }
            _ => {}
        }
    }
}

impl Session {
    /// `on_change` is called (on some thread) after the published state changed.
    pub fn new(agent: CodingAgent, directory: &Path, mcp_servers: Vec<Value>, on_change: impl Fn() + Send + Sync + 'static) -> Session {
        let state = State { status: "Connecting\u{2026}".into(), ..State::default() };
        Session {
            inner: Arc::new(Mutex::new(Inner { state, agent, directory: directory.to_path_buf(), mcp_servers, child: None, input: None, next_request: 1, pending: HashMap::new(), session_id: None, turn: 0, response_message: None, response_message_id: None, received: 0, cancelling: false, cancel_deadline: None, closed: false, next_id: 1, stderr_tail: String::new(), process: 0 })),
            on_change: Arc::new(on_change),
        }
    }

    fn with<R>(&self, body: impl FnOnce(&mut Inner) -> R) -> R {
        let result = {
            let mut inner = self.inner.lock();
            let result = body(&mut inner);
            inner.changed();
            result
        };
        (self.on_change)();
        result
    }

    /// A copy of what the view shows.
    pub fn state(&self) -> State {
        self.inner.lock().state.clone()
    }

    pub fn revision(&self) -> u64 {
        self.inner.lock().state.revision
    }

    pub fn agent_name(&self) -> String {
        self.inner.lock().agent.name.clone()
    }

    pub fn directory(&self) -> PathBuf {
        self.inner.lock().directory.clone()
    }

    /// The message that streamed text is being added to, while a turn runs.
    pub fn streaming_message(&self) -> Option<u64> {
        let inner = self.inner.lock();
        inner.state.is_busy.then_some(inner.response_message).flatten()
    }

    /// Starts the agent (`executable`: its resolved path) and opens a conversation.
    pub fn connect(&self, executable: Option<&str>) {
        let started = self.with(|inner| {
            if inner.child.is_some() || inner.closed {
                return None;
            }
            let Some(executable) = executable.filter(|_| inner.agent.is_valid()) else {
                inner.state.error = Some("ACP executable not found. Install the adapter and select its full path in the launcher.".into());
                inner.state.status = "Could not connect".into();
                return None;
            };
            let home = std::env::var("HOME").unwrap_or_default();
            let separator = if cfg!(windows) { ";" } else { ":" };
            let path = if cfg!(windows) { std::env::var("PATH").unwrap_or_default() } else { format!("{home}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin{separator}{}", std::env::var("PATH").unwrap_or_default()) };
            let spawned = Command::new(executable).args(&inner.agent.arguments).current_dir(&inner.directory).env("PATH", path).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn();
            let mut child = match spawned {
                Ok(child) => child,
                Err(error) => {
                    inner.state.error = Some(error.to_string());
                    inner.state.status = "Could not connect".into();
                    return None;
                }
            };
            inner.input = child.stdin.take();
            let pipes = (child.stdout.take(), child.stderr.take());
            inner.child = Some(child);
            inner.process += 1;
            inner.state.is_busy = true;
            let version = env!("CARGO_PKG_VERSION");
            inner.request(
                "initialize",
                json!({"protocolVersion": 1, "clientInfo": {"name": "neolink", "title": "NeoLink", "version": version}, "clientCapabilities": {"fs": {"readTextFile": false, "writeTextFile": false}, "terminal": false}}),
                30.0,
                Box::new(|inner, result| {
                    inner.state.is_busy = false;
                    if inner.closed {
                        return;
                    }
                    match result {
                        Ok(result) if result["protocolVersion"] == 1 => {
                            // Only sign-in flows this client can perform are offered.
                            inner.state.auth_methods = result["authMethods"].as_array().into_iter().flatten().filter(|method| method["type"].as_str().unwrap_or("agent") == "agent").filter_map(|method| Some(Choice { id: method["id"].as_str()?.to_string(), name: method["name"].as_str().or(method["id"].as_str())?.to_string() })).collect();
                            inner.new_session();
                        }
                        Ok(_) => {
                            inner.state.error = Some("The adapter requires an unsupported ACP version.".into());
                            inner.state.status = "Connection needs attention".into();
                        }
                        Err(error) => {
                            inner.state.error = Some(error);
                            inner.state.status = "Connection needs attention".into();
                        }
                    }
                }),
            );
            Some((pipes, inner.process))
        });
        let Some(((Some(mut output), errors), process)) = started else { return };
        // Blocking pipe reads get threads of their own.
        let session = self.clone();
        let _ = std::thread::Builder::new().name("acp stdout".into()).spawn(move || {
            let mut framer = LineFramer::default();
            let mut chunk = vec![0u8; 64 * 1024];
            let ending = loop {
                match output.read(&mut chunk) {
                    Ok(0) => break if framer.has_partial_message() { "The agent closed a partial protocol message.".to_string() } else { "Agent disconnected.".to_string() },
                    Ok(count) => match framer.append(&chunk[..count]) {
                        Ok(messages) => {
                            if !messages.is_empty() {
                                session.with(|inner| {
                                    if inner.process == process {
                                        for message in messages {
                                            inner.receive(message);
                                        }
                                    }
                                });
                            }
                        }
                        Err(error) => break error,
                    },
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(_) => break "Agent pipe closed.".to_string(),
                }
            };
            session.with(|inner| {
                if inner.process == process {
                    inner.finish(&ending);
                }
            });
        });
        if let Some(mut errors) = errors {
            let inner = self.inner.clone();
            let _ = std::thread::Builder::new().name("acp stderr".into()).spawn(move || {
                let mut chunk = vec![0u8; 16 * 1024];
                while let Ok(count) = errors.read(&mut chunk) {
                    if count == 0 {
                        break;
                    }
                    let mut inner = inner.lock();
                    if inner.process == process {
                        let text = format!("{}{}", inner.stderr_tail, String::from_utf8_lossy(&chunk[..count]));
                        let start = text.char_indices().rev().nth(8191).map(|(index, _)| index).unwrap_or(0);
                        inner.stderr_tail = text[start..].to_string();
                    }
                }
            });
        }
        // Deadlines: requests that were never answered, and a turn that would not stop.
        let session = self.clone();
        let _ = std::thread::Builder::new().name("acp deadlines".into()).spawn(move || loop {
            std::thread::sleep(Duration::from_millis(200));
            let mut inner = session.inner.lock();
            if inner.process != process || inner.child.is_none() {
                return;
            }
            let now = Instant::now();
            let late: Vec<u64> = inner.pending.iter().filter(|(_, (deadline, _))| *deadline <= now).map(|(id, _)| *id).collect();
            let gave_up = inner.cancel_deadline.is_some_and(|(deadline, turn)| deadline <= now && turn == inner.turn && inner.cancelling && inner.state.is_busy);
            if late.is_empty() && !gave_up {
                continue;
            }
            for id in late {
                if let Some((_, continuation)) = inner.pending.remove(&id) {
                    continuation(&mut inner, Err("The agent did not answer in time.".into()));
                }
            }
            if gave_up {
                inner.cancel_deadline = None;
                inner.stop_process();
                inner.state.is_ready = false;
                inner.state.is_busy = false;
                inner.state.status = "Stopped \u{b7} reconnect to continue".into();
            }
            inner.changed();
            drop(inner);
            (session.on_change)();
        });
    }

    pub fn authenticate(&self, method: &str) {
        self.with(|inner| {
            if inner.state.is_busy || inner.state.is_ready || !inner.state.auth_methods.iter().any(|choice| choice.id == method) || inner.input.is_none() {
                return;
            }
            inner.state.is_busy = true;
            inner.state.error = None;
            inner.state.status = "Signing in\u{2026}".into();
            inner.request(
                "authenticate",
                json!({"methodId": method}),
                300.0,
                Box::new(|inner, result| {
                    inner.state.is_busy = false;
                    if inner.closed {
                        return;
                    }
                    match result {
                        Ok(_) => inner.new_session(),
                        Err(error) => {
                            inner.state.error = Some(error);
                            inner.state.status = "Sign-in failed".into();
                        }
                    }
                }),
            );
        });
    }

    /// Sends a prompt. Returns `true` if a turn started.
    pub fn send(&self, text: &str, context_path: Option<&str>) -> bool {
        self.with(|inner| {
            let Some(session) = inner.session_id.clone().filter(|_| inner.state.is_ready && !inner.state.is_busy && inner.input.is_some()) else { return false };
            let text = text.trim();
            if text.is_empty() || text.len() > 128 * 1024 {
                inner.state.error = Some("Enter a prompt smaller than 128 KB.".into());
                return false;
            }
            let content = match context_path {
                Some(path) => format!("{text}\n\nContext file (saved on disk): {path}"),
                None => text.to_string(),
            };
            inner.append_message("You", &content);
            inner.response_message = None;
            inner.response_message_id = None;
            inner.received = 0;
            inner.state.tools.clear();
            inner.state.plan.clear();
            inner.state.error = None;
            inner.state.is_busy = true;
            inner.cancelling = false;
            inner.state.status = "Working\u{2026}".into();
            inner.turn += 1;
            let turn = inner.turn;
            inner.request(
                "session/prompt",
                json!({"sessionId": session, "prompt": [{"type": "text", "text": content}]}),
                1800.0,
                Box::new(move |inner, result| {
                    if !inner.closed {
                        match result {
                            Ok(result) if inner.turn == turn => inner.state.status = if result["stopReason"] == "cancelled" { "Stopped".into() } else { "Ready".into() },
                            Ok(_) => {}
                            Err(error) => {
                                inner.state.error = Some(error);
                                inner.state.status = if inner.cancelling { "Stopped \u{b7} reconnect to continue".into() } else { "Turn failed".into() };
                            }
                        }
                    }
                    if inner.turn == turn {
                        inner.state.is_busy = false;
                        inner.cancelling = false;
                        inner.cancel_deadline = None;
                        inner.cancel_permissions();
                        inner.state.turns_finished += 1;
                    }
                }),
            );
            true
        })
    }

    pub fn set_mode(&self, mode: &str) {
        self.with(|inner| {
            let Some(session) = inner.session_id.clone().filter(|_| !inner.state.is_busy && inner.state.is_ready && inner.state.modes.iter().any(|choice| choice.id == mode)) else { return };
            inner.state.is_busy = true;
            let mode = mode.to_string();
            inner.request(
                "session/set_mode",
                json!({"sessionId": session, "modeId": mode}),
                30.0,
                Box::new(move |inner, result| {
                    inner.state.is_busy = false;
                    match result {
                        Ok(_) => inner.state.current_mode = mode,
                        Err(error) => inner.state.error = Some(error),
                    }
                }),
            );
        });
    }

    /// Asks the agent to stop the turn.
    pub fn cancel(&self) {
        self.with(Inner::cancel);
    }

    /// Answers a permission request with one of its options, or `None` to cancel it.
    pub fn answer(&self, permission: u64, option: Option<&str>) {
        self.with(|inner| inner.answer(permission, option));
    }

    /// Ends the conversation and the agent's process.
    pub fn close(&self) {
        self.with(|inner| {
            inner.closed = true;
            inner.turn += 1;
            inner.cancel_permissions();
            inner.pending.clear();
            inner.stop_process();
            inner.state.is_ready = false;
            inner.state.is_busy = false;
            inner.state.status = "Closed".into();
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_split_anywhere_are_put_back_together() {
        let mut framer = LineFramer::default();
        let text = "{\"a\":\"\u{4e16}\u{754c}\"}\n{\"b\":2}\n{\"c\"";
        let bytes = text.as_bytes();
        let mut messages = Vec::new();
        for chunk in bytes.chunks(3) {
            messages.extend(framer.append(chunk).unwrap());
        }
        assert_eq!(messages, vec![json!({"a": "\u{4e16}\u{754c}"}), json!({"b": 2})]);
        assert!(framer.has_partial_message());
        assert!(LineFramer::default().append(b"not json\n").is_err());
        assert!(LineFramer::default().append(b"[1]\n").is_err());
    }

    #[test]
    fn mcp_servers_are_checked() {
        assert_eq!(parse_mcp("  ").unwrap(), Vec::<Value>::new());
        let good = r#"[{"name":"files","command":"/usr/bin/files","args":["--stdio"],"env":[{"name":"A","value":"b"}]}]"#;
        assert_eq!(parse_mcp(good).unwrap()[0]["command"], "/usr/bin/files");
        assert!(parse_mcp(r#"{"name":"x"}"#).is_err());
        assert!(parse_mcp(r#"[{"name":"x","command":"relative","args":[]}]"#).is_err());
        assert!(parse_mcp(r#"[{"name":"x","command":"/a","args":[]},{"name":"x","command":"/b","args":[]}]"#).is_err());
        assert!(parse_mcp(r#"[{"name":"x","command":"/a","args":[],"env":[{"name":"A=B","value":"c"}]}]"#).is_err());
        assert!(parse_mcp(r#"[{"name":"x","command":"/a","args":[],"env":{"A":"b"}}]"#).is_err());
    }

    #[test]
    fn tool_details_prefer_input_and_diffs() {
        let text = details(&json!({"rawInput": {"path": "a.py"}, "content": [{"type": "diff", "path": "a.py", "oldText": "x", "newText": "y"}, {"type": "content", "content": {"type": "text", "text": "done"}}]}));
        assert!(text.contains("\"path\": \"a.py\"") && text.contains("a.py\nBefore:\nx\nAfter:\ny") && text.ends_with("done"));
        assert!(bounded(&"a".repeat(20), 10).ends_with("[Preview truncated]"));
    }
}
