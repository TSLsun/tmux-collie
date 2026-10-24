#!/usr/bin/env bats

load helper

# Fake agents record their argv, then run the hook commands collie gave them
# (prompt submitted → turn finished), the way the real CLI would.
setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off
  mkdir "$TMP/bin"
  export PATH="$TMP/bin:$PATH" ARGS="$TMP/args"
  make_bare_repo A
  make_normal_repo B
  cd "$TMP"
  collie new x -r A -r B --no-window
}
teardown() { teardown_env; }

working_then_idle() {
  wait_for 'grep -q "state=working" "$(task_dir x)/events.log" && [ "$(agent_of x)" = idle ]'
  grep -q "agent_state	run=1 state=working" "$(task_dir x)/events.log"
  grep -q "agent_state	run=1 state=idle" "$(task_dir x)/events.log"
}

@test "codex adapter: -c hooks drive working -> idle; dirs and prompt passed" {
  cat >"$TMP/bin/codex" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$ARGS"
hook() { sh -c "$(sed -n "s/^hooks\.$1=.*command=\"\(.*\)\"}\]}\]$/\1/p" "$ARGS")"; }
hook UserPromptSubmit
sleep 0.3
hook Stop
exec sleep 300
EOF
  chmod +x "$TMP/bin/codex"
  collie run x --agent codex -p ''
  working_then_idle
  grep -q '^hooks.PermissionRequest=.*state waiting' "$ARGS"
  grep -qxF "$TMP/repos/B.worktrees/feat-x" "$ARGS"
  grep -qxF "$(task_dir x)" "$ARGS"
  collie run x --agent codex -p 'go'
  wait_for '[ "$(tail -n 1 "$ARGS")" = go ]'
}

@test "gemini adapter: settings-file hooks work without TMUX_PANE and print JSON" {
  cat >"$TMP/bin/gemini" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$ARGS"
hook() {
  c=$(sed -n "s/^\"$1\":.*\"command\":\"\(.*\)\"}\]}\].*/\1/p" "$GEMINI_CLI_SYSTEM_SETTINGS_PATH")
  env -u TMUX_PANE sh -c "$c" >>"$ARGS.out"
}
hook BeforeAgent
sleep 0.3
hook AfterAgent
exec sleep 300
EOF
  chmod +x "$TMP/bin/gemini"
  collie run x --agent gemini -p ''
  working_then_idle
  [ "$(cat "$ARGS.out")" = "$(printf '{}\n{}')" ]
  grep -q '"Notification":\[{"matcher":"ToolPermission".*state waiting' "$COLLIE_STATE_DIR/gemini-settings.json"
  grep -qxF -- --include-directories "$ARGS"
  grep -qxF "$TMP/repos/B.worktrees/feat-x" "$ARGS"
}

@test "state: finds its pane through parent processes when TMUX_PANE is unset" {
  cat >"$TMP/bin/fake" <<EOF
#!/bin/sh
env -u TMUX_PANE "$COLLIE_ROOT/bin/collie" state waiting
exec sleep 300
EOF
  chmod +x "$TMP/bin/fake"
  collie run x --agent fake
  wait_for '[ "$(agent_of x)" = waiting ]'
}

# --- doctor -----------------------------------------------------------------

@test "doctor: reports dependencies and agents; healthy tasks pass" {
  export COLLIE_AGENT=sleep
  run collie doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok    git version"* && "$output" == *"ok    tmux"* ]]
  [[ "$output" == *"claude"* && "$output" == *"codex"* && "$output" == *"gemini"* ]]
  [[ "$output" != *FAIL* ]]
}

@test "doctor: flags missing, unregistered worktrees and a missing default agent" {
  export COLLIE_AGENT=sleep
  rm -rf "$TMP/repos/A/feat-x"
  run collie doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  x: A worktree missing"* ]]
  git -C "$TMP/repos/A" worktree prune
  mkdir "$TMP/repos/A/feat-x"
  run collie doctor
  [[ "$output" == *"FAIL  x: A worktree not registered with git"* ]]
  COLLIE_AGENT=no-such-agent run collie doctor
  [[ "$output" == *"FAIL  default agent 'no-such-agent' not found"* ]]
}
