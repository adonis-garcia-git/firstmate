#!/usr/bin/env bash
# Behavior tests for the semantic busy-state contract (bin/fm-busy-lib.sh and
# its only writer bin/fm-busy-event.sh).
#
# Covers the captain-approved redesign invariants: busy/idle/unknown/dead with
# explicit source attribution; missing, malformed, stale (gen-mismatch), and
# untrusted (source-mismatch) semantic data classify unknown - never idle;
# adapter isolation (one adapter's writer or Grok's regex can never classify
# another adapter); endpoint death is the only process-level override and
# yields dead, never busy; converted adapters never classify from rendered
# footer text. All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-busy-state)
EV="$ROOT/bin/fm-busy-event.sh"

new_state_dir() {  # <name>
  local d="$TMP_ROOT/$1/state"
  mkdir -p "$d"
  printf '%s' "$d"
}

# --- writer: arm and apply ---------------------------------------------------

test_arm_seeds_busy_spawn() {
  local state gen out
  state=$(new_state_dir arm-seed)
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  [ -f "$state/t1.busy-gen" ] || fail "arm did not write the gen sidecar"
  [ "$(cat "$state/t1.busy-gen")" = "$gen" ] || fail "sidecar gen does not match printed gen"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed should classify 'busy fm-spawn', got '$out'"
  pass "arm mints a gen sidecar and seeds busy fm-spawn at seq=1"
}

test_apply_advances_seq_and_source() {
  local state gen out seq
  state=$(new_state_dir apply-seq)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "apply idle failed"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "idle claude-hook" ] || fail "expected 'idle claude-hook', got '$out'"
  "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || fail "apply busy failed"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy claude-hook" ] || fail "expected 'busy claude-hook', got '$out'"
  seq=$(fm_busy_record_read "$state" t1 | awk '{print $4}')
  [ "$seq" = 3 ] || fail "expected seq 3 after seed + two applies, got '$seq'"
  pass "apply advances seq under the armed gen and attributes the writing source"
}

test_apply_current_gen_reset() {
  local state out
  state=$(new_state_dir apply-current)
  "$EV" arm "$state" t1 >/dev/null
  "$EV" apply "$state" t1 idle --current-gen --source fm-interrupt --event interrupt \
    || fail "apply --current-gen failed"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "idle fm-interrupt" ] || fail "expected 'idle fm-interrupt', got '$out'"
  "$EV" apply "$state" t1 unknown --current-gen --source fm-recovery --event relaunch \
    || fail "apply unknown failed"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "unknown fm-recovery" ] || fail "expected 'unknown fm-recovery', got '$out'"
  pass "firstmate-owned interrupt and recovery events bind to the current gen"
}

test_apply_unarmed_refused() {
  local state
  state=$(new_state_dir apply-unarmed)
  if "$EV" apply "$state" t1 busy --gen g1.2.3 --source claude-hook --event x 2>/dev/null; then
    fail "apply against an unarmed task must be refused"
  fi
  [ ! -f "$state/t1.busy-state" ] || fail "refused apply must not write a record"
  pass "apply is refused for a task whose busy contract was never armed"
}

# --- stale event rejection ----------------------------------------------------

test_stale_gen_event_rejected() {
  local state old_gen new_gen out
  state=$(new_state_dir stale-event)
  old_gen=$("$EV" arm "$state" t1)
  new_gen=$("$EV" arm "$state" t1)
  [ "$old_gen" != "$new_gen" ] || fail "re-arm must mint a fresh gen"
  if "$EV" apply "$state" t1 idle --gen "$old_gen" --source claude-hook --event stop 2>/dev/null; then
    fail "an event carrying a stale gen must be rejected"
  fi
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "stale event must not change the record, got '$out'"
  pass "a late event from a previous incarnation is rejected, record unchanged"
}

test_stale_gen_record_unknown() {
  local state gen out
  state=$(new_state_dir stale-record)
  gen=$("$EV" arm "$state" t1)
  # Simulate a record left behind by a superseded incarnation.
  printf 'g-superseded.1.1\n' > "$state/t1.busy-gen.new"
  mv "$state/t1.busy-gen.new" "$state/t1.busy-gen"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown gen-mismatch" ] || fail "stale record must classify 'unknown gen-mismatch', got '$out'"
  pass "a record from a stale incarnation classifies unknown, never idle"
}

# --- missing and malformed semantic data --------------------------------------

test_missing_record_unknown_not_idle() {
  local state out h
  state=$(new_state_dir missing)
  for h in claude opencode pi pi-signed; do
    out=$(fm_busy_classify tmux w1 "$h" t1 "$state")
    [ "$out" = "unknown missing" ] || fail "$h with no record must be 'unknown missing', got '$out'"
  done
  out=$(fm_busy_classify tmux w1 codex t1 "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "codex with no verified source must be 'unknown codex-unverified', got '$out'"
  pass "a converted adapter with no record classifies unknown, never idle"
}

test_malformed_record_unknown() {
  local state gen out
  state=$(new_state_dir malformed)
  gen=$("$EV" arm "$state" t1)
  for bad in \
    'garbage' \
    "v0 gen=$gen seq=1 state=busy source=claude-hook event=x ts=1" \
    "v1 gen=$gen seq=NaN state=busy source=claude-hook event=x ts=1" \
    "v1 gen=$gen seq=1 state=frobbing source=claude-hook event=x ts=1" \
    "v1 gen=$gen seq=1 state=busy source=bad source event=x ts=1" \
    "v1 gen=$gen seq=1 state=busy source=claude-hook event=x ts=1 rogue=1"; do
    printf '%s\n' "$bad" > "$state/t1.busy-state"
    out=$(fm_busy_classify tmux w1 claude t1 "$state")
    [ "$out" = "unknown malformed" ] || fail "malformed record '$bad' must be 'unknown malformed', got '$out'"
  done
  printf 'v1 gen=%s seq=1 state=busy source=claude-hook event=x ts=1\nsecond line\n' "$gen" > "$state/t1.busy-state"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "multi-line record must be 'unknown malformed', got '$out'"
  pass "malformed records classify unknown malformed, never busy or idle"
}

test_record_without_sidecar_unknown() {
  local state out
  state=$(new_state_dir orphan-record)
  printf 'v1 gen=g1.1.1 seq=1 state=busy source=claude-hook event=x ts=1\n' > "$state/t1.busy-state"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "record without an armed gen must be unknown, got '$out'"
  pass "a record with no armed gen sidecar classifies unknown"
}

# --- adapter isolation ---------------------------------------------------------

test_source_mismatch_cross_adapter() {
  local state gen out
  state=$(new_state_dir cross-adapter)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source pi-ext --event agent-start
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown source-mismatch" ] || fail "pi-ext record on a claude task must be untrusted, got '$out'"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "busy pi-ext" ] || fail "pi-ext record on a pi task must classify, got '$out'"
  out=$(fm_busy_classify tmux w1 grok t1 "$state")
  [ "$out" = "unknown source-mismatch" ] || fail "grok trusts no semantic source, got '$out'"
  pass "a record is trusted only by the adapter whose source wrote it"
}

test_converted_adapters_ignore_footer_text() {
  local state out h
  state=$(new_state_dir no-footer)
  local tail='• Working (6s • esc to interrupt)
   ■■■■⬝⬝⬝⬝  esc interrupt
Working...
Ctrl+c:cancel'
  for h in claude opencode pi pi-signed; do
    out=$(fm_busy_classify tmux w1 "$h" t1 "$state" "$tail")
    [ "$out" = "unknown missing" ] || fail "$h must never classify from footer text, got '$out'"
  done
  out=$(fm_busy_classify tmux w1 codex t1 "$state" "$tail")
  [ "$out" = "unknown codex-unverified" ] || fail "codex must never classify from footer text, got '$out'"
  pass "converted adapters never classify busy from rendered footer text"
}

test_grok_regex_isolated() {
  local state out
  state=$(new_state_dir grok-arm)
  out=$(fm_busy_classify tmux w1 grok t1 "$state" 'thinking hard
Ctrl+c:cancel')
  [ "$out" = "busy grok-regex" ] || fail "grok busy tail must classify 'busy grok-regex', got '$out'"
  out=$(fm_busy_classify tmux w1 grok t1 "$state" 'done.
> ')
  [ "$out" = "idle grok-regex" ] || fail "grok idle tail must classify 'idle grok-regex', got '$out'"
  # Another adapter's footer never makes grok busy either.
  out=$(fm_busy_classify tmux w1 grok t1 "$state" '• Working (6s • esc to interrupt)')
  [ "$out" = "idle grok-regex" ] || fail "a claude footer must not classify grok busy, got '$out'"
  pass "the grok fallback is regex-scoped to grok and classifies only grok tasks"
}

# --- kimi verification gate -----------------------------------------------------

test_codex_unverified_gate() {
  local state gen out
  state=$(new_state_dir codex-gate)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source codex-hook --event user-prompt-submit
  out=$(fm_busy_classify tmux w1 codex t1 "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "unverified codex must classify unknown, got '$out'"
  [ -z "$(fm_busy_sources_for_harness codex)" ] \
    || fail "codex must trust no semantic source until one is verified"
  pass "codex classifies unknown until a semantic source passes its verification gate"
}

test_kimi_unverified_gate() {
  local state gen out
  state=$(new_state_dir kimi-gate)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source kimi-hook --event user-prompt-submit
  out=$(fm_busy_classify tmux w1 kimi t1 "$state")
  [ "$out" = "unknown kimi-unverified" ] || fail "unverified kimi must classify unknown, got '$out'"
  out=$(fm_busy_classify tmux w1 kimi t1 "$state" '🌒 · thinking')
  [ "$out" = "unknown kimi-unverified" ] || fail "kimi must not classify from footer text, got '$out'"
  pass "standalone kimi classifies unknown until the live verification gate opens"
}

# --- endpoint death and native fallbacks ----------------------------------------

test_dead_endpoint_overrides() {
  local state gen out
  state=$(new_state_dir dead)
  gen=$("$EV" arm "$state" t1)
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_live
  fm_backend_target_exists() { return 1; }
  out=$(fm_busy_classify_live tmux w1 claude t1 "$state")
  [ "$out" = "dead endpoint-gone" ] || fail "gone endpoint must classify dead, got '$out'"
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_live
  fm_backend_target_exists() { return 0; }
  out=$(fm_busy_classify_live tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "live endpoint must fall through to the record, got '$out'"
  out=$(fm_busy_classify_live tmux '' claude t1 "$state")
  [ "$out" = "unknown no-target" ] || fail "empty target must classify unknown, got '$out'"
  unset -f fm_backend_target_exists
  pass "endpoint death is the only process-level override and yields dead, never busy"
}

test_herdr_native_busy_only() {
  local state out
  state=$(new_state_dir herdr-native)
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
  fm_backend_busy_state() { printf '%s' "$FAKE_NATIVE"; }
  FAKE_NATIVE=busy
  out=$(fm_busy_classify herdr s:p claude t1 "$state")
  [ "$out" = "busy herdr-native" ] || fail "native busy with no record must classify busy, got '$out'"
  FAKE_NATIVE=idle
  out=$(fm_busy_classify herdr s:p claude t1 "$state")
  [ "$out" = "unknown missing" ] || fail "native idle must NOT classify idle, got '$out'"
  # A valid record outranks the native verdict.
  local gen
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop
  FAKE_NATIVE=busy
  out=$(fm_busy_classify herdr s:p claude t1 "$state")
  [ "$out" = "idle claude-hook" ] || fail "the adapter record must outrank herdr's native verdict, got '$out'"
  unset -f fm_backend_busy_state
  pass "herdr's native verdict is trusted for busy only, and records outrank it"
}

test_boolean_view_never_promotes_unknown() {
  local state gen
  state=$(new_state_dir boolean)
  gen=$("$EV" arm "$state" t1)
  fm_busy_is_busy tmux w1 claude t1 "$state" || fail "busy record must read busy"
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop
  if fm_busy_is_busy tmux w1 claude t1 "$state"; then
    fail "idle record must not read busy"
  fi
  printf 'garbage\n' > "$state/t1.busy-state"
  if fm_busy_is_busy tmux w1 claude t1 "$state"; then
    fail "malformed record must not read busy"
  fi
  pass "the boolean view reports busy only on an exact busy verdict"
}

test_arm_seeds_busy_spawn
test_apply_advances_seq_and_source
test_apply_current_gen_reset
test_apply_unarmed_refused
test_stale_gen_event_rejected
test_stale_gen_record_unknown
test_missing_record_unknown_not_idle
test_malformed_record_unknown
test_record_without_sidecar_unknown
test_source_mismatch_cross_adapter
test_converted_adapters_ignore_footer_text
test_grok_regex_isolated
test_codex_unverified_gate
test_kimi_unverified_gate
test_dead_endpoint_overrides
test_herdr_native_busy_only
test_boolean_view_never_promotes_unknown

echo "all fm-busy-state tests passed"
