#!/usr/bin/env bash
# Opt-in live guard for the Claude Code PreCompact handoff hook
# (bin/fm-precompact-handoff.sh).
#
# Three facts here come from the vendor, not from Firstmate, so a stub can only
# confirm the assumption already written into the stub:
#
#   (a) the tracked `.claude/settings.json` PreCompact entry fires before a
#       manual `/compact` and before an automatic compaction, and hands the hook
#       the trigger, the transcript path, and the /compact instructions;
#   (b) the real transcript marks the captain's turns so the hook can quote
#       them verbatim (tests/fm-precompact-handoff.test.sh pins the parsing
#       portably against hand-built records of the same shape);
#   (c) the compaction still proceeds after the hook ran.
#
# It builds a throwaway Firstmate-shaped lab outside the repo carrying the
# TRACKED Claude settings and the real hook, so a registration that stops firing
# fails this guard; the other tracked hook scripts get no-op stubs.
# The automatic case lowers the auto-compact threshold for one session through
# Claude Code's CLAUDE_CODE_AUTO_COMPACT_WINDOW (floor 100000 tokens) and
# CLAUDE_AUTOCOMPACT_PCT_OVERRIDE; a lab session is too small for the summary
# itself to succeed, and the guard asserts only that the hook fired with the
# automatic trigger before it.
#
# Run it after every Claude Code upgrade and before trusting refreshed evidence
# in docs/verification/supervision.md:
#
#   FM_PRECOMPACT_HANDOFF_LIVE_E2E=1 tests/fm-precompact-handoff-live-e2e.test.sh
#
# It costs a few small model turns.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PRECOMPACT_HANDOFF_LIVE_E2E claude jq

unset NO_MISTAKES_GATE FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE

LAB="${TMPDIR:-/tmp}/fm-precompact-handoff-live-e2e.$$"
trap 'rm -rf "$LAB"' EXIT INT TERM
NONCE=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
MODEL=${FM_PRECOMPACT_HANDOFF_LIVE_MODEL:-haiku}
VERSION=$(claude --version 2>/dev/null | head -n 1)
note() { printf '# %s\n' "$1"; }
note "claude: ${VERSION:-unknown version}"

make_lab() {  # <dir>
  local lab=$1 script
  mkdir -p "$lab/bin" "$lab/state" "$lab/data" "$lab/.claude"
  git init -q -b main "$lab"
  printf '# Firstmate lab\n' > "$lab/AGENTS.md"
  cp "$ROOT/.claude/settings.json" "$lab/.claude/settings.json"
  for script in fm-precompact-handoff.sh fm-gate-refuse-lib.sh fm-primary-scope-lib.sh \
    fm-session-lock-lib.sh fm-cursor-lib.sh fm-hook-host-lib.sh fm-timeout-lib.sh; do
    cp "$ROOT/bin/$script" "$lab/bin/$script"
  done
  for script in fm-sessionstart-run.sh fm-turnend-guard.sh fm-claude-stop-autoarm.sh \
    fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-subagent-pretool-check.sh \
    fm-host-mirror.sh fm-tasks-axi.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$lab/bin/$script"
  done
  chmod +x "$lab/bin/"*.sh
  git -C "$lab" add -A >/dev/null 2>&1
  git -C "$lab" -c user.email=fmtest@example.invalid -c user.name=fmtest commit -q -m init >/dev/null 2>&1 || true
}

field() {  # <lab> <key>
  sed -n "s/^$2=//p" "$1/state/.precompact-handoff" 2>/dev/null
}

# --- manual /compact -----------------------------------------------------------
MANUAL="$LAB/manual"
make_lab "$MANUAL"
PHRASE="Remember the manual codeword MANUAL-$NONCE and reply OK."
SESSION=$(cd "$MANUAL" && claude -p --model "$MODEL" --output-format json "$PHRASE" </dev/null 2>/dev/null \
  | jq -r '.session_id // empty')
[ -n "$SESSION" ] || fail "claude $VERSION did not start a lab session"
(cd "$MANUAL" && claude -p --model "$MODEL" --resume "$SESSION" "/compact keep ARG-$NONCE" </dev/null >/dev/null 2>&1)

[ -f "$MANUAL/state/.precompact-handoff" ] \
  || fail "claude $VERSION: the tracked PreCompact entry did not run the hook on /compact"
[ "$(field "$MANUAL" status)" = ok ] \
  || fail "claude $VERSION: the manual handoff was not ok: $(cat "$MANUAL/state/.precompact-handoff")"
[ "$(field "$MANUAL" trigger)" = manual ] || fail "claude $VERSION: /compact did not report trigger=manual"
NOTE=$(cat "$MANUAL/data/session-handoff.md")
assert_contains "$NOTE" "> $PHRASE" "claude $VERSION: the captain's words were not quoted verbatim from the real transcript"
assert_contains "$NOTE" "> keep ARG-$NONCE" "claude $VERSION: the /compact instructions did not reach the hook"
TRANSCRIPT=$(field "$MANUAL" transcript)
grep -q '"compact_boundary"' "$TRANSCRIPT" 2>/dev/null \
  || fail "claude $VERSION: the compaction did not proceed after the hook ran"
pass "claude $VERSION: /compact runs the handoff with trigger=manual, verbatim captain words, and proceeds"

# --- automatic compaction ------------------------------------------------------
AUTO="$LAB/auto"
make_lab "$AUTO"
msg() { jq -nc --arg t "$1" '{type: "user", message: {role: "user", content: $t}}'; }
{
  msg "Remember the automatic codeword AUTO-$NONCE and write two sentences about apples."
  sleep 25
  msg "Write two sentences about pears."
  sleep 60
} | (cd "$AUTO" && CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=5 \
  claude -p --model "$MODEL" --input-format stream-json --output-format stream-json --verbose \
  >/dev/null 2>&1)

[ -f "$AUTO/state/.precompact-handoff" ] \
  || fail "claude $VERSION: the tracked PreCompact entry did not run the hook before an automatic compaction"
[ "$(field "$AUTO" trigger)" = auto ] || fail "claude $VERSION: an automatic compaction did not report trigger=auto"
assert_contains "$(cat "$AUTO/data/session-handoff.md")" "AUTO-$NONCE" \
  "claude $VERSION: the automatic handoff lost the captain's words"
pass "claude $VERSION: an automatic compaction runs the handoff first with trigger=auto"
