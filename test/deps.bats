#!/usr/bin/env bats

load helper

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=sleep
  make_bare_repo A
  cd "$REPO/main"
}
teardown() { teardown_env; }

needs_of() { collie ls -a | awk -F'\t' -v id="$1" '$1 == id { print $7 }'; }

# --- set / new ----------------------------------------------------------------

@test "deps: set after= writes, normalizes and clears the field; logs it" {
  collie new a --no-window
  collie new b --no-window
  collie new x --no-window
  run collie set x "after=a,b  a"
  [ "$status" -eq 0 ]
  [ "$(fm x after)" = "a b" ]
  grep -q "field_set	after=a b" "$(task_dir x)/events.log"
  collie set x after=
  ! grep -q '^after:' "$(task_dir x)/TASK.md"
}

@test "deps: set refuses a self dep and bad ids; warns on unknown ids and cycles" {
  collie new a --no-window
  collie new x --no-window
  run collie set x after=x
  [ "$status" -ne 0 ]
  run collie set x after=Bad_id
  [ "$status" -ne 0 ]
  [ -z "$(fm x after)" ]
  run collie set x after=ghost
  [ "$status" -eq 0 ]
  [[ "$output" == *"no task 'ghost'"* ]]
  collie set a after=x
  run collie set x after=a
  [ "$status" -eq 0 ]
  [[ "$output" == *"dependency cycle"* ]]
  [ "$(fm x after)" = a ]
}

@test "deps: new --after sets the field (repeatable)" {
  collie new a --no-window
  collie new b --no-window
  collie new x --no-window --after a --after b
  [ "$(fm x after)" = "a b" ]
  run collie new y --no-window --after y
  [ "$status" -ne 0 ]
  [ ! -e "$(task_dir y)" ]
}

# --- satisfied / blocked --------------------------------------------------------

@test "deps: ls needs is blocked:<ids> until each dep is done or its PRs merged" {
  collie new a --no-window
  collie new b --no-window
  collie new x --no-window --after "a b"
  [ "$(needs_of x)" = "blocked:a,b" ]
  [ "$(needs_of a)" = start ]
  collie done a
  [ "$(needs_of x)" = "blocked:b" ]
  printf 'A\t76\tmerged\n' >"$(task_dir b)/pr.tsv"
  [ "$(needs_of x)" = start ]
  # one unmerged PR keeps it blocked
  printf 'A\t76\tmerged\nB\t77\topen\n' >"$(task_dir b)/pr.tsv"
  [ "$(needs_of x)" = "blocked:b" ]
  # CI field; a superseded closed PR beside the merged one does not block
  printf 'A\t75\tclosed\t-\nA\t76\tmerged\tpass\n' >"$(task_dir b)/pr.tsv"
  [ "$(needs_of x)" = start ]
}

@test "deps: archived, unknown and cyclic deps block without failing ls" {
  collie new a --no-window
  collie new x --no-window --after a
  collie archive a
  [ "$(needs_of x)" = "blocked:a" ]
  collie new y --no-window
  collie new y2 --no-window
  collie set y after=y2 2>/dev/null
  collie set y2 after=y 2>/dev/null
  run collie ls
  [ "$status" -eq 0 ]
  [ "$(needs_of y)" = "blocked:y2" ]
  [ "$(needs_of y2)" = "blocked:y" ]
  run collie _preview y
  [ "$status" -eq 0 ]
  [[ "$output" == *"after:  (dependency cycle)"* ]]
}

@test "deps: only todo tasks are gated" {
  collie new a --no-window
  collie new x --no-window --after a
  printf '2020-01-01T00:00:00Z\trun_started\trun=1 agent=sleep repo=A\n2020-01-01T00:00:01Z\trun_exited\trun=1 code=0\n' >>"$(task_dir x)/events.log"
  [ "$(needs_of x)" = stalled ]
}

# --- display ------------------------------------------------------------------

@test "deps: dash row says blocked (not needs you), sorted after start" {
  collie new a --no-window
  collie new x --no-window --after a
  collie new z --no-window
  plain=$(collie _rows | sed $'s/\033\\[[0-9;]*m//g')
  [ "$(printf '%s\n' "$plain" | cut -f1 | paste -s -d, -)" = "a,z,x," ]
  [[ "$(printf '%s\n' "$plain" | sed -n 3p)" == *"○ x  blocked"* ]]
  [[ "$plain" != *"needs you"* ]]
}

@test "deps: preview and show list each dep with its state, and what it blocks" {
  collie new a --no-window
  collie new b --no-window
  collie new x --no-window --after "a b ghost"
  printf 'A\t74\tdraft\n' >"$(task_dir b)/pr.tsv"
  collie archive a
  run collie _preview x
  [ "$status" -eq 0 ]
  [[ "$output" == *$'after:\n  ✗ a  archived\n  · b  todo  #74:draft\n  ✗ ghost  unknown task'* ]]
  run collie _preview b
  [[ "$output" == *"blocks: x"* ]]
  run collie show x
  [ "$status" -eq 0 ]
  [[ "$output" == *"  · b  todo  #74:draft"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^after:')" -eq 1 ]
}

# --- run ----------------------------------------------------------------------

@test "deps: run on a blocked task warns off a terminal and still runs" {
  collie new a --no-window
  collie new x --after a
  run collie run x
  [ "$status" -eq 0 ]
  [[ "$output" == *"x is blocked on: a"* ]]
  grep -q run_started "$(task_dir x)/events.log"
}

@test "deps: dash R on a blocked task asks first; the panel names the deps" {
  collie new a --no-window
  collie new x --no-window --after a
  [ "$(FZF_PROMPT='collie> ' collie _key R x)" = "change-prompt(? r x )+refresh-preview" ]
  [[ "$(FZF_PROMPT='? r x ' COLLIE_DASH="$TMP" collie _preview x)" == *"run x? (y/n)"*"blocked on: a"* ]]
  [[ "$(FZF_PROMPT='collie> ' collie _key R a)" == *"_bg r a)" ]]
}
