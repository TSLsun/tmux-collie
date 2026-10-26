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

@test "set: updates priority and title; logs each change" {
  collie new x --no-window
  run collie set x priority=P1 "title=Retry: v2"
  [ "$status" -eq 0 ]
  [ "$(fm x priority)" = P1 ]
  [ "$(fm x title)" = "Retry: v2" ]
  grep -q "field_set	title=Retry: v2" "$(task_dir x)/events.log"
}

@test "set: rejects bad fields and values without writing anything" {
  collie new x --no-window
  for bad in status=review next=later priority=P9 colour=red; do
    run collie set x title=keep "$bad"
    [ "$status" -ne 0 ]
  done
  [ "$(fm x title)" = x ]
  run collie set x
  [ "$status" -ne 0 ]
}

@test "set: a field without a value is read from stdin; COLLIE_TASK is the default" {
  collie new x --no-window
  echo "Write the migration" | COLLIE_TASK=x collie set title
  [ "$(fm x title)" = "Write the migration" ]
}

# --- edit -------------------------------------------------------------------

@test "edit: opens TASK.md in \$EDITOR; COLLIE_TASK is the default; unknown task fails" {
  collie new x --no-window
  printf '#!/bin/sh\necho "- keep it small" >>"$1"\n' >"$TMP/ed"
  chmod +x "$TMP/ed"
  EDITOR="$TMP/ed" collie edit x
  [ "$(tail -n 1 "$(task_dir x)/TASK.md")" = "- keep it small" ]
  EDITOR="$TMP/ed" COLLIE_TASK=x collie edit
  [ "$(grep -c 'keep it small' "$(task_dir x)/TASK.md")" -eq 2 ]
  # an editor with arguments, like EDITOR='code --wait'
  printf '#!/bin/sh\necho "$1" >>"$2"\n' >"$TMP/ed2"
  chmod +x "$TMP/ed2"
  EDITOR="$TMP/ed2 --wait" collie edit x
  [ "$(tail -n 1 "$(task_dir x)/TASK.md")" = "--wait" ]
  run env EDITOR="$TMP/ed" bash "$COLLIE_ROOT/bin/collie" edit nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"no task 'nope'"* ]]
}

@test "edit: a hand-written status: line does not change the derived status" {
  collie new x --no-window
  cat >"$TMP/ed" <<'EOF'
#!/bin/sh
awk 'NR == 2 { print "status: blocked" } { print }' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
EOF
  chmod +x "$TMP/ed"
  EDITOR="$TMP/ed" collie edit x
  [ "$(fm x status)" = blocked ]
  [ "$(collie ls | cut -f2)" = todo ]
}

@test "notes, park: removed" {
  collie new x --no-window
  run collie notes x
  [ "$status" -ne 0 ]
  run collie park x -m later
  [ "$status" -ne 0 ]
}

# --- dashboard --------------------------------------------------------------

@test "dash -n: waiting > idle > review > working > rest (by priority, id)" {
  for t in a b c d e f g; do collie new "$t" --no-window; done
  collie new z --no-window
  collie archive z
  collie run a -- 300
  collie run b -- 300
  collie run c -- 300
  hook b waiting
  hook c idle
  # d: a past run (no session) that wrote its report
  printf '2020-01-01T00:00:00Z\trun_started\trun=1 agent=sleep repo=A\n' >>"$(task_dir d)/events.log"
  echo done >"$(task_dir d)/REPORT.md"
  collie set g priority=P0
  run collie dash -n
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1 | paste -s -d' ' -)" = "b c d a g e f" ]
}

@test "status: review once the agent is idle and REPORT.md is fresh; working stays active" {
  collie new x --no-window
  collie run x -- 300
  echo "All green." >"$(task_dir x)/REPORT.md"
  [ "$(collie ls | cut -f2)" = active ]
  hook x idle
  [ "$(collie ls | cut -f2)" = review ]
  hook x working
  [ "$(collie ls | cut -f2)" = active ]
}

@test "dash actions: no next/notes keys" {
  run collie _actions x N
  [ -z "$output" ]
  [ "$(FZF_PROMPT='collie> ' collie _key x N)" = "put(N)" ]
  [[ "$(collie _pick x 2>/dev/null)" != *notes* ]]
}

@test "dash actions: e edits the task's TASK.md" {
  collie new x --no-window
  [ "$(FZF_PROMPT='▸ adopt agent ' collie _key x down)" = "change-prompt(▸ edit task )" ]
  [[ "$(FZF_PROMPT='▸ run agent ' collie _key x e)" == *"_actions 'x' 'e')+reload("*"_rows)+refresh-preview" ]]
  [ "$(FZF_PROMPT='▸ new task ' collie _key '' e)" = "change-prompt(collie> )+clear-screen" ]
  printf '#!/bin/sh\necho edited >>"$1"\n' >"$TMP/ed"
  chmod +x "$TMP/ed"
  EDITOR="$TMP/ed" collie _actions x e
  [ "$(tail -n 1 "$(task_dir x)/TASK.md")" = edited ]
}

@test "_rows: id first, then status glyph and live agent badge; attention first" {
  for t in a b c; do collie new "$t" --no-window; done
  collie run a -- 300
  collie run b -- 300
  hook b waiting
  run collie _rows
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1 | paste -s -d' ' -)" = "b a c" ]
  plain=$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*m//g')
  [[ "$(printf '%s\n' "$plain" | sed -n 1p)" == "b	● b	active	P2	sleep	A" ]]
  [[ "$(printf '%s\n' "$plain" | sed -n 2p)" == "a	◐ a	active	P2	sleep	A" ]]
  [[ "$(printf '%s\n' "$plain" | sed -n 3p)" == "c	○ c	todo	P2	-	A" ]]
  [[ "$output" == *$'\033[31m●'* && "$output" == *$'\033[33m◐'* ]]
}

@test "manual agent: one started by hand in a task session shows up, idle by silence" {
  collie new x
  mkdir -p "$TMP/bin"
  ln -s "$(command -v sleep)" "$TMP/bin/claude"
  tmux new-window -d -t "=x:" "sh -c '$TMP/bin/claude 300; :'"
  wait_for '[ "$(COLLIE_SILENCE=999 agent_of x)" = working ]'
  [ "$(COLLIE_SILENCE=0 agent_of x)" = idle ]
  [[ "$(collie _rows | sed $'s/\033\\[[0-9;]*m//g')" == *"	claude	"* ]]
  run collie show x
  [[ "$output" == *"-	claude	"* ]]
}

@test "adopt: stops a hand-started agent and resumes it under collie run" {
  collie new x
  mkdir -p "$TMP/bin" "$TMP/manual"
  ln -s "$(command -v sleep)" "$TMP/manual/claude"
  printf '#!/bin/sh\necho "$@" >"%s/args"\nexec sleep 300\n' "$TMP" >"$TMP/bin/claude"
  chmod +x "$TMP/bin/claude"
  export PATH="$TMP/bin:$PATH"
  tmux new-window -d -t "=x:" -c "$TMP/repos/A/feat-x" "sh -c '$TMP/manual/claude 300; :'"
  wait_for '[ "$(agent_of x)" = working ]'
  run collie adopt x </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"confirm with -y"* ]]
  collie adopt x -y
  wait_for '[ -f "$TMP/args" ]'
  [[ "$(cat "$TMP/args")" == *"--settings"*"--continue" ]]
  ! pgrep -f "$TMP/manual/claude" >/dev/null
  grep -q "agent_adopted	agent=claude" "$(task_dir x)/events.log"
  grep -q "run_started	run=1 agent=claude repo=A" "$(task_dir x)/events.log"
  run collie adopt x -y
  [[ "$output" == *"no agent started by hand"* ]]
}

@test "_key: menu keys act only while the menu prompt is up; arrows move the selection" {
  [ "$(FZF_PROMPT='collie> ' collie _key x r)" = "put(r)" ]
  [ "$(FZF_PROMPT='collie> ' collie _key x esc)" = abort ]
  [ "$(FZF_PROMPT='collie> ' collie _key x enter)" = accept ]
  [ "$(FZF_PROMPT='collie> ' collie _key x up)" = up ]
  [[ "$(FZF_PROMPT='▸ run agent ' collie _key x r)" == "change-prompt(collie> )+clear-screen+execute("*"_actions 'x' 'r')+reload("*"_rows)+refresh-preview" ]]
  [ "$(FZF_PROMPT='▸ run agent ' collie _key x down)" = "change-prompt(▸ adopt agent )" ]
  [ "$(FZF_PROMPT='▸ run agent ' collie _key x up)" = "change-prompt(▸ new task )" ]
  [ "$(FZF_PROMPT='▸ new task ' collie _key x down)" = "change-prompt(▸ run agent )" ]
  [[ "$(FZF_PROMPT='▸ review ' collie _key x enter)" == *"_actions 'x' 'v'"* ]]
  [ "$(FZF_PROMPT='▸ run agent ' collie _key x esc)" = "change-prompt(collie> )+clear-screen" ]
  [ "$(FZF_PROMPT='▸ new task ' collie _key '' r)" = "change-prompt(collie> )+clear-screen" ]
}

@test "_actions: one key runs an action on the task; done and archive ask first" {
  collie new x --no-window
  collie _actions x r
  [ -n "$(run_pane x)" ]
  echo n | collie _actions x d
  [ -z "$(fm x status)" ]
  collie _actions x q
  printf '#!/bin/sh\npwd >"%s/pwd"\nexit 3\n' "$TMP" >"$TMP/sh"
  chmod +x "$TMP/sh"
  SHELL="$TMP/sh" collie _actions x t
  [ "$(cat "$TMP/pwd")" = "$TMP/repos/A/feat-x" ]
  echo n | collie _actions x x
  [ -z "$(fm x status)" ]
  echo y | collie _actions x x
  [ "$(fm x status)" = archived ]
}

@test "_actions: done after confirm" {
  collie new x --no-window
  echo y | collie _actions x d
  [ "$(fm x status)" = done ]
}

@test "_jump: waiting/idle records the pane; nothing recorded is an error" {
  collie new x --no-window
  run collie _jump
  [ "$status" -ne 0 ]
  [[ "$output" == *"no agent pane to jump to"* ]]
  collie run x -- 300
  hook x working
  [ -z "$(tmux show-options -gqv @collie-last-pane)" ]
  hook x waiting
  [ "$(tmux show-options -gqv @collie-last-pane)" = "$(run_pane x)" ]
}

@test "_preview: title, derived status, runs, per-repo ahead/dirty" {
  collie new x --no-window --title "Ship it"
  wt="$TMP/repos/A/feat-x"
  echo hi >"$wt/f"
  git -C "$wt" add f
  git -C "$wt" commit -q -m f
  echo dirty >"$wt/g"
  run collie _preview x
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ship it"* ]]
  [[ "$output" == *"Ship it  [todo P2]"* ]]
  [[ "$output" == *"A  feat/x  1 ahead, 1 dirty"* ]]
}

@test "_preview: the start of TASK.md's Objective" {
  collie new x --no-window -m "Add OAuth login"
  run collie _preview x
  [ "$status" -eq 0 ]
  [[ "$output" == *$'objective:\n  Add OAuth login\n'* ]]
  [[ "$output" != *"## Context"* ]]
  collie new y --no-window
  run collie _preview y
  [[ "$output" == *$'objective:\n  (empty)\n'* ]]
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
