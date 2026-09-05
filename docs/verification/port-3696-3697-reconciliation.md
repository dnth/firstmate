# Upstream PR reconciliation

On 2026-09-05, this fork was compared with upstream PRs #3696 (`3c1e86d7`) and #3697 (`d43e610b`).

The fork already had keyed status folding, answerer-side `--resolve-key`, durable pending-reply records, and correlated parent-status resolution.

PR #3696 was ported by making reserved `pending-reply-*` closes use the pending-reply owner vocabulary and by verifying that the key is closed after the append.

PR #3697 was adapted to the fork's existing parent-channel surface by restating a correlated line from a same-basename secondmate status file before missed-reply escalation.

The broader upstream parent-channel helper rewrite was omitted because this fork does not contain that newer parent-channel library or its dependent publisher migration.

Verification commands were `tests/fm-send-resolve-key.test.sh` and `tests/fm-pending-reply.test.sh`.
