#!/usr/bin/env bats

load helper

# Feeds a Bash tool call to hooks/tmux-guard the way an agent's PreToolUse
# hook does: the command JSON-escaped inside tool_input.
guard() {
  local j=${1//\\/\\\\}
  j=${j//\"/\\\"}
  j=${j//$'\n'/\\n}
  printf '{"tool_name":"Bash","tool_input":{"command":"%s","description":"d"}}' "$j" |
    "$COLLIE_ROOT/hooks/tmux-guard"
}

allowed() { run guard "$1" && [ "$status" -eq 0 ] && [ -z "$output" ]; }
denied() { run guard "$1" && [ "$status" -eq 2 ] && [[ $output == *"tmux -L <name>"* ]]; }

@test "guard: private servers and other commands pass" {
  allowed 'tmux -L x kill-server'
  allowed 'tmux -S /tmp/s kill-session -t a'
  allowed 'tmux -L "$n" kill-server'
  allowed 'cd x && tmux -L t kill-server'
  allowed 'tmux ls'
  allowed 'tmux new -d \; kill-pane'
  allowed "pkill -f 'tmux -L x'"
  allowed 'pkill node'
  allowed 'git commit -m "fix tmux kill-server guard"'
  allowed 'ls'
}

@test "guard: killing the default server or its sessions is denied" {
  denied 'tmux kill-server'
  denied 'cd x && tmux kill-server'
  denied 'cd x&&tmux kill-server'
  denied 'make test; tmux kill-server'
  denied $'ls\ntmux kill-server'
  denied '/usr/bin/tmux kill-ses -t a'
  denied 'TMUX= tmux kill-server'
  denied 'tmux "kill-server"'
  denied 'tmux new -d \; kill-server'
  denied 'x=$(tmux kill-session -t a)'
  denied '{ tmux kill-server; }'
  denied "bash -c 'tmux kill-server'"
  denied 'sh -c "cd x && tmux kill-session -t a"'
}

@test "guard: pkill and killall of tmux are denied" {
  denied 'pkill tmux'
  denied 'pkill -f tmux'
  denied 'pkill -f "tmux: server"'
  denied 'killall -9 tmux'
  denied 'sudo killall tmux'
}

@test "guard: input without a command passes" {
  run "$COLLIE_ROOT/hooks/tmux-guard" <<<'{"tool_name":"Read","tool_input":{"file_path":"/x"}}'
  [ "$status" -eq 0 ]
}
