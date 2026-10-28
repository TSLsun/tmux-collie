#!/usr/bin/env bats
load helper

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off
  mkdir "$TMP/bin"
  export PATH="$TMP/bin:$PATH" ARGS="$TMP/args"
  cat >"$TMP/bin/codex" <<'SH'
#!/bin/bash
case ${1:-} in --help) echo '--no-daemon --dangerously-bypass-hook-trust'; exit ;; --version) echo 'codex-cli 0.165.0'; exit ;; esac
printf '%s\n' "$@" >"$ARGS"
prev= sid=new-$$
for a in "$@"; do
  [ "$prev" != resume ] || sid=$a
  prev=$a
done
c=$(sed -n 's/^hooks.SessionStart=.*command="\(.*\)"}]}]$/\1/p' "$ARGS")
[ -z "$c" ] || printf '{"session_id":"%s"}' "$sid" | bash -c "$c"
if [ -n "${CODEX_DRAW:-}" ]; then
  while IFS= read -r text; do printf '\033[2J\033[H%s\n' "$text"; done
fi
exec sleep 300
SH
  chmod +x "$TMP/bin/codex"
  make_bare_repo A
  cd "$REPO/main"
  collie new x --no-window
}
teardown() { teardown_env; }

@test "codex: captures identity and restores two exact conversations once" {
  collie run x --agent codex -p ''
  wait_for 'grep -q "agent_session.*run=1 id=new-" "$(task_dir x)/events.log"'
  id1=$(sed -n 's/.*agent_session.*run=1 id=//p' "$(task_dir x)/events.log")
  collie run x --agent codex -p ''
  wait_for 'grep -q "agent_session.*run=2 id=new-" "$(task_dir x)/events.log"'
  id2=$(sed -n 's/.*agent_session.*run=2 id=//p' "$(task_dir x)/events.log")
  grep -qxF -- --no-daemon "$ARGS"
  kill "$(tmux display -p '#{pid}')"
  wait_for '! tmux list-sessions >/dev/null 2>&1'
  run collie restore -n x
  [ "$output" = "x run 1: codex in A: resume $id1"$'\n'"x run 2: codex in A: resume $id2" ]
  collie restore x
  wait_for 'grep -q "agent_session.*run=4 id=" "$(task_dir x)/events.log"'
  grep -q "agent_session.*run=3 id=$id1" "$(task_dir x)/events.log"
  grep -q "agent_session.*run=4 id=$id2" "$(task_dir x)/events.log"
  run collie restore x
  [ -z "$output" ]
}

@test "codex: forwarded resume precedes prompt; flags remain distinct argv" {
  collie run x --agent codex -p 'continue task' -- resume exact-id --model a-model
  wait_for '[ -f "$ARGS" ]'
  [ "$(tail -n 5 "$ARGS")" = "$(printf '%s\n' resume exact-id --model a-model 'continue task')" ]
}

@test "codex: missing restore identity is diagnosed without guessing latest" {
  printf '2020-01-01T00:00:00Z\trun_started\trun=1 agent=codex repo=A window=@1\n' >>"$(task_dir x)/events.log"
  run collie restore -n x
  [[ "$output" == *'skipped: codex conversation id missing'* ]]
  [ ! -f "$ARGS" ]
}

@test "codex: untrusted hooks use silence fallback until a hook actually runs" {
  # This CLI deliberately skips hook execution, as an untrusted real CLI does.
  printf '#!/bin/sh\ncase "$1" in --help) echo "--no-daemon --dangerously-bypass-hook-trust"; exit;; esac\nexec sleep 300\n' >"$TMP/bin/codex"
  collie run x --agent codex -p ''
  [ "$(tmux show-options -wqv -t "$(run_pane x)" @collie_hooks)" = 0 ]
}

@test "codex: adoption refuses unknown conversation before stopping the process" {
  mkdir "$TMP/manual"
  ln -s "$(command -v sleep)" "$TMP/manual/codex"
  collie go x
  tmux new-window -d -t '=x:' -c "$REPO/feat-x" "sh -c '$TMP/manual/codex 300; :'"
  wait_for '[ "$(agent_of x)" = working ]'
  run collie adopt x -y
  [ "$status" -ne 0 ]
  [[ "$output" == *'cannot identify the active codex conversation'* ]]
  [ "$(agent_of x)" = working ]
  [ ! -f "$ARGS" ]
}

@test "codex: approval review alone never announces a human wait; dialog closes before tool completes" {
  export CODEX_DRAW=1
  export COLLIE_NOTIFY='printf "%s|%s\n" >>"$ARGS.notifications"'
  collie run x --agent codex -p ''
  wait_for 'grep -q "agent_session" "$(task_dir x)/events.log"'
  p=$(run_pane x)
  TMUX_PANE=$p collie _codex-hook state working
  TMUX_PANE=$p collie _codex-hook wait
  sleep 0.8
  [ "$(agent_of x)" = working ]
  [ ! -s "$ARGS.notifications" ]
  # The foreground test process stands in for the TUI: an actual visible
  # approval footer is required, not arbitrary tool text or an event alone.
  tmux send-keys -t "$p" -l 'Press enter to confirm or esc to cancel'
  tmux send-keys -t "$p" Enter
  wait_for '[ "$(agent_of x)" = waiting ]'
  wait_for '[ -s "$ARGS.notifications" ]'
  [ "$(wc -l <"$ARGS.notifications" | tr -d " ")" -eq 1 ]
  tmux send-keys -t "$p" -l 'Working (1s)'
  tmux send-keys -t "$p" Enter
  wait_for '[ "$(agent_of x)" = working ]'
  [[ "$(collie status)" != *'fg=red'* ]]
  [ "$(wc -l <"$ARGS.notifications" | tr -d " ")" -eq 1 ]
}

@test "codex: adoption resumes the sole open rollout, never the newest conversation in cwd" {
  sid=01a18329-a7c5-7212-911a-5ea662aff812
  mkdir "$TMP/manual"
  ln -s "$(command -v sleep)" "$TMP/manual/codex"
  collie go x
  tmux new-window -d -t '=x:' -c "$REPO/feat-x" \
    "sh -c 'exec 3>$TMP/rollout-2026-10-28T00-00-00-$sid.jsonl; $TMP/manual/codex 300; :'"
  wait_for '[ "$(agent_of x)" = working ]'
  collie adopt x -y
  wait_for '[ -f "$ARGS" ]'
  [ "$(tail -n 2 "$ARGS")" = "$(printf '%s\n' resume "$sid")" ]
  wait_for 'grep -q "agent_session.*id=$sid" "$(task_dir x)/events.log"'
}

@test "codex: two open rollouts are ambiguous and adoption leaves the agent running" {
  mkdir "$TMP/manual"
  ln -s "$(command -v sleep)" "$TMP/manual/codex"
  collie go x
  tmux new-window -d -t '=x:' -c "$REPO/feat-x" \
    "sh -c 'exec 3>$TMP/rollout-01a18329-a7c5-7212-911a-5ea662aff812.jsonl; exec 4>$TMP/rollout-01a18329-a7c5-7212-911a-5ea662aff813.jsonl; $TMP/manual/codex 300; :'"
  wait_for '[ "$(agent_of x)" = working ]'
  run collie adopt x -y
  [ "$status" -ne 0 ]
  [ "$(agent_of x)" = working ]
  [ ! -f "$ARGS" ]
}

@test "codex: shell and TOML escaping preserve quoted plugin paths and both tool hooks" {
  export PLUGIN_DIR="$TMP/plugin 'quote\" and \\ slash"
  ln -s "$COLLIE_ROOT" "$PLUGIN_DIR"
  export RUN_DIRS="$TMP/repo with spaces" RUN_PROMPT='do task'
  /bin/bash -c '. "$1/agents/codex.sh"; agent_argv resume exact-id; printf "%s\0" "${AGENT_ARGV[@]}"' bash "$PLUGIN_DIR" >"$TMP/argv"
  python3 - "$TMP/argv" <<'PY'
import sys, tomllib, subprocess, json
args = open(sys.argv[1], 'rb').read().decode().rstrip('\0').split('\0')
configs = [tomllib.loads(args[i+1]) for i, a in enumerate(args) if a == '-c']
hooks = {k:v for c in configs for k,v in c['hooks'].items()}
assert [x['matcher'] for x in hooks['PreToolUse']] == ['Bash', 'request_user_input']
command = hooks['PreToolUse'][0]['hooks'][0]['command']
p = subprocess.run(['/bin/sh','-c',command], input=json.dumps({'tool_input':{'command':'tmux kill-server'}}), text=True, capture_output=True)
assert p.returncode == 2, (command, p.stderr)
assert args[-3:] == ['resume', 'exact-id', 'do task']
assert '--sandbox' in args and args[args.index('--sandbox')+1] == 'workspace-write'
PY
}

@test "codex: environment, tmux default, new --run and dashboard actions use the same adapter" {
  COLLIE_AGENT=codex collie run x -p 'environment prompt'
  wait_for '[ -f "$ARGS" ]'
  [ "$(tail -n 1 "$ARGS")" = 'environment prompt' ]
  tmux set-option -g @collie-agent codex
  collie run x -p 'option prompt'
  wait_for '[ "$(tail -n 1 "$ARGS")" = "option prompt" ]'
  collie new y --run -p ''
  wait_for '[ -n "$(run_pane y)" ]'
  collie _bg r x
  wait_for '[ "$(grep -c "run_started" "$(task_dir x)/events.log")" -eq 3 ]'
  wait_for 'grep -q "agent_session.*run=3" "$(task_dir x)/events.log"'
  [ "$(tmux show-options -wqv -t "$(run_pane x 3)" @collie_agent)" = codex ]
}

@test "codex: stop invalidates a pending observer even while an old dialog is visible" {
  export CODEX_DRAW=1
  collie run x --agent codex -p ''
  wait_for 'grep -q "agent_session" "$(task_dir x)/events.log"'
  p=$(run_pane x)
  TMUX_PANE=$p collie _codex-hook state working
  tmux send-keys -t "$p" -l 'Press enter to confirm or esc to cancel'
  tmux send-keys -t "$p" Enter
  TMUX_PANE=$p collie _codex-hook wait
  TMUX_PANE=$p collie _codex-hook state idle
  sleep 0.8
  [ "$(agent_of x)" = idle ]
  ! grep -q 'state=waiting' "$(task_dir x)/events.log"
}
