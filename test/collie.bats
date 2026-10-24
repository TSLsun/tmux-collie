#!/usr/bin/env bats

load helper

setup() { setup_env; }
teardown() { teardown_env; }

two_repos() {
  make_bare_repo A
  make_normal_repo B
}

# --- new: single repo -------------------------------------------------------

@test "new: creates task dir, worktree, branch and .collie link for the current repo" {
  make_bare_repo A
  cd "$REPO/main"
  run collie new x --no-window
  [ "$status" -eq 0 ]
  d=$(task_dir x)
  [ -f "$d/TASK.md" ] && [ -f "$d/events.log" ]
  [ "$(fm x id)" = x ] && [ "$(fm x title)" = x ] && [ "$(fm x status)" = active ]
  [ "$(git -C "$REPO/feat-x" branch --show-current)" = feat/x ]
  [ "$(git -C "$REPO/feat-x" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse main)" ]
  [ "$(cd "$REPO/feat-x/.collie" && pwd -P)" = "$d" ]
  [ "$(cd "$d/repos/A" && pwd -P)" = "$REPO/feat-x" ]
  [ -z "$(git -C "$REPO/feat-x" status --porcelain)" ]
  grep -q worktree_created "$d/events.log"
}

@test "new: normal clone layout puts worktree under <repo>.worktrees" {
  make_normal_repo B
  cd "$REPO"
  run collie new x --no-window
  [ "$status" -eq 0 ]
  [ "$(git -C "$TMP/repos/B.worktrees/feat-x" branch --show-current)" = feat/x ]
}

@test "new: -t sets branch type, --title and --todo set frontmatter" {
  make_bare_repo A
  cd "$REPO/main"
  run collie new y -t fix --title "fix: a & b / c" --todo --no-window
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO/fix-y" branch --show-current)" = fix/y ]
  [ "$(fm y title)" = "fix: a & b / c" ]
  [ "$(fm y status)" = todo ]
}

@test "new: rejects invalid ids" {
  make_bare_repo A
  cd "$REPO/main"
  for id in Bad "has space" -lead "a/b" "$(printf 'x%.0s' {1..41})"; do
    run collie new "$id" --no-window
    [ "$status" -ne 0 ]
  done
  [ ! -d "$COLLIE_STATE_DIR/tasks" ] || [ -z "$(ls "$COLLIE_STATE_DIR/tasks")" ]
}

@test "new: rejects a duplicate id" {
  make_bare_repo A
  cd "$REPO/main"
  collie new x --no-window
  run collie new x --no-window
  [ "$status" -ne 0 ]
  [[ "$output" == *exists* ]]
}

@test "new: reuses an existing local branch" {
  make_bare_repo A
  git -C "$REPO" branch feat/x main
  git -C "$REPO/main" commit -q --allow-empty -m newer
  cd "$REPO/main"
  run collie new x --no-window
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO/feat-x" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse feat/x)" ]
}

@test "new: fails outside a repo without -r" {
  cd "$TMP"
  run collie new x
  [ "$status" -ne 0 ]
  [[ "$output" == *"not inside a git repository"* ]]
}

# --- new: multi repo --------------------------------------------------------

@test "new -r: two repos by name get worktrees and one tmux session with a window each" {
  two_repos
  cd "$TMP"
  run collie new x -r A -r B
  [ "$status" -eq 0 ]
  [ -d "$TMP/repos/A/feat-x" ] && [ -d "$TMP/repos/B.worktrees/feat-x" ]
  [ "$(window_path x A)" = "$TMP/repos/A/feat-x" ]
  [ "$(window_path x B)" = "$TMP/repos/B.worktrees/feat-x" ]
  [ "$(tmux show-environment -t =x COLLIE_TASK)" = COLLIE_TASK=x ]
  [ "$(wc -l <"$(task_dir x)/repos.tsv" | tr -d ' ')" -eq 2 ]
}

@test "new -r: repo:branch and path specs" {
  two_repos
  cd "$TMP"
  run collie new x -r A:spike/custom -r "$TMP/repos/B" --no-window
  [ "$status" -eq 0 ]
  [ "$(git -C "$TMP/repos/A/spike-custom" branch --show-current)" = spike/custom ]
  [ -d "$TMP/repos/B.worktrees/feat-x" ]
}

@test "new -w: expands a workspace; unknown workspace or repo fails cleanly" {
  two_repos
  mkdir -p "$XDG_CONFIG_HOME/collie"
  printf '# comment\nlake: A B\n' >"$XDG_CONFIG_HOME/collie/workspaces"
  cd "$TMP"
  run collie new x -w lake --no-window
  [ "$status" -eq 0 ]
  [ -d "$TMP/repos/A/feat-x" ] && [ -d "$TMP/repos/B.worktrees/feat-x" ]
  run collie new y -w nope --no-window
  [ "$status" -ne 0 ]
  run collie new z -r A -r Nope --no-window
  [ "$status" -ne 0 ]
  [ ! -e "$TMP/repos/A/feat-z" ] && [ ! -d "$(task_dir z)" ]
}

@test "new: branch held by another task is rejected up front, naming that task" {
  two_repos
  cd "$TMP"
  collie new x -r B --no-window
  run collie new y -r A -r B:feat/x --no-window
  [ "$status" -ne 0 ]
  [[ "$output" == *"task 'x'"* ]]
  [ ! -e "$TMP/repos/A/feat-y" ] && [ ! -d "$(task_dir y)" ]
}

@test "new: failure midway rolls back worktrees and branches already created" {
  two_repos
  git -C "$TMP/repos/A" tag only-in-a main
  cd "$TMP"
  run collie new x -r A -r B --from only-in-a --no-window
  [ "$status" -ne 0 ]
  [ ! -e "$TMP/repos/A/feat-x" ]
  ! git -C "$TMP/repos/A" show-ref -q --verify refs/heads/feat/x
  [ ! -d "$(task_dir x)" ]
}

# --- add --------------------------------------------------------------------

@test "add: attaches another repo to an existing task (and its session)" {
  two_repos
  cd "$TMP"
  collie new x -r A
  run collie add x -r B
  [ "$status" -eq 0 ]
  [ -d "$TMP/repos/B.worktrees/feat-x" ]
  [ "$(window_path x B)" = "$TMP/repos/B.worktrees/feat-x" ]
  [ "$(wc -l <"$(task_dir x)/repos.tsv" | tr -d ' ')" -eq 2 ]
  run collie add x -r B
  [ "$status" -ne 0 ]
}

@test "add: infers the task from COLLIE_TASK" {
  two_repos
  cd "$TMP"
  collie new x -r A --no-window
  COLLIE_TASK=x run collie add -r B --no-window
  [ "$status" -eq 0 ]
  [ -d "$TMP/repos/B.worktrees/feat-x" ]
}

# --- ls / show / repos / workspaces -----------------------------------------

@test "ls: active tasks with status, session marker and repos; -a includes finished" {
  two_repos
  cd "$TMP"
  collie new x -r A -r B
  collie new y -r A --todo --no-window
  collie new z -r B --no-window
  collie archive z
  run collie ls
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "x	active	P2	*	A,B	" ]]
  [[ "${lines[1]}" == "y	todo	P2	-	A	" ]]
  run collie ls -a
  [ "${#lines[@]}" -eq 3 ]
}

@test "show: prints task fields, repos and recent events" {
  make_bare_repo A
  cd "$REPO/main"
  collie new x --title "Hello" --no-window
  run collie show x
  [ "$status" -eq 0 ]
  [[ "$output" == *"Hello"* && "$output" == *"feat/x"* && "$output" == *task_created* ]]
}

@test "repos and workspaces list what collie can see" {
  two_repos
  mkdir -p "$XDG_CONFIG_HOME/collie"
  echo "lake: A B" >"$XDG_CONFIG_HOME/collie/workspaces"
  run collie repos
  [[ "$output" == *"A	$TMP/repos/A"* && "$output" == *"B	$TMP/repos/B"* ]]
  [ "${#lines[@]}" -eq 2 ]
  run collie workspaces
  [ "$output" = "lake	A B" ]
}

# --- go ---------------------------------------------------------------------

@test "go: outside tmux prints primary worktree and recreates a missing session" {
  two_repos
  cd "$TMP"
  collie new x -r A -r B
  tmux kill-server
  run collie go x
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/repos/A/feat-x" ]
  [ "$(window_path x B)" = "$TMP/repos/B.worktrees/feat-x" ]
}

@test "go: unknown task fails" {
  run collie go nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"no task"* ]]
}

# --- done / archive ---------------------------------------------------------

@test "done: removes worktrees and session, keeps branch and task record" {
  two_repos
  cd "$TMP"
  collie new x -r A -r B
  run collie done x
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/repos/A/feat-x" ] && [ ! -e "$TMP/repos/B.worktrees/feat-x" ]
  ! tmux has-session -t =x 2>/dev/null
  git -C "$TMP/repos/A" show-ref -q --verify refs/heads/feat/x
  [ "$(fm x status)" = done ]
  grep -q task_done "$(task_dir x)/events.log"
}

@test "done: refuses dirty or unmerged worktrees (all-or-nothing), --force overrides" {
  two_repos
  cd "$TMP"
  collie new x -r A -r B --no-window
  git -C "$TMP/repos/A/feat-x" commit -q --allow-empty -m work
  echo wip >"$TMP/repos/B.worktrees/feat-x/f"
  run collie done x
  [ "$status" -ne 0 ]
  [[ "$output" == *unmerged* && "$output" == *dirty* ]]
  [ -d "$TMP/repos/A/feat-x" ] && [ -d "$TMP/repos/B.worktrees/feat-x" ]
  [ "$(fm x status)" = active ]
  run collie done x --force
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/repos/A/feat-x" ]
}

@test "archive: marks task archived" {
  make_bare_repo A
  cd "$REPO/main"
  collie new x --no-window
  run collie archive x
  [ "$status" -eq 0 ]
  [ "$(fm x status)" = archived ]
  [ ! -e "$REPO/feat-x" ]
}

@test "done: refuses when standing inside one of the task's worktrees (outside its session)" {
  make_bare_repo A
  cd "$REPO/main"
  collie new x --no-window
  cd "$REPO/feat-x"
  run collie done x
  [ "$status" -ne 0 ]
  [[ "$output" == *"currently inside"* ]]
  [ -d "$REPO/feat-x" ]
}

# --- misc -------------------------------------------------------------------

@test "help: lists commands; unknown command fails" {
  run collie help
  [ "$status" -eq 0 ]
  [[ "$output" == *new* && "$output" == *done* && "$output" == *workspaces* ]]
  run collie bogus
  [ "$status" -ne 0 ]
}
