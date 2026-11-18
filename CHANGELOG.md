# Changelog

What changed in each NeoLink release. Downloads and full notes are on the
[releases page](https://github.com/abhayasho/NeoLink/releases); each version's notes are also in
[`docs/releases`](docs/releases).

## Unreleased

- **Smooth on Windows.** Frames were timed against a clock of their own that slowly slid across the
  display's real refreshes, so at regular intervals one refresh got two frames and the next none (and
  on a 280 Hz display about half the refreshes got none). NeoLink now measures the vertical blank of
  the display the window is on and draws exactly one frame per refresh: on a 280 Hz monitor the median
  time between frames went from 7.4 ms to 3.6 ms and the scroll's typical jerk halved. Short waits use
  a high-resolution timer instead of Windows' 15.6 ms tick, and the drawing thread runs at high priority.
- **The right GPU, through Direct3D 12.** On a PC with both integrated and dedicated graphics, NeoLink
  draws on the one that drives the window's monitor instead of always the integrated one (which copied
  every frame across), and uses Direct3D 12 rather than Vulkan, whose windows are often presented
  through an extra copy.
- **Mouse wheels glide.** Each notch scrolls over about a tenth of a second instead of jumping three
  lines in one frame; a spinning wheel scrolls continuously; the distance follows Windows' "lines to
  scroll" setting. Precision touchpads are drawn as they move, as before.
- **Windows installers.** `NeoLink-Setup-x64.exe` and a PowerShell one-liner
  (`irm https://raw.githubusercontent.com/abhayasho/NeoLink/main/scripts/install.ps1 | iex`) install
  for the current user without administrator rights: Start menu and desktop icons, "Open in NeoLink" on
  folders, a `neolink` command, an uninstall entry in Settings → Apps, and Neovim, Git and ripgrep via
  winget if missing. The Windows downloads now come with `.sha256` files.
- Tools installed after Windows signed in (Neovim, Git, ripgrep) are found without signing out.

## 2.1.0 (2026-11-18)

- **Welcome screen.** A window with no tabs shows the logo and version, the main ways to start (new
  terminal, open project, Quick Open, Find in Files, coding agent) with their shortcuts, and recent
  projects. Closing the last tab, or its shell exiting, now leaves the window open there instead of
  quitting; ⌘W on the welcome screen closes the window.
- **Code colors.** A new palette where each kind of token has its own color: keywords, types,
  functions, strings, numbers, attributes and macros, properties, parameters and operators, with
  italic comments.
- **Source Control** shows centered placeholders when the tree is clean or no file is selected, and
  its button reads *Commit* until files are staged.
- **Quick Open's** notes share one line under a hairline; the agent launcher shows the project folder
  as `~/…`.
- **Crash reports.** If NeoLink crashes, it writes a report (version, system, message and backtrace)
  to `~/Library/Logs/NeoLink` (macOS) or `%LOCALAPPDATA%\NeoLink\Logs` (Windows), keeps the newest
  20, and says so on the next launch. Nothing is sent anywhere.
- **Startup problems** such as a missing GPU now show a dialog that explains them instead of exiting
  silently.
- **Help menu** (macOS): Report an Issue, Release Notes and Show Crash Reports.
- The code builds without warnings on macOS and Windows, and CI keeps it that way.
- `scripts/compare-terminal-throughput.sh` measures terminal output throughput against VS Code.

## 2.0.4 (2026-11-17)

A visual polish release.

- Tabs take the editor's color and flow into it, on a darker strip.
- The editor toolbar shows where the file is in the project (`crates › neolink-core › src › scroll.rs · Rust`).
- Neovim's mode is a small colored pill in the editor footer.
- A slim scroll indicator appears at the right of the editor and terminal while scrolling.
- The explorer has faint indent guides; Quick Open highlights the letters you typed.
- Quieter details: Neovim's status line under a hairline, one blue for every dialog's main button,
  a round green light for a running shell.

## 2.0.3 (2026-11-17)

- Agent conversations show tool calls where they happened in a reply, with the agent's name once per
  reply.
- Choosing Custom CLI in the agent launcher selects the prefilled name.
- Dialogs dim the window evenly again; the tab strip fades at an edge with hidden tabs; new files
  and folders show their destination as `~/…`.

## 2.0.2 (2026-11-17)

- No more flicker while scrolling code: Neovim keeps more lines ready ahead of the scroll direction
  and re-centers them at rest.
- Even motion in the terminal and editor when trackpad reports arrive early. Measured from recorded
  frames (uneven steps per refresh): terminal 17 of 69 → 2 of 80, editor 39 of 132 → 8 of 140.

## 2.0.1 (2026-11-17)

- Source Control diffs start at the first change, with added and removed lines tinted; changed files
  show their icon, name, folder and a colored status letter.
- Quick Open and Find in Files show file icons, names first and folders dimmed; Find in Files
  highlights each match.
- The editor's fold column marks only closed folds (Neovim 0.12).
- Notices: information in gray, problems in red with a close button.

## 2.0.0 (2026-11-17)

A ground-up rewrite in Rust, for **macOS and Windows**, drawn on the GPU and presenting a frame only
when something changed.

- Windows x64 build.
- A terminal panel under (⌃`) or beside (⌃⇧`) the code.
- Smooth scrolling inside full-screen programs such as `less` and `vim`.
- About 115 MiB of memory with Neovim and a shell running, and no CPU while idle.
- A built-in text editor when Neovim is not installed.
- Screen-reader support through AccessKit (VoiceOver, Narrator).
- Everything from 1.x: tabbed local and SSH terminals, the Neovim editor with language servers,
  explorer with Git, Quick Open, Find in Files, Source Control, SFTP, saved SSH passwords, coding
  agents (terminal and ACP), and PDF tabs on macOS.

Versions 1.x were a Swift app for macOS; that code is kept at the
[`swift-final`](https://github.com/abhayasho/NeoLink/tree/swift-final) tag.
