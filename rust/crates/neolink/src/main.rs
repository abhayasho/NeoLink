mod bench;
mod capture;
mod clock;
mod frame;
mod gpu;
mod input;
mod present;
mod render;
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

const DEFAULT_FONT_POINTS: f32 = 12.0;

#[derive(Debug, Clone)]
enum UserEvent {
    Injected(Injected),
    SpikeChange,
    Quit,
}

struct App {
    proxy: EventLoopProxy<UserEvent>,
    window: Option<Arc<Window>>,
    shared: Option<Arc<Shared>>,
    modifiers: ModifiersState,
    pointer: (f32, f32),
    bench: Arc<BenchState>,
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
        if self.with_workspace(|workspace, _| workspace.write(bytes)) == Some(true) {
            self.invalidate();
        }
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

    /// Application shortcuts (Command on macOS, Control+Shift elsewhere). Returns `true` if handled.
    fn shortcut(&self, key: &Key, event_loop: &ActiveEventLoop) -> bool {
        let modifiers = self.modifiers;
        let command = if cfg!(target_os = "macos") { modifiers.super_key() } else { modifiers.control_key() && modifiers.shift_key() };
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
        let Key::Character(characters) = key else { return false };
        match characters.to_lowercase().as_str() {
            "t" => self.new_tab(),
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
            "{" | "[" if modifiers.shift_key() => {
                self.with_workspace(|workspace, _| workspace.select_relative(-1));
                self.invalidate();
            }
            "}" | "]" if modifiers.shift_key() => {
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
        let attributes = Window::default_attributes().with_title("NeoLink").with_inner_size(LogicalSize::new(1200.0, 820.0));
        let window = Arc::new(event_loop.create_window(attributes).expect("a window"));
        let gpu = gpu::Gpu::new().expect("a GPU");
        #[cfg(target_os = "macos")]
        let presenter = present::Presenter::new(&gpu, &window).expect("a presenter");
        #[cfg(not(target_os = "macos"))]
        let presenter = present::Presenter::new(&gpu, window.clone()).expect("a presenter");
        let size = window.inner_size();
        let scale = window.scale_factor();
        let period = display_period(&window);
        let text = text::TextSystem::new(&gpu.device, DEFAULT_FONT_POINTS, scale as f32);
        let font_family = text.family().to_string();

        let shared = if let Some(mode) = &self.spike {
            eprintln!("PERIOD {period:.6}");
            Shared::new(Box::new(spike::SpikeGrid::new(mode == "motion")), (size.width, size.height), scale, period)
        } else {
            let mut workspace = Workspace::new(text.cell, DEFAULT_FONT_POINTS, scale as f32, (size.width, size.height), period);
            let proxy = self.proxy.clone();
            workspace.set_on_empty(Box::new(move || {
                let _ = proxy.send_event(UserEvent::Quit);
            }));
            let shared = Shared::new(Box::new(workspace), (size.width, size.height), scale, period);
            {
                let mut state = shared.state.lock();
                if let Some(workspace) = state.content.as_any().downcast_mut::<Workspace>() {
                    if let Err(error) = workspace.new_tab(&shared) {
                        eprintln!("cannot start a shell: {error}");
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
        }
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: UserEvent) {
        if let (Some(shared), UserEvent::Injected(Injected::Text { .. } | Injected::Scroll { .. } | Injected::SelectTab { .. }) | UserEvent::SpikeChange) = (&self.shared, &event) {
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
                Injected::SelectTab { index, sent } => self.select_tab(index, sent),
                Injected::Finished => event_loop.exit(),
            },
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
                self.with_workspace(|workspace, _| workspace.focused = focused);
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
                let application_cursor = self.with_workspace(|workspace, _| workspace.active().map(|terminal| terminal.mode().contains(alacritty_terminal::term::TermMode::APP_CURSOR))).flatten().unwrap_or(false);
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
            }
            _ => {}
        }
    }

    fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop) {
        if let Some(shared) = &self.shared {
            shared.publish_main_cpu();
        }
    }

    fn exiting(&mut self, _event_loop: &ActiveEventLoop) {
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
        bench: Arc::new(BenchState::default()),
        spike,
        spike_seconds,
    };
    event_loop.run_app(&mut app).expect("the event loop");
}
