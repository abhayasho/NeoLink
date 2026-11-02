#!/usr/bin/env bash
# Set NEOLINK_SIGNING_IDENTITY to a valid code-signing certificate to keep
# the app's identity stable across updates. Never weaken its designated requirement.
set -euo pipefail
APP_PATH="${1:?Pass the app bundle path}"
if [[ -n "${NEOLINK_SIGNING_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --sign "$NEOLINK_SIGNING_IDENTITY" "$APP_PATH"
else
  /usr/bin/codesign --force --sign - "$APP_PATH"
  echo "Local ad-hoc build: macOS may ask for access again after updates. Set NEOLINK_SIGNING_IDENTITY for stable signing."
fi
/usr/bin/codesign --verify --strict "$APP_PATH"
