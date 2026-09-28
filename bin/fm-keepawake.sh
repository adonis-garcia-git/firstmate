#!/usr/bin/env bash
# fm-keepawake.sh - hold a macOS idle-sleep assertion while this home has live
# work, so a sleeping Mac does not cut off a worker's in-flight response.
#
# The assertion is `caffeinate -i -w <anchor>`, where <anchor> is line 1 of
# state/.lock: the harness process of the session that owns this home's
# supervision (bin/fm-lock.sh). caffeinate exits on its own the moment that
# process exits, so the assertion can never outlive the supervising session,
# including a crash that runs no cleanup at all.
#
# There is no daemon. `reconcile` converges the assertion with the fleet and
# returns; bin/fm-watch.sh runs it on every poll and bin/fm-teardown.sh runs it
# after a cleanup, so the assertion appears within one poll of the first live
# task and is dropped within one poll, or at once on cleanup, of the last. A
# caffeinate killed from outside is simply restarted by the next reconcile.
#
# Wanted exactly when all of these hold:
#   - this home has at least one task record (state/*.meta) that is not a
#     persistent secondmate; an idle secondmate is not live work, and a
#     secondmate home with live work holds its own assertion from its own
#     session;
#   - state/.lock names a live harness process (bin/fm-session-lock-lib.sh's
#     fm_session_lock_inspect reports it held);
#   - an assertion tool is available: /usr/bin/caffeinate on macOS, nothing
#     elsewhere, where this command is a silent no-op.
# FM_KEEPAWAKE=off disables it, and then reconcile releases any assertion this
# home holds. FM_KEEPAWAKE_BIN names another assertion tool, for tests.
#
# Per-home and verified: the running assertion is recorded in
# state/.keepawake as `pid=` and `anchor=` lines, and a recorded process is
# only ever signalled after `ps` shows it is still exactly `<tool> -i -w
# <anchor>`, so a recycled pid or another home's assertion is never touched.
# state/.keepawake.lock serializes the watcher and cleanup.
#
# An idle assertion does not stop lid-close sleep on battery; that stays a
# habit (leave the Mac on power, or lid open) rather than something firstmate
# can enforce.
#
# Usage: fm-keepawake.sh reconcile   converge, print nothing, exit 0 unless the
#                                    state directory is unusable
#        fm-keepawake.sh status      print `held pid=<pid> anchor=<pid>` or
#                                    `released`
#        fm-keepawake.sh release     drop this home's assertion, if any
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.keepawake"
LOCKDIR="$STATE/.keepawake.lock"

# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

assertion_tool() {
  if [ -n "${FM_KEEPAWAKE_BIN:-}" ]; then
    [ -x "$FM_KEEPAWAKE_BIN" ] || return 1
    printf '%s\n' "$FM_KEEPAWAKE_BIN"
    return 0
  fi
  [ "$(uname)" = Darwin ] && [ -x /usr/bin/caffeinate ] || return 1
  printf '%s\n' /usr/bin/caffeinate
}

record_value() {  # <key>
  sed -n "s/^$1=//p" "$RECORD" 2>/dev/null | head -1
}

# True when <pid> is still the exact assertion this home started for <anchor>.
is_our_assertion() {  # <pid> <anchor> <tool>
  local pid=$1 anchor=$2 tool=$3 args
  fm_pid_alive "$pid" || return 1
  case "$anchor" in ''|*[!0-9]*) return 1 ;; esac
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  case "$args" in
    "$tool -i -w $anchor" | *" $tool -i -w $anchor") return 0 ;;
  esac
  return 1
}

live_work() {
  local meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -qx 'kind=secondmate' "$meta" 2>/dev/null && continue
    return 0
  done
  return 1
}

wanted_anchor() {  # prints the anchor pid when an assertion is wanted
  case "${FM_KEEPAWAKE:-on}" in off|0|false|no) return 1 ;; esac
  live_work || return 1
  fm_session_lock_inspect "$STATE"
  [ "$FM_LOCK_INSPECT_STATE" = held ] || return 1
  printf '%s\n' "$FM_LOCK_INSPECT_PID"
}

release_recorded() {  # <tool-or-empty>
  local tool=$1 pid anchor
  [ -e "$RECORD" ] || return 0
  pid=$(record_value pid)
  anchor=$(record_value anchor)
  if [ -n "$tool" ] && is_our_assertion "$pid" "$anchor" "$tool"; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$RECORD"
}

# Start the assertion in its own session where perl can provide one, so a
# signal aimed at the caller's process group does not take it down, and never
# as a child the caller could end up waiting on.
start_assertion() {  # <tool> <anchor>
  local tool=$1 anchor=$2 pid tmp
  if command -v perl >/dev/null 2>&1; then
    pid=$( (perl -e 'use POSIX (); POSIX::setsid(); exec @ARGV or exit 127' \
      "$tool" -i -w "$anchor" </dev/null >/dev/null 2>&1 & echo $!) )
  else
    pid=$( ("$tool" -i -w "$anchor" </dev/null >/dev/null 2>&1 & echo $!) )
  fi
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  tmp="$RECORD.tmp.$$"
  if ! { printf 'pid=%s\nanchor=%s\n' "$pid" "$anchor" > "$tmp" && mv -f "$tmp" "$RECORD"; }; then
    rm -f "$tmp"
    kill "$pid" 2>/dev/null || true
    return 1
  fi
}

reconcile() {
  local tool anchor pid recorded_anchor i
  tool=$(assertion_tool) || tool=
  anchor=$(wanted_anchor) || anchor=
  if [ -z "$tool" ] || [ -z "$anchor" ]; then
    release_recorded "$tool"
    return 0
  fi
  pid=$(record_value pid)
  recorded_anchor=$(record_value anchor)
  if [ "$recorded_anchor" = "$anchor" ] && is_our_assertion "$pid" "$anchor" "$tool"; then
    return 0
  fi
  release_recorded "$tool"
  start_assertion "$tool" "$anchor" || return 0
  # perl replaces itself with the tool; give the exec a moment so the record
  # is verifiable by the next reader rather than naming a perl process.
  pid=$(record_value pid)
  i=0
  while [ "$i" -lt 20 ] && ! is_our_assertion "$pid" "$anchor" "$tool"; do
    fm_pid_alive "$pid" || break
    sleep 0.05
    i=$((i + 1))
  done
}

with_lock() {
  [ -d "$STATE" ] || { echo "fm-keepawake: state directory does not exist: $STATE" >&2; return 1; }
  fm_lock_acquire_wait_max "$LOCKDIR" 10 || return 0
  "$@"
  fm_lock_release "$LOCKDIR"
}

case "${1:-}" in
  reconcile) with_lock reconcile ;;
  release) with_lock release_recorded "$(assertion_tool || true)" ;;
  status)
    tool=$(assertion_tool) || tool=
    pid=$(record_value pid)
    anchor=$(record_value anchor)
    if [ -n "$tool" ] && is_our_assertion "$pid" "$anchor" "$tool"; then
      printf 'held pid=%s anchor=%s\n' "$pid" "$anchor"
    else
      echo released
    fi
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
