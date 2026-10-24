#!/usr/bin/env bats

load helper

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off
  make_bare_repo A
  cd "$REPO/main"
}
teardown() { teardown_env; }

commit_in() { # dir file
  echo "$2" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "add $2"
}

# merge a branch into origin's main the way a PR would, then fetch
merge_upstream() {
  git -C "$TMP/origin-A" fetch -q "$REPO/.bare" "$1"
  git -C "$TMP/origin-A" merge -q --ff-only FETCH_HEAD
  git -C "$REPO" fetch -q origin
}

# --- review -----------------------------------------------------------------

@test "review: commits, diff stat and dirty files for every repo, then REPORT.md" {
  make_normal_repo B
  cd "$TMP"
  collie new x -r A -r B --no-window
  commit_in "$TMP/repos/A/feat-x" one
  commit_in "$TMP/repos/B.worktrees/feat-x" two
  echo wip >"$TMP/repos/B.worktrees/feat-x/wip"
  echo "All green." >"$(task_dir x)/REPORT.md"
  run collie review x
  [ "$status" -eq 0 ]
  [[ "$output" == *"== A  feat/x  1 ahead"* ]]
  [[ "$output" == *"add one"* && "$output" == *"one | 1 +"* ]]
  [[ "$output" == *"== B  feat/x  1 ahead"* && "$output" == *"add two"* ]]
  [[ "$output" == *"?? wip"* ]]
  [[ "$output" == *"All green."* ]]
  run collie review x -p
  [[ "$output" == *"+one"* ]]
}

# --- spike ------------------------------------------------------------------

@test "spike: copies uncommitted changes to an exp/ task; source untouched" {
  collie new src --no-window
  wt="$TMP/repos/A/feat-src"
  commit_in "$wt" base
  echo changed >"$wt/base"
  echo staged >"$wt/new"
  git -C "$wt" add new
  before=$(git -C "$wt" status --porcelain)
  stashes=$(git -C "$wt" stash list)
  cd "$wt"
  run collie spike try-x --no-window
  [ "$status" -eq 0 ]
  [ "$(git -C "$wt" status --porcelain)" = "$before" ]
  [ "$(git -C "$wt" stash list)" = "$stashes" ]
  sp="$TMP/repos/A/exp-try-x"
  [ "$(git -C "$sp" branch --show-current)" = exp/try-x ]
  [ "$(cat "$sp/base")" = changed ]
  [ "$(cat "$sp/new")" = staged ]
  grep -q "spiked_from	task=src" "$(task_dir try-x)/events.log"
}

@test "spike: clean worktree just branches off HEAD" {
  collie new src --no-window
  commit_in "$TMP/repos/A/feat-src" base
  cd "$TMP/repos/A/feat-src"
  collie spike try-y --no-window
  [ -f "$TMP/repos/A/exp-try-y/base" ]
  [ -z "$(git -C "$TMP/repos/A/exp-try-y" status --porcelain)" ]
}

# --- park -------------------------------------------------------------------

@test "park: sets next and appends it to NOTES.md (-m or stdin)" {
  collie new x --no-window
  collie park x -m "rerun the flaky test"
  [ "$(fm x next)" = "rerun the flaky test" ]
  grep -q "^- parked: rerun the flaky test$" "$(task_dir x)/NOTES.md"
  echo "ask about schema" | COLLIE_TASK=x collie park
  [ "$(fm x next)" = "ask about schema" ]
  [ "$(grep -c '^- parked:' "$(task_dir x)/NOTES.md")" -eq 2 ]
  grep -q "task_parked" "$(task_dir x)/events.log"
}

# --- gc ---------------------------------------------------------------------

@test "gc: finishes tasks whose branches were merged; leaves new and unmerged ones" {
  for t in m u n; do collie new "$t" --no-window; done
  commit_in "$TMP/repos/A/feat-m" m
  commit_in "$TMP/repos/A/feat-u" u
  merge_upstream feat/m
  run collie gc -n
  [ "$status" -eq 0 ]
  [ "$output" = m ]
  [ "$(fm m status)" = active ]
  run collie gc
  [ "$status" -eq 0 ]
  [ "$(fm m status)" = done ]
  [ ! -d "$TMP/repos/A/feat-m" ]
  [ "$(fm u status)" = active ]
  [ "$(fm n status)" = active ]
}

@test "gc: skips a merged task with uncommitted changes" {
  collie new m --no-window
  commit_in "$TMP/repos/A/feat-m" m
  merge_upstream feat/m
  echo dirty >"$TMP/repos/A/feat-m/d"
  run collie gc
  [[ "$output" == *"skipped m"* ]]
  [ "$(fm m status)" = active ]
}

# --- pre-push ---------------------------------------------------------------

@test "hooks/pre-push: rejects exp/* branches unless COLLIE_ALLOW_EXP=1" {
  git init -q --bare "$TMP/remote.git"
  git -C "$REPO" config core.hooksPath "$COLLIE_ROOT/hooks"
  collie new feat-ok --no-window
  collie new try --no-window -t exp
  run git -C "$TMP/repos/A/exp-try" push -q "$TMP/remote.git" exp/try
  [ "$status" -ne 0 ]
  [[ "$output" == *"exp/try"* ]]
  git -C "$TMP/repos/A/feat-feat-ok" push -q "$TMP/remote.git" feat/feat-ok
  COLLIE_ALLOW_EXP=1 git -C "$TMP/repos/A/exp-try" push -q "$TMP/remote.git" exp/try
}
