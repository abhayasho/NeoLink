# NeoLink Rust preview

The cross-platform migration lives on `rust-rewrite`. The released Swift app remains separate.
The Rust app uses winit, wgpu, a retained GPU text renderer, an Alacritty terminal model, and one
headless Neovim editor shared by document tabs. macOS uses Metal; Windows uses wgpu's native backend.

## Current capabilities

- Local and SSH terminal tabs; selection, clipboard, search, working-directory reporting and scrollback.
- A resizable terminal dock **below or beside the editor**, with multiple shells (Control-backtick /
  Control-Shift-backtick). This is a code/terminal split, not two independently editable document panes.
- Neovim grid editing, guarded/cached file switching, unsaved-change prompts, syntax, diagnostics,
  installed language servers, code actions, formatting, Run and REPLs. A built-in plain-text editor
  is available without Neovim; it preserves UTF-8 line endings and checks for external changes.
- Project tree and Folder List; compact directories, filtering, icons, Git/diagnostic decoration,
  file operations, drag/drop, Follow Terminal, background file watching, and viewport-preserving refresh.
- Saved SSH profiles and OS credential storage; SFTP browsing, streamed transfers, file operations,
  and read-only remote previews. Windows remote browsing currently requires key/agent authentication.
- Quick Open, ripgrep content search, Git status/diffs/staging/commits/branches/read-only stash review.
- Terminal coding agents and native ACP conversations with streaming, tool previews, permissions,
  cancellation, modes and adapter-managed stdio MCP configuration.
- macOS PDF tabs with page/zoom/Fit controls; Windows currently opens PDFs in the system viewer.
- Remembered project, recent-project removal, panel sizes, text size and window geometry; dark neutral
  palette, custom icon, GPU rendering, idle suppression and a Performance Monitor.

These are implementation capabilities, not a claim that every workflow has been manually verified on
both platforms. Windows CI builds/tests the code and drives a real Neovim; it does not verify a window,
trackpad, credentials, IME, accessibility, or real SSH servers.

## Run and package

From this directory, with Rust installed:

```sh
cargo run --release --locked -p neolink -- /path/to/project
cargo test --workspace --locked
```

Neovim is optional for plain text, but required for Vim editing and language tools. Git, ripgrep,
language servers and coding-agent CLIs are installed separately.

**macOS application:** `./scripts/build-app.sh` creates `target/NeoLink.app`, named NeoLink Rust.
Copy that bundle to `/Applications/NeoLink Rust.app`. Its bundle identifier differs from the Swift app;
shared connection/credential compatibility remains intentional. Ad-hoc builds are not notarized.

**Windows portable application:** download the Windows artifact from a successful Rust CI run,
extract the contained `NeoLink-windows-x64.zip`, and open `NeoLink/NeoLink.exe`. Keep the complete
`Resources` directory beside the executable. This is a preview ZIP, not a signed installer.
To produce the archive on Windows:

```powershell
cargo build --release --locked -p neolink
python scripts/package-windows.py
```

The packaging job now includes `Resources/Editor/neolink.lua`; shipping only the executable caused
editor configuration lookup to fail outside a source checkout.

## Current horizontal-scrolling work

The default horizontal editor path still uses whole columns. The new retained-strip path is opt-in,
from **View → Pixel-Smooth Sideways Scrolling (Preview)** (saved) or the environment:

```sh
NEOLINK_HSCROLL=1 cargo run --release --locked -p neolink -- /path/to/project
```

PowerShell: `$env:NEOLINK_HSCROLL='1'` before launching the executable. Unset it to return to the default.
Wrapped text and Neovim split windows retain the existing wheel path. The experiment keeps the gutter
fixed, composes native-resolution text, and settles before editing, clicks, resizing or file changes.
Matched release runs show it much smoother for steady and slow sideways motion; a flick still has
one catch-up step at its start. It stays opt-in until checked with a physical trackpad. See
[horizontal-scrolling verification](docs/HORIZONTAL_SCROLL.md) for the numbers and tests.

## Accessibility

The window describes itself through AccessKit (NSAccessibility on macOS, UI Automation on Windows):
named toolbar buttons, the tab list with the selected tab, the file tree (level, expanded, selected),
the shown terminal's or editor's text, the editor's buttons, the docked terminal and notices (as
alerts). Pressing an element through VoiceOver runs the same code as a click. Nothing is built until a
screen reader (or another accessibility client) asks. Checked on macOS by reading the tree through the
AX API and pressing a tab with `AXPress`; not yet checked with VoiceOver speech or on Windows.

## Remaining migration work

Accessibility beyond the first tree (text ranges/caret for screen-reader reading by character, live
announcements of terminal output, Windows Narrator checks) and IME support; physical-input acceptance on both operating systems; Windows PDF tabs;
the remaining View rendering preferences; remote editing/save-back; complete encoding parity in the
fallback editor; full workspace/unsaved-session recovery; two-document split editing; bounded/cancellable
search process management; remote transfer progress/cancellation; packaging/signing/distribution polish.

The earlier Swift inventory remains the feature floor, not a statement that every item has already
been ported. [PLAN.md](PLAN.md) retains historical milestones and measurements; prefer this page for
current status. A high refresh target or passing pixel test alone does not establish smooth motion.
