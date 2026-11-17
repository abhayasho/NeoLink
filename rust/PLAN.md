# NeoLink in Rust: plan, decisions, parity, measurements

Living document for the Rust rebuild (branch `rust-rewrite`, directory `rust/`). The Swift app in `Sources/` stays the
working product until this reaches parity; nothing here replaces or modifies it.

Status line (update every milestone): **Milestone 0: toolchain missing, research and pure-logic groundwork only. Nothing
has been compiled or run yet.**

## 1. Why a rewrite, and what "better" has to mean

The Swift app's remaining complaint is scroll input delay, and Windows is now a target. Measured on the M2 Max 120 Hz
panel (see `docs/RENDERING.md`, passes 3 to 5): scroll lag 27-36 ms (one 60 Hz input interval of resampling buffer,
minus up to one frame of prediction, plus one to two refreshes of presentation), key to display 12-19 ms in the good
state and 27-32 ms in an unexplained three-refresh state, idle about 5% of a core with the benchmark probe, tab
switches about 16 ms, divider dragging hitching.

Targets for the Rust app on the same display:

| Interaction | Target | How it is designed in |
| --- | --- | --- |
| Scroll, first motion | the frame after the first event | deltas go to the next frame; no resampling buffer |
| Scroll, steady | every refresh shows new content | one frame per refresh while motion or a spread remains |
| Key to displayed echo (shell, editor) | about one refresh at the median | a frame starts when input arrives if this refresh's slot is free, not at the next tick |
| Idle | essentially no CPU/GPU | render thread sleeps on a condition variable; nothing is presented unless content changed |
| Queueing | never more than one frame behind the display | at most one frame submitted per refresh, two drawables, presented-time feedback |
| Tab switch | next frame | panes stay alive; a switch is a different scene on the same surface |

## 2. Stack decision

**Not final. The rule set by the task is a timeboxed spike, and the spike needs `cargo`, which is not installed yet.**
What is recorded here is the research that needs no compiler, the leaning it produces, and what the spike must show.

### Verified facts (crates.io and upstream sources, 16 Nov 2026)

GPUI:
- `gpui` on crates.io is 0.2.2 from 22 Oct 2025: more than a year behind upstream. Apache-2.0. Owned by Zed.
- Upstream (`zed-industries/zed`, `crates/`) has since split it into `gpui`, `gpui_platform`, `gpui_macos`,
  `gpui_apple` (Metal renderer), `gpui_windows` (DirectX renderer, DirectWrite, DWM vsync thread), `gpui_wgpu`,
  `gpui_linux`, `gpui_web`. Those are workspace crates, `publish.workspace`, and are **not on crates.io**. Depending on
  current GPUI means a git dependency on the whole Zed repository pinned to a revision, or the third-party snapshot
  below.
- `gpui-pre` (0.3.13, published today, "snapshot of zed@125ca86") is a republished snapshot maintained by the author of
  `gpui-component`, not by Zed; `gpui-component` 0.10 pins it exactly (`=0.3.12`). It works from outside the Zed
  repository, but the release cadence and contents are one person's.
- Windows is a first-class GPUI backend today (Zed ships on Windows).
- **Presentation on macOS 14+ is now `CAMetalDisplayLink` on the main run loop** (`gpui_macos/src/display_link.rs`,
  `gpui_apple/src/metal_renderer.rs`): GPUI draws only into the drawable the link hands out. That is the mechanism this
  project measured at 9-17 ms more on every interaction than taking `nextDrawable()` and presenting on commit
  (`docs/RENDERING.md`, "Direct workspace presentation"). No `preferredFrameLatency` setting was found in that file.
  GPUI exposes no presented-time callback and no way to start a frame at input time; both would need a patched fork.
- GPUI renders on the main thread; a busy main thread delays frames.

winit + wgpu:
- `winit` 0.30.13 stable (0.31 is beta); `wgpu` 30.0.2 (MIT/Apache-2.0), Metal backend on `objc2-metal`, DX12 on Windows.
- `wgpu-hal` 30 exposes what a custom presenter needs on macOS: `metal::Queue::as_raw()` (the `MTLCommandQueue`),
  `metal::Device::texture_from_raw`, `Instance::create_surface_from_layer`. So the app can own the `CAMetalLayer`, call
  `nextDrawable()` itself, render into the drawable's texture through wgpu, and present with its own command buffer on
  the same queue with `addPresentedHandler` for true display timestamps. On Windows the ordinary wgpu surface is used
  (flip model, `desired_maximum_frame_latency = 1`).
- Text: `cosmic-text` 0.19 (shaping, fallback, `swash` rasteriser), MIT/Apache-2.0. The same rasteriser runs on both
  systems, so what is verified on macOS is what Windows draws. It is not CoreText: glyph weight differs from native
  macOS text and has to be tuned and judged by eye.
- Everything else (widgets, layout, IME plumbing, menus) is ours to build. `muda` (native menus, context menus) and
  `rfd` (file dialogs) cover the native pieces on both systems.

### Leaning: winit + wgpu with an own presenter and render thread

1. The complaint is latency, and the two things that set it (when a frame starts, how it is presented) are exactly
   what GPUI does not let an application control. GPUI's current macOS path is the one this project already measured
   as slower.
2. The measurement harness needs the drawable (presented handler) and synthetic input with real timestamps. With GPUI
   that means carrying a patched fork of a framework whose only current distribution is a monorepo or a third-party
   snapshot.
3. A render thread that sleeps until something changes gives idle cost and main-thread independence by construction.
4. One WGSL renderer and one text stack for both systems means the Windows build, which cannot be run here, shares
   nearly all of its drawing code with the verified macOS build.

The cost is real: a UI toolkit (lists, text fields, panels, split views) has to be written, and accessibility and IME
start from winit's level. GPUI would give those for free.

### What the spike must show (once `cargo` exists)

Two minimal programs drawing the same 200 x 60 text grid, typing and scrolling, each for at most half a day:
- `spike-wgpu`: winit + wgpu + own `CAMetalLayer` presenter.
- `spike-gpui`: `gpui-pre`, with a local patch that logs presented times if that can be done inside the timebox.

Decision table: key to presented (p50, p95), first scroll motion, held frames in a 3 s scroll, idle CPU, clean build
time, whether `cargo check --target x86_64-pc-windows-msvc` passes. If GPUI is within 2 ms of the own presenter on the
latency rows, GPUI wins on productivity and this section is rewritten. If the own presenter is not measurably better
the leaning above is wrong and will be recorded as such.

### Confirmed building blocks (versions as of today; all permissively licensed)

| Need | Crate | Version | Notes |
| --- | --- | --- | --- |
| Terminal model | `alacritty_terminal` | 0.26.0 | Apache-2.0; VT parser and grid with scrollback |
| PTY | `portable-pty` | 0.9.0 | MIT; ConPTY on Windows |
| SSH / SFTP | `russh` / `russh-sftp` | 0.65.2 / 3.0.1 | Apache-2.0 |
| Neovim RPC | `rmpv` | 1.3.1 | MIT; msgpack values, own RPC framing |
| Git review | `git` CLI first | - | same bounded porcelain queries as the Swift app; `gix` 0.90 only if a subprocess is too slow |
| ACP | `agent-client-protocol` | 5.3.0 | Apache-2.0; to be checked against ACP v1 stdio behaviour of the Swift client |
| Menus / dialogs | `muda` / `rfd` | 0.21.2 / 0.18.0 | native on both systems |

## 3. Architecture (as designed; adjust after the spike)

```
main thread (winit)            render thread                      I/O threads
  OS events, stamped     -->   sleeps until woken           <--   PTY readers (alacritty_terminal event loops),
  UI state, layout             plans the frame (Pacer)            Neovim RPC reader, SSH, git, agents
  scene description            samples scroll/animation at        each marks its pane dirty and wakes the
  input injection (bench)      the frame's display time           render thread; never touches the main thread
                               snapshots terminal grids
                               encodes, submits, presents
                               receives presented timestamps
```

- **Presentation.** macOS: own `CAMetalLayer` (2 drawables, VSync on), `nextDrawable()` on the render thread, present
  on commit, presented handler feeds the pacer and the harness. Windows: wgpu surface, FIFO, frame latency 1.
- **Pacing (`neolink-core::pacer`).** At most one frame per refresh slot. If the slot for the next refresh is free when
  something changes, the frame starts immediately; otherwise it starts at the slot boundary. Nothing is presented when
  nothing changed.
- **Scrolling (`neolink-core::scroll`).** Deltas reach the next frame. Smoothing is off for input at the display's
  rate. The only smoothing is *spreading*: when reports are measurably slower than the display (60 Hz finger on a
  120 Hz panel, or a creeping finger at one point every 40-250 ms) an event's distance is released linearly over the
  measured report interval, starting with the next frame, capped at 150 ms. The added delay is reported by the harness.
  To be enabled by default only if the immediate mode measures held frames for that input (section 5).
- **Gesture state** comes from the OS phases; a gap with the fingers down is never the end of a gesture. Shell
  scrollback rests at any pixel; nothing settles.
- **Text.** Glyph atlas keyed by font, glyph and size; monospace cells snapped to whole device pixels (one raster
  phase); UI text with four horizontal subpixel bins.
- **Harness.** In the app (`NEOLINK_BENCHMARK=...`), same scenario names, scroll profiles and analysis formulas as
  `Sources/Rendering/InteractionBenchmark.swift`, so numbers line up with the Swift app's reports.

## 4. Parity checklist (from README, AGENTS.md and docs/)

Legend: done / partial / not started. "Verified" names the system it was actually run on.

| Area | Feature | State | Verified on |
| --- | --- | --- | --- |
| Shell | Window, GPU text, 120 Hz demand-driven presentation | not started | - |
| Shell | Local shell tabs on a real PTY, persistent across tab switches | not started | - |
| Shell | Pixel-smooth scrollback, fractional rest, mouse-aware programs get wheel reports | not started | - |
| Shell | Text size 9-32 pt, persisted; copy/paste/selection | not started | - |
| Shell | Working-directory reporting from the shell (per-tab browser state) | not started | - |
| Shell | IME / marked text | not started | - |
| Harness | Synthetic input with timestamps, busy main thread, key-to-present, evenness, idle CPU | not started | - |
| Explorer | Lazy project tree, compact folders, reveal active file, filter | not started | - |
| Explorer | Git decorations and ignore dimming, diagnostics counters, icons | not started | - |
| Explorer | File actions (create, rename, trash, copy path, open terminal here, drag/drop copy) | not started | - |
| Explorer | Folder List mode with sorts; Follow Terminal | not started | - |
| Editor | Shared headless Neovim, `ext_linegrid` client, `Resources/Editor/neolink.lua` | not started | - |
| Editor | Tabs, open/save/close with dirty prompts, external-change conflict check | not started | - |
| Editor | Correct-buffer guarantee on switch (`neolink_selection` ordering), snapshot cache rules | not started | - |
| Editor | Smooth vertical scroll, pixel-smooth horizontal scroll, axis lock | not started | - |
| Editor | LSP/Tree-sitter limits (2 MiB, 128 MiB), Run file, REPLs, folding menu | not started | - |
| Editor | Native text fallback without `nvim`; PDF viewer tabs | not started | - |
| Remote | SSH terminal tabs, saved connections, validated creation | not started | - |
| Remote | SFTP browser: list, create, rename, delete, upload, download, read-only preview | not started | - |
| Remote | Credential storage (Keychain / Windows Credential Manager) | not started | - |
| Tools | Quick Open (50,000 paths, fuzzy ranking) | not started | - |
| Tools | Find in Files (ripgrep, 180 ms debounce, bounds from CODING_WORKSPACE.md) | not started | - |
| Git | Status/diff review, stage/unstage, commit, branches, read-only stash preview | not started | - |
| Agents | ACP v1 stdio conversations: streaming, tool previews, permissions, cancel, modes, MCP config | not started | - |
| Agents | Agent terminals (Claude Code / custom CLI) in panel or tab | not started | - |
| Shell UI | Menus, shortcuts, panel visibility persistence, recent projects, Performance Monitor | not started | - |
| Packaging | macOS `.app` (resources, signing), Windows artifact, CI on both | not started | - |

## 5. Measurements

None yet. Layout for when they exist: same machine and display mode as the Swift numbers, frontmost, unlocked,
`caffeinate -d -u`, `NEOLINK_BENCHMARK_BUSY=1`, three alternating pairs against `.build/release/NeoLink`. Synthetic
input is not a physical trackpad and will be labelled as such.

## 6. Windows

No Windows machine is available. Verification will be whatever a GitHub Actions `windows-latest` job runs (build and
tests) once pushing the branch is approved, plus a local `cargo check --target x86_64-pc-windows-msvc`. Until a job
has run, Windows support is "designed for, not compiled".

## 7. Log

- 2026-11-16: `cargo`, `rustc`, `rustup` not installed; install requested. Read the specification documents and the
  Swift benchmark; checked crate versions, licences and GPUI's current structure and presentation path; created the
  `rust-rewrite` branch as a separate worktree (the main checkout's branch is untouched); wrote this plan and the
  compiler-independent logic in `crates/neolink-core` (not yet compiled).
