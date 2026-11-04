# Project-switch crash fix (1.11.4, build 28)

Three Build 27 crash reports had the same main-thread stack: `ExplorerMetalView.displayScene`, called by the shared GPU workspace display deadline. The faulting instruction was an array-bounds trap. A regression that retains a populated strip and active-file index, then replaces its model with an empty tree, reproduced `Swift/ContiguousArrayBuffer.swift: Fatal error: Index out of range` before the fix.

Project changes can briefly produce an empty or shorter tree. Native visible-cell refresh returned early when there were no cells, leaving the previous GPU composition and highlight lookup alive. Table replacement could also expose new rows to a reentrant display callback before the previous cached indices were retired.

The coordinator now invalidates row-indexed GPU state before publishing replacement rows or mutating `NSTableView`. Refresh still wakes/invalidate the surface when the native viewport is empty or lies beyond the shortened document. Native cell loops check their upper bound. The GPU composition checks its retained range against the new model before indexing, validates highlighted artwork, and restores native fallback when it cannot safely compose.

Cached text artwork remains reusable by row identity. Hover/selection still preserve the text strip, and native-resolution glyphs, paint order, clipping, resource limits and the single VSync display owner are unchanged. The project picker, folder bookmarks and SSH/SFTP paths are not replaced.

## Verification

- 156 native regression tests pass. Coverage includes the formerly crashing populated-to-empty transition, recovery into a smaller/reordered project with reference pixel equality, invalidation before native table mutation, and native visible ranges beyond a shrinking document. Existing highlight, fractional-scroll, glyph-phase, fallback, reveal and tab-ordering regressions also pass.
- Real Neovim runtime checks pass, including buffers, dirty state, saves/external conflicts, encoding, large-file mode, scrolling, Python diagnostics/definition and nonblocking service errors.
- Eight offline benchmark checks pass.

Release packaging, foreground interaction results and native project-picker verification are recorded after the final app check. Automated rendering tests establish correctness; they do not establish natural trackpad smoothness or uninterrupted 120 FPS.
