# Status: what is verified where, and what is missing

## Verified

- **macOS (Apple silicon):** every feature in the README has been exercised in the app through its
  control harness (`NEOLINK_BENCHMARK=controls`, off-screen captures) and checked against files on
  disk, Git, a private SSH/SFTP server on 127.0.0.1 and a throwaway Keychain entry. Timing comes from
  the release benchmark with the window frontmost and the screen unlocked.
- **Windows (x64):** CI compiles and links with MSVC, runs every test (the editor client against a
  real Neovim) and packages the ZIP. No window has been opened on Windows by the maintainers' tools;
  rendering, input, credentials and accessibility there still need checking on a real machine.

## Opt-in

- **Pixel-smooth sideways scrolling** in the editor (View → Pixel-Smooth Sideways Scrolling, or
  `NEOLINK_HSCROLL=1`): matched release runs are much smoother for steady and slow motion; a flick keeps
  one catch-up step at its start. It becomes the default after a physical-trackpad check.
  [Measurements](HORIZONTAL_SCROLL.md).

## Accessibility

AccessKit exposes the toolbar and editor buttons (named as their help tags), the tabs, the file tree
(level, expanded, selected), the shown terminal's or editor's text, the docked terminal and notices
(as alerts); a press runs the same code as a click. Checked on macOS through the AX API. Not yet
checked with VoiceOver speech or Narrator; text ranges for character-by-character reading and live
announcements of terminal output are not implemented.

## Known gaps

IME (input methods for Chinese, Japanese, Korean and others); PDF tabs on Windows (they open in the
system viewer); editing remote files in place (remote previews are read-only); restoring unsaved work
after a crash; two documents side by side; progress and cancellation for remote transfers and project
search; Developer ID signing and notarization on macOS, code signing on Windows; Intel Macs (build from
source).
