//! Glyphs: shaping and rasterisation with cosmic-text/swash, cached in GPU atlases.
//!
//! The same code runs on every system, so what is verified on one is what the others draw. Monospace
//! cells are a whole number of device pixels wide and tall, so a cell's glyph has exactly one raster
//! phase and never needs resampling.

use cosmic_text::{
    Attrs, Buffer, CacheKey, Family, FontSystem, Metrics, Shaping, Style, SwashCache, SwashContent, Weight,
};
use std::collections::HashMap;

pub const ATLAS_SIZE: u32 = 2048;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpriteKind {
    /// 8-bit coverage, tinted with the text colour.
    Mask,
    /// Premultiplied colour (emoji).
    Color,
}

/// Where a rasterised glyph lives in its atlas, and how to place it.
#[derive(Clone, Copy, Debug)]
pub struct Sprite {
    pub kind: SpriteKind,
    pub atlas_x: u16,
    pub atlas_y: u16,
    pub width: u16,
    pub height: u16,
    /// Offset of the bitmap's left edge from the pen position, in pixels.
    pub left: i16,
    /// Distance from the baseline up to the bitmap's top edge, in pixels.
    pub top: i16,
}

/// A simple shelf packer.
struct Shelves {
    x: u32,
    y: u32,
    row_height: u32,
}

impl Shelves {
    fn new() -> Shelves {
        Shelves { x: 1, y: 1, row_height: 0 }
    }

    fn allocate(&mut self, width: u32, height: u32) -> Option<(u32, u32)> {
        if width + 2 > ATLAS_SIZE || height + 2 > ATLAS_SIZE {
            return None;
        }
        if self.x + width + 1 > ATLAS_SIZE {
            self.x = 1;
            self.y += self.row_height + 1;
            self.row_height = 0;
        }
        if self.y + height + 1 > ATLAS_SIZE {
            return None;
        }
        let origin = (self.x, self.y);
        self.x += width + 1;
        self.row_height = self.row_height.max(height);
        Some(origin)
    }
}

pub struct Atlas {
    pub mask: wgpu::Texture,
    pub color: wgpu::Texture,
    mask_shelves: Shelves,
    color_shelves: Shelves,
}

impl Atlas {
    fn new(device: &wgpu::Device) -> Atlas {
        let make = |label, format| {
            device.create_texture(&wgpu::TextureDescriptor {
                label: Some(label),
                size: wgpu::Extent3d { width: ATLAS_SIZE, height: ATLAS_SIZE, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format,
                usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            })
        };
        Atlas {
            mask: make("glyph masks", wgpu::TextureFormat::R8Unorm),
            color: make("colour glyphs", wgpu::TextureFormat::Rgba8Unorm),
            mask_shelves: Shelves::new(),
            color_shelves: Shelves::new(),
        }
    }

    fn upload(&mut self, queue: &wgpu::Queue, kind: SpriteKind, width: u32, height: u32, data: &[u8]) -> Option<(u32, u32)> {
        let (texture, shelves, bytes) = match kind {
            SpriteKind::Mask => (&self.mask, &mut self.mask_shelves, 1),
            SpriteKind::Color => (&self.color, &mut self.color_shelves, 4),
        };
        let (x, y) = shelves.allocate(width, height)?;
        queue.write_texture(
            wgpu::TexelCopyTextureInfo { texture, mip_level: 0, origin: wgpu::Origin3d { x, y, z: 0 }, aspect: wgpu::TextureAspect::All },
            data,
            wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(width * bytes), rows_per_image: Some(height) },
            wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
        );
        Some((x, y))
    }
}

/// The size of a monospace cell in device pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CellMetrics {
    pub width: f32,
    pub height: f32,
    /// Distance from the top of the cell to the baseline.
    pub baseline: f32,
    pub font_pixels: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct CellKey {
    character: char,
    bold: bool,
    italic: bool,
}

/// A cell's glyph: its sprite and where the pen-relative origin is inside the cell.
#[derive(Clone, Copy, Debug)]
pub struct CellGlyph {
    pub sprite: Sprite,
    /// Pen offset inside the cell from shaping, in pixels.
    pub x: i16,
    pub y: i16,
}

/// A glyph of a laid-out line: its sprite and pen position relative to the line's origin and baseline.
#[derive(Clone, Copy, Debug)]
pub struct LineGlyph {
    pub sprite: Sprite,
    pub x: f32,
    pub y: f32,
}

/// One line of interface text, shaped once and cached.
#[derive(Clone, Debug, Default)]
pub struct ShapedLine {
    pub glyphs: Vec<LineGlyph>,
    pub width: f32,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct LineKey {
    text: String,
    size_bits: u32,
    bold: bool,
    monospace: bool,
}

pub struct TextSystem {
    lines: HashMap<LineKey, std::sync::Arc<ShapedLine>>,
    ui_family: String,
    fonts: FontSystem,
    swash: SwashCache,
    pub atlas: Atlas,
    sprites: HashMap<CacheKey, Option<Sprite>>,
    cells: HashMap<CellKey, Option<CellGlyph>>,
    family: String,
    pub cell: CellMetrics,
    scratch: Buffer,
}

fn monospace_family(fonts: &FontSystem) -> String {
    let preferred: &[&str] = if cfg!(target_os = "macos") {
        &["SF Mono", "Menlo", "Monaco"]
    } else if cfg!(target_os = "windows") {
        &["Cascadia Mono", "Cascadia Code", "Consolas"]
    } else {
        &["DejaVu Sans Mono", "Liberation Mono"]
    };
    for name in preferred {
        if fonts.db().faces().any(|face| face.families.iter().any(|family| family.0 == *name)) {
            return (*name).to_string();
        }
    }
    fonts
        .db()
        .faces()
        .find(|face| face.monospaced)
        .and_then(|face| face.families.first().map(|family| family.0.clone()))
        .unwrap_or_else(|| "monospace".to_string())
}

fn interface_family(fonts: &FontSystem) -> String {
    let preferred: &[&str] = if cfg!(target_os = "macos") {
        &[".AppleSystemUIFont", "SF Pro Text", "SF Pro", "System Font", "Helvetica Neue"]
    } else if cfg!(target_os = "windows") {
        &["Segoe UI Variable Text", "Segoe UI", "Tahoma"]
    } else {
        &["Inter", "Cantarell", "DejaVu Sans"]
    };
    for name in preferred {
        if fonts.db().faces().any(|face| face.families.iter().any(|family| family.0 == *name)) {
            return (*name).to_string();
        }
    }
    "sans-serif".to_string()
}

impl TextSystem {
    /// One line of text in the interface font (or the monospace font), `font_pixels` tall, laid out from
    /// x = 0 with glyph positions in whole pixels vertically and quarter pixels horizontally.
    pub fn line(&mut self, queue: &wgpu::Queue, text: &str, font_pixels: f32, bold: bool, monospace: bool) -> std::sync::Arc<ShapedLine> {
        let key = LineKey { text: text.to_string(), size_bits: font_pixels.to_bits(), bold, monospace };
        if let Some(line) = self.lines.get(&key) {
            return line.clone();
        }
        if self.lines.len() > 4096 {
            self.lines.clear();
        }
        let family = if monospace { self.family.clone() } else { self.ui_family.clone() };
        let mut attrs = Attrs::new().family(Family::Name(&family));
        if bold {
            attrs = attrs.weight(Weight::SEMIBOLD);
        }
        let mut buffer = Buffer::new_empty(Metrics::new(font_pixels, (font_pixels * 1.3).ceil()));
        buffer.set_text(text, &attrs, Shaping::Advanced, None);
        buffer.shape_until_scroll(&mut self.fonts, false);
        let mut shaped = ShapedLine::default();
        let mut physical = Vec::new();
        if let Some(run) = buffer.layout_runs().next() {
            shaped.width = run.line_w;
            physical.extend(run.glyphs.iter().map(|glyph| glyph.physical((0.0, 0.0), 1.0)));
        }
        for glyph in physical {
            let mut cache_key = glyph.cache_key;
            cache_key.y_bin = cosmic_text::SubpixelBin::Zero;
            if let Some(sprite) = self.sprite(queue, cache_key) {
                shaped.glyphs.push(LineGlyph { sprite, x: glyph.x as f32, y: glyph.y as f32 });
            }
        }
        let shaped = std::sync::Arc::new(shaped);
        self.lines.insert(key, shaped.clone());
        shaped
    }

    /// `font_points` at `scale` device pixels per point.
    pub fn new(device: &wgpu::Device, font_points: f32, scale: f32) -> TextSystem {
        let mut fonts = FontSystem::new();
        let family = std::env::var("NEOLINK_FONT").unwrap_or_else(|_| monospace_family(&fonts));
        let scratch = Buffer::new_empty(Metrics::new(16.0, 20.0));
        let ui_family = interface_family(&fonts);
        let mut system = TextSystem {
            lines: HashMap::new(),
            ui_family,
            swash: SwashCache::new(),
            atlas: Atlas::new(device),
            sprites: HashMap::new(),
            cells: HashMap::new(),
            cell: CellMetrics { width: 1.0, height: 1.0, baseline: 1.0, font_pixels: 1.0 },
            family,
            scratch,
            fonts: {
                fonts.db_mut().set_monospace_family("Menlo");
                fonts
            },
        };
        system.set_font_size(font_points, scale);
        system
    }

    pub fn family(&self) -> &str {
        &self.family
    }

    pub fn set_font_size(&mut self, font_points: f32, scale: f32) {
        let font_pixels = (font_points * scale).max(4.0);
        // Line height as the Swift app's terminal: ascent + descent + leading is about 1.2 em.
        let height = (font_pixels * 1.2).ceil();
        self.scratch.set_metrics(Metrics::new(font_pixels, height));
        let attrs = Attrs::new().family(Family::Name(&self.family));
        self.scratch.set_text("M", &attrs, Shaping::Advanced, None);
        self.scratch.shape_until_scroll(&mut self.fonts, false);
        let mut width = font_pixels * 0.6;
        let mut baseline = font_pixels;
        if let Some(run) = self.scratch.layout_runs().next() {
            baseline = run.line_y;
            if let Some(glyph) = run.glyphs.first() {
                width = glyph.w;
            }
        }
        self.cell = CellMetrics { width: width.round().max(1.0), height, baseline: baseline.round(), font_pixels };
        self.cells.clear();
        self.lines.clear();
    }

    fn sprite(&mut self, queue: &wgpu::Queue, key: CacheKey) -> Option<Sprite> {
        if let Some(sprite) = self.sprites.get(&key) {
            return *sprite;
        }
        let sprite = (|| {
            let image = self.swash.get_image_uncached(&mut self.fonts, key)?;
            let (width, height) = (image.placement.width, image.placement.height);
            if width == 0 || height == 0 {
                return None;
            }
            let (kind, data) = match image.content {
                SwashContent::Mask => (SpriteKind::Mask, image.data),
                SwashContent::Color => (SpriteKind::Color, image.data),
                SwashContent::SubpixelMask => {
                    // Not requested; fold to coverage if a font produces it anyway.
                    (SpriteKind::Mask, image.data.chunks_exact(4).map(|p| ((p[0] as u16 + p[1] as u16 + p[2] as u16) / 3) as u8).collect())
                }
            };
            let (x, y) = self.atlas.upload(queue, kind, width, height, &data)?;
            Some(Sprite {
                kind,
                atlas_x: x as u16,
                atlas_y: y as u16,
                width: width as u16,
                height: height as u16,
                left: image.placement.left as i16,
                top: image.placement.top as i16,
            })
        })();
        self.sprites.insert(key, sprite);
        sprite
    }

    /// The glyph for one terminal cell. `None` for blanks and characters no font has.
    pub fn cell_glyph(&mut self, queue: &wgpu::Queue, character: char, bold: bool, italic: bool) -> Option<CellGlyph> {
        if character == ' ' || character == '\0' {
            return None;
        }
        let key = CellKey { character, bold, italic };
        if let Some(glyph) = self.cells.get(&key) {
            return *glyph;
        }
        let mut attrs = Attrs::new().family(Family::Name(&self.family));
        if bold {
            attrs = attrs.weight(Weight::BOLD);
        }
        if italic {
            attrs = attrs.style(Style::Italic);
        }
        let mut text = [0u8; 4];
        self.scratch.set_text(character.encode_utf8(&mut text), &attrs, Shaping::Advanced, None);
        self.scratch.shape_until_scroll(&mut self.fonts, false);
        let physical = self.scratch.layout_runs().next().and_then(|run| run.glyphs.first().map(|glyph| glyph.physical((0.0, 0.0), 1.0)));
        let glyph = physical.and_then(|physical| {
            // Whole-pixel cells: drop the subpixel bin so every cell shares one raster.
            let mut key = physical.cache_key;
            key.x_bin = cosmic_text::SubpixelBin::Zero;
            key.y_bin = cosmic_text::SubpixelBin::Zero;
            self.sprite(queue, key).map(|sprite| CellGlyph { sprite, x: physical.x as i16, y: physical.y as i16 })
        });
        self.cells.insert(key, glyph);
        glyph
    }
}
