#!/usr/bin/env bats
# Interactive `collie new`: prompts on a real tty (a pane of the test server).

load helper
bats_require_minimum_version 1.5.0

setup() {
  setup_env
  make_bare_repo A
}
teardown() { teardown_env; }

# `collie new <args>` in pane =n: of the test server, from the repo's main
# worktree; the pane shows new-exit <status> when it returns
start_new() {
  tmux -f /dev/null new-session -d -s n -x 100 -y 30 -c "$REPO/main" \
    "${NEW_ENV:-} '${COLLIE_BASH:-bash}' '$COLLIE_ROOT/bin/collie' new $*; echo new-exit \$?; sleep 60"
}

screen() { tmux capture-pane -p -J -S - -t =n:; }
shows() { wait_for "screen | grep -qF -- $(printf '%q' "$1")" || { screen >&2; return 1; }; }
type_line() { tmux send-keys -t =n: -l "$1" && tmux send-keys -t =n: Enter; }

@test "new prompts: bad id re-asks with the reason; an uppercase id offers its lowercase" {
  start_new --no-window
  shows 'task id:'
  type_line 'has space'
  shows "invalid task id 'has space'"
  type_line 'LUWA-201242-airflow-sku'
  shows 'Enter accepts luwa-201242-airflow-sku'
  shows 'task id [luwa-201242-airflow-sku]:'
  type_line ''
  shows 'type [feat]:'
  type_line 'Fix'
  shows 'type [fix]:'
  type_line ''
  shows 'objective'
  type_line 'keep what I typed'
  shows 'ship'
  type_line ''
  shows 'new-exit 0'
  [ "$(git -C "$REPO/fix-luwa-201242-airflow-sku" branch --show-current)" = fix/luwa-201242-airflow-sku ]
  grep -qx 'keep what I typed' "$(task_dir luwa-201242-airflow-sku)/TASK.md"
  [ ! -e "$COLLIE_STATE_DIR/new-draft" ]
}

@test "new prompts: an existing task id is re-asked at once" {
  (cd "$REPO/main" && collie new taken --no-window)
  start_new --no-window
  shows 'task id:'
  type_line taken
  shows "task 'taken' already exists"
  type_line fresh
  shows 'type [feat]:'
  type_line ''
  type_line ''
  shows 'ship'
  type_line ''
  shows 'new-exit 0'
  [ -f "$(task_dir fresh)/TASK.md" ]
}

@test "new prompts: a failed creation keeps the input and the next new offers it" {
  # a bad --from makes creation fail after every prompt
  start_new --no-window --from no-such-ref
  shows 'task id:'
  type_line lost
  type_line ''
  shows 'objective'
  type_line 'a long objective'
  type_line ''
  shows 'new-exit 1'
  shows "kept in $COLLIE_STATE_DIR/new-draft"
  [ ! -e "$(task_dir lost)" ]
  [ "$(sed -n 3p "$COLLIE_STATE_DIR/new-draft")" = 'a long objective' ]
  tmux kill-session -t =n
  start_new --no-window
  shows 'draft objective: a long objective'
  shows 'task id [lost]:'
  type_line ''
  type_line ''
  shows 'objective [Enter: the draft'
  type_line ''
  type_line ''
  shows 'new-exit 0'
  grep -qx 'a long objective' "$(task_dir lost)/TASK.md"
  [ ! -e "$COLLIE_STATE_DIR/new-draft" ]
}

@test "new prompts: e at the objective opens \$EDITOR on TASK.md" {
  printf '#!/bin/sh\necho edited-in-editor >>"$1"\n' >"$TMP/stub/ed"
  chmod +x "$TMP/stub/ed"
  NEW_ENV="EDITOR='$TMP/stub/ed'" start_new --no-window
  shows 'task id:'
  type_line x
  type_line ''
  shows 'objective'
  type_line e
  type_line ''
  shows 'new-exit 0'
  grep -qx edited-in-editor "$(task_dir x)/TASK.md"
}
