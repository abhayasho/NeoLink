# Native GPU text rendering

NeoLink uses a vendored SwiftTerm 1.20.0 Metal renderer for terminal-backed surfaces: local shells, SSH sessions, agent terminals, REPLs, and the shared Neovim editor. GPUI itself is an open-source Rust UI framework and is not embedded; NeoLink keeps its AppKit/SwiftUI architecture and uses the same macOS GPU API, Metal. NeoLink's changes to SwiftTerm are listed in `Vendor/SwiftTerm/UPSTREAM.md`.

## Drawing and lifecycle

- CoreText shapes/rasterizes glyphs into a cached atlas. Metal draws cell backgrounds, glyphs, selections, and the cursor as GPU primitives.
- Row geometry is cached per `BufferLine` object, not per screen row. Scrolling moves line references, so a line that only moved is drawn translated by a vertex-shader offset instead of being shaped again. Only rows whose content changed are rebuilt.
- Each window has one display-link clock (`WindowFrameScheduler`, capped at 120 Hz) that paces terminal state updates and Metal submission for every surface in it. The clock runs only while something changed and stops when idle. An occluded or minimized window drains work without a clock.
- Unchanged surfaces are not presented again. Zed repeats the current frame for a second after input so ProMotion stays at 120 Hz; measured here, the repeats queued drawables ahead of the next real frame and added about 9 ms from key press to display.
- Output answering a key press is drawn as soon as it is parsed (an "immediate frame"), not at the next display callback. When such a frame is at least 1.5 refreshes after the surface's previous frame and no animation is running, it is presented without waiting for vsync (`CAMetalLayer.displaySyncEnabled = false` for that frame). A composited window does not tear. Scrolling and other continuous updates keep vsync, so every refresh shows exactly one frame.
- A surface with three frames waiting for the display defers its next frame instead of requesting a fourth drawable. Requesting one would block the main thread in `nextDrawable`, which stalls input; that happened during 10 ms key repeat when ProMotion lowered the refresh rate.
- Covered surfaces do not draw. Terminals hidden behind a document tab are hidden NSViews rather than zero-opacity SwiftUI layers.
- The shader library and pipelines are compiled once per process, on a background queue at launch, and shared by every terminal. Previously each new terminal, including the editor's, compiled them on the main thread.
- GPU setup happens after a terminal joins a window. SwiftTerm handles drawable lifetimes, font/backing-scale changes, window reparenting, and renderer recovery. Failed initialization leaves the CoreGraphics path available; toggle GPU rendering off and on to retry.
- **View → Use GPU Text Rendering** applies to existing surfaces and is remembered. Switching renderers retains the PTY, buffer, scrollback, and Neovim process.
- **View → Performance Monitor…** shows the window clock, key-press-to-display latency, and the interval between new terminal frames on screen, from `MTLDrawable.presentedTime`. **Renderer Information…** reports the focused surface's renderer.
- The packaged app includes `SwiftTerm_SwiftTerm.bundle` in `Contents/Resources` with a precompiled `default.metallib` when Xcode's Metal compiler is available; the shader source remains as a fallback. AppKit/SwiftUI, PDFKit, and the native text fallback keep their own rendering paths.

## Smooth scrolling

A terminal grid moves by whole lines, so trackpad scrolling used to jump a line at a time (about 40 content changes per second at a moderate speed). With the Metal renderer, NeoLink now follows the trackpad pixel by pixel in both places text scrolls:

- **Editor and other full-screen programs** (mouse reporting on, alternate screen): NeoLink asks the program to scroll whole lines slightly ahead of the fingers and draws its scroll region back by the remaining fraction. SwiftTerm reports the program's scroll operations (CSI L/M at the region top, CSI S/T) together with the lines that left the region; the renderer draws those lines in the edge the offset exposes and clips the region. Region scrolls restricted by left/right margins are not reported and keep line steps.
- **Shell scrollback**: the viewport moves by whole lines and the renderer draws the buffer lines above or below it in the exposed edge.

When input stops, the remaining fraction eases out in the direction of travel within about 0.1 s. Offsets are whole device pixels, so glyphs stay on the pixel grid. Keyboard-driven scrolls (for example `j` at the bottom of the window) are shown as the program draws them. Classic mouse wheels and the CoreGraphics renderer keep line steps. Lines retained from a program are discarded before a new gesture, on a full-screen erase, and when the region, buffer or size changes, so they cannot show stale text.

## Measured result

One machine: M2 Max, built-in 120 Hz ProMotion display, macOS 26.6, release build, app frontmost. The benchmark (below) posts synthetic key and trackpad events to NeoLink's own event queue and reads when each frame reached the display. Before is the pacing from the previous revision measured with the same harness; one run per row.

| Scenario | Before | After |
|---|---|---|
| Typing in a shell, key → frame on screen, p50 / p95 | 36.5 / 41.4 ms | 10.7 / 24.1 ms |
| Typing in the editor, p50 / p95 | 38.1 / 41.5 ms | 15.2 / 26.9 ms |
| 10 ms key repeat (cursor down) in the editor, p50 / p95 | 37.7 / 41.0 ms¹ | 28.2 / 34.9 ms |
| Trackpad scrolling the editor, interval between new frames, p50 / p95 | 25 / 25 ms (line steps) | 8.3 / 8.3 ms |
| Trackpad scrolling shell scrollback, p50 / p95 | 25 / 33 ms (line steps) | 8.3 / 16.7 ms |
| First file open: longest main-thread stall | 75 ms | 41 ms |
| SwiftUI AttributeGraph cycles logged opening a file | 111–131 | 0 |

¹ Measured with repeated frames and immediate frames together; the previous pacing without immediate frames was not run for this scenario. For typing, the two measured within 2 ms of each other.

Causes of the "before" numbers:

- Repeated frames during interaction kept a drawable queued, so each real frame waited behind one (about 9 ms), and vsync added two to three refreshes from submission to display.
- Output waited for the next display callback (up to 8.3 ms).
- Line-step scrolling changed the picture about 40 times per second.
- Opening a file hid the shell terminal while it was first responder. AppKit then searched the key-view loop during SwiftUI's update, which re-entered SwiftUI layout (AttributeGraph cycles). The editor's renderer also compiled its shaders on the main thread (about 55 ms).

Limits of these numbers:

- Latency starts at the event timestamp and ends at `presentedTime`. It excludes keyboard scanning and panel response, and synthetic events skip the hardware event path. Real end-to-end latency is higher; it is not zero, and no renderer can make it zero.
- Frames presented without vsync rely on the window being composited. With 10 ms key repeat, frames come too close together for that, so they take the vsync path (about 28 ms).
- ProMotion lowers the refresh rate while the screen is not updating, so the display-callback rate during typing is often below 120 Hz. Continuous scrolling and output keep it at 120 Hz.
- The remaining 41 ms stall on the first file open is SwiftUI building the editor's views and Neovim's terminal surface; later opens reuse them. SwiftUI and AppKit controls (sidebar, file tree, agent panel) are drawn by Core Animation and are not covered by these measurements.
- The output-flood case (`yes | head`) shows new frames every 8.3 ms at the median but 33% of intervals are longer, because parsing still runs on the main thread.

## Benchmark

```sh
swift build -c release
NEOLINK_BENCHMARK=editor-open,editor-scroll,editor-cursor,editor-type,terminal-type,terminal-scroll,terminal-flood \
NEOLINK_BENCHMARK_OUTPUT=/tmp/neolink-benchmark.json .build/release/NeoLink
```

The app opens a scratch copy of `NEOLINK_BENCHMARK_FILE` (default `Sources/Documents/WorkspaceDocument.swift`), runs the scenarios, writes JSON, deletes the copy, and quits. Keep the window frontmost and the screen unlocked; an occluded window pauses its clock. `editor-capture` also renders frames mid-scroll and checks that they equal the previous frame shifted by the scroll distance, writing PNGs beside the JSON. The harness lives in `Sources/Rendering/InteractionBenchmark.swift` and does nothing unless `NEOLINK_BENCHMARK` is set.

For Instruments, `SWIFTTERM_PROFILE=1` enables SwiftTerm's Metal signposts; NeoLink's frames are `Window.Frame` and `Window.ImmediateFrame` signposts (subsystem `com.neolink.app`, category `Frames`). `MTL_HUD_ENABLED=1` shows Apple's Metal HUD.

## Validation

`swift test` includes pixel comparisons of smooth-scrolled Metal frames (`SmoothScrollRenderingTests`), the scroll model, region-scroll reporting, and immediate-frame scheduling. `scripts/test-editor.py` covers the Neovim runtime. The packaged app's precompiled shader library passed the same `editor-capture` comparison.

## Sources

- [SwiftTerm 1.20.0](https://github.com/migueldeicaza/SwiftTerm/tree/v1.20.0) and its Metal implementation.
- [GPUI](https://gpui.rs/) describes the Rust framework and its GPU rendering approach.
- [Zed's 120 FPS investigation](https://zed.dev/blog/120fps) describes the repeated-frame ProMotion technique and its presentation trade-offs.

## Explorer validation and build identity (1.9.0)

The explorer has its own native AppKit table and scrolling path; terminal Metal presentation counters do not measure its pixel presentation. `ui-explorer-scroll` samples clip-view geometry through the existing window clock on macOS 13 and later. It reports total travel, range, stationary intervals between movements, and sample gaps. It invalidates workloads with fewer than 20 changing samples, less than 100 points of travel, or less than 50 points of range. An effectively stationary view cannot produce a valid smoothness result. Geometry movement still does not establish that correctly rendered pixels reached the screen or that the motion feels like Zed.

`scripts/bench-run.py` now invokes a successful release build before measuring by default. It uses SwiftPM's exact executable path, records the executable SHA-256 and a fingerprint of app/vendor/shader/Lua inputs, and rejects runs when either changes. An explicit `--binary` is labeled as a prebuilt baseline. Failed builds and failed binary-path resolution stop execution. `python3 scripts/test-benchmark.py` checks these failure paths offline. Earlier explorer results that drove a stationary view are invalid and must not be used as a performance baseline.

The numerical terminal results above describe the earlier measured revision, not a new benchmark of build 18. No claim of a measured explorer FPS gain or visual equivalence follows from this migration.
