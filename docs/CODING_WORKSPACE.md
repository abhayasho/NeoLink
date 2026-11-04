# Coding workspace: design, measurements, and limits

Research and local validation: 2 November 2026.

## Architecture

NeoLink keeps its native SwiftUI/AppKit shell, SwiftTerm terminals, and PDFKit viewer. Swift already compiles through LLVM to machine code; rewriting the window system in Rust would not, by itself, make it faster. The expensive editor work now runs in one lazily started Neovim session shared by every local code tab. Keystrokes go directly through its PTY, without copying the whole document through SwiftUI on each edit. Native tabs receive small, debounced metadata snapshots when buffer state changes.

The app deliberately has no Electron runtime, extension marketplace, plugin manager, always-running project indexer, or recursive workspace watcher. Neovim 0.12 splits that session into TUI and editor processes; tabs do not spawn separate editors. A private local socket carries user actions; a single directory event source observes the editor's metadata file. Closing the last buffer attached to a language server stops that server. Terminal and editor views survive tab changes.

Version 1.6 enables SwiftTerm's Metal text renderer for terminals and Neovim, retaining CoreGraphics as a selectable fallback. GPU glyph-atlas rendering and cached row geometry replace CPU text drawing on those surfaces; the surrounding interface and PDF/text fallbacks retain their native rendering paths. See [rendering behavior and performance limits](RENDERING.md). The earlier memory snapshots below predate Metal integration and are not measurements of 1.6.

Sources: [Swift compiler architecture](https://www.swift.org/documentation/swift-compiler/), [Neovim remote control](https://neovim.io/doc/user/remote/).

## Neovim versus Emacs

The local comparison used seven sequential, clean headless launches of each installed editor, timed with a monotonic clock and `/usr/bin/time -l` for peak resident memory:

| Command | Median elapsed | Median peak resident memory |
| --- | ---: | ---: |
| `nvim --clean --headless +qa` (0.12.6) | 16.73 ms | 11.31 MiB |
| `emacs -Q --batch --eval '(kill-emacs 0)'` (30.2) | 68.23 ms | 34.56 MiB |

[Raw runs](editor-startup-benchmark.json) include slower first launches: 1,146 ms for newly installed Neovim and 265 ms for Emacs. These are predominantly warm, empty-editor results, not GUI startup, typing latency, or a VS Code comparison. Neovim fits this app because it has a terminal UI, buffers, RPC, and built-in language-server support. Emacs can also avoid repeated startup using a daemon; neither editor is universally faster under every configuration. LSP servers can cost much more memory than either editor core.


A release preview with one local shell used about **104 MiB RSS** before starting the editor. With Python and text tabs open, a later snapshot measured **138 MiB for the app**, **28 MiB for the two Neovim processes**, **101 MiB for Pyright/Node**, and **2.5 MiB for the shell** (about 270 MiB summed RSS). RSS includes shared pages and is not the same as physical footprint. A three-second macOS sample reported **89.4 MB physical footprint for the app alone** and found its main thread predominantly waiting for events. These are one-machine observations with UI inspection active, not a controlled comparison with VS Code.

Sources: [Neovim startup and profiling](https://neovim.io/doc/user/starting.html), [Emacs server](https://www.gnu.org/software/emacs/manual/html_node/emacs/Emacs-Server.html).

## Coding features and resource bounds

- The workspace uses neutral charcoal surfaces, flat tabs, compact navigation and grayscale controls. Neovim, the native text fallback, terminal selection and ANSI colors share a restrained palette; syntax categories and diagnostics retain muted semantic colors. Explorer and Connections occupy the same left area, with an optional agent dock on the right. Panel visibility is remembered.
- Wheel input over a mouse-aware terminal is routed through SwiftTerm's mouse-report encoder to the application instead of scrolling terminal history. Trackpad pixel deltas accumulate by cell size; ordinary shells retain scrollback. Neovim scrolls one line per report. Terminal rendering still uses character rows rather than arbitrary subpixel document scrolling. Text size changes update existing terminal grids and native text views without relaunching processes; the 9–32 pt preference is shared and persisted.
- Local code opens in Neovim inside NeoLink tabs. PDFs use native PDFKit tabs. Remote files remain read-only previews; this release does not implement remote language servers or remote save-back.
- Neovim starts in Insert mode. Escape enters Normal mode; `i` resumes inserting. Standard app save/undo/redo/select-all/copy/cut/paste commands are routed to the editor. `Cmd-F` starts Neovim search; Enter accepts and `n` finds the next match.
- Syntax highlighting, line numbers, indentation, undo/redo, completion, diagnostics, hover documentation, definition, references, rename and code actions are available. Language-specific features depend on the selected server's capabilities. Formatting is available only where the server implements it; Pyright, for example, is not a formatter.
- Swift uses `sourcekit-lsp`; C/C++ uses `clangd`; Python uses `pyright-langserver`; JavaScript/TypeScript uses `typescript-language-server`. Installed `rust-analyzer` and `gopls` are detected too. No server is downloaded or started just because the app launches. Servers start on a matching file and are shared within a project.
- Completion triggers are provided by the server; Control-Space requests completion explicitly. Without a server, Control-Space completes words from the buffer.
- Bundled Tree-sitter parsers are used where available. Other languages retain syntax highlighting; NeoLink does not silently download parsers. Built-in Neovim runtime files are used, with personal plugins, modelines and project-local startup files disabled.
- Files over 2 MiB skip LSP/Tree-sitter and expensive syntax highlighting. Code tabs have a 128 MiB open limit. Native fallback/remote text previews are limited to 8 MiB and PDFs to 50 MiB. Large lines or language servers can still affect responsiveness.
- Quick Open (`Cmd-P`) reads a file list once per palette opening, capped at 50,000 paths, and filters it locally. Find in Files (`Shift-Cmd-F`) uses literal ripgrep search with smart case, a 180 ms debounce, cancellation, a 10-second timeout, two search workers, and bounded output. It shows at most 200 matching lines, at most 20 per file, in files under 2 MiB. Searches honor `.gitignore` and exclude `.git`, `node_modules`, `.build`, `build`, `dist`, `.venv`, `venv`, `__pycache__`, `DerivedData`, `.next`, `vendor`, `Pods`, and `target`. There is no continuous index.
- Clangd background indexing and clang-tidy are off, with two worker threads. Pyright diagnoses open files. LSP dynamic recursive file watching is disabled. Cross-project navigation may be less complete than with full background indexing.
- Run saves the active file and opens a terminal for supported installed interpreters. Paths are shell-quoted. It runs only after an explicit click.
- In Terminal mode, the Agent launcher starts Claude Code (`claude` or `claude --continue`) or a custom executable in a dedicated local PTY tab, rooted in an explicitly chosen project. Arguments and paths are quoted individually. No agent, login, model request or installation starts with NeoLink itself. CLI authentication and approval prompts remain in that terminal. Local file listings refresh on leaving an agent tab; clean text buffers refresh when reselected, while dirty buffers retain their external-change conflict checks. No extra recursive watcher is involved. See [Claude Code's CLI reference](https://code.claude.com/docs/en/cli-reference).

- Native ACP mode starts one adapter process per conversation only when requested. NDJSON pipe reads and writes run off the UI thread. Messages are bounded to 8 MiB, streamed replies to 512 KiB per turn, retained conversation history to about 2 MiB, and individual tool previews to 16 KiB. Pending requests have deadlines; cancellation resolves outstanding permission requests before notifying the adapter, with process termination if it fails to stop within ten seconds. Session close/app quit terminates adapters. MCP configurations are validated and passed to the agent, not started by a second client. [Agent setup and limits](AGENT_GUIDE.md).

Sources: [Neovim LSP](https://neovim.io/doc/user/lsp), [Tree-sitter](https://neovim.io/doc/user/treesitter/), [ripgrep guide](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md). VS Code also isolates language servers in processes; its architecture should not be described as doing all work on one JavaScript thread: [VS Code LSP guide](https://code.visualstudio.com/api/language-extensions/language-server-extension-guide).

## Files and permissions

Choose a folder using **File → Open Project** (`Shift-Cmd-O`). NeoLink stores a security-scoped bookmark and the selected project in user preferences. It resolves saved bookmarks without UI or mounting unavailable drives, activates access for the selected project, and activates other recent folders when selected. A temporary resolution or renewal failure preserves the original bookmark for the next launch, rather than deleting the saved grant. An unavailable recent folder does not raise a launch alert. This avoids repeatedly displaying an app-level folder picker. Local and SFTP browsers offer New File and New Folder; exclusive creation protects existing files.

Use the folder menu → **Manage Recent Projects…** to see full paths and remove individual entries, or **Clear Recent Projects** to clear the list, including unavailable folders. These actions forget persisted shortcuts/bookmarks and future automatic project restoration. They do not delete folders, close tabs or revoke access used by the current workspace; active scopes remain balanced at app shutdown. Removed entries stay removed after restarting.

macOS remains responsible for protected-folder and local-network permissions. It normally remembers approval across launches of the same installed app. Newly protected locations, revoked permissions, or a changed app signing identity can require another prompt. An ad-hoc build has a designated requirement tied to that version's code hash, so rebuilding can invalidate its previous grants. Folder bookmarks do not replace OS permission decisions. The build script supports `NEOLINK_SIGNING_IDENTITY`; use a valid Apple-issued code-signing certificate and consistent certificate type, developer team, and bundle identifier for releases. Without a certificate, local builds remain ad-hoc and cannot guarantee remembered permissions across updates. Run the installed `/Applications/NeoLink.app` instead of switching between development copies. NeoLink does not reset privacy settings or automatically grant itself broader access.

Sources: [Apple security-scoped access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox), [Apple code identity and permission persistence](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), [Apple local-network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

## Save safety and validation

Closing tabs, windows or the app checks the editor's current dirty state, then offers Save, Cancel, or Don't Save. Neovim saves preserve its detected encoding and line endings. The app Save action checks file identity, size and modification time against the loaded version to refuse ordinary external-edit conflicts. This is a metadata check, not a transactional filesystem compare-and-swap; an external write racing after that check remains possible. Use Neovim `:saveas another-name` to preserve conflicted edits. Native text tabs also offer Save Copy.

Undo is held in memory. Crash recovery and persistent undo/session restoration are not implemented. A killed editor cannot recover unsaved buffers. Git status/diff review runs on demand with bounded subprocess output; external diff drivers and textconv are disabled and file paths are literal. Native Git actions stage/unstage selected files, commit the index using the configured identity/hooks, and create/switch local branches without forcing or auto-stashing changes. Unsaved editor buffers block these actions. Stash previews use immutable object IDs and are read-only. Debug adapters and an extension ecosystem remain future work; see the [feature plan](FEATURE_PLAN.md).

Run `swift test` for native regression tests and `python3 scripts/test-editor.py` for the real Neovim runtime. The latter uses temporary files and checks quoted paths, shared buffers, dirty state, save conflicts, UTF-16/CRLF preservation, large-file mode, and installed Pyright diagnostics/definition. No SSH server is needed. Authenticated SFTP creation/preview still requires testing against a reachable server.
