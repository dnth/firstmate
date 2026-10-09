#!/usr/bin/env python3
"""Run versioned, disposable Boat QA lanes (POSIX workstation only).

Usage: fm-boat-lanes.py --spec lanes.json --run-dir NEW_DIRECTORY --cap-usd .50
       [--pilot-only] [--jobs 2]

This header and --help own the mechanics. No project recipe is built in.
The runner imports fm-boat.py's client, credentials and hourly rates; FM_BOAT_BIN,
FM_BOAT_CONFIG_FILE and FM_BOAT_CURL_BIN retain that client's meanings.
Boat personal/base creation always uses --no-env and an explicit TTL. No existing
box can be supplied. Each created ID is fsynced before customization; the provider
name is fm-lanes-<random run token>-<lane>. Never adopt or delete another run's box.

Spec v1 is JSON: {"version":1,"size":"large","ttl_seconds":1800,
 "pilot":"pilot","env":{"NAME":"value"},"prepare":[STEP],"guard":STEP,
 "lanes":[{"id":"pilot","selections":[STEP]}],"artifacts":["/tmp/results"],
 "finish":[STEP]}. STEP is {"command":"shell script","timeout_seconds":60}
 or, in prepare only, {"upload":"/absolute/local/file","destination":"/tmp/file",
 "timeout_seconds":60}. Commands execute remotely in bash with strict errors,
 VIRTUAL_ENV unset, spec env plus FM_LANE, FM_RUN_TOKEN and FM_BOX_ID. Uploads use
 Boat scp. guard is mandatory and runs after prepare and before each selection;
 it must assert the project's source/module/cwd/credential agreement. Selections
 must include the real test invocation AND case evidence; exit zero and all
 cases passing are both required. All commands are trusted operator input, never echoed.
 Docker inventory must be empty before prepare. Preparation/guard/transport
 failures are harness_failure; selection nonzero is a failed selection, never a pass.
 Artifacts must exclude credentials; only explicitly declared paths are fetched.
 Optional failure_signature_files are remote JSON reports with a top-level
 failure_signature string. Each nonempty case signature is also matched
 independently of case IDs or other failures across distinct lanes to stop new
 creation. Otherwise phase+exit is the conservative failure signature.

Required selection evidence_file is a /tmp JSON object with cases:[{id,status,
 failure_signature,request_ids,kind,dependency_blocked}]. Status is pass/fail/etc;
 kind may be infra/product. Non-pass cases classify as known-harness-defect when
 dependency_blocked or matching a literal substring in spec known_harness_defects;
 then infra when kind=infra or matching infra_signatures (e.g. a known outage);
 then product when kind=product; otherwise uncertain. Passes classify as pass.
 Only infra/uncertain are eligible for one retry. Selection retry_reset:[STEP]
 must rebuild a fresh stack; retry_cases:{case_id:STEP} provides case re-selection,
 else retry_selection:STEP must be the smallest containing selection, and is
 skipped when it would rerun an attempted case or a currently known-defect/product case. Never rerun
 all lane selections. Missing reset/selection records a skipped retry. Retry
 commands must write updated evidence_file; known defects/product are never
 retry targets. Infra transport/timeout failures without readable case evidence
 remain harness/timeout verdicts, not invented product cases.

Stack-up steps must declare role:"stack_up" and observe:STEP. The observer is a
 streaming diagnostic command started and acknowledged BEFORE the main command.
 After establishing its capture/watchers, the observer itself must flush the exact
 line FM_OBSERVER_READY on stdout or stderr within 15 seconds. The wrapper never
 emits readiness. The observer must remain running until runner cancellation;
 any premature completion (including exit zero) fails the step and pilot.
 Its timeout must exceed the main deadline by at least 5s. Put project-specific
 Compose service discovery/log-follow commands in the observer spec. Follow logs
 from container creation, since project startup may remove failed services before
 returning. On step completion, the observer's process tree is terminated and its
 bounded, redacted tail is persisted incrementally mode0600 under artifacts/<lane>/diagnostics before
 finish/delete. Observer commands must redact generated secrets at their source;
 the runner additionally removes credential assignments, bearer tokens and URI
 passwords. Sensitive env values are never echoed. This also applies to retry
 stack resets marked stack_up. No diagnostics command may operate another box.
 Observers may emit JSON lines {"service":"redis","line":"redacted log line"};
 these retain a separate last-200-line tail per service, so another service's
 output cannot bury an earlier startup error. At most 32 services are retained;
 excess services use the plain tail. Each tail is at most 32768 characters,
 and input lines over 65536 bytes are discarded. Other output uses one bounded tail.

Command-step stdout/stderr is drained and discarded. Consumers of provider JSON,
 Docker inventory, case evidence and signature files retain complete responses
 up to 1MiB per stream; larger responses fail closed rather than being truncated.

report.jsonl appends a fsynced record immediately after each selection/retry and
 lane finish: lane, box, profile, duration_seconds, cases (id/status/classification/
 request_ids/retry_decision), case_counts, failures and spend_so_far_usd. Each
 append recomputes overall_totals from the latest case result per lane/selection/id
 (retries replace their original result). report.md is atomically replaced after
 every append and readable mid-run. Only structural evidence is recorded, never
 arbitrary request bodies, credentials, commands or remote stdout/stderr.

The pilot completes its real selections before any other box is created. --jobs
 bounds subsequent concurrent lanes. Before every create, spent usage plus ALL
 outstanding TTL reservations plus the new full-TTL reservation must fit cap-usd.
 Unknown usage retains the full reservation; unsuccessful cleanup is a run failure.
 A spend cap bounds projected compute only, using fm-boat.py's hourly rates; it is
 not a provider billing limit. A TTL is mandatory even if the workstation crashes.

The NEW run directory is mode 0700. ledger.jsonl is append-only, mode 0600, fsynced
 JSON events with version=1, sequence, time, event and event-specific fields.
 create_intent records lane/name/TTL/reserved_usd before the API call; created
 records box immediately; usage records the full provider object BEFORE delete;
 deleted records explicit info 404 proof. lane_result records verdict/signature;
 summary records spent_usd/reserved_usd/systemic_halt/results. Private artifact
 directories contain declared downloads only. A crash leaves IDs (and in-flight
 create names) in the ledger for manual account inspection/cleanup. No automatic
 recovery or ledger reuse is supported; never delete by an unverified name alone.

Each process has its own session. Deadlines terminate its group AND remembered
 descendants, then kill after a grace period even if the leader already exited.
 Remote scripts also have a provider-side timeout; timeout prevents the next
 selection. SIGINT/SIGTERM stop scheduling, reap commands, capture usage, delete
 every owned box, and verify info's explicit 404. Cleanup continues across errors.
 SIGKILL/power loss cannot run cleanup: use the ledger and provider TTL.

 Exit codes: 0 all selected lanes pass with deletion proofs; 2 invalid spec/input;
 3 harness failure/refusal (including budget); 4 selection failure; 5 systemic halt;
 6 cleanup incomplete; 124 lane timeout; 130 SIGINT; 143 SIGTERM.
"""

import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import selectors
import shlex
import signal
import subprocess
import sys
import threading
import time
import uuid


sys.path.insert(0, str(Path(__file__).resolve().parent))
_module = importlib.util.spec_from_file_location(
    "fm_boat_client", Path(__file__).with_name("fm-boat.py"))
client = importlib.util.module_from_spec(_module)
_module.loader.exec_module(client)


class Refusal(Exception):
    pass


class Deadline(Exception):
    pass


class Interrupted(Exception):
    pass


def descendants(root):
    """Snapshot local descendants, including SSH's local helper processes."""
    result = subprocess.run(["ps", "-eo", "pid=,ppid="], capture_output=True,
                            text=True, timeout=5, check=False)
    pairs = [tuple(map(int, line.split())) for line in result.stdout.splitlines()
             if len(line.split()) == 2]
    found = {root}
    while True:
        newer = found | {pid for pid, parent in pairs if parent in found}
        if newer == found:
            return found - {root}
        found = newer


def terminate(process):
    children = descendants(process.pid)
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        for pid in children:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        if sig == signal.SIGTERM:
            time.sleep(.2)
    process.wait()


class Executor:
    def __init__(self, stop):
        self.stop = stop
        self.context = threading.local()

    @property
    def cleaning(self):
        return getattr(self.context, "cleaning", False)

    @cleaning.setter
    def cleaning(self, value):
        self.context.cleaning = value

    def run(self, args, *, input=None, timeout=30, check=True, env=None, cancel=None, ready=None, output=None):
        if self.stop.is_set() and not self.cleaning:
            raise Interrupted()
        try:
            process = subprocess.Popen([str(arg) for arg in args], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       start_new_session=True, env=env)
        except OSError as error:
            raise Refusal("command unavailable") from error
        result = self.stream(process, args, input, timeout, cancel, ready, output)
        if check and result.returncode:
            raise Refusal(f"command refused operation (exit {result.returncode})")
        return result


    def stream(self, process, args, input, timeout, cancel, ready, output):
        end = time.monotonic() + timeout
        buffers = {process.stdout: b"", process.stderr: b""}
        dropping = set()
        captured = {pipe: bytearray() for pipe in buffers}
        cancelled = False
        failure = None
        terminated = False
        with selectors.DefaultSelector() as selector:
            for pipe in buffers:
                selector.register(pipe, selectors.EVENT_READ)
            try:
                process.stdin.write((input or "").encode())
                process.stdin.close()
                while selector.get_map() or process.poll() is None:
                    if not terminated and ((cancel is not None and cancel.is_set()) or (self.stop.is_set() and not self.cleaning)
                            or time.monotonic() >= end):
                        if self.stop.is_set() and not self.cleaning:
                            failure = Interrupted()
                        elif time.monotonic() >= end:
                            failure = Deadline()
                        cancelled = (cancel is not None and cancel.is_set()
                                     and process.poll() is None and failure is None)
                        terminate(process)
                        terminated = True
                        end = float("inf")
                        cancel = None
                    lines = []
                    for key, _ in selector.select(.1):
                        pipe = key.fileobj
                        chunk = os.read(pipe.fileno(), 8192)
                        if not chunk:
                            selector.unregister(pipe)
                            if buffers[pipe] and pipe not in dropping:
                                lines.append(buffers[pipe].decode(errors="replace"))
                            continue
                        if output is None:
                            if len(captured[pipe]) + len(chunk) > 1048576:
                                raise Refusal("command response exceeds capture limit")
                            captured[pipe].extend(chunk)
                            continue
                        pieces = chunk.split(b"\n")
                        for index, piece in enumerate(pieces):
                            if pipe not in dropping:
                                buffers[pipe] += piece
                                if len(buffers[pipe]) > 65536:
                                    buffers[pipe] = b""
                                    dropping.add(pipe)
                            if index < len(pieces)-1:
                                if pipe not in dropping:
                                    line = buffers[pipe].decode(errors="replace")
                                    if ready is not None and line == "FM_OBSERVER_READY":
                                        ready.set()
                                    lines.append(line)
                                buffers[pipe] = b""
                                dropping.discard(pipe)
                    if lines:
                        output(lines)
                process.wait()
            finally:
                if sys.exc_info()[0] is not None or process.poll() is None:
                    terminate(process)
                for pipe in buffers:
                    pipe.close()
        if failure:
            raise failure
        result = subprocess.CompletedProcess(args, process.returncode,
            captured[process.stdout].decode(errors="replace"),
            captured[process.stderr].decode(errors="replace"))
        result.cancelled = cancelled
        return result


def objects(output):
    rows = []
    for line in output.splitlines():
        try:
            body = json.loads(line)
            if isinstance(body, dict):
                rows.append(body)
        except ValueError:
            pass
    return rows


def positive_number(value):
    return (not isinstance(value, bool) and isinstance(value, (float, int))
            and math.isfinite(value) and value > 0)


def validate(spec):
    if not isinstance(spec, dict) or type(spec.get("version")) is not int or spec["version"] != 1:
        raise Refusal("spec version must be 1")
    if spec.get("size") not in client.RATES:
        raise Refusal("spec size is unsupported")
    ttl = spec.get("ttl_seconds")
    if not isinstance(ttl, int) or isinstance(ttl, bool) or not 60 <= ttl <= 86400:
        raise Refusal("TTL must be 60..86400 seconds")
    lanes = spec.get("lanes")
    if not isinstance(lanes, list) or not lanes:
        raise Refusal("spec requires lanes")
    ids = [lane.get("id") for lane in lanes if isinstance(lane, dict)]
    if len(ids) != len(lanes) or any(not isinstance(x, str) or not re.fullmatch(
            r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}", x) for x in ids) or len(set(ids)) != len(ids):
        raise Refusal("lane IDs must be unique safe names")
    if spec.get("pilot") not in ids:
        raise Refusal("pilot must name a lane")
    env = spec.get("env", {})
    if not isinstance(env, dict) or any(not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k)
            or not isinstance(v, str) or "\0" in v or k.startswith("FM_")
            for k, v in env.items()):
        raise Refusal("invalid spec environment")
    for key in ("prepare", "finish", "artifacts", "failure_signature_files"):
        if not isinstance(spec.get(key, []), list):
            raise Refusal(f"{key} must be a list")
    steps = [(step, True) for step in spec.get("prepare", [])]
    steps += [(spec.get("guard"), False)]
    steps += [(step, False) for step in spec.get("finish", [])]
    for lane in lanes:
        selections = lane.get("selections")
        if not isinstance(selections, list) or not selections:
            raise Refusal("each lane requires real selections")
        steps += [(step, False) for step in selections]
        for selection in selections:
            if not isinstance(selection, dict):
                raise Refusal("invalid selection")
            resets = selection.get("retry_reset", [])
            retries = selection.get("retry_cases", {})
            if not isinstance(resets, list) or not isinstance(retries, dict):
                raise Refusal("invalid retry configuration")
            steps += [(step, False) for step in resets]
            steps += [(step, False) for step in retries.values()]
            if "retry_selection" in selection:
                steps.append((selection["retry_selection"], False))
            path = selection.get("evidence_file")
            if (not isinstance(path, str) or not path.startswith("/tmp/")
                    or ".." in Path(path).parts):
                raise Refusal("evidence_file must be beneath /tmp")
    for step, upload_allowed in steps:
        if not isinstance(step, dict) or not positive_number(step.get("timeout_seconds")):
            raise Refusal("each step requires a positive finite timeout_seconds")
        observer = step.get("observe")
        if step.get("role") == "stack_up" and observer is None:
            raise Refusal("stack_up requires a streaming observer")
        if observer is not None and (not isinstance(observer, dict)
                or not isinstance(observer.get("command"), str) or not observer["command"].strip()
                or not positive_number(observer.get("timeout_seconds"))
                or observer["timeout_seconds"] < step["timeout_seconds"] + 5):
            raise Refusal("observer needs a command and a longer deadline")
        if isinstance(step.get("command"), str) and step["command"].strip() and "upload" not in step:
            continue
        if (upload_allowed and isinstance(step.get("upload"), str)
                and Path(step["upload"]).is_file()
                and isinstance(step.get("destination"), str)
                and step["destination"].startswith("/tmp/")
                and "command" not in step):
            continue
        raise Refusal("invalid command or upload step")
    for key in ("artifacts", "failure_signature_files"):
        if any(not isinstance(path, str) or not path.startswith("/tmp/")
               or "\0" in path or ".." in Path(path).parts for path in spec.get(key, [])):
            raise Refusal(f"{key} must contain absolute /tmp paths")
    for key in ("known_harness_defects", "infra_signatures"):
        if not isinstance(spec.get(key, []), list) or any(not isinstance(x, str) or not x
                for x in spec.get(key, [])):
            raise Refusal(f"{key} must contain nonempty literal signatures")


class Runner:
    def __init__(self, args, spec):
        self.args, self.spec = args, spec
        self.stop = threading.Event()
        self.executor = Executor(self.stop)
        # Use the existing Boat client's JSON/API/credential implementation.
        client.run = self.executor.run
        self.lock = threading.RLock()
        self.sequence = 0
        self.token = uuid.uuid4().hex[:12]
        self.boxes = {}
        self.spent = 0.0
        self.measured = {}
        self.reserved = 0.0
        self.signatures = {}
        self.systemic = False
        self.signal = 0
        self.cleanup_failed = False
        self.results = []
        self.reports = []
        self.latest_cases = {}
        self.directory = Path(args.run_dir).resolve()
        self.directory.mkdir(mode=0o700, parents=False, exist_ok=False)
        self.ledger = os.open(self.directory / "ledger.jsonl",
                              os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_EXCL, 0o600)
        self.event("started", token=self.token, cap_usd=args.cap_usd,
                   size=spec["size"], ttl_seconds=spec["ttl_seconds"])

    def event(self, event, **fields):
        with self.lock:
            self.sequence += 1
            body = dict(version=1, sequence=self.sequence, time=time.time(), event=event, **fields)
            data = (json.dumps(body, sort_keys=True) + "\n").encode()
            offset = 0
            while offset < len(data):
                offset += os.write(self.ledger, data[offset:])
            os.fsync(self.ledger)

    def handle_signal(self, number, _frame):
        self.signal = number
        self.stop.set()

    def create(self, lane):
        with self.lock:
            if self.stop.is_set() or self.systemic:
                raise Interrupted()
            reserve = client.RATES[self.spec["size"]] * self.spec["ttl_seconds"] / 3600
            if self.spent + self.reserved + reserve > self.args.cap_usd + 1e-12:
                self.event("refused", lane=lane, reason="projected spend exceeds cap",
                           spent_usd=self.spent, reserved_usd=self.reserved, new_usd=reserve)
                self.stop.set()
                raise Refusal("projected spend exceeds cap")
            name = f"fm-lanes-{self.token}-{lane}"
            self.reserved += reserve
            self.event("create_intent", lane=lane, name=name, reserved_usd=reserve,
                       ttl_seconds=self.spec["ttl_seconds"])
            # Do not interrupt creation between its response and durable ID publication.
            # If transport dies ambiguously, the intent/name and reservation remain.
            cleaning = self.executor.cleaning
            self.executor.cleaning = True
            try:
                body = client.cli("new", "--json", "--personal", "--no-env",
                                  "--environment", "base", "--type", self.spec["size"],
                                  "--ttl", str(self.spec["ttl_seconds"]), "--no-update")
                nested = body.get("sandbox", {})
                box = body.get("id") or (nested.get("id") if isinstance(nested, dict) else None)
                if not isinstance(box, str) or not re.fullmatch(r"bx_[A-Za-z0-9]+", box):
                    raise Refusal("creation returned invalid identity; inspect create intent")
                self.boxes[box] = dict(lane=lane, name=name, reserve=reserve, deleted=False)
                self.event("created", lane=lane, box=box, name=name, reserved_usd=reserve)
            except Exception:
                self.stop.set()  # An ambiguous create must never be followed by fan-out.
                self.event("creation_uncertain", lane=lane, name=name)
                raise
            finally:
                self.executor.cleaning = cleaning
            client.api("PATCH", box, {"name": name, "ttlSeconds": self.spec["ttl_seconds"]})
            self.event("named", box=box, name=name)
            return box

    def remote(self, box, lane, command, seconds, *, cancel=None, ready=None, output=None):
        env = dict(self.spec.get("env", {}), FM_LANE=lane, FM_RUN_TOKEN=self.token, FM_BOX_ID=box)
        prefix = "unset VIRTUAL_ENV\n" + "\n".join(
            "export " + key + "=" + shlex.quote(value) for key, value in env.items())
        script = "set -euo pipefail\n" + prefix + "\n"
        script += "exec timeout --signal=TERM --kill-after=2 "
        script += shlex.quote(str(seconds)) + " bash -euo pipefail -c " + shlex.quote(command) + "\n"
        result = self.executor.run([client.BOAT, "ssh", box, "bash", "-s"],
                                   input=script, timeout=seconds + 10, check=False, cancel=cancel, ready=ready, output=output)
        if result.returncode in (124, 137) and not result.cancelled:
            raise Deadline()
        return result

    def step(self, box, lane, step, phase):
        observer = step.get("observe")
        if observer is not None:
            cancel, ready = threading.Event(), threading.Event()
            observed = {}
            target = self.directory / "artifacts" / lane / "diagnostics"
            target.mkdir(mode=0o700, parents=True, exist_ok=True)
            path = target / f"{uuid.uuid4().hex}.log"
            tails = {"": ""}
            def persist(lines):
                for line in lines:
                    service, message = "", line
                    try:
                        row = json.loads(line)
                        if (isinstance(row, dict) and isinstance(row.get("service"), str)
                                and re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", row["service"])
                                and isinstance(row.get("line"), str)):
                            service, message = row["service"], row["line"]
                    except ValueError:
                        pass
                    if service not in tails and len(tails) >= 33:
                        service = ""
                    tails[service] = self.redact(tails.get(service, "") + self.redact(message))
                fd = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
                with os.fdopen(fd, "w") as handle:
                    handle.write("".join((f"[{service}]\n" if service else "") + tail
                                         for service, tail in sorted(tails.items())))
                    handle.flush()
                    os.fsync(handle.fileno())
            persist([])
            def collect():
                try:
                    observed["result"] = self.remote(box, lane, observer["command"],
                        observer["timeout_seconds"], cancel=cancel, ready=ready, output=persist)
                    if not observed["result"].cancelled:
                        raise Refusal("diagnostic observer ended before cancellation")
                except Exception as error:
                    observed["error"] = error
            thread = threading.Thread(target=collect)
            thread.start()
            try:
                end = time.monotonic() + 15
                while not ready.wait(.05):
                    if self.stop.is_set():
                        raise Interrupted()
                    if not thread.is_alive() or time.monotonic() >= end:
                        raise Refusal("diagnostic observer failed to start")
                if not thread.is_alive():
                    raise Refusal("diagnostic observer failed to start")
                plain = {key: value for key, value in step.items() if key != "observe"}
                code = self.step(box, lane, plain, phase)
                return code
            finally:
                cancel.set()
                thread.join(timeout=20)
                result = observed.get("result")
                self.event("diagnostics", box=box, lane=lane, path=str(path.relative_to(self.directory)),
                           exit=result.returncode if result is not None else None)
                if sys.exc_info()[0] is None:
                    if "error" in observed:
                        raise observed["error"]
                    if thread.is_alive() or result is None:
                        raise Refusal("diagnostic observer did not stop")
        seconds = step["timeout_seconds"]
        if "upload" in step:
            result = self.executor.run([client.BOAT, "scp", step["upload"],
                                       box + ":" + step["destination"]], timeout=seconds, check=False, output=lambda lines: None)
        else:
            result = self.remote(box, lane, step["command"], seconds, output=lambda lines: None)
        self.event("step", box=box, lane=lane, phase=phase, exit=result.returncode)
        return result.returncode

    def redact(self, text):
        for key, value in self.spec.get("env", {}).items():
            if re.search(r"TOKEN|KEY|PASSWORD|PASSWD|SECRET|CREDENTIAL", key, re.I) and value:
                text = text.replace(value, "[REDACTED]")
        text = re.sub(r"(?i)(authorization\s*[:=]\s*(?:bearer|basic)\s+)\S+", r"\1[REDACTED]", text)
        text = re.sub(r"(?i)((?:[A-Z_]*(?:TOKEN|API_KEY|PASSWORD|PASSWD|SECRET|CREDENTIAL)[A-Z_]*|requirepass)"
                      r"\s*[:= ]\s*)[^\s,;]+", r"\1[REDACTED]", text)
        text = re.sub(r"(\w+://[^\s/:]+:)[^\s/@]+(@)", r"\1[REDACTED]\2", text)
        text = text.replace("FM_OBSERVER_READY", "")
        return "\n".join(text.splitlines()[-200:])[-32768:] + "\n"

    def signature(self, box, lane, default):
        for path in self.spec.get("failure_signature_files", []):
            result = self.remote(box, lane, "cat -- " + shlex.quote(path), 10)
            if result.returncode == 0:
                rows = objects(result.stdout)
                value = rows[-1].get("failure_signature") if rows else None
                if isinstance(value, str) and re.fullmatch(r"[a-zA-Z0-9_.:-]{1,120}", value):
                    return value
        return default

    def fetch(self, box, lane):
        target = self.directory / "artifacts" / lane
        target.mkdir(mode=0o700, parents=True, exist_ok=True)
        for index, path in enumerate(self.spec.get("artifacts", [])):
            result = self.executor.run([client.BOAT, "scp", "-r", box + ":" + path,
                                       str(target / str(index))], timeout=60, check=False, output=lambda lines: None)
            self.event("artifact", box=box, lane=lane, path=path, exit=result.returncode)
            if result.returncode:
                raise Refusal("artifact fetch failed")

    def evidence(self, box, lane, selection):
        path = selection.get("evidence_file")
        result = self.remote(box, lane, "cat -- " + shlex.quote(path), 10)
        if result.returncode:
            raise Refusal("case evidence unavailable")
        try:
            body = json.loads(result.stdout)
            cases = body["cases"]
            if not isinstance(cases, list) or not cases:
                raise ValueError()
            rows = []
            seen = set()
            for case in cases:
                identity = case["id"]
                status = case["status"]
                if (not isinstance(identity, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,120}", identity)
                        or identity in seen or not isinstance(status, str)
                        or not re.fullmatch(r"[A-Za-z_-]{1,32}", status)):
                    raise ValueError()
                seen.add(identity)
                signature = str(case.get("failure_signature", ""))
                if status == "pass":
                    classification = "pass"
                elif case.get("dependency_blocked") or status == "dependency-blocked" or any(
                        x in signature for x in self.spec.get("known_harness_defects", [])):
                    classification = "known-harness-defect"
                elif case.get("kind") == "infra" or any(
                        x in signature for x in self.spec.get("infra_signatures", [])):
                    classification = "infra"
                elif case.get("kind") == "product":
                    classification = "product"
                else:
                    classification = "uncertain"
                requests = case.get("request_ids", [])
                if not isinstance(requests, list) or any(not isinstance(x, str) or not re.fullmatch(
                        r"[A-Za-z0-9_.:-]{1,160}", x) for x in requests):
                    raise ValueError()
                rows.append(dict(id=identity, status=status, classification=classification,
                                 signature_hash=hashlib.sha256(signature.encode()).hexdigest(),
                                 request_ids=requests, retry_decision="not-needed" if status == "pass"
                                 else "never" if classification in ("known-harness-defect", "product")
                                 else "eligible"))
            return rows
        except (ValueError, KeyError, TypeError):
            raise Refusal("malformed case evidence") from None

    def report(self, lane, box, selection, cases, duration, attempt, verdict=None):
        if box and not self.boxes[box]["deleted"] and not self.stop.is_set():
            try:
                usage = client.cli("usage", box, "--json")
                cost = usage.get("dollars")
                if usage.get("sandboxId") == box and isinstance(cost, (int, float)) and not isinstance(
                        cost, bool) and math.isfinite(cost) and cost >= 0:
                    with self.lock:
                        self.measured[box] = cost
                    self.event("usage_snapshot", box=box, provider=usage)
            except Exception:
                pass  # Full TTL reservations remain authoritative for admission.
        with self.lock:
            counts = {}
            for case in cases:
                if selection != "lane":
                    self.latest_cases[(lane["id"], selection, case["id"])] = case
                counts[case["status"]] = counts.get(case["status"], 0) + 1
            totals = {}
            for case in self.latest_cases.values():
                totals[case["status"]] = totals.get(case["status"], 0) + 1
            record = dict(version=1, lane=lane["id"], box=box, profile=lane.get("profile", "default"),
                          selection=selection, attempt=attempt, verdict=verdict,
                          duration_seconds=round(duration, 3), cases=cases, case_counts=counts,
                          failures=[case for case in cases if case["status"] != "pass"],
                          spend_so_far_usd=round(self.spent + sum(self.measured.values()), 8),
                          reserved_usd=round(self.reserved, 8),
                          overall_totals=totals, time=time.time())
            fd = os.open(self.directory / "report.jsonl", os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600)
            try:
                data = (json.dumps(record, sort_keys=True) + "\n").encode()
                offset = 0
                while offset < len(data):
                    offset += os.write(fd, data[offset:])
                os.fsync(fd)
            finally:
                os.close(fd)
            self.reports.append(json.loads(json.dumps(record)))
            lines = ["# Boat lane results", "", "Overall case totals: " + json.dumps(totals),
                     f"Spend so far: ${record['spend_so_far_usd']:.6f}; reserved: ${self.reserved:.6f}", ""]
            for row in self.reports:
                lines += [f"## {row['lane']} / {row['selection']} / {row['attempt']}", "",
                          f"Box: {row['box']}; profile: {row['profile']}; duration: {row['duration_seconds']}s",
                          "Counts: " + json.dumps(row["case_counts"]) + "; verdict: " + str(row["verdict"]), ""]
                lines += [f"- {case['id']}: {case['status']}, {case['classification']}, "
                          f"retry={case['retry_decision']}, requests={','.join(case['request_ids'])}"
                          for case in row["failures"]]
                lines.append("")
            path = self.directory / "report.md.tmp"
            fd = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
            with os.fdopen(fd, "w") as handle:
                handle.write("\n".join(lines))
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(path, self.directory / "report.md")

    def selection(self, box, lane, selection, index):
        start = time.monotonic()
        code = self.step(box, lane["id"], selection, "selection")
        cases = self.evidence(box, lane["id"], selection)
        if code != 0 and all(case["status"] == "pass" for case in cases):
            raise Refusal("failed selection contradicts passing case evidence")
        targets = [case for case in cases if case["classification"] in ("uncertain", "infra")]
        protected = any(case["classification"] in ("known-harness-defect", "product") for case in cases)
        retries = selection.get("retry_cases", {})
        reset = selection.get("retry_reset", [])
        for case in targets:
            case["retry_decision"] = ("once-case" if reset and case["id"] in retries
                                      else "once-smallest-selection" if reset and "retry_selection" in selection and not protected
                                      else "skipped-no-fresh-stack-selection")
        self.report(lane, box, index, cases, time.monotonic()-start, "initial")
        attempted = set()
        for case in targets:
            if case["id"] in attempted or case["classification"] not in ("uncertain", "infra"):
                continue
            retry = retries.get(case["id"], selection.get("retry_selection"))
            if not reset or retry is None:
                continue
            if case["id"] not in retries and (attempted or any(
                    row["classification"] in ("known-harness-defect", "product") for row in cases)):
                case["retry_decision"] = "skipped-overlap-or-protected-selection"
                continue
            target_ids = {case["id"]} if case["id"] in retries else {
                row["id"] for row in cases if row["classification"] in ("uncertain", "infra")}
            attempted.update(target_ids)
            for row in cases:
                if row["id"] in target_ids:
                    row["retry_decision"] = "exhausted"
            start = time.monotonic()
            for step in reset:
                if self.step(box, lane["id"], step, "retry_reset"):
                    raise Refusal("retry fresh stack reset failed")
            if self.step(box, lane["id"], self.spec["guard"], "guard"):
                raise Refusal("retry source/credential guard failed")
            retry_code = self.step(box, lane["id"], retry, "retry")
            updated = self.evidence(box, lane["id"], selection)
            latest = {row["id"]: row for row in updated}
            if not target_ids.issubset(latest):
                raise Refusal("retry evidence omitted targeted cases")
            for row in cases:
                if row["id"] in latest:
                    decision = ("exhausted" if row["id"] in attempted else
                                "not-needed" if latest[row["id"]]["status"] == "pass" else
                                "never" if latest[row["id"]]["classification"] in ("known-harness-defect", "product")
                                else row["retry_decision"])
                    row.update(latest[row["id"]], retry_decision=decision)
                    if row["id"] in target_ids and retry_code and row["status"] == "pass":
                        raise Refusal("retry command failed with passing evidence")
            self.report(lane, box, index, [row for row in cases if row["id"] in target_ids], time.monotonic()-start, "retry")
        failures = [case for case in cases if case["status"] != "pass"]
        code = 1 if failures else 0
        kinds = {case["classification"] for case in failures}
        verdict = ("known_harness_defect" if kinds == {"known-harness-defect"}
                   else "product_failure" if "product" in kinds else "uncertain_failure")
        signatures = {"cases:" + case["signature_hash"] for case in failures
                      if case["signature_hash"] != hashlib.sha256(b"").hexdigest()}
        return code, verdict, sorted(signatures)

    def cleanup(self, box):
        with self.lock:
            row = self.boxes[box]
            if row["deleted"]:
                return
        # Always capture usage before attempting deletion, even when its query fails.
        try:
            usage = client.cli("usage", box, "--json")
            if usage.get("sandboxId") != box:
                raise Refusal("usage identity mismatch")
            self.event("usage", box=box, provider=usage)
        except Exception:
            usage = {}
            self.event("usage_unavailable", box=box)
            self.cleanup_failed = True
        try:
            client.cli("delete", box, "--yes", "--json")
            end = time.monotonic() + 30
            while True:
                result = self.executor.run([client.BOAT, "info", box, "--json"], check=False)
                rows = objects(result.stdout)
                proof = rows[-1] if rows else {}
                if result.returncode and proof.get("status") == 404 and proof.get("code") == "not_found":
                    break
                if time.monotonic() >= end or result.returncode:
                    raise Refusal("deletion lacks explicit 404 proof")
                time.sleep(.2)
            self.event("deleted", box=box, proof=proof)
            with self.lock:
                row["deleted"] = True
                self.measured.pop(box, None)
                # Provider usage billing schema: dollars; if unavailable,
                # retain the full TTL reservation instead of guessing zero cost.
                cost = usage.get("dollars")
                if (isinstance(cost, (int, float)) and not isinstance(cost, bool)
                        and math.isfinite(cost) and cost >= 0):
                    self.reserved -= row["reserve"]
                    self.spent += cost
                else:
                    self.event("reservation_retained", box=box, reserved_usd=row["reserve"])
        except Exception:
            self.cleanup_failed = True
            self.event("cleanup_failed", box=box)

    def lane(self, lane):
        name, box, verdict, signature = lane["id"], None, "pass", None
        started = time.monotonic()
        phase = "create"
        try:
            box = self.create(name)
            phase = "clean_substrate"
            result = self.remote(box, name, "docker ps -aq", 30)
            if result.returncode or result.stdout.strip():
                raise Refusal("nonempty or unavailable Docker inventory")
            self.event("clean_substrate", box=box, lane=name, containers=0)
            phase = "prepare"
            for step in self.spec.get("prepare", []):
                if self.step(box, name, step, phase):
                    raise Refusal("preparation failed")
            for index, selection in enumerate(lane["selections"]):
                phase = "guard"
                if self.step(box, name, self.spec["guard"], phase):
                    raise Refusal("source/credential guard failed")
                phase = "selection"
                code, failure_verdict, case_signature = self.selection(box, lane, selection, index)
                if code:
                    verdict = failure_verdict
                    signature = case_signature or [f"selection:exit:{code}"]
                    external = self.signature(box, name, None)
                    if external:
                        signature.append(external)
                    break
        except Deadline:
            verdict, signature = "timeout", phase + ":timeout"
        except Interrupted:
            verdict = "interrupted"
        except (Refusal, client.Failure):
            verdict, signature = "harness_failure", phase + ":refused"
        except Exception:
            # Do not print arbitrary exceptions containing remote output or secrets.
            verdict, signature = "harness_failure", phase + ":exception"
        finally:
            if box and not self.stop.is_set():
                try:
                    self.fetch(box, name)
                except Exception:
                    if verdict == "pass":
                        verdict, signature = "harness_failure", "artifacts:refused"
            with self.lock:
                for failure_signature in ([signature] if isinstance(signature, str) else signature or []):
                    seen = self.signatures.setdefault(failure_signature, set())
                    seen.add(name)
                    if len(seen) >= 2:
                        self.systemic = True
                        self.event("systemic_halt", signature=failure_signature, lanes=sorted(seen))
                result = dict(lane=name, verdict=verdict, signature=signature, box=box)
                self.results.append(result)
                self.event("lane_result", **result)
            if box:
                if not self.stop.is_set():
                    for step in self.spec.get("finish", []):
                        try:
                            if self.step(box, name, step, "finish"):
                                self.cleanup_failed = True
                        except Exception:
                            self.cleanup_failed = True
                self.executor.cleaning = True
                try:
                    self.cleanup(box)
                finally:
                    self.executor.cleaning = False
            with self.lock:
                final_cases = [case for (identity, _, _), case in self.latest_cases.items() if identity == name]
            self.report(lane, box, "lane", final_cases, time.monotonic()-started, "complete", verdict)
        return verdict

    def run(self):
        old = {sig: signal.signal(sig, self.handle_signal) for sig in (signal.SIGINT, signal.SIGTERM)}
        try:
            pilot = next(lane for lane in self.spec["lanes"] if lane["id"] == self.spec["pilot"])
            verdict = self.lane(pilot)
            if verdict == "pass" and not self.cleanup_failed and not self.args.pilot_only:
                self.event("pilot_passed", lane=pilot["id"])
                others = iter(lane for lane in self.spec["lanes"] if lane is not pilot)
                with concurrent.futures.ThreadPoolExecutor(max_workers=self.args.jobs) as pool:
                    pending = set()
                    while not self.stop.is_set() and not self.systemic:
                        while len(pending) < self.args.jobs and not self.stop.is_set() and not self.systemic:
                            lane = next(others, None)
                            if lane is None:
                                break
                            pending.add(pool.submit(self.lane, lane))
                        if not pending:
                            break
                        completed, pending = concurrent.futures.wait(
                            pending, return_when=concurrent.futures.FIRST_COMPLETED)
                        for future in completed:
                            future.result()
        finally:
            self.executor.cleaning = True
            for box in self.boxes:
                if not self.boxes[box]["deleted"]:
                    self.cleanup(box)
            self.event("summary", spent_usd=round(self.spent, 8), reserved_usd=round(self.reserved, 8),
                       systemic_halt=self.systemic, results=self.results,
                       cleanup_incomplete=self.cleanup_failed, signal=self.signal)
            os.close(self.ledger)
            for sig, handler in old.items():
                signal.signal(sig, handler)
        return self.exit_code()

    def exit_code(self):
        if self.cleanup_failed:
            return 6
        if self.signal:
            return 128 + self.signal
        if self.systemic:
            return 5
        verdicts = {row["verdict"] for row in self.results}
        if "timeout" in verdicts:
            return 124
        if "harness_failure" in verdicts or "interrupted" in verdicts:
            return 3
        if verdicts & {"product_failure", "known_harness_defect", "uncertain_failure"}:
            return 4
        return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--spec", required=True)
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--cap-usd", required=True, type=float)
    parser.add_argument("--pilot-only", action="store_true")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    try:
        if not positive_number(args.cap_usd) or args.jobs < 1:
            raise Refusal("cap must be positive and jobs at least 1")
        if os.environ.get("BOAT_ORG"):
            raise Refusal("BOAT_ORG is incompatible with personal workstation scope")
        spec = json.loads(Path(args.spec).read_text())
        validate(spec)
        runner = Runner(args, spec)
    except (Refusal, ValueError, OSError):
        print("invalid input/spec or non-new run directory", file=sys.stderr)
        return 2
    code = runner.run()
    print(json.dumps(dict(exit=code, ledger=str(runner.directory / "ledger.jsonl"))))
    return code


if __name__ == "__main__":
    sys.exit(main())
