#!/usr/bin/env -S uv run --no-project python3
"""Public Boat CLI transition tests against fixture-only provider/SSH calls."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import unittest

ROOT = Path(sys.argv[1]).resolve()
fixture = runpy.run_path(str(ROOT / 'tests/boat-auth-cases.py'), run_name='fixture_library')
BOAT = ROOT / 'bin/fm-boat.sh'

class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.lab = fixture['Lab']()
        self.identity = self.lab.path / 'identity'; self.identity.write_text('fixture private key, not an SSH credential')
        self.identity.with_suffix('.pub').write_text('ssh-ed25519 Zml4dHVyZQ== fixture')
        self.api = self.lab.path / 'api.json'; self.api.write_text('{"token":"fixture_api_key"}'); self.api.chmod(0o600)
        self.lab.env.update(FM_BOAT_BIN=str(self.lab.fake / 'boat'), FM_BOAT_CURL_BIN=str(self.lab.fake / 'curl'),
                            FM_BOAT_CONFIG_FILE=str(self.api), FM_BOAT_WAKE_TIMEOUT='3', FM_BOAT_POLL_INTERVAL='.05')
        self.path = self.lab.home / 'data/boat/mate.meta'
    def tearDown(self): self.lab.clean()
    def call(self, verb, *args, ok=True):
        result = subprocess.run([BOAT, verb, 'mate', *args], env=self.lab.env, capture_output=True, text=True, timeout=20)
        if ok and result.returncode: raise AssertionError(result.stderr)
        if not ok and not result.returncode: raise AssertionError('operation unexpectedly succeeded')
        return result
    def provision(self, auth=False, ok=True):
        args = ['--identity', str(self.identity), '--model', 'openai-codex/fixture']
        if auth: args.append('--omp-auth')
        return self.call('provision', *args, ok=ok)
    def provider(self): return json.loads((self.lab.path / 'provider.json').read_text())
    def state(self): return fixture['rows'](self.path)
    def test_happy_wake_sleep_restart_uses_fresh_endpoint_and_stable_pin(self):
        self.provision(); self.call('wake'); first = self.state()
        self.assertEqual(first['lifecycle'], 'ready'); self.assertEqual(first['endpoint_host'], '127.0.0.2')
        self.call('sleep'); self.assertEqual(self.state()['lifecycle'], 'suspended')
        self.assertEqual(self.provider()['state'], 'archived')
        self.call('wake'); self.assertEqual(self.state()['host_key'], first['host_key'])
        self.assertEqual(self.provider()['ttl'], 86400)
        self.call('destroy', '--yes'); self.assertEqual(self.provider()['state'], 'deleted'); self.assertFalse(self.path.exists())
    def test_preflight_rejects_unlisted_and_empty_models_without_billing(self):
        for model in ('anthropic/fixture', 'openai-codex/'):
            result = self.call('provision', '--identity', str(self.identity), '--model', model, ok=False)
            self.assertFalse((self.lab.path / 'calls').exists()); self.assertFalse(self.path.exists())
    def test_naming_and_authorization_failure_compensate_allocation(self):
        for failure in ('patch', 'authorize'):
            self.lab.update(fail=[failure]); self.provision(ok=False)
            self.assertEqual(self.provider()['state'], 'archived')
            self.assertEqual(self.state()['lifecycle'], 'provisioned')
            self.lab.update(fail=[]); self.call('destroy', '--yes')
    def test_stop_failure_is_truthful_and_never_reported_suspended(self):
        self.lab.update(fail=['patch', 'stop']); result = self.provision(ok=False)
        self.assertIn('compensation unresolved', result.stderr)
        self.assertEqual(self.state()['lifecycle'], 'unresolved'); self.assertEqual(self.provider()['state'], 'ready')
    def test_first_persistence_failure_can_retry_without_repinning_verified_identity(self):
        self.provision(); self.lab.update(fail=['persist']); self.call('wake', ok=False)
        self.assertEqual(self.state()['host_key_verified'], '0')
        self.lab.update(fail=[], key='ssh-ed25519 YW5vdGhlcg==')
        self.call('wake'); verified = self.state()['host_key']
        self.call('sleep'); self.lab.update(key='ssh-ed25519 dHJhbnNpZW50')
        self.call('wake'); self.assertEqual(self.state()['host_key'], verified)
        self.assertEqual(self.provider()['key'], verified)
    def test_failed_wake_ttl_and_ssh_stop_the_sandbox(self):
        self.provision()
        for failure in ('patch', 'ssh'):
            self.lab.update(fail=[failure]); self.call('wake', ok=False)
            self.assertEqual(self.provider()['state'], 'archived')
            self.assertEqual(self.state()['lifecycle'], 'provisioned')
    def test_no_ready_machine_retry_is_bounded_and_then_wakes(self):
        self.provision(); self.lab.update(no_ready=2); self.call('wake')
        self.assertEqual(self.state()['lifecycle'], 'ready'); self.assertEqual(self.provider()['no_ready'], 0)
    def test_sleep_guards_refuse_unresolved_reply_and_decision(self):
        self.provision(); self.call('wake')
        state = self.lab.home / 'state'; pending = state / 'pending-replies'; pending.mkdir()
        (pending / 'fixture').write_text('task_id=mate\nphase=waiting\n')
        self.call('sleep', ok=False); self.assertEqual(self.provider()['state'], 'ready')
        (pending / 'fixture').unlink(); (state / 'mate.status').write_text('needs-decision: [key=fixture] unresolved\n')
        self.call('sleep', ok=False); self.assertEqual(self.provider()['state'], 'ready')
    def test_shred_failure_prevents_deletion_and_failed_stop_restores_credentials(self):
        check = subprocess.run(['systemctl', '--user', 'show', '--property=ControlGroup'], capture_output=True)
        if check.returncode: self.skipTest('Linux systemd user manager required for auth transition')
        self.provision(auth=True); self.call('wake')
        self.lab.update(fail=['stop']); result = self.call('sleep', ok=False)
        self.assertIn('availability restored', result.stderr)
        self.assertEqual(self.state()['lifecycle'], 'ready'); self.assertEqual(fixture['rows'](self.lab.lease)['state'], 'ready')
        self.lab.update(fail=['shred']); self.call('destroy', '--yes', ok=False)
        self.assertNotEqual(self.provider()['state'], 'deleted'); self.assertTrue((self.lab.path / 'remote/omp-auth-broker.token').exists())
        self.assertEqual(self.state()['lifecycle'], 'unresolved')
    def test_delete_failure_never_restores_a_ready_record_for_a_stopped_box(self):
        self.provision(); self.call('wake')
        self.lab.update(fail=['delete']); result = self.call('destroy', '--yes', ok=False)
        self.assertEqual(self.provider()['state'], 'archived')
        self.assertEqual(self.state()['lifecycle'], 'unresolved')
        self.assertIn('explicit wake required', result.stderr)
    def test_live_smoke_requires_explicit_opt_in_before_any_provider_call(self):
        self.lab.env['FM_BOAT_LIVE'] = '0'
        result = subprocess.run([BOAT, 'live-smoke', '--identity', str(self.identity), '--model', 'openai-codex/fixture'],
                                env=self.lab.env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0); self.assertIn('FM_BOAT_LIVE=1', result.stderr)
        self.assertFalse((self.lab.path / 'calls').exists())

try:
    unittest.main()
finally:
    import shutil
    shutil.rmtree(fixture['BASE'])
