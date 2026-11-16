#!/usr/bin/env bats

load helper

setup() {
  setup_env
  tmux -L default -f /dev/null new-session -d -s baseline
  export TMUX="$TMUX_TMPDIR/tmux-$(id -u)/default,1,0"
}

teardown() { teardown_env; }

@test "session guard reports additions to the invoking server" {
  run "$COLLIE_ROOT/test/session-guard.sh" tmux -L default new-session -d -s leaked
  [ "$status" -eq 1 ]
  [[ "$output" == *"leaked"* ]]
}

@test "session guard permits renames and preserves command failure" {
  run "$COLLIE_ROOT/test/session-guard.sh" tmux -L default rename-session -t baseline renamed
  [ "$status" -eq 0 ]
  run "$COLLIE_ROOT/test/session-guard.sh" sh -c 'exit 7'
  [ "$status" -eq 7 ]
}
