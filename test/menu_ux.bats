#!/usr/bin/env bats

load helper

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=sleep
  make_bare_repo
  cd "$REPO/main"
}
teardown() { teardown_env; }

stub_tmux() {
  mkdir -p "$TMP/stub"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' >"$TMP/stub/tmux"
  chmod +x "$TMP/stub/tmux"
}

@test "menu: brief is global and peek appears only in task sessions" {
  stub_tmux
  PATH="$TMP/stub:$PATH" run collie _menu main cl
  [ "$status" -eq 0 ]
  [[ "$output" == *"brief"$'\n'"b"$'\n'*"_popup -w"*"brief"* ]]
  [[ "$output" != *$'\n'"peek task"$'\n'* ]]

  collie new x -r proj --no-window
  PATH="$TMP/stub:$PATH" run collie _menu x cl
  [ "$status" -eq 0 ]
  [[ "$output" == *"brief"$'\n'"b"$'\n'*"_popup -w"*"brief"* ]]
  [[ "$output" == *"peek task"$'\n'"p"$'\n'*"_popup -w"*"peek x"* ]]
}
