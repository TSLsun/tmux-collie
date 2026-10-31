#!/usr/bin/env bats

load helper

# Fake claude and codex play each flow step from the prompt they get (argv,
# or a line typed into their pane), fire the hooks a real agent would, and
# record their argv per launch. $TMP/verdicts feeds the reviews (default ok);
# $TMP/mode-<step> changes how a step behaves (nodone, bad, dirty).
setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY="$TMP/bin/note" TMP
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\nexec "${COLLIE_BASH:-bash}" %q "$@"\n' "$COLLIE_ROOT/bin/collie" >"$TMP/bin/collie"
  printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$1" "$2" >>%q\n' "$TMP/notes" >"$TMP/bin/note"
  cat >"$TMP/bin/fake-agent" <<'EOF'
#!/bin/bash
me=$(basename "$0")
printf '%s\n' "$@" >"$TMP/args-$me-$COLLIE_RUN"
printf '{"session_id":"sid-%s-%s"}' "$me" "$COLLIE_RUN" | collie _session
step() { # prompt line
  local p=${1#*read } s st d
  case $1 in *"PROMPT.md and follow it."*) ;; *"not complete"*) p=$LAST ;; *) return ;; esac
  p=${p%% and follow it.} LAST="read $p and follow it."
  d=$(dirname "$p") s=${1#*step } s=${s%%[ :]*}
  collie state working
  st=$(cat "$TMP/mode-$s" 2>/dev/null)
  case $s in
    implement) echo implemented >"$COLLIE_TASK_DIR/REPORT.md"; echo a >>impl.txt; git add impl.txt; git commit -qm impl ;;
    review)
      if [ "$st" = bad ]; then echo 'looks fine' >"$d/REVIEW.md"
      else
        v=$(head -n 1 "$TMP/verdicts" 2>/dev/null); sed -i.bak 1d "$TMP/verdicts" 2>/dev/null
        printf 'verdict: %s\n\n1. impl.txt:1: needs b. add b.\n' "${v:-ok}" >"$d/REVIEW.md"
      fi
      [ "$st" != dirty ] || echo x >>impl.txt ;;
    fix) printf '\n## Review response (round 1)\n1. fixed: added b\n' >>"$COLLIE_TASK_DIR/REPORT.md"; echo b >>impl.txt; git commit -qam fix ;;
    ship) echo 'PR https://github.com/o/r/pull/7' >>"$COLLIE_TASK_DIR/REPORT.md" ;;
  esac
  [ "$st" = nodone ] || collie flow done >>"$TMP/done.log" 2>&1
  collie state idle
}
for a in "$@"; do step "$a"; done
while IFS= read -r line; do step "$line"; done
EOF
  chmod +x "$TMP/bin/fake-agent" "$TMP/bin/collie" "$TMP/bin/note"
  cp "$TMP/bin/fake-agent" "$TMP/bin/claude"
  cp "$TMP/bin/fake-agent" "$TMP/bin/codex"
  export PATH="$TMP/bin:$PATH"
  make_bare_repo A
  cd "$REPO/main"
  collie new x --no-window
}
teardown() { teardown_env; }

# flows chain several agent launches: allow loaded CI runners 30s, not 5s
wait_for() {
  local i
  for i in $(seq 1 300); do
    if eval "$1"; then return 0; fi
    sleep 0.1
  done
  return 1
}

ev() { grep -c "	$1	" "$(task_dir x)/events.log" || true; }
flow_is() { collie show x | grep -q "^  flow $1"; }

# --- definitions ------------------------------------------------------------

@test "flow ls/show: repo-local, personal, builtin lookup with shadowing" {
  mkdir -p "$XDG_CONFIG_HOME/collie/flows" "$REPO/.collie/flows"
  printf 'implement: role=implement agent=claude model=opus effort=high\n' >"$XDG_CONFIG_HOME/collie/flows/review-loop"
  printf 'implement: role=implement agent=codex\n' >"$REPO/.collie/flows/review-loop"
  run collie flow ls
  [ "$status" -eq 0 ]
  [ "$(grep -c '^review-loop' <<<"$output")" -eq 3 ]
  [[ $(grep '^review-loop' <<<"$output" | head -n 1) == "review-loop	repo	$REPO/.collie/flows/review-loop" ]]
  [ "$(grep -c '(shadowed)' <<<"$output")" -eq 2 ]
  grep -q "^implement-review	builtin	$COLLIE_ROOT/flows/implement-review$" <<<"$output"
}

@test "flow show: steps, inherited agent of resume=, the loop" {
  run collie flow show review-loop
  [ "$status" -eq 0 ]
  [[ $output == *"review-loop (builtin)"* ]]
  [[ $output == *"fix: role=fix agent=claude (continues implement)"* ]]
  [[ $output == *"ship: role=ship agent=claude (continues implement)"* ]]
  [[ $output == *"loop: review fix, at most 2 fix rounds"* ]]
}

@test "flow show: rejects bad definitions with file:line" {
  mkdir -p "$XDG_CONFIG_HOME/collie/flows"
  f="$XDG_CONFIG_HOME/collie/flows/bad"
  check() { printf "$1" >"$f"; run collie flow show bad; [ "$status" -ne 0 ]; [[ $output == *"$2"* ]] || { echo "$output"; return 1; }; }
  check 'a: role=implement colour=red\n' "bad:1: unknown key 'colour'"
  check 'a: role=paint\n' "role must be one of"
  check 'a: role=fix resume=b\n' "no earlier step 'b'"
  check 'a: role=implement\nb: role=fix resume=a\n' "is not in a loop"
  check 'a: role=implement agent=sleep\n' "agent 'sleep' has no collie adapter"
  check 'a: role=implement\nb: role=review agent=codex\nloop: b a max=1\n' "'a' is not a fix step"
  check 'a: role=implement\nb: role=fix resume=a model=x\n' "drop agent/model/effort"
  check 'a: role=implement effort=hi"gh\n' "invalid effort"
}

# --- running ----------------------------------------------------------------

@test "review-loop: implement, changes-needed, fix in the same conversation, ok, ship" {
  printf 'changes-needed\nok\n' >"$TMP/verdicts"
  run collie flow start review-loop x
  [ "$status" -eq 0 ]
  [[ $output == *"step implement (run 1)"* ]]
  wait_for "[ \$(ev flow_done) -eq 1 ]"
  d=$(task_dir x)
  # implement=1, review=2, fix typed into run 1, review=3, ship typed into run 1
  [ "$(awk -F'\t' '$2 == "flow_step" { print $3 }' "$d/events.log" | cut -d' ' -f2,5,6)" = "$(printf '%s\n' \
    'step=implement run=1 via=new' 'step=review run=2 via=new' 'step=fix run=1 via=pane' \
    'step=review run=3 via=new' 'step=ship run=1 via=pane')" ]
  grep -q "flow_verdict	n=2 step=review round=1 verdict=changes-needed" "$d/events.log"
  grep -q "flow_verdict	n=4 step=review round=2 verdict=ok" "$d/events.log"
  grep -q "flow_done	n=5 pr=https://github.com/o/r/pull/7" "$d/events.log"
  [ "$(fm x flow)" = review-loop ]
  # the reviewer got the diff, the report, and in round 2 the prior review
  grep -q '^+a' "$d/flow/02-review/DIFF.patch"
  grep -q implemented "$d/flow/02-review/REPORT.md"
  grep -q 'changes-needed' "$d/flow/04-review/PRIOR-REVIEW.md"
  # codex got a fresh conversation with the prompt as the last argument
  [[ $(tail -n 1 "$TMP/args-codex-2") == "Task x, flow review-loop, step review (round 1): read $d/flow/02-review/PROMPT.md and follow it." ]]
  grep -q 'verdict: ok' "$d/flow/04-review/PROMPT.md"
  # the PR summary: steps, reviews and the implementer's responses
  s="$d/flow/05-ship/SUMMARY.md"
  grep -qF '| review r1 | codex | 2 | changes-needed, 1 findings |' "$s"
  grep -qF '| fix r1 | claude | 1 | see review response r1 |' "$s"
  grep -qF '### Review r2 (review)' "$s"
  grep -qF '1. fixed: added b' "$s"
  grep -qF 'Finish the delivery loop yourself' "$d/flow/05-ship/PROMPT.md"
  # notified once, at the end; no "finished its turn" popups meanwhile
  wait_for "[ -f '$TMP/notes' ]"
  [ "$(cat "$TMP/notes")" = "collie: x|flow review-loop: finished: https://github.com/o/r/pull/7" ]
  collie show x | grep -q '^  flow review-loop: done'
  collie show x | grep -q '^    05-ship  run 1 DONE SUMMARY.md$'
  collie _runrows x | grep -q "flow review r1"
}

@test "review-loop: the loop limit stops and notifies; continue reviews again" {
  mkdir -p "$XDG_CONFIG_HOME/collie/flows"
  printf 'implement: role=implement agent=claude\nreview: role=review agent=codex\nfix: role=fix resume=implement\nloop: review fix max=1\n' \
    >"$XDG_CONFIG_HOME/collie/flows/once"
  printf 'changes-needed\nchanges-needed\nok\n' >"$TMP/verdicts"
  collie flow start once x
  wait_for "[ \$(ev flow_stopped) -eq 1 ]"
  grep -q "flow_stopped	n=4 step=review reason=limit" "$(task_dir x)/events.log"
  wait_for "grep -q 'stopped at review: still changes-needed after 1 fix rounds' '$TMP/notes'"
  run collie flow continue x
  [ "$status" -eq 0 ]
  [[ $output == *"step review r2 (run 4)"* ]]
  wait_for "[ \$(ev flow_done) -eq 1 ]"
  ! grep -q "	pr=" <(grep flow_done "$(task_dir x)/events.log")
}

@test "flow: an idle step without the done signal waits and notifies" {
  echo nodone >"$TMP/mode-implement"
  collie flow start review-loop x
  wait_for "grep -q 'implement stopped without the done signal' '$TMP/notes'"
  [ "$(ev flow_step)" -eq 1 ]
  flow_is "review-loop: running, step implement"
  # the human tells it to finish: the agent signals done, the flow goes on
  rm "$TMP/mode-implement"
  TMUX_PANE=$(run_pane x 1) COLLIE_TASK=x COLLIE_RUN=1 collie flow done
  hook x working
  hook x idle
  wait_for "[ \$(ev flow_step) -ge 2 ]"
}

@test "flow: a review without a verdict is sent back once, then stops" {
  echo bad >"$TMP/mode-review"
  collie flow start review-loop x
  wait_for "[ \$(ev flow_stopped) -eq 1 ]"
  [ "$(ev flow_retry)" -eq 1 ]
  grep -q "reason=invalid-artifact" "$(task_dir x)/events.log"
  wait_for "grep -q \"must start with the line 'verdict: ok'\" '$TMP/notes'"
}

@test "flow: a reviewer that changes the worktree stops the flow" {
  echo dirty >"$TMP/mode-review"
  collie flow start review-loop x
  wait_for "[ \$(ev flow_stopped) -eq 1 ]"
  grep -q "reason=worktree-changed" "$(task_dir x)/events.log"
}

@test "flow: fix resumes the implement conversation by id once its window is gone" {
  echo changes-needed >"$TMP/verdicts"
  echo nodone >"$TMP/mode-review"
  collie flow start review-loop x
  wait_for "[ \$(ev flow_step) -eq 2 ]"
  wait_for "[ -f '$TMP/args-codex-2' ]"
  tmux kill-window -t "$(tmux list-windows -t =x -F '#{@collie_run} #{window_id}' | awk '$1 == 1 { print $2 }')"
  rm "$TMP/mode-review"
  TMUX_PANE=$(run_pane x 2) COLLIE_TASK=x COLLIE_RUN=2 collie flow done
  hook x working 2
  hook x idle 2
  wait_for "[ \$(ev flow_step) -eq 3 ]"
  grep -q "step=fix role=fix round=1 run=3 via=resume conv=implement" "$(task_dir x)/events.log"
  wait_for "[ -f '$TMP/args-claude-3' ]"
  [ "$(grep -A1 -xF -- --resume "$TMP/args-claude-3" | tail -n 1)" = sid-claude-1 ]
}

@test "flow done: only the run of the current step, only in a running flow" {
  run env COLLIE_TASK=x COLLIE_RUN=1 bash "$COLLIE_ROOT/bin/collie" flow done
  [ "$status" -ne 0 ]
  [[ $output == *"has no flow"* ]]
  echo nodone >"$TMP/mode-implement"
  collie flow start review-loop x
  run env COLLIE_TASK=x COLLIE_RUN=5 bash "$COLLIE_ROOT/bin/collie" flow done
  [ "$status" -ne 0 ]
  [[ $output == *"this is run 5; step implement is run 1"* ]]
  run collie flow start review-loop x
  [[ $output == *"already has a flow"* ]]
  collie flow stop x
  flow_is "review-loop: stopped at implement (user)"
}

@test "wait: run states, done signal, timeout and gone runs" {
  echo nodone >"$TMP/mode-implement"
  collie flow start review-loop x
  run collie wait x --for idle --timeout 5
  [ "$status" -eq 0 ]
  run collie wait x --timeout 1
  [ "$status" -eq 1 ]
  ( sleep 1; TMUX_PANE=$(run_pane x 1) COLLIE_TASK=x COLLIE_RUN=1 collie flow done ) &
  run collie wait x --for done --timeout 5
  [ "$status" -eq 0 ]
  run collie wait x --run 9 --for idle --timeout 5
  [ "$status" -eq 2 ]
}

@test "new --flow --run: starts the flow; no Ship section; conflicts rejected" {
  run collie new y --flow review-loop
  [[ $output == *"--flow needs --run"* ]]
  run collie new y --flow review-loop --run --agent codex
  [[ $output == *"--flow picks the agents"* ]]
  collie new z --flow review-loop --run --ship
  ! grep -q '^## Ship' "$(task_dir z)/TASK.md"
  [ "$(fm z flow)" = review-loop ]
  grep -q "flow_started	flow=review-loop source=builtin" "$(task_dir z)/events.log"
}

@test "flow: survives a tmux server restart; restore resumes the step's run" {
  echo nodone >"$TMP/mode-review"
  collie flow start review-loop x
  wait_for "[ \$(ev flow_step) -eq 2 ]"
  wait_for "grep -q 'run=2 id=sid-codex-2' '$(task_dir x)/events.log'"
  wait_for "[ \$(ev agent_state) -ge 2 ]"
  [ -f "$(task_dir x)/flow/02-review/REVIEW.md" ]
  tmux -S "$TMUX_TMPDIR/tmux-$(id -u)/default" kill-server
  run collie restore x
  [ "$status" -eq 0 ]
  grep -q "run_restored	run=2 as=4" "$(task_dir x)/events.log"
  grep -qxF sid-codex-2 "$TMP/args-codex-4"
  collie show x | grep -q '^  flow review-loop: running, step review r1 (run 4)'
  wait_for "grep -q 'review stopped without the done signal' '$TMP/notes'"
  rm "$TMP/mode-review"
  TMUX_PANE=$(run_pane x 4) COLLIE_TASK=x COLLIE_RUN=4 collie flow done
  hook x working 4
  hook x idle 4
  wait_for "[ \$(ev flow_done) -eq 1 ]"
}

@test "flow: a step that signalled done advances only once its agent stops" {
  echo nodone >"$TMP/mode-implement"
  collie flow start review-loop x
  wait_for "[ \$(ev agent_state) -ge 1 ]"
  hook x working
  TMUX_PANE=$(run_pane x 1) COLLIE_TASK=x COLLIE_RUN=1 collie flow done
  collie _flow-advance x
  [ "$(ev flow_step)" -eq 1 ]
  hook x idle
  wait_for "[ \$(ev flow_step) -eq 2 ]"
}
