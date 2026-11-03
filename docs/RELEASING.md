# Release checks

1. Run `swift test`, `python3 scripts/test-editor.py` and `python3 scripts/test-benchmark.py`.
2. Run `./scripts/build-app.sh`, then `python3 scripts/verify-app.py NeoLink.app`. Packaging must include the editor Lua runtime, icon and SwiftTerm shader bundle. The verifier checks resources and the bundle signature; it does not launch the app or modify system trust.
3. On a supported Mac, run a frontmost, unlocked release `render-motion,idle` benchmark. Inspect actual drawable intervals separately from changed-content intervals. Compare full-screen and smaller windows, text clarity, trackpad reversals/stops, resizing, GPU/native switching and accessibility.
4. Check local code/PDF tabs, unsaved edits, project restoration, Git review, agent cancellation and authenticated SSH/SFTP transfer/reconnection. Offline tests do not replace authenticated remote validation.
5. Record version, binary hash, hardware, settings, all accepted runs and rejected-run reasons before publishing performance claims.

The macOS Actions workflow covers automated checks and packaging. It cannot certify human-perceived smoothness, physical 120 Hz presentation or authenticated SSH/SFTP behavior.

## Distribution limits

The default local build is ad-hoc signed. It is not Developer ID signed or notarized, so it is not yet a frictionless public macOS distribution. Keep the same bundle identifier and use an Apple-issued Developer ID identity when available; notarization is a separate release step. Signature verification alone does not grant Gatekeeper trust. OS permission grants may change with ad-hoc rebuilds. Do not disable security checks or promise permanent permission retention.

Continuous High Refresh requests up to 120 Hz for visible shared GPU coding panes on macOS 14+. It increases idle presentation work and pauses when hidden/minimized. Display refresh, thermal/power conditions, other processes and native panels remain outside the renderer's guarantees. Zero dropped frames and literal zero latency are not release claims.
