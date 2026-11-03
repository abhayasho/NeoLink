# AGENTS.md

NeoLink is a native macOS (13+) SwiftUI/AppKit coding workspace: tabbed terminal + SSH/SFTP, shared Neovim editor, native ACP agents, Git review.

## Build & run
- `swift build` / `swift run` — debug executable from repo root.
- `./scripts/build-app.sh` — release `NeoLink.app` in repo root; copies `Resources/`, embeds `SwiftTerm_SwiftTerm.bundle`, precompiles Metal shaders when `xcrun metal` exists, then ad-hoc signs. Set `NEOLINK_SIGNING_IDENTITY` for stable signing. `NeoLink.app` and `.build/` are gitignored build artifacts.
- One executable module: everything under `Sources/` is the `NeoLink` target. The directory split (`Terminal/`, `Documents/`, etc.) is organizational only, so cross-folder `internal` access is normal. No `@main`; `Sources/main.swift` starts `NSApplication` directly.

## Verify
- `GlyphRasterizationTests` compares all 16 cached glyph phases with direct CoreText; preserve phase-aware atlas keys, integer-pixel quads, and stale-drawable size checks. Terminal display updates drain on the owning Metal callback, not two independent clocks.
- `swift test` — native regression tests, temporary files only; no SSH server or credentials needed. `SmoothScrollRenderingTests` renders with Metal and compares pixels (skips without a GPU).
- `python3 scripts/test-editor.py` — real Neovim runtime regression; requires `nvim` on `PATH`. Uses `Resources/Editor/neolink.lua` and checks buffers, saves, external conflicts, UTF-16/CRLF, large-file mode, optional Pyright LSP.
- `python3 scripts/test-benchmark.py` — offline build-failure/scroll-validity checks; does not launch the GUI.
- The project tree retains a reusable-row `NSTableView` for input, accessibility and fallback (`Sources/FileBrowser/ExplorerTableView.swift`). `ExplorerMetalView.swift` composes cached row artwork with Metal; CoreText rasterization runs off-thread. Folder List and SFTP retain their own views.
- Explorer Metal composition retains a native-resolution GPU strip (at most 16 MiB extra) with nearby rows; reuse only within its row range and matching scene revision/backing scale/width. Preserve pixel equality with the per-row reference path and invalidate selection, hover, content and resize changes. Benchmark traces/profiling are opt-in.
- Covered explorer cells retain their accessibility/hit-testing identity but hide and defer native artwork; restore the latest artwork on fallback. Precise unmodified trackpad deltas use `ExplorerScrollView` while Metal covers the table; other events retain AppKit behavior. Surface-owned animations advance in `prepareDrawable`, after parsed output and before encoding, with native-clock fallback.
- Explorer snapshots coalesce during live scrolling/momentum and apply after 100 ms of quiet; explicit navigation takes precedence. Local shell scrollback preserves its fractional position at rest; full-screen program scrolling retains the grid-alignment model. Metal presentation keeps VSync enabled, including immediate key echoes.
- ACP tests launch the offline fixture `scripts/fixtures/acp-agent.py` via `python3`.
- No CI, linter, or formatter config exists in the repo; those two commands are the verification path.
- Rendering/latency changes: run the interaction benchmark (`NEOLINK_BENCHMARK=...`, see `docs/RENDERING.md`) on a release build with the window frontmost and the screen unlocked; an occluded window pauses its clock and invalidates the run.
- `NEOLINK_BENCHMARK=render-motion` animates both terminal scrollback and the Metal explorer without input injection; it reports actual presented content changes. Offscreen `ExplorerMetalTests` verify pixels even when the screen is locked, not on-screen cadence. Surface Metal callbacks run separately from the window clock; do not reintroduce whole-window display passes or fetch MTKView drawables while a Metal display link owns the layer.

## Architecture wiring
- `Sources/main.swift` creates the `WorkspaceWindow` + `WindowFrameScheduler` (frame pacing, capped at 120 Hz); `Sources/ContentView.swift` composes sidebar, file browser, tabbed terminals, and right agent panel.
- `Sources/Tabs/TabsController.swift` owns all workspace tabs (`WorkspaceTab`: terminal or document) and the single shared `NeovimSession`.
- `Sources/Documents/NeovimSession.swift` lazily starts one Neovim per app in `/tmp/neolink-*`, communicates via a unix socket and watched `status.json`, and uses `Resources/Editor/neolink.lua`. Missing `nvim` degrades to the native text editor.
- Custom workspace GPU engine: `Sources/Rendering/NeoGPU/` owns retained instanced scenes, pixel clipping, shared resources and one macOS 14+ display-link deadline/drawable/command buffer/presentation for visible terminal/editor and explorer panes. The independent window clock pauses during hosting. Native views retain input/accessibility; Quick Open/Git overlays temporarily restore independent rendering. `NEOLINK_GPUI_WORKSPACE=0` selects the independent path for same-binary release comparisons. Native panels/PDFs are not rewritten.
- GPU rendering: `Sources/Terminal/TerminalRendering.swift`, `Sources/Rendering/NeoGPU/NeoGPUFrameSource.swift` + `Sources/Rendering/WindowFrameScheduler.swift` (display-link pacing, immediate frames for typed output, presentation backpressure, latency stats), persisted View-menu preference. Trackpad smooth scrolling: `Sources/Terminal/SmoothScroll.swift`. SwiftTerm's Metal bundle must be present in packaged apps.
- Agents: ACP transport/session in `Sources/Agents/ACPTransport.swift` and `ACPSession.swift`; terminal agents use `CodingAgent`/launcher. See `docs/AGENT_GUIDE.md`.
- Project access uses security-scoped bookmarks in `Sources/Workspace/WorkspaceAccess.swift`; Git review is `Sources/Workspace/GitChanges*` and explorer decoration is `Sources/FileBrowser/ExplorerGit.swift`.

## Repo-specific constraints
- `Package.swift` intentionally uses `swift-tools-version: 5.10` (Swift 5 language mode) to avoid Swift 6 concurrency conflicts with `swift-ssh-client`. Don't bump it casually.
- SwiftTerm is a pinned local snapshot (`Vendor/SwiftTerm`, v1.20.0), not a normal remote package. NeoLink changed its frame scheduling, Metal renderer (row cache by line identity, smooth-scroll region, shared shaders, a `float4` viewport uniform in `Shaders.metal`) and region-scroll reporting in `Terminal.swift`; `Vendor/SwiftTerm/UPSTREAM.md` lists every change. Read it before updating and reapply/test them.
- `Resources/` is not a SwiftPM resource target. Code falls back to `#filePath`-relative paths; `scripts/build-app.sh` must copy `Resources/Editor` and the SwiftTerm bundle for a packaged app to work.
- Resource limits are deliberate: >2 MiB files skip LSP/Tree-sitter, code tabs cap at 128 MiB, SFTP remote previews are read-only. See `docs/CODING_WORKSPACE.md`, `docs/RENDERING.md`, and `docs/EXPLORER.md` for behavior worth preserving.
- Ad-hoc rebuilds can change app identity and re-trigger macOS folder permissions; bookmark behavior depends on consistent signing.
