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
