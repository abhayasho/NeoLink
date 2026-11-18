//! Getting a frame onto the display, and learning when it got there.
//!
//! macOS: the app owns the `CAMetalLayer`, takes `nextDrawable()` itself and presents on commit, so every
//! frame reports the time it actually reached the display. Other systems: the ordinary wgpu surface.

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub use macos::Presenter;

#[cfg(not(target_os = "macos"))]
mod surface;
#[cfg(not(target_os = "macos"))]
pub use surface::Presenter;

/// The colour format every presenter renders in: 8-bit, not sRGB-encoded, so blending happens on encoded
/// values (the way text is conventionally composited).
pub const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Bgra8Unorm;

/// A frame's journey, reported once it is known.
#[derive(Clone, Copy, Debug)]
pub struct Presented {
    pub frame: u64,
    /// When the frame was handed to the system for presentation.
    pub submitted: f64,
    /// When it reached the display; 0 if the system reported that it never did. On systems without
    /// display timestamps this is the time the present call returned.
    pub displayed: f64,
    /// Whether `displayed` is a true display time.
    #[allow(dead_code)] // Diagnostics: shown with the report when frames are logged.
    pub exact: bool,
}
