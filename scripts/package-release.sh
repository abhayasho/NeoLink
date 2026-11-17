#!/usr/bin/env bash
# Archives an already built app for GitHub Releases: target/release-assets/NeoLink-macos-arm64.zip and
# its .sha256 (the names scripts/install.sh downloads). Run scripts/build-app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:-target/NeoLink.app}
OUTPUT=${2:-target/release-assets}
python3 scripts/verify-app.py "$APP"
[[ "$(lipo -archs "$APP/Contents/MacOS/NeoLink")" == arm64 ]] || {
  echo 'Expected an Apple silicon release app.' >&2; exit 1;
}
mkdir -p "$OUTPUT"
ASSET=NeoLink-macos-arm64.zip
rm -f "$OUTPUT/$ASSET" "$OUTPUT/$ASSET.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/$ASSET"
(cd "$OUTPUT" && shasum -a 256 "$ASSET" > "$ASSET.sha256")
# Extract once and check the actual download, not just the input bundle.
CHECK=$(mktemp -d "${TMPDIR:-/tmp}/neolink-package.XXXXXX")
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$OUTPUT/$ASSET" "$CHECK"
python3 scripts/verify-app.py "$CHECK/NeoLink.app"
printf 'Release assets: %s/%s (+ .sha256)\n' "$OUTPUT" "$ASSET"
