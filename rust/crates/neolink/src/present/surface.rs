use super::{Presented, FORMAT};
use crate::clock;

/// The ordinary wgpu surface (Windows: DX12 flip model with one frame of latency). There is no display
/// timestamp on this path: `Presented::displayed` is when the present call returned.
pub struct Presenter {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    size: (u32, u32),
    presented: Vec<Presented>,
}

pub struct Frame {
    pub view: wgpu::TextureView,
    pub width: u32,
    pub height: u32,
    texture: wgpu::SurfaceTexture,
}

impl Presenter {
    pub fn new(gpu: &crate::gpu::Gpu, window: std::sync::Arc<winit::window::Window>) -> Result<Presenter, String> {
        let surface = gpu.instance.create_surface(window).map_err(|error| error.to_string())?;
        Ok(Presenter { surface, device: gpu.device.clone(), queue: gpu.queue.clone(), size: (0, 0), presented: Vec::new() })
    }

    pub fn has_exact_timestamps(&self) -> bool {
        false
    }

    pub fn in_flight(&self) -> usize {
        0
    }

    fn configure(&mut self, width: u32, height: u32) {
        self.size = (width, height);
        self.surface.configure(
            &self.device,
            &wgpu::SurfaceConfiguration {
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                format: FORMAT,
                width,
                height,
                present_mode: wgpu::PresentMode::Fifo,
                desired_maximum_frame_latency: 1,
                alpha_mode: wgpu::CompositeAlphaMode::Opaque,
                view_formats: vec![],
                ..Default::default()
            },
        );
    }

    pub fn acquire(&mut self, width: u32, height: u32) -> Option<Frame> {
        let (width, height) = (width.max(1), height.max(1));
        if self.size != (width, height) {
            self.configure(width, height);
        }
        let texture = match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(texture) | wgpu::CurrentSurfaceTexture::Suboptimal(texture) => texture,
            _ => {
                self.configure(width, height);
                return None;
            }
        };
        let view = texture.texture.create_view(&wgpu::TextureViewDescriptor::default());
        Some(Frame { view, width, height, texture })
    }

    pub fn present(&mut self, frame: Frame, id: u64) {
        let submitted = clock::now();
        drop(frame.view);
        self.queue.present(frame.texture);
        self.presented.push(Presented { frame: id, submitted, displayed: clock::now(), exact: false });
    }

    pub fn take_presented(&mut self) -> Vec<Presented> {
        std::mem::take(&mut self.presented)
    }
}
