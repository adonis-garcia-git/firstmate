#!/usr/bin/env bash
# fm-pool-capacity.sh - warn before a project's Treehouse pool runs out of free
# isolated copies.
#
# A full pool fails the next spawn after a 60-second wait for a copy that never
# comes, and a pool fills quietly: finished copies awaiting review or cleanup,
# and dirty copies Treehouse will not hand out again, each hold a slot. This
# script reports a pool before that happens.
#
# Usage:
#   fm-pool-capacity.sh          one line per pool this home's tasks use
#   fm-pool-capacity.sh check    watcher mode: print one warning line per pool
#                                below the threshold, only when that set of
#                                warnings changed since it was last printed
#
# Pools: only the pools that hold this home's task copies (a state/<id>.meta
# whose worktree= is a Treehouse pool slot of its project=, as
# bin/fm-wake-lib.sh's fm_treehouse_pool_slot proves). Treehouse creates a pool
# record for any repository it is asked about, so no other project is queried.
#
# Free copies: slots Treehouse reports available that no live task record in
# this home owns (bin/fm-wake-lib.sh's fm_treehouse_worktree_other_owners; a
# parked task keeps its slot even when Treehouse would hand it out), plus the
# slots the pool may still create below its max_trees. max_trees is read from
# the project's treehouse.toml, else Treehouse's default of 16.
#
# Report line:
#   pool: <project> free=<n> max=<n> slots=<n> available=<n> dirty=<n> in_use=<n> low=<yes|no>
# Check mode queues one durable check wake per low pool (key
# pool-capacity:<project>) and prints its payload, which bin/fm-watch.sh's check
# sweep surfaces:
#   check: pool-capacity: <project> has <n> free isolated copies of <max> (<d> dirty, <u> in use); clean up finished tasks or raise max_trees in <project>/treehouse.toml
#
# A pool is low when free < FM_POOL_FREE_MIN (default 3). Check mode records
# the warnings it queued in state/.pool-capacity-surfaced and queues nothing
# while they are unchanged; when no pool is low it clears that record, so a pool
# that fills again warns again. It runs at most once per FM_POOL_CHECK_SECS
# (default 600) using state/.pool-capacity-last. A pool Treehouse cannot report
# is skipped silently: this is advice, never a gate.
#
# Exit status: 0 on a report (including an empty one), 2 on a usage error.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

TREEHOUSE_DEFAULT_MAX_TREES=16
FREE_MIN=${FM_POOL_FREE_MIN:-3}
case "$FREE_MIN" in ''|*[!0-9]*) FREE_MIN=3 ;; esac
CHECK_SECS=${FM_POOL_CHECK_SECS:-600}
case "$CHECK_SECS" in ''|*[!0-9]*) CHECK_SECS=600 ;; esac

MODE=report
case "${1:-}" in
  '') ;;
  check) MODE=check ;;
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: fm-pool-capacity.sh [check]" >&2; exit 2 ;;
esac

# The distinct project directories whose pools hold this home's task copies.
pool_projects() {
  local meta project wt
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    project=$(fm_meta_get "$meta" project 2>/dev/null) || continue
    wt=$(fm_meta_get "$meta" worktree 2>/dev/null) || continue
    [ -n "$project" ] && [ -n "$wt" ] || continue
    fm_treehouse_pool_slot "$project" "$wt" || continue
    printf '%s\n' "$project"
  done | sort -u
}

max_trees_of() {  # <project-dir>
  local n
  n=$(sed -n 's/^[[:space:]]*max_trees[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\(#.*\)\{0,1\}$/\1/p' \
    "$1/treehouse.toml" 2>/dev/null | tail -1)
  case "$n" in ''|0*) n=$TREEHOUSE_DEFAULT_MAX_TREES ;; esac
  printf '%s' "$n"
}

# One report line for <project-dir>, or nothing when Treehouse cannot report.
pool_line() {  # <project-dir>
  local project=$1 json rows max slots=0 available=0 dirty=0 in_use=0 free=0 path status low=no
  json=$( (cd "$project" && treehouse status --json) 2>/dev/null) || return 0
  rows=$(printf '%s' "$json" | jq -r '.[] | [.status, .path] | @tsv' 2>/dev/null) || return 0
  while IFS=$(printf '\t') read -r status path; do
    [ -n "$status" ] || continue
    slots=$((slots + 1))
    case "$status" in
      available)
        available=$((available + 1))
        [ -n "$(fm_treehouse_worktree_other_owners "$STATE" '' "$path")" ] || free=$((free + 1))
        ;;
      dirty) dirty=$((dirty + 1)) ;;
      *) in_use=$((in_use + 1)) ;;
    esac
  done <<EOF
$rows
EOF
  max=$(max_trees_of "$project")
  [ "$slots" -ge "$max" ] || free=$((free + max - slots))
  [ "$free" -ge "$FREE_MIN" ] || low=yes
  printf 'pool: %s free=%s max=%s slots=%s available=%s dirty=%s in_use=%s low=%s\n' \
    "$(basename "$project")" "$free" "$max" "$slots" "$available" "$dirty" "$in_use" "$low"
}

report() {
  local project
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    pool_line "$project"
  done < <(pool_projects)
}

if [ "$MODE" = report ]; then
  report
  exit 0
fi

marker="$STATE/.pool-capacity-last"
if [ -e "$marker" ] && [ "$(fm_path_age "$marker")" -lt "$CHECK_SECS" ]; then
  exit 0
fi
touch "$marker"
warnings=$(report | awk '
  $NF == "low=yes" {
    for (i = 3; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
    printf "%s\tcheck: pool-capacity: %s has %s free isolated copies of %s (%s dirty, %s in use); clean up finished tasks or raise max_trees in %s/treehouse.toml\n", $2, $2, v["free"], v["max"], v["dirty"], v["in_use"], $2
  }')
surfaced="$STATE/.pool-capacity-surfaced"
if [ -z "$warnings" ]; then
  rm -f "$surfaced"
  exit 0
fi
[ "$(cat "$surfaced" 2>/dev/null || true)" != "$warnings" ] || exit 0
# Enqueue before recording the warnings as surfaced, so an interruption can
# repeat a warning but never lose one.
while IFS=$(printf '\t') read -r project payload; do
  [ -n "$project" ] || continue
  fm_wake_append check "pool-capacity:$project" "$payload" || exit 1
  printf '%s\n' "$payload"
done <<EOF
$warnings
EOF
printf '%s\n' "$warnings" > "$surfaced"
