#!/usr/bin/env bash
# Builds NeoLink.app (macOS) at target/NeoLink.app from the release binary.
# The version comes from Cargo.toml; the bundle identifier is com.neolink.app, as for every release.
# Set NEOLINK_SIGNING_IDENTITY to sign with a certificate (folder permissions then survive updates);
# otherwise the app is ad-hoc signed. NEOLINK_UNIVERSAL=1 builds for Apple silicon and Intel and joins
# them into one universal binary (releases do; needs `rustup target add x86_64-apple-darwin
# aarch64-apple-darwin`). Run from anywhere: scripts/build-app.sh

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/target/NeoLink.app"
ICON_SRC="$ROOT/Resources/AppIcon.png"

if [[ "${NEOLINK_UNIVERSAL:-0}" == 1 ]]; then
  echo "Building the release binary for Apple silicon and Intel..."
  for TARGET in aarch64-apple-darwin x86_64-apple-darwin; do
    MACOSX_DEPLOYMENT_TARGET=13.0 cargo build --release -p neolink --locked --target "$TARGET"
  done
  BINARY=$(mktemp -d "${TMPDIR:-/tmp}/NeoLinkBinary.XXXXXX")/neolink
  lipo -create -output "$BINARY" "$ROOT/target/aarch64-apple-darwin/release/neolink" "$ROOT/target/x86_64-apple-darwin/release/neolink"
else
  echo "Building the release binary..."
  cargo build --release -p neolink --locked
  BINARY="$ROOT/target/release/neolink"
fi

echo "Creating $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/NeoLink"
# Debug information stays in target/release for profiling; the shipped binary does without it.
strip -S -x "$APP/Contents/MacOS/NeoLink"
chmod +x "$APP/Contents/MacOS/NeoLink"
# The editor's Lua runtime and the logo are looked up in Contents/Resources.
cp -R "$ROOT/Resources/Editor" "$APP/Contents/Resources/Editor"
cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.png"

VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)
# A build number that only grows: the commit count (CFBundleVersion must be numeric).
BUILD=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
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

codesign --force --sign "${NEOLINK_SIGNING_IDENTITY:--}" "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "Built $APP (NeoLink $VERSION, build $BUILD, $(lipo -archs "$APP/Contents/MacOS/NeoLink"))"
