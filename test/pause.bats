#!/usr/bin/env bats

load helper
bats_require_minimum_version 1.5.0

# As in send.bats, the agent is `cat` (generic adapter, no hooks) and tests
# fire the hooks by hand. Fake claude/codex/omp record their argv.
setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=cat COLLIE_SILENCE=600
  mkdir -p "$TMP/bin"
  for agent in claude codex omp; do
    cat >"$TMP/bin/$agent" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$COLLIE_STATE_DIR/$(basename "$0").args"
exec sleep 300
EOF
    chmod +x "$TMP/bin/$agent"
  done
  export PATH="$TMP/bin:$PATH"
  make_bare_repo A
  cd "$REPO/main"
}
teardown() {
  chmod -R u+w "$COLLIE_STATE_DIR" 2>/dev/null || true
  teardown_env
}

pane_text() { tmux capture-pane -p -J -t "$(run_pane "$1" "${2:-1}")"; }
args_of() { cat "$COLLIE_STATE_DIR/$1.args"; }

@test "pause: sends the default request to an idle agent and logs it" {
  collie new s
  collie run s
  hook s idle
  run --separate-stderr collie pause s
  [ "$status" -eq 0 ]
  [[ "$output" == "s: sent to run 1 (cat) in "* ]]
  wait_for "pane_text s | grep -qF '$(task_dir s)/RESUME.md'"
  grep -q "	sent	run=1 text=Pause: stop at the next safe boundary" "$(task_dir s)/events.log"
}

@test "pause: -p and -f replace the request" {
  collie new s
  collie run s
  hook s idle
  collie pause s -p 'pause after the tests'
  wait_for "pane_text s | grep -q 'pause after the tests'"
  ! pane_text s | grep -q RESUME.md
  printf 'from a file\n' >"$TMP/req"
  collie pause s --run 1 -f "$TMP/req"
  wait_for "pane_text s | grep -q 'from a file'"
  run --separate-stderr collie pause s -p x -f "$TMP/req"
  [ "$stderr" = "collie: pause: give -p or -f, not both" ]
}

@test "pause: refuses a working or waiting agent with exit 2 and types nothing" {
  collie new s
  collie run s
  for st in working waiting; do
    hook s "$st"
    run --separate-stderr collie pause s
    [ "$status" -eq 2 ]
    [ "$stderr" = "collie: pause: run 1 (cat) is $st, not idle; not sent (collie wait s --run 1)" ]
  done
  sleep 0.5
  ! pane_text s | grep -q Pause
  ! grep -q "	sent	" "$(task_dir s)/events.log"
}

@test "pause: no live run exits 3 like send" {
  collie new s --no-window
  run --separate-stderr collie pause s
  [ "$status" -eq 3 ]
  [ "$stderr" = "collie: send: no live agent run in task 's'; not sent" ]
}

@test "show and the dash preview mention RESUME.md only when present" {
  collie new s --no-window
  ! collie show s | grep -q RESUME
  ! collie _preview s | grep -q RESUME
  printf 'next: tests\n' >"$(task_dir s)/RESUME.md"
  collie show s | grep -qxF "resume note: $(task_dir s)/RESUME.md"
  collie _preview s | grep -qxF "resume note: $(task_dir s)/RESUME.md"
}

@test "run: the default prompt points at RESUME.md when present; -p does not" {
  collie new s --no-window
  collie run s --agent claude
  wait_for '[ -s "$COLLIE_STATE_DIR/claude.args" ]'
  ! args_of claude | grep -q RESUME
  rm "$COLLIE_STATE_DIR/claude.args"
  printf 'next: tests\n' >"$(task_dir s)/RESUME.md"
  collie run s --agent claude
  wait_for '[ -s "$COLLIE_STATE_DIR/claude.args" ]'
  [[ "$(head -n 1 "$COLLIE_STATE_DIR/claude.args")" == *".collie/REPORT.md. A paused run left a resume note at .collie/RESUME.md"* ]]
  rm "$COLLIE_STATE_DIR/claude.args"
  collie run s --agent claude -p 'just go'
  wait_for '[ -s "$COLLIE_STATE_DIR/claude.args" ]'
  ! args_of claude | grep -q RESUME
}

@test "handoff: the prompt points at RESUME.md when present" {
  collie new s --no-window
  collie run s --agent claude
  printf 'done: parser\n' >"$TMP/note"
  printf 'next: tests\n' >"$(task_dir s)/RESUME.md"
  collie handoff s --from 1 --agent codex --note "$TMP/note" >/dev/null
  wait_for '[ -s "$COLLIE_STATE_DIR/codex.args" ]'
  args_of codex | grep -qF "resume note at $(task_dir s)/RESUME.md"
}

@test "adopt: prompts the resumed agent with RESUME.md when present" {
  mkdir -p "$TMP/manual"
  fake_agent "$TMP/manual/omp"
  collie new s --no-window
  collie go s
  printf 'next: tests\n' >"$(task_dir s)/RESUME.md"
  tmux new-window -d -t "=s:" -c "$REPO/feat-s" "sh -c '$TMP/manual/omp -c \"read -t 300\"; :'"
  wait_for '[ "$(agent_of s)" = working ]'
  collie adopt s -y
  wait_for '[ -s "$COLLIE_STATE_DIR/omp.args" ]'
  args_of omp | grep -qF "Task s. A paused run left a resume note at $(task_dir s)/RESUME.md"
  grep -qxF -- -c "$COLLIE_STATE_DIR/omp.args"
}
