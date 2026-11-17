//! A terminal pane: `alacritty_terminal`'s model and PTY reader, drawn as a cell grid with pixel
//! scrollback.
//!
//! The PTY reader thread parses output into the model and invalidates the window; it never touches the
//! main thread. Scrollback is positioned in device pixels above the newest line and rests wherever the
//! fingers leave it.

use crate::frame::{Next, Painter, Shared};
use crate::render::{Instance, Rect};
use crate::text::CellMetrics;
use crate::theme::{self, Rgba};
use alacritty_terminal::event::{Event, EventListener, Notify, OnResize, WindowSize};
use alacritty_terminal::event_loop::{EventLoop, EventLoopSender, Msg, Notifier};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::sync::FairMutex;
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::tty;
use alacritty_terminal::vte::ansi::{Color, CursorShape, NamedColor, Rgb};
use neolink_core::scroll::{ScrollSmoother, Smoothing};
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock, Weak};

pub const SCROLLBACK_LINES: usize = 10_000;

/// Receives the model's events on the PTY reader thread (often while the model's lock is held, so
/// nothing here may take the window's state lock).
#[derive(Clone)]
pub struct Listener {
    shared: Weak<Shared>,
    output: Arc<AtomicU64>,
    exited: Arc<AtomicBool>,
    title: Arc<Mutex<Option<String>>>,
    sender: Arc<OnceLock<EventLoopSender>>,
    size: Arc<Mutex<WindowSize>>,
}

impl Listener {
    fn reply(&self, text: String) {
        if let Some(sender) = self.sender.get() {
            let _ = sender.send(Msg::Input(text.into_bytes().into()));
        }
    }

    fn invalidate(&self) {
        if let Some(shared) = self.shared.upgrade() {
            shared.invalidate();
        }
    }
}

impl EventListener for Listener {
    fn send_event(&self, event: Event) {
        match event {
            Event::Wakeup => {
                self.output.fetch_add(1, Ordering::Release);
                self.invalidate();
            }
            Event::PtyWrite(text) => self.reply(text),
            Event::Title(title) => {
                *self.title.lock() = Some(title);
                self.invalidate();
            }
            Event::ResetTitle => {
                *self.title.lock() = None;
                self.invalidate();
            }
            Event::ColorRequest(index, format) => {
                let color = match index {
                    0..=255 => theme::indexed(index as u8),
                    257 => theme::EDITOR_BACKGROUND,
                    _ => theme::TEXT_PRIMARY,
                };
                self.reply(format(Rgb { r: color[0], g: color[1], b: color[2] }));
            }
            Event::TextAreaSizeRequest(format) => {
                let size = *self.size.lock();
                self.reply(format(size));
            }
            Event::ChildExit(_) | Event::Exit => {
                self.exited.store(true, Ordering::Release);
                self.invalidate();
            }
            _ => {}
        }
    }
}

struct GridSize {
    columns: usize,
    lines: usize,
}

impl Dimensions for GridSize {
    fn total_lines(&self) -> usize {
        self.lines
    }

    fn screen_lines(&self) -> usize {
        self.lines
    }

    fn columns(&self) -> usize {
        self.columns
    }
}

/// How a scroll event relates to its gesture.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollPhase {
    /// Fingers touched down.
    Began,
    /// Fingers moving, or a device without phases.
    Changed,
    /// Fingers lifted.
    Ended,
    /// The system's momentum after a lift.
    Momentum,
    MomentumEnded,
}

pub struct Terminal {
    pub term: Arc<FairMutex<Term<Listener>>>,
    notifier: Notifier,
    listener: Listener,
    columns: usize,
    lines: usize,
    /// Device pixels scrolled back from the newest line.
    scroll: f64,
    /// The position the last frame drew (whole pixels).
    drawn: f64,
    smoother: ScrollSmoother,
    /// Scrollback length when the last frame was built, to keep the view on the same text while output
    /// arrives.
    last_history: usize,
    /// Pixels of wheel input not yet turned into whole lines for a full-screen program.
    program_remainder: f64,
    /// Scroll input received, in device pixels (for the benchmark).
    pub received: f64,
    scratch: Vec<Instance>,
    resolved: Vec<ResolvedCell>,
    /// Row keys by grid line, valid while `keys_state` describes the grid.
    keys: std::collections::HashMap<i32, u64>,
    keys_state: Option<(u64, usize, usize, usize, bool, bool)>,
    pub fallback_title: String,
    /// `user@host:port` if this is an SSH session.
    pub remote: Option<String>,
    /// The shell's process, to ask the system for its working directory.
    child: Option<u32>,
    master: Option<i32>,
    directory: Option<std::path::PathBuf>,
    directory_checked: (u64, f64),
    /// Counts changes of the selection (part of what a frame shows).
    look: u64,
    /// The pane as last drawn: where it was, and how far it was scrolled.
    drawn_rect: Rect,
}

/// The working directory of process `pid`, where the system can say.
fn process_directory(pid: u32) -> Option<std::path::PathBuf> {
    #[cfg(target_os = "macos")]
    {
        let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
        let written = unsafe { libc::proc_pidinfo(pid as libc::c_int, libc::PROC_PIDVNODEPATHINFO, 0, &mut info as *mut _ as *mut libc::c_void, size) };
        if written != size {
            return None;
        }
        let path = unsafe { std::ffi::CStr::from_ptr(info.pvi_cdir.vip_path.as_ptr() as *const libc::c_char) };
        let path = path.to_str().ok()?;
        (!path.is_empty()).then(|| std::path::PathBuf::from(path))
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        std::fs::read_link(format!("/proc/{pid}/cwd")).ok()
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        None
    }
}

fn window_size(columns: usize, lines: usize, cell: CellMetrics) -> WindowSize {
    WindowSize { num_lines: lines as u16, num_cols: columns as u16, cell_width: cell.width as u16, cell_height: cell.height as u16 }
}

impl Terminal {
    /// Starts the user's shell on a new PTY.
    pub fn spawn(shared: &Arc<Shared>, columns: usize, lines: usize, cell: CellMetrics, directory: Option<std::path::PathBuf>, id: u64) -> std::io::Result<Terminal> {
        Terminal::spawn_program(shared, columns, lines, cell, directory, id, None)
    }

    /// Starts `program` (with arguments) on a new PTY instead of the user's shell.
    pub fn spawn_program(shared: &Arc<Shared>, columns: usize, lines: usize, cell: CellMetrics, directory: Option<std::path::PathBuf>, id: u64, program: Option<(String, Vec<String>)>) -> std::io::Result<Terminal> {
        let size = window_size(columns, lines, cell);
        let listener = Listener {
            shared: Arc::downgrade(shared),
            output: Arc::new(AtomicU64::new(0)),
            exited: Arc::new(AtomicBool::new(false)),
            title: Arc::new(Mutex::new(None)),
            sender: Arc::new(OnceLock::new()),
            size: Arc::new(Mutex::new(size)),
        };
        let config = Config { scrolling_history: SCROLLBACK_LINES, ..Config::default() };
        let term = Term::new(config, &GridSize { columns, lines }, listener.clone());
        let term = Arc::new(FairMutex::new(term));
        let mut env = std::collections::HashMap::new();
        env.insert("TERM_PROGRAM".to_string(), "NeoLink".to_string());
        env.insert("COLORTERM".to_string(), "truecolor".to_string());
        let shell = program.map(|(program, arguments)| tty::Shell::new(program, arguments));
        let options = tty::Options { shell, working_directory: directory, drain_on_exit: false, env, ..tty::Options::default() };
        let start_directory = options.working_directory.clone();
        let pty = tty::new(&options, size, id)?;
        // The PTY's descriptor names the foreground process (the shell at a prompt; on macOS the
        // direct child is `login`, whose directory never changes).
        #[cfg(unix)]
        let (child, master) = {
            use std::os::fd::AsRawFd;
            (Some(pty.child().id()), Some(pty.file().as_raw_fd()))
        };
        #[cfg(not(unix))]
        let (child, master): (Option<u32>, Option<i32>) = (None, None);
        let event_loop = EventLoop::new(term.clone(), listener.clone(), pty, false, false)?;
        let sender = event_loop.channel();
        let _ = listener.sender.set(sender.clone());
        event_loop.spawn();
        let smoothing = match std::env::var("NEOLINK_SCROLL_SMOOTHING").as_deref() {
            Ok("off") => Smoothing::Off,
            _ => Smoothing::Auto,
        };
        Ok(Terminal {
            term,
            notifier: Notifier(sender),
            listener,
            columns,
            lines,
            scroll: 0.0,
            drawn: 0.0,
            smoother: ScrollSmoother::new(smoothing),
            last_history: 0,
            program_remainder: 0.0,
            received: 0.0,
            scratch: Vec::new(),
            resolved: Vec::new(),
            keys: std::collections::HashMap::new(),
            keys_state: None,
            fallback_title: "shell".to_string(),
            remote: None,
            child,
            master,
            directory: start_directory,
            directory_checked: (u64::MAX, 0.0),
            look: 0,
            drawn_rect: Rect::default(),
        })
    }

    /// The shell's working directory. Asked of the system when output arrived since the last answer,
    /// at most twice a second.
    pub fn directory(&mut self) -> Option<&std::path::Path> {
        let output = self.listener.output.load(Ordering::Acquire);
        let now = crate::clock::now();
        if self.directory_checked.0 != output && now - self.directory_checked.1 > 0.5 {
            self.directory_checked = (output, now);
            #[cfg(unix)]
            let foreground = if self.has_exited() { None } else { self.master.map(|descriptor| unsafe { libc::tcgetpgrp(descriptor) }).filter(|pid| *pid > 0).map(|pid| pid as u32) };
            #[cfg(not(unix))]
            let foreground: Option<u32> = None;
            if let Some(directory) = foreground.and_then(process_directory).or_else(|| self.child.and_then(process_directory)) {
                self.directory = Some(directory);
            }
        }
        self.directory.as_deref()
    }

    /// Changes when the selection does.
    pub fn look(&self) -> u64 {
        self.look
    }

    /// The grid point and cell half under `(x, y)` (window pixels), as last drawn.
    fn point_at(&self, x: f32, y: f32, cell: CellMetrics) -> (Point, Side) {
        let rect = self.drawn_rect;
        let column = ((x - rect.x) / cell.width).floor().clamp(0.0, self.columns.saturating_sub(1) as f32);
        let side = if (x - rect.x) - column * cell.width > cell.width * 0.5 { Side::Right } else { Side::Left };
        let whole = (self.drawn / cell.height as f64).floor();
        let fraction = (self.drawn - whole * cell.height as f64) as f32;
        let row = ((y - rect.y - fraction) / cell.height).floor().clamp(-1.0, self.lines as f32 - 1.0) as i32;
        (Point::new(Line(row - whole as i32), Column(column as usize)), side)
    }

    /// The program asked for mouse reports, so presses are its business, not a selection.
    pub fn wants_mouse(&self) -> bool {
        self.term.lock().mode().intersects(TermMode::MOUSE_MODE)
    }

    /// A press at `(x, y)`: starts a selection (`clicks` 2 selects a word, 3 a line), or reports the
    /// press to a program that asked for the mouse.
    pub fn mouse_down(&mut self, x: f32, y: f32, cell: CellMetrics, clicks: u8) {
        let (point, side) = self.point_at(x, y, cell);
        let mut term = self.term.lock();
        if term.mode().intersects(TermMode::MOUSE_MODE) {
            if term.mode().contains(TermMode::SGR_MOUSE) {
                let (column, line) = (point.column.0 + 1, (point.line.0.max(0) + 1) as usize);
                drop(term);
                self.notifier.notify(format!("\x1b[<0;{column};{line}M").into_bytes());
            }
            return;
        }
        let kind = match clicks {
            2 => SelectionType::Semantic,
            3 => SelectionType::Lines,
            _ => SelectionType::Simple,
        };
        term.selection = Some(Selection::new(kind, point, side));
        self.look += 1;
    }

    pub fn mouse_drag(&mut self, x: f32, y: f32, cell: CellMetrics) {
        let (point, side) = self.point_at(x, y, cell);
        let mut term = self.term.lock();
        if term.mode().intersects(TermMode::MOUSE_MODE) {
            return;
        }
        if let Some(selection) = &mut term.selection {
            selection.update(point, side);
            self.look += 1;
        }
    }

    pub fn mouse_up(&mut self, x: f32, y: f32, cell: CellMetrics) {
        let (point, _) = self.point_at(x, y, cell);
        let mut term = self.term.lock();
        if term.mode().intersects(TermMode::MOUSE_MODE) {
            if term.mode().contains(TermMode::SGR_MOUSE) {
                let (column, line) = (point.column.0 + 1, (point.line.0.max(0) + 1) as usize);
                drop(term);
                self.notifier.notify(format!("\x1b[<0;{column};{line}m").into_bytes());
            }
            return;
        }
        // A click without a drag selects nothing.
        if term.selection.as_ref().is_some_and(|selection| selection.is_empty()) {
            term.selection = None;
            self.look += 1;
        }
    }

    /// The selected text, if any.
    pub fn selected_text(&self) -> Option<String> {
        self.term.lock().selection_to_string().filter(|text| !text.is_empty())
    }

    pub fn clear_selection(&mut self) {
        let mut term = self.term.lock();
        if term.selection.take().is_some() {
            self.look += 1;
        }
    }

    /// Finds `query` (plain text, any case) above the current match, or above the newest line when
    /// `restart` is set; wraps round. The match becomes the selection and is scrolled into view.
    /// Returns `false` if the text is nowhere.
    pub fn find(&mut self, query: &str, restart: bool, cell: CellMetrics) -> bool {
        use alacritty_terminal::index::Direction;
        use alacritty_terminal::term::search::RegexSearch;
        if query.is_empty() {
            self.clear_selection();
            return true;
        }
        // The query is literal text: every character that means something in a pattern is escaped.
        let mut pattern = String::from("(?i)");
        for character in query.chars() {
            if "\\.+*?()|[]{}^$#&-~".contains(character) {
                pattern.push('\\');
            }
            pattern.push(character);
        }
        let Ok(mut search) = RegexSearch::new(&pattern) else { return false };
        let mut term = self.term.lock();
        let bottom = Point::new(term.bottommost_line(), term.last_column());
        let current = term.selection.as_ref().and_then(|selection| selection.to_range(&term)).map(|range| range.start);
        let origin = match (restart, current) {
            (false, Some(start)) if start.column.0 > 0 => Point::new(start.line, Column(start.column.0 - 1)),
            (false, Some(start)) if start.line > term.topmost_line() => Point::new(start.line - 1, term.last_column()),
            _ => bottom,
        };
        let Some(found) = term.search_next(&mut search, origin, Direction::Left, Side::Left, None) else { return false };
        let mut selection = Selection::new(SelectionType::Simple, *found.start(), Side::Left);
        selection.update(*found.end(), Side::Right);
        term.selection = Some(selection);
        // Bring the match's line to the middle of the pane if it is in the scrollback.
        let line = found.start().line.0;
        let lines = term.screen_lines() as i32;
        let history = term.grid().history_size() as i32;
        drop(term);
        self.smoother.cancel();
        self.scroll = if line < 0 { ((-line + lines / 2).min(history).max(0)) as f64 * cell.height as f64 } else { 0.0 };
        self.look += 1;
        true
    }

    /// Selects everything, scrollback included.
    pub fn select_all(&mut self) {
        let mut term = self.term.lock();
        let (top, bottom, last) = (term.topmost_line(), term.bottommost_line(), term.last_column());
        let mut selection = Selection::new(SelectionType::Simple, Point::new(top, Column(0)), Side::Left);
        selection.update(Point::new(bottom, last), Side::Right);
        term.selection = Some(selection);
        self.look += 1;
    }

    pub fn title(&self) -> String {
        self.listener.title.lock().clone().unwrap_or_else(|| self.fallback_title.clone())
    }

    pub fn has_exited(&self) -> bool {
        self.listener.exited.load(Ordering::Acquire)
    }

    /// Batches of output parsed so far.
    pub fn output_generation(&self) -> u64 {
        self.listener.output.load(Ordering::Acquire)
    }

    pub fn grid_size(&self) -> (usize, usize) {
        (self.columns, self.lines)
    }

    /// Scrollback position as last drawn: whole device pixels above the newest line.
    pub fn scroll(&self) -> f64 {
        self.drawn
    }

    /// Sends bytes to the program, and returns the view to the newest line. Returns `true` if that moved
    /// the view (typing itself changes nothing on screen until the program answers).
    pub fn write(&mut self, bytes: impl Into<std::borrow::Cow<'static, [u8]>>) -> bool {
        let mut moved = self.scroll != 0.0 || self.smoother.is_active();
        self.scroll = 0.0;
        self.smoother.cancel();
        // Typing ends a selection.
        if self.term.lock().selection.take().is_some() {
            self.look += 1;
            moved = true;
        }
        self.notifier.notify(bytes);
        moved
    }

    /// Pastes text, bracketed when the program asked for that.
    pub fn paste(&mut self, text: &str) {
        let bracketed = self.term.lock().mode().contains(TermMode::BRACKETED_PASTE);
        if bracketed {
            let cleaned = text.replace('\x1b', "");
            self.write(format!("\x1b[200~{cleaned}\x1b[201~").into_bytes());
        } else {
            self.write(text.replace("\r\n", "\r").replace('\n', "\r").into_bytes());
        }
    }

    pub fn mode(&self) -> TermMode {
        *self.term.lock().mode()
    }

    pub fn resize(&mut self, columns: usize, lines: usize, cell: CellMetrics) {
        let (columns, lines) = (columns.max(2), lines.max(1));
        if (columns, lines) == (self.columns, self.lines) {
            return;
        }
        self.columns = columns;
        self.lines = lines;
        let size = window_size(columns, lines, cell);
        *self.listener.size.lock() = size;
        self.term.lock().resize(GridSize { columns, lines });
        self.notifier.on_resize(size);
    }

    /// A scroll event of `delta` device pixels (positive: toward older output), sampled at `time`.
    pub fn scroll_input(&mut self, time: f64, delta: f64, phase: ScrollPhase, cell: CellMetrics, period: f64) {
        if phase == ScrollPhase::Began {
            self.smoother.begin_gesture();
        }
        if delta == 0.0 {
            return;
        }
        self.received += delta;
        let mode = self.mode();
        if mode.contains(TermMode::ALT_SCREEN) || mode.intersects(TermMode::MOUSE_MODE) {
            // A full-screen program scrolls itself: whole lines only.
            self.program_remainder += delta;
            let lines = (self.program_remainder / cell.height as f64).trunc();
            if lines == 0.0 {
                return;
            }
            self.program_remainder -= lines * cell.height as f64;
            let count = lines.abs() as usize;
            let up = lines > 0.0;
            let mut bytes = Vec::new();
            if mode.intersects(TermMode::MOUSE_MODE) {
                let button = if up { 64 } else { 65 };
                for _ in 0..count {
                    if mode.contains(TermMode::SGR_MOUSE) {
                        bytes.extend_from_slice(format!("\x1b[<{button};1;1M").as_bytes());
                    } else {
                        bytes.extend_from_slice(&[0x1b, b'[', b'M', 32 + button, 33, 33]);
                    }
                }
            } else if mode.contains(TermMode::ALTERNATE_SCROLL) {
                let key: &[u8] = match (up, mode.contains(TermMode::APP_CURSOR)) {
                    (true, false) => b"\x1b[A",
                    (false, false) => b"\x1b[B",
                    (true, true) => b"\x1bOA",
                    (false, true) => b"\x1bOB",
                };
                for _ in 0..count {
                    bytes.extend_from_slice(key);
                }
            }
            if !bytes.is_empty() {
                self.notifier.notify(bytes);
            }
            return;
        }
        self.smoother.push(time, delta, period);
    }

    /// Scrolls by whole pages or to an end, at once (keyboard).
    pub fn scroll_by(&mut self, pixels: f64) {
        self.smoother.cancel();
        self.scroll = (self.scroll + pixels).max(0.0);
    }

    fn color(colors: &alacritty_terminal::term::color::Colors, color: Color) -> Rgba {
        let rgb = |rgb: Rgb| [rgb.r, rgb.g, rgb.b, 0xff];
        match color {
            Color::Spec(value) => rgb(value),
            Color::Indexed(index) => colors[index as usize].map(rgb).unwrap_or_else(|| theme::indexed(index)),
            Color::Named(name) => {
                if let Some(value) = colors[name] {
                    return rgb(value);
                }
                match name {
                    NamedColor::Foreground | NamedColor::BrightForeground => theme::TEXT_PRIMARY,
                    NamedColor::Background => theme::EDITOR_BACKGROUND,
                    NamedColor::Cursor => theme::ACCENT,
                    NamedColor::DimForeground => dim(theme::TEXT_PRIMARY),
                    other => {
                        let index = other as usize;
                        if index < 16 {
                            theme::rgb(theme::ANSI[index])
                        } else if (259..=266).contains(&index) {
                            dim(theme::rgb(theme::ANSI[index - 259]))
                        } else {
                            theme::TEXT_PRIMARY
                        }
                    }
                }
            }
        }
    }

    /// Draws the pane into `rect` (device pixels), and says when scrolling will next move it.
    pub fn build(&mut self, painter: &mut Painter, rect: Rect, focused: bool, display: f64, period: f64) -> Next {
        let cell = painter.text.cell;
        let term = self.term.lock();
        let grid = term.grid();
        let (columns, lines) = (grid.columns(), grid.screen_lines());
        let history = grid.history_size();
        let alternate = term.mode().contains(TermMode::ALT_SCREEN);

        // Scrollback position: keep the same text in view while output arrives, then apply this frame's
        // share of the input, and stay within what exists.
        if self.scroll > 0.0 && history > self.last_history && !alternate {
            self.scroll += (history - self.last_history) as f64 * cell.height as f64;
        }
        self.last_history = history;
        let step = self.smoother.advance(display, period);
        let limit = if alternate { 0.0 } else { history as f64 * cell.height as f64 };
        let wanted = self.scroll + step;
        self.scroll = wanted.clamp(0.0, limit);
        if wanted != self.scroll {
            // An end of the buffer: what did not fit is dropped, so reversing answers at once.
            self.smoother.cancel();
        }
        let scroll = self.scroll.round();
        let whole = (scroll / cell.height as f64).floor();
        let fraction = (scroll - whole * cell.height as f64) as f32;
        let offset = whole as i32;

        self.drawn_rect = rect;
        painter.scene.set_clip(Some(rect));
        // The selection, under the text (cells without a background of their own show it).
        if let Some(range) = term.selection.as_ref().and_then(|selection| selection.to_range(&term)) {
            for row in -1..lines as i32 {
                let line = Line(row - offset);
                if line < range.start.line || line > range.end.line {
                    continue;
                }
                let (from, to) = if range.is_block {
                    (range.start.column.0, range.end.column.0 + 1)
                } else {
                    (if line == range.start.line { range.start.column.0 } else { 0 }, if line == range.end.line { range.end.column.0 + 1 } else { columns })
                };
                if to > from {
                    painter.scene.fill(rect.x + from as f32 * cell.width, rect.y + row as f32 * cell.height + fraction, (to - from) as f32 * cell.width, cell.height, theme::TERMINAL_SELECTION);
                }
            }
        }
        let colors = term.colors();
        let cursor = grid.cursor.point;
        let show_cursor = term.mode().contains(TermMode::SHOW_CURSOR);
        let cursor_shape = term.cursor_style().shape;
        let first_row = if fraction > 0.0 { -1 } else { 0 };
        let mut scratch = std::mem::take(&mut self.scratch);
        let mut resolved = std::mem::take(&mut self.resolved);
        // While nothing was written to the grid, a line's key is what it was in the last frame: a
        // scroll then looks at no cell at all, except in the lines that come into view.
        let state = (self.listener.output.load(Ordering::Acquire), columns, lines, history, focused, show_cursor);
        if self.keys_state != Some(state) || self.keys.len() > 8192 {
            self.keys.clear();
            self.keys_state = Some(state);
        }
        for row in first_row..lines as i32 {
            let line = Line(row - offset);
            if line.0 < -(history as i32) {
                continue;
            }
            let y = rect.y + row as f32 * cell.height + fraction;
            if let Some(retained) = self.keys.get(&line.0).and_then(|key| painter.rows.get(*key)) {
                painter.scene.retained(retained, rect.x, y);
                continue;
            }
            let cells = &grid[line];
            let cursor_column = (show_cursor && line == cursor.line).then_some(cursor.column.0);

            // Resolve the row once: what each cell shows, and a key of all of it.
            resolved.clear();
            let mut key = RowKey::new(columns as u64);
            for column in 0..columns {
                let source = &cells[Column(column)];
                let flags = source.flags;
                let inverse = flags.contains(Flags::INVERSE);
                let default_background = matches!(source.bg, Color::Named(NamedColor::Background));
                let mut foreground = Self::color(colors, if inverse { source.bg } else { source.fg });
                if inverse && default_background {
                    foreground = theme::EDITOR_BACKGROUND;
                }
                if flags.contains(Flags::DIM) {
                    foreground = dim(foreground);
                }
                let background = if !inverse && default_background { None } else { Some(Self::color(colors, if inverse { source.fg } else { source.bg })) };
                let character = if flags.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER | Flags::HIDDEN) { ' ' } else { source.c };
                key.add(character as u64 | (flags.bits() as u64) << 32);
                key.add(u32::from_le_bytes(foreground) as u64 | (background.map_or(0, u32::from_le_bytes) as u64) << 32);
                resolved.push(ResolvedCell { character, foreground, background, flags });
            }
            if let Some(column) = cursor_column {
                key.add(0xC0FFEE ^ (column as u64) << 8 ^ (cursor_shape as u64) << 40 ^ (focused as u64) << 48);
            }
            let key = key.finish();
            self.keys.insert(line.0, key);
            let retained = match painter.rows.get(key) {
                Some(row) => Some(row),
                None => {
                    scratch.clear();
                    Self::build_row(&mut scratch, painter, &resolved, cell, cursor_column, cursor_shape, focused);
                    painter.rows.insert(key, &scratch)
                }
            };
            match retained {
                Some(row) => painter.scene.retained(row, rect.x, y),
                None => painter.scene.translated(&scratch, rect.x, y),
            }
        }
        self.scratch = scratch;
        self.resolved = resolved;
        painter.scene.set_clip(None);
        self.drawn = scroll;
        match self.smoother.next_visible_change(display, period, self.scroll) {
            None => Next::Idle,
            Some(at) if at <= display + 1.5 * period => Next::Soon,
            Some(at) => Next::At(at),
        }
    }

    /// One row as instances relative to the row's top left corner.
    fn build_row(out: &mut Vec<Instance>, painter: &mut Painter, cells: &[ResolvedCell], cell: CellMetrics, cursor_column: Option<usize>, cursor_shape: CursorShape, focused: bool) {
        // Backgrounds first, merged into runs.
        let mut run: Option<(usize, Rgba)> = None;
        for column in 0..=cells.len() {
            let background = cells.get(column).and_then(|cell| cell.background);
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
        let line_thickness = (cell.font_pixels / 14.0).round().max(1.0);
        for (column, source) in cells.iter().enumerate() {
            let x = column as f32 * cell.width;
            let mut foreground = source.foreground;
            if cursor_column == Some(column) && focused && cursor_shape == CursorShape::Block {
                out.push(Instance::fill(x, 0.0, cell.width, cell.height, theme::ACCENT));
                foreground = theme::EDITOR_BACKGROUND;
            }
            let flags = source.flags;
            if let Some(glyph) = painter.text.cell_glyph(painter.queue, source.character, flags.contains(Flags::BOLD), flags.contains(Flags::ITALIC)) {
                out.push(Instance::glyph(glyph.sprite, x + glyph.x as f32, cell.baseline + glyph.y as f32, foreground));
            }
            if flags.intersects(Flags::ALL_UNDERLINES) {
                out.push(Instance::fill(x, cell.baseline + 2.0, cell.width, line_thickness, foreground));
            }
            if flags.contains(Flags::STRIKEOUT) {
                out.push(Instance::fill(x, (cell.baseline * 0.68).round(), cell.width, line_thickness, foreground));
            }
        }
        if let Some(column) = cursor_column {
            let x = column as f32 * cell.width;
            let thickness = (cell.font_pixels / 8.0).round().max(2.0);
            match cursor_shape {
                CursorShape::Block if !focused => outline(out, x, 0.0, cell.width, cell.height, theme::ACCENT),
                CursorShape::HollowBlock => outline(out, x, 0.0, cell.width, cell.height, theme::ACCENT),
                CursorShape::Beam => out.push(Instance::fill(x, 0.0, thickness, cell.height, theme::ACCENT)),
                CursorShape::Underline => out.push(Instance::fill(x, cell.height - thickness, cell.width, thickness, theme::ACCENT)),
                _ => {}
            }
        }
    }

    /// `(events spread, all events, longest delay in ms)` of the scroll smoothing so far.
    pub fn smoothing_report(&self) -> (usize, usize, f64) {
        self.smoother.delay_report()
    }

    pub fn shutdown(&self) {
        let _ = self.notifier.0.send(Msg::Shutdown);
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn dim(color: Rgba) -> Rgba {
    [(color[0] as f32 * 0.66) as u8, (color[1] as f32 * 0.66) as u8, (color[2] as f32 * 0.66) as u8, color[3]]
}

fn outline(out: &mut Vec<Instance>, x: f32, y: f32, width: f32, height: f32, color: Rgba) {
    out.push(Instance::fill(x, y, width, 2.0, color));
    out.push(Instance::fill(x, y + height - 2.0, width, 2.0, color));
    out.push(Instance::fill(x, y, 2.0, height, color));
    out.push(Instance::fill(x + width - 2.0, y, 2.0, height, color));
}

/// What one cell shows, after colours, inversion and dimming are resolved.
#[derive(Clone, Copy)]
struct ResolvedCell {
    character: char,
    foreground: Rgba,
    background: Option<Rgba>,
    flags: Flags,
}

/// A hash of a row's resolved cells: rows with equal keys draw the same pixels.
struct RowKey(u64);

impl RowKey {
    fn new(seed: u64) -> RowKey {
        RowKey(0x9E3779B97F4A7C15 ^ seed)
    }

    #[inline]
    fn add(&mut self, value: u64) {
        self.0 = (self.0.rotate_left(5) ^ value).wrapping_mul(0x517cc1b727220a95);
    }

    fn finish(&self) -> u64 {
        self.0 ^ (self.0 >> 29)
    }
}
