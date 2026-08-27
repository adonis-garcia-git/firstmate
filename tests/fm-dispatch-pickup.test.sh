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
# a sibling <number>.comments.d/<seq>.body holding each posted comment verbatim,
# so a comment read back is the bytes that were posted rather than a summary of
# them, and per-repository .labels (the labels the repository has) and
# .issues-disabled (Issues turned off) alongside them.

make_mocks() {
  local bin=$1
  mkdir -p "$bin"

  cat > "$bin/gh" <<'SH'
#!/usr/bin/env bash
# Mock gh: only the read queries fm-dispatch-pickup.sh makes are answered.
# FM_MOCK_GH_CALLS names a file this appends one line to per invocation, so a
# case can assert how many forge round trips a sweep costs rather than inferring
# it from how long the sweep took.
set -u
[ -z "${FM_MOCK_GH_CALLS:-}" ] || printf '%s\n' "$*" >> "$FM_MOCK_GH_CALLS"
[ "${FM_MOCK_GH_FAIL_READ:-0}" = 1 ] && exit 1
repo_dir() { printf '%s/%s--%s\n' "$FM_MOCK_GH_DIR" "${1%%/*}" "${1#*/}"; }
labels_of() { sed -n 's/^label=//p' "$1"; }
sub=${1:-}; shift || true
case "$sub" in
  issue|repo|label) ;;
  *) printf 'mock gh: unsupported command %s\n' "$sub" >&2; exit 2 ;;
esac
verb=${1:-}; shift || true
repo=; json=; label=; number=; jq=; search=
case "$sub:$verb" in
  issue:view) number=$1; shift ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    -R) repo=$2; shift 2 ;;
    --json) json=$2; shift 2 ;;
    --label) label=$2; shift 2 ;;
    --jq) jq=$2; shift 2 ;;
    --search) search=$2; shift 2 ;;
    --limit|--state) shift 2 ;;
    *) printf 'mock gh: unsupported flag %s\n' "$1" >&2; exit 2 ;;
  esac
done
d=$(repo_dir "$repo")
case "$sub:$verb:$json" in
  issue:list:number,title)
    # A repository this mock forge does not host is an error, as it is for real
    # gh. Answering "no issues" instead would let a build that polled the wrong
    # project - or a project that is not on GitHub at all - look clean.
    [ -d "$d" ] || exit 1
    # A repository with Issues turned off answers exactly as real gh does: the
    # listing fails outright rather than coming back empty. FM_MOCK_GH_FAIL_LIST
    # is the other half of that fixture - a listing that fails while the
    # repository itself still answers, which is an outage and not a posture.
    [ -e "$d/.issues-disabled" ] && exit 1
    [ "${FM_MOCK_GH_FAIL_LIST:-0}" = 1 ] && exit 1
    for f in "$d"/*.issue; do
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
  issue:view:state,labels)
    f="$d/$number.issue"
    [ -f "$f" ] || exit 1
    sed -n 's/^state=//p' "$f" | head -n 1
    labels_of "$f"
    # FM_MOCK_GH_SLOW_VIEW widens the window between reading an issue and acting
    # on what was read, so a case can put two pickups inside it on purpose.
    [ "${FM_MOCK_GH_SLOW_VIEW:-0}" = 0 ] || sleep "$FM_MOCK_GH_SLOW_VIEW"
    ;;
  issue:view:comments)
    f="$d/$number.issue"
    [ -f "$f" ] || exit 1
    cd="${f%.issue}.comments.d"
    newest=
    for c in "$cd"/*.body; do [ -e "$c" ] || continue; newest=$c; done
    case "$jq" in
      *'[-1].id'*)
        # jq answers null for the newest comment of an issue with none, so an
        # issue that has never been commented on is not confusable with one id.
        if [ -n "$newest" ]; then printf 'IC%s\n' "$(basename "$newest" .body)"; else printf 'null\n'; fi
        ;;
      *'[-1].body'*)
        if [ -n "$newest" ]; then cat "$newest"; else printf 'null\n'; fi
        ;;
      *) printf 'mock gh: unsupported comments query %s\n' "$jq" >&2; exit 2 ;;
    esac
    ;;
  repo:view:hasIssuesEnabled)
    [ -d "$d" ] || exit 1
    if [ -e "$d/.issues-disabled" ]; then printf 'false\n'; else printf 'true\n'; fi
    ;;
  label:list:name)
    [ -d "$d" ] || exit 1
    [ -f "$d/.labels" ] || exit 0
    grep -F -- "$search" "$d/.labels" || true
    ;;
  *) printf 'mock gh: unsupported query %s %s %s\n' "$sub" "$verb" "$json" >&2; exit 2 ;;
esac
exit 0
SH

  cat > "$bin/gh-axi" <<'SH'
#!/usr/bin/env bash
# Mock gh-axi: only the three writes fm-dispatch-pickup.sh makes are accepted.
# FM_MOCK_GHAXI_NOOP makes every write exit 0 while changing nothing, which is
# how a forge CLI that reports success without applying the change is simulated.
# FM_MOCK_GHAXI_NOOP_COMMENT is the same fixture narrowed to the comment write,
# so a case can reach the comment step with the label writes still working.
# FM_MOCK_GHAXI_CALLS names a file this appends one line to per invocation, so a
# case can assert that a command performed no forge write at all.
set -u
[ -z "${FM_MOCK_GHAXI_CALLS:-}" ] || printf '%s\n' "$*" >> "$FM_MOCK_GHAXI_CALLS"
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
    # Real gh resolves a label name to an id and fails the whole edit when the
    # repository does not carry that label, so an unknown label is an error
    # here too rather than a label this mock invents.
    for l in ${add[@]+"${add[@]}"}; do
      [ -f "${f%/*}/.labels" ] && grep -q -x -F "$l" "${f%/*}/.labels" || exit 1
    done
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
    [ "${FM_MOCK_GHAXI_NOOP_COMMENT:-0}" = 1 ] && exit 0
    d="${f%.issue}.comments.d"
    mkdir -p "$d"
    n=0
    for c in "$d"/*.body; do [ -e "$c" ] || continue; n=$((n + 1)); done
    cp "$body_file" "$d/$(printf '%03d' "$((n + 1))").body"
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
# A second GitHub-backed repository, for the cases about what one repository's
# issues cost the repositories swept after it.
OTHER_SLUG=fmtest-owner/fmtest-other

# A comment claiming the issue for somewhere else, in the shape an earlier design
# used as an ownership marker. The poll reads no comments at all now, so this is
# here to prove that: an issue carrying it is still reported. Its backticks are
# literal markdown in a comment body, never a substitution.
# shellcheck disable=SC2016
FOREIGN_CLAIM_TEXT='Picked up by firstmate as task `fm-elsewhere` on machine `other-machine`.'

# make_home <name>: a home with state/, projects/, a mock forge, and one clone
# whose origin points at REPO_SLUG. Echoes the home path.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/projects"
  make_mocks "$home/bin"
  add_repo "$home" "$REPO_SLUG" fmtest-repo
  printf '%s\n' "$home"
}

# add_repo <home> <slug> <clone-dir>: a GitHub-backed clone in the home plus the
# mock forge directory that hosts it. The repository has the four fm labels plus
# one unrelated one, so a write-side label is only missing in the case that
# stages it missing.
add_repo() {
  local home=$1 slug=$2 clone=$3 dir
  dir=$(repo_dir_of "$home" "$slug")
  mkdir -p "$dir"
  printf '%s\n' fm:dispatched fm:building fm:built fm:blocked bug > "$dir/.labels"
  add_clone "$home" "$clone" "https://github.com/$slug.git"
}

# repo_dir_of <home> <slug>: the mock forge directory for that repository.
repo_dir_of() {
  printf '%s/mock/%s--%s\n' "$1" "${2%%/*}" "${2#*/}"
}

# repo_dir <home>: the mock forge directory for REPO_SLUG in that home.
repo_dir() {
  repo_dir_of "$1" "$REPO_SLUG"
}

# add_clone <home> <dir-name> <origin-url>: a git repository under the home's
# projects dir pointing at the given origin.
add_clone() {
  local home=$1 name=$2 origin=$3
  git -C "$home/projects" init -q "$name"
  [ -z "$origin" ] || git -C "$home/projects/$name" remote add origin "$origin"
}

# seed_issue_in <home> <slug> <number> <title> <label>...
seed_issue_in() {
  local home=$1 slug=$2 number=$3 title=$4 dir f label
  shift 4
  dir=$(repo_dir_of "$home" "$slug")
  mkdir -p "$dir"
  f="$dir/$number.issue"
  {
    printf 'state=OPEN\n'
    printf 'title=%s\n' "$title"
    for label in "$@"; do printf 'label=%s\n' "$label"; done
  } > "$f"
  rm -rf -- "${f%.issue}.comments.d"
}

# seed_issue <home> <number> <title> <label>...
seed_issue() {
  local home=$1
  shift
  seed_issue_in "$home" "$REPO_SLUG" "$@"
}

# seed_comment_in <home> <slug> <number> <body>: a comment already on the issue,
# the way a pickup on another machine would have left one.
seed_comment_in() {
  local home=$1 slug=$2 number=$3 body=$4 d c n=0
  d="$(repo_dir_of "$home" "$slug")/$number.comments.d"
  mkdir -p "$d"
  for c in "$d"/*.body; do [ -e "$c" ] || continue; n=$((n + 1)); done
  printf '%s\n' "$body" > "$d/$(printf '%03d' "$((n + 1))").body"
}

# seed_comment <home> <number> <body>
seed_comment() {
  local home=$1
  shift
  seed_comment_in "$home" "$REPO_SLUG" "$@"
}

issue_field() { # <home> <number> <key>
  sed -n "s/^$3=//p" "$(repo_dir "$1")/$2.issue"
}

issue_comments() { # <home> <number>; one flattened line per comment
  local d c
  d="$(repo_dir "$1")/$2.comments.d"
  [ -d "$d" ] || return 0
  for c in "$d"/*.body; do
    [ -e "$c" ] || continue
    tr '\n' ' ' < "$c"
    printf '\n'
  done
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

test_every_unclaimed_building_issue_is_reported_as_anomalous() {
  local home out report
  # The poll does not ask whose build it is. It reads no comments and
  # distinguishes no machine: an open fm:building issue with no task record HERE
  # is anomalous and gets named, whatever is written on it. That is the whole
  # policy, and the three shapes below are the ones a marker-matching design
  # would have treated differently from each other.
  home=$(make_home anomalous)

  # A comment that claims the issue for somewhere else. An ownership marker read
  # from comment text is arbitrary third-party content, so it buys silence about
  # a genuinely stuck issue and nothing else; it is ignored.
  seed_issue "$home" 12 'Carries a foreign claim comment' fm:building
  seed_comment "$home" 12 "$FOREIGN_CLAIM_TEXT"

  # This home's own claim that never became a task: the real crash window. The
  # claim runs for real rather than being staged, so the comment under test is
  # the one this home actually writes.
  seed_issue "$home" 13 'Claimed here and then crashed' fm:dispatched
  out="$home/out.txt"
  run_pickup "$home" "$out" claim fm-crashed "$(issue_url_for 13)"
  expect_code 0 "$RUN_STATUS" "claim exit"

  # And a hand-labelled issue carrying no comments at all.
  seed_issue "$home" 14 'Labelled by hand, never claimed' fm:building

  run_pickup "$home" "$out" check
  expect_code 0 "$RUN_STATUS" "check exit"
  report=$(cat "$out")
  assert_contains "$report" "marked building with no task $REPO_SLUG#12" \
    "an issue was silenced by a claim comment naming somewhere else, which is how a stuck issue goes quiet forever"
  assert_contains "$report" "marked building with no task $REPO_SLUG#13" "this home's own crashed claim went unreported"
  assert_contains "$report" "marked building with no task $REPO_SLUG#14" "an issue with no comments at all went unreported"
  pass "every unclaimed building issue is reported as anomalous, whatever it carries"
}

test_many_building_issues_do_not_starve_the_next_repository() {
  local home out report calls n
  # The sweep budget is shared by every repository, so a probe that scales with
  # issue count lets one busy repository use it up and every repository after it
  # is never polled - the same repositories, every poll, forever. Nothing in the
  # sweep costs a call per issue now, and the count is what proves it; silence
  # would also hold while exactly that starvation was happening.
  # Titles are kept short on purpose: every one of these is now reported, and the
  # whole report is one capped line, so the second repository's finding has to
  # still fit inside it for its absence to mean it was never swept.
  home=$(make_home no-starve)
  add_repo "$home" "$OTHER_SLUG" zz-other-repo
  n=1
  while [ "$n" -le 12 ]; do
    seed_issue "$home" "$((300 + n))" "B$n" fm:building
    n=$((n + 1))
  done
  seed_issue_in "$home" "$OTHER_SLUG" 9 'Waiting' fm:dispatched

  out="$home/out.txt"
  calls="$home/calls.txt"
  : > "$calls"
  RUN_STATUS=0
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_MOCK_GH_CALLS="$calls" FM_CHECK_TIMEOUT=30 FM_DISPATCH_PICKUP_INTERVAL=0 \
    "$PICKUP" check >"$out" 2>&1 || RUN_STATUS=$?
  expect_code 0 "$RUN_STATUS" "check exit"
  report=$(cat "$out")
  assert_contains "$report" "ready to pick up $OTHER_SLUG#9" \
    "a repository full of building issues starved the next repository out of the sweep"
  n=$(wc -l < "$calls" | tr -d '[:space:]')
  # Two label listings per repository is the whole cost of a clean sweep, so
  # anything approaching one call per issue is a per-issue probe.
  [ "$n" -le 8 ] || fail "the sweep made $n forge calls for 12 building issues, so it probes per issue"
  pass "many building issues cost no extra forge calls and do not starve the next repository"
}

test_a_truncated_building_list_says_it_was_cut() {
  local home out report n
  # The same invariant the dispatched pass already holds: a sweep that hits the
  # query cap says so rather than presenting a truncated list as the whole of
  # what is stuck. Every issue here has a task record behind it, so the cut
  # notice is the only finding and cannot be crowded out of the line cap.
  home=$(make_home building-cut)
  n=1
  while [ "$n" -le 50 ]; do
    seed_issue "$home" "$((200 + n))" "Building here $n" fm:building
    write_task "$home" "fm-c$n" "$(issue_url_for "$((200 + n))")"
    n=$((n + 1))
  done
  out="$home/out.txt"
  run_pickup "$home" "$out" check
  expect_code 0 "$RUN_STATUS" "check exit"
  report=$(cat "$out")
  assert_contains "$report" "$REPO_SLUG has at least 50 issues marked building, so this list is cut" \
    "a stuck-issue list that hit the query cap was presented as the complete set"
  assert_not_contains "$report" 'marked building with no task' "an issue with a task record behind it was reported as anomalous"
  pass "a stuck-issue list that hits the query cap says it was cut"
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

test_bind_writes_nothing_to_the_forge() {
  local home out url writes
  # bind records and nothing else. It once posted a claim comment to keep an
  # ownership marker on the issue; that whole mechanism is gone, so bind must be
  # a pure recorder again - safe to re-run, and incapable of touching an issue
  # another machine is building.
  home=$(make_home bind-silent)
  seed_issue "$home" 34 'Claimed, awaiting its record' fm:building
  url=$(issue_url_for 34)
  write_task "$home" fm-recorded
  out="$home/out.txt"
  writes="$home/writes.txt"
  : > "$writes"
  RUN_STATUS=0
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_MOCK_GHAXI_CALLS="$writes" FM_DISPATCH_PICKUP_INTERVAL=0 \
    "$PICKUP" bind fm-recorded "$url" >"$out" 2>&1 || RUN_STATUS=$?
  expect_code 0 "$RUN_STATUS" "bind exit"
  assert_grep "issue=$url" "$home/state/fm-recorded.meta" "bind did not record the issue on the task record"
  [ ! -s "$writes" ] || fail "bind made $(wc -l < "$writes" | tr -d '[:space:]') forge write calls: $(cat "$writes")"
  [ -z "$(issue_comments "$home" 34)" ] || fail "bind left a comment on the issue: $(issue_comments "$home" 34)"
  pass "bind records the issue and writes nothing to the forge"
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

test_a_claim_comment_that_does_not_post_is_refused() {
  local home out
  # The comment is the durable record the other machine reads, so a forge CLI
  # that exits 0 without posting must not pass as a claim. The relabel still
  # landed, and the refusal has to say so rather than reading as "nothing
  # happened", which would invite a second claim.
  home=$(make_home noop-claim-comment)
  seed_issue "$home" 43 'Claim comment vanishes' fm:dispatched
  out="$home/out.txt"
  RUN_STATUS=0
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_MOCK_GHAXI_NOOP_COMMENT=1 FM_DISPATCH_PICKUP_INTERVAL=0 \
    "$PICKUP" claim fm-vanish "$(issue_url_for 43)" >"$out" 2>&1 || RUN_STATUS=$?
  [ "$RUN_STATUS" -ne 0 ] || fail "claim reported success after a comment that never posted"
  assert_contains "$(cat "$out")" 'may not have posted' "the refusal does not say the comment may not have posted"
  assert_contains "$(cat "$out")" 'run bind' "the refusal does not tell the caller how to recover"
  assert_contains "$(issue_field "$home" 43 label)" 'fm:building' "the relabel did not land before the comment was attempted"
  [ -z "$(issue_comments "$home" 43)" ] || fail "the issue carries a comment the write was supposed to have dropped"
  pass "a claim comment that reports success without posting is refused, not trusted"
}

test_an_outcome_comment_that_does_not_post_never_closes_the_issue() {
  local home out url labels
  # The worst shape of this bug: a closed issue with no outcome on it. The
  # captain would never see the issue again and the record of what happened
  # would exist nowhere, so the comment is confirmed before the label and the
  # close, not after.
  home=$(make_home noop-report-comment)
  seed_issue "$home" 44 'Outcome comment vanishes' fm:building
  url=$(issue_url_for 44)
  write_task "$home" fm-silent "$url"
  out="$home/out.txt"
  RUN_STATUS=0
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_MOCK_GHAXI_NOOP_COMMENT=1 FM_DISPATCH_PICKUP_INTERVAL=0 \
    "$PICKUP" report fm-silent --built --message 'Landed as https://github.com/o/r/pull/9' \
    >"$out" 2>&1 || RUN_STATUS=$?
  [ "$RUN_STATUS" -ne 0 ] || fail "a report reported success after an outcome comment that never posted"
  assert_contains "$(cat "$out")" 'may not have posted' "the refusal does not say the comment may not have posted"
  [ "$(issue_field "$home" 44 state)" = OPEN ] || fail "the issue was closed even though its outcome comment never posted"
  labels=$(issue_field "$home" 44 label)
  assert_not_contains "$labels" 'fm:built' "the issue was labelled fm:built even though its outcome comment never posted"
  assert_contains "$labels" 'fm:building' "the issue left fm:building even though nothing was reported on it"
  pass "an outcome comment that never posts stops the report before the label and the close"
}

test_a_missing_write_label_is_named_by_the_refusal() {
  local home out
  # A hand-created issue can carry fm:dispatched on a repository where nobody
  # created the three write-side labels. GitHub resolves a label name to an id
  # and fails the whole edit, and every retry fails the same way, so the
  # refusal has to name the prerequisite instead of reading like an outage.
  home=$(make_home missing-label)
  seed_issue "$home" 45 'Nowhere to move it to' fm:dispatched
  printf '%s\n' fm:dispatched > "$(repo_dir "$home")/.labels"
  out="$home/out.txt"
  run_pickup "$home" "$out" claim fm-nolabel "$(issue_url_for 45)"
  [ "$RUN_STATUS" -ne 0 ] || fail "claim succeeded against a repository with no fm:building label"
  assert_contains "$(cat "$out")" "the label fm:building does not exist in $REPO_SLUG" \
    "the refusal does not name the missing label and the repository it is missing from"
  assert_contains "$(cat "$out")" 'must be created in that repository first' \
    "the refusal does not say the label has to be created there"
  assert_contains "$(issue_field "$home" 45 label)" 'fm:dispatched' "the refused claim still relabelled the issue"
  pass "a relabel that fails on a missing label names the label and the repository"
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

test_issues_disabled_is_silent_but_a_failed_list_stays_loud() {
  local home out
  # A repository with GitHub Issues turned off cannot host a dispatched issue
  # at all. That is a registered posture like a clone with no GitHub origin, so
  # it must be silent rather than a false "unreachable" finding re-nagged
  # forever. The second half is what keeps that from swallowing a real outage:
  # a listing that fails while the repository itself still answers is loud.
  home=$(make_home issues-off)
  : > "$(repo_dir "$home")/.issues-disabled"
  out="$home/out.txt"
  run_pickup "$home" "$out" check
  expect_code 0 "$RUN_STATUS" "check exit"
  [ ! -s "$out" ] || fail "a repository with Issues turned off produced a finding: $(cat "$out")"

  home=$(make_home list-fails)
  seed_issue "$home" 55 'Waiting behind an outage' fm:dispatched
  out="$home/out.txt"
  RUN_STATUS=0
  env FM_HOME="$home" FM_MOCK_GH_DIR="$home/mock" PATH="$home/bin:$PATH" \
    FM_MOCK_GH_FAIL_LIST=1 FM_CHECK_TIMEOUT=30 FM_DISPATCH_PICKUP_INTERVAL=0 \
    "$PICKUP" check >"$out" 2>&1 || RUN_STATUS=$?
  expect_code 0 "$RUN_STATUS" "check exit"
  assert_contains "$(cat "$out")" "could not read $REPO_SLUG" \
    "a listing that failed on a repository that still answers was swallowed as a posture"
  pass "a repository with Issues turned off is silent, and a failed listing is still loud"
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
test_every_unclaimed_building_issue_is_reported_as_anomalous
test_many_building_issues_do_not_starve_the_next_repository
test_a_truncated_building_list_says_it_was_cut
test_two_concurrent_pickups_of_one_issue_produce_one_claim
test_claim_relabels_before_it_returns_and_names_the_task
test_built_outcome_comments_labels_and_closes
test_blocked_outcome_leaves_the_issue_open
test_report_refuses_a_task_that_carries_no_issue
test_bind_refuses_an_issue_that_was_never_claimed
test_bind_writes_nothing_to_the_forge
test_claim_refuses_an_issue_that_is_not_dispatched
test_claim_refuses_a_task_id_that_already_exists
test_a_write_that_does_not_land_is_refused
test_a_claim_whose_comment_fails_says_the_relabel_landed
test_a_claim_comment_that_does_not_post_is_refused
test_an_outcome_comment_that_does_not_post_never_closes_the_issue
test_a_missing_write_label_is_named_by_the_refusal
test_unreachable_github_is_reported_not_an_empty_list
test_issues_disabled_is_silent_but_a_failed_list_stays_loud
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
