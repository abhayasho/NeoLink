mod agents;
mod bench;
mod capture;
mod chrome;
mod clock;
mod dock;
mod editor;
mod explorer;
mod frame;
mod gitview;
mod gpu;
mod icons;
mod input;
mod menu;
#[cfg(target_os = "macos")]
mod menubar;
mod present;
mod render;
mod search;
mod settings;
mod spike;
mod term;
mod text;
mod theme;
mod workspace;

use bench::{BenchState, Injected, KeyRecord};
use frame::Shared;
use std::sync::Arc;
use std::time::Duration;
use term::ScrollPhase;
use winit::application::ApplicationHandler;
use winit::dpi::LogicalSize;
use winit::event::{ElementState, MouseButton, MouseScrollDelta, TouchPhase, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy};
use winit::keyboard::{Key, ModifiersState, NamedKey};
use winit::window::{Window, WindowId};
use workspace::Workspace;

/// The Swift app's default text size (`TextSizePreferences`).
const DEFAULT_FONT_POINTS: f32 = 13.0;

#[derive(Debug, Clone)]
enum UserEvent {
    Injected(Injected),
    /// A menu bar item was chosen.
    Command(String),
    SpikeChange,
    Quit,
}

struct App {
    proxy: EventLoopProxy<UserEvent>,
    window: Option<Arc<Window>>,
    shared: Option<Arc<Shared>>,
    modifiers: ModifiersState,
    pointer: (f32, f32),
    resize_cursor: u8,
    /// The settings as last written, and when they were last compared.
    saved: settings::Settings,
    settings_checked: f64,
    bench: Arc<BenchState>,
    #[cfg(target_os = "macos")]
    menu_bar: Option<muda::Menu>,
    spike: Option<String>,
    spike_seconds: f64,
}

fn display_period(window: &Window) -> f64 {
    window
        .current_monitor()
        .and_then(|monitor| monitor.refresh_rate_millihertz())
        .filter(|rate| *rate > 1000)
        .map(|rate| 1000.0 / rate as f64)
        .unwrap_or(1.0 / 60.0)
}

/// The scroll event being delivered, as the system describes it: its sampling time and whether it is
/// finger motion or momentum. winit reports neither.
#[cfg(target_os = "macos")]
fn native_scroll() -> Option<(f64, ScrollPhase)> {
    use objc2_app_kit::{NSApplication, NSEventPhase, NSEventType};
    let main = objc2::MainThreadMarker::new()?;
    let event = NSApplication::sharedApplication(main).currentEvent()?;
    if event.r#type() != NSEventType::ScrollWheel {
        return None;
    }
    let (phase, momentum) = (event.phase(), event.momentumPhase());
    let kind = if momentum.contains(NSEventPhase::Ended) || momentum.contains(NSEventPhase::Cancelled) {
        ScrollPhase::MomentumEnded
    } else if !momentum.is_empty() {
        ScrollPhase::Momentum
    } else if phase.contains(NSEventPhase::Began) || phase.contains(NSEventPhase::MayBegin) {
        ScrollPhase::Began
    } else if phase.contains(NSEventPhase::Ended) || phase.contains(NSEventPhase::Cancelled) {
        ScrollPhase::Ended
    } else {
        ScrollPhase::Changed
    };
    Some((event.timestamp(), kind))
}

#[cfg(not(target_os = "macos"))]
fn native_scroll() -> Option<(f64, ScrollPhase)> {
    None
}

impl App {
    fn with_workspace<R>(&self, body: impl FnOnce(&mut Workspace, &Arc<Shared>) -> R) -> Option<R> {
        let shared = self.shared.as_ref()?;
        let mut state = shared.state.lock();
        let workspace = state.content.as_any().downcast_mut::<Workspace>()?;
        Some(body(workspace, shared))
    }

    fn invalidate(&self) {
        if let Some(shared) = &self.shared {
            shared.invalidate();
        }
    }

    /// Bytes for the active pane (typed, pasted or injected).
    fn write(&self, bytes: Vec<u8>) {
        // No frame for the key itself: the frame belongs to the program's answer, which arrives a
        // moment later and would otherwise find this refresh already taken.
        let changed = self.with_workspace(|workspace, _| {
            if workspace.keys_go_to_editor() {
                // Injected text for the editor: literal characters.
                workspace.editor_input(&String::from_utf8_lossy(&bytes).replace('<', "<lt>"));
                false
            } else {
                workspace.write(bytes)
            }
        });
        if changed == Some(true) {
            self.invalidate();
        }
    }

    fn open_document(&self, path: &std::path::Path) {
        self.with_workspace(|workspace, _| workspace.open_document(path));
        self.invalidate();
    }

    /// A scroll report in device pixels.
    fn scroll(&self, time: f64, delta_x: f64, delta_y: f64, phase: ScrollPhase) {
        self.with_workspace(|workspace, _| workspace.scroll(time, delta_x, delta_y, phase));
        self.invalidate();
    }

    fn select_tab(&self, index: usize, sent: f64) {
        let handled = clock::now();
        let bench = self.bench.clone();
        self.with_workspace(|workspace, _| {
            workspace.select(index);
            let generation = workspace_selection(workspace);
            bench.selections.lock().push((sent, handled, generation));
        });
        self.invalidate();
    }

    fn new_tab(&self) {
        self.with_workspace(|workspace, shared| {
            if let Err(error) = workspace.new_tab(shared) {
                eprintln!("cannot start a shell: {error}");
            }
        });
        self.invalidate();
    }

    /// Writes the settings file if anything it holds changed.
    fn save_settings(&mut self) {
        if self.spike.is_some() || settings::path().is_none() {
            return;
        }
        let Some(window) = &self.window else { return };
        let mut current = self.saved.clone();
        // A full-screen or minimized window keeps the frame it had before.
        if window.fullscreen().is_none() && window.is_minimized() != Some(true) {
            let scale = window.scale_factor();
            if let Ok(position) = window.outer_position() {
                let (position, size) = (position.to_logical::<f64>(scale), window.inner_size().to_logical::<f64>(scale));
                current.window = Some((position.x.round(), position.y.round(), size.width.round(), size.height.round()));
            }
        }
        let Some(current) = self.with_workspace(|workspace, _| workspace.settings(current)) else { return };
        if current != self.saved {
            settings::save(&current);
            self.saved = current;
        }
    }

    /// A menu bar choice (see `menubar`).
    fn menu_command(&mut self, command: &str, event_loop: &ActiveEventLoop) {
        if let Some(shared) = &self.shared {
            shared.note_input();
        }
        if let Some(rest) = command.strip_prefix("key:") {
            let Some((flags, character)) = rest.split_once(':') else { return };
            let mut modifiers = ModifiersState::empty();
            for flag in flags.chars() {
                modifiers |= match flag {
                    'c' => ModifiersState::SUPER,
                    's' => ModifiersState::SHIFT,
                    'x' => ModifiersState::CONTROL,
                    _ => ModifiersState::empty(),
                };
            }
            // The same code as the key itself, with the item's modifiers.
            let held = std::mem::replace(&mut self.modifiers, modifiers);
            self.shortcut(&Key::Character(character.into()), event_loop);
            self.modifiers = held;
        } else if let Some(action) = command.strip_prefix("editor:") {
            self.with_workspace(|workspace, _| match action {
                "copy" => {
                    workspace.copy();
                }
                "selectAll" => workspace.select_all(),
                _ => workspace.editor_action(action),
            });
        } else if let Some(side) = command.strip_prefix("dock:") {
            self.with_workspace(|workspace, _| workspace.toggle_dock(side == "bottom"));
        } else if let Some(program) = command.strip_prefix("repl:") {
            self.with_workspace(|workspace, _| workspace.open_repl(program));
        }
        self.invalidate();
    }

    /// Application shortcuts (Command on macOS, Control+Shift elsewhere). Returns `true` if handled.
    fn shortcut(&self, key: &Key, event_loop: &ActiveEventLoop) -> bool {
        let modifiers = self.modifiers;
        let command = if cfg!(target_os = "macos") { modifiers.super_key() } else { modifiers.control_key() && modifiers.shift_key() };
        // Control-` shows the terminal under the code and puts the keyboard in it (again: hides it).
        if modifiers.control_key() && !modifiers.super_key() && !modifiers.alt_key() && matches!(key, Key::Character(text) if text.as_str() == "`" || text.as_str() == "~") {
            let below = !modifiers.shift_key();
            self.with_workspace(|workspace, _| workspace.toggle_dock(below));
            self.invalidate();
            return true;
        }
        if !command {
            if modifiers.shift_key() && !modifiers.control_key() && !modifiers.alt_key() {
                let pages = match key {
                    Key::Named(NamedKey::PageUp) => 1.0,
                    Key::Named(NamedKey::PageDown) => -1.0,
                    _ => return false,
                };
                self.with_workspace(|workspace, _| workspace.scroll_pages(pages));
                self.invalidate();
                return true;
            }
            if modifiers.control_key() && matches!(key, Key::Named(NamedKey::Tab)) {
                let step = if modifiers.shift_key() { -1 } else { 1 };
                self.with_workspace(|workspace, _| workspace.select_relative(step));
                self.invalidate();
                return true;
            }
            return false;
        }
        // Command-Return sends the prompt of an agent conversation.
        if matches!(key, Key::Named(NamedKey::Enter)) && self.with_workspace(|workspace, _| workspace.submit_prompt()) == Some(true) {
            self.invalidate();
            return true;
        }
        let Key::Character(characters) = key else { return false };
        // The Swift app's Shift and Control variants of a Command shortcut. Elsewhere the command chord
        // is Control+Shift, so Alt marks the Shift variant and there is no Control variant.
        let (shifted, controlled) = if cfg!(target_os = "macos") { (modifiers.shift_key(), modifiers.control_key()) } else { (modifiers.alt_key(), false) };
        match characters.to_lowercase().as_str() {
            "t" => self.new_tab(),
            "w" if shifted => event_loop.exit(),
            "n" if shifted => {
                self.with_workspace(|workspace, _| workspace.unavailable("SSH connections"));
                self.invalidate();
            }
            "a" if controlled => {
                self.with_workspace(|workspace, _| workspace.open_launcher());
                self.invalidate();
            }
            "s" if controlled => {
                self.with_workspace(|workspace, _| workspace.unavailable("The connections sidebar"));
                self.invalidate();
            }
            "b" if controlled => {
                self.with_workspace(|workspace, _| workspace.toggle_agent_panel());
                self.invalidate();
            }
            "w" => {
                let empty = self.with_workspace(|workspace, _| {
                    let index = workspace.active_index();
                    workspace.close_tab(index);
                    workspace.tab_count() == 0
                });
                if empty == Some(true) {
                    event_loop.exit();
                }
                self.invalidate();
            }
            "q" => event_loop.exit(),
            "]" | "}" if shifted => {
                self.with_workspace(|workspace, _| workspace.step_tab(1));
                self.invalidate();
            }
            "[" | "{" if shifted => {
                self.with_workspace(|workspace, _| workspace.step_tab(-1));
                self.invalidate();
            }
            "e" if shifted => {
                self.with_workspace(|workspace, _| workspace.toggle_explorer());
                self.invalidate();
            }
            "f" if controlled => {
                if let Some(window) = &self.window {
                    window.set_fullscreen(if window.fullscreen().is_some() { None } else { Some(winit::window::Fullscreen::Borderless(None)) });
                }
            }
            "o" => {
                // Open File... / Open Project... (the system's panel; it runs on this, the main, thread).
                if shifted {
                    if let Some(folder) = rfd::FileDialog::new().pick_folder() {
                        self.with_workspace(|workspace, _| workspace.set_project(neolink_core::paths::canonical(&folder)));
                    }
                } else if let Some(file) = rfd::FileDialog::new().pick_file() {
                    self.open_document(&file);
                }
                self.invalidate();
            }
            "m" => {
                if let Some(window) = &self.window {
                    window.set_minimized(true);
                }
            }
            "p" => {
                self.with_workspace(|workspace, _| workspace.open_search(false));
                self.invalidate();
            }
            "g" if shifted => {
                self.with_workspace(|workspace, _| workspace.open_git());
                self.invalidate();
            }
            "f" if shifted => {
                self.with_workspace(|workspace, _| workspace.open_search(true));
                self.invalidate();
            }
            "b" => {
                self.with_workspace(|workspace, _| workspace.toggle_explorer());
                self.invalidate();
            }
            "s" => {
                self.with_workspace(|workspace, _| workspace.save_active());
            }
            "z" => {
                let action = if shifted { "redo" } else { "undo" };
                self.with_workspace(|workspace, _| workspace.editor_action(action));
            }
            "f" => {
                self.with_workspace(|workspace, _| workspace.editor_action("find"));
            }
            "c" => {
                self.with_workspace(|workspace, _| workspace.copy());
            }
            "a" => {
                self.with_workspace(|workspace, _| workspace.select_all());
                self.invalidate();
            }
            "v" => {
                if let Ok(text) = arboard::Clipboard::new().and_then(|mut clipboard| clipboard.get_text()) {
                    self.with_workspace(|workspace, _| workspace.paste(&text));
                    self.invalidate();
                }
            }
            "=" | "+" => {
                self.with_workspace(|workspace, _| workspace.set_font_points(workspace.font_points + 1.0));
                self.invalidate();
            }
            "-" => {
                self.with_workspace(|workspace, _| workspace.set_font_points(workspace.font_points - 1.0));
                self.invalidate();
            }
            "0" => {
                self.with_workspace(|workspace, _| workspace.set_font_points(DEFAULT_FONT_POINTS));
                self.invalidate();
            }
            "{" | "[" if shifted => {
                self.with_workspace(|workspace, _| workspace.select_relative(-1));
                self.invalidate();
            }
            "}" | "]" if shifted => {
                self.with_workspace(|workspace, _| workspace.select_relative(1));
                self.invalidate();
            }
            digit if digit.len() == 1 && digit.as_bytes()[0].is_ascii_digit() && digit != "0" => {
                let index = (digit.as_bytes()[0] - b'1') as usize;
                self.select_tab(index, clock::now());
            }
            _ => return false,
        }
        true
    }

    fn start(&mut self, event_loop: &ActiveEventLoop) {
        // As the Swift app's window: 1280 x 800, at least 900 x 560, dark.
        let saved = if self.spike.is_some() { settings::Settings::default() } else { settings::load() };
        let frame = saved.window.filter(|frame| frame.2 >= 900.0 && frame.3 >= 560.0 && frame.2 <= 10_000.0 && frame.3 <= 10_000.0);
        let attributes = Window::default_attributes()
            .with_title("NeoLink")
            .with_inner_size(LogicalSize::new(frame.map_or(1280.0, |frame| frame.2), frame.map_or(800.0, |frame| frame.3)))
            .with_min_inner_size(LogicalSize::new(900.0, 560.0))
            .with_theme(Some(winit::window::Theme::Dark));
        #[cfg(target_os = "macos")]
        let attributes = {
            use winit::platform::macos::WindowAttributesExtMacOS;
            // A hidden title over a transparent title bar, in the sidebar's colour.
            attributes.with_title_hidden(true).with_titlebar_transparent(true)
        };
        // The remembered position, if a screen still shows that place.
        let attributes = match frame {
            Some(frame) if event_loop.available_monitors().any(|monitor| {
                let (origin, size, scale) = (monitor.position(), monitor.size(), monitor.scale_factor());
                let (x, y) = (frame.0 * scale, frame.1 * scale);
                x >= origin.x as f64 - 40.0 && y >= origin.y as f64 - 40.0 && x < origin.x as f64 + size.width as f64 - 80.0 && y < origin.y as f64 + size.height as f64 - 80.0
            }) => attributes.with_position(winit::dpi::LogicalPosition::new(frame.0, frame.1)),
            _ => attributes,
        };
        let window = Arc::new(event_loop.create_window(attributes).expect("a window"));
        let gpu = gpu::Gpu::new().expect("a GPU");
        #[cfg(target_os = "macos")]
        let presenter = present::Presenter::new(&gpu, &window).expect("a presenter");
        #[cfg(not(target_os = "macos"))]
        let presenter = present::Presenter::new(&gpu, window.clone()).expect("a presenter");
        let size = window.inner_size();
        let scale = window.scale_factor();
        let period = display_period(&window);
        let text = text::TextSystem::new(&gpu.device, saved.font_points.clamp(10.0, 24.0), scale as f32);
        let font_family = text.family().to_string();

        let shared = if let Some(mode) = &self.spike {
            eprintln!("PERIOD {period:.6}");
            Shared::new(Box::new(spike::SpikeGrid::new(mode == "motion")), (size.width, size.height), scale, period)
        } else {
            let mut workspace = Workspace::new(text.cell, saved.font_points.clamp(10.0, 24.0), scale as f32, (size.width, size.height), period);
            workspace.apply_settings(&saved);
            self.saved = saved.clone();
            let proxy = self.proxy.clone();
            workspace.set_on_empty(Box::new(move || {
                let _ = proxy.send_event(UserEvent::Quit);
            }));
            let shared = Shared::new(Box::new(workspace), (size.width, size.height), scale, period);
            {
                let mut state = shared.state.lock();
                if let Some(workspace) = state.content.as_any().downcast_mut::<Workspace>() {
                    workspace.attach(&shared);
                    // Files named on the command line open as document tabs.
                    // A folder named on the command line is the project; files open as document tabs.
                    let arguments: Vec<std::path::PathBuf> = std::env::args().skip(1).filter(|argument| !argument.starts_with("--")).map(std::path::PathBuf::from).collect();
                    // A folder on the command line is the project; otherwise the one open last time.
                    if let Some(folder) = arguments.iter().find(|path| path.is_dir()).cloned().or_else(|| saved.project.clone().filter(|path| path.is_dir() && arguments.is_empty())) {
                        workspace.set_project(neolink_core::paths::canonical(&folder));
                    }
                    // The first shell starts in the project.
                    if let Err(error) = workspace.new_tab(&shared) {
                        eprintln!("cannot start a shell: {error}");
                    }
                    if std::env::var("NEOLINK_EXPLORER").as_deref() == Ok("0") {
                        workspace.explorer.visible = false;
                    }
                    for file in arguments.iter().filter(|path| path.is_file()) {
                        workspace.open_document(file);
                        workspace.explorer.reveal(&neolink_core::paths::canonical(file));
                    }
                }
            }
            shared
        };
        frame::spawn(shared.clone(), gpu, presenter, text);
        let fullscreen = std::env::var("NEOLINK_WINDOW").as_deref() == Ok("fullscreen");
        if fullscreen {
            window.set_fullscreen(Some(winit::window::Fullscreen::Borderless(None)));
        }
        window.focus_window();
        self.window = Some(window.clone());
        self.shared = Some(shared.clone());

        if let Some(mode) = self.spike.clone() {
            self.start_spike(mode);
        } else if let Some(options) = bench::Options::from_env() {
            let proxy = self.proxy.clone();
            let environment = serde_json::json!({
                "window": if fullscreen { "fullscreen" } else { "windowed" },
                "scale": scale,
                "font": font_family,
                "fontPoints": DEFAULT_FONT_POINTS,
                "scrollSmoothing": std::env::var("NEOLINK_SCROLL_SMOOTHING").unwrap_or_else(|_| "auto".into()),
                "exactDisplayTimes": cfg!(target_os = "macos"),
                "os": std::env::consts::OS,
            });
            bench::start(
                options,
                shared,
                self.bench.clone(),
                Box::new(move |injected| {
                    let _ = proxy.send_event(UserEvent::Injected(injected));
                }),
                environment,
            );
        }
    }

    /// The stack spike's change source: a thread that posts to the main thread, as input would arrive.
    fn start_spike(&self, mode: String) {
        let proxy = self.proxy.clone();
        let seconds = self.spike_seconds;
        let gap: Option<u64> = std::env::var("SPIKE_GAP_MS").ok().and_then(|value| value.parse().ok());
        std::thread::spawn(move || {
            let start = clock::now();
            let mut seed: u64 = 0x2545F4914F6CDD1D;
            std::thread::sleep(Duration::from_millis(3000));
            while clock::now() - start < seconds + 3.0 {
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                let wait = match (mode.as_str(), gap) {
                    // A fixed pause between changes, with a little jitter so the phase varies.
                    (_, Some(gap)) => gap * 1000 + (seed >> 40) % 9_000,
                    ("dense", _) => 33_000 + (seed >> 40) % 700,
                    ("sparse", _) => 90_000 + (seed >> 40) % 160_000,
                    _ => 100_000,
                };
                std::thread::sleep(Duration::from_micros(wait));
                if mode == "dense" || mode == "sparse" {
                    let _ = proxy.send_event(UserEvent::SpikeChange);
                }
            }
            let _ = proxy.send_event(UserEvent::Quit);
        });
    }
}

fn workspace_selection(workspace: &mut Workspace) -> u64 {
    workspace.selection_generation()
}

impl ApplicationHandler<UserEvent> for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_none() {
            self.start(event_loop);
            #[cfg(target_os = "macos")]
            if self.menu_bar.is_none() && std::env::var("NEOLINK_MENU_BAR").as_deref() != Ok("0") {
                let proxy = self.proxy.clone();
                self.menu_bar = menubar::install(move |command| {
                    let _ = proxy.send_event(UserEvent::Command(command));
                });
            }
        }
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: UserEvent) {
        if let (Some(shared), UserEvent::Injected(Injected::Text { .. } | Injected::Scroll { .. } | Injected::SelectTab { .. } | Injected::OpenDocument { .. } | Injected::Keys(_)) | UserEvent::SpikeChange) = (&self.shared, &event) {
            shared.note_input();
        }
        match event {
            UserEvent::Injected(injected) => match injected {
                Injected::Text { bytes, sent, measure } => {
                    if measure {
                        let handled = clock::now();
                        let output_before = self.with_workspace(|workspace, _| workspace.output_generation()).unwrap_or(0);
                        self.bench.keys.lock().push(KeyRecord { sent, handled, output_before });
                    }
                    self.write(bytes);
                }
                Injected::Scroll { time, delta_x, delta_y, phase } => {
                    let scale = self.window.as_ref().map(|window| window.scale_factor()).unwrap_or(1.0);
                    self.scroll(time, delta_x * scale, delta_y * scale, phase);
                }
                Injected::Busy(hold) => {
                    let until = clock::now() + hold;
                    while clock::now() < until {
                        std::hint::spin_loop();
                    }
                }
                Injected::NewTab => self.new_tab(),
                Injected::OpenDocument { path, sent } => {
                    let handled = clock::now();
                    self.open_document(std::path::Path::new(&path));
                    let generation = self.with_workspace(|workspace, _| workspace.selection_generation()).unwrap_or(0);
                    self.bench.selections.lock().push((sent, handled, generation));
                }
                Injected::Keys(keys) => {
                    self.with_workspace(|workspace, _| workspace.editor_input(&keys));
                }
                Injected::Control(name) if name.starts_with("command:") => {
                    // A menu bar command by its identifier, e.g. "command:key:c:a".
                    self.menu_command(&name["command:".len()..], event_loop);
                }
                Injected::Control(name) => {
                    self.with_workspace(|workspace, _| {
                        if name == "dock-bottom" || name == "dock-right" {
                            workspace.toggle_dock(name == "dock-bottom");
                            return;
                        }
                        if name == "close-active" {
                            let index = workspace.active_index();
                            workspace.close_tab(index);
                            return;
                        }
                        // "hover:<control>" only moves the pointer there.
                        if let Some((x, y)) = name.strip_prefix("hover:").and_then(|name| workspace.control_point(name)) {
                            workspace.pointer(x, y);
                            return;
                        }
                        // "right:<control>" is a secondary click.
                        if let Some((x, y)) = name.strip_prefix("right:").and_then(|name| workspace.control_point(name)) {
                            workspace.pointer(x, y);
                            workspace.right_click(x, y);
                        } else if let Some((x, y)) = workspace.control_point(&name) {
                            workspace.pointer(x, y);
                            workspace.click(x, y);
                        } else {
                            eprintln!("no control named {name}");
                        }
                    });
                    if let Some(shared) = &self.shared {
                        shared.invalidate();
                    }
                }
                Injected::ChromeText(text) => {
                    self.with_workspace(|workspace, _| {
                        for character in text.chars() {
                            // "^" stands for Return in a scenario's text.
                            if character == '^' {
                                workspace.key_for_chrome(&winit::keyboard::Key::Named(winit::keyboard::NamedKey::Enter), None);
                                continue;
                            }
                            let piece = character.to_string();
                            workspace.key_for_chrome(&winit::keyboard::Key::Character(piece.as_str().into()), Some(&piece));
                        }
                    });
                    if let Some(shared) = &self.shared {
                        shared.invalidate();
                    }
                }
                Injected::SelectTab { index, sent } => self.select_tab(index, sent),
                Injected::Finished => event_loop.exit(),
            },
            UserEvent::Command(command) => self.menu_command(&command, event_loop),
            UserEvent::SpikeChange => {
                if let Some(shared) = &self.shared {
                    let mut state = shared.state.lock();
                    eprintln!("CHANGE {:.6}", clock::now());
                    if let Some(grid) = state.content.as_any().downcast_mut::<spike::SpikeGrid>() {
                        grid.change();
                    }
                    drop(state);
                    shared.invalidate();
                }
            }
            UserEvent::Quit => {
                if self.spike.is_some() {
                    eprintln!("END {:.6}", clock::now());
                }
                event_loop.exit();
            }
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        let Some(shared) = self.shared.clone() else { return };
        if matches!(event, WindowEvent::KeyboardInput { .. } | WindowEvent::MouseWheel { .. } | WindowEvent::CursorMoved { .. } | WindowEvent::MouseInput { .. } | WindowEvent::ModifiersChanged(_)) {
            shared.note_input();
        }
        match event {
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::Resized(size) => {
                shared.state.lock().size = (size.width, size.height);
                shared.invalidate();
            }
            WindowEvent::ScaleFactorChanged { scale_factor, .. } => {
                shared.state.lock().scale = scale_factor;
                shared.invalidate();
            }
            WindowEvent::Moved(_) => {
                if let Some(window) = &self.window {
                    shared.state.lock().period = display_period(window);
                }
            }
            WindowEvent::Occluded(occluded) => {
                shared.state.lock().visible = !occluded;
                shared.invalidate();
            }
            WindowEvent::Focused(focused) => {
                self.with_workspace(|workspace, _| {
                    workspace.focused = focused;
                    if focused {
                        // Other programs may have changed files while this window was in the background.
                        workspace.refresh_explorer();
                    }
                });
                shared.invalidate();
            }
            WindowEvent::ModifiersChanged(modifiers) => self.modifiers = modifiers.state(),
            WindowEvent::KeyboardInput { event, .. } => {
                if event.state != ElementState::Pressed {
                    return;
                }
                if self.shortcut(&event.logical_key, event_loop) {
                    return;
                }
                if cfg!(target_os = "macos") && self.modifiers.super_key() {
                    return;
                }
                if self.with_workspace(|workspace, _| workspace.dismiss_notice()) == Some(true) {
                    shared.invalidate();
                }
                // A focused text field (the explorer's filter) or an open menu takes the key.
                let key = event.logical_key.clone();
                let text = event.text.as_ref().map(|text| text.to_string());
                if self.with_workspace(|workspace, _| workspace.key_for_chrome(&key, text.as_deref())) == Some(true) {
                    shared.invalidate();
                    return;
                }
                if self.with_workspace(|workspace, _| workspace.keys_go_to_editor()) == Some(true) {
                    if let Some(keys) = input::neovim_keys(&event.logical_key, event.text.as_deref(), self.modifiers) {
                        self.with_workspace(|workspace, _| workspace.editor_input(&keys));
                    }
                    return;
                }
                let application_cursor = self.with_workspace(|workspace, _| workspace.keyboard_terminal().map(|terminal| terminal.mode().contains(alacritty_terminal::term::TermMode::APP_CURSOR))).flatten().unwrap_or(false);
                if let Some(bytes) = input::encode(&event.logical_key, event.text.as_deref(), self.modifiers, application_cursor) {
                    self.write(bytes);
                }
            }
            WindowEvent::MouseWheel { delta, phase, .. } => {
                let native = native_scroll();
                let time = native.map(|native| native.0).unwrap_or_else(clock::now);
                let phase = native.map(|native| native.1).unwrap_or(match phase {
                    TouchPhase::Started => ScrollPhase::Began,
                    TouchPhase::Moved => ScrollPhase::Changed,
                    TouchPhase::Ended | TouchPhase::Cancelled => ScrollPhase::Ended,
                });
                let (delta_x, delta_y) = match delta {
                    MouseScrollDelta::PixelDelta(position) => (position.x, position.y),
                    MouseScrollDelta::LineDelta(x, y) => {
                        // A wheel notch: three lines.
                        let cell = self.with_workspace(|workspace, _| workspace.cell).map(|cell| cell.height as f64).unwrap_or(30.0);
                        (x as f64 * 3.0 * cell, y as f64 * 3.0 * cell)
                    }
                };
                self.scroll(time, delta_x, delta_y, phase);
            }
            WindowEvent::CursorMoved { position, .. } => {
                self.pointer = (position.x as f32, position.y as f32);
                let pointer = self.pointer;
                if self.with_workspace(|workspace, _| workspace.pointer(pointer.0, pointer.1)) == Some(true) {
                    shared.invalidate();
                }
                let resize = self.with_workspace(|workspace, _| if workspace.wants_row_resize_cursor(pointer.0, pointer.1) { 2 } else { workspace.wants_resize_cursor(pointer.0, pointer.1) as u8 }).unwrap_or(0);
                if resize != self.resize_cursor {
                    self.resize_cursor = resize;
                    if let Some(window) = &self.window {
                        window.set_cursor(match resize {
                            2 => winit::window::CursorIcon::RowResize,
                            1 => winit::window::CursorIcon::ColResize,
                            _ => winit::window::CursorIcon::Default,
                        });
                    }
                }
            }
            WindowEvent::CursorLeft { .. } => {
                if self.with_workspace(|workspace, _| workspace.pointer(-1.0, -1.0)) == Some(true) {
                    shared.invalidate();
                }
            }
            WindowEvent::MouseInput { state: ElementState::Pressed, button: MouseButton::Left, .. } => {
                let pointer = self.pointer;
                if self.with_workspace(|workspace, _| workspace.click(pointer.0, pointer.1)) == Some(true) {
                    shared.invalidate();
                }
                // "Choose Folder...": the system's panel, shown without holding the workspace.
                if let Some(for_project) = self.with_workspace(|workspace, _| workspace.take_folder_request()).flatten() {
                    if let Some(folder) = rfd::FileDialog::new().pick_folder() {
                        let folder = neolink_core::paths::canonical(&folder);
                        self.with_workspace(|workspace, _| if for_project { workspace.set_project(folder) } else { workspace.set_launcher_directory(folder) });
                    }
                    shared.invalidate();
                }
            }
            WindowEvent::MouseInput { state: ElementState::Pressed, button: MouseButton::Right, .. } => {
                let pointer = self.pointer;
                if self.with_workspace(|workspace, _| workspace.right_click(pointer.0, pointer.1)) == Some(true) {
                    shared.invalidate();
                }
            }
            WindowEvent::MouseInput { state: ElementState::Released, button: MouseButton::Left, .. } => {
                let pointer = self.pointer;
                self.with_workspace(|workspace, _| workspace.release(pointer.0, pointer.1));
            }
            _ => {}
        }
    }

    fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop) {
        if let Some(shared) = &self.shared {
            shared.publish_main_cpu();
        }
        // At most once a second, and only after something happened (this runs after events).
        if clock::now() - self.settings_checked > 1.0 {
            self.settings_checked = clock::now();
            self.save_settings();
        }
    }

    fn exiting(&mut self, _event_loop: &ActiveEventLoop) {
        self.save_settings();
        if let Some(shared) = &self.shared {
            shared.state.lock().quit = true;
            shared.nudge();
        }
    }
}

fn main() {
    let spike = std::env::args().any(|argument| argument == "--spike").then(|| std::env::var("SPIKE_MODE").unwrap_or_else(|_| "sparse".into()));
    let spike_seconds: f64 = std::env::var("SPIKE_SECONDS").ok().and_then(|s| s.parse().ok()).unwrap_or(8.0);
    if spike.is_some() {
        // The spike logs every frame's journey.
        unsafe { std::env::set_var("NEOLINK_DEBUG_FRAMES", "1") };
    }
    alacritty_terminal::tty::setup_env();
    let event_loop = EventLoop::<UserEvent>::with_user_event().build().expect("an event loop");
    event_loop.set_control_flow(ControlFlow::Wait);
    let mut app = App {
        proxy: event_loop.create_proxy(),
        window: None,
        shared: None,
        modifiers: ModifiersState::empty(),
        pointer: (-1.0, -1.0),
        resize_cursor: 0,
        saved: settings::Settings::default(),
        settings_checked: 0.0,
        bench: Arc::new(BenchState::default()),
        #[cfg(target_os = "macos")]
        menu_bar: None,
        spike,
        spike_seconds,
    };
    event_loop.run_app(&mut app).expect("the event loop");
}
