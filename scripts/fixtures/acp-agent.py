#!/usr/bin/env python3
"""Offline ACP test peer. Does not execute tools, call models, or modify files."""
import json
import sys

session = 'fixture-session'
prompt_id = None
permission_cancelled = False


def send(value):
    payload = (json.dumps(dict(jsonrpc='2.0', **value), ensure_ascii=False) + '\n').encode()
    # Split within UTF-8 and JSON tokens to exercise pipe framing.
    sys.stdout.buffer.write(payload[:17])
    sys.stdout.buffer.flush()
    sys.stdout.buffer.write(payload[17:])
    sys.stdout.buffer.flush()


def update(value):
    send(dict(method='session/update', params=dict(sessionId=session, update=value)))


def text(value):
    update(dict(sessionUpdate='agent_message_chunk', content=dict(type='text', text=value)))


for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    params = message.get('params', {})
    rid = message.get('id')
    if method == 'initialize':
        assert params['protocolVersion'] == 1
        assert params['clientCapabilities']['terminal'] is False
        assert params['clientCapabilities']['fs']['writeTextFile'] is False
        send(dict(id=rid, result=dict(protocolVersion=1, agentCapabilities={}, authMethods=[])))
    elif method == 'session/new':
        assert params['cwd'].startswith('/') and isinstance(params['mcpServers'], list)
        send(dict(id=rid, result=dict(sessionId=session, modes=dict(currentModeId='ask', availableModes=[dict(id='ask', name='Ask'), dict(id='plan', name='Plan')]))))
    elif method == 'session/set_mode':
        send(dict(id=rid, result={}))
        update(dict(sessionUpdate='current_mode_update', currentModeId=params['modeId']))
    elif method == 'session/prompt':
        prompt_id = rid
        prompt = params['prompt'][0]['text']
        if prompt == 'disconnect':
            sys.exit(0)
        elif prompt == 'malformed':
            print('not json', flush=True)
        elif prompt == 'cancel':
            send(dict(id='cancel-permission', method='session/request_permission', params=dict(sessionId=session, toolCall=dict(toolCallId='wait', title='Waiting permission'), options=[dict(optionId='allow', name='Allow once', kind='allow_once')])))
        elif prompt == 'stream':
            # A long answer in small chunks, about as fast as a model streams tokens (benchmark).
            import time
            for index in range(600):
                text(f'Token {index} of a streamed answer with **markdown** and `code`. ')
                if index % 40 == 39:
                    text('\n\n')
                time.sleep(0.004)
            send(dict(id=prompt_id, result=dict(stopReason='end_turn')))
        else:
            text('Hello ')
            text('世界. ')
            update(dict(sessionUpdate='tool_call', toolCallId='preview', title='Preview a change', status='pending', rawInput=dict(path='example.py')))
            send(dict(id='permission-1', method='session/request_permission', params=dict(sessionId=session, toolCall=dict(toolCallId='preview'), options=[dict(optionId='allow', name='Allow once', kind='allow_once'), dict(optionId='deny', name='Reject', kind='reject_once')])))
    elif method == 'session/cancel':
        assert permission_cancelled, 'Client must cancel pending permission requests'
        send(dict(id=prompt_id, result=dict(stopReason='cancelled')))
    elif rid == 'cancel-permission':
        permission_cancelled = message['result']['outcome']['outcome'] == 'cancelled'
    elif rid == 'permission-1':
        outcome = message['result']['outcome']
        approved = outcome.get('optionId') == 'allow'
        update(dict(sessionUpdate='tool_call_update', toolCallId='preview', status='completed', content=[dict(type='diff', path='example.py', oldText='before', newText='after')]))
        text('Approved.' if approved else 'Rejected.')
        send(dict(id=prompt_id, result=dict(stopReason='end_turn')))
    elif method == 'never':
        pass
    elif rid is not None and method:
        send(dict(id=rid, error=dict(code=-32601, message='Unknown method')))
