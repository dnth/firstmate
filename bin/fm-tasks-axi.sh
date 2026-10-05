#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh append-note <id> (--body <text> | --body-file <path>) [--json]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# `append-note` is a wrapper-owned command, not a tasks-axi verb: it adds text
# to a task's existing body (joined by a blank line; appended to an empty body
# it becomes the whole body) instead of replacing it, then re-reads the stored
# body and verifies the write landed as intended. Use it for evidence and
# follow-up notes; the prior body is kept inline, so no archive entry is made.
#
# Because `update`/`edit --body|--body-file` replaces the whole body, this
# wrapper guards it: without `--archive-body` it reads the current body first
# and refuses (exit 2, nothing written) when that body is non-empty and the
# new text does not contain it verbatim. To genuinely replace a considered
# body, re-run with `--archive-body` so tasks-axi preserves the old body in
# <data>/note-archive.md; to add text, use `append-note`. The guard reads the
# prior body from `tasks-axi show <id> --full` - the only exact read surface,
# since `show` and `list` have no `--json` - and fails closed when that read
# cannot yield exactly one `body:` line or its value cannot be decoded.
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - `add` (or its `create` alias) with --start, so neither spelling places a
#     row In flight without the dispatch artifacts bin/fm-spawn.sh creates -
#     the task record, status file, and inbox that go with the row - which such
#     a row would lack, counting as live work nobody is doing that nothing
#     later would notice (`start <id>` stays a documented direct transition);
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file;
#   - `update`/`edit` with `--body`/`--body-file` and no `--archive-body` when
#     the stored body is non-empty and the new text does not contain it - use
#     `append-note` to add text, or `--archive-body` to replace while
#     archiving the old body.
# Otherwise the exit status is tasks-axi's own.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

append_note_usage() {
  cat <<'EOF'
Usage: fm-tasks-axi.sh append-note <id> (--body <text> | --body-file <path>) [--json]

Append text to a task's existing body, joined by a blank line, instead of
replacing the body the way `update --body`/`--body-file` does. To replace a
considered body, run `update <id> --body-file <path> --archive-body` so the
old body is archived into <data>/note-archive.md.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  append-note)
    for arg in "${@:2}"; do
      case "$arg" in
        -h|--help)
          append_note_usage
          exit 0
          ;;
      esac
    done
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"

# read_prior_body <id>: print the task's current decoded body to stdout.
# `show --full` is the only exact read (show/list reject --json); its `body:`
# line is a bare value or a JSON-quoted string, decoded with node's JSON.parse
# because jq is optional. Fails closed: a failed show exits with its status,
# anything but exactly one decodable body line exits 2.
read_prior_body() {
  local id=$1 out status count line decoded
  out=$(tasks-axi show "$id" --full 2>&1) || {
    status=$?
    printf '%s\n' "$out" >&2
    exit "$status"
  }
  count=$(printf '%s\n' "$out" | grep -c '^  body: ' || :)
  line=$(printf '%s\n' "$out" | sed -n 's/^  body: //p')
  if [ "$count" -ne 1 ]; then
    printf 'fm-tasks-axi: cannot read the current body of %s; refusing to write\n' "$id" >&2
    exit 2
  fi
  case "$line" in
    \"*)
      if ! decoded=$(printf '%s' "$line" | node -e '
        let s = "";
        process.stdin.on("data", (d) => { s += d; });
        process.stdin.on("end", () => { process.stdout.write(JSON.parse(s)); });
      '); then
        printf 'fm-tasks-axi: cannot read the current body of %s; refusing to write\n' "$id" >&2
        exit 2
      fi
      ;;
    *)
      decoded=$line
      ;;
  esac
  printf '%s' "$decoded"
}

strip_trailing_newlines() {  # stdin -> stdout
  local s
  s=$(cat)
  while [ "$s" != "${s%$'\n'}" ]; do
    s=${s%$'\n'}
  done
  printf '%s' "$s"
}

APPEND_TMP=
append_cleanup() {
  [ -z "$APPEND_TMP" ] || rm -f -- "$APPEND_TMP"
}

# append-note <id> (--body <text> | --body-file <path>) [--json]
cmd_append_note() {
  local id= have_body=0 have_file=0 body_text= body_file= json_flag=0
  local i arg new_text prior new_body status stored
  for ((i = 1; i < ${#ARGS[@]}; i++)); do
    arg=${ARGS[i]}
    case "$arg" in
      --body)
        have_body=1
        i=$((i + 1))
        body_text=${ARGS[i]-}
        ;;
      --body=*)
        have_body=1
        body_text=${arg#*=}
        ;;
      --body-file)
        have_file=1
        i=$((i + 1))
        body_file=${ARGS[i]-}
        ;;
      --body-file=*)
        have_file=1
        body_file=${arg#*=}
        ;;
      --json)
        json_flag=1
        ;;
      -*)
        append_note_usage >&2
        fail "append-note: unknown flag $arg"
        ;;
      *)
        [ -z "$id" ] || { append_note_usage >&2; fail "append-note: unexpected extra argument $arg"; }
        id=$arg
        ;;
    esac
  done
  if [ -z "$id" ] || [ "$have_body" = "$have_file" ]; then
    append_note_usage >&2
    exit 2
  fi
  if [ "$have_file" = 1 ]; then
    [ -r "$body_file" ] || fail "append-note: cannot read --body-file $body_file"
    new_text=$(cat -- "$body_file")
  else
    new_text=$(printf '%s' "$body_text" | strip_trailing_newlines)
  fi
  [ -n "$new_text" ] || fail "append-note: the note text is empty"

  prior=$(read_prior_body "$id") || exit $?
  if [ -n "$prior" ]; then
    new_body=$(printf '%s\n\n%s' "$prior" "$new_text")
  else
    new_body=$new_text
  fi

  APPEND_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tasks-axi-append.XXXXXX") \
    || fail "append-note: cannot stage the new body"
  trap append_cleanup EXIT
  printf '%s\n' "$new_body" > "$APPEND_TMP" || fail "append-note: cannot stage the new body"
  local -a update_args=(update "$id" --body-file "$APPEND_TMP")
  [ "$json_flag" = 0 ] || update_args+=(--json)
  status=0
  tasks-axi "${update_args[@]}" || status=$?
  [ "$status" -eq 0 ] || exit "$status"

  stored=$(read_prior_body "$id") || exit $?
  if [ "$stored" != "$new_body" ]; then
    {
      printf 'fm-tasks-axi: append-note wrote %s but the stored body does not match what was intended; nothing is lost - the prior body was:\n' "$id"
      printf '%s\n' "$prior"
    } >&2
    exit 2
  fi
}

# Refuse `update`/`edit --body|--body-file` (without --archive-body) when the
# stored body is non-empty and the new text does not contain it verbatim - the
# tell-tale shape of a caller that meant to append.
guard_body_replace() {
  local id=${ARGS[1]-} body_seen=0 archive_seen=0 body_file= new_text= prior i arg
  [ "${id#-}" = "$id" ] || return 0
  for ((i = 2; i < ${#ARGS[@]}; i++)); do
    arg=${ARGS[i]}
    case "$arg" in
      --archive-body) archive_seen=1 ;;
      --body) body_seen=1; i=$((i + 1)); new_text=${ARGS[i]-} ;;
      --body=*) body_seen=1; new_text=${arg#*=} ;;
      --body-file) body_seen=1; i=$((i + 1)); body_file=${ARGS[i]-} ;;
      --body-file=*) body_seen=1; body_file=${arg#*=} ;;
    esac
  done
  [ "$body_seen" = 1 ] || return 0
  [ "$archive_seen" = 0 ] || return 0
  if [ -n "$body_file" ]; then
    # An unreadable body file is tasks-axi's own error to report.
    [ -r "$body_file" ] || return 0
    new_text=$(cat -- "$body_file" 2>/dev/null) || return 0
  fi
  prior=$(read_prior_body "$id") || exit $?
  [ -n "$prior" ] || return 0
  [[ $new_text == *"$prior"* ]] && return 0
  printf 'fm-tasks-axi: refusing to replace the non-empty body of %s: the new body does not contain the existing text. Use append-note to add text, or re-run with --archive-body to replace it while archiving the old body.\n' "$id" >&2
  exit 2
}

case "${ARGS[0]-}" in
  append-note)
    cmd_append_note
    exit $?
    ;;
  update|edit)
    guard_body_replace
    ;;
esac

exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
