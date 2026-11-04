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

- **Automated correctness:** 154 native tests pass, including glyph phases/reference pixels, highlight overlap, large viewport jumps/reversals, native fallback, fractional anchors, minimal reveal, stable tab geometry, duplicate labels, native horizontal reveal, hidden-editor grid stability, service-error dismissal and ordered rapid selection/save/close behavior. Actual Neovim runtime tests pass, including dirty buffers, saves/conflicts, UTF-16/CRLF, large-file mode and Python diagnostics/definition. A drained private-PTY check proves a multiline service error does not block subsequent duplicate-name switching. Eight offline benchmark checks and release resources/signature checks pass. [Clean macOS CI passed](https://github.com/abhayasho/NeoLink/actions/runs/41762482174).
- **Procedural animation:** final installed binary completed motion, tab, visible-highlight and resize scenarios frontmost and unlocked. Accepted repeats and exploratory candidates are kept separately with their hashes. Offscreen Metal tests establish pixel equality, not on-screen cadence.
- **Native UI-driver actions:** opened two TypeScript files named `index.ts`; screenshots showed the correct `one` / `two` code and distinguishing parent labels. A real missing-SDK error remained dismissible and navigation continued. Rapid file/shell switches settled on the requested file, without saving edits. Opened both long explorer source filenames, exercised small/large/reversed editor and explorer scroll commands, refresh and sidebar width changes. A twelve-tab overflow check retained an already-visible selected tab and revealed the first offscreen tab at the left edge. Temporary test terminals and fixture tabs were closed. Earlier UI checks exercised folder expansion/collapse. These are interaction-correctness checks, not measured physical input latency; the final manual trace could not be correlated to those actions and is excluded from timing evidence.

Natural physical trackpad motion, momentum interruption and human-perceived smoothness still need human verification. No parity with another editor, uninterrupted 120 FPS, authenticated SSH/SFTP performance or macOS 13 device performance is claimed. Existing accessibility, keyboard paths, context menus, drag/drop, file operations and remote views remain in place.
