#!/usr/bin/env bash
# Regression tests for secondmate home seeding's pool-slot fence.
#
# Seeding a secondmate home with "-" leases a firstmate worktree from the pool
# through `treehouse get --lease`. Treehouse reports a slot available whenever
# no process sits in it, so a parked firstmate-repo task whose agent died still
# owns its slot in this home's records while treehouse would hand that slot to
# the new home and reset it. fm-spawn's own fence and backstop are covered by
# tests/fm-spawn-pool-slot-ownership.test.sh.
#
# - The real-treehouse case seeds against a throwaway pool whose lowest slot
#   belongs to a parked task with no process in it, and proves the home lands in
#   a different slot and the parked copy is left on its commit. It skips, saying
#   so, when no treehouse with --lease support is installed.
# - The portable cases prove seeding refuses, without returning it to the pool,
#   a leased home another live record in this home still names, and that a
#   secondmate spawn refuses such a home before its pre-launch sync can move it.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-home-seed-pool-fence)
export FM_BACKEND=tmux

commit_all() {  # <repo> <message>
  git -C "$1" add -A
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$2"
}

test_seed_skips_slot_owned_by_parked_task() {
  local case_dir home root origin fakebin real_th th_home parked_slot parked_head out status home_line seeded
  real_th=$(command -v treehouse 2>/dev/null || true)
  if [ -z "$real_th" ] || ! "$real_th" get --help 2>&1 | grep -q -- '--lease'; then
    echo "skip: treehouse with --lease not installed; the real-treehouse seed fence case did not run"
    return 0
  fi
  case_dir="$TMP_ROOT/real-treehouse"
  home="$case_dir/home"
  root="$case_dir/root"
  origin="$case_dir/origin.git"
  th_home="$case_dir/treehouse-home"
  mkdir -p "$th_home" "$home/projects" "$home/data" "$home/state"
  # A firstmate code root whose pool is private to this case.
  git clone --quiet "$ROOT" "$root"
  # CI checks out a detached HEAD with no branches, so give the pool a main.
  git -C "$root" checkout --quiet -B main
  printf 'max_trees = 4\nroot = "%s/pool-root"\n' "$case_dir" > "$root/treehouse.toml"
  commit_all "$root" treehouse
  git clone --quiet --bare "$root" "$origin"
  git -C "$root" remote set-url origin "file://$origin"
  git -C "$root" fetch --quiet origin

  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
HOME='$th_home' exec '$real_th' "\$@"
SH
  chmod +x "$fakebin/treehouse"

  # The parked firstmate-repo task: it owns slot 1, clean and detached, but its
  # agent is gone, so nothing sits in the slot and treehouse reports it free.
  parked_slot=$(cd "$root" && "$fakebin/treehouse" get --lease --lease-holder setup 2>/dev/null)
  [ -n "$parked_slot" ] || fail "fixture could not acquire a treehouse slot"
  (cd "$root" && "$fakebin/treehouse" return --force "$parked_slot" >/dev/null 2>&1) \
    || fail "fixture could not release the parked slot's lease"
  parked_head=$(git -C "$parked_slot" rev-parse HEAD)
  (cd "$root" && "$fakebin/treehouse" status 2>/dev/null) \
    | grep -F "$parked_slot" | grep -q 'available' \
    || fail "fixture did not leave the parked slot reporting available"
  fm_write_meta "$home/state/parked-task.meta" \
    "window=firstmate:fm-parked-task" \
    "endpoint_task_id=parked-task" \
    "worktree=$parked_slot" \
    "project=$root" \
    "kind=ship" \
    "mode=no-mistakes"
  # Origin moves on, so a reset of the parked slot is visible on its HEAD.
  printf 'later\n' > "$root/later.txt"
  commit_all "$root" later
  git -C "$root" push --quiet origin HEAD:main

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_SECONDMATE_CHARTER='fence scope' FM_SECONDMATE_SCOPE='fence scope' \
    "$ROOT/bin/fm-home-seed.sh" fence - --no-projects 2>&1)
  status=$?
  expect_code 0 "$status" "seed should succeed in an unowned slot: $out"
  home_line=$(printf '%s\n' "$out" | grep '^home=' | tail -1)
  seeded=${home_line#home=}
  [ -n "$seeded" ] || fail "seed reported no home: $out"
  [ "$(cd "$seeded" && pwd -P)" != "$(cd "$parked_slot" && pwd -P)" ] \
    || fail "seed leased the parked task's slot $parked_slot as the secondmate home"
  [ "$(git -C "$parked_slot" rev-parse HEAD)" = "$parked_head" ] \
    || fail "leasing a home moved the parked task's copy off its checked-out commit"
  [ ! -e "$parked_slot/.fm-secondmate-home" ] || fail "seed marked the parked task's copy as a secondmate home"
  pass "secondmate home seeding skips a pool slot a parked task still owns and leaves that copy untouched"
}

test_seed_refuses_home_another_task_records() {
  local case_dir home acquired acquired_abs fakebin log lease err
  case_dir="$TMP_ROOT/seed-refusal"
  home="$case_dir/home"
  acquired="$case_dir/acquired"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  git clone --quiet "$ROOT" "$acquired"
  acquired_abs=$(cd "$acquired" && pwd -P)
  fakebin=$(make_fake_tmux "$case_dir/fake")
  log="$case_dir/fake/tmux.log"
  lease="$case_dir/fake/lease"
  fm_write_meta "$home/state/older-task.meta" \
    "window=firstmate:fm-older-task" \
    "endpoint_task_id=older-task" \
    "worktree=$acquired" \
    "project=$ROOT" \
    "kind=ship" \
    "mode=no-mistakes"
  err="$case_dir/err"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" \
    FM_SECONDMATE_CHARTER='refusal scope' FM_SECONDMATE_SCOPE='refusal scope' \
    "$ROOT/bin/fm-home-seed.sh" refusal - --no-projects >/dev/null 2>"$err"; then
    fail "seed accepted a leased home another live task records"
  fi
  assert_grep 'older-task' "$err" "seed refusal did not name the task that owns the copy"
  [ ! -e "$acquired/.fm-secondmate-home" ] || fail "a refused seed still marked the other task's copy"
  [ ! -e "$home/data/secondmates.md" ] || ! grep -q refusal "$home/data/secondmates.md" \
    || fail "a refused seed still registered the secondmate"
  grep -F "treehouse return" "$log" | grep -F "$acquired_abs" >/dev/null \
    && fail "a refused seed returned the other task's copy to the pool"
  pass "secondmate home seeding refuses a leased home another live task record still names"
}

test_secondmate_spawn_refuses_home_another_task_records() {
  local case_dir home sub fakebin log err
  case_dir="$TMP_ROOT/spawn-refusal"
  home="$case_dir/home"
  sub="$case_dir/subhome"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fakebin=$(make_fake_tmux "$case_dir/fake")
  log="$case_dir/fake/tmux.log"
  FM_HOME="$home" FM_SECONDMATE_CHARTER='spawn refusal scope' FM_SECONDMATE_SCOPE='spawn refusal scope' \
    "$ROOT/bin/fm-home-seed.sh" smref "$sub" --no-projects >/dev/null 2>&1 \
    || fail "fixture could not seed the secondmate home"
  fm_write_meta "$home/state/older-task.meta" \
    "window=firstmate:fm-older-task" \
    "endpoint_task_id=older-task" \
    "worktree=$sub" \
    "project=$ROOT" \
    "kind=ship" \
    "mode=no-mistakes"
  : > "$log"
  err="$case_dir/err"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TMUX_CAPTURE="$case_dir/fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" smref "$sub" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn launched on a home another live task records"
  fi
  assert_grep 'older-task' "$err" "secondmate spawn refusal did not name the task that owns the copy"
  [ ! -e "$home/state/smref.meta" ] || fail "a refused secondmate spawn still published a task record"
  grep -q 'new-window' "$log" && fail "a refused secondmate spawn still opened a window: $(cat "$log")"
  pass "secondmate spawn refuses a home another live task record still names"
}

test_seed_skips_slot_owned_by_parked_task
test_seed_refuses_home_another_task_records
test_secondmate_spawn_refuses_home_another_task_records

echo "# all fm-home-seed-pool-fence tests passed"
