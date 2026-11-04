#!/usr/bin/env python3
"""Private-PTY regression: asynchronous errors must not block editor commands."""
import fcntl, json, os, pathlib, pty, select, shutil, socket, struct, subprocess, tempfile, termios, threading, time

with tempfile.TemporaryDirectory(prefix='neolink-messages-', dir='/tmp') as tmp:
    root = pathlib.Path(tmp).resolve()
    config = root / 'init.lua'
    runtime = pathlib.Path(__file__).resolve().parent.parent / 'Resources/Editor/neolink.lua'
    config.write_text('dofile(' + json.dumps(str(runtime)) + ')\n' + "vim.defer_fn(function() error('simulated initialize failure\\n'..string.rep('service unavailable ',30)) end,200)\n")
    first = root / 'one' / 'index.txt'; second = root / 'two' / 'index.txt'
    for file in [first, second]:
        file.parent.mkdir(); file.write_text(file.parent.name + '\n')
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH',24,80,0,0))
    env = dict(os.environ, TERM='xterm-256color', XDG_STATE_HOME=tmp,
               NEOLINK_STATUS_FILE=str(root/'status.json'), NEOLINK_CONTROL_SOCKET=str(root/'control.sock'))
    process = subprocess.Popen([shutil.which('nvim'),'--noplugin','-u',str(config),'-i','NONE'],
                               stdin=slave,stdout=slave,stderr=slave,env=env,start_new_session=True)
    os.close(slave)
    stopped = threading.Event()
    def drain():
        while not stopped.is_set():
            if select.select([master],[],[],.02)[0]:
                try: os.read(master,65536)
                except OSError: return
    reader = threading.Thread(target=drain,daemon=True); reader.start()
    try:
        deadline = time.monotonic()+5
        while not (root/'status.json').exists() and time.monotonic()<deadline: time.sleep(.01)
        assert (root/'status.json').exists(), 'TUI did not start'
        time.sleep(.4)  # Allow the deliberately scheduled error to exceed the TUI's cmdline.
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(3); connection.connect(str(root/'control.sock'))
            with connection.makefile('rwb',buffering=0) as channel:
                def request(**payload):
                    channel.write(json.dumps(payload).encode()+b'\n')
                    return json.loads(channel.readline())
                state = request(method='status')
                assert 'simulated initialize failure' in state['state'].get('notice',''), state
                assert state['ok'], state
                for selection,file in enumerate([first,second,first],1):
                    response=request(method='open',path=str(file),selection=selection,trace=True)
                    assert response['ok'], response
                    assert response['state']['active']==str(file), response
                    assert response['state']['selection']==selection, response
                    assert len(response['state']['buffers'])==min(selection,2), response
                assert 'simulated initialize failure' in response['state']['notice'], 'Error history must remain visible'
        print('PASS: multiline asynchronous errors remain visible without blocking TUI commands or duplicate-basename switching')
    finally:
        stopped.set(); process.terminate()
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired: process.kill();process.wait()
        reader.join(timeout=.2); os.close(master)
