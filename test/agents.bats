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

@test "concurrent runs get distinct IDs and keep their exit events" {
  collie go x
  export REAL_TMUX
  REAL_TMUX=$(command -v tmux)
  cat >"$TMP/bin/tmux" <<'EOF'
#!/bin/sh
# Widen the allocation-to-log gap without touching the user's server.
[ "$1" != new-window ] || sleep 0.3
exec "$REAL_TMUX" "$@"
EOF
  printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/stub"
  chmod +x "$TMP/bin/tmux" "$TMP/bin/stub"
  collie run x --agent stub -p '' >"$TMP/run-a" 2>&1 &
  a=$!
  collie run x --agent stub -p '' >"$TMP/run-b" 2>&1 &
  b=$!
  wait "$a"
  wait "$b"
  ids=$(awk -F'\t' '$2 == "run_started" { split($3, a, " "); print a[1] }' "$(task_dir x)/events.log" | sort)
  [ "$ids" = $'run=1\nrun=2' ]
  wait_for '[ "$(grep -c "run_exited" "$(task_dir x)/events.log")" -eq 2 ]'
  grep -q 'run_exited.*run=1 code=0' "$(task_dir x)/events.log"
  grep -q 'run_exited.*run=2 code=0' "$(task_dir x)/events.log"
  [ -n "$(run_pane x 1)" ]
  [ -n "$(run_pane x 2)" ]
}

@test "failed spawn releases the run lock without consuming an ID" {
  collie go x
  export REAL_TMUX
  REAL_TMUX=$(command -v tmux)
  cat >"$TMP/bin/tmux" <<'EOF'
#!/bin/sh
[ "$1" != new-window ] || exit 1
exec "$REAL_TMUX" "$@"
EOF
  chmod +x "$TMP/bin/tmux"
  run collie run x --agent sleep -- 300
  [ "$status" -ne 0 ]
  [ ! -d "$(task_dir x)/run.lock" ]
  ! grep -q run_started "$(task_dir x)/events.log"
  rm "$TMP/bin/tmux"
  collie run x --agent sleep -- 300
  [ -n "$(run_pane x 1)" ]
}

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
  grep -q '^hooks.PermissionRequest=.*_codex-hook wait' "$ARGS"
  c=$(sed -n 's/^hooks\.PreToolUse=\[{matcher="Bash",hooks=\[{type="command",command="\([^"]*\)"}\]}.*$/\1/p' "$ARGS")
  run sh -c "$c" <<<'{"tool_input":{"command":"tmux kill-server"}}'
  [ "$status" -eq 2 ]
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
  # the shell guard blocks with exit 2 and prints JSON when it allows
  c=$(sed -n 's/^"BeforeTool":\[{"matcher":"run_shell_command",.*"command":"\(.*\)"}\]}\],$/\1/p' "$COLLIE_STATE_DIR/gemini-settings.json")
  run sh -c "$c" <<<'{"tool_input":{"command":"tmux kill-server"}}'
  [ "$status" -eq 2 ]
  run sh -c "$c" <<<'{"tool_input":{"command":"tmux -L x kill-server"}}'
  [ "$output" = '{}' ]
  grep -qxF -- --include-directories "$ARGS"
  grep -qxF "$TMP/repos/B.worktrees/feat-x" "$ARGS"
}

@test "omp run: assigns a todo task and passes its contract, workspaces and extra args" {
  cat >"$TMP/bin/omp" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$ARGS"
exec sleep 300
EOF
  chmod +x "$TMP/bin/omp"
  [ "$(collie ls | cut -f2)" = todo ]
  collie run x --agent omp -- --model test-model
  wait_for '[ -s "$ARGS" ]'
  [ "$(collie ls | cut -f2)" = active ]
  p=$(run_pane x)
  [ "$(tmux display -p -t "$p" '#{@collie_task} #{@collie_agent} #{@collie_state}')" = "x omp working" ]
  [ "$(tmux display -p -t "$p" '#{pane_current_path}')" = "$TMP/repos/A/feat-x" ]
  [ "$(sed -n 1p "$ARGS")" = -e ]
  [ "$(sed -n 2p "$ARGS")" = "$COLLIE_ROOT/agents/omp.ts" ]
  grep -qxF "$TMP/repos/B.worktrees/feat-x" "$ARGS"
  grep -qxF "$(task_dir x)" "$ARGS"
  grep -q '^Task x\..*\.collie/TASK.md' "$ARGS"
  [ "$(tail -n 2 "$ARGS" | tr '\n' ' ')" = '--model test-model ' ]
  grep -q 'run_started.*agent=omp' "$(task_dir x)/events.log"
}

@test "omp run: configured default starts a todo task from the dashboard" {
  cat >"$TMP/bin/omp" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$ARGS"
exec sleep 300
EOF
  chmod +x "$TMP/bin/omp"
  export COLLIE_AGENT=omp
  collie _bg r x
  wait_for '[ -s "$ARGS" ]'
  [ "$(collie ls | cut -f2)" = active ]
  [ "$(tmux display -p -t "$(run_pane x)" '#{@collie_agent}')" = omp ]
}

@test "omp adapter: the -e extension maps lifecycle events to states" {
  node --experimental-strip-types -e '' 2>/dev/null || skip "node cannot load .ts"
  cat >"$TMP/bin/omp" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$ARGS"
node --experimental-strip-types --no-warnings --input-type=module -e '
const h = {};
const { default: ext } = await import(process.argv[1]);
ext({ on: (e, f) => (h[e] = f) });
const step = async (e, a) => (h[e](a), await new Promise((r) => setTimeout(r, 300)));
await step("agent_start");
await step("tool_approval_requested");
await step("tool_approval_resolved");
await step("tool_execution_start", { toolName: "bash" });
await step("tool_execution_start", { toolName: "ask" });
await step("tool_execution_end");
await step("agent_end", { willContinue: true });
await step("agent_end", {});
' "$2"
exec sleep 300
EOF
  chmod +x "$TMP/bin/omp"
  collie run x --agent omp -p ''
  # ask waits like an approval; agent_end with willContinue is not idle yet
  states() { grep -o 'state=[a-z]*' "$(task_dir x)/events.log" | tr '\n' ' '; }
  wait_for '[ "$(states)" = "state=working state=waiting state=working state=waiting state=working state=idle " ]'
  [ "$(agent_of x)" = idle ]
  [ "$(sed -n 2p "$ARGS")" = "$COLLIE_ROOT/agents/omp.ts" ]
  grep -qxF "$TMP/repos/B.worktrees/feat-x" "$ARGS"
}

@test "omp adopt: resumes the conversation the hand-started omp holds open" {
  # omp holds run/session-owners/<id>.lock while its session is live; -c
  # would take the session the new window's tty last showed instead
  mkdir -p "$TMP/manual" "$TMP/run/session-owners"
  fake_agent "$TMP/manual/omp"
  cat >"$TMP/bin/omp" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done >"$ARGS"
exec sleep 300
EOF
  chmod +x "$TMP/bin/omp"
  collie go x
  tmux new-window -d -t "=x:" -c "$TMP/repos/A/feat-x" \
    "sh -c 'exec 3>$TMP/run/session-owners/01a18219-e205.lock; $TMP/manual/omp -c \"read -t 300\"; :'"
  wait_for '[ "$(agent_of x)" = working ]'
  collie adopt x -y
  wait_for '[ -f "$ARGS" ]'
  [ "$(tail -n 2 "$ARGS" | tr '\n' ' ')" = "-r 01a18219-e205 " ]
  ! grep -qxF -- -c "$ARGS"
}

@test "omp adopt: without an open session it resumes the latest with -c" {
  mkdir -p "$TMP/manual"
  fake_agent "$TMP/manual/omp"
  cat >"$TMP/bin/omp" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done >"$ARGS"
exec sleep 300
EOF
  chmod +x "$TMP/bin/omp"
  collie go x
  tmux new-window -d -t "=x:" -c "$TMP/repos/A/feat-x" "sh -c '$TMP/manual/omp -c \"read -t 300\"; :'"
  wait_for '[ "$(agent_of x)" = working ]'
  collie adopt x -y
  wait_for '[ -f "$ARGS" ]'
  grep -qxF -- -c "$ARGS"
  grep -q "agent_adopted.*agent=omp" "$(task_dir x)/events.log"
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
