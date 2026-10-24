#!/usr/bin/env bats

load helper

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=sleep
  make_bare_repo A
  cd "$REPO/main"
}
teardown() { teardown_env; }

# --- set --------------------------------------------------------------------

@test "set: updates status, priority, next and title; logs each change" {
  collie new x --no-window
  run collie set x status=review priority=P1 "next=ask about retries" "title=Retry: v2"
  [ "$status" -eq 0 ]
  [ "$(fm x status)" = review ]
  [ "$(fm x priority)" = P1 ]
  [ "$(fm x next)" = "ask about retries" ]
  [ "$(fm x title)" = "Retry: v2" ]
  grep -q "field_set	next=ask about retries" "$(task_dir x)/events.log"
}

@test "set: rejects bad fields and values without writing anything" {
  collie new x --no-window
  for bad in status=done status=bogus priority=P9 colour=red; do
    run collie set x next=keep "$bad"
    [ "$status" -ne 0 ]
  done
  [ -z "$(fm x next)" ]
  run collie set x
  [ "$status" -ne 0 ]
}

@test "set: a field without a value is read from stdin; COLLIE_TASK is the default" {
  collie new x --no-window
  echo "write the migration" | COLLIE_TASK=x collie set next
  [ "$(fm x next)" = "write the migration" ]
}

# --- notes ------------------------------------------------------------------

@test "notes: creates NOTES.md and opens it in \$EDITOR" {
  collie new x --no-window
  printf '#!/bin/sh\necho edited >>"$1"\n' >"$TMP/ed"
  chmod +x "$TMP/ed"
  EDITOR="$TMP/ed" collie notes x
  [ "$(cat "$(task_dir x)/NOTES.md")" = "$(printf '# x\n\nedited')" ]
}

# --- dashboard --------------------------------------------------------------

@test "dash -n: waiting > idle > review > blocked > working > rest (by priority, id)" {
  for t in a b c d e f g; do collie new "$t" --no-window; done
  collie new z --no-window
  collie archive z
  collie run a -- 300
  collie run b -- 300
  collie run c -- 300
  hook b waiting
  hook c idle
  collie set d status=review
  collie set e status=blocked
  collie set g priority=P0
  run collie dash -n
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1 | paste -s -d' ' -)" = "b c d e a g f" ]
}

@test "_preview: title, next, runs, per-repo ahead/dirty and notes tail" {
  collie new x --no-window --title "Ship it"
  collie set x "next=open the PR"
  wt="$TMP/repos/A/feat-x"
  echo hi >"$wt/f"
  git -C "$wt" add f
  git -C "$wt" commit -q -m f
  echo dirty >"$wt/g"
  printf '# x\n\nlast note\n' >"$(task_dir x)/NOTES.md"
  run collie _preview x
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ship it"* ]]
  [[ "$output" == *"next: open the PR"* ]]
  [[ "$output" == *"A  feat/x  1 ahead, 1 dirty"* ]]
  [[ "$output" == *"last note"* ]]
}

@test "_target: window of the most urgent run (where dash jumps to)" {
  collie new x --no-window
  collie run x -- 300
  collie run x -- 300
  hook x waiting 2
  [ "$(collie _target x)" = "$(tmux display -p -t "$(run_pane x 2)" '#{window_id}')" ]
}

# --- tmux integration -------------------------------------------------------

@test "done works from tmux run-shell (menu action)" {
  collie new x
  tmux run-shell "$COLLIE_ROOT/bin/collie done x"
  [ "$(fm x status)" = done ]
}
