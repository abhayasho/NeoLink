#!/usr/bin/env python3
"""Check a packaged release without launching it or changing system trust."""
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
assert info['NSHighResolutionCapable'] is True, 'Retina support missing'
resources = app / 'Contents/Resources'
for path in [app / 'Contents/MacOS' / info['CFBundleExecutable'],
             resources / (info['CFBundleIconFile'] + '.icns'),
             resources / 'Editor/neolink.lua',
             resources / 'SwiftTerm_SwiftTerm.bundle/Shaders.metal']:
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f'Missing or empty packaged resource: {path}')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(f"Verified NeoLink {info['CFBundleShortVersionString']} build {info['CFBundleVersion']}: resources and signature")
print('Signature verification does not establish Developer ID signing or notarization.')
