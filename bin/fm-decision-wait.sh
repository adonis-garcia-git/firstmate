#!/usr/bin/env bash
# fm-decision-wait.sh - age-in-waiting tracking for captain-gated decisions.
#
# Work parks on captain-kind backlog holds and unresolved needs-decision status
# lines for days while nothing measures the wait. This script owns the durable
# first-observed record of those waits and the ranked read views built on it;
# bin/fm-watch.sh paces the once-daily digest wake on top of `digest`.
#
# A wait exists while either source is open:
#   - a backlog item carries an active captain-kind hold (held=yes,
#     hold_kind=captain; tasks-axi owns the backlog schema), wait id
#     "hold:<item-id>"; or
#   - a task's status stream has an open needs-decision per the keyed status
#     fold owned by bin/fm-classify-lib.sh's status_open_decisions, wait id
#     "status:<task-id>:<key>". A non-secondmate task whose LAST status verb is
#     done or failed is treated as ended (the same rule as fm-decision-hold.sh's
#     origin_open_decisions), and teardown removes the status file, so ended
#     work drops out on the next reconcile.
#
# Neither source timestamps its own start, so the record is conservative: each
# line stores the FIRST time this script observed the wait, marked "observed",
# never a guessed older start. The record is <data>/decision-waits.tsv, one
#   <wait-id>\t<first-observed-epoch>\tobserved
# line per wait, reconciled on every command: new waits are added at the
# current time and waits whose source has cleared are dropped. When tasks-axi
# is unavailable, or a held listing or per-item read fails at runtime, recorded
# hold entries are preserved untouched (a tooling outage must not reset ages)
# and hold scanning is skipped with a stderr note.
# Rewrites are atomic (tmp + mv); a concurrent reconcile is benign because the
# next run converges and a lost first-observation can only make an age younger,
# never older. A home whose data directory does not exist is skipped silently
# without creating it: there is nothing to track and nothing to write.
#
# "Blocks" counts the work a decision is holding up, for ranking:
#   - every queued or in_flight backlog item whose blocked_by contains the
#     held item id (hold waits) or the parked task id (status waits);
#   - the held item itself when it is in_flight (live work parked on its own
#     hold), and the hold's recorded "Origin:" task or a status wait's own
#     task when live work exists for it (state/<id>.meta present).
#
# Usage:
#   fm-decision-wait.sh scan
#   fm-decision-wait.sh list
#   fm-decision-wait.sh digest
#
# `scan` reconciles the record and prints "scan: <n> waiting".
# `list` reconciles, then prints one ranked TAB-separated row per wait:
#   <wait-id> <first-observed-epoch> <age-seconds> <blocks-count> <blocks-csv> <summary>
# with blocks-csv "-" when nothing is blocked. Rows are sorted by unblocking
# power (blocks-count desc), then age desc, then wait id, so a downstream
# consumer (e.g. helm) can take rows in order.
# `digest` reconciles, then prints ONE line ranking the top 3 unblockers, or
# prints nothing at all when no wait exists (the watcher's quiet-by-design
# gate). Ages are rendered with a trailing "+" because first-observed is a
# lower bound on the true wait.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

RECORD="$DATA/decision-waits.tsv"
TAB=$(printf '\t')

TMP_RECORD=''
trap '[ -z "$TMP_RECORD" ] || rm -f "$TMP_RECORD"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

holds_available() {
  command -v tasks-axi >/dev/null 2>&1 && fm_tasks_axi_compatible
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

list_has_id() {  # <comma-list> <id>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Backlog item ids for one tasks-axi list state, one per line. Rows are the
# only lines shaped "  <slug>,..."; count/help lines never match. Fails when
# the listing itself fails, so a runtime tasks-axi error is distinguishable
# from a genuinely empty state.
list_ids() {  # <state>
  local out
  out=$(tasks_axi list --state "$1" 2>/dev/null) || return 1
  printf '%s\n' "$out" | sed -n 's/^  \([A-Za-z0-9._-]\{1,\}\),.*/\1/p'
}

# One "hold:<id>\t<summary>\t<state>\t<origin>" line per active captain-kind
# hold among the given held ids. origin is the fm-decision-hold "Origin:" slug
# when present, else "-". Fails when any per-item read fails, so the caller
# preserves recorded entries instead of dropping the unreadable hold.
current_hold_waits() {  # <held-ids, one per line>
  local id show held hold_kind state title origin
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    show=$(task_show "$id") || return 1
    held=$(show_field "$show" held)
    hold_kind=$(show_field "$show" hold_kind)
    state=$(show_field "$show" state)
    [ "$held" = yes ] || continue
    [ "$hold_kind" = captain ] || continue
    [ "$state" != "done" ] || continue
    # tasks-axi quotes a title containing commas; strip the outer quotes.
    title=$(show_field "$show" title | tr '\t' ' ')
    case "$title" in
      \"*\") title=${title#\"}; title=${title%\"} ;;
    esac
    origin=$(show_field "$show" body | sed -n 's/.*Origin: \([A-Za-z0-9._-]\{1,\}\).*/\1/p' | head -1)
    [ -n "$origin" ] || origin='-'
    printf 'hold:%s\t%s\t%s\t%s\n' "$id" "$title" "$state" "$origin"
  done <<EOF
$1
EOF
}

# One "status:<task>:<key>\t<summary>\t-\t<task>" line per open needs-decision
# in the keyed status fold. Ended non-secondmate tasks (last verb done/failed)
# are skipped, mirroring fm-decision-hold.sh's origin_open_decisions exactly:
# a task with no .meta file skips the ended check and stays open.
current_status_waits() {
  local f id kind last verb open key v note
  for f in "$STATE"/*.status; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .status)
    open=$(status_open_decisions "$f")
    [ -n "$open" ] || continue
    if [ -f "$STATE/$id.meta" ]; then
      kind=$(meta_value "$STATE/$id.meta" kind)
      [ -n "$kind" ] || kind=ship
      if [ "$kind" != secondmate ]; then
        last=$(last_status_line "$f")
        verb=$(status_line_verb "$last")
        case "$verb" in done|failed) continue ;; esac
      fi
    fi
    while IFS=$TAB read -r key v note; do
      [ -n "$key" ] || continue
      [ "$v" = needs-decision ] || continue
      printf 'status:%s:%s\t%s\t-\t%s\n' "$id" "$key" "$(printf '%s' "$note" | tr '\t' ' ')" "$id"
    done <<EOF
$open
EOF
  done
}

record_epoch() {  # <wait-id> -> recorded epoch, or nothing
  [ -f "$RECORD" ] || return 0
  awk -F '\t' -v id="$1" '$1 == id && $2 ~ /^[0-9]+$/ { print $2; exit }' "$RECORD"
}

# Reconcile the durable record with the currently waiting decisions.
# Sets CURRENT_WAITS ("<wait-id>\t<summary>\t<state>\t<origin>" lines),
# HOLDS_SCANNED (1/0), and rewrites RECORD atomically.
reconcile() {
  local now holds='' held_ids='' line wid epoch
  now=$(date +%s)
  mkdir -p "$DATA"
  HOLDS_SCANNED=1
  if ! holds_available; then
    HOLDS_SCANNED=0
    printf 'fm-decision-wait: tasks-axi unavailable; backlog captain holds not scanned\n' >&2
  elif ! { held_ids=$(list_ids held) && holds=$(current_hold_waits "$held_ids"); }; then
    HOLDS_SCANNED=0
    holds=''
    printf 'fm-decision-wait: tasks-axi held read failed; backlog captain holds not scanned\n' >&2
  fi
  CURRENT_WAITS=$(printf '%s\n%s\n' "$holds" "$(current_status_waits)" | sed '/^$/d')
  find "$DATA" -maxdepth 1 -name '.decision-waits.*' -type f -mmin +60 -delete 2>/dev/null || true
  TMP_RECORD=$(mktemp "$DATA/.decision-waits.XXXXXX")
  {
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      wid=${line%%"$TAB"*}
      epoch=$(record_epoch "$wid")
      [ -n "$epoch" ] || epoch=$now
      printf '%s\t%s\tobserved\n' "$wid" "$epoch"
    done <<EOF
$CURRENT_WAITS
EOF
    # A tooling outage must not reset hold ages: carry the recorded hold
    # entries through untouched when the backlog could not be scanned.
    if [ "$HOLDS_SCANNED" = 0 ] && [ -f "$RECORD" ]; then
      grep '^hold:' "$RECORD" || true
    fi
  } | LC_ALL=C sort -u > "$TMP_RECORD"
  mv "$TMP_RECORD" "$RECORD"
  TMP_RECORD=''
}

# All queued/in_flight backlog items with their dependency edges, one
# "<item-id>\t<item-state>\t<blocked_by-csv>" line each. Empty when tasks-axi
# is unavailable, which degrades blocks counts to parked-work-only.
backlog_edges() {
  local ids id show state blocked
  [ "$HOLDS_SCANNED" = 1 ] || return 0
  ids=$( { list_ids queued; list_ids in_flight; list_ids held; } | LC_ALL=C sort -u )
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    show=$(task_show "$id") || continue
    state=$(show_field "$show" state)
    case "$state" in queued|in_flight) ;; *) continue ;; esac
    # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so ids match.
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]"')
    printf '%s\t%s\t%s\n' "$id" "$state" "$blocked"
  done <<EOF
$ids
EOF
}

# Unique comma-joined ids blocked by one wait (see header for the definition),
# or "-" when none.
wait_blocks() {  # <wait-id> <wait-state> <origin> <edges>
  local wid=$1 wstate=$2 origin=$3 edges=$4 target out='' id state blocked
  case "$wid" in
    hold:*) target=${wid#hold:} ;;
    status:*) target=${wid#status:}; target=${target%%:*} ;;
    *) printf -- '-'; return 0 ;;
  esac
  while IFS=$TAB read -r id state blocked; do
    [ -n "$id" ] || continue
    [ "$id" != "$target" ] || continue
    list_has_id "$blocked" "$target" || continue
    list_has_id "$out" "$id" || out="${out}${out:+,}$id"
  done <<EOF
$edges
EOF
  if [ "$wstate" = in_flight ] && ! list_has_id "$out" "$target"; then
    out="${out}${out:+,}$target"
  fi
  for id in "$origin" "$target"; do
    [ -n "$id" ] && [ "$id" != '-' ] || continue
    [ -f "$STATE/$id.meta" ] || continue
    list_has_id "$out" "$id" || out="${out}${out:+,}$id"
  done
  printf '%s' "${out:--}"
}

blocks_count() {  # <blocks-csv-or-dash>
  if [ "$1" = '-' ]; then
    printf '0'
  else
    printf '%s' "$1" | awk -F ',' '{ print NF }'
  fi
}

# Ranked rows: <blocks-count>\t<age>\t<wait-id>\t<epoch>\t<blocks-csv>\t<summary>,
# unblocking power first, then oldest, then wait id for determinism.
ranked_rows() {
  local now edges line wid summary wstate origin epoch age blocks count
  now=$(date +%s)
  edges=$(backlog_edges)
  while IFS=$TAB read -r wid summary wstate origin; do
    [ -n "$wid" ] || continue
    epoch=$(record_epoch "$wid")
    [ -n "$epoch" ] || epoch=$now
    age=$(( now - epoch ))
    [ "$age" -ge 0 ] || age=0
    blocks=$(wait_blocks "$wid" "$wstate" "$origin" "$edges")
    count=$(blocks_count "$blocks")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$count" "$age" "$wid" "$epoch" "$blocks" "$summary"
  done <<EOF
$CURRENT_WAITS
EOF
}

human_age() {  # <seconds>
  local s=$1
  if [ "$s" -ge 86400 ]; then
    printf '%sd' $(( s / 86400 ))
  elif [ "$s" -ge 3600 ]; then
    printf '%sh' $(( s / 3600 ))
  else
    printf '%sm' $(( s / 60 ))
  fi
}

wait_count() {
  [ -n "$CURRENT_WAITS" ] || { printf '0'; return; }
  printf '%s\n' "$CURRENT_WAITS" | sed '/^$/d' | wc -l | tr -d ' '
}

command_scan() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  reconcile
  printf 'scan: %s waiting\n' "$(wait_count)"
}

command_list() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  reconcile
  [ -n "$CURRENT_WAITS" ] || return 0
  ranked_rows \
    | LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2nr -k3,3 \
    | awk -F '\t' '{ printf "%s\t%s\t%s\t%s\t%s\t%s\n", $3, $4, $2, $1, $5, $6 }'
}

command_digest() {
  local count rank=0 c age wid epoch blocks summary tops=''
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  reconcile
  count=$(wait_count)
  [ "$count" -gt 0 ] || return 0
  while IFS=$TAB read -r c age wid epoch blocks summary; do
    [ -n "$wid" ] || continue
    rank=$(( rank + 1 ))
    [ "$rank" -le 3 ] || break
    summary=$(printf '%.80s' "$summary")
    tops="${tops}${tops:+; }${rank}) $wid waiting $(human_age "$age")+ blocks $c: $summary"
  done <<EOF
$(ranked_rows | LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2nr -k3,3)
EOF
  printf '%s captain decisions waiting; top unblockers: %s\n' "$count" "$tops"
}

# A home without a data directory has no backlog and no fleet records, so
# there is nothing to track and nothing to write: stay silent and inert
# rather than materializing data/ as a side effect (this also keeps
# state-only test homes untouched when their watcher sweeps run).
require_home_data() {
  [ -d "$DATA" ] && return 0
  printf 'fm-decision-wait: no data directory at %s; nothing to track\n' "$DATA" >&2
  return 1
}

case "${1:-}" in
  scan) shift; require_home_data || exit 0; command_scan "$@" ;;
  list) shift; require_home_data || exit 0; command_list "$@" ;;
  digest) shift; require_home_data || exit 0; command_digest "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
