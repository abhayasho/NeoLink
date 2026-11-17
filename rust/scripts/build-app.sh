#!/usr/bin/env bash
# Builds the Rust NeoLink as a macOS app bundle at rust/target/NeoLink.app.
# It has its own bundle identifier (com.neolink.app.rust), so it sits beside the Swift app without
# taking over its settings or folder permissions; nothing outside rust/target is written.
# Run from anywhere: rust/scripts/build-app.sh

set -euo pipefail
cd "$(dirname "$0")/.."
RUST="$PWD"
ROOT="$(cd .. && pwd)"
APP="$RUST/target/NeoLink.app"
ICON_SRC="$ROOT/Resources/AppIcon.png"

echo "Building the release binary..."
cargo build --release -p neolink --locked

echo "Creating $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$RUST/target/release/neolink" "$APP/Contents/MacOS/NeoLink"
chmod +x "$APP/Contents/MacOS/NeoLink"
# The editor's Lua and the logo are looked up in Contents/Resources.
cp -R "$ROOT/Resources/Editor" "$APP/Contents/Resources/Editor"
cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.png"

VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$RUST/Cargo.toml" | head -1)
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.neolink.app.rust" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable NeoLink" "$PLIST"
# Named apart from the Swift app in the Dock and Finder.
/usr/libexec/PlistBuddy -c "Set :CFBundleName NeoLink Rust" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string NeoLink Rust" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName NeoLink Rust" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 13.0" "$PLIST"
ICON_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$PLIST")

# The icon: the source is already framed on a square, transparent canvas.
ICONSET=$(mktemp -d "${TMPDIR:-/tmp}/NeoLinkIcon.XXXXXX")/icon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$ICON_NAME.icns"
rm -rf "$(dirname "$ICONSET")"

# Ad-hoc signing unless an identity is named (a stable identity keeps folder permissions across builds).
codesign --force --sign "${NEOLINK_SIGNING_IDENTITY:--}" "$APP" >/dev/null
echo "Built $APP"
