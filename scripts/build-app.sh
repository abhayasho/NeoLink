#!/usr/bin/env bash
# Build NeoLink as a double-clickable macOS .app with icon.
# Run from repo root: ./scripts/build-app.sh

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="NeoLink"
APP="$ROOT/$APP_NAME.app"
ICON_SRC="$ROOT/Resources/AppIcon.png"
ICON_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$ROOT/Resources/Info.plist")

echo "Building release binary..."
swift build -c release

# Ask SwiftPM for the current architecture's binary instead of choosing a stale build.
BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ -z "$BINARY" || ! -x "$BINARY" ]]; then
  echo "Error: release binary not found. Run: swift build -c release"
  exit 1
fi

echo "Creating app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# The source is already framed on a square, transparent canvas. Preserve it as-is:
# cropping or flattening it adds padding, clips artwork, or creates a second tile.
if [[ ! -f "$ICON_SRC" ]]; then
  echo "Error: missing icon source: $ICON_SRC" >&2
  exit 1
fi
W=$(sips -g pixelWidth "$ICON_SRC" | awk '/pixelWidth/{print $2}')
H=$(sips -g pixelHeight "$ICON_SRC" | awk '/pixelHeight/{print $2}')
if [[ "$W" != "$H" || "$W" -lt 1024 ]]; then
  echo "Error: AppIcon.png must be square and at least 1024 × 1024 pixels." >&2
  exit 1
fi

echo "Generating app icon..."
ICON_TMP=$(mktemp -d "${TMPDIR:-/tmp}/NeoLinkIcon.XXXXXX")
trap 'rm -rf "$ICON_TMP"' EXIT
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
# Standard macOS icon representations, including every Retina size.
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  size2=$((size * 2))
  sips -s format png -z "$size2" "$size2" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$ICON_NAME.icns"
echo "App icon created."

echo "Done: $APP"
echo "You can double-click NeoLink.app or drag it to Applications."
