//! Renders a frame's scene off screen and writes it as a PNG (`NEOLINK_CAPTURE=path.png`).
//!
//! This is how what the app draws can be inspected without screen recording permission, and it is the
//! same code path on every system: the scene, the atlas and the shader are the ones a displayed frame
//! uses; only the target differs.

use crate::gpu::Gpu;
use crate::present::FORMAT;
use crate::render::{Renderer, Scene};
use std::path::Path;

pub fn write_png(gpu: &Gpu, renderer: &mut Renderer, scene: &Scene, size: (u32, u32), background: [f64; 3], path: &Path) -> Result<(), String> {
    let (width, height) = (size.0.max(1), size.1.max(1));
    let texture = gpu.device.create_texture(&wgpu::TextureDescriptor {
        label: Some("capture"),
        size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: FORMAT,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
    let row_bytes = (width * 4).div_ceil(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT) * wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
    let buffer = gpu.device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("capture"),
        size: row_bytes as u64 * height as u64,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let mut encoder = renderer.draw(&gpu.device, &gpu.queue, &view, (width, height), background, scene);
    encoder.copy_texture_to_buffer(
        wgpu::TexelCopyTextureInfo { texture: &texture, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
        wgpu::TexelCopyBufferInfo { buffer: &buffer, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(row_bytes), rows_per_image: Some(height) } },
        wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
    );
    gpu.queue.submit([encoder.finish()]);
    let (sender, receiver) = std::sync::mpsc::channel();
    buffer.slice(..).map_async(wgpu::MapMode::Read, move |result| {
        let _ = sender.send(result);
    });
    gpu.device.poll(wgpu::PollType::wait_indefinitely()).map_err(|error| error.to_string())?;
    receiver.recv().map_err(|error| error.to_string())?.map_err(|error| error.to_string())?;
    let mapped = buffer.slice(..).get_mapped_range().map_err(|error| error.to_string())?;
    let mut pixels = Vec::with_capacity((width * height * 4) as usize);
    for row in 0..height as usize {
        let start = row * row_bytes as usize;
        for pixel in mapped[start..start + width as usize * 4].chunks_exact(4) {
            // BGRA to RGBA.
            pixels.extend_from_slice(&[pixel[2], pixel[1], pixel[0], 0xff]);
        }
    }
    drop(mapped);
    let file = std::fs::File::create(path).map_err(|error| error.to_string())?;
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), width, height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().map_err(|error| error.to_string())?;
    writer.write_image_data(&pixels).map_err(|error| error.to_string())?;
    Ok(())
}
