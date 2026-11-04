#!/bin/bash
# Install the published app. No compiler, Git checkout, sudo, or Homebrew required.
set -euo pipefail
# Parse the complete installer before performing work when invoked through curl.
main() {
fail() { printf 'NeoLink: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail 'This app requires macOS.'
# uname can report x86_64 in a Rosetta terminal on Apple silicon.
neolink_arch=$(uname -m)
if [[ "$neolink_arch" == x86_64 ]] && [[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" == 1 ]]; then
  neolink_arch=arm64
fi
[[ "$neolink_arch" == arm64 ]] || fail 'The prebuilt app currently supports Apple silicon (M1 or later). Intel Macs require a source build.'
neolink_major=$(sw_vers -productVersion | cut -d. -f1)
[[ "$neolink_major" -ge 13 ]] || fail 'macOS 13 or later is required.'
if pgrep -x NeoLink >/dev/null; then
  fail 'Quit NeoLink first, then rerun this command. Your open documents and settings will be preserved.'
fi
neolink_parent=${NEOLINK_INSTALL_DIR:-/Applications}
if [[ -z "${NEOLINK_INSTALL_DIR:-}" && ! -w "$neolink_parent" ]]; then
  neolink_parent="$HOME/Applications"
fi
[[ "$neolink_parent" == /* ]] || fail 'NEOLINK_INSTALL_DIR must be an absolute path.'
mkdir -p "$neolink_parent"
[[ -w "$neolink_parent" ]] || fail "Cannot write to $neolink_parent. Try NEOLINK_INSTALL_DIR=\"\$HOME/Applications\"."
neolink_destination="$neolink_parent/NeoLink.app"
[[ ! -L "$neolink_destination" ]] || fail 'The destination is a symlink; move it aside before installing.'
neolink_tmp=$(mktemp -d "${TMPDIR:-/tmp}/neolink-install.XXXXXX")
neolink_stage=''
neolink_backup=''
cleanup() {
  neolink_result=$?
  if [[ -n "$neolink_backup" && ! -e "$neolink_destination" ]]; then
    mv "$neolink_backup" "$neolink_destination" || printf 'Restore the previous app from %s\n' "$neolink_backup" >&2
  fi
  [[ -z "$neolink_stage" ]] || rm -rf "$neolink_stage"
  rm -rf "$neolink_tmp"
  exit "$neolink_result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
neolink_asset=NeoLink-macos-arm64.zip
neolink_url=https://github.com/abhayasho/NeoLink/releases/latest/download
printf 'Downloading NeoLink for Apple silicon…\n'
curl --fail --location --show-error --silent --retry 3 --connect-timeout 20 --max-time 300 \
  --proto '=https' --proto-redir '=https' "$neolink_url/$neolink_asset" -o "$neolink_tmp/$neolink_asset"
curl --fail --location --show-error --silent --retry 3 --connect-timeout 20 --max-time 60 \
  --proto '=https' --proto-redir '=https' "$neolink_url/$neolink_asset.sha256" -o "$neolink_tmp/checksum"
neolink_expected=$(awk -v name="$neolink_asset" '$2 == name && length($1) == 64 && $1 !~ /[^0-9a-f]/ {print $1}' "$neolink_tmp/checksum")
[[ ${#neolink_expected} -eq 64 ]] || fail 'Invalid release checksum.'
neolink_actual=$(shasum -a 256 "$neolink_tmp/$neolink_asset" | awk '{print $1}')
[[ "$neolink_actual" == "$neolink_expected" ]] || fail 'Download checksum mismatch; the installed app was not changed.'
ditto -x -k "$neolink_tmp/$neolink_asset" "$neolink_tmp/unpacked"
neolink_app="$neolink_tmp/unpacked/NeoLink.app"
[[ -d "$neolink_app" && ! -L "$neolink_app" ]] || fail 'The release does not contain NeoLink.app.'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$neolink_app/Contents/Info.plist")" == com.neolink.app ]] || fail 'Unexpected app identity.'
[[ -x "$neolink_app/Contents/MacOS/NeoLink" ]] || fail 'App executable is missing.'
codesign --verify --deep --strict "$neolink_app"
# Stage on the destination filesystem before replacing the old app; keep a rollback copy.
neolink_stage=$(mktemp -d "$neolink_parent/.neolink-install.XXXXXX")
ditto "$neolink_app" "$neolink_stage/NeoLink.app"
codesign --verify --deep --strict "$neolink_stage/NeoLink.app"
# Recheck after the download in case the user opened the app while waiting.
pgrep -x NeoLink >/dev/null && fail 'Quit NeoLink and rerun; it was opened during the download.'
if [[ -e "$neolink_destination" ]]; then
  [[ -d "$neolink_destination" ]] || fail 'The destination exists and is not an app directory.'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$neolink_destination/Contents/Info.plist")" == com.neolink.app ]] || fail 'Refusing to replace a different app.'
  neolink_saved=$(mktemp -d "$neolink_parent/NeoLink Backup.XXXXXX")
  neolink_backup="$neolink_saved/NeoLink.app"
  mv "$neolink_destination" "$neolink_backup"
fi
mv "$neolink_stage/NeoLink.app" "$neolink_destination"
if [[ -n "$neolink_backup" ]]; then
  printf 'Previous app saved in %s\n' "$neolink_saved"
fi
printf 'Installed %s\nOpen NeoLink from Applications. Rerun this command to update.\n' "$neolink_destination"
printf 'This preview is ad-hoc signed, not notarized. macOS may require first-launch approval.\n'
}
main "$@"
