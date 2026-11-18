# Contributing to NeoLink

Thanks for helping. Bug reports, measurements and pull requests are all welcome.

## Reporting problems

Use the [issue forms](https://github.com/abhayasho/NeoLink/issues/new/choose). For a crash, attach the
report from **Help → Show Crash Reports** (macOS: `~/Library/Logs/NeoLink`; Windows:
`%LOCALAPPDATA%\NeoLink\Logs`). Security problems go through [SECURITY.md](SECURITY.md) instead.

## Building

You need [Rust](https://rustup.rs) (stable). Neovim 0.11+ and ripgrep are optional but needed for the
editor and Find in Files, and for the editor tests.

```bash
cargo run --release -p neolink -- /path/to/project
cargo test --workspace --locked
python3 scripts/test-editor.py              # the editor's Lua runtime against a real Neovim
python3 scripts/test-editor-messages.py
```

`scripts/build-app.sh` builds `target/NeoLink.app` on macOS; `python scripts/package-windows.py`
packages a Windows build after `cargo build --release -p neolink`.

## Before a pull request

- **No warnings.** CI runs `cargo check --workspace --all-targets` with `-D warnings` on macOS and
  Windows. From a Mac, `cargo check -p neolink --target x86_64-pc-windows-msvc` catches Windows-only
  problems (`rustup target add x86_64-pc-windows-msvc` first).
- **Tests pass**, and a change in behavior comes with a test where one can be written.
- **UI changes:** include before and after captures. The app can drive itself and capture its window
  without a person:

  ```bash
  NEOLINK_BENCHMARK=controls NEOLINK_CONTROLS="git" NEOLINK_CAPTURE=after.png NEOLINK_CAPTURE_AFTER=7 \
      target/release/neolink /path/to/project
  ```

- **Rendering, scrolling or latency changes:** measure on a release build with the window in front and
  the screen unlocked; see [AGENTS.md](AGENTS.md) for the benchmarks and what to judge them by.
- Keep the conventions in [AGENTS.md](AGENTS.md): frames are demand-driven (anything that changes
  pixels must feed the frame signature), an idle window uses no CPU, macOS shortcuts use ⌘ and Windows
  ones Ctrl+Shift.

## Code layout

`crates/neolink` is the app, `crates/neolink-core` platform-independent logic, `crates/neolink-nvim`
the Neovim client and `crates/neolink-acp` the Agent Client Protocol client. The
[README](README.md#how-it-is-built) has an overview.

By contributing you agree that your contributions are licensed under the [MIT license](LICENSE).
