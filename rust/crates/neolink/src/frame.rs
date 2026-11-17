//! The render thread: sleeps until something changed, then draws one frame per refresh at most.

use crate::clock;
use crate::gpu::Gpu;
use crate::present::{Presented, Presenter, FORMAT};
use crate::render::{Renderer, Scene};
use crate::text::TextSystem;
use neolink_core::pacer::{Pacer, Plan};
use parking_lot::{Condvar, Mutex};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// What the main thread and I/O threads share with the render thread.
pub struct Shared {
    pub state: Mutex<State>,
    pub wake: Condvar,
}

pub struct State {
    /// Drawable size in device pixels.
    pub size: (u32, u32),
    pub scale: f64,
    pub dirty: bool,
    pub quit: bool,
    pub visible: bool,
    /// Refresh interval of the window's display, in seconds.
    pub period: f64,
    pub content: Box<dyn Content>,
}

/// What a frame is drawn from. `snapshot` runs under the state lock and must be quick.
pub trait Content: Send {
    /// Fills `scene` for a frame that will be on the display at `frame_time`. Returns `true` if
    /// another frame is needed after this one (an animation is running).
    fn build(&mut self, scene: &mut Scene, text: &mut TextSystem, queue: &wgpu::Queue, size: (u32, u32), frame_time: f64, period: f64) -> bool;
}

impl Shared {
    pub fn new(content: Box<dyn Content>, size: (u32, u32), scale: f64, period: f64) -> Arc<Shared> {
        Arc::new(Shared {
            state: Mutex::new(State { size, scale, dirty: true, quit: false, visible: true, period, content }),
            wake: Condvar::new(),
        })
    }

    /// Something visible changed: draw a frame.
    pub fn invalidate(&self) {
        self.state.lock().dirty = true;
        self.wake.notify_one();
    }
}

/// Receives every frame's submission and display report (the benchmark and the spike log use this).
pub type PresentedSink = Box<dyn FnMut(&Presented, f64) + Send>;

pub struct FrameStats {
    pub frames: u64,
    pub waits: u64,
}

pub fn spawn(shared: Arc<Shared>, gpu: Gpu, presenter: Presenter, font_points: f32, sink: PresentedSink) -> std::thread::JoinHandle<()> {
    std::thread::Builder::new()
        .name("render".into())
        .spawn(move || run(shared, gpu, presenter, font_points, sink))
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

fn run(shared: Arc<Shared>, gpu: Gpu, mut presenter: Presenter, font_points: f32, mut sink: PresentedSink) {
    raise_priority();
    let (scale, period) = {
        let state = shared.state.lock();
        (state.scale as f32, state.period)
    };
    let mut text = TextSystem::new(&gpu.device, font_points, scale);
    let mut renderer = Renderer::new(&gpu.device, &text, FORMAT);
    let mut scene = Scene::default();
    let margin = std::env::var("NEOLINK_MARGIN_MS").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(1.0) / 1000.0;
    let mut pacer = Pacer::new(period, margin);
    // Target times of frames in flight, by frame id.
    let mut targets: Vec<(u64, f64)> = Vec::new();
    let mut frame_id = 0u64;
    let mut last_size = (0u32, 0u32);
    let exact = presenter.has_exact_timestamps();
    let debug = std::env::var_os("NEOLINK_DEBUG_FRAMES").is_some();
    if debug { eprintln!("DEBUG render thread up, cell {:?}, family {}", text.cell, text.family()); }

    loop {
        // Wait until there is something to draw and a refresh to draw it for.
        let (latch, target, planned_at, size) = {
            let mut state = shared.state.lock();
            loop {
                for report in presenter.take_presented() {
                    let target = targets.iter().position(|t| t.0 == report.frame).map(|i| targets.swap_remove(i).1).unwrap_or(0.0);
                    if exact {
                        pacer.presented(report.submitted, target, report.displayed);
                    }
                    sink(&report, target);
                }
                if state.quit {
                    return;
                }
                pacer.set_period(state.period);
                if !(state.dirty && state.visible) {
                    // Idle: nothing runs until someone invalidates. Wake occasionally only while
                    // display reports are outstanding, to deliver them.
                    if presenter.in_flight() > 0 {
                        shared.wake.wait_for(&mut state, Duration::from_millis(50));
                    } else if !targets.is_empty() {
                        // Every report has been delivered to the presenter; collect the last ones.
                        let reports = presenter.take_presented();
                        if reports.is_empty() {
                            targets.clear();
                        } else {
                            for report in reports {
                                let target = targets.iter().position(|t| t.0 == report.frame).map(|i| targets.swap_remove(i).1).unwrap_or(0.0);
                                if exact {
                                    pacer.presented(report.submitted, target, report.displayed);
                                }
                                sink(&report, target);
                            }
                        }
                    } else {
                        shared.wake.wait(&mut state);
                    }
                    continue;
                }
                let now = clock::now();
                match pacer.plan(now) {
                    Plan::Draw { latch, display } => {
                        state.dirty = false;
                        if state.size != last_size {
                            // A resize (or entering full screen) changes what the system does with a frame.
                            last_size = state.size;
                            pacer.reset();
                        }
                        break (latch, display, now, state.size);
                    }
                    Plan::Wait { until } => {
                        let deadline = Instant::now() + Duration::from_secs_f64((until - now).max(0.0));
                        shared.wake.wait_until(&mut state, deadline);
                    }
                }
            }
        };
        let again = with_pool(|| {
            if debug { eprintln!("DEBUG acquiring {size:?} latch {latch:.4} display {target:.4} depth {} lead {:.2} ms", pacer.depth(), pacer.lead() * 1000.0); }
            let Some(frame) = presenter.acquire(size.0, size.1) else {
                if debug { eprintln!("DEBUG no drawable"); }
                return false;
            };
            if debug { eprintln!("DEBUG acquired {}x{}", frame.width, frame.height); }
            let again = {
                let mut state = shared.state.lock();
                scene.clear();
                let period = state.period;
                state.content.build(&mut scene, &mut text, &gpu.queue, (frame.width, frame.height), target, period)
            };
            let commands = renderer.draw(&gpu.device, &gpu.queue, &frame.view, (frame.width, frame.height), [0.094, 0.094, 0.094], &scene);
            gpu.queue.submit([commands]);
            frame_id += 1;
            targets.push((frame_id, latch));
            presenter.present(frame, frame_id);
            again
        });
        pacer.submitted(planned_at, clock::now(), latch);
        if again {
            shared.state.lock().dirty = true;
        }
    }
}
