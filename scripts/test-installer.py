#!/usr/bin/env python3
"""Installer integration checks using the real packaged ZIP and offline downloads."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'target/release-assets'
if not (ASSETS / 'NeoLink-macos-arm64.zip').is_file():
    raise SystemExit('Run scripts/build-app.sh and scripts/package-release.sh first.')
# A universal build also runs on Intel; an Apple silicon build is offered only as the arm64 download.
universal = (ASSETS / 'NeoLink-macos-universal.zip').is_file()
with tempfile.TemporaryDirectory(prefix='neolink-installer-test-') as temporary:
    work = Path(temporary)
    commands = work / 'bin'
    commands.mkdir()
    def command(name, body):
        path = commands / name
        path.write_text('#!/bin/bash\nset -eu\n' + body + '\n')
        path.chmod(0o755)
    # Serves release files by name from target/release-assets; TEST_MISSING names one that 404s.
    command('curl', '''url='' destination=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) destination=$2; shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
name=${url##*/}
if [[ -n "${TEST_MISSING:-}" && "$name" == *"$TEST_MISSING"* ]] || [[ ! -f "$TEST_ASSETS/$name" ]]; then
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
if [[ "$name" == *.sha256 && "${TEST_BAD_CHECKSUM:-0}" == 1 ]]; then
  printf '%064d  %s\\n' 0 "${name%.sha256}" > "$destination"
else
  cp "$TEST_ASSETS/$name" "$destination"
fi''')
    command('pgrep', '[[ "${TEST_RUNNING:-0}" == 1 ]]')
    command('uname', '''case "$1" in
  -s) echo "${TEST_SYSTEM:-Darwin}" ;;
  -m) echo "${TEST_ARCH:-arm64}" ;;
esac''')
    command('sysctl', 'echo 0')
    command('mv', '''if [[ "${TEST_FAIL_SWAP:-0}" == 1 && "$1" == */.neolink-install.*/NeoLink.app ]]; then
  exit 73
fi
exec /bin/mv "$@"''')
    destination = work / 'Applications with spaces'
    env = {**os.environ, 'PATH': str(commands) + ':' + os.environ['PATH'],
           'NEOLINK_INSTALL_DIR': str(destination), 'TEST_ASSETS': str(ASSETS)}
    def run(success=True, **extra):
        result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/install.sh')], env={**env, **extra},
                                text=True, capture_output=True)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        return result.stdout + result.stderr
    binary = destination / 'NeoLink.app/Contents/MacOS/NeoLink'
    run()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    assert digest == hashlib.sha256((ROOT / 'target/NeoLink.app/Contents/MacOS/NeoLink').read_bytes()).hexdigest()
    run()
    backups = list(destination.glob('NeoLink Backup.*/NeoLink.app'))
    assert len(backups) == 1 and (backups[0] / 'Contents/MacOS/NeoLink').is_file()
    assert 'checksum mismatch' in run(False, TEST_BAD_CHECKSUM='1')
    assert 'Quit NeoLink' in run(False, TEST_RUNNING='1')
    # Apple silicon falls back to the arm64 download when a release has no universal one.
    assert 'Installed' in run(TEST_MISSING='universal')
    assert 'no Intel build' in run(False, TEST_ARCH='x86_64', TEST_MISSING='universal')
    if universal:
        assert 'for Intel' in run(TEST_ARCH='x86_64')
    else:
        assert 'no Intel build' in run(False, TEST_ARCH='x86_64')
    assert 'Unsupported processor' in run(False, TEST_ARCH='ppc')
    assert 'macOS' in run(False, TEST_SYSTEM='Linux')
    run(False, TEST_FAIL_SWAP='1')
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == digest, 'Failed swap must restore old app'
    assert not list(destination.glob('.neolink-install.*')), 'Staging directories must be cleaned'
    binary.parent.parent.parent.rename(destination / 'Moved-NeoLink.app')
    (destination / 'NeoLink.app').symlink_to(destination / 'Moved-NeoLink.app')
    assert 'symlink' in run(False)
print('PASS: fresh install, update/backup, checksum rejection, running-app guard, platform guards, '
      + ('Intel install, ' if universal else '') + 'arm64 fallback, rollback, symlink guard')
