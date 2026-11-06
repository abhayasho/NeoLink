# Native Neovim grid client (default; `NEOLINK_NATIVE_GRID=0` or the View menu selects the TUI)

By default the shared editor is a Neovim TUI in a pseudo-terminal: Neovim renders its UI to escape sequences, the PTY carries them, SwiftTerm's VT parser rebuilds a cell grid on the main thread, and the Metal renderer draws that grid. The native client removes the TUI process, the PTY and the VT parser. NeoLink starts a **headless** Neovim server (same `--listen` socket, same `Resources/Editor/neolink.lua`) and attaches to it as an `ext_linegrid` UI over msgpack-RPC. The editor's cells then go straight into SwiftTerm's existing buffer, so the glyph atlas, 16 raster phases, integer-pixel quads, row cache, cursor drawing, IME/marked text, accessibility, NeoGPU hosting, VSync and the single NeoGPU display link are the terminal path's, unchanged.

The native client is the default (since the horizontal-scrolling work; see [RENDERING.md](RENDERING.md#pixel-smooth-horizontal-editor-scrolling-native-client)). The TUI path is the fallback and can be selected with **View → Native Editor Rendering (after Restart)** or `NEOLINK_NATIVE_GRID=0`. If `nvim` is missing, does not advertise `ext_linegrid`/`rgb` UI options, fails to attach, or the editor configuration lacks the native hooks, the session logs the reason (`NeovimSession.nativeFallbackReason`) and starts the TUI instead; queued commands wait for whichever engine becomes ready. A View-menu preference is deliberately not added yet (a change needs an editor restart; see the limits below).

## Pipeline

```
nvim --headless --listen editor.sock           control.sock (existing JSON channel: open/save/close/leave/action/status)
        │  msgpack-RPC redraw events                    ▲
        ▼                                               │
NeovimRPCConnection  (dispatch read source on its own serial queue; ordered write queue)
        ▼
NeovimGridClient ── NeovimGridModel (reader queue only): hl_attr_define, default_colors_set, grid_resize/clear/line/scroll,
        │            grid_cursor_goto, mode_info_set/mode_change, busy_*  →  immutable GridFrame at every `flush`
        ▼
GridMailbox (lock-protected; adjacent frames merge, so a hidden editor holds one pending frame)
        ▼  drained on the main actor: at the owning display deadline (`servicePendingOutput`) and by one coalesced main-queue wake
NativeGridPresenter ── mirror image, style table, snapshot cache, selection correlation, input
        ▼
SwiftTerm Terminal buffer rows (`externalGridSetRow`, `externalGridScroll`, `externalGridExchangeRows`) → existing Metal renderer
```

Nothing blocks on the main thread or Swift's cooperative pool. msgpack decoding, highlight/grid application and the per-flush diff against the previously emitted frame happen on the reader queue. Only rows whose content changed are published, and the presenter writes only rows that differ from what the terminal holds.

`grid_scroll` is replayed through the terminal's own region scroll (the same operation as CSI S/T) before changed rows are written, so scrolled rows keep their line identity, the renderer reuses and translates their cached geometry, and the existing smooth-scroll observers/retained lines work. The trackpad wheel path forwards line steps to `nvim_input_mouse`.

## Selection correctness (replaces the OSC title marker)

The TUI path gated visibility on a post-redraw `neolink-selection:<token>` title marker. The native path uses the same property on a different channel: after `nvim_set_current_buf` and `redraw` (which sends the buffer's redraw events and `flush`), `neolink.lua` does `rpcnotify(ui_channel, 'neolink_selection', token, path)`. Neovim writes redraw batches and notifications to the same RPC channel in order, so by the time the client reads the notification every frame it has applied belongs to that buffer. The reader publishes it as an ordered mailbox item; the presenter writes all rows to the terminal first and only then tells `NeovimSession`, which applies the existing per-selection generation check (`selectionParsed`) before the host shows and focuses the editor. Older tokens, tokens for superseded selections, and echoes arriving during a newer speculative display cannot expose or replace anything. `NativeGridEditorTests` alternates two buffers 40 times against real Neovim and requires the grid to hold exactly that buffer at every echo.

Commands keep their ordering through the unchanged control channel; saves/closes/initial opens still cannot be skipped. Unsaved buffers, the 128 MiB code-tab cap and the >2 MiB LSP/Tree-sitter limits live in Neovim and `neolink.lua` and are untouched. Asynchronous service errors still surface through `v:errmsg`/the banner. No byte is written to Neovim's stdout. The input path sends keys with `nvim_input` (`<` escaped as `<lt>`), pasted text with `nvim_paste`, mouse with `nvim_input_mouse`; input typed while a cached image is shown waits (bounded) for Neovim's confirmation so it can never reach a different buffer.

## Per-buffer snapshot cache

`neolink.lua` notifies the client when the displayed buffer is left (`neolink_leave`: path, mode, whether a popup menu is open), after redrawing, so the client's grid at that moment is exactly that buffer's screen. Images are kept for up to eight buffers. A cached image is shown immediately on return only if **all** of these hold, otherwise the editor waits for Neovim's flush:

- Neovim reported the buffer in insert mode with no popup menu (the state `open` always returns to), and restored its exact view (`winsaveview`/`winrestview` in `neolink.lua` when a native UI is attached);
- no change touched the buffer while it was hidden (`nvim_buf_attach` `on_lines`/`on_reload`, `BufWritePost`, `BufModifiedSet`, `DiagnosticChanged`, `LspAttach/Detach` send `neolink_touch`), and no layout/option/colour-scheme event happened (`WinNew`, `WinClosed`, `VimResized`, `ColorScheme`, display options send a global touch);
- the grid size, the highlight/default-colour epoch, and the diagnostics-enabled flag are unchanged;
- the file's size, mtime and inode are exactly what they were (an external or agent edit makes Neovim reload the buffer, so the image is refused).

A speculative image is a display optimisation, not a source of truth. Neovim's own confirmation then replaces it; rows that already match are not rewritten. Tests require zero corrected rows after round trips with cursor moves, page scrolling and `<C-End>`. The displayed rows of the buffer being left are detached (not overwritten) and retained with its image; re-installing them swaps `BufferLine` objects, so the renderer's row cache (keyed by line identity and generation) draws every row from retained geometry: a re-installed screen rebuilds 0 rows (`NativeGridRenderingTests`) instead of all of them.

## Vendor and shared-code changes

[Vendor/SwiftTerm/UPSTREAM.md](../Vendor/SwiftTerm/UPSTREAM.md) lists the SwiftTerm additions (`NeoLinkExternalGrid.swift`, `Mac/NeoLinkExternalGridView.swift`, three `public`→`open` changes and a renderer keep-set hook). In shared NeoGPU code, a drawable that reaches the display after the workspace's client set changed now still delivers each node's content acknowledgement (never ownership changes). Previously that acknowledgement was discarded, which could leave a selection's "presented" callback unanswered.

## Limits

- Changing engines (View menu) applies after a restart.
- Vertical scrolling uses `nvim_input_mouse` whole-line steps with the smooth-scroll driver drawing the sub-line remainder from lines retained by `grid_scroll`; horizontal scrolling is pixel-smooth through `NeoLink.hscroll` chunks and a translated text band (see RENDERING.md). Physical trackpad feel, momentum and keyboard-repeat feel are **not verified** (procedural events only).
- `ext_multigrid`, `ext_popupmenu`, `ext_cmdline`, `ext_messages`, `win_viewport` and `winblend` blending are not used; popup menus, floats and the command line are drawn by Neovim into the one grid. Cursor blink phase, `cell_percentage` and the cursor highlight attribute are approximated by the terminal's cursor styles.
- Option-as-Meta is not implemented; Option composes characters through the input system, Option plus Control/special keys sends `M-`.
- A cached image can precede Neovim's confirmation by one round trip. The window in which a change reaches Neovim but its `neolink_touch` has not yet reached the host is under a millisecond on the local socket, but it exists.
- The matched release evidence is procedural (see below). It does not establish click-to-photon latency and makes no claim of parity with another editor.

## Verification

- `swift test`: 188 tests pass, and the same 188 pass with `NEOLINK_NATIVE_GRID=1` (the whole suite, including the existing editor tab/selection/save tests, against the native client). New tests: msgpack round trips (including every split point) and bounds; line-grid application (omitted highlights, repeats, wide cells, partial and full scrolls, redefinition/epoch, merge equivalence); mailbox ordering; cache validity, bound and eviction; key encoding; **pixel equality of native grid text against the VT-parser path** for the same content (colour, bold/italic/underline/strike/reverse, shaded cells, CJK, emoji, combining marks, ligature runs), for region scrolls and for cursor shapes per mode; re-installed rows draw with 0 rebuilt rows and identical pixels; real headless Neovim: 40 buffer alternations with the correct buffer at every echo, `neolink_leave`/`neolink_touch` notices, and an end-to-end session (switching, typing, saving, an agent edit refusing a stale image, zero rows corrected after cursor moves/scrolling, resize to three sizes with no stale-sized grid).
- `python3 scripts/test-editor.py` and `python3 scripts/test-benchmark.py` pass. `scripts/verify-app.py NeoLink.app` verifies the release package.

## Release evidence (procedural, not physical input)

Measured at implementation commit `68e7a70`; later commits add the resize regression test, an orphan watchdog (a 5 s Lua timer, only in the headless native server, that exits it when NeoLink is gone) and documentation, and were not re-benchmarked. Candidate release `NeoLink.app` (`dc1c26b23698…`, built by `scripts/build-app.sh`) against installed Build 29 (`a9ea61d2b673…`; both hashes are in `native-grid-results.json`). The candidate runs both arms: the TUI arm leaves the flag unset and the native arm sets `NEOLINK_NATIVE_GRID=1` on the **same binary**. M2 Max, native full screen 1728 × 1084 points, 2× backing, 120 Hz, frontmost, the screen unlocked before and after every run (checked through the session's lock flag), `NEOLINK_SELECTION_TRACE=1 NEOLINK_WINDOW=fullscreen NEOLINK_BENCHMARK=render-motion,ui-tabs,ui-highlights,ui-resize`. Five rounds, rotating the arm order each round (15 runs, all valid; sequential, background desktop load not controlled). Per-run values below are listed in run order. [Compact per-run results for every matrix, hashes and the earlier matrix](native-grid-results.json); raw reports with traces were kept outside the repository.

### Tab → correct buffer presented (24 switches per run, 18 into an editor)

| Metric | Build 29 | Candidate, TUI | Candidate, native |
| --- | --- | --- | --- |
| Tab → presented, p50 (ms) | 65.7 / 76.4 / 74.9 / 64.6 / 76.7 | 51.5 / 52.3 / 52.6 / 52.8 / 67.8 | 46.5 / 47.9 / 49.8 / 60.6 / 61.6 |
| p95 = max (ms; 18 samples) | 71.2 / 86.7 / 92.9 / 78.7 / 89.4 | 69.0 / 68.0 / 74.8 / 75.2 / 84.2 | 59.2 / 60.1 / 57.3 / 73.9 / 76.5 |
| Pooled p50 / p95 / max (ms) | n/a | 52.7 / 81.2 / 84.2 | 54.6 / 72.9 / 76.5 |
| Selection → focus, p50 (ms) | 30.0 / 31.9 / 32.0 / 31.2 / 33.9 | 31.3 / 32.0 / 32.2 / 31.9 / 33.9 | 27.1 / 25.2 / 27.9 / 25.8 / 17.3 |
| Selection failures | 0 ×5 | 0 ×5 | 0 ×5 |
| Presentation timeouts | 0 / 1 / 1 / 0 / 0 | 0 ×5 | 0 / 0 / 0 / 1 / 0 |
| Dropped drawables (`workspaceDroppedDrawables`, whole workload) | not reported | 173 / 36 / 44 / 157 / 116 | 44 / 34 / 27 / 151 / 40 |

**The end-to-end "presented" medians are not a clean win.** The same-binary pairs favour native in four of five rounds (46.5 vs 51.5, 47.9 vs 52.3, 49.8 vs 52.6, 61.6 vs 67.8 ms) and lose in one (60.6 vs 52.8), and the pooled p50 is not better (54.6 vs 52.7 ms) though p95/max are lower. The earlier matrix on the previous candidate binary (`6ba19d38…`, before the key-echo bookkeeping fix, nothing else about tab switching changed) had native clearly ahead: pooled p50 / p95 / max 45.4 / 57.0 / 58.7 against the TUI's 51.9 / 69.0 / 77.1 ms. The difference between the two matrices is the final stage:

| Median per run, ms from selection | Build 29 | Candidate, TUI | Candidate, native |
| --- | --- | --- | --- |
| editor → editor: frame prepare starts | 33.4 / 28.6 / 33.1 / 29.1 / 34.3 | 17.1 / 18.1 / 17.3 / 17.8 / 20.9 | 17.5 / 16.4 / 17.5 / 18.8 / 18.9 |
| editor → editor: encode duration | 13.4 / 13.4 / 13.6 / 13.3 / 13.8 | 10.6 / 10.4 / 10.7 / 10.5 / 11.1 | **0.3 / 0.3 / 0.3 / 0.3 / 0.4** |
| editor → editor: **GPU complete** | 48.3 / 44.0 / 48.7 / 44.5 / 49.9 | 28.9 / 29.8 / 30.1 / 29.5 / 32.9 | **18.9 / 17.8 / 19.2 / 20.6 / 20.6** |
| editor → editor: presentation lead after GPU complete | 10.4 / 26.4 / 25.7 / 14.2 / 25.8 | 20.2 / 21.2 / 21.0 / 22.0 / 30.5 | 24.5 / 28.0 / 24.6 / **39.4 / 42.5** |
| shell → editor: GPU complete | 47.9 / 43.1 / 47.2 / 43.7 / 48.6 | 26.6 / 38.8 / 41.6 / 40.1 / 43.0 | 33.1 / 32.9 / 31.7 / 27.8 / 28.3 |
| shell → editor: presentation lead | 22.7 / 37.5 / 32.1 / 28.3 / 39.3 | 29.2 / 22.5 / 26.2 / 26.2 / 39.0 | 24.0 / 23.6 / 22.8 / 40.2 / 38.5 |

Pooled selection → GPU-complete medians (18 editor presentations per run): editor → editor 29.9 ms (TUI) vs **19.4 ms** (native), shell → editor 41.6 vs 32.6 ms. The native advantage in the part NeoLink controls is therefore about 10 ms and consistent across all runs (2 × 5 runs). What follows GPU completion is the compositor/display lead, which this machine moved between roughly 22 and 42 ms during the later runs of **both** binaries (and Build 29), and that moved the presented medians independently of the editor path. Reading the evidence conservatively: native removes the PTY, the parser and the row rebuild from the tab-switch path (encode 10.6 → 0.3 ms with retained rows; selection → GPU-complete 30 → 19 ms), and presented latency was 3–8 ms better in the quieter same-binary pairs of both matrices. A reliable end-to-end improvement across display-lead drift is **not** established by these runs.

The first frame is still not prepared until about 16–19 ms after the selection in both engines: the main thread is busy with SwiftUI/AppKit work from the selection change before the display link can run. That is the previously documented root-layout cost, unchanged by this work (the restructuring it needs, such as a native split view, is not done). Shell → editor selections also wait for SwiftUI to mount the editor view; cached images cannot show before that. The native path shows an image at the selection itself (0.2 ms), but the first drawable still waits for the main thread.

### Other scenarios

| Metric | Build 29 | Candidate, TUI | Candidate, native |
| --- | --- | --- | --- |
| Highlight → presented, p50 (ms) | 26.9 / 35.3 / 43.0 / 52.1 / 44.3 | 42.9 / 26.6 / 26.8 / 42.3 / 44.0 | 26.7 / 26.9 / 26.7 / 26.9 / 43.8 |
| Motion interval p95 (ms) | 8.3 ×5 | 16.7 / 8.3 / 16.7 / 16.7 / 8.3 | 16.7 / 8.3 / 8.3 / 16.7 / 8.3 |
| Motion missed refreshes | 24 / 20 / 18 / 20 / 17 | 58 / 26 / 33 / 52 / 23 | 32 / 28 / 15 / 33 / 15 |
| Resize changed-content interval p95 (ms) | 33.3–41.7 (one run did not exercise resize: 0, CPU 4.7 %) | 25.0 ×5 | 25.0 ×5 |
| Resize maximum main-thread wait (ms) | 158 / 164 / 100 / 3* / 125 | 594 / 278 / 418 / 277 / 248 | 296 / 449 / 296 / 433 / 165 |
| ui-tabs CPU (% of one core) | 28.3 / 27.3 / 27.6 / 28.4 / 28.3 | 25.7 / 26.1 / 25.8 / 26.3 / 26.9 | **22.7 / 22.3 / 22.0 / 23.3 / 22.1** |
| ui-tabs memory (MiB, process footprint) | 238 / 240 / 240 / 239 / 269 | 241 / 240 / 241 / 240 / 272 | 240 / 243 / 243 / 242 / 272 |
| ui-resize CPU / memory | 91.6 / 91.2 / 91.6 / 4.7* / 92.7 %; 270–276 MiB | 82.6–83.7 %; 273–280 MiB | 80.6–83.9 %; 272–275 MiB |

The highlight, motion and resize scenarios (the first of which runs before the editor process exists) do not exercise the native client's output path: their differences between the two candidate arms are run-to-run noise on identical code, which bounds how much any single run of these metrics can be trusted. Highlight latency is bimodal on every binary (about 26.7 vs 43 ms with the display lead). The candidate's resize maximum main-thread wait is worse than Build 29's in both arms (165–594 vs 100–164 ms): that is the Build 30 SwiftUI-layout regression documented in [TAB_INTERACTIONS.md](TAB_INTERACTIONS.md), not caused by the flag. \* One Build 29 run had its resize scenario inactive (CPU 4.7 %, interval 0, wait 3 ms); it is listed rather than dropped.

Process CPU during the editor-tab workload is about 13 % lower in the native arm than in the TUI arm (22.0–23.3 vs 25.7–26.9 % of one core) and about 20 % lower than Build 29 (27.3–28.4 %). Neovim itself is not in that counter: the native arm runs one headless server instead of a TUI client plus an embedded server, which was not measured. Memory is within 0–3 MiB in the tab workload.

### Editor input and scrolling (real `NSEvent` key events, wheel events; 4 rounds, 12 runs)

`editor-type` (75 keys), `editor-cursor` (400 down-arrows) and `editor-flick`, final candidate binary. Key → display is the time to the first presented frame after the key.

| Metric (per run) | Build 29 | Candidate, TUI | Candidate, native |
| --- | --- | --- | --- |
| Typing key → display p50 (ms) | 29.0 / 29.5 / 29.7 / 29.1 | 29.9 / 29.6 / 30.8 / 29.2 | 29.8 / 29.7 / 29.9 / 30.4 |
| Typing p95 / max (ms) | 32.4–33.0 / 55.2–75.6 | 32.6–34.2 / 59.1–64.1 | 33.2–41.4 / 44.7–65.4 |
| Cursor-key → display p50 (ms) | 30.9 / 33.8 / 31.0 / 30.6 | 30.0 / 30.4 / 30.1 / 30.3 | 30.0 / 29.2 / 43.4 / 31.5 |
| Flick scroll: whole-line moves / lag (ms) / position error p95 (lines) | −41 ×4 / 34–40 / 0.055–0.364 | −41 ×4 / 37–45 / 0.055–0.585 | −41 ×4 / 30–41 / 0.053–0.251 |

Typing and cursor movement are **not faster**: key → display p50 is about 29–30 ms in all three arms, set by the display deadline and presentation lead rather than by the PTY. (A first native run of this matrix showed no key echo at all in the benchmark because the native path did not note its output for key answering; fixed in the final binary and the matrix repeated. Those earlier reports are kept in `native-grid-results.json`.) A single cursor-key run (43.4 ms p50) coincided with a high display lead. Flick scrolling moves the same 41 lines with comparable lag and position error, through `nvim_input_mouse` and the replayed region scrolls.

## What still needs a person

Natural trackpad scrolling and momentum feel, key-repeat feel, IME composition with a real input source (marked text uses SwiftTerm's existing overlay at the grid cursor but was not driven through a real IME), accessibility with VoiceOver, drag-selection and context-menu behaviour in the native editor, and a long real editing session with LSP are not verified. Click-to-photon and key-to-photon latency, other displays/refresh rates and macOS 13 are not measured. Nothing here claims parity with Zed or any other editor.
