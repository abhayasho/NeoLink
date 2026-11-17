//! Frame pacing: when the render thread may draw, and for which refresh.
//!
//! Rules (each one is something docs/RENDERING.md measured):
//! - A frame is drawn only because something changed; the pacer is never asked otherwise.
//! - At most one frame is submitted per refresh, so nothing can queue behind the display.
//! - If the coming refresh has no frame yet, drawing starts at once (a key press or the first scroll event
//!   does not wait for a tick). If it has one, drawing starts when the following refresh becomes the
//!   reachable one.
//! - "Reachable" has a cutoff (`lead`: drawing must start that long before a refresh to be shown at it).
//!   Input that arrives around the cutoff must not flip between the two sides from event to event, or one
//!   refresh gets no frame and the next gets two events: the decision is sticky within a small band.
//! - Displayed times feed back: frames shown a refresh later than planned mean a standing queue (skip one
//!   slot to drain it) or too small a lead (raise it); frames shown a refresh earlier lower it.

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Plan {
    /// Draw now. The frame is expected on the display at `target`; sample motion at that time.
    Draw { target: f64 },
    /// The reachable refresh already has a frame. Ask again at `until`.
    Wait { until: f64 },
}

#[derive(Clone, Debug)]
pub struct Pacer {
    period: f64,
    /// A time at which the display refreshed.
    anchor: f64,
    lead: f64,
    min_lead: f64,
    band: f64,
    last_target: Option<f64>,
    was_late: bool,
    late_streak: u32,
    drained: u64,
    late_frames: u64,
    early_frames: u64,
}

impl Pacer {
    /// `period`: the display's refresh interval. `lead`: the first estimate of how long before a refresh
    /// a frame must start to be shown at it.
    pub fn new(period: f64, lead: f64) -> Pacer {
        Pacer {
            period,
            anchor: 0.0,
            lead,
            min_lead: lead.min(0.001),
            band: 0.0006,
            last_target: None,
            was_late: false,
            late_streak: 0,
            drained: 0,
            late_frames: 0,
            early_frames: 0,
        }
    }

    pub fn period(&self) -> f64 {
        self.period
    }

    pub fn lead(&self) -> f64 {
        self.lead
    }

    /// `(slots skipped to drain a queue, frames shown late, frames shown early)`.
    pub fn counters(&self) -> (u64, u64, u64) {
        (self.drained, self.late_frames, self.early_frames)
    }

    pub fn set_period(&mut self, period: f64) {
        if period > 0.0 && (period - self.period).abs() > 1e-7 {
            self.period = period;
            self.lead = self.lead.min(period);
            self.last_target = None;
        }
    }

    /// The first refresh strictly after `time`.
    pub fn next_refresh(&self, time: f64) -> f64 {
        let periods = ((time - self.anchor) / self.period).floor() + 1.0;
        self.anchor + periods * self.period
    }

    fn reachable(&self, now: f64) -> f64 {
        let next = self.next_refresh(now);
        let slack = next - now - self.lead;
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
        let target = self.reachable(now);
        match self.last_target {
            Some(last) if target < last + 0.5 * self.period => {
                // The moment from which the refresh after `last` is the reachable one, whatever the band says.
                let until = last - self.lead + self.band + 1e-6;
                if until <= now {
                    Plan::Draw { target: last + self.period }
                } else {
                    Plan::Wait { until }
                }
            }
            _ => Plan::Draw { target },
        }
    }

    /// A frame planned for `target` was submitted at `now`.
    pub fn submitted(&mut self, now: f64, target: f64) {
        self.was_late = target > self.next_refresh(now) + 0.5 * self.period;
        self.last_target = Some(target);
    }

    /// The frame planned for `target` reached the display at `actual`.
    pub fn presented(&mut self, target: f64, actual: f64) {
        if actual <= 0.0 {
            return;
        }
        // Keep planned targets on the same grid when the anchor moves.
        if let Some(last) = self.last_target {
            let offset = ((last - actual) / self.period).round();
            self.last_target = Some(actual + offset * self.period);
        }
        self.anchor = actual;
        let error = (actual - target) / self.period;
        if error > 0.5 {
            self.late_frames += 1;
            self.late_streak += 1;
            if self.late_streak >= 2 {
                // Either a queue is standing (skip one refresh so it empties) or frames need longer than
                // `lead` (raise it); a repeat of this after the skip keeps raising the lead.
                self.late_streak = 0;
                self.drained += 1;
                self.lead = (self.lead + 0.0005).min(self.period);
                if let Some(last) = self.last_target {
                    self.last_target = Some(last + self.period);
                }
            }
        } else {
            self.late_streak = 0;
            if error < -0.5 {
                self.early_frames += 1;
                self.lead = (self.lead - 0.00025).max(self.min_lead);
            }
        }
    }

    /// The window was hidden or the display changed: forget what was planned.
    pub fn reset(&mut self) {
        self.last_target = None;
        self.late_streak = 0;
        self.was_late = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const P: f64 = 1.0 / 120.0;

    fn pacer() -> Pacer {
        Pacer::new(P, 0.003)
    }

    fn draw(pacer: &mut Pacer, now: f64) -> f64 {
        match pacer.plan(now) {
            Plan::Draw { target } => {
                pacer.submitted(now, target);
                target
            }
            Plan::Wait { until } => panic!("expected to draw at {now}, told to wait until {until}"),
        }
    }

    #[test]
    fn an_idle_window_draws_at_once_for_the_next_refresh() {
        let mut pacer = pacer();
        let target = draw(&mut pacer, 10.0 * P + 0.001);
        assert!((target - 11.0 * P).abs() < 1e-9);
    }

    #[test]
    fn a_change_after_the_cutoff_is_planned_for_the_refresh_after() {
        let mut pacer = pacer();
        let target = draw(&mut pacer, 11.0 * P - 0.001);
        assert!((target - 12.0 * P).abs() < 1e-9);
    }

    #[test]
    fn a_second_change_in_the_same_slot_waits_then_takes_the_following_refresh() {
        let mut pacer = pacer();
        let first = draw(&mut pacer, 10.0 * P + 0.001);
        let Plan::Wait { until } = pacer.plan(10.0 * P + 0.002) else { panic!("should wait") };
        assert!(until > 10.0 * P + 0.002 && until < first);
        let second = draw(&mut pacer, until);
        assert!((second - first - P).abs() < 1e-9);
    }

    #[test]
    fn steady_input_gets_one_frame_per_refresh_at_any_phase_despite_jitter() {
        for phase_step in 0..40 {
            let phase = phase_step as f64 * P / 40.0;
            let mut pacer = pacer();
            let mut seed: u64 = 0x9E3779B97F4A7C15 ^ phase_step as u64;
            let mut targets: Vec<f64> = Vec::new();
            let mut waiting: Option<f64> = None;
            let mut merged = 0;
            for i in 0..240 {
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                let jitter = ((seed >> 40) as f64 / (1u64 << 24) as f64 - 0.5) * 0.0008;
                let arrival = 1.0 + i as f64 * P + phase + jitter;
                // A wait that came due before this event draws first.
                if let Some(until) = waiting.take() {
                    if until <= arrival {
                        targets.push(draw(&mut pacer, until));
                    } else {
                        merged += 1; // two events will share the pending frame
                        waiting = Some(until);
                        continue;
                    }
                }
                match pacer.plan(arrival) {
                    Plan::Draw { target } => {
                        pacer.submitted(arrival, target);
                        targets.push(target);
                    }
                    Plan::Wait { until } => waiting = Some(until),
                }
            }
            assert_eq!(merged, 0, "phase {phase}: events shared a frame");
            // Input whose phase sits on the cutoff may move from "reachable" to "not reachable" once
            // (one refresh without a frame, which no schedule could have filled); it must then stay
            // there instead of flipping with the jitter.
            let mut skipped = 0;
            for pair in targets.windows(2) {
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
    fn frames_shown_late_twice_skip_a_slot_and_raise_the_lead() {
        let mut pacer = pacer();
        let lead = pacer.lead();
        let first = draw(&mut pacer, 10.0 * P + 0.001);
        pacer.presented(first, first + P);
        let second = draw(&mut pacer, 11.0 * P + 0.001);
        pacer.presented(second, second + P);
        assert_eq!(pacer.counters().0, 1);
        assert!(pacer.lead() > lead);
        // The slot after `second` is given up so the queue can empty.
        let third = match pacer.plan(12.0 * P + 0.001) {
            Plan::Draw { target } => target,
            Plan::Wait { until } => draw(&mut pacer, until),
        };
        assert!(third >= second + 2.0 * P - 1e-9, "third {third} second {second}");
    }

    #[test]
    fn frames_shown_early_lower_the_lead_to_its_floor() {
        let mut pacer = Pacer::new(P, 0.004);
        for i in 0..40 {
            let now = 10.0 * P + i as f64 * P + 0.0005;
            let target = draw(&mut pacer, now);
            pacer.presented(target, target - P);
        }
        assert!(pacer.lead() <= 0.001 + 1e-9);
        assert_eq!(pacer.counters().2, 40);
    }

    #[test]
    fn the_refresh_grid_follows_presented_times() {
        let mut pacer = pacer();
        pacer.presented(0.0, 5.0005);
        let next = pacer.next_refresh(5.0010);
        assert!((next - (5.0005 + P)).abs() < 1e-9);
    }
}
