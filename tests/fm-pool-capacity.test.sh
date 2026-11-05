#!/usr/bin/env bash
# tests/fm-pool-capacity.test.sh - bin/fm-pool-capacity.sh warns before a
# project's Treehouse pool runs out of free isolated copies.
# A real project repository with real linked worktrees stands in for the pool,
# so the slot proof (fm_treehouse_pool_slot) runs for real; only `treehouse
# status --json` is faked, replaying a canned slot table.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POOL="$ROOT/bin/fm-pool-capacity.sh"
TMP_ROOT=$(fm_test_tmproot fm-pool-capacity)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# <dir>/project with max_trees=4, pool slots 1-4 as linked worktrees, a fake
# treehouse replaying <dir>/status.json, and task-a holding slot 1.
make_pool_case() {  # <name> -> dir
  local dir=$1 n
  dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/fakebin" "$dir/pool"
  git init -q "$dir/project"
  git -C "$dir/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf 'max_trees = 4\n' > "$dir/project/treehouse.toml"
  printf '{}\n' > "$dir/pool/treehouse-state.json"
  for n in 1 2 3 4; do
    git -C "$dir/project" worktree add -q --detach "$dir/pool/$n/project"
  done
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}"
[ "${1:-}" = status ] && [ "${2:-}" = --json ] || exit 1
cat "$FM_FAKE_TREEHOUSE_STATUS"
SH
  chmod +x "$dir/fakebin/treehouse"
  fm_write_meta "$dir/home/state/task-a.meta" "worktree=$dir/pool/1/project" \
    "project=$dir/project" "kind=ship"
  printf '%s\n' "$dir"
}

# Write the slot table: one status per slot 1-4, in order.
pool_status() {  # <dir> <s1> <s2> <s3> <s4>
  local dir=$1 n=0 s sep='' json='['
  shift
  for s in "$@"; do
    n=$((n + 1))
    json="$json$sep{\"name\":\"$n\",\"path\":\"$dir/pool/$n/project\",\"status\":\"$s\",\"processes\":[]}"
    sep=,
  done
  printf '%s]\n' "$json" > "$dir/status.json"
}

run_pool() {  # <dir> [args...]
  local dir=$1
  shift
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_FAKE_TREEHOUSE_STATUS="$dir/status.json" FM_FAKE_TREEHOUSE_LOG="$dir/treehouse.log" \
    FM_POOL_CHECK_SECS="${FM_POOL_CHECK_SECS:-0}" bash "$POOL" "$@"
}

test_report_counts_free_copies() {
  local dir out
  dir=$(make_pool_case report)
  # Slot 3 is available to Treehouse but a parked task still owns it.
  fm_write_meta "$dir/home/state/task-b.meta" "worktree=$dir/pool/3/project" \
    "project=$dir/project" "kind=ship"
  pool_status "$dir" in-use dirty available available
  out=$(run_pool "$dir") || fail "the report failed: $out"
  [ "$out" = "pool: project free=1 max=4 slots=4 available=2 dirty=1 in_use=1 low=yes" ] \
    || fail "unexpected report: $out"
  pass "a pool's free copies exclude in-use, dirty, and parked-owned slots"
}

test_report_counts_room_below_max_trees() {
  local dir out
  dir=$(make_pool_case room)
  printf 'max_trees = 8\n' > "$dir/project/treehouse.toml"
  pool_status "$dir" in-use dirty dirty dirty
  out=$(run_pool "$dir") || fail "the report failed: $out"
  [ "$out" = "pool: project free=4 max=8 slots=4 available=0 dirty=3 in_use=1 low=no" ] \
    || fail "unexpected report: $out"
  rm -f "$dir/project/treehouse.toml"
  out=$(run_pool "$dir") || fail "the report failed: $out"
  [ "$out" = "pool: project free=12 max=16 slots=4 available=0 dirty=3 in_use=1 low=no" ] \
    || fail "a pool without max_trees did not use Treehouse's default of 16: $out"
  pass "slots the pool may still create below max_trees count as free"
}

test_check_warns_once_per_change() {
  local dir out
  dir=$(make_pool_case check)
  pool_status "$dir" in-use dirty dirty available
  out=$(run_pool "$dir" check) || fail "check failed: $out"
  case "$out" in
    "check: pool-capacity: project has 1 free isolated copies of 4 (2 dirty, 1 in use); clean up finished tasks or raise max_trees in project/treehouse.toml") ;;
    *) fail "a nearly full pool did not warn: $out" ;;
  esac
  [ "$(awk -F '\t' '$3 == "check" && $4 == "pool-capacity:project"' "$dir/home/state/.wake-queue" | wc -l | tr -d ' ')" = 1 ] \
    || fail "the warning was not queued as one durable check wake: $(cat "$dir/home/state/.wake-queue" 2>&1)"
  out=$(run_pool "$dir" check) || fail "check failed: $out"
  [ -z "$out" ] || fail "an unchanged warning repeated: $out"
  pool_status "$dir" in-use available available available
  out=$(run_pool "$dir" check) || fail "check failed: $out"
  [ -z "$out" ] || fail "a pool with room warned: $out"
  pool_status "$dir" in-use dirty dirty available
  out=$(run_pool "$dir" check) || fail "check failed: $out"
  [ -n "$out" ] || fail "a pool that filled again did not warn again"
  pass "check mode warns once per change in a nearly full pool and again after it refills"
}

test_check_is_throttled_and_scoped() {
  local dir out
  dir=$(make_pool_case throttle)
  pool_status "$dir" in-use dirty dirty available
  run_pool "$dir" check >/dev/null || fail "first check failed"
  : > "$dir/treehouse.log"
  out=$(FM_POOL_CHECK_SECS=600 run_pool "$dir" check) || fail "throttled check failed"
  [ -z "$out" ] && [ ! -s "$dir/treehouse.log" ] || fail "a check inside the throttle window queried the pool"
  # A record whose copy is not a pool slot never makes Treehouse create a pool.
  rm -f "$dir/home/state/task-a.meta"
  mkdir -p "$dir/elsewhere"
  fm_write_meta "$dir/home/state/task-c.meta" "worktree=$dir/elsewhere" "project=$dir/project" "kind=ship"
  out=$(run_pool "$dir") || fail "the report failed: $out"
  [ -z "$out" ] && [ ! -s "$dir/treehouse.log" ] || fail "a project with no pool slot was queried: $out"
  pass "check mode is throttled and only asks about pools this home's tasks use"
}

test_watcher_surfaces_a_nearly_full_pool() {
  local dir pid i
  dir=$(make_pool_case watcher)
  pool_status "$dir" in-use dirty dirty available
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_FAKE_TREEHOUSE_STATUS="$dir/status.json" FM_POOL_CHECK_SECS=0 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err" &
  pid=$!
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 150 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -Fq 'check: pool-capacity: project has 1 free isolated copies of 4' "$dir/watch.out" \
    || fail "the watcher did not surface the nearly full pool: $(cat "$dir/watch.out" "$dir/watch.err")"
  grep -Fq 'pool-capacity:project' "$dir/home/state/.wake-queue" \
    || fail "the watcher-run check left no durable wake"
  pass "the watcher's check sweep surfaces a nearly full pool"
}

test_report_counts_free_copies
test_report_counts_room_below_max_trees
test_check_warns_once_per_change
test_check_is_throttled_and_scoped
test_watcher_surfaces_a_nearly_full_pool
