#!/usr/bin/env bats

load helper

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off
  make_bare_repo A
  cd "$REPO/main"
  mkdir -p "$TMP/bin"
  for agent in claude codex; do
    cat >"$TMP/bin/$agent" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$COLLIE_STATE_DIR/$(basename "$0").args"
exec sleep 300
EOF
    chmod +x "$TMP/bin/$agent"
  done
  export PATH="$TMP/bin:$PATH"
  collie new x --no-window
  printf 'Completed parser; next add integration tests.\n' >"$TMP/note file"
}

teardown() {
  # Packets are deliberately read-only; allow the fixture to clean them up.
  chmod -R u+w "$COLLIE_STATE_DIR" 2>/dev/null || true
  teardown_env
}

@test "handoff: Claude to Codex preserves context and source conversation in separate runs" {
  collie run x --agent claude
  printf 'before handoff\n' >"$(task_dir x)/REPORT.md"
  printf '2026-01-01T00:00:00Z\tagent_session\trun=1 id=claude-source\n' >>"$(task_dir x)/events.log"
  cp "$(task_dir x)/TASK.md" "$TMP/original-task"
  run collie handoff x --from 1 --agent codex --note "$TMP/note file"
  [ "$status" -eq 0 ]
  packet=$output
  [ -d "$packet" ]
  cmp "$TMP/original-task" "$packet/TASK.md"
  cmp "$TMP/note file" "$packet/NOTE.md"
  grep -qx 'before handoff' "$packet/REPORT.md"
  grep -q 'source_run=1 source_agent=claude destination_agent=codex repo=A' "$packet/HANDOFF.md"
  grep -q 'run_handoff.*from=1 to=2 source=claude agent=codex repo=A packet=' "$(task_dir x)/events.log"
  grep -q 'agent_session.*run=1 id=claude-source' "$(task_dir x)/events.log"
  [ -n "$(run_pane x 1)" ] && [ -n "$(run_pane x 2)" ]
  [ "$(tmux display -p -t "$(run_pane x 1)" '#{@collie_state}')" = working ]
  wait_for '[ -s "$COLLIE_STATE_DIR/codex.args" ]'
  grep -qF "$packet/HANDOFF.md" "$COLLIE_STATE_DIR/codex.args"
  ! grep -qx 'claude-source' "$COLLIE_STATE_DIR/codex.args"
  [ "$(tmux display -p -t "$(run_pane x 2)" '#{pane_current_path}')" = "$TMP/repos/A/feat-x" ]
  printf 'new report\n' >"$(task_dir x)/REPORT.md"
  printf 'new task\n' >"$(task_dir x)/TASK.md"
  grep -qx 'before handoff' "$packet/REPORT.md"
  cmp "$TMP/original-task" "$packet/TASK.md"
  [ ! -w "$packet/NOTE.md" ]
}

@test "handoff: Codex to Claude defaults to source repo and makes unique packets" {
  make_normal_repo B
  collie add x -r B --no-window
  collie run x --agent codex -r B
  run env COLLIE_TASK=x "$COLLIE_ROOT/bin/collie" handoff --from 1 --agent claude --note "$TMP/note file"
  [ "$status" -eq 0 ]
  first=$output
  [ ! -e "$first/REPORT.md" ]
  [ "$(tmux display -p -t "$(run_pane x 2)" '#{pane_current_path}')" = "$TMP/repos/B.worktrees/feat-x" ]
  wait_for '[ -s "$COLLIE_STATE_DIR/claude.args" ]'
  grep -qF "$first/HANDOFF.md" "$COLLIE_STATE_DIR/claude.args"
  run collie handoff x --from 1 --agent claude -r A --note "$TMP/note file"
  [ "$status" -eq 0 ]
  [ "$first" != "$output" ]
  [ -f "$first/HANDOFF.md" ]
  [ "$(tmux display -p -t "$(run_pane x 3)" '#{pane_current_path}')" = "$TMP/repos/A/feat-x" ]
}

@test "handoff: invalid arguments never create a destination run" {
  collie run x --agent claude
  for source in 0 99 ../1 1x; do
    run collie handoff x --from "$source" --agent codex --note "$TMP/note file"
    [ "$status" -ne 0 ]
    [[ "$output" == *'source run'* ]]
  done
  run collie handoff x --from 1 --agent claude --note "$TMP/note file"
  [ "$status" -ne 0 ]
  [[ "$output" == *'different'* ]]
  run collie handoff x --from 1 --agent gemini --note "$TMP/note file"
  [ "$status" -ne 0 ]
  [[ "$output" == *'claude or codex'* ]]
  run collie handoff x --from 1 --agent codex --note "$TMP/missing"
  [ "$status" -ne 0 ]
  [[ "$output" == *'note'* ]]
  printf ' \n\t' >"$TMP/empty"
  run collie handoff x --from 1 --agent codex --note "$TMP/empty"
  [ "$status" -ne 0 ]
  [[ "$output" == *'note'* ]]
  run collie handoff x --from 1 --agent codex --note "$TMP/note file" -r missing
  [ "$status" -ne 0 ]
  [[ "$output" == *'not part of task'* ]]
  run collie handoff x --from 1 --agent codex
  [ "$status" -ne 0 ]
  [[ "$output" == *'note'* ]]
  [ "$(grep -c run_started "$(task_dir x)/events.log")" -eq 1 ]
  ! grep -q run_handoff "$(task_dir x)/events.log"
  [ ! -d "$(task_dir x)/handoffs" ]
}

@test "handoff: failed launch leaves diagnostic packet without success event" {
  collie run x --agent claude
  mkdir -p "$TMP/fail"
  cat >"$TMP/fail/tmux" <<EOF
#!/bin/sh
case \$1 in new-window) echo 'intentional spawn failure' >&2; exit 1 ;; esac
exec $(command -v tmux) "\$@"
EOF
  chmod +x "$TMP/fail/tmux"
  PATH="$TMP/fail:$PATH" run collie handoff x --from 1 --agent codex --note "$TMP/note file"
  [ "$status" -ne 0 ]
  [[ "$output" == *'intentional spawn failure'* ]]
  [ "$(grep -c run_started "$(task_dir x)/events.log")" -eq 1 ]
  ! grep -q run_handoff "$(task_dir x)/events.log"
  [ "$(find "$(task_dir x)/handoffs" -name HANDOFF.md | wc -l | tr -d ' ')" = 1 ]
}
