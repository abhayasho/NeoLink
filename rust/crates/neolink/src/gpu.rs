//! The wgpu device shared by the renderer and the presenter.

pub struct Gpu {
    pub instance: wgpu::Instance,
    pub adapter: wgpu::Adapter,
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
}

impl Gpu {
    pub fn new() -> Result<Gpu, String> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::LowPower,
            ..Default::default()
        }))
        .map_err(|error| format!("no GPU adapter: {error}"))?;
        // Immediates carry each batch's translation, so scrolling uploads nothing but those 16 bytes.
        if !adapter.features().contains(wgpu::Features::IMMEDIATES) {
            return Err("the GPU driver does not support immediate data (push constants)".into());
        }
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("neolink"),
            required_features: wgpu::Features::IMMEDIATES,
            required_limits: wgpu::Limits { max_immediate_size: 16, ..wgpu::Limits::default() },
            ..Default::default()
        }))
        .map_err(|error| format!("no GPU device: {error}"))?;
        Ok(Gpu { instance, adapter, device, queue })
    }
}
