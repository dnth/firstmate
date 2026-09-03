#!/usr/bin/env bash
# Publish a turn-end notification into this incarnation's OWN per-generation
# marker, lock-free.
#
# Usage:
#   fm-turnend-signal.sh <state-dir> <task-id> <spawn-gen>
#
# Every per-task harness turn-end surface (the Claude/OpenCode/Pi/OMP hooks, the
# Codex notify command, the Grok/Kimi global registries, and Hermes) embeds the
# spawn_gen minted by fm-spawn.sh and calls this writer. Incarnation gating lives
# on the CONSUMER side (bin/fm-wake-lib.sh, driven by the watcher), so this writer
# takes no lock and makes no live/stale decision. It has to satisfy three
# properties a turn-end publish must meet at once, which publisher-side gating on
# the shared meta lock cannot:
#   - never drop:  a live worker's completion must always be recorded;
#   - never block: fm-teardown holds the task meta lock while stopping the harness,
#                  so a synchronous Stop/turn-end hook that blocked on it would
#                  deadlock teardown;
#   - never re-fire or clobber: a torn-down or relaunched incarnation must neither
#                  wake firstmate nor overwrite a live incarnation's completion.
# The marker is per generation: state/<id>.turn-ended.<spawn_gen>. Because each
# incarnation writes only its OWN gen file, a delayed older-incarnation hook can
# never clobber a newer live incarnation's marker. The consumer reads the live
# spawn_gen from the task metadata and looks only at that gen's marker, so a
# stale gen file is simply never read, and teardown removes every gen for the id.
set -u

STATE_DIR=${1:-}
ID=${2:-}
SPAWN_GEN=${3:-}

case "$ID" in
  ''|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
case "$SPAWN_GEN" in
  ''|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
[ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || exit 0

# This incarnation's own marker. touch creates it or updates its mtime for each
# turn-end; no other incarnation ever writes this file, so there is nothing to
# clobber and no lock to take.
touch -- "$STATE_DIR/$ID.turn-ended.$SPAWN_GEN" 2>/dev/null || true
exit 0
