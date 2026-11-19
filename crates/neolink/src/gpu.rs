//! The wgpu device shared by the renderer and the presenter.

pub struct Gpu {
    /// Owned for the device's lifetime, though nothing reads it after setup.
    #[allow(dead_code)]
    pub instance: wgpu::Instance,
    pub adapter: wgpu::Adapter,
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
}

impl Gpu {
    /// `preferred`: the name of the adapter that drives the window's display, where the system says.
    pub fn new(preferred: Option<&str>) -> Result<Gpu, String> {
        // Windows: Direct3D 12 presents through DXGI's flip model straight to the compositor. Vulkan
        // windows there are often presented through an extra copy (NVIDIA's "layered on DXGI"
        // swapchain), which adds a refresh and drops frames. Vulkan stays the fallback.
        // `WGPU_BACKEND` still chooses, for comparisons.
        let backends = if cfg!(windows) && std::env::var_os("WGPU_BACKEND").is_none() { wgpu::Backends::DX12 } else { wgpu::Backends::all() };
        let open = |backends: wgpu::Backends| {
            let mut descriptor = wgpu::InstanceDescriptor::new_without_display_handle();
            // Elsewhere (macOS) the instance is wgpu's default, as it always was.
            if cfg!(windows) {
                descriptor.backends = backends;
                descriptor = descriptor.with_env();
            }
            let instance = wgpu::Instance::new(descriptor);
            // The adapter that drives the window's display: on a desktop with monitors on the graphics
            // card, the low-power choice is the integrated GPU, and every frame would be copied across.
            let matching = preferred.and_then(|name| {
                pollster::block_on(instance.enumerate_adapters(backends))
                    .into_iter()
                    .find(|adapter| adapter.get_info().name.trim().eq_ignore_ascii_case(name.trim()) && adapter.features().contains(wgpu::Features::IMMEDIATES))
            });
            let adapter = match matching {
                Some(adapter) => Ok(adapter),
                None => pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions { power_preference: wgpu::PowerPreference::LowPower, ..Default::default() })),
            };
            adapter.map(|adapter| (instance, adapter))
        };
        let (instance, adapter) = match open(backends) {
            Ok(found) => found,
            Err(_) if backends != wgpu::Backends::all() => open(wgpu::Backends::all()).map_err(|error| format!("no GPU adapter: {error}"))?,
            Err(error) => return Err(format!("no GPU adapter: {error}")),
        };
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
