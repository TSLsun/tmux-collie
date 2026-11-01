#!/usr/bin/env bats

load helper
load tmux_diagnostics

# The fake claude records its argv and fires the SessionStart hook collie
# gave it with the JSON the real CLI sends on stdin: a fresh session id, or
# the one it was told to --resume.
setup() {
  setup_env
  setup_tmux_diagnostics
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=sleep
  mkdir "$TMP/bin"
  export PATH="$TMP/bin:$PATH" ARGS="$TMP/args"
  cat >"$TMP/bin/claude" <<'EOF'
#!/bin/sh
sid=new-$$ prev=
for a in "$@"; do
  [ "$prev" = --settings ] && settings=$a
  [ "$prev" = --resume ] && sid=$a
  prev=$a
done
echo "claude $*" >>"$ARGS"
cmd=$(printf '%s' "$settings" | sed -n 's/.*"SessionStart":\[{"hooks":\[{"type":"command","command":"\([^"]*\)"}.*/\1/p')
printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"startup"}\n' "$sid" | sh -c "$cmd"
exec sleep 300
EOF
  printf '#!/bin/sh\necho "omp $*" >>"$ARGS"\nexec sleep 300\n' >"$TMP/bin/omp"
  chmod +x "$TMP/bin/claude" "$TMP/bin/omp"
  make_bare_repo A
  cd "$REPO/main"
  collie new x --no-window
}
teardown() {
  capture_tmux_diagnostics || true
  teardown_env
  save_tmux_diagnostics || true
}

# kills the test's private server, the way a crash would
server_dies() {
  local pid
  pid=$(tmux display -p '#{pid}')
  TMUX_DIAGNOSTICS_PIDS="${TMUX_DIAGNOSTICS_PIDS:-} $pid"
  tmux_diagnostic_event "sending SIGTERM to pid=$pid"
  kill "$pid"
  wait_for '! tmux list-sessions >/dev/null 2>&1' || return
  tmux_diagnostic_event "list-sessions stopped succeeding for pid=$pid"
}

sessions_logged() { [ "$(grep -c "agent_session	" "$(task_dir x)/events.log")" -eq "$1" ]; }

agent_windows() { tmux list-windows -t "=$1" -F '#{@collie_run}' | grep -c .; }

@test "_session: the SessionStart hook logs the conversation id when it changes" {
  collie run x --agent claude
  wait_for 'sessions_logged 1'
  grep -q "agent_session	run=1 id=new-[0-9]*$" "$(task_dir x)/events.log"
  p=$(run_pane x)
  sid=$(sed -n 's/.*agent_session	run=1 id=//p' "$(task_dir x)/events.log")
  echo "{\"session_id\":\"$sid\"}" | TMUX_PANE=$p collie _session
  sessions_logged 1
  echo '{"session_id":"after-clear"}' | TMUX_PANE=$p collie _session
  grep -q "agent_session	run=1 id=after-clear$" "$(task_dir x)/events.log"
  echo '{"session_id":"bad id;rm"}' | TMUX_PANE=$p collie _session
  echo 'not json' | TMUX_PANE=$p collie _session
  echo '{"session_id":"elsewhere"}' | TMUX_PANE= collie _session
  sessions_logged 2
}

@test "restore: resumes each run lost with the server by its id, once" {
  collie run x --agent claude
  collie run x --agent claude -p ''
  wait_for 'sessions_logged 2'
  id1=$(sed -n 's/.*agent_session	run=1 id=//p' "$(task_dir x)/events.log")
  id2=$(sed -n 's/.*agent_session	run=2 id=//p' "$(task_dir x)/events.log")
  grep -q "run_started	run=1 agent=claude repo=A window=@[0-9]* server=[0-9]*$" "$(task_dir x)/events.log"
  server_dies

  run collie restore -n
  [ "$status" -eq 0 ]
  [ "$output" = "x run 1: claude in A: --resume $id1"$'\n'"x run 2: claude in A: --resume $id2" ]
  ! tmux list-sessions >/dev/null 2>&1

  run collie restore
  [ "$status" -eq 0 ]
  [ "$output" = "x run 1: claude in A: restored (--resume $id1)"$'\n'"x run 2: claude in A: restored (--resume $id2)" ]
  [ "$(agent_windows x)" -eq 2 ]
  wait_for 'sessions_logged 4'
  grep -q -- "--name x --settings .* --resume $id1$" "$ARGS"
  grep -q -- "--name x --settings .* --resume $id2$" "$ARGS"
  grep -q "run_restored	run=1 as=3$" "$(task_dir x)/events.log"
  grep -q "agent_session	run=4 id=$id2$" "$(task_dir x)/events.log"
  [ "$(collie ls | cut -f5)" = idle ]

  run collie restore
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(agent_windows x)" -eq 2 ]

  # the restored runs are lost the next time, and resume the same conversations
  server_dies
  run collie restore -n
  [ "$output" = "x run 3: claude in A: --resume $id1"$'\n'"x run 4: claude in A: --resume $id2" ]
}

@test "restore: records its own allocated ID when another run starts before it returns" {
  collie run x --agent omp -p ''
  server_dies
  export REAL_TMUX COLLIE_ROOT
  REAL_TMUX=$(command -v tmux)
  cat >"$TMP/bin/tmux" <<'EOF'
#!/bin/sh
"$REAL_TMUX" "$@" || exit
case " $* " in
  *' @collie_run '*)
    if mkdir "$COLLIE_STATE_DIR/interleaved" 2>/dev/null; then
      bash "$COLLIE_ROOT/bin/collie" run x --agent sleep -- 300
    fi ;;
esac
EOF
  chmod +x "$TMP/bin/tmux"
  collie restore x
  grep -q 'run_started.*run=3 agent=sleep' "$(task_dir x)/events.log"
  grep -q 'run_restored.*run=1 as=2$' "$(task_dir x)/events.log"
}

@test "restore: a window closed on a live server is not restored" {
  collie run x -- 300
  tmux kill-window -t "$(run_pane x)"
  run collie restore -n
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "restore: falls back to the latest conversation once per repo, skips agents that cannot" {
  collie run x --agent omp -p ''
  collie run x --agent omp -p ''
  collie run x -- 300
  collie new y --no-window
  collie run y --agent omp -p ''
  server_dies
  run collie restore x
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "x run 1: omp in A: restored (-c)" ]
  [ "${lines[1]}" = "x run 2: omp in A: skipped: run 1 already resumes the latest conversation" ]
  [ "${lines[2]}" = "x run 3: sleep in A: skipped: collie cannot resume sleep sessions" ]
  [ "${#lines[@]}" -eq 3 ]
  wait_for 'grep -q "omp -e .* -c$" "$ARGS"'
  ! tmux has-session -t =y 2>/dev/null
  # skipped runs stay lost; the restored run still holds the conversation
  run collie restore -n
  [ "${lines[0]}" = "x run 2: omp in A: skipped: run 4 already resumes the latest conversation" ]
  [ "${lines[2]}" = "y run 1: omp in A: -c" ]
  run collie restore -n nope
  [ "$status" -ne 0 ]
}

@test "restore: runs logged without a server count as lost only without the session" {
  printf '2020-01-01T00:00:00Z\trun_started\trun=1 agent=omp repo=A window=@1\n' >>"$(task_dir x)/events.log"
  run collie restore -n
  [ "$output" = "x run 1: omp in A: -c" ]
  tmux new-session -d -s x
  run collie restore -n
  [ -z "$output" ]
}

@test "restore: done and archived tasks are left alone" {
  collie run x --agent omp -p ''
  server_dies
  collie done x --force
  run collie restore -n
  [ -z "$output" ]
}

@test "collie.tmux: @collie-restore on restores lost runs at load, off by default" {
  collie run x --agent omp -p ''
  server_dies
  tmux_with_diagnostics new-session -d -s t
  tmux run-shell "$COLLIE_ROOT/collie.tmux"
  sleep 0.5
  ! tmux has-session -t =x 2>/dev/null
  tmux set-option -g @collie-restore on
  tmux run-shell "$COLLIE_ROOT/collie.tmux"
  # restore runs in the background and logs run_restored after the window exists
  wait_for 'grep -q "run_restored	run=1 as=2$" "$(task_dir x)/events.log"'
  [ "$(agent_windows x)" -eq 1 ]
}
