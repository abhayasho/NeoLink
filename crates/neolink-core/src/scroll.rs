//! Trackpad scrolling without a resampling buffer.
//!
//! The rule: what an event moved is drawn in the very next frame. The one exception is input that is
//! measurably slower than the display (a 60 Hz finger on a 120 Hz panel, or a creeping finger that reports
//! one point every 40-250 ms): shown at once, such input repeats frames between reports, or jumps two
//! device pixels and then waits. For that input only, an event's distance is *spread*: released linearly
//! over the measured report interval, beginning with the next frame. Nothing waits for a later event, so
//! the first part of every event is on screen as soon as it would have been anyway, and the last part is
//! late by at most the interval minus one frame (capped). The delay in effect is reported.

use std::collections::VecDeque;

/// The longest time an event's distance may be spread over, in seconds.
pub const MAX_SPREAD: f64 = 0.150;
/// Reports further apart than this belong to different movements when measuring the report interval.
pub const SAME_GESTURE_GAP: f64 = 0.3;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Smoothing {
    /// Every event is drawn whole in the next frame.
    Off,
    /// Spread only when reports are at least 1.5 display frames apart.
    Auto,
}

#[derive(Clone, Copy, Debug)]
struct Spread {
    amount: f64,
    released: f64,
    /// Display time of the first frame that showed part of it.
    start: f64,
    duration: f64,
}

/// One scroll axis of one pane.
#[derive(Clone, Debug)]
pub struct ScrollSmoother {
    smoothing: Smoothing,
    pending: Vec<(f64, f64)>,
    spreads: VecDeque<Spread>,
    last_event: Option<f64>,
    gaps: [f64; 3],
    gap_count: usize,
    /// The longest delay any distance has been given so far, in seconds (for reports).
    max_delay: f64,
    spread_events: usize,
    events: usize,
}

impl ScrollSmoother {
    pub fn new(smoothing: Smoothing) -> ScrollSmoother {
        ScrollSmoother {
            smoothing,
            pending: Vec::new(),
            spreads: VecDeque::new(),
            last_event: None,
            gaps: [0.0; 3],
            gap_count: 0,
            max_delay: 0.0,
            spread_events: 0,
            events: 0,
        }
    }

    pub fn set_smoothing(&mut self, smoothing: Smoothing) {
        self.smoothing = smoothing;
    }

    /// The interval between recent reports: the median of the last three gaps, so that one late or
    /// early report does not change the rule in effect.
    fn report_interval(&self) -> Option<f64> {
        match self.gap_count {
            0 => None,
            1 => Some(self.gaps[0]),
            // With two gaps, the shorter: when in doubt, less smoothing.
            2 => Some(self.gaps[0].min(self.gaps[1])),
            _ => {
                let mut sorted = self.gaps;
                sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
                Some(sorted[1])
            }
        }
    }

    /// A new movement begins (fingers touched down): forget the previous movement's report rate.
    pub fn begin_gesture(&mut self) {
        self.last_event = None;
        self.gap_count = 0;
    }

    /// An event moved the content by `delta` pixels. `time` is when the input was sampled; `period` is
    /// the display's refresh interval.
    pub fn push(&mut self, time: f64, delta: f64, period: f64) {
        if let Some(last) = self.last_event {
            let gap = time - last;
            if gap > SAME_GESTURE_GAP {
                self.gap_count = 0;
            } else if gap > 0.0 {
                if self.gap_count < 3 {
                    self.gaps[self.gap_count] = gap;
                    self.gap_count += 1;
                } else {
                    self.gaps = [self.gaps[1], self.gaps[2], gap];
                }
            }
        }
        self.last_event = Some(time);
        if delta == 0.0 {
            return;
        }
        self.events += 1;
        let duration = match (self.smoothing, self.report_interval()) {
            (Smoothing::Auto, Some(interval)) if interval >= 1.5 * period => interval.min(MAX_SPREAD),
            _ => 0.0,
        };
        if duration > period {
            self.spread_events += 1;
            self.max_delay = self.max_delay.max(duration - period);
        }
        self.pending.push((delta, duration));
    }

    /// The distance to move in the frame that will be displayed at `frame_time`.
    pub fn advance(&mut self, frame_time: f64, period: f64) -> f64 {
        let mut step = 0.0;
        for (amount, duration) in self.pending.drain(..) {
            if duration <= period {
                step += amount;
            } else {
                // A new event in the same direction takes over what is left of the one still being
                // released, and spreads both from this frame. Two spreads released side by side moved
                // two events' distance in one frame and almost nothing in the next whenever a report came
                // a little early (recorded frames: steps of 62 then 10 pixels among steps of 35). Queuing
                // them instead added up to a report interval of delay to slow scrolling.
                let mut amount = amount;
                if let Some(last) = self.spreads.back_mut().filter(|last| last.amount.signum() == amount.signum() && last.released != last.amount) {
                    amount += last.amount - last.released;
                    last.amount = last.released;
                }
                self.spreads.push_back(Spread { amount, released: 0.0, start: frame_time, duration });
            }
        }
        for spread in self.spreads.iter_mut() {
            // Finished, or taken over by a later spread: nothing more to release.
            if spread.released == spread.amount {
                continue;
            }
            let fraction = (frame_time - spread.start + period) / spread.duration;
            // Frame times are not exact multiples of the period: the last part is not left for a
            // frame of its own.
            let target = if fraction >= 1.0 - 1e-6 { spread.amount } else { spread.amount * fraction.max(0.0) };
            step += target - spread.released;
            spread.released = target;
        }
        self.spreads.retain(|spread| spread.released != spread.amount);
        step
    }

    /// What [`advance`](Self::advance) would return for a frame displayed at `frame_time`, without
    /// changing anything: used to find the next frame in which the content will actually move.
    pub fn peek(&self, frame_time: f64, period: f64) -> f64 {
        let mut step = 0.0;
        let release = |spread: &Spread| {
            if spread.released == spread.amount {
                return 0.0;
            }
            let fraction = (frame_time - spread.start + period) / spread.duration;
            let target = if fraction >= 1.0 - 1e-6 { spread.amount } else { spread.amount * fraction.max(0.0) };
            target - spread.released
        };
        // Not yet anchored: each would start in this frame, taking over what is left of the spread in
        // the same direction before it (see `advance`).
        let mut spreads: Vec<Spread> = self.spreads.iter().copied().collect();
        for (amount, duration) in &self.pending {
            if *duration <= period {
                step += amount;
            } else {
                let mut amount = *amount;
                if let Some(last) = spreads.last_mut().filter(|last| last.amount.signum() == amount.signum() && last.released != last.amount) {
                    amount += last.amount - last.released;
                    last.amount = last.released;
                }
                spreads.push(Spread { amount, released: 0.0, start: frame_time, duration: *duration });
            }
        }
        for spread in &spreads {
            step += release(spread);
        }
        step
    }

    /// The display time of the first frame after `frame_time` in which `position` (as it stands after
    /// that frame) will have moved to a different whole pixel, or the frame that finishes what is
    /// outstanding. `None` when nothing is outstanding.
    pub fn next_visible_change(&self, frame_time: f64, period: f64, position: f64) -> Option<f64> {
        if !self.is_active() {
            return None;
        }
        let shown = position.round();
        let horizon = (MAX_SPREAD / period).ceil() as usize + 2;
        for frame in 1..=horizon {
            let time = frame_time + frame as f64 * period;
            let moved = self.peek(time, period);
            if (position + moved).round() != shown || (self.outstanding() - moved).abs() < 1e-9 {
                return Some(time);
            }
        }
        Some(frame_time + horizon as f64 * period)
    }

    /// Whether more frames are needed to finish what has been received.
    pub fn is_active(&self) -> bool {
        !self.pending.is_empty() || !self.spreads.is_empty()
    }

    /// Distance received but not yet drawn.
    pub fn outstanding(&self) -> f64 {
        self.pending.iter().map(|p| p.0).sum::<f64>()
            + self.spreads.iter().map(|s| s.amount - s.released).sum::<f64>()
    }

    /// Drops everything not yet drawn (the content was moved by something else, or reached an end).
    pub fn cancel(&mut self) {
        self.pending.clear();
        self.spreads.clear();
    }

    /// `(events spread, all events, longest delay given to any distance in ms)`.
    pub fn delay_report(&self) -> (usize, usize, f64) {
        (self.spread_events, self.events, self.max_delay * 1000.0)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Axis {
    Vertical,
    Horizontal,
}

/// Locks a trackpad gesture to its dominant axis.
///
/// The lock must not flip event by event (a hand wandering around 45 degrees changed axis 59 times in
/// three seconds under a one-event rule; see docs/RENDERING.md, pass 4). With the fingers down it changes
/// only on sustained evidence: within the last 0.2 s of travel, at least 16 points across and 1.9 times
/// the travel along the locked axis. A gap is not a new gesture until 0.15 s of rest with the fingers up,
/// and momentum keeps its gesture's axis.
#[derive(Clone, Debug)]
pub struct AxisLock {
    axis: Option<Axis>,
    history: VecDeque<(f64, f64, f64)>,
    last_event: f64,
    fingers_down: bool,
    changes: usize,
}

impl Default for AxisLock {
    fn default() -> Self {
        AxisLock::new()
    }
}

impl AxisLock {
    pub const MEMORY: f64 = 0.2;
    pub const SWITCH_TRAVEL: f64 = 16.0;
    pub const SWITCH_RATIO: f64 = 1.9;
    pub const REST: f64 = 0.15;

    pub fn new() -> AxisLock {
        AxisLock { axis: None, history: VecDeque::new(), last_event: f64::NEG_INFINITY, fingers_down: false, changes: 0 }
    }

    pub fn axis(&self) -> Option<Axis> {
        self.axis
    }

    /// How many times the axis changed within gestures (for the benchmark).
    pub fn changes(&self) -> usize {
        self.changes
    }

    /// Fingers touched down (`true`) or lifted (`false`).
    pub fn set_fingers_down(&mut self, down: bool, time: f64) {
        if down && !self.fingers_down && time - self.last_event >= Self::REST {
            self.axis = None;
            self.history.clear();
        }
        self.fingers_down = down;
    }

    /// Returns the part of `(dx, dy)` the locked axis lets through, in points.
    pub fn filter(&mut self, time: f64, dx: f64, dy: f64, momentum: bool) -> (f64, f64) {
        if !momentum && !self.fingers_down && time - self.last_event >= Self::REST {
            // A device without phases (or a missed "began"): a rest starts a new gesture.
            self.axis = None;
            self.history.clear();
        }
        self.last_event = time;
        if !momentum {
            self.history.push_back((time, dx.abs(), dy.abs()));
            while self.history.front().is_some_and(|sample| time - sample.0 > Self::MEMORY) {
                self.history.pop_front();
            }
            let across: f64 = self.history.iter().map(|s| s.1).sum();
            let along: f64 = self.history.iter().map(|s| s.2).sum();
            match self.axis {
                None => {
                    if across > 0.0 || along > 0.0 {
                        self.axis = Some(if across > along { Axis::Horizontal } else { Axis::Vertical });
                    }
                }
                Some(Axis::Vertical) => {
                    if across >= Self::SWITCH_TRAVEL && across >= Self::SWITCH_RATIO * along {
                        self.axis = Some(Axis::Horizontal);
                        self.changes += 1;
                    }
                }
                Some(Axis::Horizontal) => {
                    if along >= Self::SWITCH_TRAVEL && along >= Self::SWITCH_RATIO * across {
                        self.axis = Some(Axis::Vertical);
                        self.changes += 1;
                    }
                }
            }
        }
        match self.axis {
            Some(Axis::Horizontal) => (dx, 0.0),
            Some(Axis::Vertical) => (0.0, dy),
            None => (0.0, 0.0),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::{GesturePhase, MomentumPhase, Playback, ScrollProfile};

    const P: f64 = 1.0 / 120.0;

    /// Feeds events `interval` apart and frames every refresh; returns each frame's step.
    fn run(smoothing: Smoothing, deltas: &[f64], interval: f64, frames: usize) -> (Vec<f64>, ScrollSmoother) {
        let mut smoother = ScrollSmoother::new(smoothing);
        let mut steps = Vec::new();
        let mut next_event = 0;
        for frame in 0..frames {
            let frame_time = 0.001 + frame as f64 * P;
            while next_event < deltas.len() && next_event as f64 * interval <= frame_time {
                smoother.push(next_event as f64 * interval, deltas[next_event], P);
                next_event += 1;
            }
            steps.push(smoother.advance(frame_time, P));
        }
        (steps, smoother)
    }

    #[test]
    fn display_rate_input_is_drawn_whole_in_the_next_frame() {
        let deltas = vec![3.0; 60];
        let (steps, smoother) = run(Smoothing::Auto, &deltas, P, 70);
        assert!(steps[..60].iter().all(|s| (*s - 3.0).abs() < 1e-9), "{steps:?}");
        assert!(steps[60..].iter().all(|s| *s == 0.0));
        assert_eq!(smoother.delay_report().0, 0);
        assert!(!smoother.is_active());
    }

    #[test]
    fn the_first_event_of_a_gesture_is_never_delayed() {
        let (steps, _) = run(Smoothing::Auto, &[8.0], 1.0 / 60.0, 4);
        assert_eq!(steps[0], 8.0);
    }

    #[test]
    fn sixty_hertz_input_moves_every_refresh_once_its_rate_is_known() {
        let deltas = vec![6.0; 60];
        let (steps, smoother) = run(Smoothing::Auto, &deltas, 1.0 / 60.0, 126);
        // The first event is whole (no rate yet) and one frame is held after it; from the second event
        // on, half of each event is drawn in each of two frames.
        assert_eq!(steps[0], 6.0);
        assert_eq!(steps[1], 0.0);
        for (index, step) in steps[2..120].iter().enumerate() {
            assert!((step - 3.0).abs() < 1e-9, "frame {} moved {step}", index + 2);
        }
        let total: f64 = steps.iter().sum();
        assert!((total - 360.0).abs() < 1e-9);
        let (spread, events, delay) = smoother.delay_report();
        assert_eq!((spread, events), (59, 60));
        assert!((delay - 1000.0 * P).abs() < 1e-6, "delay {delay}");
    }

    #[test]
    fn without_smoothing_sixty_hertz_input_holds_alternate_frames() {
        let deltas = vec![6.0; 60];
        let (steps, _) = run(Smoothing::Off, &deltas, 1.0 / 60.0, 126);
        assert_eq!(steps.iter().filter(|s| **s == 6.0).count(), 60);
        assert_eq!(steps[..120].iter().filter(|s| **s == 0.0).count(), 60);
    }

    #[test]
    fn a_creeping_finger_is_drawn_in_single_pixel_steps() {
        // One point (two device pixels) every 100 ms.
        let deltas = vec![2.0; 20];
        let (steps, smoother) = run(Smoothing::Auto, &deltas, 0.1, 260);
        // Position rounded to whole device pixels, as the renderer snaps it.
        let mut position = 0.0;
        let mut shown = 0.0f64;
        let mut largest: f64 = 0.0;
        for step in &steps[13..] {
            position += step;
            let snapped = (position as f64).round();
            largest = largest.max((snapped - shown).abs());
            shown = snapped;
        }
        assert!(largest <= 1.0, "largest step {largest}");
        assert!((steps.iter().sum::<f64>() - 40.0).abs() < 1e-9);
        assert!(smoother.delay_report().2 <= 1000.0 * (0.1 - P) + 1e-6);
    }

    #[test]
    fn frames_are_needed_only_when_a_pixel_changes() {
        // One point (two device pixels) every 100 ms: about two frames per event, not twelve.
        let mut smoother = ScrollSmoother::new(Smoothing::Auto);
        let mut position = 0.0f64;
        let mut frames = 0;
        let mut next_event = 0;
        let mut wake: Option<f64> = Some(0.001);
        let mut time = 0.001;
        while time < 2.2 {
            let mut due = wake.is_some_and(|at| at <= time + 1e-9);
            while next_event < 20 && next_event as f64 * 0.1 <= time {
                smoother.push(next_event as f64 * 0.1, 2.0, P);
                next_event += 1;
                due = true;
            }
            if due {
                position += smoother.advance(time, P);
                frames += 1;
                wake = smoother.next_visible_change(time, P, position);
            }
            time += P;
        }
        assert!((position - 40.0).abs() < 1e-9);
        assert!(!smoother.is_active());
        // Per event at most: the frame it arrives in, one per pixel, and one that finishes the spread.
        // Drawing every refresh would be about 250.
        assert!(frames <= 20 * 4 + 8, "{frames} frames for 40 pixel steps");
        assert!(frames >= 40);
    }

    #[test]
    fn peek_matches_advance() {
        let mut smoother = ScrollSmoother::new(Smoothing::Auto);
        smoother.push(0.0, 6.0, P);
        smoother.push(1.0 / 60.0, 6.0, P);
        let time = 1.0 / 60.0 + 0.001;
        let expected = smoother.peek(time, P);
        assert!((smoother.advance(time, P) - expected).abs() < 1e-12);
        let expected = smoother.peek(time + P, P);
        assert!((smoother.advance(time + P, P) - expected).abs() < 1e-12);
    }

    #[test]
    fn jittered_input_never_steps_backwards_and_loses_nothing() {
        let period = 1.0 / 120.0;
        let mut smoother = ScrollSmoother::new(Smoothing::Auto);
        let times = [0.0, 0.017, 0.031, 0.050, 0.066, 0.079, 0.101, 0.115, 0.134, 0.150, 0.170, 0.181];
        let (mut frame, mut next, mut total) = (0.0, 0, 0.0);
        for _ in 0..60 {
            frame += period;
            while next < times.len() && times[next] <= frame - period * 0.5 {
                smoother.push(times[next], 30.0, period);
                next += 1;
            }
            let step = smoother.advance(frame, period);
            assert!(step >= -1e-9, "a step went backwards: {step}");
            total += step;
        }
        assert!((total - 30.0 * times.len() as f64).abs() < 1e-6, "moved {total}");
    }

    #[test]
    fn jittered_sixty_hertz_input_moves_evenly() {
        // Reports about 16.7 ms apart with 2 ms of jitter, frames every 8.33 ms: every frame of the
        // gesture after the rate is known moves about the same distance (no double step, no stall).
        let period = 1.0 / 120.0;
        let mut smoother = ScrollSmoother::new(Smoothing::Auto);
        let jitter = [0.0, 0.002, -0.002, 0.0015, -0.001, 0.002, -0.002, 0.001, 0.0, -0.0015, 0.002, -0.002];
        let mut steps = Vec::new();
        let mut frame = 0.0;
        let mut next_event = 0;
        for _ in 0..90 {
            frame += period;
            while next_event < 40 && next_event as f64 / 60.0 + jitter[next_event % jitter.len()] <= frame - period * 0.5 {
                let time = next_event as f64 / 60.0 + jitter[next_event % jitter.len()];
                smoother.push(time, 40.0, period);
                next_event += 1;
            }
            steps.push(smoother.advance(frame, period));
        }
        // Skip the first events (the rate is not known yet) and the end (the input stopped).
        let middle = &steps[12..70];
        let mean = middle.iter().sum::<f64>() / middle.len() as f64;
        for (index, step) in middle.iter().enumerate() {
            assert!((step - mean).abs() < mean * 0.35, "frame {index}: step {step:.1} against mean {mean:.1}: {middle:?}");
        }
    }

    #[test]
    fn spreading_is_capped() {
        let deltas = vec![2.0; 6];
        let (_, smoother) = run(Smoothing::Auto, &deltas, 0.25, 260);
        assert!(smoother.delay_report().2 <= 1000.0 * (MAX_SPREAD - P) + 1e-6);
    }

    #[test]
    fn a_reversal_is_followed_at_once_and_totals_match() {
        let mut deltas = vec![5.0; 30];
        deltas.extend(vec![-5.0; 30]);
        let (steps, _) = run(Smoothing::Auto, &deltas, P, 70);
        assert_eq!(steps[30], -5.0);
        assert!(steps.iter().sum::<f64>().abs() < 1e-9);
    }

    #[test]
    fn a_skipped_frame_catches_up_instead_of_losing_distance() {
        let mut smoother = ScrollSmoother::new(Smoothing::Auto);
        smoother.push(0.0, 6.0, P);
        smoother.push(1.0 / 60.0, 6.0, P);
        let first = smoother.advance(1.0 / 60.0 + 0.001, P);
        // The next refresh is skipped; the one after shows the rest.
        let later = smoother.advance(1.0 / 60.0 + 0.001 + 2.0 * P, P);
        assert!((first + later - 12.0).abs() < 1e-9);
        assert!(!smoother.is_active());
    }

    #[test]
    fn cancel_drops_what_was_not_drawn() {
        let mut smoother = ScrollSmoother::new(Smoothing::Auto);
        smoother.push(0.0, 4.0, P);
        smoother.push(0.1, 4.0, P);
        smoother.advance(0.101, P);
        assert!(smoother.is_active());
        assert!(smoother.outstanding() > 0.0);
        smoother.cancel();
        assert!(!smoother.is_active());
        assert_eq!(smoother.advance(0.2, P), 0.0);
    }

    fn lock_changes(profile: &ScrollProfile) -> (usize, f64, f64) {
        let mut lock = AxisLock::new();
        let (mut passed_x, mut passed_y) = (0.0, 0.0);
        for (index, tick) in Playback::new(profile).enumerate() {
            let time = index as f64 * profile.interval;
            let Some(report) = tick.report else { continue };
            match report.phase {
                GesturePhase::Began => lock.set_fingers_down(true, time),
                GesturePhase::Ended => lock.set_fingers_down(false, time),
                _ => {}
            }
            let (dx, dy) = lock.filter(time, report.delta_x, report.delta, report.momentum != MomentumPhase::None);
            passed_x += dx.abs();
            passed_y += dy.abs();
        }
        (lock.changes(), passed_x, passed_y)
    }

    #[test]
    fn a_wandering_diagonal_does_not_change_axis() {
        let (changes, x, y) = lock_changes(&ScrollProfile::wander(3.0));
        assert_eq!(changes, 0);
        assert_eq!(x, 0.0);
        assert!(y > 0.0);
    }

    #[test]
    fn sideways_drift_of_a_vertical_gesture_is_dropped() {
        let (changes, x, _) = lock_changes(&ScrollProfile::diagonal(360.0, 3.0));
        assert_eq!((changes, x), (0, 0.0));
    }

    #[test]
    fn a_sustained_turn_changes_axis_once() {
        let mut lock = AxisLock::new();
        lock.set_fingers_down(true, 0.0);
        let mut time = 0.0;
        for _ in 0..30 {
            assert_eq!(lock.filter(time, 0.5, -6.0, false), (0.0, -6.0));
            time += 1.0 / 60.0;
        }
        let mut horizontal = 0.0;
        for _ in 0..30 {
            horizontal += lock.filter(time, 6.0, 0.5, false).0;
            time += 1.0 / 60.0;
        }
        assert_eq!(lock.changes(), 1);
        assert_eq!(lock.axis(), Some(Axis::Horizontal));
        assert!(horizontal > 100.0);
    }

    #[test]
    fn momentum_keeps_the_axis_and_a_rest_starts_over() {
        let mut lock = AxisLock::new();
        lock.set_fingers_down(true, 0.0);
        lock.filter(0.0, 0.0, -8.0, false);
        lock.set_fingers_down(false, 0.02);
        assert_eq!(lock.filter(0.03, 9.0, -1.0, true), (0.0, -1.0));
        // A new touch after a rest may choose the other axis.
        lock.set_fingers_down(true, 1.0);
        assert_eq!(lock.filter(1.0, 7.0, 1.0, false), (7.0, 0.0));
        assert_eq!(lock.changes(), 0);
    }
}
