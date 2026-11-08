#!/usr/bin/env bats

load helper
bats_require_minimum_version 1.5.0

# Reviewer runs in scratch worktrees (run --scratch) and the findings needs
# value. The default agent is `sleep`; a fake reviewer is `sh -c '...'`.
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

needs_of() { collie ls | awk -F'\t' -v id="$1" '$1 == id { print $7 }'; }
status_of() { collie ls | awk -F'\t' -v id="$1" '$1 == id { print $2 }'; }

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
  # gc skips a working or waiting agent; a reviewer done with its turn is idle
  hook m idle
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

@test "drop and branch switch refuse an active scratch run" {
  make_normal_repo B
  cd "$TMP"
  collie new x -r A -r B --no-window
  collie run x -r A --scratch --agent sleep -- 300
  hook x working
  run collie drop x -r A --force
  [ "$status" -ne 0 ]
  [ -d "$TMP/repos/A/feat-x.scratch-1" ]
  run collie add x -r A:other --force
  [ "$status" -ne 0 ]
  [ -d "$TMP/repos/A/feat-x" ]
  hook x idle
  git -C "$TMP/repos/A" worktree lock "$TMP/repos/A/feat-x.scratch-1"
  run collie drop x -r A
  [ "$status" -ne 0 ]
  [ -d "$TMP/repos/A/feat-x" ]
  run collie add x -r A:other
  [ "$status" -ne 0 ]
  [ -d "$TMP/repos/A/feat-x" ]
  git -C "$TMP/repos/A" worktree unlock "$TMP/repos/A/feat-x.scratch-1"
  collie drop x -r A
  [ ! -e "$TMP/repos/A/feat-x.scratch-1" ]
  git -C "$TMP/repos/A" show-ref -q --verify refs/heads/feat/x
}

@test "run --scratch: a folder has no branch to check out" {
  mkdir "$TMP/notes"
  collie new f -r "$TMP/notes" --no-window
  run collie run f --scratch -- 300
  [ "$status" -ne 0 ]
  [[ "$output" == *"--scratch needs a git repo"* ]]
}

@test "needs: findings while a REVIEW.md newer than REPORT.md has an unticked item" {
  collie new x --no-window
  d=$(task_dir x)
  printf '2020-01-01T00:00:00Z\trun_started\trun=1 agent=sleep repo=A\n' >>"$d/events.log"
  printf '# x\n\nDone.\n' >"$d/REPORT.md"
  touch -t 202001020000 "$d/REPORT.md"
  [ "$(needs_of x)" = review ]
  printf -- '- [ ] a.sh:1 bad. Proof: sh a.sh -> 1\n- [x] b.sh:2 fixed\n' >"$d/REVIEW.md"
  touch -t 202001030000 "$d/REVIEW.md"
  [ "$(needs_of x)" = findings ]
  [ "$(collie brief)" = "findings x (P2): the review has open findings  ->  collie review x" ]
  # every item ticked: none open
  sed -i.bak 's/^- \[ \]/- [x]/' "$d/REVIEW.md"
  touch -t 202001030000 "$d/REVIEW.md"
  [ "$(needs_of x)" = review ]
  printf 'no findings\n' >"$d/REVIEW.md"
  touch -t 202001030000 "$d/REVIEW.md"
  [ "$(needs_of x)" = review ]
  # the implementer's next REPORT.md closes them
  printf -- '- [ ] a.sh:1 bad\n' >"$d/REVIEW.md"
  touch -t 202001030000 "$d/REVIEW.md"
  [ "$(needs_of x)" = findings ]
  touch -t 202001040000 "$d/REPORT.md"
  [ "$(needs_of x)" = review ]
}

@test "needs: a scratch run is not the implementer's last run; a working one hides findings" {
  collie new x --no-window
  d=$(task_dir x)
  printf '2020-01-01T00:00:00Z\trun_started\trun=1 agent=sleep repo=A\n' >>"$d/events.log"
  printf '# x\n\nDone.\n' >"$d/REPORT.md"
  printf -- '- [ ] a.sh:1 bad\n' >"$d/REVIEW.md"
  touch -t 202001020000 "$d/REPORT.md"
  collie run x --scratch -- 300
  # a working reviewer: active, nothing for you yet
  [ "$(status_of x)" = active ]
  [ "$(needs_of x)" = - ]
  # its turn over: review again (it writes no REPORT.md), open findings first
  hook x idle 2
  [ "$(status_of x)" = review ]
  [ "$(needs_of x)" = findings ]
  # a run without --scratch counts again
  collie run x -- 300
  hook x idle 3
  [ "$(status_of x)" = active ]
}
