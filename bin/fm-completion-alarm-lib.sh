#!/usr/bin/env bash
# fm-completion-alarm-lib.sh - durable completion-alarm records for
# terminal-but-unsurfaced workers.
#
# Why: a worker can reach done: (or park at a gate) and the supervising
# firstmate session can still never learn about it - twice on 2026-08-23/24
# the captain caught a finished-and-parked worker before firstmate did.
# The done-status append's own wake can be lost or collapsed before it
# reaches a session, and once the watcher chain has lapsed nothing surfaces
# completions at all. This library is the completion analog of the steer-ack
# contract (bin/fm-steer-ack-lib.sh solves the same problem for dropped
# orders): a truth-based detector with a durable record and exactly one
# actionable escalation per completion episode. It is distinct from
# bin/fm-inactive-reconcile.sh, which owns much-longer-inactivity terminal
# OUTCOME receipts for done/failed only; this alarm owns the fast surfacing
# window and also covers parked and blocked.
#
#   1. The watcher's fm_completion_alarm_tick reconciles every live
#      non-secondmate task's CURRENT state through bin/fm-crew-state.sh
#      (FM_CREW_STATE_BIN), never the status log's last line alone, so a
#      completion whose log still shows a stale working: line is detected and
#      a resolved needs-decision whose log still shows the old verb is not.
#   2. A reconciled state that is terminal for the supervisor - done, failed,
#      parked (needs-decision or a run gate), or blocked - arms one durable
#      record stamping the state and first-observed epoch. A task whose
#      endpoint is provably busy (fm_busy_classify_meta reports the exact
#      busy verdict) is skipped and its record dropped: a busy worker is
#      mid-turn on that very state (e.g. composing a gate response), so it is
#      being actively worked, not sitting unsurfaced.
#   3. Once the same terminal state has persisted past the window
#      (FM_COMPLETION_ALARM_WINDOW_SECS, default 90), the tick queues exactly
#      one durable actionable check wake naming the task and state. The wake
#      is enqueued BEFORE the record is marked escalated
#      (enqueue-before-suppress), so a watcher crash between the two can at
#      worst duplicate the wake, never lose it. Because the record and the
#      scan are durable and truth-based, a completion that happened while no
#      watcher was running still alarms: the first healthy cycle observes it,
#      and a record already past its window escalates on that first cycle.
#   4. The record IS the completion episode, and escalated_epoch is therefore
#      scoped to exactly one episode rather than to the worker. An episode is
#      identified by its terminal state AND the branch head commit the worker
#      completed on (episode=), which is what makes two episodes that share a
#      state value distinguishable: reaching a run's approval gate and then its
#      fix_review gate both reconcile as `parked`, but the fix step commits in
#      between, so the heads differ and the second gate is a new episode that
#      alarms on its own merits. Crucially that identity is read at completion
#      time and does NOT depend on having observed the intervening working
#      window - the observation this alarm exists because it cannot rely on.
#      A reconciled completion whose identity differs from the record's re-arms
#      the alarm; an identical one stays suppressed. Both directions follow: no
#      second wake inside one episode, and no episode suppressed by an earlier
#      one. When no head can be derived the identity is empty and comparison
#      falls back to the state value alone, which is the only safe degenerate
#      behaviour: re-arming on every unidentifiable sighting would reset the
#      window forever and never alarm at all. In practice a task that
#      reconciles terminal always has a readable worktree, because one that
#      does not reconciles as unknown and is not terminal.
#   5. Clearing is truth-based too: the record is dropped as soon as the task
#      leaves the terminal state (the worker resumed, the decision was
#      answered), its meta is gone, or teardown runs
#      (fm_completion_alarm_clear_task). A busy endpoint drops a record that
#      has not escalated yet - detection is merely deferred and no wake is at
#      stake - but a record that HAS escalated is neither dropped (its one-shot
#      stamp would go with it, so a busy flap could re-nag one episode) nor
#      held blind (the episode's end would go unobserved, so a later genuine
#      completion could never alarm): it reconciles like any other. A NEW
#      terminal state (parked -> done) restarts the episode and may alarm
#      again; the same state never re-nags. A done task whose merge poll is
#      armed (state/<id>.pr-poll,
#      written by bin/fm-pr-check.sh) is already being actively landed, so it
#      is held without escalating while the poll exists.
#      Only a SUCCESSFUL reconciliation read may change a record: the reader
#      exits 0 with a `state: unknown` verdict whenever it merely cannot
#      attribute a state, so a non-zero exit or a non-`state:` line is a
#      READER failure and leaves any record untouched (no arm, no discard, no
#      escalation) rather than silently restarting the episode window.
#   6. Never armed for kind=secondmate (an idle secondmate is healthy and its
#      routed status stream has its own delivery contract), and never for a
#      declared paused: external wait (fm-crew-state.sh reports paused, which
#      is not in the terminal set).
#
# Record location: state/pending-completions/<task>, one key=value file per
# task, mode 0600 in a 0700 directory. Schema:
#   schema=fm-completion-alarm.v1
#   task=            task id in this home
#   state=           terminal state at first observation (done|failed|parked|blocked)
#   episode=         branch head commit this episode completed on; empty when
#                    it could not be derived
#   detail=          short sanitized crew-state detail for the wake reason
#   first_epoch=     when this state was first observed (window counts from here)
#   window_secs=     alarm window bound at arm time
#   escalated_epoch= empty until THIS episode's one alarm wake has been queued
#
# Beside the records, `.scan-cursor` holds the id of the last task a truncated
# sweep reconciled, so the next sweep resumes after it instead of restarting at
# the same head. It is dot-prefixed, so the orphan sweep ignores it, and a
# sweep that completes a full pass removes it.
#
# Mutation boundary: records are written only by the watcher singleton's tick
# and removed by that tick or teardown's task cleanup. Session start and every
# other read-only path never touch them.
#
# fm_completion_alarm_tick requires fm_wake_append from bin/fm-wake-lib.sh and
# fm_run_timed from bin/fm-timeout-lib.sh in the calling environment; the
# watcher loads both via fm-push-transition-lib.sh and tests source them
# alongside this file. fm_run_timed hard-bounds each reconciliation read
# (FM_COMPLETION_READ_TIMEOUT_SECS, default 20), because fm-crew-state.sh
# bounds only its own no-mistakes calls, not its tmux or git reads, and one
# wedged read inside the watcher's synchronous poll loop would otherwise stop
# the heartbeat and read as a lapsed watcher. A read that hits the bound is
# treated exactly like any other failed read: the record is left untouched.
# When fm_busy_classify_meta (bin/fm-busy-lib.sh) is defined in the caller, its
# exact busy verdict defers detection; absent, no verdict is busy and
# detection proceeds (surface bias, matching the watcher's
# absorb-only-when-provably-working rule).
#
# One sweep runs synchronously inside the watcher's poll loop and spends a
# bounded but non-trivial reconciliation read per task, so it also carries a
# wall-clock budget (FM_COMPLETION_SCAN_BUDGET_SECS, default 30, below the
# watcher's 45s scan pacing): every sweep reconciles at least one task so it
# always makes progress, then stops taking on new ones once the budget is
# spent. The budget alone bounds only how many reads a sweep STARTS, so it is
# paired with the per-read bound above; together they cap one sweep at the
# budget plus one read, which is what actually keeps a slow or wedged reader
# from holding the watcher off its ordinary surfacing cadence. Sweeps RESUME
# where the last truncated one
# stopped and wrap around, so the bound defers a task rather than starving it:
# even against a persistently slow reader every task is reconciled within a
# bounded number of sweeps. Records are durable, so a deferred tail keeps its
# window and its stamp.
#
# Tunables (env):
#   FM_COMPLETION_ALARM_WINDOW_SECS  alarm window in seconds (default 90)
#   FM_COMPLETION_SCAN_BUDGET_SECS   per-sweep wall-clock budget (default 30,
#                                    0 disables the bound)
#   FM_COMPLETION_READ_TIMEOUT_SECS  hard bound on ONE reconciliation read
#                                    (default 20, 0 disables the bound)
#   FM_COMPLETION_ALARM_NOW          fixed epoch for deterministic tests
#   FM_CREW_STATE_BIN                current-state reader override (tests)
#
# Sourced by bin/fm-watch.sh, bin/fm-teardown.sh, and tests.
# No side effects on source. set -u / set -e safe.

FM_COMPLETION_ALARM_SCHEMA='fm-completion-alarm.v1'
FM_COMPLETION_ALARM_WINDOW_DEFAULT=90
FM_COMPLETION_SCAN_BUDGET_DEFAULT=30
FM_COMPLETION_READ_TIMEOUT_DEFAULT=20

# The crew current-state reader, resolved exactly as bin/fm-classify-lib.sh
# resolves it, so a caller that already sourced that library (the watcher)
# and a test that sources only this one agree on the seam.
_FM_COMPLETION_ALARM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_COMPLETION_ALARM_LIB_DIR="."
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_COMPLETION_ALARM_LIB_DIR/fm-crew-state.sh}"

fm_completion_alarm_now() {
  if [ -n "${FM_COMPLETION_ALARM_NOW:-}" ]; then
    printf '%s' "$FM_COMPLETION_ALARM_NOW"
    return 0
  fi
  date +%s
}

fm_completion_alarm_window_secs() {
  local w=${FM_COMPLETION_ALARM_WINDOW_SECS:-$FM_COMPLETION_ALARM_WINDOW_DEFAULT}
  case "$w" in
    ''|*[!0-9]*) w=$FM_COMPLETION_ALARM_WINDOW_DEFAULT ;;
  esac
  printf '%s' "$w"
}

# Wall-clock seconds one sweep may spend before it defers its remaining tasks
# to the next sweep. 0 means unbounded.
fm_completion_alarm_budget_secs() {
  local b=${FM_COMPLETION_SCAN_BUDGET_SECS:-$FM_COMPLETION_SCAN_BUDGET_DEFAULT}
  case "$b" in
    ''|*[!0-9]*) b=$FM_COMPLETION_SCAN_BUDGET_DEFAULT ;;
  esac
  printf '%s' "$b"
}

# Hard bound on ONE reconciliation read. 0 means unbounded.
fm_completion_alarm_read_timeout_secs() {
  local t=${FM_COMPLETION_READ_TIMEOUT_SECS:-$FM_COMPLETION_READ_TIMEOUT_DEFAULT}
  case "$t" in
    ''|*[!0-9]*) t=$FM_COMPLETION_READ_TIMEOUT_DEFAULT ;;
  esac
  printf '%s' "$t"
}

# The identity of the completion episode <task> is currently in: the branch
# head commit it completed on. It advances whenever the worker or a pipeline
# fix step commits, so two completions separated by real work never share one,
# and it is readable at completion time without having watched the interval
# between them. Empty when no head can be derived.
fm_completion_alarm_episode() {  # <state-dir> <task>
  local wt
  wt=$(grep '^worktree=' "$1/$2.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$wt" ] || return 0
  [ -d "$wt" ] || return 0
  git -C "$wt" rev-parse HEAD 2>/dev/null || true
}

# Directory holding durable completion-alarm records for <state-dir>.
fm_completion_alarm_dir() {  # <state-dir>
  printf '%s/pending-completions' "$1"
}

fm_completion_alarm_path() {  # <state-dir> <task>
  printf '%s/%s' "$(fm_completion_alarm_dir "$1")" "$2"
}

fm_completion_alarm_get() {  # <record-path> <key>
  local rec=$1 key=$2
  [ -f "$rec" ] || return 0
  grep "^${key}=" "$rec" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Sanitize a short detail line: single line, printable, bounded.
fm_completion_alarm_sanitize() {  # <text>
  local cleaned
  cleaned=$(printf '%s' "$1" | tr '\t\r\n' '   ' | tr -cd '\40-\176' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ "${#cleaned}" -gt 120 ]; then
    cleaned="${cleaned:0:117}..."
  fi
  printf '%s' "$cleaned"
}

# Arm (or atomically restart, for a NEW episode) one durable record.
fm_completion_alarm_arm() {  # <state-dir> <task> <terminal-state> <detail> [episode]
  local state=$1 task=$2 tstate=$3 detail=$4 episode=${5:-} dir rec tmp now
  [ -n "$state" ] && [ -n "$task" ] && [ -n "$tstate" ] || return 2
  dir=$(fm_completion_alarm_dir "$state")
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  rec=$(fm_completion_alarm_path "$state" "$task")
  now=$(fm_completion_alarm_now)
  tmp="$dir/.$task.tmp.$$"
  cat > "$tmp" <<EOF
schema=$FM_COMPLETION_ALARM_SCHEMA
task=$task
state=$tstate
episode=$(fm_completion_alarm_sanitize "$episode")
detail=$(fm_completion_alarm_sanitize "$detail")
first_epoch=$now
window_secs=$(fm_completion_alarm_window_secs)
escalated_epoch=
EOF
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$rec"
}

# Drop a task's record: the task left the terminal state, turned busy, or is
# no longer eligible. Safe when no record exists.
fm_completion_alarm_discard() {  # <state-dir> <task>
  local rec
  rec=$(fm_completion_alarm_path "$1" "$2")
  rm -f "$rec"
}

# 0 iff <task> holds a record whose episode has already escalated, so dropping
# it would lose the one-shot stamp that keeps that episode from alarming twice.
_fm_completion_alarm_escalated() {  # <state-dir> <task>
  local rec
  rec=$(fm_completion_alarm_path "$1" "$2")
  [ -f "$rec" ] || return 1
  [ -n "$(fm_completion_alarm_get "$rec" escalated_epoch)" ]
}

# Remove the record belonging to <task> (teardown cleanup).
fm_completion_alarm_clear_task() {  # <state-dir> <task>
  local state=$1 task=$2 dir
  dir=$(fm_completion_alarm_dir "$state")
  [ -d "$dir" ] || return 0
  fm_completion_alarm_discard "$state" "$task"
  rmdir "$dir" 2>/dev/null || true
  return 0
}

# 0 iff <task>'s endpoint is PROVABLY busy per the semantic busy-state
# contract. Only the exact busy verdict returns 0; idle, unknown, dead, and a
# caller without fm_busy_classify_meta all return 1, so missing evidence
# surfaces rather than suppressing detection.
_fm_completion_alarm_busy() {  # <meta-file> <task> <state-dir>
  local verdict
  declare -F fm_busy_classify_meta >/dev/null 2>&1 || return 1
  verdict=$(fm_busy_classify_meta "$1" "$2" "$3" "") || return 1
  [ "${verdict%% *}" = busy ]
}

# One reconciliation pass over every live task. Requires fm_wake_append (see
# header). For each non-secondmate task with metadata: reconcile its current
# state through FM_CREW_STATE_BIN; a terminal state (done/failed/parked/
# blocked) on a not-provably-busy endpoint arms or ages the task's record,
# escalating exactly one durable actionable check wake once the SAME state has
# persisted past the window (enqueued before the record is marked escalated,
# and its reason printed for the caller to surface); any other state, a busy
# endpoint, or an armed done-state merge poll clears or holds the record
# without waking. Each read is hard-bounded, and a failed or timed-out
# reconciliation read leaves the task's record
# untouched; a busy endpoint never drops an already-escalated record and never
# skips reconciling one, so an episode boundary is never missed. Records whose
# task metadata is gone are removed. Tasks still unreconciled once the sweep's
# wall-clock budget is spent lead the next sweep, which resumes after the last
# task this one reconciled. Returns non-zero only when a due wake could not be
# durably enqueued.
fm_completion_alarm_tick() {  # <state-dir>
  local state=$1 dir rec meta task kind line st detail sep rec_state first window escalated now age reason budget started
  local metas total cursor_file cursor start truncated last i n read_timeout episode rec_episode
  sep=' · '
  # Orphan sweep first, so a record left behind by a missed teardown cannot
  # sit forever (its task no longer exists to reconcile).
  dir=$(fm_completion_alarm_dir "$state")
  if [ -d "$dir" ]; then
    for rec in "$dir"/*; do
      [ -f "$rec" ] || continue
      case "$(basename "$rec")" in
        .*) continue ;;
      esac
      task=$(fm_completion_alarm_get "$rec" task)
      # A record whose meta keys are gone (teardown removed it between the
      # tick's wake enqueue and its escalation stamp, and the stamp recreated
      # the file) still names its task by construction: the file name.
      [ -n "$task" ] || task=$(basename "$rec")
      [ -f "$state/$task.meta" ] || rm -f "$rec"
    done
  fi
  budget=$(fm_completion_alarm_budget_secs)
  read_timeout=$(fm_completion_alarm_read_timeout_secs)
  started=$(date +%s)
  metas=()
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    metas+=("$meta")
  done
  total=${#metas[@]}
  [ "$total" -gt 0 ] || return 0
  # Resume after the task the last truncated sweep stopped on, wrapping. A
  # fixed-order sweep that always restarts at the head would let a slow reader
  # starve the tail forever rather than merely defer it. A cursor naming a task
  # that no longer exists just falls back to the head.
  cursor_file="$dir/.scan-cursor"
  cursor=''
  if [ -f "$cursor_file" ]; then
    cursor=$(head -1 "$cursor_file" 2>/dev/null) || cursor=''
  fi
  start=0
  if [ -n "$cursor" ]; then
    for ((i = 0; i < total; i++)); do
      task=$(basename "${metas[$i]}")
      if [ "${task%.meta}" = "$cursor" ]; then
        start=$(( (i + 1) % total ))
        break
      fi
    done
  fi
  truncated=''
  last=''
  for ((n = 0; n < total; n++)); do
    meta=${metas[$(( (start + n) % total ))]}
    # This sweep runs synchronously in the watcher's poll loop, so it stops
    # taking on new tasks once its wall-clock budget is spent rather than
    # letting a slow reader hold the watcher off its surfacing cadence. The
    # untouched tail keeps its durable records and leads the next sweep.
    if [ "$n" -gt 0 ] && [ "$budget" -gt 0 ] \
      && [ "$(( $(date +%s) - started ))" -ge "$budget" ]; then
      truncated=yes
      break
    fi
    task=$(basename "$meta")
    task=${task%.meta}
    last=$task
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    # An idle secondmate is healthy by design; its routed status stream has
    # its own delivery contract, so it never arms a completion alarm and any
    # stray record for one is dropped.
    if [ "$kind" = secondmate ]; then
      fm_completion_alarm_discard "$state" "$task"
      continue
    fi
    # A provably busy endpoint means the worker is mid-turn on this very
    # state (e.g. composing a gate response): actively worked, not
    # unsurfaced. With no escalation at stake that is settled without paying
    # for the reconciliation read, which is the common case. An episode that
    # HAS escalated keeps its record - dropping it would let a busy flap
    # re-nag the same completion - but still reconciles below, because a
    # record held blind would hide the end of its episode and silently
    # swallow the worker's next completion.
    if _fm_completion_alarm_busy "$meta" "$task" "$state" \
      && ! _fm_completion_alarm_escalated "$state" "$task"; then
      fm_completion_alarm_discard "$state" "$task"
      continue
    fi
    # Only a SUCCESSFUL read may change a record. fm-crew-state.sh exits 0 and
    # reports `state: unknown` even when it can attribute nothing, so a
    # non-zero exit or a line that is not the canonical `state:` verdict means
    # the READER failed rather than that the task is non-terminal. Leave the
    # record exactly as it stands: treating a failed read as non-terminal would
    # restart the episode window on every sweep, so intermittent reader failure
    # could defer the alarm for a genuinely persisting terminal state forever.
    if [ "$read_timeout" -gt 0 ] && declare -F fm_run_timed >/dev/null 2>&1; then
      line=$(fm_run_timed "$read_timeout" "$FM_CREW_STATE_BIN" "$task" 2>/dev/null) || continue
    else
      line=$("$FM_CREW_STATE_BIN" "$task" 2>/dev/null) || continue
    fi
    case "$line" in
      state:*) ;;
      *) continue ;;
    esac
    st=${line#state: }
    st=${st%% *}
    case "$st" in
      done|failed|parked|blocked) ;;
      *) fm_completion_alarm_discard "$state" "$task"; continue ;;
    esac
    case "$line" in
      *"$sep"*"$sep"*) detail=${line#*"$sep"}; detail=${detail#*"$sep"} ;;
      *) detail='' ;;
    esac
    episode=$(fm_completion_alarm_episode "$state" "$task")
    rec=$(fm_completion_alarm_path "$state" "$task")
    if [ ! -f "$rec" ]; then
      fm_completion_alarm_arm "$state" "$task" "$st" "$detail" "$episode" || true
      continue
    fi
    rec_state=$(fm_completion_alarm_get "$rec" state)
    if [ "$rec_state" != "$st" ]; then
      # A different terminal state is a NEW completion episode (e.g. parked
      # gate answered, run finished as done): restart the window.
      fm_completion_alarm_arm "$state" "$task" "$st" "$detail" "$episode" || true
      continue
    fi
    # Same state value, but a head that has moved since the record was armed
    # means the worker completed, did more work, and completed again: two
    # episodes that would otherwise merge behind one state value (a run's
    # approval gate and its fix_review gate both reconcile as parked). Only a
    # head derived on BOTH sides can prove a difference, so an underivable one
    # falls back to the state value rather than restarting the window forever.
    rec_episode=$(fm_completion_alarm_get "$rec" episode)
    if [ -n "$episode" ] && [ -n "$rec_episode" ] && [ "$episode" != "$rec_episode" ]; then
      fm_completion_alarm_arm "$state" "$task" "$st" "$detail" "$episode" || true
      continue
    fi
    escalated=$(fm_completion_alarm_get "$rec" escalated_epoch)
    [ -z "$escalated" ] || continue
    # A done task with an armed merge poll is already being actively landed:
    # the poll's own merged wake is a guaranteed delivery path, so hold the
    # record without escalating while the poll exists.
    if [ "$st" = 'done' ] && [ -e "$state/$task.pr-poll" ]; then
      continue
    fi
    first=$(fm_completion_alarm_get "$rec" first_epoch)
    case "$first" in ''|*[!0-9]*) continue ;; esac
    window=$(fm_completion_alarm_get "$rec" window_secs)
    case "$window" in ''|*[!0-9]*) window=$(fm_completion_alarm_window_secs) ;; esac
    now=$(fm_completion_alarm_now)
    age=$((now - first))
    [ "$age" -ge "$window" ] || continue
    reason="check: completion-alarm: $task $st unsurfaced for ${age}s (window ${window}s)${detail:+ - $detail} - the completion may never have reached the supervising session; read the task's status and pane, then land, relay, or answer it"
    fm_wake_append check "completion-alarm-$task" "$reason" || return 1
    printf 'escalated_epoch=%s\n' "$now" >> "$rec"
    printf '%s\n' "$reason"
  done
  if [ -n "$truncated" ] && [ -n "$last" ]; then
    mkdir -p "$dir" 2>/dev/null || true
    chmod 700 "$dir" 2>/dev/null || true
    printf '%s\n' "$last" > "$cursor_file" 2>/dev/null || true
    chmod 600 "$cursor_file" 2>/dev/null || true
  else
    rm -f "$cursor_file"
  fi
  return 0
}
