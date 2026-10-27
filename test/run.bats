#!/usr/bin/env bats

load helper

# The default agent is `sleep`: no adapter file, so the generic adapter runs
# `sleep <args>` — a stand-in agent whose hooks the tests fire by hand.
setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=sleep
  make_bare_repo A
  cd "$REPO/main"
}
teardown() { teardown_env; }

# --- run --------------------------------------------------------------------

@test "run: launches the agent in a task window and records the run" {
  collie new x --no-window
  [ "$(collie ls | cut -f2)" = todo ]
  run collie run x -- 300
  [ "$status" -eq 0 ]
  p=$(run_pane x)
  [ "$(tmux display -p -t "$p" '#{@collie_task} #{@collie_agent} #{@collie_state}')" = "x sleep working" ]
  [ "$(tmux display -p -t "$p" '#{pane_current_path}')" = "$TMP/repos/A/feat-x" ]
  grep -q "run_started	run=1 agent=sleep repo=A" "$(task_dir x)/events.log"
  [ "$(collie ls | cut -f2)" = active ]
  [ "$(agent_of x)" = working ]
}

@test "run: retries a window whose pty open hit the macOS ptmx race" {
  # fail the first new-session and the first new-window like xnu's ENXIO race
  mkdir -p "$TMP/stub"
  cat >"$TMP/stub/tmux" <<EOF
#!/bin/sh
case \$1 in new-session | new-window)
  [ -e "$TMP/failed-\$1" ] || { touch "$TMP/failed-\$1"; echo "create window failed: fork failed: Device not configured" >&2; exit 1; } ;;
esac
exec $(command -v tmux) "\$@"
EOF
  chmod +x "$TMP/stub/tmux"
  collie new x --no-window
  PATH="$TMP/stub:$PATH" run collie run x -- 300
  [ "$status" -eq 0 ]
  [ -e "$TMP/failed-new-session" ] && [ -e "$TMP/failed-new-window" ]
  [ "$(agent_of x)" = working ]
}

@test "run: -r picks the repo; unknown repo or agent command fails" {
  make_normal_repo B
  cd "$TMP"
  collie new x -r A -r B --no-window
  collie run x -r B -- 300
  [ "$(tmux display -p -t "$(run_pane x)" '#{pane_current_path}')" = "$TMP/repos/B.worktrees/feat-x" ]
  run collie run x -r C
  [ "$status" -ne 0 ]
  [[ "$output" == *"not part of task"* ]]
  run collie run x --agent no-such-agent
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "run: COLLIE_TASK is the default task" {
  collie new x --no-window
  COLLIE_TASK=x collie run -- 300
  [ -n "$(run_pane x)" ]
}

# --- state ------------------------------------------------------------------

@test "state: hooks drive three concurrent tasks; unchanged states are not logged" {
  for t in a b c; do
    collie new "$t" --no-window
    collie run "$t" -- 300
  done
  hook a waiting
  hook b working
  hook b idle
  [ "$(agent_of a)" = waiting ]
  [ "$(agent_of b)" = idle ]
  [ "$(agent_of c)" = working ]
  hook a working
  hook a working
  [ "$(agent_of a)" = working ]
  [ "$(grep -c agent_state "$(task_dir a)/events.log")" -eq 2 ]
}

@test "state: silent no-op outside a collie window; unknown state fails" {
  TMUX_PANE='' run collie state idle
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  tmux new-session -d -s plain
  TMUX_PANE=$(tmux display -p -t plain '#{pane_id}') run collie state idle
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run collie state bogus
  [ "$status" -ne 0 ]
}

@test "exited: agent exit keeps the window; killed window is exited; kill-server is unknown" {
  collie new x --no-window
  collie run x -- 300
  pid=$(tmux display -p -t "$(run_pane x)" '#{pane_pid}')
  # anchored: _exec's own subshells carry "... _exec x 1 sleep 300" as argv
  wait_for 'pgrep -P "$pid" -f "^sleep 300$" >/dev/null'
  pkill -P "$pid" -f "^sleep 300$"
  wait_for '[ "$(agent_of x)" = exited ]'
  grep -q "run_exited	run=1" "$(task_dir x)/events.log"
  [ -n "$(run_pane x)" ]

  collie run x -- 300
  tmux kill-window -t "$(run_pane x 2)"
  run collie show x
  [[ "$output" == *"2	sleep	exited"* ]]

  collie run x -- 300
  [ "$(agent_of x)" = working ]
  tmux kill-server
  [ "$(agent_of x)" = unknown ]
}

@test "generic agent: silence turns working into idle" {
  export COLLIE_SILENCE=1
  collie new x --no-window
  collie run x -- 300
  sleep 2
  [ "$(agent_of x)" = idle ]
}

# --- notify / status --------------------------------------------------------

@test "notify: on waiting and on working -> idle, once per transition" {
  export COLLIE_NOTIFY="printf '%s|%s\n' >>'$TMP/notes'"
  collie new x --no-window
  collie run x -- 300
  hook x idle
  hook x idle
  hook x waiting
  wait_for '[ "$(wc -l <"$TMP/notes" 2>/dev/null)" -eq 2 ]'
  sleep 0.3
  [ "$(wc -l <"$TMP/notes")" -eq 2 ]
  grep -qxF "collie: x|sleep finished its turn" "$TMP/notes"
  grep -qxF "collie: x|sleep is waiting for you" "$TMP/notes"
}

@test "status: counts agents by state for the status bar" {
  run collie status
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  for t in a b c; do
    collie new "$t" --no-window
    collie run "$t" -- 300
  done
  hook a waiting
  hook b idle
  run collie status
  [ "$output" = "#[fg=red]●1 #[fg=yellow]●1 #[fg=green]●1#[default]" ]
}

# --- claude adapter ---------------------------------------------------------

@test "claude adapter: prompt, hook settings, other worktrees as --add-dir" {
  mkdir "$TMP/bin"
  cat >"$TMP/bin/claude" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done >"$CLAUDE_ARGS"
exec sleep 300
EOF
  chmod +x "$TMP/bin/claude"
  export PATH="$TMP/bin:$PATH" CLAUDE_ARGS="$TMP/args"
  make_normal_repo B
  cd "$TMP"
  collie new x -r A -r B --title 'fix the widget' --no-window
  collie run x --agent claude
  wait_for '[ -s "$TMP/args" ]'
  [[ "$(head -n 1 "$TMP/args")" == "Task x: fix the widget. "*".collie/TASK.md"* ]]
  [ "$(grep -A1 -xF -- --name "$TMP/args" | tail -n 1)" = "x: fix the widget" ]
  grep -qxF -- --settings "$TMP/args"
  grep -q '"Stop".*state idle' "$TMP/args"
  grep -q '"Notification".*state waiting' "$TMP/args"
  # the Bash guard denies killing the user's tmux server
  c=$(sed -n 's/.*"PreToolUse":\[{"matcher":"Bash","hooks":\[{"type":"command","command":"\([^"]*\)".*/\1/p' "$TMP/args")
  run sh -c "$c" <<<'{"tool_input":{"command":"tmux kill-server"}}'
  [ "$status" -eq 2 ]
  grep -qxF "$TMP/repos/B.worktrees/feat-x" "$TMP/args"
  grep -qxF "$(task_dir x)" "$TMP/args"
  ! grep -qxF "$TMP/repos/A/feat-x" "$TMP/args"
  [ "$(tmux display -p -t "$(run_pane x)" '#{@collie_hooks} #{@collie_state}')" = "1 working" ]

  rm "$TMP/args"
  collie run x --agent claude -p ''
  wait_for '[ -s "$TMP/args" ]'
  [ "$(head -n 1 "$TMP/args")" = --name ]
  grep -qxF "x: fix the widget" "$TMP/args"
  [ "$(tmux display -p -t "$(run_pane x 2)" '#{@collie_state}')" = idle ]

  rm "$TMP/args"
  collie run x --agent claude -p 'just go'
  wait_for '[ -s "$TMP/args" ]'
  [ "$(head -n 1 "$TMP/args")" = "just go" ]
}

@test "claude adapter: an untitled task is named by its id alone" {
  mkdir "$TMP/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"$CLAUDE_ARGS"\nexec sleep 300\n' >"$TMP/bin/claude"
  chmod +x "$TMP/bin/claude"
  export PATH="$TMP/bin:$PATH" CLAUDE_ARGS="$TMP/args"
  collie new x --no-window
  collie run x --agent claude
  wait_for '[ -s "$TMP/args" ]'
  [[ "$(head -n 1 "$TMP/args")" == "Task x. Your task contract is .collie/TASK.md."* ]]
  [ "$(grep -A1 -xF -- --name "$TMP/args" | tail -n 1)" = x ]
}

@test "run: a failed launch leaves no run behind" {
  collie new x --no-window
  long="$TMP/$(printf 'x%.0s' $(seq 1 120))"
  mkdir -p "$long"
  TMUX_TMPDIR=$long run collie run x -- 300
  [ "$status" -ne 0 ]
  [[ "$output" == *"too long"* ]]
  ! grep -q run_started "$(task_dir x)/events.log"
  [ "$(agent_of x)" = - ]
}
