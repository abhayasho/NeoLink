//! The one drawing primitive: instanced, pixel-aligned quads (solid fills, glyph masks, colour glyphs).
//!
//! A frame is a list of batches. A batch is a run of instances with a clip rectangle and a translation.
//! Most of a terminal is drawn from *retained rows*: a row of text is turned into instances once, kept in
//! the GPU buffer under a key of its content, and drawn again in later frames with a different
//! translation. Scrolling therefore uploads a few bytes per row, and typing rebuilds one row.

use crate::text::{Sprite, SpriteKind, TextSystem};
use bytemuck::{Pod, Zeroable};
use std::collections::HashMap;

#[repr(C)]
#[derive(Clone, Copy, Debug, Pod, Zeroable)]
pub struct Instance {
    pub position: [f32; 2],
    pub size: [f32; 2],
    pub uv: [f32; 2],
    /// RGBA, not premultiplied, in display (encoded) values.
    pub color: [u8; 4],
    /// 0 = solid, 1 = mask glyph, 2 = colour glyph, 3 = rounded rectangle (`uv` = corner radius and
    /// outline width; width 0 fills it).
    pub kind: u32,
}

impl Instance {
    pub fn fill(x: f32, y: f32, width: f32, height: f32, color: [u8; 4]) -> Instance {
        Instance { position: [x, y], size: [width, height], uv: [0.0, 0.0], color, kind: 0 }
    }

    /// A glyph whose pen position is `(x, baseline)` in pixels.
    pub fn glyph(sprite: Sprite, x: f32, baseline: f32, color: [u8; 4]) -> Instance {
        Instance {
            position: [x + sprite.left as f32, baseline - sprite.top as f32],
            size: [sprite.width as f32, sprite.height as f32],
            uv: [sprite.atlas_x as f32, sprite.atlas_y as f32],
            color,
            kind: match sprite.kind {
                SpriteKind::Mask => 1,
                SpriteKind::Color => 2,
            },
        }
    }
}

/// A rectangle in device pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl Rect {
    pub const fn new(x: f32, y: f32, width: f32, height: f32) -> Rect {
        Rect { x, y, width, height }
    }

    pub fn contains(&self, x: f32, y: f32) -> bool {
        x >= self.x && x < self.x + self.width && y >= self.y && y < self.y + self.height
    }

    pub fn right(&self) -> f32 {
        self.x + self.width
    }

    pub fn bottom(&self) -> f32 {
        self.y + self.height
    }
}

/// Instances per retained row. A row that needs more is drawn without being retained.
pub const ROW_CAPACITY: usize = 640;
/// Retained rows kept; the least recently drawn ones are replaced.
pub const ROW_SLOTS: usize = 384;

#[derive(Clone, Copy)]
struct Slot {
    key: u64,
    length: u32,
    last_used: u64,
}

/// Rows of text kept as GPU instances, addressed by a key of everything that decides their pixels.
pub struct RowCache {
    slots: Vec<Slot>,
    by_key: HashMap<u64, u32>,
    /// Slots whose instances have to be uploaded: `(slot, instances)`.
    uploads: Vec<(u32, Vec<Instance>)>,
    frame: u64,
    /// Rows built since the cache was created, and rows drawn from the cache (for the benchmark).
    pub built: u64,
    pub reused: u64,
}

impl Default for RowCache {
    fn default() -> Self {
        RowCache::new()
    }
}

impl RowCache {
    pub fn new() -> RowCache {
        RowCache { slots: Vec::new(), by_key: HashMap::new(), uploads: Vec::new(), frame: 1, built: 0, reused: 0 }
    }

    /// Everything retained is stale (the font or the atlas changed).
    pub fn clear(&mut self) {
        self.slots.clear();
        self.by_key.clear();
        self.uploads.clear();
    }

    fn next_frame(&mut self) {
        self.frame += 1;
    }

    /// The retained row for `key`, if there is one: `(slot, instance count)`.
    pub fn get(&mut self, key: u64) -> Option<(u32, u32)> {
        let slot = *self.by_key.get(&key)?;
        let entry = &mut self.slots[slot as usize];
        entry.last_used = self.frame;
        self.reused += 1;
        Some((slot, entry.length))
    }

    /// Retains `instances` (positions relative to the row's origin) under `key`. `None` if the row is
    /// too long to retain or every slot is in use by this frame.
    pub fn insert(&mut self, key: u64, instances: &[Instance]) -> Option<(u32, u32)> {
        if instances.len() > ROW_CAPACITY {
            return None;
        }
        let slot = if self.slots.len() < ROW_SLOTS {
            self.slots.push(Slot { key, length: 0, last_used: 0 });
            self.slots.len() as u32 - 1
        } else {
            let (index, oldest) = self.slots.iter().enumerate().min_by_key(|(_, slot)| slot.last_used)?;
            if oldest.last_used >= self.frame {
                return None;
            }
            self.by_key.remove(&oldest.key);
            index as u32
        };
        self.slots[slot as usize] = Slot { key, length: instances.len() as u32, last_used: self.frame };
        self.by_key.insert(key, slot);
        self.uploads.push((slot, instances.to_vec()));
        self.built += 1;
        Some((slot, instances.len() as u32))
    }
}

#[derive(Clone, Copy, Debug)]
struct Batch {
    clip: Option<Rect>,
    offset: [f32; 2],
    /// First instance in the GPU buffer, and how many.
    start: u32,
    count: u32,
    retained: bool,
}

#[derive(Default)]
pub struct Scene {
    /// Instances drawn this frame only (interface chrome, rows too long to retain).
    pub instances: Vec<Instance>,
    batches: Vec<Batch>,
    clip: Option<Rect>,
    /// Instances drawn in this frame, retained ones included.
    pub drawn: usize,
}

impl Scene {
    pub fn clear(&mut self) {
        self.instances.clear();
        self.batches.clear();
        self.clip = None;
        self.drawn = 0;
    }

    /// Everything added from now on is clipped to `clip` (`None`: the whole target).
    pub fn set_clip(&mut self, clip: Option<Rect>) {
        self.clip = clip;
    }

    fn push(&mut self, instance: Instance) {
        let index = self.instances.len() as u32;
        self.instances.push(instance);
        self.drawn += 1;
        match self.batches.last_mut() {
            Some(batch) if !batch.retained && batch.clip == self.clip && batch.offset == [0.0, 0.0] && batch.start + batch.count == index => batch.count += 1,
            _ => self.batches.push(Batch { clip: self.clip, offset: [0.0, 0.0], start: index, count: 1, retained: false }),
        }
    }

    pub fn fill(&mut self, x: f32, y: f32, width: f32, height: f32, color: [u8; 4]) {
        self.push(Instance::fill(x, y, width, height, color));
    }

    /// Where the frame-only instances end now; see `capture`.
    pub fn mark(&self) -> usize {
        self.instances.len()
    }

    /// What was drawn since `mark`, with its clipping, to draw again unchanged in a later frame
    /// (`replay`). Retained rows drawn in between are not included.
    pub fn capture(&self, mark: usize) -> Vec<(Option<Rect>, Vec<Instance>)> {
        self.batches
            .iter()
            // A batch may have begun before the mark (instances with the same clipping join it).
            .filter(|batch| !batch.retained && (batch.start + batch.count) as usize > mark)
            .map(|batch| (batch.clip, self.instances[(batch.start as usize).max(mark)..(batch.start + batch.count) as usize].to_vec()))
            .collect()
    }

    pub fn replay(&mut self, saved: &[(Option<Rect>, Vec<Instance>)]) {
        let clip = self.clip;
        for (saved_clip, instances) in saved {
            self.clip = *saved_clip;
            for instance in instances {
                self.push(*instance);
            }
        }
        self.clip = clip;
    }

    /// A filled rectangle with rounded corners (`radius` in pixels).
    pub fn rounded(&mut self, rect: Rect, radius: f32, color: [u8; 4]) {
        self.push(Instance { position: [rect.x, rect.y], size: [rect.width, rect.height], uv: [radius, 0.0], color, kind: 3 });
    }

    /// The outline of a rounded rectangle, `width` pixels thick, inside `rect`.
    pub fn outline(&mut self, rect: Rect, radius: f32, width: f32, color: [u8; 4]) {
        self.push(Instance { position: [rect.x, rect.y], size: [rect.width, rect.height], uv: [radius, width], color, kind: 3 });
    }

    pub fn fill_rect(&mut self, rect: Rect, color: [u8; 4]) {
        self.fill(rect.x, rect.y, rect.width, rect.height, color);
    }

    /// A glyph whose pen position is `(x, baseline)` in pixels.
    pub fn glyph(&mut self, sprite: Sprite, x: f32, baseline: f32, color: [u8; 4]) {
        self.push(Instance::glyph(sprite, x, baseline, color));
    }

    /// A mask sprite with its top left corner at `(x, y)` (icons).
    pub fn sprite(&mut self, sprite: Sprite, x: f32, y: f32, color: [u8; 4]) {
        self.push(Instance {
            position: [x.round(), y.round()],
            size: [sprite.width as f32, sprite.height as f32],
            uv: [sprite.atlas_x as f32, sprite.atlas_y as f32],
            color,
            kind: 1,
        });
    }

    /// Draws a retained row with its origin at `(x, y)`.
    pub fn retained(&mut self, row: (u32, u32), x: f32, y: f32) {
        if row.1 == 0 {
            return;
        }
        self.drawn += row.1 as usize;
        self.batches.push(Batch { clip: self.clip, offset: [x, y], start: row.0 * ROW_CAPACITY as u32, count: row.1, retained: true });
    }

    /// Draws instances given relative to `(x, y)` without retaining them.
    pub fn translated(&mut self, instances: &[Instance], x: f32, y: f32) {
        for instance in instances {
            let mut moved = *instance;
            moved.position[0] += x;
            moved.position[1] += y;
            self.push(moved);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_capture_replays_everything_drawn_after_the_mark() {
        let mut scene = Scene::default();
        scene.fill(0.0, 0.0, 1.0, 1.0, [1, 0, 0, 255]);
        let mark = scene.mark();
        // Joins the batch begun before the mark.
        scene.fill(1.0, 0.0, 1.0, 1.0, [2, 0, 0, 255]);
        scene.set_clip(Some(Rect::new(0.0, 0.0, 5.0, 5.0)));
        scene.fill(2.0, 0.0, 1.0, 1.0, [3, 0, 0, 255]);
        scene.set_clip(None);
        scene.fill(3.0, 0.0, 1.0, 1.0, [4, 0, 0, 255]);
        let saved = scene.capture(mark);
        let colors: Vec<u8> = saved.iter().flat_map(|(_, instances)| instances.iter().map(|instance| instance.color[0])).collect();
        assert_eq!(colors, vec![2, 3, 4]);
        assert_eq!(saved[1].0, Some(Rect::new(0.0, 0.0, 5.0, 5.0)));
        let mut later = Scene::default();
        later.replay(&saved);
        assert_eq!(later.instances.len(), 3);
        assert_eq!(later.capture(0).len(), 3);
    }
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct BatchUniform {
    viewport: [f32; 2],
    offset: [f32; 2],
}

pub struct Renderer {
    pipeline: wgpu::RenderPipeline,
    bind_group: wgpu::BindGroup,
    /// Retained rows first (`ROW_SLOTS * ROW_CAPACITY` instances), then this frame's instances.
    instances: wgpu::Buffer,
    dynamic_capacity: usize,
    /// The frame-only instances as last uploaded: unchanged chrome is not uploaded again.
    uploaded: Vec<Instance>,
    pub rows: RowCache,
}

const SHADER: &str = r#"
struct Batch { viewport: vec2<f32>, offset: vec2<f32> };
var<immediate> batch: Batch;
@group(0) @binding(0) var masks: texture_2d<f32>;
@group(0) @binding(1) var colors: texture_2d<f32>;

struct Out {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
    @location(2) @interpolate(flat) kind: u32,
    @location(3) local: vec2<f32>,
    @location(4) @interpolate(flat) shape: vec4<f32>,
};

@vertex
fn vertex(@builtin(vertex_index) index: u32, @location(0) position: vec2<f32>, @location(1) size: vec2<f32>,
          @location(2) uv: vec2<f32>, @location(3) color: vec4<f32>, @location(4) kind: u32) -> Out {
    let corner = vec2<f32>(f32(index & 1u), f32(index >> 1u));
    let pixel = position + batch.offset + corner * size;
    var out: Out;
    out.position = vec4<f32>(pixel.x / batch.viewport.x * 2.0 - 1.0, 1.0 - pixel.y / batch.viewport.y * 2.0, 0.0, 1.0);
    out.uv = uv + corner * size;
    out.color = color;
    out.kind = kind;
    out.local = corner * size;
    out.shape = vec4<f32>(size, uv);
    return out;
}

@fragment
fn fragment(in: Out) -> @location(0) vec4<f32> {
    let texel = vec2<i32>(in.uv);
    if (in.kind == 1u) {
        let coverage = textureLoad(masks, texel, 0).r * in.color.a;
        return vec4<f32>(in.color.rgb * coverage, coverage);
    }
    if (in.kind == 2u) {
        return textureLoad(colors, texel, 0) * in.color.a;
    }
    if (in.kind == 3u) {
        // Signed distance to a rounded box, one pixel of antialiasing.
        let half = in.shape.xy * 0.5;
        let radius = min(in.shape.z, min(half.x, half.y));
        let q = abs(in.local - half) - half + vec2<f32>(radius);
        let distance = length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - radius;
        var coverage = clamp(0.5 - distance, 0.0, 1.0);
        if (in.shape.w > 0.0) {
            coverage = coverage * clamp(0.5 + distance + in.shape.w, 0.0, 1.0);
        }
        let alpha = in.color.a * coverage;
        return vec4<f32>(in.color.rgb * alpha, alpha);
    }
    return vec4<f32>(in.color.rgb * in.color.a, in.color.a);
}
"#;

const RETAINED_INSTANCES: usize = ROW_SLOTS * ROW_CAPACITY;

impl Renderer {
    pub fn new(device: &wgpu::Device, text: &TextSystem, format: wgpu::TextureFormat) -> Renderer {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("quads"),
            source: wgpu::ShaderSource::Wgsl(SHADER.into()),
        });
        let texture_entry = |binding| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: false },
                view_dimension: wgpu::TextureViewDimension::D2,
                multisampled: false,
            },
            count: None,
        };
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("quads"),
            entries: &[texture_entry(0), texture_entry(1)],
        });
        let mask_view = text.atlas.mask.create_view(&wgpu::TextureViewDescriptor::default());
        let color_view = text.atlas.color.create_view(&wgpu::TextureViewDescriptor::default());
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("quads"),
            layout: &layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&mask_view) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&color_view) },
            ],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("quads"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: std::mem::size_of::<BatchUniform>() as u32,
        });
        let attributes = wgpu::vertex_attr_array![0 => Float32x2, 1 => Float32x2, 2 => Float32x2, 3 => Unorm8x4, 4 => Uint32];
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("quads"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vertex"),
                compilation_options: Default::default(),
                buffers: &[Some(wgpu::VertexBufferLayout {
                    array_stride: std::mem::size_of::<Instance>() as u64,
                    step_mode: wgpu::VertexStepMode::Instance,
                    attributes: &attributes,
                })],
            },
            primitive: wgpu::PrimitiveState { topology: wgpu::PrimitiveTopology::TriangleStrip, ..Default::default() },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fragment"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState::PREMULTIPLIED_ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            multiview_mask: None,
            cache: None,
        });
        let dynamic_capacity = 4 * 1024;
        let instances = Self::instance_buffer(device, RETAINED_INSTANCES + dynamic_capacity);
        Renderer { pipeline, bind_group, instances, dynamic_capacity, uploaded: Vec::new(), rows: RowCache::new() }
    }

    fn instance_buffer(device: &wgpu::Device, capacity: usize) -> wgpu::Buffer {
        device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("instances"),
            size: (capacity * std::mem::size_of::<Instance>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        })
    }

    /// Call before building a frame's scene.
    pub fn begin_frame(&mut self) {
        self.rows.next_frame();
    }

    /// Records `scene` into `target`, cleared to `background`. The caller finishes and submits.
    pub fn draw(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        target: &wgpu::TextureView,
        size: (u32, u32),
        background: [f64; 3],
        scene: &Scene,
    ) -> wgpu::CommandEncoder {
        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("frame") });
        let stride = std::mem::size_of::<Instance>() as u64;
        if scene.instances.len() > self.dynamic_capacity {
            // Grow, keeping the retained rows.
            let capacity = scene.instances.len().next_power_of_two();
            let larger = Self::instance_buffer(device, RETAINED_INSTANCES + capacity);
            encoder.copy_buffer_to_buffer(&self.instances, 0, &larger, 0, RETAINED_INSTANCES as u64 * stride);
            self.instances = larger;
            self.dynamic_capacity = capacity;
            self.uploaded.clear();
        }
        for (slot, instances) in self.rows.uploads.drain(..) {
            if !instances.is_empty() {
                queue.write_buffer(&self.instances, slot as u64 * ROW_CAPACITY as u64 * stride, bytemuck::cast_slice(&instances));
            }
        }
        if bytemuck::cast_slice::<Instance, u8>(&scene.instances) != bytemuck::cast_slice::<Instance, u8>(&self.uploaded) {
            if !scene.instances.is_empty() {
                queue.write_buffer(&self.instances, RETAINED_INSTANCES as u64 * stride, bytemuck::cast_slice(&scene.instances));
            }
            self.uploaded.clear();
            self.uploaded.extend_from_slice(&scene.instances);
        }
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("frame"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: target,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color { r: background[0], g: background[1], b: background[2], a: 1.0 }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            if !scene.batches.is_empty() {
                pass.set_pipeline(&self.pipeline);
                pass.set_bind_group(0, &self.bind_group, &[]);
                pass.set_vertex_buffer(0, self.instances.slice(..));
                let mut scissor: Option<(u32, u32, u32, u32)> = None;
                for batch in &scene.batches {
                    let wanted = match batch.clip {
                        None => (0, 0, size.0, size.1),
                        Some(clip) => {
                            let x0 = (clip.x.max(0.0).round() as u32).min(size.0);
                            let y0 = (clip.y.max(0.0).round() as u32).min(size.1);
                            let x1 = (clip.right().max(0.0).round() as u32).min(size.0);
                            let y1 = (clip.bottom().max(0.0).round() as u32).min(size.1);
                            (x0, y0, x1.saturating_sub(x0), y1.saturating_sub(y0))
                        }
                    };
                    if wanted.2 == 0 || wanted.3 == 0 {
                        continue;
                    }
                    if scissor != Some(wanted) {
                        pass.set_scissor_rect(wanted.0, wanted.1, wanted.2, wanted.3);
                        scissor = Some(wanted);
                    }
                    pass.set_immediates(0, bytemuck::bytes_of(&BatchUniform { viewport: [size.0 as f32, size.1 as f32], offset: batch.offset }));
                    let first = if batch.retained { batch.start } else { RETAINED_INSTANCES as u32 + batch.start };
                    pass.draw(0..4, first..first + batch.count);
                }
            }
        }
        encoder
    }
}
