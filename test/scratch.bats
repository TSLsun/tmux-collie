#!/usr/bin/env bats

load helper
bats_require_minimum_version 1.5.0

# Reviewer runs in scratch worktrees (run --scratch). The default agent is
# `sleep`; a fake reviewer is `sh -c '...'`.
setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=sleep
  make_bare_repo A
  cd "$REPO/main"
}
teardown() { teardown_env; }

commit_in() { # dir file
  echo "$2" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "add $2"
}

@test "run --scratch: a reviewer that dirties its scratch worktree leaves the task worktree unchanged" {
  collie new x --no-window
  w="$TMP/repos/A/feat-x" s="$TMP/repos/A/feat-x.scratch-1"
  commit_in "$w" m
  head=$(git -C "$w" rev-parse HEAD)
  collie run x --scratch --agent sh -- -c 'echo dirty >>m; echo junk >junk; git add junk
    printf "%s\n" "- [ ] m:1 bad. Proof: cat m -> dirty" >.collie/REVIEW.md; exec sleep 300'
  wait_for '[ -f "$(task_dir x)/REVIEW.md" ]'
  [ "$(tmux display -p -t "$(run_pane x)" '#{pane_current_path}')" = "$s" ]
  # the scratch worktree: detached at the branch head, dirtied by the reviewer
  [ "$(git -C "$s" rev-parse HEAD)" = "$head" ]
  run git -C "$s" symbolic-ref -q HEAD
  [ "$status" -ne 0 ]
  [ "$(git -C "$s" status --porcelain | sort)" = " M m
A  junk" ]
  # the task worktree: same branch, HEAD and (clean) status
  [ "$(git -C "$w" symbolic-ref HEAD)" = refs/heads/feat/x ]
  [ "$(git -C "$w" rev-parse HEAD)" = "$head" ]
  [ -z "$(git -C "$w" status --porcelain)" ]
  [ "$(cat "$w/m")" = m ]
  grep -q "scratch_created	run=1 repo=A path=$s head=$head" "$(task_dir x)/events.log"
  # a second scratch run gets a worktree of its own
  collie run x --scratch -- 300
  [ "$(tmux display -p -t "$(run_pane x 2)" '#{pane_current_path}')" = "$TMP/repos/A/feat-x.scratch-2" ]
  # archive removes both, dirty or not; the task worktree's checks still apply
  run --separate-stderr collie archive x
  [ "$status" -eq 0 ]
  [[ "$output" == *"  A  run 1 scratch worktree  "* ]]
  [[ "$output" == *"  A  run 2 scratch worktree  "* ]]
  [ ! -e "$s" ] && [ ! -e "$TMP/repos/A/feat-x.scratch-2" ] && [ ! -e "$w" ]
  [[ "$(git -C "$REPO" worktree list)" != *scratch* ]]
  grep -q "worktree_removed	repo=A path=$s run=1" "$(task_dir x)/events.log"
}

@test "run --scratch: gc -n lists scratch worktrees and gc removes them" {
  collie new m --no-window
  w="$TMP/repos/A/feat-m"
  commit_in "$w" m
  collie run m --scratch -- 300
  echo junk >"$w.scratch-1/junk"
  git -C "$TMP/origin-A" fetch -q "$REPO/.bare" feat/m
  git -C "$TMP/origin-A" merge -q --ff-only FETCH_HEAD
  git -C "$REPO" fetch -q origin
  run --separate-stderr collie gc -n
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ] && [ "${lines[0]}" = m ]
  [[ "${lines[1]}" =~ ^"  A  clean  "[0-9]+K$ ]]
  [[ "${lines[2]}" =~ ^"  A  run 1 scratch worktree  "[0-9]+K$ ]]
  run --separate-stderr collie gc
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "done m" ]
  [ ! -e "$w.scratch-1" ] && [ ! -e "$w" ]
}

@test "run --scratch: a folder has no branch to check out" {
  mkdir "$TMP/notes"
  collie new f -r "$TMP/notes" --no-window
  run collie run f --scratch -- 300
  [ "$status" -ne 0 ]
  [[ "$output" == *"--scratch needs a git repo"* ]]
}
