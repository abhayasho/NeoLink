//! Drawing helpers for the window's chrome, in the Swift app's units: sizes are points, as in its
//! SwiftUI code, and are turned into whole device pixels here.

use crate::frame::Painter;
use crate::icons::IconWeight;
use crate::render::Rect;
use crate::text::Icon;
use crate::theme::Rgba;

pub struct Ui<'a, 'b> {
    pub painter: &'a mut Painter<'b>,
    pub scale: f32,
}

impl Ui<'_, '_> {
    pub fn px(&self, points: f32) -> f32 {
        (points * self.scale).round()
    }

    pub fn fill(&mut self, rect: Rect, color: Rgba) {
        self.painter.scene.fill_rect(rect, color);
    }

    /// A filled rounded rectangle; `radius` in points.
    pub fn rounded(&mut self, rect: Rect, radius: f32, color: Rgba) {
        let radius = radius * self.scale;
        self.painter.scene.rounded(rect, radius, color);
    }

    /// A one-point outline of a rounded rectangle; `radius` in points.
    pub fn outline(&mut self, rect: Rect, radius: f32, color: Rgba) {
        let (radius, width) = (radius * self.scale, self.px(1.0).max(1.0));
        self.painter.scene.outline(rect, radius, width, color);
    }

    /// A soft shadow under a floating panel.
    pub fn shadow(&mut self, rect: Rect, radius: f32) {
        let radius = radius * self.scale;
        for (grow, alpha) in [(10.0, 10u8), (6.0, 16), (3.0, 24), (1.0, 34)] {
            let grow = grow * self.scale;
            self.painter.scene.rounded(Rect::new(rect.x - grow, rect.y - grow * 0.5, rect.width + 2.0 * grow, rect.height + 2.0 * grow), radius + grow, [0, 0, 0, alpha]);
        }
    }

    /// A one-point line along the bottom of `rect`.
    pub fn line_below(&mut self, rect: Rect, color: Rgba) {
        let thickness = self.px(1.0).max(1.0);
        self.painter.scene.fill(rect.x, rect.bottom() - thickness, rect.width, thickness, color);
    }

    pub fn measure(&mut self, text: &str, points: f32, weight: u16, monospace: bool) -> f32 {
        let pixels = self.px(points);
        self.painter.text.styled_line(self.painter.queue, text, pixels, weight, monospace).width
    }

    /// Text starting at `x`, centred vertically on `center_y`. Returns its width in pixels.
    pub fn text(&mut self, text: &str, x: f32, center_y: f32, points: f32, weight: u16, monospace: bool, color: Rgba) -> f32 {
        let pixels = self.px(points);
        let line = self.painter.text.styled_line(self.painter.queue, text, pixels, weight, monospace);
        let baseline = (center_y + pixels * 0.36).round();
        for glyph in &line.glyphs {
            self.painter.scene.glyph(glyph.sprite, x.round() + glyph.x, baseline + glyph.y, color);
        }
        line.width
    }

    /// Text ending at `right`. Returns its width.
    pub fn text_right(&mut self, text: &str, right: f32, center_y: f32, points: f32, weight: u16, monospace: bool, color: Rgba) -> f32 {
        let width = self.measure(text, points, weight, monospace);
        self.text(text, right - width, center_y, points, weight, monospace, color);
        width
    }

    /// An icon centred on `(center_x, center_y)`. Returns its width in pixels.
    pub fn icon(&mut self, name: &str, points: f32, weight: IconWeight, center_x: f32, center_y: f32, color: Rgba) -> f32 {
        match self.painter.text.icon(self.painter.queue, name, points, weight, self.scale) {
            Icon::Symbol(sprite) => {
                self.painter.scene.sprite(sprite, center_x - sprite.width as f32 * 0.5, center_y - sprite.height as f32 * 0.5, color);
                sprite.width as f32
            }
            Icon::Glyphs(line) => {
                let pixels = self.px(points);
                let baseline = (center_y + pixels * 0.36).round();
                for glyph in &line.glyphs {
                    self.painter.scene.glyph(glyph.sprite, (center_x - line.width * 0.5).round() + glyph.x, baseline + glyph.y, color);
                }
                line.width
            }
        }
    }

    /// `text` shortened in the middle with an ellipsis until it fits `width` pixels.
    pub fn fit_middle(&mut self, text: &str, width: f32, points: f32, weight: u16, monospace: bool) -> String {
        if self.measure(text, points, weight, monospace) <= width {
            return text.to_string();
        }
        let characters: Vec<char> = text.chars().collect();
        let mut count = characters.len();
        while count > 4 {
            let (head, tail) = (count.div_ceil(2), count / 2);
            let candidate: String = characters[..head].iter().chain(std::iter::once(&'\u{2026}')).chain(characters[characters.len() - tail..].iter()).collect();
            if self.measure(&candidate, points, weight, monospace) <= width {
                return candidate;
            }
            count -= 1;
        }
        characters.iter().take(2).chain(std::iter::once(&'\u{2026}')).chain(characters.iter().rev().take(2).collect::<Vec<_>>().into_iter().rev()).collect()
    }
}

/// `color` at `opacity` (0 to 1).
pub fn faded(color: Rgba, opacity: f32) -> Rgba {
    [color[0], color[1], color[2], (color[3] as f32 * opacity) as u8]
}
