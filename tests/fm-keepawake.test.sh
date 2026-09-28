#!/usr/bin/env bash
# tests/fm-keepawake.test.sh - the idle-sleep assertion bin/fm-keepawake.sh
# holds while a home has live work, pinned to the supervising session's
# process. Real processes throughout: a fake harness named claude owns the
# session lock, and a fake assertion tool honors caffeinate's -w contract, so
# the cases run on any platform. One case drives the real /usr/bin/caffeinate
# where macOS provides it.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

KEEPAWAKE="$ROOT/bin/fm-keepawake.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-keepawake)

HARNESS_BIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s "$(command -v bash)" "$HARNESS_BIN/claude"

FAKE_TOOL="$TMP_ROOT/fake-caffeinate"
cat > "$FAKE_TOOL" <<'SH'
#!/usr/bin/env bash
# Honors `-i -w <pid>`: stay alive until <pid> exits.
[ "${1:-}" = -i ] && [ "${2:-}" = -w ] || exit 64
while kill -0 "$3" 2>/dev/null; do sleep 0.1; done
SH
chmod +x "$FAKE_TOOL"

SPAWNED=()
cleanup_spawned() {
  local pid
  for pid in ${SPAWNED[@]+"${SPAWNED[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_spawned; fm_test_cleanup' EXIT

# A live process whose command name is claude, standing in for the session.
# Sets HARNESS_PID rather than printing it: a command substitution would record
# the pid in a subshell's SPAWNED and leak the process past cleanup.
# It returns only once the child has exec'd as claude: until then the fork
# still carries this script's EXIT-trap signal handling, so a prompt kill is
# swallowed (and `reap` would wait out the whole sleep), and a lock check would
# see bash rather than a harness.
HARNESS_PID=
start_harness() {
  local i=0
  "$HARNESS_BIN/claude" -c 'sleep 300; :' </dev/null >/dev/null 2>&1 &
  HARNESS_PID=$!
  SPAWNED+=("$HARNESS_PID")
  while [ "$i" -lt 100 ]; do
    case "$(ps -o args= -p "$HARNESS_PID" 2>/dev/null)" in *"-c sleep 300"*) return 0 ;; esac
    sleep 0.05
    i=$((i + 1))
  done
  fail "the fake session never started"
}

make_home() {  # <name> <anchor-pid-or-empty>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  [ -z "$2" ] || printf '%s\n' "$2" > "$home/state/.lock"
  printf '%s\n' "$home"
}

add_task() {  # <home> <id> <kind>
  printf 'window=test:fm-%s\nkind=%s\nharness=claude\n' "$2" "$3" > "$1/state/$2.meta"
}

keepawake() {  # <home> <command> [tool]
  FM_KEEPAWAKE=on FM_KEEPAWAKE_BIN="${3:-$FAKE_TOOL}" FM_HOME="$1" "$KEEPAWAKE" "$2"
}

reap() {  # <pid>
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

held_pid() {  # <home>
  sed -n 's/^pid=//p' "$1/state/.keepawake" 2>/dev/null | head -1
}

wait_dead() {  # <pid> <tenths>
  local i=0
  while [ "$i" -lt "$2" ] && kill -0 "$1" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  ! kill -0 "$1" 2>/dev/null
}

test_assertion_follows_live_work() {
  local anchor home pid again args
  start_harness; anchor=$HARNESS_PID
  home=$(make_home follows "$anchor")

  keepawake "$home" reconcile || fail "reconcile failed on an idle home"
  assert_equals "$(keepawake "$home" status)" released "an idle home took an assertion"

  add_task "$home" sample-mate secondmate
  keepawake "$home" reconcile || fail "reconcile failed with only a secondmate"
  assert_equals "$(keepawake "$home" status)" released "an idle secondmate counted as live work"

  add_task "$home" sample-ship ship
  keepawake "$home" reconcile || fail "reconcile failed with live work"
  pid=$(held_pid "$home")
  assert_equals "$(keepawake "$home" status)" "held pid=$pid anchor=$anchor" \
    "live work did not take an assertion pinned to the session"
  args=$(ps -o args= -p "$pid")
  assert_contains "$args" "$FAKE_TOOL -i -w $anchor" "the assertion is not tied to the session process"
  keepawake "$home" reconcile || fail "a repeated reconcile failed"
  again=$(held_pid "$home")
  assert_equals "$again" "$pid" "a repeated reconcile replaced a healthy assertion"

  kill "$pid"
  wait_dead "$pid" 50 || fail "could not stop the assertion from outside"
  keepawake "$home" reconcile || fail "reconcile failed after the assertion died"
  again=$(held_pid "$home")
  assert_not_equals "$again" "$pid" "a killed assertion was not restarted"
  kill -0 "$again" 2>/dev/null || fail "the restarted assertion is not running"

  rm -f "$home/state/sample-ship.meta"
  keepawake "$home" reconcile || fail "reconcile failed after the last task left"
  wait_dead "$again" 50 || fail "the assertion outlived the last live task"
  assert_equals "$(keepawake "$home" status)" released "the record survived the release"
  pass "the assertion is held exactly while the home has live work and restarts when killed"
}

test_assertion_never_outlives_the_session() {
  local anchor home pid
  start_harness; anchor=$HARNESS_PID
  home=$(make_home session-end "$anchor")
  add_task "$home" sample-ship ship
  keepawake "$home" reconcile || fail "reconcile failed"
  pid=$(held_pid "$home")
  kill -0 "$pid" 2>/dev/null || fail "no assertion was taken"
  reap "$anchor"
  wait_dead "$pid" 50 || fail "the assertion outlived the supervising session with no cleanup run"

  start_harness; anchor=$HARNESS_PID
  printf '%s\n' "$anchor" > "$home/state/.lock"
  reap "$anchor"
  wait_dead "$anchor" 50 || fail "could not end the second fake session"
  keepawake "$home" reconcile || fail "reconcile failed on a stale lock"
  assert_equals "$(keepawake "$home" status)" released "a stale session lock took an assertion"

  start_harness; anchor=$HARNESS_PID
  printf '%s\n' "$anchor" > "$home/state/.lock"
  keepawake "$home" reconcile || fail "reconcile failed under a new session"
  pid=$(held_pid "$home")
  assert_equals "$(keepawake "$home" status)" "held pid=$pid anchor=$anchor" \
    "a new session did not take its own assertion"
  FM_KEEPAWAKE=off FM_KEEPAWAKE_BIN="$FAKE_TOOL" FM_HOME="$home" "$KEEPAWAKE" reconcile \
    || fail "reconcile failed while disabled"
  wait_dead "$pid" 50 || fail "disabling keep-awake left the assertion running"
  pass "the assertion dies with its session and only a live session lock can take one"
}

test_release_touches_only_its_own_assertion() {
  local anchor home other bystander
  start_harness; anchor=$HARNESS_PID
  home=$(make_home own-only "$anchor")
  other=$(make_home other-home "$anchor")
  add_task "$other" other-ship ship
  keepawake "$other" reconcile || fail "the other home could not take its assertion"
  bystander=$(held_pid "$other")

  # This home's record names another home's assertion and then an unrelated
  # process: neither may be signalled when this home releases.
  printf 'pid=%s\nanchor=%s\n' "$bystander" 1 > "$home/state/.keepawake"
  keepawake "$home" reconcile || fail "reconcile failed over a foreign record"
  kill -0 "$bystander" 2>/dev/null || fail "a release signalled another home's assertion"
  sleep 300 >/dev/null 2>&1 &
  SPAWNED+=("$!")
  printf 'pid=%s\nanchor=%s\n' "$!" "$anchor" > "$home/state/.keepawake"
  keepawake "$home" reconcile || fail "reconcile failed over a recycled pid"
  kill -0 "$!" 2>/dev/null || fail "a release signalled a process that is not its assertion"
  [ ! -e "$home/state/.keepawake" ] || fail "an unverifiable record was kept"
  assert_contains "$(keepawake "$other" status)" "held pid=$bystander" "the other home lost its assertion"
  pass "a release signals only a process verified as this home's assertion"
}

test_watcher_takes_the_assertion_and_it_survives_the_cycle() {
  local anchor dir state out pid held i
  start_harness; anchor=$HARNESS_PID
  dir=$(make_case watcher-keepawake); state="$dir/state"; out="$dir/watch.out"
  printf '%s\n' "$anchor" > "$state/.lock"
  add_task "$dir" watched-ship ship
  PATH="$dir/fakebin:$PATH" FM_KEEPAWAKE=on FM_KEEPAWAKE_BIN="$FAKE_TOOL" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ -z "$(held_pid "$dir")" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  held=$(held_pid "$dir")
  [ -n "$held" ] || { reap "$pid"; fail "the watcher never took the assertion: $(cat "$out")"; }
  reap "$pid"
  kill -0 "$held" 2>/dev/null || fail "the assertion ended with the watcher cycle instead of the session"
  reap "$anchor"
  wait_dead "$held" 50 || fail "the assertion outlived the session after the watcher exited"
  pass "the watcher takes the assertion and it spans watcher cycles until the session ends"
}

test_real_caffeinate_holds_an_idle_sleep_assertion() {
  local anchor home pid
  if [ "$(uname)" != Darwin ] || [ ! -x /usr/bin/caffeinate ]; then
    echo "skip: /usr/bin/caffeinate is macOS-only"
    return 0
  fi
  start_harness; anchor=$HARNESS_PID
  home=$(make_home real-caffeinate "$anchor")
  add_task "$home" sample-ship ship
  FM_KEEPAWAKE=on FM_HOME="$home" "$KEEPAWAKE" reconcile || fail "reconcile failed with caffeinate"
  pid=$(held_pid "$home")
  assert_equals "$(FM_HOME="$home" "$KEEPAWAKE" status)" "held pid=$pid anchor=$anchor" \
    "the real caffeinate assertion is not recorded"
  pmset -g assertions 2>/dev/null | grep -E "pid $pid\(caffeinate\).*PreventUserIdleSystemSleep" >/dev/null \
    || fail "caffeinate pid $pid holds no PreventUserIdleSystemSleep assertion: $(pmset -g assertions 2>&1 | grep caffeinate)"
  reap "$anchor"
  wait_dead "$pid" 50 || fail "caffeinate outlived the session it was pinned to"
  pass "the real caffeinate holds an idle-sleep assertion that ends with the session"
}

test_assertion_follows_live_work
test_assertion_never_outlives_the_session
test_release_touches_only_its_own_assertion
test_watcher_takes_the_assertion_and_it_survives_the_cycle
test_real_caffeinate_holds_an_idle_sleep_assertion
