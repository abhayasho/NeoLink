#!/usr/bin/env python3
"""Paired warm-buffer command completion, not visible-content latency."""
import json
import os
import pathlib
import shutil
import socket
import statistics
import subprocess
import tempfile
import time

config = pathlib.Path(__file__).resolve().parent.parent / 'Resources/Editor/neolink.lua'
nvim = shutil.which('nvim')
if not nvim:
    raise SystemExit('Neovim is required.')

with tempfile.TemporaryDirectory(prefix='neolink-control-bench-', dir='/tmp') as tmp:
    root = pathlib.Path(tmp)
    control, rpc = root / 'control.sock', root / 'editor.sock'
    env = dict(os.environ, NEOLINK_STATUS_FILE=str(root / 'status.json'),
               NEOLINK_CONTROL_SOCKET=str(control), XDG_STATE_HOME=tmp)
    with (root / 'log').open('wb') as log:
        process = subprocess.Popen([nvim, '--headless', '--noplugin', '-u', str(config),
                                    '-i', 'NONE', '--listen', str(rpc)],
                                   env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 5
            while not (control.exists() and (root / 'status.json').exists()):
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('Editor startup failed: ' + (root / 'log').read_text())
                time.sleep(.01)
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(5)
                connection.connect(str(control))
                with connection.makefile('rwb', buffering=0) as channel:
                    def direct(message):
                        channel.write(json.dumps(message).encode() + b'\n')
                        return json.loads(channel.readline())

                    files = [root / f'file-{index}.lua' for index in range(2)]
                    for index, path in enumerate(files):
                        path.write_text(f'return {index}\n')
                        assert direct(dict(method='open', path=str(path)))['ok']
                    reports = {}
                    for name in ['subprocess', 'persistent', 'subprocess', 'persistent']:
                        timings = []
                        for index in range(40):
                            message = dict(method='open', path=str(files[index % 2]))
                            start = time.perf_counter()
                            if name == 'subprocess':
                                payload = json.dumps(message).replace("'", "''")
                                expression = "luaeval('NeoLink.dispatch(_A)', '" + payload + "')"
                                response = json.loads(subprocess.check_output(
                                    [nvim, '--server', str(rpc), '--remote-expr', expression], timeout=8))
                            else:
                                response = direct(message)
                            assert response['ok'], response
                            timings.append((time.perf_counter() - start) * 1000)
                        reports.setdefault(name, []).append(dict(
                            median=statistics.median(timings), p95=sorted(timings)[37],
                            max=max(timings), samples=len(timings)))
                    print(json.dumps(dict(scope='headless command completion in milliseconds',
                                          nvim=subprocess.check_output([nvim, '--version'], text=True).splitlines()[0],
                                          results=reports), indent=2))
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
