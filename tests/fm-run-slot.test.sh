#!/usr/bin/env bash
# Behavioral coverage for bin/fm-run-slot.sh: config parsing and refusals,
# command execution and exit status, first-come-first-served fairness, many
# concurrent acquirers never exceeding the slot count, slots and queue places
# freed when a holder or waiter is killed, signal forwarding, the memory floor
# through both memory probes, and one machine-wide queue shared by a local
# secondmate home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-run-slot)
SLOT="$ROOT/bin/fm-run-slot.sh"

# Background acquire processes and the commands they run, killed by recorded
# PID only, before the shared fixture cleanup.
BG_PIDS=()
BG_PIDFILES=()
run_slot_test_cleanup() {
  local pid f
  for f in "${BG_PIDFILES[@]:-}"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -9 "$pid" 2>/dev/null || true
  done
  for pid in "${BG_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap run_slot_test_cleanup EXIT
trap 'run_slot_test_cleanup; exit 130' INT
trap 'run_slot_test_cleanup; exit 143' TERM

# make_home <name> [config-line...]: a home whose fake meminfo reports plenty
# of memory, with config/run-slots holding the given lines when any are given.
make_home() {
  local home="$TMP_ROOT/$1" line
  shift
  mkdir -p "$home/state" "$home/config" "$home/proc"
  set_mem_kb "$home" 33554432
  if [ "$#" -gt 0 ]; then
    : > "$home/config/run-slots"
    for line in "$@"; do printf '%s\n' "$line" >> "$home/config/run-slots"; done
  fi
  printf '%s\n' "$home"
}

set_mem_kb() {  # <home> <MemAvailable-kB>
  printf 'MemTotal:       67108864 kB\nMemFree:          100000 kB\nMemAvailable:   %s kB\n' "$2" > "$1/proc/meminfo.tmp"
  mv -f "$1/proc/meminfo.tmp" "$1/proc/meminfo"
}

run_slot() {  # <home> <args...>
  local home=$1
  shift
  PATH="${RUN_SLOT_PATH:-$BASE_PATH}" FM_HOME="$home" FM_RUN_SLOT_POLL_SECS=0.1 \
    FM_PROC_ROOT_OVERRIDE="${RUN_SLOT_PROC:-$home/proc}" "$SLOT" "$@"
}

# bg_slot <home> <log> <args...>: start an acquire in the background.
bg_slot() {
  local home=$1 log=$2
  shift 2
  run_slot "$home" "$@" > "$log" 2>&1 &
  BG_PIDS+=("$!")
  BG_LAST=$!
}

# gate_cmd <dir> <name>: a command that records its PID and blocks until
# <dir>/<name>.open exists.
gate_cmd() {
  BG_PIDFILES+=("$1/$2.pid")
  printf 'echo $$ > %s/%s.pid; while [ ! -e %s/%s.open ]; do sleep 0.05; done' "$1" "$2" "$1" "$2"
}

wait_for() {  # <seconds> <description> <command...>
  local limit=$1 what=$2 i=0
  shift 2
  while ! "$@" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le $((limit * 10)) ] || fail "timed out waiting for: $what"
    sleep 0.1
  done
}

class_line() {  # <home> <class>
  run_slot "$1" status 2>&1 | grep "^$2: "
}

has_counts() {  # <home> <class> <held>/<slots> <waiting>
  class_line "$1" "$2" | grep -q "^$2: $3 held, $4 waiting,"
}

status_has() {  # <home> <text>
  run_slot "$1" status 2>&1 | grep -qF -- "$2"
}

test_usage_errors() {
  local home out rc
  home=$(make_home usage)
  out=$(run_slot "$home" 2>&1); rc=$?
  expect_code 2 "$rc" "no subcommand"
  out=$(run_slot "$home" acquire -- true 2>&1); rc=$?
  expect_code 2 "$rc" "acquire without --class"
  assert_contains "$out" "acquire needs --class cpu or --class net" "missing class was not explained"
  out=$(run_slot "$home" acquire --class gpu -- true 2>&1); rc=$?
  expect_code 2 "$rc" "unknown class"
  out=$(run_slot "$home" acquire --class cpu 2>&1); rc=$?
  expect_code 2 "$rc" "acquire without a command"
  out=$(run_slot "$home" status extra 2>&1); rc=$?
  expect_code 2 "$rc" "status with an argument"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_RUN_SLOT_POLL_SECS=0 "$SLOT" status 2>&1); rc=$?
  expect_code 2 "$rc" "a zero poll interval"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_RUN_SLOT_POLL_SECS=soon "$SLOT" status 2>&1); rc=$?
  expect_code 2 "$rc" "a non-numeric poll interval"
  out=$(run_slot "$home" --help 2>&1); rc=$?
  expect_code 0 "$rc" "--help"
  assert_contains "$out" "acquire --class <cpu|net> [--wait] -- <command>" "--help did not print the usage"
  pass "usage errors exit 2 and --help prints the header"
}

test_config_defaults_and_overrides() {
  local home out
  home=$(make_home defaults)
  out=$(run_slot "$home" status 2>&1) || fail "status failed without a config: $out"
  assert_contains "$out" "cpu: 0/2 held, 0 waiting, memory floor 2048 MB, reclaimable 32768 MB" "cpu defaults"
  assert_contains "$out" "net: 0/8 held, 0 waiting, memory floor 1024 MB, reclaimable 32768 MB" "net defaults"

  home=$(make_home overrides '# run slots for this machine' '' 'cpu_slots=3' '   ' 'net_mem_floor_mb=0' 'cpu_mem_floor_mb=0512' 'net_slots=12')
  out=$(run_slot "$home" status 2>&1) || fail "status failed with a valid config: $out"
  assert_contains "$out" "cpu: 0/3 held, 0 waiting, memory floor 512 MB," "cpu overrides"
  assert_contains "$out" "net: 0/12 held, 0 waiting, no memory floor," "net overrides"
  pass "config/run-slots defaults and overrides are applied"
}

test_config_refusals() {
  local home out rc line expect i=0
  while IFS='|' read -r line expect; do
    i=$((i + 1))
    home=$(make_home "refuse-$i" 'cpu_slots=2' "$line")
    out=$(run_slot "$home" status 2>&1); rc=$?
    expect_code 1 "$rc" "status with config line '$line'"
    assert_contains "$out" "$home/config/run-slots line 2: $expect" "refusal for '$line'"
    out=$(run_slot "$home" acquire --class net -- touch "$home/ran" 2>&1); rc=$?
    expect_code 1 "$rc" "acquire with config line '$line'"
    assert_absent "$home/ran" "acquire ran its command under an unreadable config ('$line')"
  done <<'EOF'
cpu_slots=3|cpu_slots is set more than once
net_slots=0|net_slots must be a positive integer
net_slots=two|net_slots must be a positive integer
cpu_mem_floor_mb=-1|cpu_mem_floor_mb must be a non-negative integer
gpu_slots=1|unknown key: gpu_slots
cpu_slots|expected key=value
EOF
  home=$(make_home refuse-dir)
  mkdir "$home/config/run-slots"
  out=$(run_slot "$home" status 2>&1); rc=$?
  expect_code 1 "$rc" "status with a directory as config"
  assert_contains "$out" "run-slots is not a readable regular file" "unreadable config was not named"
  pass "a malformed or unreadable config stops acquire and status with the file and line"
}

test_runs_command_and_propagates_status() {
  local home out rc
  home=$(make_home run)
  out=$(printf 'from stdin\n' | run_slot "$home" acquire --class cpu -- sh -c 'cat; printf "%s|" "$@"; exit 3' sh 'two words' "it's" 2>&1); rc=$?
  expect_code 3 "$rc" "the command's exit status"
  assert_contains "$out" "from stdin" "the command did not read acquire's stdin"
  assert_contains "$out" "two words|it's|" "arguments were not passed through intact"
  has_counts "$home" cpu 0/2 0 || fail "the slot was not freed after the command exited: $(class_line "$home" cpu)"
  out=$(run_slot "$home" acquire --class net -- "$TMP_ROOT/no-such-command" 2>&1); rc=$?
  expect_code 127 "$rc" "a command that cannot be executed"
  assert_contains "$out" "cannot execute" "an unexecutable command was not explained"
  has_counts "$home" net 0/8 0 || fail "the net slot was not freed after a failed exec"
  pass "acquire runs the command with its stdin and arguments and returns its status"
}

test_no_wait_refuses_when_full() {
  local home dir out rc
  home=$(make_home nowait 'cpu_slots=1')
  dir="$home/run"; mkdir -p "$dir"
  bg_slot "$home" "$dir/holder.log" acquire --class cpu -- sh -c "$(gate_cmd "$dir" holder)"
  wait_for 10 "the holder to start" test -s "$dir/holder.pid"
  out=$(run_slot "$home" acquire --class cpu -- touch "$dir/ran" 2>&1); rc=$?
  expect_code 75 "$rc" "acquire without --wait while every slot is held"
  assert_contains "$out" "no cpu slot free: all 1 cpu slots are held" "a busy refusal did not say why"
  assert_absent "$dir/ran" "a refused acquire ran its command"
  out=$(run_slot "$home" acquire --class net -- touch "$dir/net-ran" 2>&1); rc=$?
  expect_code 0 "$rc" "a net run while cpu slots are full: $out"
  assert_present "$dir/net-ran" "a net run queued behind cpu runs"
  touch "$dir/holder.open"
  wait "$BG_LAST" || fail "the holder failed"
  pass "without --wait a full class refuses with exit 75 and other classes are unaffected"
}

test_fifo_order() {
  local home dir name waiting=0 pids=() p
  home=$(make_home fifo 'cpu_slots=1')
  dir="$home/run"; mkdir -p "$dir"
  bg_slot "$home" "$dir/holder.log" acquire --class cpu --wait -- sh -c "$(gate_cmd "$dir" holder)"
  wait_for 10 "the holder to start" test -s "$dir/holder.pid"
  for name in w1 w2 w3 w4 w5; do
    bg_slot "$home" "$dir/$name.log" acquire --class cpu --wait -- sh -c "echo $name >> '$dir/order'"
    pids+=("$BG_LAST")
    waiting=$((waiting + 1))
    wait_for 10 "$name to queue" has_counts "$home" cpu 1/1 "$waiting"
  done
  assert_contains "$(run_slot "$home" status)" "position 1 pid ${pids[0]}, next: all 1 cpu slots are held" \
    "status did not show the head of the queue and why it waits"
  touch "$dir/holder.open"
  for p in "${pids[@]}"; do wait "$p" || fail "a queued run failed"; done
  assert_equals "w1 w2 w3 w4 w5" "$(tr '\n' ' ' < "$dir/order" | sed 's/ $//')" "queued runs did not start in arrival order"
  assert_contains "$(cat "$dir/w1.log")" "first in line for a cpu slot" "the head waiter did not report its turn"
  has_counts "$home" cpu 0/1 0 || fail "slots or queue places leaked after the FIFO run"
  pass "waiting runs start first-come-first-served"
}

test_concurrent_acquirers_never_exceed_slots() {
  local home dir i pids=() p failed=0 max lines out rc
  home=$(make_home concurrent 'cpu_slots=2')
  dir="$home/run"; mkdir -p "$dir"

  # Both slots are usable at once, and only both.
  bg_slot "$home" "$dir/g1.log" acquire --class cpu --wait -- sh -c "$(gate_cmd "$dir" g1)"
  pids+=("$BG_LAST")
  bg_slot "$home" "$dir/g2.log" acquire --class cpu --wait -- sh -c "$(gate_cmd "$dir" g2)"
  pids+=("$BG_LAST")
  wait_for 10 "both gated holders to start" test -s "$dir/g1.pid" -a -s "$dir/g2.pid"
  out=$(run_slot "$home" acquire --class cpu -- true 2>&1); rc=$?
  expect_code 75 "$rc" "a third run while both slots are held"
  touch "$dir/g1.open" "$dir/g2.open"
  for p in "${pids[@]}"; do wait "$p" || fail "a gated holder failed"; done

  pids=()
  : > "$dir/events"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    bg_slot "$home" "$dir/a$i.log" acquire --class cpu --wait -- sh -c "echo + >> '$dir/events'; sleep 0.3; echo - >> '$dir/events'"
    pids+=("$BG_LAST")
  done
  for p in "${pids[@]}"; do wait "$p" || failed=$((failed + 1)); done
  assert_equals 0 "$failed" "concurrent acquirers failed"
  max=$(awk '{ c += ($1 == "+") ? 1 : -1; if (c > m) m = c } END { print m + 0 }' "$dir/events")
  lines=$(wc -l < "$dir/events" | tr -d ' ')
  assert_equals 24 "$lines" "not every concurrent run started and finished"
  [ "$max" -le 2 ] || fail "concurrent acquirers held $max slots at once with cpu_slots=2"
  has_counts "$home" cpu 0/2 0 || fail "slots or queue places leaked after concurrent runs"
  pass "two slots run side by side and twelve concurrent acquirers never exceed them"
}

test_killed_holder_and_waiter_free_their_places() {
  local home dir out rc wrapper child queued_dead
  home=$(make_home killed 'cpu_slots=1')
  dir="$home/run"; mkdir -p "$dir"

  # Killing only the acquire process keeps the slot while its command runs.
  bg_slot "$home" "$dir/holder.log" acquire --class cpu -- sh -c "$(gate_cmd "$dir" holder)"
  wrapper=$BG_LAST
  wait_for 10 "the holder to start" test -s "$dir/holder.pid"
  child=$(cat "$dir/holder.pid")
  kill -9 "$wrapper"
  { wait "$wrapper"; } 2>/dev/null
  out=$(run_slot "$home" acquire --class cpu -- true 2>&1); rc=$?
  expect_code 75 "$rc" "a slot whose command still runs after its acquire process was killed"
  has_counts "$home" cpu 1/1 0 || fail "status lost a holder whose command is alive"

  # A killed waiter gives up its queue place.
  bg_slot "$home" "$dir/dead.log" acquire --class cpu --wait -- touch "$dir/dead-ran"
  queued_dead=$BG_LAST
  wait_for 10 "the doomed waiter to queue" has_counts "$home" cpu 1/1 1
  bg_slot "$home" "$dir/next.log" acquire --class cpu --wait -- touch "$dir/next-ran"
  wait_for 10 "the next waiter to queue" has_counts "$home" cpu 1/1 2
  kill -9 "$queued_dead"
  { wait "$queued_dead"; } 2>/dev/null
  wait_for 10 "the dead waiter to leave the queue" has_counts "$home" cpu 1/1 1

  # When the command itself dies, the slot frees and the next waiter runs.
  kill -9 "$child"
  wait "$BG_LAST" || fail "the waiter behind a killed holder failed: $(cat "$dir/next.log")"
  assert_present "$dir/next-ran" "the waiter behind a killed holder never ran"
  assert_absent "$dir/dead-ran" "a killed waiter ran its command"
  has_counts "$home" cpu 0/1 0 || fail "a killed holder or waiter leaked a place"
  pass "a killed holder frees its slot once its command is gone and a killed waiter leaves the queue"
}

test_signals_are_forwarded_and_release() {
  local home dir rc waiter term_wrapper
  home=$(make_home signals 'cpu_slots=1')
  dir="$home/run"; mkdir -p "$dir"
  BG_PIDFILES+=("$dir/term.pid")
  bg_slot "$home" "$dir/term.log" acquire --class cpu -- sh -c "echo \$\$ > '$dir/term.pid'; trap 'echo got-term > \"$dir/term.seen\"; exit 9' TERM; while :; do sleep 0.05; done"
  term_wrapper=$BG_LAST
  wait_for 10 "the trapping command to start" test -s "$dir/term.pid"

  # TERM while queued leaves the queue.
  bg_slot "$home" "$dir/queued.log" acquire --class cpu --wait -- touch "$dir/queued-ran"
  waiter=$BG_LAST
  wait_for 10 "the waiter to queue" has_counts "$home" cpu 1/1 1
  kill -TERM "$waiter"
  wait "$waiter"; rc=$?
  expect_code 143 "$rc" "TERM while queued"
  has_counts "$home" cpu 1/1 0 || fail "a TERMed waiter kept its queue place"

  kill -TERM "$term_wrapper"
  wait "$term_wrapper"; rc=$?
  expect_code 9 "$rc" "acquire's status after its command handled a forwarded TERM"
  assert_present "$dir/term.seen" "TERM was not forwarded to the command"
  assert_absent "$dir/queued-ran" "a TERMed waiter ran its command"
  has_counts "$home" cpu 0/1 0 || fail "the slot was not freed after a forwarded TERM"
  pass "TERM is forwarded to a running command and leaves the queue while waiting"
}

test_memory_floor_meminfo() {
  local home dir out rc notes
  home=$(make_home mem-proc 'cpu_mem_floor_mb=1000')
  dir="$home/run"; mkdir -p "$dir"
  set_mem_kb "$home" 512000

  # With no cpu holder the floor is waived, so one run always progresses.
  out=$(run_slot "$home" acquire --class cpu -- touch "$dir/first-ran" 2>&1); rc=$?
  expect_code 0 "$rc" "the first cpu run below the memory floor: $out"
  assert_present "$dir/first-ran" "the first cpu run below the memory floor did not start"
  bg_slot "$home" "$dir/holder.log" acquire --class cpu --wait -- sh -c "$(gate_cmd "$dir" holder)"
  wait_for 10 "the waived holder to start" test -s "$dir/holder.pid"
  assert_contains "$(run_slot "$home" status)" "cpu: 1/2 held, 0 waiting" "a waiting first run below the floor did not take its slot"

  # With one holder and a free slot, the next run waits on memory.
  out=$(run_slot "$home" acquire --class cpu -- touch "$dir/ran" 2>&1); rc=$?
  expect_code 75 "$rc" "a second acquire below the memory floor without --wait"
  assert_contains "$out" "reclaimable memory 500 MB is below the 1000 MB floor" "the memory refusal did not say why"
  assert_absent "$dir/ran" "a second run below the memory floor started"
  bg_slot "$home" "$dir/wait.log" acquire --class cpu --wait -- touch "$dir/ran"
  wait_for 10 "the run to queue on memory" has_counts "$home" cpu 1/2 1
  assert_contains "$(run_slot "$home" status)" "next: reclaimable memory 500 MB is below the 1000 MB floor" \
    "status did not show the memory wait"
  set_mem_kb "$home" 600000
  wait_for 10 "status to show the new memory reading" status_has "$home" "next: reclaimable memory 585 MB is below"
  sleep 0.3
  assert_absent "$dir/ran" "a queued run started below the memory floor"
  set_mem_kb "$home" 4096000
  wait "$BG_LAST" || fail "the queued run failed after memory freed"
  assert_present "$dir/ran" "the queued run never started after memory freed"
  notes=$(grep -c 'first in line' "$dir/wait.log")
  assert_equals 1 "$notes" "the memory wait note was reprinted as the reading changed: $(cat "$dir/wait.log")"
  touch "$dir/holder.open"
  wait_for 10 "the holder to release" has_counts "$home" cpu 0/2 0
  pass "the memory floor is waived for a class's first run and holds further runs until /proc/meminfo reports enough"
}

test_memory_floor_vm_stat() {
  local home dir fakebin out rc
  home=$(make_home mem-vmstat 'cpu_mem_floor_mb=1000' 'net_mem_floor_mb=400')
  dir="$home/run"; mkdir -p "$dir" "$home/noproc"
  fakebin=$(fm_fakebin "$home")
  # 10000 free + 20000 inactive + 2000 speculative pages of 16 KiB = 500 MB.
  cat > "$fakebin/vm_stat" <<'SH'
#!/bin/sh
echo 'Mach Virtual Memory Statistics: (page size of 16384 bytes)'
echo 'Pages free:                               10000.'
echo 'Pages active:                            900000.'
echo 'Pages inactive:                           20000.'
echo 'Pages speculative:                         2000.'
echo 'Pages wired down:                        100000.'
SH
  chmod +x "$fakebin/vm_stat"
  bg_slot "$home" "$dir/holder.log" acquire --class cpu -- sh -c "$(gate_cmd "$dir" holder)"
  wait_for 10 "the cpu holder to start" test -s "$dir/holder.pid"
  out=$(RUN_SLOT_PATH="$fakebin:$BASE_PATH" RUN_SLOT_PROC="$home/noproc" run_slot "$home" status 2>&1)
  assert_contains "$out" "reclaimable 500 MB" "vm_stat free, inactive, and speculative pages were not summed"
  out=$(RUN_SLOT_PATH="$fakebin:$BASE_PATH" RUN_SLOT_PROC="$home/noproc" run_slot "$home" acquire --class cpu -- true 2>&1); rc=$?
  expect_code 75 "$rc" "a second cpu acquire below its floor through vm_stat"
  out=$(RUN_SLOT_PATH="$fakebin:$BASE_PATH" RUN_SLOT_PROC="$home/noproc" run_slot "$home" acquire --class net -- true 2>&1); rc=$?
  expect_code 0 "$rc" "net acquire above its own floor through vm_stat: $out"

  printf '#!/bin/sh\nexit 1\n' > "$fakebin/vm_stat"
  out=$(RUN_SLOT_PATH="$fakebin:$BASE_PATH" RUN_SLOT_PROC="$home/noproc" run_slot "$home" status 2>&1)
  assert_contains "$out" "reclaimable memory unknown, floor not enforced" "an unavailable memory probe was not reported"
  out=$(RUN_SLOT_PATH="$fakebin:$BASE_PATH" RUN_SLOT_PROC="$home/noproc" run_slot "$home" acquire --class cpu -- true 2>&1); rc=$?
  expect_code 0 "$rc" "a second cpu acquire when no memory probe works: $out"
  touch "$dir/holder.open"
  wait "$BG_LAST" || fail "the cpu holder failed"
  pass "vm_stat feeds the memory floor where /proc/meminfo is absent, and an unknown reading is not enforced"
}

test_secondmate_home_shares_root_queue() {
  local root mate dir out rc
  root=$(make_home shared-root 'cpu_slots=1')
  mate="$TMP_ROOT/shared-mate"
  mkdir -p "$mate/state" "$mate/config"
  printf 'cpu_slots=5\n' > "$mate/config/run-slots"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$root" > "$mate/.fm-secondmate-parent"
  dir="$root/run"; mkdir -p "$dir"
  bg_slot "$root" "$dir/holder.log" acquire --class cpu -- sh -c "$(gate_cmd "$dir" holder)"
  wait_for 10 "the root holder to start" test -s "$dir/holder.pid"
  out=$(RUN_SLOT_PROC="$root/proc" run_slot "$mate" acquire --class cpu -- touch "$dir/mate-ran" 2>&1); rc=$?
  expect_code 75 "$rc" "a secondmate home acquiring while the root home's only slot is held"
  out=$(RUN_SLOT_PROC="$root/proc" run_slot "$mate" status 2>&1)
  assert_contains "$out" "cpu: 1/1 held" "a secondmate home did not read the root home's config and holders"
  assert_absent "$mate/state/run-slots" "a secondmate home kept its own run-slot state"
  touch "$dir/holder.open"
  wait "$BG_LAST" || fail "the root holder failed"
  pass "a local secondmate home shares the root home's machine-wide queue"
}

test_usage_errors
test_config_defaults_and_overrides
test_config_refusals
test_runs_command_and_propagates_status
test_no_wait_refuses_when_full
test_fifo_order
test_concurrent_acquirers_never_exceed_slots
test_killed_holder_and_waiter_free_their_places
test_signals_are_forwarded_and_release
test_memory_floor_meminfo
test_memory_floor_vm_stat
test_secondmate_home_shares_root_queue
echo '# all fm-run-slot tests passed'
