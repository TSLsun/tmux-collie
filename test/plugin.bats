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
  [[ "$output" == *run-shell* && "$output" == *"collie' _menu"* ]]
  tmux set-option -g @collie-key j
  tmux run-shell "$COLLIE_ROOT/collie.tmux"
  run tmux list-keys -T prefix j
  [[ "$output" == *"_menu"* ]]
}

# stub tmux that prints its argv, one per line
stub_tmux() {
  mkdir -p "$TMP/stub"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' >"$TMP/stub/tmux"
  chmod +x "$TMP/stub/tmux"
}

@test "_menu: task session gets task actions" {
  make_bare_repo
  collie new x -r proj --no-window
  stub_tmux
  PATH="$TMP/stub:$PATH" run collie _menu x cl
  [ "$status" -eq 0 ]
  [[ "$output" == *"display-menu"* && "$output" == *"collie dash"* && "$output" == *"status=review"* && "$output" == *"done x"* ]]
  [[ "$output" != *"not a collie task"* ]]
}

@test "_menu: non-task session gets a hint instead of task actions" {
  stub_tmux
  PATH="$TMP/stub:$PATH" run collie _menu main cl
  [ "$status" -eq 0 ]
  [[ "$output" == *"collie dash"* && "$output" == *"-not a collie task — use collie new"* ]]
  [[ "$output" == *"-EE"*"collie new"* ]]
  [[ "$output" != *notes* && "$output" != *"run agent"* ]]
}

@test "_popup: passes success through, pauses for a key on failure" {
  run collie _popup true
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run collie _popup 'echo boom >&2; exit 3' </dev/null
  [ "$status" -eq 3 ]
  [[ "$output" == *boom* && "$output" == *"exit 3"*"press any key"* ]]
  run collie _popup 'false | cat' </dev/null
  [ "$status" -eq 1 ]
}
