# Native GPU text rendering

[Opt-in native Neovim grid client: design, safeguards, matched release results and limits](NATIVE_GRID.md).

[Build 27 tab sizing, per-selection tracing and resize checks](TAB_INTERACTIONS.md).

[Build 26 explorer and tab interaction changes, measurements and limits](INTERACTIONS.md). Highlight composition now retains the text strip independently; historical whole-strip invalidation descriptions below apply to their original builds.

## Responsiveness pass: exact editor rows, steady resampling, cheaper switches

Sampling the release build's main thread (`sample` while the benchmark workloads ran) showed it idle for 87–89 % of the time while scrolling and while switching tabs, so the remaining choppiness and lag were not raw CPU. Four specific causes were found and fixed:

1. **Every editor keystroke rebuilt every row.** SwiftTerm records changed rows as one span from the lowest to the highest marked row. A keystroke rewrites the edited line and the status line at the bottom, so the 58 rows between them were rebuilt. Measured in the release app with `NEOLINK_PREPARATION_PROFILE=1` (75 typed keys): **58 rows rebuilt per frame and 6.95 ms median (max 7.41) of draw-data work before; 2 rows and 1.22 ms median (max 2.22) after.** Rows written through the external-grid API are now recorded exactly (`Terminal.externalUpdateRows`), merged with exact rows still waiting for a frame, and the renderer rebuilds only those. Any other mark, a full-screen update or a direct dirty-range assignment falls back to the span, so the VT-parser path is unchanged ([UPSTREAM.md](../Vendor/SwiftTerm/UPSTREAM.md)). `NativeGridRenderingTests` checks that an edit plus its status line rebuilds exactly 2 rows and draws the same pixels as a view that drew the final screen from scratch.
2. **The scroll resampler lost track of the input rate.** It measured the gap between events only while its history was non-empty. Once the drawn position caught up, the history was cleared and the next gap went unmeasured, so after a fast gesture a slower stream kept an estimate that was too short. In a failing `editor-diagonal` run the estimate was about 11 ms for events 16.7 ms apart (delay 7.4 ms instead of 22.7 ms), the drawn position caught up between events, and every other 120 Hz frame repeated. The delay also jumped by about 10 ms where the measured interval crossed 1.5 display frames, which made jittery input near 80 Hz hold frames. The rate is now measured from every event and kept across resets; the delay is a continuous blend between "half an interval plus 2 ms" (input at the display's rate) and "one interval plus 6 ms" (input at half of it); the delay in use follows that target at no more than half a second per second, so a change of rate never samples backwards; and interpolation uses the events' own timestamps when they are plausible. This applies to the editor, the sideways band, the explorer and terminal scrollback. `ScrollResamplerTests` cover a slower stream after a fast gesture, 80 Hz input, continuity of the delay and rate changes.
3. **Every tab switch re-evaluated the whole SwiftUI workspace.** The selection was a `@Published` property of `TabsController`, which nearly every view observes, so each switch re-ran the workspace root and its layout. A trace of the previous build showed the cached image of the next file ready 0.5 ms after the switch but its first frame prepared at about 19 ms, with SwiftUI view-graph updates at 6 % of the main-thread samples. The selection now lives in `TabSelection`, observed only by the views that show it; the controller publishes `browserTabID` only when the shown browser changes. `TabSelectionTests` checks that switching documents publishes the selection and not the controller.
4. **Neovim redrew the whole screen on every switch and command.** Reading or setting an option of a hidden buffer through `vim.bo[buf]` switches context, and restoring the window layout afterwards marks every window for a full redraw. `M.open` set `buflisted` that way, the status snapshot read four options of every buffer after each command and mode change, and every `BufEnter` reset the fold options. They now use `getbufvar()`, which reads in place, and set only what differs. In a headless probe on the real configuration (156 × 58 grid, 120 ms between switches), entering the buffer took 11.4 ms before and 0.5–1.0 ms after, and the whole switch 20.0 ms before and 11.6–12.9 ms after. Cached tab images hide this in `ui-tabs`. It matters for the first keystroke after a switch and for switches that miss the cache, and neither was measured end to end.

**Method.** Two release builds made by `scripts/build-app.sh`. *Before* is `1eaec25` ("Pixel-smooth horizontal editor scrolling; native editor by default", binary SHA-256 `a4ea4a5d63b0…`), *after* is `0303fdb` ("Editor: stop forcing a full Neovim redraw on every switch and command", `ff4d47ec31f3…`). M2 Max, native full screen 1728 × 1084 pt, 2×, 120 Hz, native editor, direct presentation, frontmost; the Mac was unlocked before and after every run (checked through the session's lock flag). Five rounds, alternating which build ran first. All 10 runs are valid and none is dropped (an earlier attempt stopped at its first lock check and produced no data). Each run executed `editor-type,editor-cursor,terminal-type,editor-flick,editor-slow,editor-diagonal,editor-horizontal,terminal-flick,explorer-flick,ui-tabs` with synthetic key and scroll events, not a trackpad. Values are per round (round 1 … 5). [Compact per-run results](responsiveness-pass-results.json); raw reports were kept outside the repository.

| Typing in the editor (`editor-type`, 75 keys) | Before | After |
| --- | --- | --- |
| Main-thread stall samples over 8 ms | 55 / 70 / 51 / 67 / 63 | 5 / 5 / 0 / 4 / 5 |
| Display callbacks that ran late (%) | 37.6 / 36.4 / 36.2 / 25 / 41 | 2 / 1.8 / 0 / 0 / 0.3 |
| Output read → frame submitted, median (ms) | 7.4 / 8.8 / 7.2 / 4.3 / 9.5 | 3.5 / 4.5 / 4.4 / 5 / 5.7 |
| Frame submitted → presented, median (ms) | 17.6 / 16.7 / 17.5 / 16.4 / 16.7 | 15.5 / 15.7 / 17.9 / 23.8 / 25.5 |
| Key → display p50 (ms) | 25.4 / 26.6 / 24.3 / 21.8 / 27.5 | 23.5 / 21 / 22.7 / 31 / 33.5 |
| Key → display p95 (ms) | 36.3 / 36.6 / 35.1 / 25.1 / 36.7 | 31.9 / 27.7 / 26 / 34.3 / 36.8 |
| Cursor keys (`editor-cursor`): stall samples over 8 ms | 5 / 10 / 11 / 7 / 10 | 0 / 0 / 0 / 0 / 2 |
| Cursor keys: key → display p50 (ms) | 24.3 / 14.4 / 15.7 / 16.3 / 14.3 | 13.4 / 14.3 / 23.8 / 31.2 / 15.7 |
| Shell typing (`terminal-type`, control): key → display p50 (ms) | 13.8 / 13.5 / 12.8 / 13.1 / 13.2 | 14.5 / 13.4 / 21.7 / 13.9 / 13.4 |

| Scrolling | Before | After |
| --- | --- | --- |
| Slow editor scroll (60 Hz events): refreshes skipped while the finger moved | 89 / 79 / 88 / 89 / 0 | 0 / 0 / 0 / 0 / 6 |
| Slow editor scroll (60 Hz events): best-fit input → display lag (ms) | 23 / 26 / 17 / 24 / 35 | 46 / 47 / 42 / 49 / 44 |
| Diagonal editor scroll: refreshes skipped while the finger moved | 0 / 1 / 165 / 152 / 1 | 0 / 0 / 0 / 0 / 0 |
| Diagonal editor scroll: best-fit input → display lag (ms) | 20 / 24 / 25 / 25 / 22 | 47 / 47 / 40 / 47 / 40 |
| Diagonal editor scroll: velocity error p95 (lines/s) | 7.5 / 11.2 / 22.5 / 22.5 / 7.5 | 3.8 / 3.8 / 0 / 3.8 / 0.1 |
| Diagonal editor scroll: jump frames | 0 / 1 / 0 / 0 / 1 | 0 / 0 / 0 / 0 / 0 |
| Editor flick (120 Hz events): refreshes skipped while moving | 0 / 5 / 0 / 5 / 0 | 3 / 2 / 2 / 3 / 1 |
| Editor flick: longest gap between changed frames (ms) | 16.7 / 25 / 16.7 / 25 / 16.7 | 16.7 / 16.7 / 16.7 / 16.7 / 16.7 |
| Editor flick: best-fit lag (ms) | 25 / 25 / 16 / 24 / 24 | 33 / 25 / 29 / 33 / 27 |
| Editor flick: velocity error p95 (lines/s) | 6.9 / 19.8 / 7.5 / 14.2 / 9.7 | 15.2 / 16.5 / 17.3 / 13.4 / 27.5 |
| Terminal scrollback flick: refreshes skipped while moving | 0 / 0 / 5 / 5 / 5 | 2 / 3 / 2 / 2 / 2 |
| Terminal scrollback flick: best-fit lag (ms) | 25 / 32 / 40 / 35 / 25 | 25 / 17 / 26 / 33 / 36 |
| Sideways editor scroll (`editor-horizontal`): missed refreshes | 3 / 3 / 3 / 3 / 2 | 1 / 1 / 1 / 2 / 3 |
| Explorer flick: frames with no motion while it should move | 76 / 6 / 16 / 16 / 94 | 7 / 11 / 7 / 9 / 8 |

| Switching tabs (`ui-tabs`, 24 switches) | Before | After |
| --- | --- | --- |
| Selection → correct buffer presented, p50 (ms) | 35.7 / 31.3 / 33.2 / 32.1 / 32.9 | 32.1 / 30.9 / 32.2 / 38.3 / 34.8 |
| Selection → correct buffer presented, p95 (ms) | 50 / 41.1 / 45.2 / 45.7 / 41.1 | 49.8 / 45.2 / 49.9 / 52.7 / 48.5 |
| Process CPU (% of one core) | 22.9 / 22.6 / 23.3 / 23 / 23.8 | 25.2 / 28.6 / 27.4 / 28.2 / 26.2 |
| Main-thread stall samples over 16 ms | 67 / 63 / 96 / 81 / 70 | 86 / 124 / 83 / 123 / 75 |

**What the numbers support.**

- Main-thread work while typing is gone as a source of jank. Stall samples over 8 ms fell from 51–70 to 0–5 per run, late display callbacks from 25–41 % to 0–2 %, and the time from reading Neovim's output to submitting the frame from a median of 7.4 to 4.5 ms (medians across rounds). Cursor-key runs show the same drop in stalls (5–11 to 0–2).
- Slow and diagonal editor scrolling now move on every refresh. Skipped refreshes fell from 79–89 (four of five rounds; the fifth had 0) to 0–6 in `editor-slow`, and in `editor-diagonal` from two baseline rounds of 152 and 165 to 0 in all five. Diagonal velocity error fell as well (p95 7.5–22.5 to 0–3.8 lines/s) and its jump frames to 0. The baseline problem was intermittent, so five clean rounds are evidence, not proof.
- The explorer flick lost its outliers of 76 and 94 frames with no motion (now 7–11), and no editor flick round had a 25 ms gap between changed frames (the baseline had two).

**What it does not show, and what got worse.**

- **Key → display did not improve.** Typing p50 was 25.4 ms before and 23.5 ms after (medians over rounds), cursor keys 15.7 ms in both, and the last two *after* rounds were slower (31.0 and 33.5 ms typing). That time is dominated by the submitted → presented stage, which ranged 8–18 ms in the baseline and 8–26 ms in the candidate; for typed characters it is about 17 ms against 8–9 ms for cursor keys in four of five baseline rounds, for a reason not established. Removing 5.7 ms of draw-data work per key (above) did not move it. The shell, which this pass does not change, also had one slow round (21.7 ms).
- **Scroll lag rose.** Best-fit input → display lag went from 17–35 to 42–49 ms for slow scrolling and from 20–25 to 40–47 ms for diagonal scrolling. The resampler's delay is now correctly one input interval plus 6 ms (about 23 ms for 60 Hz events), where the baseline drew each event as it arrived and repeated frames in between. Flick lag moved from a median of 24 to 29 ms, and velocity error against the raw input rose (p95 median 9.7 to 16.5 lines/s; the benchmark scores a delayed, interpolated copy of the input against the raw trajectory). Whether the extra delay is worth the evenness on a real trackpad is not established. Shrinking the margin, or predicting a few milliseconds ahead, are the obvious levers.
- **Tab switching did not improve, and the tab workload got more expensive.** Selection → buffer presented p50 was 32.9 ms before and 32.2 ms after, p95 45.2 and 49.8 ms. Process CPU during `ui-tabs` was 22.6–23.8 % before and 25.2–28.6 % after (higher in every round), and main-thread stall samples over 16 ms rose from 63–96 to 75–124. The cause is not established: the *after* build contains all four changes, and the SwiftUI split has not been shown to help end to end. Do not count it as a tab-latency improvement until that is understood.
- Anomalies kept in the tables: one *after* typing round reports 6.4 % CPU with normal results otherwise, and run durations varied from about 1 to 7 minutes for reasons not established (the 7-minute run is the last *after* round, which also has the worst typing and tab numbers of its build). Five runs per build, no significance testing, one machine, synthetic input. Physical trackpad feel, key-repeat feel and click-to-photon latency are not measured.

Checks for this pass: 213 tests pass with the native editor (the default) and 213 with `NEOLINK_NATIVE_GRID=0`; `scripts/test-editor.py`, `scripts/test-benchmark.py` and `scripts/verify-app.py` pass.

## Pixel-smooth horizontal editor scrolling (native client)

**Why it was choppy.** Neovim shows whole columns, and each column it scrolls horizontally rewrites every row of the window. In the native client each column step was a wheel event to Neovim. Neovim then sent a full redraw, and the renderer rebuilt every row. Horizontal motion therefore advanced in whole-column jumps at most every other refresh, with heavy frames.

**How it works now** (`NativeHorizontalScroll`, `NeoLink.hscroll` in `neolink.lua`, `ExternalHorizontalScroll` in the renderer). This follows the same design as the vertical smooth scroll. Zed's editor scrolls at fractional pixel positions in both axes; this is the closest equivalent while Neovim owns the viewport:

1. Finger input, in columns, is resampled at the display's cadence (`ScrollResampler`).
2. Neovim is asked, about 24 columns at a time, to put the window's leftcol ahead of the fingers. `NeoLink.hscroll` reproduces Neovim's own mouse-scroll rules: a cursor line shorter than the view moves to the longest visible line, and the cursor stays in view. It then redraws and reports on the ordered UI channel. The host shows those frames together with the report, never before it.
3. The renderer draws the window's text area translated by the sub-column remainder, in whole device pixels. The gutter (numbers, signs, folds) and other windows stay put. The strip a translation exposes is drawn from the rows that showed the previous chunks; those rows were detached, not overwritten, and keep their geometry.
4. Retained rows are preferred. Right after a chunk arrives they still cover the view, so the new rows are built six per frame in the background and only drawn where nothing older reaches. No frame rebuilds the whole window.
5. When the gesture and its momentum end, the drawn position glides to a whole column in the direction of travel and Neovim is asked for exactly that column. At rest the screen is Neovim's own grid, which a real-Neovim test checks row by row. Typing, clicks, vertical scrolling, tab changes and resizes end a session on the nearest column first.

`NEOLINK_HSCROLL=0` restores column steps for comparison. Same-binary A/B, release, native full screen, unlocked, native editor, 4 alternating rounds of `editor-horizontal`: 60 Hz sideways finger events over a file of long lines, scrolled right and back for 3 s. The pointer is over the editor; without that, Neovim ignores the wheel and the old path never moved.

| Metric (per run) | Column steps (`NEOLINK_HSCROLL=0`) | Pixel-smooth (default) |
| --- | --- | --- |
| Changed-content interval p50 / p95 | 16.7 / 16.7 ms (all four) | **8.3 / 8.3 ms (all four)** |
| Missed refreshes while scrolling | 179 / 177 / 179 / 179 | **0 / 1 / 0 / 3** |
| Display frames with no horizontal motion while scrolling | (whole-column jumps) | **0 of ~353** in every run |
| Ratio between consecutive frame steps, p50 / p95 | n/a | 1.01–1.03 / 1.07–1.22 |
| Neovim redraws / rows rewritten | 180 / 10,350 | 19 / 754 |
| Process CPU (% of one core) | 40.8 / 42.4 / 35.4 / 41.5 | 30.5 / 29.3 / 32.1 / 34.3 |
| Longest main-thread stall | 6.7 / 13.4 / 10.4 / 9.0 ms | 8.4 / 10.6 / 9.1 / 19.8 ms |

`editor-diagonal` and `editor-flick` did not change: 0 stalls and 0 jumps in nearly every run of both arms. One run of the new arm had a 19.8 ms longest stall, with 11 samples over 8 ms; the other three stayed at or under 10.6 ms. Starting a session still builds the window's rows once when the first chunk arrives. Physical trackpad feel is not established by these runs.

**The native editor is now the default.** All of this, the cached tab images and the faster presentation only reach the editor through the native client. The TUI-in-PTY path is now the fallback: it is used automatically when Neovim cannot attach natively, under **View → Native Editor Rendering (after Restart)**, or with `NEOLINK_NATIVE_GRID=0`. `NEOLINK_NATIVE_GRID=1` forces the native client. Note that `open NeoLink.app` does not pass shell variables to the app; use `open --env NAME=value -n NeoLink.app` or run the binary directly.

## Trackpad axis locking and explorer glide

**Diagonal editor scrolling.** A finger scrolling "vertically" drifts sideways. With `nowrap` every sideways column made Neovim redraw the whole screen (each row rebuilt), so diagonal input put heavy frames and jumps into otherwise smooth vertical motion. `ScrollAxisLock` follows Zed's `OngoingScroll` (gpui `gestures.rs`): a trackpad gesture locks to its dominant axis on its first event (or after a 28 ms pause). It switches only when an event of at least 6 points moves 1.9× further along the other axis. Mouse wheels are not filtered. This applies to the editor and terminal panes (`InteractiveTerminalView`), before the smooth-scroll driver.

**Explorer.** `ExplorerScrollView` moved the clip view once per trackpad event. A finger reports about 60 Hz, so the explorer held every other 120 Hz frame still and stepped by whole event distances. It now feeds the same `ScrollResampler` as the editor and glides at the display's cadence, snapped to device pixels. Programmatic scrolling and other origin changes cancel the glide, and the live-scroll end notification waits until the glide finishes.

New benchmark scenarios: `editor-diagonal` (60 Hz finger events with sinusoidal sideways drift up to 35 %) and `explorer-steady` / `explorer-flick` (wheel events delivered to the explorer, with the clip origin sampled at every display frame; the steady profile is analysed only where the content can move).

Release builds, alternating before/after, native full screen, unlocked, native editor client. Seven of 14 runs failed setup because other apps (other NeoLink windows, another agent) kept the full-screen window from becoming key. They are excluded, and the 4 valid baseline and 3 valid new runs are listed in run order:

| Metric | Before | After |
| --- | --- | --- |
| `editor-diagonal`: horizontal steps sent to Neovim | 25 / 25 / 25 / 25 | **0 / 0 / 0** |
| `editor-diagonal`: stall frames | 143 / 65 / 75 / 70 | 78 / **0 / 1** |
| `editor-diagonal`: jump frames | 31 / 12 / 15 / 17 | **1 / 0 / 1** |
| `editor-diagonal`: per-frame velocity error p95 (lines/s) | 97.5 / 41.3 / 45.0 / 59.9 | 22.5 / 3.8 / 3.8 |
| `explorer-steady` (60 Hz finger events): frames with no motion while it should move | 89 / 89 / 86 / 86 (of ~175) | **0 / 0 / 1** |
| `explorer-steady`: ratio between consecutive frame steps p50 / p95 | 1.00 / 1.00 (alternating 10 pt and 0) | 1.86 / 4.50; 1.10 / 1.25; 3.25 / 10.67 |
| `explorer-flick` (120 Hz events): frames with no motion | 18 / 18 / 18 / 18 | 15 / 4 / 15 |
| `editor-flick`: stalls / jumps | 0 / 1; 0 / 0; 15 / 9; 0 / 0 | 0 / 0 in all three |

The first new `editor-diagonal` run (78 stalls, 80 ms best-fit lag) and the third new `explorer-steady` run (131 instead of ~175 display frames sampled) look disturbed by the same competing apps. The explorer now moves on every frame, but how evenly varies between runs: one run was even (p50 1.10), and the others mixed short and long steps. Measured unevenness could come from the display-link callbacks the sampler sees, so this is not established as visual unevenness. A physical trackpad check is still needed. `editor-slow` skipped 86–95 refreshes in both arms in this session (0 in earlier sessions), so it is environmental here, not a difference between the builds.

## Direct workspace presentation (input-to-photon latency)

Per-frame traces showed every workspace frame was scheduled by `CAMetalDisplayLink` for a target **about 24 ms (3 refreshes at 120 Hz) after its callback**, and about 41 ms (5 refreshes) in later runs. Frames then often arrived 2–18 ms after that target. That fixed delay sits under every keypress, click, hover and scroll, and it is why typing in the editor and terminal measured about 30 ms key→display even when the editor did almost no work. It does not show up as a dropped frame.

The shared workspace now presents directly (`NeoGPUDirectFrameSource`): the window's `CADisplayLink` ticks at each refresh, the workspace takes `CAMetalLayer.nextDrawable()`, encodes, and presents as soon as the command buffer is committed. It is still one clock for every hosted pane, VSync stays on, there are no extra timers, and the existing one-GPU-frame-in-flight slot still applies. Latency is bounded by never letting more than two drawables wait for the display. A frame counts as waiting until its presentation callback arrives, or half a refresh after the refresh it was made for, because that callback can trail the tick that is asking. If shown frames stop being acknowledged (a sleeping display), the clock stops asking for drawables, because `nextDrawable()` would block. `NEOLINK_PRESENTATION=link` restores the `CAMetalDisplayLink` path for same-binary comparisons. Independent per-pane fallbacks (Quick Open/Git overlays, no workspace) keep their display links.

Same-binary A/B on the release build, native full screen, unlocked and frontmost, native editor client, alternating order. Valid runs: 7 with the display link, 5 direct. One more direct run is excluded: it recorded a 55.8 s main-thread stall while the Mac was locking. The screen locked twice during these runs, and runs interrupted by a lock were discarded. Ranges are across runs:

| Metric (per-run p50 unless noted) | Display link (`NEOLINK_PRESENTATION=link`) | Direct (default) |
| --- | --- | --- |
| Editor typing key → display | 28.9–30.3 ms | **20.5–21.6 ms** |
| Terminal typing key → display | 28.4–30.0 ms | 12.1–29.0 ms (variable) |
| Explorer highlight → presented | 26.7–34.7 ms | **9.8–10.5 ms** |
| Tab → correct buffer presented | 44.1–48.5 ms | **31.3–35.8 ms** |
| Flick scroll input → display (best-fit lag) | 33–49 ms | 23–35 ms |
| Frame prepare → presented (tab switches, median) | 25.5–27.3 ms | 10.8–14.2 ms |
| Dropped drawables, whole workload | 26–85 | **3–6** |
| Resize: maximum main-thread wait | 148–572 ms | **37–60 ms** |
| Resize: changed-content interval p95 | 25–33.3 ms | 29.2 ms |
| Motion: missed refreshes | 6–69 | 3–12 |
| Motion / typing CPU (% of one core) | 19–38 / 28–29 | 19–39 / 28 |

Every interaction that ends in a presented frame is 9–17 ms sooner, and dropped drawables nearly disappear. Resize's worst main-thread wait falls from hundreds of milliseconds to about 50 ms: the display-link path apparently stalled the main thread around drawable acquisition during live resize. Terminal typing improved in some runs only. Resize content cadence is slightly worse at p95 (29.2 vs 25 ms). These are procedural measurements, not physical click-to-photon latency; how it feels still needs a person.

## Scroll resampling (display-rate trackpad motion)

`SmoothScrollDriver` used to draw each trackpad event's distance the moment it arrived and nothing in between. Input slower than the display (a slowly moving finger reports about 60 Hz; arrival times also jitter) therefore repeated frames every other refresh on a 120 Hz display. `ScrollResampler` keeps the recent history of the accumulated input and, on every display frame of the shared NeoGPU clock, draws the position it had `delay` seconds earlier by linear interpolation. For input slower than 1.5 display frames the delay was one input interval plus 6 ms; for input at the display's rate it was half an interval plus 2 ms (the two now blend continuously and the rate is measured from every event: see [the responsiveness pass](#responsiveness-pass-exact-editor-rows-steady-resampling-cheaper-switches)). It is capped at 30 ms, never draws ahead of the fingers, never overshoots, and drops input the content had no room for (an end of the buffer) so reversing does not jump. It applies to program scrolling (the editor) and to local scrollback; the animation stops when the remainder has been drawn, so no extra clock or timer is introduced.

Same-binary-source A/B, release, native full screen, unlocked, native editor client, 5 alternating rounds of synthetic scroll events (not a trackpad). Per-run values in run order:

| Scenario / metric | Before | After |
| --- | --- | --- |
| `editor-slow`: refreshes skipped while the finger moved at least one device pixel per refresh | 86 / 92 / 91 / 86 / 82 | **0 / 0 / 0 / 27 / 1** |
| `editor-slow`: best-fit input-to-display lag (ms) | 38 / 38 / 41 / 36 / 35 | 53 / 54 / 58 / 62 / 54 |
| `editor-flick` (120 Hz input): stall frames | 1 / 0 / 1 / 2 / 2 | 0 / 0 / 0 / 0 / 0 |
| `editor-flick`: lag (ms) | 38 / 31 / 37 / 34 / 34 | 41 / 40 / 40 / 49 / 40 |
| `terminal-scroll` (scrollback): lag (ms) | 46 / 40 / 26 / 39 / 41 | 32 / 33 / 32 / 33 / 36 |

The slow-scroll gap is the intended effect: content now moves on (almost) every refresh instead of every other one. The cost is about 15 ms more input-to-display latency for slow 60 Hz input and 3–6 ms for 120 Hz input. The harness's per-frame velocity error against its input timeline is higher after the change for flicks (about 8–12 vs 6 lines/s, with one 40 lines/s outlier run with 3 jump frames) and reversals (4–15 vs 0.2 lines/s) because the drawn motion is a delayed, interpolated copy of the input, which the benchmark scores against the raw trajectory. The unmodified baseline also has outlier runs (a 28-jump `terminal-scroll` run and an 8.8 lines/s `editor-reversal` run). Whether this feels smoother on a real trackpad, and how it feels at the start and end of a gesture, is not established by these runs.

## Continuous workspace refresh (1.11.1, build 25)

The saved **View → Continuous High Refresh** preference defaults on. Shared coding panes reuse their retained textures and submit once per owning CAMetalDisplayLink deadline, up to the display rate capped at 120 Hz, even between content changes. There is no additional timer, independent animation phase, synchronous GPU wait or unbounded frame queue. Hidden/minimized windows pause. Turning the preference off restores demand-driven operation; native panels and macOS 13 retain their existing paths. This increases idle GPU work and does not force the panel’s physical refresh or guarantee no missed frames.

The Performance Monitor separates presented drawables (which include cached repeats) from content changes and now reports workspace presentation interval p95/max. Release reports include `workspaceDrawableIntervalMs` and late intervals separately from changed-terminal and changed-explorer metrics. Historical results below used their own documented policies and are not Build 25 measurements.

### Full-screen release results

Alternating same-binary checks on the M2 Max used continuous mode, demand-driven mode, continuous, then demand-driven; each motion/idle scenario ran five seconds plus drain, frontmost and unlocked. The intermediate binary's continuous motion CPU was 42.4% / 43.1% of one core, versus 42.9% / 43.2% in demand mode. Both modes had 8.3 ms p95 changed-terminal and explorer intervals. Maximum changed-content intervals were 25 / 8.3 ms continuous and 33.3 / 33.3 ms demand-driven. These few runs do not establish a reliable motion speedup.

Continuous idle drawable p95 was 8.3 ms in both runs (max 8.3 / 25 ms), with 17.9% / 15.8% instrumented CPU. Demand-driven idle had no workspace presentation intervals and 4.1% / 4.5% CPU. The 2 ms responsiveness probe adds work: these are not ordinary idle CPU or energy figures. Continuous mode deliberately trades idle presentation work for keeping the display-link request active.

The final package, after deleting unreachable scaffolds and retaining long visible stalls in presentation metrics, measured **8.3 ms motion p95 and 16.7 ms maximum** for workspace drawables, changed terminal content and changed explorer content. It had zero explorer fallbacks, 39.1% instrumented motion CPU, 8.3 ms idle drawable p95/max and 19.0% instrumented idle CPU. This single final run does not establish lower CPU than earlier builds. Native chrome and the display panel remain controlled by macOS; natural trackpad feel and authenticated remote performance are separate acceptance checks.

[All reports, setup and intermediate/final binary hashes](rendering-build25.json). The current package additionally fixes low-core ACP task-pool starvation, without changing rendering code. Its 139 native tests pass, including eight ACP tests with one cooperative worker. A subsequent check of the installed package after the agent fix measured 8.3 ms p95/max for workspace drawables and both changed-content streams, zero explorer fallbacks, 38.2% instrumented motion CPU and 19.7% instrumented idle CPU. Its five-second workload had no held-frame gap; this is not a guarantee for longer sessions or natural input. It passes actual Neovim runtime checks (including Python diagnostics/definition), eight offline benchmark checks, and packaged-resource/signature verification. These checks do not establish public notarization or zero dropped frames.

[Terminal-output comparison with VS Code](TERMINAL_BENCHMARK.md) · [Release checks and distribution limits](RELEASING.md)

## Shared NeoGPU workspace (1.11.0, build 24)

NeoGPU is a custom Swift/Metal retained scene engine, with ordered scenes and a supplied-drawable frame loop. Visible terminal/editor and explorer panes now latch state at one display deadline, share one command buffer, and composite into a single workspace drawable. The independent window animation clock pauses during hosting. This removes a second animation phase and independently presented coding panes. [Architecture, scope and source references](NEOGPU.md).

The engine retains packed instances, batches adjacent compatible primitives without changing paint order, clips each pane in backing pixels, keeps VSync enabled and bounds in-flight GPU work without blocking the main thread. Text remains native-resolution with nearest sampling; no reduced-resolution framebuffer or text rescaling is introduced. Native controls retain input and accessibility. Quick Open/Git overlays temporarily restore independent surfaces. Native chrome, agent conversations, PDFs, Folder List and SFTP remain native; their rendering is not rewritten. CPU text rasterization, terminal parsing and Neovim remain CPU work.

### Same-binary full-screen checks

Four unlocked/frontmost runs used the same release binary on the M2 Max, native macOS full screen at 1728 × 1084 points, 2x backing and 12-point terminal text. Run order was shared, independent, shared, independent. Each motion workload lasts five seconds plus presentation drain. Both shared runs confirmed two hosted panes and zero native explorer fallbacks.

| Metric | Shared 1 | Independent 1 | Shared 2 | Independent 2 |
|---|---:|---:|---:|---:|
| Process CPU, percent of one core | 41.1% | 43.4% | 40.9% | 44.4% |
| Terminal new-frame interval p95 | 8.3 ms | 8.3 ms | 8.3 ms | 8.3 ms |
| Terminal longest interval | 8.3 ms | 16.7 ms | 33.3 ms | 25 ms |
| Terminal intervals over 12.5 ms | 0% | 1.4% | 0.7% | 0.7% |
| Explorer changed-frame interval p95 | 8.3 ms | 8.3 ms | 8.3 ms | 8.3 ms |
| Explorer longest interval | 8.3 ms | 33.3 ms | 33.3 ms | 33.3 ms |
| Process footprint during motion | 267.6 MiB | 216 MiB | 268.3 MiB | 217.2 MiB |

Motion CPU was about 5–8% lower in these pairs. One shared run had no held frames; the repeat retained occasional gaps. The added private terminal framebuffer and workspace composition increased measured process footprint by about 51 MiB. Hidden terminal framebuffers are released. Shared-mode GPU timings cover the whole workspace command buffer and must not be quoted as isolated explorer execution times.

Idle results varied in both modes: the second shared run and first independent run had zero clock callbacks, no terminal frames and 5.1% instrumented CPU. The other shared/independent runs had 515/550 callbacks and 29.5%/27.6% CPU despite no changed terminal frames. That intermittent activity was not isolated; the 2 ms responsiveness probe itself adds work. These are not normal idle CPU or energy measurements.

**Real trackpad smoothness remains unverified.** These procedural results do not establish uninterrupted 120 FPS or subjective smoothness. A separate 30-second manual attempt captured zero explorer movement and no terminal scroll samples, so it is excluded as an input-motion acceptance test. User-reported choppiness must be checked in the installed Build 24, not the older Applications copy that was still running during the first comparisons. [Raw reports, rejected manual attempt and binary hash](rendering-build24.json).

137 native tests pass, including retained scene order/clipping/translation, shared terminal pixels compared byte for byte with the independent renderer (colors, CJK and emoji), transparent workspace chrome, oversize-pane scissoring, the SwiftUI host/overlay sibling hierarchy and resize, animation-deadline ownership and native-clock recovery. Neovim runtime checks and eight offline benchmark checks pass. Release UI checks exercised Quick Open, Git review, code scrolling, tab switching, native fallback and GPU re-enabling without session restart. Authenticated remote performance was not measured.

```sh
NEOLINK_WINDOW=fullscreen NEOLINK_BENCHMARK=render-motion,idle \
NEOLINK_BENCHMARK_OUTPUT=/tmp/neolink-workspace.json \
NeoLink.app/Contents/MacOS/NeoLink
```

Repeat with `NEOLINK_GPUI_WORKSPACE=0` for independent surface presentation. Keep the window frontmost and screen unlocked. A failed early prototype placed the overlay inside NSHostingView: it encoded content but received no presentation callbacks. The final container makes the SwiftUI host and GPU overlay siblings; the new hierarchy regression test protects that correction.

## Retained GPU composition (1.10.3, build 23)

The custom Metal explorer compositor now retains a block of nearby, fully rendered rows in a private GPU texture. Ordinary scrolling encodes one textured quad rather than rebuilding row geometry, hashing row URLs and binding each row texture on every display callback. Metal performs both the initial row composition and subsequent viewport sampling. The texture stays at native backing-pixel resolution with nearest sampling and integer-pixel placement; it does not scale down text.

A retained block is reused only when it covers the visible row range and matches the current scene revision, backing scale and pixel width. Selection, hover, Git/diagnostic decorations, content changes and resize invalidate it. It includes up to 24 nearby rows on either side and at most 16 MiB of extra GPU storage, independently of the existing bounded row cache. Oversized viewports or allocation failure retain the direct per-row GPU path. Missing row artwork still reveals the complete native table. Input, accessibility, menus, drag/drop, SSH/SFTP and document handling retain their existing paths. Rejected old-size drawables schedule up to three bounded recovery attempts, so a scrollbar/viewport size change cannot strand the surface on native rows while no further input arrives. The Performance Monitor names the fallback reason when the explorer is not covered by Metal.

Unchanged explorer content is no longer invalidated by unrelated terminal activity. Detailed per-frame motion samples and CPU/GPU profiling are opt-in for the benchmark, so ordinary scrolling does not maintain its large trace array. CoreText still prepares new glyph and row artwork on the CPU; cached visual composition is GPU work. This is a retained Metal renderer component, not a replacement of every native panel with a new UI framework.

### Same-binary full-screen comparison

Four valid, unlocked/frontmost runs on the M2 Max's built-in 120 Hz display used the same packaged binary, 1728 x 1084 point native full-screen window, 2x backing and 13-point terminal font. The first pair ran direct then retained; the second pair reversed that order. Both animate the terminal and explorer for five seconds plus presentation drain.

| Metric | Direct 1 | Retained 1 | Retained 2 | Direct 2 |
|---|---:|---:|---:|---:|
| Process CPU, percent of one core | 46.1% | 41.7% | 42.2% | 51.1% |
| Explorer CPU prepare/encode total | 570.5 ms | 36.9 ms | 37.3 ms | 630 ms |
| Explorer CPU prepare/encode p95 | 1.6 ms | 0.2 ms | 0.2 ms | 1.6 ms |
| Explorer GPU execution total | 136.7 ms | 110.8 ms | 119.1 ms | 130.5 ms |
| Explorer GPU execution p95 | 1 ms | 1 ms | 1 ms | 1 ms |
| Retained block builds / reuses | 0 / 0 | 5 / 617 | 5 / 628 | 0 / 0 |
| Terminal new-frame interval p95 | 8.3 ms | 8.3 ms | 8.3 ms | 8.3 ms |
| Explorer changed-frame interval p95 | 8.3 ms | 8.3 ms | 8.3 ms | 8.3 ms |
| Native explorer fallbacks | 0 | 0 | 0 | 0 |

Explorer CPU rendering work decreased by about 94%; total process CPU was 9.5% and 17.4% lower in the two pairs. These are different scopes. GPU execution also became more efficient: retaining composition does not imply a higher GPU utilization percentage. This moves repeated scene work out of the CPU loop without adding artificial GPU load. System-wide GPU utilization and energy consumption were not measured.

Three idle scenarios had zero window callbacks and no terminal frames, with 4.7–4.9% instrumented process CPU. The retained repeat's idle scenario had 119 callbacks and terminal content updates (13.1% CPU); the source of that activity was not isolated. The 2 ms responsiveness probe itself adds work, so those figures must not be quoted as normal idle CPU. Motion scenarios still had occasional 16.7–33.3 ms held-frame gaps; p95 at 8.3 ms does not establish uninterrupted 120 FPS or subjective smoothness. No natural-input or authenticated remote performance claim follows from this procedural workload.

[Raw reports and tested binary hashes](rendering-build23.json) retain all four comparison runs and the final-package check after adding resize recovery. The final package measured 42.8% process CPU, 29.4 ms total explorer CPU encoding, one composition build and 628 reuses, with 8.3 ms p95 on both surfaces and no native fallbacks. Its maximum terminal/explorer intervals were 33.3/16.7 ms; idle had zero clock callbacks and no terminal frames. The 129 native tests pass, including byte-for-byte comparison of retained GPU pixels against the independent per-row path during fractional scrolling and reversals, plus selection/hover invalidation, input pass-through, rejection of stale-size drawables, recovery without further input and native fallback. Neovim runtime and eight offline benchmark checks pass.

Repeat the existing full-screen command below with `NEOLINK_EXPLORER_COMPOSITION=0` to compare the direct path. That variable is read only by the developer benchmark and never changes the persisted user preference. Normal rendering uses retained composition when available.

## Full-size explorer work and surface motion (1.10.2, build 22)

The larger-window investigation separated CPU preparation, GPU execution and actual drawable presentation. In the maximized baseline, terminal encoding took 0.2 ms at p95 and GPU execution 1.8 ms, while the main-thread probe saw waits up to 29.9 ms. A main-thread sample also found native AppKit glyph rasterization underneath the Metal explorer: setting row layer opacity to zero had not stopped that work.

- Covered explorer cells now hide their artwork container and defer native label/icon updates. The cell itself remains available for accessibility, hit testing, menus and drag/drop. When Metal falls back, it restores the latest row artwork and geometry. Covered rows skip their native artwork layout.
- Precise, unmodified vertical trackpad input goes directly into the Metal explorer's clip position, including macOS momentum deltas. This avoids sampling a separately animated AppKit backing layer. The viewport clamps at its bounds. Mouse wheels, modified/horizontal gestures and the native fallback retain AppKit handling; Folder List and SFTP are unchanged.
- Editor scroll-settling animations advance on their own terminal Metal callback after parsed output, using its target presentation timestamp. They no longer depend on the phase of the independent window clock. Native fallback and occlusion still settle the animation.
- Opt-in benchmark instrumentation reports CPU encoding, GPU execution and GPU queue wait. Normal rendering does not install this profiling callback or read back pixels. Retina backing resolution, phase-aware glyph coverage and VSync are unchanged.

These independently implemented Swift changes use [Apple’s target presentation timestamp guidance](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/update/targetpresentationtimestamp). Existing workspace features retain their original models and input paths.

### Release checks

The native regression suite passes 129 tests, including covered-cell reuse/accessibility/fallback, precise scroll bounds, Metal pixel comparisons, and surface animation ownership/fallback/occlusion. Neovim runtime checks and eight offline benchmark checks pass.

On the M2 Max's built-in 120 Hz display, at 2x backing scale and 13-point text, two valid five-second **native macOS full-screen** runs produced:

| Metric | Run 1 | Run 2 |
|---|---:|---:|
| Terminal new-frame interval, p50 / p95 | 8.3 / 8.3 ms | 8.3 / 8.3 ms |
| Explorer changed-frame interval, p50 / p95 | 8.3 / 8.3 ms | 8.3 / 8.3 ms |
| Longest terminal / explorer interval | 25 / 33.3 ms | 16.7 / 33.3 ms |
| Terminal intervals over 12.5 ms | 1.2% | 1.0% |
| Terminal GPU execution, p95 | 0.8 ms | 0.7 ms |
| Native explorer fallbacks | 0 | 0 |

A final-package repeat (after removing an unreachable statement in benchmark setup) again measured 8.3 ms at p50/p95 on both surfaces, with 16.7 ms maximum intervals, 2.1% terminal intervals over 12.5 ms, no explorer fallbacks, and no idle clock callbacks or terminal frames. Its binary hash and raw report are recorded alongside the earlier runs. Release UI checks verified tree expansion and scrolling, file context actions, opening code in a tab, code scrolling, and restoring the latest native row artwork when GPU rendering is toggled off and on.

The window was 1728 x 1084 points, with a 187 x 59 terminal grid; `nativeFullScreen: true` verifies the window mode. A repeated 1000 x 682 point run had terminal p95 of 16.7 ms and explorer p95 of 8.3 ms. An earlier small-window run had 25 ms p95 on both surfaces; it is retained in the raw data rather than discarded. Idle in the repeated runs had zero window-clock callbacks and no terminal frames. The first full-screen run had idle activity (463 window callbacks); its cause was not isolated.

An intermediate matched maximized-window comparison, before the final scroll-routing changes, reduced CPU usage from 56.4% to 38.8% of one core and the longest main-thread wait from 29.9 ms to 6 ms. This supports removing duplicate native artwork work, but is not an end-to-end speedup claim for every workload.

[Raw reports](rendering-build22.json) include the baseline, intermediate build, poorer small-window result, full-screen repeats and rejected-run reasons. **This is not a guarantee of uninterrupted 120 FPS or subjective smoothness.** The workload is a procedural animation, not a natural trackpad gesture; occasional held frames and run-to-run variability remain. Native fullscreen versus composited windows is also a confounding factor. Human trackpad acceptance and authenticated SSH/SFTP performance remain separate checks.

Reproduce native full-screen without racing an accessibility-tree button during fixture loading:

```sh
NEOLINK_WINDOW=fullscreen NEOLINK_BENCHMARK=render-motion,idle \
NEOLINK_BENCHMARK_OUTPUT=/tmp/neolink-fullscreen.json \
NeoLink.app/Contents/MacOS/NeoLink
```

The harness enters the full-screen Space, waits for the transition and fails setup unless the window is key and full-screen. `NEOLINK_WINDOW=max` maximizes within the visible screen; `1000x650` requests a smaller content size. Keep the window frontmost and screen unlocked; the harness exits after writing the report. The expanded fixture now contains enough rows to scroll at full display height.

## Text clarity and surface updates (1.10.1, build 21)

This follows the reported Build 20 blur/judder regression and retains the subsequent larger explorer cache, visible-row prefetch priority, scroll-reversal correction and local row-hover changes.

- Terminal glyphs now cache four CoreText raster phases on each axis. The fractional baseline is incorporated into the coverage bitmap; ordinary glyph quads land on integer device pixels instead of linearly filtering an already-antialiased glyph between pixels. Phase quantization is translation-invariant even for negative coordinates. Scaled CJK fitting keeps its existing path. Atlas size limits still apply.
- Terminal drawables must match the current rounded backing-pixel dimensions. A stale drawable after a resize/display move is refused rather than drawing the new viewport into the old texture. The render viewport uses the actual texture dimensions.
- On macOS 14+, parsed terminal display updates are consumed by that surface's Metal callback immediately before its draw. They no longer wait for the independent window CADisplayLink and then a second drawable callback. CPU/native rendering and macOS 13 keep the previous window-clock path. Pending updates drain on renderer changes and window occlusion.
- Explorer artwork is mapped one-to-one in device pixels. SF Symbols are rasterized at the actual backing scale, native font descriptors are retained, and completion-triggered viewport work is batched over 4 ms. Incomplete visible artwork reveals the complete native table rather than presenting blank rows or stale cached text for up to 30 frames. The larger 512-row/32 MiB-or-four-viewports cache and 48-row prefetch margin remain.

The 126-test native regression suite compares every fractional glyph phase against direct CoreText coverage, verifies translation across negative/positive coordinates, and checks surface-local state consumption without a window-clock tick, renderer switching and occlusion. Existing Metal scrolling pixel tests and a stale-size drawable rejection test also pass. Neovim runtime and eight offline benchmark checks pass. This verifies raster correctness; it does not measure a human's perception of motion.

### Release validation and remaining motion variability

All 126 native tests, the real Neovim runtime checks and eight offline benchmark checks pass. Release UI checks exercised shell output/scrollback, text sizing, native/GPU switching, opening a code tab and resizing it. The text tests compare all 16 raster phases against direct CoreText coverage; they establish crisp raster placement, not perceived motion quality.

Two valid final-package runs on the M2 Max, 120 Hz built-in display, 1720 × 832 point window, 2× backing scale and 13-point text gave these results. Both stayed frontmost and unlocked. Each motion scenario lasted five seconds, followed by five seconds idle:

| Surface / metric | Run 1 | Run 2 |
|---|---:|---:|
| Terminal new-frame interval, p50 / p95 | 16.7 / 25 ms | 8.3 / 25 ms |
| Explorer changed-frame interval, p50 / p95 | 16.7 / 33.3 ms | 16.7 / 25 ms |
| Longest terminal / explorer interval | 33.3 / 58.3 ms | 33.3 / 50 ms |
| Native explorer fallbacks | 0 | 0 |
| Main-thread frame work, p95 | 0.7 ms | 0.8 ms |
| Idle presented frames | 0 | 0 |
| Process footprint during motion | 162.6 MiB | 163 MiB |

[Raw final-package reports and binary hash](rendering-build21.json) preserve both runs. An earlier development run reached 8.3 ms at p95 on both surfaces, but that was not consistently reproduced. The final runs therefore **do not establish sustained 120 Hz, a speedup over the previous build, or subjective smoothness**. A matched baseline attempt lost foreground focus and was rejected. WindowServer and the remote inspection service were busy during this session; their contribution has not been isolated, so they are not treated as a proven explanation. This release fixes verified raster/resizing issues and scheduling dependencies, while perceptual smoothness remains an open acceptance check.

### Source research

Reviewed pinned source, independently implementing the changes in Swift:

- [Ghostty surface presentation](https://github.com/ghostty-org/ghostty/blob/18e645ea22a5ef4793a2008275eb6f98e5d039bb/src/renderer/metal/IOSurfaceLayer.zig): rejects asynchronously completed surfaces of the wrong size, avoiding resize artifacts. Its [render thread](https://github.com/ghostty-org/ghostty/blob/18e645ea22a5ef4793a2008275eb6f98e5d039bb/src/renderer/Thread.zig) coalesces wakeups instead of doing work continuously at idle.
- [Alacritty renderer updates](https://github.com/alacritty/alacritty/blob/aecf0f600fa840a415b55da5cf34fbeaec39ac32/alacritty/src/display/mod.rs): applies pending resize/font-cache changes just before rendering.

The supplied architecture notes were useful directions, not performance evidence. No application intercepts input at the kernel to guarantee the first frame in 8.33 ms; ProMotion remains controlled by macOS. A rope, Tree-sitter or SDF UI shader does not by itself correct an interpolated glyph bitmap or uneven presentation deadlines.

## Metal explorer and drawable pacing (1.10.0, build 20)

The project tree now has its own Metal drawing surface, fixed beside the native clip view so concurrent native scrolling cannot translate it a second time. CoreText prepares immutable row artwork on a background queue; cached GPU textures are translated and clipped on each frame. Selection and hover are GPU fills, so scrolling and highlighting do not re-rasterize every label. The native table retains keyboard navigation, type selection, context menus, drag/drop and accessibility. It becomes the visible fallback during cache misses or GPU failure. Folder List, SFTP and other AppKit/SwiftUI controls keep their native rendering paths.

On macOS 14 and later, `CAMetalDisplayLink` supplies explorer drawables with VSync and the system’s default render lead time. This avoids taking another drawable from the main thread while the pool is busy. macOS 13 uses the native display-clock fallback. Window visibility, minimize, display changes and backing-scale changes reconfigure or pause the surface. Shutdown invalidates the display link once and restores native rows. Shader preparation is shared and runs off-thread. Artwork is limited to 256 cached rows with a byte budget of 24 MiB or twice the viewport's pixel footprint, whichever is larger.

Interaction briefly keeps the cached explorer scene presenting for 250 ms. This provides ProMotion activity without adding repeated terminal frames to the terminal's drawable queue. The Performance Monitor separates the explorer's presented drawable rate from its scene-change rate: repeated pictures are not counted as motion. The overall window remains a native SwiftUI/AppKit application; it is not a GPUI integration.

Terminal/editor surfaces also receive display-link-provided drawables on macOS 14+. Their renderer builds a render pass around that supplied texture and bypasses MTKView drawable acquisition while attached. Requests coalesce to the newest pending draw; an empty update pauses the link without queuing an identical frame. The legacy presentation-count throttle is unnecessary for a drawable already acquired by the display link. macOS 13 retains the prior MTKView path.

The window clock still advances terminal state and animations; each surface submits from its own drawable callback. A trial that advanced the whole window from the explorer callback regressed terminal cadence, so it was removed. GPU completion releases the explorer's frame slot directly on the completion thread, so another main-run-loop turn is not required before its next frame. Metal row artwork is kept outside the scrolling clip view to avoid a second translation by native concurrent scrolling.

Terminal state and GPU submission share the supplied-drawable callback. GPU completion releases in-flight resources without blocking the main thread.

`NEOLINK_BENCHMARK=render-motion` is a five-second procedural animation of terminal scrollback and the explorer viewport. It uses no keyboard or wheel injection and records terminal drawable timing, explorer changed-frame timing and native fallbacks. It isolates rendering cadence from the input-event rate. It does not establish natural trackpad feel or smoothness as perceived by a person. `manual-motion` remains available for input-driven comparison.

Validation: 121 native tests pass, including offscreen Metal pixels for explorer selection, badges, fractional edges, native fallback and terminal drawable handoff. Neovim runtime and eight offline benchmark checks pass. Unlocked release UI checks exercised explorer scrolling/selection, file context actions, embedded file opening, GPU/native toggles, shell output/scrollback and closing/reopening the browser. The native control path remains in place; authenticated SFTP and human trackpad acceptance are separate integration/acceptance checks. Native drawing is serviced by AppKit's run loop rather than a forced whole-window display pass every frame.

NeoLink uses a vendored SwiftTerm 1.20.0 Metal renderer for terminal-backed surfaces: local shells, SSH sessions, agent terminals, REPLs, and the shared Neovim editor. NeoLink keeps its AppKit/SwiftUI architecture and uses Metal for GPU composition. NeoLink's changes to SwiftTerm are listed in `Vendor/SwiftTerm/UPSTREAM.md`.

## Build 20 release measurement

On an M2 Max with the built-in 120 Hz ProMotion display, unlocked/frontmost release build, 1280 × 832 point window, five seconds of procedural motion:

| Surface | New-frame interval p50 / p95 | Longest interval |
|---|---|---|
| Terminal scrollback | 8.3 / 16.7 ms | 33.3 ms |
| GPU explorer | 8.3 / 16.7 ms | 25 ms |

The terminal recorded 551 new-frame intervals and 7.6% longer than 12.5 ms; the explorer recorded 544 changed frames with no native fallbacks. There were 600 window-clock intervals. These are different counts: 120 callbacks per second does not mean every refresh carried new pixels. The main-thread probe's longest wait during motion was 15.4 ms. The idle scenario recorded zero clock callbacks and zero new terminal frames. Process footprint was about 102 MiB during motion. Full samples and the tested binary hash are in [rendering-build20.json](rendering-build20.json).

These results demonstrate remaining held frames and do not establish locked 120 FPS, all-GPU native controls, or subjective smoothness. A 900-point-wide development run reached 8.3 ms at p95 for both surfaces; the larger-window release result above is the reported limit. Frame-work timing covers window-clock work, with per-surface Metal callbacks outside that scope. Natural trackpad input, larger workspaces, other displays and system load can change the result.

Reproduce without synthetic input: `NEOLINK_WINDOW=1280x800 NEOLINK_BENCHMARK=render-motion,idle NEOLINK_BENCHMARK_OUTPUT=/tmp/neolink-rendering.json NeoLink.app/Contents/MacOS/NeoLink`. Keep the app frontmost and the screen unlocked. The benchmark exits when complete.

## Drawing and lifecycle

- CoreText shapes/rasterizes glyphs into a cached atlas. Metal draws cell backgrounds, glyphs, selections, and the cursor as GPU primitives.
- Row geometry is cached per `BufferLine` object, not per screen row. Scrolling moves line references, so a line that only moved is drawn translated by a vertex-shader offset instead of being shaped again. Only rows whose content changed are rebuilt.
- Each window has a display-link clock (`WindowFrameScheduler`, capped at 120 Hz) for animations and legacy/native updates. On macOS 14+, terminal state updates and GPU submission use that surface's Metal drawable callback. Clocks stop when idle; an occluded or minimized window drains work without animation.
- Historical Build 17 used demand-driven terminal presentation. An earlier timer-driven repeated-frame experiment added about 9 ms to key-to-display latency by queuing stale frames. Build 25 repeats retained workspace content only at the owning display-link deadline; this requires separate release validation.
- On the legacy path, output answering a key press requests immediate submission after parsing. On macOS 14+, it is consumed by the next supplied Metal drawable, without an intervening window-clock tick. All terminal-backed surfaces keep `CAMetalLayer.displaySyncEnabled = true`, including sparse key echoes. Early submission still prepares the response promptly; presentation waits for a display refresh in composited and full-screen/direct windows alike. VSync prevents unsynchronized presentation; it does not guarantee that every refresh contains a new frame.
- On the legacy MTKView path, a surface with three frames waiting for the display defers its next frame instead of requesting a fourth drawable. The macOS 14+ path uses the drawable supplied by CAMetalDisplayLink. Requesting one would block the main thread in `nextDrawable`, which stalls input; that happened during 10 ms key repeat when ProMotion lowered the refresh rate.
- Covered surfaces do not draw. Terminals hidden behind a document tab are hidden NSViews rather than zero-opacity SwiftUI layers.
- The shader library and pipelines are compiled once per process, on a background queue at launch, and shared by every terminal. Previously each new terminal, including the editor's, compiled them on the main thread.
- GPU setup happens after a terminal joins a window. SwiftTerm handles drawable lifetimes, font/backing-scale changes, window reparenting, and renderer recovery. Failed initialization leaves the CoreGraphics path available; toggle GPU rendering off and on to retry.
- **View → Use GPU Text Rendering** applies to existing surfaces and is remembered. Switching renderers retains the PTY, buffer, scrollback, and Neovim process.
- **View → Performance Monitor…** shows the window clock, key-press-to-display latency, and the interval between new terminal frames on screen, from `MTLDrawable.presentedTime`. **Renderer Information…** reports the focused surface's renderer.
- The packaged app includes `SwiftTerm_SwiftTerm.bundle` in `Contents/Resources` with a precompiled `default.metallib` when Xcode's Metal compiler is available; the shader source remains as a fallback. AppKit/SwiftUI, PDFKit, and the native text fallback keep their own rendering paths.

## Smooth scrolling

A terminal grid moves by whole lines, so trackpad scrolling used to jump a line at a time (about 40 content changes per second at a moderate speed). With the Metal renderer, NeoLink now follows the trackpad pixel by pixel in both places text scrolls:

- **Editor and other full-screen programs** (mouse reporting on, alternate screen): NeoLink asks the program to scroll whole lines slightly ahead of the fingers and draws its scroll region back by the remaining fraction. SwiftTerm reports the program's scroll operations (CSI L/M at the region top, CSI S/T) together with the lines that left the region; the renderer draws those lines in the edge the offset exposes and clips the region. Region scrolls restricted by left/right margins are not reported and keep line steps.
- **Shell scrollback**: the viewport moves by whole lines and the renderer draws the buffer lines above or below it in the exposed edge. Its input is applied directly, without predictive requests or a settling spring. The fractional position is preserved after momentum ends and between gestures. It stays still until new input, and does not keep an animation loop running. Keyboard/scroller navigation, resize and output that moves the viewport clear the parked fraction.

For a full-screen program, the remaining fraction still eases out to a whole line when input stops; that program controls its own grid. Shell scrollback stops at the position supplied by the OS instead. Offsets are whole device pixels, so glyphs stay on the pixel grid. Keyboard-driven scrolls (for example `j` at the bottom of the window) are shown as the program draws them. Classic mouse wheels and the CoreGraphics renderer keep line steps. Lines retained from a program are discarded before a new gesture, on a full-screen erase, and when the region, buffer or size changes, so they cannot show stale text.

## Measured result

Historical measurements from before build 19, not measurements of the current always-VSync policy. One machine: M2 Max, built-in 120 Hz ProMotion display, macOS 26.6, release build, app frontmost. The benchmark (below) posts synthetic key and trackpad events to NeoLink's own event queue and reads when each frame reached the display. Before is the pacing from the previous revision measured with the same harness; one run per row.

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
- The historical sparse-key results used VSync bypass in a composited window. Build 19 keeps VSync enabled; the additional presentation wait can increase sparse-key latency. The historical key numbers must not be attributed to this policy without remeasurement.
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

### Passive motion capture

`NEOLINK_BENCHMARK=manual-motion NEOLINK_BENCHMARK_SECONDS=60` captures externally driven interaction for 60 seconds (5–180 allowed), then writes the report and exits. This scenario does not inject keys or wheel events, focus controls, or select a project. Use the trackpad or an external UI driver to fill and scroll a shell and expand/scroll the explorer. It includes terminal input/drawn positions at actual drawable presentation and explorer clip-view geometry. Geometry is not proof of pixel presentation. Gaps while changing targets or pausing are deliberate; aggregate frame percentiles from a manual session are not a sustained-scrolling FPS score. Compare moving segments and inspect reversals, stops and edge content visually.

For Instruments, `SWIFTTERM_PROFILE=1` enables SwiftTerm's Metal signposts; NeoLink's frames are `Window.Frame` and `Window.ImmediateFrame` signposts (subsystem `com.neolink.app`, category `Frames`). `MTL_HUD_ENABLED=1` shows Apple's Metal HUD.

## Validation

`swift test` includes pixel comparisons of smooth-scrolled Metal frames (`SmoothScrollRenderingTests`), the scroll model, region-scroll reporting, and immediate-frame scheduling. `scripts/test-editor.py` covers the Neovim runtime. The packaged app's precompiled shader library passed the same `editor-capture` comparison.

## Sources

- [SwiftTerm 1.20.0](https://github.com/migueldeicaza/SwiftTerm/tree/v1.20.0) and its Metal implementation.

## Explorer validation and build identity (1.9.0)

The explorer has its own native AppKit table and scrolling path; terminal Metal presentation counters do not measure its pixel presentation. `ui-explorer-scroll` samples clip-view geometry through the existing window clock on macOS 13 and later. It reports total travel, range, stationary intervals between movements, and sample gaps. It invalidates workloads with fewer than 20 changing samples, less than 100 points of travel, or less than 50 points of range. An effectively stationary view cannot produce a valid smoothness result. Geometry movement still does not establish that correctly rendered pixels reached the screen or that the motion feels consistently smooth.

`scripts/bench-run.py` now invokes a successful release build before measuring by default. It uses SwiftPM's exact executable path, records the executable SHA-256 and a fingerprint of app/vendor/shader/Lua inputs, and rejects runs when either changes. An explicit `--binary` is labeled as a prebuilt baseline. Failed builds and failed binary-path resolution stop execution. `python3 scripts/test-benchmark.py` checks these failure paths offline. Earlier explorer results that drove a stationary view are invalid and must not be used as a performance baseline.

The numerical terminal results above describe the earlier measured revision, not a new benchmark of build 18. No claim of a measured explorer FPS gain or visual equivalence follows from this migration.
