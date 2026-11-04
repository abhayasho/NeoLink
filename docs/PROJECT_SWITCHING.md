# Project-switch crash fix (1.11.4, build 28)

Three Build 27 crash reports had the same main-thread stack: `ExplorerMetalView.displayScene`, called by the shared GPU workspace display deadline. The faulting instruction was an array-bounds trap. A regression that retains a populated strip and active-file index, then replaces its model with an empty tree, reproduced `Swift/ContiguousArrayBuffer.swift: Fatal error: Index out of range` before the fix.

Project changes can briefly produce an empty or shorter tree. Native visible-cell refresh returned early when there were no cells, leaving the previous GPU composition and highlight lookup alive. Table replacement could also expose new rows to a reentrant display callback before the previous cached indices were retired.

The coordinator now invalidates row-indexed GPU state before publishing replacement rows or mutating `NSTableView`. Refresh still wakes and invalidates the surface when the native viewport is empty or lies beyond the shortened document. Native cell loops check their upper bound. The GPU composition checks its retained range against the new model before indexing, validates highlighted artwork, and restores native fallback when it cannot safely compose.

Cached text artwork remains reusable by row identity. Hover/selection still preserve the text strip, and native-resolution glyphs, paint order, clipping, resource limits and the single VSync display owner are unchanged. The project picker, folder bookmarks and SSH/SFTP paths are not replaced.

## Verification

- 156 native regression tests pass. Coverage includes the formerly crashing populated-to-empty transition, recovery into a smaller/reordered project with reference pixel equality, invalidation before native table mutation, and native visible ranges beyond a shrinking document. Existing highlight, fractional-scroll, glyph-phase, fallback, reveal and tab-ordering regressions also pass.
- Real Neovim runtime checks pass, including buffers, dirty state, saves/external conflicts, encoding, large-file mode, scrolling, Python diagnostics/definition and nonblocking service errors.
- Eight offline benchmark checks pass.

- The release app's resources and strict ad-hoc signature pass verification before and after ZIP extraction. Installer checks cover fresh install, update/backup, checksum rejection, running-app protection, platform guards, rollback and symlink rejection.
- Ten project changes through the native picker (both menu and shortcut) completed in the same app process, with an existing code tab left open while switching between empty, three-file and 300-file fixtures. The empty folder rendered empty and populated folders restored their rows. The original project was restored and the unmodified fixture tab closed. No new app crash report appeared.
- A frontmost, unlocked full-screen release check completed motion, 60 highlights and 24 tab selections with no selection failures or presentation timeouts. Highlights rebuilt zero text strips. Motion's changed-content interval was 8.3 ms median, 16.7 ms p95 and 33.3 ms maximum, with no explorer native fallbacks. These are validation results, not evidence of uninterrupted 120 FPS or a speedup over the prior release: the run used 13-point text and the existing agent panel, unlike historical 12-point runs.

[Raw release report, setup and executable hash](project-switch-build28.json). Automated rendering tests establish correctness; they do not establish natural trackpad smoothness or uninterrupted 120 FPS.

[Clean macOS CI passed](https://github.com/abhayasho/NeoLink/actions/runs/41781483999), including packaging and installer checks. The public latest-release ZIP was downloaded, its checksum and signature verified, and its executable matched the installed/tested Build 28 binary.
