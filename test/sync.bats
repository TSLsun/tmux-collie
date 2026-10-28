#!/usr/bin/env bats

load helper
bats_require_minimum_version 1.5.0

# The agent is `sleep` (generic adapter): a stand-in whose hooks the tests
# fire by hand, and whose pane echoes whatever sync types into it.
setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=sleep
  make_bare_repo A
  cd "$REPO/main"
}
teardown() { teardown_env; }

commit_in() { # dir file [content]
  echo "${3:-$2}" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "add $2"
}

# another PR lands on origin's main
land() { # file [content]
  commit_in "$TMP/origin-A" "$@"
}

wt() { echo "$TMP/repos/A/feat-$1"; }

@test "sync: merges base into a clean branch; up-to-date, merged and untouched tasks are left alone" {
  for t in s u m; do collie new "$t" --no-window; done
  commit_in "$(wt s)" s
  commit_in "$(wt m)" m
  git -C "$TMP/origin-A" fetch -q "$REPO/.bare" feat/m
  git -C "$TMP/origin-A" merge -q --squash FETCH_HEAD >/dev/null
  git -C "$TMP/origin-A" commit -q -m "squash feat/m"
  land other
  run --separate-stderr collie sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"s A: merged 2 commit(s) from origin/main"* ]]
  [[ "$output" == *"m A: skipped: merged into origin/main (clean up with: collie gc)"* ]]
  [[ "$output" == *"u A: skipped: no commits beyond origin/main"* ]]
  [ "$stderr" = "collie: A: fetching origin…"$'\n'"collie: A: fetched (base origin/HEAD @ $(git -C "$REPO" rev-parse --short origin/HEAD))" ]
  git -C "$(wt s)" merge-base --is-ancestor origin/main HEAD
  [ "$(git -C "$(wt s)" log -1 --format=%s)" = "Merge origin/main into feat/s" ]
  [ -f "$(wt s)/other" ] && [ -f "$(wt s)/s" ]
  grep -q "synced	repo=A base=" "$(task_dir s)/events.log"
  run --separate-stderr collie sync s
  [ "$output" = "s A: up to date" ]
}

@test "sync: pushes a merged branch that has an upstream" {
  collie new s --no-window
  commit_in "$(wt s)" s
  git -C "$(wt s)" push -q -u origin feat/s
  land other
  run --separate-stderr collie sync s
  [[ "$output" == *"s A: merged 1 commit(s) from origin/main, pushed"* ]]
  [ "$(git -C "$TMP/origin-A" rev-parse feat/s)" = "$(git -C "$(wt s)" rev-parse HEAD)" ]
}

@test "sync -n: predicts without touching worktrees" {
  collie new s --no-window
  collie new c --no-window
  commit_in "$(wt s)" s
  commit_in "$(wt c)" f mine
  land f theirs
  echo dirty >"$(wt s)/d"
  head=$(git -C "$(wt c)" rev-parse HEAD)
  run --separate-stderr collie sync -n
  [ "$status" -eq 0 ]
  [[ "$output" == *"s A: would merge 1 commit(s) from origin/main"* ]]
  [[ "$output" == *"c A: conflict in f"* ]]
  [ "$(git -C "$(wt c)" rev-parse HEAD)" = "$head" ]
  [ "$(git -C "$(wt s)" rev-list --count HEAD)" = 2 ]
}

@test "sync: skips dirty worktrees and tasks whose agent is working or waiting" {
  collie new d --no-window
  collie new w --no-window
  commit_in "$(wt d)" d
  commit_in "$(wt w)" w
  echo dirty >"$(wt d)/x"
  collie run w -- 300
  hook w waiting
  land other
  run collie sync
  [[ "$output" == *"d A: skipped: uncommitted changes"* ]]
  [[ "$output" == *"w A: skipped: agent busy"* ]]
  ! git -C "$(wt w)" merge-base --is-ancestor origin/main HEAD
}

@test "sync: a conflict without an agent leaves the worktree untouched" {
  collie new c --no-window
  commit_in "$(wt c)" f mine
  land f theirs
  run --separate-stderr collie sync
  [ "$output" = "c A: conflict in f; no agent to resolve it" ]
  [ -z "$(git -C "$(wt c)" status --porcelain)" ]
  ! git -C "$(wt c)" rev-parse -q --verify MERGE_HEAD
}

@test "sync: a conflict is started and typed into the idle agent" {
  collie new c --no-window
  commit_in "$(wt c)" f mine
  collie run c -- 300
  hook c idle
  land f theirs
  run --separate-stderr collie sync
  [ "$output" = "c A: conflict in f; sent to the agent in $(tmux display -p -t "$(run_pane c)" '#{window_id}')" ]
  git -C "$(wt c)" rev-parse -q --verify MERGE_HEAD
  wait_for "tmux capture-pane -p -J -t '$(run_pane c)' | grep -q 'conflicts in: f. Resolve them'"
  grep -q "sync_conflict	repo=A base=.* files=f" "$(task_dir c)/events.log"
}

@test "sync: a conflict is typed into the agent's pane of a split window, not the active pane" {
  collie new c --no-window
  commit_in "$(wt c)" f mine
  collie run c -- 300
  hook c idle
  local agent other
  agent=$(run_pane c)
  other=$(tmux split-window -P -F '#{pane_id}' -t "$agent")
  [ "$(run_pane c)" = "$other" ]
  land f theirs
  run --separate-stderr collie sync
  [ "$output" = "c A: conflict in f; sent to the agent in $(tmux display -p -t "$agent" '#{window_id}')" ]
  wait_for "tmux capture-pane -p -J -t '$agent' | grep -q 'conflicts in: f. Resolve them'"
  ! tmux capture-pane -p -J -t "$other" | grep -q 'Resolve them'
}

@test "sync: a conflict for an idle agent whose pane is gone sends no keys" {
  collie new c --no-window
  commit_in "$(wt c)" f mine
  collie run c -- 300
  hook c idle
  local agent other
  agent=$(run_pane c)
  other=$(tmux split-window -P -F '#{pane_id}' -t "$agent")
  tmux kill-pane -t "$agent"
  land f theirs
  run --separate-stderr collie sync
  [ "$output" = "c A: conflict in f; agent pane not found, resolve it in $(wt c)" ]
  git -C "$(wt c)" rev-parse -q --verify MERGE_HEAD
  sleep 0.5
  ! tmux capture-pane -p -J -t "$other" | grep -q 'Resolve them'
}

@test "sync: a conflict for an exited agent starts a new run of it" {
  collie new c --no-window
  commit_in "$(wt c)" f mine
  collie run c -- 0
  wait_for "grep -q run_exited '$(task_dir c)/events.log'"
  land f theirs
  run --separate-stderr collie sync
  [ "$output" = "c A: conflict in f; started a sleep run" ]
  git -C "$(wt c)" rev-parse -q --verify MERGE_HEAD
  grep -q "run_started	run=2 agent=sleep repo=A" "$(task_dir c)/events.log"
}

@test "dash sync: shows sync -n for the marked ids, asks, then syncs only those" {
  for t in a b c; do collie new "$t" --no-window; done
  for t in a b c; do commit_in "$(wt $t)" "$t"; done
  land other
  run --separate-stderr collie _actions a s a b <<<n
  [[ "$output" == *"a A: would merge 1 commit(s) from origin/main"* ]]
  [[ "$output" == *"b A: would merge"* && "$output" != *"c A:"* ]]
  [ ! -f "$(wt a)/other" ]
  run --separate-stderr collie _actions a s a b <<<y
  [ -f "$(wt a)/other" ] && [ -f "$(wt b)/other" ] && [ ! -f "$(wt c)/other" ]
  [ "$(git -C "$(wt c)" log -1 --format=%s)" = "add c" ]
}

@test "dash sync: with nothing marked, syncs the task under the cursor only" {
  for t in a b; do collie new "$t" --no-window; done
  for t in a b; do commit_in "$(wt $t)" "$t"; done
  land other
  run --separate-stderr collie _actions b s <<<y
  [ -f "$(wt b)/other" ] && [ ! -f "$(wt a)/other" ]
}

@test "sync -n: predicts conflicts between tasks; dash shows them until a branch moves" {
  for t in x y z u m; do collie new "$t" --no-window; done
  commit_in "$(wt x)" f from-x
  commit_in "$(wt y)" f from-y
  commit_in "$(wt z)" z
  # merged (squash) and untouched (u) branches take no part
  commit_in "$(wt m)" g
  git -C "$TMP/origin-A" fetch -q "$REPO/.bare" feat/m
  git -C "$TMP/origin-A" merge -q --squash FETCH_HEAD >/dev/null
  git -C "$TMP/origin-A" commit -q -m "squash feat/m"
  run --separate-stderr collie sync -n
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n'"between tasks (whichever lands first, the other conflicts):"$'\n'"  x × y A: conflict in f" ]]
  [[ "$output" != *"× m"* && "$output" != *"× u"* && "$output" != *"z ×"* && "$output" != *"× z"* ]]
  [ "$(collie dash -n | awk -F'\t' '{ print $1 ":" $9 }' | sort | paste -s -d, -)" = "m:-,u:-,x:1,y:1,z:-" ]
  plain=$(collie _rows | sed $'s/\033\\[[0-9;]*m//g' | cut -f2)
  [[ "$plain" == *$'\n'"○ x     start  P2   -      now  A      -   ⚡1"$'\n'* ]]
  [[ "$plain" == *$'\n'"○ z     start  P2   -      now  A      -"$'\n'* ]]
  # the badge counts toward the row's width in a narrow list (42 columns)
  plain=$(COLUMNS=45 collie _rows | sed $'s/\033\\[[0-9;]*m//g' | cut -f2)
  [[ "$plain" == *$'\n'"○ x     start  P2   -      A      -   ⚡1"$'\n'* ]]
  local l
  while IFS= read -r l; do LC_ALL=C.UTF-8 eval '[ "${#l}" -le 42 ]'; done <<<"$plain"
  [[ "$(collie _preview y)" == *$'\n'"conflicts with: x (f)" ]]
  [[ "$(collie _preview z)" != *"conflicts with"* ]]
  # a new commit on x: the caches are stale, nothing shows; a background refresh fixes it
  commit_in "$(wt x)" f from-x-2
  [ "$(collie dash -n | awk -F'\t' '$9 != "-"' | wc -l | tr -d ' ')" = 0 ]
  [[ "$(collie _preview y)" != *"conflicts with"* ]]
  wait_for "grep -q '$(git -C "$(wt x)" rev-parse HEAD)' '$(task_dir y)/conflicts.tsv'"
  wait_for "[ ! -d '$COLLIE_STATE_DIR/conflicts.lock' ]"
  [[ "$(collie _preview y)" == *$'\n'"conflicts with: x (f)" ]]
  # a branch that conflicts with base shows that alone and skips pairs
  land f theirs
  run --separate-stderr collie sync -n
  [[ "$output" == *"x A: conflict in f"* && "$output" == *"y A: conflict in f"* ]]
  [[ "$output" == *$'\n'"between tasks: no conflicts" ]]
  [[ "$(collie _preview x)" == *$'\n'"conflicts with: base (f)" ]]
}
