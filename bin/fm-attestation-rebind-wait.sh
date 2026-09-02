#!/usr/bin/env bash
# fm-attestation-rebind-wait.sh - wait for the no-mistakes gate to rebind the
# PR-body attestation to this event's head, then export the live PR facts.
#
# The `Require no-mistakes` check first judges the PR body carried by the
# triggering event.
# The pipeline pushes a head and rewrites the PR body moments later, and GitHub
# does not reliably deliver a fresh `edited` check run for a body rewrite that
# lands seconds after a push, so a stale-body `synchronize` failure can stay the
# check's latest verdict for a head whose live body is already compliant.
# This helper closes that gap: it waits, bounded, for the live body's
# attestation to bind the event's head, then appends the live facts to
# GITHUB_OUTPUT so the workflow can re-judge them with the same pinned shared
# action.
# The attestation extraction below is only a wait heuristic - the compliance
# verdict always comes from the pinned action, never from repo-owned logic.
#
# Usage (from the Require no-mistakes workflow, after a failed event verdict):
#   GITHUB_REPOSITORY=<owner/repo> PR_NUMBER=<n> EVENT_HEAD_SHA=<sha> \
#   GITHUB_OUTPUT=<file> bin/fm-attestation-rebind-wait.sh
#
# Outputs appended to GITHUB_OUTPUT on success: head-sha, body (multiline).
# Exit 0 when the live attestation binds the event head.
# Exit 1 when a newer push superseded this event (that push's own run governs)
# or the rebind did not land within the wait budget.
set -eu

ATTEMPTS="${FM_REBIND_WAIT_ATTEMPTS:-24}"
INTERVAL="${FM_REBIND_WAIT_INTERVAL_SECONDS:-15}"

for tool in gh jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is required to poll the live pull request" >&2
    exit 1
  fi
done
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${EVENT_HEAD_SHA:?EVENT_HEAD_SHA is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

ATTESTATION_PREFIX='<!-- no-mistakes-pipeline-attestation:v1 '

attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
  if [ "$attempt" -gt 1 ]; then
    sleep "$INTERVAL"
  fi

  if ! live=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER" 2>&1); then
    echo "attempt $attempt/$ATTEMPTS: could not read the live pull request, retrying: $live"
    attempt=$((attempt + 1))
    continue
  fi

  live_head=$(printf '%s' "$live" | jq -r '.head.sha // empty' 2>/dev/null) || live_head=""
  if [ -z "$live_head" ]; then
    echo "attempt $attempt/$ATTEMPTS: live pull request response had no head SHA, retrying"
    attempt=$((attempt + 1))
    continue
  fi

  if [ "$live_head" != "$EVENT_HEAD_SHA" ]; then
    {
      echo "error: a newer push superseded this event's head, so this run's verdict no longer governs the PR."
      echo "event head: $EVENT_HEAD_SHA"
      echo "live head:  $live_head"
      echo "The compliance run for the newer head decides; this run stays failed."
    } >&2
    exit 1
  fi

  live_body=$(printf '%s' "$live" | jq -r '.body // ""' 2>/dev/null) || live_body=""

  # Heuristic extraction of the attested head, used only to decide whether the
  # rebind has landed; the pinned action re-parses and judges the real body.
  attested_json=$(printf '%s\n' "$live_body" \
    | sed -n "s/.*$ATTESTATION_PREFIX\\(.*\\) -->.*/\\1/p" \
    | head -n 1)
  attested_head=""
  if [ -n "$attested_json" ]; then
    attested_head=$(printf '%s' "$attested_json" | jq -r '.head_sha // empty' 2>/dev/null) || attested_head=""
  fi

  if [ -n "$attested_head" ] && [ "$attested_head" = "$live_head" ]; then
    echo "attempt $attempt/$ATTEMPTS: live attestation binds the event head $live_head; exporting live PR facts"
    delim="fm-rebind-body-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    {
      printf 'head-sha=%s\n' "$live_head"
      printf 'body<<%s\n' "$delim"
      printf '%s\n' "$live_body"
      printf '%s\n' "$delim"
    } >>"$GITHUB_OUTPUT"
    exit 0
  fi

  echo "attempt $attempt/$ATTEMPTS: live attestation binds '${attested_head:-none}', waiting for the gate to rebind $EVENT_HEAD_SHA"
  attempt=$((attempt + 1))
done

{
  echo "error: the PR body attestation did not rebind to $EVENT_HEAD_SHA within the wait budget."
  echo "If the no-mistakes gate has since rewritten the PR body, re-run this failed job - it re-judges the live body."
  echo "Otherwise drive the branch through the gate again, or run 'no-mistakes rerun' when the stale-attested tip is already the pipeline-pushed head."
  echo "A gate older than no-mistakes v1.60.2 never restamps the attestation onto its own CI-repair pushes, so when the pipeline pushed this head, upgrade the gate before the rerun or the next repair cycle wedges the check the same way."
  echo "See CONTRIBUTING.md for the full recovery contract."
} >&2
exit 1
