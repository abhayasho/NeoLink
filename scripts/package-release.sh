#!/bin/bash
# Archive an already built/verified app for GitHub Releases.
set -euo pipefail
cd "$(dirname "$0")/.."
neolink_app=${1:-NeoLink.app}
neolink_output=${2:-.build/release-assets}
python3 scripts/verify-app.py "$neolink_app"
[[ "$(lipo -archs "$neolink_app/Contents/MacOS/NeoLink")" == arm64 ]] || {
  echo 'Expected an Apple silicon release app.' >&2; exit 1;
}
mkdir -p "$neolink_output"
neolink_asset=NeoLink-macos-arm64.zip
ditto -c -k --sequesterRsrc --keepParent "$neolink_app" "$neolink_output/$neolink_asset"
(cd "$neolink_output" && shasum -a 256 "$neolink_asset" > "$neolink_asset.sha256")
# Extract once and check the actual distributable, not just the input bundle.
neolink_check=$(mktemp -d "${TMPDIR:-/tmp}/neolink-package.XXXXXX")
trap 'rm -rf "$neolink_check"' EXIT
ditto -x -k "$neolink_output/$neolink_asset" "$neolink_check"
python3 scripts/verify-app.py "$neolink_check/NeoLink.app"
printf 'Release assets: %s/%s (+ .sha256)\n' "$neolink_output" "$neolink_asset"
