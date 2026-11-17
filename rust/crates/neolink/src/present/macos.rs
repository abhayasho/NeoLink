use super::{Presented, FORMAT};
use crate::clock;
use block2::RcBlock;
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2::msg_send;
use objc2_app_kit::NSView;
use objc2_core_foundation::CGSize;
use objc2_metal::{MTLCommandBuffer, MTLCommandQueue, MTLDrawable, MTLPixelFormat, MTLTexture, MTLTextureType};
use objc2_quartz_core::{CALayer, CAMetalDrawable, CAMetalLayer};
use parking_lot::Mutex;
use std::ptr::NonNull;
use std::sync::Arc;
use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};

/// Owns the window's Metal layer. Created on the main thread, then used only by the render thread.
pub struct Presenter {
    layer: Retained<CAMetalLayer>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    size: (u32, u32),
    presented: Arc<Mutex<Vec<Presented>>>,
    /// Frames submitted whose display time has not been reported yet.
    in_flight: Arc<std::sync::atomic::AtomicUsize>,
}

// The layer is only touched from the render thread after creation; CAMetalLayer's drawable calls are
// thread-safe.
unsafe impl Send for Presenter {}

pub struct Frame {
    pub view: wgpu::TextureView,
    pub width: u32,
    pub height: u32,
    _texture: wgpu::Texture,
    drawable: Retained<ProtocolObject<dyn CAMetalDrawable>>,
}

impl Presenter {
    /// Must be called on the main thread.
    pub fn new(gpu: &crate::gpu::Gpu, window: &winit::window::Window) -> Result<Presenter, String> {
        let handle = window.window_handle().map_err(|error| error.to_string())?;
        let RawWindowHandle::AppKit(handle) = handle.as_raw() else {
            return Err("not an AppKit window".into());
        };
        let view: &NSView = unsafe { handle.ns_view.cast::<NSView>().as_ref() };
        let layer = CAMetalLayer::new();
        let raw_device = unsafe { gpu.device.as_hal::<wgpu::hal::api::Metal>() }.ok_or("the device is not Metal")?;
        layer.setDevice(Some(raw_device.raw_device()));
        drop(raw_device);
        layer.setPixelFormat(MTLPixelFormat::BGRA8Unorm);
        layer.setFramebufferOnly(true);
        layer.setOpaque(true);
        // Two drawables: one on the display, one being drawn or waiting. Nothing can queue further back.
        layer.setMaximumDrawableCount(2);
        layer.setDisplaySyncEnabled(true);
        layer.setAllowsNextDrawableTimeout(true);
        layer.setPresentsWithTransaction(false);
        let scale = window.scale_factor();
        layer.setContentsScale(scale);
        view.setWantsLayer(true);
        let root: Retained<CALayer> = view.layer().ok_or("the view has no layer")?;
        layer.setFrame(root.bounds());
        // kCALayerWidthSizable | kCALayerHeightSizable
        let _: () = unsafe { msg_send![&*layer, setAutoresizingMask: 18u32] };
        // A resize shows the old frame unscaled at the top left until the next one is drawn.
        let gravity = objc2_foundation::NSString::from_str("topLeft");
        let _: () = unsafe { msg_send![&*layer, setContentsGravity: &*gravity] };
        root.addSublayer(&layer);
        let size = window.inner_size();
        let presenter = Presenter {
            layer,
            device: gpu.device.clone(),
            queue: gpu.queue.clone(),
            size: (0, 0),
            presented: Arc::new(Mutex::new(Vec::new())),
            in_flight: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
        };
        let mut presenter = presenter;
        presenter.resize(size.width.max(1), size.height.max(1));
        Ok(presenter)
    }

    pub fn has_exact_timestamps(&self) -> bool {
        true
    }

    fn resize(&mut self, width: u32, height: u32) {
        if self.size != (width, height) {
            self.size = (width, height);
            self.layer.setDrawableSize(CGSize { width: width as f64, height: height as f64 });
        }
    }

    pub fn in_flight(&self) -> usize {
        self.in_flight.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Takes the next drawable (this can block while both drawables are in use).
    pub fn acquire(&mut self, width: u32, height: u32) -> Option<Frame> {
        self.resize(width.max(1), height.max(1));
        let drawable = self.layer.nextDrawable()?;
        let texture = drawable.texture();
        let (width, height) = (texture.width() as u32, texture.height() as u32);
        let hal_texture = unsafe {
            wgpu::hal::metal::Device::texture_from_raw(
                texture,
                FORMAT,
                MTLTextureType::Type2D,
                1,
                1,
                wgpu::hal::CopyExtent { width, height, depth: 1 },
                None,
            )
        };
        let descriptor = wgpu::TextureDescriptor {
            label: Some("drawable"),
            size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: FORMAT,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            view_formats: &[],
        };
        let texture = unsafe {
            self.device.create_texture_from_hal::<wgpu::hal::api::Metal>(
                hal_texture,
                &descriptor,
                wgpu::TextureUses::UNINITIALIZED,
            )
        };
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        Some(Frame { view, width, height, _texture: texture, drawable })
    }

    /// Presents `frame` once the commands already submitted to the queue have been scheduled.
    pub fn present(&mut self, frame: Frame, id: u64) {
        let Frame { view, _texture, drawable, .. } = frame;
        drop(view);
        let submitted = clock::now();
        let sink = self.presented.clone();
        let in_flight = self.in_flight.clone();
        in_flight.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let handler = RcBlock::new(move |shown: NonNull<ProtocolObject<dyn MTLDrawable>>| {
            let displayed: f64 = unsafe { msg_send![shown.as_ref(), presentedTime] };
            in_flight.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
            sink.lock().push(Presented { frame: id, submitted, displayed, exact: true });
        });
        unsafe { drawable.addPresentedHandler(RcBlock::as_ptr(&handler)) };
        // A command buffer of our own on wgpu's queue: buffers on one queue run in order, so the
        // drawable is presented after the frame's rendering.
        let queue = unsafe { self.queue.as_hal::<wgpu::hal::api::Metal>() }.expect("a Metal queue");
        if let Some(buffer) = queue.as_raw().commandBuffer() {
            let shown: &ProtocolObject<dyn MTLDrawable> = ProtocolObject::from_ref(&*drawable);
            buffer.presentDrawable(shown);
            buffer.commit();
        }
        drop(queue);
        drop(_texture);
    }

    /// Display reports that arrived since the last call.
    pub fn take_presented(&mut self) -> Vec<Presented> {
        std::mem::take(&mut *self.presented.lock())
    }
}
