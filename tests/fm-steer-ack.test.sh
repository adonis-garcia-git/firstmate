#!/usr/bin/env bash
# tests/fm-steer-ack.test.sh - the steer acknowledgment contract
# (bin/fm-steer-ack-lib.sh, fm-send.sh --ack, the watcher's no-ack escalation,
# the generated brief instruction, and teardown cleanup).
#
# Incident background: a steer can submit cleanly (composer verification proves
# SUBMISSION) and still never be processed into a turn by the worker, leaving
# supervision falsely reporting the work as under way. The contract under test:
#   - fm-send --ack prefixes a visible [ack=<token>] mark into the order's
#     durable steering-inbox record and arms one pending-ack record; a plain
#     send arms nothing; both directions of the delivery boundary hold - an
#     order the inbox plane refuses before transport, whether its record cannot
#     be written or its task record cannot be locked, discards the pending-ack
#     record, while a skipped or failed doorbell keeps it armed; secondmate,
#     --key, and harness-command targets are refused.
#   - The watcher tick clears an acked or orphaned record, and queues exactly
#     one actionable check wake per order that stays unacknowledged past its
#     window - never a second wake for the same order.
#   - Repeated ack lines and re-armed duplicate tokens are safe.
#   - Generated ship and scout briefs teach the ack reply.
#   - Teardown clears the task's leftover records and only that task's.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
fm_git_identity fmtest fmtest@example.invalid

SEND="$ROOT/bin/fm-send.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
ACK_LIB="$ROOT/bin/fm-steer-ack-lib.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-steer-ack-tests)

# --- helpers ----------------------------------------------------------------

# Run one lib function in a subshell scoped to <state>, so sourcing the wake
# lib never binds this test shell's globals to one case's state dir.
# ack_lib_call <state> <function> [args...]
ack_lib_call() {
  local state=$1; shift
  FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    # shellcheck disable=SC1090
    . "$2"
    fn=$3
    shift 3
    "$fn" "$@"
  ' _ "$WAKE_LIB" "$ACK_LIB" "$@"
}

# arm_record <state> <task> <token> <text> [sent-epoch]
arm_record() {
  local state=$1 task=$2 token=$3 text=$4 now=${5:-}
  FM_STEER_ACK_NOW="$now" ack_lib_call "$state" fm_steer_ack_arm "$state" "$task" "$token" "$text"
}

run_tick() {  # <state>
  ack_lib_call "$1" fm_steer_ack_tick "$1"
}

record_path() {  # <state> <task> <token>
  printf '%s/pending-acks/%s.%s' "$1" "$2" "$3"
}

# The order text an --ack send delivers now lives in the task's steering-inbox
# record, so assertions about the mark read it through the library that owns
# the record format (bin/fm-task-inbox-lib.sh).
record_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

queue_steer_ack_count() {  # <state> <task> <token>
  local q="$1/.wake-queue"
  if [ -f "$q" ]; then
    grep -c "steer-ack-$2-$3" "$q" || true
  else
    printf '0\n'
  fi
}

epoch_ago() {  # <seconds>
  printf '%s' "$(( $(date +%s) - $1 ))"
}

# A crewmate ship meta so fm-send resolves a task selector in this home.
write_ship_meta() {  # <state> <id> [window]
  local state=$1 id=$2 window=${3:-sess:fm-$2}
  fm_write_meta "$state/$id.meta" \
    "window=$window" "endpoint_task_id=$id" "worktree=$state/wt" \
    "project=$state/p" "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
}

# Fake tmux whose composer reads empty after Enter, so fm-send reaches a clean
# confirmed submit; literal typed text is recorded to FM_SEND_LOG (same shape
# as the fm-send-secondmate-marker suite's stub).
make_send_stubs() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# Variant whose composer NEVER reads empty, so every submit verdict stays
# unconfirmed and fm-send must fail loudly.
make_stuck_send_stubs() {  # <dir> -> echoes fakebin dir
  local fb
  fb=$(make_send_stubs "$1")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭──────────────╮\n│ > stuck text │\n╰──────────────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <home> <send-log> <fm-send args...>
run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 \
    "$SEND" "$@" 2>"$log.err"
}

setup_send_home() {  # <name> -> echoes home dir with state/
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# --- fm-send arming behavior ------------------------------------------------

test_ack_send_arms_record_and_prefixes_mark() {
  local dir fb log home rc got token rec typed
  dir="$TMP_ROOT/send-arm"; mkdir -p "$dir"
  fb=$(make_send_stubs "$dir"); log="$dir/send.log"
  home=$(setup_send_home send-arm-home)
  write_ship_meta "$home/state" helm
  # An --ack order is text to a task recorded in this home, so it rides the
  # steering-inbox plane like any other: the mark must land in the durable
  # record the worker actually reads, and the pane must see only the doorbell.
  FM_STEER_ACK_TOKEN=1234abcd run_send "$fb" "$home" "$log" fm-helm "rebase onto main now"; rc=$?
  expect_code 0 "$rc" "plain-send probe to a crewmate should succeed"
  got=$(record_body "$home/state/helm.inbox/001.msg")
  [ "$got" = "rebase onto main now" ] || fail "plain-send probe altered the literal text: $got"
  FM_STEER_ACK_TOKEN=1234abcd run_send "$fb" "$home" "$log" fm-helm --ack "rebase onto main now"; rc=$?
  expect_code 0 "$rc" "--ack send should succeed on a durable enqueue"
  got=$(record_body "$home/state/helm.inbox/002.msg")
  [ "$got" = "[ack=1234abcd] rebase onto main now" ] \
    || fail "--ack send did not prefix the visible mark exactly once: $got"
  typed=$(cat "$log")
  case "$typed" in
    *"rebase onto main now"*)
      fail "the order payload must never be typed into the pane:"$'\n'"$typed" ;;
  esac
  token=1234abcd
  rec=$(record_path "$home/state" helm "$token")
  assert_present "$rec" "--ack send should arm a durable pending-ack record"
  assert_grep "task=helm" "$rec" "record should carry the task id"
  assert_grep "token=$token" "$rec" "record should carry the token"
  assert_grep "summary=[ack=1234abcd] rebase onto main now" "$rec" "record should carry the order summary"
  pass "fm-send --ack prefixes [ack=<token>] and arms one durable record"
}

test_plain_send_arms_nothing() {
  local dir fb log home rc
  dir="$TMP_ROOT/send-plain"; mkdir -p "$dir"
  fb=$(make_send_stubs "$dir"); log="$dir/send.log"
  home=$(setup_send_home send-plain-home)
  write_ship_meta "$home/state" helm
  run_send "$fb" "$home" "$log" fm-helm "carry on"; rc=$?
  expect_code 0 "$rc" "plain send should succeed"
  [ ! -d "$home/state/pending-acks" ] \
    || [ -z "$(find "$home/state/pending-acks" -type f 2>/dev/null)" ] \
    || fail "a plain send without --ack armed a pending-ack record"
  pass "fm-send without --ack arms no detection (back-compat preserved)"
}

test_ack_send_refusals() {
  local dir fb log home rc
  dir="$TMP_ROOT/send-refuse"; mkdir -p "$dir"
  fb=$(make_send_stubs "$dir"); log="$dir/send.log"

  home=$(setup_send_home send-refuse-sm)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  run_send "$fb" "$home" "$log" fm-domain --ack "audit the build"; rc=$?
  [ "$rc" -ne 0 ] || fail "--ack to a secondmate target should be refused"
  assert_grep "pending-reply" "$log.err" "secondmate refusal should point at the pending-reply expectation"
  [ ! -d "$home/state/pending-acks" ] || fail "refused secondmate --ack still armed a record"

  home=$(setup_send_home send-refuse-key)
  write_ship_meta "$home/state" helm
  run_send "$fb" "$home" "$log" fm-helm --ack --key Enter; rc=$?
  [ "$rc" -ne 0 ] || fail "--ack combined with --key should be refused"

  run_send "$fb" "$home" "$log" fm-helm --ack "/compact now"; rc=$?
  [ "$rc" -ne 0 ] || fail "--ack on a leading-slash harness command should be refused"
  [ ! -d "$home/state/pending-acks" ] || fail "refused command --ack still armed a record"

  home=$(setup_send_home send-refuse-explicit)
  write_ship_meta "$home/state" helm "other:win"
  run_send "$fb" "$home" "$log" "other:win" --ack "do it"; rc=$?
  [ "$rc" -ne 0 ] || fail "--ack to an explicit endpoint (not a task selector) should be refused"
  assert_grep "requires a task recorded in this home" "$log.err" \
    "explicit-endpoint refusal should explain the task-selector requirement"
  pass "fm-send --ack refuses secondmate, --key, harness-command, and non-selector targets"
}

test_ack_send_preserves_record_on_unrung_doorbell() {
  # A composer visibly holding text makes the doorbell advisory-skip. On the
  # inbox plane the durable record IS the delivery, so the send still succeeds
  # and the watcher owns the re-ring - but detection must stay armed, because
  # an order nobody rang for is exactly the one that goes unnoticed. Discarding
  # the record here would leave a delivered order unmonitored.
  local dir fb log home rc
  dir="$TMP_ROOT/send-stuck"; mkdir -p "$dir"
  fb=$(make_stuck_send_stubs "$dir"); log="$dir/send.log"
  home=$(setup_send_home send-stuck-home)
  write_ship_meta "$home/state" helm
  FM_STEER_ACK_TOKEN=feedc0de run_send "$fb" "$home" "$log" fm-helm --ack "rebase now"; rc=$?
  expect_code 0 "$rc" "a durable enqueue succeeds even when the doorbell is skipped"
  [ -f "$home/state/helm.inbox/001.msg" ] \
    || fail "the order must be durably recorded even when the doorbell is skipped"
  assert_grep "the watcher will re-ring" "$log.err" \
    "a skipped doorbell should tell the caller the watcher owns the retry, not resend"
  assert_present "$(record_path "$home/state" helm feedc0de)" \
    "an unrung doorbell must keep the pending-ack record armed"
  pass "fm-send --ack keeps detection armed when the doorbell is skipped"
}

test_ack_send_discards_record_on_undeliverable_order() {
  # On the inbox plane a failed keystroke is not a failed delivery - the durable
  # record is. The proven-undelivered case is therefore an inbox that cannot be
  # written, and that is the one case where the pending-ack record MUST go: an
  # armed record for an order the worker was never given would escalate a steer
  # that never existed.
  local dir fb log home rc
  dir="$TMP_ROOT/send-fail"; mkdir -p "$dir"
  fb=$(make_send_stubs "$dir"); log="$dir/send.log"
  home=$(setup_send_home send-fail-home)
  write_ship_meta "$home/state" helm
  # Block the record write by parking a non-directory where the inbox must live.
  : > "$home/state/helm.inbox"
  FM_STEER_ACK_TOKEN=feedc0de run_send "$fb" "$home" "$log" fm-helm --ack "rebase now"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unwritable inbox should fail loudly, got $rc"
  assert_grep "inbox record could not be written" "$log.err" \
    "the failure should name the undeliverable record, not a keystroke"
  assert_absent "$(record_path "$home/state" helm feedc0de)" \
    "an order that was never recorded must discard the pending-ack record"
  pass "fm-send --ack discards the record when the order cannot be delivered"
}

test_ack_send_discards_record_when_the_meta_lock_is_unresolvable() {
  # The other pre-transport exit of the same class: the inbox plane validates
  # the target under the task's metadata lock, so a task record whose lock path
  # cannot be derived never reaches the inbox at all. fm-spawn.sh refuses to
  # create such an id, so this models a hand-written or externally supplied
  # record - but arming does not validate the id, so without the discard the
  # watcher would escalate an order that was never written anywhere.
  local dir fb log home rc id
  dir="$TMP_ROOT/send-lockpath"; mkdir -p "$dir"
  fb=$(make_send_stubs "$dir"); log="$dir/send.log"
  home=$(setup_send_home send-lockpath-home)
  id='my task'
  write_ship_meta "$home/state" "$id"
  FM_STEER_ACK_TOKEN=feedc0de run_send "$fb" "$home" "$log" "fm-$id" --ack "rebase now"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unlockable task record should fail loudly, got $rc"
  [ ! -e "$home/state/$id.inbox" ] || fail "no inbox record may exist for an order that was refused before transport"
  assert_absent "$(record_path "$home/state" "$id" feedc0de)" \
    "an order that never reached the inbox must discard the pending-ack record"
  assert_grep "no valid lock for final delivery validation" "$log.err" \
    "the failure should name why the order was never recorded"
  pass "fm-send --ack discards the record when the task metadata lock cannot be resolved"
}

test_ack_send_keeps_record_when_only_the_doorbell_fails() {
  # The complement of the case above: the record landed, so the order IS
  # delivered and detection must stay armed even though the ring failed.
  local dir fb log home rc
  dir="$TMP_ROOT/send-ringfail"; mkdir -p "$dir"
  fb=$(make_send_stubs "$dir"); log="$dir/send.log"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 1 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭──────────────╮\n│ >            │\n╰──────────────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  home=$(setup_send_home send-ringfail-home)
  write_ship_meta "$home/state" helm
  FM_STEER_ACK_TOKEN=feedc0de run_send "$fb" "$home" "$log" fm-helm --ack "rebase now"; rc=$?
  expect_code 0 "$rc" "a durable record survives a failed doorbell"
  [ -f "$home/state/helm.inbox/001.msg" ] || fail "the order was not durably recorded"
  assert_present "$(record_path "$home/state" helm feedc0de)" \
    "a delivered order must keep detection armed when only the ring failed"
  pass "fm-send --ack keeps detection armed when only the doorbell fails"
}

# --- lib tick behavior ------------------------------------------------------

test_tick_is_silent_inside_window() {
  local state out
  state="$TMP_ROOT/tick-window/state"; mkdir -p "$state"
  fm_write_meta "$state/helm.meta" "window=sess:fm-helm"
  arm_record "$state" helm aaaa1111 "rebase now"
  out=$(run_tick "$state") || fail "tick failed"
  [ -z "$out" ] || fail "tick surfaced an order still inside its window: $out"
  assert_present "$(record_path "$state" helm aaaa1111)" "record inside its window must be preserved"
  [ ! -e "$state/.wake-queue" ] || fail "tick queued a wake inside the window"
  pass "steer-ack tick leaves an in-window unacknowledged order alone"
}

test_tick_escalates_exactly_once_past_window() {
  local state out rec
  state="$TMP_ROOT/tick-escalate/state"; mkdir -p "$state"
  fm_write_meta "$state/helm.meta" "window=sess:fm-helm"
  arm_record "$state" helm bbbb2222 "rebase now" "$(epoch_ago 400)"
  out=$(run_tick "$state") || fail "tick failed"
  assert_contains "$out" "check: steer-ack: helm order [ack=bbbb2222] unacknowledged" \
    "tick should print the actionable reason naming task and token"
  [ "$(queue_steer_ack_count "$state" helm bbbb2222)" = 1 ] \
    || fail "exactly one durable wake expected after the first escalation"
  rec=$(record_path "$state" helm bbbb2222)
  assert_present "$rec" "escalated record is preserved (a late ack can still clear it)"
  grep -qE '^escalated_epoch=[0-9]+$' "$rec" || fail "record should carry the escalation epoch"
  out=$(run_tick "$state") || fail "second tick failed"
  [ -z "$out" ] || fail "a second tick re-surfaced an already-escalated order: $out"
  [ "$(queue_steer_ack_count "$state" helm bbbb2222)" = 1 ] \
    || fail "a second tick queued a duplicate wake"
  pass "steer-ack tick queues exactly one actionable wake per unacknowledged order"
}

test_tick_clears_on_ack_including_late_and_duplicate() {
  local state out
  state="$TMP_ROOT/tick-ack/state"; mkdir -p "$state"
  fm_write_meta "$state/helm.meta" "window=sess:fm-helm"
  arm_record "$state" helm cccc3333 "rebase now" "$(epoch_ago 400)"
  printf 'resolved [key=ack-cccc3333]: starting rebase onto main\n' >> "$state/helm.status"
  printf 'resolved [key=ack-cccc3333]: starting rebase onto main\n' >> "$state/helm.status"
  out=$(run_tick "$state") || fail "tick failed"
  [ -z "$out" ] || fail "an acked order was still surfaced: $out"
  assert_absent "$(record_path "$state" helm cccc3333)" "ack must clear the pending record"
  [ ! -e "$state/.wake-queue" ] || fail "an acked order queued a wake"

  # Late ack after escalation, in the raw-mark form, still clears the record.
  arm_record "$state" helm dddd4444 "push the fix" "$(epoch_ago 400)"
  out=$(run_tick "$state") || fail "tick failed"
  assert_contains "$out" "dddd4444" "unacked order should escalate first"
  printf 'blocked: got order [ack=dddd4444] but the branch is gone\n' >> "$state/helm.status"
  out=$(run_tick "$state") || fail "tick failed"
  [ -z "$out" ] || fail "late-acked order re-surfaced: $out"
  assert_absent "$(record_path "$state" helm dddd4444)" "a late ack must clear the escalated record"
  pass "steer-ack tick clears acked records; duplicate and late acks are safe"
}

test_tick_clears_orphaned_record() {
  local state out
  state="$TMP_ROOT/tick-orphan/state"; mkdir -p "$state"
  arm_record "$state" gone eeee5555 "old order" "$(epoch_ago 4000)"
  out=$(run_tick "$state") || fail "tick failed"
  [ -z "$out" ] || fail "an orphaned record (no task meta) was surfaced: $out"
  assert_absent "$(record_path "$state" gone eeee5555)" "orphaned record must be removed"
  pass "steer-ack tick removes records whose task is gone"
}

test_rearm_same_token_restarts_window() {
  local state out
  state="$TMP_ROOT/tick-rearm/state"; mkdir -p "$state"
  fm_write_meta "$state/helm.meta" "window=sess:fm-helm"
  arm_record "$state" helm ffff6666 "first order" "$(epoch_ago 400)"
  arm_record "$state" helm ffff6666 "re-issued order"
  out=$(run_tick "$state") || fail "tick failed"
  [ -z "$out" ] || fail "a re-armed duplicate token escalated from the stale window: $out"
  assert_present "$(record_path "$state" helm ffff6666)" "re-armed record must be preserved"
  pass "re-arming a duplicate token safely restarts its window"
}

test_clear_task_removes_only_that_task() {
  local state
  state="$TMP_ROOT/clear-task/state"; mkdir -p "$state"
  arm_record "$state" helm 12121212 "order one"
  arm_record "$state" helm 34343434 "order two"
  arm_record "$state" helm.aux 56565656 "sibling order"
  ack_lib_call "$state" fm_steer_ack_clear_task "$state" helm || fail "clear_task failed"
  assert_absent "$(record_path "$state" helm 12121212)" "clear_task should remove the task's first record"
  assert_absent "$(record_path "$state" helm 34343434)" "clear_task should remove the task's second record"
  assert_present "$(record_path "$state" helm.aux 56565656)" \
    "clear_task must not remove a dotted sibling task's record"
  pass "fm_steer_ack_clear_task removes exactly the named task's records"
}

# --- watcher end-to-end -----------------------------------------------------

watch_bg() {  # <state> <fakebin> <out>
  local state=$1 fakebin=$2 out=$3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · test fixture' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
}

test_watcher_surfaces_unacknowledged_order() {
  local dir state out rc
  dir=$(make_case ack-watch-escalate); state="$dir/state"
  fm_write_meta "$state/helm.meta" "window=sess:fm-helm"
  printf 'working: implementing\n' > "$state/helm.status"
  arm_record "$state" helm abcd9876 "rebase onto main" "$(epoch_ago 400)"
  watch_bg "$state" "$dir/fakebin" "$dir/out"
  rc=0
  wait_for_exit $! 100 || rc=$?
  [ "$rc" != 124 ] || fail "watcher did not exit on an overdue unacknowledged order"
  out=$(cat "$dir/out")
  assert_contains "$out" "check: steer-ack: helm order [ack=abcd9876] unacknowledged" \
    "watcher should surface the no-ack wake naming task and token"
  [ "$(queue_steer_ack_count "$state" helm abcd9876)" = 1 ] \
    || fail "watcher should have queued exactly one durable steer-ack wake"

  # A relaunched watcher re-surfaces the still-unhandled durable wake through
  # the recovery reason - never as a duplicate steer-ack record.
  watch_bg "$state" "$dir/fakebin" "$dir/out2"
  rc=0
  wait_for_exit $! 100 || rc=$?
  [ "$rc" != 124 ] || fail "relaunched watcher did not re-surface the unhandled durable order"
  assert_contains "$(cat "$dir/out2")" "check: rearm-resurface" \
    "relaunched watcher should report recovery for the unacknowledged order"
  [ "$(queue_steer_ack_count "$state" helm abcd9876)" = 1 ] \
    || fail "relaunched watcher queued a duplicate steer-ack wake"

  # Handling: drain the durable wake and run the printed generation-bound
  # acknowledgement; only then does a relaunched watcher keep blocking.
  local drain_out="$dir/drain.out" drain_err="$dir/drain.err" sequence generation
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" \
    || fail "drain failed on the durable steer-ack wake"
  grep -F 'check: steer-ack: helm order [ack=abcd9876] unacknowledged' "$drain_out" >/dev/null \
    || fail "drain did not re-print the durable steer-ack row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$drain_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$drain_err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "drain omitted its post-handling acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "handled steer-ack wake could not be acknowledged"

  watch_bg "$state" "$dir/fakebin" "$dir/out3"
  local pid=$!
  wait_live "$pid" 25 || { out=$(cat "$dir/out3"); fail "watcher exited again after the order was handled and acknowledged: $out"; }
  reap "$pid"
  [ "$(queue_steer_ack_count "$state" helm abcd9876)" = 0 ] \
    || fail "post-acknowledgement watcher re-queued the already-handled steer-ack wake"
  pass "watcher surfaces an unacknowledged order once, recovers it until acknowledged, then keeps blocking"
}

test_watcher_absorbs_acknowledged_order() {
  local dir state pid
  dir=$(make_case ack-watch-clear); state="$dir/state"
  fm_write_meta "$state/helm.meta" "window=sess:fm-helm"
  printf 'working: implementing\nresolved [key=ack-fedc1234]: starting rebase onto main\n' > "$state/helm.status"
  arm_record "$state" helm fedc1234 "rebase onto main" "$(epoch_ago 400)"
  watch_bg "$state" "$dir/fakebin" "$dir/out"
  pid=$!
  wait_live "$pid" 30 || fail "watcher exited despite the acknowledged order: $(cat "$dir/out")"
  reap "$pid"
  assert_absent "$(record_path "$state" helm fedc1234)" "watcher tick should clear the acked record"
  [ "$(queue_steer_ack_count "$state" helm fedc1234)" = 0 ] \
    || fail "an acked order still produced a steer-ack wake"
  pass "watcher clears an acknowledged order without waking firstmate"
}

# wait_live/reap come from the watch-triage suite's pattern; re-rolled here so
# this file stays self-contained alongside wake-helpers.sh.
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

# --- generated brief instruction --------------------------------------------

test_briefs_teach_the_ack_reply() {
  local home brief
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$BRIEF" ship-task some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "ship brief scaffold failed"
  brief="$home/data/ship-task/brief.md"
  assert_grep '[ack={token}]' "$brief" "ship brief should name the token-marked order form"
  assert_grep 'resolved [key=ack-{token}]: starting' "$brief" \
    "ship brief should teach the keyed ack reply"
  FM_HOME="$home" "$BRIEF" scout-task some-proj --scout >/dev/null 2>&1 \
    || fail "scout brief scaffold failed"
  brief="$home/data/scout-task/brief.md"
  assert_grep '[ack={token}]' "$brief" "scout brief should name the token-marked order form"
  assert_grep 'resolved [key=ack-{token}]: starting' "$brief" \
    "scout brief should teach the keyed ack reply"
  pass "generated ship and scout briefs teach the steer-ack reply"
}

# --- teardown cleanup -------------------------------------------------------

test_teardown_clears_task_records() {
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
  arm_record "$case_dir/state" task-x1 76543210 "land the fix"
  arm_record "$case_dir/state" other-task 89abcdef "unrelated order"
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$fb:$PATH" \
    "$TEARDOWN" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "teardown of a clean local-only task should succeed ($(cat "$case_dir/stderr"))"
  assert_absent "$(record_path "$case_dir/state" task-x1 76543210)" \
    "teardown must clear the task's leftover pending-ack record"
  assert_present "$(record_path "$case_dir/state" other-task 89abcdef)" \
    "teardown must not clear another task's pending-ack record"
  pass "teardown clears exactly the torn-down task's pending-ack records"
}

test_ack_send_arms_record_and_prefixes_mark
test_plain_send_arms_nothing
test_ack_send_refusals
test_ack_send_preserves_record_on_unrung_doorbell
test_ack_send_discards_record_on_undeliverable_order
test_ack_send_discards_record_when_the_meta_lock_is_unresolvable
test_ack_send_keeps_record_when_only_the_doorbell_fails
test_tick_is_silent_inside_window
test_tick_escalates_exactly_once_past_window
test_tick_clears_on_ack_including_late_and_duplicate
test_tick_clears_orphaned_record
test_rearm_same_token_restarts_window
test_clear_task_removes_only_that_task
test_watcher_surfaces_unacknowledged_order
test_watcher_absorbs_acknowledged_order
test_briefs_teach_the_ack_reply
test_teardown_clears_task_records
