# NeoGPU workspace renderer

NeoGPU is NeoLink’s small custom retained Metal UI engine. It is independently implemented in Swift; it does not embed Zed or copy its source. It keeps the terminal model, Neovim, SSH/SFTP, native document viewers, input handling and accessibility adapters.

## Scene and frame ownership

- `NeoGPUScene`: immutable, device-owned packed instances for solid fills, textured surfaces and coverage masks. Paint order is preserved; only adjacent compatible primitives batch. Buffers and textures remain retained through encoding.
- `NeoGPURenderer`: instanced quads, per-instance clipping and premultiplied blending. Scroll translation is a small uniform update. Textures sample at native backing resolution; no reduced-resolution rendering or linear rescaling.
- `NeoGPUFrameSource`: demand-driven CAMetalDisplayLink with supplied drawables, VSync and a 120 Hz cap. A wake during frame encoding survives the idle decision.
- `NeoGPUWorkspace`: latches all visible clients at one presentation timestamp. Terminal/editor content renders into private textures using the workspace command buffer. Explorer retains its nearby-row texture. A single final render pass composites both into one transparent window drawable, which is presented once. Window state and animations latch on that same callback; the independent window clock pauses during hosting. A nonblocking in-flight slot releases on GPU completion. No synchronous GPU waits or normal-frame readbacks.

The transparent overlay ignores hit testing and accessibility. Native controls remain visible outside pane clips. In-window Quick Open/Git overlays suspend hosting and restore independent surfaces; dismissal resumes it without restarting sessions. Hidden terminal buffers release their private framebuffer. Display changes and resizing rebuild backing-pixel geometry. GPU failure restores existing independent/native paths. macOS 13 keeps the existing renderer.

## Scope and tradeoffs

SwiftUI/AppKit chrome, agent conversations, PDF views, menus and Folder List/SFTP remain native. CoreText still rasterizes new glyphs and row artwork on the CPU; terminal parsing and Neovim remain CPU work. The custom engine removes independent presentation between the coding panes, but it is not an all-widget GPU rewrite. Each visible terminal needs an extra native-resolution BGRA framebuffer (about 30 MiB at a large Retina viewport); hidden views release it. The explorer’s retained strip keeps its existing 16 MiB extra-storage limit.

`NEOLINK_GPUI_WORKSPACE=0` disables shared hosting for a same-binary comparison. Use `render-motion,idle` in the release benchmark with an unlocked, frontmost window. `workspaceVisiblePanes` must be two for the combined terminal/explorer test. Shared-mode GPU timings cover the whole command buffer and cannot be compared as an isolated explorer cost. [Release results](RENDERING.md) distinguish measured behavior from perceived smoothness.

## References

The design was informed by Zed revision `504a7f2cf25b817cda3998cab93473adef15f93c`: its [scene and ordering](https://github.com/zed-industries/zed/blob/504a7f2cf25b817cda3998cab93473adef15f93c/crates/gpui/src/scene.rs), [Metal renderer](https://github.com/zed-industries/zed/blob/504a7f2cf25b817cda3998cab93473adef15f93c/crates/gpui_apple/src/metal_renderer.rs), and [macOS supplied-drawable callback](https://github.com/zed-industries/zed/blob/504a7f2cf25b817cda3998cab93473adef15f93c/crates/gpui_macos/src/window.rs). These architectural references do not establish equal performance or zero latency.
