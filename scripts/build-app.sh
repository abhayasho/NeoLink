#!/usr/bin/env bash
# Build NeoLink as a double-clickable macOS .app with icon.
# Run from repo root: ./scripts/build-app.sh

set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="NeoLink"
APP="$ROOT/$APP_NAME.app"
ICON_SRC="$ROOT/Resources/AppIcon.png"
ICONSET="$ROOT/Resources/AppIcon.iconset"

echo "Building release binary..."
swift build -c release

# SPM puts the binary in .build/<triplet>/release/NeoLink (exclude .dSYM copy)
BINARY=$(find "$ROOT/.build" -type f -name "$APP_NAME" -path "*/release/*" ! -path "*.dSYM*" 2>/dev/null | head -1)
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

# Generate .icns from AppIcon.png (crop to content so artwork fills the icon, no dark border)
if [[ -f "$ICON_SRC" ]]; then
  echo "Generating app icon..."
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  # Crop to focus on the axolotl: shift crop down and right to cut off the top-left (terminal prompt >_)
  W=$(sips -g pixelWidth "$ICON_SRC" 2>/dev/null | awk '/pixelWidth/{print $2}')
  H=$(sips -g pixelHeight "$ICON_SRC" 2>/dev/null | awk '/pixelHeight/{print $2}')
  if [[ -n "$W" && -n "$H" && "$W" -gt 0 && "$H" -gt 0 ]]; then
    MIN=$(( W < H ? W : H ))
    CROP=$(( MIN * 90 / 100 ))
    # Offset crop toward bottom-right so top-left (prompt) is excluded
    OX=$(( (W - CROP) * 22 / 100 ))
    OY=$(( (H - CROP) * 38 / 100 ))
    sips -s format png --cropOffset "$OY" "$OX" -c "$CROP" "$CROP" "$ICON_SRC" --out "$ICONSET/_src.png" 2>/dev/null
    sips -s format png -z 1024 1024 "$ICONSET/_src.png" --out "$ICONSET/_src.png" 2>/dev/null
    ICON_SRC="$ICONSET/_src.png"
  fi
  for size in 16 32 64 128 256 512; do
    sips -s format png -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" 2>/dev/null
    size2=$((size * 2))
    sips -s format png -z $size2 $size2 "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" 2>/dev/null
  done
  rm -f "$ICONSET/_src.png"
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    echo "App icon created."
  else
    echo "Warning: could not create .icns (iconutil failed); app will use default icon."
  fi
  rm -rf "$ICONSET"
else
  echo "Warning: $ICON_SRC not found; app will use default icon."
fi

echo "Done: $APP"
echo "You can double-click NeoLink.app or drag it to Applications."
