#!/usr/bin/env bats

load helper

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=race-fake
  make_bare_repo A
  cd "$REPO/main"
  mkdir -p "$TMP/bin"
  export PATH="$TMP/bin:$PATH"
  cat >"$TMP/bin/race-fake" <<EOF
#!/bin/bash
set -e
while [ ! -e "$TMP/go-\$COLLIE_TASK" ]; do sleep 0.02; done
printf 'candidate %s\\n' "\$COLLIE_TASK" >"\$COLLIE_TASK"
git add "\$COLLIE_TASK"
git commit -q -m "candidate \$COLLIE_TASK"
printf 'REPORT %s\\n' "\$COLLIE_TASK" >"\$COLLIE_TASK_DIR/REPORT.md"
"$COLLIE_ROOT/bin/collie" signal done
"$COLLIE_ROOT/bin/collie" state idle
read -r _
EOF
  chmod +x "$TMP/bin/race-fake"
  collie new race --no-window --title 'Race contract'
  printf '\n## Objective\nChoose the strongest candidate.\n' >>"$(task_dir race)/TASK.md"
}
teardown() { teardown_env; }

release_candidates() {
  touch "$TMP/go-race-1" "$TMP/go-race-2"
  collie wait race-1 --run 1 --done --timeout 30
  collie wait race-2 --run 1 --done --timeout 30
}

@test "race: candidates start from one base, finish, review and pick while preserving branches" {
  local base parent picked
  base=$(git -C "$REPO/main" rev-parse HEAD)
  run collie race race -n 2 --agent race-fake,race-fake -p 'same prompt'
  [ "$status" -eq 0 ]
  [[ "$output" == *'race-1 1 '* && "$output" == *'race-2 1 '* ]]
  grep -q "race_started.*base=$base repo=A n=2" "$(task_dir race)/events.log"
  grep -q 'race_candidate.*task=race-1 agent=race-fake branch=exp/race-1' "$(task_dir race)/events.log"
  grep -q 'race_candidate.*task=race-2 agent=race-fake branch=exp/race-2' "$(task_dir race)/events.log"
  [ "$(git -C "$REPO" rev-parse refs/heads/exp/race-1)" = "$base" ]
  [ "$(git -C "$REPO" rev-parse refs/heads/exp/race-2)" = "$base" ]
  [ "$(git -C "$REPO/exp-race-1" branch --show-current)" = exp/race-1 ]
  [ "$(git -C "$REPO/exp-race-2" branch --show-current)" = exp/race-2 ]
  cmp "$(task_dir race)/TASK.md" "$(task_dir race-1)/TASK.md"
  cmp "$(task_dir race)/TASK.md" "$(task_dir race-2)/TASK.md"
  [ -n "$(run_pane race-1 1)" ] && [ -n "$(run_pane race-2 1)" ]

  release_candidates
  run collie review race
  [ "$status" -eq 0 ]
  [[ "$output" == *'race-1'* && "$output" == *'race-2'* ]]
  [[ "$output" == *'race-1 | 1 +'* && "$output" == *'race-2 | 1 +'* ]]
  [[ "$output" == *'REPORT race-1'* && "$output" == *'REPORT race-2'* ]]

  picked=$(git -C "$REPO" rev-parse exp/race-2)
  collie pick race 2
  parent=$(git -C "$REPO" rev-parse feat/race)
  [ "$parent" = "$picked" ]
  [ "$(git -C "$REPO" rev-parse exp/race-1)" != "$parent" ]
  [ "$(git -C "$REPO" rev-parse exp/race-2)" = "$parent" ]
  grep -q 'race_picked.*n=2 task=race-2 commit=' "$(task_dir race)/events.log"
}

@test "race: refuses a moved parent branch when picking and retains candidate branches" {
  collie race race -n 2 --agent race-fake,race-fake
  release_candidates
  printf 'parent moved\n' >"$REPO/feat-race/parent"
  git -C "$REPO/feat-race" add parent
  git -C "$REPO/feat-race" commit -q -m 'move parent'
  run collie pick race 2
  [ "$status" -ne 0 ]
  [[ "$output" == *'base'* || "$output" == *'changed'* ]]
  [ "$(git -C "$REPO" rev-parse exp/race-1)" != "$(git -C "$REPO" rev-parse feat/race)" ]
  git -C "$REPO" show-ref --verify --quiet refs/heads/exp/race-1
  git -C "$REPO" show-ref --verify --quiet refs/heads/exp/race-2
}

@test "race: refuses reuse without changing the existing candidate branches" {
  collie race race -n 2 --agent race-fake,race-fake
  release_candidates
  run collie race race -n 2 --agent race-fake,race-fake
  [ "$status" -ne 0 ]
  [[ "$output" == *"already"* || "$output" == *"exists"* ]]
  git -C "$REPO" show-ref --verify --quiet refs/heads/exp/race-1
  git -C "$REPO" show-ref --verify --quiet refs/heads/exp/race-2
}

@test "race: a failed agent launch retains both candidates and starts the next" {
  run collie race race -n 2 --agent missing-race-agent,race-fake
  [ "$status" -ne 0 ]
  [[ "$output" == *"run failed for race-1"* ]]
  git -C "$REPO" show-ref --verify --quiet refs/heads/exp/race-1
  git -C "$REPO" show-ref --verify --quiet refs/heads/exp/race-2
  touch "$TMP/go-race-2"
  collie wait race-2 --run 1 --done --timeout 30
}

@test "race: a mid-race creation failure rolls back every candidate and a retry succeeds" {
  local events
  events=$(cat "$(task_dir race)/events.log")
  cat >"$TMP/stub/ln" <<'SH'
#!/bin/bash
case "${@: -1}" in */race-2/repos/A) exit 1 ;; esac
exec /bin/ln "$@"
SH
  chmod +x "$TMP/stub/ln"
  run collie race race -n 2 --agent race-fake,race-fake
  [ "$status" -ne 0 ]
  [[ "$output" == *"rolled back"* ]]
  [ ! -e "$(task_dir race-1)" ] && [ ! -e "$(task_dir race-2)" ]
  [ ! -e "$REPO/exp-race-1" ] && [ ! -e "$REPO/exp-race-2" ]
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/exp/race-1
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/exp/race-2
  [ "$(cat "$(task_dir race)/events.log")" = "$events" ]
  ! git -C "$REPO" worktree list | grep -q exp-race

  rm "$TMP/stub/ln"
  run collie race race -n 2 --agent race-fake,race-fake
  [ "$status" -eq 0 ]
  [[ "$output" == *'race-1 1 '* && "$output" == *'race-2 1 '* ]]
  [ "$(grep -c race_started "$(task_dir race)/events.log")" -eq 1 ]
  release_candidates
}

@test "race: pick --archive-rest archives the losers and keeps every exp branch" {
  local picked
  collie race race -n 3 --agent race-fake
  touch "$TMP/go-race-3"
  release_candidates
  collie wait race-3 --run 1 --done --timeout 30
  picked=$(git -C "$REPO" rev-parse exp/race-2)
  run collie pick race 2 --archive-rest
  [ "$status" -eq 0 ]
  [[ "$output" == *'archived race-1'* && "$output" == *'archived race-3'* ]]
  [[ "$output" != *'archived race-2'* && "$output" != *hint:* ]]
  [ "$(git -C "$REPO" rev-parse feat/race)" = "$picked" ]
  run collie ls -a
  [[ "$output" == *$'race-1\tarchived'* && "$output" == *$'race-3\tarchived'* ]]
  [[ "$output" != *$'race-2\tarchived'* ]]
  for b in exp/race-1 exp/race-2 exp/race-3; do
    git -C "$REPO" show-ref --verify --quiet "refs/heads/$b"
  done
}

@test "race: pick --archive-rest refuses a dirty loser, archives the rest, and --force archives it" {
  collie race race -n 3 --agent race-fake
  touch "$TMP/go-race-3"
  release_candidates
  collie wait race-3 --run 1 --done --timeout 30
  printf 'unsaved\n' >"$REPO/exp-race-1/scratch"
  run collie pick race 2 --archive-rest
  [ "$status" -ne 0 ]
  [[ "$output" == *'refused race-1'*'--force'* && "$output" == *'archived race-3'* ]]
  [ "$(git -C "$REPO" rev-parse feat/race)" = "$(git -C "$REPO" rev-parse exp/race-2)" ]
  [ -f "$REPO/exp-race-1/scratch" ]
  fm_status() { awk '/^status:/ { print $2 }' "$(task_dir "$1")/TASK.md"; }
  [ "$(fm_status race-1)" != archived ]
  [ "$(fm_status race-3)" = archived ]
  # pick cannot run twice (the branch has moved); archive the loser directly
  run collie archive race-1 --force
  [ "$status" -eq 0 ]
  [ "$(fm_status race-1)" = archived ]
  git -C "$REPO" show-ref --verify --quiet refs/heads/exp/race-1
}

@test "race: pick --archive-rest --force archives a dirty loser" {
  collie race race -n 2 --agent race-fake
  release_candidates
  printf 'unsaved\n' >"$REPO/exp-race-1/scratch"
  run collie pick race 2 --force --archive-rest
  [ "$status" -eq 0 ]
  [[ "$output" == *'archived race-1'* ]]
  run collie ls -a
  [[ "$output" == *$'race-1\tarchived'* ]]
  git -C "$REPO" show-ref --verify --quiet refs/heads/exp/race-1
}

@test "race: plain pick hints only open losers; --force alone errors" {
  collie race race -n 3 --agent race-fake
  touch "$TMP/go-race-3"
  release_candidates
  collie wait race-3 --run 1 --done --timeout 30
  run collie pick race 2 --force
  [ "$status" -ne 0 ]
  [[ "$output" == *'--force needs --archive-rest'* ]]
  [ "$(git -C "$REPO" rev-parse feat/race)" != "$(git -C "$REPO" rev-parse exp/race-2)" ]
  collie archive race-3
  run collie pick race 2
  [ "$status" -eq 0 ]
  [[ "$output" == *'hint: collie archive race-1'* ]]
  [[ "$output" != *'hint: collie archive race-2'* && "$output" != *'hint: collie archive race-3'* ]]
}
