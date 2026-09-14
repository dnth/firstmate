# Treehouse pool audit verification

Audience: maintainer verification.

This record supports the session-start `TREEHOUSE_POOL` audit guarantees: a dirty ownerless idle slot is reported even on a multi-user Linux host, and an unleased `treehouse-state.json` entry with no backing `git worktree list` registration surfaces as the distinct orphan diagnostic.
Operator behavior and limits remain in `docs/configuration.md`; the mechanism stays in `bin/fm-treehouse-status-read-only.sh` and `bin/fm-bootstrap.sh`.

## Multi-user Linux occupancy (EACCES)

Checked 2026-09-14 on a Linux 6.17 host where roughly 400 of 852 `/proc` entries deny `cwd` reads with EACCES.

Before the fix, `bin/fm-treehouse-status-read-only.sh /home/dnth/Desktop/firstmate` printed nothing while pool slots 8, 15, and 17 were dirty and ownerless.

After the fix, the same command prints:

```json
{"slot":"15","path":"/home/dnth/.treehouse/firstmate-e1905f/15/firstmate"}
{"slot":"17","path":"/home/dnth/.treehouse/firstmate-e1905f/17/firstmate"}
{"slot":"8","path":"/home/dnth/.treehouse/firstmate-e1905f/8/firstmate"}
```

The portable regression is `test_treehouse_audit_eacces_and_orphans` in `tests/fm-bootstrap.test.sh`, which simulates a foreign-owned `/proc` entry with a mode-000 pid directory and proves the dirty slot still reports while a genuinely occupied slot stays suppressed.
Run: `bin/fm-test-run.sh tests/fm-bootstrap.test.sh` -> `exit=0` on 2026-09-14.

## Orphan diagnostic class

Checked 2026-09-14 against the live pools documented in the `treehouse-hygiene-astra-debug` scout report.

`bin/fm-treehouse-status-read-only.sh /home/dnth/Desktop/firstmate/projects/superfk-aceh` prints:

```json
{"slot":"21","path":"/home/dnth/.treehouse/superfk-aceh-f7e8ed/21/superfk-aceh","orphan":true}
```

`bin/fm-treehouse-status-read-only.sh /home/dnth/Desktop/firstmate/projects/infoconnect-search-engine` prints:

```json
{"slot":"3","path":"/home/dnth/.treehouse/infoconnect-search-engine-f4e2f3/3/infoconnect-search-engine","orphan":true}
{"slot":"5","path":"/home/dnth/.treehouse/infoconnect-search-engine-f4e2f3/5/infoconnect-search-engine","orphan":true}
```

Slot 21 is foreign-administered through a dead home's gitdir; slots 3 and 5 are damaged directories with no `.git` marker.
Bootstrap renders each record as `TREEHOUSE_POOL: orphaned slot <slot> at <path> - no registered worktree; inspect before cleanup; no changes made` and takes no action.

Known residual: a pool whose every slot is foreign-administered never reaches the state diff, because no listed worktree maps back to its `treehouse-state.json`.
