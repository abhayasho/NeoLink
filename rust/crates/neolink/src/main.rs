mod clock;
mod frame;
mod gpu;
mod present;
mod render;
mod spike;
mod text;

use frame::Shared;
use std::sync::Arc;
use std::time::Duration;
use winit::application::ApplicationHandler;
use winit::dpi::LogicalSize;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy};
use winit::window::{Window, WindowId};

#[derive(Debug, Clone)]
enum UserEvent {
    SpikeChange,
    Quit,
}

struct App {
    proxy: EventLoopProxy<UserEvent>,
    window: Option<Arc<Window>>,
    shared: Option<Arc<Shared>>,
    spike: Option<Arc<parking_lot::Mutex<()>>>,
    mode: String,
    seconds: f64,
}

fn display_period(window: &Window) -> f64 {
    window
        .current_monitor()
        .and_then(|monitor| monitor.refresh_rate_millihertz())
        .filter(|rate| *rate > 1000)
        .map(|rate| 1000.0 / rate as f64)
        .unwrap_or(1.0 / 60.0)
}

impl ApplicationHandler<UserEvent> for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }
        let attributes = Window::default_attributes().with_title("NeoLink").with_inner_size(LogicalSize::new(1200.0, 820.0));
        let window = Arc::new(event_loop.create_window(attributes).expect("a window"));
        let gpu = gpu::Gpu::new().expect("a GPU");
        #[cfg(target_os = "macos")]
        let presenter = present::Presenter::new(&gpu, &window).expect("a presenter");
        #[cfg(not(target_os = "macos"))]
        let presenter = present::Presenter::new(&gpu, window.clone()).expect("a presenter");
        let size = window.inner_size();
        let period = display_period(&window);
        eprintln!("PERIOD {period:.6}");
        let content = Box::new(spike::SpikeGrid::new(self.mode == "motion"));
        let shared = Shared::new(content, (size.width, size.height), window.scale_factor(), period);
        frame::spawn(
            shared.clone(),
            gpu,
            presenter,
            12.0,
            Box::new(|report, target| {
                eprintln!("PRESENTED {:.6} {:.6} {:.6}", report.submitted, report.displayed, target);
            }),
        );
        if std::env::var("NEOLINK_WINDOW").as_deref() == Ok("fullscreen") {
            window.set_fullscreen(Some(winit::window::Fullscreen::Borderless(None)));
        }
        window.focus_window();
        self.window = Some(window);
        self.shared = Some(shared);
        let _ = &self.spike;

        // The spike's change source: a thread that posts to the main thread, as input would arrive.
        let proxy = self.proxy.clone();
        let mode = self.mode.clone();
        let seconds = self.seconds;
        std::thread::spawn(move || {
            let start = clock::now();
            let mut seed: u64 = 0x2545F4914F6CDD1D;
            std::thread::sleep(Duration::from_millis(3000));
            while clock::now() - start < seconds + 3.0 {
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                let wait = match mode.as_str() {
                    "dense" => 33_000 + (seed >> 40) % 700,
                    "sparse" => 90_000 + (seed >> 40) % 160_000,
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

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: UserEvent) {
        match event {
            UserEvent::SpikeChange => {
                if let Some(shared) = &self.shared {
                    let mut state = shared.state.lock();
                    eprintln!("CHANGE {:.6}", clock::now());
                    // The spike's content is always a SpikeGrid.
                    let content: &mut dyn frame::Content = &mut *state.content;
                    let grid = unsafe { &mut *(content as *mut dyn frame::Content as *mut spike::SpikeGrid) };
                    grid.change();
                    state.dirty = true;
                    drop(state);
                    shared.wake.notify_one();
                }
            }
            UserEvent::Quit => {
                eprintln!("END {:.6}", clock::now());
                event_loop.exit();
            }
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        let Some(shared) = &self.shared else { return };
        match event {
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::Resized(size) => {
                let mut state = shared.state.lock();
                state.size = (size.width, size.height);
                state.dirty = true;
                drop(state);
                shared.wake.notify_one();
            }
            WindowEvent::ScaleFactorChanged { scale_factor, .. } => {
                shared.state.lock().scale = scale_factor;
                shared.invalidate();
            }
            WindowEvent::Occluded(occluded) => {
                shared.state.lock().visible = !occluded;
                shared.invalidate();
            }
            _ => {}
        }
    }

    fn exiting(&mut self, _event_loop: &ActiveEventLoop) {
        if let Some(shared) = &self.shared {
            shared.state.lock().quit = true;
            shared.wake.notify_one();
        }
    }
}

fn main() {
    let mode = std::env::var("SPIKE_MODE").unwrap_or_else(|_| "sparse".into());
    let seconds: f64 = std::env::var("SPIKE_SECONDS").ok().and_then(|s| s.parse().ok()).unwrap_or(8.0);
    let event_loop = EventLoop::<UserEvent>::with_user_event().build().expect("an event loop");
    event_loop.set_control_flow(ControlFlow::Wait);
    let mut app = App { proxy: event_loop.create_proxy(), window: None, shared: None, spike: None, mode, seconds };
    event_loop.run_app(&mut app).expect("the event loop");
}
