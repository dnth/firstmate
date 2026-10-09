#!/usr/bin/env python3
"""Fake Boat CLI/curl; no network or real credentials, state isolated per test."""
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


root = Path(os.environ["FAKE_BOAT_HOME"])


def mutate(callback):
    with (root / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = root / "state.json"
        state = json.loads(path.read_text()) if path.exists() else {"boxes": {}, "events": []}
        result = callback(state)
        temporary = root / "state.tmp"
        temporary.write_text(json.dumps(state))
        temporary.replace(path)
        return result


def event(kind, **fields):
    mutate(lambda state: state["events"].append(dict(event=kind, **fields)))


def main():
    if Path(sys.argv[0]).name == "curl":
        config = sys.stdin.read()
        if os.environ.get("FAKE_BOAT_MODE") == "naming-failure":
            event("naming_failed")
            return 1
        box = re.search(r"/sandboxes/(bx_[A-Za-z0-9]+)", config).group(1)
        data = next(line[7:] for line in config.splitlines() if line.startswith("data = "))
        body = json.loads(json.loads(data))
        mutate(lambda state: state["boxes"][box].update(body))
        print(json.dumps({"ok": True}))
        return 0
    args = sys.argv[1:]
    command = args[0]
    mode = os.environ.get("FAKE_BOAT_MODE", "")
    if command == "new":
        assert "--no-env" in args and "--personal" in args
        assert args[args.index("--environment") + 1] == "base"
        def create(state):
            box = "bx_" + str(len(state["boxes"]) + 1)
            state["boxes"][box] = {"deleted": False}
            state["events"].append({"event": "new", "box": box})
            return box
        box = mutate(create)
        print(json.dumps({"id": box}), flush=True)
        return 0
    if command == "ssh":
        box = args[1]
        script = sys.stdin.read().replace("/tmp/boat-lane-tests/", str(root) + "/")
        lane = re.search(r"export FM_LANE=([^\n]+)", script).group(1)
        phase = ("observer" if "# OBSERVE" in script else "finish" if "# FINISH" in script
                 else "clean" if "docker ps -aq" in script else "guard" if "# GUARD" in script
                 else "selection" if "# SELECT" in script else "prepare")
        event("ssh", box=box, lane=lane, phase=phase, pid=os.getpid(),
              retry_target="uncertain" if "# RETRY_uncertain" in script else None)
        if phase == "clean":
            if mode == "dirty":
                print("existing-docker-container")
            return 0
        if phase == "guard" and mode == "mismatch":
            return 42
        if "# HANG_LOCAL" in script:
            # Model the CLI -> SSH -> local helper tree. The leader exits on TERM;
            # its helper deliberately ignores TERM, requiring unconditional KILL.
            child = subprocess.Popen([sys.executable, "-c",
                "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(120)"])
            event("child", pid=child.pid, parent=os.getpid())
            time.sleep(120)
            return 0
        process = subprocess.Popen(["bash", "-s"], stdin=subprocess.PIPE, text=True)
        event("remote_child", pid=process.pid)
        process.communicate(script)
        return process.returncode
    if command == "scp":
        box = args[-2].split(":", 1)[0]
        event("scp", box=box)
        name = mutate(lambda state: state["boxes"].get(box, {}).get("name", ""))
        if mode == "slow-artifacts" and name.endswith(("-lane1", "-lane2")):
            event("artifact_wait", box=box)
            end = time.monotonic() + 10
            while not (root / "release-artifacts").exists() and time.monotonic() < end:
                time.sleep(.02)
        return 0
    box = args[1]
    if command == "usage":
        event("usage", box=box)
        name = mutate(lambda state: state["boxes"][box].get("name", ""))
        if mode == "slow-report" and name.endswith(("-lane1", "-lane2")):
            event("report_wait", box=box)
            end = time.monotonic() + 10
            while not (root / "release-report").exists() and time.monotonic() < end:
                time.sleep(.02)
        if mode == "usage-failure":
            return 1
        usage = {"sandboxId": box, "seconds": 100,
                 "secondsPerDollar": 100000, "sandboxType": "large"}
        if mode != "no-cost":
            usage["dollars"] = .001
        print(json.dumps(usage))
        return 0
    if command == "delete":
        event("delete", box=box)
        mutate(lambda state: state["boxes"][box].update(deleted=True))
        print(json.dumps({"operation": {"status": "pending", "targetId": box}}))
        return 0
    if command == "info":
        deleted = mutate(lambda state: state["boxes"][box]["deleted"])
        event("info", box=box)
        if deleted:
            if mode == "bad-proof":
                print(json.dumps({"status": 500, "code": "unknown"}))
            else:
                print(json.dumps({"status": 404, "code": "not_found", "error": "not found"}))
            return 1
        print(json.dumps({"id": box, "state": "running"}))
        return 0
    raise AssertionError("unexpected fake command")


if __name__ == "__main__":
    sys.exit(main())
