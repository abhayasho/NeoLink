//! Per-frame scroll analysis: the same quantities, with the same formulas, as `ScrollAnalysis` in
//! `Sources/Rendering/InteractionBenchmark.swift`, so reports from the two apps can be compared.
//!
//! Positions are in lines (points divided by the cell height); times in seconds on one clock. A frame is
//! `(time it reached the display, position drawn in it)`.

use crate::stats::{percentile, round_to};

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScrollReport {
    pub frames: usize,
    /// The constant delay (0 to 80 ms) that best aligns drawn positions with the ideal input.
    pub lag_ms: f64,
    /// Time from the first input event to the first displayed frame that moved at least half a pixel.
    pub first_motion_ms: f64,
    /// Change of step between consecutive refreshes beyond what the input did, in device pixels.
    pub jerk_pixels_p50: f64,
    pub jerk_pixels_p95: f64,
    pub jerk_pixels_max: f64,
    /// Frames whose jerk exceeds 1.5 device pixels.
    pub uneven_frames: usize,
    pub step_error_pixels_p95: f64,
    /// Frames in which the content stayed put while the (lag-corrected) input moved.
    pub stall_frames: usize,
    /// Frames that moved more than twice the input plus a quarter line.
    pub jump_frames: usize,
    pub missed_refreshes_while_moving: usize,
    /// Slow-motion quality: largest single step, frames of two pixels or more while the finger moves
    /// less than one per refresh, and the coefficient of variation of the time between pixel steps.
    pub largest_step_pixels: f64,
    pub burst_frames: usize,
    pub pixel_steps: usize,
    pub step_gap_spread: f64,
    pub step_gap_mean_ms: f64,
    /// How far the content was ever drawn ahead of the input at display time (prediction error).
    pub ahead_lines_max: f64,
    pub backward_frames: usize,
    pub backward_lines_max: f64,
    pub trailing_lines_p50: f64,
    pub trailing_lines_p95: f64,
    pub position_error_lines_p95: f64,
    pub position_error_lines_max: f64,
    pub velocity_error_p95: f64,
    pub settle_ms: f64,
    pub settle_lines: f64,
    pub ideal_lines: f64,
    pub drawn_lines: f64,
}

pub struct ScrollAnalysis<'a> {
    /// `(time, ideal position in lines)` at every tick of the input profile.
    pub timeline: &'a [(f64, f64)],
    /// `(presented time, drawn position in lines)`, relative to the position when the input began.
    pub frames: &'a [(f64, f64)],
    /// Display refresh rate in Hz.
    pub rate: f64,
    /// Device pixels per line.
    pub cell_pixels: f64,
}

impl ScrollAnalysis<'_> {
    /// The ideal position at `time`, linearly interpolated between input ticks.
    pub fn ideal(&self, time: f64) -> f64 {
        let Some(first) = self.timeline.first() else { return 0.0 };
        if time <= first.0 {
            return 0.0;
        }
        let index = self.timeline.partition_point(|sample| sample.0 < time);
        if index >= self.timeline.len() {
            return self.timeline[self.timeline.len() - 1].1;
        }
        let (t1, p1) = self.timeline[index];
        let (t0, p0) = if index > 0 { self.timeline[index - 1] } else { (first.0, 0.0) };
        if t1 > t0 {
            p0 + (p1 - p0) * (time - t0) / (t1 - t0)
        } else {
            p1
        }
    }

    pub fn report(&self) -> ScrollReport {
        let (Some(&(start, _)), Some(&(end, last_ideal))) = (self.timeline.first(), self.timeline.last()) else {
            return ScrollReport::default();
        };
        let frames: Vec<(f64, f64)> = self.frames.iter().copied().filter(|f| f.0 >= start).collect();
        if frames.len() <= 2 {
            return ScrollReport { frames: frames.len(), ..ScrollReport::default() };
        }
        let cell = self.cell_pixels.max(1.0);
        let period = 1.0 / self.rate;
        let pixel = 1.0 / cell;

        // Best constant latency in 0-80 ms.
        let mut lag = 0.0;
        let mut best = f64::INFINITY;
        for step in 0..=80 {
            let candidate = step as f64 * 0.001;
            let error: f64 = frames
                .iter()
                .filter(|f| f.0 <= end + 0.02)
                .map(|f| (f.1 - self.ideal(f.0 - candidate)).powi(2))
                .sum();
            if error < best {
                best = error;
                lag = candidate;
            }
        }

        let mut stalls = 0;
        let mut jumps = 0;
        let mut velocity_errors = Vec::new();
        let mut position_errors = Vec::new();
        let mut missed_moving = 0usize;
        for i in 1..frames.len() {
            if frames[i].0 > end + lag {
                continue;
            }
            let dt = frames[i].0 - frames[i - 1].0;
            let drawn = frames[i].1 - frames[i - 1].1;
            let expected = self.ideal(frames[i].0 - lag) - self.ideal(frames[i - 1].0 - lag);
            position_errors.push((frames[i].1 - self.ideal(frames[i].0 - lag)).abs());
            if dt > 0.0 {
                velocity_errors.push((drawn - expected).abs() / dt);
            }
            if expected.abs() > 0.02 && drawn.abs() < 0.1 * expected.abs() {
                stalls += 1;
            }
            if drawn.abs() > 2.0 * expected.abs() + 0.25 {
                jumps += 1;
            }
            // Refreshes skipped while the finger moved at least one device pixel per refresh.
            if dt > 1.5 * period {
                let refreshes = dt / period;
                if expected.abs() / refreshes >= pixel {
                    missed_moving += (refreshes.round() as usize).saturating_sub(1);
                }
            }
        }

        // Settling after the last input event.
        let at_end = frames.iter().rev().find(|f| f.0 <= end + lag).map(|f| f.1).unwrap_or(frames[frames.len() - 1].1);
        let after: Vec<(f64, f64)> = frames.iter().copied().filter(|f| f.0 > end + lag).collect();
        let mut settle_end = end + lag;
        for i in 1..after.len() {
            if (after[i].1 - after[i - 1].1).abs() > 0.002 {
                settle_end = after[i].0;
            }
        }
        let settle_distance = frames[frames.len() - 1].1 - at_end;

        // Responsiveness, apart from the lag-corrected evenness.
        let first_motion = frames.iter().find(|f| f.1.abs() > 0.5 * pixel).map(|f| f.0);
        let mut ahead_max: f64 = 0.0;
        let mut backward_frames = 0;
        let mut backward_max: f64 = 0.0;
        let mut trailing = Vec::new();
        for i in 1..frames.len() {
            if frames[i].0 > end + 0.1 {
                continue;
            }
            let now = self.ideal(frames[i].0);
            let before = self.ideal(frames[i].0 - 0.02);
            let moving = now - before;
            if moving.abs() > 2.0 * pixel {
                let lead = (frames[i].1 - now) * moving.signum();
                ahead_max = ahead_max.max(lead);
                trailing.push(-lead);
            }
            let step = frames[i].1 - frames[i - 1].1;
            let expected = self.ideal(frames[i].0 - lag) - self.ideal(frames[i - 1].0 - lag);
            if step.abs() > pixel && expected.abs() > 0.5 * pixel && (step > 0.0) != (expected > 0.0) {
                backward_frames += 1;
                backward_max = backward_max.max(step.abs());
            }
        }

        // Visual smoothness: change of step from one refresh to the next beyond what the input did.
        let mut jerk = Vec::new();
        let mut step_errors = Vec::new();
        for i in 2..frames.len() {
            if frames[i].0 > end + lag {
                continue;
            }
            let gap_a = frames[i].0 - frames[i - 1].0;
            let gap_b = frames[i - 1].0 - frames[i - 2].0;
            let want_a = self.ideal(frames[i].0 - lag) - self.ideal(frames[i - 1].0 - lag);
            if gap_a >= 1.5 * period || gap_b >= 1.5 * period {
                // A skipped refresh is itself a visible change of speed: the whole step it should have shown.
                jerk.push(want_a.abs() * cell / (gap_a / period).round().max(1.0));
                continue;
            }
            let step_a = frames[i].1 - frames[i - 1].1;
            let step_b = frames[i - 1].1 - frames[i - 2].1;
            let want_b = self.ideal(frames[i - 1].0 - lag) - self.ideal(frames[i - 2].0 - lag);
            if want_a.abs() + want_b.abs() <= 0.5 * pixel {
                continue;
            }
            jerk.push(((step_a - step_b) - (want_a - want_b)).abs() * cell);
            step_errors.push((step_a - want_a).abs() * cell);
        }

        // Slow motion is judged by its pixel steps.
        let mut largest_step: f64 = 0.0;
        let mut burst_frames = 0;
        let mut step_times = Vec::new();
        for i in 1..frames.len() {
            if frames[i].0 > end + lag + 0.2 {
                continue;
            }
            let step = (frames[i].1 - frames[i - 1].1).abs() * cell;
            if step <= 0.5 {
                continue;
            }
            largest_step = largest_step.max(step);
            step_times.push(frames[i].0);
            let finger_per_frame =
                (self.ideal(frames[i].0 - lag) - self.ideal(frames[i].0 - lag - 0.1)).abs() * cell / 12.0;
            if step >= 1.5 && finger_per_frame < 0.75 {
                burst_frames += 1;
            }
        }
        let step_gaps: Vec<f64> = step_times.windows(2).map(|w| w[1] - w[0]).collect();
        let mean_gap = if step_gaps.is_empty() { 0.0 } else { step_gaps.iter().sum::<f64>() / step_gaps.len() as f64 };
        let gap_spread = if step_gaps.is_empty() || mean_gap == 0.0 {
            0.0
        } else {
            (step_gaps.iter().map(|g| (g - mean_gap).powi(2)).sum::<f64>() / step_gaps.len() as f64).sqrt() / mean_gap
        };

        ScrollReport {
            frames: frames.len(),
            lag_ms: round_to(lag * 1000.0, 1),
            first_motion_ms: first_motion.map(|t| round_to((t - start) * 1000.0, 1)).unwrap_or(-1.0),
            jerk_pixels_p50: round_to(percentile(&jerk, 0.5), 2),
            jerk_pixels_p95: round_to(percentile(&jerk, 0.95), 2),
            jerk_pixels_max: round_to(crate::stats::max(&jerk), 2),
            uneven_frames: jerk.iter().filter(|j| **j > 1.5).count(),
            step_error_pixels_p95: round_to(percentile(&step_errors, 0.95), 2),
            stall_frames: stalls,
            jump_frames: jumps,
            missed_refreshes_while_moving: missed_moving,
            largest_step_pixels: round_to(largest_step, 1),
            burst_frames,
            pixel_steps: step_times.len(),
            step_gap_spread: round_to(gap_spread, 2),
            step_gap_mean_ms: round_to(mean_gap * 1000.0, 1),
            ahead_lines_max: round_to(ahead_max, 3),
            backward_frames,
            backward_lines_max: round_to(backward_max, 3),
            trailing_lines_p50: round_to(percentile(&trailing, 0.5), 3),
            trailing_lines_p95: round_to(percentile(&trailing, 0.95), 3),
            position_error_lines_p95: round_to(percentile(&position_errors, 0.95), 3),
            position_error_lines_max: round_to(crate::stats::max(&position_errors), 3),
            velocity_error_p95: round_to(percentile(&velocity_errors, 0.95), 1),
            settle_ms: round_to((settle_end - end - lag) * 1000.0, 1),
            settle_lines: round_to(settle_distance, 3),
            ideal_lines: round_to(last_ideal, 3),
            drawn_lines: round_to(frames[frames.len() - 1].1, 3),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: f64 = 120.0;
    const CELL: f64 = 32.0;

    /// A finger moving at `lines_per_second`, sampled at 120 Hz for `seconds`.
    fn timeline(lines_per_second: f64, seconds: f64) -> Vec<(f64, f64)> {
        (0..=(seconds * 120.0) as usize).map(|i| (i as f64 / 120.0, lines_per_second * i as f64 / 120.0)).collect()
    }

    fn frames_following(timeline: &[(f64, f64)], lag: f64, held_every: usize) -> Vec<(f64, f64)> {
        let analysis = ScrollAnalysis { timeline, frames: &[], rate: RATE, cell_pixels: CELL };
        let end = timeline.last().unwrap().0;
        let mut frames = Vec::new();
        let mut previous = 0.0;
        let mut i = 0;
        loop {
            let time = 0.004 + i as f64 / RATE;
            if time > end + 0.3 {
                break;
            }
            let position = if held_every > 0 && i % held_every == held_every - 1 { previous } else { analysis.ideal(time - lag) };
            frames.push((time, position));
            previous = position;
            i += 1;
        }
        frames
    }

    #[test]
    fn a_delayed_copy_is_even_and_its_lag_is_found() {
        let timeline = timeline(20.0, 2.0);
        let frames = frames_following(&timeline, 0.017, 0);
        let report = ScrollAnalysis { timeline: &timeline, frames: &frames, rate: RATE, cell_pixels: CELL }.report();
        assert!((report.lag_ms - 17.0).abs() <= 1.0, "{report:?}");
        assert_eq!(report.uneven_frames, 0);
        assert_eq!(report.stall_frames, 0);
        assert_eq!(report.jump_frames, 0);
        assert!(report.jerk_pixels_p95 < 0.01);
        assert!((report.drawn_lines - 40.0).abs() < 0.01);
    }

    #[test]
    fn held_frames_are_counted_as_stalls_and_uneven() {
        let timeline = timeline(20.0, 2.0);
        // Every other frame repeats the previous one: 60 Hz content on a 120 Hz display.
        let frames = frames_following(&timeline, 0.0, 2);
        let report = ScrollAnalysis { timeline: &timeline, frames: &frames, rate: RATE, cell_pixels: CELL }.report();
        assert!(report.stall_frames > 100, "{report:?}");
        assert!(report.uneven_frames > 200, "{report:?}");
        assert!(report.jerk_pixels_p50 > 5.0);
    }

    #[test]
    fn first_motion_is_measured_from_the_first_event() {
        let timeline = timeline(20.0, 1.0);
        let frames = frames_following(&timeline, 0.010, 0);
        let report = ScrollAnalysis { timeline: &timeline, frames: &frames, rate: RATE, cell_pixels: CELL }.report();
        // The first frame after 10 ms of lag that has moved half a pixel.
        assert!(report.first_motion_ms > 10.0 && report.first_motion_ms < 22.0, "{report:?}");
    }

    #[test]
    fn too_few_frames_reports_only_the_count() {
        let timeline = timeline(20.0, 1.0);
        let frames = [(0.1, 0.0), (0.2, 1.0)];
        let report = ScrollAnalysis { timeline: &timeline, frames: &frames, rate: RATE, cell_pixels: CELL }.report();
        assert_eq!(report.frames, 2);
        assert_eq!(report.lag_ms, 0.0);
    }
}
