# Horizontal editor continuation — 2026-11-17

Continues `e7df757` on `rust-rewrite`. The Swift source and released `main` are unchanged.

## Implementation

- `horizontal.rs` retains at most two previous immutable screens plus the current screen. Neovim
  supplies whole-column chunks ahead of movement; disjoint clipped bands fill the exposed edges.
  Movement is integral device pixels, with no scaled framebuffer or blurred glyph texture.
- Gutter and status line stay fixed. Input uses the existing dominant-axis lock and display-paced
  smoother. The nearest visible column is queued before typing/clicks/commands; selection and resize
  retire the composition. Wrapped and split Neovim windows retain stepped wheel input.
- The private input gate orders horizontal requests behind file selections. A token identifies each
  answer, and the reader captures its screen atomically. Old tokens cannot satisfy a later session.
- Testing exposed that `:redraw` followed by the original shared Lua notice could precede a later
  grid flush during reversal. The Rust wrapper now explicitly flushes before its own acknowledgement,
  using guarded `nvim__redraw({flush=true,valid=true})` and a `redraw!` fallback. The API is experimental;
  the fallback is exercised with it disabled. [Neovim API documentation](https://neovim.io/doc/user/api/#nvim__redraw()).
- A second defect was missing fractional horizontal position in the workspace's changed-content
  signature. Without it, valid translated scenes were built but only shown with subsequent redraws.
  That position and composition state now participate in the signature.
- Unrelated spontaneous text/style updates invalidate retained composition; stale dimensions are
  rejected. Request waits are bounded to 500 ms. There is no second presentation clock or GPU wait.

## Correctness checks

- Exhaustive strip coverage checks for forward/reverse movement and chunk replacement: every pixel
  has exactly one owner and maps to the same underlying buffer coordinate.
- Offscreen GPU comparisons of cached bands against direct text at six pixel offsets. Combining marks,
  CJK, emoji, gutter clipping and retained rows are included. Pixels match exactly on this Mac.
  GPU-less hosts explicitly skip this test; passing CI alone does not establish GPU coverage.
- Real-Neovim tests verify acknowledgement coordinates and content, scrolling immediately after a
  file switch, immutable saved screens, settling before typing, the older-redraw fallback, and
  wrapped/split eligibility. Existing buffer/save/conflict/order tests remain in the workspace suite.
- Explorer refresh tests cover inserted/deleted rows, parent collapse, and retained fractional offsets.
- Windows archive tests check runtime-resource layout, rejection of non-Windows binaries, and preservation
  of an existing archive when inputs are incomplete. They do not execute Windows software.

## Matched release comparison (2026-11-17, later the same day)

Same binary (`23deb88b…`), alternating `NEOLINK_HSCROLL=0` / `=1`, three rounds, full screen,
`NEOLINK_BENCHMARK_BUSY=1`, window frontmost and unoccluded: all 18 runs report
`visibleTimingValid: true`. Display path was direct except two `on` crawl runs (composited).

| Scenario | Column steps (off) | Pixel composition (on) |
|---|---|---|
| `editor-horizontal` (steady) | 225 frames, 137–141 uneven, jerk95 12–15 px | 301 frames, 1–4 uneven, jerk95 0.01–0.02 px |
| `editor-horizontal-crawl` | 27 frames, 7 jumps, first motion ~440 ms | 152–156 frames, 0 jumps, first motion ~90 ms |
| `editor-horizontal-flick` | 61 frames, 32–35 uneven, jerk95 17–26 px, largest 48 px | 119–124 frames, 40–51 uneven, jerk95 2.9–37 px, largest 148 px |

Crawl costs more CPU while moving (~26% → ~60% of one core). The flick's largest steps are all in its
first two or three frames: nothing can be drawn until Neovim answers the session's first geometry
request (one round trip), then the text catches up in one step. After that the flick is even. The
request lead now also covers the distance already received and the recent speed (`horizontal.rs`);
three further `on` runs were 42–65 uneven with the same start-up step, so that change did not remove it.

Still open: a physical-trackpad check (reversal, momentum interruption, slow creep, typing
mid-gesture, resize). Until then the column path stays the default; **View → Pixel-Smooth Sideways
Scrolling (Preview)** turns the new path on and is saved, so it can be tried in the packaged app
(`open` does not pass environment variables). `NEOLINK_HSCROLL=1`/`0` still overrides the setting.

## Earlier status (before the matched comparison)

The experiment is **off by default** (View menu or `NEOLINK_HSCROLL=1` opts in). Initial development runs showed
regressions, including sparse presentation and reversal jumps. Those drove the signature and flush
fixes above. Final live verification was blocked when the Mac locked; the last run had zero displayed
frames and failed foreground validity. No final speedup or smoothness claim is made.

Raw development reports, including failures/outliers, remain in [horizontal-review](horizontal-review/).
They are **not a matched baseline/final comparison**: implementation and fixture changed between runs.
Early fixtures used 5,400-character Rust lines; the repeatable horizontal fixture now uses 900-character
plain-text lines and a separate path per scenario, avoiding inherited views between scenarios. The
logged trace is instrumentation-assisted and must not be mixed with unprofiled timing comparisons.

The harness now reports `frontmostAndUnoccludedThroughout` and `visibleTimingValid`; a focus/occlusion
transition invalidates the interval. `visibleTimingValid` also requires presented frames. An idle test
may correctly present none. Screen-unlocked status still needs confirmation before running tests.

Run alternating off/on release comparisons with the window frontmost, the screen unlocked, no capture
or trace instrumentation, and the same binary/configuration:

```sh
cargo build --release --locked -p neolink
shasum -a 256 target/release/neolink
NEOLINK_HSCROLL=0 NEOLINK_WINDOW=fullscreen NEOLINK_BENCHMARK_BUSY=1 \
  NEOLINK_BENCHMARK=editor-horizontal,editor-horizontal-crawl,editor-horizontal-flick \
  NEOLINK_BENCHMARK_OUTPUT=/tmp/neolink-horizontal-off.json target/release/neolink
NEOLINK_HSCROLL=1 NEOLINK_WINDOW=fullscreen NEOLINK_BENCHMARK_BUSY=1 \
  NEOLINK_BENCHMARK=editor-horizontal,editor-horizontal-crawl,editor-horizontal-flick \
  NEOLINK_BENCHMARK_OUTPUT=/tmp/neolink-horizontal-on.json target/release/neolink
```

Repeat at least three paired rounds. Preserve display path (direct/composited), every invalid/outlier
run, binary hashes, first-motion delay, worst interval, jerk, uneven/held/burst frames, and CPU. Also run
the existing vertical, typing and tab-switch scenarios. Test a physical trackpad for reversal, momentum
interruption, slow creeping, long Unicode lines, typing mid-gesture and resize. Synthetic events bypass
OS input delivery; offscreen equality establishes pixel correctness, not perceived smoothness.

Windows has not been visually exercised here. The portable package and CI tests do not close that gap.
