#!/usr/bin/env bats

load helper

setup() {
  setup_env
  export SHELL=/bin/sh COLLIE_NOTIFY=off
  make_bare_repo A
  cd "$REPO/main"
  collie new x --no-window
  export COLLIE_TASK=x
  LOG="$(task_dir x)/decisions.tsv"
}
teardown() { teardown_env; }

@test "log: the first row brings the header; ts and run are stamped" {
  collie log plan 'use ln' 'atomic header' test/log.bats ok
  [ "$(sed -n 1p "$LOG")" = $'ts\trun\tphase\tdecision\twhy\tevidence\tresult' ]
  [[ "$(sed -n 2p "$LOG")" =~ ^20[0-9-]+T[0-9:]+Z$'\t-\tplan\tuse ln\tatomic header\ttest/log.bats\tok'$ ]]
  collie log build second '' '' done
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 3 ]
  [ "$(sed -n 3p "$LOG" | cut -f2-)" = $'-\tbuild\tsecond\t\t\tdone' ]
}

@test "log: tabs, newlines and a leading = + - @ are sanitized" {
  collie log $'a\tb' $'line1\nline2\r' '=SUM(A1)' '+1' $'-x\t@y'
  run awk -F'\t' 'NR == 2 { print NF; for (i = 3; i <= NF; i++) print $i }' "$LOG"
  [ "${lines[0]}" -eq 7 ]
  [ "${lines[1]}" = "a b" ]
  [ "${lines[2]}" = "line1 line2 " ]
  [ "${lines[3]}" = "'=SUM(A1)" ]
  [ "${lines[4]}" = "'+1" ]
  [ "${lines[5]}" = "'-x @y" ]
  collie log '@me' ok ok ok ok
  [ "$(sed -n 3p "$LOG" | cut -f3)" = "'@me" ]
}

@test "log: needs five fields and a task" {
  run collie log a b c d
  [ "$status" -ne 0 ] && [[ "$output" == *"usage: collie log"* ]]
  [ ! -e "$LOG" ]
  COLLIE_TASK= run collie log a b c d e
  [ "$status" -ne 0 ] && [[ "$output" == *"COLLIE_TASK"* ]]
}

@test "log: the run comes from the agent window of this task" {
  tmux new-session -d -s s
  pane=$(tmux display-message -p -t s: '#{pane_id}')
  tmux set-option -w -t s: @collie_task x \; set-option -w -t s: @collie_run 3
  TMUX_PANE=$pane collie log build a b c d
  [ "$(sed -n 2p "$LOG" | cut -f2)" = 3 ]
  # another task's window: not this task's run
  tmux set-option -w -t s: @collie_task other
  TMUX_PANE=$pane collie log build a b c d
  [ "$(sed -n 3p "$LOG" | cut -f2)" = - ]
}

@test "show/_preview: print the last logged decision, nothing before one" {
  run collie show x
  [[ "$output" != *"last decision"* ]]
  collie log plan first why1 ev1 ok
  collie log build 'second one' 'why two' 'test/x.bats' passed
  run collie show x
  [ "$status" -eq 0 ]
  [[ "$output" == *$'last decision (of 2):\n  -  build  second one  20'* ]]
  [[ "$output" == *$'  why: why two  ·  evidence: test/x.bats  ·  result: passed\n\nevents:'* ]]
  [[ "$output" != *first* ]]
  run collie _preview x
  [ "$status" -eq 0 ]
  [[ "$output" == *$'last decision (of 2):\n  -  build  second one'*$'result: passed\n\nruns:'* ]]
}

@test "history -n: a pattern matches text in decisions.tsv" {
  collie new y --no-window
  collie log plan 'pick sqlite-free design' why ev ok
  collie done x
  collie done y
  run collie history -n sqlite-free
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ] && [[ "${lines[0]}" == *"  x  "* ]]
}
