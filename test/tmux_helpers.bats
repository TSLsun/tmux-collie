#!/usr/bin/env bats

load helper

setup() {
  setup_env
  TMUX_OPT_SERVER=window-opt
  TMUX_OPT_TMPDIR=$(mktemp -d /tmp/cwopt.XXXXXX)
  export TMUX_OPT_SERVER TMUX_OPT_TMPDIR
  TMUX_TMPDIR=$TMUX_OPT_TMPDIR
  export TMUX_TMPDIR
}

teardown() {
  [ -z "${TMUX_OPT_SERVER:-}" ] || tmux -L "$TMUX_OPT_SERVER" kill-server 2>/dev/null || true
  unset TMUX TMUX_PANE
  teardown_env
  [ -z "${TMUX_OPT_TMPDIR:-}" ] || rm -rf "$TMUX_OPT_TMPDIR"
}

@test "window-option helpers preserve values and missing-target statuses on a private server" {
  local socket pid pane missing
  tmux -L "$TMUX_OPT_SERVER" -f /dev/null new-session -d -s options
  socket=$(tmux -L "$TMUX_OPT_SERVER" display-message -p '#{socket_path}')
  pid=$(tmux -L "$TMUX_OPT_SERVER" display-message -p '#{pid}')
  pane=$(tmux -L "$TMUX_OPT_SERVER" display-message -p -t '=options:' '#{pane_id}')
  export TMUX="$socket,$pid,$pane"
  . "$COLLIE_ROOT/lib/tmux.sh"

  tmux_set_window_opt "$pane" @collie-test-option 'two words'
  [ "$(tmux_window_opt "$pane" @collie-test-option)" = 'two words' ]
  tmux_unset_window_opt "$pane" @collie-test-option
  [ -z "$(tmux_window_opt "$pane" @collie-test-option)" ]

  missing='=missing:'
  run tmux_window_opt "$missing" @collie-test-option
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run tmux_set_window_opt "$missing" @collie-test-option value
  [ "$status" -eq 1 ]
  run tmux_unset_window_opt "$missing" @collie-test-option
  [ "$status" -eq 1 ]
}
