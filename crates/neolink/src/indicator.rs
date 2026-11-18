//! An overlay scroll indicator: a slim thumb at the right edge of the editor or terminal, shown while
//! the content moves and for a moment after, then faded out. At rest it draws nothing and asks for no
//! frames.

use crate::frame::Next;
use crate::render::{Rect, Scene};

/// Fully visible this long after the last movement, then fading out over `FADE`.
const SHOWN: f64 = 0.8;
const FADE: f64 = 0.35;

#[derive(Default)]
pub struct ScrollIndicator {
    last_motion: f64,
    last_position: Option<f64>,
}

impl ScrollIndicator {
    /// The content's top is at `position` pixels: a change (re)shows the indicator.
    pub fn note(&mut self, position: f64, now: f64) {
        if self.last_position.is_some_and(|last| (last - position).abs() > 0.5) {
            self.last_motion = now;
        }
        self.last_position = Some(position);
    }

    /// 0 (hidden) to 1, at display time `now`.
    pub fn opacity(&self, now: f64) -> f32 {
        let since = now - self.last_motion;
        if self.last_motion == 0.0 || since >= SHOWN + FADE {
            0.0
        } else if since <= SHOWN {
            1.0
        } else {
            (1.0 - (since - SHOWN) / FADE) as f32
        }
    }

    /// The opacity in 16 steps, for the frame signature (a frame is presented only when it changes).
    pub fn level(&self, now: f64) -> u64 {
        (self.opacity(now) * 15.0).round() as u64
    }

    /// Draws the thumb inside `area` for content `content` pixels tall shown `view` pixels at a time,
    /// scrolled to `position`. Returns when the next frame is needed for the fade.
    pub fn draw(&self, scene: &mut Scene, area: Rect, position: f64, content: f64, view: f64, now: f64, scale: f32, period: f64) -> Next {
        let opacity = self.opacity(now);
        if opacity <= 0.0 || content <= view + 1.0 || area.height <= 0.0 {
            return Next::Idle;
        }
        let width = (5.0 * scale).round();
        let inset = (2.0 * scale).round();
        let thumb = ((view / content) as f32 * area.height).clamp(24.0 * scale, area.height);
        let travel = area.height - thumb;
        let fraction = (position / (content - view)).clamp(0.0, 1.0) as f32;
        let rect = Rect::new(area.right() - width - inset, (area.y + travel * fraction).round(), width, thumb.round());
        scene.rounded(rect, width * 0.5, [255, 255, 255, (70.0 * opacity) as u8]);
        let since = now - self.last_motion;
        if since < SHOWN {
            Next::At(self.last_motion + SHOWN)
        } else {
            // Each frame of the fade.
            Next::At(now + period)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shows_on_motion_then_fades_and_stops_asking_for_frames() {
        let mut indicator = ScrollIndicator::default();
        indicator.note(0.0, 1.0);
        assert_eq!(indicator.opacity(1.0), 0.0, "the first position is not motion");
        indicator.note(40.0, 2.0);
        assert_eq!(indicator.opacity(2.5), 1.0);
        let middle = indicator.opacity(2.0 + SHOWN + FADE * 0.5);
        assert!(middle > 0.4 && middle < 0.6);
        assert_eq!(indicator.opacity(2.0 + SHOWN + FADE), 0.0);
        let mut scene = Scene::default();
        let area = Rect::new(0.0, 0.0, 100.0, 400.0);
        assert!(matches!(indicator.draw(&mut scene, area, 0.0, 4000.0, 400.0, 2.0 + SHOWN + FADE + 0.1, 2.0, 1.0 / 120.0), Next::Idle));
        assert!(matches!(indicator.draw(&mut scene, area, 0.0, 4000.0, 400.0, 2.1, 2.0, 1.0 / 120.0), Next::At(_)));
        // Content that fits needs no indicator.
        assert!(matches!(indicator.draw(&mut scene, area, 0.0, 300.0, 400.0, 2.1, 2.0, 1.0 / 120.0), Next::Idle));
    }
}
