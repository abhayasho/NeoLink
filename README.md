<p align="center">
  <img src="Resources/AppIcon.png" alt="NeoLink axolotl logo" width="180">
</p>

<h1 align="center">NeoLink</h1>
<p align="center">A native macOS coding workspace, terminal, and agent companion.</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-6.0%2B-F05138?logo=swift&logoColor=white" alt="Swift 6.0+">
  <img src="https://img.shields.io/badge/UI-SwiftUI-0A84FF" alt="SwiftUI">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license">
  <img src="https://img.shields.io/badge/status-prototype-orange" alt="Prototype">
</p>

**NeoLink** is a native macOS coding workspace and terminal that puts tabbed local and SSH sessions next to a file browser, so you can work with local and remote files from one window. I wanted a terminal like this for macOS and couldn't find one I liked, so I started building it.

> [!NOTE]
> NeoLink is an early prototype. Expect rough edges.

## Features

- **Persistent terminal tabs.** Switch between local and SSH sessions without restarting shells or losing scrollback, powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
- **GPU text rendering at up to 120 Hz.** Shells, SSH sessions, agent terminals, and the Neovim editor draw with Metal: CoreText glyphs are cached in an atlas and drawn as GPU quads, and a row that only moved is translated instead of being shaped again. One display-link clock per window paces every surface and stops when nothing changes. Typed output is submitted promptly and every frame keeps VSync enabled. Shell scrollback follows trackpad displacement directly and keeps its fractional position when momentum stops. The explorer defers background row changes during scrolling to avoid interrupting motion. Earlier latency figures in the rendering documentation describe the previous presentation policy; the current build needs fresh measurements and visual comparison. **View → Performance Monitor…** shows the same latency and frame-interval numbers live; **View → Use GPU Text Rendering** switches renderers without restarting sessions, and failures fall back to CoreGraphics. GPUI is not embedded; this is a native Metal integration. [Rendering details and benchmarks](docs/RENDERING.md).
- **Code and PDFs in tabs.** One shared, on-demand Neovim engine provides a dark code editor inside NeoLink. PDFs use a native viewer. Reopening a file selects its existing tab and preserves editing state. A native text editor is available when Neovim is not installed.
- **Code intelligence.** Syntax highlighting, completion, diagnostics, definition, references, hover, rename and code actions use installed language servers. Run supported files in a terminal directly from the code toolbar.
- **Native agent conversations.** Connect an installed ACP adapter from **Agent → Native conversation (ACP)**. Stream replies, inspect tool input and file-change previews, approve or reject requested actions, change advertised modes, and stop a turn in the right panel. Multiple sessions can run alongside code; hiding the panel keeps them alive. Optional stdio MCP server configurations are passed to the adapter. [Setup and limits](docs/AGENT_GUIDE.md).
- **Agent terminals.** Run Claude Code, continue its last project conversation, or launch another installed CLI in a panel or workspace tab. Authentication and terminal-based approvals stay in that CLI. Clean code buffers refresh after agent turns or when editor focus returns; unsaved buffers remain protected.
- **Pixel-smooth scrolling and text zoom.** With a trackpad, the editor, other mouse-aware full-screen terminal programs, and shell scrollback follow your fingers pixel by pixel, drawing a new frame at or near every 120 Hz refresh instead of jumping a line at a time. When you let go, the remaining part of a line eases out. Classic mouse wheels, Neovim side-by-side splits, and the CoreGraphics renderer keep line steps. **⌘+**, **⌘−**, **⌘0**, the **View** menu, and the editor's text-size menu adjust code and terminal text. The chosen size is saved across launches; these shortcuts zoom the active PDF instead when it has focus.
- **Native source control.** **⇧⌘G** opens staged/unstaged diffs, file staging and unstaging, commits from the index, local branch creation/switching, and read-only stash previews. Commits use your configured Git identity and hooks. Save editor changes before Git operations; branch switching preserves Git’s normal conflict checks. Push, pull, merge, stash creation/apply, and generated commit messages remain terminal operations.
- **Folding and REPLs.** Use the **Code** menu to fold/unfold code, toggle server-provided inlay hints, or open an installed Python, JavaScript, Swift, Ruby or Lua REPL in the current project.
- **Project tools.** Open a project once and restore its saved folder access on launch. Use **⌘P** for ranked fuzzy filename/path search and **⇧⌘F** to search file contents. Searches skip dependency/build folders and run only on demand.
- **Safe editing.** Unsaved changes prompt before closing or quitting. Saves preserve encoding and check for external edits. Remote files remain read-only previews. See the [coding workspace guide](docs/CODING_WORKSPACE.md) for limits and recovery behavior.
- **Connection sidebar.** Search saved hosts, create a validated SSH connection, or open a local shell in one click.
- **Directory-aware.** Local zsh sessions report their working directory automatically without editing your shell configuration. Each tab keeps its own directory and file browser state.
- **Native IDE explorer.** A reusable-row AppKit table keeps hover local, updates decorations in place, and preserves your scroll position during background refreshes. Expand project folders in place, compact single-child folder chains, and automatically reveal the active file. Muted Git colors and letter badges distinguish added, untracked, modified, renamed, conflicted, and deleted paths; ignored items are dimmed or optionally hidden. Language/configuration icons and error/warning counts from open Neovim buffers help identify files. Use the explorer options for **Project Tree** or the existing **Folder List**, compact folders, hidden files, and auto-reveal. [Explorer behavior](docs/EXPLORER.md).
- **Local file and terminal actions.** Create files/folders, filter, rename, move to Trash, copy paths/relative paths, and open an integrated terminal in any folder. Drag files onto a folder or the explorer background to copy them; copies preserve existing files by choosing a unique name. Folder List retains all sorting choices. **Follow terminal** continues to track each local shell's directory, and SSH sessions retain the dedicated remote browser below.
- **Remote SFTP browser.** When you SSH into a host, NeoLink notices and switches the file pane to an SFTP view:
  - browse remote folders, and create, rename or delete entries;
  - upload by dragging files in from Finder;
  - download files and folders from the context menu;
  - reuse connections and stream large transfers without buffering whole files on the UI thread.
- **Keychain storage.** Enter your SFTP password once. NeoLink saves it in the macOS Keychain and reconnects without asking again.
- **Understated dark workspace.** A compact navigator, flat tabs, a `#141414` navigator, `#181818` editor and agent surfaces, muted blue/pink syntax, subtle gray borders, and a resizable agent panel keep attention on your code. Connections and Explorer share the left navigation area. The native editor fallback uses the same palette.
- **Collapsible panels.** Close Connections or Files/SFTP with **×** and reopen them from the header. Your panel visibility is remembered across launches, while open tabs and saved connections stay available.

## Requirements

- macOS 13 Ventura or later
- Xcode 16 or later, or a Swift 6.0+ toolchain with the macOS SDK

> The app uses Swift 5 language mode for compatibility with `swift-ssh-client`; the Metal-enabled SwiftTerm dependency requires a Swift 6.0+ toolchain.

## Build and run

**From the terminal:**

```bash
git clone https://github.com/abhayasho/NeoLink.git
cd NeoLink
swift build
swift run
```

**As a double-clickable app with an icon:**

```bash
./scripts/build-app.sh
```

This builds a release binary, wraps it in `NeoLink.app` in the project root and embeds the icon from `Resources/AppIcon.png`. Double-click it, or move it to `/Applications`.

## Coding tools

```bash
brew install neovim ripgrep
# Optional language servers for Python and JavaScript/TypeScript:
brew install pyright typescript-language-server
```

Neovim 0.11+ is required for the coding engine (tested with 0.12.6). Swift and C/C++ language services use `sourcekit-lsp` and `clangd` from the installed toolchain. Servers start only when needed. Without Neovim, text files still open in native tabs; without ripgrep, project search explains how to install it.

For remembered folder access, choose **File → Open Project** once. NeoLink restores the selected folder, retains bookmarks when a drive is temporarily unavailable, and activates other recent folders only when selected. Use the same installed copy in `/Applications` for everyday work.

macOS controls Documents/Desktop/Downloads and local-network permissions separately from NeoLink's project picker. It normally remembers your decision for the same app identity. **Local ad-hoc builds can prompt again after an update** because their signing identity changes; a saved folder bookmark cannot prevent this. For releases, set `NEOLINK_SIGNING_IDENTITY` to a valid Apple-issued signing certificate and keep using the same certificate type, developer team, and bundle identifier. New protected locations or revoked grants may still need approval. [Architecture, benchmarks, permissions and limits](docs/CODING_WORKSPACE.md).

## Coding agents

Open a project and click **Agent** (or **⌃⌘A**). Choose an interface:

- **Terminal** runs `claude`, `claude --continue`, or a custom CLI in a PTY. Sign in and answer its prompts there. Choose a panel or workspace tab.
- **Native conversation (ACP)** runs an ACP-compatible adapter in the right panel. For Claude, install [`claude-agent-acp`](https://github.com/agentclientprotocol/claude-agent-acp) separately, then select **Claude Code**. For another adapter, select **Custom CLI** and its executable. A regular `claude` binary is a terminal application, not an ACP adapter.

Custom arguments are passed literally, one per line. The custom name/executable are remembered; arguments and optional MCP configuration are not saved. NeoLink does not automatically install or start agents. Provider authentication and model configuration belong to the selected CLI/adapter; NeoLink has no API-key store or direct model client.

Agents operate on saved files. Save your editor changes first. Native conversations can explicitly include the active file's path; they do not automatically send editor selections or unsaved text. Tool permission requests require your choice. Closing a native session stops its adapter; hiding the panel keeps it running. Conversations currently last for the app session. See the [agent guide](docs/AGENT_GUIDE.md) for setup, MCP configuration, protocol support, and validation limits.

## Using NeoLink

| To… | Do this |
| --- | --- |
| Open a local shell | Pick **Local terminal**, click the tab-strip **+**, or press **⌘T** |
| Connect over SSH | Use **+** beside **Connections** or **⇧⌘N** to save a host, then click the connection. You can also run `ssh user@host` in a local tab |
| Browse remote files | Select an SSH tab, then **Connect to files**. Local shell title detection also recognizes remote hosts |
| Upload | Drag files from Finder into the SFTP pane |
| Download | Right-click a remote file and choose download |
| Open code or a PDF | Click it in the file browser, or use **⌘O** for a local file |
| Save local code/text edits | **⌘S** or **Save**; Neovim `:saveas filename` or native **Save Copy…** preserves a separate copy |
| Open / remember a project | **⇧⌘O** |
| Create a file or folder | **+** in the file pane, or right-click a local folder |
| Find a file / search project text | **⌘P** / **⇧⌘F** |
| Code completion | **Control-Space**, or server-provided automatic triggers |
| Launch a coding agent | **Agent** in the header or **⌃⌘A**; choose a project and interface |
| Hide / reopen agent panel | **⌃⌘B**, or the right-sidebar button; sessions keep running |
| Change text size | **⌘+** / **⌘−** / **⌘0**, **View**, or the editor's **pt** menu |
| Review / stage / commit Git changes | **⇧⌘G**, or the branch icon in the header |
| Fold code / toggle inlay hints | **Code** menu or editor toolbar's **Code** menu |
| Start an interactive interpreter | **Code → Open REPL** |
| Definition, rename, references | Use the **Code** menu or editor toolbar |
| Neovim editing modes | Starts in Insert; **Esc** for Normal; **i** to insert |
| Find text in the editor | **⌘F** |
| Use an external application | Right-click a local file and choose **Open in Default App** |
| Switch tabs | **⇧⌘]** / **⇧⌘[** |
| Close a tab | Click its **×**, or press **⌘W** |
| Close files / connections | Click the panel's **×**; reopen it with the **folder** / **sidebar** buttons in the workspace header, or **⇧⌘E** / **⌃⌘S**. Visibility is remembered across launches |
| Move the window | Drag an empty part of the **Workspace** header |
| Close / minimize / full screen | Use the standard red, yellow, and green window buttons, or **⇧⌘W** / **⌘M** / **⌃⌘F** |

## Verify changes

```bash
swift test
python3 scripts/test-editor.py
```

The regression suite (92 tests) covers Metal rendering of smooth-scrolled frames compared pixel by pixel, the scroll model, frame scheduling and input-latency attribution, wheel-delta accumulation, persisted text sizing, docked-agent lifecycle, Git staging/unstaging and commits (including an unborn repository), local branch conflicts, stash previews, literal filenames, ACP streaming/permissions/cancellation/timeouts and parallel session isolation, isolated tab state, native screen and scrollback retention, document deduplication, editor undo, PDF page retention, encoding-preserving saves and external-edit conflicts, shell startup and directory reporting, agent argument quoting and project selection, clean-buffer reloads, bookmark recovery after temporary failures, safe local copies and renames, asynchronous navigation, SSH input validation, and remote path parsing. Tests use temporary files and require no SSH server or credentials; the rendering tests skip without a Metal GPU. Authenticated SFTP transfers and remote previews still need an integration check against a server.

To measure scrolling smoothness and typing latency on your machine, run the interaction benchmark described in [docs/RENDERING.md](docs/RENDERING.md#benchmark) on a release build.

## Project layout

```
Sources/
├── Terminal/       SwiftTerm view wrapper, GPU renderer setup, smooth scrolling
├── Rendering/      per-window frame clock, Performance Monitor, interaction benchmark
├── Tabs/           tab controller and tabbed terminal view
├── Documents/      Neovim bridge, native text fallback, PDF viewer, file IO
├── Workspace/      remembered project access and bounded project search
├── Agents/         ACP transport/conversations and terminal agent launcher
├── Tools/          cancellable subprocess runner
├── Sessions/       saved sessions, sidebar, persistence
├── FileBrowser/    local file browser pane
├── SFTP/           SFTP manager, connection pool, browser view, Keychain passwords
├── Security/       credential store
└── NeoLinkTheme.swift
Vendor/SwiftTerm/   SwiftTerm 1.20.0 with NeoLink's rendering changes (see UPSTREAM.md)
```

## Roadmap

The [feature plan](docs/FEATURE_PLAN.md) distinguishes shipped native tools from larger planned features, including debugging, editable multi-file excerpts, edit prediction, and an extension system. NeoLink does not claim feature parity or a measured speed advantage over established IDEs.

- A two-pane layout showing local and remote files together
- Server-side copy and move for remote items
- Better SSH session management: tunnels, jump hosts and more
- Remote desktop sessions (there's a placeholder view for RDP/VNC)
- Eventually, a polished standalone app

## Built with

- [Neovim](https://neovim.io) for the embedded coding engine
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for terminal emulation and Metal rendering, vendored with NeoLink's changes listed in [`Vendor/SwiftTerm/UPSTREAM.md`](Vendor/SwiftTerm/UPSTREAM.md)
- [swift-ssh-client](https://github.com/gaetanzanella/swift-ssh-client) for SSH and SFTP

## License

[MIT](LICENSE) © 2026 Abhay Ashok
