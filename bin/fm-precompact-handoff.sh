#!/usr/bin/env bash
# Pre-compaction handoff: the Claude Code PreCompact hook entry point.
#
# Why it exists: a compaction replaces the conversation with a summary that
# lives only in that session. A planned "stow then compact" writes everything
# durable first, but an automatic compaction fires with no stow at all, and
# whatever existed only in conversation - a captain decision given in chat, an
# answer to an open question, the thread of the work - can be lost or blurred by
# the summary. This hook runs just before every compaction, manual or automatic,
# and writes a deterministic snapshot of what the summary could lose into the
# home's session handoff note, so the post-compaction context re-emit
# (bin/fm-session-start.sh, source `compact`) can surface it.
# It records; it never judges. Filing work items and correcting records stays
# with the stow skill and the agent.
#
# Usage: fm-precompact-handoff.sh
#   Reads the Claude-shaped PreCompact JSON payload on stdin (`session_id`,
#   `transcript_path`, `trigger` manual|auto, `custom_instructions` string or
#   null). Prints nothing on stdout.
#
# Where it writes (both in this home, FM_HOME):
#   data/session-handoff.md  The session handoff note. Only the block between
#                            `<!-- fm-precompact-handoff:begin -->` and
#                            `<!-- fm-precompact-handoff:end -->` is owned by
#                            this script: it is replaced in place, or appended
#                            when absent, and every other line of the note (for
#                            example the conversation threads a /stow wrote) is
#                            preserved byte for byte. The replacement is atomic.
#   state/.precompact-handoff The last-result record, one key=value per line:
#                            status (ok|partial|failed), at (epoch seconds),
#                            trigger, session, transcript, turns, reason.
#                            partial means the note was written without the
#                            conversation part (transcript missing or
#                            unreadable). The re-emit reads it to say whether a
#                            fresh snapshot exists for this compaction.
#
# The snapshot block holds, newest state at compaction time:
#   - the /compact custom instructions, when the captain gave any;
#   - the captain's most recent turns, verbatim and clipped;
#   - the id and hold kind of every held backlog item, through
#     bin/fm-tasks-axi.sh (captain decisions and external waits);
#   - every state/*.meta task's id, kind, and recorded PR URL.
# It deliberately carries only the captain's own words plus identifiers, never
# firstmate's replies, worker status lines, backlog titles, or hold reasons:
# those can quote patient or worker text, and the compact re-emit already
# reprints the work state from its own records.
#
# Captain turns are the transcript's `user` records whose `origin.kind` is
# `human`, minus firstmate's own typed operational input, which Claude Code also
# records as human: whatever bin/fm-operational-input.sh classifies as
# operational input, or recognizes as a record-backed doorbell. A transcript
# with no `origin` field has no captain turns.
#
# Contract with the compaction: this hook must never block or fail it. Claude
# Code blocks compaction on exit 2 or a `decision: block` JSON object, so the
# work runs in a subshell and the script always exits 0 with empty stdout. A
# failure is recorded in the last-result record with its reason, logged to
# stderr (Claude Code's debug log), and the compaction proceeds. The settings
# entry bounds the whole hook with a timeout; a timed-out hook is a non-blocking
# error, and the atomic replace means a kill never leaves a torn note.
#
# Scope: the same eligibility owners as bin/fm-sessionstart-run.sh - a
# no-mistakes gate agent or a linked task worktree never writes a home's note -
# plus the Cursor and pi-code payload guards (bin/fm-hook-host-lib.sh), since
# both hosts load the tracked Claude settings but write a different transcript
# format, and a session that another live session
# holds the fleet lock against steps aside because it has no mutation authority
# in this home. An absent, stale, or self-owned lock writes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
HANDOFF="$DATA/session-handoff.md"
RESULT="$STATE/.precompact-handoff"
BEGIN_MARK='<!-- fm-precompact-handoff:begin -->'
END_MARK='<!-- fm-precompact-handoff:end -->'

# Clip bounds keep the block small enough for the re-emit digest, whose tail a
# harness may truncate.
MAX_TURNS=10
TURN_CHARS=1000
HOLDS_TIMEOUT=10

case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
    exit 0
    ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

TRIGGER=unknown
SESSION_ID=
TRANSCRIPT=

# write_result <status> <turns> <reason>: atomically replace the last-result
# record. Best effort: a state directory that cannot be written is logged.
write_result() {
  local status=$1 turns=$2 reason=$3 tmp
  tmp=$(mktemp "$STATE/.precompact-handoff.XXXXXX" 2>/dev/null) || {
    printf 'fm-precompact-handoff: cannot record result in %s\n' "$STATE" >&2
    return 0
  }
  if printf 'status=%s\nat=%s\ntrigger=%s\nsession=%s\ntranscript=%s\nturns=%s\nreason=%s\n' \
    "$status" "$(date +%s)" "$TRIGGER" "$SESSION_ID" "$TRANSCRIPT" "$turns" "$reason" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$RESULT" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  printf 'fm-precompact-handoff: cannot record result in %s\n' "$STATE" >&2
}

step_aside() {  # <reason>
  printf 'fm-precompact-handoff: %s; compaction proceeds without a handoff\n' "$1" >&2
  write_result failed 0 "$1"
  exit 0
}

# human_turns <transcript>: print every human-origin turn, newest first, as a
# NUL-terminated pair: its raw text, then the turn as a JSON object. Each line
# parses on its own, so a torn line from a concurrent append is skipped rather
# than failing the whole read.
human_turns() {
  jq -Rjn '
    def blocks: if (.message.content | type) == "array" then .message.content else [] end;
    def content_text:
      if (.message.content | type) == "string" then .message.content
      else [blocks[] | select(type == "object" and .type == "text") | .text | strings] | join("\n")
      end;
    def has_block($t): any(blocks[]; type == "object" and .type == $t);
    def command_form:
      if test("<command-name>") then
        ((try capture("<command-name>(?<n>[^<]*)</command-name>").n catch "")
          + " " + (try capture("<command-args>(?<a>[\\s\\S]*?)</command-args>").a catch ""))
        | sub("\\s+$"; "")
      else . end;
    [inputs | try fromjson catch null
      | select(type == "object" and .type == "user" and .isMeta != true
          and .isCompactSummary != true and .isSidechain != true
          and (has_block("tool_result") | not)
          and (.origin | type) == "object" and .origin.kind == "human")]
    | reverse[]
    | content_text as $t
    | ($t | gsub("\u0000"; "")), "\u0000",
      ({ts: (.timestamp // ""), text: ($t | command_form), image: has_block("image")} | tojson),
      "\u0000"
  ' < "$1"
}

# render_turns <transcript>: print TURNS=<n> on the first line, then the
# markdown for the captain's most recent turns.
render_turns() {
  local pairs raw turn kind kept=() n=0 i
  pairs=$(mktemp "$DATA/.precompact-turns.XXXXXX" 2>/dev/null) || return 1
  if ! human_turns "$1" > "$pairs"; then
    rm -f "$pairs"
    return 1
  fi
  while [ "$n" -lt "$MAX_TURNS" ] && IFS= read -r -d '' raw && IFS= read -r -d '' turn; do
    if fm_operational_input_classify "$raw" kind || fm_operational_doorbell_record_kind "$raw" kind; then
      continue
    fi
    kept[n]=$turn
    n=$((n + 1))
  done < "$pairs"
  rm -f "$pairs"
  for ((i = n - 1; i >= 0; i--)); do printf '%s\n' "${kept[i]}"; done | jq -rs \
    --argjson turn_chars "$TURN_CHARS" '
    def clip($n): if length > $n then .[0:$n] + " [...]" else . end;
    def safe: gsub("<!--"; "<! --");
    def quote: split("\n") | map("> " + .) | join("\n");
    . as $turns
    | "TURNS=\($turns | length)",
      "### Captain'"'"'s recent words (verbatim, oldest first)",
      "",
      (if ($turns | length) == 0 then "(no captain turns found in the transcript)"
       else ($turns[] |
         "- \(.ts)" + (if .image then " (with an attachment)" else "" end),
         "",
         ((if (.text | length) > 0 then .text else "(attachment only)" end) | clip($turn_chars) | safe | quote),
         "")
       end)
  '
}

# render_workers: one line per state/*.meta task - its id, kind, and PR URL.
render_workers() {
  local meta id kind pr found=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    found=1
    id=$(basename "$meta" .meta)
    kind=$(sed -n 's/^kind=//p' "$meta" 2>/dev/null | tail -n 1)
    pr=$(sed -n 's/^pr=//p' "$meta" 2>/dev/null | tail -n 1)
    printf -- '- %s (%s)' "$id" "${kind:-unknown kind}"
    [ -z "$pr" ] || printf ' pr=%s' "$pr"
    printf '\n'
  done
  [ "$found" -eq 1 ] || printf '(no task records)\n'
}

# render_holds: one line per held backlog item - its id and hold kind only. In
# the listing's row form the id is the first cell and hold_kind, requested as
# the one extra field, is the last; the title between them may hold commas, so
# only those two cells are read, and a row whose cells do not look like
# identifiers is left out rather than guessed at.
render_holds() {
  local out rc=0
  if [ ! -x "$SCRIPT_DIR/fm-tasks-axi.sh" ]; then
    printf '(unavailable: bin/fm-tasks-axi.sh is missing)\n'
    return 0
  fi
  out=$(fm_run_timed "$HOLDS_TIMEOUT" "$SCRIPT_DIR/fm-tasks-axi.sh" list --state held \
    --fields hold_kind 2>&1 </dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '(unavailable: the backlog listing exited %s)\n' "$rc"
    return 0
  fi
  printf '%s\n' "$out" | awk '
    /^  [^ ]/ {
      row = substr($0, 3)
      id = row; sub(/,.*/, "", id)
      kind = row; sub(/.*,/, "", kind)
      if (id ~ /^[A-Za-z0-9._-]+$/ && kind ~ /^[a-z-]*$/) {
        printf "- %s (hold kind: %s)\n", id, (kind == "" ? "unknown" : kind)
        found = 1
      }
    }
    END { if (!found) print "(none)" }
  '
}

main() {
  fm_is_gate_agent "$FM_ROOT" && exit 0
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

  local payload=
  [ -t 0 ] || payload=$(cat 2>/dev/null || true)
  fm_hook_payload_is_foreign_host "$payload" && exit 0
  fm_hook_payload_is_pi_code "$payload" && exit 0
  fm_session_lock_foreign_owner_live "$STATE" && exit 0

  command -v jq >/dev/null 2>&1 || step_aside "jq is not installed"
  if ! printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
    step_aside "the hook payload is missing or not a JSON object"
  fi
  local custom
  TRIGGER=$(printf '%s' "$payload" | jq -r '.trigger // "unknown" | tostring' 2>/dev/null) || TRIGGER=unknown
  SESSION_ID=$(printf '%s' "$payload" | jq -r '.session_id // "" | tostring' 2>/dev/null) || SESSION_ID=
  TRANSCRIPT=$(printf '%s' "$payload" | jq -r '.transcript_path // "" | tostring' 2>/dev/null) || TRANSCRIPT=
  custom=$(printf '%s' "$payload" | jq -r '.custom_instructions // "" | tostring' 2>/dev/null) || custom=
  # The record is line-oriented, so a newline in a vendor field must not forge
  # another key.
  TRIGGER=$(printf '%s' "$TRIGGER" | tr '\n' ' ')
  SESSION_ID=$(printf '%s' "$SESSION_ID" | tr '\n' ' ')
  TRANSCRIPT=$(printf '%s' "$TRANSCRIPT" | tr '\n' ' ')

  [ -d "$DATA" ] || step_aside "the data directory $DATA does not exist"

  local turns_out turns=0 status=ok reason=
  if [ -z "$TRANSCRIPT" ] || [ ! -r "$TRANSCRIPT" ]; then
    status=partial
    reason="transcript not readable: ${TRANSCRIPT:-(none given)}"
    turns_out="### Captain's recent words

(unavailable: $reason)"
  elif turns_out=$(render_turns "$TRANSCRIPT" 2>/dev/null); then
    turns=$(printf '%s\n' "$turns_out" | sed -n '1s/^TURNS=//p')
    turns_out=$(printf '%s\n' "$turns_out" | sed '1d')
  else
    status=partial
    reason="transcript could not be parsed: $TRANSCRIPT"
    turns_out="### Captain's recent words

(unavailable: $reason)"
  fi

  local block_file tmp kind
  block_file=$(mktemp "$DATA/.session-handoff-block.XXXXXX" 2>/dev/null) \
    || step_aside "cannot create a temporary file in $DATA"
  {
    printf '%s\n' "$BEGIN_MARK"
    printf '## Pre-compaction snapshot\n\n'
    case "$TRIGGER" in
      auto) kind='an automatic' ;;
      manual) kind='a manual (/compact)' ;;
      *) kind="a ($TRIGGER)" ;;
    esac
    printf 'Written automatically at %s just before %s compaction (session %s).\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "${SESSION_ID:-unknown}"
    printf 'The captain'"'"'s words below are verbatim and outrank any summary of them.\n'
    printf 'The work state is a snapshot from that moment: re-verify it live before acting.\n'
    printf 'Full pre-compaction transcript: %s\n\n' "${TRANSCRIPT:-unknown}"
    if [ -n "$custom" ]; then
      printf '### Compaction instructions\n\n'
      printf '%s\n' "$custom" | sed 's/<!--/<! --/g; s/^/> /'
      printf '\n'
    fi
    printf '%s\n\n' "$turns_out"
    printf '### Open work at compaction\n\n'
    printf 'Identifiers only: the compact digest reprints each item'"'"'s state from its record.\n\n'
    printf 'Held backlog items (captain decisions and external waits):\n\n'
    render_holds
    printf '\nTask records:\n\n'
    render_workers
    printf '%s\n' "$END_MARK"
  } > "$block_file" 2>/dev/null || {
    rm -f "$block_file" 2>/dev/null || true
    step_aside "cannot write the snapshot in $DATA"
  }

  tmp=$(mktemp "$DATA/.session-handoff.XXXXXX" 2>/dev/null) || {
    rm -f "$block_file" 2>/dev/null || true
    step_aside "cannot create a temporary file in $DATA"
  }
  local merged=1
  if [ -f "$HANDOFF" ] && grep -qxF "$BEGIN_MARK" "$HANDOFF" 2>/dev/null \
    && grep -qxF "$END_MARK" "$HANDOFF" 2>/dev/null; then
    # Replace the first owned block in place; everything around it stays.
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v block="$block_file" '
      !done && !inside && $0 == begin {
        while ((getline line < block) > 0) print line
        inside = 1
        next
      }
      inside { if ($0 == end) { inside = 0; done = 1 } ; next }
      { print }
    ' "$HANDOFF" > "$tmp" 2>/dev/null || merged=0
  elif [ -f "$HANDOFF" ]; then
    { cat "$HANDOFF"; printf '\n'; cat "$block_file"; } > "$tmp" 2>/dev/null || merged=0
  else
    cat "$block_file" > "$tmp" 2>/dev/null || merged=0
  fi
  rm -f "$block_file" 2>/dev/null || true
  if [ "$merged" -eq 1 ] && mv -f "$tmp" "$HANDOFF" 2>/dev/null; then
    write_result "$status" "${turns:-0}" "$reason"
    exit 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  step_aside "cannot replace $HANDOFF"
}

# The subshell is the never-block guarantee: any failure inside it, including
# an unbound variable, ends only the subshell, and this process still exits 0.
( main "$@" )
exit 0
