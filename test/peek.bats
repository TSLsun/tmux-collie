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

@test "peek: default count without an event" {
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

@test "peek: wrapped history returns exactly the requested complete lines" {
  collie new p
  collie run p
  pane=$(run_pane p)
  long=$(printf '%0400d' 0)
  for i in $(seq 1 12); do
    tmux send-keys -t "$pane" -l "$long"
    tmux send-keys -t "$pane" Enter
  done
  wait_for "[ \"\$(tmux capture-pane -p -J -S - -t '$pane' | grep -c '^$long$')\" -ge 12 ]"
  run --separate-stderr collie peek p -n 12
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 12 ]
  for line in "${lines[@]}"; do [ "$line" = "$long" ]; done
}

@test "peek and dashboard trim whitespace-only trailing rows" {
  collie new p
  collie run p
  pane=$(run_pane p)
  tmux send-keys -t "$pane" trim-marker Enter
  # tty echo, then cat's copy: spaces typed sooner would share cat's row
  wait_for "[ \"\$(tmux capture-pane -p -J -t '$pane' | grep -c trim-marker)\" -ge 2 ]"
  tmux send-keys -t "$pane" -l '      '
  tmux send-keys -t "$pane" Enter
  run --separate-stderr collie peek p -n 1
  [ "$status" -eq 0 ]
  [ "$output" = trim-marker ]
  export COLLIE_DASH="$TMP/dash"
  mkdir -p "$COLLIE_DASH"
  printf 'p\n' >"$COLLIE_DASH/runs"
  run collie _preview 1
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = trim-marker ]
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
  [ "${#lines[@]}" -eq 2 ]
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
  [[ "$stderr" == *"several live runs"* ]]
  [[ "$stderr" == *"Choose one with --run N"* && "$stderr" == *"collie peek p --run 1"* ]]
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

@test "gone run never resolves the previous legacy run window" {
  collie new p --no-window
  collie run p
  collie run p
  collie run p
  p1=$(run_pane p 1)
  p2=$(run_pane p 2)
  p3=$(run_pane p 3)
  tmux send-keys -t "$p2" wrong-screen-marker Enter
  wait_for "tmux capture-pane -p -t '$p2' | grep -q wrong-screen-marker"
  tmux kill-window -t "$p1"
  tmux set-option -wu -t "$p3" @collie_pane
  tmux select-window -t "$p3"
  run --separate-stderr collie peek p --run 1
  [ "$status" -eq 3 ]
  [[ "$output" != *wrong-screen-marker* ]]
  export COLLIE_DASH="$TMP/dash"
  mkdir -p "$COLLIE_DASH"
  printf 'p\n' >"$COLLIE_DASH/runs"
  run collie _preview 1
  [ "$status" -eq 0 ]
  [[ "$output" != *wrong-screen-marker* ]]
}

@test "peek: oversized line counts exit 1" {
  collie new p
  run --separate-stderr collie peek p -n 99999999999
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"must not exceed 100000"* ]]
}

@test "peek: reads panes regardless of run state" {
  collie new p
  collie run p
  tmux set-option -w -t "$(tmux display -p -t "$(run_pane p)" '#{window_id}')" @collie_state exited
  run --separate-stderr collie peek p --run 1
  [ "$status" -eq 0 ]
}
