//! The in-app interaction benchmark (`NEOLINK_BENCHMARK=scenario,scenario,...`).
//!
//! Scenario names, input profiles and scroll analysis are those of the Swift app's
//! `Sources/Rendering/InteractionBenchmark.swift`, so the two reports can be read side by side.
//!
//! Input is synthetic, and says so in the report: events are created on a timer thread with the time they
//! were "sampled", and posted to the main thread, where they take the same path as real input from the
//! point winit would have delivered them. The operating system's own delivery and a physical trackpad or
//! keyboard are not part of what is measured. `NEOLINK_BENCHMARK_BUSY=1` keeps the main thread busy
//! during scroll scenarios (a block every 9.1 ms holding it for 0.3-3.5 ms), as layout and I/O do in use.

use crate::clock;
use crate::frame::{FrameRecord, Shared};
use crate::term::ScrollPhase;
use crate::workspace::Workspace;
use neolink_core::analysis::ScrollAnalysis;
use neolink_core::profile::{GesturePhase, MomentumPhase, Playback, ScrollProfile};
use neolink_core::stats::{percentile, round_to, Summary};
use parking_lot::Mutex;
use serde_json::{json, Map, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// Something the benchmark asks the main thread to do.
#[derive(Debug, Clone)]
pub enum Injected {
    /// Bytes typed into the active pane; `sent` is when the key was "pressed".
    Text { bytes: Vec<u8>, sent: f64, measure: bool },
    /// A trackpad report in points, sampled at `time`.
    Scroll { time: f64, delta_x: f64, delta_y: f64, phase: ScrollPhase },
    /// Hold the main thread for this many seconds.
    Busy(f64),
    NewTab,
    SelectTab { index: usize, sent: f64 },
    /// Open (or select) a file in the editor.
    OpenDocument { path: String, sent: f64 },
    /// Keys for the editor in Neovim's notation.
    Keys(String),
    Finished,
}

#[derive(Clone, Copy, Debug)]
pub struct KeyRecord {
    pub sent: f64,
    /// When the main thread handled it.
    pub handled: f64,
    /// Output batches the pane had parsed at that moment.
    pub output_before: u64,
}

#[derive(Default)]
pub struct BenchState {
    pub keys: Mutex<Vec<KeyRecord>>,
    /// `(when the selection changed on the main thread, selection generation)`.
    pub selections: Mutex<Vec<(f64, f64, u64)>>,
}

pub type Post = Box<dyn Fn(Injected) + Send + Sync>;

fn with_workspace<R>(shared: &Shared, body: impl FnOnce(&mut Workspace) -> R) -> Option<R> {
    let mut state = shared.state.lock();
    state.content.as_any().downcast_mut::<Workspace>().map(body)
}

/// Seconds of system (kernel) CPU this process has used.
fn system_cpu_seconds() -> f64 {
    #[cfg(unix)]
    {
        let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
        if unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) } == 0 {
            let usage = unsafe { usage.assume_init() };
            return usage.ru_stime.tv_sec as f64 + usage.ru_stime.tv_usec as f64 / 1e6;
        }
    }
    0.0
}

/// Seconds of CPU this process has used (user + system), where the system can tell.
fn cpu_seconds() -> Option<f64> {
    #[cfg(unix)]
    {
        let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
        if unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) } != 0 {
            return None;
        }
        let usage = unsafe { usage.assume_init() };
        let seconds = |time: libc::timeval| time.tv_sec as f64 + time.tv_usec as f64 / 1e6;
        Some(seconds(usage.ru_utime) + seconds(usage.ru_stime))
    }
    #[cfg(not(unix))]
    {
        None
    }
}

use crate::clock::thread_cpu_seconds;

/// Sleeps to an absolute time on the benchmark's clock, spinning the last fraction of a millisecond so
/// that events are stamped and posted when the profile says.
fn wait_until(deadline: f64) {
    loop {
        let remaining = deadline - clock::now();
        if remaining <= 0.0 {
            return;
        }
        if remaining > 0.0015 {
            std::thread::sleep(Duration::from_secs_f64(remaining - 0.0012));
        } else {
            std::hint::spin_loop();
        }
    }
}

fn sleep(seconds: f64) {
    std::thread::sleep(Duration::from_secs_f64(seconds));
}

struct Runner {
    shared: Arc<Shared>,
    state: Arc<BenchState>,
    post: Post,
    busy: bool,
    period: f64,
    /// CPU seconds the benchmark's helper threads used (the timer that spins to post input on time).
    helper_cpu: Mutex<f64>,
}

struct Measurement {
    frames: Vec<FrameRecord>,
    seconds: f64,
    cpu: Option<f64>,
    /// CPU of the benchmark's own timer threads, as a percentage of one core.
    timers: f64,
    system_cpu: f64,
    render_cpu: f64,
    main_cpu: f64,
    frames_drawn: u64,
    warm_frames: u64,
}

impl Runner {
    fn type_text(&self, text: &str, interval: f64) {
        let mut next = clock::now();
        for character in text.chars() {
            wait_until(next);
            let mut buffer = [0u8; 4];
            (self.post)(Injected::Text { bytes: character.encode_utf8(&mut buffer).as_bytes().to_vec(), sent: clock::now(), measure: false });
            next += interval;
        }
    }

    fn measure(&self, body: impl FnOnce()) -> Measurement {
        self.state.keys.lock().clear();
        self.state.selections.lock().clear();
        let drawn_before = self.shared.frames.load(Ordering::Relaxed);
        let warm_before = self.shared.warm_frames.load(Ordering::Relaxed);
        self.shared.log.start();
        *self.helper_cpu.lock() = 0.0;
        let render_before = self.shared.render_cpu();
        let main_before = self.shared.main_cpu();
        let own_before = thread_cpu_seconds();
        let system_before = system_cpu_seconds();
        let cpu_before = cpu_seconds();
        let started = clock::now();
        body();
        let seconds = clock::now() - started;
        let cpu = match (cpu_before, cpu_seconds()) {
            (Some(before), Some(after)) => Some((after - before) / seconds * 100.0),
            _ => None,
        };
        let timers = (thread_cpu_seconds() - own_before + *self.helper_cpu.lock()) / seconds * 100.0;
        let system_cpu = (system_cpu_seconds() - system_before) / seconds * 100.0;
        let render_cpu = (self.shared.render_cpu() - render_before) / seconds * 100.0;
        let main_cpu = (self.shared.main_cpu() - main_before) / seconds * 100.0;
        // Let the last frames report when they were displayed.
        sleep(0.4);
        let frames = self.shared.log.stop();
        let frames_drawn = self.shared.frames.load(Ordering::Relaxed) - drawn_before;
        let warm_frames = self.shared.warm_frames.load(Ordering::Relaxed) - warm_before;
        Measurement { frames, seconds, cpu, timers, system_cpu, render_cpu, main_cpu, frames_drawn, warm_frames }
    }

    /// Frame statistics common to every scenario.
    fn frame_report(&self, measurement: &Measurement) -> Map<String, Value> {
        let frames = &measurement.frames;
        let shown: Vec<&FrameRecord> = frames.iter().filter(|frame| frame.displayed > 0.0).collect();
        let mut times: Vec<f64> = shown.iter().map(|frame| frame.displayed).collect();
        times.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let intervals: Vec<f64> = times.windows(2).map(|pair| (pair[1] - pair[0]) * 1000.0).collect();
        let commit_to_display: Vec<f64> = shown.iter().map(|frame| (frame.displayed - frame.committed) * 1000.0).collect();
        let cost: Vec<f64> = frames.iter().map(|frame| (frame.committed - frame.planned) * 1000.0).collect();
        let late = shown.iter().filter(|frame| frame.displayed - frame.expected > 0.5 * self.period).count();
        let mut report = Map::new();
        report.insert("seconds".into(), json!(round_to(measurement.seconds, 2)));
        report.insert("framesDrawn".into(), json!(measurement.frames_drawn));
        report.insert("framesRepeatedToKeepDisplayFast".into(), json!(measurement.warm_frames));
        report.insert("framesDisplayed".into(), json!(shown.len()));
        report.insert("framesNeverDisplayed".into(), json!(frames.iter().filter(|frame| frame.reported && frame.displayed <= 0.0).count()));
        report.insert("framesUnreported".into(), json!(frames.iter().filter(|frame| !frame.reported).count()));
        report.insert("framesLaterThanPlanned".into(), json!(late));
        report.insert("displayIntervalMs".into(), summary(&intervals));
        report.insert("commitToDisplayMs".into(), summary(&commit_to_display));
        // Which way frames reached the display: scanned out directly (a commit shows at the next
        // refresh it is in time for) or through the compositor (two refreshes later). The system
        // decides; the numbers of a run mean little without knowing which it was.
        if !commit_to_display.is_empty() {
            let median = percentile(&commit_to_display, 0.5) / (self.period * 1000.0);
            report.insert("displayPath".into(), json!(if median < 1.4 { "direct" } else { "composited" }));
            report.insert("commitToDisplayRefreshesP50".into(), json!(round_to(median, 2)));
        }
        report.insert("drawCostMs".into(), summary(&cost));
        let stage = |index: usize| round_to(percentile(&frames.iter().map(|frame| frame.stages[index] as f64).collect::<Vec<_>>(), 0.5), 3);
        report.insert("stageMsP50".into(), json!({"build": stage(0), "acquireDrawable": stage(1), "encodeAndSubmit": stage(2), "present": stage(3)}));
        if let Some(cpu) = measurement.cpu {
            // The whole process, like the Swift app's figure; then without the threads that exist only
            // to post synthetic input on time (they spin; a device does not cost the app that).
            report.insert("cpuPercentOfOneCore".into(), json!(round_to(cpu, 1)));
            report.insert("cpuPercentWithoutBenchmarkTimers".into(), json!(round_to((cpu - measurement.timers).max(0.0), 1)));
            report.insert("cpuPercentInKernel".into(), json!(round_to(measurement.system_cpu, 1)));
            report.insert("cpuPercentRenderThread".into(), json!(round_to(measurement.render_cpu, 1)));
            report.insert("cpuPercentMainThread".into(), json!(round_to(measurement.main_cpu, 1)));
        }
        report
    }

    fn idle(&self) -> Value {
        sleep(1.5);
        let measurement = self.measure(|| sleep(5.0));
        Value::Object(self.frame_report(&measurement))
    }

    /// Types `count` characters `interval` apart and reports when each echo reached the display.
    fn typing(&self, count: usize, interval: f64) -> Value {
        let measurement = self.measure(|| {
            let mut next = clock::now();
            for index in 0..count {
                wait_until(next);
                let character = (b'a' + (index % 26) as u8) as char;
                (self.post)(Injected::Text { bytes: vec![character as u8], sent: clock::now(), measure: true });
                next += interval;
            }
            sleep(0.3);
        });
        let keys = self.state.keys.lock().clone();
        let mut frames = measurement.frames.clone();
        frames.sort_by(|a, b| a.planned.partial_cmp(&b.planned).unwrap());
        let (mut latency, mut delivery, mut echo, mut display) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
        let mut unanswered = 0;
        for key in &keys {
            // The first frame, drawn after the key was handled, that shows output the pane did not have
            // when the key was pressed.
            let frame = frames.iter().find(|frame| frame.planned >= key.handled && frame.marks.output > key.output_before && frame.displayed > 0.0);
            match frame {
                Some(frame) => {
                    latency.push((frame.displayed - key.sent) * 1000.0);
                    delivery.push((key.handled - key.sent) * 1000.0);
                    echo.push((frame.planned - key.handled) * 1000.0);
                    display.push((frame.displayed - frame.planned) * 1000.0);
                }
                None => unanswered += 1,
            }
        }
        let mut report = self.frame_report(&measurement);
        report.insert("keys".into(), json!(keys.len()));
        report.insert("keysWithoutDisplayedEcho".into(), json!(unanswered));
        report.insert("keyToDisplayMs".into(), summary(&latency));
        report.insert("stages".into(), json!({
            "keyToMainThreadMs": summary(&delivery),
            "mainThreadToFrameStartMs": summary(&echo),
            "frameStartToDisplayMs": summary(&display),
        }));
        // Clear the typed line.
        (self.post)(Injected::Text { bytes: vec![0x15], sent: clock::now(), measure: false });
        sleep(0.2);
        Value::Object(report)
    }

    /// Plays a scroll profile over the active pane and analyses every displayed frame.
    fn scroll(&self, profile: &ScrollProfile) -> Value {
        let Some((origin, cell_height, scale)) = with_workspace(&self.shared, |workspace| (workspace.scroll_lines(), workspace.cell.height as f64, workspace.scale() as f64)) else {
            return json!({"error": "no workspace"});
        };
        let cell_points = cell_height / scale;
        let smoothing_before = with_workspace(&self.shared, |workspace| workspace.smoothing_report()).unwrap_or((0, 0, 0.0));
        let timeline: Arc<Mutex<Vec<(f64, f64)>>> = Arc::new(Mutex::new(Vec::new()));
        let stop_busy = Arc::new(AtomicBool::new(false));
        let lateness: Arc<Mutex<Vec<f64>>> = Arc::new(Mutex::new(Vec::new()));
        let measurement = self.measure(|| {
            std::thread::scope(|scope| {
                if self.busy {
                    let stop = stop_busy.clone();
                    let post = &self.post;
                    let helper_cpu = &self.helper_cpu;
                    scope.spawn(move || {
                        let mut seed: u64 = 0x9E3779B97F4A7C15;
                        let mut next = clock::now();
                        while !stop.load(Ordering::Acquire) {
                            wait_until(next);
                            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                            let hold = 0.0003 + 0.0032 * (seed >> 40) as f64 / (1u64 << 24) as f64;
                            post(Injected::Busy(hold));
                            next += 0.0091;
                        }
                        *helper_cpu.lock() += thread_cpu_seconds();
                    });
                }
                let mut next = clock::now();
                for tick in Playback::new(profile) {
                    wait_until(next);
                    let sampled = clock::now();
                    lateness.lock().push((sampled - next) * 1000.0);
                    timeline.lock().push((sampled, tick.ideal_points / cell_points));
                    if let Some(report) = tick.report {
                        let phase = match (report.momentum, report.phase) {
                            (MomentumPhase::Ended, _) => ScrollPhase::MomentumEnded,
                            (MomentumPhase::Began | MomentumPhase::Changed, _) => ScrollPhase::Momentum,
                            (_, GesturePhase::Began) => ScrollPhase::Began,
                            (_, GesturePhase::Ended) => ScrollPhase::Ended,
                            _ => ScrollPhase::Changed,
                        };
                        (self.post)(Injected::Scroll { time: sampled, delta_x: report.delta_x, delta_y: report.delta, phase });
                    }
                    next += profile.interval;
                }
                stop_busy.store(true, Ordering::Release);
            });
            sleep(0.4);
        });
        let timeline = timeline.lock().clone();
        let mut frames: Vec<(f64, f64)> = measurement.frames.iter().filter(|frame| frame.displayed > 0.0).map(|frame| (frame.displayed, frame.marks.scroll_lines - origin.0)).collect();
        frames.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
        let analysis = ScrollAnalysis { timeline: &timeline, frames: &frames, rate: 1.0 / self.period, cell_pixels: cell_height }.report();
        let received = with_workspace(&self.shared, |workspace| workspace.scroll_lines().1).unwrap_or(0.0) - origin.1;
        let smoothing = with_workspace(&self.shared, |workspace| workspace.smoothing_report()).unwrap_or((0, 0, 0.0));
        let start = timeline.first().map(|sample| sample.0).unwrap_or(0.0);
        let samples: Vec<Value> = measurement
            .frames
            .iter()
            .filter(|frame| frame.displayed > 0.0)
            .map(|frame| json!([round_to((frame.displayed - start) * 1000.0, 2), round_to(frame.marks.input_lines - origin.1, 3), round_to(frame.marks.scroll_lines - origin.0, 3), round_to((frame.planned - start) * 1000.0, 2)]))
            .collect();
        let mut report = self.frame_report(&measurement);
        if std::env::var_os("NEOLINK_BENCHMARK_SAMPLES").is_some() {
            // Per frame: displayed (ms from the first event), input received (lines), drawn (lines), frame start (ms).
            report.insert("samples".into(), Value::Array(samples));
            report.insert("timeline".into(), Value::Array(timeline.iter().map(|sample| json!([round_to((sample.0 - start) * 1000.0, 2), round_to(sample.1, 3)])).collect()));
        }
        report.insert("scroll".into(), json!({
            "frames": analysis.frames,
            "lagMs": analysis.lag_ms,
            "firstMotionMs": analysis.first_motion_ms,
            "jerkPixelsP50": analysis.jerk_pixels_p50,
            "jerkPixelsP95": analysis.jerk_pixels_p95,
            "jerkPixelsMax": analysis.jerk_pixels_max,
            "unevenFrames": analysis.uneven_frames,
            "stepErrorPixelsP95": analysis.step_error_pixels_p95,
            "stallFrames": analysis.stall_frames,
            "jumpFrames": analysis.jump_frames,
            "missedRefreshesWhileMoving": analysis.missed_refreshes_while_moving,
            "largestStepPixels": analysis.largest_step_pixels,
            "burstFrames": analysis.burst_frames,
            "pixelSteps": analysis.pixel_steps,
            "stepGapSpread": analysis.step_gap_spread,
            "stepGapMeanMs": analysis.step_gap_mean_ms,
            "aheadLinesMax": analysis.ahead_lines_max,
            "backwardFrames": analysis.backward_frames,
            "backwardLinesMax": analysis.backward_lines_max,
            "trailingLinesP50": analysis.trailing_lines_p50,
            "trailingLinesP95": analysis.trailing_lines_p95,
            "positionErrorLinesP95": analysis.position_error_lines_p95,
            "velocityErrorP95": analysis.velocity_error_p95,
            "settleMs": analysis.settle_ms,
            "settleLines": analysis.settle_lines,
            "idealLines": analysis.ideal_lines,
            "drawnLines": analysis.drawn_lines,
            "receivedLines": round_to(received, 3),
            "inputEvents": smoothing.1 - smoothing_before.1,
            "eventsSpread": smoothing.0 - smoothing_before.0,
            "longestSmoothingDelayMs": round_to(smoothing.2, 2),
        }));
        // How late each synthetic report left the timer thread (a device's reports are not late).
        report.insert("inputLatenessMs".into(), summary(&lateness.lock()));
        Value::Object(report)
    }

    /// Terminal scenarios run in the first tab (the shell), whatever an earlier scenario left selected.
    fn select_shell(&self) {
        (self.post)(Injected::SelectTab { index: 0, sent: clock::now() });
        sleep(0.3);
    }

    /// Fills the scrollback so there is something to scroll through.
    fn fill_scrollback(&self) {
        self.type_text("clear; seq 1 6000\r", 0.01);
        sleep(1.5);
    }

    /// Switches between two tabs and reports when the other pane reached the display.
    fn tabs(&self) -> Value {
        (self.post)(Injected::NewTab);
        sleep(1.0);
        self.type_text("clear; seq 1 200\r", 0.01);
        sleep(0.8);
        let measurement = self.measure(|| {
            let mut next = clock::now();
            for index in 0..24 {
                wait_until(next);
                (self.post)(Injected::SelectTab { index: index % 2, sent: clock::now() });
                next += 0.25;
            }
            sleep(0.3);
        });
        let selections = self.state.selections.lock().clone();
        let mut frames = measurement.frames.clone();
        frames.sort_by(|a, b| a.planned.partial_cmp(&b.planned).unwrap());
        let mut latency = Vec::new();
        let mut missing = 0;
        for (sent, _handled, generation) in &selections {
            match frames.iter().find(|frame| frame.marks.selection >= *generation && frame.displayed > 0.0) {
                Some(frame) => latency.push((frame.displayed - sent) * 1000.0),
                None => missing += 1,
            }
        }
        let mut report = self.frame_report(&measurement);
        report.insert("switches".into(), json!(selections.len()));
        report.insert("switchesWithoutDisplayedFrame".into(), json!(missing));
        report.insert("switchToDisplayMs".into(), summary(&latency));
        Value::Object(report)
    }

    /// A scratch copy of a source file to edit (`NEOLINK_BENCHMARK_FILE`, default a file of the Swift app).
    fn scratch_copy(&self, name: &str) -> Option<String> {
        let source = std::env::var_os("NEOLINK_BENCHMARK_FILE").map(std::path::PathBuf::from).or_else(|| {
            let mut directory = std::env::current_exe().ok()?;
            for _ in 0..8 {
                directory = directory.parent()?.to_path_buf();
                let candidate = directory.join("Sources/Documents/WorkspaceDocument.swift");
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
            None
        })?;
        let directory = std::env::temp_dir().join(format!("neolink-bench-{}", std::process::id()));
        std::fs::create_dir_all(&directory).ok()?;
        let target = directory.join(name);
        std::fs::copy(&source, &target).ok()?;
        neolink_core::paths::canonical(&target).to_str().map(str::to_string)
    }

    /// Waits until the frame log's newest frame shows selection `generation` (the document is on screen).
    fn wait_for_selection(&self, seconds: f64) {
        let deadline = clock::now() + seconds;
        while clock::now() < deadline {
            let shown = with_workspace(&self.shared, |workspace| !workspace.active_is_document() || workspace.shows_active());
            if shown == Some(true) {
                return;
            }
            sleep(0.01);
        }
    }

    /// Typing in the editor: 75 keys in insert mode at 25 a second.
    fn editor_typing(&self) -> Value {
        let Some(path) = self.scratch_copy("typing.swift") else { return json!({"error": "no file to edit"}) };
        (self.post)(Injected::OpenDocument { path, sent: clock::now() });
        self.wait_for_selection(10.0);
        sleep(0.5);
        let report = self.typing(75, 1.0 / 25.0);
        (self.post)(Injected::Keys("<Esc>u".into()));
        sleep(0.2);
        report
    }

    /// Switching between two documents (and a shell): when the confirmed buffer reached the display.
    fn editor_tabs(&self) -> Value {
        let (Some(first), Some(second)) = (self.scratch_copy("first.swift"), self.scratch_copy("second.swift")) else { return json!({"error": "no file to edit"}) };
        // Make the two files look different near the top.
        let _ = std::fs::write(&second, format!("// second\n{}", std::fs::read_to_string(&second).unwrap_or_default()));
        (self.post)(Injected::OpenDocument { path: first.clone(), sent: clock::now() });
        self.wait_for_selection(10.0);
        (self.post)(Injected::OpenDocument { path: second.clone(), sent: clock::now() });
        self.wait_for_selection(10.0);
        sleep(0.5);
        let measurement = self.measure(|| {
            let mut next = clock::now();
            for index in 0..24 {
                wait_until(next);
                let path = if index % 2 == 0 { first.clone() } else { second.clone() };
                (self.post)(Injected::OpenDocument { path, sent: clock::now() });
                next += 0.25;
            }
            sleep(0.3);
        });
        let selections = self.state.selections.lock().clone();
        let mut frames = measurement.frames.clone();
        frames.sort_by(|a, b| a.planned.partial_cmp(&b.planned).unwrap());
        let mut latency = Vec::new();
        let mut missing = 0;
        for (sent, _handled, generation) in &selections {
            match frames.iter().find(|frame| frame.marks.selection >= *generation && frame.displayed > 0.0) {
                Some(frame) => latency.push((frame.displayed - sent) * 1000.0),
                None => missing += 1,
            }
        }
        let mut report = self.frame_report(&measurement);
        report.insert("switches".into(), json!(selections.len()));
        report.insert("switchesWithoutDisplayedFrame".into(), json!(missing));
        report.insert("switchToDisplayMs".into(), summary(&latency));
        Value::Object(report)
    }

    fn run(&self, scenario: &str) -> Value {
        match scenario {
            "editor-type" => self.editor_typing(),
            "editor-tabs" => self.editor_tabs(),
            "idle" => self.idle(),
            "terminal-type" => {
                self.select_shell();
                self.typing(75, 1.0 / 25.0)
            }
            "terminal-type-sparse" => {
                self.select_shell();
                self.typing(6, 1.6)
            }
            "terminal-scroll" | "terminal-flick" | "terminal-swell" | "terminal-crawl" | "terminal-steady60" | "terminal-reversal" => {
                self.select_shell();
                self.fill_scrollback();
                let profile = match scenario {
                    "terminal-flick" => ScrollProfile::flick(true),
                    "terminal-swell" => ScrollProfile::swell(3.0, true),
                    "terminal-crawl" => ScrollProfile::crawl(5.0, true),
                    "terminal-steady60" => ScrollProfile::steady60(360.0, 3.0, true),
                    "terminal-reversal" => {
                        // The Swift profile scrolls toward newer output first; start from older output.
                        let mut profile = ScrollProfile::reversal();
                        for event in &mut profile.events {
                            event.delta = -event.delta;
                        }
                        profile
                    }
                    _ => ScrollProfile::steady(720.0, 2.5, true),
                };
                let report = self.scroll(&profile);
                // Back to the prompt for the next scenario.
                (self.post)(Injected::Text { bytes: b"clear\r".to_vec(), sent: clock::now(), measure: false });
                sleep(0.3);
                report
            }
            "ui-tabs" => self.tabs(),
            "demo" => {
                // Something to look at (used with NEOLINK_CAPTURE): styles, colours, wide and combined
                // characters, a listing.
                self.type_text("clear; printf '\\033[1mbold\\033[0m \\033[3mitalic\\033[0m \\033[4munderline\\033[0m \\033[7minverse\\033[0m \\033[2mdim\\033[0m \\033[9mstrike\\033[0m\\n'; for c in 31 32 33 34 35 36 91 92 93 94 95 96; do printf \"\\033[${c}m color$c \\033[0m\"; done; echo; echo 'Unicode: e\u{301} \u{fc} \u{2192} \u{2713} \u{65e5}\u{672c}\u{8a9e} \u{1f642} | fn main() { let x = [1, 2, 3]; }'; ls -la /\r", 0.004);
                sleep(30.0);
                json!({})
            }
            other => json!({"error": format!("unknown scenario {other}")}),
        }
    }
}

fn summary(values: &[f64]) -> Value {
    let summary = Summary::of(values);
    json!({"count": summary.count, "p50": summary.p50, "p95": summary.p95, "max": summary.max, "mean": summary.mean, "p05": round_to(percentile(values, 0.05), 2)})
}

pub struct Options {
    pub scenarios: Vec<String>,
    pub output: Option<std::path::PathBuf>,
    pub busy: bool,
}

impl Options {
    pub fn from_env() -> Option<Options> {
        let list = std::env::var("NEOLINK_BENCHMARK").ok()?;
        let scenarios: Vec<String> = list.split(',').map(|name| name.trim().to_string()).filter(|name| !name.is_empty()).collect();
        if scenarios.is_empty() {
            return None;
        }
        Some(Options {
            scenarios,
            output: std::env::var_os("NEOLINK_BENCHMARK_OUTPUT").map(std::path::PathBuf::from),
            busy: std::env::var("NEOLINK_BENCHMARK_BUSY").as_deref() == Ok("1"),
        })
    }
}

/// Runs the scenarios on their own thread, writes the report, then asks the app to quit.
pub fn start(options: Options, shared: Arc<Shared>, state: Arc<BenchState>, post: Post, environment: Value) {
    std::thread::Builder::new()
        .name("benchmark".into())
        .spawn(move || {
            // Input must leave this thread when the profile says, as a device's reports do.
            #[cfg(target_os = "macos")]
            unsafe {
                libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
            }
            // The window (and a full-screen transition) settles, and the shell prints its prompt.
            sleep(3.5);
            let period = shared.state.lock().period;
            let runner = Runner { shared, state, post, busy: options.busy, period, helper_cpu: Mutex::new(0.0) };
            let mut scenarios = Map::new();
            for scenario in &options.scenarios {
                eprintln!("benchmark: {scenario}");
                scenarios.insert(scenario.clone(), runner.run(scenario));
                sleep(0.3);
            }
            let mut environment = environment;
            if let Some(object) = environment.as_object_mut() {
                object.insert("busyMainThread".into(), json!(options.busy));
                object.insert("refreshHz".into(), json!(round_to(1.0 / period, 2)));
                object.insert("input".into(), json!("synthetic events posted to the main thread with their sampling time; not a physical trackpad or keyboard, and not the operating system's event delivery"));
                if let Some((cell, grid)) = with_workspace(&runner.shared, |workspace| (workspace.cell, workspace.grid())) {
                    object.insert("cellPixels".into(), json!([cell.width, cell.height]));
                    object.insert("grid".into(), json!([grid.0, grid.1]));
                }
            }
            let report = json!({"app": "neolink-rust", "environment": environment, "scenarios": scenarios});
            let text = serde_json::to_string_pretty(&report).unwrap_or_default();
            match &options.output {
                Some(path) => {
                    if let Err(error) = std::fs::write(path, &text) {
                        eprintln!("benchmark: cannot write {}: {error}", path.display());
                    }
                }
                None => println!("{text}"),
            }
            (runner.post)(Injected::Finished);
        })
        .expect("benchmark thread");
}
