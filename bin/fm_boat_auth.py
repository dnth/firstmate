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
import secrets
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
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
        try:
            run([SYSTEMCTL, '--user', 'stop', unit], timeout=TIMEOUT + 10)
        except Failure:
            # A failed worker can disappear between the state probe and stop.
            # Treat that race as retired only after confirming the unit is gone.
            if properties(unit).get('LoadState') != 'not-found':
                raise
    after = properties(unit)
    if after.get('ActiveState') not in ('inactive', 'failed'):
        raise Failure('credential service did not stop')
    if cgroup:
        if not cgroup.startswith('/user.slice/') or '..' in cgroup.split('/'):
            raise Failure('invalid credential cgroup')
        events = Path('/sys/fs/cgroup') / cgroup.lstrip('/') / 'cgroup.events'
        deadline = time.monotonic() + TIMEOUT + 10
        while events.exists() and 'populated 1' in events.read_text():
            if time.monotonic() >= deadline:
                raise Failure('credential cgroup still contains helpers')
            time.sleep(0.05)

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
                    and settings.get('model_provider') == model.split('/', 1)[0]
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
            'providers': allowed,
            'model_provider': model.split('/', 1)[0],
            'opencode_auth_file': str(Path.home() / '.local' / 'share' / 'opencode' / 'auth.json'),
            'omp': executable(os.environ.get('FM_BOAT_OMP_BIN', 'omp')),
            'node': executable(os.environ.get('FM_BOAT_NODE_BIN', 'node')),
            # A lease must not depend on a conventional port owned by another app.
            'broker': os.environ.get('FM_BOAT_BROKER_URL') or 'http://' + free_loopback(),
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
                 '--property=Type=exec',
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

OPEN_CODE_GO_PROVIDERS = (
    'opencode-go-dnth',
    'opencode-go-dnth-1',
    'opencode-go-neuralengine',
    'opencode-go-neuralengine-1',
)

def broker_request(url, token, method, path, payload=None):
    try:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port
    except ValueError:
        raise Failure('canonical broker URL is invalid') from None
    if (parsed.scheme != 'http' or parsed.hostname not in ('127.0.0.1', 'localhost', '::1') or
            not port or not 1 <= port <= 65535 or parsed.path not in ('', '/') or
            parsed.query or parsed.fragment or parsed.username or parsed.password):
        raise Failure('OpenCode Go credential import requires the loopback broker')
    data = None if payload is None else json.dumps(payload).encode()
    headers = {'Authorization': 'Bearer ' + token}
    if data is not None:
        headers['Content-Type'] = 'application/json'
    request = urllib.request.Request(url.rstrip('/') + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            if response.status != 200:
                raise Failure('canonical broker refused OpenCode Go credential operation')
            body = response.read(4_000_000)
        value = json.loads(body)
    except Failure:
        raise
    except (OSError, ValueError, urllib.error.URLError):
        raise Failure('canonical broker unavailable for OpenCode Go credentials') from None
    if not isinstance(value, dict):
        raise Failure('canonical broker returned an invalid OpenCode Go response')
    return value

def api_key_entries(snapshot, provider=None):
    credentials = snapshot.get('credentials')
    if not isinstance(credentials, list):
        raise Failure('canonical broker returned an invalid credential snapshot')
    return [entry for entry in credentials
            if isinstance(entry, dict) and (provider is None or entry.get('provider') == provider) and
            isinstance(entry.get('id'), int) and not isinstance(entry.get('id'), bool) and
            0 <= entry['id'] <= 9007199254740991 and
            isinstance(entry.get('credential'), dict) and
            entry['credential'].get('type') == 'api_key' and
            isinstance(entry['credential'].get('key'), str)]

def credential_id_map(path):
    if not path.exists() and not path.is_symlink():
        return {}
    try:
        value = json.loads(regular(path, 0o600).read_text())
    except (OSError, ValueError, Failure):
        raise Failure('OpenCode Go credential ownership record is unsafe') from None
    if not isinstance(value, dict) or any(provider not in OPEN_CODE_GO_PROVIDERS for provider in value):
        raise Failure('OpenCode Go credential ownership record is invalid')
    for item in value.values():
        if (not isinstance(item, dict) or not isinstance(item.get('id'), int) or
                isinstance(item.get('id'), bool) or not 0 <= item['id'] <= 9007199254740991 or
                not isinstance(item.get('owned'), bool)):
            raise Failure('OpenCode Go credential ownership record is invalid')
    return value

def source_auth(path, required):
    try:
        value = json.loads(regular(path, 0o600).read_text())
        if not isinstance(value, dict):
            raise ValueError
        return value
    except (OSError, ValueError, Failure):
        if required:
            raise Failure('selected OpenCode Go credential source is unavailable or invalid') from None
        return None

def sync_opencode_go_credentials(base, broker, token, allowed, model_provider, auth_path):
    allowed = set(allowed)
    go_allowed = [provider for provider in OPEN_CODE_GO_PROVIDERS if provider in allowed]
    required = model_provider if model_provider in go_allowed else None
    ownership_path = base / 'opencode-go-credential-ids.json'
    ownership = credential_id_map(ownership_path)
    auth = source_auth(auth_path, required is not None) if go_allowed else None
    source_keys = {}
    if auth is not None:
        for provider in go_allowed:
            source = auth.get(provider)
            key = source.get('key') if isinstance(source, dict) and source.get('type') == 'api_key' else None
            if not isinstance(key, str) or not key.strip():
                if provider == required:
                    raise Failure('selected OpenCode Go account key is unavailable')
                continue
            source_keys[provider] = key
    selected = {}
    if source_keys:
        snapshot = broker_request(broker, token, 'GET', '/v1/snapshot')
        for provider, key in source_keys.items():
            active = api_key_entries(snapshot, provider)
            previous = ownership.get(provider)
            tracked = next((entry for entry in active if entry['id'] == previous['id']), None) if previous else None
            if tracked and tracked['credential']['key'] == key:
                selected[provider] = tracked['id']
                continue
            matches = [entry for entry in active if entry['credential']['key'] == key]
            if matches:
                chosen = min(matches, key=lambda entry: entry['id'])
                if tracked and previous['owned'] and tracked['id'] != chosen['id']:
                    broker_request(broker, token, 'POST', f"/v1/credential/{tracked['id']}/disable",
                                   {'cause': 'replaced by current OpenCode auth.json key'})
                selected[provider] = chosen['id']
                ownership[provider] = {'id': chosen['id'], 'owned': bool(previous and previous['id'] == chosen['id'] and previous['owned'])}
                continue
            uploaded = broker_request(broker, token, 'POST', '/v1/credential',
                                      {'provider': provider, 'credential': {'type': 'api_key', 'key': key}})
            entries = api_key_entries({'credentials': uploaded.get('entries')}, provider)
            matches = [entry for entry in entries if entry['credential']['key'] == key]
            if not matches:
                raise Failure('canonical broker did not retain the OpenCode Go account key')
            chosen = min(matches, key=lambda entry: entry['id'])
            if tracked and previous['owned']:
                broker_request(broker, token, 'POST', f"/v1/credential/{tracked['id']}/disable",
                               {'cause': 'replaced by current OpenCode auth.json key'})
            selected[provider] = chosen['id']
            ownership[provider] = {'id': chosen['id'], 'owned': True}
        publish(ownership_path, json.dumps(ownership, sort_keys=True))
    if required and required not in selected:
        raise Failure('selected OpenCode Go account key is unavailable')
    snapshot = broker_request(broker, token, 'GET', '/v1/snapshot')
    ids = []
    for entry in api_key_entries(snapshot):
        provider = entry.get('provider')
        if provider not in allowed:
            continue
        if provider in OPEN_CODE_GO_PROVIDERS and selected.get(provider) != entry['id']:
            continue
        ids.append(entry['id'])
    return sorted(set(ids))


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
        api_key_credential_ids = sync_opencode_go_credentials(
            base, settings['broker'], upstream, settings['providers'], settings['model_provider'],
            Path(settings['opencode_auth_file']))
        environment = os.environ.copy()
        environment.update(FM_OMP_AUTH_BROKER_TOKEN_FILE=str(base / 'facade.token'),
                           FM_OMP_AUTH_BROKER_UPSTREAM_TOKEN_FILE=str(base / 'upstream.token'),
                           FM_OMP_AUTH_BROKER_UPSTREAM_URL=settings['broker'],
                           FM_OMP_AUTH_BROKER_PROXY_BIND=settings['proxy'],
                           FM_BOAT_PROVIDERS=json.dumps(settings['providers']),
                           FM_BOAT_API_KEY_CREDENTIAL_IDS=json.dumps(api_key_credential_ids))
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
        remote_helper = (ROOT / 'fm-boat-remote-omp.py').read_text()
        ssh(descriptor, 'umask 077; mkdir -p /home/user/.fm && cat > /home/user/.fm/boat-omp-remote.py && chmod 700 /home/user/.fm/boat-omp-remote.py', input=remote_helper, timeout=timeout)
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
        # With a shared-broker override, another lease's broker may disappear
        # with that lease. Restore it inside the surviving service's cgroup.
        if broker_process is not None:
            broker_process.poll()
        if not ready_url(settings['broker']) and (broker_process is None or broker_process.poll() is not None):
            broker_process = subprocess.Popen([settings['omp'], 'auth-broker', 'serve', '--bind=' + settings['broker'].removeprefix('http://')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.2)
