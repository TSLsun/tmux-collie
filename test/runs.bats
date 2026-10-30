#!/usr/bin/env bats

load helper

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=sleep
  make_bare_repo A
  cd "$REPO/main"
}
teardown() {
  # handoff packets are read-only
  chmod -R u+w "$COLLIE_STATE_DIR" 2>/dev/null || true
  teardown_env
}

plain() { sed $'s/\033\\[[0-9;]*m//g'; }

# runs 1..5: exits 0 and 1, a handoff 2 -> 3 that left no exit (lost), and a
# run from before repo= restored as 5
history_fixture() {
  collie new x --no-window
  cat >>"$(task_dir x)/events.log" <<'EOF'
2026-01-01T00:00:00Z	run_started	run=1 agent=claude repo=A window=@1 server=1
2026-01-01T00:01:00Z	run_exited	run=1 code=0
2026-01-01T00:02:00Z	run_started	run=2 agent=claude repo=A window=@2 server=1
2026-01-01T00:02:30Z	agent_session	run=2 id=sess-2
2026-01-01T00:03:00Z	run_started	run=3 agent=codex repo=A window=@3 server=1
2026-01-01T00:03:00Z	run_handoff	from=2 to=3 source=claude agent=codex repo=A packet=from-2-to-codex.abc
2026-01-01T00:04:00Z	run_exited	run=2 code=1
2026-01-01T00:05:00Z	run_started	run=4 agent=claude window=@4
2026-01-01T00:06:00Z	run_started	run=5 agent=claude repo=A window=@5 server=2
2026-01-01T00:06:00Z	run_restored	run=4 as=5
EOF
}

@test "_runrows: every run newest first with its exit, lost/restored state and handoff/restore links" {
  history_fixture
  out=$(collie _runrows x | plain)
  [ "$(cut -f1 <<<"$out" | paste -s -d, -)" = "5,4,3,2,1" ]
  [ "$(paste -s -d, "$COLLIE_STATE_DIR/dash-rows")" = "5,4,3,2,1" ]
  grep -Eq $'^5\t#5  claude  A  lost +[0-9]+w  restore of 4$' <<<"$out"
  grep -Eq $'^4\t#4  claude  -  restored +[0-9]+w  restored as 5$' <<<"$out"
  grep -Eq $'^3\t#3  codex   A  lost +[0-9]+w  handoff from 2 \\(claude\\)$' <<<"$out"
  grep -Eq $'^2\t#2  claude  A  exited 1 +[0-9]+w  handoff to 3 \\(codex\\)$' <<<"$out"
  grep -Eq $'^1\t#1  claude  A  exited 0 +[0-9]+w$' <<<"$out"
  # every row as wide as dash-width says, at most
  w=$(cat "$COLLIE_STATE_DIR/dash-width")
  while IFS= read -r l; do [ "${#l}" -le "$w" ]; done < <(cut -f2 <<<"$out")
}

@test "_runrows: two live runs of one agent are told apart, ▸ on enter's; a logged exit wins over the window" {
  collie new x --no-window
  collie run x -- 300
  collie run x -- 300
  wait_for '[ "$(collie _runrows x | plain | grep -c sleep)" -eq 2 ]'
  out=$(collie _runrows x | plain)
  grep -Eq $'^2\t#2  sleep  A  (working|idle)' <<<"$out"
  grep -Eq $'^1\t#1  sleep  A  (working|idle)' <<<"$out"
  [ "$(collie _preview x | grep -c '^▸ #')" -eq 1 ]
  printf '2026-01-01T00:00:00Z\trun_exited\trun=1 code=3\n' >>"$(task_dir x)/events.log"
  grep -Eq $'^1\t#1  sleep  A  exited 3' <<<"$(collie _runrows x | plain)"
}

@test "preview: the task's newest runs; the runs view previews one run" {
  history_fixture
  out=$(collie _preview x)
  grep -q '^runs:$' <<<"$out"
  grep -q '^  #2  claude  A  exited 1  handoff to 3 (codex)$' <<<"$out"
  ! grep -q '#1  claude' <<<"$out"
  printf '2026-01-01T00:07:00Z\trun_started\trun=6 agent=claude repo=A\n' >>"$(task_dir x)/events.log"
  grep -q '^runs:  (newest 5 of 6; u: all)$' <<<"$(collie _preview x)"

  mkdir -p "$TMP/dash"
  echo x >"$TMP/dash/runs"
  out=$(COLLIE_DASH="$TMP/dash" collie _preview 3)
  grep -q '^run #3  \[lost\]$' <<<"$out"
  grep -q '^links:   handoff from 2 (claude)$' <<<"$out"
  grep -q '^packet:  handoffs/from-2-to-codex.abc$' <<<"$out"
  grep -q '^h: hand off to claude$' <<<"$out"
  out=$(COLLIE_DASH="$TMP/dash" collie _preview 2)
  grep -q '^session: sess-2$' <<<"$out"
  grep -q '^ended:   2026-01-01T00:04:00Z$' <<<"$out"
}

@test "_key: u opens the task's runs, esc goes back to its row; task keys do nothing there" {
  history_fixture
  collie new y --no-window
  collie _rows >/dev/null
  export COLLIE_DASH="$TMP/dash" FZF_PROMPT='collie> '
  mkdir -p "$COLLIE_DASH"
  pos=$(grep -nxF x "$COLLIE_STATE_DIR/dash-rows" | cut -d: -f1)
  out=$(collie _key u x)
  [ "$(cat "$COLLIE_DASH/runs")" = x ]
  [[ "$out" == *"reload-sync("*"_runrows)+first"* ]]
  [[ "$(plain <<<"$out")" == *"runs of x"*"h: handoff  esc: back"* ]]
  # u on a separator does nothing
  [ -z "$(rm "$COLLIE_DASH/runs" && collie _key u '')" ]
  collie _key u x >/dev/null

  [ -z "$(collie _key d 3)" ]
  [ -z "$(collie _group next)" ]
  [ "$(collie _key j 3)" = down ]
  # a kept filter clears first
  [[ "$(FZF_QUERY=claude collie _key esc 3)" == show-input+clear-query* ]]
  [ -f "$COLLIE_DASH/runs" ]
  out=$(collie _key esc 3)
  [ ! -f "$COLLIE_DASH/runs" ]
  [[ "$out" == *"reload-sync("*"_rows)+pos($pos)"* ]]
}

@test "_key: enter in the runs view goes to that run's window, or says why not" {
  collie new x --no-window
  collie run x -- 300
  collie run x -- 300
  wait_for '[ "$(collie _runrows x | plain | grep -c sleep)" -eq 2 ]'
  export COLLIE_DASH="$TMP/dash" FZF_PROMPT='collie> '
  mkdir -p "$COLLIE_DASH"
  echo x >"$COLLIE_DASH/runs"
  w1=$(tmux list-windows -t =x -F '#{window_id} #{@collie_run}' | awk '$2 == 1 { print $1 }')
  [ "$(collie _key enter 1)" = accept ]
  [ "$(cat "$COLLIE_DASH/go")" = "x	$w1" ]
  rm "$COLLIE_DASH/go"
  printf '2026-01-01T00:00:00Z\trun_exited\trun=2 code=0\n' >>"$(task_dir x)/events.log"
  [ "$(collie _key enter 2)" = refresh-preview ]
  [ ! -f "$COLLIE_DASH/go" ]
  [ "$(cat "$COLLIE_DASH/msg")" = $'fail\nrun 2 has no window (exited 0)' ]
}

@test "_handoff: hands a run to the other agent with the note from \$EDITOR; an empty note cancels" {
  mkdir -p "$TMP/bin"
  for agent in claude codex; do
    printf '#!/bin/sh\nexec sleep 300\n' >"$TMP/bin/$agent"
    chmod +x "$TMP/bin/$agent"
  done
  export PATH="$TMP/bin:$PATH"
  collie new x --no-window
  collie run x --agent claude
  printf '#!/bin/sh\n' >"$TMP/ed"
  chmod +x "$TMP/ed"
  out=$(EDITOR="$TMP/ed" collie _handoff x 1 </dev/null)
  [[ "$out" == *"handoff x run 1 (claude, A, "* ]]
  [[ "$out" == *"run 1 stays live: both runs share the worktree"* ]]
  ! grep -q run_handoff "$(task_dir x)/events.log"

  printf '#!/bin/sh\necho "parser done; add tests" >"$1"\n' >"$TMP/ed"
  EDITOR="$TMP/ed" collie _handoff x 1 </dev/null
  grep -q $'run_handoff\tfrom=1 to=2 source=claude agent=codex' "$(task_dir x)/events.log"
  grep -q 'parser done' "$(task_dir x)"/handoffs/*/NOTE.md

  collie run x -- 300
  out=$(EDITOR="$TMP/ed" collie _handoff x 3 </dev/null)
  [[ "$out" == *"run 3 (sleep) cannot be handed off: only claude and codex runs"* ]]
  [ "$(grep -c run_handoff "$(task_dir x)/events.log")" -eq 1 ]
}

@test "dash: u shows the runs and previews the newest, esc comes back to the tasks" {
  command -v fzf >/dev/null || skip "fzf not installed"
  history_fixture
  tmux -f /dev/null new-session -d -s d -x 160 -y 30 \
    "'${COLLIE_BASH:-bash}' '$COLLIE_ROOT/bin/collie' dash; sleep 60"
  wait_for "tmux capture-pane -p -t =d: | grep -q 'objective:'"
  tmux send-keys -t =d: u
  wait_for "tmux capture-pane -p -t =d: | grep -q 'run #5  \[lost\]'"
  tmux capture-pane -p -t =d: >"$TMP/screen"
  grep -q 'runs of x' "$TMP/screen"
  grep -q '#2  claude  A  exited 1' "$TMP/screen"
  tmux send-keys -t =d: k
  wait_for "tmux capture-pane -p -t =d: | grep -q 'run #4  \[restored\]'"
  tmux send-keys -t =d: Escape
  wait_for "tmux capture-pane -p -t =d: | grep -q 'objective:'"
  ! tmux capture-pane -p -t =d: | grep -q 'runs of x'
}
