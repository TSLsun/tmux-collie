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
  [ "$(fm x id)" = x ] && [ "$(fm x title)" = x ] && [ -z "$(fm x status)" ]
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

@test "new: -t sets branch type, --title sets frontmatter; no stored status or next" {
  make_bare_repo A
  cd "$REPO/main"
  run collie new y -t fix --title "fix: a & b / c" --no-window
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO/fix-y" branch --show-current)" = fix/y ]
  [ "$(fm y title)" = "fix: a & b / c" ]
  ! grep -qE '^(status|next):' "$(task_dir y)/TASK.md"
  run collie new w --todo --no-window
  [ "$status" -ne 0 ]
}

@test "new: -m writes the objective into TASK.md" {
  make_bare_repo A
  cd "$REPO/main"
  run collie new x -m 'add OAuth login & keep $HOME' --no-window
  [ "$status" -eq 0 ]
  run awk '/^## Objective$/ { getline; print; exit }' "$(task_dir x)/TASK.md"
  [ "$output" = 'add OAuth login & keep $HOME' ]
  grep -qx '## Context' "$(task_dir x)/TASK.md"
}

@test "new: without an id and no tty, prints usage" {
  make_bare_repo A
  cd "$REPO/main"
  run collie new --no-window </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: collie new"* ]]
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
  collie new y -r A --no-window
  collie new z -r B --no-window
  collie archive z
  run collie ls
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "x	todo	P2	*	-	A,B" ]]
  [[ "${lines[1]}" == "y	todo	P2	-	-	A" ]]
  run collie ls -a
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[2]}" == "z	archived	P2	-	-	B" ]]
}

# run 1 of a task, started in 2020 and exited (no session)
past_run() {
  printf '2020-01-01T00:00:00Z\trun_started\trun=1 agent=sleep repo=A\n2020-01-01T00:00:01Z\trun_exited\trun=1 code=0\n' >>"$(task_dir "$1")/events.log"
}

@test "ls: status is derived: todo (no run), active (run), review (fresh REPORT.md)" {
  make_bare_repo A
  cd "$REPO/main"
  for t in a r s t; do collie new "$t" --no-window; done
  past_run a
  past_run r
  echo "All green." >"$(task_dir r)/REPORT.md"
  past_run s
  echo "old" >"$(task_dir s)/REPORT.md"
  touch -t 201901010000 "$(task_dir s)/REPORT.md"
  run collie ls
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1,2 | paste -s -d' ' -)" = "a	active r	review s	active t	todo" ]
}

@test "ls/show: old records with next: and status: blocked still list" {
  make_bare_repo A
  cd "$REPO/main"
  collie new x --no-window
  f="$(task_dir x)/TASK.md"
  awk 'NR == 2 { print "status: blocked"; print "next: ask about retries" } { print }' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  run collie ls
  [ "$status" -eq 0 ]
  [ "$output" = "x	todo	P2	-	-	A" ]
  run collie show x
  [ "$status" -eq 0 ]
  [[ "$output" == *"status: todo"* && "$output" != *blocked* && "$output" != *"next:"* ]]
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
  wait_for '[ "$(window_path x B)" = "$TMP/repos/B.worktrees/feat-x" ]'
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
  echo work >"$TMP/repos/A/feat-x/w"
  git -C "$TMP/repos/A/feat-x" add w
  git -C "$TMP/repos/A/feat-x" commit -q -m work
  echo wip >"$TMP/repos/B.worktrees/feat-x/f"
  run collie done x
  [ "$status" -ne 0 ]
  [[ "$output" == *unmerged* && "$output" == *dirty* ]]
  [ -d "$TMP/repos/A/feat-x" ] && [ -d "$TMP/repos/B.worktrees/feat-x" ]
  [ -z "$(fm x status)" ]
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

@test "new: ship off by default leaves TASK.md as the template" {
  make_bare_repo A
  cd "$REPO/main"
  run collie new x --no-window
  [ "$status" -eq 0 ]
  diff <(sed '1,/^---$/d' "$(task_dir x)/TASK.md") "$COLLIE_ROOT/templates/TASK.md"
}

@test "new: ship on (COLLIE_SHIP, --ship) appends the ship rules; --no-ship wins" {
  make_bare_repo A
  cd "$REPO/main"
  COLLIE_SHIP=on collie new a --no-window
  collie new b --ship --no-window
  COLLIE_SHIP=1 collie new c --no-ship --no-window
  for id in a b; do
    grep -qx '## Ship' "$(task_dir $id)/TASK.md"
    grep -q 'REPORT.md' "$(task_dir $id)/TASK.md"
    grep -qx '## Verify' "$(task_dir $id)/TASK.md"
  done
  ! grep -q '^## Ship' "$(task_dir c)/TASK.md"
}

@test "new: ship from @collie-ship" {
  make_bare_repo A
  cd "$REPO/main"
  tmux -f /dev/null new-session -d -s keep
  tmux set -g @collie-ship on
  collie new a --no-window
  grep -qx '## Ship' "$(task_dir a)/TASK.md"
}
