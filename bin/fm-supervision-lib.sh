# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because it has in-flight
# work (a state/<id>.meta exists) or an X-mode relay poll
# (state/x-watch.check.sh), and whether its watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# True (0) only when the watcher singleton lock names a pid that is present but
# no longer alive: a watcher that died while still holding the lock. A released
# or absent lock - the legitimate re-arm/wake-handling gap, where the watcher
# cleanly exited (releasing its lock) and a fresh cycle has not re-armed yet - is
# NOT this state, so the grace-based beacon tolerance still absorbs it and no
# spurious alarm fires mid-turn.
#
# The beacon mtime can outlive its writer: the watcher touches the beacon at the
# top of every cycle (bin/fm-watch.sh) and can die later in the same cycle, so a
# fresh mtime - even a fresh AWAKE-time mtime on a machine that never slept - is
# not proof a watcher is alive. Awake-time age (above) stops a LIVE watcher from
# looking falsely dead across a sleep window; this stops a DEAD watcher from
# looking falsely alive behind a recent beacon. The two are orthogonal, and this
# aligns the shared freshness flag with the lock-pid liveness the turn-end guard
# already enforces through fm_watcher_healthy. A reused pid landing on the exact
# dead-watcher pid would mask the death, but that only reverts to the prior
# beacon-only behavior - never a false alarm.
#
# On true, FM_SUP_DEAD_LOCK_PID holds the dead holder's pid so banners can name
# it. Pid liveness delegates to bin/fm-wake-lib.sh's fm_pid_alive (the one owner
# of that check) when that lib is loaded, which every production consumer does;
# the inline fallback keeps this file independently sourceable. The empty and
# non-numeric guard stays here because those mean "no holder recorded", which is
# NOT the dead-holder state, while fm_pid_alive reports them as not-alive.
fm_sup_watcher_lock_pid_dead() {  # <state-dir>
  local state=$1 pid
  FM_SUP_DEAD_LOCK_PID=
  pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if declare -F fm_pid_alive >/dev/null; then
    fm_pid_alive "$pid" && return 1
  else
    kill -0 "$pid" 2>/dev/null && return 1
  fi
  FM_SUP_DEAD_LOCK_PID=$pid
  return 0
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, or a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if
#                         absent); when a fresh beacon's recorded lock holder is
#                         dead, it also names that dead pid so alarm banners
#                         never print a bare fresh age as their only evidence
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# Beacon age counts awake time only when bin/fm-wake-lib.sh is loaded: time the
# system spent asleep before its last wake never counts against the watcher.
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ]; then
    FM_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      # Awake-time beacon age via bin/fm-wake-lib.sh's
      # fm_path_age_since_system_wake (the one owner of that contract) when
      # that lib is loaded, which every production consumer of these fields
      # does. The plain wall-clock fallback keeps this file independently
      # sourceable.
      if declare -F fm_path_age_since_system_wake >/dev/null; then
        age=$(fm_path_age_since_system_wake "$beat")
      else
        age=$(( $(date +%s) - m ))
      fi
      FM_SUP_BEACON_DESC="${age}s ago"
      # A fresh beacon is honest liveness only while a watcher process is still
      # behind it. If the singleton lock names a now-dead watcher, the beacon
      # outlived its writer, so report not-fresh and let the WATCHER DOWN alarm
      # fire instead of masking a dead watcher for the rest of the grace window.
      # In exactly that case the description must name the dead holder: an alarm
      # whose only evidence is a fresh-looking age reads as a contradiction.
      if [ "$age" -lt "$grace" ]; then
        if fm_sup_watcher_lock_pid_dead "$state"; then
          FM_SUP_BEACON_DESC="${age}s ago, but its watcher (lock pid $FM_SUP_DEAD_LOCK_PID) died"
        else
          FM_SUP_WATCHER_FRESH=true
        fi
      fi
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
