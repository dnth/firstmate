#!/usr/bin/env -S uv run --no-project python3
"""Boat secondmate compute owner, not a worker/session backend.

Public shell entry points own the existing delivery/reply guards. This module
owns create/wake compensation, stable SSH trust and credential-before-stop
ordering. Records contain no credentials. Each transition holds kernel flock.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import sys
import secrets
import time

from fm_boat_common import (CONFIG, DATA, HOME, ROOT, STATE, Failure, directory,
                            load, lock, policy, publish, regular, run, safe_id, save, ssh)
import fm_boat_auth as auth

BOAT = os.environ.get('FM_BOAT_BIN', str(Path.home() / '.ascii/bin/boat'))
CURL = os.environ.get('FM_BOAT_CURL_BIN', 'curl')
TIMEOUT = float(os.environ.get('FM_BOAT_WAKE_TIMEOUT', '900'))
POLL = float(os.environ.get('FM_BOAT_POLL_INTERVAL', '2'))
RATES = {'small': .018, 'default': .036, 'large': .072, 'xlarge': .200}

def record_path(id):
    return DATA / 'boat' / (safe_id(id) + '.meta')

def record(id):
    rows = load(record_path(id))
    if not rows or rows.get('provider') != 'boat':
        raise Failure('secondmate has no valid Boat placement')
    if (DATA / 'runpod' / (id + '.meta')).exists():
        raise Failure('contradictory Boat and RunPod ownership')
    return rows

def write(id, rows):
    rows['updated'] = str(int(time.time()))
    save(record_path(id), rows)

def cli(*args):
    result = run([BOAT, *args], timeout=TIMEOUT)
    objects = []
    for line in result.stdout.splitlines():
        try:
            obj = json.loads(line)
            if isinstance(obj, dict):
                objects.append(obj)
        except ValueError:
            continue
    if not objects and args[0] in ('new', 'info'):
        raise Failure('Boat returned no valid JSON response')
    return objects[-1] if objects else {}

def info(box):
    body = cli('info', box, '--json')
    nested = body.get('sandbox')
    body = nested if nested is not None else body
    if not isinstance(body, dict) or body.get('id') != box or not isinstance(body.get('state'), str):
        raise Failure('Boat inspection returned an invalid sandbox identity')
    return body

def api(method, box, body):
    override = os.environ.get('FM_BOAT_CONFIG_FILE')
    if override is not None:
        candidates = [Path(override).expanduser()]
    else:
        config = Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config')
        candidates = [config / 'ascii' / name / 'config.json' for name in ('boat', 'box')]
    keyfile = next((path for path in candidates if path.exists() or path.is_symlink()), None)
    if keyfile is None:
        raise Failure('Boat CLI config unavailable; tried: ' + ', '.join(map(str, candidates))
                      + '; authenticate with boat login or set FM_BOAT_CONFIG_FILE')
    config_body = json.loads(regular(keyfile, 0o600).read_text())
    if not isinstance(config_body, dict):
        raise Failure('Boat API credential unavailable')
    token = config_body.get('token', '')
    if not isinstance(token, str) or not re.fullmatch(r'[A-Za-z0-9._~-]{8,}', token):
        raise Failure('Boat API credential unavailable')
    url = os.environ.get('FM_BOAT_API_BASE', 'https://boat.dev/api/v1') + '/sandboxes/' + box
    if method == 'POST':
        url += '/sshkey'
    # stdin config, not argv/logs. CLI output and HTTP bodies are never echoed.
    config = f'silent\nfail\nmax-time = "30"\nrequest = "{method}"\nurl = "{url}"\nheader = "Authorization: Bearer {token}"\nheader = "Content-Type: application/json"\n'
    config += 'data = ' + json.dumps(json.dumps(body)) + '\n'
    response = json.loads(run([CURL, '--config', '-'], input=config).stdout)
    if not isinstance(response, dict):
        raise Failure('Boat API returned an invalid object response')
    return response

def stopped(rows):
    state = info(rows['sandbox_id'])['state']
    if state in ('archived', 'stopped'):
        rows['provider_state'] = state
        return
    cli('stop', rows['sandbox_id'], '--json')
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        state = info(rows['sandbox_id'])['state']
        if state in ('archived', 'stopped'):
            rows['provider_state'] = state
            return
        time.sleep(POLL)
    raise Failure('sandbox stop was not confirmed')

def wake_ttl(rows):
    if 'smoke_deadline' not in rows:
        return int(rows['ttl'])
    remaining = int(float(rows['smoke_deadline']) - time.time())
    if remaining < 1:
        raise Failure('live smoke absolute sandbox-hour deadline exhausted')
    return min(int(rows['ttl']), remaining)


def compensate(id, rows, cause):
    failures = []
    cleanup = 'credentials not requested'
    if rows.get('omp_auth') == '1':
        try:
            auth.release(id)
            cleanup = load(auth.paths(id)[1])['cleanup']
        except (Failure, OSError, ValueError) as error:
            failures.append(str(error))
    try:
        stopped(rows)
    except (Failure, OSError, ValueError) as error:
        failures.append(str(error))
    rows['lifecycle'] = 'unresolved' if failures else ('suspended' if rows.get('ever_ready') == '1' else 'provisioned')
    rows['cleanup'] = '; '.join(failures) if failures else cleanup + '; provider stop confirmed'
    write(id, rows)
    raise Failure(str(cause) + ('; compensation unresolved: ' + rows['cleanup'] if failures else '; compensation confirmed'))

def unknown_allocation(id, rows, cause):
    rows['lifecycle'] = 'unresolved'
    rows['cleanup'] = 'allocation-unknown'
    write(id, rows)
    raise Failure(str(cause) + '; billable sandbox may exist; inspect Boat by creation time before retrying')

def provision(args):
    id = safe_id(args.id)
    policy(args.model)  # Before any billable creation, including non-OMP routes.
    if args.omp_auth:
        auth.substrate()
    if not 1 <= args.ttl <= 2592000:
        raise Failure('TTL must be finite, 1 through 2592000 seconds')
    identity = regular(Path(args.identity).expanduser()).resolve()
    public = regular(str(identity) + '.pub').read_text().strip()
    if not re.fullmatch(r'ssh-[A-Za-z0-9-]+ [A-Za-z0-9+/=]+(?: [^\r\n]+)?', public):
        raise Failure('SSH public key is invalid')
    alias = safe_id(args.alias or 'boat-' + id)
    directory(DATA / 'boat')
    with lock(STATE / '.boat-placement.lock'):
        if record_path(id).exists() or (DATA / 'runpod' / (id + '.meta')).exists():
            raise Failure('secondmate placement already exists')
        for path in (DATA / 'boat').glob('*.meta'):
            if load(path).get('ssh_alias') == alias:
                raise Failure('SSH alias already belongs to another secondmate')
        rows = dict(schema='fm-boat-secondmate.v1', provider='boat', secondmate=id,
                    lifecycle='pending-allocation', ever_ready='0', ssh_alias=alias,
                    ssh_identity=str(identity), model=args.model, size=args.size, ttl=str(args.ttl),
                    omp_auth='1' if args.omp_auth else '0', host_key_verified='0', cost_per_hr=str(RATES[args.size]),
                    name=args.prefix + id, allocation_started=str(int(time.time())))
        if hasattr(args, 'smoke_deadline'):
            rows['smoke_deadline'] = str(args.smoke_deadline)
        write(id, rows)
        try:
            body = cli('new', '--json', '--no-env', '--type', args.size, '--ttl', str(args.ttl))
        except (Failure, OSError, ValueError, KeyError) as error:
            unknown_allocation(id, rows, error)
        nested = body.get('sandbox')
        box = body.get('id') or (nested.get('id') if isinstance(nested, dict) else None)
        if not isinstance(box, str) or not re.fullmatch(r'bx_[A-Za-z0-9]+', box):
            unknown_allocation(id, rows, 'created sandbox identity is unknown')
        rows.update(sandbox_id=box, lifecycle='provisioned')
        # Publish allocation before the first fallible customization.
        write(id, rows)
        try:
            api('PATCH', box, {'name': args.prefix + id, 'ttlSeconds': args.ttl})
            api('POST', box, {'key': public})
            stopped(rows)
            write(id, rows)
        except (Failure, OSError, ValueError) as error:
            compensate(id, rows, error)
    print('provisioned: ' + id)

def descriptor(rows):
    return {'ssh': os.environ.get('FM_BOAT_SSH_BIN', os.environ.get('FM_SSH_BIN', 'ssh')),
            'alias': rows['ssh_alias'], 'config': str(CONFIG / 'boat' / 'ssh.d' / (rows['ssh_alias'] + '.conf'))}

def endpoint(rows):
    public = regular(rows['ssh_identity'] + '.pub').read_text().strip()
    reply = api('POST', rows['sandbox_id'], {'key': public})
    host = reply.get('machineIp')
    port = 22
    endpoint = reply.get('sshEndpoint')
    if endpoint is not None:
        if not isinstance(endpoint, str) or ':' not in endpoint:
            raise Failure('invalid fresh SSH endpoint')
        host, port_text = endpoint.rsplit(':', 1)
        host = host.strip('[]'); port = int(port_text)
    key = reply.get('hostKey')
    if not isinstance(host, str) or not re.fullmatch(r'[A-Za-z0-9:.%-]+', host) or not 1 <= port <= 65535:
        raise Failure('invalid fresh SSH endpoint')
    if not isinstance(key, str) or not re.fullmatch(r'ssh-[A-Za-z0-9-]+ [A-Za-z0-9+/=]+', key):
        raise Failure('provider host key unavailable')
    # API key may be transient at boot. A VERIFIED key is never changed.
    pinned = rows.get('host_key') if rows.get('host_key_verified') == '1' else key
    if not pinned:
        raise Failure('verified SSH pin missing')
    state_dir = directory(CONFIG / 'boat')
    known = state_dir / (rows['ssh_alias'] + '.known_hosts')
    publish(known, rows['ssh_alias'] + ' ' + pinned + '\n')
    desc = descriptor(rows)
    quoted_known = str(known).replace('"', '\\"')
    quoted_identity = rows['ssh_identity'].replace('"', '\\"')
    publish(desc['config'], f'Host {desc["alias"]}\n  HostName {host}\n  Port {port}\n  User user\n  HostKeyAlias {desc["alias"]}\n  UserKnownHostsFile "{quoted_known}"\n  StrictHostKeyChecking yes\n  ForwardAgent no\n  IdentityFile "{quoted_identity}"\n  IdentitiesOnly yes\n')
    rows.update(endpoint_host=host, endpoint_port=str(port))
    return desc, pinned

def persist_hostkey(desc):
    # Stash FIRST. Only a complete persistence install permits verified=1.
    # Resume restores over the API-owned exec channel before pinned SSH probes.
    script = 'set -e; sudo mkdir -p /var/lib/fm/hostkeys; sudo install -m 600 /etc/ssh/ssh_host_ed25519_key /var/lib/fm/hostkeys/; sudo install -m 644 /etc/ssh/ssh_host_ed25519_key.pub /var/lib/fm/hostkeys/'
    ssh(desc, 'sh -s', input=script + '\n')

def wake(id):
    with lock(STATE / ('.boat-lifecycle-' + safe_id(id) + '.lock')):
        rows = record(id)
        policy(rows['model'])
        try:
            if rows['lifecycle'] == 'ready' and info(rows['sandbox_id'])['state'] in ('ready', 'running', 'idle'):
                if rows['omp_auth'] == '1':
                    desc = descriptor(rows)
                    auth.acquire(id, desc['alias'], desc['config'], rows['model'])
                reply(id, 'arm')
                return
            rows['lifecycle'] = 'waking'; write(id, rows)
            deadline = time.monotonic() + TIMEOUT
            while True:
                result = run([BOAT, 'resume', rows['sandbox_id'], '--ttl', str(wake_ttl(rows)), '--json'], timeout=TIMEOUT, check=False)
                if result.returncode == 0:
                    break
                if 'no_ready_machine' not in result.stdout + result.stderr or time.monotonic() >= deadline:
                    raise Failure('Boat resume refused')
                time.sleep(POLL)
            api('PATCH', rows['sandbox_id'], {'ttlSeconds': wake_ttl(rows)})
            if rows.get('host_key_verified') == '1':
                heal = 'set -e; test -f /var/lib/fm/hostkeys/ssh_host_ed25519_key; sudo install -m 600 /var/lib/fm/hostkeys/ssh_host_ed25519_key /etc/ssh/; sudo install -m 644 /var/lib/fm/hostkeys/ssh_host_ed25519_key.pub /etc/ssh/; sudo systemctl --no-block restart ssh.socket ssh.service'
                cli('exec', rows['sandbox_id'], '--', 'sh', '-c', heal)
            while True:
                desc, key = endpoint(rows)
                if ssh(desc, 'true', check=False).returncode == 0:
                    break
                if time.monotonic() >= deadline:
                    raise Failure('SSH did not verify the stable pin')
                time.sleep(POLL)
            if rows.get('host_key_verified') != '1':
                persist_hostkey(desc)
                rows.update(host_key=key, host_key_verified='1')
                write(id, rows)
            if rows['omp_auth'] == '1':
                auth.acquire(id, desc['alias'], desc['config'], rows['model'])
            rows.update(lifecycle='ready', ever_ready='1', cleanup='')
            write(id, rows)
            reply(id, 'arm')
            print('ready: ' + id)
        except (Failure, OSError, ValueError) as error:
            compensate(id, rows, error)

def reply(id, verb):
    # An unseeded placement has no reply source to restore.
    if (STATE / (id + '.meta')).exists():
        run([ROOT / 'fm-procevent-remote-reply.sh', verb, id])

def sleep(id, destroy=False):
    with lock(STATE / ('.boat-lifecycle-' + safe_id(id) + '.lock')):
        rows = record(id)
        before = rows['lifecycle']
        if before not in ('ready', 'provisioned', 'suspended'):
            raise Failure('unresolved compute must be reconciled before sleep or deletion')
        try:
            rows['lifecycle'] = 'suspending'; write(id, rows)
            if rows['omp_auth'] == '1':
                auth.release(id)
            stopped(rows)
            if destroy:
                cli('delete', rows['sandbox_id'], '--yes', '--json')
                record_path(id).unlink()
                print('deleted: ' + id)
                return
            rows['lifecycle'] = 'suspended' if rows['ever_ready'] == '1' else 'provisioned'
            write(id, rows)
            print('suspended: ' + id)
        except (Failure, OSError, ValueError) as error:
            rows['lifecycle'] = before; write(id, rows)
            failures = []
            available = before != 'ready'
            if before == 'ready':
                try:
                    available = info(rows['sandbox_id'])['state'] in ('ready', 'running', 'idle')
                    if not available:
                        failures.append('sandbox is stopped; explicit wake required')
                except (Failure, OSError, ValueError):
                    failures.append('sandbox availability could not be confirmed')
            if available and before == 'ready' and rows['omp_auth'] == '1':
                try:
                    desc = descriptor(rows)
                    auth.acquire(id, desc['alias'], desc['config'], rows['model'])
                except (Failure, OSError, ValueError) as failure:
                    failures.append('credential availability: ' + str(failure))
            if failures:
                rows.update(lifecycle='unresolved', cleanup='; '.join(failures)); write(id, rows)
            raise Failure(str(error) + ('; restoration incomplete: ' + '; '.join(failures) if failures else '; availability restored'))

def live_smoke(identity, model):
    if os.environ.get('FM_BOAT_LIVE') != '1':
        raise Failure('live Boat smoke requires explicit FM_BOAT_LIVE=1 approval')
    # Reserve 100 seconds below one sandbox-hour for bounded request latency.
    # Every renewal uses this original deadline, never a fresh hourly TTL.
    global TIMEOUT
    TIMEOUT = 30
    with lock(STATE / '.boat-live-smoke.lock'):
        for path in (DATA / 'boat').glob('*.meta'):
            existing = load(path)
            if existing.get('name', '').startswith('fm-boat-smoke-'):
                if existing.get('lifecycle') == 'unresolved' and existing.get('cleanup') == 'allocation-unknown':
                    raise Failure('live smoke allocation identity is unknown; inspect Boat by creation time before retrying')
                raise Failure('an earlier live smoke sandbox must be reconciled first')
        id = 'fm-boat-smoke-' + secrets.token_hex(4)
        args = argparse.Namespace(id=id, identity=identity, model=model, alias=id,
                                  size='small', ttl=3500, prefix='',
                                  omp_auth=True, smoke_deadline=time.time() + 3500)
        failure = None
        try:
            provision(args)
            wake(id)
            sleep(id)
            wake(id)
            sleep(id)
        except BaseException as error:
            failure = error
            raise
        finally:
            if record_path(id).exists():
                try:
                    sleep(id, destroy=True)
                except Exception as cleanup:
                    if failure is None:
                        raise
                    raise Failure(str(failure) + '; smoke cleanup failed: ' + str(cleanup)) from failure
        print('live smoke passed: one small sandbox, two wake/sleep cycles, stable SSH pin and checked credential retirement')


def main():
    parser = argparse.ArgumentParser(description='Boat secondmate compute and credentials; no ephemeral workers')
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('provision'); p.add_argument('id'); p.add_argument('--identity', required=True)
    p.add_argument('--model', required=True); p.add_argument('--alias'); p.add_argument('--size', choices=RATES, default='small')
    p.add_argument('--ttl', type=int, default=86400); p.add_argument('--prefix', default='fm-boat-'); p.add_argument('--omp-auth', action='store_true')
    for name in ('wake', 'sleep', 'status', 'cost', 'ssh', 'destroy'):
        p = commands.add_parser(name); p.add_argument('id')
        if name == 'destroy': p.add_argument('--yes', action='store_true', required=True)
        if name == 'ssh': p.add_argument('args', nargs=argparse.REMAINDER)
    p = commands.add_parser('auth'); p.add_argument('verb', choices=['start', 'stop', 'status']); p.add_argument('id'); p.add_argument('args', nargs='*')
    p = commands.add_parser('auth-run'); p.add_argument('base'); p.add_argument('generation')
    p = commands.add_parser('live-smoke'); p.add_argument('--identity', required=True); p.add_argument('--model', required=True)
    args = parser.parse_args()
    if args.command == 'provision': provision(args)
    elif args.command == 'live-smoke': live_smoke(args.identity, args.model)
    elif args.command == 'wake': wake(args.id)
    elif args.command in ('sleep', 'destroy'): sleep(args.id, args.command == 'destroy')
    elif args.command == 'auth-run': auth.worker(args.base, args.generation)
    elif args.command == 'auth':
        if args.verb == 'start':
            if len(args.args) != 3: raise Failure('auth start requires alias, config and model')
            auth.acquire(args.id, *args.args)
        elif args.verb == 'stop': auth.release(args.id)
        else: print(json.dumps(load(auth.paths(args.id)[1])))
    elif args.command == 'ssh':
        rows = record(args.id)
        if rows['lifecycle'] != 'ready': raise Failure('wake secondmate before SSH')
        desc, _ = endpoint(rows)
        result = ssh(desc, *args.args, check=False)
        sys.stdout.write(result.stdout); sys.stderr.write(result.stderr)
        return result.returncode
    else: print(json.dumps(record(args.id)))
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Failure, OSError, ValueError, KeyError) as error:
        print('error: ' + str(error), file=sys.stderr)
        sys.exit(1)
