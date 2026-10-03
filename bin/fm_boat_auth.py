"""Boat credential acquire/use/release owner. Linux systemd owns every child.

The durable generation is a capability, not a PID journal. Start contenders
compare the generation observed before flock; release revokes it before stop.
A late systemd start must take the same lock and validate its generation before
any acquisition. Its installer, broker, facade and SSH legs never leave the unit.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import secrets
import subprocess
import sys
import time
import urllib.request

from fm_boat_common import (CONFIG, ROOT, STATE, Failure, directory, load, lock,
                            policy, publish, regular, run, safe_id, save, ssh, executable)

RUNTIME = STATE / 'boat-omp-auth'
TIMEOUT = float(os.environ.get('FM_BOAT_AUTH_TIMEOUT', '30'))
SYSTEMCTL = os.environ.get('FM_BOAT_SYSTEMCTL_BIN', 'systemctl')
SYSTEMD_RUN = os.environ.get('FM_BOAT_SYSTEMD_RUN_BIN', 'systemd-run')

def paths(id):
    base = directory(RUNTIME / safe_id(id))
    return base, base / 'lease.meta', base / 'operation.lock'

def substrate():
    if sys.platform != 'linux' or not Path('/sys/fs/cgroup/cgroup.controllers').is_file():
        raise Failure('Boat auth requires Linux cgroup v2 and a systemd user manager')
    run([SYSTEMCTL, '--user', 'show', '--property=ControlGroup'])

def properties(unit):
    result = run([SYSTEMCTL, '--user', 'show', unit, '--property=ActiveState',
                  '--property=LoadState', '--property=ControlGroup', '--property=KillMode',
                  '--property=RemainAfterExit'])
    return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)

def retire(record):
    unit = record.get('unit')
    if not unit:
        return
    if not re.fullmatch(r'fm-boat-[0-9a-f]{20}-[0-9a-f]{32}\.service', unit):
        raise Failure('invalid credential service identity')
    before = properties(unit)
    cgroup = before.get('ControlGroup') or record.get('cgroup', '')
    if before.get('LoadState') != 'not-found':
        run([SYSTEMCTL, '--user', 'stop', unit], timeout=TIMEOUT + 10)
    after = properties(unit)
    if after.get('ActiveState') not in ('inactive', 'failed'):
        raise Failure('credential service did not stop')
    if cgroup:
        if not cgroup.startswith('/user.slice/') or '..' in cgroup.split('/'):
            raise Failure('invalid credential cgroup')
        events = Path('/sys/fs/cgroup') / cgroup.lstrip('/') / 'cgroup.events'
        if events.exists() and 'populated 1' in events.read_text():
            raise Failure('credential cgroup still contains helpers')

def remote_shred(record):
    descriptor = record.get('descriptor')
    if not descriptor:
        raise Failure('SSH descriptor missing; remote bearer shred is unproven')
    descriptor = json.loads(descriptor)
    regular(descriptor['config'], 0o600)
    ssh(descriptor, '/home/user/.fm/boat-auth-control', '--shred', timeout=TIMEOUT)

def release_locked(base, record, *, remote_gone=False):
    # Tombstone first. An orphaned, delayed systemd-run request cannot install.
    record['generation'] = secrets.token_hex(16)
    record['state'] = 'revoked'
    save(base / 'lease.meta', record)
    errors = []
    for file in ('facade.token', 'upstream.token'):
        try:
            (base / file).unlink(missing_ok=True)
        except OSError:
            errors.append(f'{file} unretired')
    try:
        retire(record)
    except (Failure, OSError, ValueError, KeyError) as error:
        errors.append(str(error))
    # Never shred while an installer may still write. No sandbox deletion
    # is permitted by the lifecycle owner unless this whole release succeeds.
    if not errors and record.get('install_attempted') == '1' and not remote_gone:
        try:
            remote_shred(record)
        except (Failure, OSError, ValueError, KeyError) as error:
            errors.append(str(error))
    if errors:
        if record.get('install_attempted') == '1' and not remote_gone:
            errors.append('remote bearer unshredded')
        record['state'] = 'unresolved'
        record['cleanup'] = '; '.join(errors)
        save(base / 'lease.meta', record)
        raise Failure('credential cleanup unresolved: ' + record['cleanup'])
    record['state'] = 'retired'
    record['cleanup'] = 'helpers=retired' if record.get('unit') else 'helpers=not-started'
    if remote_gone:
        record['cleanup'] += ' remote=verified-gone'
    else:
        record['cleanup'] += ' bearer=shredded' if record.get('install_attempted') == '1' else ' bearer=not-installed'
    record['install_attempted'] = '0'
    save(base / 'lease.meta', record)

def release(id, remote_gone=False):
    substrate()
    base, path, guard = paths(id)
    with lock(guard):
        release_locked(base, load(path), remote_gone=remote_gone)

def acquire(id, alias, config, model):
    substrate()
    allowed = policy(model)
    regular(config, 0o600)
    base, path, guard = paths(id)
    observed = load(path).get('generation', '')
    with lock(guard):
        prior = load(path)
        if prior.get('generation', '') != observed:
            raise Failure('credential generation changed while waiting; stale acquisition refused')
        if prior.get('state') == 'ready':
            settings = json.loads(regular(base / 'settings.json', 0o600).read_text())
            if (settings['providers'] == allowed and settings['descriptor']['alias'] == alias
                    and settings['descriptor']['config'] == str(Path(config).resolve())
                    and properties(prior['unit']).get('ActiveState') == 'active'
                    and (base / 'facade.token').is_file() and (base / 'upstream.token').is_file()):
                try:
                    ssh(settings['descriptor'], '/home/user/.fm/boat-auth-control', '--check', timeout=TIMEOUT)
                    return
                except (Failure, OSError, ValueError, KeyError):
                    release_locked(base, prior)
                    raise
        if prior:
            release_locked(base, prior)
        generation = secrets.token_hex(16)
        unit = 'fm-boat-' + hashlib.sha256(str(base.resolve()).encode()).hexdigest()[:20] + '-' + generation + '.service'
        settings = {
            'descriptor': {'ssh': executable(os.environ.get('FM_BOAT_SSH_BIN', os.environ.get('FM_SSH_BIN', 'ssh'))),
                           'alias': alias, 'config': str(Path(config).resolve())},
            'providers': allowed, 'omp': executable(os.environ.get('FM_BOAT_OMP_BIN', 'omp')),
            'node': executable(os.environ.get('FM_BOAT_NODE_BIN', 'node')),
            'broker': os.environ.get('FM_BOAT_BROKER_URL', 'http://127.0.0.1:8765'),
            'proxy': os.environ.get('FM_BOAT_PROXY_BIND') or free_loopback(),
            'remote': os.environ.get('FM_BOAT_REMOTE_BIND', '127.0.0.1:8765'),
            'timeout': TIMEOUT,
            'path': os.environ['PATH'],
        }
        publish(base / 'settings.json', json.dumps(settings))
        save(path, {'generation': generation, 'state': 'acquiring', 'unit': unit,
                    'descriptor': json.dumps(settings['descriptor']), 'install_attempted': '0'})
        try:
            # The manager forks the payload already inside its cgroup. No STOP /
            # CONT handshake, pre-claim shell fork or journaled PID is involved.
            run([SYSTEMD_RUN, '--user', '--quiet', '--collect', '--unit=' + unit,
                 '--property=Type=exec', '--property=RemainAfterExit=yes',
                 '--property=KillMode=control-group', '--property=TimeoutStopSec=5',
                 '--property=SendSIGKILL=yes', '--property=RuntimeMaxSec=86400',
                 executable('uv'), 'run', '--no-project', '--python', sys.executable,
                 ROOT / 'fm-boat.py', 'auth-run', str(base), generation], timeout=TIMEOUT)
        except Failure:
            release_locked(base, load(path))
            raise
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        record = load(path)
        if record.get('generation') != generation:
            raise Failure('credential acquisition superseded or revoked')
        if record.get('state') == 'ready':
            return
        time.sleep(0.05)
    with lock(guard):
        record = load(path)
        if record.get('generation') == generation:
            release_locked(base, record)
    raise Failure('credential acquisition did not become ready')

def ready_url(url):
    try:
        with urllib.request.urlopen(url + '/v1/healthz', timeout=1) as response:
            return response.status == 200
    except (OSError, ValueError):
        return False

def free_loopback():
    # A bind collision is detected by the facade's own process and authenticated
    # remote readiness check; it can never reuse another lease's credentials.
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return '127.0.0.1:' + str(listener.getsockname()[1])


def worker(base, generation):
    base = Path(base)
    path = base / 'lease.meta'
    # This lock is needed only during acquisition, not throughout the service
    # lifetime. Release cannot wait on a service whose exit needs its lock.
    with lock(base / 'operation.lock'):
        record = load(path)
        if record.get('generation') != generation or record.get('state') != 'acquiring':
            return
        settings = json.loads(regular(base / 'settings.json', 0o600).read_text())
        os.environ['PATH'] = settings['path']
        timeout = settings['timeout']
        descriptor = settings['descriptor']
        upstream = run([settings['omp'], 'auth-broker', 'token'], timeout=timeout).stdout.rstrip('\n').rstrip('\r')
        if run(['bash', ROOT / 'fm-omp-auth-token-lib.sh', '--validate-token'], input=upstream, check=False).returncode:
            raise Failure('OMP returned an invalid bearer')
        publish(base / 'upstream.token', upstream)
        publish(base / 'facade.token', secrets.token_urlsafe(32))
        broker_process = None
        if not ready_url(settings['broker']):
            bind = settings['broker'].removeprefix('http://')
            broker_process = subprocess.Popen([settings['omp'], 'auth-broker', 'serve', '--bind=' + bind], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + timeout
        while not ready_url(settings['broker']):
            if time.monotonic() >= deadline:
                raise Failure('canonical broker unavailable')
            time.sleep(0.05)
        environment = os.environ.copy()
        environment.update(FM_OMP_AUTH_BROKER_TOKEN_FILE=str(base / 'facade.token'),
                           FM_OMP_AUTH_BROKER_UPSTREAM_TOKEN_FILE=str(base / 'upstream.token'),
                           FM_OMP_AUTH_BROKER_UPSTREAM_URL=settings['broker'],
                           FM_OMP_AUTH_BROKER_PROXY_BIND=settings['proxy'],
                           FM_BOAT_PROVIDERS=json.dumps(settings['providers']))
        facade = subprocess.Popen([settings['node'], ROOT / 'fm-omp-auth-broker-readonly-proxy.mjs'], env=environment,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        while True:
            try:
                with urllib.request.urlopen('http://' + settings['proxy'] + '/v1/healthz', timeout=1) as response:
                    if response.headers.get('x-fm-auth-broker-facade') == 'credential-read-only':
                        break
            except OSError:
                pass
            if time.monotonic() >= deadline or facade.poll() is not None:
                raise Failure('credential facade unavailable or mis-cabled')
            time.sleep(0.05)
        helper = (ROOT / 'fm-omp-auth-token-lib.sh').read_text() + '\n' + (ROOT / 'fm-boat-remote-auth.sh').read_text()
        ssh(descriptor, 'umask 077; mkdir -p /home/user/.fm && cat > /home/user/.fm/boat-auth-control && chmod 700 /home/user/.fm/boat-auth-control', input=helper, timeout=timeout)
        record['install_attempted'] = '1'
        save(path, record)
        ssh(descriptor, '/home/user/.fm/boat-auth-control', '--install', input=regular(base / 'facade.token', 0o600).read_text(), timeout=timeout)
        tunnel_args = [descriptor['ssh'], '-N', '-T', '-o', 'BatchMode=yes', '-o', 'ExitOnForwardFailure=yes',
                       '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3', '-F', descriptor['config'],
                       '-R', settings['remote'] + ':' + settings['proxy'], descriptor['alias']]
        tunnel = subprocess.Popen(tunnel_args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ssh(descriptor, '/home/user/.fm/boat-auth-control', '--check', timeout=timeout)
        record.update(state='ready', cgroup=properties(record['unit']).get('ControlGroup', ''))
        save(path, record)
    # All respawns remain in this same service cgroup. The parent never signals
    # child PIDs, including on failure; systemd's stop handles descendants.
    while True:
        if facade.poll() is not None:
            raise Failure('credential facade exited')
        if tunnel.poll() is not None:
            tunnel = subprocess.Popen(tunnel_args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # A canonical broker started by another lease may disappear with that
        # lease. The surviving service restores it inside its own cgroup.
        if broker_process is not None:
            broker_process.poll()
        if not ready_url(settings['broker']) and (broker_process is None or broker_process.poll() is not None):
            broker_process = subprocess.Popen([settings['omp'], 'auth-broker', 'serve', '--bind=' + settings['broker'].removeprefix('http://')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.2)
