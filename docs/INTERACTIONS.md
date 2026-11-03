# Explorer and editor interaction changes (1.11.2, build 26)

The explorer keeps its native table for input, accessibility, keyboard navigation, context menus and drag/drop. Cached text remains at native backing resolution. This change does not raise refresh targets or add presentations.

- Hover, selection and the active file update a small retained scene above the opaque text strip. Each changed row uses its original transparent artwork and replacement background, preserving the reference renderer's paint order and antialiasing. These updates allocate no strip texture. Row content, scale, width and range still invalidate the strip; its 16 MiB limit is unchanged.
- Revealing a visible file leaves the viewport stationary. Offscreen files move to the nearest edge. Row identity and fractional offset survive incremental membership and decoration updates; collapsing the anchored child uses its surviving parent. Reveal revisions are issued before directory loading, so a later scroll or navigation can cancel stale requests.
- A persistent private Unix socket replaces `nvim --remote-expr` subprocesses for app commands. Requests enter the FIFO before awaiting startup. Obsolete selection-only requests are skipped; initial opens, saves, closes and actions retain ordering. Generation checks reject old acknowledgements and snapshots. The editor is exposed after parsing a TUI marker emitted after redraw, rather than trusting control-response timing. Socket I/O, status reads, JSON decoding and path normalization run off-main, with bounded messages and coalesced status reads. Failed commands are not automatically replayed.
- Session mode changes stay inside the editor view. Unchanged terminal-host and explorer-cell updates do no configuration/layout work. Editor focus callbacks validate their selection before taking focus. Tab-strip scrolling no longer queues selection animations. During sidebar resizing, obsolete queued rasters are cancelled and outstanding row jobs are bounded to 16.

## Evidence and limits

[Reports, setup and hashes](interactions-build26.json). The baseline is Build 25 at `f2038f1`. The baseline and final release checks used the same full-screen size (1728 × 1084 points), 2× backing scale, 12-point text and refresh policy on this M2 Max, frontmost and unlocked. Common focus measurements use the same 24-switch procedural workload.

| Workload | Before | Final installed release |
| --- | ---: | ---: |
| 24 tab switches, selection to focus, median / worst | 110.5 / 141.7 ms | 45.2 / 64.1 ms |
| Main-thread worst wait during tab switches | 36.4 ms | 35.2 ms |
| 60 offscreen hover changes, strip builds | 60 | 0 |
| Offscreen hover CPU encode, median / worst | 0.714 / 1.740 ms | 0.226 / 1.149 ms |
| Headless warm-buffer command completion, paired medians | 7.01 / 7.05 ms, subprocess | 0.744 / 0.750 ms, persistent |

The offscreen hover comparison is a debug rendering-cost check, not an on-screen latency measurement. The command comparison measures warm Neovim command completion without a GUI, not file-opening or click-to-screen latency.

The final release additionally timed 18 editor switches from selection to a drawable containing the acknowledged buffer: **77.9 ms median, 98.3 ms worst**, without presentation timeouts or focus failures. The baseline did not have this instrumentation, so this is not a before/after presentation comparison. Fixtures contain identical source text in different paths; the post-redraw marker identifies the selected buffer, and the displayed status path changes. This is procedural selection, not a physical click-to-photon measurement.

For 60 procedural highlight updates across six fully visible rows, the final release built **zero strip textures**. Explorer CPU encoding was **0.4 ms p95, 0.6 ms worst**; highlight-to-presentation was **43.9 ms median, 45.4 ms worst**, with no timeouts and a 3.8 ms maximum main-thread wait. Cheap composition does not mean immediate presentation: that remaining response delay is recorded separately from frame cadence. Two intermediate highlight runs could change offscreen rows; their latency is excluded from visible-content claims.

During five seconds of procedural scrolling, both changed-content streams had **8.3 ms p95, 16.7 ms maximum** intervals. The maximum main-thread wait was 6.8 ms, versus 13.1 ms in the baseline. Final instrumented CPU was 36.9% of one core, versus 40.4% before. These single-run differences do not establish a general scrolling or CPU speedup: the baseline explorer's maximum interval was 8.3 ms, and occasional held frames remain. Refresh targets and the existing continuous-refresh preference were unchanged. Two early tab timeouts were fixed before the corrected intermediate and final runs; the rejected results remain in the raw report.

**Sidebar resizing remains expensive.** The final repeated full-screen divider sweep had a **33.3 ms p95, 75 ms maximum** changed-terminal interval and a **178.8 ms maximum main-thread wait**. Cancelling obsolete explorer artwork bounds queued work but does not establish a resize speedup. A separate sampled resize run points primarily to terminal row rebuilding/text work and native split-view constraint layout; explorer GPU preparation was a small part of that sample. That run started with different shell content and incurred profiler overhead, so its timings are diagnostic, not an equivalent-workload comparison. Native fallback during resize remains deliberate: an old-sized drawable is never stretched.

## Verification and remaining acceptance

- **Automated correctness:** 144 native tests pass, including highlight overlap/reference pixel equality, native fallback, glyph phases, minimal reveal, scroll cancellation, anchor preservation and rapid selection/save/close ordering. Actual Neovim runtime checks pass, including Python diagnostics/definition, dirty-buffer preservation, external conflicts, UTF-16/CRLF and large-file mode. Eight offline benchmark checks and packaged-resource/signature verification pass. [Clean macOS CI passed](https://github.com/abhayasho/NeoLink/actions/runs/41740089285). Pyright uses its push-diagnostic capability path to avoid unreliable dynamic pull registration during rapid startup; the runtime test still requires a real diagnostic and definition response.
- **Procedural on-screen checks:** the release binary completed scrolling, tab, visible-highlight and resize scenarios frontmost and unlocked. Its measured executable hash is recorded separately from the subsequently re-signed installed package. The later Python-diagnostic fix changed the Lua resource and the app signature; no Swift/Metal source changed.
- **Real UI actions:** expanded/collapsed directories, refreshed while scrolling, opened two code files, switched repeatedly between them and the shell, inspected developer context actions, and resized the sidebar through native controls. These establish interaction correctness, not physical trackpad latency. A passive full-screen run failed setup; a later maximized run lost foreground focus and had insufficient motion samples. Both are retained as rejected timing evidence.

Natural trackpad feel and sustained external-input timing remain unverified. No parity with another editor, uninterrupted 120 FPS, macOS 13 device performance or authenticated SSH/SFTP performance is claimed. The native table, keyboard/accessibility paths, context menus, drag/drop and remote views remain in place; no authenticated remote session was exercised in this change.

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
