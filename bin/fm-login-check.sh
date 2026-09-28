#!/usr/bin/env bash
# fm-login-check.sh - find every login today's work will need that is not
# signed in, so session start can ask for all of them at once instead of a
# worker stopping mid-task.
#
# Usage: fm-login-check.sh
#   Prints nothing when every needed login is signed in, or exactly one line:
#     NEEDS_LOGIN: <login> (<detail>; sign in: <how>); <login> (...); ...
#   and always exits 0. bin/fm-bootstrap.sh runs it in its network phase beside
#   `gh auth status` (which keeps its own NEEDS_GH_AUTH line), so it runs in
#   session start's deferred stage (bin/fm-startup-network.sh) and never holds
#   up the digest.
#
# What today's work needs is read, never guessed:
#   - Projects: the repo of every in-flight and dispatch-ready backlog row
#     (`tasks-axi list --state in_flight` and `tasks-axi ready`), plus the
#     project of every live task record (state/*.meta) except persistent
#     secondmates.
#   - config/logins (optional, captain-private) declares the per-project logins,
#     one per line, `|`-separated, with `#` comments and blank lines ignored:
#       <name> | <projects> | <check command> | <how to sign in>
#     <projects> is `*` (always needed) or a comma-separated list of project
#     names; a login is checked only when one of its projects has work today.
#     <check command> runs through bash with no stdin and must exit 0 exactly
#     when the login is usable; it must not prompt. It may contain `|`, since
#     the sign-in hint is whatever follows the last separator. Examples:
#       gcloud | heva-ai-backend,heva-web | gcloud auth print-access-token --quiet | gcloud auth login
#       GitHub fork account | firstmate | GH_TOKEN="$(security find-generic-password -s gh-fork -w)" gh api user | refresh the gh-fork keychain token
#     A malformed line is itself reported, so a typo cannot silently skip a
#     login.
#   - Worker accounts, built in: the Claude worker account is checked when
#     config/claude-account pins one or the crew harness is claude, and each
#     provider config/pi-account declares is checked for Pi workers. A pinned
#     account reuses bin/fm-worker-account-lib.sh's launch-time sign-in check,
#     so it reports exactly what a spawn would refuse. An unpinned Claude
#     worker inherits this session's environment, so it is checked with
#     `claude auth status` under that same environment, which counts API-key,
#     OAuth-token, and Bedrock or Vertex sign-ins exactly as the worker will.
# FM_LOGIN_CHECK=off skips every check (the test suites set it so fixtures
# never probe the machine's real logins).
# Every check is bounded: FM_LOGIN_CHECK_SECONDS (default 20) per config/logins
# check, and FM_WORKER_ACCOUNT_CHECK_SECONDS for worker accounts. A check that
# times out is reported as unconfirmed rather than passed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LOGIN_CHECK_SECONDS=${FM_LOGIN_CHECK_SECONDS:-20}
case "$LOGIN_CHECK_SECONDS" in ''|*[!0-9]*|0) LOGIN_CHECK_SECONDS=20 ;; esac

# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

case "${1:-}" in
  '') ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  *) echo "usage: fm-login-check.sh" >&2; exit 2 ;;
esac

case "${FM_LOGIN_CHECK:-on}" in off|0|false|no) exit 0 ;; esac

MISSING=()

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# The repo column of a tasks-axi listing: id, state, kind, and repo are slugs
# that precede the quoted title, so a comma in a title cannot shift them.
listing_repos() {
  awk -F, '/^  [A-Za-z0-9._-]+,/ { print $4 }'
}

backlog_listing() {  # <tasks-axi args...>
  local data
  data=$(fm_backlog_data_absolute "$DATA") || return 1
  fm_backlog_tasks_axi_addressing "$data" || return 1
  if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
    (cd "$FM_BACKLOG_AXI_ROOT" 2>/dev/null && fm_tasks_axi "$@" --file "$FM_BACKLOG_AXI_FILE" 2>/dev/null)
  else
    (cd "$FM_BACKLOG_AXI_ROOT" 2>/dev/null && fm_tasks_axi "$@" 2>/dev/null)
  fi
}

todays_projects() {
  local meta project
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -qx 'kind=secondmate' "$meta" 2>/dev/null && continue
    project=$(sed -n 's/^project=//p' "$meta" | tail -1)
    project=${project%/}
    [ -z "$project" ] || printf '%s\n' "${project##*/}"
  done
  if [ -f "$DATA/backlog.md" ] || [ -e "$FM_HOME/.tasks.toml" ]; then
    if command -v tasks-axi >/dev/null 2>&1; then
      backlog_listing list --state in_flight | listing_repos
      backlog_listing ready | listing_repos
    fi
  fi
}

needed_by_today() {  # <projects-field> <today's projects, newline-separated>
  local want project
  [ "$(trim "$1")" = '*' ] && { printf 'all work\n'; return 0; }
  while IFS= read -r want; do
    want=$(trim "$want")
    [ -n "$want" ] || continue
    while IFS= read -r project; do
      [ "$project" = "$want" ] && { printf '%s\n' "$want"; return 0; }
    done <<EOF
$2
EOF
  done <<EOF
$(printf '%s\n' "$1" | tr ',' '\n')
EOF
  return 1
}

check_configured_logins() {  # <today's projects>
  local file="$CONFIG/logins" line n=0 name projects check how rest why rc
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$(trim "$line")" in ''|'#'*) continue ;; esac
    # The check command may itself contain pipes, so the sign-in hint is
    # everything after the LAST separator and the command is what lies between.
    name=$(trim "${line%%|*}"); rest=${line#*|}
    projects=$(trim "${rest%%|*}"); rest=${rest#*|}
    check=$(trim "${rest%|*}"); how=$(trim "${rest##*|}")
    if [ "$(printf '%s' "$line" | tr -cd '|' | wc -c | tr -d ' ')" -lt 3 ] \
      || [ -z "$name" ] || [ -z "$projects" ] || [ -z "$check" ] || [ -z "$how" ]; then
      MISSING+=("config/logins line $n (malformed; expected: name | projects | check command | how to sign in)")
      continue
    fi
    why=$(needed_by_today "$projects" "$1") || continue
    rc=0
    fm_run_timed "$LOGIN_CHECK_SECONDS" bash -c "$check" </dev/null >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) ;;
      124) MISSING+=("$name (for $why; check timed out after ${LOGIN_CHECK_SECONDS}s; sign in: $how)") ;;
      *) MISSING+=("$name (for $why; sign in: $how)") ;;
    esac
  done < "$file"
}

check_claude_worker_account() {
  local resolved declared root pinned=0 crew
  [ -e "$CONFIG/claude-account" ] && pinned=1
  if [ "$pinned" = 0 ]; then
    crew=$("$SCRIPT_DIR/fm-harness.sh" crew 2>/dev/null) || crew=
    [ "$crew" = claude ] || return 0
  fi
  command -v claude >/dev/null 2>&1 || return 0
  if [ "$pinned" = 1 ]; then
    if ! resolved=$(fm_worker_account_resolve claude "$CONFIG" 2>/dev/null); then
      MISSING+=("Claude worker account (config/claude-account is invalid; fix the pin)")
      return 0
    fi
    declared=${resolved%%$'\t'*}
    root=${resolved#*$'\t'}; root=${root%%$'\t'*}
    fm_worker_account_check claude "$declared" "$root" claude >/dev/null 2>&1 && return 0
  else
    root=${CLAUDE_CONFIG_DIR:-}
    fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" claude auth status </dev/null >/dev/null 2>&1 && return 0
  fi
  if [ -n "$root" ]; then
    MISSING+=("Claude worker account $root (sign in: CLAUDE_CONFIG_DIR=$root claude, then /login)")
  else
    MISSING+=("Claude worker account (sign in: env -u CLAUDE_CONFIG_DIR claude, then /login)")
  fi
}

check_pi_worker_account() {
  local resolved declared root providers provider
  [ -e "$CONFIG/pi-account" ] || return 0
  command -v pi >/dev/null 2>&1 || return 0
  if ! resolved=$(fm_worker_account_resolve pi "$CONFIG" 2>/dev/null); then
    MISSING+=("Pi worker account (config/pi-account is invalid; fix the pin)")
    return 0
  fi
  declared=${resolved%%$'\t'*}
  root=${resolved#*$'\t'}; providers=${root#*$'\t'}; root=${root%%$'\t'*}
  for provider in $providers; do
    fm_worker_account_check pi "$declared" "$root" pi "$provider" >/dev/null 2>&1 && continue
    MISSING+=("Pi worker account $declared provider $provider (sign in: PI_CODING_AGENT_DIR=$root pi, then /login)")
  done
}

projects=$(todays_projects | sed '/^$/d' | LC_ALL=C sort -u)
check_configured_logins "$projects"
check_claude_worker_account
check_pi_worker_account

if [ "${#MISSING[@]}" -gt 0 ]; then
  line="NEEDS_LOGIN: ${MISSING[0]}"
  for item in "${MISSING[@]:1}"; do
    line="$line; $item"
  done
  printf '%s\n' "$line"
fi
exit 0
