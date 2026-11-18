#!/usr/bin/env bash
# Archives an already built app for GitHub Releases, in target/release-assets:
# - a universal app (Apple silicon and Intel; scripts/build-app.sh with NEOLINK_UNIVERSAL=1) becomes
#   NeoLink-macos-universal.zip, plus the same archive as NeoLink-macos-arm64.zip, the name older
#   installers and links download;
# - an Apple silicon app becomes NeoLink-macos-arm64.zip only (NEOLINK_REQUIRE_UNIVERSAL=1 refuses it).
# Each archive gets a .sha256 naming it. Run scripts/build-app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:-target/NeoLink.app}
OUTPUT=${2:-target/release-assets}
python3 scripts/verify-app.py "$APP"
ARCHS=$(lipo -archs "$APP/Contents/MacOS/NeoLink")
case "$ARCHS" in
  "x86_64 arm64" | "arm64 x86_64") ASSETS=(NeoLink-macos-universal.zip NeoLink-macos-arm64.zip) ;;
  arm64)
    [[ "${NEOLINK_REQUIRE_UNIVERSAL:-0}" != 1 ]] || { echo 'Expected a universal app (NEOLINK_UNIVERSAL=1 scripts/build-app.sh).' >&2; exit 1; }
    ASSETS=(NeoLink-macos-arm64.zip) ;;
  *) echo "Unexpected architectures: $ARCHS" >&2; exit 1 ;;
esac
mkdir -p "$OUTPUT"
rm -f "$OUTPUT"/NeoLink-macos-*.zip "$OUTPUT"/NeoLink-macos-*.zip.sha256
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/${ASSETS[0]}"
for ASSET in "${ASSETS[@]}"; do
  [[ -f "$OUTPUT/$ASSET" ]] || cp "$OUTPUT/${ASSETS[0]}" "$OUTPUT/$ASSET"
  (cd "$OUTPUT" && shasum -a 256 "$ASSET" > "$ASSET.sha256")
done
# Extract once and check the actual download, not just the input bundle.
CHECK=$(mktemp -d "${TMPDIR:-/tmp}/neolink-package.XXXXXX")
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$OUTPUT/${ASSETS[0]}" "$CHECK"
python3 scripts/verify-app.py "$CHECK/NeoLink.app"
[[ "$(lipo -archs "$CHECK/NeoLink.app/Contents/MacOS/NeoLink")" == "$ARCHS" ]] || { echo 'The archive lost an architecture.' >&2; exit 1; }
printf 'Release assets (%s): %s\n' "$ARCHS" "${ASSETS[*]/#/$OUTPUT/}"
