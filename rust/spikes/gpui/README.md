# GPUI stack spike

The losing candidate of the stack decision (see `../../PLAN.md`, section 2). Kept so the measurement can be repeated.

It draws a 160 x 50 text grid with `gpui-pre` 0.3.13 and changes it on a timer; a patched copy of
`gpui-pre-apple` logs when each frame was submitted and when it reached the display.

```sh
# vendor the renderer crate and apply the patch (the copy is not committed)
SRC=$(ls -d ~/.cargo/registry/src/*/gpui-pre-apple-0.3.13)   # after one `cargo fetch`
mkdir -p vendor && cp -R "$SRC" vendor/gpui-pre-apple && rm -f vendor/gpui-pre-apple/.cargo-ok
patch -d vendor/gpui-pre-apple -p1 < gpui-pre-apple.patch
cargo build --release
NEOLINK_WINDOW=fullscreen SPIKE_MODE=dense ./target/release/spike-gpui 2> out.log   # sparse | dense | motion
python3 ../../scripts/analyze-spike.py out.log
# SPIKE_NO_METAL_LINK=1 selects GPUI's CVDisplayLink + nextDrawable() path instead of CAMetalDisplayLink.
```

The same modes exist in the app itself: `SPIKE_MODE=dense ./target/release/neolink --spike`.
