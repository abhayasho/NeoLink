# NeoLink in Rust: plan, decisions, parity, measurements

Living document for the Rust rebuild (branch `rust-rewrite`, directory `rust/`). The Swift app in `Sources/` stays the
working product until this reaches parity; nothing here replaces or modifies it.

Status line (update every milestone): **Milestone 1 is done and measured on macOS; CI builds and unit-tests it on
macOS and Windows. Milestone 2 is partly done: the Neovim editor and a basic explorer work on macOS (synthetic input
and captures only). Milestones 3-5 not started.**

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

**Decided by the spike (16 Nov 2026): `winit` + `wgpu` with an own presenter and a render thread.** GPUI is not used.

### Spike result

Two programs drawing the same 160 x 50 monospace grid, changing one row on a timer (`sparse`: every 90-250 ms,
`dense`: every 33 ms) or every frame (`motion`). Each logs when the model changed, when the frame was committed and
when the drawable's presented handler says it reached the display. M2 Max, built-in 120 Hz panel, on battery, 7-8 s
per run, one run per cell (the differences are far outside run-to-run noise; they are not a statistical study).
`spikes/gpui` holds the GPUI program and the renderer patch; `SPIKE_MODE=... neolink --spike` is the other.

| Change to displayed, p50 / p95 (ms) | Own presenter | GPUI as shipped (`CAMetalDisplayLink`) | GPUI forced to `nextDrawable()` |
| --- | --- | --- | --- |
| Full screen, sparse | **7.7 / 11.3** | 19.7 / 24.5 | 15.2 / 18.4 |
| Full screen, dense | **7.7 / 9.4** | 20.8 / 24.9 | 11.3 / 15.6 |
| Windowed, sparse | 22.6 / 27.1 | 49.3 / 49.4 | 24.3 / 28.9 |
| Windowed, dense | 22.2 / 26.8 | 45.7 / 49.9 | 24.8 / 30.2 |
| Change to commit (waiting for a tick, drawing), p50 | 1.6-2.4 | 5.3-9.2 | 6.1-8.9 |
| Motion, full screen: commit to displayed p50; refreshes without a frame | 6.2; 7 of 1162 | 14.5; 24 of 1109 | 16.1; 7 of 1048 |
| Motion, windowed: commit to displayed p50; refreshes without a frame | 20.0; 7 of 1159 | 40.3; 0 of 1161 | 27.0; 0 of 1164 |

The refreshes without a frame are at the start of each run in all three (the first second after the window appears).
An earlier own-presenter run of full screen sparse, before the pacer learned the commit margin, measured 4.9 / 7.2.

What the spike established beyond the table:

- **Where latency comes from on this system.** The compositor latches what was committed before a refresh and shows
  it a fixed number of refreshes later. For a window that number is two (commit to display is never under 16.7 ms).
  In native full screen with the window being one opaque Metal layer it is zero: the layer is scanned out directly,
  and a frame committed 2.7 ms or more before a refresh is on the display at that refresh. The Swift app composites a
  transparent Metal overlay over native views, which is one reason it measured 11-14 ms from frame preparation to
  display in full screen. A single opaque layer for the whole window is therefore a design rule here, not a detail.
- **GPUI's default path costs three to five refreshes** on this machine (commit to display 14.5 ms in full screen,
  40 ms windowed), and about half of its sparse frames report no display time at all. Forcing its older path helps,
  but frames still start at a display-link tick on the main thread (6-9 ms after the change), and continuous motion
  settles one to two refreshes behind (a standing queue).
- **Starting the frame when the change arrives** instead of at the next tick is worth about 4-6 ms by itself.
- Windowed latency (about 22 ms) is the system's; neither stack can do better there with VSync on.

Decision rule from before the spike: GPUI wins if it is within 2 ms. It is 3.6 ms (best case, dense full screen with
its legacy path) to 27 ms behind, and each better GPUI number needs a patched renderer.

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

### Why the other reasons still hold

The measurement harness needs the drawable (presented handler) and control over when a frame starts; with GPUI both
mean carrying a patched fork of a framework whose only current distribution is a monorepo or a third-party snapshot.
One WGSL renderer and one text stack serve both systems, so the Windows build, which cannot be run here, shares its
drawing code with the verified macOS build. The cost is real: lists, text fields, panels and split views are ours to
write, and accessibility and IME start from winit's level.

### Confirmed building blocks (versions as of today; all permissively licensed)

| Need | Crate | Version | Notes |
| --- | --- | --- | --- |
| Terminal model | `alacritty_terminal` | 0.26.0 | Apache-2.0; VT parser and grid with scrollback |
| PTY | `alacritty_terminal::tty` | 0.26.0 | its own PTY layer (ConPTY on Windows), so `portable-pty` is not needed |
| SSH / SFTP | `russh` / `russh-sftp` | 0.65.2 / 3.0.1 | Apache-2.0 |
| Neovim RPC | `rmpv` | 1.3.1 | MIT; msgpack values, own RPC framing |
| Git review | `git` CLI first | - | same bounded porcelain queries as the Swift app; `gix` 0.90 only if a subprocess is too slow |
| ACP | `agent-client-protocol` | 5.3.0 | Apache-2.0; to be checked against ACP v1 stdio behaviour of the Swift client |
| Menus / dialogs | `muda` / `rfd` | 0.21.2 / 0.18.0 | native on both systems |

## 3. Architecture

```
main thread (winit)            render thread                      I/O threads
  OS events, stamped     -->   parked until invalidated     <--   PTY readers (alacritty_terminal event loops);
  shortcuts, key encoding      plans the frame (Pacer)            later: Neovim RPC, SSH, git, agents
  benchmark injection          builds the scene, skips it         each invalidates lock-free and never
                               if nothing visible changed         touches the main thread
                               acquires, encodes, presents
                               receives displayed timestamps
```

Crates: `neolink-core` (no dependencies: scroll model, pacer, benchmark profiles and analysis, statistics; 36 tests)
and `neolink` (the app). Source map of the app: `frame.rs` render thread and frame log, `present/` presenters,
`render.rs` quads and retained rows, `text.rs` glyphs, `term.rs` terminal pane, `workspace.rs` tabs and layout,
`input.rs` key encoding, `bench.rs` harness, `capture.rs` off-screen PNG, `spike.rs` the stack spike.

Rules the measurements produced (each has a number behind it in section 5):

- **One opaque layer.** Everything is drawn by the one renderer into one opaque `CAMetalLayer`: no native views or
  transparent overlays over it, so full screen can be scanned out directly.
- **Own presenter (macOS).** The app calls `nextDrawable()` itself and presents on commit with a presented handler.
  Three drawables: with two, `nextDrawable()` blocks until the next refresh whenever a frame is waiting and that frame
  then shows two events (108 of 300 scroll frames carried zero or two events). The second, empty command buffer per
  frame (wgpu 30 refuses `presentDrawable` on its own encoder) is a known cost.
- **Pacing (`neolink-core::pacer`).** A frame is drawn only when something changed. At most one commit per refresh.
  A frame starts the moment a change arrives if the coming refresh has no frame yet, otherwise just after that
  refresh. Depth (refreshes between latch and display: 0 scanned out directly, 2 through the compositor) and the
  commit margin (about 2.7 ms and 0.3 ms) are learned from displayed times. Three late frames in a row give up one
  slot (a standing queue); a depth that survives three such drains is adopted.
- **No frame for nothing.** The scene is built before a drawable is taken; if its signature equals the last frame's
  (output in a hidden tab, scroll distance under a pixel) nothing is presented. A key press does not draw: the frame
  belongs to the program's echo (drawing at the key cost 8 ms: the echo found its refresh taken).
- **Keep the panel fast while the user is active.** A panel given no frames lowers its refresh rate within a second:
  the next frame took 6 ms after a 0.2-0.4 s pause, 13 ms after 1 s and about 50 ms after several. For 3 s after the
  last input (`NEOLINK_WARM_SECONDS`) the last frame is repeated every 250 ms (`NEOLINK_WARM_MS`, 0 = off). After
  that the render thread is parked and nothing runs.
- **Scrolling (`neolink-core::scroll`).** Deltas reach the next frame; nothing is resampled or predicted. Input slower
  than 1.5 refreshes per report is *spread*: an event's distance is released linearly over the measured report
  interval starting with the next frame, capped at 150 ms. `NEOLINK_SCROLL_SMOOTHING=off` disables it. Frames are
  scheduled only for the refreshes in which a device pixel changes. Shell scrollback rests at any pixel.
- **Retained rows.** A terminal row becomes GPU instances once, keyed by its resolved cells; later frames draw it
  with a 16-byte translation (wgpu immediates). While the grid is unchanged a scroll looks at no cell.
- **Text.** cosmic-text/swash on every system; monospace cells are whole device pixels (one raster phase). Combining
  marks stored as zero-width extras are not drawn yet.

## 4. Parity checklist (from README, AGENTS.md and docs/)

Legend: done / partial / not started. "Verified" names the system it was actually run on. "macOS, synthetic" means
exercised by the in-app benchmark or the capture, not by a person at the keyboard.

| Area | Feature | State | Verified on |
| --- | --- | --- | --- |
| Shell | Window, GPU text, demand-driven presentation at 120 Hz | done | macOS, synthetic (capture: `docs/milestone-1-capture.png`) |
| Shell | Local shell tabs on a real PTY, alive across tab switches (Cmd-T/W, Cmd-1..9, Ctrl-Tab, click) | done | macOS, synthetic (`ui-tabs`); shortcuts not exercised by a person |
| Shell | Pixel-smooth scrollback, fractional rest; wheel reports for mouse-aware and alternate-screen programs | partial | scrollback: macOS, synthetic; program wheel reports: written, never exercised |
| Shell | Colours, bold/italic/underline/strike/inverse/dim, wide characters, emoji, cursor shapes | partial | macOS capture; combining marks missing, cursor blink missing |
| Shell | Text size 9-32 pt (Cmd +/-/0) | partial | written, not exercised; not persisted |
| Shell | Paste (Cmd-V, bracketed); copy and mouse selection | partial | paste written, not exercised; selection not started |
| Shell | Working-directory reporting from the shell, titles | partial | OSC titles handled; directory tracking not started |
| Shell | IME / marked text; accessibility | not started | - |
| Shell | Window resize (smooth live resize), display changes | partial | resize relays out the grid; live-resize smoothness not measured |
| Harness | Synthetic input with timestamps, busy main thread, key-to-display, evenness, idle CPU, per-thread CPU | done | macOS |
| Explorer | Lazy project tree, compact folders, reveal active file, filter | partial | tree, compaction, reveal, active-file highlight, pixel scrolling, refresh on save and window activation: macOS capture and unit tests; no filter, no keyboard navigation, no watcher for outside changes |
| Explorer | Git decorations and ignore dimming, diagnostics counters, icons | partial | status letters and colours, folder summaries, ignored entries dimmed (parser unit-tested, macOS capture); no deleted placeholders, diagnostics counters or icons |
| Explorer | File actions (create, rename, trash, copy path, open terminal here, drag/drop copy) | not started | - |
| Explorer | Folder List mode with sorts; Follow Terminal | not started | - |
| Editor | Shared embedded Neovim, `ext_linegrid` client, `Resources/Editor/neolink.lua` unchanged | done | macOS: real-Neovim tests, capture, `editor-type` |
| Editor | Tabs, open/save/close with dirty prompts, external-change conflict check | partial | open, save, refused save after an outside change, live unsaved marker: tested; closing an unsaved document warns in a banner and closes on the second request (not a Save / Don't Save / Cancel dialog, and not exercised by a person) |
| Editor | Correct-buffer guarantee on switch (`neolink_selection` ordering), snapshot cache rules | done | macOS and Windows CI against real Neovim: 40 alternations, 10 rapid switches with typing, remembered screens equal to Neovim's redraw, a touched hidden buffer loses its screen. The diagnostics-flag rule is not checked (nothing in this app toggles it) |
| Editor | Smooth vertical scroll, pixel-smooth horizontal scroll, axis lock | not started | the wheel scrolls the editor by whole lines; axis lock logic exists in `neolink-core` with tests |
| Editor | LSP/Tree-sitter limits (2 MiB, 128 MiB), Run file, REPLs, folding menu | partial | the limits live in `neolink.lua` and apply; Tree-sitter highlighting seen in the capture; LSP not exercised; no Run, REPL or menus |
| Editor | Native text fallback without `nvim`; PDF viewer tabs | not started | - |
| Remote | SSH terminal tabs, saved connections, validated creation | not started | - |
| Remote | SFTP browser: list, create, rename, delete, upload, download, read-only preview | not started | - |
| Remote | Credential storage (Keychain / Windows Credential Manager) | not started | - |
| Tools | Quick Open (50,000 paths, fuzzy ranking) | not started | - |
| Tools | Find in Files (ripgrep, 180 ms debounce, bounds from CODING_WORKSPACE.md) | not started | - |
| Git | Status/diff review, stage/unstage, commit, branches, read-only stash preview | not started | - |
| Agents | ACP v1 stdio conversations: streaming, tool previews, permissions, cancel, modes, MCP config | not started | - |
| Agents | Agent terminals (Claude Code / custom CLI) in panel or tab | not started | - |
| Shell UI | Menus, panel visibility persistence, recent projects, Performance Monitor | not started | winit's default macOS menu only |
| Packaging | macOS `.app` (resources, signing), Windows artifact, CI on both | partial | CI builds, tests and uploads a Windows executable on every push; no `.app`, no installer |

## 5. Measurements (milestone 1)

M2 Max, built-in 120 Hz panel, on battery, both apps frontmost and unlocked under `caffeinate -d -u`. Swift app:
`.build/release/NeoLink` at `32dde85` (binary `dac58eda63b7`, the installed build). Rust app: binary `1b81776288ba`
for the paired runs, `ffb565b77c0c` for the windowed runs (differs only in the pacer's three-late-frames rule).
Rust grid 245 x 72 at 12 pt Menlo in full screen; the Swift app's grid differs slightly (its chrome differs).
Raw reports: `docs/milestone-1/*.json.gz`. Tools: `scripts/compare-reports.py`, `scripts/show-report.py`.

**All input is synthetic.** Both apps create events on a timer with their sampling time and deliver them on the main
thread; neither measurement includes the operating system's event delivery, a physical trackpad or a keyboard. Three
alternating pairs per condition; values are runs 1 / 2 / 3. Scroll metrics are those of
`InteractionBenchmark.swift`, computed with the same formulas.

### The display has two states, and they move both apps together

Frames reach this display in one of two ways. Either a commit is on the glass at the next refresh it is in time for
("direct"), or two refreshes later ("composited"). Windowed is always composited. Full screen is usually direct, but
not always: in one set of three pairs (kept out of the tables below; raw reports in `docs/milestone-1/composited-set/`, taken with an earlier Rust binary) both
apps ran the whole time about 17 ms slower (Swift typing 28-30 ms, Rust 23-25 ms), and single Rust scenarios
inside otherwise direct runs came out composited twice. The Rust report states the path per scenario
(`displayPath`). Earlier Swift figures in `docs/RENDERING.md` (typing 27-32 ms, scroll lag 26-36 ms) match the
composited state; its 12-19 ms figures match the direct one. What selects the state was not found.

### Full screen, direct state, main thread not busy

| | Swift app | Rust app |
| --- | --- | --- |
| Typing (75 keys at 25/s), key to display p50 (ms) | 14.8 / 15.2 / 13.7 | **5.6 / 7.0 / 7.1** |
| Typing p95 (ms) | 20.6 / 23.4 / 23.8 | **8.1 / 8.7 / 8.8** |
| Typing, slowest key (ms) | **20.6 / 27.6 / 31.3** | 43.1 / 27.0 / 43.8 |
| A key every 1.6 s, p50 (ms) | 16.3 / 17.6 / 18.0 | **8.0 / 8.3 / 9.2** |
| `terminal-scroll` (120 Hz reports) lag (ms) | 15 / 10 / 10 | 8 / 12 (composited) / 9 |
| `terminal-scroll` first motion (ms) | 16.2 / 16.4 / 11.2 | **7.6 / 4.3 / 4.7** |
| `terminal-scroll` uneven frames of about 300; jerk p95 (px) | 25, 7, 9; 1.99, 0.02, 1.01 | **2, 4, 3; 0.02, 0, 0** |
| `terminal-swell` (60 Hz, speed varying) lag (ms) | 20 / 19 / - | 17 / 17 / 16 |
| `terminal-swell` uneven frames of about 360 | 37 / 28 / - | **5 / 4 / 3** |
| `terminal-flick` lag; first motion (ms) | 12, 12, 12; 11.4, 11.0, 9.1 | 21 (composited), 8, 9; 14.3, 6.0, 6.7 |
| `terminal-flick` uneven frames of about 125; jerk p95 (px) | **17, 20, 19**; 7.8, 7.3, 9.2 | 40, 41, 41; 24.7, 2.9, 2.9 |
| `terminal-flick` refreshes missed while moving | **1 / 2 / 1** | 5 / 4 / 4 |
| `terminal-crawl` lag (ms); frames presented without motion | 58, 57, -; 4, 5, - | **44, 43, 42; 0, 0, 0** |
| `terminal-crawl` burst frames; step-gap spread (input itself: 0.70) | **0, 0; 0.71, 0.70** | 1, 1, 1; 0.76, 0.77, 0.78 |
| Idle CPU (% of a core) | 1.2 / 5.1 / 4.8 | **0.1 / 0.1 / 0.1** |
| CPU while scrolling (`terminal-scroll`, % of a core) | **5.8 / 6.6 / 6.8** | 17.6 / 15.7 / 16.3 (benchmark timers excluded) |

One Swift run produced no crawl or swell result. Rust-only scenarios, same runs: `terminal-steady60` lag 23 / 15 / 17
ms with 44 / 4 / 4 uneven frames of 360; `ui-tabs` (24 switches between two shells) switch to display p50
5.3-8.0 ms, worst 14.6 ms.

### Full screen, direct state, main thread busy (`NEOLINK_BENCHMARK_BUSY=1`, scroll scenarios only)

| | Swift app | Rust app |
| --- | --- | --- |
| Typing p50 (ms) | 13.0 / 14.7 / 15.0 | **6.5 / 7.0 / 6.2** |
| A key every 1.6 s, p50 (ms) | 13.4 / 18.7 / 19.1 | **6.8 / 6.6 / 7.4** |
| `terminal-scroll` lag; first motion (ms) | 11, 19, 11; 12.9, 10.8, 15.1 | 14, 12, 10; **6.3, 6.3, 8.8** |
| `terminal-scroll` uneven frames; refreshes missed | **7, 16, 13; 0, 1, 0** | 4, 13, 31; 1, 5, 7 |
| `terminal-swell` lag (ms); uneven frames | 20, 20, 20; 36, 37, 56 | 21, 21, 22; **6, 5, 4** |
| `terminal-flick` lag (ms); uneven frames | 12, 12, 12; **26, 27, 16** | 9, 7, 8; 41, 38, 39 |
| `terminal-crawl` lag (ms) | 58 / 58 / 58 | **43 / 43 / 44** |
| Idle CPU | 5.0 / 5.0 / 5.2 | **0.1 / 0.1 / 0.1** |
| CPU while scrolling (`terminal-scroll`) | **24.6 / 24.8 / 25.7** | 30.9 / 31.9 / 29.4 (timers excluded) |

### Windowed (always composited), main thread not busy, two runs each

| | Swift app | Rust app |
| --- | --- | --- |
| Typing p50; p95 (ms) | 28.3, 29.6; 36.5, 33.0 | **21.9, 22.8; 26.0, 26.1** |
| `terminal-scroll` lag; first motion (ms) | 27, 27; 27.6, 28.8 | 26, 26; 18.7, 25.4 |
| `terminal-scroll` uneven frames; refreshes missed | 48, 11; **0, 0** | 15, 12; 5, 3 |
| `terminal-swell` lag (ms); uneven frames; refreshes missed | 37, 37; 43, 38; **1, 1** | 35, 34; 24, 17; 10, 6 |
| `terminal-flick` lag (ms); uneven frames | 29, 29; **18, 33** | 24, 25; 39, 48 |
| CPU while scrolling (`terminal-scroll`) | **8.0 / 8.3** | 13.1 / 12.3 (timers excluded) |

### Reading it honestly

- **Typing is where the rewrite clearly wins**: about half the Swift app's latency in the direct state (6-7 ms
  against 13-15 ms at the median, 8-9 against 16-24 at p95) and 6-7 ms less windowed. The target of about one
  refresh at the median is met in full screen and cannot be met in a window (the compositor alone takes two).
- **The slowest key is worse in the Rust app** (27-50 ms against 21-31 ms): it is the first key after more than 3 s
  without input, when the panel has slowed down. Within 3 s of the last input it is 8 ms.
- **Idle is 0.1% of a core against about 5%.**
- **Scroll lag is not clearly better.** With the display in the same state the two apps are within a few
  milliseconds of each other (8-14 ms against 10-19 ms in full screen, 26 against 27 windowed): the Swift app's
  predictor cancels most of its resampling delay on steady synthetic input, and the Rust app's lag swings by a whole
  refresh with the phase between events and refreshes. First visible motion is 4-9 ms against 9-16 ms. Slow
  scrolling trails less (43 ms against 58 ms). What the user reported as input delay may be the composited state
  rather than the resampler; that was not established.
- **Evenness is mixed.** Steady and varying-speed scrolling is more even (2-6 uneven frames against 7-56). Flicks
  are less even by the frame count (about 40 against 16-27 of 125) though their worst steps are smaller: momentum
  reports are whole points and the Rust app draws them as they come, where the Swift app's resampler averages them.
  With the main thread held busy, 120 Hz scrolling missed more refreshes than the Swift app in two of three runs
  (an event delivered late lands in the next frame). In a window the Rust app misses a few more refreshes (3-10
  against 0-1 in 300).
- **CPU while scrolling is about 2.5 times the Swift app's** (16-18% of a core against 6-7% in full screen): about
  6% on the render thread (wgpu's encoding and submit, 0.5 ms a frame), about 7% in the kernel, most of the rest in
  system threads. The retained rows halved the render thread's share; the second command buffer per frame and
  wgpu's per-frame overhead remain. This is the main regression against the Swift app.
- Not measured: a physical trackpad or keyboard, energy, memory, the busy option's realism for an app whose main
  thread does no layout, other displays, 60 Hz, and anything on Windows.

## 6. Windows

No Windows machine is available. What has been established, all of it by GitHub Actions on `windows-latest`
(`.github/workflows/rust.yml`): the workspace **compiles and links with MSVC and the unit tests pass** (first green
run: 17 Nov 2026, commit `4a73914`, milestone 1). The job opens no window, so **rendering, input, the PTY, fonts and
latency on Windows have never executed**. On Windows the presenter is the plain wgpu surface (no display timestamps),
the PTY is `alacritty_terminal`'s ConPTY backend, and fonts fall back to Cascadia/Consolas.

The editor client's tests run against a real Neovim (0.12.6, installed by the job) on Windows too. The first such
run (commit `14c1068`) passed four of six and failed two for a real reason: `std::fs::canonicalize` returns
`\\?\C:\...` there and Neovim names the same file `C:\...`, so paths did not compare equal. The app had the same flaw
(tab matching, unsaved marker, explorer highlight); `neolink_core::paths::canonical` now removes that prefix, and the next run (commit `821875e`,
17 Nov 2026) passed all 64 tests on Windows, the five real-Neovim tests included: the editor client opens, types,
saves, refuses a conflicting save, switches buffers correctly and resizes against Neovim on Windows. The tests skip
themselves if `nvim` is missing, so check the run's log rather than its colour.
`cargo check -p neolink --target x86_64-pc-windows-msvc` on the Mac catches type errors before a push.

## 6a. Milestone 2 so far (editor and explorer)

- **Editor.** `neolink-nvim` runs `nvim --embed` with the Swift app's `Resources/Editor/neolink.lua` unchanged, as
  an `ext_linegrid` UI. Commands, redraws and the `neolink_selection` notice share one ordered channel; a document
  tab is shown only when the notice for its request has been read, and until then the pane (and the highlighted
  tab) stay on what was confirmed before.
- **Input needs its own rule, found by test:** Neovim handles `nvim_input` the moment it is read, ahead of an `open`
  that is still queued, and runs queued requests back to back. So keys sent right after a switch were typed into the
  buffer being left. The client keeps one switch in flight and holds everything sent after it until that switch is
  confirmed (`keys_sent_right_after_a_switch_reach_the_new_buffer`). Without the hold the outcome is a race: in
  about a dozen runs the keys reached the old buffer every time, then once the new one after an unrelated change.
- **Explorer.** `neolink_core::tree` (tests) plus a sidebar drawn by the same renderer; folders are read on
  background threads; Cmd-B hides it; a folder on the command line is the project.
- Captures: `docs/milestone-2-editor-capture.png`, `docs/milestone-2-explorer-capture.png`.

- **Remembered screens.** When Neovim leaves a buffer it says so after a redraw; the client keeps that screen (eight
  buffers at most) and drops it when the hidden buffer is touched. A document selected again is shown from it at once
  if Neovim left it in plain insert mode, grid and styles are unchanged and the file on disk has the same size,
  time and inode; Neovim's screen replaces it on confirmation and input is held until then
  (`NEOLINK_EDITOR_CACHE=0` turns it off).

Measured (full screen, direct state, synthetic input, two runs each; `docs/milestone-2/`): editor typing key to
display p50 5.3 / 7.3 ms, p95 8.1 / 9.3 ms (the Swift app's best documented figures: 12-19 ms). Switching between
two documents, request to the right buffer on the display: **p50 5.4 / 5.6 ms, p95 13.8 / 13.4 ms, worst 22 ms with
remembered screens** (21 and 22 of 26 switches used one); 21.2 / 20.1 ms, p95 30-32 ms, worst 34-37 ms with them
off, same binary, alternating runs (Swift: about 16 ms with its cached images, 31-36 ms without). A third run (`with-explorer.json.gz`) fell in the composited state for
its first scenarios: editor typing 24.6 ms, terminal typing 22.7 ms. No paired Swift run was made for the editor.

## 6b. Look and feature parity (the standing requirement)

The Rust app has to look exactly like the Swift app and have exactly the same features. The Swift sources are the
specification for layout, sizes, fonts, colours and icons, not only for the feature list.

Matched so far, from the SwiftUI code (capture: `docs/milestone-2-look-capture.png`; not yet compared side by side
with a screenshot of the Swift app): window size and transparent title bar; 34 pt header with project name and the
seven tools; explorer pane (EXPLORER / LOCAL / close, navigation bar, filter field, 24 pt rows with chevron, SF
Symbol or two-letter file icon, Git colours and letter badges, footer); tab strip (width rule, icon, close button,
unsaved dot, accent line, new-tab button); terminal status bar; editor toolbar and footer; window footer; 13 pt
default text. Icons are the same SF Symbols, rasterised on macOS; Windows has stand-in glyphs.

Added on 2026-11-17 (night), each checked with synthetic presses and captures, and where it changes files or
a repository, by looking at the result on disk:
- Rounded corners and shadows; code drawn in SF Mono (loaded from Terminal's font files; Menlo if absent).
- Toolbar Save, Run, text-size menu, Code menu; explorer filter, options menu, New File / New Folder sheet.
- Quick Open (Cmd-P) and Find in Files (Shift-Cmd-F): the Swift app's ripgrep arguments, fuzzy scoring and
  limits; a match opens the file at its line.
- Source Control (Shift-Cmd-G): changed files, coloured diff, working tree / staged picker, Stage, Unstage,
  Commit, branch menu with Create Branch, stashes. Stage, commit and branch creation verified in a scratch
  repository with `git log` / `git branch`.
- Explorer: right-click menu with the Swift app's entries (open, new here, default app, Finder, terminal here,
  copy path / relative path, copy, paste here, rename, trash), arrow keys and Return, selection highlight.
  Copy, paste, rename and trash verified on disk.
- Sidebar and agent panel widths change by dragging their edges (200-400 and 240-480 points).
- "Save changes?" alert (Save / Cancel / Don't Save) before closing a modified document; Save verified on disk.
- Native macOS menu bar with the Swift app's menus, titles and key equivalents (read back through System
  Events; File > Quick Open exercised). Open File / Open Project use the system's panel.
- Agent panel and "Coding agent" launcher: terminal agents in the panel or in a tab (a custom command ran in
  the panel).

Known differences still open:
- Native (ACP) conversations, the connections sidebar, SSH and SFTP do not exist; their menu items say so.
- Menus opened inside the window (Code, text size, explorer, context, branches) and the sheets and alerts are
  drawn by the app, not AppKit, so they are close to but not the same as the Swift app's native ones.
- The Code menu always says there is no language server; diagnostics count is always what Neovim reports, with
  no explorer counters; Folder List and Follow Terminal do nothing; no file watcher (the tree refreshes on
  focus, save and file actions).
- Editor scrolling moves by whole lines (the Swift app's native client scrolls by pixels); no horizontal smooth
  scroll.
- The status bar shows the project folder, not the shell's directory; tab titles of duplicate file names carry
  no parent folder; the tab strip does not scroll; text size and the custom agent are not saved between runs.
- Terminal: no selection or copy, no IME, no cursor blink.
- The app menu is titled "neolink" until the app is packaged as NeoLink.app.
- Windows: none of this has been seen running; CI only compiles and runs the tests.

## 6c. The minimum feature list (given by the user on 2026-11-17)

The user's 14-section description of the Swift app is the floor, plus two things the Swift app does not have: a
terminal under the code, and split views of code and terminal. Status of each section in the Rust app. "Checked"
means synthetic presses plus a capture, and a look at the result on disk or in Git where there is one; nothing
here has been used by a person, and none of it has been seen running on Windows.

| # | Area | Have | Missing |
|---|------|------|---------|
| 1 | Workspace and window | Three areas (connections or files at the left, tabs in the middle, agent panel at the right), each shown and hidden on its own and remembered; file browser and agent panel resize by dragging; native menu bar and shortcuts; window frame remembered; minimise, zoom, full screen; empty header space drags the window (not exercised: it needs a real mouse) | |
| 2 | Tabs | One strip for terminals and documents; shells keep running; one Neovim for all files; reopening selects the tab; modified dot and close button; widths from names; folder context for same-named files; scrolling with nearest-edge reveal; path tooltips; next / previous / close shortcuts; panes stay mounted | Accessibility labels (the window has no accessibility tree) |
| 3 | Local terminal | Several tabs; scrollback kept; selection, copy, paste, select all; mouse-aware programs get wheel and click reports; text size; agents and REPLs use the same terminal; working directory followed (status bar, Follow terminal); search with Command-F (match selected and scrolled into view) | Mouse drag reports; IME; a count of matches |
| 4 | SSH | Saved connections (name, host, user, port) in the Swift app's file and format, search, new / edit / remove, sessions in tabs through the system's `ssh` (checked against a private server on 127.0.0.1) | The Swift app's built-in SSH library and Keychain passwords: here `ssh` asks in the terminal, and nothing is stored |
| 5 | SFTP and remote files | A remote browser in place of the project tree while an SSH tab is shown: folders, parent, refresh, new file / folder, rename, delete, upload (files, folders, drops), download (files, folders), open a remote file as a read-only tab, one browser per connection, disconnect. It runs the system's `sftp` over the tab's shared connection, so transfers are streamed by `sftp`. Create, rename, delete, upload, download and preview were checked against the private server | Remembered passwords (the browser works once the tab has signed in, or with keys); transfer progress and cancelling; previews over 8 MB; Windows (its OpenSSH has no connection sharing, so only key or agent sign-in can work there, untested) |
| 6 | Explorer | Tree with compact chains, collapse all, hidden and ignored controls, file-type icons, filter, active file highlight and reveal, Git colours and badges, diagnostics counts on files and folders; create, rename, copy / paste, trash, copy paths, show in Finder, default app, terminal here; dropped files are copied without overwriting; lazy loading and row limits | Folder List mode; deleted-file placeholders; anchor-preserving refresh; a file watcher |
| 7 | Editing | Neovim as a native grid client; syntax colours, line numbers, undo / redo, find, cut / copy / paste / select all through Neovim, folding, several buffers, Insert mode at start; remembered screens for instant switches with input held until Neovim confirms; vertical pixel scrolling | Horizontal pixel scrolling; the TUI-in-terminal fallback and the native text editor fallback (without `nvim` the app says so and has no editor) |
| 8 | Language tools | Whatever `neolink.lua` configures runs unchanged (Pyright checked: diagnostics, indicator, counts); Code menu actions; Run; REPLs | Nothing known; each server not tried individually |
| 9 | Search | Quick Open and Find in Files with the Swift app's ripgrep arguments, scoring and limits | Cancelling a running `rg` (a newer query waits for the old process to end) |
| 10 | Git | Status, staged / unstaged, diff, stage, unstage, commit, create and switch branch, stash preview, open changed file, explorer decorations, unsaved-buffer guard | Deleted-file placeholders in the explorer |
| 11 | Agents | Terminal agents in the panel or a tab, Claude's continue option, custom CLI; native ACP conversations: streaming, plan, tools with input and diffs, permissions, stop, modes, several sessions, picker, include the active file, Git review, MCP servers passed through | Nothing known against the offline test agent; not tried with the real Claude adapter |
| 12 | Documents and projects | Open Project, project restored, recent projects with removal and clearing; unsaved-change prompt on closing a tab and on quitting | PDF tabs (a PDF opens in the system's viewer instead, with a note); external-change check before saving beyond what `neolink.lua` does; file size limits enforced by the app |
| 13 | Look | The palette, system font for controls, SF Mono for code, SF Symbols, thin separators, compact bars; the axolotl logo and app icon (`rust/scripts/build-app.sh` makes `rust/target/NeoLink.app` with its own bundle identifier; the bundle was run from outside the repository) | Menus, sheets and alerts inside the window are drawn by the app rather than AppKit; |
| 14 | Rendering | GPU glyph atlas, retained rows, one presenter for all panes, VSync kept, at most one commit per refresh, nothing presented when nothing changed, replayed unchanged chrome | The View menu's rendering toggles, Renderer Information and the Performance Monitor; phase-aware glyph positions are quarter-pixel horizontally only |
| + | Terminal under the code | Control-` (also View menu): a panel under the code with any number of shells, resizable, remembered | |
| + | Split view of code and terminal | Control-Shift-` or the panel's button: the same panel beside the code | Splitting two documents side by side |

Measurements after this work: typing and terminal scrolling were re-measured once (about 7 ms key to display in
full screen, as before; scroll CPU with the sidebar shown back to the milestone-1 level after the explorer replay).
The editor's pixel scrolling has NOT been measured on screen: the display was asleep when it was finished, and a
run with no displayed frames reports nothing. `NEOLINK_BENCHMARK=editor-scroll,editor-crawl,editor-flick` is the
scenario to run with the screen on.

## 7. Open items after milestone 1

- CPU while scrolling (section 5): try presenting on a raw Metal command buffer shared with rendering, or cut
  wgpu's per-frame cost; measure kernel time with one command buffer.
- Find what puts a full-screen window in the composited state, and whether the app can avoid it.
- The first key after a long pause (panel slowed down): 27-50 ms. The keep-warm window is a power trade.
- Flick evenness against whole-point momentum reports; refreshes missed in a window.
- Combining marks, selection and copy, cursor blink, IME, text size persistence, live-resize smoothness.
- A person has not used this build: every interaction above was synthetic.

## 8. Log

- 2026-11-17 (early morning): the user's feature list became the floor (section 6c). Added: native ACP
  conversations (new `neolink-acp` crate, tested against `scripts/fixtures/acp-agent.py`), terminal under or beside
  the code, settings and recent projects, tab folder context / scrolling / tooltips, terminal selection and copy,
  working directory and Follow terminal, diagnostics counters and language-server indicator, file drops, pixel
  scrolling in the editor, connections sidebar, SSH tabs and the remote file browser. 96 tests. CI: macOS green; Windows failed once on a
  path check in a new test, fixed in `cde7563`.
- 2026-11-17 (late night): Quick Open, Find in Files, Source Control, explorer context menu and keyboard, file
  operations, pane resizing, Save alert, native menu bar, agent panel and launcher (terminal agents). Explorer
  drawing is replayed when unchanged (scroll CPU with the sidebar shown back to about the milestone-1 level).
  80 tests.
- 2026-11-17 (night): in-app popup menus and a text field; explorer filter and options, Code menu, text-size
  menu, toolbar Save, Run, New File / New Folder, Cmd-P and Reveal Active File now act. `controls` benchmark scenario presses named controls for captures.
- 2026-11-17 (later): remembered screens for instant document switches (tested against real Neovim), live
  unsaved marker and close warning, Windows path spelling fixed after the first Windows run of the editor tests,
  explorer refresh and Git decorations. 68 tests; CI green on both systems for `821875e`.
- 2026-11-17: branch pushed with the user's go-ahead; first CI run green on macOS and Windows. Milestone 2 begun:
  Neovim crate (RPC framing, grid model, embedded client with input held across switches, 6 real-Neovim tests),
  editor pane and document tabs, explorer tree and sidebar. 63 tests.

- 2026-11-16 (night): milestone 1. Terminal on `alacritty_terminal`, tabs, key encoding, pixel scrollback, harness
  with the Swift benchmark's profiles and analysis, off-screen capture, retained rows, keep-warm frames, pacer
  reworked three times against measurements (latch/depth/margin, start after the previous latch, queue draining).
  Paired runs against the Swift app in three conditions. Windows type-check and CI workflow (not run).
- 2026-11-16 (later): toolchain installed (Rust 1.100). Stack spike run and decided (section 2).
- 2026-11-16: `cargo`, `rustc`, `rustup` not installed; install requested. Read the specification documents and the
  Swift benchmark; checked crate versions, licences and GPUI's current structure and presentation path; created the
  `rust-rewrite` branch as a separate worktree (the main checkout's branch is untouched); wrote this plan and the
  compiler-independent logic in `crates/neolink-core`.
