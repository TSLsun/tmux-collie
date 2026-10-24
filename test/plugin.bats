#!/usr/bin/env bats

load helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "collie.tmux: prepends bin/ to tmux global PATH" {
  tmux new-session -d -s t
  run tmux run-shell "$COLLIE_ROOT/collie.tmux"
  [ "$status" -eq 0 ]
  [[ "$(tmux show-environment -g PATH)" == "PATH=$COLLIE_ROOT/bin:"* ]]
}

@test "collie.tmux: is idempotent on reload" {
  tmux new-session -d -s t
  tmux run-shell "$COLLIE_ROOT/collie.tmux"
  tmux run-shell "$COLLIE_ROOT/collie.tmux"
  count=$(tmux show-environment -g PATH | sed 's/^PATH=//' | tr ':' '\n' | grep -cx "$COLLIE_ROOT/bin")
  [ "$count" -eq 1 ]
}

@test "collie.tmux: replaces #{collie_status} in status-right" {
  tmux new-session -d -s t
  tmux set-option -g status-right 'x #{collie_status} y'
  tmux run-shell "$COLLIE_ROOT/collie.tmux"
  [ "$(tmux show-options -gqv status-right)" = "x #(\"$COLLIE_ROOT/bin/collie\" status) y" ]
}

@test "collie.tmux: binds the menu to prefix h (or @collie-key)" {
  tmux new-session -d -s t
  tmux run-shell "$COLLIE_ROOT/collie.tmux"
  run tmux list-keys -T prefix h
  [[ "$output" == *display-menu* && "$output" == *"collie dash"* && "$output" == *"status=review"* ]]
  tmux set-option -g @collie-key j
  tmux run-shell "$COLLIE_ROOT/collie.tmux"
  run tmux list-keys -T prefix j
  [[ "$output" == *display-menu* ]]
}
