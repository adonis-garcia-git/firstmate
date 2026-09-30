#!/usr/bin/env bash
# Behavior tests for the Claude Code PreCompact handoff hook
# (bin/fm-precompact-handoff.sh, docs/sessionstart-nudge.md "Pre-compaction
# handoff").
#
# The hook runs hermetically against a fixture home with a copied bin/, a stub
# backlog listing, and hand-built Claude-shaped transcripts, so no real home,
# model, or backlog is touched. Every case also asserts the never-block
# contract: exit 0 and empty stdout, whatever happens.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || fail "test host must provide jq"

TMP_ROOT=$(fm_test_tmproot fm-precompact-handoff)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

BEGIN_MARK='<!-- fm-precompact-handoff:begin -->'
END_MARK='<!-- fm-precompact-handoff:end -->'

install_hook_scripts() {
  local dir=$1 script
  mkdir -p "$dir/bin"
  for script in fm-precompact-handoff.sh fm-gate-refuse-lib.sh fm-primary-scope-lib.sh \
    fm-session-lock-lib.sh fm-cursor-lib.sh fm-hook-host-lib.sh fm-timeout-lib.sh \
    fm-operational-input.sh; do
    cp "$ROOT/bin/$script" "$dir/bin/$script"
  done
  chmod +x "$dir/bin/fm-precompact-handoff.sh"
  # Answers like the real listing: the requested extra fields follow the title,
  # which may itself hold commas.
  cat > "$dir/bin/fm-tasks-axi.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *hold_reason*)
    printf 'count: 1\ntasks[1]{id,state,kind,repo,title,hold_kind,hold_reason}:\n'
    printf '  held-1,queued,task,demo,"TITLE-SENTINEL, with a comma",captain,REASON-SENTINEL patient said\n'
    ;;
  *)
    printf 'count: 1\ntasks[1]{id,state,kind,repo,title,hold_kind}:\n'
    printf '  held-1,queued,task,demo,"TITLE-SENTINEL, with a comma",captain\n'
    ;;
esac
SH
  chmod +x "$dir/bin/fm-tasks-axi.sh"
}

make_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state" "$dir/data"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_hook_scripts "$dir"
  printf 'kind=ship\npr=https://example.invalid/pr/7\n' > "$dir/state/task-a.meta"
  printf 'working [at=1]: started\npaused [at=2]: WORKER-SENTINEL waiting on https://example.invalid/pr/7\n' \
    > "$dir/state/task-a.status"
  printf '%s\n' "$dir"
}

# payload <transcript> [trigger] [custom]
payload() {
  jq -nc --arg t "$1" --arg trigger "${2:-manual}" --arg custom "${3:-}" '{
    session_id: "sess-1", transcript_path: $t, cwd: "/", hook_event_name: "PreCompact",
    trigger: $trigger, custom_instructions: (if $custom == "" then null else $custom end)
  }'
}

# run_hook <dir> <payload>: runs the hook, asserts exit 0 and empty stdout.
run_hook() {
  local dir=$1 body=$2 out rc=0
  out=$(printf '%s' "$body" | env -u NO_MISTAKES_GATE FM_HOME="$dir" \
    "$dir/bin/fm-precompact-handoff.sh" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || fail "the hook exited $rc; it must always exit 0 so compaction is never blocked"
  [ -z "$out" ] || fail "the hook wrote to stdout: $out"
}

record_field() {  # <dir> <key>
  sed -n "s/^$2=//p" "$1/state/.precompact-handoff"
}

block_of() {  # <dir>
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0 == b { f = 1; next } $0 == e { f = 0 } f' \
    "$1/data/session-handoff.md"
}

# A transcript in current Claude Code shape: genuine captain turns carry
# origin.kind "human"; wakes, tool results, meta records, compaction summaries,
# and sidechains must never read as captain words.
write_origin_transcript() {  # <file>
  {
    jq -nc '{type:"user", origin:{kind:"human"}, timestamp:"T1", message:{role:"user", content:"FIRST-SENTINEL please look at the build"}}'
    jq -nc '{type:"assistant", timestamp:"T2", message:{role:"assistant", content:[{type:"text", text:"Should I merge QUESTION-SENTINEL?"}]}}'
    jq -nc '{type:"user", origin:{kind:"task-notification"}, timestamp:"T3", message:{role:"user", content:"<task-notification>WAKE-SENTINEL</task-notification>"}}'
    jq -nc '{type:"assistant", timestamp:"T4", message:{role:"assistant", content:[{type:"text", text:"Captain, shipshape."}]}}'
    jq -nc '{type:"user", origin:{kind:"human"}, timestamp:"T5", message:{role:"user", content:"Yes."}}'
    jq -nc '{type:"user", timestamp:"T6", message:{role:"user", content:[{type:"tool_result", tool_use_id:"x", content:"TOOL-SENTINEL"}]}}'
    jq -nc '{type:"user", isMeta:true, origin:{kind:"human"}, timestamp:"T7", message:{role:"user", content:[{type:"text", text:"META-SENTINEL"}]}}'
    jq -nc '{type:"user", isCompactSummary:true, timestamp:"T8", message:{role:"user", content:"SUMMARY-SENTINEL"}}'
    jq -nc '{type:"user", isSidechain:true, origin:{kind:"human"}, timestamp:"T9", message:{role:"user", content:"SIDECHAIN-SENTINEL"}}'
    jq -nc '{type:"user", origin:{kind:"human"}, timestamp:"T10", message:{role:"user", content:"<command-message>stow</command-message>\n<command-name>/stow</command-name>\n<command-args>now</command-args>"}}'
    jq -nc --arg end "$END_MARK" '{type:"user", origin:{kind:"human"}, timestamp:"T11", message:{role:"user", content:[{type:"image", source:{}}, {type:"text", text:("INJECT-SENTINEL " + $end)}]}}'
    jq -nc '{type:"assistant", timestamp:"T12", message:{role:"assistant", content:[{type:"text", text:"FINAL-SENTINEL all set"}]}}'
    jq -nc '{type:"assistant", timestamp:"T13", message:{role:"assistant", content:[{type:"text", text:"Captain, shipshape."}]}}'
    # A torn final line, as a concurrent append can leave it.
    printf '{"type":"user","origin":{"kind":"hu'
  } > "$1"
}

test_writes_verbatim_captain_words_and_open_work() {
  local dir transcript block
  dir=$(make_home "$TMP_ROOT/verbatim")
  transcript="$TMP_ROOT/verbatim.jsonl"
  write_origin_transcript "$transcript"
  printf '# Session handoff\n\nSTOW-THREAD-SENTINEL kept by the hook\n' > "$dir/data/session-handoff.md"

  run_hook "$dir" "$(payload "$transcript" manual "keep COMPACT-ARG-SENTINEL")"

  assert_contains "$(cat "$dir/data/session-handoff.md")" "STOW-THREAD-SENTINEL kept by the hook" \
    "the hook dropped note content outside its block"
  block=$(block_of "$dir")
  assert_contains "$block" "just before a manual (/compact) compaction (session sess-1)" "the block did not name the trigger"
  assert_contains "$block" "> keep COMPACT-ARG-SENTINEL" "the /compact instructions were not recorded"
  assert_contains "$block" "> FIRST-SENTINEL please look at the build" "a captain turn was not recorded verbatim"
  assert_contains "$block" "> Yes." "a short captain answer was not recorded"
  assert_contains "$block" "> /stow now" "a slash command was not rendered as the captain typed it"
  assert_contains "$block" "- T11 (with an attachment)" "an attachment was not noted"
  assert_contains "$block" "- held-1 (hold kind: captain)" "a held backlog item's id and kind were not recorded"
  assert_contains "$block" "- task-a (ship) pr=https://example.invalid/pr/7" "a task record was not recorded"
  local sentinel
  for sentinel in WAKE-SENTINEL TOOL-SENTINEL META-SENTINEL SUMMARY-SENTINEL SIDECHAIN-SENTINEL; do
    assert_not_contains "$block" "$sentinel" "a non-captain record was recorded as captain words"
  done
  [ "$(grep -cxF "$END_MARK" "$dir/data/session-handoff.md")" -eq 1 ] \
    || fail "captain text forged a block marker"

  [ "$(record_field "$dir" status)" = ok ] || fail "the result record did not say ok"
  [ "$(record_field "$dir" trigger)" = manual ] || fail "the result record lost the trigger"
  [ "$(record_field "$dir" turns)" = 4 ] || fail "expected 4 captain turns, got $(record_field "$dir" turns)"
  [ "$(record_field "$dir" transcript)" = "$transcript" ] || fail "the result record lost the transcript path"
  pass "the hook records verbatim captain words and open-work identifiers, and keeps the rest of the note"
}

# The note carries only the captain's own words plus identifiers. Firstmate's
# replies, worker status lines, backlog titles, and hold reasons can quote
# patient or worker text, so none of them may reach it.
test_carries_no_dropped_fields() {
  local dir transcript note sentinel
  dir=$(make_home "$TMP_ROOT/dropped")
  transcript="$TMP_ROOT/dropped.jsonl"
  write_origin_transcript "$transcript"
  run_hook "$dir" "$(payload "$transcript")"
  note=$(cat "$dir/data/session-handoff.md")
  for sentinel in QUESTION-SENTINEL FINAL-SENTINEL "Captain, shipshape." WORKER-SENTINEL \
    TITLE-SENTINEL REASON-SENTINEL "In reply to" "last status" "last reply"; do
    assert_not_contains "$note" "$sentinel" "the note carried a field outside the captain's words and identifiers"
  done
  assert_contains "$note" "> FIRST-SENTINEL please look at the build" "the captain's words were dropped too"
  pass "the note carries no firstmate replies, worker status lines, backlog titles, or hold reasons"
}

test_replaces_its_block_in_place() {
  local dir transcript
  dir=$(make_home "$TMP_ROOT/replace")
  transcript="$TMP_ROOT/replace.jsonl"
  write_origin_transcript "$transcript"
  printf 'BEFORE-SENTINEL\n' > "$dir/data/session-handoff.md"
  run_hook "$dir" "$(payload "$transcript")"
  printf 'AFTER-SENTINEL\n' >> "$dir/data/session-handoff.md"

  jq -nc '{type:"user", origin:{kind:"human"}, timestamp:"T99", message:{role:"user", content:"SECOND-RUN-SENTINEL"}}' > "$transcript"
  run_hook "$dir" "$(payload "$transcript" auto)"

  [ "$(grep -cxF "$BEGIN_MARK" "$dir/data/session-handoff.md")" -eq 1 ] || fail "a second run duplicated the block"
  assert_contains "$(block_of "$dir")" "SECOND-RUN-SENTINEL" "the second run did not refresh the block"
  assert_contains "$(block_of "$dir")" "just before an automatic compaction" "the block did not name an automatic trigger"
  assert_not_contains "$(block_of "$dir")" "FIRST-SENTINEL" "the second run kept stale captain words"
  assert_contains "$(head -n 1 "$dir/data/session-handoff.md")" "BEFORE-SENTINEL" "content before the block moved"
  assert_contains "$(tail -n 1 "$dir/data/session-handoff.md")" "AFTER-SENTINEL" "content after the block moved"
  pass "a later compaction replaces the block in place and leaves the surrounding note untouched"
}

test_keeps_only_the_most_recent_turns() {
  local dir transcript i
  dir=$(make_home "$TMP_ROOT/bounded")
  transcript="$TMP_ROOT/bounded.jsonl"
  : > "$transcript"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    jq -nc --arg i "$i" '{type:"user", origin:{kind:"human"}, timestamp:("T" + $i), message:{role:"user", content:("TURN-" + $i + "-END")}}' >> "$transcript"
  done
  run_hook "$dir" "$(payload "$transcript")"
  [ "$(record_field "$dir" turns)" = 10 ] || fail "expected the 10 most recent turns, got $(record_field "$dir" turns)"
  assert_not_contains "$(block_of "$dir")" "TURN-2-END" "an old turn beyond the bound was kept"
  assert_contains "$(block_of "$dir")" "TURN-3-END" "the oldest in-bound turn was dropped"
  assert_contains "$(block_of "$dir")" "TURN-12-END" "the newest turn was dropped"
  local order
  order=$(block_of "$dir" | grep -o 'TURN-[0-9]*-END' | tr '\n' ' ')
  [ "$order" = "TURN-12-END TURN-11-END TURN-10-END TURN-9-END TURN-8-END TURN-7-END TURN-6-END TURN-5-END TURN-4-END TURN-3-END " ] \
    || fail "captain turns were not newest first: $order"
  pass "the block keeps only the most recent captain turns"
}

test_records_no_turns_without_origin() {
  local dir transcript
  dir=$(make_home "$TMP_ROOT/no-origin")
  transcript="$TMP_ROOT/no-origin.jsonl"
  jq -nc '{type:"user", message:{role:"user", content:"NO-ORIGIN-SENTINEL merge it"}}' > "$transcript"
  run_hook "$dir" "$(payload "$transcript")"
  assert_not_contains "$(block_of "$dir")" "NO-ORIGIN-SENTINEL" "a record without origin was recorded as captain words"
  assert_contains "$(block_of "$dir")" "(no captain turns found in the transcript)" "the block did not say no turns were found"
  [ "$(record_field "$dir" status)" = ok ] || fail "a transcript without origin was not recorded as ok"
  [ "$(record_field "$dir" turns)" = 0 ] || fail "expected 0 captain turns without origin, got $(record_field "$dir" turns)"
  pass "a transcript with no origin field records no captain turns"
}

# Claude Code records firstmate's own typed operational input with
# origin.kind "human": a record-backed doorbell, one whose record has since been
# pruned, and an envelope. None is the captain's word, and none may push the
# captain's turns out of the window.
test_skips_firstmate_operational_input() {
  local dir transcript doorbell pruned record envelope block i
  dir=$(make_home "$TMP_ROOT/operational")
  transcript="$TMP_ROOT/operational.jsonl"
  doorbell=$(printf 'DOORBELL-BODY-SENTINEL' | FM_STATE_OVERRIDE="$dir/state" \
    "$ROOT/bin/fm-operational-input.sh" record away-supervisor) || fail "could not write an operational record"
  pruned=$(printf 'PRUNED-BODY-SENTINEL' | FM_STATE_OVERRIDE="$dir/state" \
    "$ROOT/bin/fm-operational-input.sh" record away-supervisor) || fail "could not write an operational record"
  record=$(printf '%s' "$pruned" | sed "s/^[^']*'//; s/'.*\$//")
  rm "$record" || fail "could not prune the operational record $record"
  envelope=$(printf 'ENVELOPE-BODY-SENTINEL' | "$ROOT/bin/fm-operational-input.sh" encode watcher) \
    || fail "could not encode an operational envelope"
  {
    jq -nc '{type:"user", origin:{kind:"human"}, timestamp:"T0", message:{role:"user", content:"AWAY-BRIEF-SENTINEL hold the fort"}}'
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
      jq -nc --arg d "$pruned" '{type:"user", origin:{kind:"human"}, message:{role:"user", content:$d}}'
      jq -nc --arg d "$doorbell" '{type:"user", origin:{kind:"human"}, message:{role:"user", content:$d}}'
    done
    jq -nc --arg e "$envelope" '{type:"user", origin:{kind:"human"}, message:{role:"user", content:$e}}'
  } > "$transcript"
  run_hook "$dir" "$(payload "$transcript" auto)"
  block=$(block_of "$dir")
  assert_contains "$block" "> AWAY-BRIEF-SENTINEL hold the fort" "firstmate's doorbells pushed the captain's words out"
  assert_not_contains "$block" "Firstmate operational input waiting" "a doorbell was recorded as captain words"
  assert_not_contains "$block" "ENVELOPE-BODY-SENTINEL" "an operational envelope was recorded as captain words"
  [ "$(record_field "$dir" turns)" = 1 ] || fail "expected 1 captain turn, got $(record_field "$dir" turns)"
  pass "firstmate's own typed operational input is not recorded as captain words"
}

test_missing_transcript_still_writes_open_work() {
  local dir
  dir=$(make_home "$TMP_ROOT/no-transcript")
  run_hook "$dir" "$(payload "$TMP_ROOT/does-not-exist.jsonl")"
  [ "$(record_field "$dir" status)" = partial ] || fail "a missing transcript was not recorded as partial"
  assert_contains "$(record_field "$dir" reason)" "transcript not readable" "the partial reason was not recorded"
  assert_contains "$(block_of "$dir")" "- task-a (ship) pr=https://example.invalid/pr/7" \
    "open work was not written without a transcript"
  pass "a missing transcript still writes the open-work snapshot and records a partial result"
}

test_failures_step_aside_without_blocking() {
  local dir transcript before bare
  dir=$(make_home "$TMP_ROOT/unwritable")
  transcript="$TMP_ROOT/unwritable.jsonl"
  write_origin_transcript "$transcript"
  printf 'UNTOUCHED-SENTINEL\n' > "$dir/data/session-handoff.md"
  chmod 555 "$dir/data"
  if [ -w "$dir/data" ]; then
    chmod 755 "$dir/data"
    printf '# skip: running as a user that ignores directory permissions\n'
  else
    run_hook "$dir" "$(payload "$transcript")"
    chmod 755 "$dir/data"
    [ "$(record_field "$dir" status)" = failed ] || fail "an unwritable note was not recorded as failed"
    assert_contains "$(record_field "$dir" reason)" "$dir/data" "the failure reason did not name the location"
    [ "$(cat "$dir/data/session-handoff.md")" = UNTOUCHED-SENTINEL ] || fail "a failed run changed the note"
  fi

  dir=$(make_home "$TMP_ROOT/malformed")
  run_hook "$dir" 'not json'
  [ "$(record_field "$dir" status)" = failed ] || fail "a malformed payload was not recorded as failed"
  [ ! -e "$dir/data/session-handoff.md" ] || fail "a malformed payload wrote a note"

  dir=$(make_home "$TMP_ROOT/no-jq")
  bare="$TMP_ROOT/no-jq-bin"
  mkdir -p "$bare"
  local tool path
  for tool in bash cat date mktemp mv rm sed awk grep tail cut basename dirname tr git ps head env uname; do
    path=$(command -v "$tool") || continue
    ln -sf "$path" "$bare/$tool"
  done
  before=$(payload "$transcript")
  local out rc=0
  out=$(printf '%s' "$before" | env -u NO_MISTAKES_GATE PATH="$bare" FM_HOME="$dir" \
    "$bare/bash" "$dir/bin/fm-precompact-handoff.sh" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || fail "without jq the hook exited $rc or wrote stdout: $out"
  [ "$(record_field "$dir" status)" = failed ] || fail "a missing jq was not recorded as failed"
  assert_contains "$(record_field "$dir" reason)" "jq is not installed" "the missing-jq reason was not recorded"
  pass "an unwritable note, a malformed payload, and a missing jq all step aside with exit 0 and a recorded reason"
}

test_out_of_scope_sessions_never_write() {
  local dir base wt transcript
  transcript="$TMP_ROOT/scope.jsonl"
  write_origin_transcript "$transcript"

  base="$TMP_ROOT/scope-base"
  wt="$TMP_ROOT/scope-worktree"
  fm_git_worktree "$base" "$wt" fm/precompact-test
  mkdir -p "$wt/state" "$wt/data"
  : > "$wt/AGENTS.md"
  install_hook_scripts "$wt"
  run_hook "$wt" "$(payload "$transcript")"
  [ ! -e "$wt/data/session-handoff.md" ] && [ ! -e "$wt/state/.precompact-handoff" ] \
    || fail "a linked task worktree wrote a handoff"

  dir=$(make_home "$TMP_ROOT/gate")
  local out rc=0
  out=$(payload "$transcript" | NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 FM_HOME="$dir" "$dir/bin/fm-precompact-handoff.sh" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || fail "a gate agent run exited $rc or wrote stdout"
  [ ! -e "$dir/data/session-handoff.md" ] || fail "a no-mistakes gate agent wrote a handoff"

  dir=$(make_home "$TMP_ROOT/cursor")
  run_hook "$dir" "$(payload "$transcript" | jq -c '. + {cursor_version: "2026.08.11"}')"
  [ ! -e "$dir/data/session-handoff.md" ] || fail "a Cursor-delivered payload wrote a handoff"

  dir=$(make_home "$TMP_ROOT/pi-code")
  run_hook "$dir" "$(payload "$TMP_ROOT/.pi/sessions/s.jsonl")"
  [ ! -e "$dir/data/session-handoff.md" ] || fail "a pi-code-delivered payload wrote a handoff"
  pass "task worktrees, gate agents, and Cursor or pi-code payloads never write a handoff"
}

test_lock_ownership_decides_authority() {
  local dir transcript holder rc=0 out
  transcript="$TMP_ROOT/lock.jsonl"
  write_origin_transcript "$transcript"

  dir=$(make_home "$TMP_ROOT/foreign-lock")
  # The trailing no-op stops bash from exec-ing sleep, so the holder stays a
  # harness-shaped process.
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  holder=$!
  # The backgrounded child is still a plain bash fork until it execs the fake
  # harness; wait for the harness shape so the lock names a live owner.
  local tries=0
  until bash -c '. "$1"; fm_harness_pid_alive "$2"' _ "$ROOT/bin/fm-session-lock-lib.sh" "$holder"; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || fail "the fake lock holder never became a live harness"
    sleep 0.1
  done
  printf '%s\n' "$holder" > "$dir/state/.lock"
  # In production Claude runs the hook, so this session's own harness ancestry
  # resolves; a second fake harness gives the hook that ancestry here. The
  # trailing no-op keeps bash from exec-ing the hook in the harness's place.
  out=$(payload "$transcript" | env -u NO_MISTAKES_GATE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-precompact-handoff.sh"; :' 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || fail "a non-owner run exited $rc or wrote stdout"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ ! -e "$dir/data/session-handoff.md" ] || fail "a session without the fleet lock wrote over the lock holder's handoff"

  dir=$(make_home "$TMP_ROOT/own-lock")
  out=$(payload "$transcript" | env -u NO_MISTAKES_GATE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$FM_HOME/bin/fm-precompact-handoff.sh"
    :
  ' 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || fail "the lock holder's run exited $rc or wrote stdout"
  [ "$(record_field "$dir" status)" = ok ] || fail "the lock-holding session did not write its handoff"

  dir=$(make_home "$TMP_ROOT/dead-lock")
  printf '999999\n' > "$dir/state/.lock"
  run_hook "$dir" "$(payload "$transcript")"
  [ "$(record_field "$dir" status)" = ok ] || fail "a stale lock stopped the handoff"
  pass "only a session another live session holds the lock against steps aside"
}

test_writes_verbatim_captain_words_and_open_work
test_carries_no_dropped_fields
test_replaces_its_block_in_place
test_keeps_only_the_most_recent_turns
test_records_no_turns_without_origin
test_skips_firstmate_operational_input
test_missing_transcript_still_writes_open_work
test_failures_step_aside_without_blocking
test_out_of_scope_sessions_never_write
test_lock_ownership_decides_authority

echo "# fm-precompact-handoff.test.sh: all assertions passed"
