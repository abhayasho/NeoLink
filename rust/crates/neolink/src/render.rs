//! The one drawing primitive: instanced, pixel-aligned quads (solid fills, glyph masks, colour glyphs).

use crate::text::{Sprite, SpriteKind, TextSystem, ATLAS_SIZE};
use bytemuck::{Pod, Zeroable};

#[repr(C)]
#[derive(Clone, Copy, Debug, Pod, Zeroable)]
pub struct Instance {
    pub position: [f32; 2],
    pub size: [f32; 2],
    pub uv: [f32; 2],
    /// RGBA, not premultiplied, in display (encoded) values.
    pub color: [u8; 4],
    /// 0 = solid, 1 = mask glyph, 2 = colour glyph.
    pub kind: u32,
}

#[derive(Default)]
pub struct Scene {
    pub instances: Vec<Instance>,
}

impl Scene {
    pub fn clear(&mut self) {
        self.instances.clear();
    }

    pub fn fill(&mut self, x: f32, y: f32, width: f32, height: f32, color: [u8; 4]) {
        self.instances.push(Instance { position: [x, y], size: [width, height], uv: [0.0, 0.0], color, kind: 0 });
    }

    /// A glyph whose pen position is `(x, baseline)` in pixels.
    pub fn glyph(&mut self, sprite: Sprite, x: f32, baseline: f32, color: [u8; 4]) {
        self.instances.push(Instance {
            position: [x + sprite.left as f32, baseline - sprite.top as f32],
            size: [sprite.width as f32, sprite.height as f32],
            uv: [sprite.atlas_x as f32, sprite.atlas_y as f32],
            color,
            kind: match sprite.kind {
                SpriteKind::Mask => 1,
                SpriteKind::Color => 2,
            },
        });
    }
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct Globals {
    viewport: [f32; 2],
    atlas: [f32; 2],
}

pub struct Renderer {
    pipeline: wgpu::RenderPipeline,
    globals: wgpu::Buffer,
    bind_group: wgpu::BindGroup,
    instances: wgpu::Buffer,
    capacity: usize,
}

const SHADER: &str = r#"
struct Globals { viewport: vec2<f32>, atlas: vec2<f32> };
@group(0) @binding(0) var<uniform> globals: Globals;
@group(0) @binding(1) var masks: texture_2d<f32>;
@group(0) @binding(2) var colors: texture_2d<f32>;

struct Out {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
    @location(2) @interpolate(flat) kind: u32,
};

@vertex
fn vertex(@builtin(vertex_index) index: u32, @location(0) position: vec2<f32>, @location(1) size: vec2<f32>,
          @location(2) uv: vec2<f32>, @location(3) color: vec4<f32>, @location(4) kind: u32) -> Out {
    let corner = vec2<f32>(f32(index & 1u), f32(index >> 1u));
    let pixel = position + corner * size;
    var out: Out;
    out.position = vec4<f32>(pixel.x / globals.viewport.x * 2.0 - 1.0, 1.0 - pixel.y / globals.viewport.y * 2.0, 0.0, 1.0);
    out.uv = uv + corner * size;
    out.color = color;
    out.kind = kind;
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
    return vec4<f32>(in.color.rgb * in.color.a, in.color.a);
}
"#;

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
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX,
                    ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None },
                    count: None,
                },
                texture_entry(1),
                texture_entry(2),
            ],
        });
        let globals = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("globals"),
            size: std::mem::size_of::<Globals>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let mask_view = text.atlas.mask.create_view(&wgpu::TextureViewDescriptor::default());
        let color_view = text.atlas.color.create_view(&wgpu::TextureViewDescriptor::default());
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("quads"),
            layout: &layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: globals.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&mask_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&color_view) },
            ],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("quads"),
            bind_group_layouts: &[Some(&layout)],
            ..Default::default()
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
        let capacity = 16 * 1024;
        let instances = Self::instance_buffer(device, capacity);
        Renderer { pipeline, globals, bind_group, instances, capacity }
    }

    fn instance_buffer(device: &wgpu::Device, capacity: usize) -> wgpu::Buffer {
        device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("instances"),
            size: (capacity * std::mem::size_of::<Instance>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        })
    }

    /// Draws `scene` into `target`, cleared to `background`.
    pub fn draw(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        target: &wgpu::TextureView,
        size: (u32, u32),
        background: [f64; 3],
        scene: &Scene,
    ) -> wgpu::CommandBuffer {
        if scene.instances.len() > self.capacity {
            self.capacity = scene.instances.len().next_power_of_two();
            self.instances = Self::instance_buffer(device, self.capacity);
        }
        queue.write_buffer(&self.globals, 0, bytemuck::bytes_of(&Globals { viewport: [size.0 as f32, size.1 as f32], atlas: [ATLAS_SIZE as f32; 2] }));
        if !scene.instances.is_empty() {
            queue.write_buffer(&self.instances, 0, bytemuck::cast_slice(&scene.instances));
        }
        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("frame") });
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
            if !scene.instances.is_empty() {
                pass.set_pipeline(&self.pipeline);
                pass.set_bind_group(0, &self.bind_group, &[]);
                pass.set_vertex_buffer(0, self.instances.slice(..));
                pass.draw(0..4, 0..scene.instances.len() as u32);
            }
        }
        encoder.finish()
    }
}
