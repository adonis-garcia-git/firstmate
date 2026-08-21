#!/usr/bin/env bash
# tests/fm-decision-wait.test.sh - age-in-waiting tracking for captain-gated
# decisions (bin/fm-decision-wait.sh) and the watcher's once-daily
# decision-digest wake (bin/fm-watch.sh). Covers: first-observed wait-start
# recorded when a captain hold or needs-decision appears, ages preserved across
# restarts (fresh processes over the durable record) and across runtime
# tasks-axi failures (a failed held read must not reset recorded ages),
# resolved/unheld waits dropping out, the meta-missing open-decision rule
# mirroring origin_open_decisions, stale reconcile temp files being swept,
# ranking by unblocking power then age, and the digest wake firing at most
# once per interval and never when nothing is waiting.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DW="$ROOT/bin/fm-decision-wait.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-wait)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  printf '%s\n' "$home"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_dw() {  # <home> <subcommand...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$DW" "$@"
}

record_of() {  # <home>
  cat "$1/data/decision-waits.tsv" 2>/dev/null || true
}

# Rewrite one wait's recorded first-observed epoch, simulating a wait first
# observed by an earlier session so a fresh process must compute age from the
# durable record rather than from its own start.
backdate_record() {  # <home> <wait-id> <epoch>
  local home=$1 wid=$2 epoch=$3 f="$1/data/decision-waits.tsv"
  awk -F '\t' -v OFS='\t' -v id="$wid" -v e="$epoch" \
    '$1 == id { $2 = e } { print }' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
}

add_captain_hold() {  # <home> <id> <title>
  local home=$1 id=$2 title=$3
  tasks_in "$home" add "$id" "$title" --kind captain >/dev/null \
    || fail "could not add backlog item $id"
  tasks_in "$home" hold "$id" --reason "captain decision pending" --kind captain >/dev/null \
    || fail "could not hold $id"
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

wait_for_grep() {  # <pattern> <file> [limit-ticks]
  local pattern=$1 file=$2 limit=${3:-100} i=0
  while [ "$i" -lt "$limit" ]; do
    grep -q "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

watch_bg() {  # <home> <out> [extra env assignments...]
  local home=$1 out=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
    "$@" "$WATCH" > "$out" 2>/dev/null &
}

# --- wait-start recording ----------------------------------------------------

test_hold_wait_start_recorded_first_observed() {
  local home before after rec epoch epoch2
  home=$(make_home hold-start)
  add_captain_hold "$home" dec-a "Pick the API shape"
  before=$(date +%s)
  run_dw "$home" scan >/dev/null || fail "scan failed on a fresh captain hold"
  after=$(date +%s)
  rec=$(record_of "$home")
  assert_contains "$rec" "hold:dec-a" "captain hold must be recorded on appearance"
  epoch=$(printf '%s\n' "$rec" | awk -F '\t' '$1 == "hold:dec-a" { print $2 }')
  case "$epoch" in ''|*[!0-9]*) fail "recorded wait-start is not an epoch: $epoch" ;; esac
  [ "$epoch" -ge "$before" ] && [ "$epoch" -le "$after" ] \
    || fail "wait-start must be the observation time (got $epoch, window $before..$after)"
  assert_contains "$rec" "observed" "conservative starts must be marked as first-observed"
  sleep 1
  run_dw "$home" scan >/dev/null || fail "re-scan failed"
  epoch2=$(record_of "$home" | awk -F '\t' '$1 == "hold:dec-a" { print $2 }')
  [ "$epoch2" = "$epoch" ] || fail "re-scan must preserve first-observed time, not reset it"
  pass "captain-hold wait-start recorded at first observation and preserved on re-scan"
}

test_status_wait_recorded_and_filters() {
  local home rec
  home=$(make_home status-start)
  printf 'working: setup\nneeds-decision [key=api]: choose REST or RPC\nblocked [key=infra]: waiting on firstmate\n' \
    > "$home/state/t1.status"
  fm_write_meta "$home/state/t1.meta" "window=x:fm-t1" "kind=ship"
  tasks_in "$home" add ext-item "Externally held work" >/dev/null || fail "could not add ext-item"
  tasks_in "$home" hold ext-item --reason "waiting on upstream release" --kind external >/dev/null \
    || fail "could not hold ext-item"
  run_dw "$home" scan >/dev/null || fail "scan failed"
  rec=$(record_of "$home")
  assert_contains "$rec" "status:t1:api" "open needs-decision must be recorded as a wait"
  assert_not_contains "$rec" "status:t1:infra" "a blocked line is not a captain-gated wait"
  assert_not_contains "$rec" "ext-item" "a non-captain hold kind must not be recorded"
  pass "needs-decision recorded; blocked lines and non-captain holds filtered out"
}

# --- age across restarts -----------------------------------------------------

test_age_computed_from_durable_record_across_restarts() {
  local home now row epoch age
  home=$(make_home restart-age)
  add_captain_hold "$home" dec-old "An old decision"
  run_dw "$home" scan >/dev/null || fail "scan failed"
  now=$(date +%s)
  backdate_record "$home" hold:dec-old $(( now - 100000 ))
  row=$(run_dw "$home" list | grep '^hold:dec-old') || fail "listed wait missing after restart"
  epoch=$(printf '%s' "$row" | cut -f2)
  age=$(printf '%s' "$row" | cut -f3)
  [ "$epoch" = "$(( now - 100000 ))" ] || fail "restart must preserve the recorded wait-start (got $epoch)"
  [ "$age" -ge 100000 ] && [ "$age" -lt 100600 ] \
    || fail "age must be computed from the durable record (got $age)"
  pass "age computed from the durable record by a fresh process"
}

# --- drop-out ----------------------------------------------------------------

test_resolved_and_unheld_waits_drop_out() {
  local home
  home=$(make_home drop-out)
  add_captain_hold "$home" dec-a "Pick the API shape"
  printf 'needs-decision [key=api]: choose REST or RPC\n' > "$home/state/t1.status"
  run_dw "$home" scan >/dev/null || fail "scan failed"
  assert_contains "$(record_of "$home")" "hold:dec-a" "fixture hold must be recorded"
  assert_contains "$(record_of "$home")" "status:t1:api" "fixture status wait must be recorded"
  tasks_in "$home" unhold dec-a >/dev/null || fail "could not unhold dec-a"
  printf 'resolved [key=api]: captain chose REST\n' >> "$home/state/t1.status"
  run_dw "$home" scan >/dev/null || fail "re-scan failed"
  [ -z "$(record_of "$home")" ] || fail "cleared waits must drop out of the record: $(record_of "$home")"
  [ -z "$(run_dw "$home" list)" ] || fail "cleared waits must not be listed"
  [ -z "$(run_dw "$home" digest)" ] || fail "digest must be empty with no waits"
  pass "unheld holds and resolved status decisions drop out; empty digest stays silent"
}

# --- outage preservation -----------------------------------------------------

# A tasks-axi that passes the compatibility probe but fails at list time (e.g.
# an unreadable backlog) must preserve recorded hold entries and their ages.
test_runtime_list_failure_preserves_hold_ages() {
  local home shim real rec epoch epoch2
  home=$(make_home holds-outage)
  add_captain_hold "$home" dec-a "Pick the API shape"
  run_dw "$home" scan >/dev/null || fail "scan failed on a fresh captain hold"
  epoch=$(record_of "$home" | awk -F '\t' '$1 == "hold:dec-a" { print $2 }')
  [ -n "$epoch" ] || fail "fixture hold must be recorded"
  shim="$TMP_ROOT/axi-shim"
  mkdir -p "$shim"
  real=$(command -v tasks-axi)
  # shellcheck disable=SC2016  # $1 and $@ are the shim's own parameters, expanded when it runs.
  printf '#!/bin/sh\ncase "$1" in list) echo "backlog unreadable" >&2; exit 1 ;; esac\nexec %s "$@"\n' \
    "$real" > "$shim/tasks-axi"
  chmod +x "$shim/tasks-axi"
  PATH="$shim:$PATH" run_dw "$home" scan >/dev/null 2>&1 \
    || fail "scan must still exit 0 when the held listing fails"
  rec=$(record_of "$home")
  assert_contains "$rec" "hold:dec-a" "a failed held listing must preserve recorded holds"
  epoch2=$(printf '%s\n' "$rec" | awk -F '\t' '$1 == "hold:dec-a" { print $2 }')
  [ "$epoch2" = "$epoch" ] \
    || fail "a failed held listing must not reset the wait-start (got $epoch2, want $epoch)"
  run_dw "$home" scan >/dev/null || fail "re-scan failed after the outage cleared"
  epoch2=$(record_of "$home" | awk -F '\t' '$1 == "hold:dec-a" { print $2 }')
  [ "$epoch2" = "$epoch" ] \
    || fail "recovery must keep the original wait-start (got $epoch2, want $epoch)"
  pass "a runtime tasks-axi list failure preserves recorded hold ages across the outage"
}

# --- meta-missing open decisions ---------------------------------------------

# origin_open_decisions skips the ended-verb check when no .meta exists; the
# wait tracker must apply the same rule so both consumers agree.
test_status_wait_without_meta_skips_ended_check() {
  local home rec
  home=$(make_home no-meta)
  printf 'needs-decision [key=api]: choose REST or RPC\ndone: wrapped up\n' > "$home/state/t1.status"
  run_dw "$home" scan >/dev/null || fail "scan failed"
  rec=$(record_of "$home")
  assert_contains "$rec" "status:t1:api" \
    "a task with no .meta must stay open despite a last done verb"
  pass "meta-missing status waits mirror origin_open_decisions and stay open"
}

# --- ranking -----------------------------------------------------------------

test_ranking_prefers_blocking_then_age() {
  local home now out first digest
  home=$(make_home ranking)
  add_captain_hold "$home" dec-block "Decision blocking two work items"
  tasks_in "$home" add work-1 "Blocked work one" >/dev/null
  tasks_in "$home" add work-2 "Blocked work two" >/dev/null
  tasks_in "$home" block work-1 --by dec-block >/dev/null || fail "could not block work-1"
  tasks_in "$home" block work-2 --by dec-block >/dev/null || fail "could not block work-2"
  add_captain_hold "$home" dec-oldest "Oldest decision, blocks nothing"
  add_captain_hold "$home" dec-newer "Newer decision, blocks nothing"
  printf 'needs-decision [key=ux]: pick layout A or B\n' > "$home/state/t1.status"
  fm_write_meta "$home/state/t1.meta" "window=x:fm-t1" "kind=ship"
  run_dw "$home" scan >/dev/null || fail "scan failed"
  now=$(date +%s)
  backdate_record "$home" hold:dec-oldest $(( now - 500000 ))
  backdate_record "$home" hold:dec-newer $(( now - 1000 ))
  out=$(run_dw "$home" list | cut -f1 | paste -sd' ' -)
  [ "$out" = "hold:dec-block status:t1:ux hold:dec-oldest hold:dec-newer" ] \
    || fail "ranking must prefer blocking waits then age (got: $out)"
  first=$(run_dw "$home" list | head -1)
  assert_contains "$first" "work-1,work-2" "blocked items must be listed for the top wait"
  digest=$(run_dw "$home" digest)
  assert_contains "$digest" "4 captain decisions waiting" "digest must carry the wait count"
  assert_contains "$digest" "1) hold:dec-block" "digest must rank the strongest unblocker first"
  assert_contains "$digest" "blocks 2" "digest must carry the blocked-work count"
  pass "ranking prefers blocking decisions, then oldest; digest carries ranked data"
}

# --- no-data homes stay inert ------------------------------------------------

test_home_without_data_dir_is_inert() {
  local home out
  home="$TMP_ROOT/state-only"
  mkdir -p "$home/state"
  printf 'needs-decision: pick A or B\n' > "$home/state/t1.status"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$DW" digest 2>/dev/null) || fail "digest must exit 0 in a home with no data directory"
  [ -z "$out" ] || fail "digest must stay silent in a home with no data directory: $out"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$DW" scan >/dev/null 2>&1 || fail "scan must exit 0 in a home with no data directory"
  [ ! -d "$home/data" ] || fail "a no-data home must not have data/ materialized as a side effect"
  pass "a home without a data directory is skipped silently and never written"
}

# --- reconcile temp hygiene --------------------------------------------------

test_reconcile_sweeps_stale_tmpfiles() {
  local home stale fresh
  home=$(make_home tmp-sweep)
  stale="$home/data/.decision-waits.stale0"
  fresh="$home/data/.decision-waits.fresh0"
  : > "$stale"
  set_mtime $(( $(date +%s) - 7200 )) "$stale"
  : > "$fresh"
  run_dw "$home" scan >/dev/null || fail "scan failed"
  [ ! -e "$stale" ] || fail "reconcile must sweep stale .decision-waits.* leftovers"
  [ -e "$fresh" ] || fail "reconcile must leave recent temp files (a live concurrent reconcile) alone"
  pass "stale reconcile temp files are swept; recent ones are preserved"
}

# --- watcher digest wake -----------------------------------------------------

# Set <file>'s mtime to exactly <epoch> seconds (BSD `date -r` or GNU `date -d @`).
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

marker_mtime() {  # <file>
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1"; else stat -c %Y "$1"; fi
}

test_watch_digest_fires_once_per_interval_and_stays_quiet() {
  local home out pid queue marker anchored
  home=$(make_home watch-digest)
  add_captain_hold "$home" dec-a "Pick the API shape"
  queue="$home/state/.wake-queue"
  marker="$home/state/.last-decision-digest"

  # A fresh home's first sweep anchors the cadence without firing, even with a
  # waiting decision on the books.
  out="$home/watch0.out"
  watch_bg "$home" "$out"
  pid=$!
  wait_live "$pid" 25 || { reap "$pid"; fail "watcher exited on a fresh home's first sweep: $(cat "$out")"; }
  reap "$pid"
  [ -e "$marker" ] || fail "first sweep must anchor the digest cadence marker"
  [ ! -e "$queue" ] || ! grep -q "decision-digest" "$queue" \
    || fail "a fresh home must not fire a digest on its first cycle"
  assert_contains "$(record_of "$home")" "hold:dec-a" \
    "the anchoring sweep must still record the wait"

  # An aged marker makes the digest due: exactly one ranked wake is queued.
  set_mtime $(( $(date +%s) - 90000 )) "$marker"
  out="$home/watch1.out"
  watch_bg "$home" "$out"
  pid=$!
  wait_for_grep "check: decision-digest:" "$out" 150 \
    || { reap "$pid"; fail "digest wake did not fire with a waiting decision and an aged marker"; }
  wait "$pid" 2>/dev/null || true
  [ "$(grep -c 'decision-digest' "$queue")" -eq 1 ] || fail "exactly one digest wake expected"
  grep -q "hold:dec-a" "$queue" || fail "the digest wake must carry the ranked wait data"

  # Within the interval a re-armed watcher must not fire again, even though the
  # same wait (the current top item) is still there.
  out="$home/watch2.out"
  watch_bg "$home" "$out"
  pid=$!
  wait_live "$pid" 25 || { reap "$pid"; fail "watcher exited again within the digest interval: $(cat "$out")"; }
  reap "$pid"
  [ "$(grep -c 'decision-digest' "$queue")" -eq 1 ] \
    || fail "at most one digest wake per interval (queue: $(cat "$queue"))"

  # With no waiting decision an eligible (aged) sweep must stay quiet: no wake
  # and no cadence-marker advance, so the next sweep re-checks immediately.
  tasks_in "$home" unhold dec-a >/dev/null || fail "could not unhold dec-a"
  anchored=$(( $(date +%s) - 90000 ))
  set_mtime "$anchored" "$marker"
  out="$home/watch3.out"
  watch_bg "$home" "$out"
  pid=$!
  wait_live "$pid" 25 || { reap "$pid"; fail "watcher exited with nothing waiting: $(cat "$out")"; }
  reap "$pid"
  [ "$(grep -c 'decision-digest' "$queue")" -eq 1 ] || fail "no digest wake when nothing is waiting"
  [ "$(marker_mtime "$marker")" -eq "$anchored" ] \
    || fail "an empty digest must not advance the cadence marker"
  [ -z "$(record_of "$home")" ] || fail "watcher-driven reconcile must drop the cleared wait"
  pass "digest anchors quietly, fires once per interval, never repeats within it, and stays quiet when nothing waits"
}

test_hold_wait_start_recorded_first_observed
test_status_wait_recorded_and_filters
test_age_computed_from_durable_record_across_restarts
test_resolved_and_unheld_waits_drop_out
test_runtime_list_failure_preserves_hold_ages
test_status_wait_without_meta_skips_ended_check
test_ranking_prefers_blocking_then_age
test_home_without_data_dir_is_inert
test_reconcile_sweeps_stale_tmpfiles
test_watch_digest_fires_once_per_interval_and_stays_quiet
