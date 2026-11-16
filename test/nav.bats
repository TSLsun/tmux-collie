#!/usr/bin/env bats

load helper

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off COLLIE_AGENT=sleep
  make_bare_repo A
  cd "$REPO/main"
}
teardown() { teardown_env; }

# a: waits for an answer, b: finished its turn, c: wrote its report (no session)
queue() {
  for t in a b c d; do collie new "$t" --no-window; done
  collie run a -- 300
  collie run b -- 300
  hook a waiting
  hook b idle
  printf '2020-01-01T00:00:00Z\trun_started\trun=1 agent=sleep repo=A\n' >>"$(task_dir c)/events.log"
  printf '# c\n\nDone.\n' >"$(task_dir c)/REPORT.md"
}

client_at() { tmux list-clients -F '#{client_session} #{window_id}'; }

@test "next: walks the queue in brief order from the current task and wraps" {
  queue
  tmux new-session -d -s main
  attach_client main
  cl=$(tmux list-clients -F '#{client_name}')
  collie next -c "$cl"
  [ "$(client_at)" = "a $(collie _target a)" ]
  collie next -c "$cl"
  [ "$(client_at)" = "b $(collie _target b)" ]
  # c has no session: next opens one, in the session's own window
  collie next -c "$cl"
  [ "$(tmux list-clients -F '#{client_session}')" = c ]
  collie next -c "$cl"
  [ "$(client_at)" = "a $(collie _target a)" ]
  # d needs nothing; from there next starts at the top
  tmux switch-client -c "$cl" -t "=a"
  collie go d >/dev/null
  tmux switch-client -c "$cl" -t "=d"
  collie next -c "$cl"
  [ "$(tmux list-clients -F '#{client_session}')" = a ]
}

@test "next: one stop per task, and nothing to do outside tmux" {
  run collie next
  [ "$status" -eq 0 ]
  [ "$output" = "collie: nothing waits on you" ]
  collie new x --no-window
  printf '2020-01-01T00:00:00Z\trun_started\trun=1 agent=sleep repo=A\n' >>"$(task_dir x)/events.log"
  printf '# x\n\nDone.\n' >"$(task_dir x)/REPORT.md"
  printf 'A\t3\topen\tfail\n' >"$(task_dir x)/pr.tsv"
  # x is both a review and a ci row; next sees it once
  [ "$(collie _todo_rows | cut -f1,2)" = $'x\treview\nx\tci' ]
  tmux new-session -d -s main
  attach_client main
  cl=$(tmux list-clients -F '#{client_name}')
  collie next -c "$cl"
  [ "$(tmux list-clients -F '#{client_session}')" = x ]
  collie next -c "$cl"
  [ "$(tmux list-clients -F '#{client_session}')" = x ]
  run collie next -n
  [ "$status" -eq 1 ]
}

@test "todo: rows carry id and action; -a lists every open task" {
  queue
  run collie _todo_rows
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1,2)" = $'a\tgo\nb\tgo\nc\treview' ]
  [[ "$output" == *$'\t'"answer    a (P2)  an agent waits for your answer"* ]]
  [ "$(collie _todo_rows -a | cut -f1 | sort | tr '\n' ' ')" = "a b c d " ]
  run collie _todo_preview c review
  [ "$status" -eq 0 ]
  [[ "$output" == *"Done."* ]]
  run collie _todo_preview d go
  [ "$status" -eq 0 ]
  [[ "$output" == *"status:"* ]]
}

# fzf stand-in: picks the row of $PICK the first time, then closes
stub_fzf() {
  cat >"$TMP/stub/fzf" <<STUB
#!/bin/sh
[ ! -e "$TMP/fzf-ran" ] || exit 130
touch "$TMP/fzf-ran"
printf '%s\n' "\$*" >"$TMP/fzf-args"
awk -F'\t' -v id="\$PICK" '\$1 == id { print; exit }'
STUB
  chmod +x "$TMP/stub/fzf"
}

@test "todo: enter goes to the task, or shows a review and comes back" {
  queue
  stub_fzf
  PICK=a run collie todo
  [ "$status" -eq 0 ]
  [ "$output" = "$(awk -F'\t' '{ print $4 }' "$(task_dir a)/repos.tsv")" ]
  [[ "$(cat "$TMP/fzf-args")" == *"_todo_preview {1} {2}"*"_todo_rows -a"* ]]
  rm "$TMP/fzf-ran"
  PICK=c run collie todo </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Done."* ]]
  [ -e "$TMP/fzf-ran" ]
}
