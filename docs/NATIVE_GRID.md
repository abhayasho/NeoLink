# Native Neovim grid client (opt-in, `NEOLINK_NATIVE_GRID=1`)

By default the shared editor is a Neovim TUI in a pseudo-terminal: Neovim renders its UI to escape sequences, the PTY carries them, SwiftTerm's VT parser rebuilds a cell grid on the main thread, and the Metal renderer draws that grid. The native client removes the TUI process, the PTY and the VT parser. NeoLink starts a **headless** Neovim server (same `--listen` socket, same `Resources/Editor/neolink.lua`) and attaches to it as an `ext_linegrid` UI over msgpack-RPC. The editor's cells then go straight into SwiftTerm's existing buffer, so the glyph atlas, 16 raster phases, integer-pixel quads, row cache, cursor drawing, IME/marked text, accessibility, NeoGPU hosting, VSync and the single NeoGPU display link are the terminal path's, unchanged.

The TUI path stays the default and the fallback. Set `NEOLINK_NATIVE_GRID=1` to select the native client. If `nvim` is missing, does not advertise `ext_linegrid`/`rgb` UI options, fails to attach, or the editor configuration lacks the native hooks, the session logs the reason (`NeovimSession.nativeFallbackReason`) and starts the TUI instead; queued commands wait for whichever engine becomes ready. A View-menu preference is deliberately not added yet (a change needs an editor restart; see the limits below).

## Pipeline

```
nvim --headless --listen editor.sock           control.sock (existing JSON channel: open/save/close/leave/action/status)
        │  msgpack-RPC redraw events                    ▲
        ▼                                               │
NeovimRPCConnection  (dispatch read source on its own serial queue; ordered write queue)
        ▼
NeovimGridClient ── NeovimGridModel (reader queue only): hl_attr_define, default_colors_set, grid_resize/clear/line/scroll,
        │            grid_cursor_goto, mode_info_set/mode_change, busy_*  →  immutable GridFrame at every `flush`
        ▼
GridMailbox (lock-protected; adjacent frames merge, so a hidden editor holds one pending frame)
        ▼  drained on the main actor: at the owning display deadline (`servicePendingOutput`) and by one coalesced main-queue wake
NativeGridPresenter ── mirror image, style table, snapshot cache, selection correlation, input
        ▼
SwiftTerm Terminal buffer rows (`externalGridSetRow`, `externalGridScroll`, `externalGridExchangeRows`) → existing Metal renderer
```

Nothing blocks on the main thread or Swift's cooperative pool. msgpack decoding, highlight/grid application and the per-flush diff against the previously emitted frame happen on the reader queue. Only rows whose content changed are published, and the presenter writes only rows that differ from what the terminal holds.

`grid_scroll` is replayed through the terminal's own region scroll (the same operation as CSI S/T) before changed rows are written, so scrolled rows keep their line identity, the renderer reuses and translates their cached geometry, and the existing smooth-scroll observers/retained lines work. The trackpad wheel path forwards line steps to `nvim_input_mouse`.

## Selection correctness (replaces the OSC title marker)

The TUI path gated visibility on a post-redraw `neolink-selection:<token>` title marker. The native path uses the same property on a different channel: after `nvim_set_current_buf` and `redraw` (which sends the buffer's redraw events and `flush`), `neolink.lua` does `rpcnotify(ui_channel, 'neolink_selection', token, path)`. Neovim writes redraw batches and notifications to the same RPC channel in order, so by the time the client reads the notification every frame it has applied belongs to that buffer. The reader publishes it as an ordered mailbox item; the presenter writes all rows to the terminal first and only then tells `NeovimSession`, which applies the existing per-selection generation check (`selectionParsed`) before the host shows and focuses the editor. Older tokens, tokens for superseded selections, and echoes arriving during a newer speculative display cannot expose or replace anything. `NativeGridEditorTests` alternates two buffers 40 times against real Neovim and requires the grid to hold exactly that buffer at every echo.

Commands keep their ordering through the unchanged control channel; saves/closes/initial opens still cannot be skipped. Unsaved buffers, the 128 MiB code-tab cap and the >2 MiB LSP/Tree-sitter limits live in Neovim and `neolink.lua` and are untouched. Asynchronous service errors still surface through `v:errmsg`/the banner. No byte is written to Neovim's stdout. The input path sends keys with `nvim_input` (`<` escaped as `<lt>`), pasted text with `nvim_paste`, mouse with `nvim_input_mouse`; input typed while a cached image is shown waits (bounded) for Neovim's confirmation so it can never reach a different buffer.

## Per-buffer snapshot cache

`neolink.lua` notifies the client when the displayed buffer is left (`neolink_leave`: path, mode, whether a popup menu is open), after redrawing, so the client's grid at that moment is exactly that buffer's screen. Images are kept for up to eight buffers. A cached image is shown immediately on return only if **all** of these hold, otherwise the editor waits for Neovim's flush:

- Neovim reported the buffer in insert mode with no popup menu (the state `open` always returns to), and restored its exact view (`winsaveview`/`winrestview` in `neolink.lua` when a native UI is attached);
- no change touched the buffer while it was hidden (`nvim_buf_attach` `on_lines`/`on_reload`, `BufWritePost`, `BufModifiedSet`, `DiagnosticChanged`, `LspAttach/Detach` send `neolink_touch`), and no layout/option/colour-scheme event happened (`WinNew`, `WinClosed`, `VimResized`, `ColorScheme`, display options send a global touch);
- the grid size, the highlight/default-colour epoch, and the diagnostics-enabled flag are unchanged;
- the file's size, mtime and inode are exactly what they were (an external or agent edit makes Neovim reload the buffer, so the image is refused).

A speculative image is a display optimisation, not a source of truth. Neovim's own confirmation then replaces it; rows that already match are not rewritten. Tests require zero corrected rows after round trips with cursor moves, page scrolling and `<C-End>`. The displayed rows of the buffer being left are detached (not overwritten) and retained with its image; re-installing them swaps `BufferLine` objects, so the renderer's row cache (keyed by line identity and generation) draws every row from retained geometry: a re-installed screen rebuilds 0 rows (`NativeGridRenderingTests`) instead of all of them.

## Vendor and shared-code changes

[Vendor/SwiftTerm/UPSTREAM.md](../Vendor/SwiftTerm/UPSTREAM.md) lists the SwiftTerm additions (`NeoLinkExternalGrid.swift`, `Mac/NeoLinkExternalGridView.swift`, three `public`→`open` changes and a renderer keep-set hook). In shared NeoGPU code, a drawable that reaches the display after the workspace's client set changed now still delivers each node's content acknowledgement (never ownership changes). Previously that acknowledgement was discarded, which could leave a selection's "presented" callback unanswered.

## Limits

- Opt-in only; no View-menu preference. Changing engines needs an editor restart.
- Native-path scrolling follows whole Neovim lines through `nvim_input_mouse` with the same trackpad accumulator and smooth-scroll driver; the interpolated sub-line region draws from lines retained by `grid_scroll`. Physical trackpad feel, momentum and keyboard-repeat feel are **not verified** (procedural events only).
- `ext_multigrid`, `ext_popupmenu`, `ext_cmdline`, `ext_messages`, `win_viewport` and `winblend` blending are not used; popup menus, floats and the command line are drawn by Neovim into the one grid. Cursor blink phase, `cell_percentage` and the cursor highlight attribute are approximated by the terminal's cursor styles.
- Option-as-Meta is not implemented; Option composes characters through the input system, Option plus Control/special keys sends `M-`.
- A cached image can precede Neovim's confirmation by one round trip. The window in which a change reaches Neovim but its `neolink_touch` has not yet reached the host is under a millisecond on the local socket, but it exists.
- The matched release evidence is procedural (see below). It does not establish click-to-photon latency and makes no claim of parity with another editor.
