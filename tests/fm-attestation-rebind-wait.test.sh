#!/usr/bin/env bash
# Behavior tests for bin/fm-attestation-rebind-wait.sh, the bounded wait that
# lets the Require no-mistakes workflow re-judge a rebound live PR body.
# The script is executed for real against a stubbed `gh` and `sleep`, and the
# assertions cover its observable contract: exit codes, the GITHUB_OUTPUT
# step-output file the workflow consumes, and the operator-facing messages.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/fm-attestation-rebind-wait.sh"
TMP_ROOT=$(fm_test_tmproot fm-attestation-rebind-wait)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

EVENT_SHA=2222222222222222222222222222222222222222
OLD_SHA=1111111111111111111111111111111111111111
NEWER_SHA=3333333333333333333333333333333333333333

command -v jq >/dev/null 2>&1 || fail "jq is required to exercise the rebind-wait helper"

# The gh stub serves one canned response file per call, indexed by a counter.
# A response file whose first line is FAIL makes that call exit non-zero, so a
# transient API error is representable. Argument lines are logged for asserts.
cat >"$FAKEBIN/gh" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$GH_ARG_LOG"
count=$(cat "$GH_COUNT")
count=$((count + 1))
printf '%s\n' "$count" >"$GH_COUNT"
resp="$GH_RESPONSE_DIR/resp.$count"
[ -f "$resp" ] || resp="$GH_RESPONSE_DIR/resp.last"
if [ "$(head -n 1 "$resp")" = "FAIL" ]; then
  echo "stubbed gh outage" >&2
  exit 1
fi
cat "$resp"
STUB
chmod 755 "$FAKEBIN/gh"

# The sleep stub records the requested interval and returns immediately so the
# polling loop is fully deterministic and the suite never waits in real time.
cat >"$FAKEBIN/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$SLEEP_LOG"
exit 0
STUB
chmod 755 "$FAKEBIN/sleep"

# make_response <file> <head-sha> <attested-sha-or-empty>: a live PR JSON whose
# multiline body carries the signature line and, when requested, an attestation
# comment bound to the given SHA.
make_response() {
  local file=$1 head=$2 attested=$3 body
  body='## Intent

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
  if [ -n "$attested" ]; then
    body="$body
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$attested\",\"steps\":[{\"step\":\"review\",\"status\":\"completed\"}]} -->"
  fi
  body="$body

trailing section after the attestation"
  jq -n --arg sha "$head" --arg body "$body" '{head: {sha: $sha}, body: $body}' >"$file"
}

# run_wait <attempts>: run the real helper against the stub environment.
run_wait() {
  local attempts=$1
  printf '0\n' >"$TMP_ROOT/gh.count"
  : >"$TMP_ROOT/gh.args"
  : >"$TMP_ROOT/sleep.log"
  : >"$TMP_ROOT/github.out"
  PATH="$FAKEBIN:$PATH" \
    GH_COUNT="$TMP_ROOT/gh.count" \
    GH_ARG_LOG="$TMP_ROOT/gh.args" \
    GH_RESPONSE_DIR="$TMP_ROOT/responses" \
    SLEEP_LOG="$TMP_ROOT/sleep.log" \
    GITHUB_REPOSITORY=example/firstmate \
    PR_NUMBER=12 \
    EVENT_HEAD_SHA="$EVENT_SHA" \
    GITHUB_OUTPUT="$TMP_ROOT/github.out" \
    FM_REBIND_WAIT_ATTEMPTS="$attempts" \
    FM_REBIND_WAIT_INTERVAL_SECONDS=7 \
    bash "$SCRIPT" 2>&1
}

reset_responses() {
  rm -rf "$TMP_ROOT/responses"
  mkdir -p "$TMP_ROOT/responses"
}

test_rebind_lands_and_live_facts_are_exported() {
  local output rc delim exported expected
  reset_responses
  make_response "$TMP_ROOT/responses/resp.1" "$EVENT_SHA" "$OLD_SHA"
  make_response "$TMP_ROOT/responses/resp.2" "$EVENT_SHA" "$EVENT_SHA"
  rc=0
  output=$(run_wait 5) || rc=$?
  expect_code 0 "$rc" "helper did not succeed once the live attestation bound the event head"
  assert_contains "$output" "exporting live PR facts" \
    "helper did not report that the rebind landed"
  assert_grep "head-sha=$EVENT_SHA" "$TMP_ROOT/github.out" \
    "GITHUB_OUTPUT is missing the live head-sha output"
  delim=$(sed -n 's/^body<<//p' "$TMP_ROOT/github.out")
  [ -n "$delim" ] || fail "GITHUB_OUTPUT is missing the multiline body output"
  exported=$(sed -n "/^body<<$delim\$/,/^$delim\$/p" "$TMP_ROOT/github.out" | sed '1d;$d')
  expected=$(jq -r '.body' "$TMP_ROOT/responses/resp.2")
  [ "$exported" = "$expected" ] || fail "exported body does not match the live PR body byte for byte"
  expect_code 1 "$(wc -l <"$TMP_ROOT/sleep.log" | tr -d ' ')" \
    "helper should sleep exactly once before the second poll"
  assert_grep "7" "$TMP_ROOT/sleep.log" "helper did not honor the configured poll interval"
  pass "stale body heals in place once the gate rebinds, exporting the live facts"
}

test_superseded_head_fails_fast() {
  local output rc
  reset_responses
  make_response "$TMP_ROOT/responses/resp.1" "$NEWER_SHA" "$NEWER_SHA"
  rc=0
  output=$(run_wait 5) || rc=$?
  [ "$rc" -ne 0 ] || fail "helper accepted an event superseded by a newer push"
  assert_contains "$output" "$EVENT_SHA" "superseded failure did not name the event head"
  assert_contains "$output" "$NEWER_SHA" "superseded failure did not name the live head"
  expect_code 1 "$(cat "$TMP_ROOT/gh.count")" "helper should stop polling after seeing a newer head"
  assert_no_grep "head-sha=" "$TMP_ROOT/github.out" "superseded run must not export live facts"
  pass "a newer push fails the run fast and defers to that push's own compliance run"
}

test_timeout_reports_recovery_guidance() {
  local output rc
  reset_responses
  make_response "$TMP_ROOT/responses/resp.last" "$EVENT_SHA" "$OLD_SHA"
  rc=0
  output=$(run_wait 3) || rc=$?
  [ "$rc" -ne 0 ] || fail "helper succeeded although the attestation never rebound"
  expect_code 3 "$(cat "$TMP_ROOT/gh.count")" "helper did not poll once per configured attempt"
  assert_contains "$output" "re-run this failed job" \
    "timeout message did not tell the operator that a re-run re-judges the live body"
  assert_contains "$output" "no-mistakes rerun" \
    "timeout message did not point at the gate rerun recovery"
  assert_contains "$output" "v1.60.2" \
    "timeout message did not name the minimum gate version that restamps CI-repair pushes"
  assert_no_grep "head-sha=" "$TMP_ROOT/github.out" "timed-out run must not export live facts"
  pass "an unrebound attestation times out with the documented recovery guidance"
}

test_transient_api_failure_is_retried() {
  local output rc
  reset_responses
  printf 'FAIL\n' >"$TMP_ROOT/responses/resp.1"
  make_response "$TMP_ROOT/responses/resp.2" "$EVENT_SHA" "$EVENT_SHA"
  rc=0
  output=$(run_wait 5) || rc=$?
  expect_code 0 "$rc" "helper did not survive a transient API failure before the rebind"
  assert_contains "$output" "retrying" \
    "helper did not report the transient API failure it retried past"
  assert_grep "head-sha=$EVENT_SHA" "$TMP_ROOT/github.out" \
    "live facts were not exported after retrying past the API failure"
  pass "a transient API failure is retried instead of failing the run"
}

test_malformed_attestation_keeps_waiting() {
  local output rc
  reset_responses
  jq -n --arg sha "$EVENT_SHA" \
    '{head: {sha: $sha}, body: "<!-- no-mistakes-pipeline-attestation:v1 {not json} -->"}' \
    >"$TMP_ROOT/responses/resp.last"
  rc=0
  output=$(run_wait 2) || rc=$?
  [ "$rc" -ne 0 ] || fail "helper treated a malformed attestation as a rebind"
  assert_contains "$output" "waiting for the gate to rebind" \
    "helper did not keep waiting on the malformed attestation"
  expect_code 2 "$(cat "$TMP_ROOT/gh.count")" "helper should keep polling past a malformed attestation"
  pass "a malformed attestation is treated as not yet rebound, never as a pass"
}

test_rebind_lands_and_live_facts_are_exported
test_superseded_head_fails_fast
test_timeout_reports_recovery_guidance
test_transient_api_failure_is_retried
test_malformed_attestation_keeps_waiting
