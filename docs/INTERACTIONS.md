# Explorer and editor interaction changes (1.11.2, build 26)

The explorer keeps its native table for input, accessibility, keyboard navigation, context menus and drag/drop. Cached text remains at native backing resolution. This change does not raise refresh targets or add presentations.

- Hover, selection and the active file update a small retained scene above the opaque text strip. Each changed row uses its original transparent artwork and replacement background, preserving the reference renderer's paint order and antialiasing. These updates allocate no strip texture. Row content, scale, width and range still invalidate the strip; its 16 MiB limit is unchanged.
- Revealing a visible file leaves the viewport stationary. Offscreen files move to the nearest edge. Row identity and fractional offset survive incremental membership and decoration updates; collapsing the anchored child uses its surviving parent. Reveal revisions are issued before directory loading, so a later scroll or navigation can cancel stale requests.
- A persistent private Unix socket replaces `nvim --remote-expr` subprocesses for app commands. Requests enter the FIFO before awaiting startup. Obsolete selection-only requests are skipped; initial opens, saves, closes and actions retain ordering. Generation checks reject old acknowledgements and snapshots. The editor is exposed after parsing a TUI marker emitted after redraw, rather than trusting control-response timing. Socket I/O, status reads, JSON decoding and path normalization run off-main, with bounded messages and coalesced status reads. Failed commands are not automatically replayed.
- Session mode changes stay inside the editor view. Unchanged terminal-host and explorer-cell updates do no configuration/layout work. Editor focus callbacks validate their selection before taking focus. Tab-strip scrolling no longer queues selection animations. During sidebar resizing, obsolete queued rasters are cancelled and outstanding row jobs are bounded to 16.

## Evidence and limits

[Reports, setup and hashes](interactions-build26.json). The baseline is Build 25 at `f2038f1`. The initial and corrected intermediate release runs used the same full-screen size, text size and refresh policy, stayed frontmost/unlocked and used the same scenario implementations for the common focus metric.

| Workload | Before | Corrected intermediate |
| --- | ---: | ---: |
| 24 tab switches, selection to focus, median / worst | 110.5 / 141.7 ms | 40.6 / 69.2 ms |
| Main-thread worst wait during tab switches | 36.4 ms | 33.9 ms |
| 60 offscreen hover changes, strip builds | 60 | 0 |
| Offscreen hover CPU encode, median / worst | 0.714 / 1.740 ms | 0.226 / 1.149 ms |
| Headless warm-buffer command completion, paired medians | 7.01 / 7.05 ms, subprocess | 0.744 / 0.750 ms, persistent |

The corrected intermediate run additionally timed 18 editor switches from selection to a drawable containing the acknowledged buffer: **77.9 ms median, 94.8 ms worst**, without timeouts. The baseline did not have this instrumentation, so it is not a before/after presentation comparison. Fixtures contain identical source text in different paths; the marker identifies the selected buffer, and the displayed status path changes. This is procedural selection, not a physical click-to-photon measurement.

Procedural scrolling still reached 8.3 ms p95 on both surfaces. Its maximum intervals and stalls varied; the first intermediate had a 25 ms content interval. These results do not establish a general smoothness speedup. Two early tab timeouts were fixed before the corrected run. An early highlight timing scenario could change offscreen rows and is excluded from visible-content claims; the final harness requires six fully visible rows.

**Sidebar resizing remains expensive.** The corrected intermediate's repeated full-screen divider sweep had a 33.3 ms p95 changed-terminal interval and a 197 ms maximum main-thread wait. Cancelling obsolete artwork does not establish a resize speedup; SwiftUI/AppKit layout, terminal reflow and GPU surface reallocation still contribute work. A later profiling attempt was rejected when the Mac locked. Native fallback during resize remains deliberate: an old-sized drawable is never stretched.

The final package additionally caches active-row lookup during hover, ignores stale redraw markers, and corrects the visible-row benchmark. It builds and passes automated checks, but its final live repeat and natural trackpad acceptance are pending after the screen lock. No parity with another editor, uninterrupted 120 FPS, macOS 13 device performance or authenticated SSH/SFTP performance is claimed.

## Reproduce

```sh
swift test
python3 scripts/test-editor.py
python3 scripts/test-benchmark.py
python3 scripts/benchmark-editor-control.py
./scripts/build-app.sh
python3 scripts/verify-app.py NeoLink.app

NEOLINK_INTERACTION_COSTS=1 swift test --filter ExplorerMetalTests
NEOLINK_WINDOW=fullscreen NEOLINK_BENCHMARK=render-motion,ui-tabs,ui-highlights,ui-resize \
NEOLINK_BENCHMARK_OUTPUT=/tmp/neolink-interactions.json \
NeoLink.app/Contents/MacOS/NeoLink
```

Keep the window frontmost and the screen unlocked. Reject reports with setup errors, `invalid`, focus failures or presentation timeouts. `ui-tabs` reports focus and first acknowledged-buffer presentation separately; `ui-highlights` reports visible highlight response and strip builds. Neither injects input. `render-motion` reports changed-content presentation; `ui-resize` procedurally moves the divider.

For external input, run `NEOLINK_BENCHMARK=manual-motion` with `NEOLINK_BENCHMARK_SECONDS=60`. The passive scenario records explorer geometry and opted-in editor selection-to-presentation samples while you move the pointer, scroll slowly, flick/reverse, refresh, expand/collapse, switch tabs and resize. Geometry alone does not verify pixels. Pixel equality, phase-correct text, stale-size rejection and native fallback are checked by automated Metal tests; perceptual trackpad smoothness requires a separate human check.
