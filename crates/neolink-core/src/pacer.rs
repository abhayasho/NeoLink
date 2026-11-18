//! Frame pacing: when the render thread may draw, and for which refresh.
//!
//! The model, measured on macOS with a `CAMetalLayer` presented on commit (PLAN.md, section 5): the
//! compositor latches whatever was committed before a refresh (the *latch*), and that frame reaches the
//! display a fixed number of refreshes later (the *depth*: two for a window, fewer in full screen). So a
//! frame's latency is the wait for its latch plus the depth, and the only parts an application controls
//! are how soon after a change it commits and whether anything queues in front of it.
//!
//! Rules (each one is something docs/RENDERING.md or the spike measured):
//! - A frame is drawn only because something changed; the pacer is never asked otherwise.
//! - At most one frame is committed per latch, so nothing can queue behind the display.
//! - If the coming latch has no frame yet, drawing starts at once: a key press or the first scroll event
//!   does not wait for a tick. If it has one, drawing starts once that latch has passed.
//! - A slot closes `lead` before its latch (the time a frame needs from the decision to draw until its
//!   commit, plus a margin). Input that arrives around the close must not flip between the two sides from
//!   event to event, or one refresh gets no frame and the next gets two events: the decision is sticky
//!   within a small band.
//! - Displayed times feed back. The depth is learned from them (two refreshes for a window, none in full
//!   screen, where the layer is scanned out directly). So is the margin: how long before a refresh a
//!   commit must happen to be latched for it (about 0.3 ms windowed, 2.7 ms in full screen on the machine
//!   this was written on). A frame that was committed in time by the current margin and still came a
//!   refresh late raises it to just above that frame's slack; frames that made it with less lower it.
//! - A frame shown late behind another late frame stood in a queue: three late frames in a row give up
//!   one slot so the queue empties.

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Plan {
    /// Draw now. The frame should be committed before `latch` and is expected on the display at
    /// `display`; sample motion at that time.
    Draw { latch: f64, display: f64 },
    /// The reachable latch already has a frame. Ask again at `until`.
    Wait { until: f64 },
}

const DEPTH_SAMPLES: usize = 24;
const COST_SAMPLES: usize = 8;
const SLACK_SAMPLES: usize = 32;
/// A missed latch stops counting after this many frames: one busy moment must not cost latency forever.
const MISS_MEMORY: u64 = 1800;

#[derive(Clone, Debug)]
pub struct Pacer {
    period: f64,
    /// A time at which the display refreshed.
    anchor: f64,
    margin: f64,
    min_margin: f64,
    max_margin: f64,
    band: f64,
    costs: [f64; COST_SAMPLES],
    cost_count: usize,
    depths: [u32; DEPTH_SAMPLES],
    depth_count: usize,
    last_latch: Option<f64>,
    was_late: bool,
    late_streak: u32,
    /// Slots given up since the last frame that was shown on time.
    drains_in_a_row: u32,
    /// Commit time of the newest frame when a slot was last given up.
    drained_until: f64,
    last_committed: f64,
    initial_margin: f64,
    /// Slacks (latch minus commit) of recent frames that were shown on time.
    good: [f64; SLACK_SAMPLES],
    good_count: usize,
    /// `(slack, frame number)` of recent frames that were committed before their latch and missed it.
    missed: Vec<(f64, u64)>,
    previous_late: bool,
    previous_displayed: f64,
    drained: u64,
    late_frames: u64,
    frames: u64,
}

impl Pacer {
    /// `period`: the display's refresh interval. `margin`: how long before a latch a commit must happen
    /// (first estimate; it is then learned from displayed times, up to half a period).
    pub fn new(period: f64, margin: f64) -> Pacer {
        Pacer {
            period,
            anchor: 0.0,
            margin,
            min_margin: 0.00025,
            max_margin: (period * 0.5).max(margin),
            initial_margin: margin,
            good: [f64::INFINITY; SLACK_SAMPLES],
            good_count: 0,
            missed: Vec::new(),
            previous_late: false,
            previous_displayed: 0.0,
            band: 0.0005,
            costs: [0.0; COST_SAMPLES],
            cost_count: 0,
            depths: [0; DEPTH_SAMPLES],
            depth_count: 0,
            last_latch: None,
            was_late: false,
            late_streak: 0,
            drains_in_a_row: 0,
            drained_until: 0.0,
            last_committed: 0.0,
            drained: 0,
            late_frames: 0,
            frames: 0,
        }
    }

    pub fn period(&self) -> f64 {
        self.period
    }

    /// Time a frame needs between the decision to draw and its commit: the second slowest of the recent
    /// ones (one slow frame does not close every slot earlier; each millisecond here is a millisecond
    /// of average latency).
    pub fn cost(&self) -> f64 {
        let known = self.cost_count.min(COST_SAMPLES);
        let mut recent = [0.0f64; COST_SAMPLES];
        recent[..known].copy_from_slice(&self.costs[..known]);
        recent[..known].sort_by(|a, b| b.partial_cmp(a).unwrap());
        let cost = if known >= 4 { recent[1] } else { recent[0] };
        cost.min(self.period * 0.5)
    }

    /// How long before a latch drawing must start.
    pub fn lead(&self) -> f64 {
        self.cost() + self.margin
    }

    /// Refreshes between a latch and the display, as learned so far (1 before any frame was shown).
    pub fn depth(&self) -> u32 {
        let known = self.depth_count.min(DEPTH_SAMPLES);
        self.depths[..known].iter().copied().min().unwrap_or(1)
    }

    /// `(slots given up to drain a queue, frames shown late, frames reported)`.
    pub fn counters(&self) -> (u64, u64, u64) {
        (self.drained, self.late_frames, self.frames)
    }

    pub fn set_period(&mut self, period: f64) {
        if period > 0.0 && (period - self.period).abs() > 1e-7 {
            self.period = period;
            self.max_margin = (period * 0.5).max(self.min_margin);
            self.margin = self.margin.min(self.max_margin);
            self.reset();
        }
    }

    /// The system reported a refresh at `vblank` and measured the refresh interval as `period`
    /// (Windows, where no frame reports its display time). Moves the grid onto it, keeping what was
    /// learned unless the rate itself changed (another display, a new mode).
    pub fn align(&mut self, vblank: f64, period: f64) {
        if !(period > 0.0) || !(vblank > 0.0) {
            return;
        }
        if (period - self.period).abs() > self.period * 0.01 {
            self.set_period(period);
        } else {
            // A finer measurement of the same rate: a whole-hertz figure (143 for 143.86 Hz) drifts a
            // refresh off the display's grid within a few seconds, so the measured one replaces it.
            self.period = period;
        }
        if let Some(last) = self.last_latch {
            let offset = ((last - vblank) / self.period).round();
            self.last_latch = Some(vblank + offset * self.period);
        }
        self.anchor = vblank;
    }

    /// The first refresh strictly after `time`.
    pub fn next_refresh(&self, time: f64) -> f64 {
        let periods = ((time - self.anchor) / self.period).floor() + 1.0;
        self.anchor + periods * self.period
    }

    fn reachable(&self, now: f64) -> f64 {
        let next = self.next_refresh(now);
        let slack = next - now - self.lead();
        let on_time = if slack >= self.band {
            true
        } else if slack <= -self.band {
            false
        } else {
            !self.was_late
        };
        if on_time {
            next
        } else {
            next + self.period
        }
    }

    pub fn plan(&self, now: f64) -> Plan {
        let latch = self.reachable(now);
        let latch = match self.last_latch {
            Some(last) if latch < last + 0.5 * self.period => {
                // The moment from which the latch after `last` is the reachable one, whatever the band
                // says, but not before `last` itself has passed: a frame committed earlier than that
                // would only wait in line behind the one already committed, showing input a whole
                // refresh older than it could (measured: commit to display 11.6 ms instead of 6.2).
                let until = (last - self.lead() + self.band + 1e-6).max(last + 0.0002);
                if until > now {
                    return Plan::Wait { until };
                }
                last + self.period
            }
            _ => latch,
        };
        Plan::Draw { latch, display: latch + self.depth() as f64 * self.period }
    }

    /// A frame planned at `planned` for `latch` was committed at `committed`.
    pub fn submitted(&mut self, planned: f64, committed: f64, latch: f64) {
        self.was_late = latch > self.next_refresh(planned) + 0.5 * self.period;
        self.last_latch = Some(latch);
        self.last_committed = committed;
        let cost = (committed - planned).max(0.0);
        self.costs[self.cost_count % COST_SAMPLES] = cost;
        self.cost_count += 1;
    }

    /// The frame committed at `committed` for `latch` reached the display at `displayed`.
    pub fn presented(&mut self, committed: f64, latch: f64, displayed: f64) {
        if displayed <= 0.0 {
            return;
        }
        self.frames += 1;
        // Keep the planned latch on the grid when the anchor moves.
        if let Some(last) = self.last_latch {
            let offset = ((last - displayed) / self.period).round();
            self.last_latch = Some(displayed + offset * self.period);
        }
        self.anchor = displayed;
        if latch <= 0.0 {
            return;
        }
        let observed = ((displayed - latch) / self.period).round().max(0.0) as u32;
        let expected = if self.depth_count == 0 { observed } else { self.depth() };
        let slack = latch - committed;
        if observed > expected {
            self.late_frames += 1;
            let queued = self.previous_late && committed < self.previous_displayed;
            self.previous_displayed = displayed;
            if !queued && slack > 0.0 && slack < 0.5 * self.period && observed == expected + 1 {
                // Committed before its refresh and still shown at the next one: the system needed
                // more than `slack`. (A late frame behind a late frame only stood in the queue.)
                self.missed.push((slack, self.frames));
                if self.missed.len() > 6 {
                    self.missed.remove(0);
                }
            }
            self.previous_late = true;
            if committed > self.drained_until {
                // Frames that were already committed when a slot was given up say nothing new.
                self.late_streak += 1;
            }
            if self.late_streak >= 3 {
                // A queue is standing: give up one slot so it empties. (One or two late frames are
                // the compositor's own hiccups: a window's frames are shown a refresh late about one
                // time in thirty whatever their slack, and skipping slots for those costs frames.)
                self.late_streak = 0;
                self.drained += 1;
                self.drains_in_a_row += 1;
                self.drained_until = self.last_committed;
                if let Some(last) = self.last_latch {
                    self.last_latch = Some(last + self.period);
                }
                if self.drains_in_a_row >= 3 {
                    // Giving up slots did not help: it is not a queue, the system's pipeline got
                    // deeper (something is composited over a full-screen window, say).
                    self.depths = [observed; DEPTH_SAMPLES];
                    self.depth_count = DEPTH_SAMPLES;
                    self.drains_in_a_row = 0;
                    self.missed.clear();
                    self.previous_late = false;
                }
            }
            self.update_margin();
            // A late frame says nothing about the depth.
            return;
        }
        self.drains_in_a_row = 0;
        self.previous_late = false;
        self.previous_displayed = displayed;
        self.late_streak = 0;
        self.depths[self.depth_count % DEPTH_SAMPLES] = observed;
        self.depth_count += 1;
        if observed == expected && slack > 0.0 {
            self.good[self.good_count % SLACK_SAMPLES] = slack;
            self.good_count += 1;
        }
        self.update_margin();
    }

    fn update_margin(&mut self) {
        let frames = self.frames;
        self.missed.retain(|miss| frames - miss.1 < MISS_MEMORY);
        let needed = self.missed.iter().map(|miss| miss.0).fold(0.0, f64::max);
        let known_good = self.good.iter().copied().fold(f64::INFINITY, f64::min);
        let margin = if needed > 0.0 {
            // Above the largest slack that was not enough, by more than the band within which a
            // decision may stick to the earlier side. The extra 0.3 ms keeps the number of frames
            // spent finding the limit small.
            needed + self.band + 0.0003
        } else {
            // Nothing has missed: the first estimate, or less if less has been seen to work.
            self.initial_margin.min(known_good)
        };
        self.margin = margin.clamp(self.min_margin, self.max_margin);
    }

    /// The window was hidden, resized or moved to another display: forget what was planned and learned.
    pub fn reset(&mut self) {
        self.last_latch = None;
        self.late_streak = 0;
        self.drains_in_a_row = 0;
        self.was_late = false;
        self.depth_count = 0;
        self.good = [f64::INFINITY; SLACK_SAMPLES];
        self.good_count = 0;
        self.missed.clear();
        self.previous_late = false;
        self.margin = self.initial_margin;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const P: f64 = 1.0 / 120.0;

    fn pacer() -> Pacer {
        Pacer::new(P, 0.003)
    }

    /// Plans at `now` and commits immediately (no drawing cost).
    fn draw(pacer: &mut Pacer, now: f64) -> f64 {
        match pacer.plan(now) {
            Plan::Draw { latch, .. } => {
                pacer.submitted(now, now, latch);
                latch
            }
            Plan::Wait { until } => panic!("expected to draw at {now}, told to wait until {until}"),
        }
    }

    #[test]
    fn an_idle_window_draws_at_once_for_the_next_latch() {
        let mut pacer = pacer();
        let latch = draw(&mut pacer, 10.0 * P + 0.001);
        assert!((latch - 11.0 * P).abs() < 1e-9);
    }

    #[test]
    fn a_change_after_the_slot_closed_is_planned_for_the_latch_after() {
        let mut pacer = pacer();
        let latch = draw(&mut pacer, 11.0 * P - 0.001);
        assert!((latch - 12.0 * P).abs() < 1e-9);
    }

    #[test]
    fn a_second_change_in_the_same_slot_waits_then_takes_the_following_latch() {
        let mut pacer = pacer();
        let first = draw(&mut pacer, 10.0 * P + 0.001);
        let Plan::Wait { until } = pacer.plan(10.0 * P + 0.002) else { panic!("should wait") };
        assert!(until > first && until < first + 0.001, "the next frame starts just after the latch it follows");
        let second = draw(&mut pacer, until);
        assert!((second - first - P).abs() < 1e-9);
    }

    #[test]
    fn the_display_time_is_the_latch_plus_the_learned_depth() {
        let mut pacer = pacer();
        let Plan::Draw { latch, display } = pacer.plan(10.0 * P + 0.001) else { panic!() };
        assert!((display - latch - P).abs() < 1e-9, "one refresh is assumed before anything is known");
        pacer.submitted(10.0 * P + 0.001, 10.0 * P + 0.002, latch);
        pacer.presented(10.0 * P + 0.002, latch, latch + 2.0 * P);
        assert_eq!(pacer.depth(), 2);
        assert_eq!(pacer.counters().1, 0, "the first report sets the depth; it is not late");
        let Plan::Draw { latch, display } = pacer.plan(20.0 * P + 0.001) else { panic!() };
        assert!((display - latch - 2.0 * P).abs() < 1e-9);
    }

    #[test]
    fn drawing_cost_closes_the_slot_earlier() {
        let mut pacer = pacer();
        // Frames that take 2 ms from the decision to the commit.
        for i in 0..4 {
            let now = (10 + i) as f64 * P + 0.001;
            let Plan::Draw { latch, .. } = pacer.plan(now) else { panic!() };
            pacer.submitted(now, now + 0.002, latch);
        }
        assert!((pacer.lead() - 0.005).abs() < 1e-9);
        // 4 ms before a latch is now too late for it.
        let Plan::Draw { latch, .. } = pacer.plan(30.0 * P - 0.004) else { panic!() };
        assert!((latch - 31.0 * P).abs() < 1e-9);
    }

    #[test]
    fn steady_input_gets_one_frame_per_refresh_at_any_phase_despite_jitter() {
        for phase_step in 0..40 {
            let phase = phase_step as f64 * P / 40.0;
            let mut pacer = pacer();
            let mut seed: u64 = 0x9E3779B97F4A7C15 ^ phase_step as u64;
            let mut latches: Vec<f64> = Vec::new();
            let mut waiting: Option<f64> = None;
            let mut merged = 0;
            for i in 0..240 {
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                let jitter = ((seed >> 40) as f64 / (1u64 << 24) as f64 - 0.5) * 0.0008;
                let arrival = 1.0 + i as f64 * P + phase + jitter;
                // A wait that came due before this event draws first.
                if let Some(until) = waiting.take() {
                    if until <= arrival {
                        latches.push(draw(&mut pacer, until));
                    } else {
                        merged += 1; // two events will share the pending frame
                        waiting = Some(until);
                        continue;
                    }
                }
                match pacer.plan(arrival) {
                    Plan::Draw { latch, .. } => {
                        pacer.submitted(arrival, arrival, latch);
                        latches.push(latch);
                    }
                    Plan::Wait { until } => waiting = Some(until),
                }
            }
            assert_eq!(merged, 0, "phase {phase}: events shared a frame");
            // Input whose phase sits on the close of the slot may move from "reachable" to "not
            // reachable" once (one refresh without a frame, which no schedule could have filled); it
            // must then stay there instead of flipping with the jitter.
            let mut skipped = 0;
            for pair in latches.windows(2) {
                let gap = (pair[1] - pair[0]) / P;
                if (gap - 2.0).abs() < 1e-6 {
                    skipped += 1;
                } else {
                    assert!((gap - 1.0).abs() < 1e-6, "phase {phase}: refresh gap {gap}");
                }
            }
            assert!(skipped <= 1, "phase {phase}: {skipped} refreshes without a frame");
        }
    }

    #[test]
    fn three_frames_shown_late_give_up_a_slot() {
        let mut pacer = pacer();
        // Learn a depth of one.
        let learned = draw(&mut pacer, 5.0 * P + 0.001);
        pacer.presented(5.0 * P + 0.001, learned, learned + P);
        let first = draw(&mut pacer, 10.0 * P + 0.001);
        pacer.presented(10.0 * P + 0.001, first, first + 2.0 * P);
        let second = draw(&mut pacer, 11.0 * P + 0.001);
        pacer.presented(11.0 * P + 0.001, second, second + 2.0 * P);
        assert_eq!(pacer.counters().0, 0, "two late frames are not yet a queue");
        let second = draw(&mut pacer, 12.0 * P + 0.001);
        pacer.presented(12.0 * P + 0.001, second, second + 2.0 * P);
        assert_eq!(pacer.counters().0, 1);
        assert_eq!(pacer.counters().1, 3);
        assert_eq!(pacer.depth(), 1, "late frames do not change the depth");
        // The slot after `second` is given up so the queue can empty.
        let third = match pacer.plan(13.0 * P + 0.001) {
            Plan::Draw { latch, .. } => latch,
            Plan::Wait { until } => draw(&mut pacer, until),
        };
        assert!(third >= second + 2.0 * P - 1e-9, "third {third} second {second}");
    }

    #[test]
    fn the_margin_is_learned_from_frames_that_missed_and_frames_that_made_it() {
        // Full screen on the development machine: a commit needs 2.7 ms before the refresh.
        let needs = 0.0027;
        let mut pacer = Pacer::new(P, 0.001);
        let mut seed: u64 = 7;
        let mut late_after_learning = 0;
        for i in 0..400 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let phase = (seed >> 40) as f64 / (1u64 << 24) as f64 * P;
            // Sparse changes at random phases, far enough apart that nothing queues.
            let now = 10.0 + i as f64 * 4.0 * P + phase;
            let Plan::Draw { latch, .. } = pacer.plan(now) else { panic!("sparse changes never wait") };
            pacer.submitted(now, now, latch);
            let made_it = latch - now >= needs;
            pacer.presented(now, latch, if made_it { latch } else { latch + P });
            if i >= 100 && !made_it {
                late_after_learning += 1;
            }
        }
        assert_eq!(pacer.depth(), 0);
        assert!(pacer.lead() > needs && pacer.lead() < needs + 0.0009, "lead {}", pacer.lead());
        assert!(late_after_learning <= 1, "{late_after_learning} frames missed after the limit was found");
        assert!(pacer.counters().1 <= 8, "finding the limit cost {} frames", pacer.counters().1);

        // Windowed: commits half a millisecond before the refresh are fine, and the margin follows down.
        let mut pacer = Pacer::new(P, 0.001);
        for i in 0..40 {
            let now = 10.0 + (i * 4 + 1) as f64 * P - 0.0005;
            let latch = pacer.next_refresh(now);
            pacer.submitted(now, now, latch);
            pacer.presented(now, latch, latch + 2.0 * P);
        }
        assert_eq!(pacer.depth(), 2);
        assert!((pacer.lead() - 0.0005).abs() < 1e-6, "lead {}", pacer.lead());
    }

    /// Draws a frame per refresh for `frames` refreshes; `shown` says when a frame committed for `latch`
    /// reaches the display. Returns the refreshes that got no frame.
    fn run_motion(pacer: &mut Pacer, start: f64, frames: usize, mut shown: impl FnMut(f64) -> f64) -> usize {
        let mut now = start;
        let mut latches = Vec::new();
        // Reports arrive when the frame is displayed, like the real thing.
        let mut pending: Vec<(f64, f64, f64)> = Vec::new();
        while latches.len() < frames {
            pending.retain(|(committed, latch, displayed)| {
                if *displayed <= now {
                    pacer.presented(*committed, *latch, *displayed);
                    false
                } else {
                    true
                }
            });
            match pacer.plan(now) {
                Plan::Draw { latch, .. } => {
                    pacer.submitted(now, now, latch);
                    pending.push((now, latch, shown(latch)));
                    latches.push(latch);
                    now += 0.0003;
                }
                Plan::Wait { until } => now = until.max(now + 1e-5),
            }
        }
        latches.windows(2).map(|pair| ((pair[1] - pair[0]) / P).round() as usize - 1).sum()
    }

    #[test]
    fn a_standing_queue_is_drained_not_adopted() {
        let mut pacer = pacer();
        // Direct scan-out: shown at the latch.
        run_motion(&mut pacer, 10.0 * P + 0.001, 30, |latch| latch);
        assert_eq!(pacer.depth(), 0);
        // A hiccup leaves one frame queued: every frame is shown a refresh late until a slot is skipped.
        let mut backlog = 1.0;
        let mut previous_latch = 0.0;
        let skipped = run_motion(&mut pacer, 50.0 * P + 0.001, 60, |latch| {
            if previous_latch > 0.0 && latch - previous_latch > 1.5 * P {
                backlog = 0.0; // a refresh without a commit let the queue empty
            }
            previous_latch = latch;
            latch + backlog * P
        });
        assert_eq!(pacer.depth(), 0, "the queue must not be taken for the system's depth");
        assert!((1..=2).contains(&skipped), "{skipped} slots given up");
    }

    #[test]
    fn a_lasting_change_of_depth_is_adopted_after_draining_does_not_help() {
        let mut pacer = pacer();
        run_motion(&mut pacer, 10.0 * P + 0.001, 30, |latch| latch);
        assert_eq!(pacer.depth(), 0);
        // Something is composited over the window: two refreshes, whatever is skipped.
        let skipped = run_motion(&mut pacer, 50.0 * P + 0.001, 80, |latch| latch + 2.0 * P);
        assert_eq!(pacer.depth(), 2);
        assert!(skipped <= 4, "{skipped} slots given up before the new depth was accepted");
        let late_before = pacer.counters().1;
        run_motion(&mut pacer, 200.0 * P + 0.001, 20, |latch| latch + 2.0 * P);
        assert_eq!(pacer.counters().1, late_before, "the new depth is no longer late");
    }

    #[test]
    fn aligning_to_reported_refreshes_keeps_one_frame_per_refresh() {
        // The display really runs at 143.86 Hz; the system first said 143. Without alignment the
        // planned grid drifts across the real one and a refresh periodically gets two frames.
        let real = 1.0 / 143.86;
        let mut pacer = Pacer::new(1.0 / 143.0, 0.001);
        pacer.align(1.0 + 0.0021, real);
        assert!((pacer.period() - real).abs() < 1e-12);
        let mut latches = Vec::new();
        let mut now = 1.0 + 0.0025;
        while latches.len() < 600 {
            // A refresh is reported every frame, as the Windows vblank clock does.
            let vblank = 1.0 + 0.0021 + ((now - 1.0021) / real).floor() * real;
            pacer.align(vblank, real);
            match pacer.plan(now) {
                Plan::Draw { latch, .. } => {
                    pacer.submitted(now, now + 0.0004, latch);
                    latches.push(latch);
                    now += 0.0005;
                }
                Plan::Wait { until } => now = until.max(now + 1e-5),
            }
        }
        for pair in latches.windows(2) {
            let gap = (pair[1] - pair[0]) / real;
            assert!((gap - 1.0).abs() < 1e-6, "refresh gap {gap}");
        }
        // Every latch is on the real grid.
        for latch in &latches {
            let phase = ((latch - 1.0021) / real).fract();
            assert!(phase < 1e-6 || phase > 1.0 - 1e-6, "latch {latch} off the grid by {phase}");
        }
    }

    #[test]
    fn aligning_to_another_rate_starts_over() {
        let mut pacer = pacer();
        draw(&mut pacer, 10.0 * P + 0.001);
        pacer.align(2.0, 1.0 / 60.0);
        assert!((pacer.period() - 1.0 / 60.0).abs() < 1e-12);
        assert!((pacer.next_refresh(2.001) - (2.0 + 1.0 / 60.0)).abs() < 1e-9);
    }

    #[test]
    fn the_refresh_grid_follows_presented_times() {
        let mut pacer = pacer();
        pacer.presented(0.0, 0.0, 5.0005);
        let next = pacer.next_refresh(5.0010);
        assert!((next - (5.0005 + P)).abs() < 1e-9);
    }
}
