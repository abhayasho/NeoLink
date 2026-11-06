# SwiftTerm source snapshot

Source: https://github.com/migueldeicaza/SwiftTerm
Tag: v1.20.0
Commit: 5d14406844143538cd8f8851d2d8a67c1fe443e5
License: MIT (see LICENSE)

Only the library target and its resources are included. The package manifest omits upstream examples, benchmarks, documentation plugins and the Git build-info generator; build information is pinned to this snapshot.

## NeoLink changes

- **Deadline-only row preparation** (`MetalTerminalRenderer.draw`): hidden panes return before acquiring a frame slot or touching dirty state. With an external drawable owner, native MTKView callbacks without a supplied texture/drawable also return before row preparation. Native resize otherwise built rows only to reject the missing drawable, including work for hidden editor panes. Supplied-size validation, independent fallback and presentation ownership remain unchanged.
- **Zero-ink glyph results and font interning** (`CoreTextGlyphRasterizer`, `MetalTerminalRenderer`): distinguish deterministic empty outline bounds from transient raster/allocation failure. Empty results are keyed by interned scaled-font id and glyph only (emptiness does not depend on raster phase) and capped at 8192. Glyph-atlas entries are keyed by font id, glyph and all 16 raster phases. Scaled fonts are resolved once per shaped glyph run through a bounded identity cache that retains the source font. Blank cells are skipped before placement math, after the same-cell anchor update so combining marks keep their position. Id reissue clears every id-keyed cache together.
- **Preparation diagnostics** (`metalPreparationProfile`): optional main-thread stage costs for attributed text, shaping, geometry, row buffers and overall draw data, plus cache/rebuild counts. Nil in ordinary operation; clocks/dictionaries are only collected in diagnostic runs.
- **PTY diagnostics** (`LocalProcess.outputEventHandler`): immutable chunk IDs/counts and monotonic timestamps at background receipt, queue admission, main delivery and parse completion, plus whether the owning display deadline (`servicePendingOutput`) rather than the main-queue block drained the chunk. A handler is captured per chunk under a lock; no view or mutable terminal state is read on the reader queue. Existing ordered delivery, time slicing and backlog limits remain intact.

- **Hosted workspace rendering** (`metalHostTexture`, `metalHostCommandBuffer`, `metalHostFrameEncoded`, `metalHostFramePresented`): render into a private, native-resolution texture with the workspace owner’s command buffer. The terminal neither commits nor presents that buffer; the owner reports the actual shared drawable presentation time. Existing glyph, image, row-cache, scroll and capture paths are reused. Independent drawable rendering remains the fallback. Pixel tests compare the hosted output byte for byte against independent terminal rendering.

- **Opt-in frame cost profiling** (`metalFrameProfile`): benchmark callbacks report CPU preparation/encoding, Metal GPU execution and queue wait separately. Normal rendering does not install completion telemetry or read back textures.

- **Fractional glyph rasterization** (`CoreTextGlyphRasterizer.swift`, `MetalTerminalRenderer.swift`): cache up to 4×4 CoreText coverage variants per glyph, include phase in the atlas key, add one pixel of antialiasing padding, and draw unscaled glyphs on integer device pixels. Cursor text uses the same placement. This avoids a second antialiasing/filtering step; scaled glyph fitting and atlas bounds remain unchanged.
- **Resize drawable validation** (`MetalTerminalRenderer.swift`): round drawable dimensions to device pixels, reject supplied textures with stale dimensions, and normalize vertices using the actual texture size.

All changes are macOS and Metal paths; marked `NeoLink` in comments where they are not self-explanatory. With none of the new hooks set, upstream behavior is unchanged except for the renderer's row cache and shared shader resources, which produce identical frames.

- **Frame scheduling** (`Mac/MacTerminalView.swift`, `Apple/AppleTerminalView.swift`): optional `displayUpdateScheduler` and `metalFrameScheduler` callbacks let the host synchronize state updates and Metal submission with its window's display link, replacing the fixed 16.67 ms batch timers.
- **Renderer redraws** (`Apple/Metal/MetalTerminalRenderer.swift`, `requestRedraw()`): redraws the renderer starts itself (a frame refused while another was in flight, retries, cursor blink) go through `metalFrameScheduler` when one is installed. Upstream calls `MTKView.setNeedsDisplay`, which draws unpaced on MTKView's own main-queue source.
- **Presentation reporting** (`metalNextFrameTag`, `metalFramePresented`): the host tags a frame and receives its `MTLDrawable.presentedTime`, for latency and cadence measurement.
- **Vsync bypass hook** (`metalPresentsImmediately`): can set `CAMetalLayer.displaySyncEnabled = false` for the next frame. NeoLink leaves it off, including sparse key echoes, so full-screen/direct and composited windows both keep display synchronization.
- **Frame capture** (`allowsMetalFrameCapture`, `metalFrameCapture`): opt-in copy of a rendered frame for tests and the benchmark; views created while it is on are not `framebufferOnly`.
- **Row cache by line identity** (`MetalTerminalRenderer.swift`): rows are cached per `BufferLine` object with the visible row they were built for, and drawn translated (`PlacedRow.offsetY`) after they move. `yDisp` is no longer part of the cache signature. `TerminalView.metalMovedLines` marks lines that moved without changing content (viewport scrolls in `scrollTo`, program region scrolls) so their dirty-range entries do not force a rebuild.
- **Translation uniform** (`Apple/Metal/Shaders.metal`): the vertex shaders' `viewport` is a `float4`; `zw` translates the drawn primitives. All `setVertexBytes` call sites pass `SIMD4<Float>`.
- **Smooth scrolling** (new `Mac/MacSmoothScroll.swift`, `Terminal.swift`): `Terminal.regionScrollObserver` reports full-width region scrolls (CSI L/M at the region's top row, CSI S/T) with the lines that left the region; `screenErasedObserver` reports a full erase (ED 2). `TerminalView` keeps those lines (`RetainedScrollLines`) and exposes `smoothScrollOffset`, `smoothScrollSource`, `smoothScrollRange`, `programScrolled`, `discardRetainedScrollLines()` and `scrollViewport(towardTop:)`. The renderer draws the region at the offset, clipped by a scissor rectangle (`RowClip`), and fills the exposed edge with retained or scrollback lines from its cache.
- **Shared shader resources**: the shader library and pipelines are compiled once per device and pixel format and shared by all renderers; `TerminalView.prepareMetalRenderer()` compiles them ahead of time on any thread. Text and color pipelines keep upstream's different blend factors.
- **Display-link drawable handoff** (`MacTerminalView.swift`, `AppleTerminalView.swift`, `MetalTerminalRenderer.swift`): optional `metalUsesExternalDrawables`, `metalExternalDrawable` and `metalDisplayLayer` let the host acquire through `CAMetalDisplayLink`. The supplied drawable gets a separate render-pass descriptor; the renderer never reads MTKView's drawable/pass descriptor while attached. Host draw closures invoke the renderer directly in that mode, retaining the synchronized-output guard. Without these hooks the upstream acquisition path remains unchanged.
- **Drawable acquisition**: `draw(in:)` builds draw data before taking the drawable. It changes `MTKView.drawableSize` only when the size actually changes, avoiding a redundant layer update each frame.
- **Viewport navigation hook** (`viewportScrollWillChange`, `Apple/AppleTerminalView.swift`): an optional callback before `scrollTo(row:notifyAccessibility:)` lets the host clear a parked scrollback fraction before keyboard/scroller navigation. With no callback, upstream behavior is unchanged.
- **Resource lookup**: `candidateBundles()` also checks the directory containing a bundle, where a SwiftPM test bundle finds `SwiftTerm_SwiftTerm.bundle`.

Additional retained work after the initial rendering snapshot:

- `LocalProcess.swift` uses a 2 ms main-queue parsing time slice. The budget is checked between chunks, not a hard upper bound on an individual parse or input latency; backpressure remains in place.
- Margin-restricted region-scroll reporting lets the host invalidate interpolation for side-by-side terminal windows without moving neighboring text.
- Renderer capture/scroll-state reporting and drawable submission tags support the developer's geometry and pixel-analysis harness. Glyph/content capture is opt-in, and benchmark measurement remains distinct from real trackpad visual acceptance.

Keep this snapshot and its license in source control. Do not patch SwiftPM's transient `.build/checkouts` directory. When updating, diff against the tag, reapply the changes above, and run `swift test` (it includes Metal pixel comparisons of smooth-scrolled frames), `scripts/test-editor.py`, and the benchmark in `docs/RENDERING.md`.
