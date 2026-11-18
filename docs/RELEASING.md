# Releasing

1. Set the version in `Cargo.toml` (`[workspace.package] version`). The macOS bundle takes it from
   there; its build number is the commit count, so it only grows.
2. Check: `cargo test --workspace --locked`, `python3 scripts/test-editor.py`,
   `python3 scripts/test-editor-messages.py`, then `scripts/build-app.sh`, `scripts/package-release.sh`
   and `python3 scripts/test-installer.py`. For rendering or input changes, also run the release
   benchmark (`NEOLINK_BENCHMARK=...`) with the window frontmost and the screen unlocked; a run whose
   report says `visibleTimingValid: false` (locked screen, hidden window) shows nothing about timing.
3. Write the notes in `docs/releases/v<version>.md` and commit.
4. Push to `main`, then push the tag: `git tag -a v<version> -m "NeoLink <version>" && git push origin v<version>`.
   The Release workflow tests and packages both systems and attaches `NeoLink-macos-arm64.zip`,
   `NeoLink-windows-x64.zip`, `NeoLink-Setup-x64.exe` (built with Inno Setup from
   `scripts/windows/NeoLink.iss`) and a `.sha256` for each to a **draft** release with those notes.
   The Windows job also runs `scripts/test-windows-installer.ps1` against the new downloads.
5. Check the draft's assets (download, verify the checksum, open the app), then publish it and mark it
   latest. `scripts/install.sh`, `scripts/install.ps1` and the README's links download from the latest
   release, so keep the asset names. Never change the AppId in `NeoLink.iss`: updates find an
   installation by it.

The bundle identifier stays `com.neolink.app`: the installer refuses to replace any other app, and
macOS ties folder permissions to it. Builds are ad-hoc signed unless `NEOLINK_SIGNING_IDENTITY` names a
certificate; with ad-hoc signing macOS may ask again for folder access after an update.
