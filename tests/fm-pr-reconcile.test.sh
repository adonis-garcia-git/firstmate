#!/usr/bin/env bash
# Tests for bin/fm-pr-reconcile.sh: the throttled, batched reconcile sweep that
# detects recorded PRs merged or closed externally on GitHub and surfaces them
# through the durable wake queue, plus its watcher and bootstrap wiring.
#
# Matrix:
#   (a) merged recorded PR queues one check wake naming state and sources
#   (b) closed-unmerged recorded PR queues a "closed without merging" wake
#   (c) open recorded PR queues nothing and is re-queried on the next sweep
#   (d) already-surfaced terminal PR is neither re-queried nor re-waked
#   (e) offline/auth failure: exit 0, exactly one diagnostic wake, no repeat
#       until a sweep reaches GitHub again, then one wake for a new episode
#   (f) malformed and non-GitHub URLs in backlog holds are skipped safely
#   (g) Done backlog items are excluded; open items and metas are included,
#       and all URLs go out in ONE batched gh call
#   (h) throttle: a second non-forced run inside the interval does not call gh
#   (i) seen-cache pruning drops URLs no longer recorded anywhere
#   (j) watcher check cadence runs the sweep and exits with the queued reason
#   (k) bootstrap mutating path runs the sweep; detect-only path does not
#   (l) a record set above the per-sweep cap rotates: successive sweeps cover
#       every recorded PR instead of starving the tail
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECONCILE="$ROOT/bin/fm-pr-reconcile.sh"
WATCH="$ROOT/bin/fm-watch.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:$PATH}
TMP_ROOT=$(fm_test_tmproot fm-pr-reconcile-tests)

# Hermetic backend detection for the bootstrap wiring case: ambient runtime
# markers must not flip the sandbox onto a non-tmux backend.
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

# One sandbox home per case: state/, data/, and a fakebin whose gh stub logs
# every invocation and answers `api graphql` from a canned reply file with a
# configurable exit code. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data"
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
if [ "${1:-}" = api ] && [ "${2:-}" = graphql ]; then
  [ -z "${FM_TEST_GH_REPLY:-}" ] || cat "$FM_TEST_GH_REPLY"
  exit "${FM_TEST_GH_RC:-0}"
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  : > "$case_dir/gh.log"
  printf '%s\n' "$case_dir"
}

# Run one sweep in the case sandbox. Args after <case_dir> may mix env
# KEY=VAL assignments (passed before the command) and script flags such as
# --force (passed after it).
run_sweep() {  # <case_dir> [KEY=VAL...] [--force]
  local case_dir=$1 arg
  local -a assigns=() flags=()
  shift
  for arg in "$@"; do
    case "$arg" in
      *=*) assigns+=("$arg") ;;
      *) flags+=("$arg") ;;
    esac
  done
  env PATH="$case_dir/fakebin:$BASE_PATH" \
    FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_TEST_GH_LOG="$case_dir/gh.log" \
    "${assigns[@]+"${assigns[@]}"}" "$RECONCILE" "${flags[@]+"${flags[@]}"}"
}

queue_lines() {
  local n
  n=$(grep -c . "$1/state/.wake-queue" 2>/dev/null) || true
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# --- (a) merged PR -> one check wake with state and sources -----------------

test_merged_pr_queues_wake() {
  local case_dir out rc
  case_dir=$(make_case merged)
  fm_write_meta "$case_dir/state/t1.meta" \
    "window=fm-t1" \
    "pr=https://github.com/acme/widget/pull/7"
  cat > "$case_dir/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] widget-fix - fix the widget (hold: awaiting captain merge of https://github.com/acme/widget/pull/7) (hold-kind: captain)
EOF
  printf 'pr0 MERGED\n' > "$case_dir/reply"
  out=$(run_sweep "$case_dir" FM_TEST_GH_REPLY="$case_dir/reply" --force)
  rc=$?
  expect_code 0 "$rc" "merged sweep exits 0"
  assert_contains "$out" "https://github.com/acme/widget/pull/7 was merged on GitHub" \
    "merged sweep reports the merged URL"
  assert_grep "$(printf 'check\tpr-reconcile:acme/widget#7')" "$case_dir/state/.wake-queue" \
    "merged PR queues a check wake keyed by the PR"
  assert_grep "was merged on GitHub" "$case_dir/state/.wake-queue" \
    "merged wake payload names the observed state"
  assert_grep "task t1" "$case_dir/state/.wake-queue" \
    "merged wake payload names the recording task"
  assert_grep "backlog item widget-fix" "$case_dir/state/.wake-queue" \
    "merged wake payload names the recording backlog item"
  assert_grep "$(printf 'https://github.com/acme/widget/pull/7\tMERGED')" \
    "$case_dir/state/.pr-reconcile-seen" \
    "merged observation lands in the seen cache"
  pass "merged recorded PR queues one sourced check wake"
}

# --- (b) closed-unmerged PR -> wake with closed wording ---------------------

test_closed_pr_queues_wake() {
  local case_dir out
  case_dir=$(make_case closed)
  fm_write_meta "$case_dir/state/t2.meta" \
    "window=fm-t2" \
    "pr=https://github.com/acme/widget/pull/9"
  printf 'pr0 CLOSED\n' > "$case_dir/reply"
  out=$(run_sweep "$case_dir" FM_TEST_GH_REPLY="$case_dir/reply" --force)
  expect_code 0 $? "closed sweep exits 0"
  assert_contains "$out" "was closed without merging" "closed sweep reports closed-unmerged"
  assert_grep "was closed without merging on GitHub" "$case_dir/state/.wake-queue" \
    "closed-unmerged PR queues a wake with closed wording"
  pass "closed-unmerged recorded PR queues a check wake"
}

# --- (c) open PR -> silence, re-queried next sweep --------------------------

test_open_pr_stays_silent() {
  local case_dir out
  case_dir=$(make_case open)
  fm_write_meta "$case_dir/state/t3.meta" \
    "window=fm-t3" \
    "pr=https://github.com/acme/widget/pull/11"
  printf 'pr0 OPEN\n' > "$case_dir/reply"
  out=$(run_sweep "$case_dir" FM_TEST_GH_REPLY="$case_dir/reply" --force)
  expect_code 0 $? "open sweep exits 0"
  [ -z "$out" ] || fail "open PR must produce no output (got: $out)"
  assert_absent "$case_dir/state/.wake-queue" "open PR queues no wake"
  out=$(run_sweep "$case_dir" FM_TEST_GH_REPLY="$case_dir/reply" --force)
  expect_code 2 "$(grep -c 'api graphql' "$case_dir/gh.log")" \
    "open PR is re-queried on the next sweep"
  pass "open recorded PR queues nothing and stays watched"
}

# --- (d) surfaced terminal PR is not re-queried or re-waked -----------------

test_terminal_pr_not_requeried() {
  local case_dir before after
  case_dir=$(make_case dedupe)
  fm_write_meta "$case_dir/state/t4.meta" \
    "window=fm-t4" \
    "pr=https://github.com/acme/widget/pull/13"
  printf 'pr0 MERGED\n' > "$case_dir/reply"
  run_sweep "$case_dir" FM_TEST_GH_REPLY="$case_dir/reply" --force > /dev/null
  before=$(queue_lines "$case_dir")
  run_sweep "$case_dir" FM_TEST_GH_REPLY="$case_dir/reply" --force > /dev/null
  after=$(queue_lines "$case_dir")
  [ "$before" = "$after" ] || fail "surfaced terminal PR must not wake again ($before -> $after)"
  expect_code 1 "$(grep -c 'api graphql' "$case_dir/gh.log")" \
    "surfaced terminal PR is not queried again"
  pass "surfaced terminal PR is cached, never re-queried or re-waked"
}

# --- (e) offline/auth failure: one diagnostic, no spam, episode reset -------

test_offline_failure_one_diagnostic() {
  local case_dir out rc
  case_dir=$(make_case offline)
  fm_write_meta "$case_dir/state/t5.meta" \
    "window=fm-t5" \
    "pr=https://github.com/acme/widget/pull/15"
  out=$(run_sweep "$case_dir" FM_TEST_GH_RC=1 --force)
  rc=$?
  expect_code 0 "$rc" "offline sweep exits 0"
  assert_contains "$out" "could not read recorded PR state from GitHub" \
    "offline sweep prints the diagnostic once"
  expect_code 1 "$(queue_lines "$case_dir")" "offline sweep queues exactly one diagnostic wake"
  out=$(run_sweep "$case_dir" FM_TEST_GH_RC=1 --force)
  expect_code 0 $? "repeat offline sweep exits 0"
  [ -z "$out" ] || fail "repeat offline sweep must stay silent (got: $out)"
  expect_code 1 "$(queue_lines "$case_dir")" "repeat offline sweep queues no further wake"
  # A sweep that reaches GitHub ends the failure episode...
  printf 'pr0 OPEN\n' > "$case_dir/reply"
  run_sweep "$case_dir" FM_TEST_GH_REPLY="$case_dir/reply" --force > /dev/null
  assert_absent "$case_dir/state/.pr-reconcile-error" "reaching GitHub clears the failure episode"
  # ...so the next outage surfaces one fresh diagnostic.
  out=$(run_sweep "$case_dir" FM_TEST_GH_RC=1 --force)
  assert_contains "$out" "could not read recorded PR state from GitHub" \
    "a new outage after recovery surfaces one fresh diagnostic"
  expect_code 2 "$(queue_lines "$case_dir")" "new outage queues exactly one more wake"
  pass "offline failure is loud once per episode, never spam, never a crash"
}

# --- (f) malformed and non-GitHub URLs are skipped safely -------------------

test_malformed_urls_skipped() {
  local case_dir out
  case_dir=$(make_case malformed)
  cat > "$case_dir/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] messy-item - task with junk links (hold: see https://github.com/acme/widget/pull/notanumber and https://github.com/only-owner and https://gitlab.example.com/grp/proj/-/merge_requests/4 and PR #12) (hold-kind: captain)
  body ref https://github.com/acme/widget/pull/, wrapped (https://github.com/acme/widget/pull/21).
EOF
  printf 'pr0 OPEN\n' > "$case_dir/reply"
  out=$(run_sweep "$case_dir" FM_TEST_GH_REPLY="$case_dir/reply" --force)
  expect_code 0 $? "malformed-URL sweep exits 0"
  [ -z "$out" ] || fail "malformed-URL sweep must produce no output (got: $out)"
  assert_grep "number: 21" "$case_dir/gh.log" "the one valid wrapped URL is queried"
  assert_no_grep "notanumber" "$case_dir/gh.log" "malformed PR number is never queried"
  assert_no_grep "gitlab" "$case_dir/gh.log" "GitLab merge requests are never queried"
  expect_code 1 "$(grep -c 'api graphql' "$case_dir/gh.log")" "exactly one batched query runs"
  assert_absent "$case_dir/state/.wake-queue" "malformed URLs queue nothing"
  pass "malformed and non-GitHub URL candidates are skipped safely"
}

# --- (g) Done items excluded; open items + metas batch into one call --------

test_sources_and_batching() {
  local case_dir query
  case_dir=$(make_case sources)
  fm_write_meta "$case_dir/state/t6.meta" \
    "window=fm-t6" \
    "pr=https://github.com/acme/widget/pull/31"
  cat > "$case_dir/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] open-item - live thing https://github.com/acme/widget/pull/32 (since 2026-08-20)
  continuation line https://github.com/acme/gadget/pull/33
## Done
- [x] done-item - shipped https://github.com/acme/widget/pull/34 (merged 2026-08-19)
  done continuation https://github.com/acme/widget/pull/35
EOF
  printf 'pr0 OPEN\npr1 OPEN\npr2 OPEN\n' > "$case_dir/reply"
  run_sweep "$case_dir" FM_TEST_GH_REPLY="$case_dir/reply" --force > /dev/null
  expect_code 1 "$(grep -c 'api graphql' "$case_dir/gh.log")" \
    "all recorded URLs go out in one batched gh call"
  query=$(grep 'api graphql' "$case_dir/gh.log")
  assert_contains "$query" "number: 31" "meta pr= URL is queried"
  assert_contains "$query" "number: 32" "open backlog item URL is queried"
  assert_contains "$query" "number: 33" "open item continuation-line URL is queried"
  assert_not_contains "$query" "number: 34" "Done item URL is not queried"
  assert_not_contains "$query" "number: 35" "Done item continuation URL is not queried"
  pass "open items and metas batch into one call; Done items are excluded"
}

# --- (h) throttle: second non-forced run does not call gh -------------------

test_throttle() {
  local case_dir out
  case_dir=$(make_case throttle)
  fm_write_meta "$case_dir/state/t7.meta" \
    "window=fm-t7" \
    "pr=https://github.com/acme/widget/pull/41"
  printf 'pr0 OPEN\n' > "$case_dir/reply"
  run_sweep "$case_dir" FM_TEST_GH_REPLY="$case_dir/reply" > /dev/null
  expect_code 1 "$(grep -c 'api graphql' "$case_dir/gh.log")" "first non-forced sweep queries"
  out=$(run_sweep "$case_dir" FM_TEST_GH_REPLY="$case_dir/reply")
  expect_code 0 $? "throttled sweep exits 0"
  [ -z "$out" ] || fail "throttled sweep must stay silent (got: $out)"
  expect_code 1 "$(grep -c 'api graphql' "$case_dir/gh.log")" \
    "a second sweep inside the interval never reaches gh"
  pass "self-throttle keeps repeat sweeps off the network"
}

# --- (i) seen-cache entries for unrecorded URLs are pruned ------------------

test_seen_cache_pruned() {
  local case_dir
  case_dir=$(make_case prune)
  fm_write_meta "$case_dir/state/t8.meta" \
    "window=fm-t8" \
    "pr=https://github.com/acme/widget/pull/51"
  fm_write_meta "$case_dir/state/t9.meta" \
    "window=fm-t9" \
    "pr=https://github.com/acme/widget/pull/52"
  printf 'pr0 MERGED\npr1 OPEN\n' > "$case_dir/reply"
  run_sweep "$case_dir" FM_TEST_GH_REPLY="$case_dir/reply" --force > /dev/null
  assert_grep "pull/51" "$case_dir/state/.pr-reconcile-seen" "terminal observation is cached"
  rm "$case_dir/state/t8.meta"
  printf 'pr0 OPEN\n' > "$case_dir/reply"
  run_sweep "$case_dir" FM_TEST_GH_REPLY="$case_dir/reply" --force > /dev/null
  assert_no_grep "pull/51" "$case_dir/state/.pr-reconcile-seen" \
    "cache entry for an unrecorded URL is pruned"
  pass "seen cache stays bounded to currently recorded URLs"
}

# --- (j) watcher check cadence runs the sweep and surfaces the wake ---------

test_watcher_wiring() {
  local case_dir out_file i
  case_dir=$(make_case watcher)
  fm_write_meta "$case_dir/state/t10.meta" \
    "pr=https://github.com/acme/widget/pull/61"
  printf 'pr0 MERGED\n' > "$case_dir/reply"
  out_file="$case_dir/watch.out"
  PATH="$case_dir/fakebin:$BASE_PATH" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_HOME="$case_dir" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_TEST_GH_LOG="$case_dir/gh.log" FM_TEST_GH_REPLY="$case_dir/reply" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out_file" &
  watch_pid=$!
  i=0
  while kill -0 "$watch_pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  assert_grep "check: pr-reconcile: PR https://github.com/acme/widget/pull/61 was merged" \
    "$out_file" "watcher surfaces the reconcile wake reason"
  assert_grep "was merged on GitHub" "$case_dir/state/.wake-queue" \
    "watcher-run sweep leaves the durable queue record"
  pass "watcher check cadence runs the sweep and exits on its wake"
}

# --- (k) bootstrap wiring: mutating path sweeps, detect-only does not -------

test_bootstrap_wiring() {
  local case_dir home
  case_dir=$(make_case bootstrap)
  home="$case_dir"
  fm_write_meta "$home/state/t11.meta" \
    "pr=https://github.com/acme/widget/pull/71"
  printf 'pr0 MERGED\n' > "$case_dir/reply"
  PATH="$case_dir/fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_TEST_GH_LOG="$case_dir/gh.log" FM_TEST_GH_REPLY="$case_dir/reply" \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$BOOTSTRAP" > /dev/null 2>&1 || true
  assert_absent "$home/state/.wake-queue" "detect-only bootstrap never runs the sweep"
  PATH="$case_dir/fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_TEST_GH_LOG="$case_dir/gh.log" FM_TEST_GH_REPLY="$case_dir/reply" \
    "$BOOTSTRAP" > /dev/null 2>&1 || true
  assert_grep "was merged on GitHub" "$home/state/.wake-queue" \
    "locked bootstrap runs the sweep and queues the wake"
  pass "bootstrap runs the sweep only on the mutating path"
}

# --- (l) capped record set rotates across sweeps ----------------------------

test_cap_rotation() {
  local case_dir
  case_dir=$(make_case rotation)
  fm_write_meta "$case_dir/state/t12.meta" \
    "window=fm-t12" \
    "pr=https://github.com/acme/widget/pull/81"
  fm_write_meta "$case_dir/state/t13.meta" \
    "window=fm-t13" \
    "pr=https://github.com/acme/widget/pull/82"
  printf 'pr0 OPEN\n' > "$case_dir/reply"
  run_sweep "$case_dir" FM_TEST_GH_REPLY="$case_dir/reply" FM_PR_RECONCILE_MAX=1 --force > /dev/null
  run_sweep "$case_dir" FM_TEST_GH_REPLY="$case_dir/reply" FM_PR_RECONCILE_MAX=1 --force > /dev/null
  assert_grep "number: 81" "$case_dir/gh.log" "first capped sweep queries the first PR"
  assert_grep "number: 82" "$case_dir/gh.log" "second capped sweep rotates to the second PR"
  pass "per-sweep cap rotates instead of starving the tail"
}

test_merged_pr_queues_wake
test_closed_pr_queues_wake
test_open_pr_stays_silent
test_terminal_pr_not_requeried
test_offline_failure_one_diagnostic
test_malformed_urls_skipped
test_sources_and_batching
test_throttle
test_seen_cache_pruned
test_watcher_wiring
test_bootstrap_wiring
test_cap_rotation

echo "all fm-pr-reconcile tests passed"
