# Tab readability and interaction latency (1.11.3, build 27)

Build 27 preserves Build 26's retained explorer text strip, minimal tree reveal and persistent Neovim control connection. It changes admission of warm tab selections, native visibility gating, tab-strip sizing/reveal and raster priority. Refresh targets, VSync and the single display owner remain unchanged.

## Changes and measured bottlenecks

Per-selection instrumentation found a main-thread scheduling/layout delay before a warm selection reached the socket, followed by editor row preparation and presentation wait. An idle warm selection now enters the dedicated socket worker synchronously. The existing command chain remains the ordering barrier when work is pending; saves, closes, initial opens and actions cannot be skipped. Hidden editor toolbar space remains 30 points tall while a shell/PDF is selected, avoiding a pair of unnecessary Neovim grid resizes on each round trip. A window-level regression verifies frame and row-count stability. The native host hides synchronously when selection changes and exposes/focuses the editor only after the matching post-redraw marker. Older acknowledgements and markers cannot expose another selection. Real UI checks also found an optional language server initialization error blocking Neovim behind a hit-enter prompt. Errors now remain in `:messages` and the native banner without blocking commands; a private-PTY regression covers that failure followed by duplicate-basename switching.

Tabs use content-aware widths from 120 to 320 points. Long explorer filenames fit without truncation. Duplicate basenames use the shortest distinct parent suffix, compressed around distinguishing text when necessary. Close and modified slots are always reserved; selection and hover do not change geometry. Full paths remain in tooltips and accessibility labels. A native horizontal scroll view retains momentum and reveals only the nearest edge of an offscreen selected tab. Selecting a visible tab preserves its fractional scroll origin and queues no animation.

Explorer artwork admits visible rows first. At most 16 jobs remain outstanding on the existing serial worker. Nearest neighbors warm before distant rows. A disjoint jump cancels obsolete unfinished work while retaining valid cached artwork. Separate-worker prefetch experiments increased strip churn and memory and were rejected. Row-cache and 16 MiB strip limits remain unchanged.

An experimental terminal row-cache optimization reused width-independent geometry during sub-column resize and passed fresh-render pixel comparisons. Release repeats reduced CPU work but had worse maximum resize stalls, so it was removed. The terminal keeps its prior cache invalidation and clipping behavior. The added native-resolution resize/fresh-render regression remains, covering colors, CJK, emoji and DEC doubled-height/width text. Native split-view layout and framebuffer allocation remain costly.

These choices apply retained primitives/artwork, visible-range work, nearest-edge reveal, logical anchors plus fractional offsets, native momentum and resource lifetime discipline to the current Swift/AppKit/Metal implementation. No replacement UI framework, extra animation clock or new scroll spring was introduced. Existing local scrollback and Neovim grid scrolling retain their separate motion models.

## Selection tracing

Set `NEOLINK_SELECTION_TRACE=1` for bounded per-generation events in the `ui-tabs` report. Set it to an absolute JSON path instead to write the events when the app quits. Recording is off by default and capped at 8192 events; no paths, source text or typed characters are recorded.

Host timestamps use `CACurrentMediaTime`. Neovim records `uv.hrtime` at dispatch, buffer activation, redraw, marker queuing and metadata/acknowledgement. Each response explicitly maps those remote timestamps to the host clock using socket-worker send/receive times and editor dispatch/ack times, and includes the remaining round-trip uncertainty. This is an estimated clock mapping, not an assumption that two clocks have identical epochs. Marker queuing into the TUI is distinct from PTY receipt and parsing.

Host events cover selection and available native input-event timestamps, command enqueue/queue-ready/dispatch, socket receipt, main-thread acknowledgement, metadata adoption, marker recognition, visibility, layout, focus, frame preparation/encoding/submission, GPU scheduling/completion and actual acknowledged-buffer presentation. Each generation is recorded independently. GPU stage tracing covers the shared workspace path on the tested macOS version; native fallback and older systems do not provide every GPU stage. PTY events describe the first chunk during a generation; only the parsed redraw marker establishes the matching buffer boundary.

```sh
swift test
python3 scripts/test-editor.py
python3 scripts/test-benchmark.py
./scripts/build-app.sh
python3 scripts/verify-app.py NeoLink.app

NEOLINK_SELECTION_TRACE=1 NEOLINK_WINDOW=fullscreen \
NEOLINK_BENCHMARK=render-motion,ui-tabs,ui-highlights,ui-resize \
NEOLINK_BENCHMARK_OUTPUT=/tmp/neolink-tabs.json \
NeoLink.app/Contents/MacOS/NeoLink
```

Keep the window frontmost and screen unlocked. Reject invalid/setup-failed runs and retain presentation timeouts and worst stalls. The 24-switch workload reports focus separately from first acknowledged-buffer presentation. Its two editor fixtures contain identical source text in different paths; the redraw marker and status path distinguish buffer identity. The report does not establish physical click-to-photon latency or prove the pixels of every presented frame.

## Release evidence and remaining limits

[Raw repeated runs, setup, hashes and rejected experiments](interactions-build27.json). The current baseline is the saved Build 26 release (`e2ea1b1…1044`); the final installed Build 27 binary is `bef763f5…0ab`, implementation commit `183b498`. Two repeats of each used native full screen at 1728 × 1084 points, 2× backing scale, 12-point text and the unchanged 120 Hz refresh policy on this M2 Max, frontmost and unlocked. Runs were sequential and background desktop load was not controlled. They are not a randomized experiment. The shell grid remained 200 × 63; the hidden editor's two-row setup difference reflects the stable-toolbar fix. There were no selection failures or presentation timeouts in these accepted runs.

Each entry below shows run 1 / run 2. Times are milliseconds; CPU is percent of one core, and memory is process footprint in MiB.

| Metric | Current Build 26 baseline | Final installed Build 27 |
| --- | --- | --- |
| Selection → focus, p50 | 37.6 / 32.5 | 26.4 / 30.0 |
| Selection → focus, p95 | 58.7 / 49.6 | 35.8 / 39.7 |
| Selection → focus, p99 / max | 61.7 / 50.0 | 42.0 / 41.6 |
| Selection → acknowledged-buffer presentation, p50 | 76.7 / 69.9 | 72.9 / 62.0 |
| Selection → presentation, p95 / p99 / max | 90.7 / 87.4 | 81.5 / 79.2 |
| Tab workload, maximum main-thread wait | 39.2 / 29.5 | 39.5 / 38.3 |
| Tab workload, CPU / memory | 27.6 / 270.1; 26.4 / 270.5 | 25.6 / 272.0; 28.5 / 242.8 |
| Motion changed-content interval, p50 | 8.3 / 8.3 | 8.3 / 8.3 |
| Motion interval, p95 / p99 | 8.3 / 8.3 | 8.3 / 16.7 |
| Motion interval, maximum | 8.3 / 16.7 | 16.7 / 25.0 |
| Motion missed-refresh count (terminal) | 0 / 3 | 3 / 35 |
| Motion explorer native fallbacks | 0 / 0 | 0 / 0 |
| Motion CPU / memory | 33.3 / 259.5; 17.3 / 260.0 | 36.7 / 261.5; 40.3 / 232.5 |
| 60 highlight changes, strip builds | 0 / 0 | 0 / 0 |
| Highlight → presentation, p50 / max | 44.1 / 49.4; 43.4 / 45.8 | 43.5 / 45.2; 35.2 / 37.2 |
| Resize changed-content interval, p50 | 25.0 / 25.0 | 25.0 / 25.0 |
| Resize interval, p95 | 33.3 / 33.3 | 33.3 / 41.7 |
| Resize interval, p99 / max | 41.7 / 75.0; 50.0 / 75.0 | 41.7 / 83.3; 45.8 / 83.3 |
| Resize maximum main-thread wait | 149.9 / 172.3 | 251.5 / 107.3 |
| Resize CPU / memory | 92.7 / 302.7; 92.2 / 299.5 | 92.3 / 301.0; 91.3 / 269.2 |

The focus improvement is larger than the visible-buffer improvement. Correct-buffer presentation still takes tens of milliseconds after acknowledgement; native hosting/layout, row preparation and GPU/compositor wait remain. The instrumented intermediate trace puts median socket dispatch at 0.54 ms, marker recognition at 21.32 ms, focus at 21.85 ms, frame preparation at 33.75 ms, encoding complete at 42.42 ms and presentation at 75.22 ms from selection. Clock-map uncertainty was at most 0.124 ms. This trace identifies stages but comes from an intermediate cache experiment, so it is not substituted for final-binary latency measurements.

The 24-switch workload includes 18 editor presentations. At these small sample counts p99 equals the maximum under the existing percentile convention; baseline tab summaries did not emit p99 explicitly. Generic changed-content intervals near 200 ms during `ui-tabs` reflect its deliberate action dwell and are not a scrolling FPS measure. Missed-refresh and drawable counters, full distributions, highlight p95/p99, CPU and memory remain in the raw reports.

**No general scrolling or CPU improvement is established.** The second final motion repeat had more held frames, despite no native fallbacks. Resize worst waits vary widely and remain unacceptable for a continuous 120 Hz claim. The rejected width-cache optimization produced 262.1 / 338.4 ms resize waits and was removed; the final binary retains the conservative terminal renderer. Higher refresh targets and repeated frames were not used to hide response delays.

## Verification

- **Automated correctness:** 154 native tests pass, including glyph phases/reference pixels, highlight overlap, large viewport jumps/reversals, native fallback, fractional anchors, minimal reveal, stable tab geometry, duplicate labels, native horizontal reveal, hidden-editor grid stability, service-error dismissal and ordered rapid selection/save/close behavior. Actual Neovim runtime tests pass, including dirty buffers, saves/conflicts, UTF-16/CRLF, large-file mode and Python diagnostics/definition. A drained private-PTY check proves a multiline service error does not block subsequent duplicate-name switching. Eight offline benchmark checks and release resources/signature checks pass. [Clean macOS CI passed](https://github.com/abhayasho/NeoLink/actions/runs/41778129038).
- **Procedural animation:** final installed binary completed motion, tab, visible-highlight and resize scenarios frontmost and unlocked. Accepted repeats and exploratory candidates are kept separately with their hashes. Offscreen Metal tests establish pixel equality, not on-screen cadence.
- **Native UI-driver actions:** opened two TypeScript files named `index.ts`; screenshots showed the correct `one` / `two` code and distinguishing parent labels. A real missing-SDK error remained dismissible and navigation continued. Rapid file/shell switches settled on the requested file, without saving edits. Opened both long explorer source filenames, exercised small/large/reversed editor and explorer scroll commands, refresh and sidebar width changes. A twelve-tab overflow check retained an already-visible selected tab and revealed the first offscreen tab at the left edge. Temporary test terminals and fixture tabs were closed. Earlier UI checks exercised folder expansion/collapse. These are interaction-correctness checks, not measured physical input latency; the final manual trace could not be correlated to those actions and is excluded from timing evidence.

Natural physical trackpad motion, momentum interruption and human-perceived smoothness still need human verification. No parity with another editor, uninterrupted 120 FPS, authenticated SSH/SFTP performance or macOS 13 device performance is claimed. Existing accessibility, keyboard paths, context menus, drag/drop, file operations and remote views remain in place.

## Build 30 latency pass (procedural, release, native full screen)

Three alternating pairs, sequential, frontmost and unlocked, 1728 × 1084 pt, 2× scale, 120 Hz, M2 Max. Installed Build 29 (`a9ea61d2…fd6`) against the working-tree release (`78c919e5…393`), both running `render-motion,ui-tabs,ui-highlights,ui-resize`. Raw per-run reports were kept outside the repository; values below are run 1 / 2 / 3.

| Metric | Build 29 | Build 30 candidate |
| --- | --- | --- |
| Tab selection → correct buffer presented, p50 | 76.7 / 77.0 / 77.4 | 61.7 / 66.5 / 67.6 |
| Tab p95 / max (same value at 18 samples) | 87.4 / 89.0 / 98.1 | 85.5 / 85.1 / 87.0 |
| Selection → focus, p50 | 29.3 / 28.3 / 29.1 | 30.3 / 30.8 / 32.7 |
| Selection failures / presentation timeouts | 0 / 0 | 0 / 0 |
| Highlight → presentation, p50 | 44.0 / 43.9 / 43.4 | 43.9 / 43.6 / 43.6 |
| Resize changed-content interval p50 / p95 / p99 / max | 25 / 33.3 / 41.7 / 75 (all three) | 16.7 / 25 / 41.7 / 66.7; 16.7 / 25 / 33.3 / 66.7; 16.7 / 25 / 33.3 / 66.7 |
| Resize missed refreshes | 407 / 403 / 424 | 226 / 207 / 223 |
| Resize CPU % | 91.5 / 91.5 / 91.6 | 81.2 / 81.8 / 79.2 |
| Resize **maximum main-thread wait** | 109 / 120 / 180 ms | **335 / 204 / 249 ms (worse)** |
| Motion (scrolling) interval p95 / p99 / max | 8.3 / 16.7 / 16.7; 8.3 / 8.3 / 16.7; 8.3 / 8.3 / 16.7 | 8.3 / 8.3 / 8.3; 8.3 / 8.3 / 16.7; 8.3 / 8.3 / 16.7 |
| Motion explorer native fallbacks | 0 | 0 |

Measured causes, from a per-selection trace and a Time Profiler capture of the same workload:

- Editor→editor switch timeline (median, ms from selection): Neovim redraw complete 10; PTY bytes received by the background reader 10 (the marker flush made this immediate; it was about 18 before); main-thread delivery 17–21; frame encode about 10; presentation about 50. Shell→editor switches are the slow class: the marker is ready almost at once, but the main thread is busy for 25–35 ms in SwiftUI/AppKit layout before it can deliver the bytes, giving 60–72 ms.
- `TabPresentation.make`/`measure` ran inside the tab-strip SwiftUI body on every selection (about 5 ms of text measurement per switch). Measurement and the last presentation are now memoized (pure function of names/paths and the fixed 12 pt font). The parser now starts about 4 ms earlier.
- Terminal row preparation (profiled, per frame): about 6.3 ms of draw data, split into attributed strings 1.9, geometry 3.2, shaping 0.8, buffers 0.2 ms. About 5,300 blank-glyph lookups per frame hashed a string-keyed `GlyphKey` each; font ids are now interned and blank glyphs are skipped before placement math. Encode time moved from about 11.7 to 9.8 ms. Pixel-equality tests are unchanged.
- `preferredFrameLatency`: 1 versus 2 frames showed no reliable gain (p50 51.7/53.4/52.2 versus 69/52.5/52.7, where the single 69 is a first-run effect). The reported lead stayed about 24 ms in most runs and rose to 41 ms in another, so the system appears to adapt it. Default retained; `NEOLINK_FRAME_LATENCY=1|2` remains available for experiments and the effective value is written to the report setup.
- Resize: hidden editor panes and native resize callbacks without a supplied drawable no longer build rows. The largest remaining main-thread bursts (60–90 ms) are SwiftUI view-graph updates and flexible-frame layout of the root hosting view, not terminal rendering.

**Not improved:** resize worst-case main-thread wait is worse in this A/B (and varies 95–335 ms between runs of either binary), and its cause is SwiftUI/AppKit root layout that this pass did not restructure. Shell→editor switches remain 60–70 ms for the same reason. Tab p95/max are essentially unchanged. Highlight and scrolling results are unchanged within noise. Edit-to-photon latency, natural trackpad scrolling, momentum interruption and perceived smoothness were not measured and need hands-on verification.

### Root layout investigation and dropped drawables (Build 30)

A Time Profiler capture of the full workload shows the largest main-thread bursts (60–90 ms, during sidebar resize and shell→editor selection) are SwiftUI view-graph updates and flexible-frame layout of the root hosting view. Two cheap hypotheses were tested as same-binary A/B pairs (three alternating pairs each, full four-scenario workload) and **rejected, with the code removed**:

- `NSHostingController.sizingOptions = []` (stops min/ideal/max probing of the root): tab p50 52.0 vs 53.6 ms, resize wait 137–649 vs 120–187 ms — no reliable difference.
- Answering `sizeThatFits` directly in every native `NSViewRepresentable` (tab strip, terminal host, Neovim surface, explorer, background helpers) so SwiftUI does not ask AppKit for `fittingSize`: tab p50 52.4 vs 53.2 ms, resize wait 180–233 vs 86–315 ms — no reliable difference. Shell and editor grids were identical (155×59, 156×58).

Resize worst-case main-thread wait varies from about 90 to 650 ms between runs of the *same* binary, so it is not a usable regression gate at three runs. Reducing it needs the root layout restructured (for example a native split view with panes that do not share one SwiftUI layout pass), which is not done.

**Fixed: lost presentation acknowledgements.** The shared drawable can be dropped by the compositor (`presentedTime == 0`) — 27 to 51 times per full workload. The old handler returned early, discarding that frame's presentation callbacks. An editor selection whose only frame was dropped never reported "presented", producing an intermittent selection-presentation timeout (2 of 18 full-workload runs on the previous commit; 0 of 8 after the fix, 0 of 12 ui-tabs-only runs on either binary). Dropped frames' callbacks are now deferred (bounded to 64, cleared on overlay/fallback/generation change) and acknowledged, oldest first, by the next drawable that reaches the display, which shows the same or newer retained content. Dropped counts are written as `workspaceDroppedDrawables`. This restores a lost acknowledgement; it does not make a buffer visible earlier or expose a different one.

Verification limit: after moving the deferral into the `DeferredPresentations` type (covered by unit tests for ordering, no replay, bounding and discard), the release sanity runs were rejected because the Mac locked. The eight clean runs were taken on the same logic before that extraction.

### Selection published apart from the controller (responsiveness pass)

`TabsController` no longer publishes the selected tab. `TabSelection` (`controller.selection`) does, and only the views that show the selection observe it; the controller publishes `browserTabID` when the shown file browser changes. The motivation was the SwiftUI transaction and root layout measured above after every switch. `TabSelectionTests` verifies the split. The `ui-tabs` A/B in [RENDERING.md](RENDERING.md#responsiveness-pass-exact-editor-rows-steady-resampling-cheaper-switches) shows **no change in selection → buffer presented (p50 32.9 → 32.2 ms)**, a slightly higher p95 (45.2 → 49.8 ms), and **higher process CPU (22.6–23.8 % → 25.2–28.6 %) and more long main-thread stall samples (63–96 → 75–124)** in all five rounds of the *after* build. That build also contains three other changes, so the cause is not established. Treat this change as unproven for tab latency.
