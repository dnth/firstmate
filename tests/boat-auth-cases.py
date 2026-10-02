#!/usr/bin/env -S uv run --no-project python3
"""Real cgroup custody, fake SSH/OMP/Boat credentials, real scoped facade."""
import contextlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(sys.argv.pop(1)).resolve()
AUTH = ROOT / 'bin/fm-boat-omp-auth.sh'
BASE = Path(tempfile.mkdtemp(prefix='fm-boat-auth-'))
ENV_ENTRY = {'generation': 1, 'generatedAt': 1, 'serverNowMs': 1,
             'refresher': {'enabled': True, 'intervalMs': 100, 'skewMs': 100, 'nextSweepInMs': 100}}
ENTRY = {'provider': 'openai-codex', 'id': 2, 'identityKey': 'must-not-egress', 'rotatesInMs': 99,
         'credential': {'type': 'oauth', 'access': 'fixture_access', 'expires': 4102444800000,
                        'refresh': 'upstream-refresh-must-not-egress', 'key': 'upstream-api-key'}}

def rows(path):
    return dict(line.split('=', 1) for line in path.read_text().splitlines())

def wait_for(predicate, seconds=12):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate(): return
        time.sleep(.05)
    raise AssertionError('fixture condition did not become true')

def helper_alive(identity):
    pid, starttime = identity.split()
    proc = Path('/proc') / pid / 'stat'
    try:
        fields = proc.read_text().split(') ', 1)[1].split()
    except FileNotFoundError:
        return False
    return fields[0] != 'Z' and fields[19] == starttime

def blocked_on(path):
    inode = str(path.stat().st_ino)
    return any('->' in line and line.split()[-3].endswith(':' + inode)
               for line in Path('/proc/locks').read_text().splitlines())

class Lab:
    def __init__(self):
        self.path = Path(tempfile.mkdtemp(dir=BASE))
        self.home = self.path / 'home'; self.home.mkdir()
        self.fake = self.path / 'fakebin'; self.fake.mkdir()
        for tool in ('ssh', 'omp', 'boat', 'curl'):
            (self.fake / tool).symlink_to(ROOT / 'tests/boat-fixture.py')
        self.config = self.path / 'ssh.conf'
        self.config.write_text('Host fixture\n'); self.config.chmod(0o600)
        self.state = {'state': 'archived', 'key': 'ssh-ed25519 Zml4dHVyZQ==', 'ip': '127.0.0.1', 'fail': []}
        self.update()
        self.payload = dict(ENV_ENTRY, credentials=[ENTRY]); self.refresh = dict(ENV_ENTRY, entry=ENTRY)
        self.status = 200; self.health_status = 200; self.refresh_calls = 0; self.streams = []
        lab = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                if self.path.endswith('/stream'):
                    self.send_response(200); self.send_header('content-type', 'text/event-stream'); self.end_headers()
                    lab.streams.append(self)
                    try:
                        self.wfile.write(('data: ' + json.dumps(dict(lab.payload, kind='snapshot')) + '\n\n').encode()); self.wfile.flush()
                        while not lab.end.is_set(): time.sleep(.05)
                    except (BrokenPipeError, ConnectionResetError): pass
                    return
                body = {'ok': True, 'version': '18.4.4'} if self.path.endswith('healthz') else lab.payload
                self.send_response(lab.health_status if self.path.endswith('healthz') else 200)
                self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(json.dumps(body).encode())
            def do_POST(self):
                lab.refresh_calls += 1
                self.send_response(lab.status); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(json.dumps(lab.refresh).encode())
        self.end = threading.Event()
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever); self.thread.start()
        # Bind an ephemeral port just long enough to choose this isolated facade.
        import socket
        with socket.socket() as socket:
            socket.bind(('127.0.0.1', 0)); self.proxy_port = socket.getsockname()[1]
        self.env = dict(os.environ, FM_HOME=str(self.home), FM_BOAT_SSH_BIN=str(self.fake / 'ssh'),
                        FM_DATA_OVERRIDE=str(self.home / 'data'), FM_STATE_OVERRIDE=str(self.home / 'state'),
                        FM_CONFIG_OVERRIDE=str(self.home / 'config'),
                        FM_BOAT_OMP_BIN=str(self.fake / 'omp'), FM_BOAT_BROKER_URL=f'http://127.0.0.1:{self.server.server_port}',
                        FM_BOAT_PROXY_BIND=f'127.0.0.1:{self.proxy_port}', FM_BOAT_AUTH_TIMEOUT='3')
        self.lease = self.home / 'state/boat-omp-auth/mate/lease.meta'
    def update(self, **changes):
        path = self.path / 'provider.json'
        if path.exists():
            self.state = json.loads(path.read_text())
        self.state.update(changes); path.write_text(json.dumps(self.state))
    def call(self, verb, *args, ok=True):
        result = subprocess.run([AUTH, verb, 'mate', *args], env=self.env, capture_output=True, text=True, timeout=25)
        if ok and result.returncode: raise AssertionError(result.stderr)
        if not ok and not result.returncode: raise AssertionError('operation unexpectedly succeeded')
        return result
    def start(self, ok=True):
        return self.call('start', 'fixture', str(self.config), 'openai-codex/fixture', ok=ok)
    def request(self, path='/v1/snapshot', method='GET', bearer=None):
        if bearer is None: bearer = (self.path / 'remote/omp-auth-broker.token').read_text()
        request = urllib.request.Request(f'http://127.0.0.1:{self.proxy_port}' + path, method=method,
                                        headers={'Authorization': 'Bearer ' + bearer}, data=b'' if method == 'POST' else None)
        with urllib.request.urlopen(request, timeout=3) as response: return json.load(response)
    def clean(self):
        self.update(fail=[])
        if self.lease.exists(): self.call('stop')
        for path in self.home.glob('state/boat-omp-auth/*/lease.meta'):
            unit = rows(path).get('unit')
            if unit:
                output = subprocess.check_output(['systemctl', '--user', 'show', unit, '-p', 'ActiveState'], text=True)
                if output.strip() != 'ActiveState=inactive': raise AssertionError('service survived fixture cleanup: ' + output)
        if (self.path / 'helpers').exists():
            for identity in (self.path / 'helpers').read_text().splitlines():
                if helper_alive(identity):
                    raise AssertionError('helper survived release: ' + identity)
        self.end.set(); self.server.shutdown(); self.server.server_close(); self.thread.join()

class CredentialTests(unittest.TestCase):
    def setUp(self): self.lab = Lab()
    def tearDown(self): self.lab.clean()
    def test_failure_matrix_and_shred_before_delete(self):
        for failure in ('token', 'invalid-token', 'stage', 'install', 'check', 'tunnel'):
            with self.subTest(failure=failure):
                self.lab.update(fail=[failure]); self.lab.start(ok=False)
                state = rows(self.lab.lease)
                self.assertEqual(state['state'], 'retired')
                self.assertFalse((self.lab.path / 'remote/omp-auth-broker.token').exists())
                self.lab.update(fail=[])
        self.lab.start(); self.lab.update(fail=['shred']); self.lab.call('stop', ok=False)
        self.assertEqual(rows(self.lab.lease)['state'], 'unresolved')
        self.assertIn('bearer unshredded', rows(self.lab.lease)['cleanup'])
        self.assertTrue((self.lab.path / 'remote/omp-auth-broker.token').exists())
        self.assertFalse((self.lab.lease.parent / 'facade.token').exists())
    def test_service_broker_and_facade_partial_acquisition_failures(self):
        self.lab.health_status = 503
        self.lab.start(ok=False)
        self.assertEqual(rows(self.lab.lease)['state'], 'retired')
        self.assertFalse((self.lab.path / 'remote/omp-auth-broker.token').exists())
        self.lab.health_status = 200
        node = self.lab.path / 'refusing-facade'
        node.write_text('#!/usr/bin/env -S uv run --no-project python3\nimport os,sys\nif sys.argv[1].endswith("fm-omp-auth-broker-readonly-proxy.mjs"): sys.exit(1)\nos.execv("' + subprocess.check_output(['which', 'node'], text=True).strip() + '",["node",*sys.argv[1:]])\n')
        node.chmod(0o700); self.lab.env['FM_BOAT_NODE_BIN'] = str(node)
        self.lab.start(ok=False)
        self.assertEqual(rows(self.lab.lease)['state'], 'retired')
        self.assertFalse((self.lab.path / 'remote/omp-auth-broker.token').exists())
        self.lab.env.pop('FM_BOAT_NODE_BIN')
        launch = self.lab.path / 'refusing-service'
        launch.write_text('#!/bin/sh\nexit 1\n'); launch.chmod(0o700)
        self.lab.env['FM_BOAT_SYSTEMD_RUN_BIN'] = str(launch)
        self.lab.start(ok=False)
        self.assertEqual(rows(self.lab.lease)['state'], 'retired')
        self.assertFalse((self.lab.path / 'remote/omp-auth-broker.token').exists())
        self.lab.env.pop('FM_BOAT_SYSTEMD_RUN_BIN')
    def test_worker_crash_before_token_consumption_is_retired(self):
        self.lab.update(token_barrier=True)
        parent = subprocess.Popen([AUTH, 'start', 'mate', 'fixture', str(self.lab.config), 'openai-codex/fixture'],
                                  env=self.lab.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for(lambda: (self.lab.path / 'token-waiting').exists())
            unit = rows(self.lab.lease)['unit']
            subprocess.run(['systemctl', '--user', 'kill', '--kill-who=all', '--signal=KILL', unit], check=True)
            parent.communicate(timeout=15)
            self.assertNotEqual(parent.returncode, 0)
            self.assertEqual(rows(self.lab.lease)['state'], 'retired')
            self.assertFalse((self.lab.path / 'remote/omp-auth-broker.token').exists())
        finally:
            if parent.poll() is None:
                parent.kill(); parent.wait()
            parent.communicate()
    def test_missing_descriptor_is_unresolved(self):
        self.lab.start()
        record = rows(self.lab.lease); record.pop('descriptor')
        self.lab.lease.write_text(''.join(k + '=' + v + '\n' for k, v in record.items()))
        result = self.lab.call('stop', ok=False)
        self.assertIn('descriptor missing', result.stderr)
        self.assertIn('bearer unshredded', result.stderr)
        self.assertEqual(rows(self.lab.lease)['state'], 'unresolved')
        # Restore the real descriptor so test cleanup can prove shred.
        record = rows(self.lab.lease)
        record['descriptor'] = json.dumps({'ssh': str(self.lab.fake / 'ssh'), 'alias': 'fixture', 'config': str(self.lab.config)})
        self.lab.lease.write_text(''.join(k + '=' + v + '\n' for k, v in record.items()))
    def test_exact_scoped_egress_and_refresh_admission(self):
        self.lab.payload['extra'] = 'upstream-top-level-secret'
        self.lab.payload['credentials'] += [{'provider': 'anthropic', 'id': 9, 'credential': ENTRY['credential']},
                                             {'provider': 'openai-codex', 'id': 3, 'credential': {'type': 'api_key', 'key': 'reserved'}},
                                             {'provider': 'openai-codex', 'id': 4, 'credential': {'type': 'oauth', 'access': 'a'}}]
        self.lab.start()
        out = self.lab.request()
        expected = {'provider': 'openai-codex', 'id': 2, 'identityKey': None, 'rotatesInMs': None,
                    'credential': {'type': 'oauth', 'access': 'fixture_access', 'expires': 4102444800000, 'refresh': '__remote__'}}
        self.assertEqual(out, dict(ENV_ENTRY, credentials=[expected]))
        self.assertEqual(self.lab.request('/v1/credential/2/refresh', 'POST')['entry'], expected)
        from urllib.error import HTTPError
        with self.assertRaises(HTTPError) as failure: self.lab.request('/v1/credential/9/refresh', 'POST')
        self.assertEqual(failure.exception.code, 403); self.assertEqual(self.lab.refresh_calls, 1)
        for expiry in (None, '4102444800000'):
            self.lab.payload = dict(ENV_ENTRY, credentials=[dict(ENTRY, credential=dict(ENTRY['credential'], expires=expiry))])
            self.assertEqual(self.lab.request()['credentials'], [])
        self.lab.payload = {'unknown': 'secret'}
        with self.assertRaises(HTTPError) as failure: self.lab.request()
        self.assertEqual(failure.exception.code, 502)
        self.lab.payload = dict(ENV_ENTRY, credentials=[ENTRY])
        self.lab.status = 500; self.lab.refresh = {'refresh_token': 'never-egress'}
        with self.assertRaises(HTTPError) as failure: self.lab.request('/v1/credential/2/refresh', 'POST')
        self.assertEqual(failure.exception.code, 502)
        self.lab.status = 200
        with self.assertRaises(HTTPError) as failure: self.lab.request('/v1/credential/2/refresh', 'POST')
        self.assertEqual(failure.exception.code, 502)
    def test_token_deletion_revokes_cached_authorization(self):
        self.lab.start(); bearer = (self.lab.path / 'remote/omp-auth-broker.token').read_text()
        self.lab.request(bearer=bearer)
        (self.lab.lease.parent / 'facade.token').unlink()
        from urllib.error import HTTPError
        with self.assertRaises(HTTPError) as failure: self.lab.request(bearer=bearer)
        self.assertEqual(failure.exception.code, 401)
    def test_dead_leader_setsid_escape_remains_in_cgroup(self):
        self.lab.update(escape=True); self.lab.start()
        helpers = self.lab.path / 'helpers'
        wait_for(lambda: helpers.exists() and len(helpers.read_text().splitlines()) >= 2)
        leader, escapee = helpers.read_text().splitlines()[:2]
        wait_for(lambda: not helper_alive(leader))
        self.assertTrue(helper_alive(escapee))
        unit = rows(self.lab.lease)['unit']
        cgroup = subprocess.check_output(['systemctl', '--user', 'show', unit, '-p', 'ControlGroup', '--value'], text=True).strip()
        self.assertIn(cgroup, (Path('/proc') / escapee.split()[0] / 'cgroup').read_text())
        self.lab.call('stop')
        self.assertFalse(helper_alive(escapee))
        self.assertEqual(rows(self.lab.lease)['state'], 'retired')
        self.assertFalse((self.lab.path / 'remote/omp-auth-broker.token').exists())
    def test_stale_pid_identity_cannot_select_stranger_or_descendant(self):
        childfile = self.lab.path / 'stranger-child'
        stranger = subprocess.Popen(['bash', '-c',
            'sleep 60 & child=$!; trap \'kill "$child"; wait "$child"; exit\' TERM; printf "%s" "$child" > "$1"; wait "$child"',
            '_', str(childfile)])
        try:
            wait_for(childfile.exists)
            kid = childfile.read_text()
            self.lab.start()
            record = rows(self.lab.lease)
            # Exact r4 identity ambiguity: live PID, mismatched recorded starttime.
            # These obsolete fields have no signaling authority in the new substrate.
            record.update(pid=str(stranger.pid), starttime='0', descendants=kid)
            self.lab.lease.write_text(''.join(k + '=' + v + '\n' for k, v in record.items()))
            self.lab.call('stop')
            self.assertIsNone(stranger.poll())
            self.assertNotEqual((Path('/proc') / kid / 'stat').read_text().split(') ', 1)[1][0], 'Z')
            self.assertEqual(rows(self.lab.lease)['state'], 'retired')
            self.assertFalse((self.lab.path / 'remote/omp-auth-broker.token').exists())
        finally:
            stranger.terminate(); stranger.wait(timeout=5)
    def test_acquisition_owner_crash_cannot_leave_late_installer(self):
        self.lab.update(install_barrier=True)
        parent = subprocess.Popen([AUTH, 'start', 'mate', 'fixture', str(self.lab.config), 'openai-codex/fixture'], env=self.lab.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(lambda: (self.lab.path / 'installer-waiting').exists())
        parent.kill(); parent.wait()
        # Acquisition has a bounded transport deadline. Release then stops its
        # cgroup before shredding, even though the calling start process died.
        self.lab.call('stop')
        (self.lab.path / 'installer-go').touch()
        time.sleep(.2)
        self.assertFalse((self.lab.path / 'remote/omp-auth-broker.token').exists())
        self.assertEqual(rows(self.lab.lease)['state'], 'retired')
    def test_preclaim_service_request_after_release_is_generation_fenced(self):
        shim = self.lab.path / 'delayed-systemd-run'
        shim.write_text('#!/usr/bin/env -S uv run --no-project python3\nimport os,sys,time\nfrom pathlib import Path\np=Path(__file__).parent\n(p/"request-waiting").touch()\nwhile not (p/"request-go").exists(): time.sleep(.05)\nos.execv("/usr/bin/systemd-run",["systemd-run",*sys.argv[1:]])\n')
        shim.chmod(0o700); self.lab.env['FM_BOAT_SYSTEMD_RUN_BIN'] = str(shim)
        parent = subprocess.Popen([AUTH, 'start', 'mate', 'fixture', str(self.lab.config), 'openai-codex/fixture'], env=self.lab.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(lambda: (self.lab.path / 'request-waiting').exists())
        parent.kill(); parent.wait()
        self.lab.call('stop')
        self.assertEqual(rows(self.lab.lease)['state'], 'retired')
        (self.lab.path / 'request-go').touch()
        unit = rows(self.lab.lease)['unit']
        wait_for(lambda: 'ActiveState=active' in subprocess.check_output(['systemctl', '--user', 'show', unit, '-p', 'ActiveState'], text=True))
        self.assertFalse((self.lab.path / 'remote/omp-auth-broker.token').exists())
        self.assertFalse((self.lab.path / 'helpers').exists())
        self.lab.call('stop')
    def test_retire_failure_is_surfaced_without_dropping_custody(self):
        self.lab.start(); unit = rows(self.lab.lease)['unit']
        shim = self.lab.path / 'refusing-systemctl'
        shim.write_text('#!/usr/bin/env -S uv run --no-project python3\nimport os,sys\nif "stop" in sys.argv: sys.exit(1)\nos.execv("/usr/bin/systemctl",["systemctl",*sys.argv[1:]])\n')
        shim.chmod(0o700); self.lab.env['FM_BOAT_SYSTEMCTL_BIN'] = str(shim)
        self.lab.call('stop', ok=False)
        state = rows(self.lab.lease)
        self.assertEqual(state['state'], 'unresolved'); self.assertEqual(state['unit'], unit)
        self.assertIn('bearer unshredded', state['cleanup'])
        self.assertTrue((self.lab.path / 'remote/omp-auth-broker.token').exists())
        self.lab.env.pop('FM_BOAT_SYSTEMCTL_BIN'); self.lab.call('stop')
    def test_concurrent_stream_removals_have_independent_membership(self):
        self.lab.start()
        bearer = (self.lab.path / 'remote/omp-auth-broker.token').read_text()
        connections = []
        try:
            for _ in range(2):
                request = urllib.request.Request(f'http://127.0.0.1:{self.lab.proxy_port}/v1/snapshot/stream', headers={'Authorization': 'Bearer ' + bearer})
                response = urllib.request.urlopen(request, timeout=3); connections.append(response)
                payload = json.loads(response.readline().decode().removeprefix('data: '))
                self.assertEqual(payload['kind'], 'snapshot'); response.readline()
            self.lab.request()  # An unrelated snapshot cannot reset either reader.
            event = ('data: ' + json.dumps(dict(ENV_ENTRY, kind='removed', id=2)) + '\n\n').encode()
            for stream in self.lab.streams:
                stream.wfile.write(event); stream.wfile.flush()
            for response in connections:
                payload = json.loads(response.readline().decode().removeprefix('data: '))
                self.assertEqual(payload['kind'], 'removed'); self.assertEqual(payload['id'], 2)
        finally:
            for response in connections: response.close()
    def test_post_release_contender_refuses_and_stopped_child_handshake_removed(self):
        self.lab.start()
        # Hold the actual flock, launch a contender that observes the old gen,
        # then revoke while it waits. This is the r4 post-release claim schedule.
        import fcntl
        with (self.lab.lease.parent / 'operation.lock').open('r+') as guard:
            fcntl.flock(guard, fcntl.LOCK_EX)
            contender = subprocess.Popen([AUTH, 'start', 'mate', 'fixture', str(self.lab.config), 'openai-codex/fixture'], env=self.lab.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            wait_for(lambda: blocked_on(self.lab.lease.parent / 'operation.lock'))
            record = rows(self.lab.lease); record['generation'] = 'revoked-by-fixture'; record['state'] = 'revoked'
            self.lab.lease.write_text(''.join(k + '=' + v + '\n' for k, v in record.items()))
        output, error = contender.communicate(timeout=10)
        self.assertNotEqual(contender.returncode, 0); self.assertIn('generation changed', error)
        self.lab.call('stop')
        # A deliberately delayed bash child startup cannot lose SIGCONT: the
        # manager starts children directly inside custody, with no self-STOP.
        bashenv = self.lab.path / 'bashenv'; bashenv.write_text('sleep .2\n')
        self.lab.env['BASH_ENV'] = str(bashenv)
        self.lab.start(); self.assertEqual(rows(self.lab.lease)['state'], 'ready')

if __name__ == '__main__':
    try:
        unittest.main()
    finally:
        import shutil
        shutil.rmtree(BASE)
