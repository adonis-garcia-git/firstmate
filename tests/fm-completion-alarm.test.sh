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
#     episode and may alarm again. So does a completion under an ADVANCED
#     pipeline run head at the same state value, which is what keeps a run's
#     approval gate and its fix_review gate from merging into one episode
#     without relying on having observed the working interval between them -
#     the crew worktree HEAD cannot serve there, because a fix round commits
#     into the gate repo and leaves it untouched. Losing run attribution
#     between two gates changes the KIND of evidence rather than the identity,
#     and an already-fired record re-arms rather than letting that flap swallow
#     the next gate. An identity that cannot be derived at all leaves the
#     window start alone so the alarm matures and fires once. Only a SUCCESSFUL read
#     decides any of it: a failed, malformed, or timed-out reader leaves the
#     record and its window untouched, and one wedged read cannot stall a sweep.
#   - A healthy idle secondmate, a declared paused: external wait, a provably
#     busy endpoint (e.g. a worker composing a gate response), and a done task
#     with an armed merge poll never alarm. A busy endpoint defers detection
#     but never drops an already-escalated record, so busy flapping on a
#     completion the supervisor is holding cannot re-nag it - and never holds
#     one blind either, so a busy period that ends an episode still lets the
#     worker's NEXT completion alarm on its own merits.
#   - One sweep is bounded by its own wall-clock budget rather than starving
#     the watcher's poll loop, and resumes at the deferred tail, so even a
#     persistently slow reader reconciles every task within a few sweeps.
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
TIMEOUT_LIB="$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-completion-alarm-tests)

# One shared fake current-state reader for the unit-level ticks; the canned
# verdict comes from FM_FAKE_CREW_STATE (or a per-id override) per call.
FAKE_CREW=$(make_fake_crew_state "$TMP_ROOT")

# The run-identity token the fake reader reports, when a case cares. Empty for
# every case that does not, which exercises the crew-HEAD fallback.
FAKE_EPISODE=""

# --- helpers ----------------------------------------------------------------

# Run one lib function in a subshell scoped to <state>, with the fake
# current-state reader and canned verdict, so sourcing the wake lib never
# binds this test shell's globals to one case's state dir.
# tick_with <state> <crew-state-line> [now]
tick_with() {
  local state=$1 verdict=$2 now=${3:-}
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$FAKE_CREW" \
    FM_FAKE_CREW_STATE="$verdict" FM_COMPLETION_ALARM_NOW="$now" \
    FM_FAKE_CREW_EPISODE="${FAKE_EPISODE:-}" bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    # shellcheck disable=SC1090
    . "$2"
    # shellcheck disable=SC1090
    . "$3"
    fm_completion_alarm_tick "$4"
  ' _ "$WAKE_LIB" "$TIMEOUT_LIB" "$ALARM_LIB" "$state"
}

# Same tick, against a reader that WEDGES rather than answering, so the test
# can observe the per-read hard bound instead of the sweep-level budget (which
# gates how many reads start, never how long one takes).
tick_with_hung_reader() {  # <state> <read-timeout-secs>
  local state=$1 read_timeout=$2 bin
  bin="$TMP_ROOT/hung-crew-state.sh"
  if [ ! -x "$bin" ]; then
    # shellcheck disable=SC2016 # The generated reader expands these itself.
    printf '#!/usr/bin/env bash\nset -u\nsleep "${FM_FAKE_CREW_HANG:-15}"\nprintf "state: done\\n"\n' > "$bin"
    chmod +x "$bin"
  fi
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$bin" FM_FAKE_CREW_HANG=15 \
    FM_COMPLETION_READ_TIMEOUT_SECS="$read_timeout" bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    # shellcheck disable=SC1090
    . "$2"
    # shellcheck disable=SC1090
    . "$3"
    fm_completion_alarm_tick "$4"
  ' _ "$WAKE_LIB" "$TIMEOUT_LIB" "$ALARM_LIB" "$state"
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

# Same tick, against a deliberately BROKEN current-state reader, so the test
# can distinguish a reader failure from a real verdict. <mode> is `missing`
# (no such binary - the persistently broken FM_CREW_STATE_BIN case, exit 127
# with no output) or `garbage` (exits 0 but emits something that is not the
# canonical `state:` line).
tick_with_broken_reader() {  # <state> <mode> [now]
  local state=$1 mode=$2 now=${3:-} bin
  case "$mode" in
    missing) bin="$TMP_ROOT/no-such-crew-state.sh" ;;
    garbage)
      bin="$TMP_ROOT/garbage-crew-state.sh"
      if [ ! -x "$bin" ]; then
        printf '#!/usr/bin/env bash\nprintf "fm-crew-state.sh: unbound variable\\n"\nexit 0\n' > "$bin"
        chmod +x "$bin"
      fi
      ;;
    *) fail "unknown broken-reader mode: $mode" ;;
  esac
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$bin" \
    FM_COMPLETION_ALARM_NOW="$now" bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    # shellcheck disable=SC1090
    . "$2"
    fm_completion_alarm_tick "$3"
  ' _ "$WAKE_LIB" "$ALARM_LIB" "$state"
}

# Same tick, against a deliberately SLOW current-state reader and an explicit
# per-sweep wall-clock budget, so the test can observe one sweep bounding its
# own work and deferring the tail rather than starving the watcher poll loop.
tick_with_slow_reader() {  # <state> <sleep-secs> <budget-secs>
  local state=$1 secs=$2 budget=$3 bin
  bin="$TMP_ROOT/slow-crew-state.sh"
  if [ ! -x "$bin" ]; then
    cat > "$bin" <<'SH'
#!/usr/bin/env bash
set -u
sleep "${FM_FAKE_CREW_SLEEP:-0}"
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none}"
exit 0
SH
    chmod +x "$bin"
  fi
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$bin" \
    FM_FAKE_CREW_SLEEP="$secs" FM_FAKE_CREW_STATE="$DONE_LINE" \
    FM_COMPLETION_SCAN_BUDGET_SECS="$budget" bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    # shellcheck disable=SC1090
    . "$2"
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
  arm_record "$state" domain 'done' "stray record" "$(epoch_ago 4000)"
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
  arm_record "$state" helm 'done' "stale record" "$(epoch_ago 4000)"
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
  arm_record "$state" helm 'done' "checks green" "$(epoch_ago 4000)"
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

test_tick_busy_flap_never_renags_escalated_episode() {
  local state out rec t
  state="$TMP_ROOT/tick-busy-flap/state"; mkdir -p "$state"
  fm_write_meta "$state/helm.meta" "kind=ship"
  t=$(date +%s)
  arm_record "$state" helm 'done' "checks green" "$(( t - 400 ))"
  rec=$(record_path "$state" helm)
  out=$(tick_with "$state" "$DONE_LINE" "$t") || fail "escalation tick failed"
  assert_contains "$out" "check: completion-alarm: helm done unsurfaced" \
    "the aged completion episode should escalate once"
  [ "$(queue_alarm_count "$state" helm)" = 1 ] || fail "expected exactly one wake"
  # The supervisor messages the done-and-parked worker (a routine action on a
  # completion being deliberately held), so its endpoint is busy for a turn.
  out=$(tick_with_busy "$state" "$DONE_LINE" "busy claude-hook" "$(( t + 10 ))") \
    || fail "busy tick failed"
  [ -z "$out" ] || fail "a busy endpoint escalated: $out"
  assert_present "$rec" "a busy endpoint must not drop an already-escalated record"
  grep -qE '^escalated_epoch=[0-9]+$' "$rec" \
    || fail "the busy interval dropped the one-shot escalation stamp"
  # Endpoint idle again and still done, now well past a fresh window: the
  # episode was already surfaced, so it must never wake a second time.
  out=$(tick_with "$state" "$DONE_LINE" "$(( t + 20 ))") || fail "post-busy tick failed"
  [ -z "$out" ] || fail "the same completion episode re-nagged right after a busy flap: $out"
  out=$(tick_with "$state" "$DONE_LINE" "$(( t + 400 ))") || fail "late tick failed"
  [ -z "$out" ] || fail "the same completion episode re-nagged after a busy flap: $out"
  [ "$(queue_alarm_count "$state" helm)" = 1 ] \
    || fail "a busy flap produced a duplicate wake for one completion episode"
  pass "a busy flap after escalation never re-nags the same completion episode"
}

test_tick_busy_period_ends_episode_and_next_completion_alarms() {
  local state out rec t
  state="$TMP_ROOT/tick-second-episode/state"; mkdir -p "$state"
  fm_write_meta "$state/helm.meta" "kind=ship"
  t=$(date +%s)
  arm_record "$state" helm 'done' "checks green" "$(( t - 400 ))"
  rec=$(record_path "$state" helm)
  out=$(tick_with "$state" "$DONE_LINE" "$t") || fail "first escalation failed"
  assert_contains "$out" "check: completion-alarm: helm done unsurfaced" \
    "the first completion episode should escalate"
  [ "$(queue_alarm_count "$state" helm)" = 1 ] || fail "expected one wake for episode 1"
  # The supervisor hands helm new work, so its endpoint is busy AND its
  # reconciled state has left the terminal set. That ends episode 1: a record
  # held blind through the busy period would swallow the next completion.
  out=$(tick_with_busy "$state" "$WORKING_LINE" "busy claude-hook" "$(( t + 10 ))") \
    || fail "busy working tick failed"
  [ -z "$out" ] || fail "a working task escalated: $out"
  assert_absent "$rec" \
    "a busy endpoint that has left the terminal state must end the episode"
  # helm finishes the new work and that done wake is lost too: a second,
  # genuinely distinct episode that has to alarm on its own merits.
  out=$(tick_with "$state" "$DONE_LINE" "$(( t + 100 ))") || fail "re-arm tick failed"
  [ -z "$out" ] || fail "episode 2 escalated before its own window: $out"
  assert_present "$rec" "the second completion should arm a fresh record"
  [ "$(queue_alarm_count "$state" helm)" = 1 ] || fail "episode 2 woke inside its window"
  out=$(tick_with "$state" "$DONE_LINE" "$(( t + 300 ))") || fail "episode 2 tick failed"
  assert_contains "$out" "check: completion-alarm: helm done unsurfaced" \
    "a genuinely new completion episode must alarm on its own merits"
  [ "$(queue_alarm_count "$state" helm)" = 2 ] \
    || fail "the second completion episode never raised its own wake"
  pass "a busy period that ends an episode never suppresses the next completion"
}

test_tick_distinct_episodes_never_merge_behind_one_state() {
  local state wt out rec t crew_head
  state="$TMP_ROOT/tick-episode/state"; mkdir -p "$state"
  # A real crew worktree, whose HEAD a no-mistakes fix round does NOT touch:
  # the pipeline commits into the gate repo, and fm_nm_head_matches_worktree's
  # ancestor rule exists precisely because the crew HEAD stays behind. So this
  # worktree is committed to exactly once and never again - anything that
  # depended on it moving would be testing a state the system never produces.
  wt="$TMP_ROOT/tick-episode/wt"
  git init -q "$wt"
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "crew work"
  crew_head=$(git -C "$wt" rev-parse HEAD)
  fm_write_meta "$state/helm.meta" "kind=ship" "worktree=$wt"
  t=$(date +%s)
  rec=$(record_path "$state" helm)
  # Gate 1: the run parks at approval. Same run, head as the pipeline sees it.
  FAKE_EPISODE="run:R1@1111111111111111111111111111111111111111"
  out=$(tick_with "$state" "$PARKED_LINE" "$t") || fail "arm tick failed"
  [ -z "$out" ] || fail "the first gate escalated inside its window: $out"
  assert_grep "episode_source=run" "$rec" "a run-backed completion should bind the run identity"
  out=$(tick_with "$state" "$PARKED_LINE" "$(( t + 400 ))") || fail "escalation tick failed"
  assert_contains "$out" "check: completion-alarm: helm parked unsurfaced" \
    "the first gate should escalate"
  [ "$(queue_alarm_count "$state" helm)" = 1 ] || fail "expected one wake for gate 1"
  # The supervisor answers the gate and the fix step lands its commits in the
  # GATE repo, so the run head advances while the crew worktree HEAD does not.
  # The run then parks at fix_review, which reconciles as `parked` all over
  # again, and that whole working interval falls between two sweeps - so no
  # reconciliation observes it and the identity must carry the difference.
  FAKE_EPISODE="run:R1@2222222222222222222222222222222222222222"
  out=$(tick_with "$state" "$PARKED_LINE" "$(( t + 500 ))") || fail "re-arm tick failed"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$crew_head" ] \
    || fail "the test moved the crew HEAD, which a real fix round never does"
  [ -z "$out" ] || fail "the second episode escalated inside its own window: $out"
  assert_grep "first_epoch=$(( t + 500 ))" "$rec" \
    "a completion under an advanced run head must restart the episode window"
  [ "$(queue_alarm_count "$state" helm)" = 1 ] || fail "the new episode woke inside its window"
  out=$(tick_with "$state" "$PARKED_LINE" "$(( t + 900 ))") || fail "gate 2 tick failed"
  assert_contains "$out" "check: completion-alarm: helm parked unsurfaced" \
    "the second gate is a distinct episode and must alarm on its own merits"
  [ "$(queue_alarm_count "$state" helm)" = 2 ] \
    || fail "two distinct episodes merged behind one state value"
  # An unmoved run identity is the SAME episode and must stay suppressed, so
  # this closes the merge without reopening the re-nag direction.
  out=$(tick_with "$state" "$PARKED_LINE" "$(( t + 1400 ))") || fail "same-episode tick failed"
  [ -z "$out" ] || fail "an unchanged episode re-nagged: $out"
  [ "$(queue_alarm_count "$state" helm)" = 2 ] \
    || fail "an unchanged episode queued a duplicate wake"
  FAKE_EPISODE=""
  pass "two distinct run episodes sharing one state value never merge, and one never re-nags"
}

test_tick_lost_run_attribution_still_alarms_next_gate() {
  local state wt out rec t
  state="$TMP_ROOT/tick-flap/state"; mkdir -p "$state"
  wt="$TMP_ROOT/tick-flap/wt"
  git init -q "$wt"
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "crew work"
  fm_write_meta "$state/helm.meta" "kind=ship" "worktree=$wt"
  t=$(date +%s)
  rec=$(record_path "$state" helm)
  FAKE_EPISODE="run:R1@1111111111111111111111111111111111111111"
  out=$(tick_with "$state" "$PARKED_LINE" "$t") || fail "arm tick failed"
  out=$(tick_with "$state" "$PARKED_LINE" "$(( t + 400 ))") || fail "escalation tick failed"
  assert_contains "$out" "check: completion-alarm: helm parked unsurfaced" \
    "the first gate should escalate"
  [ "$(queue_alarm_count "$state" helm)" = 1 ] || fail "expected one wake for gate 1"
  # A bounded no-mistakes read times out, so the reader loses run attribution
  # and answers from the status log with no identity line at all. The evidence
  # kind changed, so the stamped identity is no longer comparable - an already
  # fired record must not ride that flap out and swallow what comes next.
  FAKE_EPISODE=""
  out=$(tick_with "$state" "$PARKED_LINE" "$(( t + 500 ))") || fail "flap tick failed"
  [ -z "$out" ] || fail "the attribution flap escalated on the spot: $out"
  assert_grep "episode_source=head" "$rec" "the flap should record the evidence it now has"
  # The supervisor answers the gate, the fix round lands in the gate repo, and
  # the run parks at fix_review with an advanced head. Attribution is back.
  FAKE_EPISODE="run:R1@2222222222222222222222222222222222222222"
  out=$(tick_with "$state" "$PARKED_LINE" "$(( t + 900 ))") || fail "gate 2 tick failed"
  assert_contains "$out" "check: completion-alarm: helm parked unsurfaced" \
    "a gate reached across an attribution flap must still alarm"
  [ "$(queue_alarm_count "$state" helm)" = 2 ] \
    || fail "the second gate was swallowed by the flapped evidence kind"
  FAKE_EPISODE=""
  pass "a completion whose run attribution flapped still alarms on the next gate"
}

test_tick_underivable_identity_still_matures_the_alarm() {
  local state out rec
  state="$TMP_ROOT/tick-noident/state"; mkdir -p "$state"
  # No run token from the reader and no worktree= in the meta, so neither
  # identity can be derived. The window must still run down from where it
  # started: re-arming on each unidentifiable sighting would push the deadline
  # forward every sweep and the alarm would never mature at all.
  fm_write_meta "$state/helm.meta" "kind=ship"
  rec=$(record_path "$state" helm)
  out=$(tick_with "$state" "$DONE_LINE" "$(epoch_ago 400)") || fail "arm tick failed"
  [ -z "$out" ] || fail "an unidentifiable completion escalated immediately: $out"
  assert_grep "episode_source=none" "$rec" \
    "an underivable identity must be recorded as such, never as a real one"
  assert_grep "first_epoch=$(epoch_ago 400)" "$rec" "the window should start at first sighting"
  out=$(tick_with "$state" "$DONE_LINE" "$(epoch_ago 350)") || fail "second tick failed"
  [ -z "$out" ] || fail "escalated before the window elapsed: $out"
  assert_grep "first_epoch=$(epoch_ago 400)" "$rec" \
    "an unidentifiable sighting must not reset the window start"
  out=$(tick_with "$state" "$DONE_LINE") || fail "matured tick failed"
  assert_contains "$out" "check: completion-alarm: helm done unsurfaced" \
    "the alarm must still mature and fire once without a derivable identity"
  [ "$(queue_alarm_count "$state" helm)" = 1 ] || fail "expected exactly one wake"
  out=$(tick_with "$state" "$DONE_LINE") || fail "post-escalation tick failed"
  [ -z "$out" ] || fail "an unidentifiable episode re-nagged: $out"
  pass "an underivable identity still matures the alarm and fires it exactly once"
}

test_tick_bounds_a_single_hung_read() {
  local state out rec started elapsed
  state="$TMP_ROOT/tick-hung/state"; mkdir -p "$state"
  fm_write_meta "$state/helm.meta" "kind=ship"
  arm_record "$state" helm 'done' "checks green" "$(epoch_ago 400)"
  rec=$(record_path "$state" helm)
  started=$(date +%s)
  out=$(tick_with_hung_reader "$state" 1) || fail "hung-reader tick failed"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 10 ] \
    || fail "one wedged read held the sweep for ${elapsed}s, stalling the watcher poll loop"
  [ -z "$out" ] || fail "a timed-out read escalated: $out"
  assert_present "$rec" "a timed-out read must leave the record untouched"
  ! grep -qE '^escalated_epoch=[0-9]+$' "$rec" \
    || fail "a timed-out read must not stamp an escalation"
  [ ! -e "$state/.wake-queue" ] || fail "a timed-out read queued a wake"
  pass "one wedged reconciliation read is hard-bounded and cannot stall the sweep"
}

test_tick_bounds_one_sweeps_work() {
  local state out cursor mode
  state="$TMP_ROOT/tick-budget/state"; mkdir -p "$state"
  fm_write_meta "$state/aaa.meta" "kind=ship"
  fm_write_meta "$state/bbb.meta" "kind=ship"
  fm_write_meta "$state/ccc.meta" "kind=ship"
  # A reader slower than the whole sweep's budget: the first task consumes it,
  # so the sweep must stop taking on new tasks instead of running N x slow
  # reads inside the watcher's poll loop.
  out=$(tick_with_slow_reader "$state" 1 1) || fail "budgeted tick failed"
  [ -z "$out" ] || fail "a budgeted sweep escalated: $out"
  assert_present "$(record_path "$state" aaa)" "the sweep should reconcile its first task"
  assert_absent "$(record_path "$state" bbb)" \
    "a sweep past its budget must stop taking on new tasks"
  assert_absent "$(record_path "$state" ccc)" \
    "a sweep past its budget must stop taking on new tasks"
  # The cursor names a task and lives beside the records, so it owes the same
  # private mode the record contract states.
  cursor="$state/pending-completions/.scan-cursor"
  assert_present "$cursor" "a truncated sweep should record where it stopped"
  mode=$(stat -c %a "$cursor" 2>/dev/null || stat -f %Lp "$cursor" 2>/dev/null)
  [ "$mode" = 600 ] || fail "the sweep cursor should be 0600 like the records, got $mode"
  # The reader stays just as slow, so every sweep keeps truncating. The tail
  # must still be reached: a sweep resumes after the task the last one stopped
  # on instead of re-reconciling the same head forever, so the bound defers
  # work and never starves it.
  out=$(tick_with_slow_reader "$state" 1 1) || fail "second budgeted tick failed"
  assert_present "$(record_path "$state" bbb)" \
    "an equally slow next sweep must resume at the deferred tail"
  out=$(tick_with_slow_reader "$state" 1 1) || fail "third budgeted tick failed"
  assert_present "$(record_path "$state" ccc)" \
    "every task must be reconciled within a bounded number of slow sweeps"
  pass "a bounded sweep defers its tail to the next sweep and never starves it"
}

test_tick_preserves_record_when_reader_fails() {
  local state out rec first
  state="$TMP_ROOT/tick-reader-fail/state"; mkdir -p "$state"
  fm_write_meta "$state/helm.meta" "kind=ship"
  fm_write_meta "$state/spare.meta" "kind=ship"
  first=$(epoch_ago 400)
  arm_record "$state" helm 'done' "checks green" "$first"
  rec=$(record_path "$state" helm)
  # A reader that cannot run at all (a persistently broken FM_CREW_STATE_BIN)
  # proves nothing about the task, so it must not restart the episode.
  out=$(tick_with_broken_reader "$state" missing) || fail "tick failed on a missing reader"
  [ -z "$out" ] || fail "a failed reconciliation read escalated: $out"
  assert_present "$rec" "a failed reconciliation read must not discard the armed record"
  assert_grep "first_epoch=$first" "$rec" "a failed read must not restart the episode window"
  assert_absent "$(record_path "$state" spare)" "a failed read must not arm a record either"
  [ ! -e "$state/.wake-queue" ] || fail "a failed reconciliation read queued a wake"
  # A reader that exits 0 but emits something other than the canonical
  # `state:` verdict is equally a reader failure, not a non-terminal verdict.
  out=$(tick_with_broken_reader "$state" garbage) || fail "tick failed on a garbage reader"
  [ -z "$out" ] || fail "a malformed reader line escalated: $out"
  assert_grep "first_epoch=$first" "$rec" "a malformed reader line must not restart the window"
  # The regression: with the window preserved, the FIRST successful read of the
  # still-terminal state escalates instead of starting the episode over.
  out=$(tick_with "$state" "$DONE_LINE") || fail "recovered tick failed"
  assert_contains "$out" "check: completion-alarm: helm done unsurfaced" \
    "the first successful read after reader failures should escalate the aged episode"
  [ "$(queue_alarm_count "$state" helm)" = 1 ] \
    || fail "exactly one durable wake expected once the reader recovers"
  pass "a failed reconciliation read preserves the record and its episode window"
}

test_tick_clears_orphaned_record() {
  local state out rec
  state="$TMP_ROOT/tick-orphan/state"; mkdir -p "$state"
  arm_record "$state" gone 'done' "old completion" "$(epoch_ago 4000)"
  # A record left behind by the teardown-vs-escalation-stamp race carries only
  # the appended stamp, so it no longer names its task in the record body; the
  # file name is still the task id, and the sweep must fall back to it.
  rec=$(record_path "$state" stamped-only)
  printf 'escalated_epoch=%s\n' "$(epoch_ago 4000)" > "$rec"
  out=$(tick_with "$state" "$DONE_LINE") || fail "tick failed"
  [ -z "$out" ] || fail "an orphaned record (no task meta) was escalated: $out"
  assert_absent "$(record_path "$state" gone)" "orphaned record must be removed"
  assert_absent "$rec" "an orphaned record with no surviving meta keys must be removed"
  pass "completion tick removes records whose task is gone, malformed ones included"
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
  arm_record "$case_dir/state" task-x1 'done' "landed work"
  arm_record "$case_dir/state" other-task 'done' "unrelated completion"
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
test_tick_busy_flap_never_renags_escalated_episode
test_tick_busy_period_ends_episode_and_next_completion_alarms
test_tick_distinct_episodes_never_merge_behind_one_state
test_tick_lost_run_attribution_still_alarms_next_gate
test_tick_underivable_identity_still_matures_the_alarm
test_tick_bounds_a_single_hung_read
test_tick_bounds_one_sweeps_work
test_tick_preserves_record_when_reader_fails
test_tick_clears_orphaned_record
test_watcher_alarms_lost_completion_and_rearms_after_restart
test_teardown_clears_task_record
