#!/usr/bin/env bats

load helper

# The fake claude records the run identity collie exports to it, then idles;
# its state changes come from hook().
setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off
  mkdir "$TMP/bin"
  export PATH="$TMP/bin:$PATH" ENVLOG="$TMP/env"
  printf '#!/bin/sh\necho "$COLLIE_TASK $COLLIE_RUN" >>"$ENVLOG"\nexec sleep 300\n' >"$TMP/bin/claude"
  chmod +x "$TMP/bin/claude"
  make_bare_repo A
  cd "$REPO/main"
  collie new x --no-window
}
teardown() { teardown_env; }

events() { cat "$(task_dir x)/events.log"; }

@test "run: the agent gets COLLIE_TASK and COLLIE_RUN" {
  collie run x --agent claude -p ''
  collie run x --agent claude -p ''
  wait_for '[ "$(wc -l <"$ENVLOG")" -eq 2 ]'
  [ "$(sort "$ENVLOG")" = "x 1"$'\n'"x 2" ]
}

@test "wait: states of the latest or a given run, timeout, gone runs" {
  run collie wait x --timeout 1
  [ "$status" -eq 1 ]
  [[ $output == *"no run to wait for"* ]]
  collie run x --agent claude -p ''
  collie run x --agent claude -p ''
  hook x working 1
  hook x working 2
  run collie wait x --state idle --timeout 1
  [ "$status" -eq 1 ]
  (sleep 1; hook x idle 2) &
  run collie wait x --timeout 10
  [ "$status" -eq 0 ]
  collie wait x --run 1 --state working --timeout 1
  run collie wait x --run 1 --timeout 1
  [ "$status" -eq 1 ]
  run collie wait x --run 9 --timeout 5
  [ "$status" -eq 2 ]
  run collie wait x --state bogus
  [ "$status" -eq 1 ]
  tmux kill-window -t "$(run_pane x 1)"
  collie wait x --run 1 --state exited --timeout 5
  run collie wait x --run 1 --state idle --timeout 5
  [ "$status" -eq 2 ]
}

@test "signal done: logged for the agent's run; wait --done needs it and a stopped run" {
  collie run x --agent claude -p ''
  hook x working
  run collie wait x --done --timeout 1
  [ "$status" -eq 1 ]
  COLLIE_TASK=x COLLIE_RUN=1 collie signal done
  events | grep -q "	run_signal	run=1 signal=done$"
  # still working: the agent signalled mid-turn
  run collie wait x --done --timeout 1
  [ "$status" -eq 1 ]
  hook x idle
  collie wait x --done --timeout 5
  # a new prompt starts a new turn: the old signal no longer counts
  printf '2026-01-01T00:00:00Z\trun_prompt\trun=1\n' >>"$(task_dir x)/events.log"
  run collie wait x --done --timeout 1
  [ "$status" -eq 1 ]
  # without $COLLIE_RUN the pane's run is used
  COLLIE_TASK=x TMUX_PANE=$(run_pane x 1) collie signal done
  collie wait x --done --timeout 5
  # gone without signalling cannot be done any more
  printf '2026-01-01T00:00:00Z\trun_prompt\trun=1\n' >>"$(task_dir x)/events.log"
  tmux kill-window -t "$(run_pane x 1)"
  run collie wait x --done --timeout 5
  [ "$status" -eq 2 ]
}

@test "signal: refused outside a collie run or for other signals" {
  COLLIE_TASK=x run collie signal done
  [ "$status" -eq 1 ]
  [[ $output == *"not inside a collie run"* ]]
  COLLIE_TASK=x COLLIE_RUN=1 run collie signal stop
  [ "$status" -eq 1 ]
  [[ $output == *"usage: collie signal done"* ]]
  ! events | grep -q run_signal
}
