#!/usr/bin/env bats
load helper
setup() { setup_env; }
teardown() { teardown_env; }

fail_link() {
  cat >"$TMP/stub/ln" <<'SH'
#!/bin/bash
case "${@: -1}" in *"$FAIL_LINK") exit 1 ;; esac
exec /bin/ln "$@"
SH
  chmod +x "$TMP/stub/ln"
  export FAIL_LINK=$1
}

@test "new rolls back on a second repo link failure" {
  make_normal_repo good
  make_normal_repo bad
  mkdir "$TMP/repos/good.worktrees"
  fail_link /repos/bad
  run collie new broken -r good -r bad --no-window
  [ "$status" -ne 0 ]
  [ ! -e "$(task_dir broken)" ]
  [ ! -e "$TMP/repos/good.worktrees/feat-broken" ]
  [ ! -e "$TMP/repos/bad.worktrees/feat-broken" ]
  [ -d "$TMP/repos/good.worktrees" ]
  run git -C "$TMP/repos/good" show-ref --verify refs/heads/feat/broken
  [ "$status" -ne 0 ]
  [ ! -e "$TMP/repos/good/.git/info/exclude" ] || ! grep -qx '/.collie' "$TMP/repos/good/.git/info/exclude"
}

@test "new rejects tracked .collie files and dangling symlinks" {
  make_normal_repo bad
  echo keep >"$REPO/.collie"
  git -C "$REPO" add .collie
  git -C "$REPO" commit -qm file
  run collie new file -r bad --from main --no-window
  [ "$status" -ne 0 ]
  [ "$(cat "$REPO/.collie")" = keep ]
  rm "$REPO/.collie"
  ln -s missing "$REPO/.collie"
  git -C "$REPO" add .collie
  git -C "$REPO" commit -qm symlink
  run collie new symlink -r bad --from main --no-window
  [ "$status" -ne 0 ]
  [ "$(readlink "$REPO/.collie")" = missing ]
}

@test "reopen link failure preserves status metadata and existing links" {
  make_normal_repo good
  make_normal_repo bad
  collie new broken -r good -r bad --no-window
  collie archive broken --force
  local d
  d=$(task_dir broken)
  ln -s "$TMP/repos/good.worktrees/feat-broken" "$d/repos/good"
  cp "$d/TASK.md" "$TMP/task"
  cp "$d/events.log" "$TMP/events"
  fail_link /repos/bad
  run collie reopen broken --no-window
  [ "$status" -ne 0 ]
  cmp "$TMP/task" "$d/TASK.md"
  cmp "$TMP/events" "$d/events.log"
  [ -L "$d/repos/good" ]
  [ ! -e "$TMP/repos/good.worktrees/feat-broken" ]
  [ ! -e "$TMP/repos/bad.worktrees/feat-broken" ]
  git -C "$REPO" show-ref --verify refs/heads/feat/broken
}

@test "new rolls back if TASK.md template rendering fails" {
  make_normal_repo good
  mkdir -p "$XDG_CONFIG_HOME/collie"
  echo template >"$XDG_CONFIG_HOME/collie/TASK.md"
  cat >"$TMP/stub/awk" <<'SH'
#!/bin/bash
case "${@: -1}" in */templates/TASK.md|*/collie/TASK.md) exit 1 ;; esac
exec /usr/bin/awk "$@"
SH
  chmod +x "$TMP/stub/awk"
  run collie new broken -r good --no-window
  [ "$status" -ne 0 ]
  [ ! -e "$(task_dir broken)" ]
  [ ! -e "$TMP/repos/good.worktrees/feat-broken" ]
}

@test "new rejects tracked .collie collisions and rolls back all worktrees" {
  make_normal_repo good
  make_normal_repo bad
  mkdir "$REPO/.collie"
  echo keep >"$REPO/.collie/keep"
  git -C "$REPO" add .collie
  git -C "$REPO" commit -qm collision
  run collie new collision -r good -r bad --from main --no-window
  [ "$status" -ne 0 ]
  [ "$(cat "$REPO/.collie/keep")" = keep ]
  [ ! -e "$(task_dir collision)" ]
  [ ! -e "$TMP/repos/good.worktrees/feat-collision" ]
  run git -C "$TMP/repos/good" show-ref --verify refs/heads/feat/collision
  [ "$status" -ne 0 ]
}

@test "add preserves existing metadata and colliding task link" {
  make_normal_repo good
  make_normal_repo bad
  collie new collision -r good --no-window
  local d
  d=$(task_dir collision)
  cp "$d/repos.tsv" "$TMP/before"
  cp "$d/events.log" "$TMP/events"
  mkdir "$d/repos/bad"
  echo keep >"$d/repos/bad/keep"
  run collie add collision -r bad --no-window
  [ "$status" -ne 0 ]
  cmp "$TMP/before" "$d/repos.tsv"
  cmp "$TMP/events" "$d/events.log"
  [ "$(cat "$d/repos/bad/keep")" = keep ]
  [ ! -e "$d/repos/bad/feat-collision" ]
}

@test "failed add removes earlier new links and preserves existing branches" {
  make_normal_repo original
  make_normal_repo good
  git -C "$REPO" branch feat/broken
  make_normal_repo bad
  collie new broken -r original --no-window
  local d
  d=$(task_dir broken)
  cp "$d/repos.tsv" "$TMP/before"
  cp "$d/events.log" "$TMP/events"
  fail_link /repos/bad
  run collie add broken -r good -r bad --no-window
  [ "$status" -ne 0 ]
  cmp "$TMP/before" "$d/repos.tsv"
  cmp "$TMP/events" "$d/events.log"
  [ -L "$d/repos/original" ]
  [ ! -L "$d/repos/good" ]
  [ ! -e "$TMP/repos/good.worktrees/feat-broken" ]
  git -C "$TMP/repos/good" show-ref --verify refs/heads/feat/broken
}

@test "new fails cleanly when metadata directory setup fails" {
  make_normal_repo good
  cat >"$TMP/stub/mkdir" <<'SH'
#!/bin/bash
case "${@: -1}" in */tasks/broken/repos) exit 1 ;; esac
exec /bin/mkdir "$@"
SH
  chmod +x "$TMP/stub/mkdir"
  run collie new broken -r good --no-window
  [ "$status" -ne 0 ]
  [ ! -e "$(task_dir broken)" ]
  run git -C "$REPO" show-ref --verify refs/heads/feat/broken
  [ "$status" -ne 0 ]
}
# a git stub that fails the worktree subcommand $1 when its args match $2
fail_git() {
  cat >"$TMP/stub/git" <<'SH'
#!/bin/bash
case "$*" in *"worktree $FAIL_GIT_CMD"*"$FAIL_GIT_PATH"*) exit 1 ;; esac
exec /usr/bin/git "$@"
SH
  chmod +x "$TMP/stub/git"
  export FAIL_GIT_CMD=$1 FAIL_GIT_PATH=$2
}

# a task "broken" (good, bad) with a dirty scratch worktree of bad's run 1
dirty_scratch_task() {
  make_normal_repo good
  make_normal_repo bad
  collie new broken -r good -r bad --no-window
  D="$COLLIE_STATE_DIR/tasks/broken"
  WT="$TMP/repos/bad.worktrees/feat-broken"
  collie run broken -r bad --scratch --agent sleep -- 300
  hook broken idle
  echo repro >"$WT.scratch-1/untracked"
  echo edit >>"$WT.scratch-1/README.md"
  cp "$D/repos.tsv" "$TMP/before"
  cp "$D/events.log" "$TMP/events"
}

# everything as dirty_scratch_task left it: worktrees registered in place
assert_scratch_restored() {
  [ -d "$WT" ]
  [ "$(cat "$WT.scratch-1/untracked")" = repro ]
  grep -q edit "$WT.scratch-1/README.md"
  [ -L "$WT.scratch-1/.collie" ] && [ -L "$WT/.collie" ]
  [ "$(readlink "$D/repos/bad")" = "$WT" ]
  git -C "$TMP/repos/bad" worktree list --porcelain | grep -qx "worktree $WT.scratch-1"
  git -C "$TMP/repos/bad" worktree list --porcelain | grep -qx "worktree $WT"
  [ -z "$(ls -d "$TMP"/repos/bad.worktrees/*collie-staged* 2>/dev/null)" ]
  cmp "$TMP/before" "$D/repos.tsv"
  cmp "$TMP/events" "$D/events.log"
  git -C "$TMP/repos/bad" show-ref -q --verify refs/heads/feat/broken
}

@test "drop restores a dirty scratch worktree when a later step fails" {
  dirty_scratch_task
  # the scratch worktree is staged first; moving the main worktree then fails
  fail_git move "$WT "
  run collie drop broken -r bad --force
  [ "$status" -ne 0 ]
  assert_scratch_restored
}

@test "drop restores a dirty scratch worktree when unlinking fails" {
  dirty_scratch_task
  cat >"$TMP/stub/mv" <<'SH'
#!/bin/bash
case "$1" in */repos/bad) exit 1 ;; esac
exec /bin/mv "$@"
SH
  chmod +x "$TMP/stub/mv"
  run collie drop broken -r bad --force
  [ "$status" -ne 0 ]
  assert_scratch_restored
}

@test "branch switch restores a dirty scratch worktree when linking fails" {
  dirty_scratch_task
  fail_link /repos/bad
  run collie add broken -r bad:release/v2 --force --no-window
  [ "$status" -ne 0 ]
  assert_scratch_restored
  [ ! -e "$TMP/repos/bad.worktrees/release-v2" ]
  run git -C "$TMP/repos/bad" show-ref --verify refs/heads/release/v2
  [ "$status" -ne 0 ]
}

@test "drop of several repos is all-or-nothing" {
  dirty_scratch_task
  make_normal_repo third
  collie add broken -r third --no-window
  cp "$D/repos.tsv" "$TMP/before"
  cp "$D/events.log" "$TMP/events"
  local good="$TMP/repos/good.worktrees/feat-broken"
  # good is staged first; bad's scratch worktree then fails to move
  fail_git move "$WT.scratch-1 "
  run collie drop broken -r good -r bad --force
  [ "$status" -ne 0 ]
  assert_scratch_restored
  [ -d "$good" ] && [ "$(readlink "$D/repos/good")" = "$good" ]
  git -C "$TMP/repos/good" worktree list --porcelain | grep -qx "worktree $good"
  rm "$TMP/stub/git"
  run collie drop broken -r good -r bad --force
  [ "$status" -eq 0 ]
  [ ! -e "$good" ] && [ ! -e "$WT" ] && [ ! -e "$WT.scratch-1" ]
  [ "$(cut -f1 "$D/repos.tsv")" = third ]
  [ ! -e "$D/repos/good" ] && [ ! -e "$D/repos/bad" ]
  [ "$(grep -c repo_dropped "$D/events.log")" -eq 2 ]
  [ "$(grep -c worktree_removed "$D/events.log")" -eq 3 ]
  git -C "$TMP/repos/good" show-ref -q --verify refs/heads/feat/broken
  git -C "$TMP/repos/bad" show-ref -q --verify refs/heads/feat/broken
}

@test "drop keeps an old worktree it cannot remove after the commit" {
  dirty_scratch_task
  fail_git remove ".scratch-1.collie-staged."
  run collie drop broken -r bad --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept the old worktree of bad at $WT.scratch-1.collie-staged."* ]]
  # committed: the repo is gone from the task; the scratch work is not lost
  [ "$(cut -f1 "$D/repos.tsv")" = good ]
  [ ! -e "$D/repos/bad" ] && [ ! -e "$WT" ] && [ ! -e "$WT.scratch-1" ]
  [ "$(cat "$WT".scratch-1.collie-staged.*/untracked)" = repro ]
}

@test "add switches multiple repos and adds a new repo in one transaction" {
  make_normal_repo C
  make_normal_repo A
  make_normal_repo B
  cd "$TMP"
  collie new x -r A -r B --no-window
  run collie add x -r A:release/a -r B:release/b -r C:release/c --no-window
  [ "$status" -eq 0 ]
  [ "$(git -C "$TMP/repos/A.worktrees/release-a" branch --show-current)" = release/a ]
  [ "$(git -C "$TMP/repos/B.worktrees/release-b" branch --show-current)" = release/b ]
  [ "$(git -C "$TMP/repos/C.worktrees/release-c" branch --show-current)" = release/c ]
  [ ! -e "$TMP/repos/A.worktrees/feat-x" ]
  [ ! -e "$TMP/repos/B.worktrees/feat-x" ]
  git -C "$TMP/repos/A" show-ref -q --verify refs/heads/feat/x
  git -C "$TMP/repos/B" show-ref -q --verify refs/heads/feat/x
}

@test "failed mixed multi-repo add restores every original attachment" {
  make_normal_repo A
  make_normal_repo B
  cd "$TMP"
  collie new x -r A -r B --no-window
  local d="$COLLIE_STATE_DIR/tasks/x"
  cp "$d/repos.tsv" "$TMP/before"
  cp "$d/events.log" "$TMP/events"
  fail_link /repos/B
  run collie add x -r A:release/a -r B:release/b --no-window
  [ "$status" -ne 0 ]
  [ -d "$TMP/repos/A.worktrees/feat-x" ]
  [ -d "$TMP/repos/B.worktrees/feat-x" ]
  [ ! -e "$TMP/repos/A.worktrees/release-a" ]
  [ ! -e "$TMP/repos/B.worktrees/release-b" ]
  [ -L "$d/repos/A" ] && [ -L "$d/repos/B" ]
  cmp "$TMP/before" "$d/repos.tsv"
  cmp "$TMP/events" "$d/events.log"
  git -C "$TMP/repos/A" show-ref -q --verify refs/heads/feat/x
  git -C "$TMP/repos/B" show-ref -q --verify refs/heads/feat/x
}
