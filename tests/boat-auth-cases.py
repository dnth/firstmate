#!/usr/bin/env -S uv run --no-project python3
"""Real cgroup custody, fake SSH/OMP/Boat credentials, real scoped facade."""
import contextlib
import json
import os
from pathlib import Path
import signal
import shlex
import yaml
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import hmac
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

GO_PROVIDERS = ('opencode-go-dnth', 'opencode-go-dnth-1',
                'opencode-go-neuralengine', 'opencode-go-neuralengine-1')

class UniqueYamlLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        mapping = super().construct_mapping(node, deep=deep)
        if len(mapping) != len(node.value):
            raise ValueError('duplicate YAML mapping key')
        return mapping


def assert_go_models(case, text, helper):
    config = yaml.load(text, Loader=UniqueYamlLoader)
    providers = config['providers']
    for account in GO_PROVIDERS:
        entry = providers[account]
        case.assertEqual(entry['baseUrl'], 'https://opencode.ai/zen/go/v1')
        case.assertTrue(entry['apiKey'].startswith('!'))
        case.assertEqual(shlex.split(entry['apiKey'][1:]), ['python3', str(helper), 'api-key', account])
        case.assertEqual({model['id']: model['api'] for model in entry['models']},
                         {'deepseek-v4.1-flash': 'openai-completions',
                          'muse-spark-1.3-contributor': 'openai-responses'})
    return providers


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
        self.upload_calls = []; self.disable_calls = []; self.next_credential_id = 100
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
                path = self.path.split('?', 1)[0]
                if path == '/v1/credential':
                    request = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
                    provider = request['provider']; credential = request['credential']
                    lab.upload_calls.append({'provider': provider, 'type': credential['type']})
                    entry = next((item for item in lab.payload['credentials']
                                  if item['provider'] == provider and item['credential'] == credential), None)
                    if entry is None:
                        entry = {'provider': provider, 'id': lab.next_credential_id, 'identityKey': None,
                                 'rotatesInMs': None, 'credential': credential}
                        lab.next_credential_id += 1; lab.payload['credentials'].append(entry)
                    body = {'entries': [item for item in lab.payload['credentials'] if item['provider'] == provider]}
                    status = 200
                elif (parts := path.strip('/').split('/')) and len(parts) == 4 and parts[:2] == ['v1', 'credential'] and parts[2].isdigit() and parts[3] == 'disable':
                    credential_id = int(parts[2]); lab.disable_calls.append(credential_id)
                    lab.payload['credentials'] = [item for item in lab.payload['credentials'] if item['id'] != credential_id]
                    body = {'ok': True}; status = 200
                else:
                    lab.refresh_calls += 1; body = lab.refresh; status = lab.status
                self.send_response(status); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(json.dumps(body).encode())
        self.end = threading.Event()
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever); self.thread.start()
        # Bind an ephemeral port just long enough to choose this isolated facade.
        import socket
        with socket.socket() as socket:
            socket.bind(('127.0.0.1', 0)); self.proxy_port = socket.getsockname()[1]
        self.env = dict(os.environ, HOME=str(self.home), FM_HOME=str(self.home), FM_BOAT_SSH_BIN=str(self.fake / 'ssh'),
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
    def start(self, ok=True, model='openai-codex/fixture'):
        return self.call('start', 'fixture', str(self.config), model, ok=ok)
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

class ModelConfigTests(unittest.TestCase):
    def test_replacement_preserves_siblings(self):
        for provider in GO_PROVIDERS:
            for quote in ('', "'", '"'):
                with self.subTest(provider=provider, quote=quote), tempfile.TemporaryDirectory(dir=BASE) as directory:
                    home = Path(directory)
                    models = home / 'models.yml'
                    before = '  private-before:\n    baseUrl: https://before.example/v1\n'
                    after = f'  {quote}private-provider{quote}:\n    baseUrl: https://after.example/v1\n'
                    models.write_text('providers:\n' + before +
                                      f'  {quote}{provider}{quote}:\n    apiKey: fixture_old_key\n' + after)
                    env = dict(os.environ, PI_CODING_AGENT_DIR=str(home), FM_BOAT_REMOTE_AUTH_DIR=str(home))
                    command = [sys.executable, str(ROOT / 'bin/fm-boat-remote-omp.py'), 'install-models']
                    subprocess.run(command, env=env, check=True, capture_output=True)
                    installed = models.read_text()
                    providers = assert_go_models(self, installed, home / 'boat-omp-remote.py')
                    self.assertEqual(providers['private-before'], {'baseUrl': 'https://before.example/v1'})
                    self.assertEqual(providers['private-provider'], {'baseUrl': 'https://after.example/v1'})
                    self.assertEqual(set(providers), {*GO_PROVIDERS, 'private-before', 'private-provider'})
                    subprocess.run(command, env=env, check=True, capture_output=True)
                    self.assertEqual(models.read_text(), installed)

    def test_unsupported_providers_mapping_refuses_without_writing(self):
        inline = 'providers: {private-provider: {baseUrl: https://private.example/v1}}\n'
        for original in (inline, inline.replace('providers:', 'providers :'),
                         inline.replace('providers:', '"providers":'),
                         inline.replace('providers:', "'providers':"),
                         inline + 'providers:\n', 'providers:\n' + inline,
                         'providers:\n    private-provider:\n        baseUrl: https://private.example/v1\n',
                         'providers:\n private-provider:\n  baseUrl: https://private.example/v1\n',
                         'providers:\n  private-provider: {}\n  private-provider: {}\n',
                         'providers:\n  private-provider: [unterminated\n'):
            with self.subTest(original=original), tempfile.TemporaryDirectory(dir=BASE) as directory:
                home = Path(directory)
                models = home / 'models.yml'
                env = dict(os.environ, PI_CODING_AGENT_DIR=str(home), FM_BOAT_REMOTE_AUTH_DIR=str(home))
                command = [sys.executable, str(ROOT / 'bin/fm-boat-remote-omp.py')]
                models.write_bytes(original.encode())
                result = subprocess.run(command + ['install-models'], env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(models.read_bytes(), original.encode())
                models.unlink()
                subprocess.run(command + ['install-models'], env=env, check=True, capture_output=True)
                installed = models.read_bytes()
                helper = home / 'boat-omp-remote.py'
                helper.touch(mode=0o700)
                subprocess.run(command + ['check-models'], env=env, check=True, capture_output=True)
                for corrupted in (original.encode() + installed,
                                  original.encode() + installed.removeprefix(b'providers:\n')):
                    models.write_bytes(corrupted)
                    result = subprocess.run(command + ['check-models'], env=env, capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(models.read_bytes(), corrupted)

    def test_check_rejects_changed_broker_command(self):
        with tempfile.TemporaryDirectory(dir=BASE) as directory:
            home = Path(directory)
            models = home / 'models.yml'
            helper = home / 'boat-omp-remote.py'
            helper.touch(mode=0o700)
            env = dict(os.environ, PI_CODING_AGENT_DIR=str(home), FM_BOAT_REMOTE_AUTH_DIR=str(home))
            command = [sys.executable, str(ROOT / 'bin/fm-boat-remote-omp.py')]
            subprocess.run(command + ['install-models'], env=env, check=True, capture_output=True)
            config = yaml.load(models.read_text(), Loader=UniqueYamlLoader)
            config['providers']['opencode-go-dnth']['apiKey'] = '!cat /tmp/fixture-key'
            changed = yaml.safe_dump(config).encode()
            models.write_bytes(changed)
            result = subprocess.run(command + ['check-models'], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(models.read_bytes(), changed)



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
    def test_default_brokers_do_not_share_listeners_or_credentials(self):
        other = Lab()
        try:
            for lab, access in ((self.lab, 'first_lease_access'), (other, 'second_lease_access')):
                lab.env.pop('FM_BOAT_BROKER_URL')
                lab.update(broker_access=access)
                lab.start()
                self.assertEqual(lab.request()['credentials'][0]['credential']['access'], access)
            self.lab.call('stop')
            self.assertEqual(other.request()['credentials'][0]['credential']['access'], 'second_lease_access')
        finally:
            other.clean()
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

    def test_repeated_start_check_failure_retires_ready_generation(self):
        self.lab.start()
        self.lab.update(fail=['check'])
        result = self.lab.start(ok=False)
        self.assertIn('ssh refused the operation', result.stderr)
        state = rows(self.lab.lease)
        self.assertEqual(state['state'], 'retired')
        self.assertFalse((self.lab.path / 'remote/omp-auth-broker.token').exists())
        unit = state.get('unit')
        if unit:
            self.assertIn('ActiveState=inactive', subprocess.check_output(
                ['systemctl', '--user', 'show', unit, '-p', 'ActiveState'], text=True))
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
        self.lab.payload['credentials'] += [
            {'provider': 'anthropic', 'id': 9, 'credential': ENTRY['credential']},
            {'provider': 'openai-codex', 'id': 3, 'identityKey': 'api-key-identity-must-not-egress',
             'rotatesInMs': 31, 'credential': {'type': 'api_key', 'key': 'fixture_api_key', 'extra': 'must-not-egress'}},
            {'provider': 'openai-codex', 'id': 4, 'credential': {'type': 'oauth', 'access': 'a'}},
            {'provider': 'anthropic', 'id': 10, 'credential': {'type': 'api_key', 'key': 'non_allowlisted_fixture_key'}},
        ]
        self.lab.start()
        out = self.lab.request()
        expected = [
            {'provider': 'openai-codex', 'id': 2, 'identityKey': None, 'rotatesInMs': None,
             'credential': {'type': 'oauth', 'access': 'fixture_access', 'expires': 4102444800000, 'refresh': '__remote__'}},
            {'provider': 'openai-codex', 'id': 3, 'identityKey': None, 'rotatesInMs': None,
             'credential': {'type': 'api_key', 'key': 'fixture_api_key'}},
        ]
        self.assertEqual(out, dict(ENV_ENTRY, credentials=expected))
        self.assertEqual(self.lab.request('/v1/credential/2/refresh', 'POST')['entry'], expected[0])
        from urllib.error import HTTPError
        for credential_id in (3, 9, 10):
            with self.assertRaises(HTTPError) as failure:
                self.lab.request(f'/v1/credential/{credential_id}/refresh', 'POST')
            self.assertEqual(failure.exception.code, 403)
        self.assertEqual(self.lab.refresh_calls, 1)
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
    def test_opencode_go_key_is_brokered_without_remote_file(self):
        provider = 'opencode-go-dnth'
        old_key = 'fixture_opencode_go_key'
        new_key = 'fixture_rotated_opencode_go_key'
        providers = ['openai-codex', 'anthropic', 'opencode-go-dnth', 'opencode-go-dnth-1',
                     'opencode-go-neuralengine', 'opencode-go-neuralengine-1']
        other_keys = {account: f'fixture_{account.replace("-", "_")}_key' for account in providers[3:]}
        auth_values = {provider: {'type': 'api_key', 'key': old_key},
                       **{account: {'type': 'api_key', 'key': key} for account, key in other_keys.items()}}
        allowlist = self.lab.home / 'config/boat/providers.json'
        allowlist.parent.mkdir(parents=True)
        allowlist.write_text(json.dumps(providers)); allowlist.chmod(0o600)
        auth = self.lab.home / '.local/share/opencode/auth.json'
        auth.parent.mkdir(parents=True)
        auth.write_text(json.dumps(auth_values)); auth.chmod(0o600)
        self.lab.payload['credentials'].append({
            'provider': provider, 'id': 90, 'identityKey': 'unrelated-account',
            'credential': {'type': 'api_key', 'key': 'unrelated_fixture_api_key'},
        })

        remote = self.lab.path / 'remote'
        models = remote / '.omp/agent/models.yml'
        models.parent.mkdir(parents=True)
        original_models = ('providers:\n  private-provider:\n    api: openai-completions\n'
                           '  opencode-go-dnth:\n'
                           '    apiKey: \"!jq -er openai_go_key ~/.local/share/opencode/auth.json\"\n'
                           '  private-after:\n    baseUrl: https://private.example/v1\n')
        models.write_text(original_models)
        self.lab.start(model=f'{provider}/deepseek-v4.1-flash')
        self.assertEqual(self.lab.upload_calls, [{'provider': account, 'type': 'api_key'} for account in providers[2:]])
        first = [item for item in self.lab.request()['credentials'] if item['provider'] == provider]
        self.assertEqual(len(first), 1)
        self.assertEqual(first[0]['credential'], {'type': 'api_key', 'key': old_key})
        go_credentials = [item for item in self.lab.request()['credentials'] if item['provider'] in providers[2:]]
        self.assertEqual([item['provider'] for item in go_credentials], providers[2:])
        credential_id = first[0]['id']

        remote = self.lab.path / 'remote'
        helper = remote / 'boat-omp-remote.py'
        models = remote / '.omp/agent/models.yml'
        self.assertTrue(helper.is_file())
        configured = assert_go_models(self, models.read_text(), remote / 'boat-omp-remote.py')
        self.assertEqual(configured['private-provider'], {'api': 'openai-completions'})
        self.assertEqual(configured['private-after'], {'baseUrl': 'https://private.example/v1'})
        self.assertEqual(set(configured), {*GO_PROVIDERS, 'private-provider', 'private-after'})
        self.assertFalse((remote / '.local/share/opencode/auth.json').exists())
        token = (remote / 'omp-auth-broker.token').read_text()
        resolver_env = dict(self.lab.env, HOME=str(remote), FM_BOAT_REMOTE_AUTH_DIR=str(remote),
                            OMP_AUTH_BROKER_URL=f'http://127.0.0.1:{self.lab.proxy_port}',
                            OMP_AUTH_BROKER_TOKEN=token)
        for account, key in {provider: old_key, **other_keys}.items():
            resolved = subprocess.run([sys.executable, helper, 'api-key', account], env=resolver_env,
                                      capture_output=True, text=True, timeout=5)
            self.assertEqual(resolved.returncode, 0)
            self.assertTrue(hmac.compare_digest(resolved.stdout.rstrip('\n'), key))
            self.assertEqual(resolved.stderr, '')
        unscoped_env = dict(resolver_env, OMP_AUTH_BROKER_URL=f'http://127.0.0.1:{self.lab.server.server_port}')
        unscoped = subprocess.run([sys.executable, helper, 'api-key', provider], env=unscoped_env,
                                  capture_output=True, text=True, timeout=5)
        self.assertNotEqual(unscoped.returncode, 0)
        self.assertEqual(unscoped.stdout, '')
        for key in [old_key, *other_keys.values()]:
            self.assertNotIn(key, '\0'.join(resolver_env.values()))
        for file in remote.rglob('*'):
            if file.is_file():
                contents = file.read_bytes()
                for key in [old_key, *other_keys.values()]:
                    self.assertNotIn(key.encode(), contents)

        self.lab.call('stop')
        rotated_auth = dict(auth_values)
        rotated_auth[provider] = {'type': 'api_key', 'key': new_key}
        auth.write_text(json.dumps(rotated_auth))
        self.lab.start(model=f'{provider}/deepseek-v4.1-flash')
        self.assertEqual(self.lab.disable_calls, [credential_id])
        self.assertEqual(self.lab.upload_calls,
                         [{'provider': account, 'type': 'api_key'} for account in providers[2:]] +
                         [{'provider': provider, 'type': 'api_key'}])
        current = [item for item in self.lab.request()['credentials'] if item['provider'] == provider]
        self.assertEqual(len(current), 1)
        self.assertEqual(current[0]['credential'], {'type': 'api_key', 'key': new_key})
        current_go = {item['provider']: item['credential']['key'] for item in self.lab.request()['credentials']
                      if item['provider'] in providers[2:]}
        expected_go = {provider: new_key, **other_keys}
        self.assertEqual(set(current_go), set(expected_go))
        for account, key in expected_go.items():
            self.assertTrue(hmac.compare_digest(current_go[account], key))
        for file in remote.rglob('*'):
            if file.is_file():
                contents = file.read_bytes()
                for key in [old_key, new_key, *other_keys.values()]:
                    self.assertNotIn(key.encode(), contents)


if __name__ == '__main__':
    try:
        unittest.main()
    finally:
        import shutil
        shutil.rmtree(BASE)
