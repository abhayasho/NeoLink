//! The render thread: sleeps until something changed, then draws one frame per refresh at most.
//!
//! Nothing here runs while the window is unchanged: the thread is parked. Anything that changes what is
//! on screen (input on the main thread, terminal output on a PTY thread) calls [`Shared::invalidate`],
//! which is lock-free, so it can be called while holding other locks.

use crate::clock;
use crate::gpu::Gpu;
use crate::present::{Presenter, FORMAT};
use crate::render::{Renderer, RowCache, Scene};
use crate::text::TextSystem;
use neolink_core::pacer::{Pacer, Plan};
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

/// What the main thread and I/O threads share with the render thread.
pub struct Shared {
    pub state: Mutex<State>,
    dirty: AtomicBool,
    render_thread: OnceLock<std::thread::Thread>,
    /// Every frame's journey, kept only while a benchmark records.
    pub log: FrameLog,
    /// Frames drawn since launch.
    pub frames: AtomicU64,
    pub foreground: AtomicBool,
    pub visibility_epoch: AtomicU64,
    /// Frames among them that only repeated the previous content to keep the display at full rate.
    pub warm_frames: AtomicU64,
    /// Frames that were built and found identical to what is shown, so nothing was presented.
    pub skipped: AtomicU64,
    /// When the user last did something (bits of an `f64` on the app's clock).
    last_input: AtomicU64,
    /// When the last scroll input arrived (see `note_scroll`).
    last_scroll: AtomicU64,
    /// When the last presented frames reached the display (the Performance Monitor's intervals).
    pub displayed: parking_lot::Mutex<std::collections::VecDeque<f64>>,
    /// How long the last frame took to build, in milliseconds (`f64` bits).
    pub build_cost: AtomicU64,
    /// CPU seconds used by the render thread and by the main thread, as last published (`f64` bits).
    render_cpu: AtomicU64,
    main_cpu: AtomicU64,
}

pub struct State {
    /// Drawable size in device pixels.
    pub size: (u32, u32),
    pub scale: f64,
    pub quit: bool,
    pub visible: bool,
    /// Refresh interval of the window's display, in seconds.
    pub period: f64,
    pub content: Box<dyn Content>,
}

/// What a frame is drawn from. `build` runs under the state lock on the render thread.
pub trait Content: Send {
    /// Fills the scene for a frame that will be on the display at `frame.display`; says whether it
    /// differs from the last frame built, and when the content will next change by itself.
    fn build(&mut self, painter: &mut Painter, frame: FrameContext) -> Built;

    /// What the frame just built shows, for the benchmark.
    fn marks(&self) -> FrameMarks {
        FrameMarks::default()
    }

    fn as_any(&mut self) -> &mut dyn std::any::Any;
}

/// What content draws with.
pub struct Painter<'a> {
    pub scene: &'a mut Scene,
    pub text: &'a mut TextSystem,
    pub queue: &'a wgpu::Queue,
    /// Rows of text retained on the GPU between frames.
    pub rows: &'a mut RowCache,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Built {
    /// `false`: every pixel is what the previous frame drew; nothing needs presenting.
    pub changed: bool,
    pub next: Next,
}

/// When content changes without anyone invalidating it (an animation, scroll distance still to show).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Next {
    /// Not until something invalidates it.
    Idle,
    /// In the very next refresh.
    Soon,
    /// In the frame displayed at this time; nothing visible changes before it.
    At(f64),
}

#[derive(Clone, Copy, Debug)]
pub struct FrameContext {
    pub size: (u32, u32),
    pub scale: f32,
    /// When this frame is expected on the display. Sample motion at this time.
    pub display: f64,
    pub period: f64,
}

/// What a frame showed.
#[derive(Clone, Copy, Debug, Default)]
pub struct FrameMarks {
    /// Scroll position of the active pane, in lines above its resting position.
    pub scroll_lines: f64,
    /// Scroll input received by the active pane so far, in lines.
    pub input_lines: f64,
    /// How many batches of output the active pane had parsed when the frame was built.
    pub output: u64,
    /// Selection generation (tab switches) the frame shows.
    pub selection: u64,
    pub instances: usize,
}

#[derive(Clone, Copy, Debug)]
pub struct FrameRecord {
    pub id: u64,
    /// When the decision to draw was made.
    pub planned: f64,
    /// The refresh this frame was committed for, and when it was expected on the display.
    #[allow(dead_code)] // Diagnostics: shown with the record when frames are logged.
    pub latch: f64,
    pub expected: f64,
    pub committed: f64,
    /// When it reached the display (0 until reported, or if it never did).
    pub displayed: f64,
    pub reported: bool,
    pub marks: FrameMarks,
    /// Milliseconds spent building the scene, taking the drawable, encoding and submitting, presenting.
    pub stages: [f32; 4],
}

#[derive(Default)]
pub struct FrameLog {
    recording: AtomicBool,
    records: Mutex<Vec<FrameRecord>>,
}

impl FrameLog {
    pub fn start(&self) {
        self.records.lock().clear();
        self.recording.store(true, Ordering::Release);
    }

    pub fn stop(&self) -> Vec<FrameRecord> {
        self.recording.store(false, Ordering::Release);
        std::mem::take(&mut *self.records.lock())
    }

    fn is_recording(&self) -> bool {
        self.recording.load(Ordering::Acquire)
    }
}

impl Shared {
    pub fn new(content: Box<dyn Content>, size: (u32, u32), scale: f64, period: f64) -> Arc<Shared> {
        Arc::new(Shared {
            state: Mutex::new(State { size, scale, quit: false, visible: true, period, content }),
            dirty: AtomicBool::new(true),
            render_thread: OnceLock::new(),
            log: FrameLog::default(),
            frames: AtomicU64::new(0),
            foreground: AtomicBool::new(false),
            visibility_epoch: AtomicU64::new(0),
            warm_frames: AtomicU64::new(0),
            skipped: AtomicU64::new(0),
            displayed: parking_lot::Mutex::new(std::collections::VecDeque::new()),
            build_cost: AtomicU64::new(0f64.to_bits()),
            last_input: AtomicU64::new(0f64.to_bits()),
            last_scroll: AtomicU64::new(0f64.to_bits()),
            render_cpu: AtomicU64::new(0f64.to_bits()),
            main_cpu: AtomicU64::new(0f64.to_bits()),
        })
    }

    /// The user did something (a key, a scroll, the pointer): for a few seconds from now the display is
    /// kept at its full refresh rate, so the answer to the next input is not held up by a slowed panel.
    pub fn note_input(&self) {
        let now = clock::now();
        let previous = f64::from_bits(self.last_input.swap(now.to_bits(), Ordering::AcqRel));
        // The render thread sleeps without a deadline once the window of an earlier input has passed.
        if now - previous > 0.2 {
            self.nudge();
        }
    }

    /// Scroll input arrived (a gesture or its momentum). Until shortly after the last one, every
    /// refresh is presented, moved or not (see the render loop).
    pub fn note_scroll(&self) {
        self.last_scroll.store(clock::now().to_bits(), Ordering::Release);
        self.invalidate();
    }

    /// Something visible changed: draw a frame. Lock-free; callable from any thread.
    pub fn invalidate(&self) {
        self.dirty.store(true, Ordering::Release);
        if let Some(thread) = self.render_thread.get() {
            thread.unpark();
        }
    }

    pub fn render_cpu(&self) -> f64 {
        f64::from_bits(self.render_cpu.load(Ordering::Relaxed))
    }

    pub fn main_cpu(&self) -> f64 {
        f64::from_bits(self.main_cpu.load(Ordering::Relaxed))
    }

    /// The main thread publishes its CPU time after handling an event (for the benchmark).
    pub fn publish_main_cpu(&self) {
        self.main_cpu.store(clock::thread_cpu_seconds().to_bits(), Ordering::Relaxed);
    }

    /// Wakes the render thread without asking for a frame (to notice `quit` or visibility).
    pub fn nudge(&self) {
        if let Some(thread) = self.render_thread.get() {
            thread.unpark();
        }
    }
}

pub fn spawn(shared: Arc<Shared>, gpu: Gpu, presenter: Presenter, text: TextSystem) -> std::thread::JoinHandle<()> {
    std::thread::Builder::new()
        .name("render".into())
        .spawn(move || {
            let _ = shared.render_thread.set(std::thread::current());
            run(shared, gpu, presenter, text)
        })
        .expect("render thread")
}

#[cfg(target_os = "macos")]
fn raise_priority() {
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
    }
}

#[cfg(not(target_os = "macos"))]
fn raise_priority() {}

#[cfg(target_os = "macos")]
fn with_pool<R>(body: impl FnOnce() -> R) -> R {
    objc2::rc::autoreleasepool(|_| body())
}

#[cfg(not(target_os = "macos"))]
fn with_pool<R>(body: impl FnOnce() -> R) -> R {
    body()
}

fn run(shared: Arc<Shared>, gpu: Gpu, mut presenter: Presenter, mut text: TextSystem) {
    raise_priority();
    let period = shared.state.lock().period;
    let mut renderer = Renderer::new(&gpu.device, &text, FORMAT);
    let mut scene = Scene::default();
    let margin = std::env::var("NEOLINK_MARGIN_MS").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(1.0) / 1000.0;
    let mut pacer = Pacer::new(period, margin);
    // Latches of frames whose display time has not been reported yet, by frame id.
    let mut latches: Vec<(u64, f64)> = Vec::new();
    let mut frame_id = 0u64;
    let mut last_size = (0u32, 0u32);
    let exact = presenter.has_exact_timestamps();
    let debug = std::env::var_os("NEOLINK_DEBUG_FRAMES").is_some();
    let background = crate::theme::background_clear();
    let env_number = |name: &str, default: f64| std::env::var(name).ok().and_then(|value| value.parse::<f64>().ok()).unwrap_or(default);
    let warm_interval = env_number("NEOLINK_WARM_MS", 250.0) / 1000.0;
    let warm_seconds = env_number("NEOLINK_WARM_SECONDS", 3.0);
    // While a scroll is live, and this long after its last input, every refresh is presented (the
    // last frame repeats when the content moved less than a pixel). A ProMotion display follows the
    // app's frame rate: frames presented only when the text moved a whole pixel came 8-90 ms apart in
    // a slow scroll, the panel changed its refresh rate every few frames, and dark backgrounds pulsed
    // in brightness. A steady rate during the gesture changes it once, at the end.
    let steady_scroll = env_number("NEOLINK_STEADY_SCROLL_MS", 250.0) / 1000.0;
    let mut last_frame_at = 0.0f64;
    // Display time of a frame the content asked for.
    let mut scheduled: Option<f64> = None;
    // `NEOLINK_CAPTURE=file.png`: write the first frame built after `NEOLINK_CAPTURE_AFTER` seconds
    // (default 4) as an image, and quit.
    // `NEOLINK_RECORD=folder`: every frame whose content changed is also written there as a PNG
    // (frame-0001.png, ...), from `NEOLINK_RECORD_FROM` seconds after launch, at most
    // `NEOLINK_RECORD_COUNT` of them. For finding frames that should not have been shown (flicker);
    // writing them slows the frame loop, so timing measured meanwhile means nothing.
    let record = std::env::var_os("NEOLINK_RECORD").map(std::path::PathBuf::from);
    let record_from = env_number("NEOLINK_RECORD_FROM", 0.0);
    let record_count = env_number("NEOLINK_RECORD_COUNT", 400.0) as u32;
    let mut recorded = 0u32;
    // `NEOLINK_RECORD_FAST=1`: append raw gray frames to one file instead of writing PNGs.
    let record_fast = std::env::var("NEOLINK_RECORD_FAST").as_deref() == Ok("1");
    let capture = std::env::var_os("NEOLINK_CAPTURE").map(|path| (std::path::PathBuf::from(path), env_number("NEOLINK_CAPTURE_AFTER", 4.0)));
    let started_at = clock::now();
    let mut force_present = true;
    let mut presented_size = (0u32, 0u32);

    loop {
        // For the benchmark and the Performance Monitor.
        shared.render_cpu.store(clock::thread_cpu_seconds().to_bits(), Ordering::Relaxed);
        for report in presenter.take_presented() {
            {
                let mut displayed = shared.displayed.lock();
                if displayed.len() >= 240 {
                    displayed.pop_front();
                }
                displayed.push_back(report.displayed);
            }
            let latch = latches.iter().position(|entry| entry.0 == report.frame).map(|i| latches.swap_remove(i).1).unwrap_or(0.0);
            if exact {
                pacer.presented(report.submitted, latch, report.displayed);
            }
            if shared.log.is_recording() {
                if let Some(record) = shared.log.records.lock().iter_mut().rev().find(|record| record.id == report.frame) {
                    record.displayed = report.displayed;
                    record.reported = true;
                }
            }
            if debug {
                eprintln!("PRESENTED {:.6} {:.6} {:.6}", report.submitted, report.displayed, latch);
            }
        }
        let (visible, size, scale) = {
            let state = shared.state.lock();
            if state.quit {
                return;
            }
            pacer.set_period(state.period);
            (state.visible, state.size, state.scale as f32)
        };
        if let Some(at) = scheduled {
            // A frame the content asked for: start it just after the latch before its own, so it is
            // displayed when the content said it changes.
            let start = at - (pacer.depth() as f64 + 1.0) * pacer.period() + 0.0005;
            if clock::now() >= start {
                scheduled = None;
                shared.dirty.store(true, Ordering::Release);
            }
        }
        if capture.as_ref().is_some_and(|(_, after)| clock::now() - started_at >= *after) {
            // The capture wants a frame even if nothing changed.
            shared.dirty.store(true, Ordering::Release);
        }
        let mut warming = false;
        let scrolling = visible && steady_scroll > 0.0 && clock::now() - f64::from_bits(shared.last_scroll.load(Ordering::Acquire)) < steady_scroll;
        if !(shared.dirty.load(Ordering::Acquire) && visible) && !scrolling {
            // Idle. A display that is given no frames lowers its refresh rate within a second, and the
            // next frame then waits for a slow refresh (measured in full screen: 6 ms after a 0.2-0.4 s
            // pause, 13 ms after 1 s, about 50 ms after several). While the user is active, repeat the
            // last frame a few times a second; after `warm_seconds` without input nothing runs at all.
            let now = clock::now();
            let since_input = now - f64::from_bits(shared.last_input.load(Ordering::Acquire));
            let warm = visible && warm_interval > 0.0 && since_input < warm_seconds;
            if warm && now - last_frame_at >= warm_interval {
                warming = true;
            } else {
                if let Some(at) = scheduled {
                    let start = at - (pacer.depth() as f64 + 1.0) * pacer.period() + 0.0005;
                    std::thread::park_timeout(Duration::from_secs_f64((start - now).clamp(0.0002, 0.25)));
                } else if capture.is_some() {
                    std::thread::park_timeout(Duration::from_millis(100));
                } else if warm {
                    std::thread::park_timeout(Duration::from_secs_f64((last_frame_at + warm_interval - now).clamp(0.001, warm_interval)));
                } else if presenter.in_flight() > 0 {
                    // Display reports are outstanding (only the benchmark and the pacer want them).
                    std::thread::park_timeout(Duration::from_millis(50));
                } else {
                    latches.clear();
                    std::thread::park();
                }
                continue;
            }
        }
        let now = clock::now();
        let (latch, display) = match pacer.plan(now) {
            Plan::Draw { latch, display } => (latch, display),
            Plan::Wait { until } => {
                std::thread::park_timeout(Duration::from_secs_f64((until - now).max(0.0)));
                continue;
            }
        };
        if size != last_size {
            // A resize (or entering full screen) changes what the system does with a frame.
            last_size = size;
            pacer.reset();
        }
        if !warming {
            shared.dirty.store(false, Ordering::Release);
        }
        // Build first: most invalidations change nothing that is on screen (output in a covered pane,
        // scroll distance smaller than a pixel), and those frames are not presented at all.
        let mut marks = None;
        let mut stages = [0f32; 4];
        let build_started = clock::now();
        let built = {
            let mut state = shared.state.lock();
            scene.clear();
            renderer.begin_frame();
            let period = state.period;
            let context = FrameContext { size, scale, display, period };
            let mut painter = Painter { scene: &mut scene, text: &mut text, queue: &gpu.queue, rows: &mut renderer.rows };
            let built = state.content.build(&mut painter, context);
            if shared.log.is_recording() {
                let mut shown = state.content.marks();
                shown.instances = scene.drawn;
                marks = Some(shown);
            }
            built
        };
        let again = built.next;
        stages[0] = ((clock::now() - build_started) * 1000.0) as f32;
        shared.build_cost.store((stages[0] as f64).to_bits(), Ordering::Relaxed);
        if let Some(folder) = &record {
            if built.changed && recorded < record_count && clock::now() - started_at >= record_from {
                recorded += 1;
                if record_fast {
                    // Half width, gray, appended raw (no image encoding): fast enough to keep the
                    // frame rate, so the sequence is what the screen showed.
                    if let Ok((width, height, pixels)) = crate::capture::read_pixels(&gpu, &mut renderer, &scene, size, background) {
                        // Every row (motion is measured in whole device pixels), every other column.
                        let (half_width, half_height) = (width / 2, height);
                        let mut gray = Vec::with_capacity((half_width * half_height) as usize);
                        for y in 0..half_height as usize {
                            let row = y * width as usize * 4;
                            for x in 0..half_width as usize {
                                let i = row + x * 2 * 4;
                                gray.push(((pixels[i] as u16 + pixels[i + 1] as u16 + pixels[i + 2] as u16) / 3) as u8);
                            }
                        }
                        append_fast_frame(folder, half_width, half_height, display, &gray);
                    }
                } else {
                    let path = folder.join(format!("frame-{recorded:04}.png"));
                    if let Err(error) = crate::capture::write_png(&gpu, &mut renderer, &scene, size, background, &path) {
                        eprintln!("record failed: {error}");
                    }
                }
            }
        }
        if let Some((path, after)) = &capture {
            if clock::now() - started_at >= *after {
                match crate::capture::write_png(&gpu, &mut renderer, &scene, size, background, path) {
                    Ok(()) => eprintln!("captured {}x{} to {}", size.0, size.1, path.display()),
                    Err(error) => eprintln!("capture failed: {error}"),
                }
                std::process::exit(0);
            }
        }
        if built.changed || warming || scrolling || force_present || size != presented_size {
            let committed = with_pool(|| {
                let started = clock::now();
                let frame = presenter.acquire(size.0, size.1)?;
                let acquired = clock::now();
                let mut encoder = renderer.draw(&gpu.device, &gpu.queue, &frame.view, (frame.width, frame.height), background, &scene);
                frame_id += 1;
                presenter.schedule(&mut encoder, &frame, frame_id);
                gpu.queue.submit([encoder.finish()]);
                let submitted = clock::now();
                latches.push((frame_id, latch));
                presenter.present(frame, frame_id);
                let done = clock::now();
                stages[1] = ((acquired - started) * 1000.0) as f32;
                stages[2] = ((submitted - acquired) * 1000.0) as f32;
                stages[3] = ((done - submitted) * 1000.0) as f32;
                Some(done)
            });
            let Some(committed) = committed else {
                // No drawable (the display is asleep or the window is hidden): try again later.
                force_present = true;
                shared.dirty.store(true, Ordering::Release);
                std::thread::park_timeout(Duration::from_millis(100));
                continue;
            };
            force_present = false;
            presented_size = size;
            pacer.submitted(now, committed, latch);
            last_frame_at = committed;
            shared.frames.fetch_add(1, Ordering::Relaxed);
            if warming || (scrolling && !built.changed) {
                shared.warm_frames.fetch_add(1, Ordering::Relaxed);
            }
            if let Some(marks) = marks {
                shared.log.records.lock().push(FrameRecord {
                    id: frame_id,
                    planned: now,
                    latch,
                    expected: display,
                    committed,
                    displayed: 0.0,
                    reported: false,
                    marks,
                    stages,
                });
            }
        } else {
            shared.skipped.fetch_add(1, Ordering::Relaxed);
        }
        match again {
            Next::Idle => {}
            Next::Soon => shared.dirty.store(true, Ordering::Release),
            // A change already due by this frame's display time is drawn at the next refresh, not
            // rebuilt again and again before it.
            Next::At(at) if at <= display => shared.dirty.store(true, Ordering::Release),
            Next::At(at) => scheduled = Some(scheduled.map_or(at, |earlier: f64| earlier.min(at))),
        }
    }
}

/// Appends a frame recorded by `NEOLINK_RECORD_FAST` to `frames.raw`: a header line
/// `width height display-time`, then `width * height` gray bytes.
fn append_fast_frame(folder: &std::path::Path, width: u32, height: u32, display: f64, gray: &[u8]) {
    use std::io::Write;
    let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(folder.join("frames.raw")) else { return };
    let _ = writeln!(file, "{width} {height} {display:.6}");
    let _ = file.write_all(gray);
}
