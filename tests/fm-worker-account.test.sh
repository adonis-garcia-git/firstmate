#!/usr/bin/env bash
# Behavior tests for the opt-in per-home worker account pin
# (config/claude-account, config/pi-account; bin/fm-worker-account-lib.sh).
#
# Each case drives the real fm-spawn.sh through the shared fake tmux, which
# records the launch command, then runs that command in a synthetic pane whose
# ambient environment carries a different account. The fake claude and pi
# answer the sign-in checks the way the real runners do - an environment
# credential counts as signed in, otherwise the selected root's stored login
# decides - and record the account environment and arguments a launched worker
# receives. The shared fake quota-axi answers each Claude root's quota read in
# the real tool's shape and logs which root it was asked about.
# tests/fm-worker-account-live-e2e.test.sh proves those answers against the
# real runners and quota-axi.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-account)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN PI_CODING_AGENT_DIR OPENAI_API_KEY

# make_account_fakes <fakebin> <case-dir>
# The fakes cannot read test variables during a sign-in check, which runs with
# a cleared environment, so their log paths are written into them here.
make_account_fakes() {
  local fakebin=$1 dir=$2
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  printf '%s\n' "\${CLAUDE_CONFIG_DIR-unset}" >> '$dir/claude-checks'
  [ -z "\${ANTHROPIC_API_KEY:-}\${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || exit 0
  [ -f "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.credentials.json" ]
  exit
fi
{
  printf 'CLAUDE_CONFIG_DIR=%s\n' "\${CLAUDE_CONFIG_DIR-unset}"
  printf 'ANTHROPIC_API_KEY=%s\n' "\${ANTHROPIC_API_KEY-unset}"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "\${CLAUDE_CODE_OAUTH_TOKEN-unset}"
  printf 'CLAUDE_CODE_USE_BEDROCK=%s\n' "\${CLAUDE_CODE_USE_BEDROCK-unset}"
} > '$dir/claude-worker'
SH
  cat > "$fakebin/pi" <<SH
#!/usr/bin/env bash
root=\${PI_CODING_AGENT_DIR:-\$HOME/.pi/agent}
case "\${1:-}" in
  --help) printf '%s\n' 'Pi 0.86.1' 'Options: --help --tui-mode <mode>'; exit 0 ;;
  auth)
    provider=\$4
    printf '%s %s\n' "\${PI_CODING_AGENT_DIR-unset}" "\$provider" >> '$dir/pi-checks'
    if [ -f "\$root/old-pi" ]; then echo "Unknown command: auth" >&2; exit 1; fi
    if [ -n "\${OPENAI_API_KEY:-}" ] || grep -qx "\$provider" "\$root/signed-in" 2>/dev/null; then
      printf '{"status":"ready","provider":"%s","authType":"oauth"}\n' "\$provider"
      exit 0
    fi
    if grep -qx "\$provider" "\$root/extension-providers" 2>/dev/null; then
      printf '{"status":"not_ready","provider":"%s","reason":"provider_not_found"}\n' "\$provider"
      exit 1
    fi
    printf '{"status":"not_ready","provider":"%s","reason":"credentials_not_configured"}\n' "\$provider"
    exit 1
    ;;
  --list-models)
    printf 'provider  model  context\n'
    [ ! -f "\$root/listed" ] || cat "\$root/listed"
    exit 0
    ;;
esac
{
  printf 'PI_CODING_AGENT_DIR=%s\n' "\${PI_CODING_AGENT_DIR-unset}"
  printf 'ARGS=%s\n' "\$*"
} > '$dir/pi-worker'
SH
  chmod +x "$fakebin/claude" "$fakebin/pi"
}

# new_case <name> <crew-harness> -> sets CASE HOME_DIR PROJ WT FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  make_account_fakes "$FAKEBIN" "$CASE"
  fm_test_fake_quota_axi "$FAKEBIN" "$CASE/quota-reads"
  fm_test_spawn_home "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$HOME_DIR/user-home"
  : > "$CASE/launch.log"
}

# signed_in_claude_root <dir>: a Claude config root holding a stored login.
signed_in_claude_root() {
  mkdir -p "$1"
  printf '{}\n' > "$1/.credentials.json"
}

# spawn_ship <id> [fm-spawn args...]: a ship spawn from HOME_DIR whose invoking
# process carries an ambient signed-in Claude root and an ambient API key.
spawn_ship() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  # Every spawn in a case reuses the one fake pool slot, so retire earlier
  # tasks' records as their cleanup would; one live record owns a slot.
  rm -f "$HOME_DIR/state/"*.meta
  signed_in_claude_root "$CASE/ambient-claude"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    ANTHROPIC_API_KEY=ambient-invoker-key \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

# run_pane: execute the recorded launch in a pane whose ambient environment
# names another account for every runner.
run_pane() {
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" TERM=xterm \
    CLAUDE_CONFIG_DIR="$CASE/ambient-claude" ANTHROPIC_API_KEY=ambient-pane-key \
    CLAUDE_CODE_OAUTH_TOKEN=ambient-pane-token CLAUDE_CODE_USE_BEDROCK=1 \
    PI_CODING_AGENT_DIR="$CASE/ambient-pi" OPENAI_API_KEY=ambient-pane-openai \
    bash -c "$(cat "$CASE/launch.log")" || fail "the recorded launch failed in the synthetic pane"
}

# named_accounts <line...>: config/claude-account in the named form.
named_accounts() {
  printf '%s\n' '# name | root | weight' "$@" > "$HOME_DIR/config/claude-account"
}

# quota_reading <root> <reading>: what the fake quota-axi reports for a root
# (tests/fixtures.sh fm_test_fake_quota_axi owns the reading format).
quota_reading() {
  mkdir -p "$1"
  printf '%s\n' "$2" > "$1/quota-reading"
}

# assert_refused_before_launch <id> <out> <needle>
assert_refused_before_launch() {
  local id=$1 out=$2 needle=$3
  assert_contains "$out" "$needle" "the refusal should say: $needle"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
}

test_absent_pin_keeps_the_launch_unchanged() {
  local out rc id=acct-absent
  new_case absent claude
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "an unpinned Claude spawn should succeed: $out"
  assert_not_contains "$out" "account=" "an unpinned spawn must not report an account"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" "an unpinned task record must not carry an account"
  assert_absent "$CASE/claude-checks" "an unpinned spawn must not run a sign-in check"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/ambient-claude" "$CASE/claude-worker" \
    "an unpinned launch must keep forwarding the invoking process's own Claude root"
  assert_grep "ANTHROPIC_API_KEY=ambient-pane-key" "$CASE/claude-worker" \
    "an unpinned launch must leave the pane's environment credentials alone"

  new_case absent-pi pi
  out=$(spawn_ship acct-absent-pi --model gpt-5.5); rc=$?
  expect_code 0 "$rc" "an unpinned Pi spawn with an unqualified model should succeed: $out"
  assert_not_contains "$(cat "$CASE/launch.log")" "--provider" "an unpinned Pi launch must not add a provider"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/ambient-pi" "$CASE/pi-worker" \
    "an unpinned Pi launch must keep the pane's own Pi root"
  pass "an absent pin leaves Claude and Pi launches exactly as they were"
}

test_claude_pin_selects_the_root_and_sheds_ambient_credentials() {
  local out rc id=acct-claude
  new_case claude-pin claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a Claude spawn pinned to a signed-in root should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "the spawn should report the pinned account"
  assert_grep "account=$CASE/work" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned account"
  [ "$(cat "$CASE/claude-checks")" = "$CASE/work" ] \
    || fail "the sign-in check should ask about the pinned root only: $(cat "$CASE/claude-checks")"
  assert_contains "$(cat "$CASE/work/.claude.json" 2>/dev/null)" "$WT" \
    "workspace trust should be registered in the pinned root's store"
  assert_absent "$CASE/ambient-claude/.claude.json" "the ambient Claude store must not receive the trust entry"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" "the worker should run under the pinned root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the pin"
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=unset" "$CASE/claude-worker" "an ambient OAuth token must not outrank the pin"
  assert_grep "CLAUDE_CODE_USE_BEDROCK=unset" "$CASE/claude-worker" "an ambient cloud-provider switch must not outrank the pin"
  pass "a Claude pin selects its root and sheds the credentials that would outrank it"
}

test_claude_pin_refuses_a_signed_out_root_despite_an_ambient_login() {
  local out rc id=acct-claude-out
  new_case claude-signed-out claude
  mkdir -p "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "a Claude pin to a signed-out root must refuse"
  assert_refused_before_launch "$id" "$out" "config/claude-account pins Claude workers to $CASE/work, which is not signed in"
  assert_absent "$CASE/work/.claude.json" "a refused spawn must not register trust in the pinned root"
  pass "a Claude pin refuses a signed-out root even when the invoking process has a usable login and API key"
}

test_claude_ordinary_pin_unsets_the_config_root() {
  local out rc id=acct-ordinary
  new_case ordinary claude
  printf 'ordinary' > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "an ordinary pin with no default login must refuse"
  assert_refused_before_launch "$id" "$out" "pins Claude workers to the ordinary account, which is not signed in"
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  : > "$CASE/claude-checks"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "an ordinary pin with a default login should succeed: $out"
  assert_contains "$out" "account=ordinary" "the spawn should report the ordinary account"
  [ "$(cat "$CASE/claude-checks")" = unset ] \
    || fail "the ordinary check must run with CLAUDE_CONFIG_DIR unset: $(cat "$CASE/claude-checks")"
  assert_contains "$(cat "$HOME_DIR/user-home/.claude.json" 2>/dev/null)" "$WT" \
    "ordinary trust should land in the default ~/.claude.json store"
  assert_absent "$CASE/ambient-claude/.claude.json" "the ambient Claude store must not receive the trust entry"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" \
    "the ordinary account must drop an ambient CLAUDE_CONFIG_DIR"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the ordinary pin"
  pass "an ordinary Claude pin selects the default login and drops an ambient root"
}

test_malformed_pins_refuse_before_launch() {
  local out rc id=acct-bad n=0 body
  new_case malformed claude
  mkdir -p "$CASE/work"
  for body in 'relative/root' "$CASE/work"$'\r' '' 'ordinary'$'\n''environment' "$CASE/missing-root"; do
    n=$((n + 1))
    printf '%s' "$body" > "$HOME_DIR/config/claude-account"
    out=$(spawn_ship "$id-$n"); rc=$?
    expect_code 1 "$rc" "malformed pin #$n must refuse"
    assert_refused_before_launch "$id-$n" "$out" "config/claude-account"
  done
  rm "$HOME_DIR/config/claude-account"
  mkdir "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-dir"); rc=$?
  expect_code 1 "$rc" "a directory in place of the pin must refuse"
  assert_refused_before_launch "$id-dir" "$out" "config/claude-account must be a readable regular file"
  rmdir "$HOME_DIR/config/claude-account"
  printf 'ordinary\n' > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-pi" --harness pi --model openai-codex/gpt-5.5); rc=$?
  expect_code 1 "$rc" "a Pi pin without a providers line must refuse"
  assert_refused_before_launch "$id-pi" "$out" "config/pi-account must hold"
  assert_absent "$CASE/claude-checks" "a malformed pin must refuse before any sign-in check"
  pass "malformed, relative, CR-terminated, empty, extra-line, missing-root, and non-file pins refuse before launch"
}

test_pi_pin_selects_the_root_and_the_declared_provider() {
  local out rc id=acct-pi launch
  new_case pi-pin pi
  mkdir -p "$CASE/pi-work"
  printf 'openai-codex\n' > "$CASE/pi-work/signed-in"
  printf '%s\nopenai-codex anthropic\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id" --model openai-codex/gpt-5.5); rc=$?
  expect_code 0 "$rc" "a Pi spawn pinned to a signed-in provider should succeed: $out"
  assert_contains "$out" "account=$CASE/pi-work account_provider=openai-codex" \
    "the spawn should report the pinned root and provider"
  assert_grep "account=$CASE/pi-work" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned root"
  assert_grep "account_provider=openai-codex" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned provider"
  [ "$(cat "$CASE/pi-checks")" = "$CASE/pi-work openai-codex" ] \
    || fail "the sign-in check should ask the pinned root about the model's provider: $(cat "$CASE/pi-checks")"
  launch=$(cat "$CASE/launch.log")
  assert_contains "$launch" "--provider 'openai-codex' --model 'openai-codex/gpt-5.5'" \
    "the launch should confine Pi's model lookup to the declared provider"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/pi-work" "$CASE/pi-worker" "the worker should run under the pinned Pi root"
  assert_grep "--provider openai-codex --model openai-codex/gpt-5.5" "$CASE/pi-worker" \
    "the worker should receive the declared provider"
  pass "a Pi pin selects its root and passes the declared provider"
}

test_pi_pin_refusals() {
  local out rc id=acct-pi-bad
  new_case pi-refusals pi
  mkdir -p "$CASE/pi-work"
  printf 'openai-codex\n' > "$CASE/pi-work/signed-in"
  printf '%s\nopenai-codex anthropic\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-bare" --model gpt-5.5); rc=$?
  expect_code 1 "$rc" "an unqualified Pi model must refuse under a pin"
  assert_refused_before_launch "$id-bare" "$out" "'gpt-5.5' names no provider"
  out=$(spawn_ship "$id-none"); rc=$?
  expect_code 1 "$rc" "a Pi launch with no model must refuse under a pin"
  assert_refused_before_launch "$id-none" "$out" "'none' names no provider"
  out=$(spawn_ship "$id-other" --model openrouter/gpt-5.5); rc=$?
  expect_code 1 "$rc" "an undeclared Pi provider must refuse"
  assert_refused_before_launch "$id-other" "$out" "names provider 'openrouter'"
  out=$(OPENAI_API_KEY=ambient-invoker-openai spawn_ship "$id-out" --model anthropic/claude-sonnet); rc=$?
  expect_code 1 "$rc" "a declared provider the root is not signed in to must refuse"
  assert_refused_before_launch "$id-out" "$out" "which is not signed in for provider 'anthropic'"
  out=$(spawn_ship "$id-raw" --harness "pi --provider openai-codex --model openai-codex/gpt-5.5"); rc=$?
  expect_code 1 "$rc" "a raw Pi launch must refuse under a pin"
  assert_refused_before_launch "$id-raw" "$out" "a raw Pi launch command runs verbatim"
  pass "a Pi pin refuses unqualified, missing, undeclared, signed-out, and raw launches"
}

test_pi_extension_provider_and_old_pi_fall_back_to_the_model_listing() {
  local out rc id=acct-pi-list
  new_case pi-listing pi
  mkdir -p "$CASE/pi-work"
  printf 'codex-native\n' > "$CASE/pi-work/extension-providers"
  printf '%s\ncodex-native openai-codex\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-unlisted" --model codex-native/gpt-6); rc=$?
  expect_code 1 "$rc" "an extension provider the root lists no model for must refuse"
  assert_refused_before_launch "$id-unlisted" "$out" "no model listed for provider codex-native"
  printf 'codex-native  gpt-6  272K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-ext" --model codex-native/gpt-6); rc=$?
  expect_code 0 "$rc" "an extension provider listed under the root should launch: $out"
  : > "$CASE/pi-work/old-pi"
  printf 'openai-codex-mini  gpt-5  128K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-old-near" --model openai-codex/gpt-5); rc=$?
  expect_code 1 "$rc" "a Pi without auth check must match the provider column exactly"
  assert_refused_before_launch "$id-old-near" "$out" "no model listed for provider openai-codex"
  printf 'openai-codex  gpt-5  128K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-old" --model openai-codex/gpt-5); rc=$?
  expect_code 0 "$rc" "a Pi without auth check should launch when the root lists the provider: $out"
  pass "extension providers and a Pi without auth check fall back to an exact model-listing match"
}

test_a_pin_governs_only_its_own_runner() {
  local out rc id=acct-scope
  new_case scope codex
  mkdir -p "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-codex"); rc=$?
  expect_code 0 "$rc" "a codex spawn must ignore a Claude pin: $out"
  assert_not_contains "$out" "account=" "a codex spawn must not report a Claude pin"
  out=$(spawn_ship "$id-pi" --harness pi --model gpt-5.5); rc=$?
  expect_code 0 "$rc" "a Pi spawn must ignore a Claude pin: $out"
  assert_absent "$CASE/claude-checks" "no Claude sign-in check may run for another runner"
  pass "a Claude pin leaves codex and Pi launches unchanged"
}

test_raw_claude_command_receives_the_pin() {
  local out rc id=acct-raw
  new_case raw-claude claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id" --harness "claude --print raw"); rc=$?
  expect_code 0 "$rc" "a raw Claude spawn under a signed-in pin should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "a raw Claude spawn should report the pin"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" "a raw Claude worker should run under the pinned root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "a raw Claude worker must not keep an ambient API key"
  pass "a raw Claude launch command receives the home's pin"
}

test_raw_claude_account_override_refuses_under_a_pin() {
  local out rc id=acct-raw-override var
  new_case raw-override claude
  signed_in_claude_root "$CASE/work"
  signed_in_claude_root "$CASE/other"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  for var in "CLAUDE_CONFIG_DIR=$CASE/other" ANTHROPIC_API_KEY=override-key; do
    out=$(spawn_ship "$id-${var%%=*}" --harness "FOO=1 $var claude --print raw"); rc=$?
    expect_code 1 "$rc" "a raw Claude command setting ${var%%=*} must refuse under a pin"
    assert_refused_before_launch "$id-${var%%=*}" "$out" "the raw launch command sets ${var%%=*}"
    assert_contains "$out" "remove ${var%%=*} from the raw command, or change or remove config/claude-account" \
      "the refusal should say how to proceed"
  done
  assert_absent "$CASE/claude-worker" "a refused raw override must never start Claude"
  pass "a pinned home refuses a raw Claude command that overrides the account"
}

test_raw_claude_account_override_is_kept_without_a_pin() {
  local out rc id=acct-raw-unpinned
  new_case raw-unpinned claude
  mkdir -p "$CASE/other"
  out=$(spawn_ship "$id" --harness "CLAUDE_CONFIG_DIR=$CASE/other ANTHROPIC_API_KEY=override-key claude --print raw"); rc=$?
  expect_code 0 "$rc" "an unpinned home should accept a raw Claude account override: $out"
  assert_not_contains "$out" "account=" "an unpinned raw spawn must not report an account"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/other" "$CASE/claude-worker" "an unpinned raw override should keep its own root"
  assert_grep "ANTHROPIC_API_KEY=override-key" "$CASE/claude-worker" "an unpinned raw override should keep its own key"
  pass "an unpinned home keeps a raw Claude account override"
}

test_local_secondmate_reads_the_launching_home_pin() {
  local out rc id=acct-sm sm
  new_case secondmate claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  sm="$CASE/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/config" "$CASE/sm-own"
  git init -q -b main "$sm"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  printf '%s\n' "$CASE/sm-own" > "$sm/config/claude-account"
  signed_in_claude_root "$CASE/ambient-claude"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$sm" --secondmate); rc=$?
  expect_code 0 "$rc" "a local secondmate spawn under the launching home's pin should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "the secondmate spawn should report the launching home's pin"
  [ "$(cat "$sm/config/claude-account")" = "$CASE/sm-own" ] \
    || fail "the launching home's pin must not be inherited over the secondmate home's own file"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" \
    "the secondmate agent should run under the launching home's pinned root"
  pass "a local secondmate reads the launching home's pin and its own home's file is never inherited over"
}

test_named_accounts_choose_the_most_weighted_remaining_quota() {
  local out rc id=acct-named personal
  new_case named claude
  personal="$HOME_DIR/user-home/.claude"
  signed_in_claude_root "$personal"
  signed_in_claude_root "$CASE/work"
  named_accounts "personal | ordinary | 20" "" "	work |	$CASE/work	| 6.25  "
  quota_reading "$personal" "30 30 80"
  quota_reading "$CASE/work" "90 95 90"
  out=$(spawn_ship "$id-max"); rc=$?
  expect_code 0 "$rc" "a spawn over two named Claude accounts should succeed: $out"
  assert_contains "$out" "account=personal account_root=ordinary" "the spawn line should name the chosen account and its root"
  assert_contains "$out" "notice: chose Claude account personal by weighted remaining quota" "the spawn should say why it chose"
  assert_contains "$out" "personal 20 x 30% = 600 (session 30%, week 80%)" "the notice should show the larger plan's weighted reading"
  assert_contains "$out" "work 6.25 x 90% = 562.5 (session 95%, week 90%)" "the notice should show the smaller plan's weighted reading"
  [ "$(grep '^account' "$HOME_DIR/state/$id-max.meta")" = "account=personal"$'\n'"account_root=ordinary" ] ||
    fail "the task record should name the chosen account and its root: $(grep '^account' "$HOME_DIR/state/$id-max.meta")"
  [ "$(cat "$CASE/quota-reads")" = "unset"$'\n'"$CASE/work" ] ||
    fail "each declared root should be read once, under its own root only: $(cat "$CASE/quota-reads")"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" "the worker should run on the ordinary account it was given"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "a chosen account must shed ambient credentials like a pin"

  quota_reading "$personal" "10 10 80"
  out=$(spawn_ship "$id-team"); rc=$?
  expect_code 0 "$rc" "a spawn should follow the weighted readings: $out"
  assert_contains "$out" "account=work account_root=$CASE/work" "a drained larger plan should yield to the smaller one"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" "the worker should run under the chosen root"

  quota_reading "$personal" "20 20 20"
  quota_reading "$CASE/work" "64 64 64"
  out=$(spawn_ship "$id-tie"); rc=$?
  expect_code 0 "$rc" "a tied spawn should succeed: $out"
  assert_contains "$out" "account=personal account_root=ordinary" "a tie should go to the account declared first"
  pass "several named Claude accounts are chosen by weight times remaining quota, ties to the first declared"
}

test_named_accounts_skip_an_account_that_cannot_take_the_worker() {
  local out rc id=acct-skip personal reads
  new_case named-skip claude
  personal="$HOME_DIR/user-home/.claude"
  signed_in_claude_root "$personal"
  signed_in_claude_root "$CASE/work"
  named_accounts "personal | ordinary | 20" "work | $CASE/work | 6.25"
  quota_reading "$personal" "50 50 50"
  quota_reading "$CASE/work" "unreadable keychain_prompt_required quota-axi --allow-keychain-prompt"
  out=$(spawn_ship "$id-unread"); rc=$?
  expect_code 0 "$rc" "an unreadable account should not stop a readable one: $out"
  assert_contains "$out" "account=personal" "the readable account should take the worker"
  assert_contains "$out" "skipped: work: quota unreadable (keychain_prompt_required; remedy: CLAUDE_CONFIG_DIR=$CASE/work quota-axi --allow-keychain-prompt)" \
    "the notice should name the unreadable account and quota-axi's remedy under its root"

  quota_reading "$personal" "0 0 50 exhausted_now"
  quota_reading "$CASE/work" "40 40 40"
  out=$(spawn_ship "$id-out"); rc=$?
  expect_code 0 "$rc" "an exhausted account should yield to one with quota: $out"
  assert_contains "$out" "account=work" "the account with quota should take the worker"
  assert_contains "$out" "skipped: personal: out of quota (session 0%, week 50%)" "the notice should name the exhausted account"

  quota_reading "$personal" "90 90 90"
  quota_reading "$CASE/work" "10 10 10"
  rm "$personal/.credentials.json"
  out=$(spawn_ship "$id-signed-out"); rc=$?
  expect_code 0 "$rc" "a signed-out best account should yield to the next: $out"
  assert_contains "$out" "account=work" "the next signed-in account should take the worker"
  assert_contains "$out" "personal: not signed in (sign in with env -u CLAUDE_CONFIG_DIR claude, then /login)" \
    "the notice should name the signed-out account and how to sign in"

  quota_reading "$personal" "unreadable credentials_missing"
  quota_reading "$CASE/work" "unreadable keychain_prompt_required quota-axi --allow-keychain-prompt"
  out=$(spawn_ship "$id-none"); rc=$?
  expect_code 1 "$rc" "a spawn must refuse when no declared account can be read"
  assert_refused_before_launch "$id-none" "$out" "none can take this worker"
  assert_contains "$out" "personal: quota unreadable (credentials_missing)" "the refusal should name each account's reason"
  assert_contains "$out" "work: quota unreadable (keychain_prompt_required" "the refusal should name each account's reason"
  assert_contains "$out" "pass --account <name> to choose one explicitly" "the refusal should say how to proceed"

  reads=$(wc -l < "$CASE/quota-reads")
  out=$(spawn_ship "$id-explicit" --account work); rc=$?
  expect_code 0 "$rc" "an explicit account should launch without a quota reading: $out"
  assert_contains "$out" "account=work account_root=$CASE/work" "the explicit account should take the worker"
  assert_not_contains "$out" "notice: chose" "an explicit account is not a quota choice"
  [ "$(wc -l < "$CASE/quota-reads")" = "$reads" ] || fail "an explicit account must not read quota"

  rm -r "$CASE/work"
  quota_reading "$personal" "5 5 5"
  signed_in_claude_root "$personal"
  out=$(spawn_ship "$id-missing-root"); rc=$?
  expect_code 0 "$rc" "a declared root that vanished should not stop the other account: $out"
  assert_contains "$out" "skipped: work: $CASE/work is not a readable, searchable existing directory" \
    "the notice should name the unusable root"
  pass "an unreadable, exhausted, signed-out, or missing account is skipped and named, none refuses, and --account bypasses quota"
}

test_explicit_account_and_named_file_refusals() {
  local out rc id=acct-named-bad n=0 body
  new_case named-refusals claude
  signed_in_claude_root "$CASE/work"
  signed_in_claude_root "$CASE/other"
  named_accounts "personal | ordinary | 20" "work | $CASE/work | 6.25"
  out=$(spawn_ship "$id-unknown" --account nope); rc=$?
  expect_code 1 "$rc" "an undeclared --account must refuse"
  assert_refused_before_launch "$id-unknown" "$out" "--account 'nope' is not one of the Claude accounts config/claude-account declares (personal, work)"
  out=$(spawn_ship "$id-codex" --harness codex --account work); rc=$?
  expect_code 1 "$rc" "--account on another runner must refuse"
  assert_refused_before_launch "$id-codex" "$out" "applies only to a claude launch, not codex"
  out=$(spawn_ship "$id-raw" --harness "CLAUDE_CONFIG_DIR=$CASE/other claude --print raw"); rc=$?
  expect_code 1 "$rc" "a raw override must refuse under named accounts"
  assert_refused_before_launch "$id-raw" "$out" "the raw launch command sets CLAUDE_CONFIG_DIR"
  assert_absent "$CASE/quota-reads" "a raw override must refuse before any quota reading"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-legacy" --account work); rc=$?
  expect_code 1 "$rc" "--account under a single-line pin must refuse"
  assert_refused_before_launch "$id-legacy" "$out" "config/claude-account declares none by name"
  rm "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-nofile" --account work); rc=$?
  expect_code 1 "$rc" "--account with no account file must refuse"
  assert_refused_before_launch "$id-nofile" "$out" "config/claude-account declares none by name"
  for body in "personal | ordinary" "work | relative/root | 1" "work | $CASE/work | 0" \
    "work | $CASE/work | 1"$'\n'"work | $CASE/other | 1" "work | $CASE/work | 1"$'\n'"team | $CASE/work | 1" \
    "work | $CASE/work | 1"$'\r' "work | $CASE/work | heavy"; do
    n=$((n + 1))
    printf '%s\n' "$body" > "$HOME_DIR/config/claude-account"
    out=$(spawn_ship "$id-$n"); rc=$?
    expect_code 1 "$rc" "malformed named file #$n must refuse"
    assert_refused_before_launch "$id-$n" "$out" "config/claude-account line"
  done
  assert_contains "$out" "line 1 must read <name> | <root> | <weight>" "the refusal should say what a line must hold"
  named_accounts "solo | $CASE/work | 3"
  out=$(spawn_ship "$id-solo"); rc=$?
  expect_code 0 "$rc" "a single named account should launch: $out"
  assert_contains "$out" "account=solo account_root=$CASE/work" "a single named account should be reported by name"
  assert_absent "$CASE/quota-reads" "a single declared account needs no quota reading"
  pass "undeclared, misdirected, and unnamed --account values, raw overrides, and malformed named lines refuse; one named account needs no quota"
}

# select_recorded <account> <root>: the launch-time selection a relaunch makes
# for a task whose record names that Claude account, run through the library
# with the case's fakes and its own user home.
select_recorded() {
  (
    PATH="$FAKEBIN:$PATH" HOME="$HOME_DIR/user-home"
    # shellcheck source=bin/fm-worker-account-lib.sh
    . "$ROOT/bin/fm-worker-account-lib.sh"
    fm_worker_account_select claude "$HOME_DIR/config" "" claude "" "" "$1" "$2" ""
  ) 2>&1
}

test_recorded_named_account_is_kept_only_while_usable() {
  local out rc
  new_case recorded claude
  signed_in_claude_root "$CASE/one"
  signed_in_claude_root "$CASE/two"
  named_accounts "one | $CASE/one | 1" "two | $CASE/two | 1"
  quota_reading "$CASE/one" "40 40 40"
  quota_reading "$CASE/two" "90 90 90"
  out=$(select_recorded one "$CASE/one"); rc=$?
  expect_code 0 "$rc" "a usable recorded account should be selected: $out"
  [ "$out" = "$CASE/one"$'\t'"$CASE/one"$'\t\t'"one"$'\t'"recorded" ] ||
    fail "a recorded account with quota must keep the worker even when another has more: $out"

  quota_reading "$CASE/one" "unreadable keychain_prompt_required"
  out=$(select_recorded one "$CASE/one"); rc=$?
  expect_code 0 "$rc" "an unreadable recorded reading should still select: $out"
  assert_contains "$out" "one"$'\t'"recorded" "an unreadable quota reading is not evidence of exhaustion"

  quota_reading "$CASE/one" "0 0 70 exhausted_now"
  out=$(select_recorded one "$CASE/one"); rc=$?
  expect_code 0 "$rc" "a 5-hour-exhausted recorded account should yield: $out"
  assert_contains "$out" "notice: moving this worker off its recorded Claude account one, which is exhausted_now on the 5-hour window (session 0%, week 70%)" \
    "the notice should name the recorded account and the exhausted window"
  assert_contains "$out" "two"$'\t'"quota" "the weighted choice should take the worker"

  quota_reading "$CASE/one" "0 30 0 exhausted_now"
  out=$(select_recorded one "$CASE/one"); rc=$?
  expect_code 0 "$rc" "a weekly-exhausted recorded account should yield: $out"
  assert_contains "$out" "which is exhausted_now on the weekly window (session 30%, week 0%)" "the notice should name the weekly window"
  assert_contains "$out" "two"$'\t'"quota" "the weighted choice should take the worker"

  quota_reading "$CASE/one" "40 40 40"
  rm "$CASE/one/.credentials.json"
  out=$(select_recorded one "$CASE/one"); rc=$?
  expect_code 0 "$rc" "a signed-out recorded account should yield: $out"
  assert_contains "$out" "account one, which is not signed in" "the notice should say the recorded account is signed out"
  assert_contains "$out" "two"$'\t'"quota" "the weighted choice should take the worker"

  signed_in_claude_root "$CASE/one"
  out=$(select_recorded gone "$CASE/gone"); rc=$?
  expect_code 0 "$rc" "an undeclared recorded account should yield: $out"
  assert_contains "$out" "account gone, which is no longer declared by name in config/claude-account" \
    "the notice should say the recorded account is no longer declared"
  assert_contains "$out" "two"$'\t'"quota" "the weighted choice should take the worker"

  printf '%s\n' "$CASE/two" > "$HOME_DIR/config/claude-account"
  out=$(select_recorded "$CASE/one" ""); rc=$?
  expect_code 0 "$rc" "an unnamed recorded root under a single-line pin should select the pin: $out"
  [ "$out" = "$CASE/two"$'\t'"$CASE/two"$'\t\t\t'"pin" ] || fail "a single-line pin must replace an older recorded root: $out"
  out=$(select_recorded one "$CASE/one"); rc=$?
  assert_contains "$out" "account one, which is no longer declared by name" "a single-line pin declares no named account"
  [ "$(printf '%s\n' "$out" | tail -1)" = "$CASE/two"$'\t'"$CASE/two"$'\t\t\t'"pin" ] || fail "a single-line pin must replace a recorded named account: $out"

  rm "$HOME_DIR/config/claude-account" "$CASE/one/.credentials.json"
  out=$(select_recorded "$CASE/one" ""); rc=$?
  expect_code 0 "$rc" "a recorded root with no file should select the ambient account: $out"
  [ -z "$out" ] || fail "with no file a relaunch must launch like any unpinned launch, not on its recorded root: $out"
  pass "a recorded named account is kept only while declared, signed in, and not exhausted_now; an unnamed root never is"
}

test_absent_pin_keeps_the_launch_unchanged
test_claude_pin_selects_the_root_and_sheds_ambient_credentials
test_claude_pin_refuses_a_signed_out_root_despite_an_ambient_login
test_claude_ordinary_pin_unsets_the_config_root
test_malformed_pins_refuse_before_launch
test_pi_pin_selects_the_root_and_the_declared_provider
test_pi_pin_refusals
test_pi_extension_provider_and_old_pi_fall_back_to_the_model_listing
test_a_pin_governs_only_its_own_runner
test_raw_claude_command_receives_the_pin
test_raw_claude_account_override_refuses_under_a_pin
test_raw_claude_account_override_is_kept_without_a_pin
test_local_secondmate_reads_the_launching_home_pin
test_named_accounts_choose_the_most_weighted_remaining_quota
test_named_accounts_skip_an_account_that_cannot_take_the_worker
test_explicit_account_and_named_file_refusals
test_recorded_named_account_is_kept_only_while_usable

echo "# all fm-worker-account tests passed"
