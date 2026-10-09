#!/usr/bin/env python3
"""Behavioral acceptance tests through the runner executable and fake Boat CLI."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(sys.argv.pop(1)).resolve()


def step(command="true", seconds=2):
    return dict(command=command, timeout_seconds=seconds)


def spec(lanes=1):
    return dict(version=1, size="large", ttl_seconds=600, pilot="pilot",
                prepare=[step("true # SETUP")], guard=step("true # GUARD"),
                lanes=[dict(id="pilot" if index == 0 else f"lane{index}",
                            selections=[step("true # SELECT")]) for index in range(lanes)],
                artifacts=[], finish=[])


class Cases(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        fixture = ROOT / "tests/boat-lane-runner-fixture.py"
        for name in ("boat", "curl"):
            (self.home / name).symlink_to(fixture)
        (self.home / "credential.json").write_text(json.dumps({"token": "fakefixturetoken"}))
        (self.home / "credential.json").chmod(0o600)
        self.env = dict(os.environ, FM_BOAT_BIN=str(self.home / "boat"),
                        FM_BOAT_CURL_BIN=str(self.home / "curl"),
                        FM_BOAT_CONFIG_FILE=str(self.home / "credential.json"),
                        FAKE_BOAT_HOME=str(self.home), FM_BOAT_WAKE_TIMEOUT="10")
        self.env.pop("BOAT_ORG", None)
        self.env.pop("FAKE_BOAT_MODE", None)

    def tearDown(self):
        self.temp.cleanup()

    def start(self, body=None, *extra):
        (self.home / "spec.json").write_text(json.dumps(body or spec()))
        return subprocess.Popen([sys.executable, str(ROOT / "bin/fm-boat-lanes.py"),
                                 "--spec", str(self.home / "spec.json"),
                                 "--run-dir", str(self.home / "run"), "--cap-usd", ".5",
                                 *extra], env=self.env, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)

    def run_case(self, body=None, *extra):
        process = self.start(body, *extra)
        out, err = process.communicate(timeout=40)
        self.assertNotIn("fakefixturetoken", out + err)
        return process.returncode

    def ledger(self):
        return [json.loads(line) for line in (self.home / "run/ledger.jsonl").read_text().splitlines()]

    def state(self):
        path = self.home / "state.json"
        return json.loads(path.read_text()) if path.exists() else {"boxes": {}, "events": []}

    def wait_event(self, predicate):
        end = time.monotonic() + 10
        while time.monotonic() < end:
            try:
                if predicate(self.state()):
                    return
            except ValueError:
                pass
            time.sleep(.02)
        self.fail("expected fake-provider event never appeared")

    def assert_cleanup(self):
        rows = self.ledger()
        boxes = [row["box"] for row in rows if row["event"] == "created"]
        self.assertTrue(boxes)
        for box in boxes:
            usage = next(row["sequence"] for row in rows if row["event"] in
                         ("usage", "usage_unavailable") and row["box"] == box)
            deleted = next(row for row in rows if row["event"] == "deleted" and row["box"] == box)
            self.assertLess(usage, deleted["sequence"])
            self.assertEqual(deleted["proof"]["status"], 404)
            self.assertTrue(self.state()["boxes"][box]["deleted"])
            events = [row["event"] for row in self.state()["events"] if row.get("box") == box]
            self.assertLess(events.index("usage"), events.index("delete"))
        self.assertEqual(set(boxes), set(self.state()["boxes"]))

    def test_success_pilot_gate_and_cleanup(self):
        self.assertEqual(self.run_case(spec(3), "--jobs", "1"), 0)
        rows = self.ledger()
        pilot = next(row for row in rows if row["event"] == "lane_result" and row["lane"] == "pilot")
        self.assertEqual(pilot["verdict"], "pass")
        for row in rows:
            if row["event"] == "created" and row["lane"] != "pilot":
                self.assertGreater(row["sequence"], pilot["sequence"])
        self.assert_cleanup()

    def test_dirty_substrate_refused_before_stack(self):
        self.env["FAKE_BOAT_MODE"] = "dirty"
        self.assertEqual(self.run_case(spec(3)), 3)
        self.assertEqual(len(self.state()["boxes"]), 1)
        self.assertFalse(any(row.get("phase") == "prepare" for row in self.state()["events"]))
        self.assert_cleanup()

    def test_root_credential_mismatch_is_harness_failure(self):
        self.env["FAKE_BOAT_MODE"] = "mismatch"
        self.assertEqual(self.run_case(), 3)
        result = next(row for row in self.ledger() if row["event"] == "lane_result")
        self.assertEqual(result["verdict"], "harness_failure")
        self.assertFalse(any(row.get("phase") == "selection" for row in self.state()["events"]))
        self.assert_cleanup()

    def test_initial_budget_refusal_creates_nothing(self):
        self.assertEqual(self.run_case(None, "--cap-usd", ".001"), 3)
        self.assertEqual(self.state()["boxes"], {})

    def test_budget_counts_spent_and_all_reserved_ttls(self):
        body = spec(4)
        # A valid provider response with no cost keeps its full TTL reserved.
        self.env["FAKE_BOAT_MODE"] = "no-cost"
        self.assertEqual(self.run_case(body, "--cap-usd", ".025", "--jobs", "1"), 3)
        self.assertEqual(len(self.state()["boxes"]), 2)
        self.assertTrue(any(row["event"] == "refused" and row["reserved_usd"] >= .0239
                            for row in self.ledger()))
        self.assert_cleanup()

    def test_product_failure_cleanup_and_pilot_stops_fanout(self):
        body = spec(4)
        body["lanes"][0]["selections"] = [step("false # SELECT")]
        self.assertEqual(self.run_case(body), 4)
        self.assertEqual(len(self.state()["boxes"]), 1)
        self.assert_cleanup()

    def test_two_matching_failures_halt_new_creates(self):
        body = spec(6)
        for lane in body["lanes"][1:]:
            lane["selections"] = [step("false # SELECT")]
        self.assertEqual(self.run_case(body, "--jobs", "1"), 5)
        self.assertEqual(len(self.state()["boxes"]), 3)
        self.assertTrue(self.ledger()[-1]["systemic_halt"])
        self.assert_cleanup()

    def test_remote_deadline_stops_next_selection(self):
        body = spec()
        body["lanes"][0]["selections"] = [step("sleep 120 # SELECT", .15), step("true # SELECT")]
        self.assertEqual(self.run_case(body), 124)
        selections = [row for row in self.state()["events"] if row.get("phase") == "selection"]
        self.assertEqual(len(selections), 1)
        self.assertEqual(next(row for row in self.ledger() if row["event"] == "lane_result")["verdict"], "timeout")
        self.assert_cleanup()

    def test_local_deadline_kills_ssh_helper_even_when_leader_exits(self):
        body = spec()
        body["lanes"][0]["selections"] = [step("true # SELECT # HANG_LOCAL", .1), step("true # SELECT")]
        self.assertEqual(self.run_case(body), 124)
        child = next(row for row in self.state()["events"] if row["event"] == "child")["pid"]
        state = Path(f"/proc/{child}/stat")
        if state.exists():
            self.assertEqual(state.read_text().split()[2], "Z")
        else:
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
        self.assertEqual(len([row for row in self.state()["events"] if row.get("phase") == "selection"]), 1)
        self.assert_cleanup()

    def test_signals_capture_usage_delete_and_prove_404(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sig):
                if (self.home / "run").exists():
                    import shutil
                    shutil.rmtree(self.home / "run")
                    (self.home / "state.json").unlink()
                body = spec(3)
                body["lanes"][0]["selections"] = [step("sleep 120 # SELECT", 120)]
                process = self.start(body)
                self.wait_event(lambda state: any(row.get("phase") == "selection" for row in state["events"]))
                process.send_signal(sig)
                process.communicate(timeout=15)
                self.assertEqual(process.returncode, 128 + sig)
                self.assert_cleanup()

    def test_crash_ledger_lists_created_ids_for_manual_cleanup(self):
        body = spec()
        body["lanes"][0]["selections"] = [step("sleep 120 # SELECT", 120)]
        process = self.start(body)
        self.wait_event(lambda state: any(row.get("phase") == "selection" for row in state["events"]))
        process.kill()
        process.communicate(timeout=5)
        created = {row["box"] for row in self.ledger() if row["event"] == "created"}
        self.assertEqual(created, set(self.state()["boxes"]))
        self.assertEqual((self.home / "run/ledger.jsonl").stat().st_mode & 0o777, 0o600)
        # Reap this test's fake CLI tree after proving SIGKILL cannot run cleanup.
        for row in self.state()["events"]:
            if row["event"] in ("ssh", "remote_child") and row.get("pid"):
                try:
                    os.killpg(row["pid"], signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_generic_info_error_is_not_deletion_proof(self):
        self.env["FAKE_BOAT_MODE"] = "bad-proof"
        self.assertEqual(self.run_case(), 6)
        self.assertFalse(any(row["event"] == "deleted" for row in self.ledger()))

    def test_case_retry_excludes_known_defect(self):
        body = spec()
        path = str(self.home / "cases.json")
        initial = dict(cases=[dict(id="known", status="fail", failure_signature="expected HTTP 429, got 200"),
                              dict(id="uncertain", status="fail", request_ids=["req-123"])])
        retried = dict(cases=[dict(id="uncertain", status="pass", request_ids=["req-456"])])
        import shlex
        emit = lambda payload: "printf %s " + shlex.quote(json.dumps(payload)) + " > " + shlex.quote(path)
        body["known_harness_defects"] = ["expected HTTP 429, got 200"]
        body["lanes"][0]["selections"] = [dict(command=emit(initial) + "; false # SELECT",
            timeout_seconds=2, evidence_file=path, retry_reset=[step("true # RESET_FRESH_STACK")],
            retry_cases={"uncertain": step(emit(retried) + " # RETRY_uncertain"),
                         "known": step("false # RETRY_known")})]
        self.assertEqual(self.run_case(body), 4)
        reports = [json.loads(line) for line in (self.home / "run/report.jsonl").read_text().splitlines()]
        initial = next(row for row in reports if row["attempt"] == "initial")
        cases = {row["id"]: row for row in initial["cases"]}
        self.assertEqual(cases["known"]["classification"], "known-harness-defect")
        self.assertEqual(cases["known"]["retry_decision"], "never")
        self.assertEqual(cases["uncertain"]["retry_decision"], "once-case")
        retries = [row for row in reports if row["attempt"] == "retry"]
        self.assertEqual(len(retries), 1)
        self.assertEqual([row["id"] for row in retries[0]["cases"]], ["uncertain"])
        self.assertEqual(retries[0]["overall_totals"], {"fail": 1, "pass": 1})
        self.assert_cleanup()

    def test_streaming_report_valid_before_last_lane_finishes(self):
        body = spec(3)
        body["lanes"][1]["selections"] = [step("sleep .15 # SELECT")]
        body["lanes"][2]["selections"] = [step("sleep 2 # SELECT", 3)]
        process = self.start(body, "--jobs", "2")
        report = self.home / "run/report.jsonl"
        end = time.monotonic() + 10
        while time.monotonic() < end:
            rows = [json.loads(line) for line in report.read_text().splitlines()] if report.exists() else []
            if any(row["lane"] == "lane1" and row["attempt"] == "complete" for row in rows):
                break
            time.sleep(.02)
        else:
            self.fail("no mid-run completed lane report")
        self.assertFalse(any(row["lane"] == "lane2" and row["attempt"] == "complete" for row in rows))
        self.assertIn("lane1", (self.home / "run/report.md").read_text())
        self.assertIsNone(process.poll())
        process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0)
        self.assert_cleanup()

    def test_infra_retried_once_product_never_retried(self):
        import shlex
        body = spec()
        path = str(self.home / "cases.json")
        payload = dict(cases=[dict(id="infra", status="fail", kind="infra", request_ids=["req-infra"]),
                              dict(id="product", status="fail", kind="product")])
        emit = "printf %s " + shlex.quote(json.dumps(payload)) + " > " + shlex.quote(path)
        body["lanes"][0]["selections"] = [dict(command=emit + "; false # SELECT", timeout_seconds=2,
            evidence_file=path, retry_reset=[step("true")],
            retry_cases={"infra": step(emit + "; false # RETRY_infra"), "product": step("false")})]
        self.assertEqual(self.run_case(body), 4)
        rows = [json.loads(line) for line in (self.home / "run/report.jsonl").read_text().splitlines()]
        initial = next(row for row in rows if row["attempt"] == "initial")
        cases = {row["id"]: row for row in initial["cases"]}
        self.assertEqual(cases["product"]["retry_decision"], "never")
        retries = [row for row in rows if row["attempt"] == "retry"]
        self.assertEqual(len(retries), 1)
        self.assertEqual([case["id"] for case in retries[0]["cases"]], ["infra"])
        self.assertEqual(next(row for row in rows if row["attempt"] == "complete")["verdict"], "product_failure")
        self.assert_cleanup()

    def test_failed_command_with_passing_evidence_blocks_fanout(self):
        import shlex
        body = spec(3)
        path = str(self.home / "cases.json")
        payload = dict(cases=[dict(id="real", status="pass")])
        body["lanes"][0]["selections"] = [dict(command="printf %s " + shlex.quote(json.dumps(payload))
            + " > " + shlex.quote(path) + "; false # SELECT", timeout_seconds=2, evidence_file=path)]
        self.assertEqual(self.run_case(body), 3)
        self.assertEqual(len(self.state()["boxes"]), 1)
        self.assert_cleanup()

    def test_concurrent_budget_includes_active_box_reservations(self):
        body = spec(5)
        for lane in body["lanes"][1:]:
            lane["selections"] = [step("sleep 2 # SELECT", 3)]
        self.assertEqual(self.run_case(body, "--cap-usd", ".025", "--jobs", "3"), 3)
        self.assertEqual(len(self.state()["boxes"]), 3)
        self.assert_cleanup()

    def test_streamed_diagnostics_redacted_before_failure_teardown(self):
        body = spec()
        observer = step("printf 'redis exited: config unreadable\\nAuthorization: Bearer fakefixturetoken\\nTOKEN=fakefixturetoken\\n'; sleep 30 # OBSERVE", 10)
        body["prepare"] = [dict(command="sleep .3; false # UP", timeout_seconds=2,
                                role="stack_up", observe=observer)]
        body["finish"] = [step("true # FINISH")]
        self.assertEqual(self.run_case(body), 3)
        diagnostics = next(row for row in self.ledger() if row["event"] == "diagnostics")
        path = self.home / "run" / diagnostics["path"]
        content = path.read_text()
        self.assertIn("redis exited: config unreadable", content)
        self.assertNotIn("fakefixturetoken", content)
        self.assertIn("[REDACTED]", content)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        finish = next(row for row in self.ledger() if row["event"] == "step" and row["phase"] == "finish")
        self.assertLess(diagnostics["sequence"], finish["sequence"])
        self.assert_cleanup()

    def test_stack_up_without_observer_is_refused(self):
        body = spec()
        body["prepare"][0]["role"] = "stack_up"
        self.assertEqual(self.run_case(body), 2)
        self.assertEqual(self.state()["boxes"], {})

    def test_service_tails_keep_early_redis_error(self):
        import shlex
        body = spec()
        program = "import json,time; print(json.dumps({'service':'redis','line':'redis config unreadable'}),flush=True); "
        program += "[print(json.dumps({'service':'api','line':'healthy noise '+str(i)}),flush=True) for i in range(300)]; time.sleep(30)"
        observer = step("python3 -c " + shlex.quote(program) + " # OBSERVE", 10)
        body["prepare"] = [dict(command="sleep .3; false", timeout_seconds=2,
                                role="stack_up", observe=observer)]
        self.assertEqual(self.run_case(body), 3)
        row = next(row for row in self.ledger() if row["event"] == "diagnostics")
        content = (self.home / "run" / row["path"]).read_text()
        self.assertIn("redis config unreadable", content)
        self.assertIn("healthy noise 299", content)
        self.assertNotIn("healthy noise 0\n", content)
        self.assert_cleanup()

    def test_help_owns_schema_and_exits(self):
        result = subprocess.run([sys.executable, str(ROOT / "bin/fm-boat-lanes.py"), "--help"],
                                capture_output=True, text=True, check=True)
        for term in ("Spec v1", "ledger.jsonl", "Exit codes", "124", "SIGKILL", "pilot", "cap-usd"):
            self.assertIn(term, result.stdout)


if __name__ == "__main__":
    unittest.main()
