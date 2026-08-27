#!/usr/bin/env bash
# Tests for fm-dispatch-pickup.sh, the cross-machine work dispatch pickup.
#
# The transport is a GitHub issue: another machine opens one carrying a spec and
# the label fm:dispatched, this machine polls for it, builds it, and reports the
# outcome back into that same issue. Two properties decide whether that is safe
# rather than merely working, and both are exercised here rather than asserted:
#
#   1. A second poll over the same issue creates nothing. The issue URL is the
#      key, the task record carries it as issue=<url>, and claiming refuses when
#      any record already holds it. test_a_second_poll_over_the_same_issue_
#      creates_nothing drives the whole loop twice and counts the claim comments
#      on the issue, so a build that happened twice cannot pass.
#   2. The relabel to fm:building happens BEFORE the worker is spawned. A crash
#      in that window must leave an issue visibly stuck rather than one the next
#      poll builds again, so test_a_claim_that_never_became_a_task_is_reported_
#      not_offered_again asserts both halves: the issue is named as stuck AND it
#      is not offered for pickup.
#
# Every case runs against a mock forge (fake gh and gh-axi over a directory of
# issue files) rather than GitHub, so no case reads or writes a real repository.
# The mocks are deliberately strict: an invocation neither of them recognizes
# fails the case instead of being absorbed, so a query this script stops making
# correctly cannot keep passing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PICKUP="$ROOT/bin/fm-dispatch-pickup.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-pickup)

fm_git_identity fmtest fmtest@example.invalid

# --- the mock forge ---------------------------------------------------------
#
# One file per issue under $FM_MOCK_GH_DIR/<owner>--<repo>/<number>.issue:
#   state=OPEN|CLOSED
#   title=<one line>
#   label=<name>            (repeated)
# and a sibling <number>.comments holding one line per posted comment.

make_mocks() {
  local bin=$1
  mkdir -p "$bin"

  cat > "$bin/gh" <<'SH'
#!/usr/bin/env bash
# Mock gh: only the two read queries fm-dispatch-pickup.sh makes are answered.
set -u
[ "${FM_MOCK_GH_FAIL_READ:-0}" = 1 ] && exit 1
issue_file() { printf '%s/%s--%s/%s.issue\n' "$FM_MOCK_GH_DIR" "${2%%/*}" "${2#*/}" "$1"; }
labels_of() { sed -n 's/^label=//p' "$1"; }
sub=${1:-}; shift || true
[ "$sub" = issue ] || { printf 'mock gh: unsupported command %s\n' "$sub" >&2; exit 2; }
verb=${1:-}; shift || true
repo=; json=; label=; number=
case "$verb" in
  view) number=$1; shift ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    -R) repo=$2; shift 2 ;;
    --json) json=$2; shift 2 ;;
    --label) label=$2; shift 2 ;;
    --jq|--limit|--state) shift 2 ;;
    *) printf 'mock gh: unsupported flag %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "$verb:$json" in
  list:number,title)
    # A repository this mock forge does not host is an error, as it is for real
    # gh. Answering "no issues" instead would let a build that polled the wrong
    # project - or a project that is not on GitHub at all - look clean.
    [ -d "$FM_MOCK_GH_DIR/${repo%%/*}--${repo#*/}" ] || exit 1
    for f in "$FM_MOCK_GH_DIR/${repo%%/*}--${repo#*/}"/*.issue; do
      [ -e "$f" ] || continue
      grep -q '^state=OPEN$' "$f" || continue
      labels_of "$f" | grep -q -x -F "$label" || continue
      n=$(basename "$f" .issue)
      # Deliberately NOT applying the query's own control-character strip, so a
      # title's whitespace reaches the script and its second line of defence is
      # exercised rather than assumed.
      t=$(sed -n 's/^title=//p' "$f" | head -n 1)
      printf '%s\t%s\n' "$n" "$t"
    done
    ;;
  view:state,labels)
    f=$(issue_file "$number" "$repo")
    [ -f "$f" ] || exit 1
    sed -n 's/^state=//p' "$f" | head -n 1
    labels_of "$f"
    # FM_MOCK_GH_SLOW_VIEW widens the window between reading an issue and acting
    # on what was read, so a case can put two pickups inside it on purpose.
    [ "${FM_MOCK_GH_SLOW_VIEW:-0}" = 0 ] || sleep "$FM_MOCK_GH_SLOW_VIEW"
    ;;
  *) printf 'mock gh: unsupported query %s %s\n' "$verb" "$json" >&2; exit 2 ;;
esac
exit 0
SH

  cat > "$bin/gh-axi" <<'SH'
#!/usr/bin/env bash
# Mock gh-axi: only the three writes fm-dispatch-pickup.sh makes are accepted.
# FM_MOCK_GHAXI_NOOP makes every write exit 0 while changing nothing, which is
# how a forge CLI that reports success without applying the change is simulated.
set -u
[ "${FM_MOCK_GHAXI_FAIL:-0}" = 1 ] && exit 1
sub=${1:-}; shift || true
[ "$sub" = issue ] || { printf 'mock gh-axi: unsupported command %s\n' "$sub" >&2; exit 2; }
verb=${1:-}; shift || true
number=${1:-}; shift || true
repo=; add=(); remove=(); body_file=; reason=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -R) repo=$2; shift 2 ;;
    --add-label) add+=("$2"); shift 2 ;;
    --remove-label) remove+=("$2"); shift 2 ;;
    --body-file) body_file=$2; shift 2 ;;
    --reason) reason=$2; shift 2 ;;
    *) printf 'mock gh-axi: unsupported flag %s\n' "$1" >&2; exit 2 ;;
  esac
done
f="$FM_MOCK_GH_DIR/${repo%%/*}--${repo#*/}/$number.issue"
[ -f "$f" ] || exit 1
case "$verb" in
  edit)
    [ "${FM_MOCK_GHAXI_NOOP:-0}" = 1 ] && exit 0
    for l in ${remove[@]+"${remove[@]}"}; do
      grep -v -x -F "label=$l" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done
    for l in ${add[@]+"${add[@]}"}; do
      grep -q -x -F "label=$l" "$f" || printf 'label=%s\n' "$l" >> "$f"
    done
    ;;
  comment)
    [ "${FM_MOCK_GHAXI_FAIL_COMMENT:-0}" = 1 ] && exit 1
    [ -f "$body_file" ] || exit 1
    [ "${FM_MOCK_GHAXI_NOOP:-0}" = 1 ] && exit 0
    tr '\n' ' ' < "$body_file" >> "${f%.issue}.comments"
    printf '\n' >> "${f%.issue}.comments"
    ;;
  close)
    [ "$reason" = completed ] || exit 1
    [ "${FM_MOCK_GHAXI_NOOP:-0}" = 1 ] && exit 0
    sed 's/^state=OPEN$/state=CLOSED/' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    ;;
  *) printf 'mock gh-axi: unsupported verb %s\n' "$verb" >&2; exit 2 ;;
esac
exit 0
SH
  chmod 0755 "$bin/gh" "$bin/gh-axi"
}

# --- fixtures ---------------------------------------------------------------

REPO_SLUG=fmtest-owner/fmtest-repo

# make_home <name>: a home with state/, projects/, a mock forge, and one clone
# whose origin points at REPO_SLUG. Echoes the home path.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/projects" "$home/mock/${REPO_SLUG%%/*}--${REPO_SLUG#*/}"
  make_mocks "$home/bin"
  add_clone "$home" fmtest-repo "https://github.com/$REPO_SLUG.git"
  printf '%s\n' "$home"
}

# add_clone <home> <dir-name> <origin-url>: a git repository under the home's
# projects dir pointing at the given origin.
add_clone() {
  local home=$1 name=$2 origin=$3
  git -C "$home/projects" init -q "$name"
  [ -z "$origin" ] || git -C "$home/projects/$name" remote add origin "$origin"
}

# seed_issue <home> <number> <title> <label>...
seed_issue() {
  local home=$1 number=$2 title=$3 dir f label
  shift 3
  dir="$home/mock/${REPO_SLUG%%/*}--${REPO_SLUG#*/}"
  mkdir -p "$dir"
  f="$dir/$number.issue"
  {
    printf 'state=OPEN\n'
    printf 'title=%s\n' "$title"
    for label in "$@"; do printf 'label=%s\n' "$label"; done
  } > "$f"
  : > "${f%.issue}.comments"
}

issue_field() { # <home> <number> <key>
  sed -n "s/^$3=//p" "$1/mock/${REPO_SLUG%%/*}--${REPO_SLUG#*/}/$2.issue"
}

issue_comments() { # <home> <number>
  cat "$1/mock/${REPO_SLUG%%/*}--${REPO_SLUG#*/}/$2.comments" 2>/dev/null
}

issue_url_for() { # <number>
  printf 'https://github.com/%s/issues/%s\n' "$REPO_SLUG" "$1"
}

# write_task <home> <id> [issue-url]: the task record a spawn would have left.
write_task() {
  local home=$1 id=$2 url=${3:-}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/wt-$id" \
    "project=$home/projects/fmtest-repo" \
    "harness=echo" \
    "kind=crew"
  [ -z "$url" ] || printf 'issue=%s\n' "$url" >> "$home/state/$id.meta"
}

# run_pickup <home> <out> -- <args...>: run the script with the home's mock
# forge first on PATH and the cadence gate open, capturing combined output.
# Echoes nothing; sets RUN_STATUS.
RUN_STATUS=0
run_pickup() {
  local home=$1 out=$2
  shift 2
  RUN_STATUS=0
  env FM_HOME="$home" \
    FM_MOCK_GH_DIR="$home/mock" \
    PATH="$home/bin:$PATH" \
    FM_CHECK_TIMEOUT=30 \
    FM_DISPATCH_PICKUP_INTERVAL=0 \
    "$PICKUP" "$@" >"$out" 2>&1 || RUN_STATUS=$?
}

# --- the two properties this script exists for ------------------------------

test_a_second_poll_over_the_same_issue_creates_nothing() {
  local home out url report
  home=$(make_home second-poll)
  seed_issue "$home" 7 'Add rate limiting' fm:dispatched
  url=$(issue_url_for 7)
  out="$home/out.txt"

  run_pickup "$home" "$out" check
  expect_code 0 "$RUN_STATUS" "first check exit"
  assert_contains "$(cat "$out")" "ready to pick up $REPO_SLUG#7" "the first poll did not offer the dispatched issue"

  run_pickup "$home" "$out" claim fm-first "$url"
  expect_code 0 "$RUN_STATUS" "first claim exit"
  write_task "$home" fm-first
  run_pickup "$home" "$out" bind fm-first "$url"
  expect_code 0 "$RUN_STATUS" "first bind exit"
  assert_grep "issue=$url" "$home/state/fm-first.meta" "bind did not record the issue on the task record"

  # The second poll: nothing is offered, because the issue left fm:dispatched
  # and the task record now claims it.
  run_pickup "$home" "$out" check
  expect_code 0 "$RUN_STATUS" "second check exit"
  report=$(cat "$out")
  [ -z "$report" ] || fail "a second poll over an already-built issue reported: $report"

  # And a second claim of the same issue is refused by name, which is what makes
  # a double-click, a re-poll, and a crash-and-retry all safe.
  run_pickup "$home" "$out" claim fm-second "$url"
  [ "$RUN_STATUS" -ne 0 ] || fail "a second claim of the same issue succeeded"
  assert_contains "$(cat "$out")" "already claimed by task fm-first" "the refusal did not name the task already holding the issue"

  write_task "$home" fm-second
  run_pickup "$home" "$out" bind fm-second "$url"
  [ "$RUN_STATUS" -ne 0 ] || fail "a second task bound itself to an issue another task already claims"
  assert_no_grep "issue=$url" "$home/state/fm-second.meta" "the refused bind still wrote the issue onto the second task"

  # The count is the proof: one pickup means exactly one claim comment.
  [ "$(issue_comments "$home" 7 | grep -c 'Picked up by firstmate')" = 1 ] \
    || fail "the issue carries $(issue_comments "$home" 7 | grep -c 'Picked up by firstmate') pickup comments, so it was picked up more than once"
  pass "a second poll, claim, and bind over the same issue all create nothing"
}

test_a_claim_that_never_became_a_task_is_reported_not_offered_again() {
  local home out report
  # Exactly the crash window the relabel-before-spawn order creates: the issue
  # is fm:building and no task record claims it. It must be named as stuck, and
  # it must NOT be offered for pickup, or the next poll would build it twice.
  home=$(make_home stuck-building)
  seed_issue "$home" 11 'Half-claimed work' fm:building
  out="$home/out.txt"
  run_pickup "$home" "$out" check
  expect_code 0 "$RUN_STATUS" "check exit"
  report=$(cat "$out")
  assert_contains "$report" "marked building with no task $REPO_SLUG#11" "an issue claimed but never spawned was not reported as stuck"
  assert_not_contains "$report" "ready to pick up" "an issue already marked building was offered for pickup again"
  pass "a claim that never became a task is reported as stuck, not offered for pickup again"
}

test_two_concurrent_pickups_of_one_issue_produce_one_claim() {
  local home url a b pids status_a status_b wins comments
  # The refusal is a read followed by a write, so it has a window: both pickups
  # can read "nobody claims this" and read the issue as still dispatched before
  # either relabels, and the second relabel then verifies clean because the
  # labels are already where it wanted them. The slow read below puts two real
  # pickups inside that window rather than reasoning about it.
  home=$(make_home concurrent)
  seed_issue "$home" 5 'Contended work' fm:dispatched
  url=$(issue_url_for 5)
  a="$home/a.txt"
  b="$home/b.txt"
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_MOCK_GH_SLOW_VIEW=1 "$PICKUP" claim fm-race-a "$url" >"$a" 2>&1 &
  pids=$!
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_MOCK_GH_SLOW_VIEW=1 "$PICKUP" claim fm-race-b "$url" >"$b" 2>&1 &
  status_a=0; status_b=0
  wait "$pids" || status_a=$?
  wait $! || status_b=$?

  wins=0
  [ "$status_a" -eq 0 ] && wins=$((wins + 1))
  [ "$status_b" -eq 0 ] && wins=$((wins + 1))
  [ "$wins" = 1 ] || fail "two concurrent pickups of one issue produced $wins claims (a: $(cat "$a"); b: $(cat "$b"))"
  comments=$(issue_comments "$home" 5 | grep -c 'Picked up by firstmate')
  [ "$comments" = 1 ] || fail "one issue carries $comments pickup comments after two concurrent pickups"
  pass "two concurrent pickups of one issue produce exactly one claim"
}

test_claim_relabels_before_it_returns_and_names_the_task() {
  local home out labels
  home=$(make_home claim-order)
  seed_issue "$home" 3 'Do the thing' fm:dispatched
  out="$home/out.txt"
  run_pickup "$home" "$out" claim fm-order "$(issue_url_for 3)"
  expect_code 0 "$RUN_STATUS" "claim exit"

  # The relabel must already have landed by the time claim returns, because the
  # caller spawns next and a crash between the two must leave building, not
  # dispatched.
  labels=$(issue_field "$home" 3 label)
  assert_contains "$labels" 'fm:building' "claim returned without the issue labelled fm:building"
  assert_not_contains "$labels" 'fm:dispatched' "claim left the issue still labelled fm:dispatched"
  assert_contains "$(issue_comments "$home" 3)" 'fm-order' "the claim comment does not name the task"
  pass "claim relabels to building and names the task before it returns"
}

# --- outcomes ---------------------------------------------------------------

test_built_outcome_comments_labels_and_closes() {
  local home out url labels
  home=$(make_home built)
  seed_issue "$home" 21 'Ship it' fm:building
  url=$(issue_url_for 21)
  write_task "$home" fm-built "$url"
  out="$home/out.txt"
  run_pickup "$home" "$out" report fm-built --built --message 'Landed as https://github.com/o/r/pull/9'
  expect_code 0 "$RUN_STATUS" "report --built exit"

  labels=$(issue_field "$home" 21 label)
  assert_contains "$labels" 'fm:built' "a built outcome did not label the issue fm:built"
  assert_not_contains "$labels" 'fm:building' "a built outcome left the issue labelled fm:building"
  [ "$(issue_field "$home" 21 state)" = CLOSED ] || fail "a built outcome did not close the issue"
  assert_contains "$(issue_comments "$home" 21)" 'pull/9' "the outcome comment does not name the delivered work"
  pass "a built outcome comments the result, labels fm:built, and closes the issue"
}

test_blocked_outcome_leaves_the_issue_open() {
  local home out url labels
  home=$(make_home blocked)
  seed_issue "$home" 22 'Cannot build this' fm:building
  url=$(issue_url_for 22)
  write_task "$home" fm-blocked "$url"
  out="$home/out.txt"
  run_pickup "$home" "$out" report fm-blocked --blocked --message 'The spec needs a decision about the storage format'
  expect_code 0 "$RUN_STATUS" "report --blocked exit"

  labels=$(issue_field "$home" 22 label)
  assert_contains "$labels" 'fm:blocked' "a failure did not label the issue fm:blocked"
  assert_not_contains "$labels" 'fm:building' "a failure left the issue labelled fm:building"
  # The whole point: a failure the captain never sees again is worse than none.
  [ "$(issue_field "$home" 22 state)" = OPEN ] || fail "a failure closed its own issue instead of leaving it open"
  assert_contains "$(issue_comments "$home" 22)" 'storage format' "the failure comment does not carry the reason"
  pass "a failure labels fm:blocked, says why, and leaves the issue open"
}

test_report_refuses_a_task_that_carries_no_issue() {
  local home out
  home=$(make_home no-issue)
  write_task "$home" fm-plain
  out="$home/out.txt"
  run_pickup "$home" "$out" report fm-plain --built --message 'done'
  [ "$RUN_STATUS" -ne 0 ] || fail "a report succeeded for a task carrying no dispatched issue"
  assert_contains "$(cat "$out")" 'carries no dispatched issue' "the refusal does not say the task carries no issue"
  pass "a report refuses a task that carries no dispatched issue"
}

# --- refusals that keep one issue to one build ------------------------------

test_bind_refuses_an_issue_that_was_never_claimed() {
  local home out
  # An issue still labelled dispatched is one the poll still offers. Binding a
  # task to it would let a worker adopt work nobody claimed, and the poll would
  # hand the same issue to a second worker.
  home=$(make_home unclaimed-bind)
  seed_issue "$home" 31 'Still waiting' fm:dispatched
  write_task "$home" fm-adopt
  out="$home/out.txt"
  run_pickup "$home" "$out" bind fm-adopt "$(issue_url_for 31)"
  [ "$RUN_STATUS" -ne 0 ] || fail "a task bound itself to an issue that was never claimed"
  assert_contains "$(cat "$out")" 'was never claimed' "the refusal does not say the issue was never claimed"
  assert_no_grep 'issue=' "$home/state/fm-adopt.meta" "the refused bind still wrote an issue onto the task record"
  pass "bind refuses an issue that was never claimed"
}

test_claim_refuses_an_issue_that_is_not_dispatched() {
  local home out
  home=$(make_home not-dispatched)
  seed_issue "$home" 32 'Already building' fm:building
  out="$home/out.txt"
  run_pickup "$home" "$out" claim fm-late "$(issue_url_for 32)"
  [ "$RUN_STATUS" -ne 0 ] || fail "claim accepted an issue that is not labeled fm:dispatched"
  assert_contains "$(cat "$out")" 'not labeled fm:dispatched' "the refusal does not name the missing label"
  pass "claim refuses an issue that is not waiting to be picked up"
}

test_claim_refuses_a_task_id_that_already_exists() {
  local home out
  home=$(make_home existing-task)
  seed_issue "$home" 33 'Fresh work' fm:dispatched
  write_task "$home" fm-taken
  out="$home/out.txt"
  run_pickup "$home" "$out" claim fm-taken "$(issue_url_for 33)"
  [ "$RUN_STATUS" -ne 0 ] || fail "claim reused an existing task id"
  assert_contains "$(issue_field "$home" 33 label)" 'fm:dispatched' "the refused claim still relabelled the issue"
  pass "claim refuses a task id that already exists, before writing anything"
}

test_a_write_that_does_not_land_is_refused() {
  local home out
  # A forge CLI that exits 0 without applying the change would leave the
  # relabel-before-spawn ordering silently inoperative. Every write is read back.
  home=$(make_home noop-write)
  seed_issue "$home" 41 'Quietly ignored' fm:dispatched
  out="$home/out.txt"
  RUN_STATUS=0
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_MOCK_GHAXI_NOOP=1 FM_DISPATCH_PICKUP_INTERVAL=0 \
    "$PICKUP" claim fm-noop "$(issue_url_for 41)" >"$out" 2>&1 || RUN_STATUS=$?
  [ "$RUN_STATUS" -ne 0 ] || fail "claim reported success after a relabel that never landed"
  assert_contains "$(cat "$out")" 'nothing was claimed' "the refusal does not say the claim did not happen"
  assert_contains "$(issue_field "$home" 41 label)" 'fm:dispatched' "the issue changed despite the write being a no-op"
  pass "a relabel that reports success without landing is refused, not trusted"
}

test_a_claim_whose_comment_fails_says_the_relabel_landed() {
  local home out
  # The relabel is first on purpose, so this window exists. What must not happen
  # is a caller being told nothing happened while the issue is already building.
  home=$(make_home comment-fails)
  seed_issue "$home" 42 'Comment will fail' fm:dispatched
  out="$home/out.txt"
  RUN_STATUS=0
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_MOCK_GHAXI_FAIL_COMMENT=1 FM_DISPATCH_PICKUP_INTERVAL=0 \
    "$PICKUP" claim fm-halfway "$(issue_url_for 42)" >"$out" 2>&1 || RUN_STATUS=$?
  [ "$RUN_STATUS" -ne 0 ] || fail "a claim whose comment failed reported plain success"
  assert_contains "$(cat "$out")" 'could not comment' "the message does not name the step that failed"
  assert_contains "$(cat "$out")" 'run bind' "the message does not tell the caller how to recover"
  assert_contains "$(issue_field "$home" 42 label)" 'fm:building' "the relabel did not land before the comment was attempted"
  pass "a claim whose comment fails reports that the relabel already landed"
}

# --- reading, and failing to read -------------------------------------------

test_unreachable_github_is_reported_not_an_empty_list() {
  local home out report
  home=$(make_home unreachable)
  seed_issue "$home" 51 'Waiting out there' fm:dispatched
  out="$home/out.txt"
  RUN_STATUS=0
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_MOCK_GH_FAIL_READ=1 FM_CHECK_TIMEOUT=30 FM_DISPATCH_PICKUP_INTERVAL=0 \
    "$PICKUP" check >"$out" 2>&1 || RUN_STATUS=$?
  expect_code 0 "$RUN_STATUS" "check exit"
  report=$(cat "$out")
  [ -n "$report" ] || fail "an unreachable forge produced the same silence as nothing dispatched"
  assert_contains "$report" "could not read $REPO_SLUG" "the report does not name the repository that could not be read"
  pass "an unreachable forge is reported by name, never as an empty list"
}

test_missing_gh_is_reported_not_silence() {
  local home out reduced
  home=$(make_home no-gh)
  seed_issue "$home" 52 'Unreadable' fm:dispatched
  rm -f "$home/bin/gh"
  # The system directories carry the ordinary tools the check shells out to, and
  # a forge CLI is not an ordinary tool, so this is the honest absence fixture.
  # A host that ships gh in one of them cannot express it, so say so and skip
  # rather than pass a case that never tested anything.
  reduced="$home/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  if PATH="$reduced" command -v gh >/dev/null 2>&1; then
    printf 'skip: this host has gh in a system directory, so its absence cannot be staged\n'
    return 0
  fi
  out="$home/out.txt"
  RUN_STATUS=0
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$reduced" \
    FM_CHECK_TIMEOUT=30 FM_DISPATCH_PICKUP_INTERVAL=0 \
    "$PICKUP" check >"$out" 2>&1 || RUN_STATUS=$?
  expect_code 0 "$RUN_STATUS" "check exit"
  assert_contains "$(cat "$out")" 'gh is not on PATH' "a missing forge CLI read as nothing dispatched"
  pass "a missing forge CLI is reported, not read as nothing dispatched"
}

test_nothing_dispatched_is_silent() {
  local home out
  home=$(make_home quiet)
  seed_issue "$home" 61 'Someone else concern' bug
  out="$home/out.txt"
  run_pickup "$home" "$out" check
  expect_code 0 "$RUN_STATUS" "check exit"
  [ ! -s "$out" ] || fail "a repository with nothing dispatched reported: $(cat "$out")"
  pass "a repository with nothing dispatched is silent"
}

test_a_clone_without_a_github_origin_is_skipped_silently() {
  local home out
  # A local-only project is a registered posture, not a fault, so it must not
  # turn into a finding the operator has to dismiss on every poll.
  home=$(make_home local-only)
  add_clone "$home" local-thing ''
  add_clone "$home" elsewhere 'https://git.example.invalid/o/r.git'
  out="$home/out.txt"
  run_pickup "$home" "$out" check
  expect_code 0 "$RUN_STATUS" "check exit"
  [ ! -s "$out" ] || fail "a clone with no GitHub origin produced a finding: $(cat "$out")"
  pass "a clone with no GitHub origin is skipped in silence"
}

test_several_findings_and_an_odd_title_stay_one_line() {
  local home out lines report
  # The whole report is one line, because it becomes one wake record. Several
  # findings must not become several records, and a title is captain-typed text
  # whose own whitespace must not split a finding either.
  home=$(make_home odd-title)
  seed_issue "$home" 71 "$(printf 'Tabbed\ttitle')" fm:dispatched
  seed_issue "$home" 72 'Second waiting item' fm:dispatched
  seed_issue "$home" 73 'Stuck item' fm:building
  out="$home/out.txt"
  run_pickup "$home" "$out" check
  expect_code 0 "$RUN_STATUS" "check exit"
  lines=$(wc -l < "$out" | tr -d '[:space:]')
  [ "$lines" = 1 ] || fail "the report is $lines lines; it must be exactly one for the wake record"
  report=$(cat "$out")
  assert_contains "$report" "$REPO_SLUG#71" "the first waiting issue is missing from the one-line report"
  assert_contains "$report" "$REPO_SLUG#72" "the second waiting issue is missing from the one-line report"
  assert_contains "$report" "$REPO_SLUG#73" "the stuck issue is missing from the one-line report"
  case "$report" in
    *"$(printf '\t')"*) fail "a tab from an issue title survived into the wake record" ;;
  esac
  pass "several findings and an odd title still make exactly one line"
}

# --- cadence ----------------------------------------------------------------

test_findings_are_reported_once_until_they_change() {
  local home out
  home=$(make_home report-once)
  seed_issue "$home" 81 'Waiting' fm:dispatched
  out="$home/out.txt"
  run_pickup "$home" "$out" check
  assert_contains "$(cat "$out")" "$REPO_SLUG#81" "the first poll did not report the waiting issue"

  run_pickup "$home" "$out" check
  [ ! -s "$out" ] || fail "the same unchanged finding was reported twice in a row: $(cat "$out")"

  seed_issue "$home" 82 'Also waiting' fm:dispatched
  run_pickup "$home" "$out" check
  assert_contains "$(cat "$out")" "$REPO_SLUG#82" "a new waiting issue was suppressed as an unchanged finding"
  pass "findings are reported once until the finding set changes"
}

test_an_unchanged_finding_set_is_reported_again_after_the_renag() {
  local home out first
  # Reporting once is what keeps one waiting issue from waking firstmate every
  # poll. On its own it would let work nobody picked up go quiet forever, so an
  # unchanged set is news again once the re-nag interval has passed.
  home=$(make_home renag)
  seed_issue "$home" 91 'Nobody picked this up' fm:dispatched
  out="$home/out.txt"
  first=1000000
  RUN_STATUS=0
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_CHECK_TIMEOUT=30 FM_DISPATCH_PICKUP_INTERVAL=0 FM_DISPATCH_PICKUP_RENAG=3600 \
    FM_DISPATCH_PICKUP_NOW="$first" "$PICKUP" check >"$out" 2>&1 || RUN_STATUS=$?
  assert_contains "$(cat "$out")" "$REPO_SLUG#91" "the first poll did not report the waiting issue"

  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_CHECK_TIMEOUT=30 FM_DISPATCH_PICKUP_INTERVAL=0 FM_DISPATCH_PICKUP_RENAG=3600 \
    FM_DISPATCH_PICKUP_NOW="$((first + 60))" "$PICKUP" check >"$out" 2>&1 || true
  [ ! -s "$out" ] || fail "an unchanged finding was re-reported before the re-nag interval: $(cat "$out")"

  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_CHECK_TIMEOUT=30 FM_DISPATCH_PICKUP_INTERVAL=0 FM_DISPATCH_PICKUP_RENAG=3600 \
    FM_DISPATCH_PICKUP_NOW="$((first + 3600))" "$PICKUP" check >"$out" 2>&1 || true
  assert_contains "$(cat "$out")" "$REPO_SLUG#91" "work nobody picked up went quiet forever instead of being reported again"
  pass "an unchanged finding set is reported again once the re-nag interval passes"
}

test_probes_are_skipped_between_intervals() {
  local home out
  home=$(make_home interval)
  seed_issue "$home" 95 'Waiting' fm:dispatched
  out="$home/out.txt"
  RUN_STATUS=0
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_CHECK_TIMEOUT=30 FM_DISPATCH_PICKUP_INTERVAL=900 FM_DISPATCH_PICKUP_NOW=2000000 \
    "$PICKUP" check >"$out" 2>&1 || RUN_STATUS=$?
  assert_contains "$(cat "$out")" "$REPO_SLUG#95" "the first poll did not report the waiting issue"

  # A new issue inside the interval must not be probed for at all.
  seed_issue "$home" 96 'Arrived a minute later' fm:dispatched
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_CHECK_TIMEOUT=30 FM_DISPATCH_PICKUP_INTERVAL=900 FM_DISPATCH_PICKUP_NOW=2000060 \
    "$PICKUP" check >"$out" 2>&1 || true
  [ ! -s "$out" ] || fail "the check probed inside its own interval: $(cat "$out")"

  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_CHECK_TIMEOUT=30 FM_DISPATCH_PICKUP_INTERVAL=900 FM_DISPATCH_PICKUP_NOW=2000901 \
    "$PICKUP" check >"$out" 2>&1 || true
  assert_contains "$(cat "$out")" "$REPO_SLUG#96" "the check did not probe again once its interval had passed"
  pass "probes are skipped between intervals and resume after one"
}

test_an_oversized_budget_is_cut_to_fit_and_reported() {
  local home out
  home=$(make_home budget-cut)
  out="$home/out.txt"
  RUN_STATUS=0
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_CHECK_TIMEOUT=10 FM_DISPATCH_PICKUP_INTERVAL=0 FM_DISPATCH_PICKUP_BUDGET_SECS=90 \
    "$PICKUP" check >"$out" 2>&1 || RUN_STATUS=$?
  expect_code 0 "$RUN_STATUS" "check exit"
  assert_contains "$(cat "$out")" 'sweep budget 90s cut to 7s' "an oversized sweep budget was not cut to fit the watcher check timeout"
  pass "a sweep budget larger than the watcher allows is cut to fit and reported"
}

# --- arguments and arming ---------------------------------------------------

test_invalid_arguments_refuse() {
  local home out
  home=$(make_home invalid)
  out="$home/out.txt"

  run_pickup "$home" "$out" nonsense
  expect_code 2 "$RUN_STATUS" "unknown action exit"

  run_pickup "$home" "$out" claim fm-x 'https://github.com/o/r/pull/3'
  [ "$RUN_STATUS" -ne 0 ] || fail "claim accepted a pull request URL as an issue"

  run_pickup "$home" "$out" claim fm-x 'http://github.com/o/r/issues/3'
  [ "$RUN_STATUS" -ne 0 ] || fail "claim accepted a non-https issue URL"

  run_pickup "$home" "$out" claim ../escape "$(issue_url_for 1)"
  [ "$RUN_STATUS" -ne 0 ] || fail "claim accepted a path-traversing task id"

  RUN_STATUS=0
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_DISPATCH_PICKUP_INTERVAL=17 "$PICKUP" check >"$out" 2>&1 || RUN_STATUS=$?
  expect_code 2 "$RUN_STATUS" "out-of-range interval exit"
  pass "invalid actions, URLs, task ids, and environment values all refuse"
}

test_arm_registers_the_check_and_disarm_removes_it() {
  local home
  home=$(make_home arm)
  FM_HOME="$home" "$PICKUP" arm >/dev/null || fail "arm failed"
  assert_present "$home/state/dispatch-pickup.check.sh" "arm did not write the check shim"
  assert_present "$home/state/dispatch-pickup.check-trust" "arm did not write the trust binding"
  [ "$(stat -f %Lp "$home/state/dispatch-pickup.check.sh" 2>/dev/null \
    || stat -c %a "$home/state/dispatch-pickup.check.sh")" = 700 ] \
    || fail "the check shim is not mode 0700"
  FM_HOME="$home" "$PICKUP" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/dispatch-pickup.check.sh" "disarm left the check shim"
  assert_absent "$home/state/dispatch-pickup.check-trust" "disarm left the trust binding"
  pass "arm registers the check shim and disarm removes it"
}

test_armed_check_wakes_the_watcher_with_the_dispatched_report() {
  local home out err status
  # End to end through the real watcher: the armed check must reach it as an
  # ordinary `check:` wake carrying the same report, with no new machinery.
  home=$(make_home wake)
  seed_issue "$home" 101 'Dispatched from the other machine' fm:dispatched
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  FM_HOME="$home" "$PICKUP" arm >/dev/null || fail "could not arm the dispatched-issue check"

  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_CHECK_TIMEOUT=30 FM_DISPATCH_PICKUP_INTERVAL=0 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds 10 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "the armed check did not reach the watcher as a check wake"
  assert_contains "$(cat "$out")" "dispatched work: ready to pick up $REPO_SLUG#101" "the wake did not carry the dispatched-work report"
  pass "the armed check reaches the watcher as an ordinary check wake"
}

test_a_second_poll_over_the_same_issue_creates_nothing
test_a_claim_that_never_became_a_task_is_reported_not_offered_again
test_two_concurrent_pickups_of_one_issue_produce_one_claim
test_claim_relabels_before_it_returns_and_names_the_task
test_built_outcome_comments_labels_and_closes
test_blocked_outcome_leaves_the_issue_open
test_report_refuses_a_task_that_carries_no_issue
test_bind_refuses_an_issue_that_was_never_claimed
test_claim_refuses_an_issue_that_is_not_dispatched
test_claim_refuses_a_task_id_that_already_exists
test_a_write_that_does_not_land_is_refused
test_a_claim_whose_comment_fails_says_the_relabel_landed
test_unreachable_github_is_reported_not_an_empty_list
test_missing_gh_is_reported_not_silence
test_nothing_dispatched_is_silent
test_a_clone_without_a_github_origin_is_skipped_silently
test_several_findings_and_an_odd_title_stay_one_line
test_findings_are_reported_once_until_they_change
test_an_unchanged_finding_set_is_reported_again_after_the_renag
test_probes_are_skipped_between_intervals
test_an_oversized_budget_is_cut_to_fit_and_reported
test_invalid_arguments_refuse
test_arm_registers_the_check_and_disarm_removes_it
test_armed_check_wakes_the_watcher_with_the_dispatched_report
