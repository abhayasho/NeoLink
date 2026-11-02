# Native editor feature plan

NeoLink continues incrementally on SwiftUI/AppKit, SwiftTerm, PDFKit and a shared Neovim engine. Version 1.5 adds native ACP conversations and source-control actions to the existing editor/agent layout. The following is a scope map, not a list of features already implemented.

| Capability | Current state |
| --- | --- |
| Scroll and text size | Wheel events reach the active mouse-aware TUI; trackpad fractions accumulate. Persisted 9–32 pt text sizing, View commands, keyboard shortcuts and editor menu. PDF shortcuts adjust document zoom. |
| Compact workspace | Explorer or Connections on the left, flat file tabs in the center, resizable agent sessions on the right. Panels can be hidden independently. |
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
| Edit predictions | Planned. No model is downloaded and no source is sent for background predictions. Zeta is not bundled. |
| DAP debugger | Planned. Requires adapter lifecycle, breakpoint state, stack/variable inspection, launch configuration and terminal routing. Running a file or opening a REPL is not debugging. |
| Extensions | Planned after an explicit permission/lifecycle model. There is no extension marketplace, plugin auto-installation or compatibility claim with another editor's extensions. |
| Rendering | SwiftTerm 1.20's native Metal glyph-atlas renderer powers shells, SSH, agent terminals and Neovim by default, with a saved View-menu switch and CoreGraphics fallback. AppKit/SwiftUI/PDFKit still draw the surrounding UI and PDFs. GPUI/Alacritty are not embedded. [Details and frame-rate limits](RENDERING.md). |

## Research notes

[GPUI](https://gpui.rs/) is an open-source Rust UI framework, not a proprietary engine or a drop-in Swift renderer. Replacing the rendering layer would be a separate architecture migration. GPU rendering cannot guarantee zero input latency.

Zed distinguishes [ACP external agents](https://zed.dev/docs/ai/external-agents) from terminal-based sessions. Its [MCP documentation](https://zed.dev/docs/ai/mcp) likewise distinguishes editor-managed context servers from a CLI's native configuration. NeoLink supports both terminal sessions and a bounded ACP v1 stdio client; optional MCP configuration is delegated to the adapter. See the [agent guide](AGENT_GUIDE.md).

[Zed multi-buffers](https://zed.dev/docs/multibuffers) edit underlying files through shared excerpts; reproducing this needs more than a concatenated text preview. [DAP](https://zed.dev/docs/debugger) is a separate client/server protocol, and [edit prediction](https://zed.dev/docs/ai/edit-prediction) requires an explicitly configured provider. Those systems should be integrated and tested independently rather than represented by inactive controls.
