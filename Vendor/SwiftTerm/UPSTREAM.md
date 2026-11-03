# SwiftTerm source snapshot

Source: https://github.com/migueldeicaza/SwiftTerm
Tag: v1.20.0
Commit: 5d14406844143538cd8f8851d2d8a67c1fe443e5
License: MIT (see LICENSE)

Only the library target and its resources are included. The package manifest omits upstream examples, benchmarks, documentation plugins and the Git build-info generator; build information is pinned to this snapshot.

## NeoLink changes

All changes are macOS and Metal paths; marked `NeoLink` in comments where they are not self-explanatory. With none of the new hooks set, upstream behavior is unchanged except for the renderer's row cache and shared shader resources, which produce identical frames.

- **Frame scheduling** (`Mac/MacTerminalView.swift`, `Apple/AppleTerminalView.swift`): optional `displayUpdateScheduler` and `metalFrameScheduler` callbacks let the host synchronize state updates and Metal submission with its window's display link, replacing the fixed 16.67 ms batch timers.
- **Renderer redraws** (`Apple/Metal/MetalTerminalRenderer.swift`, `requestRedraw()`): redraws the renderer starts itself (a frame refused while another was in flight, retries, cursor blink) go through `metalFrameScheduler` when one is installed. Upstream calls `MTKView.setNeedsDisplay`, which draws unpaced on MTKView's own main-queue source.
- **Presentation reporting** (`metalNextFrameTag`, `metalFramePresented`): the host tags a frame and receives its `MTLDrawable.presentedTime`, for latency and cadence measurement.
- **Vsync bypass** (`metalPresentsImmediately`): sets `CAMetalLayer.displaySyncEnabled = false` for the next frame. The host uses it only for sparse frames answering key presses.
- **Frame capture** (`allowsMetalFrameCapture`, `metalFrameCapture`): opt-in copy of a rendered frame for tests and the benchmark; views created while it is on are not `framebufferOnly`.
- **Row cache by line identity** (`MetalTerminalRenderer.swift`): rows are cached per `BufferLine` object with the visible row they were built for, and drawn translated (`PlacedRow.offsetY`) after they move. `yDisp` is no longer part of the cache signature. `TerminalView.metalMovedLines` marks lines that moved without changing content (viewport scrolls in `scrollTo`, program region scrolls) so their dirty-range entries do not force a rebuild.
- **Translation uniform** (`Apple/Metal/Shaders.metal`): the vertex shaders' `viewport` is a `float4`; `zw` translates the drawn primitives. All `setVertexBytes` call sites pass `SIMD4<Float>`.
- **Smooth scrolling** (new `Mac/MacSmoothScroll.swift`, `Terminal.swift`): `Terminal.regionScrollObserver` reports full-width region scrolls (CSI L/M at the region's top row, CSI S/T) with the lines that left the region; `screenErasedObserver` reports a full erase (ED 2). `TerminalView` keeps those lines (`RetainedScrollLines`) and exposes `smoothScrollOffset`, `smoothScrollSource`, `smoothScrollRange`, `programScrolled`, `discardRetainedScrollLines()` and `scrollViewport(towardTop:)`. The renderer draws the region at the offset, clipped by a scissor rectangle (`RowClip`), and fills the exposed edge with retained or scrollback lines from its cache.
- **Shared shader resources**: the shader library and pipelines are compiled once per device and pixel format and shared by all renderers; `TerminalView.prepareMetalRenderer()` compiles them ahead of time on any thread. Text and color pipelines keep upstream's different blend factors.
- **Drawable acquisition**: `draw(in:)` builds draw data before taking the drawable.
- **Resource lookup**: `candidateBundles()` also checks the directory containing a bundle, where a SwiftPM test bundle finds `SwiftTerm_SwiftTerm.bundle`.

Additional retained work after the initial rendering snapshot:

- `LocalProcess.swift` uses a 2 ms main-queue parsing time slice. The budget is checked between chunks, not a hard upper bound on an individual parse or input latency; backpressure remains in place.
- Margin-restricted region-scroll reporting lets the host invalidate interpolation for side-by-side terminal windows without moving neighboring text.
- Renderer capture/scroll-state reporting and drawable submission tags support the developer's geometry and pixel-analysis harness. Glyph/content capture is opt-in, and benchmark measurement remains distinct from real trackpad visual acceptance.

Keep this snapshot and its license in source control. Do not patch SwiftPM's transient `.build/checkouts` directory. When updating, diff against the tag, reapply the changes above, and run `swift test` (it includes Metal pixel comparisons of smooth-scrolled frames), `scripts/test-editor.py`, and the benchmark in `docs/RENDERING.md`.
