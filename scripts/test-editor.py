#!/usr/bin/env python3
"""Exercise the actual Neovim runtime through its socket, using disposable files."""
import json, os, pathlib, shutil, socket as socket_module, subprocess, sys, tempfile, time

nvim = shutil.which('nvim')
if not nvim:
    raise SystemExit('Install Neovim before running editor integration tests.')
config = pathlib.Path(__file__).resolve().parent.parent / 'Resources/Editor/neolink.lua'
with tempfile.TemporaryDirectory(prefix='neolink-editor-', dir='/tmp') as tmp:
    root = pathlib.Path(tmp).resolve()
    socket = root / 'editor.sock'
    control = root / 'control.sock'
    connection = None
    channel = None
    env = dict(os.environ, XDG_STATE_HOME=tmp, XDG_CACHE_HOME=tmp, XDG_DATA_HOME=tmp,
               NEOLINK_STATUS_FILE=str(root / 'status.json'), NEOLINK_CONTROL_SOCKET=str(control), PATH='/opt/homebrew/bin:/usr/local/bin:' + os.environ['PATH'])
    with (root / 'stderr').open('w+') as log:
        process = subprocess.Popen([nvim, '--headless', '--noplugin', '-u', str(config), '-i', 'NONE', '--listen', str(socket)], env=env, stdout=log, stderr=log)
        def expr(value):
            result = subprocess.run([nvim, '--headless', '--server', str(socket), '--remote-expr', value], capture_output=True, text=True, env=env, timeout=12)
            assert result.returncode == 0, result.stderr
            return result.stdout.strip()
        def lua(value):
            return expr("luaeval('" + value.replace("'", "''") + "')")
        def dispatch(**request):
            payload = json.dumps(request).encode() + b'\n'
            channel.write(payload)
            return json.loads(channel.readline())
        try:
            for _ in range(300):
                if (root / 'status.json').exists(): break
                if process.poll() is not None: raise AssertionError('Editor exited on startup')
                time.sleep(.02)
            assert (root / 'status.json').exists(), 'Editor did not publish initial state'
            connection = socket_module.socket(socket_module.AF_UNIX)
            connection.settimeout(12)
            connection.connect(str(control))
            channel = connection.makefile('rwb', buffering=0)
            lua('vim.lsp.log.set_level("debug")')
            assert dispatch(method='status')['state']['buffers'] == []
            first = root / "quoted ' $(no-shell).lua"
            first.write_text('local greeting = "hello"\nprint(greeting)\n')
            second = root / 'second.lua'
            second.write_text('return 42\n')
            opened = dispatch(method='open', path=str(first))
            assert opened['ok'], opened
            lua('vim.api.nvim_buf_set_lines(0,0,1,false,{"local greeting = 123"})')
            assert dispatch(method='status')['state']['buffers'][0]['modified']
            assert dispatch(method='open', path=str(second))['ok']
            state = dispatch(method='status')['state']
            assert len(state['buffers']) == 2
            assert any(b['path'] == str(first) and b['modified'] for b in state['buffers'])
            assert dispatch(method='save', path=str(first))['ok']
            assert first.read_text().startswith('local greeting = 123')
            first.write_text('outside change\n')
            assert not dispatch(method='save', path=str(first))['ok'], 'External edit overwritten'
            assert first.read_text() == 'outside change\n'
            assert dispatch(method='close', path=str(first))['ok']
            assert len(dispatch(method='status')['state']['buffers']) == 1
            encoded = root / 'utf16.txt'
            encoded.write_bytes(b'\xff\xfe' + 'before\r\n'.encode('utf-16-le'))
            assert dispatch(method='open', path=str(encoded))['ok']
            lua('vim.api.nvim_buf_set_lines(0,0,1,false,{"after"})')
            assert dispatch(method='save', path=str(encoded))['ok']
            assert encoded.read_bytes() == b'\xff\xfe' + 'after\r\n'.encode('utf-16-le')
            agent_file = root / 'agent-edits.lua'
            agent_file.write_text('return "before"\n')
            assert dispatch(method='open', path=str(agent_file))['ok']
            agent_file.write_text('return "updated by agent"\n')
            assert dispatch(method='open', path=str(agent_file))['ok']
            assert 'updated by agent' in lua('vim.api.nvim_get_current_line()')
            lua('vim.api.nvim_buf_set_lines(0,0,1,false,{"return 123"})')
            agent_file.write_text('return "conflicting agent edit"\n')
            assert dispatch(method='open', path=str(agent_file))['ok']
            assert lua('vim.api.nvim_get_current_line()') == 'return 123'
            assert not dispatch(method='save', path=str(agent_file))['ok'], 'Dirty editor overwrote agent edits'
            assert 'conflicting agent edit' in agent_file.read_text()
            print('PASS: clean buffers reload agent edits; unsaved buffers and external edits are preserved')
            scroll_file = root / 'scrolling.py'
            scroll_file.write_text(''.join(f'print({i})\n' for i in range(1, 401)))
            assert dispatch(method='open', path=str(scroll_file))['ok']
            assert lua('vim.o.mousescroll') == 'ver:1,hor:1'
            before_scroll = int(lua('vim.fn.line("w0")'))
            for _ in range(8): lua('vim.api.nvim_input_mouse("wheel","down","",0,8,12)')
            assert int(lua('vim.fn.line("w0")')) > before_scroll, 'Wheel input did not scroll the code buffer'
            assert lua('vim.bo.modified') == 'false', 'Scrolling modified the document'
            print('PASS: mouse wheel scrolls code without editing it')
            large = root / 'large.py'
            large.write_text('# large file\n' * 180000)
            assert dispatch(method='open', path=str(large))['ok']
            assert lua('vim.bo.syntax') == 'OFF'
            assert lua('#vim.lsp.get_clients({bufnr=0})') == '0'
            if shutil.which('pyright-langserver'):
                source = root / 'example.py'
                source.write_text('def greet(name: str) -> str:\n    return "Hello " + name\n\ngreet(123)\n')
                assert dispatch(method='open', path=str(source), line=4)['ok']
                # NeoLink intentionally defers diagnostics during Insert mode.
                # Leave it before checking the published diagnostic count.
                lua('vim.cmd("stopinsert")')
                # A clean CI image also cold-starts Node, Pyright and typeshed.
                # Use a wall-clock deadline rather than assuming 300 RPC process
                # launches take a predictable time on every Mac.
                diagnostic_deadline = time.monotonic() + 60
                while True:
                    snapshot = dispatch(method='status')['state']
                    current = next(b for b in snapshot['buffers'] if b['path'] == str(source))
                    if current['diagnostics'] > 0: break
                    if time.monotonic() >= diagnostic_deadline: break
                    time.sleep(.1)
                assert 'pyright' in current['servers'], current
                assert lua('vim.lsp.get_clients({bufnr=0})[1].capabilities.textDocument.diagnostic.dynamicRegistration') == 'false'

                if current['diagnostics'] == 0:
                    print('LSP diagnostic timeout:', current, 'mode:', lua('vim.fn.mode()'))
                    print('LSP clients:', lua('vim.json.encode(vim.tbl_map(function(c) return {id=c.id,initialized=c.initialized,stopped=c:is_stopped(),root=c.config.root_dir,diagnosticProvider=c.server_capabilities.diagnosticProvider,requests=c.requests} end,vim.lsp.get_clients({bufnr=0})))'))
                    lsp_log = pathlib.Path(lua('vim.lsp.log.get_filename()'))
                    if lsp_log.is_file(): print(lsp_log.read_text(errors='replace')[-16000:])
                assert current['diagnostics'] > 0, 'No Python type diagnostic'
                definition = lua('vim.json.encode(vim.lsp.buf_request_sync(0,"textDocument/definition",vim.lsp.util.make_position_params(0,"utf-16"),3000))')
                assert 'example.py' in definition and '"line":0' in definition, definition
                print('PASS: Python LSP diagnostics and definition')
            print('PASS: safe paths, shared buffers, dirty state, saving, external conflict, UTF-16/CRLF, large-file mode')
        finally:
            if channel is not None: channel.close()
            if connection is not None: connection.close()
            if process.poll() is None:
                try: expr("execute('qa!')")
                except Exception: pass
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
            log.seek(0)
            errors = log.read()
            if 'Error detected' in errors or 'Error in' in errors:
                print(errors[-6000:])
                raise AssertionError('Editor runtime errors')

# Headless mode cannot detect hit-enter deadlocks; use a private drained PTY too.
subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name("test-editor-messages.py"))], check=True)
