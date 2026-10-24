#!/usr/bin/env bats

load helper

setup() { setup_env; }
teardown() { teardown_env; }

# --- new ------------------------------------------------------------------

@test "new (bare layout): creates sibling worktree on a new branch from default branch" {
  make_bare_repo
  cd "$REPO/main"
  run collie new feat/login
  [ "$status" -eq 0 ]
  [ -d "$REPO/feat-login" ]
  [ "$(git -C "$REPO/feat-login" branch --show-current)" = feat/login ]
  [ "$(git -C "$REPO/feat-login" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse main)" ]
}

@test "new (normal layout): creates worktree under ../<repo>.worktrees" {
  make_normal_repo
  cd "$REPO"
  run collie new fix/typo
  [ "$status" -eq 0 ]
  [ -d "$TMP/proj.worktrees/fix-typo" ]
  [ "$(git -C "$TMP/proj.worktrees/fix-typo" branch --show-current)" = fix/typo ]
}

@test "new: works from a subdirectory of any worktree" {
  make_bare_repo
  mkdir -p "$REPO/main/src/deep"
  cd "$REPO/main/src/deep"
  run collie new feat/a
  [ "$status" -eq 0 ]
  [ -d "$REPO/feat-a" ]
}

@test "new: checks out an existing local branch instead of creating one" {
  make_bare_repo
  git -C "$REPO" branch feat/old main
  git -C "$REPO/main" commit -q --allow-empty -m newer
  cd "$REPO/main"
  run collie new feat/old
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO/feat-old" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse feat/old)" ]
}

@test "new --from: bases branch on given ref" {
  make_bare_repo
  base=$(git -C "$REPO/main" rev-parse HEAD)
  git -C "$REPO/main" commit -q --allow-empty -m next
  cd "$REPO/main"
  run collie new feat/b --from "$base"
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO/feat-b" rev-parse HEAD)" = "$base" ]
}

@test "new: opens a tmux window in a session named after the repo" {
  make_bare_repo my.proj
  cd "$REPO/main"
  run collie new feat/x
  [ "$status" -eq 0 ]
  [ "$(window_for "$REPO/feat-x")" = "my_proj:feat-x" ]
  [ "$(tmux display -p -t my_proj:feat-x '#{pane_current_path}')" = "$REPO/feat-x" ]
}

@test "new --no-window: skips tmux" {
  make_bare_repo
  cd "$REPO/main"
  run collie new feat/x --no-window
  [ "$status" -eq 0 ]
  [ -z "$(window_for "$REPO/feat-x")" ]
}

@test "new: fails when worktree already exists" {
  make_bare_repo
  cd "$REPO/main"
  collie new feat/x --no-window
  run collie new feat/x --no-window
  [ "$status" -ne 0 ]
  [[ "$output" == *exists* ]]
}

@test "new: fails outside a git repo" {
  cd "$TMP"
  run collie new feat/x
  [ "$status" -ne 0 ]
  [[ "$output" == *"not inside a git repository"* ]]
}

# --- ls -------------------------------------------------------------------

@test "ls: lists worktrees with branch, path and window marker" {
  make_bare_repo
  cd "$REPO/main"
  collie new feat/x
  collie new feat/y --no-window
  run collie ls
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == "main	main	$REPO/main	-" ]]
  [[ "$output" == *"feat-x	feat/x	$REPO/feat-x	*"* ]]
  [[ "$output" == *"feat-y	feat/y	$REPO/feat-y	-"* ]]
}

# --- go -------------------------------------------------------------------

@test "go: outside tmux prints the worktree path (by branch or slug)" {
  make_bare_repo
  cd "$REPO/main"
  collie new feat/x --no-window
  run collie go feat/x
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO/feat-x" ]
  run collie go feat-x
  [ "$output" = "$REPO/feat-x" ]
}

@test "go: unknown target fails" {
  make_bare_repo
  cd "$REPO/main"
  run collie go nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"no worktree"* ]]
}

# --- rm -------------------------------------------------------------------

@test "rm: removes worktree and its window, keeps branch" {
  make_bare_repo
  cd "$REPO/main"
  collie new feat/x
  run collie rm feat/x
  [ "$status" -eq 0 ]
  [ ! -d "$REPO/feat-x" ]
  [ -z "$(window_for "$REPO/feat-x")" ]
  git -C "$REPO" show-ref --verify -q refs/heads/feat/x
}

@test "rm --delete-branch: also deletes a merged branch" {
  make_bare_repo
  cd "$REPO/main"
  collie new feat/x --no-window
  run collie rm feat/x --delete-branch
  [ "$status" -eq 0 ]
  ! git -C "$REPO" show-ref --verify -q refs/heads/feat/x
}

@test "rm: refuses a dirty worktree unless --force" {
  make_bare_repo
  cd "$REPO/main"
  collie new feat/x --no-window
  echo wip >"$REPO/feat-x/file"
  run collie rm feat/x
  [ "$status" -ne 0 ]
  [ -d "$REPO/feat-x" ]
  run collie rm feat/x --force
  [ "$status" -eq 0 ]
  [ ! -d "$REPO/feat-x" ]
}

@test "rm: refuses the worktree you are standing in" {
  make_bare_repo
  cd "$REPO/main"
  collie new feat/x --no-window
  cd "$REPO/feat-x"
  run collie rm feat/x
  [ "$status" -ne 0 ]
  [[ "$output" == *"currently inside"* ]]
  [ -d "$REPO/feat-x" ]
}

@test "rm: refuses the main worktree of a normal clone" {
  make_normal_repo
  cd "$TMP"
  cd "$REPO" && collie new feat/x --no-window && cd "$TMP/proj.worktrees/feat-x"
  run collie rm main
  [ "$status" -ne 0 ]
  [ -d "$REPO" ]
}

# --- misc -----------------------------------------------------------------

@test "help: lists commands; unknown command fails" {
  run collie help
  [ "$status" -eq 0 ]
  [[ "$output" == *new* && "$output" == *rm* ]]
  run collie bogus
  [ "$status" -ne 0 ]
}
