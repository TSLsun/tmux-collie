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

@test "collie.tmux: a click on a status count opens its menu; a user binding stays" {
  tmux new-session -d -s t
  tmux run-shell "$COLLIE_ROOT/collie.tmux"
  run tmux list-keys -T root MouseUp1Status
  [[ "$output" == *"#{m:collie-*,#{mouse_status_range}}"* && "$output" == *"collie' _status-menu #{q:mouse_status_range} #{q:client_name} #{mouse_x}"* ]]
  tmux run-shell "$COLLIE_ROOT/collie.tmux"
  [ "$(tmux list-keys -T root MouseUp1Status | grep -c _status-menu)" -eq 1 ]
  tmux bind-key -n MouseUp1Status display-message mine
  tmux run-shell "$COLLIE_ROOT/collie.tmux"
  [[ "$(tmux list-keys -T root MouseUp1Status)" == *"display-message mine"* ]]
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
  [[ "$output" == *"display-menu"* && "$output" == *"collie dash"* && "$output" == *"review x"* && "$output" == *"_popup "*"done x"* ]]
  [[ "$output" == *"edit task"$'\n'"e"$'\n'*"_popup "*"edit x"* ]]
  [[ "$output" == *"run default agent"$'\n'"R"$'\n'"run-shell '"*"collie run x -s -c cl'"* ]]
  [[ "$output" == *"adopt agent"$'\n'"a"$'\n'*"_popup "*"adopt x"* ]]
  [[ "$output" == *"archive"$'\n'"x"$'\n'"confirm-before -p 'archive x? (y/n)'"*"_popup "*"archive x"* ]]
  [[ "$output" == *"jump to alert"*"_jump - cl"* ]]
  [[ "$output" != *"not a collie task"* && "$output" != *notes* && "$output" != *"next action"* && "$output" != *"status="* ]]
}

@test "_menu: task actions match the dashboard's keys and labels; sync confirms" {
  make_bare_repo
  collie new x -r proj --no-window
  stub_tmux
  PATH="$TMP/stub:$PATH" run collie _menu x cl
  [ "$status" -eq 0 ]
  # every dashboard task action (? menu) is in the prefix menu, same key and
  # label; terminal (t) and new task (c) are its global items
  acts=$(bash -c '. "$1" && action_items x' _ "$BATS_TEST_DIRNAME/../lib/cmd/dash.sh" | grep -v '^[tc] ')
  [ "$(printf '%s\n' "$acts" | wc -l)" -ge 7 ]
  while read -r k l; do
    [[ "$output" == *$'\n'"$l"$'\n'"$k"$'\n'* ]] || { echo "missing: $k $l"; false; }
  done <<<"$acts"
  [[ "$output" == *"terminal"$'\n'"t"$'\n'* && "$output" == *"new task"$'\n'"c"$'\n'* ]]
  [[ "$output" == *"sync"$'\n'"s"$'\n'"confirm-before -p 'sync x? (y/n)'"*"_popup -w "*"collie sync x"* ]]
}

@test "_menu: run agent (r) opens a menu of agents, the default first" {
  make_bare_repo
  collie new x -r proj --no-window
  stub_tmux
  PATH="$TMP/stub:$PATH" run collie _menu x cl
  [[ "$output" == *"run agent"$'\n'"r"$'\n'"run-shell '"*"collie _runpick x cl'"* ]]
  COLLIE_AGENT=codex PATH="$TMP/stub:$PATH" run collie _runpick x cl
  [ "$status" -eq 0 ]
  [[ "$output" == "display-menu"$'\n'"-c"$'\n'"cl"$'\n'*"run agent"* ]]
  [[ "$output" == *$'\n'"codex (default)"$'\n'"1"$'\n'"run-shell '"*"collie run x -s -c cl --agent codex'"$'\n'"claude"$'\n'"2"$'\n'* ]]
  [[ "$output" == *$'\n'"gemini"$'\n'"3"$'\n'*$'\n'"omp"$'\n'"4"$'\n'"run-shell '"*"collie run x -s -c cl --agent omp'" ]]
  [ "$(grep -c -- '--agent codex' <<<"$output")" -eq 1 ]
  # a default no menu command can quote is left out
  COLLIE_AGENT="my agent" PATH="$TMP/stub:$PATH" run collie _runpick x
  [[ "$output" == *$'\n'"claude (default)"$'\n'"1"$'\n'"run-shell '"*"collie run x -s --agent claude'"* && "$output" != *"my agent"* ]]
  run collie _runpick "bad id"
  [ "$status" -ne 0 ]
}

@test "_popup: -w pauses for a key after success too" {
  run collie _popup -w true </dev/null
  [ "$status" -eq 0 ] && [[ "$output" == *"[press any key]"* ]]
}

@test "_menu: non-task session gets a hint instead of task actions" {
  stub_tmux
  PATH="$TMP/stub:$PATH" run collie _menu main cl
  [ "$status" -eq 0 ]
  [[ "$output" == *"collie dash"* && "$output" == *"-not a collie task — use collie new"* ]]
  [[ "$output" == *"-EE"*"collie new"* ]]
  [[ "$output" == *"terminal"$'\n'"t"$'\n'"display-popup -E -w 90% -h 85% -d '#{pane_current_path}'"$'\n'* ]]
  [[ "$output" == *"gc merged tasks"$'\n'"G"$'\n'"display-popup "*"_popup "*"collie _gc'"* ]]
  [[ "$output" != *notes* && "$output" != *"run agent"* && "$output" != *"edit task"* && "$output" != *archive* ]]
}

@test "_menu: dev items only with @collie-dev on" {
  stub_tmux
  PATH="$TMP/stub:$PATH" run collie _menu main cl
  [[ "$output" != *"_dev"* ]]
  COLLIE_DEV=on PATH="$TMP/stub:$PATH" run collie _menu main cl
  [[ "$output" == *"_dev load #{q:pane_current_path}"* && "$output" == *"_dev reset"* ]]
}

@test "_dev: load swaps bin/, menu and status to a checkout; reset swaps back" {
  tmux new-session -d -s t
  tmux set-option -g status-right 'x #{collie_status}'
  tmux run-shell "$COLLIE_ROOT/collie.tmux"
  cp -R "$COLLIE_ROOT" "$TMP/dev"
  collie _dev load "$TMP/dev/bin"
  [ "$(tmux show-options -gqv @collie-home)" = "$COLLIE_ROOT" ]
  [[ "$(tmux show-environment -g PATH)" == "PATH=$TMP/dev/bin:"* ]]
  [[ "$(tmux show-environment -g PATH)" != *"$COLLIE_ROOT/bin"* ]]
  [ "$(tmux show-options -gqv status-right)" = "x #(\"$TMP/dev/bin/collie\" status)" ]
  [[ "$(tmux list-keys -T prefix h)" == *"$TMP/dev/bin/collie"* ]]
  collie _dev reset
  [[ "$(tmux show-environment -g PATH)" == "PATH=$COLLIE_ROOT/bin:"* ]]
  [[ "$(tmux show-environment -g PATH)" != *"$TMP/dev/bin"* ]]
  [ "$(tmux show-options -gqv status-right)" = "x #(\"$COLLIE_ROOT/bin/collie\" status)" ]
  run collie _dev load "$TMP"
  [ "$status" -ne 0 ]
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
