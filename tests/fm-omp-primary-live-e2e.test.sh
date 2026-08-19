#!/usr/bin/env bash
# Opt-in real OMP primary lifecycle on a clean project and private tmux socket.
set -u

if [ "${FM_OMP_PRIMARY_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_PRIMARY_LIVE_E2E=1 to run the isolated OMP primary lifecycle"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-primary-watch-version-lib.sh
. "$ROOT/bin/fm-primary-watch-version-lib.sh"
# shellcheck source=bin/fm-omp-process-lib.sh
. "$ROOT/bin/fm-omp-process-lib.sh"

command -v omp >/dev/null 2>&1 || fail "OMP (version unavailable) binary not found"
OMP_BIN=$("$ROOT/bin/fm-omp-capabilities.sh" --print-binary) || fail "OMP capability check failed"
OMP_VERSION=$("$OMP_BIN" --version 2>&1 | head -1) || fail "OMP version probe failed for $OMP_BIN"
[ -n "$OMP_VERSION" ] || fail "OMP version probe returned no version"
OMP_BIN=$(fm_test_realpath "$OMP_BIN") || fail "OMP binary realpath could not be resolved"
OMP_LAUNCH_IDENTITY=$(fm_omp_process_launch_identity "$OMP_BIN") \
  || fail "OMP launch identity could not be resolved for $OMP_BIN"
EXPECTED_OMP_BUN=$(printf '%s\n' "$OMP_LAUNCH_IDENTITY" | sed -n '1p')
EXPECTED_OMP_BIN=$(printf '%s\n' "$OMP_LAUNCH_IDENTITY" | sed -n '2p')
command -v tmux >/dev/null 2>&1 || fail "OMP $OMP_VERSION primary E2E requires tmux"
REAL_TMUX=$(command -v tmux)
export FM_POLL=${FM_POLL:-0.2}
export FM_SIGNAL_GRACE=${FM_SIGNAL_GRACE:-0.2}
LAB=$(fm_test_tmproot fm-omp-primary-live)
SOCKET="fm-omp-primary-live-$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/home"
SESSION_DIR="$LAB/sessions"
WRAPPER_BIN="$LAB/bin"
TARGET=primary:omp

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.omp/extensions" "$PROJECT/.agents/skills" "$PROJECT/docs" \
  "$HOME_DIR/state" "$HOME_DIR/config" "$SESSION_DIR" "$WRAPPER_BIN"
cp "$ROOT/AGENTS.md" "$ROOT/.tasks.toml" "$PROJECT/"
cp -R "$ROOT/bin" "$PROJECT/bin"
cp -R "$ROOT/docs/supervision-protocols" "$PROJECT/docs/supervision-protocols"
cp -R "$ROOT/.agents/skills/harness-adapters" "$PROJECT/.agents/skills/harness-adapters"
cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$PROJECT/.omp/extensions/fm-primary-omp.ts"
git init -q -b main "$PROJECT"
fm_git_identity fmtest fmtest@example.invalid
git -C "$PROJECT" add .
git -C "$PROJECT" commit -qm init

cat > "$WRAPPER_BIN/tmux" <<SH
#!/usr/bin/env bash
exec '$REAL_TMUX' -L '$SOCKET' "\$@"
SH
chmod +x "$WRAPPER_BIN/tmux"
PATH="$WRAPPER_BIN:$PATH" tmux new-session -d -s primary -n omp -c "$PROJECT" \
  "exec bash --noprofile --norc"

capture() {
  PATH="$WRAPPER_BIN:$PATH" tmux capture-pane -p -t "$TARGET" -S -260 2>/dev/null || true
}

composer_state() {
  PATH="$WRAPPER_BIN:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_composer_state tmux "$2" omp "$3" "$4"' \
    _ "$PROJECT" "$TARGET" "$(sed -n '3p' "$MARKER")" "$(sed -n '4p' "$MARKER")"
}

composer_text() {
  local cursor pane row text
  cursor=$(PATH="$WRAPPER_BIN:$PATH" tmux display-message -p -t "$TARGET" '#{cursor_y}') || return 1
  case "$cursor" in ''|*[!0-9]*) return 1 ;; esac
  pane=$(PATH="$WRAPPER_BIN:$PATH" tmux capture-pane -p -t "$TARGET" -S 0 -E -) || return 1
  row=$(printf '%s\n' "$pane" | sed -n "$((cursor + 1))p")
  row="${row#"${row%%[![:space:]]*}"}"
  row="${row%"${row##*[![:space:]]}"}"
  case "$row" in '╰─'*'─╯') ;; *) return 1 ;; esac
  text=${row#╰─}
  text=${text%─╯}
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

wait_idle() {
  local attempts=${1:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    if ! PATH="$WRAPPER_BIN:$PATH" bash -c \
      '. "$1/bin/fm-tmux-lib.sh"; fm_pane_is_busy "$2" omp' _ "$PROJECT" "$TARGET" \
      && [ "$(composer_state)" = empty ]; then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  capture >&2
  return 1
}

session_has_terminal_assistant_after() {
  local file=$1 offset=$2 marker=$3
  tail -c "+$((offset + 1))" "$file" | node -e '
    const marker = process.argv[1];
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => { input += chunk; });
    process.stdin.on("end", () => {
      let seen = false;
      for (const line of input.trimEnd().split("\n")) {
        if (!line) continue;
        let entry;
        try { entry = JSON.parse(line); } catch { continue; }
        const message = entry.message;
        const text = Array.isArray(message?.content)
          ? message.content.filter(part => part?.type === "text").map(part => part.text).join("\n")
          : "";
        if (message?.role === "user" && text.includes(marker)) seen = true;
        if (seen && message?.role === "assistant" && message.stopReason === "stop") process.exit(0);
      }
      process.exit(1);
    });
  ' "$marker"
}

wait_file_nonempty() {
  local file=$1 attempts=${2:-600} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -s "$file" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

wait_text() {
  local text=$1 attempts=${2:-600} i=0 pane
  while [ "$i" -lt "$attempts" ]; do
    pane=$(capture)
    printf '%s\n' "$pane" | grep -F -- "$text" >/dev/null 2>&1 && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

hash_file() {  # <adapter> <fm-root>
  local file=$1 root=$2
  command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 \
    || fail "SHA-256 utility unavailable for OMP adapter marker verification"
  fm_primary_watch_version "$file" "$root" \
    || fail "could not compute the OMP primary watcher marker version"
}

wait_pid_change() {
  local file=$1 old=${2:-} attempts=${3:-240} i=0 pid
  while [ "$i" -lt "$attempts" ]; do
    pid=$(cat "$file" 2>/dev/null || true)
    if [ -n "$pid" ] && [ "$pid" != "$old" ] && kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

submit_omp() {
  local text=$1 bun bin
  bun=$(sed -n '3p' "$MARKER")
  bin=$(sed -n '4p' "$MARKER")
  PATH="$WRAPPER_BIN:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_send_text_submit tmux "$2" "$3" 5 0.2 2 "" omp "$4" "$5"' \
    _ "$PROJECT" "$TARGET" "$text" "$bun" "$bin" >/dev/null
}

launch_omp() {
  local prompt=$1 command
  printf -v command \
    "env FM_HOME=%q FM_ROOT_OVERRIDE=%q FM_STATE_OVERRIDE=%q FM_CONFIG_OVERRIDE=%q OMP_SKIP_SETUP=1 %q --model openai-codex/gpt-5.6-sol --thinking low --session-dir %q --auto-approve %q" \
    "$HOME_DIR" "$PROJECT" "$HOME_DIR/state" "$HOME_DIR/config" "$OMP_BIN" "$SESSION_DIR" "$prompt"
  PATH="$WRAPPER_BIN:$PATH" tmux send-keys -t "$TARGET" -l "$command"
  PATH="$WRAPPER_BIN:$PATH" tmux send-keys -t "$TARGET" Enter
}

FALLBACK_PROJECT="$LAB/fallback-project"
FALLBACK_HOME="$FALLBACK_PROJECT"
FALLBACK_SESSIONS="$LAB/fallback-sessions"
mkdir -p "$FALLBACK_PROJECT/.omp/extensions" "$FALLBACK_HOME/config" "$FALLBACK_SESSIONS"
cp "$ROOT/AGENTS.md" "$FALLBACK_PROJECT/AGENTS.md"
cp -R "$ROOT/bin" "$FALLBACK_PROJECT/bin"
cp "$ROOT/.omp/extensions/fm-primary-omp.ts" \
  "$FALLBACK_PROJECT/.omp/extensions/fm-primary-omp.ts"
git init -q -b main "$FALLBACK_PROJECT"
git -C "$FALLBACK_PROJECT" add .
git -C "$FALLBACK_PROJECT" commit -qm init
PATH="$WRAPPER_BIN:$PATH" tmux new-session -d -s fallback -n omp -c "$FALLBACK_PROJECT" \
  "env FM_HOME='$FALLBACK_HOME' FM_ROOT_OVERRIDE='$FALLBACK_PROJECT' FM_CONFIG_OVERRIDE='$FALLBACK_HOME/config' OMP_SKIP_SETUP=1 '$OMP_BIN' --model openai-codex/gpt-5.6-sol --thinking low --session-dir '$FALLBACK_SESSIONS'"
wait_file_nonempty "$FALLBACK_HOME/state/.omp-primary-extension-loaded" \
  || fail "fresh plain-checkout OMP primary extension did not create state and load"
fallback_pid=$(sed -n '2p' "$FALLBACK_HOME/state/.omp-primary-extension-loaded")
FM_STATE_OVERRIDE="$FALLBACK_HOME/state" bash -c \
  '. "$1/bin/fm-session-lock-lib.sh"; fm_harness_pid_alive "$2"' \
  _ "$FALLBACK_PROJECT" "$fallback_pid" \
  || fail "fresh plain-checkout OMP extension did not retain exact process identity"
PATH="$WRAPPER_BIN:$PATH" tmux kill-session -t fallback
for _ in $(seq 1 120); do
  kill -0 "$fallback_pid" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$fallback_pid" 2>/dev/null && fail "fresh plain-checkout OMP extension did not shut down cleanly"

first_prompt="Follow the injected Firstmate startup instruction exactly once. Then run this exact bash command: bin/fm-harness.sh > '$LAB/first-harness'. Call the fm_watch_arm_omp tool exactly once. When startup and supervision are ready, reply exactly OMP_PRIMARY_READY."
launch_omp "$first_prompt"
wait_file_nonempty "$LAB/first-harness" || fail "OMP primary did not complete the injected startup instruction"
wait_text OMP_PRIMARY_READY || fail "OMP primary did not complete its first guarded turn"
[ "$(cat "$LAB/first-harness")" = omp ] || fail "OMP primary tool subprocess did not detect exact OMP ancestry"

MARKER="$HOME_DIR/state/.omp-primary-extension-loaded"
LOCK="$HOME_DIR/state/.lock"
WATCH_LOCK="$HOME_DIR/state/.watch.lock/pid"
wait_file_nonempty "$MARKER" || fail "plain OMP did not natively discover the tracked primary extension"
wait_file_nonempty "$LOCK" || fail "injected startup did not publish the primary session lock"
first_omp_pid=$(sed -n '2p' "$MARKER")
[ "$first_omp_pid" = "$(cat "$LOCK")" ] || fail "OMP loaded marker was not tied to the lock owner"
expected_version=$(hash_file "$PROJECT/.omp/extensions/fm-primary-omp.ts" "$PROJECT")
[ "$(head -n 1 "$MARKER")" = "$expected_version" ] || fail "OMP loaded marker was not tied to the adapter version"
[ "$(wc -l < "$MARKER" | tr -d '[:space:]')" = 4 ] || fail "OMP loaded marker omitted executable identity"
[ "$(sed -n '3p' "$MARKER")" = "$EXPECTED_OMP_BUN" ] \
  || fail "OMP loaded marker did not bind the resolved runtime identity"
[ "$(sed -n '4p' "$MARKER")" = "$EXPECTED_OMP_BIN" ] \
  || fail "OMP loaded marker did not bind the selected OMP entrypoint identity"
FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c \
  '. "$1/bin/fm-session-lock-lib.sh"; fm_harness_pid_alive "$2"' _ "$PROJECT" "$first_omp_pid" \
  || fail "real OMP process-title identity did not satisfy the exact Bun argv boundary"
first_watch_pid=$(wait_pid_change "$WATCH_LOCK") || fail "fm_watch_arm_omp did not establish a live watcher child"

session_file=$(find "$SESSION_DIR" -maxdepth 1 -type f -name '*.jsonl' -print | head -1)
[ -n "$session_file" ] || fail "OMP primary did not persist its session"
[ "$(grep -Fc '"customType":"firstmate-sessionstart-nudge"' "$session_file")" -eq 1 ] \
  || fail "OMP initial startup instruction was not injected exactly once"
grep -F '"attribution":"agent"' "$session_file" >/dev/null \
  || fail "OMP startup instruction was attributed to the captain instead of the adapter"

sessions_before=$(find "$SESSION_DIR" -maxdepth 1 -type f -name '*.jsonl' | wc -l | tr -d ' ')
submit_omp /new || fail "OMP /new command was not submitted"
second_watch_pid=$(wait_pid_change "$WATCH_LOCK" "$first_watch_pid") \
  || fail "OMP /new did not replace and restore the extension-owned watcher generation"
submit_omp 'Reply exactly OMP_NEW_READY.' || fail "new OMP session did not accept a prompt"
wait_text OMP_NEW_READY || fail "new OMP session did not complete its first turn"
for _ in $(seq 1 240); do
  sessions_after=$(find "$SESSION_DIR" -maxdepth 1 -type f -name '*.jsonl' | wc -l | tr -d ' ')
  [ "$sessions_after" -gt "$sessions_before" ] && break
  sleep 0.25
done
[ "${sessions_after:-0}" -gt "$sessions_before" ] || fail "OMP /new did not create a native session"
[ "$(grep -Rhc '"customType":"firstmate-sessionstart-nudge"' "$SESSION_DIR"/*.jsonl | awk '{s+=$1} END{print s+0}')" -eq 2 ] \
  || fail "OMP /new did not inject exactly one startup instruction for the new session"

submit_omp /exit || fail "OMP primary /exit was not submitted"
for _ in $(seq 1 240); do
  kill -0 "$first_omp_pid" 2>/dev/null || break
  sleep 0.25
done
kill -0 "$first_omp_pid" 2>/dev/null && fail "OMP primary did not exit cleanly"
for _ in $(seq 1 120); do
  kill -0 "$second_watch_pid" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$second_watch_pid" 2>/dev/null && fail "OMP shutdown left its watcher generation alive"

resume_prompt="Follow the injected Firstmate startup instruction exactly once after this resume. Then run this exact bash command: bin/fm-harness.sh > '$LAB/resume-harness'. Call the fm_watch_arm_omp tool exactly once. Reply exactly OMP_RESUME_READY."
printf -v resume_command \
  "env FM_HOME=%q FM_ROOT_OVERRIDE=%q FM_STATE_OVERRIDE=%q FM_CONFIG_OVERRIDE=%q OMP_SKIP_SETUP=1 %q --model openai-codex/gpt-5.6-sol --thinking low --session-dir %q --resume %q --auto-approve %q" \
  "$HOME_DIR" "$PROJECT" "$HOME_DIR/state" "$HOME_DIR/config" "$OMP_BIN" "$SESSION_DIR" "$session_file" "$resume_prompt"
PATH="$WRAPPER_BIN:$PATH" tmux send-keys -t "$TARGET" -l "$resume_command"
PATH="$WRAPPER_BIN:$PATH" tmux send-keys -t "$TARGET" Enter
wait_file_nonempty "$LAB/resume-harness" || fail "resumed OMP primary did not reclaim startup ownership"
wait_text OMP_RESUME_READY || fail "resumed OMP primary did not complete its guarded turn"
[ "$(cat "$LAB/resume-harness")" = omp ] || fail "resumed OMP subprocess lost exact harness identity"
second_omp_pid=$(sed -n '2p' "$MARKER")
[ "$second_omp_pid" != "$first_omp_pid" ] || fail "OMP resume marker retained the exited process identity"
[ "$second_omp_pid" = "$(cat "$LOCK")" ] || fail "OMP resume did not bind the lock to the new process"
resume_watch_pid=$(wait_pid_change "$WATCH_LOCK" "$second_watch_pid") \
  || fail "OMP resume did not restore a live watcher generation"
[ "$(grep -Rhc '"customType":"firstmate-sessionstart-nudge"' "$SESSION_DIR"/*.jsonl | awk '{s+=$1} END{print s+0}')" -eq 3 ] \
  || fail "OMP process resume did not add exactly one fresh startup instruction"
kill -0 "$resume_watch_pid" 2>/dev/null || fail "OMP resume watcher is not live"

touch "$HOME_DIR/state/.afk"
away_offset=$(wc -c < "$session_file" | tr -d '[:space:]')
PATH="$WRAPPER_BIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SUPERVISOR_TARGET="$TARGET" FM_SUPERVISOR_BACKEND=tmux \
  FM_SUPERVISOR_HARNESS=omp FM_SUPERVISOR_OMP_BUN="$(sed -n '3p' "$MARKER")" \
  FM_SUPERVISOR_OMP_BIN="$(sed -n '4p' "$MARKER")" \
  FM_INJECT_CONFIRM_RETRIES=5 FM_INJECT_CONFIRM_SLEEP=0.2 \
  bash -c '. "$1/bin/fm-supervise-daemon.sh"; inject_msg "OMP_AWAY_DELIVERY" "$2"' \
    _ "$PROJECT" "$HOME_DIR/state" \
  || fail "OMP idle composer did not accept an away-mode notification"
for _ in $(seq 1 120); do
  session_has_terminal_assistant_after "$session_file" "$away_offset" OMP_AWAY_DELIVERY && break
  sleep 0.25
done
session_has_terminal_assistant_after "$session_file" "$away_offset" OMP_AWAY_DELIVERY \
  || fail "OMP $OMP_VERSION away-mode turn did not reach a terminal assistant record"
grep -R -F 'OMP_AWAY_DELIVERY' "$SESSION_DIR"/*.jsonl >/dev/null 2>&1 \
  || fail "OMP away-mode notification was acknowledged but not persisted"
grep -R -F 'away-supervisor' "$SESSION_DIR"/*.jsonl >/dev/null 2>&1 \
  || fail "OMP away-mode notification lost its operational-input kind"
wait_idle || fail "OMP $OMP_VERSION did not reach an idle boundary after away-mode delivery"
printf 'ok - OMP %s primary E2E proved fresh no-state and ordinary native discovery, exact ownership, once-only startup, guarded watcher startup, /new continuity, shutdown, resume, and away-mode delivery\n' \
  "$OMP_VERSION"
draft="human-draft-survives-omp-watcher-wake"
PATH="$WRAPPER_BIN:$PATH" tmux send-keys -t "$TARGET" -l "$draft"
[ "$(composer_state)" = pending ] && [ "$(composer_text)" = "$draft" ] \
  || { capture >&2; fail "OMP $OMP_VERSION did not render the exact editable draft before the watcher wake"; }
wake_status="$HOME_DIR/state/omp-wake-preserve-$$.status"
wake_offset=$(wc -c < "$session_file" | tr -d '[:space:]')
printf 'done: omp watcher draft preservation probe\n' > "$wake_status"
wake_seen=0
for _ in $(seq 1 240); do
  if tail -c "+$((wake_offset + 1))" "$session_file" \
    | grep -F '"customType":"firstmate-watcher-wake"' \
    | grep -F 'FIRSTMATE_OP: v1 watcher:' \
    | grep -F -- "$wake_status" >/dev/null 2>&1; then
    wake_seen=1
    break
  fi
  sleep 0.25
done
[ "$wake_seen" -eq 1 ] || fail "OMP $OMP_VERSION watcher wake was not delivered to the session"
[ "$(composer_state)" = pending ] && [ "$(composer_text)" = "$draft" ] \
  || { capture >&2; fail "OMP $OMP_VERSION watcher wake changed the exact editable draft"; }

printf 'ok - OMP %s primary E2E proved watcher delivery with an intact editable draft\n' "$OMP_VERSION"
PATH="$WRAPPER_BIN:$PATH" tmux send-keys -t "$TARGET" Escape
submit_omp /exit || fail "OMP $OMP_VERSION did not accept cleanup after draft preservation"
