#!/usr/bin/env bash
# Regression tests for fm-spawn's pool-slot ownership.
#
# Treehouse reports a pool slot available whenever no process sits in it, so a
# parked task whose agent died still owns its slot in firstmate's records while
# `treehouse get` would hand that slot to the next spawn and reset it. Two live
# task records then name one copy. Teardown's own refusal for a shared copy is
# covered by tests/fm-teardown-endpoint-safety.test.sh.
#
# - The real-treehouse case drives fm-spawn's actual `treehouse get` against a
#   throwaway pool whose lowest slot belongs to a parked task with no process
#   in it, and proves the new task lands in a different slot. The parked slot
#   is clean and detached (a worker that stopped before branching): current
#   treehouse already passes over a slot holding a branch or local changes, but
#   still hands this one out. It skips, saying so, when no treehouse with
#   --lease support is installed.
# - The portable case proves spawn refuses a worktree another live record names.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-slot-ownership)

make_home() {  # <home> <id>
  fm_test_spawn_home "$1" codex
  fm_test_spawn_brief "$1" "$2"
}

make_project_with_origin() {  # <project> <origin>
  local project=$1 origin=$2
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" fetch --quiet origin
}

test_spawn_skips_slot_owned_by_parked_task() {
  local case_dir home project origin fakebin real_th th_home parked_slot parked_head out status id wt
  real_th=$(command -v treehouse 2>/dev/null || true)
  if [ -z "$real_th" ] || ! "$real_th" get --help 2>&1 | grep -q -- '--lease'; then
    echo "skip: treehouse with --lease not installed; the real-treehouse slot-skip case did not run"
    return 0
  fi
  id='pool-slot-new-r1'
  case_dir="$TMP_ROOT/real-treehouse"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  th_home="$case_dir/treehouse-home"
  mkdir -p "$th_home"
  make_home "$home" "$id"
  make_project_with_origin "$project" "$origin"
  printf 'max_trees = 4\nroot = "%s/pool-root"\n' "$case_dir" > "$project/treehouse.toml"
  git -C "$project" add treehouse.toml
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm treehouse
  git -C "$project" push --quiet origin main

  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  # Every treehouse call, including the one the fake pane runs, shares one
  # private HOME so no pool state reaches the real one.
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
HOME='$th_home' exec '$real_th' "\$@"
SH
  chmod +x "$fakebin/treehouse"
  # The fake pane: `treehouse get` acquires a real slot (leased, standing in
  # for the interactive subshell that holds it) and moves the pane there.
  mv "$fakebin/tmux" "$fakebin/tmux.base"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"#{pane_current_path}"*)
    cat '$case_dir/pane-path' 2>/dev/null || printf '%s\n' '$project'
    exit 0
    ;;
  "send-keys -t "*" treehouse get Enter")
    (cd '$project' && '$fakebin/treehouse' get --lease --lease-holder fake-pane 2>/dev/null) \\
      > '$case_dir/pane-path'
    exit 0
    ;;
esac
exec '$fakebin/tmux.base' "\$@"
SH
  chmod +x "$fakebin/tmux"

  # The parked task: it owns slot 1, still clean and detached, but its agent is
  # gone, so nothing sits in the slot and treehouse reports it available.
  parked_slot=$(cd "$project" && "$fakebin/treehouse" get --lease --lease-holder setup 2>/dev/null)
  [ -n "$parked_slot" ] || fail "fixture could not acquire a treehouse slot"
  (cd "$project" && "$fakebin/treehouse" return --force "$parked_slot" >/dev/null 2>&1) \
    || fail "fixture could not release the parked slot's lease"
  parked_head=$(git -C "$parked_slot" rev-parse HEAD)
  (cd "$project" && "$fakebin/treehouse" status 2>/dev/null) \
    | grep -F "$parked_slot" | grep -q 'available' \
    || fail "fixture did not leave the parked slot reporting available"
  fm_write_meta "$home/state/parked-task.meta" \
    "window=firstmate:fm-parked-task" \
    "endpoint_task_id=parked-task" \
    "worktree=$parked_slot" \
    "project=$project" \
    "kind=ship" \
    "mode=no-mistakes"

  out=$(fm_test_run_spawn "$home" "$project" "$fakebin" "$id" "$project" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should succeed in an unowned slot: $out"
  wt=$(grep "^worktree=" "$home/state/$id.meta" 2>/dev/null | tail -1 | cut -d= -f2-)
  [ -n "$wt" ] || fail "spawn recorded no worktree"
  [ "$(cd "$wt" && pwd -P)" != "$(cd "$parked_slot" && pwd -P)" ] \
    || fail "spawn was handed the parked task's slot $parked_slot"
  [ "$(git -C "$parked_slot" rev-parse HEAD)" = "$parked_head" ] \
    || fail "acquiring a slot moved the parked task's copy off its checked-out commit"
  pass "spawn skips a pool slot a parked task still owns and leaves that copy untouched"
}

test_spawn_refuses_worktree_another_task_records() {
  local case_dir home project origin pool fakebin out status id
  id='pool-slot-dup-r2'
  case_dir="$TMP_ROOT/spawn-refusal"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  make_home "$home" "$id"
  make_project_with_origin "$project" "$origin"
  git -C "$project" worktree add --quiet --detach "$pool" HEAD
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_write_meta "$home/state/older-task.meta" \
    "window=firstmate:fm-older-task" \
    "endpoint_task_id=older-task" \
    "worktree=$pool" \
    "project=$project" \
    "kind=ship" \
    "mode=no-mistakes"
  export FM_FAKE_LAUNCH_LOG="$case_dir/launch.log"
  : > "$FM_FAKE_LAUNCH_LOG"

  out=$(fm_test_run_spawn "$home" "$pool" "$fakebin" "$id" "$project" --mode no-mistakes --yolo off)
  status=$?
  unset FM_FAKE_LAUNCH_LOG
  [ "$status" -ne 0 ] || fail "spawn launched into a worktree another live task records"
  assert_contains "$out" "older-task" "spawn refusal did not name the task that owns the copy"
  [ ! -e "$home/state/$id.meta" ] || fail "a refused spawn still published a task record"
  [ ! -s "$case_dir/launch.log" ] || fail "a refused spawn still typed an agent launch: $(cat "$case_dir/launch.log")"
  pass "spawn refuses a worktree another live task record still names"
}

test_spawn_skips_slot_owned_by_parked_task
test_spawn_refuses_worktree_another_task_records

echo "# all fm-spawn-pool-slot-ownership tests passed"
