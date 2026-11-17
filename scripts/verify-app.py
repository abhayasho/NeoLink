#!/usr/bin/env python3
"""Check a packaged NeoLink.app without launching it or changing system trust: identity, version,
executable, icon, the editor's Lua runtime and the code signature."""
import argparse
import plistlib
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
args = parser.parse_args()
app = args.app.resolve()
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleIdentifier'] == 'com.neolink.app', 'Unexpected bundle identity'
assert info['CFBundleName'] == 'NeoLink', 'Unexpected bundle name'
assert info['NSHighResolutionCapable'] is True, 'Retina support missing'
assert info['CFBundleVersion'].isdigit(), 'CFBundleVersion must be numeric'
resources = app / 'Contents/Resources'
for path in [app / 'Contents/MacOS' / info['CFBundleExecutable'],
             resources / (info['CFBundleIconFile'] + '.icns'),
             resources / 'AppIcon.png',
             resources / 'Editor/neolink.lua']:
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f'Missing or empty packaged resource: {path}')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(f"Verified NeoLink {info['CFBundleShortVersionString']} build {info['CFBundleVersion']}: resources and signature")
print('Signature verification does not establish Developer ID signing or notarization.')
