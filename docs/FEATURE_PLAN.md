# Native editor feature plan

NeoLink continues incrementally on SwiftUI/AppKit, SwiftTerm, PDFKit and a shared Neovim engine. Version 1.5 adds native ACP conversations and source-control actions to the existing editor/agent layout. The following is a scope map, not a list of features already implemented.

| Capability | Current state |
| --- | --- |
| Scroll and text size | Wheel events reach the active mouse-aware TUI; trackpad fractions accumulate. Persisted 9–32 pt text sizing, View commands, keyboard shortcuts and editor menu. PDF shortcuts adjust document zoom. |
| Compact workspace | Explorer or Connections on the left, flat file tabs in the center, resizable agent sessions on the right. Panels can be hidden independently. |
| IDE explorer | Lazy expandable local tree, compact expanded chains, active-file reveal, Git/ignore decorations and deleted placeholders, semantic icons, open-buffer diagnostics, fuzzy Quick Open, path/terminal hooks, and folder-targeted copy/drop. Folder List and SSH/SFTP workflows remain available. [Details](EXPLORER.md). |
| Terminal threads / parallel agents | Installed CLI agents run in separate PTYs and project directories. The right panel switches among active sessions and preserves them when hidden. |
| LSP | Existing completion, definitions, references, diagnostics, rename, code actions and server-dependent formatting. New inlay-hint toggle; availability depends on the language server. |
| Parsing / folding | Neovim uses available Tree-sitter parsers, with syntax fallback. Tree-sitter folding where available, indentation folding otherwise. No parser auto-installation. |
| Vim / Helix | Neovim's Vim editing is available, with Insert mode at entry. Helix-style selection-first editing is not implemented. |
| Project search | Existing bounded, asynchronous ripgrep search. Results navigate to source; they are not editable multi-file excerpts. |
| Git | Native status/diff, stage/unstage, commits from staged files, local branch creation/switching, and read-only stash previews. No push/pull/merge UI, stash apply/create, automatic commits or generated commit messages. |
| REPL | Native terminal tabs launch installed Python, Node, Swift, Ruby or Lua interpreters. Notebook cells and rich inline outputs are not implemented. |
| Multi-buffers / diagnostics excerpts | Planned. Source-linked editable excerpts need shared-buffer mapping, coordinated undo, conflict handling and reliable multi-file saving. Existing diagnostics use Neovim's list. |
| ACP agent integration | ACP v1 stdio conversations: streamed text, tool input/diff previews, plans, advertised modes, explicit tool approval and cancellation, plus parallel sessions. Optional active-file path context and access to Git review. Terminal CLIs remain available. No persisted conversations or editor-managed agent filesystem/terminal RPC. |
| Models / MCP | Agents retain authentication and model/provider choices. ACP launch accepts explicit stdio MCP server configurations for the adapter to manage. No NeoLink API-key store, model router, direct Ollama connection or standalone native MCP client. |
| Edit predictions | Planned. No prediction model is bundled or downloaded, and no source is sent for background predictions. |
| DAP debugger | Planned. Requires adapter lifecycle, breakpoint state, stack/variable inspection, launch configuration and terminal routing. Running a file or opening a REPL is not debugging. |
| Extensions | Planned after an explicit permission/lifecycle model. There is no extension marketplace, plugin auto-installation or compatibility claim with another editor's extensions. |
| Rendering | SwiftTerm 1.20's native Metal glyph-atlas renderer powers shells, SSH, agent terminals and Neovim by default, with a saved View-menu switch and CoreGraphics fallback. AppKit/SwiftUI/PDFKit still draw the surrounding UI and PDFs. NeoGPU shares presentation across coding panes on macOS 14+. [Details and frame-rate limits](RENDERING.md). |

## Research notes

NeoGPU is a retained Swift/Metal compositor. CoreText rasterization, terminal parsing and language services still require CPU work. GPU rendering cannot guarantee zero input latency.

ACP conversations and terminal-based agent sessions have separate transports. NeoLink supports a bounded ACP v1 stdio client; optional MCP configuration is delegated to the adapter. See the [agent guide](AGENT_GUIDE.md).

Editable multi-file excerpts require shared source buffers, coordinated undo and conflict handling. Debugging requires a separate DAP client; edit prediction requires an explicitly configured provider. Each system needs its own integration and validation.
