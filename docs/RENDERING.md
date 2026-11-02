# Native GPU text rendering

NeoLink uses SwiftTerm 1.20.0's Metal renderer for terminal-backed surfaces: local shells, SSH sessions, agent terminals, REPLs, and the shared Neovim editor. The dependency is pinned to retain its 1.x API. GPUI itself is an open-source Rust UI framework and is not embedded; this integration keeps NeoLink's AppKit/SwiftUI architecture while using the same macOS GPU API, Metal.

## Drawing and lifecycle

- CoreText shapes/rasterizes glyphs into a cached atlas. Metal draws cell backgrounds, glyphs, selections, and the cursor as GPU primitives.
- Per-row persistent buffers reuse unchanged geometry. There is no additional NeoLink render timer, continuous 120 Hz loop, or duplicate rendering surface.
- GPU setup happens after a terminal joins a window. SwiftTerm handles drawable lifetimes, frame coalescing, font/backing-scale changes, window reparenting, and renderer recovery.
- Failed initialization leaves the CoreGraphics path available. Upstream recovery can also fall back after a repeated GPU failure. Toggle GPU rendering off and on to retry explicitly.
- **View → Use GPU Text Rendering** applies to existing surfaces and is remembered. Switching renderers retains the PTY, buffer, scrollback, and Neovim process.
- **View → Renderer Information…** reports the focused surface's renderer, GPU presentation count, and the display's maximum refresh rate. A display capability is not an application FPS measurement.
- The packaged app includes `SwiftTerm_SwiftTerm.bundle` in `Contents/Resources`; shader loading must not depend on the developer's checkout. When Xcode's Metal compiler is available, packaging precompiles the shader library to avoid compilation during the first terminal's GPU setup. The source remains as a fallback. AppKit/SwiftUI, PDFKit, and the native text fallback retain their own rendering paths.

## Performance limits

GPU rendering moves text drawing work to Metal; text shaping, parsing, PTY traffic, language servers, and application state still require CPU time. SwiftTerm 1.20 bypasses its normal 16.67 ms output coalescing delay for output shortly after keyboard input. Bulk output and some other updates retain upstream coalescing, so this is not a verified 120 FPS renderer. No extra timer forces redraws of unchanged content to inflate an FPS counter.

Actual presentation rate and input latency depend on content, font size, display refresh rate, power settings, the terminal application, and GPU load. Neither a GPU renderer nor a 120 Hz screen can deliver literally zero latency. NeoLink makes no measured superiority claim over VS Code or Zed.

For profiling a release app, enable Apple's Metal HUD with `MTL_HUD_ENABLED=1`, or collect SwiftTerm's existing Metal signposts with `SWIFTTERM_PROFILE=1` in Instruments. Compare the same workload with the View-menu switch on and off; include frame intervals, main-thread work, memory, and idle CPU rather than relying only on an average FPS counter.

## Validation

The 1.6.0 release passed 73 native tests and the Neovim runtime regression script. A local installed-app check confirmed healthy Metal presentation in both a shell and Neovim, code scrolling, syntax highlighting, CJK/emoji rendering, text zoom, and typing/undo. Switching GPU rendering off and back on retained the editor's buffer and viewport. The packaged release includes a precompiled Metal library and passed strict code-signature verification. These checks establish working GPU rendering, not a measured frame-rate or input-latency benchmark.

## Sources

- [SwiftTerm 1.20.0](https://github.com/migueldeicaza/SwiftTerm/tree/v1.20.0) and its Metal implementation.
- [GPUI](https://gpui.rs/) describes the Rust framework and its GPU rendering approach.
- [Zed's 120 FPS investigation](https://zed.dev/blog/120fps) documents presentation synchronization and ProMotion tradeoffs; it is not a performance guarantee for NeoLink.
