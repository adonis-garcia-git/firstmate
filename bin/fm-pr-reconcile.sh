#!/usr/bin/env bash
# Reconcile recorded PRs against GitHub: detection and surfacing only.
#
# Firstmate keeps two kinds of PR records that can outlive the PR itself:
#   - pr= lines in state/<id>.meta task metadata
#   - GitHub PR URLs referenced by open (non-Done) items in data/backlog.md,
#     including captain-gated hold reasons and item body lines
# A PR merged or closed directly on the forge leaves those records stale, so a
# finished-and-parked task or a captain hold can keep re-surfacing a decision
# the forge already settled (the 2026-08-20 incident: three PRs merged/closed
# on GitHub while backlog holds kept asking the captain to merge them). This
# sweep detects that drift and surfaces it through the durable wake queue; the
# supervising firstmate session reconciles the records with full context. The
# sweep itself NEVER rewrites task metadata, backlog items, or anything under
# projects/ - there is no auto-clear path here.
#
# Usage: fm-pr-reconcile.sh [--force]
#
# Behavior:
#   - Self-throttled: runs at most once per FM_PR_RECONCILE_INTERVAL seconds
#     (default 3600), keyed on the state/.pr-reconcile-last mtime; --force
#     ignores the throttle. Callers (the fm-watch.sh check cadence and the
#     locked fm-bootstrap.sh sweep) can therefore invoke it unconditionally.
#   - Batched and bounded: all still-open recorded PRs are read in ONE
#     `gh api graphql` request, capped at FM_PR_RECONCILE_MAX URLs per sweep
#     (default 30) and bounded by FM_PR_RECONCILE_TIMEOUT seconds (default 20).
#     When more PRs are recorded than the cap, a rotating cursor
#     (state/.pr-reconcile-cursor) starts each sweep where the last one
#     stopped, so every recorded PR is covered across successive sweeps
#     instead of the tail being starved.
#   - GitHub only: URL candidates are validated with fm_pr_url_parse and only
#     provider=github records are queried. A GitLab merge request keeps its
#     per-task armed merge poll (bin/fm-pr-poll.sh); this sweep does not read
#     GitLab. Malformed or non-GitHub candidates are skipped silently.
#   - Cached: a PR observed MERGED or CLOSED is recorded in
#     state/.pr-reconcile-seen and never queried or surfaced again; cache
#     entries for URLs no longer recorded anywhere are pruned each sweep. An
#     armed per-task merge poll may also report the same merge; this cache and
#     the drain-time queue dedupe bound that overlap to at most one extra wake.
#   - Outcome: each newly merged or closed recorded PR queues one durable
#     check wake (fm_wake_append, key pr-reconcile:<owner>/<repo>#<n>) naming
#     the observed forge state and every task and backlog item still recording
#     the PR. Each queued payload is also printed to stdout, so a caller can
#     treat any output as "durable wakes were queued".
#   - Offline/auth failure: exits 0 with ONE diagnostic wake per failure
#     episode. state/.pr-reconcile-error dedupes the diagnostic until a sweep
#     reaches GitHub again; a failed sweep still advances the throttle so an
#     offline laptop is not hammered with retries. A GraphQL response that
#     carries errors (one recorded repo deleted or access lost) makes gh
#     bypass --jq and print the raw JSON body; that is NOT a failure episode:
#     per-alias states are recovered from the body and unresolvable aliases
#     become UNKNOWN, skipped and retried on a later sweep.
#   - Concurrency: a state/.pr-reconcile.lock singleton makes overlapping
#     invocations (watcher and bootstrap racing) exit 0 silently instead of
#     double-querying.
#
# Exit status: 0 for every routine outcome, including not-due, lock-busy,
# offline, and nothing-to-reconcile; nonzero only for unusable local state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

INTERVAL=${FM_PR_RECONCILE_INTERVAL:-3600}
MAX=${FM_PR_RECONCILE_MAX:-30}
TIMEOUT=${FM_PR_RECONCILE_TIMEOUT:-20}
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=3600 ;; esac
case "$MAX" in ''|*[!0-9]*|0) MAX=30 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*|0) TIMEOUT=20 ;; esac

LAST="$STATE/.pr-reconcile-last"
SEEN="$STATE/.pr-reconcile-seen"
ERRMARK="$STATE/.pr-reconcile-error"
LOCK="$STATE/.pr-reconcile.lock"

FORCE=0
[ "${1:-}" = --force ] && FORCE=1

if [ "$FORCE" -ne 1 ] && [ "$(fm_path_age "$LAST")" -lt "$INTERVAL" ]; then
  exit 0
fi

fm_lock_try_acquire "$LOCK" || exit 0
RECORDS=
GH_OUT=
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
reconcile_cleanup() {
  [ -z "$RECORDS" ] || rm -f -- "$RECORDS"
  [ -z "$GH_OUT" ] || rm -f -- "$GH_OUT" "$GH_OUT.parsed"
  fm_lock_release "$LOCK"
}
trap reconcile_cleanup EXIT
trap 'exit 1' HUP INT TERM

# Advance the throttle before the network read so a crash or an offline sweep
# cannot hot-loop the forge from a tight caller cadence (X mode polls checks
# every 30s).
touch "$LAST"

RECORDS=$(mktemp "$STATE/.fm-pr-reconcile.XXXXXX") || exit 1

# Trim the leading/trailing punctuation prose wraps around a URL token
# ("(https://...)", "https://...," etc.) so only an exact PR URL survives the
# strict parse below.
trim_url_token() {
  local t=$1
  while :; do
    case "$t" in
      "("*|"["*|"<"*|"'"*|'"'*) t=${t#?}; continue ;;
    esac
    case "$t" in
      *")"|*"]"|*">"|*","|*"."|*";"|*":"|*"!"|*"?"|*"'"|*'"') t=${t%?}; continue ;;
    esac
    break
  done
  printf '%s' "$t"
}

record_candidate() {  # <raw-token> <source-label>
  local raw=$1 label=$2
  raw=$(trim_url_token "$raw")
  fm_pr_url_parse "$raw" || return 0
  [ "$FM_PR_PROVIDER" = github ] || return 0
  printf '%s\t%s\n' "$FM_PR_URL" "$label" >> "$RECORDS"
}

# Source 1: pr= task metadata.
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  url=$(grep '^pr=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$url" ] || continue
  record_candidate "$url" "task $(basename "$meta" .meta)"
done

# Source 2: GitHub PR URLs inside open (non-Done) backlog items, conservatively:
# only whitespace-delimited tokens that are exactly a PR URL after punctuation
# trimming count, and only on an open item's own line or its continuation
# lines. A checked "- [x]" item or a new section heading closes the item.
BACKLOG="$DATA/backlog.md"
if [ -f "$BACKLOG" ] && [ ! -L "$BACKLOG" ]; then
  while IFS=$(printf '\t') read -r item line; do
    [ -n "$item" ] || continue
    case "$line" in *github.com*) ;; *) continue ;; esac
    read -r -a tokens <<< "$line"
    for tok in "${tokens[@]+"${tokens[@]}"}"; do
      case "$tok" in
        *github.com/*/pull/*) record_candidate "$tok" "backlog item $item" ;;
      esac
    done
  done < <(awk '
    /^- \[ \] /    { id=$4; if (id == "") id="(unnamed)"; print id "\t" $0; next }
    /^- \[[xX]\] / { id=""; next }
    /^#/           { id=""; next }
    { if (id != "") print id "\t" $0 }
  ' "$BACKLOG" 2>/dev/null)
fi

# Rewrite the seen cache keeping only URLs still recorded somewhere, plus the
# newly terminal observations appended by this sweep.
prune_seen() {
  local tmp
  [ -f "$SEEN" ] || return 0
  tmp=$(mktemp "$STATE/.fm-pr-seen.XXXXXX") || return 0
  if awk -F '\t' 'NR==FNR { live[$1]=1; next } ($1 in live) && !dup[$1]++' \
    "$RECORDS" "$SEEN" > "$tmp" 2>/dev/null; then
    mv -f -- "$tmp" "$SEEN"
  else
    rm -f -- "$tmp"
  fi
}

url_seen_terminal() {  # <url>
  [ -f "$SEEN" ] || return 1
  awk -F '\t' -v u="$1" \
    '$1 == u && ($2 == "MERGED" || $2 == "CLOSED") { found=1 } END { exit !found }' \
    "$SEEN" 2>/dev/null
}

# Unique recorded URLs in first-seen order, minus already-surfaced terminal
# observations.
eligible=()
while IFS= read -r u; do
  [ -n "$u" ] || continue
  url_seen_terminal "$u" && continue
  eligible+=("$u")
done < <(awk -F '\t' '!seen[$1]++ { print $1 }' "$RECORDS" 2>/dev/null)

if [ "${#eligible[@]}" -eq 0 ]; then
  prune_seen
  exit 0
fi

# Take at most MAX URLs for this sweep. When the record set exceeds the cap,
# a persisted cursor rotates the starting point so successive sweeps cover
# every recorded PR instead of starving the tail.
CURSOR="$STATE/.pr-reconcile-cursor"
total=${#eligible[@]}
start=$(cat "$CURSOR" 2>/dev/null || printf '0')
case "$start" in ''|*[!0-9]*) start=0 ;; esac
start=$((start % total))
to_query=()
i=0
while [ "$i" -lt "$total" ] && [ "${#to_query[@]}" -lt "$MAX" ]; do
  to_query+=("${eligible[$(( (start + i) % total ))]}")
  i=$((i + 1))
done
if [ "$total" -gt "$MAX" ]; then
  printf '%s\n' $(( (start + MAX) % total )) > "$CURSOR"
else
  rm -f -- "$CURSOR"
fi

# One batched GraphQL read for every queried PR. Owner, repo, and number were
# validated by fm_pr_url_parse (restricted charsets), so interpolation into the
# query is safe. gh's built-in --jq keeps this free of an external JSON
# processor, matching bin/fm-pr-poll.sh's toolchain footprint.
query='query {'
i=0
for u in "${to_query[@]}"; do
  fm_pr_url_parse "$u" || exit 1
  query="$query pr$i: repository(owner: \"$FM_PR_OWNER\", name: \"$FM_PR_REPO\") { pullRequest(number: $FM_PR_NUMBER) { state } }"
  i=$((i + 1))
done
query="$query }"

GH_OUT=$(mktemp "$STATE/.fm-pr-reconcile-gh.XXXXXX") || exit 1
gh api graphql -f query="$query" \
  --jq '.data | to_entries[] | .key + " " + ((.value.pullRequest.state)? // "UNKNOWN")' \
  > "$GH_OUT" 2>/dev/null &
gh_pid=$!
start=$SECONDS
while kill -0 "$gh_pid" 2>/dev/null; do
  if [ $((SECONDS - start)) -ge "$TIMEOUT" ]; then
    kill "$gh_pid" 2>/dev/null || true
    break
  fi
  sleep 1
done
wait "$gh_pid" 2>/dev/null || true

# When the GraphQL response carries errors (e.g. one batched repo was deleted
# or access was lost), gh bypasses the --jq filter and prints the raw JSON
# body instead of "pr<i> <STATE>" lines. The body still answers for the whole
# batch, so rewrite it into the same line format by extracting each alias from
# its fixed self-chosen shape ("pr<i>":{"pullRequest":{"state":"..."}}); an
# alias that is null or unparseable becomes UNKNOWN.
recover_raw_body() {
  tr -d ' \t\r\n' < "$GH_OUT" 2>/dev/null | awk -v n="${#to_query[@]}" '
    { body = body $0 }
    END {
      while (match(body, /"pr[0-9]+":(null|\{"pullRequest":(null|\{"state":"[A-Z_]+"\})\})/)) {
        entry = substr(body, RSTART, RLENGTH)
        body = substr(body, RSTART + RLENGTH)
        alias = entry
        sub(/^"/, "", alias)
        sub(/".*/, "", alias)
        state = "UNKNOWN"
        if (match(entry, /"state":"[A-Z_]+"/))
          state = substr(entry, RSTART + 9, RLENGTH - 10)
        states[alias] = state
      }
      for (i = 0; i < n; i++) {
        alias = "pr" i
        print alias " " ((alias in states) ? states[alias] : "UNKNOWN")
      }
    }
  ' > "$GH_OUT.parsed" 2>/dev/null
}

first=$(awk 'NF { print; exit }' "$GH_OUT" 2>/dev/null || true)
case "$first" in
  '{'*)
    if recover_raw_body; then
      mv -f -- "$GH_OUT.parsed" "$GH_OUT"
    else
      rm -f -- "$GH_OUT.parsed"
    fi
    ;;
esac

# Any well-formed "pr<i> <STATE>" line proves the forge answered; per-PR
# UNKNOWN entries (deleted repo, lost access) are skipped and simply retried
# on a later sweep.
reached=0
while IFS=' ' read -r alias st; do
  case "$alias" in pr*) ;; *) continue ;; esac
  idx=${alias#pr}
  case "$idx" in ''|*[!0-9]*) continue ;; esac
  [ "$idx" -lt "${#to_query[@]}" ] || continue
  case "$st" in OPEN|MERGED|CLOSED|UNKNOWN) reached=1 ;; *) continue ;; esac
  u=${to_query[$idx]}
  case "$st" in
    MERGED) verb='was merged' ;;
    CLOSED) verb='was closed without merging' ;;
    *) continue ;;
  esac
  sources=$(awk -F '\t' -v u="$u" \
    '$1 == u && !dup[$2]++ { printf "%s%s", (c++ ? ", " : ""), $2 }' "$RECORDS" 2>/dev/null)
  [ -n "$sources" ] || sources='an unresolved record'
  fm_pr_url_parse "$u" || continue
  payload="check: pr-reconcile: PR $u $verb on GitHub but is still recorded by $sources - reconcile the records (update the backlog item or hold; refresh the project clone if merged)"
  fm_wake_append check "pr-reconcile:$FM_PR_PATH#$FM_PR_NUMBER" "$payload" || exit 1
  printf '%s\t%s\n' "$u" "$st" >> "$SEEN"
  printf '%s\n' "$payload"
done < "$GH_OUT"

if [ "$reached" -eq 0 ]; then
  msg='could not read recorded PR state from GitHub (offline, unauthenticated, or rate-limited); recorded PRs not reconciled this sweep'
  if [ "$(cat "$ERRMARK" 2>/dev/null || true)" != "$msg" ]; then
    printf '%s' "$msg" > "$ERRMARK"
    fm_wake_append check pr-reconcile "check: pr-reconcile: $msg" || exit 1
    printf 'check: pr-reconcile: %s\n' "$msg"
  fi
  exit 0
fi

rm -f -- "$ERRMARK"
prune_seen
exit 0
