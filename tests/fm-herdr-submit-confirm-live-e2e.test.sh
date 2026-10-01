#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. A stub cannot prove
# either signal. This guard launches real Claude Code in an isolated Herdr lab
# and requires fm_backend_herdr_send_text_submit to report empty for a landed
# idle steer, to submit a long multi-line message and short messages with a
# paragraph break (helm's text-plus-attachment shape, whose attachment line
# ends in ` |`) whole, as Claude's own session transcript records it, both
# idle and while Claude is mid-turn, to submit a message holding a carriage
# return once and whole, and to refuse a composer that shows only part of the
# payload. In a pane short enough that Claude's composer scrolls a long
# message, it requires the proof to type the message again in proven pieces
# and submit it whole, single-paragraph, multi-paragraph, or holding a
# carriage return, to refuse a composer whose visible rows are blank lines
# below a hidden draft, and to clear that draft and a long draft in a narrow
# pane completely. It fails naming the harness and version rather than
# degrading quietly.
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr submit confirmation" entry.
# Every Herdr CLI call, including adapter calls, is routed through
# bin/fm-herdr-lab.sh. The long message's paste-aware request goes straight to
# the control socket that the lab-routed session list names for the lab session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
# The lab server hands this process's environment to every pane it starts. A
# guard run from inside a Claude Code session would pass that session's
# identity markers to the lab Claude, which then runs as a child session and
# saves no transcript, and the long-message case below reads that transcript.
unset CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT \
  CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN \
  CLAUDE_CODE_EXECPATH CLAUDE_PID

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-submit-confirm-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-submit-confirm-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
# FM_LIVE_SEND_TEXT_DELAY injects a late render: the typed text reaches the
# pane that many seconds after the adapter's send returns.
if [ -n "\${FM_LIVE_SEND_TEXT_DELAY:-}" ] && [ "\${args[0]:-}" = pane ] && [ "\${args[1]:-}" = send-text ]; then
  ( sleep "\$FM_LIVE_SEND_TEXT_DELAY"; exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}" ) >/dev/null 2>&1 &
  exit 0
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
wait_idle() {  # <seconds>
  local st i=0
  while [ "$i" -lt "$1" ]; do
    st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$st" in idle|done) return 0 ;; esac
    i=$((i + 1))
    sleep 1
  done
  return 1
}
# submitted_shape: print "whole" when Claude's session transcript records a
# submitted prompt containing <message> byte-for-byte, "fragment:<chars>" when
# the prompt carrying <token> holds less, and nothing when no prompt carries
# <token> within 30 seconds. A prompt queued during a tool call is recorded
# as a queued_command attachment rather than a user message.
submitted_shape() {  # <message> <token>
  local shape='' i=0
  while [ "$i" -lt 30 ]; do
    if [ -f "$TRANSCRIPT" ] && grep -q "$2" "$TRANSCRIPT"; then
      shape=$(jq -j --arg m "$1" --arg t "$2" '
        ((select(.type == "user") | .message.content
          | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join("")) end),
         (select(.type == "attachment" and .attachment.type == "queued_command") | .attachment.prompt))
        | select(type == "string") | select(contains($t))
        | if contains($m) then "whole" else "fragment:" + (length | tostring) end
      ' "$TRANSCRIPT" 2>/dev/null)
    fi
    [ -n "$shape" ] && break
    i=$((i + 1))
    sleep 1
  done
  printf '%s' "$shape"
}
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive --no-focus) \
  || fail "could not create the isolated submit-confirm workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

# A fixed session id names the one transcript the long-message case reads.
CLAUDE_SESSION=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null) || CLAUDE_SESSION=
CLAUDE_SESSION=$(printf '%s' "$CLAUDE_SESSION" | tr 'A-F' 'a-f')
[ -n "$CLAUDE_SESSION" ] || fail "could not generate a Claude Code session id (needs uuidgen or /proc/sys/kernel/random/uuid)"
TRANSCRIPT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$ROOT" | sed 's/[^A-Za-z0-9]/-/g')/$CLAUDE_SESSION.jsonl"
lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}' --session-id $CLAUDE_SESSION" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in
    idle|done) idle=1; break ;;
    blocked)
      # A fresh checkout path stops on Claude's folder-trust prompt, which the
      # pre-send proof would read as a non-empty composer. Accept it and keep
      # waiting for a real idle composer. The prompt preselects "No, exit", so
      # move to "Yes" before confirming; a bare Enter quits Claude.
      case "$(lab pane read "$PANE" --source visible 2>/dev/null || true)" in
        *'Yes, I trust this folder'*) lab pane send-keys "$PANE" down enter >/dev/null \
          || fail "could not accept Claude's folder-trust prompt" ;;
      esac
      ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never registered an idle agent in the lab pane"

TOKEN="FMHERDRPONG$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.4 0.4) \
  || fail "send_text_submit failed to run against Claude Code ($VERSION) on $HERDR_VER"
CHECKED=1
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed idle steer must confirm empty, got '$verdict'"

# Confirm the instruction reached Claude, not merely that the composer cleared.
# The token occurs once in the submitted prompt and once in Claude's reply.
landed=0
i=0
screen=''
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER reports empty and renders the requested reply in isolated session $SESSION"

# Away-mode digests start with U+2063, which Claude's composer read-back drops.
# The pre-Enter proof must still accept the rest of the payload.
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
wait_idle 45 || true
OP_TOKEN="FMHERDROPPONG$$_$RANDOM"
op_text=
fm_operational_input_encode away-supervisor "Reply with exactly $OP_TOKEN and nothing else." op_text \
  || fail "could not encode an away-supervisor payload"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$op_text" 3 0.4 0.4) \
  || fail "send_text_submit failed to run an operational payload against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed U+2063 operational payload must confirm empty, got '$verdict'"
landed=0
i=0
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$OP_TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: operational submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER submits a U+2063 away-supervisor payload whose read-back drops the mark"

# Long multi-line message integrity (helm issue #3): a raw send of a message
# longer than one pty read reached Claude Code in pieces, and only the tail was
# submitted even though the submit confirmed. The composer collapses a paste to
# a placeholder, so the screen cannot prove completeness; Claude's own session
# transcript is the ground truth for what was submitted.
wait_idle 60 || true
LONG_TOKEN="FMLONG$$x$RANDOM"
LONG_MSG=''
for n in 01 02 03 04 05 06 07 08 09 10; do
  LONG_MSG+="$((10#$n)). ${LONG_TOKEN}L$n begins here and carries ordinary prose so the line is about one hundred chars avo."$'\n'
done
LONG_MSG+="END OF TEST MESSAGE ${LONG_TOKEN}END - reply with only the word OK."
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$LONG_MSG" 3 0.4 0.3) \
  || fail "send_text_submit failed to run the long message against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed ${#LONG_MSG}-char message must confirm empty, got '$verdict'"
submitted=$(submitted_shape "$LONG_MSG" "${LONG_TOKEN}END")
[ -n "$submitted" ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the long message never appeared in the lab session transcript $TRANSCRIPT"
[ "$submitted" = whole ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the submitted prompt was not the whole ${#LONG_MSG}-char message ($submitted chars)"
pass "live Herdr long message: Claude Code ($VERSION) on $HERDR_VER submits the whole ${#LONG_MSG}-char multi-line message byte-for-byte"

# Short messages with a paragraph break (the captain's helm send failure):
# Claude renders a typed blank line as a blank row inside its ruled composer.
# The pre-Enter read-back once stopped at that row, so the payload proof saw
# only the first paragraph and refused every such send. helm joins chat text
# and its attachment line with a blank line, so both shapes must land whole.
# Both stay under the paste threshold, so they take the raw typing path.
PNG="$TMP_ROOT/helm-attachment.png"
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==' \
  | base64 -d > "$PNG" 2>/dev/null || printf 'png' > "$PNG"
PNG2="$TMP_ROOT/helm-attachment-second.png"
cp "$PNG" "$PNG2"
PARA_TOKEN="FMPARA$$x$RANDOM"
HELM_TOKEN="FMHELM$$x$RANDOM"
HELM2_TOKEN="FMHELMTWO$$x$RANDOM"
# helm ends its attachment line with ` |` (never on a bare image path), so a
# wrapped row of the two-attachment line starts or ends with `|`.
for shape in paragraphs attachment attachments; do
  case "$shape" in
    paragraphs) token=$PARA_TOKEN
      msg="First paragraph ${token}A of a short message."$'\n\n'"Second paragraph ${token}END - reply with only the word OK." ;;
    attachment) token=$HELM_TOKEN
      msg="1. ${token}END this screenshot shows the report. Reply with only the word OK."$'\n\n'"ATTACHMENTS: $PNG |" ;;
    attachments) token=$HELM2_TOKEN
      msg="${token}END both screenshots. Reply with only the word OK."$'\n\n'"ATTACHMENTS: $PNG | $PNG2 |" ;;
  esac
  wait_idle 60 || true
  verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$msg" 3 0.4 0.3) \
    || fail "send_text_submit failed to run the $shape message against Claude Code ($VERSION) on $HERDR_VER"
  [ "$verdict" = empty ] \
    || fail "Claude Code ($VERSION) on $HERDR_VER: a ${#msg}-char $shape message with a blank line must confirm empty, got '$verdict'"
  submitted=$(submitted_shape "$msg" "$token")
  [ "$submitted" = whole ] \
    || fail "Claude Code ($VERSION) on $HERDR_VER: the ${#msg}-char $shape message was not submitted whole (${submitted:-absent})"
  pass "live Herdr paragraph break: Claude Code ($VERSION) on $HERDR_VER submits the whole ${#msg}-char $shape message byte-for-byte"
done

# A late render: a large, busy Claude can draw typed text after the caller's
# settle. The text reaches the pane 0.8 seconds after the send returns, past
# the 0.3-second settle, and must still be proven and submitted once whole.
wait_idle 60 || true
LATE_TOKEN="FMLATE$$x$RANDOM"
msg="${LATE_TOKEN}END I want you to launch a thorough investigation instead, to make sure that we actually understand the situation. Regarding the question you raised, based on what I know, I would say go with your recommendation. Reply with only the word OK."
export FM_LIVE_SEND_TEXT_DELAY=0.8
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$msg" 3 0.4 0.3) \
  || fail "send_text_submit failed to run the late-render message against Claude Code ($VERSION) on $HERDR_VER"
unset FM_LIVE_SEND_TEXT_DELAY
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a ${#msg}-char message drawn 0.8s late must confirm empty, got '$verdict'"
submitted=$(submitted_shape "$msg" "$LATE_TOKEN")
[ "$submitted" = whole ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the ${#msg}-char message drawn late was not submitted whole (${submitted:-absent})"
pass "live Herdr late render: Claude Code ($VERSION) on $HERDR_VER re-reads a ${#msg}-char message drawn 0.8s after the send and submits it whole"

# Carriage returns: Claude reads a CR in a short burst as Enter, which would
# submit the text before it. The adapter types it as a line break, so the
# whole message is submitted once, with no partial prompt before it.
wait_idle 60 || true
CR_TOKEN="FMCR$$x$RANDOM"
msg="${CR_TOKEN}A one"$'\r'"${CR_TOKEN}END two."
[ "$(printf '%s' "$msg" | wc -c)" -lt 56 ] \
  || fail "the carriage-return case is ${#msg} bytes, too long for Claude to read it as keys, so it would prove nothing"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$msg" 3 0.4 0.3) \
  || fail "send_text_submit failed to run the short carriage-return message against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a ${#msg}-char message with a carriage return must confirm empty, got '$verdict'"
submitted=$(submitted_shape "${msg//$'\r'/$'\n'}" "$CR_TOKEN")
[ "$submitted" = whole ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the ${#msg}-char carriage-return message was not submitted once whole (${submitted:-absent})"
pass "live Herdr carriage return: Claude Code ($VERSION) on $HERDR_VER submits a ${#msg}-char message with a carriage return once, whole, with a line break"

# The captain sends from helm while firstmate is mid-turn: the same attachment
# shape must land in a busy Claude, which queues it, and be submitted whole.
wait_idle 60 || true
BUSY_TOKEN="FMBUSY$$x$RANDOM"
lab pane send-text "$PANE" "Use the Bash tool once, in the foreground and not in the background, to run exactly: for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sleep 1; done. Then reply with only the word OK." >/dev/null \
  || fail "could not type the busy-turn prompt into the lab composer"
sleep 0.4
lab pane send-keys "$PANE" enter >/dev/null || fail "could not submit the busy-turn prompt"
busy=0
i=0
while [ "$i" -lt 30 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  if [ "$st" = working ] || [ "$(fm_backend_herdr_rendered_busy_state "$TARGET")" = busy ]; then
    busy=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$busy" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never showed a busy turn for the busy-send case"
msg="${BUSY_TOKEN}END sent while you work. Reply with only the word OK."$'\n\n'"ATTACHMENTS: $PNG | $PNG2 |"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$msg" 3 0.4 0.3) \
  || fail "send_text_submit failed to run the busy attachment message against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a ${#msg}-char attachment message sent mid-turn must confirm empty, got '$verdict'"
wait_idle 90 || true
submitted=$(submitted_shape "$msg" "$BUSY_TOKEN")
[ "$submitted" = whole ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the ${#msg}-char attachment message sent mid-turn was not submitted whole (${submitted:-absent})"
pass "live Herdr busy send: Claude Code ($VERSION) on $HERDR_VER queues and submits the whole ${#msg}-char attachment message sent mid-turn"

# The payload proof must still refuse a composer that shows only part of the
# message. Type just the tail, and then just the head, of a two-paragraph
# message into the real composer and require the proof to reject each read.
wait_idle 60 || true
CUT_TOKEN="FMCUT$$x$RANDOM"
cut_head="Head paragraph ${CUT_TOKEN}A."
cut_tail="Tail paragraph ${CUT_TOKEN}B."
cut_msg="$cut_head"$'\n\n'"$cut_tail"
for part in tail head; do
  if [ "$part" = tail ]; then typed=$cut_tail; else typed=$cut_head; fi
  lab pane send-text "$PANE" "$typed" >/dev/null \
    || fail "could not type the $part of the truncation probe into the lab composer"
  sleep 0.5
  content=$(fm_backend_herdr_composer_content "$TARGET" "$FM_BACKEND_HERDR_PROOF_CAPTURE_LINES") \
    || fail "Claude Code ($VERSION) on $HERDR_VER: could not read back the composer holding the $part"
  case "$content" in
    *"$typed"*) ;;
    *) fail "Claude Code ($VERSION) on $HERDR_VER: the composer read-back '$content' does not show the typed $part" ;;
  esac
  if fm_backend_herdr_composer_payload_shown "$cut_msg" "$content"; then
    fail "Claude Code ($VERSION) on $HERDR_VER: the payload proof accepted a composer showing only the $part"
  fi
  fm_backend_herdr_composer_clear "$TARGET" "$cut_msg" 1 \
    || fail "Claude Code ($VERSION) on $HERDR_VER: could not clear the truncation probe's $part from the composer"
done
pass "live Herdr payload proof: Claude Code ($VERSION) on $HERDR_VER refuses a composer showing only the head or only the tail"

# A composer too short for the message (Helm's long captain chat while
# firstmate sat idle): Claude's fullscreen view caps its composer at about half
# the pane's rows and scrolls a longer draft, so the read-back shows only the
# message's last rows. A lab pane has its real size only while a client is
# attached, so the viewer attaches before the pane is split to about 16 rows,
# which leaves Claude three composer rows for a message that wraps over five.
wait_idle 60 || true
# The viewer runs `herdr --session <name>` from PATH, so it gets the real
# Herdr rather than this guard's session-checking wrapper.
env PATH="$ORIGINAL_PATH" "$LAB_HELPER" viewer start "$SESSION" >/dev/null \
  || fail "could not attach the lab viewer that gives the Claude pane a real size"
lab pane split "$PANE" --direction down --ratio 0.4 >/dev/null \
  || fail "could not split the lab pane to shorten Claude's composer"
rows=''
i=0
while [ "$i" -lt 20 ]; do
  rows=$(lab pane get "$PANE" 2>/dev/null | jq -r '.result.pane.scroll.viewport_rows // empty')
  case "$rows" in ''|*[!0-9]*) ;; *) [ "$rows" -le 16 ] && break ;; esac
  i=$((i + 1))
  sleep 0.5
done
case "$rows" in ''|*[!0-9]*) rows=99 ;; esac
[ "$rows" -le 16 ] || fail "the split lab pane never shrank to 16 rows (viewport rows: $rows)"
wait_idle 30 || true
SCROLL_TOKEN="FMSCROLL$$x$RANDOM"
msg="${SCROLL_TOKEN}END All right. Regarding the stuff you said, waiting on me for number one, look into it. Make sure that he didn't actually do anything, and that we have a better understanding of this situation before I ask anything. For number two and three, elaborate on them with your recommendation and how. Same thing for number five. Reply with only the word OK."
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$msg" 3 0.4 0.3) \
  || fail "send_text_submit failed to run the scrolled-composer message against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a ${#msg}-char message that Claude's $rows-row pane scrolls in its composer must confirm empty, got '$verdict'"
scroll_msg=$msg
submitted=$(submitted_shape "$msg" "$SCROLL_TOKEN")
[ "$submitted" = whole ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the ${#msg}-char message scrolled in the composer was not submitted whole (${submitted:-absent})"
pass "live Herdr scrolled composer: Claude Code ($VERSION) on $HERDR_VER types a ${#msg}-char message its $rows-row pane scrolls again in proven pieces and submits it whole"

# The same pane with a multi-paragraph message: blank lines between its
# paragraphs and list sit at the top of some proof reads.
wait_idle 60 || true
PARA2_TOKEN="FMSCROLLPARA$$x$RANDOM"
msg="Captain notes ${PARA2_TOKEN}END, reply with only OK:"$'\n\n'"first paragraph about the release, which should go out after the review is done and the docs are fixed."$'\n\n'"- item one: rebase the branch"$'\n'"- item two: rerun the checks"$'\n'"- item three: update the report"$'\n\n'"last line, including the docs."
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$msg" 3 0.4 0.3) \
  || fail "send_text_submit failed to run the scrolled multi-paragraph message against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a ${#msg}-char multi-paragraph message that Claude's $rows-row pane scrolls must confirm empty, got '$verdict'"
submitted=$(submitted_shape "$msg" "$PARA2_TOKEN")
[ "$submitted" = whole ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the ${#msg}-char multi-paragraph message scrolled in the composer was not submitted whole (${submitted:-absent})"
pass "live Herdr scrolled composer: Claude Code ($VERSION) on $HERDR_VER submits a ${#msg}-char multi-paragraph message its $rows-row pane scrolls whole"

# A draft hidden above blank lines: Claude's capped composer shows only the
# blank rows, so the composer looks empty. The send must be refused before
# anything is typed, and the Claude-aware clear must then empty the draft.
wait_idle 60 || true
HIDDEN_TOKEN="FMHIDDEN$$x$RANDOM"
hidden="STALE-FRAGMENT ${HIDDEN_TOKEN} rm the release branch"$'\n\n\n\n'
lab pane send-text "$PANE" "$hidden" >/dev/null \
  || fail "could not type the hidden draft into the lab composer"
sleep 0.5
fm_backend_herdr_composer_view "$TARGET" "$FM_BACKEND_HERDR_PROOF_CAPTURE_LINES" \
  || fail "Claude Code ($VERSION) on $HERDR_VER: could not read the composer holding the hidden draft"
[ -z "${FM_BACKEND_HERDR_VIEW_TEXT//[$' \t']/}" ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the $rows-row pane still shows the hidden draft ('$FM_BACKEND_HERDR_VIEW_TEXT'), so this case proves nothing about blank rows"
HIDDEN_MSG_TOKEN="FMHIDDENMSG$$x$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "${HIDDEN_MSG_TOKEN}END reply with only OK." 3 0.4 0.3 2>"$TMP_ROOT/hidden.err") \
  || fail "send_text_submit failed to run against the hidden draft in Claude Code ($VERSION) on $HERDR_VER"
{ [ "$verdict" = send-failed ] && grep -q 'visible rows are blank before typing, so nothing was typed' "$TMP_ROOT/hidden.err"; } \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a send over a draft hidden above blank rows must be refused before typing, got '$verdict': $(cat "$TMP_ROOT/hidden.err")"
fm_backend_herdr_composer_clear "$TARGET" "$hidden" 1 \
  || fail "Claude Code ($VERSION) on $HERDR_VER: could not clear the draft hidden above blank rows"
{ fm_backend_herdr_composer_view "$TARGET" "$FM_BACKEND_HERDR_PROOF_CAPTURE_LINES" && [ "$FM_BACKEND_HERDR_VIEW_EMPTY" = 1 ]; } \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the cleared composer does not show one empty row"
if grep -q "$HIDDEN_TOKEN" "$TRANSCRIPT" 2>/dev/null; then
  fail "Claude Code ($VERSION) on $HERDR_VER: the hidden draft reached Claude's transcript"
fi
pass "live Herdr hidden draft: Claude Code ($VERSION) on $HERDR_VER refuses to type over a draft hidden above blank composer rows in its $rows-row pane and clears it"

# A refused long draft in a narrow pane: Claude's Ctrl+U deletes one wrapped
# row per press, so the clear needs one press per row the draft really wraps
# to, more than a 40-characters-per-row estimate allows at this width.
lab pane split "$PANE" --direction right --ratio 0.35 >/dev/null \
  || fail "could not split the lab pane to narrow Claude's composer"
cols=''
i=0
while [ "$i" -lt 20 ]; do
  cols=$(lab pane layout --pane "$PANE" 2>/dev/null | jq -r --arg p "$PANE" '.result.layout.panes[] | select(.pane_id == $p) | .rect.width')
  case "$cols" in ''|*[!0-9]*) ;; *) [ "$cols" -le 40 ] && break ;; esac
  i=$((i + 1))
  sleep 0.5
done
case "$cols" in ''|*[!0-9]*) cols=999 ;; esac
[ "$cols" -le 40 ] || fail "the split lab pane never narrowed to 40 columns (width: $cols)"
sleep 1
draft="${scroll_msg} ${scroll_msg}"
draft=${draft:0:700}
lab pane send-text "$PANE" "$draft" >/dev/null \
  || fail "could not type the long draft into the narrow lab composer"
sleep 0.5
fm_backend_herdr_composer_clear "$TARGET" "$draft" 1 \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a ${#draft}-char draft in a $cols-column pane was not cleared back to empty"
{ fm_backend_herdr_composer_view "$TARGET" "$FM_BACKEND_HERDR_PROOF_CAPTURE_LINES" && [ "$FM_BACKEND_HERDR_VIEW_EMPTY" = 1 ]; } \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the $cols-column composer still holds part of the cleared draft"
pass "live Herdr composer clear: Claude Code ($VERSION) on $HERDR_VER clears a ${#draft}-char draft in a $cols-column pane row by row"

# The same narrow pane: the scrolled message is typed again in more, smaller
# pieces, and must still be submitted whole.
wait_idle 60 || true
NARROW_TOKEN="FMNARROW$$x$RANDOM"
msg="${NARROW_TOKEN}END Make sure that he didn't actually do anything, and that we have a better understanding of this situation before I ask anything. For number two and three, elaborate on them with your recommendation and how. Reply with only the word OK."
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$msg" 3 0.4 0.3) \
  || fail "send_text_submit failed to run the narrow scrolled message against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a ${#msg}-char message in a $cols-column pane must confirm empty, got '$verdict'"
submitted=$(submitted_shape "$msg" "$NARROW_TOKEN")
[ "$submitted" = whole ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the ${#msg}-char message in a $cols-column pane was not submitted whole (${submitted:-absent})"
pass "live Herdr scrolled composer: Claude Code ($VERSION) on $HERDR_VER submits a ${#msg}-char message whole in a $cols-column pane"
# The narrow pane with a carriage return in a scrolled message: each piece
# typed again is a burst of fewer than 30 bytes, where Claude reads a CR as
# Enter.
wait_idle 60 || true
CR2_TOKEN="FMSCROLLCR$$x$RANDOM"
msg="${CR2_TOKEN}A first part before a bare carriage return, then: ${scroll_msg#* }"$'\r'"${CR2_TOKEN}END SECOND PART AFTER IT, reply with only OK."
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$msg" 3 0.4 0.3) \
  || fail "send_text_submit failed to run the scrolled carriage-return message against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a ${#msg}-char message with a carriage return in a $cols-column pane must confirm empty, got '$verdict'"
submitted=$(submitted_shape "${msg//$'\r'/$'\n'}" "$CR2_TOKEN")
[ "$submitted" = whole ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the ${#msg}-char scrolled carriage-return message was not submitted once whole (${submitted:-absent})"
pass "live Herdr scrolled composer: Claude Code ($VERSION) on $HERDR_VER submits a ${#msg}-char message with a carriage return a $cols-column pane scrolls once, whole"

env PATH="$ORIGINAL_PATH" "$LAB_HELPER" viewer stop "$SESSION" >/dev/null || true

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"
