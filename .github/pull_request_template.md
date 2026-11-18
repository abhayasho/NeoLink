## What and why

<!-- What this changes, and the problem it solves. Link an issue if there is one. -->

## How it was checked

- [ ] `cargo test --workspace --locked`
- [ ] No warnings (`cargo check --workspace --all-targets` with `RUSTFLAGS=-D warnings`; Windows too if the change touches platform code)
- [ ] Editor runtime tests, if `Resources/Editor/neolink.lua` changed (`python3 scripts/test-editor.py`)
- [ ] Before/after captures for visible changes
- [ ] Measurements for rendering, scrolling or latency changes
