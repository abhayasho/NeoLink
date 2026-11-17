//! Synthetic trackpad gestures for the benchmark.
//!
//! These are the profiles of `Sources/Rendering/InteractionBenchmark.swift` (`ScrollProfile`), formula for
//! formula, so the Rust app is driven by the same input as the Swift app's reports. Deltas are in points;
//! positive moves the content toward the top.

use std::f64::consts::PI;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GesturePhase {
    /// No finger phase (a momentum event, or a classic wheel).
    None,
    Began,
    Changed,
    Ended,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MomentumPhase {
    None,
    Began,
    Changed,
    Ended,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ProfileEvent {
    pub delta: f64,
    pub delta_x: f64,
    pub phase: GesturePhase,
    pub momentum: MomentumPhase,
}

impl ProfileEvent {
    fn finger(delta: f64, phase: GesturePhase) -> ProfileEvent {
        ProfileEvent { delta, delta_x: 0.0, phase, momentum: MomentumPhase::None }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ScrollProfile {
    pub events: Vec<ProfileEvent>,
    /// Seconds between events.
    pub interval: f64,
    /// A trackpad reports nothing while the finger has not moved a whole point: skip such events
    /// instead of delivering empty ones (which would also keep telling the app the gesture is alive).
    pub skips_empty_reports: bool,
}

fn phase_at(index: usize, count: usize) -> GesturePhase {
    if index == 0 {
        GesturePhase::Began
    } else if index + 1 == count {
        GesturePhase::Ended
    } else {
        GesturePhase::Changed
    }
}

impl ScrollProfile {
    fn new(events: Vec<ProfileEvent>, interval: f64) -> ScrollProfile {
        ScrollProfile { events, interval, skips_empty_reports: false }
    }

    /// A finger creeping at 4 to 24 points per second: one-point reports 40 to 250 ms apart, fingers down
    /// throughout.
    pub fn crawl(seconds: f64, toward_top: bool) -> ScrollProfile {
        let count = (seconds * 120.0) as usize;
        let sign = if toward_top { 1.0 } else { -1.0 };
        let events = (0..count)
            .map(|i| {
                let speed = 14.0 + 10.0 * (i as f64 / 120.0 * 2.0 * PI * 0.35).sin();
                let phase = if i + 1 == count { GesturePhase::Ended } else { GesturePhase::Changed };
                ProfileEvent::finger(sign * speed / 120.0, phase)
            })
            .collect();
        let mut profile = ScrollProfile::new(events, 1.0 / 120.0);
        profile.skips_empty_reports = true;
        profile
    }

    /// Mostly vertical at 60 Hz reports, drifting sideways by up to 35% of the vertical motion.
    pub fn diagonal(points_per_second: f64, seconds: f64) -> ScrollProfile {
        let count = (seconds * 60.0) as usize;
        let step = points_per_second / 60.0;
        let events = (0..count)
            .map(|i| ProfileEvent {
                delta: -step,
                delta_x: 0.35 * step * (i as f64 / 9.0).sin(),
                phase: phase_at(i, count),
                momentum: MomentumPhase::None,
            })
            .collect();
        ScrollProfile::new(events, 1.0 / 60.0)
    }

    /// A finger wandering around 45 degrees at 60 Hz: each axis leads for three reports at a time.
    pub fn wander(seconds: f64) -> ScrollProfile {
        let count = (seconds * 60.0) as usize;
        let events = (0..count)
            .map(|i| {
                let sideways = (i / 3) % 2 == 1;
                ProfileEvent {
                    delta: if sideways { -3.0 } else { -9.0 },
                    delta_x: if sideways { -9.0 } else { -3.0 },
                    phase: phase_at(i, count),
                    momentum: MomentumPhase::None,
                }
            })
            .collect();
        ScrollProfile::new(events, 1.0 / 60.0)
    }

    /// Speed changing between 120 and 900 points per second about once a second, 60 Hz reports.
    pub fn swell(seconds: f64, toward_top: bool) -> ScrollProfile {
        let count = (seconds * 60.0) as usize;
        let sign = if toward_top { 1.0 } else { -1.0 };
        let events = (0..count)
            .map(|i| {
                let speed = 510.0 + 390.0 * (i as f64 / 60.0 * 2.0 * PI * 1.1).sin();
                ProfileEvent::finger(sign * speed / 60.0, phase_at(i, count))
            })
            .collect();
        ScrollProfile::new(events, 1.0 / 60.0)
    }

    /// Sideways motion at 60 Hz reports: right, then back left.
    pub fn horizontal(points_per_second: f64, seconds: f64) -> ScrollProfile {
        let per_direction = (seconds * 30.0) as usize;
        let step = points_per_second / 60.0;
        let mut events = Vec::with_capacity(per_direction * 2);
        for dx in [-step, step] {
            for i in 0..per_direction {
                events.push(ProfileEvent {
                    delta: 0.0,
                    delta_x: dx,
                    phase: phase_at(i, per_direction),
                    momentum: MomentumPhase::None,
                });
            }
        }
        ScrollProfile::new(events, 1.0 / 60.0)
    }

    /// Constant speed at the 60 Hz report rate of a moving finger, one direction then the other.
    pub fn steady60(points_per_second: f64, seconds: f64, toward_top_first: bool) -> ScrollProfile {
        let per_direction = (seconds * 30.0) as usize;
        let step = if toward_top_first { 1.0 } else { -1.0 } * points_per_second / 60.0;
        let mut events = Vec::with_capacity(per_direction * 2);
        for delta in [step, -step] {
            for i in 0..per_direction {
                events.push(ProfileEvent::finger(delta, phase_at(i, per_direction)));
            }
        }
        ScrollProfile::new(events, 1.0 / 60.0)
    }

    /// Constant speed with a report every 1/120 s, one direction then the other.
    pub fn steady(points_per_second: f64, seconds: f64, toward_top_first: bool) -> ScrollProfile {
        let per_direction = (seconds * 60.0) as usize;
        let step = points_per_second / 120.0;
        let first = if toward_top_first { step } else { -step };
        let mut events = Vec::with_capacity(per_direction * 2);
        for delta in [first, -first] {
            for i in 0..per_direction {
                events.push(ProfileEvent::finger(delta, phase_at(i, per_direction)));
            }
        }
        ScrollProfile::new(events, 1.0 / 120.0)
    }

    /// A quick swipe, then macOS-style momentum decaying by a constant factor per event.
    pub fn flick(toward_top: bool) -> ScrollProfile {
        let sign = if toward_top { 1.0 } else { -1.0 };
        let mut events: Vec<ProfileEvent> = [8.0, 16.0, 22.0, 24.0, 22.0]
            .iter()
            .enumerate()
            .map(|(i, d)| {
                ProfileEvent::finger(sign * d, if i == 0 { GesturePhase::Began } else { GesturePhase::Changed })
            })
            .collect();
        events.push(ProfileEvent::finger(0.0, GesturePhase::Ended));
        let mut delta = 20.0;
        let mut first = true;
        while delta > 0.25 {
            events.push(ProfileEvent {
                delta: sign * delta,
                delta_x: 0.0,
                phase: GesturePhase::None,
                momentum: if first { MomentumPhase::Began } else { MomentumPhase::Changed },
            });
            delta *= 0.965;
            first = false;
        }
        events.push(ProfileEvent {
            delta: 0.0,
            delta_x: 0.0,
            phase: GesturePhase::None,
            momentum: MomentumPhase::Ended,
        });
        ScrollProfile::new(events, 1.0 / 120.0)
    }

    /// Down, then up again within one gesture.
    pub fn reversal() -> ScrollProfile {
        let mut events = Vec::with_capacity(121);
        for i in 0..60 {
            events.push(ProfileEvent::finger(-5.0, if i == 0 { GesturePhase::Began } else { GesturePhase::Changed }));
        }
        for _ in 0..60 {
            events.push(ProfileEvent::finger(5.0, GesturePhase::Changed));
        }
        events.push(ProfileEvent::finger(0.0, GesturePhase::Ended));
        ScrollProfile::new(events, 1.0 / 120.0)
    }

    pub fn duration(&self) -> f64 {
        self.events.len() as f64 * self.interval
    }
}

/// What one tick of a profile delivers.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Tick {
    /// The finger's exact position after this tick, in points (the continuous ideal).
    pub ideal_points: f64,
    pub ideal_points_x: f64,
    /// The event to deliver, or `None` when the finger moved less than a whole point and the profile
    /// skips empty reports.
    pub report: Option<Report>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Report {
    /// Whole points, as a trackpad reports them.
    pub delta: f64,
    pub delta_x: f64,
    pub phase: GesturePhase,
    pub momentum: MomentumPhase,
}

/// Turns a profile into deliverable events. Like AppKit's synthesized continuous deltas, reports carry
/// whole points; the fraction is carried so the delivered total matches the profile, while the ideal
/// position stays continuous (so comparisons include that rounding of up to half a point).
pub struct Playback<'a> {
    profile: &'a ScrollProfile,
    index: usize,
    position: f64,
    position_x: f64,
    carried: f64,
    carried_x: f64,
    began: bool,
}

impl<'a> Playback<'a> {
    pub fn new(profile: &'a ScrollProfile) -> Playback<'a> {
        Playback { profile, index: 0, position: 0.0, position_x: 0.0, carried: 0.0, carried_x: 0.0, began: false }
    }
}

impl Iterator for Playback<'_> {
    type Item = Tick;

    fn next(&mut self) -> Option<Tick> {
        let step = *self.profile.events.get(self.index)?;
        self.index += 1;
        self.carried += step.delta;
        let whole = self.carried.trunc();
        self.carried -= whole;
        self.carried_x += step.delta_x;
        let whole_x = self.carried_x.trunc();
        self.carried_x -= whole_x;
        self.position += step.delta;
        self.position_x += step.delta_x;
        let empty = whole == 0.0 && whole_x == 0.0;
        if self.profile.skips_empty_reports
            && empty
            && step.phase == GesturePhase::Changed
            && step.momentum == MomentumPhase::None
        {
            return Some(Tick { ideal_points: self.position, ideal_points_x: self.position_x, report: None });
        }
        // The first report of a gesture carries the "began" phase, whichever tick it falls on.
        let phase = if self.profile.skips_empty_reports && !self.began && step.phase == GesturePhase::Changed {
            GesturePhase::Began
        } else {
            step.phase
        };
        self.began = true;
        Some(Tick {
            ideal_points: self.position,
            ideal_points_x: self.position_x,
            report: Some(Report { delta: whole, delta_x: whole_x, phase, momentum: step.momentum }),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delivered_total_matches_profile_within_a_point() {
        for profile in [
            ScrollProfile::crawl(5.0, false),
            ScrollProfile::swell(3.0, true),
            ScrollProfile::flick(true),
            ScrollProfile::steady60(360.0, 3.0, true),
            ScrollProfile::diagonal(360.0, 3.0),
        ] {
            let mut delivered = 0.0;
            let mut ideal = 0.0;
            for tick in Playback::new(&profile) {
                ideal = tick.ideal_points;
                if let Some(report) = tick.report {
                    delivered += report.delta;
                    assert_eq!(report.delta, report.delta.trunc());
                }
            }
            assert!((delivered - ideal).abs() < 1.0, "delivered {delivered} ideal {ideal}");
        }
    }

    #[test]
    fn crawl_reports_are_sparse_and_begin_once() {
        let profile = ScrollProfile::crawl(5.0, false);
        let ticks: Vec<Tick> = Playback::new(&profile).collect();
        let reports: Vec<(usize, Report)> =
            ticks.iter().enumerate().filter_map(|(i, t)| t.report.map(|r| (i, r))).collect();
        assert_eq!(reports.iter().filter(|(_, r)| r.phase == GesturePhase::Began).count(), 1);
        assert_eq!(reports.first().unwrap().1.phase, GesturePhase::Began);
        // 4 to 24 points per second means 5 to 30 ticks of 1/120 s between one-point reports.
        let gaps: Vec<usize> = reports.windows(2).map(|w| w[1].0 - w[0].0).collect();
        assert!(gaps.iter().all(|g| (4..=31).contains(g)), "{gaps:?}");
        assert!(reports.len() > 40 && reports.len() < 100);
    }

    #[test]
    fn flick_has_finger_then_momentum() {
        let profile = ScrollProfile::flick(false);
        assert_eq!(profile.events[0].phase, GesturePhase::Began);
        assert_eq!(profile.events[5].phase, GesturePhase::Ended);
        assert_eq!(profile.events[6].momentum, MomentumPhase::Began);
        assert_eq!(profile.events.last().unwrap().momentum, MomentumPhase::Ended);
        assert!(profile.events.iter().all(|e| e.delta <= 0.0));
    }

    #[test]
    fn steady_profiles_reverse_halfway() {
        let profile = ScrollProfile::steady60(360.0, 2.0, true);
        assert_eq!(profile.events.len(), 120);
        assert_eq!(profile.events[0].delta, 6.0);
        assert_eq!(profile.events[60].delta, -6.0);
        assert_eq!(profile.events[59].phase, GesturePhase::Ended);
        assert_eq!(profile.events[60].phase, GesturePhase::Began);
    }
}
