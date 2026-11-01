#!/usr/bin/env bats

load helper
bats_require_minimum_version 1.5.0

# The agent is `cat` (generic adapter, no hooks): its pane shows typed text
# once as tty echo and once more when cat reads the submitted line. Tests
# fire the hooks by hand; a long silence keeps a "working" agent working.
setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=cat COLLIE_SILENCE=600
  make_bare_repo A
  cd "$REPO/main"
}
teardown() { teardown_env; }

pane_text() { tmux capture-pane -p -J -t "$(run_pane "$1" "${2:-1}")"; }

# text shown twice: typed, then submitted to cat (whose output may share a
# row with the echo of the next pasted line)
submitted() { # id text [run]
  [ "$(pane_text "$1" "${3:-1}" | grep -oF -- "$2" | wc -l)" -ge 2 ]
}

@test "send: types a line into the idle agent, submits it and logs it" {
  collie new s
  collie run s
  hook s idle
  run --separate-stderr collie send s fix the 'flaky test'
  [ "$status" -eq 0 ]
  [ "$output" = "s: sent to run 1 (cat) in $(tmux display -p -t "$(run_pane s)" '#{window_id}')" ]
  wait_for "submitted s 'fix the flaky test'"
  grep -q "	sent	run=1 text=fix the flaky test$" "$(task_dir s)/events.log"
}

@test "send: multi-line text from -f and stdin is pasted, then submitted" {
  collie new s
  collie run s
  hook s waiting
  printf 'first line\nsecond line\n' >"$TMP/msg"
  run --separate-stderr collie send s -f "$TMP/msg"
  [ "$status" -eq 0 ]
  wait_for "submitted s 'first line' && submitted s 'second line'"
  grep -q "	sent	run=1 text=first line$" "$(task_dir s)/events.log"
  printf 'third\nfourth\n' | collie send s -f -
  wait_for "submitted s third && submitted s fourth"
}

@test "send: refuses a working agent with exit 2 and types nothing" {
  collie new s
  collie run s
  hook s working
  run --separate-stderr collie send s hello
  [ "$status" -eq 2 ]
  [ "$stderr" = "collie: send: run 1 (cat) is working; not sent (--wait waits for its turn to end)" ]
  sleep 0.5
  ! pane_text s | grep -q hello
  ! grep -q "	sent	" "$(task_dir s)/events.log"
}

@test "send --wait: types once the agent's turn ends" {
  collie new s
  collie run s
  hook s working
  (sleep 1.5; hook s idle) &
  run --separate-stderr collie send s --wait hello
  [ "$status" -eq 0 ]
  wait_for "submitted s hello"
}

@test "send: refuses with exit 3 when the run exited or there is none" {
  collie new s --no-window
  run --separate-stderr collie send s hello
  [ "$status" -eq 3 ]
  [ "$stderr" = "collie: send: no live agent run in task 's'; not sent" ]
  collie run s
  tmux send-keys -t "$(run_pane s)" C-d
  wait_for "grep -q 'run_exited	run=1' '$(task_dir s)/events.log'"
  run --separate-stderr collie send s hello
  [ "$status" -eq 3 ]
  run --separate-stderr collie send s --run 1 hello
  [ "$status" -eq 3 ]
  [ "$stderr" = "collie: send: run 1 (cat) has exited; not sent" ]
  ! pane_text s | grep -q hello
  run --separate-stderr collie send s --run 7 hello
  [ "$status" -eq 1 ]
  [ "$stderr" = "collie: send: task 's' has no run 7" ]
}

@test "send: never types into an agent started by hand" {
  mkdir -p "$TMP/manual"
  fake_agent "$TMP/manual/claude"
  collie new s
  tmux new-window -d -t '=s:' -c "$REPO/feat-s" "sh -c '$TMP/manual/claude -c \"read -t 300\"; :'"
  wait_for '[ "$(agent_of s)" = working ]'
  manual=$(tmux list-windows -t '=s' -F '#{window_id}' | tail -1)
  run --separate-stderr collie send s hello
  [ "$status" -eq 3 ]
  ! tmux capture-pane -p -t "$manual" | grep -q hello
}

@test "send: several live runs need --run; --run picks one" {
  collie new s
  collie run s
  collie run s
  hook s idle 1
  hook s idle 2
  run --separate-stderr collie send s hello
  [ "$status" -eq 1 ]
  [ "$stderr" = "collie: send: several live runs in task 's' (1 2); pick one with --run" ]
  run --separate-stderr collie send s -r A hello
  [ "$status" -eq 1 ]
  run --separate-stderr collie send s --run 2 hello
  [ "$status" -eq 0 ]
  wait_for "submitted s hello 2"
  ! pane_text s 1 | grep -q hello
}

@test "send: rejects bad arguments" {
  collie new s --no-window
  run --separate-stderr collie send
  [ "$status" -eq 1 ]
  run --separate-stderr collie send s
  [ "$stderr" = "collie: send: nothing to send" ]
  run --separate-stderr collie send s -r B hi
  [ "$stderr" = "collie: repo 'B' is not part of task 's'" ]
  run --separate-stderr collie send s -r A --run 1 hi
  [ "$stderr" = "collie: send: give -r or --run, not both" ]
  run --separate-stderr collie send s -f "$TMP/none"
  [ "$stderr" = "collie: send: cannot read $TMP/none" ]
}
