#!/usr/bin/env bash
# Behavior tests for bin/fm-tasks-axi.sh's body-safety contract:
#
#   append-note <id> (--body|--body-file) adds text to the existing body
#   (joined by a blank line) instead of replacing it, and verifies the stored
#   result.
#
#   update|edit --body|--body-file without --archive-body refuses (exit 2,
#   nothing written) when the stored body is non-empty and the new text does
#   not contain it verbatim; --archive-body replaces while archiving, and a
#   replace that keeps the prior text proceeds unflagged.
#
# The tests drive the real wrapper and real tasks-axi CLI against a fixture
# home with a markdown backlog, asserting stored bodies via `show --full` -
# never the wrapper's source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# An exported TASKS_AXI_BACKEND would outrank each case's .tasks.toml fixture.
unset TASKS_AXI_BACKEND || :

TASKS="$ROOT/bin/fm-tasks-axi.sh"
TMP_ROOT=$(fm_test_tmproot fm-tasks-axi)

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed; the body guard and append-note are inert without it)\n'
  exit 0
}

# --- fixture ----------------------------------------------------------------

make_home() {  # <name> -> <home>
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/data"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  printf '%s\n' "$home"
}

add_item() {  # <home> <id> [body]
  local home=$1 id=$2 body=${3-}
  if [ $# -ge 3 ]; then
    FM_HOME=$home "$TASKS" add "$id" "item for $id" --kind ship --body "$body" >/dev/null \
      || fail "could not add $id"
  else
    FM_HOME=$home "$TASKS" add "$id" "item for $id" --kind ship >/dev/null \
      || fail "could not add $id"
  fi
}

# Decoded body via the wrapper's own read surface (`show --full`).
body_of() {  # <home> <id>
  local out line
  out=$(FM_HOME=$1 "$TASKS" show "$2" --full) || fail "show --full failed for $2: $out"
  line=$(printf '%s\n' "$out" | sed -n 's/^  body: //p')
  case "$line" in
    \"*)
      printf '%s' "$line" | node -e '
        let s = "";
        process.stdin.on("data", (d) => { s += d; });
        process.stdin.on("end", () => { process.stdout.write(JSON.parse(s)); });
      ' || fail "could not decode the stored body of $2"
      ;;
    *) printf '%s' "$line" ;;
  esac
}

# --- append-note ------------------------------------------------------------

test_append_note_keeps_the_prior_body_and_adds_text() {
  local home id prior new_text body
  home=$(make_home append-keeps)
  id=append-keep-t1
  prior='a: "b"

multi	line'
  new_text='evidence: all green'
  add_item "$home" "$id" "$prior"

  FM_HOME=$home "$TASKS" append-note "$id" --body "$new_text" >/dev/null \
    || fail "append-note failed"

  body=$(body_of "$home" "$id")
  assert_contains "$body" "$prior" "append-note dropped the prior body"
  assert_contains "$body" "$new_text" "append-note did not store the new text"
  case "$body" in
    *"$prior"$'\n\n'"$new_text") : ;;
    *) fail "append-note did not join prior and new text in order: $body" ;;
  esac
  assert_absent "$home/data/note-archive.md" "append-note must not archive the kept body"
  pass "append-note keeps the prior body and appends the new text"
}

test_append_note_to_an_empty_body_stores_just_the_text() {
  local home id body
  home=$(make_home append-empty)
  id=append-empty-t2
  add_item "$home" "$id"

  FM_HOME=$home "$TASKS" append-note "$id" --body 'first note' >/dev/null \
    || fail "append-note on an empty body failed"
  body=$(body_of "$home" "$id")
  assert_equals 'first note' "$body" "append-note on an empty body stored the wrong text"
  pass "append-note on an empty body stores just the new text"
}

test_append_note_body_file_resolves_against_the_caller_directory() {
  local home id caller body
  home=$(make_home append-file)
  id=append-file-t3
  caller="$TMP_ROOT/append-file/caller"
  mkdir -p "$caller"
  printf 'file note text\n' > "$caller/note.md"
  add_item "$home" "$id" 'existing body'

  (cd "$caller" && FM_HOME=$home "$TASKS" append-note "$id" --body-file note.md) >/dev/null \
    || fail "append-note --body-file with a relative path failed"
  body=$(body_of "$home" "$id")
  assert_equals "$(printf 'existing body\n\nfile note text')" "$body" \
    "append-note --body-file stored the wrong body"
  pass "append-note resolves a relative --body-file against the caller directory"
}

test_append_note_on_a_missing_id_fails_and_writes_nothing() {
  local home out status=0
  home=$(make_home append-missing)
  out=$(FM_HOME=$home "$TASKS" append-note nope-t4 --body 'x' 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "append-note on a missing id succeeded"
  assert_no_grep 'nope-t4' "$home/data/backlog.md" "append-note wrote a row for a missing id"
  assert_absent "$home/data/note-archive.md" "append-note archived on a missing id"
  pass "append-note on a missing id fails and writes nothing"
}

# --- replace guard ----------------------------------------------------------

test_update_body_file_dropping_the_body_is_refused() {
  local home id status=0 out body
  home=$(make_home refuse-file)
  id=refuse-file-t5
  add_item "$home" "$id" 'considered body'
  printf 'unrelated replacement\n' > "$TMP_ROOT/refuse-file/new.md"

  out=$(FM_HOME=$home "$TASKS" update "$id" --body-file "$TMP_ROOT/refuse-file/new.md" 2>&1) || status=$?
  expect_code 2 "$status" "update --body-file dropping a non-empty body"
  assert_contains "$out" "append-note" "refusal did not point at append-note"
  assert_contains "$out" "--archive-body" "refusal did not name --archive-body"
  body=$(body_of "$home" "$id")
  assert_equals 'considered body' "$body" "a refused replace still changed the body"
  assert_absent "$home/data/note-archive.md" "a refused replace left an archive"
  pass "update --body-file dropping a non-empty body is refused"
}

test_update_body_text_dropping_the_body_is_refused() {
  local home id status=0 body
  home=$(make_home refuse-body)
  id=refuse-body-t6
  add_item "$home" "$id" 'considered body'

  FM_HOME=$home "$TASKS" update "$id" --body 'unrelated replacement' >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "update --body dropping a non-empty body"
  body=$(body_of "$home" "$id")
  assert_equals 'considered body' "$body" "a refused --body replace still changed the body"
  pass "update --body dropping a non-empty body is refused"
}

test_edit_alias_dropping_the_body_is_refused() {
  local home id status=0 body
  home=$(make_home refuse-edit)
  id=refuse-edit-t7
  add_item "$home" "$id" 'considered body'

  FM_HOME=$home "$TASKS" edit "$id" --body 'unrelated replacement' >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "edit --body dropping a non-empty body"
  body=$(body_of "$home" "$id")
  assert_equals 'considered body' "$body" "a refused edit still changed the body"
  pass "edit --body dropping a non-empty body is refused"
}

test_update_with_archive_body_replaces_and_archives() {
  local home id body
  home=$(make_home archive-replace)
  id=archive-t8
  add_item "$home" "$id" 'considered body'
  printf 'unrelated replacement\n' > "$TMP_ROOT/archive-replace/new.md"

  FM_HOME=$home "$TASKS" update "$id" --body-file "$TMP_ROOT/archive-replace/new.md" --archive-body >/dev/null \
    || fail "update --archive-body was refused or failed"
  body=$(body_of "$home" "$id")
  assert_equals 'unrelated replacement' "$body" "--archive-body did not store the new body"
  assert_grep 'considered body' "$home/data/note-archive.md" \
    "--archive-body did not archive the prior body"
  pass "update --archive-body replaces the body and archives the old one"
}

test_update_keeping_the_prior_body_proceeds_without_the_flag() {
  local home id body
  home=$(make_home keep-prior)
  id=keep-prior-t9
  add_item "$home" "$id" 'considered body'

  FM_HOME=$home "$TASKS" update "$id" --body "$(printf 'considered body\n\nand more')" >/dev/null \
    || fail "a replace containing the prior body was refused"
  body=$(body_of "$home" "$id")
  assert_equals "$(printf 'considered body\n\nand more')" "$body" \
    "a containing replace stored the wrong body"
  pass "a replace whose new text contains the prior body proceeds"
}

test_update_of_an_empty_body_proceeds_without_the_flag() {
  local home id body
  home=$(make_home empty-replace)
  id=empty-replace-t10
  add_item "$home" "$id"

  FM_HOME=$home "$TASKS" update "$id" --body 'fresh body' >/dev/null \
    || fail "a replace of an empty body was refused"
  body=$(body_of "$home" "$id")
  assert_equals 'fresh body' "$body" "an empty-body replace stored the wrong body"
  pass "a replace of an empty body proceeds without --archive-body"
}

# --- runner -----------------------------------------------------------------

test_append_note_keeps_the_prior_body_and_adds_text
test_append_note_to_an_empty_body_stores_just_the_text
test_append_note_body_file_resolves_against_the_caller_directory
test_append_note_on_a_missing_id_fails_and_writes_nothing
test_update_body_file_dropping_the_body_is_refused
test_update_body_text_dropping_the_body_is_refused
test_edit_alias_dropping_the_body_is_refused
test_update_with_archive_body_replaces_and_archives
test_update_keeping_the_prior_body_proceeds_without_the_flag
test_update_of_an_empty_body_proceeds_without_the_flag

printf 'ok - fm-tasks-axi: all cases passed\n'
