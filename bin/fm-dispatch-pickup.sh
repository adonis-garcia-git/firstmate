#!/usr/bin/env bash
# fm-dispatch-pickup.sh - pick up work another machine dispatched as a GitHub
# issue, and report the outcome back into that same issue.
#
# Usage:
#   fm-dispatch-pickup.sh [check]
#   fm-dispatch-pickup.sh arm
#   fm-dispatch-pickup.sh disarm
#   fm-dispatch-pickup.sh claim <task-id> <issue-url>
#   fm-dispatch-pickup.sh bind <task-id> <issue-url>
#   fm-dispatch-pickup.sh report <task-id> --built|--blocked <message source>
#   fm-dispatch-pickup.sh --help
#
# THE TRANSPORT. The captain writes a spec on one machine and presses Dispatch;
# that machine's firstmate opens an issue on the target repository carrying the
# spec as the body and one label. This machine picks it up. Nothing pushes and
# nothing listens: both machines poll on their own schedule, so the dispatching
# machine can be powered off from the moment it dispatches, and the issue simply
# waits until this machine next looks.
#
# THE ISSUE IS THE RECORD, not a notification. There is no parallel state file
# describing what was dispatched or how it went, because two records of one fact
# drift apart. Every state is one label plus the issue's own open/closed:
#
#   fm:dispatched              waiting to be picked up (set by the author)
#   fm:building                a task exists and is working
#   fm:built    + closed       landed, or ready for the captain
#   fm:blocked  + still OPEN   needs the captain; deliberately not abandoned
#
# THE ONE ORDERING THAT MATTERS. `claim` relabels dispatched -> building BEFORE
# the worker is spawned, never after. A crash in that window leaves an issue
# marked building with no task, which `check` reports by name and an operator
# can act on. The other order leaves an issue still marked dispatched that the
# next poll picks up and builds a SECOND time. Do not "tidy" this into the more
# natural-looking order.
#
# IDEMPOTENCY. The issue URL is the key, and the task record carries it as
# `issue=<url>`, the same shape as the existing `pr=` field. `claim` refuses
# when any task record in this home already claims that issue, so a double
# claim, a re-poll, or a crash-and-retry cannot produce two builds. `bind`
# refuses the same way, and additionally refuses an issue that is not currently
# labeled building, so a task cannot be bound to an issue nobody claimed.
#
# UNREACHABLE DEGRADES LOUDLY. "Nothing was dispatched" and "I could not reach
# GitHub" never produce the same result: a repository that cannot be read is a
# reported finding, never silence, and never an empty list.
#
# WHICH FORGE CLI. Reads go through `gh` with `--json`/`--jq`, because this
# script decides whether to spawn a worker and needs an exact machine-readable
# answer; writes go through `gh-axi`, whose output is never parsed. That split
# is the one this repo already uses - bin/fm-pr-poll.sh reads with `gh`,
# bin/fm-pr-merge.sh and bin/fm-teardown.sh write with `gh-axi`. Every call
# passes `-R <owner>/<repo>` explicitly, because the watcher runs a check from
# no particular directory.
#
# WRITES ARE VERIFIED, NOT TRUSTED. After every relabel, comment, and close, the
# resulting issue is read back and the expected state asserted. A forge CLI that
# exits 0 without having applied the change would otherwise let the whole
# ordering guarantee above quietly lapse.
#
# CADENCE. `check` prints one line when something needs attention and prints
# nothing at all otherwise, so it composes with the existing watcher state-check
# contract instead of needing a schedule of its own. Probing costs real network
# time, so it runs its probes at most once per FM_DISPATCH_PICKUP_INTERVAL
# (default 900, 0 disables the gate, otherwise 60..86400).
#
# Findings are reported when they CHANGE, so one dispatched issue does not wake
# firstmate on every poll while it is being built. That alone would let an issue
# nobody acted on go quiet forever, so an unchanged finding set is reported
# again once per FM_DISPATCH_PICKUP_RENAG (default 21600, 0 disables the re-nag,
# otherwise 300..604800). Silence therefore means "nothing is waiting", never
# "something is waiting and I already mentioned it".
#
# BOUNDS. Each probe is bounded by FM_DISPATCH_PICKUP_PROBE_SECS (default 8,
# valid 1..30) and a whole sweep by FM_DISPATCH_PICKUP_BUDGET_SECS (default 20,
# valid 1..120). The sweep has to finish inside the watcher's own per-check
# bound, because a run the watcher kills prints nothing and writes no record and
# would repeat that silence on every poll, so a budget larger than
# FM_CHECK_TIMEOUT (default 30) allows is cut down to fit and the cut is
# reported. The mutating actions are bounded by FM_DISPATCH_PICKUP_WRITE_SECS
# (default 30, valid 1..300) per call and have no sweep budget, because a person
# or firstmate is waiting on their result.
#
# WHAT THIS SCRIPT NEVER DOES. It never creates an issue, never writes to a
# project working tree, never merges anything, and never closes an issue on
# failure. A worker that failed leaves its issue OPEN and labeled blocked with
# a comment saying why.
set -u
export LC_ALL=C
# A forge probe must never stop to ask for credentials; an unauthenticated read
# has to fail inside its bound instead of waiting for an answer.
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
RECORD="$STATE/.dispatch-pickup"
CHECK_ID=dispatch-pickup
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-dispatch-pickup-v1

LABEL_DISPATCHED='fm:dispatched'
LABEL_BUILDING='fm:building'
LABEL_BUILT='fm:built'
LABEL_BLOCKED='fm:blocked'

# Wider than the digest default because one finding names a repository, an issue
# number, and a title, and several repositories can report in the same sweep.
MAX_LINE=1000
# How many issues one label query returns. A sweep that hits the cap says so
# rather than presenting a truncated list as the whole of what is waiting.
LIST_LIMIT=50
# Titles are cosmetic in the report, so they are cut per issue to keep one
# waiting issue from consuming the whole line cap.
MAX_TITLE=80

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-dispatch-pickup.sh [check]            report dispatched work waiting here (silent when nothing waits)
  fm-dispatch-pickup.sh arm                write and register state/dispatch-pickup.check.sh
  fm-dispatch-pickup.sh disarm             remove the check shim, its trust binding, and the record
  fm-dispatch-pickup.sh claim <task-id> <issue-url>
                                           relabel fm:dispatched -> fm:building and comment naming the task.
                                           Run this BEFORE spawning the worker, never after.
  fm-dispatch-pickup.sh bind <task-id> <issue-url>
                                           record issue=<url> on the spawned task. Run this after the spawn.
  fm-dispatch-pickup.sh report <task-id> --built   (--message <text> | --message-file <path>)
                                           comment the outcome, label fm:built, close the issue.
  fm-dispatch-pickup.sh report <task-id> --blocked (--message <text> | --message-file <path>)
                                           comment the reason, label fm:blocked, leave the issue OPEN.

An issue URL is https://github.com/<owner>/<repo>/issues/<number>.
See docs/configuration.md "Cross-machine work dispatch" for the state machine and setup.
EOF
}

die_usage() {
  printf 'fm-dispatch-pickup: %s\n' "$1" >&2
  usage >&2
  exit 2
}

die() {
  printf 'fm-dispatch-pickup: %s\n' "$1" >&2
  exit 1
}

# --- environment ------------------------------------------------------------

# Reports the accepted value in BOUNDED_VALUE rather than on stdout, because a
# command substitution would run the refusal in a subshell where its exit could
# not stop the script, and an out-of-range setting would then be silently read
# as an empty value instead of refused.
BOUNDED_VALUE=

read_bounded_env() { # <var-name> <default> <min> <max> <allow-zero>
  local name=$1 default=$2 min=$3 max=$4 allow_zero=$5 value zero=''
  [ "$allow_zero" = 1 ] && zero='0 or '
  value=${!name:-$default}
  BOUNDED_VALUE=
  case "$value" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$allow_zero" = 1 ] && [ "$value" -eq 0 ]; then
        BOUNDED_VALUE=0
        return 0
      fi
      if [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]; then
        BOUNDED_VALUE=$value
        return 0
      fi
      ;;
  esac
  printf 'fm-dispatch-pickup: %s must be %sa whole number from %s to %s\n' \
    "$name" "$zero" "$min" "$max" >&2
  return 1
}

read_bounded_env FM_DISPATCH_PICKUP_INTERVAL 900 60 86400 1 || exit 2
INTERVAL=$BOUNDED_VALUE
read_bounded_env FM_DISPATCH_PICKUP_RENAG 21600 300 604800 1 || exit 2
RENAG=$BOUNDED_VALUE
read_bounded_env FM_DISPATCH_PICKUP_PROBE_SECS 8 1 30 0 || exit 2
PROBE_SECS=$BOUNDED_VALUE
read_bounded_env FM_DISPATCH_PICKUP_BUDGET_SECS 20 1 120 0 || exit 2
BUDGET_SECS=$BOUNDED_VALUE
read_bounded_env FM_DISPATCH_PICKUP_WRITE_SECS 30 1 300 0 || exit 2
WRITE_SECS=$BOUNDED_VALUE

# The smallest bound a probe can be given, because fm_run_timed treats a
# non-positive bound as no bound.
PROBE_MIN_SECS=1
# Both clocks here count whole seconds, so a probe can start when the arithmetic
# says a second is left while almost none of it really is.
CLOCK_ROUNDING_SECS=1
# fm_run_timed asks its runner for -k 1, so a probe that does not stop on TERM
# is only killed a second after its bound.
KILL_GRACE_SECS=1

# The watcher's per-check bound, read from this check's own environment. The
# watcher runs the check as a direct child, so an operator who raised it is seen
# here too, and when it is unset both sides resolve the same default.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
BUDGET_MAX=$((CHECK_TIMEOUT - PROBE_MIN_SECS - CLOCK_ROUNDING_SECS - KILL_GRACE_SECS))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
# Cut rather than refuse. A refusal is reported once and then suppressed, which
# leaves the detector dead and quiet, and a check that goes silent is worse than
# a check that reports something awkward.
BUDGET_CUT_FROM=
if [ "$BUDGET_SECS" -gt "$BUDGET_MAX" ]; then
  BUDGET_CUT_FROM=$BUDGET_SECS
  BUDGET_SECS=$BUDGET_MAX
fi

# The record epoch is overridable so a test can drive the cadence gate; the
# sweep budget always uses real time so a frozen epoch cannot disable it.
record_epoch_now() {
  case "${FM_DISPATCH_PICKUP_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_DISPATCH_PICKUP_NOW" ;;
  esac
}

real_epoch() { date +%s; }

# --- issue identity ---------------------------------------------------------

FM_DISPATCH_OWNER=
FM_DISPATCH_REPO=
FM_DISPATCH_NUMBER=
FM_DISPATCH_URL=

# The GitHub half of bin/fm-pr-lib.sh's fm_pr_url_parse, for issues rather than
# pull requests. Deliberately strict and deliberately one canonical spelling per
# issue: the URL is the idempotency key, so two spellings of one issue would be
# two keys and would defeat the refusal that prevents a second build.
fm_dispatch_issue_url_parse() {
  local raw=${1-} pattern
  local LC_ALL=C
  FM_DISPATCH_OWNER=
  FM_DISPATCH_REPO=
  FM_DISPATCH_NUMBER=
  FM_DISPATCH_URL=
  pattern='^https://github\.com/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})/issues/([1-9][0-9]*)$'
  [[ "$raw" =~ $pattern ]] || return 1
  [[ "${BASH_REMATCH[1]}" != *--* ]] || return 1
  [ "${BASH_REMATCH[2]}" != . ] && [ "${BASH_REMATCH[2]}" != .. ] || return 1
  FM_DISPATCH_OWNER=${BASH_REMATCH[1]}
  FM_DISPATCH_REPO=${BASH_REMATCH[2]}
  FM_DISPATCH_NUMBER=${BASH_REMATCH[3]}
  FM_DISPATCH_URL=$raw
  return 0
}

issue_url() { # <owner> <repo> <number>
  printf 'https://github.com/%s/%s/issues/%s\n' "$1" "$2" "$3"
}

# A GitHub "<owner>/<repo>" slug, held to the same owner and repository rules the
# URL parser applies, so a slug derived from a clone and a slug derived from a
# URL can never disagree about which project they name.
slug_valid() { # <owner>/<repo>
  local slug=${1-}
  case "$slug" in
    */*) ;;
    *) return 1 ;;
  esac
  fm_dispatch_issue_url_parse "$(issue_url "${slug%%/*}" "${slug#*/}" 1)"
}

# --- task records -----------------------------------------------------------

# Every task record in this home that claims the given issue, one id per line.
# The scan is over the whole home rather than one task, because the question the
# refusal asks is "has ANY task already claimed this issue", and a per-task
# lookup could not answer it.
issue_claimants() { # <issue-url>
  local url=$1 meta id
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    grep -q -x -F "issue=$url" "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    printf '%s\n' "$id"
  done
}

meta_issue() { # <meta-path>; prints the recorded issue URL, if any
  local meta=$1 line value=''
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      issue=*) value=${line#issue=} ;;
    esac
  done < "$meta"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# --- forge access -----------------------------------------------------------

DEADLINE=0
BUDGETED=0

# The bound for one probe. Under a sweep it is cut down to whatever the budget
# has left, so no probe can run past the end of the sweep; outside a sweep the
# write bound applies. Never below PROBE_MIN_SECS, because fm_run_timed treats a
# non-positive bound as no bound.
probe_bound() {
  local left
  if [ "$BUDGETED" -eq 0 ]; then
    printf '%s\n' "$WRITE_SECS"
    return 0
  fi
  left=$((DEADLINE - $(real_epoch)))
  if [ "$left" -lt "$PROBE_MIN_SECS" ]; then
    printf '%s\n' "$PROBE_MIN_SECS"
  elif [ "$left" -lt "$PROBE_SECS" ]; then
    printf '%s\n' "$left"
  else
    printf '%s\n' "$PROBE_SECS"
  fi
}

gh_read() { # <args...>; bounded read through gh
  fm_run_timed "$(probe_bound)" gh "$@" 2>/dev/null
}

gh_write() { # <args...>; bounded write through gh-axi
  fm_run_timed "$(probe_bound)" gh-axi "$@" >/dev/null 2>&1
}

FM_ISSUE_STATE=
FM_ISSUE_LABELS=

# Read one issue's state and labels. The state comes back on the first line and
# each label on a line of its own, because GitHub label names may contain commas
# and spaces but never a newline, so line separation is the only delimiter that
# cannot be forged by a label name.
issue_read() { # <owner>/<repo> <number>
  local repo=$1 number=$2 raw
  FM_ISSUE_STATE=
  FM_ISSUE_LABELS=
  raw=$(gh_read issue view "$number" -R "$repo" --json state,labels \
    --jq '.state, (.labels[].name)') || return 1
  [ -n "$raw" ] || return 1
  FM_ISSUE_STATE=$(printf '%s\n' "$raw" | head -n 1)
  FM_ISSUE_LABELS=$(printf '%s\n' "$raw" | tail -n +2)
  case "$FM_ISSUE_STATE" in
    OPEN|CLOSED) ;;
    *) return 1 ;;
  esac
  return 0
}

issue_has_label() { # <label>
  printf '%s\n' "$FM_ISSUE_LABELS" | grep -q -x -F "$1"
}

# --- check ------------------------------------------------------------------

FINDINGS=
INCOMPLETE_REPORTED=0

# Each finding is flattened to a single line, because the whole report must stay
# one line for the wake record.
emit() {
  local text
  text=$(printf '%s' "$1" | tr '\t\r\n' '   ')
  if [ -z "$FINDINGS" ]; then
    FINDINGS=$text
  else
    FINDINGS="$FINDINGS; $text"
  fi
}

budget_exhausted() {
  [ "$(real_epoch)" -ge "$DEADLINE" ]
}

# True while the sweep budget still has room for another probe. When it does
# not, it records once which repository the sweep did not reach, so a sweep that
# cannot finish says so rather than being killed by the watcher with nothing
# printed.
budget_allows() { # <repo>
  local repo=$1
  budget_exhausted || return 0
  if [ "$INCOMPLETE_REPORTED" -eq 0 ]; then
    INCOMPLETE_REPORTED=1
    emit "check incomplete: the time budget ran out before $repo"
  fi
  return 1
}

short_title() {
  local title=$1
  fm_cap_line_var "$title" "$MAX_TITLE"
  printf '%s\n' "$FM_LINE_CAP_LINE"
}

# The GitHub owner/repo a clone points at, or nothing when it points elsewhere.
# A project with no origin, or an origin on another forge, is not a failure: a
# local-only project is a registered posture, so it is skipped in silence rather
# than reported as something the operator must fix.
clone_repo_slug() { # <clone-dir>
  local dir=$1 url slug
  url=$(git -C "$dir" config --get remote.origin.url 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  case "$url" in
    https://github.com/*) slug=${url#https://github.com/} ;;
    ssh://git@github.com/*) slug=${url#ssh://git@github.com/} ;;
    git@github.com:*) slug=${url#git@github.com:} ;;
    *) return 1 ;;
  esac
  slug=${slug%.git}
  slug=${slug%/}
  slug_valid "$slug" || return 1
  printf '%s\n' "$slug"
}

# Every GitHub-backed clone in this home, deduplicated by slug so two clones of
# one repository are polled once.
#
# The sweep reads this through a process substitution, so it runs in a subshell:
# nothing here can add a finding, because emit would set FINDINGS in that
# subshell and the value would be thrown away. Anything this function needs to
# report has to be returned to the caller instead.
clone_slugs() {
  local dir slug seen=''
  [ -d "$PROJECTS" ] || return 0
  for dir in "$PROJECTS"/*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    slug=$(clone_repo_slug "$dir") || continue
    case " $seen " in
      *" $slug "*) continue ;;
    esac
    seen="$seen $slug"
    printf '%s\n' "$slug"
  done
}

# One label query. Prints "<number><tab><title>" per issue, with control
# characters removed from the title inside the query so one issue is always
# exactly one line whatever the captain typed into it.
list_labeled() { # <repo> <label>
  gh_read issue list -R "$1" --state open --label "$2" --limit "$LIST_LIMIT" \
    --json number,title --jq '.[] | "\(.number)\t\(.title | gsub("[[:cntrl:]]"; " "))"'
}

sweep_repo() { # <repo>
  local repo=$1 raw number title count claimed url
  # An unreadable repository is a finding, never an empty list. "Nothing was
  # dispatched" and "I could not look" must never render the same.
  if ! raw=$(list_labeled "$repo" "$LABEL_DISPATCHED"); then
    emit "could not read $repo: the dispatched issues could not be listed"
    return 0
  fi
  count=0
  while IFS=$'\t' read -r number title; do
    [ -n "$number" ] || continue
    case "$number" in
      *[!0-9]*) continue ;;
    esac
    count=$((count + 1))
    emit "ready to pick up ${repo}#${number} \"$(short_title "$title")\""
  done <<EOF
$raw
EOF
  if [ "$count" -ge "$LIST_LIMIT" ]; then
    emit "$repo has at least $LIST_LIMIT dispatched issues, so this list is cut"
  fi

  budget_allows "$repo" || return 0
  if ! raw=$(list_labeled "$repo" "$LABEL_BUILDING"); then
    emit "could not read $repo: the building issues could not be listed"
    return 0
  fi
  while IFS=$'\t' read -r number title; do
    [ -n "$number" ] || continue
    case "$number" in
      *[!0-9]*) continue ;;
    esac
    url=$(issue_url "${repo%%/*}" "${repo#*/}" "$number")
    claimed=$(issue_claimants "$url")
    [ -z "$claimed" ] || continue
    # The recoverable half of the relabel-before-spawn ordering: the issue was
    # claimed and the task never appeared. Nothing will pick it up again on its
    # own, because the poll only offers dispatched issues, so it is named here.
    emit "marked building with no task ${repo}#${number} \"$(short_title "$title")\""
  done <<EOF
$raw
EOF
  return 0
}

RECORD_EPOCH=0
RECORD_REPORTED_EPOCH=0
RECORD_REPORTED=

record_read() {
  local line first=1
  RECORD_EPOCH=0
  RECORD_REPORTED_EPOCH=0
  RECORD_REPORTED=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      epoch=*)
        line=${line#epoch=}
        case "$line" in
          ''|*[!0-9]*) RECORD_EPOCH=0 ;;
          *) RECORD_EPOCH=$line ;;
        esac
        ;;
      reported_epoch=*)
        line=${line#reported_epoch=}
        case "$line" in
          ''|*[!0-9]*) RECORD_REPORTED_EPOCH=0 ;;
          *) RECORD_REPORTED_EPOCH=$line ;;
        esac
        ;;
      reported=*) RECORD_REPORTED=${line#reported=} ;;
    esac
  done < "$RECORD"
  return 0
}

record_write() { # <findings> <reported-epoch>
  local reported=$1 reported_epoch=$2 tmp
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'epoch=%s\n' "$(record_epoch_now)"
    printf 'reported_epoch=%s\n' "$reported_epoch"
    printf 'reported=%s\n' "$reported"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

action_check() {
  local slug line now reported_epoch elapsed

  record_read
  now=$(record_epoch_now)
  if [ "$INTERVAL" -ne 0 ] && [ "$RECORD_EPOCH" -gt 0 ] \
    && [ "$now" -ge "$RECORD_EPOCH" ] && [ $((now - RECORD_EPOCH)) -lt "$INTERVAL" ]; then
    return 0
  fi

  BUDGETED=1
  DEADLINE=$(($(real_epoch) + BUDGET_SECS))

  if [ -n "$BUDGET_CUT_FROM" ]; then
    emit "sweep budget ${BUDGET_CUT_FROM}s cut to ${BUDGET_SECS}s to stay inside the watcher check timeout of ${CHECK_TIMEOUT}s"
  fi

  if ! command -v gh >/dev/null 2>&1; then
    # Reported rather than silent: with no gh, every repository below would look
    # exactly like a repository with nothing dispatched.
    emit 'gh is not on PATH, so no dispatched work can be read'
  else
    while IFS= read -r slug; do
      [ -n "$slug" ] || continue
      budget_allows "$slug" || break
      sweep_repo "$slug"
    done < <(clone_slugs)
  fi

  line=
  if [ -n "$FINDINGS" ]; then
    # Capped through the shared cut so an over-long report carries the same
    # visible truncation marker the digests use, instead of ending mid-finding
    # as if that were all of it.
    fm_cap_line_var "dispatched work: $FINDINGS" "$MAX_LINE"
    line=$FM_LINE_CAP_LINE
  fi

  # An unchanged finding set is news again once the re-nag interval has passed,
  # so work nobody picked up cannot go quiet forever. A changed set is always
  # news. Report before recording, so a record that cannot be written costs a
  # repeated report rather than a lost one.
  reported_epoch=$RECORD_REPORTED_EPOCH
  if [ -n "$line" ]; then
    elapsed=-1
    if [ "$RECORD_REPORTED_EPOCH" -gt 0 ] && [ "$now" -ge "$RECORD_REPORTED_EPOCH" ]; then
      elapsed=$((now - RECORD_REPORTED_EPOCH))
    fi
    if [ "$FINDINGS" != "$RECORD_REPORTED" ] \
      || [ "$elapsed" -lt 0 ] \
      || { [ "$RENAG" -ne 0 ] && [ "$elapsed" -ge "$RENAG" ]; }; then
      printf '%s\n' "$line"
      reported_epoch=$now
    fi
  else
    reported_epoch=0
  fi
  record_write "$FINDINGS" "$reported_epoch" || true
  return 0
}

# --- claim / bind / report --------------------------------------------------

# Apply a label change and prove it landed. gh-axi's exit status alone is not
# enough: a forge CLI that exits 0 without applying the change would leave the
# relabel-before-spawn ordering silently inoperative, which is the one guarantee
# this whole transport rests on.
relabel() { # <repo> <number> <add> <remove...>
  local repo=$1 number=$2 add=$3
  shift 3
  local -a args=(issue edit "$number" -R "$repo" --add-label "$add")
  local removed
  for removed in "$@"; do
    args+=(--remove-label "$removed")
  done
  gh_write "${args[@]}" || return 1
  issue_read "$repo" "$number" || return 1
  issue_has_label "$add" || return 1
  for removed in "$@"; do
    ! issue_has_label "$removed" || return 1
  done
  return 0
}

comment_issue() { # <repo> <number> <body-file>
  gh_write issue comment "$2" -R "$1" --body-file "$3"
}

# The message a report carries. A file is the primary form because an outcome is
# routinely multi-line, and text is accepted for the one-line case.
MESSAGE_FILE=
MESSAGE_TMP=

resolve_message() { # <--message|--message-file> <value>
  case "$1" in
    --message-file)
      [ -f "$2" ] && [ -r "$2" ] || die "cannot read the message file $2"
      MESSAGE_FILE=$2
      ;;
    --message)
      [ -n "$2" ] || die 'the message must not be empty'
      MESSAGE_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-dispatch-message.XXXXXX") || die 'cannot stage the message'
      printf '%s\n' "$2" > "$MESSAGE_TMP" || die 'cannot stage the message'
      MESSAGE_FILE=$MESSAGE_TMP
      ;;
    *) die_usage "unknown message source: $1" ;;
  esac
}

cleanup_message() {
  [ -z "$MESSAGE_TMP" ] || rm -f -- "$MESSAGE_TMP"
  MESSAGE_TMP=
}

require_gh_tools() {
  command -v gh >/dev/null 2>&1 || die 'gh is not on PATH'
  command -v gh-axi >/dev/null 2>&1 || die 'gh-axi is not on PATH'
}

# One home-wide lock across every claim decision and every issue= write.
#
# Without it the refusal has a window: two pickups of one issue can both read
# "nobody claims this" and both read the issue as still dispatched before either
# relabels, and the second relabel then verifies clean because the labels are
# already where it wanted them. Claims are rare and short, so a single lock for
# the whole home is enough and needs no per-issue key to sanitize.
CLAIM_LOCK=
CLAIM_LOCK_HELD=0

claim_lock_acquire() {
  CLAIM_LOCK="$STATE/.dispatch-claim.lock"
  trap claim_lock_release EXIT
  fm_lock_acquire_wait "$CLAIM_LOCK" || die "cannot lock this home's issue claims"
  CLAIM_LOCK_HELD=1
}

claim_lock_release() {
  [ "$CLAIM_LOCK_HELD" = 1 ] || return 0
  CLAIM_LOCK_HELD=0
  fm_lock_release "$CLAIM_LOCK" || true
}

action_claim() { # <task-id> <issue-url>
  local id=$1 raw=$2 repo claimed body
  fm_task_id_creation_valid "$id" || die "not a usable task id: $id"
  fm_dispatch_issue_url_parse "$raw" || die "not a GitHub issue URL: $raw"
  require_gh_tools
  repo="$FM_DISPATCH_OWNER/$FM_DISPATCH_REPO"

  claim_lock_acquire
  claimed=$(issue_claimants "$FM_DISPATCH_URL")
  if [ -n "$claimed" ]; then
    # The refusal that makes a double-click, a re-poll, and a crash-and-retry
    # all safe. It is deliberately checked before anything is written.
    die "$FM_DISPATCH_URL is already claimed by task $(printf '%s' "$claimed" | tr '\n' ' ')"
  fi
  [ ! -e "$STATE/$id.meta" ] || die "task $id already exists, so it cannot claim a new issue"

  issue_read "$repo" "$FM_DISPATCH_NUMBER" || die "cannot read $repo#$FM_DISPATCH_NUMBER"
  [ "$FM_ISSUE_STATE" = OPEN ] || die "$FM_DISPATCH_URL is closed"
  issue_has_label "$LABEL_DISPATCHED" \
    || die "$FM_DISPATCH_URL is not labeled $LABEL_DISPATCHED, so it is not waiting to be picked up"

  # RELABEL FIRST, then comment, then the caller spawns. See the header.
  relabel "$repo" "$FM_DISPATCH_NUMBER" "$LABEL_BUILDING" "$LABEL_DISPATCHED" \
    || die "could not relabel $FM_DISPATCH_URL to $LABEL_BUILDING, so nothing was claimed"

  body=$(mktemp "${TMPDIR:-/tmp}/fm-dispatch-claim.XXXXXX") || die 'cannot stage the claim comment'
  printf "Picked up by firstmate as task \`%s\`.\n" "$id" > "$body"
  if ! comment_issue "$repo" "$FM_DISPATCH_NUMBER" "$body"; then
    rm -f -- "$body"
    # The relabel already landed, so a retry of claim would correctly refuse.
    # Say exactly what is true so the caller reconciles rather than re-claims.
    die "relabeled $FM_DISPATCH_URL to $LABEL_BUILDING but could not comment; spawn task $id and run bind, or reconcile the issue"
  fi
  rm -f -- "$body"
  claim_lock_release
  printf 'claimed: %s as %s\n' "$FM_DISPATCH_URL" "$id"
  return 0
}

action_bind() { # <task-id> <issue-url>
  local id=$1 raw=$2 repo meta existing claimed lock tmp line
  fm_pr_task_id_valid "$id" || die "not a usable task id: $id"
  fm_dispatch_issue_url_parse "$raw" || die "not a GitHub issue URL: $raw"
  require_gh_tools
  repo="$FM_DISPATCH_OWNER/$FM_DISPATCH_REPO"
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || die "no task record for $id"

  claim_lock_acquire
  existing=$(meta_issue "$meta") || existing=
  if [ -n "$existing" ] && [ "$existing" != "$FM_DISPATCH_URL" ]; then
    die "task $id already carries $existing"
  fi
  claimed=$(issue_claimants "$FM_DISPATCH_URL")
  case "$claimed" in
    ''|"$id") ;;
    *) die "$FM_DISPATCH_URL is already claimed by task $(printf '%s' "$claimed" | tr '\n' ' ')" ;;
  esac

  # A task can only bind an issue somebody claimed, so a worker spawned without
  # going through claim cannot silently adopt an issue the poll still offers.
  issue_read "$repo" "$FM_DISPATCH_NUMBER" || die "cannot read $repo#$FM_DISPATCH_NUMBER"
  issue_has_label "$LABEL_BUILDING" \
    || die "$FM_DISPATCH_URL is not labeled $LABEL_BUILDING, so it was never claimed"

  if [ "$existing" = "$FM_DISPATCH_URL" ]; then
    claim_lock_release
    printf 'bound: %s to %s\n' "$FM_DISPATCH_URL" "$id"
    return 0
  fi

  lock=$(fm_meta_lock_path "$meta") || die "cannot lock the record for $id"
  fm_lock_acquire_wait "$lock" || die "cannot lock the record for $id"
  tmp=$(mktemp "$STATE/.fm-dispatch-meta.XXXXXX") || { fm_lock_release "$lock"; die "cannot stage the record for $id"; }
  {
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        issue=*) ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$meta"
    printf 'issue=%s\n' "$FM_DISPATCH_URL"
  } > "$tmp" || { rm -f -- "$tmp"; fm_lock_release "$lock"; die "cannot stage the record for $id"; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$meta" || { rm -f -- "$tmp"; fm_lock_release "$lock"; die "cannot record the issue on $id"; }
  fm_lock_release "$lock"
  claim_lock_release
  printf 'bound: %s to %s\n' "$FM_DISPATCH_URL" "$id"
  return 0
}

action_report() { # <task-id> <--built|--blocked> <message source> <value>
  local id=$1 outcome=$2 repo meta url
  shift 2
  fm_pr_task_id_valid "$id" || die "not a usable task id: $id"
  case "$outcome" in
    --built|--blocked) ;;
    *) die_usage "unknown outcome: $outcome" ;;
  esac
  [ "$#" -eq 2 ] || die_usage 'a report needs --message <text> or --message-file <path>'
  require_gh_tools

  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || die "no task record for $id"
  url=$(meta_issue "$meta") || die "task $id carries no dispatched issue"
  fm_dispatch_issue_url_parse "$url" || die "task $id carries an unusable issue URL: $url"
  repo="$FM_DISPATCH_OWNER/$FM_DISPATCH_REPO"

  trap cleanup_message EXIT
  resolve_message "$1" "$2"

  # Read once before writing anything, so an issue that cannot be reached at all
  # is reported before a comment is posted against it. The state this fills in is
  # replaced by the read inside the relabel below.
  issue_read "$repo" "$FM_DISPATCH_NUMBER" || die "cannot read $repo#$FM_DISPATCH_NUMBER"

  # The outcome is comment-first, so a failure between the two steps leaves the
  # reason visible on the issue rather than a bare label change nobody can read.
  comment_issue "$repo" "$FM_DISPATCH_NUMBER" "$MESSAGE_FILE" \
    || die "could not comment the outcome on $url, so nothing was changed"

  if [ "$outcome" = --blocked ]; then
    relabel "$repo" "$FM_DISPATCH_NUMBER" "$LABEL_BLOCKED" "$LABEL_BUILDING" "$LABEL_DISPATCHED" \
      || die "commented on $url but could not label it $LABEL_BLOCKED"
    # Deliberately left OPEN. A failure that closes its own issue is a silent
    # close, and the captain would never see it again.
    [ "$FM_ISSUE_STATE" = OPEN ] \
      || die "commented and labeled $url but it is already closed; reopen it so the captain still sees this failure"
    printf 'reported: %s blocked\n' "$url"
    return 0
  fi

  relabel "$repo" "$FM_DISPATCH_NUMBER" "$LABEL_BUILT" "$LABEL_BUILDING" "$LABEL_DISPATCHED" \
    || die "commented on $url but could not label it $LABEL_BUILT"
  gh_write issue close "$FM_DISPATCH_NUMBER" -R "$repo" --reason completed \
    || die "commented and labeled $url but could not close it"
  issue_read "$repo" "$FM_DISPATCH_NUMBER" || die "cannot confirm the state of $url"
  [ "$FM_ISSUE_STATE" = CLOSED ] || die "commented and labeled $url but it is still open"
  printf 'reported: %s built\n' "$url"
  return 0
}

# --- arm / disarm -----------------------------------------------------------

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-dispatch-pickup.sh - dispatched-issue poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-dispatch-pickup.sh") check"
}

# Write the shim the way this repo writes its other trusted check shims: the
# guards run before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename so the watcher
# never reads a half-written shim and rejects it as unauthenticated.
SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-dispatch-pickup-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# Keep a byte copy of a shim that is already in place, so a failed arm can put
# back the shim a working home was already using rather than an equivalent
# rewrite.
shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-dispatch-pickup-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So the one rule after a
# failed or interrupted arm is that the home never holds a shim without a
# matching trust binding.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-dispatch-pickup: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-dispatch-pickup: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-dispatch-pickup: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-dispatch-pickup: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-dispatch-pickup: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

ACTION=${1:-check}
[ "$#" -eq 0 ] || shift
case "$ACTION" in
  check)
    [ "$#" -eq 0 ] || die_usage 'check takes no arguments'
    action_check
    ;;
  arm)
    [ "$#" -eq 0 ] || die_usage 'arm takes no arguments'
    action_arm
    ;;
  disarm)
    [ "$#" -eq 0 ] || die_usage 'disarm takes no arguments'
    action_disarm
    ;;
  claim)
    [ "$#" -eq 2 ] || die_usage 'claim needs a task id and an issue URL'
    action_claim "$1" "$2"
    ;;
  bind)
    [ "$#" -eq 2 ] || die_usage 'bind needs a task id and an issue URL'
    action_bind "$1" "$2"
    ;;
  report)
    [ "$#" -ge 2 ] || die_usage 'report needs a task id and an outcome'
    action_report "$@"
    ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $ACTION" ;;
esac
