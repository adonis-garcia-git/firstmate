#!/usr/bin/env bash
# tests/fm-login-check.test.sh - bin/fm-login-check.sh asks for every login
# today's work needs in one line, checks only logins that work needs, and never
# reports an unconfirmed check as signed in. Worker-account checks run against
# a fake claude so no real login is probed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-login-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-login-check)
fm_test_need_tool tasks-axi || exit 0

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  # A codex crew keeps the built-in Claude check off unless a case pins it.
  printf '%s\n' codex > "$home/config/crew-harness"
  fm_fakebin "$home" >/dev/null
  printf '%s\n' "$home"
}

run_check() {  # <home>
  PATH="$1/fakebin:$PATH" FM_LOGIN_CHECK=on FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CONFIG_OVERRIDE="$1/config" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    "$CHECK"
}

test_only_todays_logins_are_checked_and_asked_in_one_line() {
  local home out
  home=$(make_home todays-work)
  printf 'window=test:fm-live\nkind=ship\nproject=%s/projects/live-app\n' "$home" > "$home/state/live.meta"
  printf 'window=test:fm-mate\nkind=secondmate\nproject=%s/projects/mate-app\n' "$home" > "$home/state/mate.meta"
  (cd "$home" && tasks-axi add flying "Flying work" --repo flying-app --start >/dev/null \
    && tasks-axi add ready-row "Ready work" --repo ready-app >/dev/null \
    && tasks-axi add parked-row "Parked work" --repo parked-app >/dev/null \
    && tasks-axi hold parked-row --reason "parked" --kind parked >/dev/null) \
    || fail "could not seed the backlog fixture"
  cat > "$home/config/logins" <<EOF
# name | projects | check | how to sign in
cloud | live-app | false | cloud login
store | flying-app,other | exit 3 | store login
queue | ready-app | printf ready | grep -q nope | queue login
always | * | false | always login
fine | live-app | true | never shown
parked | parked-app | touch "$home/parked-ran" | parked login
mate | mate-app | touch "$home/mate-ran" | mate login
idle | idle-app | touch "$home/idle-ran" | idle login
broken line without separators
EOF

  out=$(run_check "$home") || fail "the login probe failed"
  [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] || fail "missing logins were not asked in one line: $out"
  assert_contains "$out" "NEEDS_LOGIN: cloud (for live-app; sign in: cloud login)" \
    "a live task's login was not asked for"
  assert_contains "$out" "store (for flying-app; sign in: store login)" \
    "an in-flight row's login was not asked for"
  assert_contains "$out" "queue (for ready-app; sign in: queue login)" \
    "a dispatch-ready row's login, checked through a pipe, was not asked for"
  assert_contains "$out" "always (for all work; sign in: always login)" "an always-needed login was skipped"
  assert_contains "$out" "config/logins line 10 (malformed" "a malformed line was silently skipped"
  assert_not_contains "$out" "fine" "a signed-in login was reported"
  assert_absent "$home/parked-ran" "a login for held work nobody will start today was checked"
  assert_absent "$home/mate-ran" "an idle secondmate counted as today's work"
  assert_absent "$home/idle-ran" "a login for a project with no work today was checked"

  out=$(PATH="$home/fakebin:$PATH" FM_LOGIN_CHECK=off FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$CHECK")
  assert_equals "$out" "" "FM_LOGIN_CHECK=off still probed logins"
  pass "only today's work's logins are checked, and every missing one is asked for in one line"
}

test_timeouts_are_unconfirmed_not_signed_in() {
  local home out
  home=$(make_home timeout)
  printf '%s\n' 'slow | * | sleep 5 | slow login' > "$home/config/logins"
  out=$(FM_LOGIN_CHECK_SECONDS=1 run_check "$home") || fail "the login probe failed on a slow check"
  assert_contains "$out" "NEEDS_LOGIN: slow (for all work; check timed out after 1s; sign in: slow login)" \
    "a check that timed out was treated as signed in"
  printf '%s\n' 'quick | * | true | quick login' > "$home/config/logins"
  out=$(run_check "$home") || fail "the login probe failed"
  assert_equals "$out" "" "a home with every login signed in was not silent"
  pass "a check that times out is reported as unconfirmed, and all-signed-in is silent"
}

test_claude_worker_account_is_checked() {
  local home out pin
  home=$(make_home claude-worker)
  pin="$home/claude-worker-root"
  mkdir -p "$pin"
  cat > "$home/fakebin/claude" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "auth status" ] || exit 64
[ -e "${CLAUDE_CONFIG_DIR:-/nonexistent}/signed-in" ]
SH
  chmod +x "$home/fakebin/claude"
  printf '%s\n' "$pin" > "$home/config/claude-account"
  out=$(run_check "$home") || fail "the login probe failed with a Claude pin"
  assert_equals "$out" "NEEDS_LOGIN: Claude worker account $pin (sign in: CLAUDE_CONFIG_DIR=$pin claude, then /login)" \
    "a signed-out pinned Claude worker account was not asked for"
  : > "$pin/signed-in"
  out=$(run_check "$home") || fail "the login probe failed with a signed-in pin"
  assert_equals "$out" "" "a signed-in pinned Claude worker account was reported"
  printf 'not an absolute path\n' > "$home/config/claude-account"
  out=$(run_check "$home") || fail "the login probe failed with an invalid pin"
  assert_contains "$out" "Claude worker account (config/claude-account is invalid" "an invalid pin was not reported"
  pass "the Claude worker account is checked exactly as a spawn would check it"
}

test_unpinned_claude_worker_uses_the_inherited_environment() {
  local home out
  home=$(make_home claude-unpinned)
  printf '%s\n' claude > "$home/config/crew-harness"
  cat > "$home/fakebin/claude" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "auth status" ] || exit 64
[ -n "${ANTHROPIC_API_KEY:-}" ]
SH
  chmod +x "$home/fakebin/claude"
  out=$(ANTHROPIC_API_KEY=test-key run_check "$home") || fail "the login probe failed with an API-key worker"
  assert_equals "$out" "" "an unpinned worker signed in through the inherited environment was reported"
  out=$(env -u ANTHROPIC_API_KEY PATH="$home/fakebin:$PATH" FM_LOGIN_CHECK=on FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$CHECK") || fail "the login probe failed with a signed-out worker"
  assert_equals "$out" "NEEDS_LOGIN: Claude worker account (sign in: env -u CLAUDE_CONFIG_DIR claude, then /login)" \
    "a signed-out unpinned Claude worker account was not asked for"
  printf '%s\n' "$home/claude-pin" > "$home/config/claude-account"
  mkdir -p "$home/claude-pin"
  out=$(ANTHROPIC_API_KEY=test-key run_check "$home") || fail "the login probe failed with a Claude pin"
  assert_contains "$out" "NEEDS_LOGIN: Claude worker account $home/claude-pin" \
    "a pinned account was credited with the session's environment a pinned spawn drops"
  pass "an unpinned Claude worker is checked with the environment it inherits, a pinned one without it"
}

test_only_todays_logins_are_checked_and_asked_in_one_line
test_timeouts_are_unconfirmed_not_signed_in
test_claude_worker_account_is_checked
test_unpinned_claude_worker_uses_the_inherited_environment
