# AGENTS.md

NeoLink is a GPU-rendered coding workspace for macOS and Windows, written in Rust: tabbed local/SSH
terminals, a shared Neovim editor (with a built-in fallback editor), explorer with Git, SFTP, Source
Control, ACP and terminal coding agents. Versions 1.x were a Swift app; that code lives only at tag
`swift-final` and is the reference for look and behavior where this app follows it.

## Build & run
- `cargo run --release -p neolink -- <folder> [files]` from the repository root; `cargo test --workspace --locked`.
- `scripts/build-app.sh` builds `target/NeoLink.app` (bundle id `com.neolink.app`, version from
  `Cargo.toml`, ad-hoc signed unless `NEOLINK_SIGNING_IDENTITY` is set). `scripts/package-release.sh`
  makes the release zip + `.sha256`; `python3 scripts/test-installer.py` checks `scripts/install.sh`
  against it. Windows: `cargo build --release -p neolink` then `python scripts/package-windows.py`;
  the archive must hold `Resources/Editor`, not just the `.exe`.
- `cargo check -p neolink --target x86_64-pc-windows-msvc` type-checks Windows code from a Mac.
- Releasing: `docs/RELEASING.md` (tag `v*` → draft release with both downloads; publishing is manual).

## Layout
- `crates/neolink` — the app. `main.rs` (winit event loop, menu bar, shortcuts, accessibility adapter),
  `workspace.rs` (layout, tabs, sheets, drawing, signature), `frame.rs` (render thread, demand-driven
  frames), `render.rs`/`text.rs` (instanced quads, glyph atlas, retained rows), `term.rs` (terminal),
  `editor.rs` + `horizontal.rs` (Neovim grid client), `native.rs` (fallback editor), `explorer.rs`,
  `gitview.rs`, `search.rs`, `agents.rs`, `connections.rs`, `remote.rs`, `dock.rs`, `pdf.rs`, `access.rs`.
- `crates/neolink-core` (pure logic: scrolling, pacing, tree, Git, search, SFTP), `crates/neolink-nvim`
  (RPC + grid model), `crates/neolink-acp` (ACP client; tests use `scripts/fixtures/acp-agent.py`).
- `Resources/Editor/neolink.lua` is the editor's runtime; `scripts/test-editor.py` and
  `scripts/test-editor-messages.py` test it against a real Neovim.

## Rules worth keeping
- Frames are demand-driven: a frame is presented only when the workspace signature changes. Anything
  that changes pixels (scroll positions, composition offsets, notices) must feed the signature, or it
  is drawn but never shown. An idle window must use no CPU (`scripts/compare-editors.py` measures it).
- Never return `Next::At(t)` for a time already past the display time (it busy-loops).
- Accessibility (`access.rs`) builds its tree only while a client listens and only after a frame was drawn.
- Scrolling: input goes through `ScrollSmoother` at display cadence; trackpad gestures lock to one axis
  (`AxisLock`) and never forward sideways drift of a vertical gesture to Neovim.
- Editor pixel scrolling: Neovim draws extra hidden rows; a view notice applies with the redraw it
  describes. Sideways composition (`horizontal.rs`, opt-in via View menu / `NEOLINK_HSCROLL=1`) pairs
  coordinates only with the screen captured at its acknowledgement, keeps the gutter fixed and settles
  before input; keep its GPU pixel test and real-Neovim ordering tests passing. It stays opt-in until a
  physical-trackpad check.
- Explorer row replacement preserves a path anchor plus fractional offset (`reanchored_scroll`).
- Full-screen program scrolling (`term.rs` ProgramScroll) measures movement against the last screen the
  program confirmed; `NEOLINK_PROGRAM_SMOOTH=0` turns it off.
- The fallback editor's saves keep line endings and refuse to overwrite files changed on disk.
- Platform conventions: macOS shortcuts use ⌘; on Windows app shortcuts use Ctrl+Shift (Ctrl belongs
  to the terminal), except in the built-in editor. Word movement is Option on macOS, Ctrl on Windows.
- Keep the bundle identifier `com.neolink.app` and the release asset names: `scripts/install.sh` and
  existing installs depend on them.

## Verifying UI and timing
- Drive the app without a person: `NEOLINK_BENCHMARK=controls NEOLINK_CONTROLS="tab:1,git,type:ls^,scroll:-200"
  NEOLINK_CAPTURE=out.png NEOLINK_CAPTURE_AFTER=<seconds>`; captures work with the screen locked.
- Timing: release build, `NEOLINK_WINDOW=fullscreen NEOLINK_BENCHMARK_BUSY=1 NEOLINK_BENCHMARK=<scenarios>`.
  Check `visibleTimingValid` and `displayPath` first: a locked screen or hidden window presents nothing,
  and macOS's composited state adds about two refreshes to every app. Judge smoothness by uneven frames
  and jerk, not by lag alone.
- The scroll benchmark reports where the app *meant* to draw, not the pixels. To see what reached the
  screen, record frames: `NEOLINK_RECORD=<folder> NEOLINK_RECORD_FAST=1` appends every changed frame
  (half width, gray) to `frames.raw` without slowing the frame loop much (`NEOLINK_RECORD_FROM`,
  `NEOLINK_RECORD_COUNT`); without `_FAST` it writes PNGs (slow: frames end up 100-300 ms apart).
  Measure the text's motion between frames from the pixels; a stall followed by a jump is what users call
  flicker. `NEOLINK_DEBUG_SCROLL_CHECK=1` logs editor frames whose rows do not match Neovim's top line and
  frames where the scroll offset ran past the hidden rows (Neovim answering too late).
- Scroll smoothing: a new event takes over the unreleased rest of the previous spread in the same
  direction (side-by-side spreads released two events in one frame and almost nothing in the next;
  queuing them instead added ~30 ms of lag to slow scrolling). The editor keeps Neovim's window
  ahead in the direction of travel (8 hidden rows) and re-centers it at rest.
- Settings and saved connections are not read or written during benchmarks/captures unless
  `NEOLINK_SETTINGS_FILE` / `NEOLINK_SESSIONS_FILE` name files.
