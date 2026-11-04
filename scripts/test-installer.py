#!/usr/bin/env python3
"""Installer integration checks using the real packaged ZIP and offline downloads."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ASSET = 'NeoLink-macos-arm64.zip'
archive = ROOT / '.build/release-assets' / ASSET
if not archive.is_file():
    raise SystemExit('Run ./scripts/package-release.sh first.')
with tempfile.TemporaryDirectory(prefix='neolink-installer-test-') as temporary:
    work = Path(temporary)
    commands = work / 'bin'
    commands.mkdir()
    def command(name, body):
        path = commands / name
        path.write_text('#!/bin/bash\nset -eu\n' + body + '\n')
        path.chmod(0o755)
    command('curl', '''url='' destination=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) destination=$2; shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [[ "$url" == *.sha256 ]]; then
  if [[ "${TEST_BAD_CHECKSUM:-0}" == 1 ]]; then
    printf '%064d  NeoLink-macos-arm64.zip\\n' 0 > "$destination"
  else
    cp "$TEST_ARCHIVE.sha256" "$destination"
  fi
else
  cp "$TEST_ARCHIVE" "$destination"
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
           'NEOLINK_INSTALL_DIR': str(destination), 'TEST_ARCHIVE': str(archive)}
    def run(success=True, **extra):
        result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/install.sh')], env={**env, **extra},
                                text=True, capture_output=True)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        return result.stdout + result.stderr
    binary = destination / 'NeoLink.app/Contents/MacOS/NeoLink'
    run()
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    assert digest == hashlib.sha256((ROOT / 'NeoLink.app/Contents/MacOS/NeoLink').read_bytes()).hexdigest()
    run()
    backups = list(destination.glob('NeoLink Backup.*/NeoLink.app'))
    assert len(backups) == 1 and (backups[0] / 'Contents/MacOS/NeoLink').is_file()
    assert 'checksum mismatch' in run(False, TEST_BAD_CHECKSUM='1')
    assert 'Quit NeoLink' in run(False, TEST_RUNNING='1')
    assert 'Apple silicon' in run(False, TEST_ARCH='x86_64')
    assert 'macOS' in run(False, TEST_SYSTEM='Linux')
    run(False, TEST_FAIL_SWAP='1')
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == digest, 'Failed swap must restore old app'
    assert not list(destination.glob('.neolink-install.*')), 'Staging directories must be cleaned'
    binary.parent.parent.parent.rename(destination / 'Moved-NeoLink.app')
    (destination / 'NeoLink.app').symlink_to(destination / 'Moved-NeoLink.app')
    assert 'symlink' in run(False)
print('PASS: fresh install, update/backup, checksum rejection, running-app guard, platform guards, rollback, symlink guard')
