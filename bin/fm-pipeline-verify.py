#!/usr/bin/env python3
"""Validate Pipeline identity and fingerprint post-ready integrity only.

Pre-ready status and test-result edits are not detected; they become the
trusted fingerprint when PR-ready accepts the block.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import sys


def verify(response, mode, worktree, url, check_digest, expected_digest):
    body = response["data"]["repository"]["pullRequest"]["body"] or ""
    head = response["data"]["repository"]["pullRequest"]["headRefOid"]
    headings = list(re.finditer(r"(?m)^##[ \t]+Pipeline[ \t]*\r?$", body))
    if not headings:
        if mode == "no-mistakes" or expected_digest:
            raise ValueError("the PR body has no '## Pipeline' section; keep it verbatim")
        return ""
    if len(headings) != 1:
        raise ValueError("the PR body must have exactly one '## Pipeline' section")
    start = headings[0].start()
    following = re.search(r"(?m)^##[ \t]+", body[headings[0].end():])
    end = headings[0].end() + following.start() if following else len(body)
    pipeline = body[start:end]
    matches = re.findall(
        r"(?m)^<!-- no-mistakes-pipeline-attestation:v1 (.+) -->[ \t]*\r?$", pipeline)
    if not matches:
        raise ValueError("the PR body's '## Pipeline' section carries no intact No-Mistakes attestation")
    if len(matches) != 1:
        raise ValueError("the PR body's '## Pipeline' section must carry exactly one No-Mistakes attestation")
    try:
        att = json.loads(matches[0])
        steps = att["steps"]
        valid = (re.fullmatch(r"[0-9a-f]{40}", att["head_sha"]) and
                 isinstance(steps, list) and bool(steps) and
                 all(isinstance(s["step"], str) and s["step"] and
                     isinstance(s["status"], str) and s["status"] for s in steps))
    except (ValueError, TypeError, KeyError):
        valid = False
    if not valid:
        raise ValueError("the PR body's No-Mistakes attestation is malformed; keep it verbatim")
    if att["head_sha"] != head:
        raise ValueError(f"the PR body's No-Mistakes attestation is for head {att['head_sha']}, not the PR head {head}")
    table = re.search(
        r"(?im)^\|[ \t]*(?:Test|Scenario)[ \t]*\|[ \t]*(?:Result|Status)[ \t]*\|[^\n]*\n"
        r"\|[ \t]*:?-+:?[ \t]*\|[ \t]*:?-+:?[ \t]*\|[^\n]*\n"
        r"\|[ \t]*[^\s|][^\n]*\|[ \t]*[^\s|][^\n]*\|", pipeline)
    if not table:
        raise ValueError("the PR body's '## Pipeline' section has no test table; keep it verbatim")
    digest = hashlib.sha256(pipeline.encode("utf-8")).hexdigest()
    if check_digest == "1":
        if not re.fullmatch(r"[0-9a-f]{64}", expected_digest):
            raise ValueError("the PR's Pipeline digest is missing or malformed; report PR-ready before merging")
        if digest != expected_digest:
            raise ValueError("the PR's Pipeline digest changed since PR-ready; keep the exact Pipeline block verbatim")
    root = Path(os.environ.get("NM_HOME") or Path.home() / ".no-mistakes")
    if not root.is_absolute():
        if not worktree:
            raise ValueError("the local No-Mistakes run record is unavailable without its worktree")
        root = Path(worktree) / root
    path = root / "state.sqlite"
    if not path.is_file():
        raise ValueError("the local No-Mistakes run record is unavailable for Pipeline head_sha")
    try:
        db = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=1)
        try:
            with db:
                run = db.execute(
                    "SELECT id FROM runs WHERE head_sha = ? AND pr_url = ? "
                    "ORDER BY created_at DESC LIMIT 1", (head, url)).fetchone()
                if run is None:
                    raise ValueError("the local No-Mistakes run record has no matching Pipeline head_sha and PR")
                names = [row[0] for row in db.execute(
                    "SELECT step_name FROM step_results WHERE run_id = ? ORDER BY step_order", (run[0],))]
        finally:
            db.close()
    except sqlite3.Error as exc:
        raise ValueError("the local No-Mistakes run record is unavailable for Pipeline validation") from exc
    if [s["step"] for s in steps] != names:
        raise ValueError("the No-Mistakes attestation step names do not match the local run")
    return digest


if __name__ == "__main__":
    try:
        with open(sys.argv[1], encoding="utf-8") as source:
            result = verify(json.load(source), *sys.argv[2:])
        if result:
            print(result)
    except (ValueError, KeyError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
