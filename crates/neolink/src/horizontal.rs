//! Chunked horizontal Neovim scrolling. Screens and their left columns travel together on the ordered
//! UI channel. Between replies only retained rows move; the gutter and status line never translate.
use crate::{clock, frame::Next};
use neolink_core::scroll::{ScrollSmoother, Smoothing};
use neolink_nvim::{
    client::{Client, HorizontalFrame},
    grid::Screen,
};

pub struct Horizontal {
    serial: u64,
    session: Option<Session>,
    pub drawn: f64,
    pub received: f64,
}

struct Session {
    current: Screen,
    window: Option<HorizontalFrame>,
    // At most two previous immutable screens, never copies of mutable grid storage.
    previous: Vec<(Screen, u64)>,
    position: f64,
    smoother: ScrollSmoother,
    pending: Option<(u64, i64, f64)>,
    mouse: (usize, usize),
    width: f64,
    direction: i64,
    last_input: f64,
    released: bool,
    settling: bool,
    highest: Option<f64>,
    /// Recent drawn speed in columns per second (decays), so fast flicks ask Neovim further ahead.
    speed: f64,
}

/// One non-overlapping strip, in device pixels relative to the text band's left edge.
#[derive(Debug, PartialEq)]
pub struct Band {
    pub source: usize,
    pub start: f32,
    pub end: f32,
    pub translation: f32,
}

/// Oldest artwork first: it is already in the GPU cache. Fill only its exposed edges from newer rows.
/// All edges and translations are integral device pixels; no sampling/stretching a previous image.
pub fn bands(origins: &[u64], position: f64, cell: f64, width: f32) -> Vec<Band> {
    let mut uncovered = vec![(0.0f32, width)];
    let mut result = Vec::new();
    for (source, origin) in origins.iter().enumerate() {
        let translation = (*origin as f64 * cell - position).round() as f32;
        let mut remaining = Vec::new();
        for (start, end) in uncovered {
            let a = start.max(translation);
            let b = end.min(translation + width);
            if a < b {
                result.push(Band {
                    source,
                    start: a,
                    end: b,
                    translation,
                });
                if start < a {
                    remaining.push((start, a));
                }
                if b < end {
                    remaining.push((b, end));
                }
            } else {
                remaining.push((start, end));
            }
        }
        uncovered = remaining;
    }
    result
}

impl Horizontal {
    pub fn new() -> Self {
        Self {
            serial: 0,
            session: None,
            drawn: 0.0,
            received: 0.0,
        }
    }
    pub fn active(&self) -> bool {
        self.session.is_some()
    }
    pub fn clear(&mut self) {
        self.session = None;
    }

    pub fn input(&mut self, client: &Client, screen: Screen, time: f64, delta: f64, period: f64, cell: f64, row: usize, column: usize) {
        if self.session.is_none() {
            self.session = Some(Session {
                current: screen,
                window: None,
                previous: Vec::new(),
                position: 0.0,
                smoother: ScrollSmoother::new(Smoothing::Auto),
                pending: None,
                mouse: (row, column),
                width: cell,
                direction: 0,
                last_input: clock::now(),
                released: false,
                settling: false,
                highest: None,
                speed: 0.0,
            });
            // Establish the geometry and left column without moving anything.
            self.send(client, 0, true);
        }
        let session = self.session.as_mut().unwrap();
        session.smoother.push(time, -delta, period);
        session.direction = if delta < 0.0 { 1 } else { -1 };
        session.last_input = clock::now();
        session.released = false;
        self.received += delta;
    }

    pub fn release(&mut self) {
        if let Some(session) = &mut self.session {
            session.released = true;
        }
    }

    fn send(&mut self, client: &Client, amount: i64, relative: bool) {
        self.serial += 1;
        if let Some(session) = &mut self.session {
            if std::env::var_os("NEOLINK_HSCROLL_TRACE").is_some() {
                eprintln!(
                    "hscroll send {} {amount} relative={relative} position={} drawn={}",
                    self.serial, session.position, self.drawn
                );
            }
            session.pending = Some((self.serial, amount, clock::now()));
            if client
                .horizontal_scroll(self.serial, session.mouse.0, session.mouse.1, amount, relative)
                .is_err()
            {
                self.session = None;
            }
        }
    }

    /// Before input, a resize, or a switch: queue the nearest shown column before the next command.
    /// Keep the composed view until the ordered settling answer; never flash the ahead-of-fingers
    /// screen between the key press and its redraw. Input is queued after this command on the socket.
    pub fn finish(&mut self, client: &Client) {
        if let Some(session) = &mut self.session {
            if session.settling {
                return;
            }
            if session.window.is_none() {
                self.session = None;
                return;
            }
            session.settling = true;
            session.smoother.cancel();
            let target = (self.drawn / session.width).round().max(0.0) as i64;
            self.send(client, target, false);
        }
    }

    pub fn advance(&mut self, client: &Client, display: f64, period: f64) -> Next {
        let Some(session) = &mut self.session else { return Next::Idle };
        let now = clock::now();
        if let Some((token, target, sent)) = session.pending {
            let answer = client.with_state(|state| state.horizontal.as_ref().filter(|a| a.token == token).cloned());
            if let Some(answer) = answer {
                if std::env::var_os("NEOLINK_HSCROLL_TRACE").is_some() {
                    eprintln!(
                        "hscroll ack {token} {} -> {} generation={}",
                        answer.before, answer.after, answer.screen.generation
                    );
                }
                // Multi-window layouts and wrapped grids retain Neovim's stepped path. Never translate
                // a gutter, popup or neighbouring split using another window's coordinates.
                if answer.column != 0
                    || answer.row != 0
                    || answer.width != answer.screen.columns
                    || answer.height != answer.screen.rows.len().saturating_sub(1)
                    || answer.gutter >= answer.width
                    || answer.screen.columns != session.current.columns
                    || answer.screen.rows.len() != session.current.rows.len()
                    || answer.screen.style_epoch != session.current.style_epoch
                {
                    self.session = None;
                    return Next::Idle;
                }
                if let Some(old) = &session.window {
                    if old.after != answer.after {
                        session.previous.push((session.current.clone(), old.after));
                        if session.previous.len() > 2 {
                            session.previous.remove(0);
                        }
                    }
                    if answer.after < target.max(0) as u64 && session.direction > 0 {
                        session.highest = Some(answer.after as f64 * session.width);
                    }
                } else {
                    session.position = answer.before as f64 * session.width;
                }
                session.current = answer.screen.clone();
                session.window = Some(answer);
                session.pending = None;
                if session.settling {
                    self.session = None;
                    return Next::Idle;
                }
            } else if now - sent > 0.5 {
                self.finish(client);
                self.clear();
                return Next::Idle;
            }
        }
        let session = self.session.as_mut().unwrap();
        let Some(window) = &session.window else {
            return Next::At(now + 0.5);
        };
        // A spontaneous redraw (edit, diagnostics, popup) invalidates detached row artwork. Replies
        // still in flight are held until their ordered acknowledgement instead of guessing an origin.
        if session.pending.is_none()
            && client
                .with_state(|state| state.screen.style_epoch != session.current.style_epoch || state.screen.rows != session.current.rows)
        {
            if std::env::var_os("NEOLINK_HSCROLL_TRACE").is_some() {
                eprintln!(
                    "hscroll spontaneous redraw {} -> {}",
                    session.current.generation,
                    client.with_state(|s| s.screen.generation)
                );
            }
            self.finish(client);
            return Next::Idle;
        }
        let step = session.smoother.advance(display, period);
        session.position += step;
        let frame_speed = step.abs() / session.width / period.max(1e-3);
        session.speed = frame_speed.max(session.speed * 0.85);
        let bounded = session.position.clamp(0.0, session.highest.unwrap_or(f64::MAX));
        if bounded != session.position {
            session.smoother.cancel();
            session.position = bounded;
        }
        let mut low = window.after;
        let mut high = window.after;
        for (_, left) in &session.previous {
            low = low.min(*left);
            high = high.max(*left);
        }
        self.drawn = session
            .position
            .clamp(low as f64 * session.width, high as f64 * session.width)
            .round();
        let chunk = ((window.width - window.gutter) / 3).clamp(4, 24) as i64;
        let idle = (session.released && now - session.last_input > 0.04) || now - session.last_input > 1.0;
        if idle && !session.smoother.is_active() && session.pending.is_none() {
            // Settle to the nearest complete cell after momentum, leaving Neovim's own screen at rest.
            session.settling = true;
            let target = (self.drawn / session.width).round() as i64;
            self.send(client, target, false);
            return Next::Soon;
        }
        if session.pending.is_none() && !session.settling {
            let current = self.drawn / session.width;
            let left = window.after as f64;
            // The text cannot be drawn past the newest screen, so ask while the distance already
            // received (and what the current speed covers in a Neovim round trip) still fits in the
            // lead. A fast flick otherwise held, then jumped several columns when the answer came.
            let text = (window.width - window.gutter).max(1) as f64;
            let outstanding = (session.smoother.outstanding() / session.width).abs();
            let lead = (chunk as f64 / 2.0).max(outstanding + session.speed * 0.06).min(text * 0.6);
            let reach = (chunk as f64).max(lead + session.speed * 0.04).min(text * 0.6).round() as i64;
            let target = if session.direction > 0
                && left - current < lead
                && session.highest.is_none_or(|limit| left * session.width < limit)
            {
                // Each screen must overlap the previous one for the bands to cover the text.
                Some((current.ceil() as i64 + reach).min(window.after as i64 + text as i64 - 1))
            } else if session.direction < 0 && current - left < lead && left > 0.0 {
                Some((current.floor() as i64 - reach).max(0).max(window.after as i64 - text as i64 + 1))
            } else {
                None
            };
            if let Some(target) = target {
                self.send(client, target, false);
            }
        }
        let session = self.session.as_ref().unwrap();
        if session.smoother.is_active() {
            Next::Soon
        } else {
            Next::At(now + if session.released { 0.05 } else { 1.0 })
        }
    }

    pub fn screen(&self) -> Option<&Screen> {
        self.session.as_ref().map(|s| &s.current)
    }

    pub fn layers(&self) -> Option<(&HorizontalFrame, Vec<(&Screen, Band)>)> {
        let session = self.session.as_ref()?;
        let window = session.window.as_ref()?;
        let screens: Vec<_> = session
            .previous
            .iter()
            .map(|(s, col)| (s, *col))
            .chain(std::iter::once((&session.current, window.after)))
            .collect();
        let origins: Vec<_> = screens.iter().map(|(_, col)| *col).collect();
        let layers = bands(
            &origins,
            self.drawn,
            session.width,
            (window.width - window.gutter) as f32 * session.width as f32,
        )
        .into_iter()
        .map(|band| (screens[band.source].0, band))
        .collect();
        Some((window, layers))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn every_pixel_is_covered_exactly_once_during_forward_reverse_and_chunk_changes() {
        for origins in [vec![0, 24], vec![48, 24], vec![0, 24, 48]] {
            for position in *origins.iter().min().unwrap() * 13..=*origins.iter().max().unwrap() * 13 {
                let bands = bands(&origins, position as f64, 13.0, 900.0);
                for pixel in 0..900 {
                    let owners: Vec<_> = bands
                        .iter()
                        .filter(|band| pixel as f32 >= band.start && (pixel as f32) < band.end)
                        .collect();
                    assert_eq!(owners.len(), 1, "origins={origins:?} position={position} pixel={pixel}");
                    let band = owners[0];
                    // Mapping back to buffer pixels is identical irrespective of which cached screen won.
                    assert_eq!(
                        pixel as f32 - band.translation + origins[band.source] as f32 * 13.0,
                        pixel as f32 + position as f32
                    );
                }
            }
        }
    }
    #[test]
    fn fractional_travel_snaps_only_to_device_pixels() {
        for pixel in 0..240 {
            let layers = bands(&[0, 24], pixel as f64 + 0.25, 10.0, 800.0);
            assert_eq!(layers[0].translation, -(pixel as f32));
            assert_eq!(layers.iter().map(|b| b.end - b.start).sum::<f32>(), 800.0);
        }
    }
}

#[cfg(test)]
mod integration_tests {
    use super::*;
    use std::{
        path::Path,
        time::{Duration, Instant},
    };

    #[test]
    fn real_editor_moves_between_columns_and_settles_before_typing() {
        if std::process::Command::new("nvim").arg("--version").output().is_err() {
            return;
        }
        let file = std::env::temp_dir().join(format!("neolink-horizontal-controller-{}.txt", std::process::id()));
        std::fs::write(&file, ("abcdefghijklmnopqrstuvwxyz".repeat(50) + "\n").repeat(30)).unwrap();
        let config = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Resources/Editor/neolink.lua");
        let client = Client::spawn(Path::new("nvim"), &config, 80, 24, || {}).unwrap();
        client.open(file.to_str().unwrap(), None, 1).unwrap();
        let start = Instant::now();
        while client.with_state(|s| s.selection.as_ref().map(|s| s.0)) != Some(1) {
            assert!(start.elapsed() < Duration::from_secs(5));
            std::thread::sleep(Duration::from_millis(2));
        }
        let mut horizontal = Horizontal::new();
        horizontal.input(&client, client.screen(), clock::now(), -7.0, 1.0 / 120.0, 16.0, 0, 10);
        let start = Instant::now();
        while horizontal.drawn != 7.0 {
            horizontal.advance(&client, clock::now(), 1.0 / 120.0);
            assert!(
                start.elapsed() < Duration::from_secs(5),
                "did not draw the fractional column: {}",
                horizontal.drawn
            );
            std::thread::sleep(Duration::from_millis(2));
        }
        let (_, layers) = horizontal.layers().unwrap();
        assert!(layers.len() >= 2);
        horizontal.finish(&client);
        client.input("typed").unwrap();
        let start = Instant::now();
        while horizontal.active() {
            horizontal.advance(&client, clock::now(), 1.0 / 120.0);
            assert!(start.elapsed() < Duration::from_secs(5));
            std::thread::sleep(Duration::from_millis(2));
        }
        client.call("nvim_eval", vec!["1".into()], Duration::from_secs(5)).unwrap();
        let left = client
            .call("nvim_eval", vec!["winsaveview().leftcol".into()], Duration::from_secs(5))
            .unwrap();
        assert_eq!(left.as_u64(), Some(0));
        let line = client.call("nvim_get_current_line", vec![], Duration::from_secs(5)).unwrap();
        assert!(line.as_str().unwrap().contains("typed"));
        drop(client);
        std::fs::remove_file(file).unwrap();
    }
}
