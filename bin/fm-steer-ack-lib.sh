#!/usr/bin/env bash
# fm-steer-ack-lib.sh - durable acknowledgment records for token-marked steers.
#
# Why: a steer can submit cleanly (the composer verification layers prove
# SUBMISSION) and still never be processed into a turn by the worker - the
# 2026-08-20 incident had a rebase order exit 0, the pane read busy from the
# worker's own unrelated recap, and the order sat unprocessed for 15 minutes
# while supervision reported the work as under way. This library closes that
# gap with an opt-in acknowledgment contract:
#
#   1. fm-send.sh --ack prefixes the outbound order with a visible
#      "[ack=<token>]" mark and arms one durable record BEFORE submitting;
#      a failed or unconfirmed submit discards the record so transport failure
#      (already a loud fm-send error) never masquerades as a missed ack.
#   2. The generated brief scaffold (bin/fm-brief.sh) teaches ship and scout
#      workers to append `resolved [key=ack-<token>]: starting <restatement>`
#      to their status file as the FIRST action on receiving a token-marked
#      order, consistent with fm-classify-lib.sh's keyed status grammar.
#   3. The watcher's fm_steer_ack_tick clears a record as soon as ANY status
#      line for the task carries the token ("[key=ack-<token>]" or
#      "[ack=<token>]" - any quoted sighting proves the worker saw the order),
#      and past the acknowledgment window queues exactly one durable
#      actionable check wake naming the task and token. The wake is enqueued
#      BEFORE the record is marked escalated (enqueue-before-suppress), so a
#      watcher crash between the two can at worst duplicate the wake, never
#      lose it; the queue's kind+key dedup absorbs the duplicate.
#   4. Teardown clears a task's leftover records via fm_steer_ack_clear_task,
#      and the tick removes orphaned records whose task meta is gone.
#
# Record location: state/pending-acks/<task>.<token>, one key=value file per
# order, mode 0600 in a 0700 directory. Schema:
#   schema=fm-steer-ack.v1
#   task=            task id in this home (authoritative; never parsed from the filename)
#   token=           8 lowercase hex chars
#   sent_epoch=      when the record was armed (window counts from here)
#   window_secs=     acknowledgment window bound at arm time
#   summary=         short sanitized order summary
#   escalated_epoch= empty until the one no-ack wake has been queued
#
# Mutation boundary: records are written only by fm-send's --ack path (a steer,
# which a lock-refused session must never perform), the watcher singleton's
# tick, and teardown's task cleanup. Session start and every other read-only
# path never touch them.
#
# fm_steer_ack_tick requires fm_wake_append from bin/fm-wake-lib.sh in the
# calling environment; the watcher loads it via fm-push-transition-lib.sh and
# tests source fm-wake-lib.sh alongside this file.
#
# Tunables (env):
#   FM_STEER_ACK_WINDOW_SECS  acknowledgment window in seconds (default 180)
#   FM_STEER_ACK_TOKEN        fixed token for the next fm-send --ack (tests)
#   FM_STEER_ACK_NOW          fixed epoch for deterministic tests
#
# Sourced by bin/fm-send.sh, bin/fm-watch.sh, bin/fm-teardown.sh, and tests.
# No side effects on source. set -u / set -e safe.

FM_STEER_ACK_SCHEMA='fm-steer-ack.v1'
FM_STEER_ACK_WINDOW_DEFAULT=180

fm_steer_ack_now() {
  if [ -n "${FM_STEER_ACK_NOW:-}" ]; then
    printf '%s' "$FM_STEER_ACK_NOW"
    return 0
  fi
  date +%s
}

fm_steer_ack_window_secs() {
  local w=${FM_STEER_ACK_WINDOW_SECS:-$FM_STEER_ACK_WINDOW_DEFAULT}
  case "$w" in
    ''|*[!0-9]*) w=$FM_STEER_ACK_WINDOW_DEFAULT ;;
  esac
  printf '%s' "$w"
}

# Directory holding durable steer-ack records for <state-dir>.
fm_steer_ack_dir() {  # <state-dir>
  printf '%s/pending-acks' "$1"
}

fm_steer_ack_path() {  # <state-dir> <task> <token>
  printf '%s/%s.%s' "$(fm_steer_ack_dir "$1")" "$2" "$3"
}

# 8 lowercase hex chars: short enough to restate by hand, unique enough for the
# handful of orders ever pending at once.
fm_steer_ack_new_token() {
  local raw=
  if command -v openssl >/dev/null 2>&1; then
    raw=$(openssl rand -hex 4 2>/dev/null || true)
  fi
  if [ -z "$raw" ]; then
    raw=$(printf '%s' "$$-$(date +%s%N 2>/dev/null || date +%s)-$RANDOM$RANDOM" \
      | shasum -a 256 2>/dev/null | awk '{print $1}')
  fi
  printf '%s' "$raw" | tr 'A-F' 'a-f' | tr -cd 'a-f0-9' | cut -c1-8
}

fm_steer_ack_token_valid() {  # <token>
  printf '%s' "$1" | grep -qE '^[a-f0-9]{8}$'
}

# The visible mark prefixed to a token-carrying order.
fm_steer_ack_mark() {  # <token>
  printf '[ack=%s]' "$1"
}

fm_steer_ack_get() {  # <record-path> <key>
  local rec=$1 key=$2
  [ -f "$rec" ] || return 0
  grep "^${key}=" "$rec" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Sanitize a short order summary: single line, printable, bounded.
fm_steer_ack_summarize() {  # <text>
  local cleaned
  cleaned=$(printf '%s' "$1" | tr '\t\r\n' '   ' | tr -cd '\40-\176' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ "${#cleaned}" -gt 120 ]; then
    cleaned="${cleaned:0:117}..."
  fi
  printf '%s' "$cleaned"
}

# Arm (or atomically re-arm, restarting the window) one durable record.
fm_steer_ack_arm() {  # <state-dir> <task> <token> <order-text>
  local state=$1 task=$2 token=$3 text=$4 dir rec tmp now
  [ -n "$state" ] && [ -n "$task" ] || return 2
  fm_steer_ack_token_valid "$token" || return 2
  dir=$(fm_steer_ack_dir "$state")
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  rec=$(fm_steer_ack_path "$state" "$task" "$token")
  now=$(fm_steer_ack_now)
  tmp="$dir/.$task.$token.tmp.$$"
  cat > "$tmp" <<EOF
schema=$FM_STEER_ACK_SCHEMA
task=$task
token=$token
sent_epoch=$now
window_secs=$(fm_steer_ack_window_secs)
summary=$(fm_steer_ack_summarize "$text")
escalated_epoch=
EOF
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$rec"
}

# Drop a record after a failed or unconfirmed send: the loud fm-send error
# already owns that failure, so it must not later fire as a missed ack.
fm_steer_ack_discard() {  # <state-dir> <task> <token>
  local rec
  rec=$(fm_steer_ack_path "$1" "$2" "$3")
  rm -f "$rec"
}

# 0 if any status line carries the ack token, in the taught keyed form
# ("[key=ack-<token>]") or the raw mark ("[ack=<token>]"). Any sighting is
# proof the worker saw the order - a worker quoting the mark inside a blocked:
# line has still demonstrably received it. Repeated ack lines are naturally
# safe: there is one record and one removal.
fm_steer_ack_status_has_ack() {  # <status-file> <token>
  local f=$1 token=$2
  [ -f "$f" ] || return 1
  fm_steer_ack_token_valid "$token" || return 1
  grep -qE "\[key=ack-${token}\]|\[ack=${token}\]" "$f" 2>/dev/null
}

# One reconciliation pass over every record. Requires fm_wake_append (see
# header). For each record: an acked or orphaned (task meta gone) record is
# removed; an unacknowledged record past its window gets exactly one durable
# actionable check wake, enqueued before the record is marked escalated, and
# its reason line is printed for the caller to surface. A record inside its
# window, already escalated, or unreadable is preserved untouched. Cheap when
# no records exist. Returns non-zero only when a due wake could not be durably
# enqueued.
fm_steer_ack_tick() {  # <state-dir>
  local state=$1 dir rec task token sent window escalated now age reason
  dir=$(fm_steer_ack_dir "$state")
  [ -d "$dir" ] || return 0
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    case "$(basename "$rec")" in
      .*) continue ;;
    esac
    task=$(fm_steer_ack_get "$rec" task)
    token=$(fm_steer_ack_get "$rec" token)
    if [ -z "$task" ] || ! fm_steer_ack_token_valid "$token"; then
      # Only manual tampering produces this (arm writes are atomic); preserve
      # for inspection rather than silently deleting or guessing.
      continue
    fi
    if [ ! -f "$state/$task.meta" ]; then
      rm -f "$rec"
      continue
    fi
    if fm_steer_ack_status_has_ack "$state/$task.status" "$token"; then
      rm -f "$rec"
      continue
    fi
    escalated=$(fm_steer_ack_get "$rec" escalated_epoch)
    [ -z "$escalated" ] || continue
    sent=$(fm_steer_ack_get "$rec" sent_epoch)
    case "$sent" in ''|*[!0-9]*) continue ;; esac
    window=$(fm_steer_ack_get "$rec" window_secs)
    case "$window" in ''|*[!0-9]*) window=$(fm_steer_ack_window_secs) ;; esac
    now=$(fm_steer_ack_now)
    age=$((now - sent))
    [ "$age" -ge "$window" ] || continue
    reason="check: steer-ack: $task order [ack=$token] unacknowledged for ${age}s (window ${window}s) - the worker may not have processed the steer; inspect its pane and re-issue if needed"
    fm_wake_append check "steer-ack-$task-$token" "$reason" || return 1
    printf 'escalated_epoch=%s\n' "$now" >> "$rec"
    printf '%s\n' "$reason"
  done
  return 0
}

# Remove every record belonging to <task> (teardown cleanup). Matches on the
# record's own task field, never the filename, so a task id containing dots
# cannot claim a sibling's records.
fm_steer_ack_clear_task() {  # <state-dir> <task>
  local state=$1 task=$2 dir rec
  dir=$(fm_steer_ack_dir "$state")
  [ -d "$dir" ] || return 0
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    [ "$(fm_steer_ack_get "$rec" task)" = "$task" ] || continue
    rm -f "$rec"
  done
  rmdir "$dir" 2>/dev/null || true
  return 0
}
