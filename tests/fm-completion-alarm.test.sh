#!/usr/bin/env bash
# tests/fm-completion-alarm.test.sh - the completion-alarm contract
# (bin/fm-completion-alarm-lib.sh, the watcher's paced escalation, and
# teardown cleanup).
#
# Incident background (2026-08-23/24, twice): workers reached done: and parked
# awaiting merge, but the supervising session never surfaced it - the
# done-status append's wake was lost or collapsed, and a lapsed watcher chain
# surfaced nothing at all. The contract under test:
#   - The tick reconciles each live task's CURRENT state (fm-crew-state.sh via
#     FM_CREW_STATE_BIN), never the status log's last line alone, and arms one
#     durable record per terminal state (done/failed/parked/blocked).
#   - The same persisting terminal state escalates exactly one actionable
#     check wake past the window - never a second wake for the same episode.
#   - A task that resumes clears its record; a NEW terminal state restarts the
#     episode and may alarm again.
#   - A healthy idle secondmate, a declared paused: external wait, a provably
#     busy endpoint (e.g. a worker composing a gate response), and a done task
#     with an armed merge poll never alarm.
#   - The durable records and truth-based scan make a completion that
#     happened while no watcher ran alarm after a restart, without
#     duplicating an already-escalated episode.
#   - Teardown clears the task's leftover record and only that task's.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
fm_git_identity fmtest fmtest@example.invalid

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
ALARM_LIB="$ROOT/bin/fm-completion-alarm-lib.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-completion-alarm-tests)

# One shared fake current-state reader for the unit-level ticks; the canned
# verdict comes from FM_FAKE_CREW_STATE (or a per-id override) per call.
FAKE_CREW=$(make_fake_crew_state "$TMP_ROOT")

# --- helpers ----------------------------------------------------------------

# Run one lib function in a subshell scoped to <state>, with the fake
# current-state reader and canned verdict, so sourcing the wake lib never
# binds this test shell's globals to one case's state dir.
# tick_with <state> <crew-state-line> [now]
tick_with() {
  local state=$1 verdict=$2 now=${3:-}
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$FAKE_CREW" \
    FM_FAKE_CREW_STATE="$verdict" FM_COMPLETION_ALARM_NOW="$now" bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    # shellcheck disable=SC1090
    . "$2"
    fm_completion_alarm_tick "$3"
  ' _ "$WAKE_LIB" "$ALARM_LIB" "$state"
}

# Same tick, with a stubbed semantic busy classifier returning <busy-verdict>.
tick_with_busy() {  # <state> <crew-state-line> <busy-verdict> [now]
  local state=$1 verdict=$2 busy=$3 now=${4:-}
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$FAKE_CREW" \
    FM_FAKE_CREW_STATE="$verdict" FM_COMPLETION_ALARM_NOW="$now" \
    FM_FAKE_BUSY_VERDICT="$busy" bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    # shellcheck disable=SC1090
    . "$2"
    fm_busy_classify_meta() { printf "%s" "$FM_FAKE_BUSY_VERDICT"; }
    fm_completion_alarm_tick "$3"
  ' _ "$WAKE_LIB" "$ALARM_LIB" "$state"
}

# arm_record <state> <task> <terminal-state> <detail> [first-epoch]
arm_record() {
  local state=$1 task=$2 tstate=$3 detail=$4 now=${5:-}
  FM_COMPLETION_ALARM_NOW="$now" bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    fm_completion_alarm_arm "$2" "$3" "$4" "$5"
  ' _ "$ALARM_LIB" "$state" "$task" "$tstate" "$detail"
}

record_path() {  # <state> <task>
  printf '%s/pending-completions/%s' "$1" "$2"
}

queue_alarm_count() {  # <state> <task>
  local q="$1/.wake-queue"
  if [ -f "$q" ]; then
    grep -c "completion-alarm-$2" "$q" || true
  else
    printf '0\n'
  fi
}

epoch_ago() {  # <seconds>
  printf '%s' "$(( $(date +%s) - $1 ))"
}

DONE_LINE='state: done · source: run-step · checks green: PR ready for review'
PARKED_LINE='state: parked · source: run-step · parked at approval: 2 finding(s)'
WORKING_LINE='state: working · source: run-step · validating (running)'
PAUSED_LINE='state: paused · source: status-log · waiting on upstream release'

# --- lib tick behavior ------------------------------------------------------

test_tick_arms_then_escalates_exactly_once() {
  local state out rec
  state="$TMP_ROOT/tick-once/state"; mkdir -p "$state"
  fm_write_meta "$state/helm.meta" "kind=ship"
  out=$(tick_with "$state" "$DONE_LINE") || fail "first tick failed"
  [ -z "$out" ] || fail "first sighting escalated before the window: $out"
  rec=$(record_path "$state" helm)
  assert_present "$rec" "first sighting should arm a durable record"
  assert_grep "state=done" "$rec" "record should carry the terminal state"
  [ ! -e "$state/.wake-queue" ] || fail "tick queued a wake inside the window"
  out=$(tick_with "$state" "$DONE_LINE" "$(( $(date +%s) + 400 ))") || fail "escalation tick failed"
  assert_contains "$out" "check: completion-alarm: helm done unsurfaced" \
    "tick should print the actionable reason naming task and state"
  [ "$(queue_alarm_count "$state" helm)" = 1 ] \
    || fail "exactly one durable wake expected after the first escalation"
  grep -qE '^escalated_epoch=[0-9]+$' "$rec" || fail "record should carry the escalation epoch"
  out=$(tick_with "$state" "$DONE_LINE" "$(( $(date +%s) + 800 ))") || fail "post-escalation tick failed"
  [ -z "$out" ] || fail "a later tick re-nagged the same completion episode: $out"
  [ "$(queue_alarm_count "$state" helm)" = 1 ] \
    || fail "a later tick queued a duplicate wake for the same episode"
  pass "completion tick arms on first sighting and escalates exactly once past the window"
}

test_tick_alarms_parked_gate() {
  local state out
  state="$TMP_ROOT/tick-parked/state"; mkdir -p "$state"
  fm_write_meta "$state/helm.meta" "kind=ship"
  arm_record "$state" helm parked "parked at approval" "$(epoch_ago 400)"
  out=$(tick_with "$state" "$PARKED_LINE") || fail "tick failed"
  assert_contains "$out" "check: completion-alarm: helm parked unsurfaced" \
    "a persisting parked gate should escalate like done"
  pass "completion tick escalates a persisting parked (needs-decision/gate) state"
}

test_tick_clears_on_resume_and_rearms_for_new_completion() {
  local state out rec
  state="$TMP_ROOT/tick-resume/state"; mkdir -p "$state"
  fm_write_meta "$state/helm.meta" "kind=ship"
  arm_record "$state" helm parked "parked at approval" "$(epoch_ago 400)"
  rec=$(record_path "$state" helm)
  out=$(tick_with "$state" "$WORKING_LINE") || fail "tick failed"
  [ -z "$out" ] || fail "a resumed task was escalated: $out"
  assert_absent "$rec" "a resumed task must drop its record"
  [ ! -e "$state/.wake-queue" ] || fail "a resumed task queued a wake"
  # The next completion is a fresh episode and alarms again after its window.
  out=$(tick_with "$state" "$DONE_LINE") || fail "re-arm tick failed"
  assert_present "$rec" "a later completion should arm a fresh record"
  out=$(tick_with "$state" "$DONE_LINE" "$(( $(date +%s) + 400 ))") || fail "re-arm escalation failed"
  assert_contains "$out" "check: completion-alarm: helm done unsurfaced" \
    "the fresh completion episode should escalate"
  pass "completion tick clears on resume and re-arms cleanly for the next completion"
}

test_tick_state_change_restarts_episode() {
  local state out rec
  state="$TMP_ROOT/tick-restate/state"; mkdir -p "$state"
  fm_write_meta "$state/helm.meta" "kind=ship"
  arm_record "$state" helm parked "parked at approval" "$(epoch_ago 4000)"
  out=$(tick_with "$state" "$DONE_LINE") || fail "tick failed"
  [ -z "$out" ] || fail "a NEW terminal state escalated from the old episode's window: $out"
  rec=$(record_path "$state" helm)
  assert_grep "state=done" "$rec" "record should restart on the new terminal state"
  [ ! -e "$state/.wake-queue" ] || fail "the restarted episode escalated immediately"
  pass "a different terminal state restarts the completion episode and its window"
}

test_tick_never_alarms_secondmate() {
  local state out
  state="$TMP_ROOT/tick-mate/state"; mkdir -p "$state"
  fm_write_meta "$state/domain.meta" "kind=secondmate"
  arm_record "$state" domain done "stray record" "$(epoch_ago 4000)"
  out=$(tick_with "$state" "$DONE_LINE") || fail "tick failed"
  [ -z "$out" ] || fail "a healthy idle secondmate was escalated: $out"
  assert_absent "$(record_path "$state" domain)" "a secondmate's stray record must be dropped"
  [ ! -e "$state/.wake-queue" ] || fail "a secondmate produced a completion wake"
  pass "a healthy idle secondmate never arms or fires the completion alarm"
}

test_tick_never_alarms_declared_pause() {
  local state out
  state="$TMP_ROOT/tick-pause/state"; mkdir -p "$state"
  fm_write_meta "$state/helm.meta" "kind=ship"
  arm_record "$state" helm done "stale record" "$(epoch_ago 4000)"
  out=$(tick_with "$state" "$PAUSED_LINE") || fail "tick failed"
  [ -z "$out" ] || fail "a declared external-wait pause was escalated: $out"
  assert_absent "$(record_path "$state" helm)" "a declared pause must drop the record"
  [ ! -e "$state/.wake-queue" ] || fail "a declared pause produced a completion wake"
  pass "a declared paused: external wait never fires the completion alarm"
}

test_tick_defers_while_endpoint_busy() {
  local state out
  state="$TMP_ROOT/tick-busy/state"; mkdir -p "$state"
  fm_write_meta "$state/helm.meta" "kind=ship"
  arm_record "$state" helm parked "parked at approval" "$(epoch_ago 4000)"
  out=$(tick_with_busy "$state" "$PARKED_LINE" "busy claude-hook") || fail "tick failed"
  [ -z "$out" ] || fail "a provably busy worker (mid gate-response) was escalated: $out"
  assert_absent "$(record_path "$state" helm)" "a busy endpoint must drop the record"
  [ ! -e "$state/.wake-queue" ] || fail "a busy endpoint produced a completion wake"
  # Anything short of the exact busy verdict keeps detection armed.
  out=$(tick_with_busy "$state" "$PARKED_LINE" "unknown missing") || fail "tick failed"
  assert_present "$(record_path "$state" helm)" \
    "a non-busy verdict must arm detection (surface bias)"
  pass "a provably busy endpoint defers the completion alarm; unknown does not"
}

test_tick_holds_done_with_armed_merge_poll() {
  local state out rec
  state="$TMP_ROOT/tick-poll/state"; mkdir -p "$state"
  fm_write_meta "$state/helm.meta" "kind=ship"
  arm_record "$state" helm done "checks green" "$(epoch_ago 4000)"
  : > "$state/helm.pr-poll"
  out=$(tick_with "$state" "$DONE_LINE") || fail "tick failed"
  [ -z "$out" ] || fail "a done task being actively landed (armed merge poll) was escalated: $out"
  rec=$(record_path "$state" helm)
  assert_present "$rec" "the held record is preserved while the poll is armed"
  [ ! -e "$state/.wake-queue" ] || fail "an actively landed task produced a completion wake"
  rm -f "$state/helm.pr-poll"
  out=$(tick_with "$state" "$DONE_LINE") || fail "tick failed"
  assert_contains "$out" "check: completion-alarm: helm done unsurfaced" \
    "a retired poll with the task still done should escalate"
  pass "a done task with an armed merge poll is held without alarming"
}

test_tick_clears_orphaned_record() {
  local state out
  state="$TMP_ROOT/tick-orphan/state"; mkdir -p "$state"
  arm_record "$state" gone done "old completion" "$(epoch_ago 4000)"
  out=$(tick_with "$state" "$DONE_LINE") || fail "tick failed"
  [ -z "$out" ] || fail "an orphaned record (no task meta) was escalated: $out"
  assert_absent "$(record_path "$state" gone)" "orphaned record must be removed"
  pass "completion tick removes records whose task is gone"
}

# --- watcher end-to-end -----------------------------------------------------

watch_bg() {  # <state> <fakebin> <out> <crew-state-line>
  local state=$1 fakebin=$2 out=$3 verdict=$4
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE="$verdict" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_COMPLETION_ALARM_WINDOW_SECS=2 FM_COMPLETION_SCAN_INTERVAL=1 \
    "$WATCH" > "$out" &
}

test_watcher_alarms_lost_completion_and_rearms_after_restart() {
  local dir state out rc
  dir=$(make_case completion-watch); state="$dir/state"
  # A done-and-parked worker whose completion wake never reached a session:
  # the status append is marked already-seen (the lost/collapsed wake) and the
  # meta records no window, so neither the signal nor the stale path can
  # surface it - only the truth-based completion alarm can.
  fm_write_meta "$state/helm.meta" "kind=ship"
  printf 'done: PR https://example.invalid/pr/7 checks green\n' > "$state/helm.status"
  prime_status_seen "$state" "$state/helm.status"
  watch_bg "$state" "$dir/fakebin" "$dir/out" "$DONE_LINE"
  rc=0
  wait_for_exit $! 150 || rc=$?
  [ "$rc" != 124 ] || fail "watcher did not exit on the unsurfaced completion"
  out=$(cat "$dir/out")
  assert_contains "$out" "check: completion-alarm: helm done unsurfaced" \
    "watcher should surface the completion alarm naming task and state"
  [ "$(queue_alarm_count "$state" helm)" = 1 ] \
    || fail "watcher should have queued exactly one durable completion wake"

  # A relaunched watcher re-surfaces the still-unhandled durable wake through
  # the recovery reason - never as a duplicate completion record.
  watch_bg "$state" "$dir/fakebin" "$dir/out2" "$DONE_LINE"
  rc=0
  wait_for_exit $! 150 || rc=$?
  [ "$rc" != 124 ] || fail "relaunched watcher did not re-surface the unhandled completion"
  assert_contains "$(cat "$dir/out2")" "check: rearm-resurface" \
    "relaunched watcher should report recovery for the unhandled completion"
  [ "$(queue_alarm_count "$state" helm)" = 1 ] \
    || fail "relaunched watcher queued a duplicate completion wake"

  # Handling: drain the durable wake, run the printed generation-bound
  # acknowledgement, and let the task resume; the next watcher clears the
  # record and keeps blocking.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "drain failed on the durable completion wake"
  grep -F 'check: completion-alarm: helm done unsurfaced' "$dir/drain.out" >/dev/null \
    || fail "drain did not re-print the durable completion row"
  ack_drain_err "$state" "$dir/drain.err" \
    || fail "handled completion wake could not be acknowledged"

  watch_bg "$state" "$dir/fakebin" "$dir/out3" "$WORKING_LINE"
  local pid=$!
  wait_live "$pid" 30 || { out=$(cat "$dir/out3"); fail "watcher exited again after the completion was handled: $out"; }
  reap "$pid"
  assert_absent "$(record_path "$state" helm)" \
    "a resumed task's record should be cleared by the running watcher"
  [ "$(queue_alarm_count "$state" helm)" = 0 ] \
    || fail "post-acknowledgement watcher re-queued the handled completion wake"
  pass "watcher alarms a lost completion once, recovers it across restarts, then keeps blocking"
}

wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# --- teardown cleanup -------------------------------------------------------

test_teardown_clears_task_record() {
  local case_dir fb rc
  case_dir="$TMP_ROOT/teardown-case"
  mkdir -p "$case_dir/state" "$case_dir/config"
  fb=$(fm_fakebin "$case_dir")
  fm_fake_exit0 "$fb" treehouse tmux gh-axi gh
  git init -q "$case_dir/project"
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m baseline
  git -C "$case_dir/project" branch -M main
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=local-only"
  arm_record "$case_dir/state" task-x1 done "landed work"
  arm_record "$case_dir/state" other-task done "unrelated completion"
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$fb:$PATH" \
    "$TEARDOWN" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "teardown of a clean local-only task should succeed ($(cat "$case_dir/stderr"))"
  assert_absent "$(record_path "$case_dir/state" task-x1)" \
    "teardown must clear the task's completion-alarm record"
  assert_present "$(record_path "$case_dir/state" other-task)" \
    "teardown must not clear another task's completion-alarm record"
  pass "teardown clears exactly the torn-down task's completion-alarm record"
}

test_tick_arms_then_escalates_exactly_once
test_tick_alarms_parked_gate
test_tick_clears_on_resume_and_rearms_for_new_completion
test_tick_state_change_restarts_episode
test_tick_never_alarms_secondmate
test_tick_never_alarms_declared_pause
test_tick_defers_while_endpoint_busy
test_tick_holds_done_with_armed_merge_poll
test_tick_clears_orphaned_record
test_watcher_alarms_lost_completion_and_rearms_after_restart
test_teardown_clears_task_record
