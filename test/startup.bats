#!/usr/bin/env bats
load helper
bats_require_minimum_version 1.5.0

# The fake claude (real adapter, so real dialog patterns) draws $SCREEN when it
# appears and logs every line it reads to $TYPED. Hooks fire through hook().
CLAUDE_DIALOG=$' Quick safety check: Is this a project you created or one you trust?\n\n Security guide\n\n \xe2\x9d\xaf No, exit\n   Yes, I trust this folder\n\n Enter to confirm \xc2\xb7 Esc to cancel'

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY="echo >>$TMP/notified" SCREEN="$TMP/screen" TYPED="$TMP/typed"
  mkdir "$TMP/bin"
  export PATH="$TMP/bin:$PATH"
  cat >"$TMP/bin/claude" <<'SH'
#!/bin/bash
# bash 3.2's read has no fractional timeout: draw in the background instead
while :; do
  if [ -f "$SCREEN" ]; then
    # scroll the old screen away only when asked; otherwise draw over it
    [ -f "$SCREEN.append" ] || printf '\033[2J\033[H'
    cat "$SCREEN"
    rm -f "$SCREEN"
  fi
  sleep 0.1
done &
while IFS= read -r line; do printf '%s\n' "$line" >>"$TYPED"; done
wait
SH
  chmod +x "$TMP/bin/claude"
  make_bare_repo A
  cd "$REPO/main"
  collie new x --no-window
}
teardown() { teardown_env; }

draw() { printf '%s\n' "$1" >"$SCREEN.tmp"; mv "$SCREEN.tmp" "$SCREEN"; }
state() { tmux display -p -t "$(run_pane x "${1:-1}")" '#{@collie_state}'; }
start() { collie run x --agent claude -p "${1-do the work}"; }
watching() { [ -n "$(tmux show-options -wqv -t "$(run_pane x)" @collie_startup)" ]; }

@test "startup dialog: run becomes waiting, needs an answer, notifies, wait returns" {
  start
  draw "$CLAUDE_DIALOG"
  collie wait x --state waiting --timeout 10
  [ "$(state)" = waiting ]
  [ "$(collie ls | awk -F'\t' '$1 == "x" { print $7 }')" = answer ]
  wait_for 'grep -q "collie: x claude is waiting for you" "$TMP/notified"'
}

@test "startup dialog: closing it restores the starting state, then hooks lead" {
  start
  draw "$CLAUDE_DIALOG"
  wait_for '[ "$(state)" = waiting ]'
  draw "working on it"
  wait_for '[ "$(state)" = working ]'
  hook x idle
  [ "$(state)" = idle ]
  ! watching
  # the observer is gone: a later dialog-looking screen changes nothing
  draw "$CLAUDE_DIALOG"
  sleep 1.5
  [ "$(state)" = idle ]
}

@test "startup dialog: a run with no prompt goes back to idle" {
  start ''
  [ "$(state)" = idle ]
  draw "$CLAUDE_DIALOG"
  wait_for '[ "$(state)" = waiting ]'
  draw "input box"
  wait_for '[ "$(state)" = idle ]'
}

@test "startup dialog: two dialogs in a row are both reported" {
  start
  draw "$CLAUDE_DIALOG"
  wait_for '[ "$(state)" = waiting ]'
  draw "between dialogs"
  wait_for '[ "$(state)" = working ]'
  draw "$CLAUDE_DIALOG"
  wait_for '[ "$(state)" = waiting ]'
}

@test "startup dialog: a hook during the dialog ends the watch and wins" {
  start
  draw "$CLAUDE_DIALOG"
  wait_for '[ "$(state)" = waiting ]'
  hook x working
  [ "$(state)" = working ]
  ! watching
  sleep 1.5
  [ "$(state)" = working ]
}

@test "startup watch: no dialog means never waiting, and it stops after its bound" {
  export COLLIE_STARTUP_WATCH=1
  start
  draw "plain output"
  wait_for '! watching'
  draw "$CLAUDE_DIALOG"
  sleep 1.5
  [ "$(state)" = working ]
  ! grep -q "state=waiting" "$(task_dir x)/events.log"
}

@test "startup watch: dialog text above the bottom rows or in scrollback is ignored" {
  start
  # above the bottom rows, on the visible screen
  draw "$CLAUDE_DIALOG"$'\n'"$(printf 'output %s\n' 1 2 3 4 5 6 7 8)"
  sleep 1.5
  [ "$(state)" = working ]
  # scrolled off the screen entirely
  : >"$SCREEN.append"
  draw "$(printf 'line %s\n' $(seq 1 80))"
  sleep 1.5
  [ "$(state)" = working ]
  [ "$(tmux capture-pane -p -S - -t "$(run_pane x)" | grep -c 'I trust this folder')" -ge 1 ]
  ! grep -q "state=waiting" "$(task_dir x)/events.log"
}

@test "startup watch: agents with no dialog pattern are not watched" {
  collie run x --agent cat -p ''
  [ -z "$(tmux show-options -wqv -t "$(run_pane x)" @collie_startup)" ]
}

@test "send: types nothing into a detected startup dialog and exits 2" {
  start
  draw "$CLAUDE_DIALOG"
  wait_for '[ "$(state)" = waiting ]'
  run --separate-stderr collie send x hello
  [ "$status" -eq 2 ]
  [[ $stderr == *"run 1 (claude) is at a startup dialog that needs a human; not sent"* ]]
  sleep 0.5
  [ ! -e "$TYPED" ]
  ! tmux capture-pane -p -t "$(run_pane x)" | grep -q hello
  ! grep -q "	sent	" "$(task_dir x)/events.log"
}

@test "send: the screen decides, even before the state reports the dialog" {
  start ''
  hook x idle
  ! watching
  draw "$CLAUDE_DIALOG"
  wait_for 'tmux capture-pane -p -t "$(run_pane x)" | grep -q "Enter to confirm"'
  [ "$(state)" = idle ]
  run --separate-stderr collie send x hello
  [ "$status" -eq 2 ]
  sleep 0.5
  [ ! -e "$TYPED" ]
}

@test "send: still types once the dialog is gone" {
  start
  draw "$CLAUDE_DIALOG"
  wait_for '[ "$(state)" = waiting ]'
  draw "input box"
  wait_for '[ "$(state)" = working ]'
  hook x idle
  run --separate-stderr collie send x hello
  [ "$status" -eq 0 ]
  wait_for 'grep -qx hello "$TYPED"'
}

@test "sync: a conflict is not typed into a startup dialog" {
  echo mine >"$REPO/feat-x/f"
  git -C "$REPO/feat-x" add f
  git -C "$REPO/feat-x" commit -q -m mine
  start ''
  hook x idle
  draw "$CLAUDE_DIALOG"
  wait_for 'tmux capture-pane -p -t "$(run_pane x)" | grep -q "Enter to confirm"'
  echo theirs >"$TMP/origin-A/f"
  git -C "$TMP/origin-A" add f
  git -C "$TMP/origin-A" commit -q -m theirs
  run --separate-stderr collie sync
  [[ $output == *"is at a startup dialog that needs a human, resolve it in"* ]]
  sleep 0.5
  [ ! -e "$TYPED" ]
}

@test "adapters: real dialog text matches, near misses do not" {
  check() { # adapter screen
    (PLUGIN_DIR=$COLLIE_ROOT; . "$COLLIE_ROOT/agents/$1.sh"; agent_startup_dialog "$2")
  }
  codex_folder=$'\xe2\x80\xba 1. Trust and continue\n  2. Quit\n\n  enter continue \xc2\xb7 esc quit'
  codex_hooks=$'\xe2\x80\xba 1. Review hooks\n  2. Trust all and continue\n  3. Continue without trusting (hooks won\'t run)\n\n  enter confirm \xc2\xb7 esc skip'
  codex_review=$'  UserPromptSubmit      1           0           1\n\xe2\x86\x93\n  t trust all \xc2\xb7 enter review \xc2\xb7 esc close'
  gemini_folder=$' \xe2\x94\x82 \xe2\x97\x8f 1. Trust folder (feat-x)    \xe2\x94\x82\n \xe2\x94\x82   2. Trust parent folder (repo)   \xe2\x94\x82\n \xe2\x94\x82   3. Don\'t trust     \xe2\x94\x82'
  gemini_dirs=$' \xe2\x94\x82 \xe2\x97\x8f 1. Yes   \xe2\x94\x82\n \xe2\x94\x82   2. Yes, and remember the directories as trusted   \xe2\x94\x82\n \xe2\x94\x82   3. No   \xe2\x94\x82'
  check claude "$CLAUDE_DIALOG"
  check codex "$codex_folder"
  check codex "$codex_hooks"
  check codex "$codex_review"
  check gemini "$gemini_folder"
  check gemini "$gemini_dirs"
  ! check claude 'Yes, I trust this folder'
  ! check codex 'Trust and continue'
  ! check gemini '1. Trust folder'
  ! check gemini $'1. Yes\n3. No'
  ! grep -q agent_startup_dialog "$COLLIE_ROOT/agents/omp.sh"
}
