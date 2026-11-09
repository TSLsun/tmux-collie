#!/usr/bin/env bats

load helper
bats_require_minimum_version 1.5.0

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=cat COLLIE_SILENCE=600
  make_bare_repo A
  make_bare_repo B
  cd "$REPO/main"
}
teardown() { teardown_env; }

@test "peek: default count, joined lines, and trailing blanks without an event" {
  collie new p
  collie run p
  pane=$(run_pane p)
  for i in $(seq 1 60); do
    tmux send-keys -t "$pane" "line-$i" Enter
  done
  wait_for "tmux capture-pane -p -t '$pane' | grep -q line-60"
  before=$(wc -l <"$(task_dir p)/events.log")
  run --separate-stderr collie peek p
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 40 ]
  [[ "$output" == *line-60* ]]
  [[ "$output" != *line-1$'\n'* ]]
  ! grep -q 'peek' "$(task_dir p)/events.log"
  [ "$(wc -l <"$(task_dir p)/events.log")" -eq "$before" ]
}

@test "peek: -n, --run, and repo targeting" {
  collie new p -r A -r B
  collie run p -r A
  collie run p -r B
  tmux send-keys -t "$(run_pane p 1)" alpha Enter beta Enter gamma Enter
  tmux send-keys -t "$(run_pane p 2)" other Enter
  wait_for "tmux capture-pane -p -t '$(run_pane p 1)' | grep -q gamma"
  wait_for "tmux capture-pane -p -t '$(run_pane p 2)' | grep -q other"
  run --separate-stderr collie peek p -n 2 --run 1
  [ "$status" -eq 0 ]
  [[ "$output" == *gamma* ]]
  [[ "$output" != *alpha* ]]
  run --separate-stderr collie peek p -r B -n 10
  [ "$status" -eq 0 ]
  [[ "$output" == *other* ]]
}

@test "peek: several live runs require --run" {
  collie new p
  collie run p
  collie run p
  run --separate-stderr collie peek p
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"several live runs"* ]]
}

@test "peek: implicit selection prefers a live run over an exited run" {
  collie new p
  collie run p
  p1=$(run_pane p 1)
  tmux send-keys -t "$p1" C-d
  wait_for "grep -q 'run_exited.*run=1 ' '$(task_dir p)/events.log'"
  collie run p
  p2=$(run_pane p 2)
  tmux send-keys -t "$p2" live-marker Enter
  wait_for "tmux capture-pane -p -t '$p2' | grep -q live-marker"
  run --separate-stderr collie peek p
  [ "$status" -eq 0 ]
  [[ "$output" == *live-marker* ]]
  run --separate-stderr collie peek p -r B
  [ "$status" -eq 0 ]
  [[ "$output" == *live-marker* ]]
}

@test "peek: a gone pane exits 3" {
  collie new p
  collie run p
  tmux kill-window -t "$(tmux display -p -t "$(run_pane p)" '#{window_id}')"
  run --separate-stderr collie peek p --run 1
  [ "$status" -eq 3 ]
}

@test "peek: reads panes regardless of run state" {
  collie new p
  collie run p
  tmux set-option -w -t "$(tmux display -p -t "$(run_pane p)" '#{window_id}')" @collie_state exited
  run --separate-stderr collie peek p --run 1
  [ "$status" -eq 0 ]
}
