#!/usr/bin/env -S uv run --no-project python3
"""Boat/SSH/OMP/curl fixture. Each executable is a symlink inside a fresh lab.
No handler delegates to a real provider, SSH, or credentials command.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

world = Path(sys.argv[0]).absolute().parent.parent
name = Path(sys.argv[0]).name
args = sys.argv[1:]
path = world / 'provider.json'
state = json.loads(path.read_text())
fail = set(state.get('fail', []))
with (world / 'calls').open('a') as log:
    # No input bytes or tokens are ever recorded.
    log.write(name + ' ' + ('tunnel' if '-N' in args else args[0] if args else '') + '\n')

def commit():
    path.write_text(json.dumps(state))

def refusal(operation):
    if operation in fail:
        print('fixture refused ' + operation, file=sys.stderr)
        sys.exit(1)

def helper(pid):
    fields = (Path('/proc') / str(pid) / 'stat').read_text().split(') ', 1)[1].split()
    with (world / 'helpers').open('a') as log:
        log.write(f'{pid} {fields[19]}\n')

if name == 'boat':
    verb = args[0]
    refusal(verb)
    if verb == 'new':
        shape = state.get('new_shape')
        if shape == 'absent':
            print(json.dumps({'sandbox': {}})); sys.exit(0)
        if shape == 'malformed':
            print(json.dumps({'sandbox': {'id': 'not-a-box'}})); sys.exit(0)
        state.update(id='bx_fixture', state='ready', ip='127.0.0.1', ttl=int(args[args.index('--ttl') + 1]))
    elif verb == 'resume':
        if state.get('no_ready', 0):
            state['no_ready'] -= 1; commit(); print('no_ready_machine'); sys.exit(1)
        state.update(state='ready', ip='127.0.0.2', ttl=int(args[args.index('--ttl') + 1]))
    elif verb == 'stop':
        if state['state'] in ('archived', 'stopped'):
            print(json.dumps({'code': 'stop_failed', 'error': 'Sandbox is archived, so it cannot be stopped.', 'status': 400}))
            sys.exit(1)
        state['state'] = 'archived'
    elif verb == 'delete':
        state['state'] = 'deleted'
    elif verb == 'exec':
        state['key'] = state.get('persisted_key', state['key'])
    elif verb != 'info':
        sys.exit(2)
    if verb == 'info' and state.get('malformed_info'):
        print(json.dumps({'sandbox': []})); sys.exit(0)
    commit(); print(json.dumps({'sandbox': state}))
elif name == 'curl':
    request = sys.stdin.read()
    verb = 'authorize' if '/sshkey' in request else 'patch'
    refusal(verb)
    if verb == 'authorize':
        if state.get('malformed_endpoint'):
            print(json.dumps({'machineIp': '127.0.0.1', 'sshEndpoint': 22, 'hostKey': state['key']})); sys.exit(0)
        print(json.dumps({'success': True, 'machineIp': state['ip'], 'sshUser': 'user', 'hostKey': state['key']}))
    else:
        print(json.dumps({'ok': True, 'sandbox': state}))
elif name == 'omp':
    refusal('token')
    if state.get('token_barrier'):
        (world / 'token-waiting').touch()
        while True: time.sleep(.05)
    print('bad token' if 'invalid-token' in fail else 'fixture_upstream_bearer')
elif name == 'ssh':
    if '-N' in args:
        refusal('tunnel')
        helper(os.getpid())
        if state.get('escape'):
            child = subprocess.Popen(['uv', 'run', '--no-project', sys.executable, '-c', 'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(300)'], start_new_session=True)
            helper(child.pid)
            sys.exit(0)  # The r4 dead-leader schedule; escapee is now reparented.
        while True:
            time.sleep(1)
    command = ' '.join(args)
    remote = world / 'remote'
    remote.mkdir(exist_ok=True)
    if 'cat > /home/user/.fm/boat-auth-control' in command:
        refusal('stage')
        (remote / 'boat-auth-control').write_text(sys.stdin.read())
    elif '--install' in command:
        refusal('install')
        if state.get('install_barrier'):
            (world / 'installer-waiting').touch()
            while not (world / 'installer-go').exists(): time.sleep(.05)
        env = dict(os.environ, FM_BOAT_REMOTE_AUTH_DIR=str(remote))
        sys.exit(subprocess.run(['bash', remote / 'boat-auth-control', '--install'], input=sys.stdin.read(), text=True, env=env).returncode)
    elif '--shred' in command:
        refusal('shred')
        env = dict(os.environ, FM_BOAT_REMOTE_AUTH_DIR=str(remote))
        sys.exit(subprocess.run(['bash', remote / 'boat-auth-control', '--shred'], env=env).returncode)
    elif '--check' in command:
        refusal('check')
        refusal('tunnel')
        settings = json.loads(next((world / 'home/state/boat-omp-auth').glob('*/settings.json')).read_text())
        token = (remote / 'omp-auth-broker.token').read_text()
        request = urllib.request.Request('http://' + settings['proxy'] + '/v1/snapshot', headers={'Authorization': 'Bearer ' + token})
        with urllib.request.urlopen(request) as response:
            if response.headers.get('x-fm-auth-broker-facade') != 'credential-read-only': sys.exit(1)
    elif 'sh -s' in command:
        refusal('persist')
        sys.stdin.read()
        state['persisted_key'] = state['key']; commit()
    else:
        refusal('ssh')
        config = Path(args[args.index('-F') + 1])
        pin = next(config.parent.parent.glob('*.known_hosts')).read_text().split(' ', 1)[1].strip()
        if pin != state['key']: sys.exit(255)
else:
    sys.exit(2)
